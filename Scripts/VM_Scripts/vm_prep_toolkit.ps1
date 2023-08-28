<#
COPY THIS CODE TO AVD REFERENCE VM
#>
[CmdletBinding()]
Param(
    [string]$ResourcePath="<resourcePath>",
    [string]$Sequence="<sequence>",
    [string]$ControlSettings = "<settings>",
    [string]$BlobUrl="<bloburl>",
    [string]$SasToken="<sastoken>",
    [string[]]$FilterSequenceType = @('Application','Script'),
    [string[]]$FilterSequenceName = @(),
    [string[]]$ExcludeSequenceName = @('Microsoft 365 Apps for enterprise - en-us','Microsoft Visio - en-us','Microsoft Project - en-us')
)
#=======================================================
# VARIABLES
#=======================================================
$ScriptInvocation = (Get-Variable MyInvocation -Scope Script).Value

$ErrorActionPreference = "Stop"
#<verbosePreference>
# Save current progress preference and hide the progress
$prevProgressPreference = $global:ProgressPreference
$global:ProgressPreference = 'SilentlyContinue'
#Check if verbose is used; if it is don't use the nonewline in output
If($VerbosePreference){$NoNewLine=$False}Else{$NoNewLine=$True}

$ApplicationsPath = Join-Path $ResourcePath -ChildPath 'Applications'
#$TemplatesPath = Join-Path $ResourcePath -ChildPath 'Templates'
$ControlPath = Join-Path $ResourcePath -ChildPath 'Control'
$ImportsPath = Join-Path $ResourcePath -ChildPath 'Imports'
$ScriptsPath = Join-Path $ResourcePath -ChildPath 'Scripts'
$ToolsPath = Join-Path $ResourcePath -ChildPath 'Tools'
$LogsPath = Join-Path $ResourcePath -ChildPath 'Logs'

#build log directory
New-Item $ResourcePath -ItemType Directory -ErrorAction SilentlyContinue -Force | Out-Null
New-Item $LogsPath -ItemType Directory -ErrorAction SilentlyContinue -Force | Out-Null
New-Item $ImportsPath -ItemType Directory -ErrorAction SilentlyContinue -Force | Out-Null
New-Item $ApplicationsPath -ItemType Directory -ErrorAction SilentlyContinue -Force | Out-Null

#build log directory and File
New-Item $LogsPath -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
$DateLogFormat = (Get-Date).ToString('yyyy-MM-dd_Thh-mm-ss-tt')
$LogfileName = ($ScriptInvocation.MyCommand.Name.replace('.ps1','_').ToLower() + $DateLogFormat + '.log')
Start-transcript "$LogsPath\$LogfileName" -ErrorAction Stop

Write-Host "[string]`$ResourcePath=`"$ResourcePath`""
Write-Host "[string]`$Sequence=`"$Sequence`""
Write-Host "[string]`$ControlSettings = `"$ControlSettings`""
Write-Host "[string]`$BlobUrl=`"$BlobUrl`""
Write-Host "[string]`$SasToken=`"$SasToken`""
##*=============================================
##* INSTALL MODULES (OFFLINE)
##*=============================================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

## ================================
## MAIN
## ================================
Write-Host ("`nSTARTING PREP PROCESS") -ForegroundColor Cyan
#first Build Deployment path on VM

#Build Deployment Folders
$AVDToolkitFolders = @(
    'Control'
    'Scripts'
    'Templates'
    'Tools'
)

$i=0
Foreach($Folder in $AVDToolkitFolders){
    $i++
    Write-Host ("`n[{0}/{1}] Processing folder [{2}]..." -f $i,$AVDToolkitFolders.count,$Folder )
    $DepFileName = ('toolkitfolders_'+ $Folder +'.zip')
    $uri = ($BlobUrl + '/' + $DepFileName +'?' + $SasToken)
    New-Item ($ResourcePath + '\' + $Folder) -ItemType Directory -ErrorAction SilentlyContinue -Force | Out-Null
    Write-Host ("    |---Downloading {0}..." -f $DepFileName) -NoNewline:$NoNewLine
    try{
        Write-Verbose ("RUNNING: Invoke-WebRequest `"$uri`" -ContentType `"application/zip`" -OutFile `"$ImportsPath\$DepFileName`" -UseBasicParsing")
        Invoke-WebRequest $uri -ContentType "application/zip"  -OutFile "$ImportsPath\$DepFileName" -UseBasicParsing
        Write-Host ("Done") -ForegroundColor Green
    }Catch{
        Write-Host ("Failed. {0}" -f $_.Exception.Message) -ForegroundColor Red
    }

    Write-Host ("    |---Extracting {0}..." -f $DepFileName) -NoNewline:$NoNewLine
    try{
        Write-Verbose ("RUNNING: Expand-Archive `"$ImportsPath\$DepFileName`" -DestinationPath `"$ResourcePath`" -Force")
        Expand-Archive "$ImportsPath\$DepFileName" -DestinationPath $ResourcePath -Force
        Remove-item "$ImportsPath\$DepFileName" -ErrorAction SilentlyContinue -Force | Out-Null
        Write-Host ("Done") -ForegroundColor Green
    }Catch{
        Write-Host ("Failed. {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}


#Build Deployment Files
$AVDDeploymentFiles = @{
    'applications_uploaded.xml' = $ApplicationsPath
    'applications_downloaded.xml' = $ApplicationsPath
    'applications.json' = $ApplicationsPath
    'A5_run_sequence.ps1' = $ResourcePath
}
$i=0
Foreach($Item in $AVDDeploymentFiles.GetEnumerator()){
    $i++
    Write-Host ("`n[{0}/{1}] Processing file [{2}]..." -f $i,$AVDDeploymentFiles.count,$Item.Name )
    $uri = ($BlobUrl + '/' + $Item.Name +'?' + $SasToken)
    $Extension = [System.IO.Path]::GetExtension($Item.Name)
    switch($Extension){
        '.json' {$ContentType="application/json"}
        '.xml'  {$ContentType="text/xml"}
        '.ps1'  {$ContentType="text/plain"}
        '.zip'  {$ContentType="application/zip"}
        default {$ContentType="application/octet-stream"}
    }
    Write-Host ("    |---Downloading file {0}..." -f $Item.Name) -NoNewline:$NoNewLine
    try{
        Write-Verbose ("RUNNING: Invoke-WebRequest `"$uri`" -ContentType `"$ContentType`" -OutFile `"$($Item.Value)`" -UseBasicParsing")
        Invoke-WebRequest $uri -ContentType $ContentType -OutFile "$($Item.Value)\$($Item.Name)" -UseBasicParsing
        Write-Host ("Done") -ForegroundColor Green
    }Catch{
        Write-Host ("Failed. {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
}

## ===========================================
## IMPORT FUNCTIONS AFTER FILES ARE DONWLOADED
## ===========================================
. "$ScriptsPath\Environment.ps1"
. "$ScriptsPath\BlobControl.ps1"

## ================================
## GET SETTINGS
## ================================
#import exported apps list from last run (this allows to check if downloaded recent)
If( (Test-Path "$ApplicationsPath\applications.json") -and (Test-Path "$ApplicationsPath\applications_uploaded.xml") -and (Test-Path "$ControlPath\$Sequence\sequence.json") -and (Test-Path "$ControlPath\$ControlSettings") ){
    $ApplicationsList = (Get-Content "$ApplicationsPath\applications.json") | ConvertFrom-Json
    $UploadedApplications = Import-Clixml "$ApplicationsPath\applications_uploaded.xml"
    $ControlCustomizationData = (Get-Content "$ControlPath\$Sequence\sequence.json") | ConvertFrom-Json
    $ToolkitSettings = (Get-Content "$ControlPath\$ControlSettings") | ConvertFrom-Json
}Else{
    Write-Host "Unable to retrieve list of applications, needed files..." -ForegroundColor Red
    Write-Host "  $ApplicationsPath\applications.json" -ForegroundColor Red
    Write-Host "  $ApplicationsPath\applications_uploaded.xml" -ForegroundColor Red
    Write-Host "  $ControlPath\$Sequence\sequence.json" -ForegroundColor Red
    Write-Host "  $ControlPath\$ControlSettings" -ForegroundColor Red
    Write-Host "`nPlease run [" -ForegroundColor Red -NoNewline
    Write-Host "A3_upload_to_azureblob.ps1" -ForegroundColor Cyan -NoNewline
    Write-Host "] prior to this step to prep blob storage" -ForegroundColor Red
    Break
}

#Get settings (for some reason this only works if looped)
Foreach($Setting in $ControlCustomizationData.customSettings){
    #update path
    If($Setting.localPath){
        $Setting.localPath = $ApplicationsPath
    }
    If([System.Convert]::ToBoolean($Setting.showProgress) ){
        $global:ProgressPreference = 'Continue'
    }
}

$BlobRestParams = @{
    SasToken = $SasToken
    BlobUrl = $BlobUrl
}

$BlobAzCopyParams = @{
    SasToken = $SasToken
    SourceUrl = $BlobUrl
    AzCopyPath="$ToolsPath\azcopy.exe"
}

## ================================
## DOWNLOAD APPS
## ================================

#build dyanmic filter
$filterScript = @()
$filterScript += { $_.enabled -eq $true}
If($FilterSequenceType.count -gt 0){
    $filterScript += { $_.Type -in $FilterSequenceType}
}

If($FilterSequenceName.count -gt 0){
    $filterScript += { $_.Name -in $FilterSequenceName}

}
If($ExcludeSequenceName.count -gt 0){
    $filterScript += { $_.Name -notin $ExcludeSequenceName}
}
#combine filter into one scripblock
$JoinedFilterScript = [scriptblock]::Create($filterScript -join ' -and')
#select only steps that are filtered to match name and type
$FilteredCustomizations = ($ControlCustomizationData.customSequence | Where -FilterScript $JoinedFilterScript)

$i=0
#TEST $SequenceItem = $ControlCustomizationData.customSequence[9]
#TEST $SequenceItem = $ControlCustomizationData.customSequence[0]
#TEST $SequenceItem = $ControlCustomizationData.customSequence[13]
#TEST $SequenceItem = $FilteredCustomizations[1]
Foreach($SequenceItem in $FilteredCustomizations){
    $i++
    Write-Host ("`n[{0}/{1}] Processing {2} [{3}]..." -f $i,$FilteredCustomizations.count,$SequenceItem.type,$SequenceItem.name )

    If([System.Convert]::ToBoolean($SequenceItem.enabled))
    {
        switch($SequenceItem.type){

            'Application' {
                #grab the upload metadata that matches
                $AppUploadList = $UploadedApplications | Where id -eq $SequenceItem.id
                #grab the application metadata that matches
                $Application = $ApplicationsList | Where appId -eq $SequenceItem.id

                If($AppUploadList.count -gt 0){
                    $a=0
                    Foreach($AppUploadItem in $AppUploadList)
                    {
                        $a++
                        If( $AppUploadItem.Uploaded -eq $true){
                            Write-Host ("    |---[{0}/{1}] Downloading [{2}]..." -f $a,$AppUploadList.count,$AppUploadItem.ArchiveFile) -NoNewline:$NoNewLine
                            try{
                                Invoke-AzCopyFromBlob -BlobFile $AppUploadItem.ArchiveFile -DestinatioPath $ApplicationsPath @BlobAzCopyParams -Force
                                #Invoke-RestCopyFromBlob -BlobFile $AppUploadItem.ArchiveFile -Destination "$ApplicationsPath\$($AppUploadItem.ArchiveFile)" @BlobRestParams
                                Write-Host ("Done") -ForegroundColor Green
                                $ExtractFile = $true
                            }Catch{
                                Write-Host ("Failed. {0}" -f $_.Exception.Message) -ForegroundColor Red
                                $ExtractFile = $false
                            }
                        }Else{
                            Write-Host ("    |---[{0}/{1}] file not found [{2}]; unable to download" -f $a,$AppUploadList.count,$AppUploadItem.ArchiveFile) -ForegroundColor Yellow
                            $ExtractFile = $false
                        }
                    }#end loop of items

                    If($ExtractFile)
                    {
                        #get one archive file (either single or first file of parts)
                        If($AppUploadList.count -gt 1){
                            $AppUploadItem = $AppUploadList | Where ArchiveFile -match '001$'
                            $ExtractParts = $true
                        }Else{
                            $AppUploadItem = $AppUploadList
                            $ExtractParts = $false
                        }

                        If( ($AppUploadItem.Version -ne '[version]') -and ($AppUploadItem.Version -ne 'latest') ){
                            #update the object
                            $Application.version = $AppUploadItem.Version
                            $AppDestinationPath = Join-Path (Expand-StringVariables -Object $Application -Property $Application.localPath -IncludeVariables) -ChildPath $AppVersion
                            #$AppDestinationPath = "$ApplicationsPath\$($Application.localPath -replace '\s+|\W')\$AppVersion"
                            New-Item $AppDestinationPath -ItemType Directory -ErrorAction SilentlyContinue -Force | Out-Null

                        }Else{
                            $AppDestinationPath = Join-Path (Expand-StringVariables -Object $Application -Property $Application.localPath -IncludeVariables) -ChildPath "Latest"
                            New-Item $AppDestinationPath -ItemType Directory -ErrorAction SilentlyContinue -Force | Out-Null
                        }

                        #update paths in application and build objects
                        $SequenceItem.workingDirectory = $AppDestinationPath
                        $Application.localPath = $AppDestinationPath

                        Try{
                            #extract data to destination
                            If($ExtractParts){
                                Write-Host ("    |---Extracting {1} parts starting with [{0}]..." -f $AppUploadItem.ArchiveFile,$AppUploadList.count) -NoNewline:$NoNewLine
                                Expand-7zipArchive -SevenZipPath ($ToolsPath + '\7za.exe') -FilePath "$ApplicationsPath\$($AppUploadItem.ArchiveFile)" -DestinationPath $AppDestinationPath -Force
                            }Else{
                                Write-Host ("    |---Extracting [{0}]..." -f $AppUploadItem.ArchiveFile) -NoNewline:$NoNewLine
                                Expand-Archive "$ApplicationsPath\$($AppUploadItem.ArchiveFile)" -DestinationPath $AppDestinationPath -Force
                            }
                            Write-Host ("Done") -ForegroundColor Green
                        }Catch{
                            Write-Host ("Failed. {0}" -f $_.Exception.Message) -ForegroundColor Red
                            Continue
                        }

                        Foreach($File in $AppUploadList.ArchiveFile){
                            Remove-item "$ApplicationsPath\$File" -ErrorAction SilentlyContinue -Force | Out-Null
                        }
                    }

                }Else{
                    Write-Host ("    |---Application was not uploaded. Unable to download") -ForegroundColor Yellow
                }


            }#end app switch

            'Script' {
                #DO NOTHING
            }#end script switch

            'WindowsUpdate' {
                #DO NOTHING
            }#end windows update switch
        }
    }Else{
        Write-Host ("    |---not enabled to run") -ForegroundColor Yellow
    }

}
#update json wih version values
$ApplicationsList | ConvertTo-Json | Out-File "$ApplicationsPath\applications.json" -Force
$ControlCustomizationData | ConvertTo-Json -Depth 5 | Out-File "$ControlPath\$Sequence\sequence.json" -Force

$global:ProgressPreference = $prevProgressPreference
Stop-Transcript -ErrorAction SilentlyContinue

Write-Host ("`nCOMPLETED PREP PROCESS") -ForegroundColor Cyan
Write-Host ("REBOOT PENDING: {0}" -f (Test-IsPendingReboot)) -ForegroundColor Cyan