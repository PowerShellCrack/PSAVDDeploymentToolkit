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


        $ControlSettings = Get-Childitem "$PSScriptRoot\Control" -Filter Settings* | Where Extension -eq '.json' | Select -ExpandProperty Name

        $ControlSettings | Where-Object {
            $_ -like "$wordToComplete*"
        }

    } )]
    [Alias("Config","Setting")]
    [string]$ControlSettings = "Settings.json",

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
. "$ScriptsPath\BlobControl.ps1"