Clear-Host
$root_path = Split-Path $PSScriptRoot -Parent

$repoRemoteOrigin = $(git config --get remote.origin.url)
$repoRemoteOrigin -match "^https://github.com/(.*)/(.*).git$" | Out-Null
$repoOwner = $Matches[1]
$repoName = $Matches[2]
$repoBranch = $(git rev-parse --abbrev-ref HEAD)
$repoBaseUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$repoBranch"

function Set-ResourceGroupName {
    param()

    $script:create_resource_group = $false
    $script:resource_group_name = $null
    $first = $true

    while ([string]::IsNullOrEmpty($script:resource_group_name) -or ($script:resource_group_name -notmatch "^[a-z0-9-_]*$")) {
        if ($first -eq $false) {
            Write-Host "Use alphanumeric characters as well as '-' or '_'."
        }
        else {
            Write-Host
            Write-Host "Provide a name for the resource group to host all the new resources that will be deployed as part of your solution."
            $first = $false
        }
        $script:resource_group_name = Read-Host -Prompt ">"

        $resourceGroup = az group list | ConvertFrom-Json | Where-Object { $_.name -eq $script:resource_group_name }
        if (!$resourceGroup) {
            $script:create_resource_group = $true
        }
        else {
            $script:create_resource_group = $false
        }
    }
}

function Get-InputSelection {
    param(
        [array] $options,
        $text,
        $separator = "`r`n",
        $default_index = $null
    )

    Write-Host
    Write-Host $text -Separator "`r`n`r`n"
    $indexed_options = @()
    for ($index = 0; $index -lt $options.Count; $index++) {
        $indexed_options += ("$($index + 1): $($options[$index])")
    }

    Write-Host $indexed_options -Separator $separator

    if (!$default_index) {
        $prompt = ">"
    }
    else {
        $prompt = "> $default_index"
    }

    while ($true) {
        $option = Read-Host -Prompt $prompt
        try {
            if (!!$default_index -and !$option)  {
                $option = $default_index
                break
            }
            elseif ([int] $option -ge 1 -and [int] $option -le $options.Count) {
                break
            }
        }
        catch {
            Write-Host "Invalid index '$($option)' provided."
        }

        Write-Host
        Write-Host "Choose from the list using an index between 1 and $($options.Count)."
    }

    return $option
}

function Get-ResourceProviderLocations {
    param(
        [string] $provider,
        [string] $typeName
    )

    $providers = $(az provider show --namespace $provider | ConvertFrom-Json)
    $resourceType = $providers.ResourceTypes | Where-Object { $_.ResourceType -eq $typeName }

    return $resourceType.locations
}

function New-Deployment {

    #region select resource group
    
    # subscription id
    $subscriptionId = az account show --query id -o tsv

    $resourceGroups = (az group list | ConvertFrom-Json | Sort-Object -Property name).name
    $option = Get-InputSelection `
        -options $resourceGroups `
        -text "Choose a resource group for your deployment from this list (using its Index):"

    $resourceGroup = $resourceGroups[$option - 1]
    #endregion
    
    #region select azure region
    $locations = Get-ResourceProviderLocations -provider 'Microsoft.Devices' -typeName 'ProvisioningServices'
    $option = Get-InputSelection `
        -options $locations `
        -text "Choose a resource group for your deployment from this list (using its Index):"

    $location = $locations[$option - 1].Replace(' ', '').ToLower()
    #endregion

    #region select number of instances to create
    Write-Host "`r`nHow many instances do you want to create?"
    $count = Read-Host -Prompt ">"
    #endregion

    #region DPS name prefix
    $dps = az iot dps list -g $resourceGroup | ConvertFrom-Json
    if ($dps.Count -gt 0) {
        $dps[0].name -match "^([0-9a-z\-_]+-)[0-9]+$"
        $dpsNamePrefix = $Matches[1]
        [System.Array]$existingDpsNames = $dps.name
    }
    else {
        $dpsNamePrefix = "mmd-dps-"
        $existingDpsNames = @()
    }
    #endregion

    #region iot hub name prefix
    $iotHubs = az iot hub list -g $resourceGroup | ConvertFrom-Json
    if ($iotHubs.Count -gt 0) {
        $iotHubs[0].name -match "^([0-9a-z\-_]+-)[0-9]+$"
        $iotHubNamePrefix = $Matches[1]
        [System.Array]$existingIoTHubNames = $iotHubs.name
    }
    else {
        $iotHubNamePrefix = "mmd-iothub-"
        $existingIoTHubNames = @()
    }
    #endregion

    #region this information should be retrieved from the environment and passed down to the template
    $storageAccount = "mmdiotstorage"
    $storageContainer = "events"

    $eventHubNamespace = "mmd-hub-1"
    $messageEventHub = "events"
    $lifecycleEventHub = "lifecycle"
    $twinsEventHub = "twinevents"
    $eventHubsAuthPolicy = "Send"

    $keyVaultName = "mmd-iot-keyvault"
    $secretExpiry = 1688152264
    #endregion
    
    $parameters = @{
        "location"                               = @{ "value" = $location }
        "resourceGroup"                          = @{ "value" = $resourceGroup }
        "instanceCount"                          = @{ "value" = [int]$count }
        "existingDpsNames"                       = @{ "value" = $existingDpsNames }
        "existingIoTHubNames"                    = @{ "value" = $existingIoTHubNames }
        "dpsNamePrefix"                          = @{ "value" = $dpsNamePrefix }
        "iotHubNamePrefix"                       = @{ "value" = $iotHubNamePrefix }
        "dpsSku"                                 = @{ "value" = "S1" }
        "dpsCapacity"                            = @{ "value" = 1 }
        "dpsDiagnosticSettings"                  = @{
            "value" = @{
                "SubscriptionId"    = $subscriptionId
                "ResourceGroup"     = $resourceGroup
                "EventHubNamespace" = "mmd-hub-1"
                "EventHub"          = "diagnostics"
            }
        }
        "iotHubSku"                              = @{ "value" = "S1" }
        "iotHubCapacity"                         = @{ "value" = 1 }
        "iotHubIdentity"                         = @{ "value" = "None" }
        "iotHubPartitionCount"                   = @{ "value" = 32 }
        "iotHubRetentionInDays"                  = @{ "value" = 7 }
        "iotHubDiagnosticSettings"               = @{
            "value" = @{
                "SubscriptionId"    = $subscriptionId
                "ResourceGroup"     = $resourceGroup
                "EventHubNamespace" = "mmd-hub-1"
                "EventHub"          = "diagnostics"
            }
        }
        "storageAccountName"                     = @{ "value" = $storageAccount }
        "containerName"                          = @{ "value" = $storageContainer }
        "eventhubSubscriptionId"                 = @{ "value" = $subscriptionId }
        "eventHubResourceGroup"                  = @{ "value" = $resourceGroup }
        "eventHubNamespace"                      = @{ "value" = $eventHubNamespace }
        "messageEventHubName"                    = @{ "value" = $messageEventHub }
        "messsageEventHubAuthorizationRuleName"  = @{ "value" = $eventHubsAuthPolicy }
        "lifeCycleEventHubName"                  = @{ "value" = $lifecycleEventHub }
        "lifecycleEventHubAuthorizationRuleName" = @{ "value" = $eventHubsAuthPolicy }
        "twinEventHubName"                       = @{ "value" = $twinsEventHub }
        "twinEventHubAuthorizationRuleName"      = @{ "value" = $eventHubsAuthPolicy }
        "keyVaultName"                           = @{ "value" = $keyVaultName }
        "envName"                                = @{ "value" = "marv" }
        "stampName"                              = @{ "value" = "stamp" }
        "version"                                = @{ "value" = "v1.0.0" }
        "owningTeam"                             = @{ "value" = "E+P" }
        "secretExpiry"                           = @{ "value" = $secretExpiry }
        "templateBaseUrl"                        = @{ "value" = $repoBaseUrl }
    }

    $parametersFile = "$($root_path)/$repoName/parameters/IoTResourceOrchestrator.Parameters.json"
    Set-Content -Path $parametersFile -Value (ConvertTo-Json $parameters -Depth 5)

    az group create -n $resourceGroup -l $location -o none

    Write-Host "`r`nParameters file location: $parametersFile"
    Write-Host "`r`nPress Enter to continue..."
    Read-Host

    $deploymentName = "mmd-iot-deployment-$(Get-Date -Format yyMMddHHmm)"
    Write-Host "`r`nCreating resource group deployment $deploymentName"
    
    az deployment group create `
        --name $deploymentName `
        --resource-group $resourceGroup `
        --template-file "./templates/IoTResourceOrchestrator.Templates.json" `
        --parameters $parametersFile | ConvertFrom-Json
}

New-Deployment