Function New-ItemPath {
    <#
    .SYNOPSIS
        Creates new path
    .DESCRIPTION
        Itereated through all nodes in path and builds new registry and file paths
    .PARAMETER Path
        The path to create
    .EXAMPLE
        New-ItemPath -Path "HKLM:\SOFTWARE\Microsoft\Teams"

        This example looks for each registry key and bullds the path for it
    .EXAMPLE
        New-ItemPath -Path "C:\Windows\Temp\Apps\New\Folder"

        This example looks for each folder and bulld the path for it
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    Foreach($Node in $Path.split('\'))
    {
        $CurrentPos += $Node + '\'
        Write-Verbose ('Create new path [{0}]' -f $CurrentPos)
        New-Item $CurrentPos -ErrorAction SilentlyContinue -Force | Out-Null
    }
}

Function Get-ResultDescription ($val){
    Switch ($val){
        0 {"Not Started"}
        1 {"In Progress"}
        2 {"Succeeded"}
        3 {"Succeeded With Errors"}
        4 {"Failed"}
        5 {"Aborted"}
        default {"Unknown ($val)"}
    }
}

function Exit-WithCode($exitCode) {
    $host.SetShouldExit($exitCode)
    Exit
}


function Wait-Condition {
    param(
      [scriptblock]$Condition,
      [int]$DebounceSeconds=15
    )
    begin{
        Try{
            Add-Type @'
                using System;
                using System.Runtime.InteropServices;
                
                public static class Windows
                {
                    [DllImport("kernel32", SetLastError=true)]
                    public static extern UInt64 GetTickCount64();
                
                    public static TimeSpan GetUptime()
                    {
                        return TimeSpan.FromMilliseconds(GetTickCount64());
                    }
                }
'@
        }Catch{}
    }
    process {
        $begin = [Windows]::GetUptime()
        do {
            Start-Sleep -Seconds 1
            try {
              $result = &$Condition
            } catch {
              $result = $false
            }
            if (-not $result) {
                $begin = [Windows]::GetUptime()
                continue
            }
        } while ((([Windows]::GetUptime()) - $begin).TotalSeconds -lt $DebounceSeconds)
    }
}


function Wait-WhenRebootRequired{
    Param(
        [bool]$rebootRequired = $false
    )
    # check for pending Windows Updates.
    if (!$rebootRequired) {
        $systemInformation = New-Object -ComObject 'Microsoft.Update.SystemInfo'
        $rebootRequired = $systemInformation.RebootRequired
    }

    # check for pending Windows Features.
    if (!$rebootRequired) {
        $pendingPackagesKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackagesPending'
        $pendingPackagesCount = (Get-ChildItem -ErrorAction SilentlyContinue $pendingPackagesKey | Measure-Object).Count
        $rebootRequired = ($pendingPackagesCount -gt 0)
    }

    if ($rebootRequired) {
        Write-Output 'Waiting for the Windows Update Trusted Installer to exit...'
        Wait-Condition {(Get-Process -ErrorAction SilentlyContinue TiWorker | Measure-Object).Count -eq 0}
        #Exit-WithCode 101
    }

    return $rebootRequired
}


Function Enable-WindowsUpdateAgent{
    Write-Host ('Enabling WUA...')
    New-ItemPath -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name NoAutoUpdate -Type DWORD -Value 0 -Force
    #Turn ON: Get latest updates as soon as they are available
    New-ItemPath -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name IsContinuousInnovationOptedIn -Type DWORD -Value 1 -Force
    Restart-Service wuauserv -Force
}

Function Disable-WindowsUpdateAgent{
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name NoAutoUpdate -Type DWORD -Value 1 -Force
    Restart-Service wuauserv -Force
}

Function Get-AllWindowsUpdates {
    <#
    .SYNOPSIS
        Gets all Windows updates
    .PARAMETER SearchCriteria
        Change the search criteria. Defaults to "'BrowseOnly=0 and IsInstalled=0'"

        Change to "(IsInstalled=0 and DeploymentAction=*) or (IsHidden=1 and DeploymentAction=*)" for all preview updates
            "BrowseOnly=1" finds updates that are considered optional.
            "BrowseOnly=0" finds updates that are not considered optional.
            "AutoSelectOnWebSites=1" finds updates that are flagged to be automatically selected by Windows Update.
            "IsInstalled=0" finds updates that are not installed on the destination computer.
            "IsHidden=0" finds updates that are not marked as hidden.
    .PARAMETER Type
        Type of updates to search for. Defaults to all types
    .PARAMETER IncludeDrivers    
        Include drivers in the search. Defaults to $false
    .PARAMETER Passthru
        Return the update object. Defaults to $false
    .EXAMPLE
        Get-AllWindowsUpdates

        This example gets all Windows updates

    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $SearchCriteria = 'BrowseOnly=0 and IsInstalled=0 and IsHidden=1',
        [ValidateSet('Critical Updates',
            'Definition Updates',
            'Feature Packs',
            'Security Updates',
            'Service Packs',
            'Tools',
            'Update Rollups',
            'Updates',
            'Upgrades'
            )]
        [string[]] $Type,
        [switch] $IncludeDrivers,
        [switch] $Passthru
    )

    $Categories = @()
    If($Type.count -gt 0){
        $Categories += $Type
    }Else{
        $Categories += 'Critical Updates','Definition Updates','Feature Packs','Security Updates','Service Packs','Tools','Update Rollups','Updates','Upgrades'
    }

    If($IncludeDrivers){
        $Categories +='Drivers'
    }

    Enable-WindowsUpdateAgent

    $objSession = New-Object -ComObject "Microsoft.Update.Session"

    #https://learn.microsoft.com/en-us/windows/win32/wua_sdk/opt-in-to-microsoft-update
    #$ServiceManager = New-Object -ComObject Microsoft.Update.ServiceManager
    #$ServiceManager.ClientApplicationID = "WindowsUpdateOptIn"
    #$NewUpdateService = $ServiceManager.AddService2("7971f918-a847-4430-9279-4a52d1efe18d",7,"")

    #$updates = $objSession.CreateUpdateSearcher().Search($SearchCriteria).Updates
    #$update = $updates | Select -Last 1
    foreach($update in $objSession.CreateUpdateSearcher().Search($SearchCriteria).Updates)
    {
        $CategoryList = $Update.Categories | Where-Object{ $_.Parent.CategoryID -ne "6964aab4-c5b5-43bd-a17d-ffb4346a8e1d" } | ForEach-Object{ $_.Name }

        If( $null -ne(Compare-Object $CategoryList -DifferenceObject $Categories -IncludeEqual | Where-Object SideIndicator -eq '==') ){

            If($Passthru){
                $update
            }
            Else{

                [pscustomobject] @{
                    ID = $update.Identity.UpdateID
                    KB = $update.KBARticleIDs| ForEach-Object{ $_ }
                    URL = $update.MoreInfoUrls| ForEach-Object{ $_ }
                    PublishedDate = $update.LastDeploymentChangeTime.ToString('yyyy-MM-dd')
                    Type = $CategoryList
                    Title = $update.Title
                    Size =  [math]::round($update.MaxDownloadSize /1Gb, 3).ToString() + 'gb'
                    DownloadURL = $update.BundledUpdate.DownloadContents.DownloadURL
                    Auto = $update.autoSelectOnWebSites
                    Downloaded = $update.IsDownloaded
                }
            }
        }
    }
}


Function Install-AllWindowsUpdates{
    <#
    .SYNOPSIS
        Installs all Windows updates
    .PARAMETER SearchCriteria
        Change the search criteria. Defaults to "'BrowseOnly=0 and IsInstalled=0'"
        Change to "(IsInstalled=0 and DeploymentAction=*) or (IsHidden=1 and DeploymentAction=*)" for all preview updates
            "BrowseOnly=1" finds updates that are considered optional.
            "BrowseOnly=0" finds updates that are not considered optional.
            "AutoSelectOnWebSites=1" finds updates that are flagged to be automatically selected by Windows Update.
            "AutoSelectOnWebSites=0" finds updates that are not flagged for Automatic Updates.
            "IsInstalled=0" finds updates that are not installed on the destination computer.
            "IsHidden=0" finds updates that are not marked as hidden. 
    .PARAMETER Filters
        Filters to apply to the updates. Defaults to 'include:$true'
    .PARAMETER UpdateLimit
        Maximum number of updates to install. Defaults to 1000
    .PARAMETER OnlyCheckForRebootRequired
        Only check for reboot required. Defaults to $false
    .PARAMETER AllowRestart
        True or False: Allow restart if needed. Defaults to $false
    .PARAMETER RestartTimeout
        Set timeframe to reboot. Defualt to 0
    
    .EXAMPLE
        Install-AllWindowsUpdates

        This example installs all Windows updates
    .LINK
    https://learn.microsoft.com/lv-lv/windows/win32/api/wuapi/nf-wuapi-iupdatesearcher-search
    https://learn.microsoft.com/en-us/windows/win32/wua_sdk/opt-in-to-microsoft-update
    #>
    param(
        [string]$SearchCriteria = 'BrowseOnly=0 and IsInstalled=0 and IsHidden=1',
        [string[]]$SearchCriterias = @('include:$true'),
        [int]$UpdateLimit = 1000,
        [switch]$AllowRestart,
        [int]$RestartTimeout = 0
        
    ) 
    
    $updateFilters = $SearchCriterias | ForEach-Object {
        $action, $expression = $_ -split ':',2
        New-Object PSObject -Property @{
            Action = $action
            Expression = [ScriptBlock]::Create($expression)
        }
    }

    function Test-IncludeUpdate($SearchCriterias, $update) {
        foreach ($SearchCriteria in $SearchCriterias) {
            if (Where-Object -InputObject $update $SearchCriteria.Expression) {
                return $SearchCriteria.Action -eq 'include'
            }
        }
        return $false
    }
    
    Enable-WindowsUpdateAgent

    $windowsOsVersion = [System.Environment]::OSVersion.Version

    Write-Output 'Searching for Windows updates...'

    $updatesToDownloadSize = 0
    $updatesToDownload = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    $updatesToInstall = New-Object -ComObject 'Microsoft.Update.UpdateColl'
    while ($true) {
        try {
            $updateSession = New-Object -ComObject 'Microsoft.Update.Session'
            $updateSession.ClientApplicationID = "avdtoolkit-windows-updates"
            
            #$ServiceManager = New-Object -ComObject Microsoft.Update.ServiceManager
            #$ServiceManager.ClientApplicationID = "WindowsUpdateOptIn"
            #$NewUpdateService = $ServiceManager.AddService2("7971f918-a847-4430-9279-4a52d1efe18d",7,"")
            
            $updateSearcher = $updateSession.CreateUpdateSearcher()
            $searchResult = $updateSearcher.Search($SearchCriteria)
            if ($searchResult.ResultCode -eq 2) {
                break
            }
            $searchStatus = Get-ResultDescription($searchResult.ResultCode)
        } catch {
            $searchStatus = $_.ToString()
        }
        Write-Output ("Search for Windows updates failed with '{0}'. Retrying..." -f $searchStatus)
        Start-Sleep -Seconds 5
    }
    $rebootRequired = $false
    for ($i = 0; $i -lt $searchResult.Updates.Count; ++$i) {
        $update = $searchResult.Updates.Item($i)
        $updateDate = $update.LastDeploymentChangeTime.ToString('yyyy-MM-dd')
        $updateSize = [math]::round($update.MaxDownloadSize /1Gb, 3).ToString() + 'gb'
        $updateTitle = $update.Title
        $updateSummary = ("Windows update ({0}; {1} MB): {2}" -f $updateDate,$updateSize,$updateTitle)

        if (!(Test-IncludeUpdate $updateFilters $update)) {
            Write-Output ("Skipped (filter): {0}" -f $updateSummary)
            continue
        }

        if ($update.InstallationBehavior.CanRequestUserInput) {
            Write-Output "Warning The update '$updateTitle' has the CanRequestUserInput `
                flag set (if the install hangs, you might need to exclude it with the filter `
                'exclude:`$_.InstallationBehavior.CanRequestUserInput' or `
                'exclude:`$_.Title -like '*$updateTitle*'')"
        }

        Write-Output "Found $updateSummary"

        #accept the EULA
        $update.AcceptEula() | Out-Null

        #calculate the size of the updates to download
        $updatesToDownloadSize += $update.MaxDownloadSize
        $updatesToDownload.Add($update) | Out-Null

        $updatesToInstall.Add($update) | Out-Null
        if ($updatesToInstall.Count -ge $UpdateLimit) {
            $rebootRequired = $true
            break
        }
    }

    #DOWNLOAD UPDATES
    if ($updatesToDownload.Count -gt 0)
    {
        $updateSize = [math]::round($updatesToDownloadSize /1Gb, 3).ToString() + 'gb'
        Write-Output ("Downloading Windows updates ({0} updates; {1} MB)..." -f $updatesToDownload.Count,$updateSize)

        $updateDownloader = $updateSession.CreateUpdateDownloader()
        # https://docs.microsoft.com/en-us/windows/desktop/api/winnt/ns-winnt-_osversioninfoexa#remarks
        if (($windowsOsVersion.Major -eq 6 -and $windowsOsVersion.Minor -gt 1) -or ($windowsOsVersion.Major -gt 6)) {
            $updateDownloader.Priority = 4 # 1 (dpLow), 2 (dpNormal), 3 (dpHigh), 4 (dpExtraHigh).
        } else {
            # For versions lower then 6.2 highest prioirty is 3
            $updateDownloader.Priority = 3 # 1 (dpLow), 2 (dpNormal), 3 (dpHigh).
        }
        $updateDownloader.Updates = $updatesToDownload
        while ($true) {
            $downloadResult = $updateDownloader.Download()
            if ($downloadResult.ResultCode -eq 2) {
                break
            }
            if ($downloadResult.ResultCode -eq 3) {
                Write-Output "Download Windows updates succeeded with errors. Will retry after the next reboot."
                $rebootRequired = $true
                break
            }
            $downloadStatus = Get-ResultDescription $downloadResult.ResultCode
            Write-Output ("Download Windows updates failed with {0}. Retrying..." -f $downloadStatus)
            Start-Sleep -Seconds 5
        }
    }

    #INSTALL UPDATES
    if ($updatesToInstall.Count -gt 0) {
        Write-Output ('Installing {0} Windows updates...' -f $updatesToInstall.Count)
        $updateInstaller = $updateSession.CreateUpdateInstaller()
        $updateInstaller.Updates = $updatesToInstall

        $installRebootRequired = $false
        try {
            $installResult = $updateInstaller.Install()
            $installRebootRequired = $installResult.RebootRequired
        } catch {
            Write-Warning "Windows update installation failed with error:"
            Write-Warning $_.Exception.ToString()

            # Windows update install failed for some reason
            # restart the machine and try again
            $rebootRequired = $true
        }
        $null = Wait-WhenRebootRequired ($installRebootRequired -or $rebootRequired)
    } else {
        $null = Wait-WhenRebootRequired $rebootRequired
        Write-Output 'No Windows updates found'
    }

    # Disable Automatic Updates...
    Disable-WindowsUpdateAgent

    If( ($installRebootRequired -or $rebootRequired) -and $AllowRestart){
        Write-Host ('Installed {0} updates. A reboot will be performed!' -f $updatesToInstall.Count) -ForegroundColor Yellow
        Restart-Computer -Timeout $RestartTimeout -Force
    }Else{
        Write-Host ('Installed {0} updates. Rebooot required: {1}' -f $updatesToInstall.Count,($installRebootRequired -or $rebootRequired)) -ForegroundColor Green
    }
}

Function Invoke-PSWindowsUpdate{
    <#
    .SYNOPSIS
        Invokes Windows update process

    .PARAMETER SearchCriteria
        Change the search criteria. Defaults to "'BrowseOnly=0 and IsInstalled=0'"
        Change to "(IsInstalled=0 and DeploymentAction=*) or (IsHidden=1 and DeploymentAction=*)" for all preview updates
            "BrowseOnly=1" finds updates that are considered optional.
            "BrowseOnly=0" finds updates that are not considered optional.
            "AutoSelectOnWebSites=1" finds updates that are flagged to be automatically selected by Windows Update.
            "IsInstalled=0" finds updates that are not installed on the destination computer.
            "IsHidden=0" finds updates that are not marked as hidden. 
    .PARAMETER RestartTimeout
        Set timefram to reboot. Defualt to 0

    .PARAMETER AllowRestart
        True or False

    .EXAMPLE
        Invoke-PSWindowsUpdate

        This example update system and reboot if needed

    .EXAMPLE
        Invoke-PSWindowsUpdate -RestartTimeout 10

        This example updates system and reboots after 10 minutes if needed
    #>
    [CmdletBinding()]
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$SearchCriteria = 'BrowseOnly=0 and IsInstalled=0 and IsHidden=1',
        [int]$RestartTimeout = 0,
        [switch]$AllowRestart
    )

    $ProductName = 'Windows Updates'
    Enable-WindowsUpdateAgent

    #Build progress
    $stepCounter++
    #Write-Progress -Activity ('AVD Customizations [{0} of {1}]' -f $stepCounter,$Maxsteps) -Status ('Running {0}..this can take a while...' -f $ProductName) -PercentComplete ((($stepCounter) / $Maxsteps) * 100)
    Write-Host ("  [1 of 2]: Searching for {0}..." -f  $ProductName) -NoNewline

    Import-Module PSWindowsUpdate -Force -ErrorAction SilentlyContinue
    Add-WUServiceManager -ServiceID "7971f918-a847-4430-9279-4a52d1efe18d" -Confirm:$false -Silent

    $Updates = Get-WindowsUpdate -Criteria $SearchCriteria
    $Null = $Updates | UnHide-WindowsUpdate -Criteria $SearchCriteria -Confirm:$false
    Write-Host ('Done. Found {0} updates' -f $Updates.count) -ForegroundColor Gree

    Write-Verbose ("RUNNING {0} CMDLET: Install-WindowsUpdate -Criteria '{1}' -MicrosoftUpdate -AcceptAll -ForceDownload -ForceInstall -IgnoreReboot" -f $ProductName.ToUpper(),$SearchCriteria)
    Write-Host ("  [2 of 2]: Installing {0}..." -f  $ProductName) -NoNewline
    $Null = Install-WindowsUpdate -Criteria $SearchCriteria -MicrosoftUpdate -AcceptAll -ForceDownload -ForceInstall -IgnoreReboot

    $WUHistory = Get-WUHistory -MaxDate (Get-Date -Format 'MM/dd/yyyy')

    $WUHistory | Select-Object @{n="Message";e={("INSTALLED " + $ProductName.ToUpper() + ": " + $_.Title)}} | Select-Object -ExpandProperty Message | Write-Host
    Write-Verbose ("COMPLETED {0}: Pending reboot is: {1}" -f $ProductName.ToUpper(),(Get-WURebootStatus -Silent))

    # Disable Automatic Updates...
    Disable-WindowsUpdateAgent

    If( (Get-WURebootStatus -Silent) -and $AllowRestart){
        Write-Host ('Installed {0} updates. A reboot will be required!' -f $WUHistory.count) -ForegroundColor Yellow
        Restart-Computer -Timeout $RestartTimeout -Force
    }Else{
        Write-Host ('Done. Installed {0} updates' -f $WUHistory.count) -ForegroundColor Green
    }
}