<#
    .SYNOPSIS
    Downloads appplications

    .DESCRIPTION
    Downloads appplications and zips them up for upload

    .NOTES
    AUTHOR: Dick Tracy II (@powershellcrack)
    PROCESS: What this script will do (in order)
    1.  Imports list of applications
    2.  Installs required modules
    3.  Downloads applications
    4.  Zips up applications
    5.  Exports archive list
    
    TIP: this script can be ran more than once and will check each configuration

    TODO:
        - Check for recent downloads based on version and date
        - Clean up old zipped files and applications folders
        - Split large archive into parts and upload each -DONE 6/9/2023
        - Record applications that are set not to downlaod to be used incase file is already avaialable

    .PARAMETER ResourcePath
    Specify a path other than the relative path this script is running in

    .PARAMETER ControlSettings
    Specify a configuration file. Defaults to settings.json

    .PARAMETER ApplicationsOverrideFile
    Specify an Application fiel to override the path in settings file
    
    .PARAMETER CompressForUpload
    Compresses dwonload applications to zip

    .PARAMETER RemoveOlderVersions
    Removes older versions of applications

    .INPUTS
    applications.json <-- List of applications to download

    .OUTPUTS
    applications_downloaded.xml <-- List of applications successfully download and their archive name
    a2_download_applications_<date>.log <-- Transaction Log file

    .EXAMPLE
    PS .\A2_download_applications.ps1

    RESULT: Run default setting 

   .EXAMPLE
    PS .\A2_download_applications.ps1 -ControlSettings setting.gov.json

    RESULT: Run script using configuration for a gov tenant

    .EXAMPLE
    PS .\A2_download_applications.ps1 -ResourcePath C:\Temp -ControlSettings setting.test.json -CompressForUpload

    RESULT: Run script using configuration from a another file, apps will be downloaded to C:\Temp\Applications, and zipped up
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


        $ToolkitSettings = Get-Childitem "$PSScriptRoot\Control" -Filter Settings* | Where-Object Extension -eq '.json' | Select-Object -ExpandProperty Name

        $ToolkitSettings | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("Config","Setting")]
    [string]$ControlSettings = "Settings.json",

    [Parameter(Mandatory = $false)]
    [ArgumentCompleter( {
        param ( $commandName,
                $parameterName,
                $wordToComplete,
                $commandAst,
                $fakeBoundParameters )


        $ApplicationsLists = Get-Childitem "$PSScriptRoot\Applications" -Filter applications* | Where-Object Extension -eq '.json' | Select-Object -ExpandProperty Name

        $ApplicationsLists | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("AppList")]
    [string]$ApplicationsOverrideFile = "applications.json",

    [switch]$CompressForUpload,

    [switch]$RemoveOlderVersions,

    [switch]$Force
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

#Build paths
$ApplicationsPath = Join-Path $ResourcePath -ChildPath 'Applications'
$ControlPath = Join-Path $ResourcePath -ChildPath 'Control'
$ScriptsPath = Join-Path $ResourcePath -ChildPath 'Scripts'
$ToolsPath = Join-Path $ResourcePath -ChildPath 'Tools'

#build log directory and File
New-Item "$ResourcePath\Logs" -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
$DateLogFormat = (Get-Date).ToString('yyyy-MM-dd_Thh-mm-ss-tt')
$LogfileName = ($ScriptInvocation.MyCommand.Name.replace('.ps1','_').ToLower() + $DateLogFormat + '.log')
Start-transcript "$ResourcePath\Logs\$LogfileName" -ErrorAction Stop

## ================================
## GET SETTINGS
## ================================
$ToolkitSettings = Get-Content "$ControlPath\$ControlSettings" -Raw | ConvertFrom-Json
If($PSBoundParameters.ContainsKey('ApplicationsOverrideFile')){
    $ApplicationsList = Get-Content "$ApplicationsPath\$ApplicationsOverrideFile" -Raw | ConvertFrom-Json | Where-Object enabled -eq $true
}Else{
    $ApplicationsList = (Get-Content "$ResourcePath\$($ToolkitSettings.Settings.appListFilePath)"  -Raw | ConvertFrom-Json) | Where-Object enabled -eq $true
}


## ================================
## IMPORT FUNCTIONS
## ================================
. "$ScriptsPath\Symbols.ps1"
. "$ScriptsPath\Environment.ps1"
. "$ScriptsPath\SoftwareInventory.ps1"
. "$ScriptsPath\WindowsUpdate.ps1"


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


$i=1
Foreach($Module in $ToolkitSettings.Settings.supportingModules){
    $i++
    Write-Host ("    |---[{0} of {1}]: Installing module {2}..." -f $i,($ToolkitSettings.Settings.supportingModules.count+1),$Module) -NoNewline:$NoNewLine
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


## ================================
## MAIN
## ================================


Write-Host ("`nSTARTING DOWNLOAD PROCESS") -ForegroundColor Cyan
$mainstopwatch = [System.Diagnostics.Stopwatch]::StartNew()
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$i = 0
$apps = @()
Foreach($Application in $ApplicationsList){
    $i++
    Write-Host ("`n[{0}/{1}] Processing {2} {3}..." -f $i,$ApplicationsList.count,$Application.productName,$Application.version.replace('[version]','') )
    
    #-and ($LastApplicationRun | Where {$_.productName -eq $Application.productName -and $_.DateDownloaded -ne (get-Date -Format yyyyMMdd)})
    
    #reset version for each iteration (some predownload scripts will set this variable)
    $version = $null
    #expand the [variables] into values
    $Localpath = Expand-StringVariables -Object $Application -Property $Application.localpath -IncludeVariables
    New-Item -Path $Localpath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    
    If([System.Convert]::ToBoolean($Application.download) )
    {
        #run the pre process section
        If($Application.psobject.properties | Where-Object Name -eq 'preDownloadScript' ){
            Write-Host ("    |---Running pre download script...") -NoNewline:$NoNewLine
            Foreach($scriptline in $Application.preDownloadScript){
                $expandedscript = Expand-StringVariables -Object $Application -Property $scriptline
                Write-Verbose "RUNNING: Invoke-Expression `"$expandedscript`""
                Invoke-Expression $expandedscript
            }
            Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
        }
    }
        
    $f = 0
    #TEST $fileName = $Application.fileName | Select -first 1
    Foreach($fileName in $Application.fileName)
    {
        
        $f++
        $appObject = New-Object pscustomobject
        #record the app
        $appObject | Add-Member -MemberType NoteProperty -Name ProductName -Value $Application.productName
        $appObject | Add-Member -MemberType NoteProperty -Name Id -Value $Application.appId

        #some names may have paths (becuase thats the install path); need to grabe the name for use is certain calls
        $fileName = Expand-StringVariables -Object $Application -Property $fileName -IncludeVariables
        $file = $fileName.split('\')[-1]
        $Extension = [System.IO.Path]::GetExtension($fileName)
        
        $outputPath = Join-Path $LocalPath -ChildPath $fileName
        #record location
        $appObject | Add-Member -MemberType NoteProperty -Name AppLocation -Value $LocalPath

        Write-Host ("    |---Downloading [{0}]..." -f $fileName) -NoNewline:$NoNewLine
        #check to see if application should download
        If([System.Convert]::ToBoolean($Application.download) )
        {
            #Update the uri with any variables
            $downloadURI = Expand-StringVariables -Object $Application -Property $Application.downloadURI -IncludeVariables
            #allow for downloading of files from internet
            $env:SEE_MASK_NOZONECHECKS = 1
            Try{
                switch($Application.downloadUriType){
                    'webrequest' {
                        Write-Verbose "RUNNING: Invoke-WebRequest -Uri `"$downloadURI`" -OutFile `"$outputPath`" -UseBasicParsing"
                        $null = Invoke-WebRequest -Uri $downloadURI -OutFile $outputPath -UseBasicParsing
                    }
    
                    'shortlink' {
                        Write-Verbose "RUNNING: Get-MsftLink -ShortLink `"$downloadURI`" | Invoke-MsftLinkDownload -DestPath `"$localpath`""
                        $null = Get-MsftLink -ShortLink $downloadURI | Invoke-MsftLinkDownload -DestPath $localpath
                    }

                    'shortlinkextract' {
                        Write-Verbose "RUNNING: Get-MsftLink -ShortLink `"$downloadURI`" | Invoke-MsftLinkDownload -DestPath `"$localpath`" -Extract -Cleanup"
                        $null = Get-MsftLink -ShortLink $downloadURI | Invoke-MsftLinkDownload -DestPath $localpath -Extract -Cleanup
                    }
    
                    'linkId' {
                        $LinkID = [regex]::Matches($downloadURI, '\d+$').Value
                        Write-Verbose "RUNNING: Invoke-MsftLinkDownload -LinkID $LinkID -Filter $file -DestPath `"$localpath`" -NoProgress -Force"
                        $null = Invoke-MsftLinkDownload -LinkID $LinkID -Filter $file -DestPath $Localpath -NoProgress -Force
                    }
    
                    'linkIdExtract' {
                        $LinkID = [regex]::Matches($downloadURI, '\d+$').Value
                        Write-Verbose "RUNNING: Invoke-MsftLinkDownload -LinkID $LinkID -DestPath $Localpath -Extract -Cleanup"
                        
                        $null = Invoke-MsftLinkDownload -LinkID $LinkID -DestPath $Localpath -Extract -Cleanup
                    }
                }
                $Downloaded = $true
                #record date downloaded
                $appObject | Add-Member -MemberType NoteProperty -Name DateDownloaded -Value (get-Date -Format yyyyMMdd)
                Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))

                
            }Catch{
                $Downloaded = $false
                Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Red  
            }

            #remove metadata
            Unblock-File -Path ($Localpath + '\' + $fileName) -ErrorAction SilentlyContinue

            #remove variable
            Remove-Variable -Name 'SEE_MASK_NOZONECHECKS' -ErrorAction SilentlyContinue
            
            #run the post process section
            If($Application.psobject.properties | Where-Object Name -eq 'postDownloadScript' ){
                Write-Host ("    |---Running post download script...") -NoNewline:$NoNewLine
                Foreach($scriptline in $Application.postDownloadScript){
                    $expandedscript = Expand-StringVariables -Object $Application -Property $scriptline -IncludeVariables
                    Write-Verbose "RUNNING: Invoke-Expression `"$expandedscript`""
                    Invoke-Expression $expandedscript
                }
                Write-Host ("{0}" -f (Get-Symbol -Symbol GreenCheckmark))
            }

            #record action
            $appObject | Add-Member -MemberType NoteProperty -Name Downloaded -Value $Downloaded

        }Else{
            #record action
            $appObject | Add-Member -MemberType NoteProperty -Name Downloaded -Value $false
            If(Test-Path ($Localpath + '\' + $fileName) -ErrorAction SilentlyContinue){
                Write-Host ("{0} Using local copy!" -f (Get-Symbol -Symbol GreenCheckmark)) -ForegroundColor Green
            }Else{
                Write-Host ("{0} No local copy found!" -f (Get-Symbol -Symbol WarningSign)) -ForegroundColor Yellow
            }
        }

        If($RemoveOlderVersions -or ($Application.version -eq 'latest')){
            Write-Host ("    |---Removing older versions...") -NoNewline:$NoNewLine
            $OlderVersions = Get-ChildItem -Path $LocalPath -File -Filter "*$Extension" | Where-Object {$_.Name -ne $fileName}
            If($OlderVersions){
                $OlderVersions | Remove-Item -Force -ErrorAction SilentlyContinue | Out-Null
                Write-Verbose ("Removing file(s): {0}" -f ($OlderVersions.name -join ','))
                Write-Host ("{0} Removed {1} files" -f (Get-Symbol -Symbol GreenCheckmark),$OlderVersions.count) -ForegroundColor Yellow
            }Else{
                Write-Host ("{0} Removed {1} files" -f (Get-Symbol -Symbol GreenCheckmark),'0') -ForegroundColor Green
            }
        }

        If(Test-Path ($Localpath + '\' + $fileName) -ErrorAction SilentlyContinue){
            
            Write-Host ("    |---Updating application version info...") -NoNewline:$NoNewLine
            If($version){
                $Application.version = $version
            }Else{
                #attempt to get version from file properties; otherwisre default to version in json file
                Try{
                    $Application.version = Get-VersionInfo ($Localpath + '\' + $fileName)
                }Catch{
                    $Application.version = (Expand-StringVariables -Object $Application -Property $Application.version -IncludeVariables).Trim()
                }
            }
            #record value
            $appObject | Add-Member -MemberType NoteProperty -Name Version -Value $Application.version
            Write-Host ('{0}' -f $appObject.version) -ForegroundColor Green

            If($CompressForUpload)
            {
                Write-Host "    |---Zipping up application files..." -NoNewline:$NoNewLine

                $ZippedNames = @()
                #create zip file name     
                $ZippedName = ('application_' + ($Application.productName -replace '\s+|\W') + '_' + ($fileName).replace($Extension,'') + '_' + $Application.version + '.zip')
                Write-Verbose ("Compressing application [{0}] as zip: {1}" -f $Application.productName, $ZippedName)
                Try{
                    #to save some time, check if zipped file exists
                    If( -NOT(Test-Path "$ApplicationsPath\$ZippedName*") ){
                
                        #if extension is already a zip file just copy it and rename it
                        If($Extension -eq '.zip'){
                            #Remove-Item -LiteralPath ($Localpath + '\' + $ZippedName) -ErrorAction SilentlyContinue -Force | Out-Null
                            Write-Verbose "RUNNING: Copy-Item -LiteralPath `"$Localpath\$fileName`" -Destination `"$ApplicationsPath\$ZippedName`" -Force"
                            Copy-Item ($Localpath + '\' + $fileName) -Destination ($ApplicationsPath + '\' + $ZippedName) -Force | Out-Null
                        
                        #check to see if there are multiple files in the directory and that its the last filename to process (will compress all files)
                        }ElseIf( ((Get-ChildItem -Path $Localpath -Recurse -Exclude 'InstallOnline.ps1').count -gt 1) -and ($f -eq $Application.filename.count) ){
                            $folderSize = Get-ChildItem -Path $Localpath -Recurse -File | Measure-Object -Property Length -Sum
                            If( ($folderSize.Sum / 1GB) -gt 2){
                                Write-Verbose "RUNNING: Compress-7zipArchive -SevenZipPath `"$ToolsPath\7za.exe`" -Path `"$Localpath`" -DestinationPath `"$ApplicationsPath\$ZippedName`" -Force"
                                Compress-7zipArchive -SevenZipPath "$ToolsPath\7za.exe" -Path $Localpath -DestinationPath "$ApplicationsPath\$ZippedName" -Force -SplitSize 500m
                            }Else{
                                Write-Verbose "RUNNING: Compress-Archive -LiteralPath `"$Localpath`" -DestinationPath `"$ApplicationsPath\$ZippedName`" -Force"
                                Compress-Archive -LiteralPath $Localpath -DestinationPath ($ApplicationsPath + '\' + $ZippedName) -Force | Out-Null
                            }

                        }Else{
                            $folderSize = Get-ChildItem -Path "$Localpath\$fileName" -File | Measure-Object -Property Length -Sum
                            If( ($folderSize.Sum / 1GB) -gt 2){
                                Write-Verbose "RUNNING: Compress-7zipArchive -SevenZipPath `"$ToolsPath\7za.exe`" -Path `"$Localpath\$fileName`" -DestinationPath `"$ApplicationsPath\$ZippedName`" -Force"
                                Compress-7zipArchive -SevenZipPath "$ToolsPath\7za.exe" -Path "$Localpath\$fileName" -DestinationPath "$ApplicationsPath\$ZippedName" -Force -SplitSize 500m
                            }Else{
                                Write-Verbose "RUNNING: Compress-Archive -LiteralPath `"$Localpath\$fileName`" -DestinationPath `"$ApplicationsPath\$ZippedName`" -Force"
                                Compress-Archive -LiteralPath ($Localpath + '\' + $fileName) -DestinationPath ($ApplicationsPath + '\' + $ZippedName) -Force | Out-Null
                            }
                        }
                        #zip up directory if more than one file is found
                        $ZippedNames += Get-ChildItem $ApplicationsPath -Filter "$ZippedName*" | Select-Object -ExpandProperty Name
                        Write-Host ("{0} Total zipped files {1}" -f (Get-Symbol -Symbol GreenCheckmark),$ZippedNames.count) -ForegroundColor Green

                    }Else{
                        $ZippedNames += Get-ChildItem $ApplicationsPath -Filter "$ZippedName*" | Select-Object -ExpandProperty Name
                        Write-Host ("{0} File exists already!" -f (Get-Symbol -Symbol GreenCheckmark)) -ForegroundColor Green
                    }
                    #record value. Sometimes file may be split into parts; get all parts
                    $appObject | Add-Member -MemberType NoteProperty -Name ArchiveFile -Value $ZippedNames
                    #$appObject | Add-Member -MemberType NoteProperty -Name ArchiveFiles -Value $ZippedNames
                    $Archived = $true
                }Catch{
                    $Archived = $false
                    Write-Host ("{0}. {1}" -f (Get-Symbol -Symbol RedX),$_.Exception.message) -ForegroundColor Red  
                }
                
                
                #record action
                $appObject | Add-Member -MemberType NoteProperty -Name ExportedPath -Value $ApplicationsPath
                $appObject | Add-Member -MemberType NoteProperty -Name Archived -Value $Archived
  
                #check to see if zip file(s) exist
                #If( Test-Path ($ApplicationsPath + '\' + $ZippedName.replace('.zip','*')) ){
                If( Test-Path "$ApplicationsPath\$ZippedName*" )
                {
                    If($RemoveOlderVersions){
                        #remove older versions
                        Write-Host ("    |---Removing older zip versions...") -NoNewline:$NoNewLine
                        $OlderVersions = Get-ChildItem -Path $ApplicationsPath -File -Filter ('application_' + ($Application.productName -replace '\s+|\W') + '_' + ($fileName).replace($Extension,'') + '*') | Where-Object { $_.Name -notin $ZippedNames }
                        If($OlderVersions){
                            $OlderVersions | Remove-Item -Force -ErrorAction SilentlyContinue | Out-Null
                            Write-Verbose ("Removing file(s): {0}" -f ($OlderVersions.name -join ','))
                            Write-Host ("{0} Removed {1} zipped files" -f (Get-Symbol -Symbol GreenCheckmark),$OlderVersions.count) -ForegroundColor Yellow
                        }Else{
                            Write-Host ("{0} Removed {1} zipped files" -f (Get-Symbol -Symbol GreenCheckmark),'0') -ForegroundColor Green
                        }
                    }

                    Write-Host ("{0}" -f (Get-Symbol -Symbol Hourglass)) -NoNewline
                    Write-Host (" Processed application in [") -ForegroundColor Green -NoNewline
                    Write-Host ("{0} seconds" -f [math]::Round($stopwatch.Elapsed.TotalSeconds,0)) -ForegroundColor Cyan -NoNewline
                    Write-Host ("]") -ForegroundColor Green
                }Else{
                    Write-Host ("{0}. Failed to find application file(s)" -f (Get-Symbol -Symbol Warning))
                }
            }
        }#end if file exists

        $stopwatch.Stop()
        $stopwatch.Reset()
        $stopwatch.Restart()
        $apps += $appObject
    }#end filename loop

    
}#end application loop



#Export record
$apps | Export-Clixml -Path "$ResourcePath\$($ToolkitSettings.Settings.appDownloadedFilePath)" -Force
$mainstopwatch.Stop()

$global:ProgressPreference = $prevProgressPreference
Stop-Transcript -ErrorAction SilentlyContinue

Write-Host ("`nCOMPLETED DOWNLOAD PROCESS") -ForegroundColor Cyan

Write-Host ("`n{0}" -f (Get-Symbol -Symbol Hourglass)) -NoNewline
Write-Host (" Overall process took [") -ForegroundColor White -NoNewline
Write-Host ("{0} seconds" -f [math]::Round($mainstopwatch.Elapsed.TotalSeconds,0)) -ForegroundColor Cyan -NoNewline
Write-Host ("]") -ForegroundColor White