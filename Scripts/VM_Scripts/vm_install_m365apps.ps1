<#
THIS CODE IS COPIED TO AVD REFERENCE VM
#>
[CmdletBinding()]
Param(
    [string]$ResourcePath="<resourcePath>",
    [string]$Sequence="<sequence>",
    [string]$ControlSettings = "<settings>",
    [string[]]$FilterSequenceType = @('Application','Script'),
    [string[]]$IncludeSequenceId = @('73d9d3c6-0041-48dc-9866-55b6c1f2af33','bec3bda7-dc2a-49dd-a7c7-23820f303061','55ef05ee-ec78-4ef4-a51b-f9406c059dc9'),
    [string[]]$ExcludeSequenceId = @()
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


If(-NOT(Test-Path $ResourcePath)){
    [string]$ResourcePath = ($PWD.ProviderPath, $PSScriptRoot)[[bool]$PSScriptRoot]
}

$ApplicationsPath = Join-Path $ResourcePath -ChildPath 'Applications'
#$TemplatesPath = Join-Path $ResourcePath -ChildPath 'Templates'
$ControlPath = Join-Path $ResourcePath -ChildPath 'Control'
$ScriptsPath = Join-Path $ResourcePath -ChildPath 'Scripts'
$ToolsPath = Join-Path $ResourcePath -ChildPath 'Tools'
$LogsPath = Join-Path $ResourcePath -ChildPath 'Logs'

#build log directory and File
New-Item $LogsPath -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
$DateLogFormat = (Get-Date).ToString('yyyy-MM-dd_Thh-mm-ss-tt')
$LogfileName = ($ScriptInvocation.MyCommand.Name.replace('.ps1','_').ToLower() + $DateLogFormat + '.log')
Start-transcript "$LogsPath\$LogfileName" -ErrorAction Stop

Write-Host "[string]`$ResourcePath=`"$ResourcePath`""
Write-Host "[string]`$Sequence=`"$Sequence`""
Write-Host "[string]`$ControlSettings = `"$ControlSettings`""

## ================================
## GET SETTINGS
## ================================
$ApplicationsList = Get-Content "$ApplicationsPath\applications.json" | ConvertFrom-Json
$ControlCustomizationData = Get-Content "$ControlPath\$Sequence\sequence.json" | ConvertFrom-Json
$ToolkitSettings = Get-Content "$ControlPath\$ControlSettings" | ConvertFrom-Json

#build dyanmic filter
$filterScript = @()
$filterScript += { $_.enabled -eq $true}
If($FilterSequenceType.count -gt 0){
    $filterScript += { $_.Type -in $FilterSequenceType}
}

If($IncludeSequenceId.count -gt 0){
    $filterScript += { $_.Id -in $IncludeSequenceId}

}
If($ExcludeSequenceId.count -gt 0){
    $filterScript += { $_.Id -notin $ExcludeSequenceId}
}
#combine filter into one scripblock
$JoinedFilterScript = [scriptblock]::Create($filterScript -join ' -and')
#select only steps that are filtered to match name and type
$FilteredCustomizations = ($ControlCustomizationData.customSequence | Where-Object -FilterScript $JoinedFilterScript)
## ================================
## IMPORT FUNCTIONS
## ================================
. "$ScriptsPath\Symbols.ps1"
. "$ScriptsPath\Environment.ps1"
. "$ScriptsPath\SevenZipCmdlets.ps1"
. "$ScriptsPath\SoftwareInventory.ps1"
. "$ScriptsPath\WindowsUpdate.ps1"

## ================================
## IMPORT OFFLINE MODULES
## ================================
Install-PackageProvider NuGet -Force

#If(-NOT(Get-PackageProvider -Name Nuget)){Install-PackageProvider -Name Nuget -ForceBootstrap -RequiredVersion '2.8.5.201' -Force | Out-Null}
#Register-PSRepository -Name Local -SourceLocation "$ToolsPath\Modules" -InstallationPolicy Trusted

$OfflineModules = Get-ChildItem $ToolsPath -Recurse -Filter *.nupkg
$ModulesNeeded = @('PSWindowsUpdate')
$i=0
Foreach($Module in $ModulesNeeded){
    Write-Host ("`n[{0} of {1}] Processing module [{2}]..." -f $i,$ModulesNeeded.count,$Module )
    If($OfflineModule = $OfflineModules | Where-Object Name -like "$Module*"){

        $Name = $OfflineModule.BaseName.split('.')[0].Trim()
        $Version = ($OfflineModule.BaseName -replace '^\w+.').Trim()
        $ModuleDestination = "$env:ProgramFiles\WindowsPowerShell\Modules\$Name\$Version"
        Write-Host ("    |---Importing module [{0} v{1}] to [{2}]..." -f $Name,$Version,$ModuleDestination) -NoNewline:$NoNewLine
        try{
            Rename-Item $OfflineModule.FullName -NewName ($OfflineModule.BaseName + '.zip') -Force -ErrorAction SilentlyContinue
            New-Item $ModuleDestination -ItemType Directory -ErrorAction SilentlyContinue -Force | Out-Null
            Expand-Archive -Path ($OfflineModule.FullName -replace '\.nupkg$','.zip') -DestinationPath $ModuleDestination -ErrorAction SilentlyContinue
            Install-Module $Name -Force
            Write-Host ("Done") -ForegroundColor Green
        }Catch{
            Write-Host ("Failed. {0}" -f $_.Exception.Message) -ForegroundColor Red
        }
    }Else{
        Write-Host Write-Host ("    |---no offline modules exists in folder [{0}]" -f $ToolsPath) -ForegroundColor Yellow
    }
    $i++

}

## ================================
## MAIN
## ================================
Write-Host ("`nSTARTING M365 INSTALL PROCESS") -ForegroundColor Cyan

$i = 0
Foreach($SequenceItem in $FilteredCustomizations){
    $i++
    Write-Host ("`n[{0}/{1}] Processing step: {2} {3}..." -f $i,$FilteredCustomizations.count,$SequenceItem.name,$SequenceItem.version -replace '\[version\]','' )

    switch($SequenceItem.type){

        'Application' {

            #find the application's details associated with id
            $ApplicationData = $ApplicationsList | Where-Object appId -eq $SequenceItem.id

            If($ApplicationData){

                #Always check to ensure same product and version is being installed
                If( Test-ApplicationDetection -ApplicationObject $ApplicationData){
                    Write-Host ("    |---Already installed [{0}], skipping..." -f $ApplicationData.version) -ForegroundColor Green
                    Continue
                }

                $Localpath = $ControlCustomizationData.customSettings.localPath

                #expand the [variables] into values
                $workingDirectory = Expand-StringVariables -Object $SequenceItem -Property $SequenceItem.workingDirectory -IncludeVariables
                New-Item -Path $workingDirectory -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null

                #run the pre install section
                If($ApplicationData.psobject.properties | Where-Object Name -eq 'preInstallScript' ){
                    Write-Host ("    |---Running pre install script...") -NoNewline:$NoNewLine
                    #TEST $scriptline = $ApplicationData.preInstallScript[0]
                    Foreach($scriptline in $ApplicationData.preInstallScript){
                        $expandedscript = Expand-StringVariables -Object $ApplicationData -Property $scriptline -IncludeVariables
                        Write-Verbose "RUNNING: Invoke-Expression `"$expandedscript`""
                        Invoke-Expression $expandedscript
                    }
                    Write-Host ("Done") -ForegroundColor Green
                }


                $f = 0
                Foreach($fileName in $ApplicationData.fileName)
                {
                    $f++
                    $fileName = Expand-StringVariables -Object $ApplicationData -Property $fileName -IncludeVariables

                    If(Test-Path "$workingDirectory\$filename"){

                        $InstallerPath = Join-Path $workingDirectory -ChildPath $fileName

                        Try{
                            #run the pre process section
                            If($ApplicationData.psobject.properties | Where-Object Name -eq 'installArguments' ){
                                $InstallArguments = Expand-StringVariables -Object $ApplicationData -Property $ApplicationData.InstallArguments -IncludeVariables
                                switch([System.IO.Path]::GetExtension($fileName)){
                                    ".msi" {
                                        Write-Verbose "RUNNING: Start-Process -FilePath 'msiexec.exe' -ArgumentList '/i $InstallerPath $InstallArguments' -Wait -Passthru -WindowStyle Hidden"
                                        $Result = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i $InstallerPath $InstallArguments" -Wait -Passthru -WindowStyle Hidden
                                    }
                                    ".exe" {
                                        Write-Verbose "RUNNING: Start-Process -FilePath `"$InstallerPath`" -ArgumentList $InstallArguments -Wait -Passthru -WindowStyle Hidden"
                                        $Result = Start-Process -FilePath $InstallerPath -ArgumentList $InstallArguments -Wait -Passthru -WindowStyle Hidden
                                    }
                                    ".ps1" {
                                        Write-Verbose "RUNNING: powershell.exe -command `"$InstallerPath`" $Arguments"
                                        "& `"`"$InstallerPath`"`" $Arguments"
                                    }
                                    ".vbs" {
                                        Write-Verbose "RUNNING: Start-Process -FilePath 'c:\windows\system32\cscript.exe' -ArgumentList '//Nologo $InstallerPath $InstallArguments' -Wait -Passthru -WindowStyle Hidden"
                                        $Result = Start-Process -FilePath 'c:\windows\system32\cscript.exe' -ArgumentList "//Nologo $InstallerPath $InstallArguments" -Wait -Passthru -WindowStyle Hidden
                                    }
                                    ".wsf" {
                                        Write-Verbose "RUNNING: Start-Process -FilePath 'c:\windows\system32\cscript.exe' -ArgumentList '//Nologo $InstallerPath $InstallArguments' -Wait -Passthru -WindowStyle Hidden"
                                        $Result = Start-Process -FilePath 'c:\windows\system32\cscript.exe' -ArgumentList "//Nologo $InstallerPath $InstallArguments" -Wait -Passthru -WindowStyle Hidden
                                    }
                                }
                            }Else{
                                switch([System.IO.Path]::GetExtension($fileName)){
                                    ".msi" {
                                        Write-Verbose "RUNNING: Start-Process -FilePath 'msiexec.exe' -ArgumentList `"/i $InstallerPath /qn /noretart`" -Wait -Passthru -WindowStyle Hidden"
                                        $Result = Start-Process -FilePath 'msiexec.exe' -ArgumentList "/i $InstallerPath /qn /noretart" -Wait -Passthru -WindowStyle Hidden
                                    }
                                    ".exe" {
                                        Write-Verbose "RUNNING: Start-Process -FilePath `"$InstallerPath`" -Wait -Passthru -WindowStyle Hidden"
                                        $Result = Start-Process -FilePath $InstallerPath -Wait -Passthru -WindowStyle Hidden
                                    }
                                    ".ps1" {
                                        Write-Verbose "RUNNING: powershell.exe -command `"$InstallerPath`""
                                        "& `"`"$InstallerPath`"`""
                                    }
                                    ".vbs" {
                                        Write-Verbose "RUNNING: Start-Process -FilePath 'c:\windows\system32\cscript.exe' -ArgumentList `"//Nologo $InstallerPath`" -Wait -Passthru -WindowStyle Hidden"
                                        $Result = Start-Process -FilePath 'c:\windows\system32\cscript.exe' -ArgumentList "//Nologo $InstallerPath" -Wait -Passthru -WindowStyle Hidden
                                    }
                                    ".wsf" {
                                        Write-Verbose "RUNNING: Start-Process -FilePath 'c:\windows\system32\cscript.exe' -ArgumentList `"//Nologo $InstallerPath`" -Wait -Passthru -WindowStyle Hidden"
                                        $Result = Start-Process -FilePath 'c:\windows\system32\cscript.exe' -ArgumentList "//Nologo $InstallerPath" -Wait -Passthru -WindowStyle Hidden
                                    }
                                }
                            }


                            #get results and see if they are valid
                            If($Result.ExitCode -in $SequenceItem.ValidExitCodes){
                                Write-Host "Install command ran successfully" -ForegroundColor Green
                            }Else{
                                Write-Verbose ("Install command failed for [{0}], error [{1}]" -f $SequenceItem.name,$Result.ExitCode)
                                Write-Host ('Failed. Exit Code: {0}' -f $Result.ExitCode) -ForegroundColor Red
                                If([System.Convert]::ToBoolean($SequenceItem.continueOnError) -eq $false){
                                    Break
                                }
                            }

                        }Catch{
                            Write-Host ("Failed. {0}" -f $_.Exception.Message) -ForegroundColor Red
                        }

                        #run the post process section
                        If($ApplicationData.psobject.properties | Where-Object Name -eq 'postInstallScript' ){
                            Write-Host ("    |---Running post install script...") -NoNewline:$NoNewLine
                            Foreach($scriptline in $ApplicationData.postInstallScript){
                                $expandedscript = Expand-StringVariables -Object $ApplicationData -Property $scriptline -IncludeVariables
                                Write-Verbose "RUNNING: Invoke-Expression `"$expandedscript`""
                                Invoke-Expression $expandedscript
                            }
                            Write-Host ("Done") -ForegroundColor Green
                        }



                        If( [System.Convert]::ToBoolean($SequenceItem.validateInstalled) ){
                            #Always check to ensure same product and version is being installed
                            If( Test-ApplicationDetection -ApplicationObject $ApplicationData){
                                Write-Host ("Successfully installed application [{1}] in: {0} seconds" -f [math]::Round($stopwatch.Elapsed.TotalSeconds,0),$ApplicationData.productName) -ForegroundColor Green
                            }Else{
                                Write-Host ("Unable to find product: {0}" -f $ApplicationData.productName) -ForegroundColor Red
                            }
                        }

                    }Elseif( [System.Convert]::ToBoolean($SequenceItem.continueOnError) ){
                        #if path not found unable to install, continue to next install if ContinueOnError set to true
                        Write-Host ('Unable to install. File not found: {0}, continuing next step' -f $ApplicationData.filename) -ForegroundColor Yellow
                        Continue
                    }Else{
                        Write-Host ('Failed to install. File not found: {0}' -f $ApplicationData.filename) -ForegroundColor Red
                        Break
                    }

                }#end filename loop

            }Elseif([System.Convert]::ToBoolean($SequenceItem.continueOnError)){
                #if path not found unable to install, continue to next install if ContinueOnError set to true
                Write-Host ('Unable to install. Application was not found for {0}, continuing next step' -f $SequenceItem.name) -ForegroundColor Yellow
                Continue
            }Else{
                Write-Host ('Failed to install. Application was not found for {0}' -f $SequenceItem.name) -ForegroundColor Red
                Break
            }

        }#end application switch

        'Script' {
            Write-Host ("    |---Running script") -NoNewline:$NoNewLine
            #TEST $scriptline = $SequenceItem.inlineScript[0]
            Foreach($scriptline in $SequenceItem.inlineScript){
                $expandedscript = Expand-StringVariables -Object $SequenceItem -Property $scriptline -IncludeVariables
                Write-Verbose "RUNNING: Invoke-Expression `"$expandedscript`""
                Try{
                    Invoke-Expression $expandedscript
                }Catch{
                    Write-Verbose ("Failed to run command [{0}], error [{1}]" -f $expandedscript,$_.exception.message)
                    Write-Host ('Failed. Error: {0}' -f $_.exception.message) -ForegroundColor Red
                    If([System.Convert]::ToBoolean($SequenceItem.continueOnError) -eq $false){
                        Break
                    }
                }
            }

            Write-Host ("Done") -ForegroundColor Green
        }#end script switch

        'WindowsUpdate' {
            If($SequenceItem.psobject.properties | Where-Object Name -eq 'preUpdateScript' ){
                Write-Host ("    |---Running pre update script...") -NoNewline:$NoNewLine
                Foreach($scriptline in $SequenceItem.preUpdateScript){
                    $expandedscript = Expand-StringVariables -Object $ApplicationData -Property $scriptline -IncludeVariables
                    Write-Verbose "RUNNING: Invoke-Expression `"$expandedscript`""
                    Invoke-Expression $expandedscript
                }
                Write-Host ("Done") -ForegroundColor Green
            }

            Write-Host ("    |---Running step: {0}...")
            #Invoke-PSWindowsUpdate -AllowRestart:$([System.Convert]::ToBoolean($SequenceItem.rebootOnSuccess)) -RestartTimeout $SequenceItem.restartTimeout
            Install-AllWindowsUpdates -AllowRestart:$([System.Convert]::ToBoolean($SequenceItem.rebootOnSuccess)) -RestartTimeout $SequenceItem.restartTimeout
            If([System.Convert]::ToBoolean($SequenceItem.continueOnError) -eq $false){
                Break
            }

            If($SequenceItem.psobject.properties | Where-Object Name -eq 'postUpdateScript' ){
                Write-Host ("    |---Running post update script...") -NoNewline:$NoNewLine
                Foreach($scriptline in $SequenceItem.postUpdateScript){
                    $expandedscript = Expand-StringVariables -Object $ApplicationData -Property $scriptline -IncludeVariables
                    Write-Verbose "RUNNING: Invoke-Expression `"$expandedscript`""
                    Invoke-Expression $expandedscript
                }
                Write-Host ("Done") -ForegroundColor Green
            }

        }#end windows update switch
    }

}

$global:ProgressPreference = $prevProgressPreference
Stop-Transcript -ErrorAction SilentlyContinue
Write-Host ("COMPLETED INSTALL PROCESS: {0}" -f (Test-IsPendingReboot)) -ForegroundColor Cyan