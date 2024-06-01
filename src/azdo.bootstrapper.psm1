function Get-AzdoUrls {
    [CmdletBinding()]
    param(
        [string]
        [ValidateSet('default')]
        $UrlName = 'default'
    )

    if ('default' -eq $UrlName) {
        return 'https://dev.azure.com'
    }
}

<#
.SYNOPSIS
Bundles useful data we can use to access the Azure DevOps REST API and provision new resources.
#>
function Connect-AzdoRestApi {
    param(
        [string]$tenantId,
        [string]$subscriptionId,
        [string]$subscriptionName,
        [string]$adoOrgId,
        [string]$adoOrgName,
        [string]$adoProjectId,
        [string]$adoProjectName,
        [string]$pat
    )

    if ([string]::IsNullOrEmpty($pat)) {
        $pat = Read-Host -Prompt 'Enter Azure DevOps PAT:' -AsSecureString | ConvertFrom-SecureString -AsPlainText
    }

    $authToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$pat"))
    $authHeader = "Basic $authToken"

    $AzdoConnection = [PSCustomObject]@{
        tenantId = $tenantId
        subscriptionId = $subscriptionId
        subscriptionName = $subscriptionName
        adoOrgId = $adoOrgId
        adoOrgName = $adoOrgName 
        adoProjectId = $adoProjectId
        adoProjectName = $adoProjectName
        authHeader = $authHeader
    } | ConvertTo-Json

    [System.Environment]::SetEnvironmentVariable('AZDO_CONNECTION',$AzdoConnection, 'User')
}

function Get-AzdoConnection {
    [CmdletBinding()]
    param()

    [System.Environment]::GetEnvironmentVariable('AZDO_CONNECTION', 'User') | ConvertFrom-Json
}

function Invoke-AzdoRestApi {
    param(
        [switch]$ProjectApi,
        [string]$ApiPath,
        [string][ValidateSet('GET','POST','PUT','PATCH','DELETE','OPTIONS','HEAD')]$Method = 'GET',
        [string]$ApiVersion,
        [string][ValidateSet('default')]$AzdoDomain = 'default',
        [hashtable]$QueryParameters = @{},
        [PSCustomObject]$Body
    )

    $Connection = Get-AzdoConnection
    $AzdoRootUrl = Get-AzdoUrls -UrlName $AzdoDomain

    $FinalUrlSb = [System.Text.StringBuilder]::new()

    $null = $FinalUrlSb.Append("$AzdoRootUrl/$($Connection.adoOrgName)")

    if ($ProjectApi) {
        $FinalUrlSb.Append("/$($Connection.adoProjectName)")
    }

    $null = $FinalUrlSb.Append("/_apis/$($ApiPath.TrimStart('/'))")
    $null = $FinalUrlSb.Append("?api-version=$ApiVersion")

    if ($QueryParameters.Count -gt 0) {
        $QueryParameters.Keys | ForEach-Object {
            $Key = $_
            $Value = $QueryParameters[$Key]
            $null = $FinalUrlSb.Append("&$Key=$Value")
        }
    }

    $JsonBody = ''

    if ($null -ne $Body) {
        Write-Verbose "Post body detected, converting..."
        $JsonBody = $Body | ConvertTo-Json -Depth 5
    }

    $Headers = @{
        authorization = $Connection.authHeader
        'content-type' = 'application/json'
    }

    $FinalUrl = $FinalUrlSb.ToString()

    Write-Verbose "Invoking Azdo Rest API at $FinalUrl"
    Write-Verbose "Body is $JsonBody"

    $Response = Invoke-WebRequest -Uri $FinalUrl -Method $Method -Headers $Headers -Body $JsonBody -SkipHttpErrorCheck

    if ($Response.StatusCode -eq 200 -or $response.StatusCode -eq 201) {
        return $Response.Content | ConvertFrom-Json
    }
    
    throw $Response
}


<#
.SYNOPSIS
Create a new Azure DevOps ARM service connection using workload identity federation.
#>
function New-AzdoArmOidcServiceEndpoint {
    [CmdletBinding()]
    param(
        [string]$spnClientId,
        [string]$serviceConnectionName
    )

    Write-Information "Creating service connection $serviceConnectionName to SPN $spnClientId" 

    $Connection = Get-AzdoConnection

    $body = [PSCustomObject]@{
        data = [PSCustomObject]@{
            subscriptionId = $Connection.subscriptionId
            subscriptionName = $Connection.subscriptionName
            environment = 'AzureCloud'
            scopeLevel = 'Subscription'
            creationMode = 'Manual'
        }
        name = $serviceConnectionName
        type = 'AzureRM'
        url = 'https://management.azure.com/'
        authorization = [PSCustomObject]@{
            parameters = [PSCustomObject]@{
                #workloadIdentityFederationSubject = "sc://$($Connection.adoOrgName)/$($Connection.adoProjectName)/$serviceConnectionName"
                #workloadIdentityFederationIssuer = "https://vstoken.dev.azure.com/$($Connection.adoOrgId)"
                serviceprincipalid = $spnClientId
                tenantid = $Connection.tenantId
            }
            scheme = 'WorkloadIdentityFederation'
        }
        isShared = $false
        isReady = $true
        serviceEndpointProjectReferences = @(
            [PSCustomObject]@{
                projectReference = [PSCustomObject]@{
                    id = $Connection.adoProjectId 
                    name = $Connection.adoProjectName
                }
                name = $serviceConnectionName
            }
        )
    }

    $Request = @{
        ApiPath = 'serviceendpoint/endpoints'
        ApiVersion = '7.2-preview.4'
        Body = $body
        Method = 'POST'
    }

    $null = Invoke-AzdoRestApi @Request -ErrorAction Stop 

    [PSCustomObject]@{
        ServiceConnectionName = $serviceConnectionName
        ServicePrincipalId = $spnClientId
        AdAppFederatedCredential = [PSCustomObject]@{
            Subject = "sc://$($Connection.adoOrgName)/$($Connection.adoProjectName)/$serviceConnectionName"
            Issuer = "https://vstoken.dev.azure.com/$($Connection.adoOrgId)"
            Audience = 'api://AzureADTokenExchange'
        }
    }
}
