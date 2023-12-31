<#
    .SYNOPSIS
    Creates Azure VM

    .DESCRIPTION
    Create Azure VM and runs prep script to install applications

    .NOTES
    AUTHOR: Dick Tracy II (@powershellcrack)
    PROCESS: What this script will do (in order)
    1. Install required Az modules
    2. Connect to Azure
    3. Check if VNET and subnet are valid
    4. Check if tempalte has valid azure image publisher, offer and sku
    5. Create VM
    6. Run prep script and app install script

    TODO:
        - Monitor script progess; output results to log
        - retrieve local admin password from keyvault -DONE 6/9/2023
        - retrieve sastoken from keyvault -DONE 6/9/2023
        - store sastoken in credential manager within VM during app install
        - Force deletion of vm and its disk and nic if same reference vm exists

    .PARAMETER ResourcePath
    Specify a path other than the relative path this script is running in

    .PARAMETER ControlSettings
    Specify a setting configuration file. Defaults to settings.json

    .PARAMETER Sequence
    Specify a image configuration file (sequence.json). Defaults to Win11AvdGFEImage

    .PARAMETER RunScriptOnVM
    Array. List of script to run on vm options are:
        vm_run_sequence.ps1
        vm_prep_toolkit.ps1
        vm_install_applications.ps1
        vm_install_m365apps.ps1
        vm_update_windows.ps1
        vm_cleanup_toolkit.ps1
        vm_prep_capture.ps1

    NOTE: scripts are a the same a vm_run_sequence.ps1 but are filtered to do certain tasks. Doing all in on command  may cause the the extension commandto time out
    
    .PARAMETER ToolkitBuildPath
    Specify the location wher ethe script will be ran on VM. Defaults to "$Env:windir\temp\AVDToolkit"

    .PARAMETER VMName
    Required if using RunScriptOnVM switch. Specify the name of VM to look for

    .EXAMPLE
    PS .\A4_create_avd_ref_vm.ps1

    RESULT: Run default setting and creates VM and runs prep script

   .EXAMPLE
    PS .\A4_create_avd_ref_vm.ps1 -ControlSettings setting.gov.json -Sequence Win11AvdGFEImage

    RESULT: Run script using configuration for a gov tenant and creates VM and runs prep script

    .EXAMPLE
    PS .\A4_create_avd_ref_vm.ps1 -ResourcePath C:\Temp -ControlSettings setting.test.json

    RESULT: Run script using configuration from a another file, and creates VM and runs prep script from C:\Temp\Templates

    .EXAMPLE
    PS .\A4_create_avd_ref_vm.ps1 -ControlSettings setting.gov.json -RunScriptOnVM -VMName TESTVM01

    RESULT: Run script using configuration from a another file and wil attempt to run script on an existing VM named TESTVM01

    .EXAMPLE
    $ControlSettings='settings-ritracyi-gov.json'
    $Sequence='Win11AvdM365Image'


    .LINK
    https://learn.microsoft.com/en-us/azure/virtual-machines/windows/run-command
    https://learn.microsoft.com/en-us/azure/virtual-machines/extensions/custom-script-windows

#>
[CmdletBinding(DefaultParameterSetName='new')]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourcePath,

    [Parameter(Mandatory = $false)]
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )


        $ToolkitSettings = Get-Childitem "$PSScriptRoot\Control" -Filter Settings* | Where-Object Extension -eq '.json' | Select-Object -ExpandProperty Name

        $ToolkitSettings | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("Config","Setting")]
    [string]$ControlSettings = "settings.json",

    [Parameter(Mandatory = $false)]
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )


        $Sequence = Get-Childitem "$PSScriptRoot\Control" -Directory | Select-Object -ExpandProperty Name

        $Sequence | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("ImageBuild","Template")]
    [string]$Sequence="Win11AvdGFEImage",

    [Parameter(Mandatory = $false)]
    [string]$ToolkitBuildPath = "$Env:windir\temp\AVDToolkit",

    [Parameter(Mandatory = $false)]
    [ValidateSet('vm_run_sequence.ps1','vm_prep_toolkit.ps1','vm_install_applications.ps1','vm_install_m365apps.ps1',
                'vm_update_windows.ps1','vm_cleanup_toolkit.ps1','vm_prep_capture.ps1')]
    [string[]]$RunScriptsOnVM = @(
        'vm_prep_toolkit.ps1'
        'vm_install_applications.ps1'
        'vm_install_m365apps.ps1'
        'vm_update_windows.ps1'
        'vm_cleanup_toolkit.ps1'
        'vm_prep_capture.ps1'
    ),

    [Parameter(Mandatory = $true,ParameterSetName='existing')]
    [string]$VMName,

    [switch]$PromptAdminPassword,

    [switch]$Force
)


#=======================================================
# VARIABLES
#=======================================================
$ScriptInvocation = (Get-Variable MyInvocation -Scope Script).Value

$ErrorActionPreference = "Stop"

# Save current progress preference and hide the progress
$prevProgressPreference = $global:ProgressPreference
$global:ProgressPreference = 'SilentlyContinue'
#Check if verbose is used; if it is don't use the nonewline in output
If($VerbosePreference){$NoNewLine=$False}Else{$NoNewLine=$True}

If(!$ResourcePath){
    #resolve path locally
    [string]$ResourcePath = ($PWD.ProviderPath, $PSScriptRoot)[[bool]$PSScriptRoot]
}

#Build paths
$ControlPath = Join-Path $ResourcePath -ChildPath 'Control'
$LogsPath = Join-Path $ResourcePath -ChildPath 'Logs'
$ScriptsPath = Join-Path $ResourcePath -ChildPath 'Scripts'
#$TemplatesPath = Join-Path $ResourcePath -ChildPath 'Templates'


#build log directory and File
New-Item $LogsPath -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
$DateLogFormat = (Get-Date).ToString('yyyy-MM-dd_Thh-mm-ss-tt')
$LogfileName = ($ScriptInvocation.MyCommand.Name.replace('.ps1','_').ToLower() + $DateLogFormat + '.log')
Start-transcript "$LogsPath\$LogfileName" -ErrorAction Stop

## ================================
## GET SETTINGS
## ================================
$ToolkitSettings = Get-Content "$ControlPath\$ControlSettings" -Raw | ConvertFrom-Json
$ControlCustomizationData = Get-Content "$ControlPath\$Sequence\sequence.json" | ConvertFrom-Json
##======================
## FUNCTIONS
##======================
#region Sequencer custom functions
. "$ScriptsPath\Symbols.ps1"
. "$ScriptsPath\Environment.ps1"
. "$ScriptsPath\LogAnalytics.ps1"
. "$ScriptsPath\BlobControl.ps1"
#=======================================================
# CONNECT TO AZURE
#=======================================================
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
## ================================
## MAIN
## ================================
Write-Host ("`nStarting precheck process...") -ForegroundColor Cyan

If(($AzureVM = Get-AzVM -Name $VMName -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup -Status -ErrorAction SilentlyContinue)){
    Write-Host ("    |---Using Azure Virtual Machine [{0}]" -f $VMName) -ForegroundColor White
    If($AzureVM.PowerState -ne 'Running'){
        Start-AzVM -Name $VMName -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup
        Write-Host ("{0} started" -f (Get-Symbol -Symbol GreenCheckmark)) -ForegroundColor Green
    }

}Else{
    $VMName = $ToolkitSettings.AzureResources.refVmPrefix + '-' + $(Get-Date).ToString('yyMM') + '-REF'
    $VMDiskName = $ToolkitSettings.AzureResources.refVmPrefix + '-' + $(Get-Date).ToString('yyMM') + '-REF_OSDISK'
    $VMNic = $ToolkitSettings.AzureResources.refVmPrefix + '-' + $(Get-Date).ToString('yyMM') + '-REF_NIC'

    #=========================================================
    # CHECK RESOURCE GROUP
    #=========================================================
    Write-Host ("    |---Validating Resource Group [{0}] for compute..." -f $ToolkitSettings.AzureResources.computeResourceGroup) -ForegroundColor White -NoNewline
    If(Get-AzResourceGroup -Name $ToolkitSettings.AzureResources.computeResourceGroup -ErrorAction SilentlyContinue)
    {
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }Else{
        Write-Host ("{0}. Not found" -f (Get-Symbol -Symbol RedX))
        break
    }

    Write-Host ("    |---Validating Resource Group [{0}] for network..." -f $ToolkitSettings.AzureResources.networkResourceGroup) -ForegroundColor White -NoNewline
    If(Get-AzResourceGroup -Name $ToolkitSettings.AzureResources.networkResourceGroup -ErrorAction SilentlyContinue)
    {
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }Else{
        Write-Host ("{0}. Not found" -f (Get-Symbol -Symbol RedX))
        break
    }

    #=========================================================
    # CHECK NETWORK RESOURCES
    #=========================================================
    Write-Host ("    |---Validating virtual network [{0}]..." -f $ToolkitSettings.AzureResources.refVmVNetName) -ForegroundColor White -NoNewline
    $VNet = Get-AzVirtualNetwork -Name $ToolkitSettings.AzureResources.refVmVNetName -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup
    if($VNet)
    {
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }Else{
        Write-Host ("{0}. Not found" -f (Get-Symbol -Symbol RedX))
        break
    }

    Write-Host ("    |---Validating subnet [{0}]..." -f $ToolkitSettings.AzureResources.refVmSubnet) -ForegroundColor White -NoNewline
    $subnetID = $VNet.Subnets | Where-Object {$_.Name -eq $ToolkitSettings.AzureResources.refVmSubnet} | Select-Object -ExpandProperty Id
    if($subnetID)
    {
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }Else{
        Write-Host ("{0}. Not found" -f (Get-Symbol -Symbol RedX))
        break
    }
    #=========================================================
    # CREATE VIRTUAL MACHINE
    #=========================================================
    Write-Host ("    |---Validating host definition...") -ForegroundColor White -NoNewline
    Try{
        $Images = Get-AzVMImage -Location $ToolkitSettings.TenantEnvironment.location -PublisherName $ControlCustomizationData.imageDefinition.publisher -Offer $ControlCustomizationData.imageDefinition.offer -Skus $ControlCustomizationData.imageDefinition.osSku
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }Catch{
        #Source Image not found
        Write-Host ("{0}. Markeplace definition not valid (ImagePublisher:'{1}',Offer:'{2}',Skus:'{3}'. {4})" -f (Get-Symbol -Symbol RedX),$ControlCustomizationData.imageDefinition.publisher,$ControlCustomizationData.imageDefinition.offer,$ControlCustomizationData.imageDefinition.osSku, $_.Exception.Message) -ForegroundColor Red
        break
    }

    Write-Host ("Creating Azure Virtual Machine [{0}]..." -f $VMName) -ForegroundColor Cyan

    If($ToolkitSettings.AzureResources.refVmAdminPassword -eq '[KeyVault]'){
        If($ToolkitSettings.AzureResources.refVmAdminPassword -eq '[KeyVault]' -and !($null = Get-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault -Name $VMName -ErrorAction SilentlyContinue) -or $ForceKeyVaultAdminSecret){
            # Credentials for Local Admin account
            If($PromptAdminPassword){
                $LocalAdminSecurePassword = Read-Host -AsSecureString -Prompt '    |---Specify admin secret'
            }Else{
                $LocalAdminSecurePassword = New-Password
            }
            $secretvalue = ConvertTo-SecureString $LocalAdminSecurePassword -AsPlainText -Force
            Try{
                Write-Host ("    |---Generating Keyvault local admin secret [{0}]..." -f $VMName) -ForegroundColor White -NoNewline:$NoNewLine

                $null = Set-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault `
                                            -Name $VMName `
                                            -SecretValue $secretvalue `
                                            -ContentType $ToolkitSettings.AzureResources.refVmAdmin
                Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
            }Catch{
                #Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -BackgroundColor Red
                #Stop-Transcript;Break
                Send-AIBMessage -Message ("{0} {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
            }
        }

        Write-Host ("    |---Retrieving password from keyvault...") -ForegroundColor White -NoNewline
        Try{
            $KeyvaultSecret = Get-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault -Name $VMName -AsPlainText
            $LocalAdminSecurePassword = ConvertTo-SecureString $KeyvaultSecret -AsPlainText -Force
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }Catch{
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0} {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3
            # Credentials for Local Admin account
            $LocalAdminSecurePassword = Read-Host -AsSecureString -Prompt '    |---Specify admin password'
            #Save the key in keyvault
            $secretvalue = ConvertTo-SecureString $LocalAdminSecurePassword -AsPlainText -Force
            $null = Set-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault `
                                            -Name $VMName `
                                            -SecretValue $secretvalue `
                                            -ContentType $ToolkitSettings.AzureResources.refVmAdmin
        }
    }Else{
        # Credentials for Local Admin account
        $LocalAdminSecurePassword = Read-Host -AsSecureString -Prompt '    |---Specify admin password'
    }

    Write-Host ("    |---Deploying virtual machine configurations...") -ForegroundColor White -NoNewline
    try{
        $NIC = New-AzNetworkInterface -Name $VMNic.ToLower() -ResourceGroupName $ToolkitSettings.AzureResources.networkResourceGroup -Location $ToolkitSettings.TenantEnvironment.location -SubnetId $subnetID -Force

        $Credential = New-Object System.Management.Automation.PSCredential ($ToolkitSettings.AzureResources.refVmAdmin, $LocalAdminSecurePassword)

        $VirtualMachine = New-AzVMConfig -VMName $VMName -VMSize $ControlCustomizationData.imageDefinition.vmSize
        $VirtualMachine = Set-AzVMBootDiagnostic -VM $VirtualMachine -Disable
        $VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $VMName -Credential $Credential -ProvisionVMAgent
        $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id
        $VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine `
                                            -PublisherName $ControlCustomizationData.imageDefinition.publisher `
                                            -Offer $ControlCustomizationData.imageDefinition.offer `
                                            -Skus $ControlCustomizationData.imageDefinition.osSku `
                                            -Version "latest"
        $VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -Name $VMDiskName -Caching $OSDiskCaching -CreateOption FromImage -Windows

        $Result = New-AzVM -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup -Location $ToolkitSettings.TenantEnvironment.location -VM $VirtualMachine -DisableBginfoExtension
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }
    Catch{
        #Write-Host ("{0} {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0} {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}

#=========================================================
# RUN CUSTOMIZATION SCRIPT
#=========================================================


If($RunScriptsOnVM.Count -gt 0){
    Write-Host ("`nInvoking post process for Azure VM: {0}..." -f $VMName) -ForegroundColor Cyan

    $BlobUrl = [System.String]::Concat('https://',$ToolkitSettings.AzureResources.storageAccount,'.',$blobUriAppendix,'/',$ToolkitSettings.AzureResources.storageContainer.ToLower())
    #build copy params

    #determine where to get sastoken
    If($ToolkitSettings.AzureResources.containerSasToken -eq '[KeyVault]'){
        Write-Host ("    |---Retrieving SASToken [{0}] from keyvault [{1}]..." -f $ToolkitSettings.AzureResources.storageContainer,$ToolkitSettings.AzureResources.keyVault) -ForegroundColor White -NoNewline
        # use sastoken stored in keyvault
        Try{
            $SasToken = Get-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault -Name $ToolkitSettings.AzureResources.storageContainer -AsPlainText
            #$SasToken = ConvertTo-SecureString $KeyvaultSecret -AsPlainText -Force
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }Catch{
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }
    }Else{
        # use sastoken stored in config
        $SasToken = $ToolkitSettings.AzureResources.containerSasToken
    }

    $i=0
    #TEST $Script = $RunScriptsOnVM[0]
    #TEST $Script = $RunScriptsOnVM[1]
    #TEST $Script = $RunScriptsOnVM[2]
    #TEST $Script = $RunScriptsOnVM[3]
    #TEST $Script = $RunScriptsOnVM[4]
    #TEST $Script = $RunScriptsOnVM[5]
    Foreach($Script in $RunScriptsOnVM){
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $i++
        Write-Host ("    |---[{0}/{1}] Running script [{2}]..." -f $i,$RunScriptsOnVM.count,$Script) -ForegroundColor White -NoNewline

        # Save the command to a local file
        $ScriptDestinationPath = "$env:Temp\temp.ps1"
        Copy-Item "$ScriptsPath\VM_Scripts\$Script" -Destination "$env:Temp\temp.ps1" -Force | Out-Null
        ((Get-Content -Path $ScriptDestinationPath -Raw) -replace "<resourcePath>",$ToolkitBuildPath) | Set-Content -Path $ScriptDestinationPath
        ((Get-Content -Path $ScriptDestinationPath -Raw) -replace "<sequence>",$Sequence) | Set-Content -Path $ScriptDestinationPath
        ((Get-Content -Path $ScriptDestinationPath -Raw) -replace "<settings>",$ControlSettings) | Set-Content -Path $ScriptDestinationPath
        ((Get-Content -Path $ScriptDestinationPath -Raw) -replace "<bloburl>",$BlobUrl) | Set-Content -Path $ScriptDestinationPath
        ((Get-Content -Path $ScriptDestinationPath -Raw) -replace "<sastoken>",$SasToken) | Set-Content -Path $ScriptDestinationPath
        #((Get-Content -Path $ScriptDestinationPath -Raw) -replace "<appscriptpath>",(Join-Path $ToolkitBuildPath -ChildPath $ToolkitSettings.Settings.sequenceRunnerScriptFile)) | Set-Content -Path $ScriptDestinationPath
        ((Get-Content -Path $ScriptDestinationPath -Raw) -replace "#<verbosePreference>",("`$VerbosePreference = `"$VerbosePreference`"")) | Set-Content -Path $ScriptDestinationPath

        <#
        #View the ouput:
        notepad $ScriptDestinationPath
        #>

        try{
            #run script within the Azure VM
            $Result = Invoke-AzVMRunCommand -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup -VMName $VMName -CommandId 'RunPowerShellScript' -ScriptPath $ScriptDestinationPath

            #collect output msg and display appropiately
            $StdOut = $Result.Value.Message[0]
            $StdErr = $Result.Value.Message[1]
            $RegexExport = [System.Text.RegularExpressions.Regex]::Match(($StdOut -split "`n"), '^(?<status>.*):\s+(?<reboot>.*)$').Groups
            #determine if the stdout eport found reboot and status
            If($RegexExport.Success -ne $false){
                $CompleteStatus = ($RegexExport | Where-Object Name -eq 'status' | Select-Object -Last 1).Value.Trim()
                $RebootStatus = ($RegexExport | Where-Object Name -eq 'reboot' | Select-Object -Last 1).Value.Trim()
            }

            if ([bool]$StdErr) {
                Write-Host ("{0} {1}" -f (Get-Symbol -Symbol RedX),$StdErr) -ForegroundColor Red
                Continue
            }Else{
                Write-Host ("{0}. Output:" -f (Get-Symbol -Symbol GreenCheckmark)) -ForegroundColor Green -NoNewline
                $CompleteStatus.split('|---') | Write-Host -ForegroundColor Gray
                Write-Host ("Runtime: [") -ForegroundColor Green -NoNewline
                Write-Host ("{0} seconds" -f [math]::Round($stopwatch.Elapsed.TotalSeconds,0)) -ForegroundColor Cyan -NoNewline
                Write-Host ("]") -ForegroundColor Green
            }

            #parse output file for last job status

            <#
            #send out proper output
            switch ($Status){
                'Completed' {Write-Output $Status}
                default {Write-Error $Status}
            }
            #>
        }
        Catch{
            Write-Host ("{0} {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
        }
        finally {
            Remove-Item $ScriptDestinationPath -Force | Out-Null

            $stopwatch.Stop()
            $stopwatch.Reset()
            $stopwatch.Restart()

            #determine if reboot is needed
            #last output will be true or false
            If($RebootStatus){
                If([Boolean]::Parse($RebootStatus)){
                    Try{
                        Write-Host ("    |---Detected restart is needed, rebooting VM [{0}]..." -f $VMName) -ForegroundColor White -NoNewline
                        $Null = Restart-AzVM -Name $VMName -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup
                        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
                    }Catch{
                        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3
                    }
                }
            }


        }
    }#end script loop

    #Complete final action
    Try{
        Switch($ControlCustomizationData.customSettings.finalAction){
            'Shutdown' {
                Write-Host ("    |---Running Final Action: Shutting down VM [{0}]..." -f $VMName) -ForegroundColor White -NoNewline
                $Null = Stop-AzVM -Name $VMName -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup -Force
            }

            'Reboot' {
                Write-Host ("    |---Running Final Action: Rebooting VM [{0}]..." -f $VMName) -ForegroundColor White -NoNewline
                $Null = Restart-AzVM -Name $VMName -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup
            }
            default {#Do nothing
            }
        }
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }Catch{
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3
    }
}



$global:ProgressPreference = $prevProgressPreference
Stop-Transcript -ErrorAction SilentlyContinue

Write-Host ("`nCOMPLETED VM PROCESS") -ForegroundColor Cyan
