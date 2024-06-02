[CmdletBinding()]
param(
    [Parameter()]
    [string]$GroupName = 'rg-root-1'
)

<#
.SYNOPSIS
Creates a new resource group, storage account, container, and spn with access to the container for running terraform deployments.
#>
function New-TfStorageAccountTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,
        [Parameter()]
        [string]$GroupName = 'rg-root-1'
    )
    $AppReg = New-AzAppRegistration -DisplayName "$GroupName-deployer"
    $ResourceGroup = New-ResourceGroup -Name $GroupName
    $StorageAcccountName = "sa$($GroupName -replace '-','')tf"
    $Account = New-TfStorageAccount -Name $StorageAcccountName -ResourceGroupName $GroupName -SubscriptionId $SubscriptionId
    $null = Grant-SPAccessToContainer -SubscriptionId $SubscriptionId -SPObjectId $AppReg.Spid -ResourceGroupName $GroupName  -StorageAccountName $StorageAcccountName -ContainerName $Account.Container
    $null = Grant-SPAccessToResourceGroup -SubscriptionId $SubscriptionId -SPObjectId $AppReg.Spid -ResourceGroupName $GroupName

    [PSCustomObject]@{
        AppReg = $AppReg
        ResourceGroup = $ResourceGroup
        StorageAccount = $Account
    }
}

<#
.SYNOPSIS
Create an Azure DevOps ARM service connection using workload identity federation.  Create a federated secret on an Azure service principal. This SPN will be used to run 
Terraform deployments of new resource groups in a subscription.
#>
function New-AzdoArmServiceEndpointWithFederatedCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$spnClientId,
        [Parameter(Mandatory)]
        [string]$serviceConnectionName
    )

    $ServiceEndpoint = New-AzdoArmOidcServiceEndpoint -spnClientId $spnClientId -serviceConnectionName $serviceConnectionName
    $FederatedCredentialArgs = @{
        SpnClientId = $spnClientId
        ServiceConnectionName = $serviceConnectionName
        Subject = $ServiceEndpoint.AdAppFederatedCredential.Subject
        Issuer = $ServiceEndpoint.AdAppFederatedCredential.Issuer
        Audience = $ServiceEndpoint.AdAppFederatedCredential.Audience
    }
    $FederatedCredentialResponse = New-AzdoArmOidcServicePrincipalFederatedCredential @FederatedCredentialArgs

    return [PSCustomObject]@{
        AzureDevOpsResponse = $ServiceEndpoint
        AzureSpnFederatedCredentialResponse = $FederatedCredentialResponse
    }
}

Import-Module -Name "$PSScriptRoot/azdo.bootstrapper.psm1" -Force
Import-Module -Name "$PSScriptRoot/aztf.bootstrapper.psm1" -Force

$ConnectAzdoRestApiArgs = @{
    TenantId = $ENV:AZ_TENANT_ID
    SubscriptionId = $ENV:AZ_SUBSCRIPTION_ID
    SubscriptionName = $ENV:AZ_SUBSCRIPTION_NAME
    AdoOrgId = $ENV:ADO_ORG_ID
    AdoOrgName = $ENV:ADO_ORG_NAME
    AdoProjectId = $ENV:ADO_PROJECT_ID
    AdoProjectName = $ENV:ADO_PROJECT_NAME
    PAT = $ENV:ADO_PAT
}

$Valid = $true

foreach($argKey in $ConnectAzdoRestApiArgs.Keys) {
    if ([string]::IsNullOrWhiteSpace(($ConnectAzdoRestApiArgs[$argKey]))) {
        Write-Host "Required environment variable for $argKey is missing or has an empty value."
        $Valid = $false
    }
}

if (!$Valid) {
    return
}

Connect-AzdoRestApi @ConnectAzdoRestApiArgs

try
{
    $StorageAccountResult = New-TfStorageAccountTest -SubscriptionId $ENV:AZ_SUBSCRIPTION_ID -GroupName $GroupName

    Write-Information "ClientId is $($StorageAccountResult.AppReg.ClientId)"
    Write-Information "AppDisplayName is $($StorageAccountResult.AppReg.AppDisplayName)"

    #TODO: SOmething is wrong with the REST API call, we are getting an exception at the very end.
    # We are getting 401. PAT isn't working, something up with header encoding... lame. tryu again later.
    $ServiceEndpointResult = New-AzdoArmServiceEndpointWithFederatedCredential -spnClientId $StorageAccountResult.AppReg.ClientId -serviceConnectionName $StorageAccountResult.AppReg.AppDisplayName

    return [PSCustomObject]@{
        StorageAccountResult = $StorageAccountResult
        ServiceEndpointResult = $ServiceEndpointResult
    }
} catch{
    Write-Error $_

    return [PSCustomObject]@{
        StorageAccountResult = $StorageAccountResult
        ServiceEndpointResult = $ServiceEndpointResult
    }
}