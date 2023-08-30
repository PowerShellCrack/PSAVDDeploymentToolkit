<#
    .SYNOPSIS
    Uploads applications to blob

    .DESCRIPTION
    Uploads archived applications to blob using sastoken

    .NOTES
    AUTHOR: Dick Tracy II (@powershellcrack)
    PROCESS: What this script will do (in order)
    1.  Imports list of downloaded applications
    2.  Upload archived applications to blob
    4.  Zip up toolkit foldeer ad upload to blob
    5.  Exports uploaded list

    TODO:
        - Check for existing files in blob storage before upload -DONE 6/10/2023
        - Cleanup blob storage
        - detect azcopy failed in log $env:userprofile\.azcopy\<guid>.log
        - validate file upload is correct hash
        - bulk transfer using azcopy (multiple part files)
        - support parts uploads -DONE 6/9/2023
        - retrieve sastoken from keyvault -DONE 6/9/2023

    .PARAMETER ResourcePath
    Specify a path other than the relative path this script is running in

    .PARAMETER ControlSettings
    Specify a confoguration file. Defaults to settings.json

    .INPUTS
    applications_downloaded <-- List of applications to download

    .OUTPUTS
    applications_uploaded.xml <-- List of applications successfully uploaded
    tooklitfolders_uploaded.xml <-- List of toolkit folders successfully uploaded
    a3_upload_to_azureblob_<date>.log <-- Transaction Log file

    .EXAMPLE
    PS .\A3_upload_to_azureblob.ps1

    RESULT: Run default setting

   .EXAMPLE
    PS .\A3_upload_to_azureblob.ps1 -ControlSettings setting.gov.json

    RESULT: Run script using configuration for a gov tenant

    .EXAMPLE
    PS .\A3_upload_to_azureblob.ps1 -ResourcePath C:\Temp -ControlSettings setting.test.json

    RESULT: Run script using configuration from a another file, apps will be uploaded from C:\Temp\Applications

    .EXAMPLE
    PS .\A3_upload_to_azureblob.ps1 -ControlSettings setting.gov.json -SkipAppUploads

    RESULT: Run script using configuration from a another file and will NOT upload applications
#>
[CmdletBinding()]
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


        $ControlSettings = Get-Childitem "$PSScriptRoot\Control" -Filter Settings* | Where-Object Extension -eq '.json' | Select-Object -ExpandProperty Name

        $ControlSettings | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("Config","Setting")]
    [string]$ControlSettings = "settings.json",

    [switch]$SkipAppUploads,

    [switch]$BlobCleanup
)

#=======================================================
# VARIABLES
#=======================================================
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

#get paths
$ApplicationsPath = Join-Path $ResourcePath -ChildPath 'Applications'
$ControlPath = Join-Path $ResourcePath -ChildPath 'Control'
$ScriptsPath = Join-Path $ResourcePath -ChildPath 'Scripts'
$ToolsPath = Join-Path $ResourcePath -ChildPath 'Tools'
$LogsPath = Join-Path $ResourcePath -ChildPath 'Logs'

#build log directory and File
New-Item $LogsPath -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
$DateLogFormat = (Get-Date).ToString('yyyy-MM-dd_Thh-mm-ss-tt')
$LogfileName = ($ScriptInvocation.MyCommand.Name.replace('.ps1','_').ToLower() + $DateLogFormat + '.log')
Start-transcript "$LogsPath\$LogfileName" -ErrorAction Stop

## ================================
## IMPORT FUNCTIONS
## ================================
. "$ScriptsPath\Symbols.ps1"
. "$ScriptsPath\Environment.ps1"
. "$ScriptsPath\SevenZipCmdlets.ps1"
. "$ScriptsPath\BlobControl.ps1"

## ================================
## GET SETTINGS
## ================================
Write-Host "AZURE SIGNIN..." -ForegroundColor Cyan

$ToolkitSettings = Get-Content "$ResourcePath\Control\$ControlSettings" -Raw | ConvertFrom-Json
#grab envrionment info
Switch($ToolkitSettings.TenantEnvironment.azureEnvironment){
    'AzureUSPublic' {$blobUriAppendix = ".blob.core.windows.net"; $ToolkitSettings.TenantEnvironment.azureEnvironment = 'AzureCloud'}
    'AzureCloud' {$blobUriAppendix = ".blob.core.windows.net"}
    'AzureUSGovernment' {$blobUriAppendix = "blob.core.usgovcloudapi.net"}
    'USsec' {
        Add-AzEnvironment -AutoDiscover 'https://management.azure.microsoft.scloud/metadata/endpoints?api-version=2020-06-01'
        $blobUriAppendix = "blob.core.microsoft.scloud"
    }
}

# CONNECT TO AZURE
Connect-AzAccount -Environment $ToolkitSettings.TenantEnvironment.azureEnvironment
Set-AzContext -Subscription $ToolkitSettings.TenantEnvironment.subscriptionName

# Step 2: get existing context
$currentAzContext = Get-AzContext
# your subscription, this will get your current subscription
$subscriptionID = $currentAzContext.Subscription.Id
Set-Item Env:\SuppressAzurePowerShellBreakingChangeWarnings "true" | Out-Null

#determine where to get sastoken
If($ToolkitSettings.AzureResources.containerSasToken -eq '[KeyVault]'){

    # use sastoken stored in keyvault
    Try{
        $SasToken = Get-AzKeyVaultSecret -VaultName $ToolkitSettings.AzureResources.keyVault -Name $ToolkitSettings.AzureResources.storageContainer -AsPlainText
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }Catch{
        #Stop-Transcript;Break
        Send-AIBMessage -Message ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -Severity 3 -BreakonError
    }
}Else{
    # use sastoken stored in config
    $SasToken = $ToolkitSettings.AzureResources.containerSasToken
}

#get storage context
$StorageKey = (Get-AzStorageAccountKey -ResourceGroupName $ToolkitSettings.AzureResources.storageResourceGroup -Name $ToolkitSettings.AzureResources.storageAccount | Where-Object KeyName -eq 'key1').Value
$Ctx = New-AzStorageContext -StorageAccountName $ToolkitSettings.AzureResources.storageAccount -StorageAccountKey $StorageKey


$BlobUrl = [System.String]::Concat('https://',$ToolkitSettings.AzureResources.storageAccount,'.',$blobUriAppendix,'/',$ToolkitSettings.AzureResources.storageContainer.ToLower())
#build copy params
$BlobCopyParams = @{
    AzCopyPath = (Join-Path $ToolsPath -ChildPath 'azcopy.exe')
    SasToken = $SasToken
    DestinationURL = $BlobUrl
}

## ================================
## MAIN
## ================================
Write-Host ("`nSTARTING UPLOAD PROCESS") -ForegroundColor Cyan

$mainstopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

#import exported apps list from last run (this allows to check if downloaded recent)
If(Test-Path "$ResourcePath\$($ToolkitSettings.Settings.appDownloadedFilePath)"  ){
    $ArchivedApplicationsList = Import-Clixml "$ResourcePath\$($ToolkitSettings.Settings.appDownloadedFilePath)"
    $ArchivedApplications = $ArchivedApplicationsList | Where-Object Archived -eq $true
}Else{
    Write-Host "Unable to process applications, missing {0}. `nPlease run [A2_download_applications.ps1] prior to this step" -ForegroundColor Red
    Break
}

#TEST $Application = $ArchivedApplications | Select -First 1
#TEST $Application = $ArchivedApplications[3]
If(!$SkipAppUploads){
    $i = 0
    $apps = @()
    Foreach($Application in $ArchivedApplications){
        $i++
        Write-Host ("`n[{0}/{1}] Uploaded application [{2} (v{3})]..." -f $i,$ArchivedApplications.count,$Application.ProductName,$Application.version.replace('[version]','') )

        $f=0
        #TEST $Filename = $Application.ArchiveFile | Select -first 1
        Foreach($Filename in $Application.ArchiveFile){
            $f++

            $appObject = New-Object pscustomobject
            $appObject | Add-Member -MemberType NoteProperty -Name Id -Value $Application.Id
            $appObject | Add-Member -MemberType NoteProperty -Name ProductName -Value $Application.ProductName
            $appObject | Add-Member -MemberType NoteProperty -Name Version -Value $Application.Version
            $appObject | Add-Member -MemberType NoteProperty -Name DateUploaded -Value (Get-Date)
            $appObject | Add-Member -MemberType NoteProperty -Name UploadSourcePath -Value ($BlobUrl + '/' + $Filename)
            $appObject | Add-Member -MemberType NoteProperty -Name ArchiveFile -Value $Filename

            Write-Host ("    |---[{0}/{1}] file uploading [" -f $f,$Application.ArchiveFile.count) -NoNewline
            Write-Host ("{0}" -f $Filename) -ForegroundColor Cyan -NoNewline
            Write-Host ("]...") -NoNewline:$NoNewLine

            $BlobFileExists = $false
            If(Get-AzStorageBlob -Container $ToolkitSettings.AzureResources.storageContainer -Context $Ctx -Prefix $Filename -ErrorAction SilentlyContinue){
                $BlobFileExists = $True
            }

            If($BlobFileExists -ne $True){
                try{
                    #Invoke-RestCopyToBlob -SourcePath $Application.ExportedPath @RestCopyParams
                    $Results = Invoke-AzCopyToBlob -Source ($Application.ExportedPath + '\'+ $Filename) @BlobCopyParams -ShowProgress
                    $Uploaded = $true
                    Write-Host ("{0} {1}" -f (Get-Symbol -Symbol GreenCheckmark),($Results -join '')) -ForegroundColor Green
                }Catch{
                    $Uploaded = $false
                    Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Red
                }
            }Else{
                #mimic upload
                Write-Host ("{0} already exists" -f (Get-Symbol -Symbol GreenCheckmark)) -ForegroundColor Green
                $Uploaded = $true
            }

            $appObject | Add-Member -MemberType NoteProperty -Name Uploaded -Value $Uploaded
            $apps += $appObject
        }#end file loop

        $stopwatch.Stop()

        Write-Host ("{0}" -f (Get-Symbol -Symbol Hourglass)) -NoNewline
        Write-Host (" Uploaded {0} file for application in [" -f $Application.ArchiveFile.count) -ForegroundColor Green -NoNewline
        Write-Host ("{0} seconds" -f [math]::Round($stopwatch.Elapsed.TotalSeconds,0)) -ForegroundColor Cyan -NoNewline
        Write-Host ("]") -ForegroundColor Green

        $stopwatch.Reset()
        $stopwatch.Restart()
    }#end app loop
    #Export record
    $apps | Export-Clixml -Path "$ResourcePath\$($ToolkitSettings.Settings.appUploadedFilePath)" -Force

    #Blob Cleanup
    ## ================================
    Write-Host ("Checking for older versions of applications in blob...") -ForegroundColor Cyan
    $UnusedAppplications = Get-AzStorageBlob -Container $ToolkitSettings.AzureResources.storageContainer -Context $Ctx | Where-Object {($_.Name -like 'application_*') -and ($_.Name -notin $apps.ArchiveFile)}
    If($BlobCleanup -and ($UnusedAppplications.count -gt 0) ){
        Write-Host ("    |---cleaning up {0} application(s) in blob..." -f $UnusedAppplications.count) -NoNewline
        try{
            $UnusedAppplications | Remove-AzStorageBlob -Force
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }Catch{
            Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Red
        }
    }Else{
        Write-Host ("    |---No applications were removed from blob...") -ForegroundColor Yellow
    }
}



#collect avd folders and compress them to upload
$AVDToolkitFolders = @(
    'Control'
    'Scripts'
    'Templates'
    'Tools'
)

$i=0
$foldersObject = @()
Foreach($Folder in $AVDToolkitFolders){
    $i++
    $appObject = New-Object pscustomobject
    Write-Host ("`n[{0}/{1}] Uploading folder [{2}]..." -f $i,$AVDToolkitFolders.count,$Folder )

    $ZippedFilePath = ($ApplicationsPath + '\toolkitfolders_' + $Folder + '.zip')
    Write-Host ("    |---Archived folder [{0}]..." -f $ZippedFilePath) -NoNewline:$NoNewLine
    try{
        Compress-Archive -Path ($ResourcePath + '\' + $Folder) -DestinationPath $ZippedFilePath -Force | Out-Null
        Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
    }Catch{
        Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Red
    }

    Write-Host ("    |---Uploading folder to [{0}]..." -f $BlobUrl) -NoNewline:$NoNewLine
    try{
        #Invoke-RestCopyToBlob -SourcePath $ZippedFilePath @RestCopyParams
        $Results = Invoke-AzCopyToBlob -Source $ZippedFilePath @BlobCopyParams -ShowProgress
        $Uploaded = $true
        Write-Host ("{0} {1}" -f (Get-Symbol -Symbol GreenCheckmark),($Results -join '')) -ForegroundColor Green
    }Catch{
        $Uploaded = $false
        Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Red
    }
    $foldersObject | Add-Member -MemberType NoteProperty -Name Uploaded -Value $Uploaded
    $foldersObject | Add-Member -MemberType NoteProperty -Name Folder -Value $ZippedFilePath
    $foldersObject | Add-Member -MemberType NoteProperty -Name UploadSourcePath -Value ($BlobUrl + '/' + $Folder + '.zip')
    $folders += $foldersObject
}
$folders | Export-Clixml -Path "$ResourcePath\$($ToolkitSettings.Settings.folderUploadedFilePath)" -Force



Write-Host ("`nUploading toolkit files...")
Write-Host ("    |---Uploading control data file...") -NoNewline:$NoNewLine
try{
    #Get-ChildItem -Path $ControlPath -Filter '*.xml' | Select -ExpandProperty FullName | Invoke-AzCopyToBlob @RestCopyParams
    $Results = Get-ChildItem -Path $ControlPath -Filter '*.xml' | Select-Object -ExpandProperty FullName | Invoke-AzCopyToBlob @BlobCopyParams -ShowProgress
    Write-Host ("{0} {1}" -f (Get-Symbol -Symbol GreenCheckmark),($Results -join '')) -ForegroundColor Green
}Catch{
    Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Red
}

Write-Host ("    |---Uploading application data files...") -NoNewline:$NoNewLine
try{
    #Get-ChildItem -Path $ApplicationsPath -Filter '*.xml' | Select -ExpandProperty FullName | Invoke-AzCopyToBlob @RestCopyParams
    $Results = Get-ChildItem -Path $ApplicationsPath -Filter '*.xml' | Select-Object -ExpandProperty FullName | Invoke-AzCopyToBlob @BlobCopyParams -ShowProgress
    Write-Host ("{0} {1}" -f (Get-Symbol -Symbol GreenCheckmark),($Results -join '')) -ForegroundColor Green
}Catch{
    Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Red
}
Write-Host ("    |---Uploading application.json...") -NoNewline:$NoNewLine
try{
    #Get-ChildItem -Path (Resolve-Path $($ToolkitSettings.Settings.appListFilePath)) | Select -ExpandProperty FullName | Invoke-AzCopyToBlob @RestCopyParams
    $Results = Get-ChildItem -Path (Resolve-Path $($ToolkitSettings.Settings.appListFilePath)) | Select-Object -ExpandProperty FullName | Invoke-AzCopyToBlob @BlobCopyParams -ShowProgress
    Write-Host ("{0} {1}" -f (Get-Symbol -Symbol GreenCheckmark),($Results -join '')) -ForegroundColor Green
}Catch{
    Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Red
}
Write-Host ("    |---Uploading sequencer...") -NoNewline:$NoNewLine
try{
    #Invoke-AzCopyToBlob -SourcePath "$ResourcePath\$($ToolkitSettings.Settings.sequenceRunnerScriptFile)" @RestCopyParams
    $Results = Invoke-AzCopyToBlob -Source "$ResourcePath\$($ToolkitSettings.Settings.sequenceRunnerScriptFile)" @BlobCopyParams -ShowProgress
    Write-Host ("{0} {1}" -f (Get-Symbol -Symbol GreenCheckmark),($Results -join '')) -ForegroundColor Green
}Catch{
    Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Red
}

$global:ProgressPreference = $prevProgressPreference
Stop-Transcript -ErrorAction SilentlyContinue

$mainstopwatch.Stop()
Write-Host ("`nCOMPLETED UPLOAD PROCESS") -ForegroundColor Cyan
Write-Host ("{0} Upload took [" -f (Get-Symbol -Symbol Hourglass)) -NoNewline
Write-Host ("{0} seconds" -f [math]::Round($mainstopwatch.Elapsed.TotalSeconds,0)) -ForegroundColor Cyan -NoNewline
Write-Host ("]")

<#
$ExcludeRootFile = (Get-ChildItem $ResourcePath -File).Name
$AzCopyParams = @{
    AzCopyPath = "$ResourcePath\Tools\azcopy.exe"
    Source = $ResourcePath
    DestinationPath = [System.String]::Concat('https://',$ToolkitSettings.AzureResources.storageAccount,$blobUriAppendix,'/',$ToolkitSettings.AzureResources.storageContainer.ToLower())
    SasToken = $ToolkitSettings.AzureResources.containerSasToken
    ExcludeFolders = @('DeploymentShare','$OEM$','Boot','Captures','Control','Logs','Operating Systems','Out-of-Box Drivers','Packages','PSDResources','Scripts','Temp','Tools\Modules','Tools\OSDResults','Tools\x64','Tools\x86','.git','.images')
    ExcludeFiles = @('*.xml','*.xsd','*.log','*.ini','*.xaml','*.mof','*.ico','*.wim','*.md') + $ExcludeRootFile
    #IncludeFiles = @('azcopy.exe','*.json','*.ps1','*.msi','*.exe','*.vbs','*.reg','*.xml')
}

iF($TestRun){
    $AzCopyParams += @{
        Test = $true
    }
}

Write-Host ("STARTING SYNC PROCESS...")
Invoke-AzCopyToBlob @AzCopyParams -ShowProgress -Verbose
#>