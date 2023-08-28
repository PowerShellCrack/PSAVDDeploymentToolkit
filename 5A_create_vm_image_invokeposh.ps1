<#
    .SYNOPSIS
    Creates image from VM

    .DESCRIPTION
    Creates image from VM and uploads to shared image gallery

    .NOTES
    AUTHOR: Dick Tracy II (@powershellcrack)
    PROCESS: What this script will do (in order)
    1.  Login to Azure
    2.  Check resources
    3.  Build sysprep script and invoke it on VM
    4.  Deallocated and generalize the VM
    5.  Generate definition version
    6.  Capture Image from VM disk
    7.  Cleanup VM resources (if used -CleanUpVMOnCaptureSuccess)

    TODO:
        - Cleanup VM and its resources - DONE 6/13/2023

    .PARAMETER ControlSettings
    Specify a setting configuration file. Defaults to settings.json

    .PARAMETER Sequence
    Specify a image configuration file (sequence.json). Defaults to Win11AvdGFEImage

    .PARAMETER VMName
    Specify the VM name to capture

    .PARAMETER CleanUpVMOnCaptureSuccess
    Removed the VM it just captured to includ Disk and NIC

    .EXAMPLE
    PS .\A5_create_vm_image.ps1

    RESULT: Run default setting

   .EXAMPLE
    PS .\A5_create_vm_image.ps1 -ControlSettings setting.gov.json

    RESULT: Run script using configuration for a gov tenant

    .EXAMPLE
    PS .\A5_create_vm_image.ps1 -ResourcePath C:\Temp -ControlSettings setting.test.json

    RESULT: Run script using configuration from a another file, apps will be uploaded from C:\Temp\Applications

    .EXAMPLE
    PS .A5_create_vm_image.ps1 -ControlSettings setting.gov.json -SkipAppUploads

    RESULT: Run script using configuration from a another file and will NOT upload applications
#>
[CmdletBinding()]
param(
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

    [Parameter(Mandatory = $false)]
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )


        $Sequence = Get-Childitem "$PSScriptRoot\Control" -Directory | Select -ExpandProperty Name

        $Sequence | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("ImageBuild","Template")]
    [string]$Sequence="Win11AvdGFEImage",

    [parameter(Mandatory = $true)]
    $targetVMName,

    [switch]$CleanUpVMOnCaptureSuccess
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
$TemplatesPath = Join-Path $ResourcePath -ChildPath 'Templates'

#build log directory and File
New-Item "$ResourcePath\Logs" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
$DateLogFormat = (Get-Date).ToString('yyyy-MM-dd_Thh-mm-ss-tt')
$LogfileName = ($ScriptInvocation.MyCommand.Name.replace('.ps1','_').ToLower() + $DateLogFormat + '.log')
Start-transcript "$ResourcePath\Logs\$LogfileName" -ErrorAction Stop

## ================================
## GET SETTINGS
## ================================
$ToolkitSettings = Get-Content "$ResourcePath\Control\$ControlSettings" -Raw | ConvertFrom-Json
$ControlCustomizationData = Get-Content "$ControlPath\$Sequence\sequence.json" | ConvertFrom-Json


##======================
## FUNCTIONS
##======================
#region Sequencer custom functions
. "$ScriptsPath\Symbols.ps1"
. "$ResourcePath\Scripts\LogAnalytics.ps1"
. "$ResourcePath\Scripts\BlobControl.ps1"

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
$subscriptionID = $currentAzContext.Subscription.Id

Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null
## ================================
## MAIN
## ================================

Write-Host ("`nStarting precheck process...") -ForegroundColor Cyan



If($targetVM = Get-AzVM -Name $targetVMName -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup -Status -ErrorAction SilentlyContinue)
{
    Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
}Else{
    Write-Host ("{0}. Not found" -f (Get-Symbol -Symbol RedX))
    break
}

#Verify Image Gallery Exists

if($null = Get-AzGallery -ResourceGroupName $ToolkitSettings.AzureResources.imageResourceGroup -Name $ToolkitSettings.AzureResources.imageComputeGallery -ErrorAction SilentlyContinue)
{
    Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
}Else{
    Write-Host ("{0}. Image Gallery [{1}] in Resource Group [{2}] not found" -f (Get-Symbol -Symbol RedX), $ToolkitSettings.AzureResources.imageComputeGallery, $ToolkitSettings.AzureResources.imageResourceGroup) -ForegroundColor Red
    break
}

Write-Host ("Caturing Azure Virtual Machine [{0}]..." -f $targetVMName) -ForegroundColor Cyan

$remoteCommand =
@"
#Remove C:\temp
Remove-Item -Path C:\temp -Recurse -Force
'Removed C:\temp' | Out-File C:\Windows\Temp\sysprep_capture.log -Append

#Remove all the files in user profile downloads
foreach(`$usrFolder in ls C:\users)
{
    `$dlPath = Join-Path -Path `$usrFolder.FullName -ChildPath 'downloads'
    Remove-Item -Path "`$dlPath\*" -Recurse -Force -ErrorAction SilentlyContinue
    "Removing `$dlPath" | Out-File C:\Windows\Temp\sysprep_capture.log -Append
}

#Remove C:\Windows\Panther
Remove-Item -Path C:\Windows\Panther -Recurse -Force
'Removed C:\Windows\Panther' | Out-File C:\Windows\Temp\sysprep_capture.log -Append

#Sysprep
`$result = Start-Process C:\Windows\System32\Sysprep\sysprep.exe -ArgumentList "/oobe /generalize /shutdown /mode:vm" -Wait -NoNewWindow -PassThru
"Sysprep exit code: `$(`$result.ExitCode)" | Out-File C:\Windows\Temp\sysprep_capture.log -Append
Write-Host ("COMPLETED SYSPREP PROCESS...")
"@

### Save the command to a local file
$ScriptDestinationPath = "$env:Temp\temp.ps1"
Set-Content -Path $ScriptDestinationPath -Value $remoteCommand -Force | Out-Null
Write-Host ("    |---Invoking sysprep script on VM [{0}]..." -f $targetVMName)
try{
    $Global:Result = Invoke-AzVMRunCommand -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup -VMName $targetVMName -CommandId 'RunPowerShellScript' -ScriptPath $ScriptDestinationPath

    #collect output msg and display appropiately
    $StdOut = $Global:Result.Value.Message[0]
    $StdErr = $Global:Result.Value.Message[1]
    if ([bool]$StdErr) {
        Write-Host ("{0} {1}" -f (Get-Symbol -Symbol RedX),$StdErr) -ForegroundColor Red
        Continue
    }Else{
        Write-Host ("{0} {1}" -f (Get-Symbol -Symbol GreenCheckmark),($StdOut -split "`n" | Select -Last 1))
    }
}
Catch{
    Write-Host ("{0} {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Black -BackgroundColor Red
}
finally {
    #Invoke-AzVMRunCommand -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup -VMName $targetVMName -CommandId 'RemoveRunCommandWindowsExtension'
    Remove-Item $ScriptDestinationPath -Force | Out-Null
}

#VM should be shutdown already but no deallocated
#Sleep for 5 seconds between checking whether VM is shutdown. Output a dot to screen to show script is still running
Write-Host ("    |---Deallocating resources from VM [{0}]..." -f $targetVMName) -NoNewline
$Null = Stop-AzVM -Name $targetVMName -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup -Force
while($targetVM.PowerState -ne 'VM deallocated' -and $targetVM.PowerState -ne 'VM stopped')
{
    Start-Sleep -Seconds 5
    Write-Host "." -NoNewline
    $targetVM = Get-AzVM -Name $targetVMName -Status
}

#Set VM to Generalized
Write-Host ("    |---Generalizing the VM...") -ForegroundColor White -NoNewline
Try{
    $Null = Set-AzVM -Name $targetVMName -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup -Generalized
    Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
}Catch{
    #Stop-Transcript;Break
    Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
}


Write-Host ("    |---Building Image definition...") -ForegroundColor White -NoNewline
If(-Not($targetDefinition = Get-AzGalleryImageDefinition -GalleryName $ToolkitSettings.AzureResources.imageComputeGallery -ResourceGroupName $ToolkitSettings.AzureResources.imageResourceGroup -Name $ControlCustomizationData.imageDefinition.Name -ErrorAction SilentlyContinue)){
    Try{
        $Null = New-AzGalleryimageDefinition -GalleryName $ToolkitSettings.AzureResources.imageComputeGallery `
                                    -Name $ControlCustomizationData.imageDefinition.name `
                                    -ResourceGroupName $ToolkitSettings.AzureResources.imageResourceGroup `
                                    -Location $ToolkitSettings.TenantEnvironment.location `
                                    -Publisher $ControlCustomizationData.imageDefinition.publisher `
                                    -Offer $ControlCustomizationData.imageDefinition.offer `
                                    -Sku $ControlCustomizationData.imageDefinition.osSku `
                                    -OsState Generalized -OsType Windows `
                                    -HyperVGeneration V2
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }Catch{
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---{1} Using Image definition [{0}]" -f $ControlCustomizationData.imageDefinition.name,(Get-Symbol -Symbol GreenCheckmark))
}

Write-Host ("    |---Generating Image version...") -ForegroundColor White -NoNewline
$Date = Get-Date
$Year=$Date.ToString('yyyy')
$Month=$Date.ToString('MM')


If($LatestVersion = Get-AzGalleryImageVersion -ResourceGroupName $ToolkitSettings.AzureResources.imageResourceGroup -GalleryName $ToolkitSettings.AzureResources.imageComputeGallery -GalleryImageDefinitionName $ControlCustomizationData.ImageDefinition.Name | Select -Last 1){
    #increment build version is year and month found
    $v = [version]$LatestVersion.Name
    #find the build nnumber
    #$build = [System.Text.RegularExpressions.Regex]::Match(($v), '^(?<major>.*)\.(?<minor>.*)\.(?<build>.*)$').Groups[-1].value
    #try and match version with year and month if not use new date and start with build 1
    If($v -eq [version]("{0}.{1}.{2}" -f $Year, $Month, $v.Build)){
        [string]$NewVersion = [version]::New($v.Major,$v.Minor,$v.Build + 1)
    }Else{
        [string]$NewVersion = ("{0}.{1}.{2}" -f $Year, $Month, 1)
    }
}Else{
    [string]$NewVersion = ("{0}.{1}.{2}" -f $Year, $Month, 1)
}
Write-Host ("{0} version is: {1}" -f (Get-Symbol -Symbol GreenCheckmark),[string]$NewVersion) -ForegroundColor Green

#this should always happen (version will increment)
Write-Host ("    |---Building image (this can take awhile)...") -ForegroundColor White -NoNewline
If(-Not(Get-AzGalleryImageVersion -GalleryimageDefinitionName $ControlCustomizationData.imageDefinition.name -ResourceGroupName $ToolkitSettings.AzureResources.imageResourceGroup -GalleryName $ToolkitSettings.AzureResources.imageComputeGallery -Name $NewVersion -ErrorAction SilentlyContinue)){
    Try{
        $Null = New-AzGalleryImageVersion -GalleryimageDefinitionName $ControlCustomizationData.imageDefinition.name `
                                            -Name $NewVersion `
                                            -ResourceGroupName $ToolkitSettings.AzureResources.imageResourceGroup `
                                            -GalleryName $ToolkitSettings.AzureResources.imageComputeGallery `
                                            -Location $ToolkitSettings.TenantEnvironment.location `
                                            -SourceImageId $targetVM.Id
        Write-Host ("{0} created [{1}/{2}/{3}]" -f (Get-Symbol -Symbol GreenCheckmark),$ToolkitSettings.AzureResources.imageComputeGallery,$ControlCustomizationData.imageDefinition.name,$NewVersion)

    }Catch{
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    Write-Host ("    |---{0} Image already exist [{1}/{2}/{3}]" -f (Get-Symbol -Symbol WarningSign),$ToolkitSettings.AzureResources.imageComputeGallery,$ControlCustomizationData.imageDefinition.name,$NewVersion) -ForegroundColor Yellow
}

#check the proviooning status of new image
Write-Host ("    |---Checking image provisioning state...") -ForegroundColor White -NoNewline
If( (Get-AzGalleryImageVersion -GalleryimageDefinitionName $ControlCustomizationData.imageDefinition.name -ResourceGroupName $ToolkitSettings.AzureResources.imageResourceGroup -GalleryName $ToolkitSettings.AzureResources.imageComputeGallery -Name $NewVersion).ProvisioningState -eq 'Succeeded'){
    $ImageReady = $True

}Else{
    $ImageReady = $False
    Send-AIBMessage -Message ("{0}. Captured image was not successfule state" -f (Get-Symbol -Symbol RedX)) -Severity 3 -BreakonError
}

If($CleanUpVMOnCaptureSuccess -and $ImageReady){
    Write-Host ("`nCleaning up resources tied to Azure Virtual Machine [{0}]..." -f $targetVMName) -ForegroundColor Cyan
    if ($targetVM) {
        $RGName=$targetVM.ResourceGroupName

        #Build tag used to indeinfy all resources that need to be deleted
        $tags = @{"VMName"=$targetVMName; "Delete Ready"="Yes"}

        Write-Host ("    |---Marking Disks for deletion...") -ForegroundColor White -NoNewline
        $osDiskName = $targetVM.StorageProfile.OSDisk.Name
        $datadisks = $targetVM.StorageProfile.DataDisks
        $ResourceID = (Get-Azdisk -Name $osDiskName).id
        #tag the system disk for deletion
        New-AzTag -ResourceId $ResourceID -Tag $tags | Out-Null
        #tag the data disk for deletion (if any)
        if ($targetVM.StorageProfile.DataDisks.Count -gt 0) {
            foreach ($datadisks in $targetVM.StorageProfile.DataDisks){
                $datadiskname=$datadisks.name
                $ResourceID = (Get-Azdisk -Name $datadiskname).id
                New-AzTag -ResourceId $ResourceID -Tag $tags | Out-Null
            }
        }

        #get all resources to get VM ID
        $azResourceParams = @{
            'ResourceName' = $targetVMName
            'ResourceType' = 'Microsoft.Compute/virtualMachines'
            'ResourceGroupName' = $RGName
        }
        $targetVMResource = Get-AzResource @azResourceParams
        $targetVMId = $targetVMResource.Properties.VmId

        Write-Host ("    |---Removing Boot Diagnostic disk....") -ForegroundColor White -NoNewline
        $diagSa = [regex]::match($targetVM.DiagnosticsProfile.bootDiagnostics.storageUri, '^http[s]?://(.+?)\.').groups[1].value
        if ($diagSaRg = (Get-AzStorageAccount | where { $_.StorageAccountName -eq $diagSa }).ResourceGroupName){
            Try{
                if ($targetVM.Name.Length -gt 9){
                    $i = 9
                }
                else{
                    $i = $targetVM.Name.Length - 1
                }

                $saParams = @{
                    'ResourceGroupName' = $diagSaRg
                    'Name' = $diagSa
                }
                $diagContainerName = ('bootdiagnostics-{0}-{1}' -f $targetVM.Name.ToLower().Substring(0, $i), $targetVMId)

                Get-AzStorageAccount @saParams | Get-AzStorageContainer | where {$_.Name-eq $diagContainerName} | Remove-AzStorageContainer -Force
                Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
            }Catch{
                #Stop-Transcript;Break
                Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
            }
        }
        else {
            Write-Host ("    |---{0} No Boot Diagnostics Disk found" -f (Get-Symbol -Symbol Information))
        }

        #remove the virtual machine
        Write-Host ("    |---Removing Virtual Machine....") -ForegroundColor White -NoNewline
        Try{
            $null = $targetVM | Remove-AzVM -Force
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }Catch{
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }

        #remove the virtual machine's nics
        Write-Host ("    |---Removing associated Network Interface Cards, Public IP Address(s)....") -ForegroundColor White -NoNewline
        Try{
            foreach($nicUri in $targetVM.NetworkProfile.NetworkInterfaces.Id) {
                $nic = Get-AzNetworkInterface -ResourceGroupName $targetVM.ResourceGroupName -Name $nicUri.Split('/')[-1]
                Remove-AzNetworkInterface -Name $nic.Name -ResourceGroupName $targetVM.ResourceGroupName -Force
                foreach($ipConfig in $nic.IpConfigurations) {
                    if($ipConfig.PublicIpAddress -ne $null){
                        Remove-AzPublicIpAddress -ResourceGroupName $targetVM.ResourceGroupName -Name $ipConfig.PublicIpAddress.Id.Split('/')[-1] -Force
                    }
                }
            }
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }Catch{
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }

        #remove the virtual machine's disks
        Write-Host ("    |---Removing associated OS disk and Data Disk(s)....") -ForegroundColor White -NoNewline
        Try{
            Get-AzResource -tag $tags | where{$_.resourcegroupname -eq $RGName}| Remove-AzResource -force | Out-Null
        }Catch{
            #Stop-Transcript;Break
            Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
        }

    }Else{

        Write-Host ("    |---Virtual Machine does not exist, looking for residual resources....") -ForegroundColor White
        $NicName = ($targetVMName + '_NIC')
        $DiskName = ($targetVMName + '_OSDISK')

        Write-Host ("    |---Removing associated Network Interface Cards....") -ForegroundColor White -NoNewline
        If(Get-AzNetworkInterface -ResourceGroupName $ToolkitSettings.AzureResources.networkResourceGroup -Name $NicName){
            Try{
                Remove-AzNetworkInterface -ResourceGroupName $ToolkitSettings.AzureResources.networkResourceGroup -Name $NicName -Force | Out-Null
                Write-Host ("{0} Removed [{1}]" -f (Get-Symbol -Symbol GreenCheckmark),$NicName) -ForegroundColor Green
            }Catch{
                #Stop-Transcript;Break
                Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
            }
        }Else{
            Write-Host ("    |---{0} No NIC found with name [{1}]" -f (Get-Symbol -Symbol Information),$DiskName) -ForegroundColor Green
        }

        Write-Host ("    |---Removing associated OS disk....") -ForegroundColor White -NoNewline
        If(Get-AzDisk -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup -DiskName $DiskName){
            Try{
                Remove-AzDisk -ResourceGroupName $ToolkitSettings.AzureResources.computeResourceGroup -DiskName $DiskName -Force | Out-Null
                Write-Host ("{0} Removed [{1}]" -f (Get-Symbol -Symbol GreenCheckmark),$DiskName) -ForegroundColor Green
            }Catch{
                #Stop-Transcript;Break
                Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
            }
        }Else{
            Write-Host ("    |---{0} No Disk found with name [{1}]" -f (Get-Symbol -Symbol Information),$DiskName) -ForegroundColor Green
        }
    }
}