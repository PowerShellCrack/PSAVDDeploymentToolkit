
<#
    .SYNOPSIS
    Sets up azure environment

    .DESCRIPTION
    Sets up azure environment to support this toolkit and AIB

    .NOTES
    AUTHOR: Dick Tracy II (@powershellcrack)
    PROCESS: What this script will do (in order) if nothing esits
    1.  Install required Az modules
    2.  Connect to Azure
    3.  Enable Azure resources to support AIB (if use -AibSupport)
    4.  Create resource groups
    5.  Create key vault
    6.  store admin password in keyvault
    7.  Create shared image gallery
    8.  Create managed identity for AIB, Storage and Keyvault access (if use -AibSupport)
    9.  Build roldefinition for AIB (if use -AibSupport)
    10. Create storage account and set permissions (if use -AibSupport)
    11. Create container with public access
    10. Generate Sastoken and store in config
    
    TIP: this script can be ran more than once and will check each configuration

    TODO:
        - Create keyvault -DONE 6/9/2023
        - Setup storage account with appropiate vnet access
        - Setup key rotation for storage account to keyvault
        - Store Sastoken in keyvault instead of config -DONE 6/9/2023
        - Randomize admin password and store in keyvault (used with bastion) -DONE 6/9/2023
        - Use access policies to build sastoken permisssions
        - Give AIB managed identity access to keyvault secrets
        - Store workspaceid an workspacekey in keyvault -DONE 6/9/2023
        - Setup key rotation for workspacekey to keyvault

    .PARAMETER ResourcePath
    Specify a path other than the relative path this script is running in

    .PARAMETER ControlSettings
    Specify a confoguration file. Defaults to settings.json

    .PARAMETER AibSupport
    Enabled feature and roles required fo AIB to function

    .PARAMETER ForceNewSasToken
    Forces a new sas token for blob storage even if date is still valid
    
    .PARAMETER SasTokenExpireDays
    Set the number of days the SasToek will expire. Defaults to 5

    .PARAMETER ReturnSasToken
    Returns the output of the sas token; testing purposes

    .PARAMETER ForceKeyVaultAdminSecret
    Forces a new admin password is set in key vault

    .PARAMETER PromptAdminPassword
    Prompts for a password instead of random

    .OUTPUTS
    a1_prep_azureenv_<date>.log <-- Transaction Log file

    .EXAMPLE
    PS .\A1_prep_azureenv.ps1

    RESULT: Run default setting 

   .EXAMPLE
    PS .\A1_prep_azureenv.ps1 -ControlSettings setting.gov.json

    RESULT: Run script using configuration for a gov tenant

    .EXAMPLE
    PS .\A1_prep_azureenv.ps1 -ResourcePath C:\Temp -ControlSettings setting.test.json -ForceNewSasToken

    RESULT: Run script using configuration from a another file, while the toolkit is in C:\Temp, and force a sastoken

    .EXAMPLE
    PS .\A1_prep_azureenv.ps1 -ControlSettings setting.test.json -AibSupport

    RESULT: Run script using configuration from a another file, and setup AIB support infrastructure

    .LINK
    https://github.com/Azure/KeyVault-Secrets-Rotation-StorageAccount-PowerShell
#>
Param(
    [Parameter(Mandatory = $false)]
    [string]$ResourcePath,
    
    [Parameter(Mandatory = $false)]
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )


        $ToolkitSettings = Get-Childitem "$PSScriptRoot\Control" -Filter Settings* | Where Extension -eq '.json' | Select -ExpandProperty Name

        $ToolkitSettings | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("Config","Setting")]
    [string]$ControlSettings = "settings.json",

    [switch]$ForceKeyVaultAdminSecret,

    [switch]$PromptAdminPassword,

    [switch]$AibSupport, 

    [int]$SasTokenExpireDays = 5,

    [switch]$ForceNewSasToken,

    [switch]$ReturnSasToken
)
#Requires -Modules Az.Accounts,Az.ImageBuilder,Az.ManagedServiceIdentity,Az.Resources,Az.Storage,Az.Compute,Az.Monitor,Az.KeyVault,Az.OperationalInsights
##======================
## VARIABLES
##======================
$ScriptInvocation = (Get-Variable MyInvocation -Scope Script).Value

$ErrorActionPreference = "Stop"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# Save current progress preference and hide the progress
$prevProgressPreference = $global:ProgressPreference
$global:ProgressPreference = 'SilentlyContinue'
#Check if verbose is used; if it is don't use the nonewline in output
If($VerbosePreference){$NoNewLine=$False}Else{$NoNewLine=$True}

If(!$ResourcePath){
    #resolve path locally
    [string]$ResourcePath = ($PWD.ProviderPath, $PSScriptRoot)[[bool]$PSScriptRoot]
}

#build log directory and File
New-Item "$ResourcePath\Logs" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
$DateLogFormat = (Get-Date).ToString('yyyy-MM-dd_Thh-mm-ss-tt')
$LogfileName = ($ScriptInvocation.MyCommand.Name.replace('.ps1','_').ToLower() + $DateLogFormat + '.log')
Start-transcript "$ResourcePath\Logs\$LogfileName" -ErrorAction Stop

## ================================
## GET SETTINGS
## ================================
$ToolkitSettings = Get-Content "$ResourcePath\Control\$ControlSettings" -Raw | ConvertFrom-Json

##======================
## FUNCTIONS
##======================


#region Sequencer custom functions
. "$ResourcePath\Scripts\Environment.ps1"
. "$ResourcePath\Scripts\Symbols.ps1"
. "$ResourcePath\Scripts\LogAnalytics.ps1"
. "$ResourcePath\Scripts\BlobControl.ps1"


# Add AZ PS modules to support AzUserAssignedIdentity and Az AIB
##*=============================================
##* INSTALL MODULES
##*=============================================
Write-Host ("`nSTARTING MODULE CHECK") -ForegroundColor Cyan

If(Test-IsAdmin){
    If(-NOT(Get-PackageProvider -Name Nuget)){Install-PackageProvider -Name Nuget -ForceBootstrap -RequiredVersion '2.8.5.201' -Force | Out-Null}
    Write-Host ("    |---[{0} of {1}]: Checking install policy for PSGallery..." -f 1,($ToolkitSettings.Settings.supportingModules.count+1)) -NoNewline
    If($PSGallery = Get-PSRepository -Name "PSGallery"){
        If($PSGallery.InstallationPolicy -ne 'Trusted'){
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
    }Else{
        Register-PSRepository -Name "PSGallery" -SourceLocation "https://www.powershellgallery.com/api/v2/" -InstallationPolicy Trusted
    }
    Write-Host "Trusted" -ForegroundColor Green
}

$AzModuleList = @('Az.Accounts','Az.ImageBuilder','Az.ManagedServiceIdentity','Az.Resources','Az.Storage','Az.Compute','Az.Monitor','Az.KeyVault','Az.OperationalInsights')
$i=1
Foreach($Module in $AzModuleList){
    $i++
    Write-Host ("    |---[{0} of {1}]: Installing module {2}..." -f $i,($AzModuleList.count+1),$Module) -NoNewline:$NoNewLine
    if ( Get-Module -FullyQualifiedName $Module -ListAvailable) {
        Write-Host ("already installed") -ForegroundColor Green
    }
    else {
        Try{
            If(Test-IsAdmin){
                # Needs to be installed as an admin so that the module will execte
                Install-Module -Name $Module -ErrorAction Stop -Scope AllUsers | Out-Null
                Import-Module -Name $Module -Global
            }Else{
                # Needs to be installed as an admin so that the module will execte
                Install-Module -Name $Module -ErrorAction Stop | Out-Null
                Import-Module -Name $Module
            }
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }
        Catch {
            Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message)
            exit
        }
    } 
}

#=======================================================
# CONNECT TO AZURE
#=======================================================
Write-Host "AZURE SIGNIN..." -ForegroundColor Cyan

Switch($ToolkitSettings.TenantEnvironment.azureEnvironment){
    'AzureUSPublic' {$blobUriAppendix = ".blob.core.windows.net"; $ToolkitSettings.TenantEnvironment.azureEnvironment = 'AzureCloud'}
    'AzureCloud' {$blobUriAppendix = ".blob.core.windows.net"}
    'AzureUSGovernment' {$blobUriAppendix = "blob.core.usgovcloudapi.net"}
    'USsec' {
        Add-AzEnvironment -AutoDiscover 'https://management.azure.microsoft.scloud/metadata/endpoints?api-version=2020-06-01'
        $blobUriAppendix = "blob.core.microsoft.scloud"
    }
}

Connect-AzAccount -Environment $ToolkitSettings.TenantEnvironment.azureEnvironment
Set-AzContext -Subscription $ToolkitSettings.TenantEnvironment.subscriptionName

# Step 2: get existing context
$currentAzContext = Get-AzContext
# your subscription, this will get your current subscription
$subscriptionID=$currentAzContext.Subscription.Id

Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null
#=========================================================
## ENABLE AZURE RESOURCE PROVIDER FOR AIB
#=========================================================
<#
#REFERENCE: https://docs.microsoft.com/en-us/azure/virtual-machines/image-builder-overview?tabs=azure-powershell
Get-AzResourceProvider -ProviderNamespace Microsoft.Compute, Microsoft.KeyVault, Microsoft.Storage, Microsoft.VirtualMachineImages, Microsoft.Network |
    Where-Object RegistrationState -ne Registered | Register-AzResourceProvider
#>
Write-Host "AZURE PREREQUISITES..." -ForegroundColor Cyan

$AzureProviders = Get-AzResourceProvider -ProviderNamespace Microsoft.Compute, Microsoft.KeyVault, Microsoft.Storage, Microsoft.Network -Location $ToolkitSettings.TenantEnvironment.location -ErrorAction SilentlyContinue
#install Devlabs for Arm Templates support
Write-Host ("`nValidating [{0}] Azure Resource providers are registered..." -f $AzureProviders.count)
$i=0
Foreach ($Provider in $AzureProviders){
    $i++
    Write-Host ("    |---[{0}/{1}] {2} [" -f $i,$AzureProviders.count,$Provider.ProviderNamespace) -ForegroundColor White -NoNewline
    Write-Host ("{0}" -f $Provider.ResourceTypes.ResourceTypeName) -ForegroundColor Cyan -NoNewline
    Write-Host ("]...") -ForegroundColor White -NoNewline
    If($Provider.RegistrationState -eq 'NotRegistered'){
        Try{
            Register-AzResourceProvider -ProviderNamespace $Provider.ProviderNamespace | Out-Null
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }
        Catch{
            Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
            Stop-Transcript;Break
        }

    }Else{
        Write-Host ("{0} Already registered" -f (Get-Symbol -Symbol GreenCheckmark)) -ForegroundColor Green
    }
}

If($AibSupport){
    Write-Host ("`nValidating Azure Image builder is enabled for [{0}]..." -f ($currentAzContext).Environment.Name)
    If(($currentAzContext).Environment.Name -eq 'AzureUSGovernment'){
        $AIBProviders = Get-AzResourceProvider -ProviderNamespace Microsoft.VirtualMachineImages -Location $ToolkitSettings.TenantEnvironment.location -ErrorAction SilentlyContinue
        Register-AzProviderPreviewFeature -ProviderNamespace Microsoft.VirtualMachineImages -Name FairfaxPublicPreview
        #Get-AzResourceProvider -ProviderNamespace Microsoft.VirtualMachineImages -Name FairfaxPublicPreview
        Foreach($AIBProvider in $AIBProviders){
            If($AIBProvider.RegistrationState -eq 'NotRegistered'){
                Write-Host ("    |---Registering {0}..." -f $AIBProvider.ProviderNamespace) -NoNewline
                Try{
                    
                    Register-AzResourceProvider -ProviderNamespace $AIBProvider.ProviderNamespace | Out-Null
                    Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
                }
                Catch{
                    Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
                    Stop-Transcript;Break
                }
        
            }Else{
                Write-Host ("    |---{0} {1} Already registered" -f (Get-Symbol -Symbol GreenCheckmark),$AIBProvider.ProviderNamespace) -ForegroundColor Green
            }
        }
        
    }
    Else{
        #Write-Host ("Azure resource provider [Microsoft.VirtualMachineImages] is not available, unable to continue!") -ForegroundColor Red
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0} not available in cloud: {1}!" -f (Get-Symbol -Symbol WarningSign),($currentAzContext).Environment.Name) -Severity 3
    }
}

#>

#=========================================================
# CREATE RESOURCE GROUPS
#=========================================================
Write-Host ("`nBuilding Azure Resources for tenantid [{0}]..." -f $currentAzContext.Tenant.Id)

If(-Not(Get-AzResourceGroup -Name $ToolkitSettings.AzureResources.imageResourceGroup -ErrorAction SilentlyContinue))
{
    Write-Host ("    |---Creating Azure Resource Group [{0}] for image gallery..." -f $ToolkitSettings.AzureResources.imageResourceGroup) -ForegroundColor White -NoNewline:$NoNewLine
    Try{
        New-AzResourceGroup -Name $ToolkitSettings.AzureResources.imageResourceGroup -Location $ToolkitSettings.TenantEnvironment.location -ErrorAction Stop | Out-Null
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }
    Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Using Azure Resource Group [{0}] for image gallery! {1}" -f $ToolkitSettings.AzureResources.imageResourceGroup,(Get-Symbol -Symbol GreenCheckmark))
}

If(-Not(Get-AzResourceGroup -Name $ToolkitSettings.AzureResources.storageResourceGroup -ErrorAction SilentlyContinue))
{
    Write-Host ("    |---Creating Azure Resource Group [{0}] for storage account..." -f $ToolkitSettings.AzureResources.storageResourceGroup) -ForegroundColor White -NoNewline:$NoNewLine
    Try{
        New-AzResourceGroup -Name $ToolkitSettings.AzureResources.storageResourceGroup -Location $ToolkitSettings.TenantEnvironment.location -ErrorAction Stop | Out-Null
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }
    Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Using Azure Resource Group [{0}] for storage account! {1}" -f $ToolkitSettings.AzureResources.storageResourceGroup,(Get-Symbol -Symbol GreenCheckmark))
}

If(-Not(Get-AzResourceGroup -Name $ToolkitSettings.AzureResources.keyVaultResourceGroup -ErrorAction SilentlyContinue))
{
    Write-Host ("    |---Creating Azure Resource Group [{0}] for keyvault..." -f $ToolkitSettings.AzureResources.keyVaultResourceGroup) -ForegroundColor White -NoNewline:$NoNewLine
    Try{
        New-AzResourceGroup -Name $ToolkitSettings.AzureResources.keyVaultResourceGroup -Location $ToolkitSettings.TenantEnvironment.location -ErrorAction Stop | Out-Null
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }
    Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Using Azure Resource Group [{0}] for keyvault! {1}" -f $ToolkitSettings.AzureResources.keyVaultResourceGroup,(Get-Symbol -Symbol GreenCheckmark))
}

If(-Not(Get-AzResourceGroup -Name $ToolkitSettings.AzureResources.computeResourceGroup -ErrorAction SilentlyContinue))
{
    Write-Host ("    |---Creating Azure Resource Group [{0}] for compute..." -f $ToolkitSettings.AzureResources.computeResourceGroup) -ForegroundColor White -NoNewline:$NoNewLine
    Try{
        New-AzResourceGroup -Name $ToolkitSettings.AzureResources.computeResourceGroup -Location $ToolkitSettings.TenantEnvironment.location -ErrorAction Stop | Out-Null
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }
    Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Using Azure Resource Group [{0}] for compute! {1}" -f $ToolkitSettings.AzureResources.computeResourceGroup,(Get-Symbol -Symbol GreenCheckmark))
}

If(-Not(Get-AzResourceGroup -Name $ToolkitSettings.AzureResources.networkResourceGroup -ErrorAction SilentlyContinue))
{
    Write-Host ("    |---Creating Azure Resource Group [{0}] for network..." -f $ToolkitSettings.AzureResources.networkResourceGroup) -ForegroundColor White -NoNewline:$NoNewLine
    Try{
        New-AzResourceGroup -Name $ToolkitSettings.AzureResources.networkResourceGroup -Location $ToolkitSettings.TenantEnvironment.location -ErrorAction Stop | Out-Null
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }
    Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Using Azure Resource Group [{0}] for network! {1}" -f $ToolkitSettings.AzureResources.networkResourceGroup,(Get-Symbol -Symbol GreenCheckmark))
}


If(-Not(Get-AzResourceGroup -Name $ToolkitSettings.LogAnalytics.resourceGroup -ErrorAction SilentlyContinue))
{
    Write-Host ("    |---Creating Azure Resource Group [{0}] for log analytics..." -f $ToolkitSettings.LogAnalytics.resourceGroup) -ForegroundColor White -NoNewline:$NoNewLine
    Try{
        New-AzResourceGroup -Name $ToolkitSettings.LogAnalytics.resourceGroup -Location $ToolkitSettings.TenantEnvironment.location -ErrorAction Stop | Out-Null
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }
    Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Using Azure Resource Group [{0}] for log analytics! {1}" -f$ToolkitSettings.LogAnalytics.resourceGroup,(Get-Symbol -Symbol GreenCheckmark))
}
#=========================================================
# CREATE SHARED IMAGE GALLERY
#=========================================================
If(-Not($Gallery = Get-AzGallery -ResourceGroupName $ToolkitSettings.AzureResources.imageResourceGroup -Name $ToolkitSettings.AzureResources.imageComputeGallery -ErrorAction SilentlyContinue)){
    Try{
        Write-Host ("    |---Creating Azure Shared Image Gallery [{0}]..." -f $ToolkitSettings.AzureResources.imageComputeGallery) -ForegroundColor White -NoNewline:$NoNewLine
        $parameters = @{
            GalleryName = $ToolkitSettings.AzureResources.imageComputeGallery
            ResourceGroupName = $ToolkitSettings.AzureResources.imageResourceGroup
            Location = $ToolkitSettings.TenantEnvironment.location
        }
        $Null = New-AzGallery @parameters
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -BackgroundColor Red
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Using Azure Shared Image Gallery [{0}] {1}" -f $ToolkitSettings.AzureResources.imageComputeGallery,(Get-Symbol -Symbol GreenCheckmark))
}

#=========================================================
# CREATE KEYVAULT
#=========================================================
#REFERENCE: https://learn.microsoft.com/en-us/azure/key-vault/secrets/quick-create-powershell
If(-Not($KeyVault = Get-AzKeyVault -ResourceGroupName $ToolkitSettings.AzureResources.keyVaultResourceGroup -Name $ToolkitSettings.AzureResources.keyVault -ErrorAction SilentlyContinue)){
    Try{
        Write-Host ("    |---Creating Azure Keyvault [{0}]..." -f $ToolkitSettings.AzureResources.keyVault) -ForegroundColor White -NoNewline:$NoNewLine
        $parameters = @{
            Name = $ToolkitSettings.AzureResources.keyVault
            ResourceGroupName = $ToolkitSettings.AzureResources.keyVaultResourceGroup
            Location = $ToolkitSettings.TenantEnvironment.location
        }
        $Null = New-AzKeyVault @parameters
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -BackgroundColor Red
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Using Azure Keyvault [{0}] {1}" -f $ToolkitSettings.AzureResources.keyVault,(Get-Symbol -Symbol GreenCheckmark))
}

#=========================================================
# MANAGE WORKSPACE ID AND KEYS
#=========================================================
If([Boolean]::Parse($ToolkitSettings.Settings.recordToLaw)){
    If(-Not($Workspace = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ToolkitSettings.LogAnalytics.resourceGroup -Name $ToolkitSettings.LogAnalytics.name -ErrorAction SilentlyContinue)){
        Try{
            Write-Host ("    |---Creating Azure Log Analytics workspace [{0}]..." -f $ToolkitSettings.AzureResources.keyVault) -ForegroundColor White -NoNewline:$NoNewLine
            $parameters = @{
                Name = $ToolkitSettings.LogAnalytics.name
                ResourceGroupName = $ToolkitSettings.LogAnalytics.resourceGroup
                Location = $ToolkitSettings.TenantEnvironment.location
            }
            $Null = New-AzOperationalInsightsWorkspace @parameters
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }Catch{
            #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -BackgroundColor Red
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }
    }Else{
        Write-Host ("    |---Using Azure Log Analytics workspace [{0}] {1}" -f $ToolkitSettings.AzureResources.keyVault,(Get-Symbol -Symbol GreenCheckmark))
    }

    $WorkspaceIDKeyVaultName = (($ToolkitSettings.LogAnalytics.name -replace '\W+').ToLower() + 'Id')
    If($ToolkitSettings.LogAnalytics.workspaceId -eq '[KeyVault]' -and !($null = Get-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault -Name $WorkspaceIDKeyVaultName -ErrorAction SilentlyContinue)){
        
        $secretvalue = ConvertTo-SecureString $Workspace.CustomerId -AsPlainText -Force
        Try{
            Write-Host ("    |---Storing to Keyvault workplace id secret [{0}]..." -f $WorkspaceIDKeyVaultName) -ForegroundColor White -NoNewline:$NoNewLine
            
            $null = Set-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault `
                                        -Name $WorkspaceIDKeyVaultName `
                                        -SecretValue $secretvalue `
                                        -ContentType 'workspaceid'
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }Catch{
            #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -BackgroundColor Red
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }
    }

    $WorkspaceKey1Name = (($ToolkitSettings.LogAnalytics.name -replace '\W+').ToLower() + 'Key1')
    If($ToolkitSettings.LogAnalytics.workspaceKey -eq '[KeyVault]' -and !($null = Get-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault -Name $WorkspaceKey1Name -ErrorAction SilentlyContinue)){
        $PrimaryKey = (Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $ToolkitSettings.LogAnalytics.resourceGroup -Name $ToolkitSettings.LogAnalytics.name).PrimarySharedKey
        $secretvalue = ConvertTo-SecureString $PrimaryKey -AsPlainText -Force
        Try{
            Write-Host ("    |---Storing to Keyvault workplace id secret [{0}]..." -f $WorkspaceKey1Name) -ForegroundColor White -NoNewline:$NoNewLine
            
            $null = Set-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault `
                                        -Name $WorkspaceKey1Name `
                                        -SecretValue $secretvalue `
                                        -ContentType 'workspaceprimarykey'
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }Catch{
            #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -BackgroundColor Red
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }
    }

    $WorkspaceKey2Name = (($ToolkitSettings.LogAnalytics.name -replace '\W+').ToLower() + 'Key2')
    If($ToolkitSettings.LogAnalytics.workspaceKey -eq '[KeyVault]' -and !($null = Get-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault -Name $WorkspaceKey2Name -ErrorAction SilentlyContinue)){
        $SecondaryKey = (Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $ToolkitSettings.LogAnalytics.resourceGroup -Name $ToolkitSettings.LogAnalytics.name).SecondarySharedKey
        $secretvalue = ConvertTo-SecureString $SecondaryKey -AsPlainText -Force
        Try{
            Write-Host ("    |---Storing to Keyvault workplace id secret [{0}]..." -f $WorkspaceKey2Name) -ForegroundColor White -NoNewline:$NoNewLine
            
            $null = Set-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault `
                                        -Name $WorkspaceKey2Name `
                                        -SecretValue $secretvalue `
                                        -ContentType 'workspacesecondarykey'
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }Catch{
            #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -BackgroundColor Red
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }
    }
}

#=========================================================
# CREATE MANAGED IDENTITY FOR AIB
#=========================================================
If($AibSupport){
    #REFERENCE: https://docs.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-permissions-powershell
    If(-Not($AssignedID = Get-AzUserAssignedIdentity -Name $ToolkitSettings.ManagedIdentity.identityName -ResourceGroupName $ToolkitSettings.AzureResources.imageResourceGroup -ErrorAction SilentlyContinue ))
    {
        Write-Host ("    |---Creating Azure Managed Identity for AIB [{0}]..." -f $ToolkitSettings.ManagedIdentity.identityName) -ForegroundColor White -NoNewline:$NoNewLine
        Try{
            $IdentityParams = @{
                Name = $ToolkitSettings.ManagedIdentity.identityName
                ResourceGroupName = $ToolkitSettings.AzureResources.imageResourceGroup
                Location = $ToolkitSettings.TenantEnvironment.location
            }
            $AssignedID = New-AzUserAssignedIdentity @IdentityParams -ErrorAction Stop
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }
        Catch{
            #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }
    }Else{
        Write-Host ("    |---Using Azure Managed identity [{0}] {1}" -f $AssignedID.Name,(Get-Symbol -Symbol GreenCheckmark))
    }


    #=========================================================
    # ASSIGN MANAGED IDENTITY PERMISSIONS TO IMAGE GALLERY
    #=========================================================
    #REFERENCE: https://docs.microsoft.com/en-us/powershell/module/az.AzureResources/New-azRoleDefinition?view=azps-8.0.0
    #get settings file (this can be retrieved from URL or file path)
    #grab resource Id and Principal ID
    #=======================================================
    $IdentityNameResourceId = $AssignedID.Id
    $identityNamePrincipalId = $AssignedID.PrincipalId
    $IdentityGuid = ($AssignedID.Name).replace(($identityPrefix + '-'),'')
    # Create a unique role name to avoid clashes in the same Azure Active Directory domain
    $imageRoleDefName="Azure Image Builder Image Def (" + $IdentityGuid + ")"
    $roleDefinitionPath = Join-Path $env:TEMP -ChildPath 'aibRoleImageCreation.json'
    
    If([uri]::IsWellFormedUriString($ToolkitSettings.ManagedIdentity.roleDefinitionTemplate, 'Absolute') -and ([uri]$ToolkitSettings.ManagedIdentity.roleDefinitionTemplate).Scheme -in 'http', 'https')
    {
        Invoke-WebRequest -Uri $roleDefinitionUri -Outfile $roleDefinitionPath -UseBasicParsing
    }
    ElseIf(Test-Path (Resolve-Path "$ResourcePath\$($ToolkitSettings.ManagedIdentity.roleDefinitionTemplate)") )
    {
        Copy-Item (Resolve-Path "$ResourcePath\$($ToolkitSettings.ManagedIdentity.roleDefinitionTemplate)") -Destination $roleDefinitionPath -Force
    }
    ElseIf(Test-Path $ToolkitSettings.ManagedIdentity.roleDefinitionTemplate)
    {
        Copy-Item $ToolkitSettings.ManagedIdentity.roleDefinitionTemplate -Destination $roleDefinitionPath -Force
    }
    Else{
        Write-Host ("{0}. Missing path from control settings" -f (Get-Symbol -Symbol RedX)) -ForegroundColor Red  
        Break
    }

    # Update the JSON definition placeholders with variable values
    ((Get-Content -path $roleDefinitionPath -Raw) -replace '<subscriptionID>',$subscriptionID) | Set-Content -Path $roleDefinitionPath
    ((Get-Content -path $roleDefinitionPath -Raw) -replace '<rgName>', $ToolkitSettings.AzureResources.imageResourceGroup) | Set-Content -Path $roleDefinitionPath
    ((Get-Content -path $roleDefinitionPath -Raw) -replace 'Azure Image Builder Service Image Creation Role', $imageRoleDefName) | Set-Content -Path $roleDefinitionPath

    #=========================================================
    # CREATE CUSTOM ROLE DEFINITION
    #=========================================================
    # Create a custom role from the aibRoleImageCreation.json description file.
    If(-Not($RoleDef = Get-AzRoleDefinition -Name $imageRoleDefName -ErrorAction SilentlyContinue))
    {
        Write-Host ("    |---Creating Azure role definition [{0}]..." -f $imageRoleDefName) -ForegroundColor White -NoNewline:$NoNewLine
        Try{
            # create role definition
            #$RoleDef = New-AzRoleDefinition -Role $role -ErrorAction Stop
            $RoleDef = New-AzRoleDefinition -InputFile $roleDefinitionPath
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }
        Catch{
            #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
            #Stop-Transcript;Break
        }
    }Else{
        Write-Host ("    |---Using Azure role definition [{0}] {1}" -f $imageRoleDefName,(Get-Symbol -Symbol GreenCheckmark))
    }

    # Get the user-identity properties
    #======================================================
    $identityNameResourceId = (Get-AzUserAssignedIdentity -Name $ToolkitSettings.ManagedIdentity.identityName -ResourceGroupName $ToolkitSettings.AzureResources.imageResourceGroup).id
    $identityNamePrincipalId= (Get-AzUserAssignedIdentity -Name $ToolkitSettings.ManagedIdentity.identityName -ResourceGroupName $ToolkitSettings.AzureResources.imageResourceGroup).PrincipalId

    #=========================================================
    # GRANT ROLE DEFINITION TO IMAGE BUILDER
    #=========================================================
    If(-Not($RoleAssignment = Get-AzRoleAssignment -ObjectId $IdentityNamePrincipalId -ErrorAction SilentlyContinue))
    {
        Write-Host ("    |---Creating Azure role assignment for definition [{0}]..." -f $imageRoleDefName) -ForegroundColor White -NoNewline:$NoNewLine
        Try{
            # Grant the custom role to the user-assigned managed identity for Azure Image Builder.
            $parameters = @{
                ObjectId = $identityNamePrincipalId
                RoleDefinitionName = $imageRoleDefName
                Scope = '/subscriptions/' + $subscriptionID + '/resourceGroups/' + $ToolkitSettings.AzureResources.imageResourceGroup
            }
            $RoleAssignment = New-AzRoleAssignment @parameters

            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }
        Catch{
            #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }
    }Else{
        Write-Host ("    |---Using Azure role assignment for AIB definition [{0}] {1}" -f $imageRoleDefName,(Get-Symbol -Symbol GreenCheckmark))
    }
}#end AIB support

#=========================================================
## CREATE STORAGE ACCOUNT
#=========================================================
#REFERNCE: hhttps://docs.microsoft.com/en-us/azure/storage/blobs/anonymous-read-access-configure?tabs=powershell
#REFERNCE: https://docs.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-permissions-powershell
If(-Not($StorageObject = Get-AzStorageAccount -Name $ToolkitSettings.AzureResources.storageAccount -ResourceGroupName $ToolkitSettings.AzureResources.storageResourceGroup -ErrorAction SilentlyContinue ))
{
    Write-Host ("    |---Creating Azure Storage Account [{0}]..." -f $ToolkitSettings.AzureResources.storageAccount) -ForegroundColor White -NoNewline:$NoNewLine
    Try{
        New-AzStorageAccount -ResourceGroupName $ToolkitSettings.AzureResources.storageResourceGroup `
            -Name $ToolkitSettings.AzureResources.storageAccount `
            -Location $ToolkitSettings.TenantEnvironment.location `
            -SkuName Standard_GRS #`
            -AllowBlobPublicAccess $false
        
        <#
        Set-AzStorageAccount -Name $ToolkitSettings.AzureResources.storageAccount `
            -ResourceGroupName $ToolkitSettings.AzureResources.storageResourceGroup `
            -AllowBlobPublicAccess $True

           #> 
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }
    Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Using Azure Storage Account [{0}] {1}" -f $StorageObject.StorageAccountName,(Get-Symbol -Symbol GreenCheckmark))
}


# Get context object as system
Write-Host ("    |---Retreiving Key from Storage Account [{0}]..." -f $ToolkitSettings.AzureResources.storageAccount) -ForegroundColor White -NoNewline:$NoNewLine
Try{
    #Get system key to use to create system sastoken
    $storageAccountKey = (Get-AzStorageAccountKey -Name $ToolkitSettings.AzureResources.storageAccount -ResourceGroupName $ToolkitSettings.AzureResources.storageResourceGroup).Value[0]
    $storageContext = New-AzStorageContext -StorageAccountName $ToolkitSettings.AzureResources.storageAccount -StorageAccountKey $storageAccountKey
    #User key: $StorageContext = New-AzStorageContext -StorageAccountName $ToolkitSettings.AzureResources.storageAccount
    Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
}
Catch{
    #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
    Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
}

#=========================================================
# GRANT ROLE DEFINITION TO STORAGE ACCOUNT
#=========================================================
# add managed identity for Azure blob Storage access
# NOTE: If you see this error: 'New-AzRoleDefinition: Role definition limit exceeded. No more role definitions can be created.' See this article to resolve:
#https://docs.microsoft.com/en-us/azure/role-based-access-control/troubleshooting
If($AibSupport){
    # Grant the storage reader to the user-assigned managed identity for the storage .
    If(-Not($StorageRoleAssignment = Get-AzRoleAssignment -ObjectId $IdentityNamePrincipalId -ErrorAction SilentlyContinue | Where RoleDefinitionName -eq 'Storage Blob Data Reader'))
    {
        Write-Host ("    |---Assigning [Storage Blob Data Reader] for Managed Identity [{0}] to storage account [{1}]..." -f $AssignedID.Name,$StorageContext.StorageAccountName) -ForegroundColor White -NoNewline:$NoNewLine
        Try{
            # Grant the custom role to the user-assigned managed identity for Azure Image Builder.
            $parameters = @{
                ObjectId = $identityNamePrincipalId
                RoleDefinitionName = "Storage Blob Data Reader"
                Scope = '/subscriptions/' + $subscriptionID + '/resourceGroups/' + $ToolkitSettings.AzureResources.storageResourceGroup + '/providers/Microsoft.Storage/storageAccounts/' + $StorageContext.StorageAccountName
                #Scope = '/subscriptions/' + $subscriptionID + '/resourceGroups/' + $ToolkitSettings.AzureResources.storageResourceGroup + '/providers/Microsoft.Storage/storageAccounts/' + $StorageContext.StorageAccountName + '/blobServices/default/containers/' + <Storage account container>
            }
            $StorageRoleAssignment = New-AzRoleAssignment @parameters

            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }
        Catch{
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }
    }Else{
        Write-Host ("    |---[Storage reader role] is already assigned to AIB Managed Identity [{0}] {1}" -f $AssignedID.Name,(Get-Symbol -Symbol GreenCheckmark))
    }


    # Grant the storage Contributor to the user running this module for upload to the storage .
    If(-Not($StorageUserRoleAssignment = Get-AzRoleAssignment -SignInName $currentAzContext.Account.Id -ErrorAction SilentlyContinue | Where RoleDefinitionName -eq 'Storage Blob Data Contributor'))
    {
        Write-Host ("    |---Assigning [Storage Blob Data Contributor] for current user [{0}] to storage account [{1}]..." -f $currentAzContext.Account.Id,$StorageContext.StorageAccountName) -ForegroundColor White -NoNewline:$NoNewLine
        Try{
            $parameters = @{
                SignInName = $currentAzContext.Account.Id
                RoleDefinitionName = "Storage Blob Data Contributor"
                Scope = '/subscriptions/' + $subscriptionID + '/resourceGroups/' + $ToolkitSettings.AzureResources.storageResourceGroup + '/providers/Microsoft.Storage/storageAccounts/' + $StorageContext.StorageAccountName
            }
            $StorageUserRoleAssignment = New-AzRoleAssignment @parameters
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }
        Catch{
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }
    }Else{
        Write-Host ("    |---[Storage reader Contributor] is already assigned to user [{0}] {1}" -f $currentAzContext.Account.Id,(Get-Symbol -Symbol GreenCheckmark))
    }

    #unkown permissiong should be removed from roles.
    If($UnknownRoles = Get-AzRoleAssignment | Where-Object {$_.ObjectType.Equals("Unknown")})
    {
        Write-Host ("    |---Removing [{0}] Unknown User Identities from role assignments..." -f $UnknownRoles.RoleDefinitionName.count) -ForegroundColor White -NoNewline:$NoNewLine
        Try{
            #Remove-AzRoleAssignment -ObjectId $UnknownRole.ObjectId -RoleDefinitionName $UnknownRole.RoleDefinitionName -Scope $UnknownRole.Scope | Out-Null
            $UnknownRole | Remove-AzRoleAssignment | Out-Null

            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }
        Catch{
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 2
        }
    }
}


#=========================================================
# SET PUBLIC ACCESS TO CONTAINER
#=========================================================
$Container = $ToolkitSettings.AzureResources.storageContainer.ToLower()
If(-Not($ContainerObject = Get-AzStorageContainer -Name $Container -Context $StorageContext -ErrorAction SilentlyContinue ))
{
    Write-Host ("    |---Creating Azure Storage Container [{0}]..." -f $Container) -ForegroundColor White -NoNewline:$NoNewLine
    Try{
        # Create a new container with public access setting set to Off.
        $ContainerObject = New-AzStorageContainer -Name $Container -Permission Off -Context $StorageContext

        # Read the container's public access setting.
        #Get-AzStorageContainerAcl -Container $Container -Context $StorageContext

        # Update the container's public access setting to Container.
        Set-AzStorageContainerAcl -Container $Container -Permission Container -Context $StorageContext

        # Read the container's public access setting.
        #Get-AzStorageContainerAcl -Container $Container -Context $StorageContext
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }
    Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Using Azure Storage Container [{0}] {1}" -f $ContainerObject.Name,(Get-Symbol -Symbol GreenCheckmark))
}

$storagePolicyName = "ReadPolicy01"
If(-Not($ReadPolicy = Get-AzStorageContainerStoredAccessPolicy -Container $Container -Policy $storagePolicyName -Context $storageContext -ErrorAction SilentlyContinue ))
{
    $NewExpiryTime = (Get-Date).AddMonths(1)
    Try{
        If($Null -eq $WritePolicy){
            Write-Host ("    |---Creating Azure Storage Container Access policy [{0}]..." -f $storagePolicyName) -ForegroundColor White -NoNewline:$NoNewLine
            $ReadPolicy = New-AzStorageContainerStoredAccessPolicy -Container $Container -Policy $storagePolicyName -Permission rl -ExpiryTime $NewExpiryTime -Context $storageContext
            Write-Host ("{0} " -f (Get-Symbol -Symbol GreenCheckmark)) -NoNewline
            Write-Host ("Expires on [") -NoNewline
            Write-Host ("{0}" -f $NewExpiryTime) -ForegroundColor Cyan -NoNewline
            Write-Host ("]") -NoNewline
        }ElseIf($ReadPolicy.expiryTime -gt $NewExpiryTime){
            Write-Host ("    |---Updating Azure Storage Container Access policy [{0}]..." -f $storagePolicyName) -ForegroundColor White -NoNewline:$NoNewLine
            $ReadPolicy = Set-AzStorageContainerStoredAccessPolicy -Container $Container -Policy $storagePolicyName -Permission rl -StartTime (Get-Date) -ExpiryTime $NewExpiryTime -Context $storageContext
            Write-Host ("{0} " -f (Get-Symbol -Symbol GreenCheckmark)) -NoNewline
            Write-Host ("Expires on [") -NoNewline
            Write-Host ("{0}" -f $NewExpiryTime) -ForegroundColor Cyan -NoNewline
            Write-Host ("]") -NoNewline
            $expiryTime = $NewExpiryTime
        }Else{
            #do nothing
            Write-Host ("    |---Azure Storage Container Access policy [{0}] expires on [{1}]" -f $storagePolicyName,$WritePolicy.expiryTime) -ForegroundColor Green
        }
    }
    Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Azure Storage Container Access policy already exists [{0}] {1}" -f $storagePolicyName,(Get-Symbol -Symbol GreenCheckmark))
}

$storagePolicyName = "ReadWritePolicy01"
If(-Not($WritePolicy = Get-AzStorageContainerStoredAccessPolicy -Container $Container -Policy $storagePolicyName -Context $storageContext -ErrorAction SilentlyContinue ))
{
    $NewExpiryTime = (Get-Date).AddDays(7)
    Try{
        If($Null -eq $WritePolicy){
            Write-Host ("    |---Creating Azure Storage Container Access policy [{0}]..." -f $storagePolicyName) -ForegroundColor White -NoNewline:$NoNewLine
            $WritePolicy = New-AzStorageContainerStoredAccessPolicy -Container $Container -Policy $storagePolicyName -Permission rwdl -ExpiryTime $NewExpiryTime -Context $storageContext
            Write-Host ("{0} " -f (Get-Symbol -Symbol GreenCheckmark)) -NoNewline
            Write-Host ("Expires on [") -NoNewline
            Write-Host ("{0}" -f $NewExpiryTime) -ForegroundColor Cyan -NoNewline
            Write-Host ("]") -NoNewline
        }ElseIf($WritePolicy.expiryTime -gt $NewExpiryTime){
            Write-Host ("    |---Updating Azure Storage Container Access policy [{0}]..." -f "ReadWritePolicy01") -ForegroundColor White -NoNewline:$NoNewLine
            $WritePolicy = Set-AzStorageContainerStoredAccessPolicy -Container $Container -Policy $storagePolicyName -Permission rwdl -StartTime (Get-Date) -ExpiryTime $NewExpiryTime -Context $storageContext 
            Write-Host ("{0} " -f (Get-Symbol -Symbol GreenCheckmark)) -NoNewline
            Write-Host ("Expires on [") -NoNewline
            Write-Host ("{0}" -f $NewExpiryTime) -ForegroundColor Cyan -NoNewline
            Write-Host ("]") -NoNewline
        }Else{
            #do nothing
            Write-Host ("    |---Azure Storage Container Access policy [{0}] expires on [{1}]" -f $storagePolicyName,$WritePolicy.expiryTime) -ForegroundColor Green
        }
    }
    Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---Azure Storage Container Access policy already exists [{0}] {1}" -f $storagePolicyName,(Get-Symbol -Symbol GreenCheckmark))
}
#=========================================================
# GENERATE SAS TOKEN
#=========================================================
#REFERENCE https://learn.microsoft.com/en-us/powershell/module/az.storage/new-azstorageaccountsastoken?view=azps-10.0.0
#REFERENCE https://learn.microsoft.com/en-us/rest/api/storageservices/create-user-delegation-sas
#REFERENCE https://learn.microsoft.com/en-us/azure/storage/blobs/storage-blob-user-delegation-sas-create-powershell
$GenerateNewSasToken = $True
$midnight = Get-Date -Hour 0 -Minute 00 -Second 00
Write-Host ("    |---Checking SaSToken for [{0}]..." -f $ContainerObject.Name) -NoNewline:$NoNewLine
If( ($ToolkitSettings.AzureResources.containerSasToken.Length -gt 0) -and !$ForceNewSasToken){
    If($ToolkitSettings.AzureResources.containerSasToken -eq '[KeyVault]' -and ($KeyvaultSecret = Get-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault -Name $ToolkitSettings.AzureResources.storageContainer -ErrorAction SilentlyContinue)){
        $ExpiryDate = $KeyvaultSecret.Expires
        $sasTokenValue = $KeyvaultSecret.SecretValue | ConvertFrom-SecureString -AsPlainText
    }Else{
        #$ExpiryDate = [System.Text.RegularExpressions.Regex]::Match($ToolkitSettings.AzureResources.containerSasToken, 'sv=(?<Created>.*)&st=(?<Start>.*)&se=(?<Expiry>.*)&sr=(?<token>.*)').Groups['Expiry'].value
        $ExpiryDate = [System.Text.RegularExpressions.Regex]::Match($ToolkitSettings.AzureResources.containerSasToken, 'sv=(?<Created>.*)&se=(?<Expiry>.*)&sr=(?<token>.*)').Groups['Expiry'].value.replace('%3A',':')
        $sasTokenValue = $ToolkitSettings.AzureResources.containerSasToken
    }
    
    If($ExpiryDate.Length -gt 0){
        
        If((Get-Date) -gt $ExpiryDate){
            Write-Host ("expired on [") -NoNewline
            Write-Host ("{0}" -f $ExpiryDate.ToString()) -ForegroundColor Yellow -NoNewline
            Write-Host ("]") -NoNewline
            Write-Host ("{0}" -f (Get-Symbol -Symbol WarningSign))
        }Else{
            Write-Host ("still valid until [") -NoNewline -ForegroundColor Green
            Write-Host ("{0}" -f $ExpiryDate.ToString()) -ForegroundColor Cyan -NoNewline
            Write-Host ("]") -NoNewline
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
            $GenerateNewSasToken =  $False
            $sasToken = $sasTokenValue
        }
    }Else{
        Write-Host ("{0} Invalid. generating new SASToken..." -f (Get-Symbol -Symbol WarningSign)) -ForegroundColor Yellow
    }
    
}Else{
    Write-Host ("{0} skipped check" -f (Get-Symbol -Symbol Information)) -ForegroundColor Yellow
}


If($GenerateNewSasToken -or $ForceNewSasToken){
    #$UserStorageContext = New-AzStorageContext -StorageAccountName $ToolkitSettings.AzureResources.storageAccount -UseConnectedAccount    
    Write-Host ("    |---Generating new SasToken for [{0}]..." -f $ContainerObject.Name) -ForegroundColor White -NoNewline:$NoNewLine
    Try{
        #remove any keys associated with storarge account
        Revoke-AzStorageAccountUserDelegationKeys -ResourceGroupName $ToolkitSettings.AzureResources.storageResourceGroup -StorageAccountName $ToolkitSettings.AzureResources.storageAccount
        #create new key
        $sasToken = (New-AzStorageContainerSASToken -Name $ContainerObject.Name -Permission "racwdl" -ExpiryTime $midnight.AddDays($SasTokenExpireDays) -Context $storageContext) -replace '^\?','' 
        #$sasToken = (New-AzStorageContainerSASToken -Name $ContainerObject.Name -Policy $storagePolicyName -Context $storageContext).substring(1)
        #$ToolkitSettings.AzureResources.containerSasToken = $sasToken -replace '^\?',''       
        Write-Host ("Done. SasToken expires [") -ForegroundColor Green -NoNewline
        Write-Host ("{0}" -f $midnight.AddDays($SasTokenExpireDays)) -ForegroundColor Cyan -NoNewline
        Write-Host ("]") -ForegroundColor Green
    }
    Catch{
        #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        Write-Host ("Failed! A new one needs to be generated from Azure Portal...") -ForegroundColor Red
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }

    #store sastoken either in config or keyvault
    If($ToolkitSettings.AzureResources.containerSasToken -eq '[KeyVault]'){
        Try{
            Write-Host ("    |---Storing SASToken to Keyvault secret [{0}]..." -f $ToolkitSettings.AzureResources.storageContainer) -ForegroundColor White -NoNewline:$NoNewLine
            $tokensecretvalue = ConvertTo-SecureString $sasToken -AsPlainText -Force
            $null = Set-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault`
                                        -Name $ToolkitSettings.AzureResources.storageContainer `
                                        -SecretValue $tokensecretvalue `
                                        -Expires $midnight.AddDays($SasTokenExpireDays) `
                                        -ContentType 'sastoken'
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }Catch{
            #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -BackgroundColor Red
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }   
    }Else{
        Try{
            Write-Host ("    |---Storing SASToken in config [{0}]..." -f ("$ResourcePath\Control\$ControlSettings")) -ForegroundColor White -NoNewline:$NoNewLine
            $ToolkitSettings | ConvertTo-Json | Out-File "$ResourcePath\Control\$ControlSettings" -Force
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }Catch{
            #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -BackgroundColor Red
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }    
    }
}

If($ToolkitSettings.AzureResources.containerSasToken -eq '[KeyVault]'){
    Write-Host ("    |---SASToken stored in Keyvault secret [{0}]..." -f $ToolkitSettings.AzureResources.storageContainer) -ForegroundColor White
}Else{
    Write-Host ("    |---SASToken stored in config [{0}]..." -f $ControlSettings) -ForegroundColor White
}


If($ReturnSasToken){
    Write-Host ("    |---SasToken is [") -ForegroundColor White -NoNewline
    Write-Host "$sasToken" -ForegroundColor Cyan -NoNewline
    Write-Host "]" -ForegroundColor White
    $Global:sasToken = $sasToken
}

<#
#contstruct User SAS token
$SasBreakdown = [System.Text.RegularExpressions.Regex]::Match($sasToken,'skoid=(?<oid>.*)&sktid=(?<tenantId>.*)&skt=(?<startKeyTime>.*)&ske=(?<signedKeyExpiry>.*)&sks=(?<signedKeyService>.*)&skv=(?<signedKeyVersion>.*)&sv=(?<signedVersion>.*)&se=(?<signedExpiry>.*)&sr=(?<signedResource>.*)&sp=(?<signedPermissions>.*)&sig=(?<signature>.*)').Groups
$UserSasToken = "sp=$($SasBreakdown['signedPermissions'].value)&st=$($SasBreakdown['startKeyTime'].value)&se=$($SasBreakdown['signedKeyExpiry'].value)&spr=https&sv=$($SasBreakdown['signedVersion'].value)&sr=$($SasBreakdown['signedResource'].value)&sig=$($SasBreakdown['signature'].value)"
$ToolkitSettings.AzureResources.containerSasToken = $UserSasToken -replace '^\?','' -replace '%3A',':'
#>

$global:ProgressPreference = $prevProgressPreference
Stop-Transcript -ErrorAction SilentlyContinue

Write-Host ("`nCOMPLETED AZURE PREP PROCESS") -ForegroundColor Cya