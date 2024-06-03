# This module contains functions for creating a "root" resource group, storage account, and service principal for an Azure subscription.
# The account will host tfstate that tracks other resource groups in the subscription. 

function Get-DefaultLocation {
    'eastus'
}


<#
.SYNOPSIS
Creates a new Azure app registration and service principal in the caller's current subscription.
#>
function New-AzAppRegistration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$DisplayName
    )

    Write-Information "Creating App Registration named $DisplayName..."

    $appId = & az ad app create --display-name $DisplayName --query id --output tsv

    if (0 -ne $LASTEXITCODE) {
        throw "Failed to create enterprise app '$DisplayName'."
    }

    $spIdJson = & az ad sp create --id $AppId --query '{id:id, appId:appId}' --output json

    if (0 -ne $LASTEXITCODE) {
        throw "Failed to create service principal for enterprise app '$appId' with display name '$DisplayName'"
    }

    $spId = $spIdJson | ConvertFrom-Json

    Write-Information "AppId is $appId"
    Write-Information "AppDisplayName is $DisplayName"
    Write-Information "SpId is $($spId.Id)"
    Write-Information "ClientId is $($spId.AppId)"

    [PSCustomObject]@{
        AppId = $appId
        AppDisplayName = $DisplayName
        SpId = $spId.Id
        ClientId = $spId.AppId
    }
}

<#
.SYNOPSIS
Gets Azure app registration details for the app with the specified client or object ID.
#>
function Get-AzApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AppId
    )

    & az ad app show --id $AppId
}

function New-ResourceGroup {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$Location = (Get-DefaultLocation)
    )

    Write-Information "Creating Resource Group named $Name in $Location..."

    $null = & az group create --name $Name --location $Location

    [PSCustomObject]@{
        Name = $Name
        Location = $Location
    }
}


<#
.SYNOPSIS
Create a new azure storage account with a container for storing tfstate. This account is open to the public internet, which is not ideal, but
a more secure setup with private networking will require a two-phase bootstrap of network resources in addition to the subscription-level 
Terraform resource group.
#>
function New-TfStorageAccount {
    [CmdletBinding()]
    param(
       [Parameter(Mandatory)]
       [string]$Name,

       [Parameter(Mandatory)]
       [string]$SubscriptionId,
 
       [Parameter(Mandatory)]
       [string]$ResourceGroupName,
 
       [Parameter()]
       [string]$Location = (Get-DefaultLocation),

       [Parameter()]
       [string]$ContainerName = 'tfstate-container'
    )

    Write-Information "Creating storage account with name $Name" 
 
    $checkNameResult = & az storage account check-name --name $Name --query nameAvailable --output tsv
 
    if ('false' -eq $checkNameResult) {
       throw "Cannot create storage account '$Name' because it already exists."
    }
 
    # Default action is set to allow right now to accommodate access from MS hosted agents in Azure DevOps. 
    # The only way to allow list those IPs is using their stupid weekly published file (~100 IP range entries per region) and manually ACL-ing each IP range. 
    # Self-hosted agents are really the way to go.
    $account = & az storage account create `
      --name $Name `
      --resource-group $ResourceGroupName `
      --location $Location `
      --allow-blob-public-access 'false' `
      --allow-shared-key-access 'false' `
      --https-only 'true' `
      --kind 'StorageV2' `
      --default-action 'Allow' `
      --min-tls-version 'TLS1_2' `
      --public-network-access 'Enabled' `
      --sku 'Standard_LRS'
 
    if (0 -ne $LASTEXITCODE) {
     throw "Failed to create storage account '$Name'."
    }

    # Even a subscription owner can't provision storage account objects directly - Storage contributor/owner rights are necessary
    $null = Grant-PersonalAccessToContainer -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -StorageAccountName $Name

    # RBAC Grants take time to propagate. Use retry.
    $MaxAttempts = 10
    $SleepTimeSec = 15
    $Attempt = 0

    while ($Attempt -lt $MaxAttempts) {
        Write-Information "Attempt $Attempt/$MaxAttempts to create storage container tfstate-container on account $Name..."
        $null  = az storage container create `
        --name $ContainerName `
        --auth-mode 'login' `
        --fail-on-exist `
        --public-access 'off' `
        --account-name $Name

        if (0 -ne $LASTEXITCODE) {
            Start-Sleep -Seconds $SleepTimeSec
            $Attempt++
        } else {
            Write-Information "Success!"
            break
        }
    }
 
     if (0 -ne $LASTEXITCODE) {
         throw "Failed to create storage container 'tfstate-container' on account '$Name'."
     }
 
     [PSCustomObject]@{
         Account = ($account | ConvertFrom-Json)
         Container = $ContainerName
     }
 }


function Grant-PersonalAccessToContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$StorageAccountName
    )

    $UserId = (az ad signed-in-user show --query id -o tsv)
    Write-Information "Granting storage blob access to $StorageAccountName/$ContainerName for User $UserId" 

    $null = az role assignment create `
      --role 'Storage Blob Data Owner' `
      --assignee-object-id $UserId `
      --assignee-principal-type 'User' `
      --scope "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"
}

<#
.SYNOPSIS
Assign storage blob data contributor role to a service princpal in a particular container. This allows the SPN access to read and write data to the container. 
For our purposes this means the SPN can be used to manage tfstate.

.PARAMETER SPObjectId
The OBJECT ID (really the object id, not the client ID or anything else) of the SPN to grant rights to. 
#>
function Grant-SPAccessToContainer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SPObjectId,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory)]
        [string]$StorageAccountName,

        [Parameter(Mandatory)]
        [string]$ContainerName
    )

    Write-Information "Granting storage blob access to $StorageAccountName/$ContainerName for SPN $SPObjectId" 

    $null = az role assignment create `
      --role 'Storage Blob Data Contributor' `
      --assignee-object-id $SPObjectId `
      --assignee-principal-type 'ServicePrincipal' `
      --scope "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName/blobServices/default/containers/$ContainerName"
}

<#
.SYNOPSIS
Assign Contributor rights to one resource group for a service principal, meaning the SPN can create or delete resources in the group. For our purposes,
this means the SPN can be used to apply changes to the resource group with terraform.
#>
function Grant-SPAccessToResourceGroup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SPObjectId,

        [Parameter(Mandatory)]
        [string]$SubscriptionId,

        [Parameter(Mandatory)]
        [string]$ResourceGroupName
    )

    Write-Information "Granting resource group access to $ResourceGroupName for SPN $SPObjectId" 

    $null = az role assignment create `
      --role 'Contributor' `
      --assignee-object-id $SPObjectId `
      --assignee-principal-type 'ServicePrincipal' `
      --scope "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
}

<#
.SYNOPSIS
Assign Contributor rights to a subscription for a service principal, meaning the SPN can create or delete resources at the subscription level, such as resource groups. 
For our purposes, this means the SPN can be used to provision new resource groups.
#>
function Grant-SPAccessToSubscription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SPObjectId,

        [Parameter(Mandatory)]
        [string]$SubscriptionId
    )

    Write-Information "Granting subscription access to $ResourceGroupName for SPN $SPObjectId" 

    $null = az role assignment create `
      --role 'Contributor' `
      --assignee-object-id $SPObjectId `
      --assignee-principal-type 'ServicePrincipal' `
      --scope "/subscriptions/$SubscriptionId"
}

<#
.SYNOPSIS
Create a federated credential on a service principal. This implementation is designed to create a federated credential compatible with Azure DevOps ARM service connections
using workload identity federation.
#>
function New-AzdoArmOidcServicePrincipalFederatedCredential {
    [CmdletBinding()]
    param(
        [string]$serviceConnectionName,
        [string]$spnClientId,
        [string]$subject,
        [string]$issuer,
        [string]$audience
    )

    Write-Information "Creating Federated secret on $spnClientId" 

    $FederatedCredentialParameters = [PSCustomObject]@{
        Name = $serviceConnectionName
        Issuer = $issuer
        Subject = $subject
        Description = $serviceConnectionName
        Audiences = @(
            $audience 
        )
    } | ConvertTo-Json -Compress

    # Note use of @- below - az cli understands this to mean input comes from stdin.
    $FederatedCredentialParameters | & az ad app federated-credential create `
      --id $spnClientId `
      --parameters "@-" 

}

Export-ModuleMember -Function *