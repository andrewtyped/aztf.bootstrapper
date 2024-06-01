[CmdletBinding()]
param()

<#
.SYNOPSIS
Creates a new resource group, storage account, container, and spn with access to the container for running terraform deployments.
#>
function New-TfStorageAccountTest {
    [CmdletBinding()]
    param(
        [string]$SubscriptionId
    )
    $GroupName = 'rg-root-1'
    $AppReg = New-AzAppRegistration -DisplayName "$GroupName-deployer"
    $RG = New-ResourceGroup -Name $GroupName
    $StorageAcccountName = "sa$($GroupName -replace '-','')tf"
    $Account = New-TfStorageAccount -Name $StorageAcccountName -ResourceGroupName $GroupName
    Grant-SPAccessToContainer -SubscriptionId $SubscriptionId -SPObjectId $AppReg.Spid -ResourceGroupName $GroupName  -StorageAccountName $StorageAcccountName -ContainerName $Account.Container.Name
    Grant-SPAccessToResourceGroup -SubscriptionId $SubscriptionId -SPObjectId $AppReg.Spid -ResourceGroupName $GroupName

    [PSCustomObject]@{
        AppReg = $AppReg
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
        [string]$spnClientId,
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
    New-AzdoArmOidcServicePrincipalFederatedCredential @FederatedCredentialArgs
}


Import-Module -Name "$PSScriptRoot/azdo.bootstrapper.psm1"
Import-Module -Name "$PSScriptRoot/aztf.bootstrapper.psm1"


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
        Write-Host "Required environment variable $argKey is missing or has an empty value."
        $Valid = $false
    }
}

if (!$Valid) {
    return
}

Connect-AzdoRestApi @ConnectAzdoRestApiArgs

$Result = New-TfStorageAccountTest -SubscriptionId $ENV:AZ_SUBSCRIPTION_ID
New-AzdoArmServiceEndpointWithFederatedCredential -spnClientId $Result.AppReg.ClientId -serviceConnectionName $Result.AppReg.AppDisplayName
