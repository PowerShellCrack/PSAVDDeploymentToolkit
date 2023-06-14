<#
COPY THIS CODE TO AVD REFERENCE VM
#>
[CmdletBinding()]
Param(
    [string]$ResourcePath="<resourcePath>",
    [string]$Sequence="<sequence>",
    [string]$ControlSettings = "<settings>"
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
$ControlCustomizationData = Get-Content "$ControlPath\$Sequence\aib.json" | ConvertFrom-Json

## ================================
## MAIN
## ================================
Write-Host ("`nSTARTING TOOLKIT CLEANUP") -ForegroundColor Cyan

#run cleanup job
Switch($ControlCustomizationData.customSettings.cleanupAction){
    'Everything' {
        Write-Host ("Removing all files and folders from directory: {0}" -f $ResourcePath)
        Remove-Item $ResourcePath -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
    }
    
    'IgnoreLogs' {
        Write-Host ("Removing all files except logs from directory: {0}" -f $ResourcePath)
        Get-ChildItem $ResourcePath -Exclude '*.logs' -Recurse | Remove-Item -ErrorAction SilentlyContinue | Out-Null 
    }

    'JustExectuables' { 
        Write-Host ("Removing all executables from directory: {0} " -f $ResourcePath)
        Get-ChildItem $ResourcePath -Include '*.exe','*.msi' -Recurse | Remove-Item -ErrorAction SilentlyContinue | Out-Null
    }

    default {#Do nothing
    }
}

$global:ProgressPreference = $prevProgressPreference
Stop-Transcript -ErrorAction SilentlyContinue
Write-Host ("COMPLETED TOOLKIT CLEANUP") -ForegroundColor Cyan