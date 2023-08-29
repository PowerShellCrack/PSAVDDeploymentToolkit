<#
THIS CODE IS COPIED TO AVD REFERENCE VM
#>
[CmdletBinding()]
Param(
    [string]$ResourcePath="<resourcePath>",
    [string]$Sequence="<sequence>",
    [string]$ControlSettings = "<settings>",
    [string]$BlobUrl="<bloburl>",
    [string]$SasToken="<sastoken>",
    [string]$AppInstallScriptPath = "<appscriptpath>"
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
Write-Host "[string]`$AppInstallScriptPath = `"$AppInstallScriptPath`""
##*=============================================
##* INSTALL MODULES (OFFLINE)
##*=============================================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

## ================================
## MAIN
## ================================
Write-Host ("`nSTARTING POST PROCESS") -ForegroundColor Cyan
#Reference: https://docs.microsoft.com/en-us/azure/virtual-desktop/set-up-customize-master-image

# Disable Automatic Updates...
#Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name NoAutoUpdate -Type DWORD -Value 1 -Force

# Specify Start layout for Windows 10 PCs...
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer" -Name SpecialRoamingOverrideAllowed -Type DWORD -Value 1 -Force

# Set up time zone redirection...
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" -Name fEnableTimeZoneRedirection -Type DWORD -Value 1 -Force

# Other applications and registry configuration...
Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name AllowTelemetry -Type DWORD -Value 3 -Force

#remove CorporateWerServer* from Computer\HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\Windows Error Reporting

# fix 5k resolution support...
#New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -ErrorAction SilentlyContinue -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name MaxMonitors -Type DWORD -Value 4 -Force
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name MaxXResolution -Type DWORD -Value 5120 -Force
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name MaxYResolution -Type DWORD -Value 2880 -Force

New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs" -ErrorAction SilentlyContinue -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs" -Name MaxMonitors -Type DWORD -Value 4 -Force
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs" -Name MaxXResolution -Type DWORD -Value 5120 -Force
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\rdp-sxs" -Name MaxYResolution -Type DWORD -Value 2880 -Force

#Remote Desktop Protocol (RDP) is enabled
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0 -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name fDenyTSConnections -Value 0 -Type DWord -Force

#The RDP port is set up correctly using the default port of 3389
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\Winstations\RDP-Tcp' -Name PortNumber -Value 3389 -Type DWord -Force

#The listener is listening on every network interface
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\Winstations\RDP-Tcp' -Name LanAdapter -Value 0 -Type DWord -Force

#Configure network-level authentication (NLA) mode for the RDP connections
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 1 -Type DWord -Force

#Set the keep-alive value:
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name KeepAliveEnable -Value 1  -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name KeepAliveInterval -Value 1  -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\Winstations\RDP-Tcp' -Name KeepAliveTimeout -Value 1 -Type DWord -Force

#Set the reconnect options:
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name fDisableAutoReconnect -Value 0 -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\Winstations\RDP-Tcp' -Name fInheritReconnectSame -Value 1 -Type DWord -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\Winstations\RDP-Tcp' -Name fReconnectSame -Value 1 -Type DWord -Force

#Make sure the environmental variables TEMP and TMP are set to their default values
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name TEMP -Value "%SystemRoot%\TEMP" -Type ExpandString -Force
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' -Name TMP -Value "%SystemRoot%\TEMP" -Type ExpandString -Force

$Diskpartscript = "
san policy=onlineall
exit
"

$Diskpartscript | Set-Content "$env:temp\diskpartsanonline.txt"
#Get-Content "$env:temp\diskpartsanonline.txt"

#Set the disk SAN policy to Onlineall
diskpart /s "$env:temp\diskpartsanonline.txt"

#Set Coordinated Universal Time (UTC) time for Windows
Set-ItemProperty -Path HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation -Name RealTimeIsUniversal -Value 1 -Type DWord -Force
Set-Service -Name w32time -StartupType Automatic

#Set the power profile to high performance
powercfg.exe /setactive SCHEME_MIN

#Check the Windows services
Get-Service -Name BFE, Dhcp, Dnscache, IKEEXT, iphlpsvc, nsi, mpssvc, RemoteRegistry |
  Where-Object StartType -ne Automatic |
    Set-Service -StartupType Automatic

Get-Service -Name Netlogon, Netman, TermService |
  Where-Object StartType -ne Manual |
    Set-Service -StartupType Manual


#Limit the number of concurrent connections
#Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\Winstations\RDP-Tcp' -Name MaxInstanceCount -Value 4294967295 -Type DWord -Force

#Remove any self-signed certificates tied to the RDP listener
if ((Get-Item -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp').Property -contains 'SSLCertificateSHA1Hash')
{
    Remove-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name SSLCertificateSHA1Hash -Force
}

#Turn on Windows Firewall on the three profiles (domain, standard, and public)
Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True | Out-Null

# allow WinRM through the three firewall profiles (domain, private, and public)
Enable-PSRemoting -Force
Set-NetFirewallRule -Name WINRM-HTTP-In-TCP -Enabled True | Out-Null
#Set-NetFirewallRule -Name WINRM-HTTP-In-TCP, WINRM-HTTP-In-TCP-PUBLIC -Enabled True


#Enable the following firewall rules to allow the RDP traffic
Set-NetFirewallRule -Group '@FirewallAPI.dll,-28752' -Enabled True | Out-Null

#Enable the rule for file and printer sharing
Set-NetFirewallRule -Name FPS-ICMP4-ERQ-In -Enabled True | Out-Null

#Create a rule for the Azure platform network
New-NetFirewallRule -DisplayName AzurePlatform -Direction Inbound -RemoteAddress 168.63.129.16 -Profile Any -Action Allow -EdgeTraversalPolicy Allow | Out-Null
New-NetFirewallRule -DisplayName AzurePlatform -Direction Outbound -RemoteAddress 168.63.129.16 -Profile Any -Action Allow | Out-Null

#chkdsk.exe /f

#Set the Boot Configuration Data (BCD) settings
bcdedit.exe /set "{bootmgr}" integrityservices enable
bcdedit.exe /set "{default}" device partition=C:
bcdedit.exe /set "{default}" integrityservices enable
bcdedit.exe /set "{default}" recoveryenabled Off
bcdedit.exe /set "{default}" osdevice partition=C:
bcdedit.exe /set "{default}" bootstatuspolicy IgnoreAllFailures

#Enable Serial Console Feature
bcdedit.exe /set "{bootmgr}" displaybootmenu yes
bcdedit.exe /set "{bootmgr}" timeout 5
bcdedit.exe /set "{bootmgr}" bootems yes
bcdedit.exe /ems "{current}" ON
bcdedit.exe /emssettings EMSPORT:1 EMSBAUDRATE:115200

#Enable the dump log; can be helpful in troubleshooting
# Set up the guest OS to collect a kernel dump on an OS crash event
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name CrashDumpEnabled -Type DWord -Force -Value 2
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name DumpFile -Type ExpandString -Force -Value "%SystemRoot%\MEMORY.DMP"
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' -Name NMICrashDump -Type DWord -Force -Value 1

# Set up the guest OS to collect user mode dumps on a service crash event
$key = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps'
if ((Test-Path -Path $key) -eq $false) {(New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' -Name LocalDumps)}
New-ItemProperty -Path $key -Name DumpFolder -Type ExpandString -Force -Value 'C:\CrashDumps'
New-ItemProperty -Path $key -Name CrashCount -Type DWord -Force -Value 10
New-ItemProperty -Path $key -Name DumpType -Type DWord -Force -Value 2
Set-Service -Name WerSvc -StartupType Manual

#Verify that the Windows Management Instrumentation (WMI) repository is consistent
#winmgmt.exe /verifyrepository

#Make sure no other applications than TermService are using port 3389
#netstat.exe -anob | findstr 3389
#Write-Host "tasklist /svc | findstr 4056"

$global:ProgressPreference = $prevProgressPreference
Stop-Transcript -ErrorAction SilentlyContinue
Write-Host ("COMPLETED PREP FOR CAPTURE")

