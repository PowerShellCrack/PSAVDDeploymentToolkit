Function Get-PendingWindowsUpdate {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Filter = "(IsInstalled=0 and DeploymentAction=*) or (IsHidden=1 and DeploymentAction=*)",
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
    $objSession = New-Object -ComObject "Microsoft.Update.Session"

    #https://learn.microsoft.com/en-us/windows/win32/wua_sdk/opt-in-to-microsoft-update
    #$ServiceManager = New-Object -ComObject Microsoft.Update.ServiceManager
    #$ServiceManager.ClientApplicationID = "WindowsUpdateOptIn"
    #$NewUpdateService = $ServiceManager.AddService2("7971f918-a847-4430-9279-4a52d1efe18d",7,"")

    #$updates = $objSession.CreateUpdateSearcher().Search($Filter).Updates
    #$update = $updates | Select -Last 1
    foreach($update in $objSession.CreateUpdateSearcher().Search($Filter).Updates)
    {      
        $CategoryList = $Update.Categories | ?{ $_.Parent.CategoryID -ne "6964aab4-c5b5-43bd-a17d-ffb4346a8e1d" } | %{ $_.Name }
       
        If( $null -ne(Compare-Object $CategoryList -DifferenceObject $Categories -IncludeEqual | Where SideIndicator -eq '==') ){
            
            If($Passthru){
                $update
            }
            Else{

                [pscustomobject] @{
                    ID = $update.Identity.UpdateID
                    KB = $update.KBARticleIDs| %{ $_ } 
                    URL = $update.MoreInfoUrls| %{ $_ } 
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

Function Install-PendingWindowsUpdate {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string] $Filter = "(IsInstalled=0 and DeploymentAction=*) or (IsHidden=1 and DeploymentAction=*)",
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
        [switch] $IncludeDrivers
    )

    ## Get the name of this function
    [string]${CmdletName} = $MyInvocation.MyCommand

    $Categories = @()
    If($Type.count -gt 0){
        $Categories += $Type
    }Else{
        $Categories += 'Critical Updates','Definition Updates','Feature Packs','Security Updates','Service Packs','Tools','Update Rollups','Updates','Upgrades'
    }

    If($IncludeDrivers){
        $Categories += 'Drivers'
    }
    
    Write-Host("Checking for pending updates...") -NoNewline
    Write-YaCMLogEntry -Message ("Checking for pending updates...") -Source ${CmdletName}
    $UpdateSession = New-Object -Com Microsoft.Update.Session
    $UpdateSearcher = $UpdateSession.CreateUpdateSearcher()
    $SearchResult = $UpdateSearcher.Search($Filter)
    
    $FinalResult = @()
    Foreach($Update in $SearchResult.Updates){
        $CategoryList = $Update.Categories | ?{ $_.Parent.CategoryID -ne "6964aab4-c5b5-43bd-a17d-ffb4346a8e1d" } | %{ $_.Name }
        If( $null -ne (Compare-Object $CategoryList -DifferenceObject $Categories -IncludeEqual | Where SideIndicator -eq '==') ){
            $FinalResult += $SearchResult
        }
    }

    If ($FinalResult.Updates.Count -eq 0) {
        Write-Host ("no applicable updates found.") -ForegroundColor Green
        Write-YaCMLogEntry -Message ("no applicable updates found.") -Source ${CmdletName}
        return $False    
    }
    Else{
        Write-Host ("found {0}." -f $FinalResult.Updates.Count) -ForegroundColor Green  
        Write-YaCMLogEntry -Message ("found {0}." -f $FinalResult.Updates.Count) -Source ${CmdletName}     
        For ($X = 0; $X -lt $FinalResult.Updates.Count; $X++){
            $Update = $FinalResult.Updates.Item($X)
            Write-Host (" - " + $Update.Title)
            Write-YaCMLogEntry -Message (" - " + $Update.Title) -Source ${CmdletName}
        }
    }
    
    $UpdatesToDownload = New-Object -Com Microsoft.Update.UpdateColl
 
    For ($X = 0; $X -lt $FinalResult.Updates.Count; $X++){
        $Update = $FinalResult.Updates.Item($X)
        #Write-Host( ($X + 1).ToString() + "`> Adding: " + $Update.Title)
        $Null = $UpdatesToDownload.Add($Update)
    }

    Write-Host("Downloading Updates, this may take a while...") -NoNewline
    Write-YaCMLogEntry -Message ("Downloading Updates, this may take a while...") -Source ${CmdletName}
    $Downloader = $UpdateSession.CreateUpdateDownloader()
    $Downloader.Updates = $UpdatesToDownload
    $Null = $Downloader.Download()
    Write-Host "Done" -ForegroundColor Green

    Write-Host("Installing Updates...") -NoNewline
    Write-YaCMLogEntry -Message ("Installing Updates...") -Source ${CmdletName}
    $UpdatesToInstall = New-Object -Com Microsoft.Update.UpdateColl
    For ($X = 0; $X -lt $FinalResult.Updates.Count; $X++){
        $Update = $FinalResult.Updates.Item($X)
        If ($Update.IsDownloaded) {
            #Write-Host( ($X + 1).ToString() + "`> " + $Update.Title)
            $Null = $UpdatesToInstall.Add($Update)        
        }
    }
    $Installer = $UpdateSession.CreateUpdateInstaller()
    $Installer.Updates = $UpdatesToInstall
 
    $InstallationResult = $Installer.Install()
    Write-Host "Done" -ForegroundColor Green

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

    #Write-Host("List of Updates Installed with Results") 
    $UpdatesArray = @()
    For ($X = 0; $X -lt $UpdatesToInstall.Count; $X++){
        $UpdatesObject = [pscustomobject] @{
            Title = $UpdatesToInstall.Item($X).Title
            ID = $UpdatesToInstall.Item($X).Identity.UpdateID
            KB = $UpdatesToInstall.Item($X).KBARticleIDs| %{ $_ } 
            URL = $UpdatesToInstall.Item($X).MoreInfoUrls| %{ $_ } 
            Type = $UpdatesToInstall.Item($X).Categories | ?{ $_.Parent.CategoryID -ne "6964aab4-c5b5-43bd-a17d-ffb4346a8e1d" } | %{ $_.Name }
            Size = $UpdatesToInstall.Item($X).bundledUpdate.MaxDownloadSize
            DownloadURL = $UpdatesToInstall.Item($X).bundledUpdate.DownloadContents.DownloadURL
            Auto = $UpdatesToInstall.Item($X).autoSelectOnWebSites
            Downloaded = $UpdatesToInstall.Item($X).IsDownloaded
            ResultDescription = Get-ResultDescription($InstallationResult.GetUpdateResult($X).ResultCode)
        }
        $UpdatesArray += $UpdatesObject        
    }

    #Write-Host("Installation Result: " + $InstallationResult.ResultCode)
    #Write-Host("    Reboot Required: " + $InstallationResult.RebootRequired)
    If($InstallationResult.RebootRequired){
        Write-YaCMLogEntry -Message ("Device need to reboot") -Source ${CmdletName}
    }

    [pscustomobject] @{
        UpdatesInstalled = $FinalResult.Updates.Count
        UpdateList = $UpdatesArray
        InstallResults = $InstallationResult.ResultCode
        ResultDescription = Get-ResultDescription($InstallationResult.ResultCode)
        RebootRequired = $InstallationResult.RebootRequired
    }
}


Function Invoke-PSWindowsUpdate{
    <#
    .SYNOPSIS
        Invokes Windows update process
    
    .PARAMETER SearchCriteria
        Change the search criteria. Defaults to "(IsInstalled=0 and DeploymentAction=*) or (IsHidden=1 and DeploymentAction=*)"  
    
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
        [string]$SearchCriteria = "(IsInstalled=0 and DeploymentAction=*) or (IsHidden=1 and DeploymentAction=*)",
        [int]$RestartTimeout = 0,
        [switch]$AllowRestart
    )
    
    $ProductName = 'Windows Updates'
    Write-Host ('Enabling {0} agent...' -f $ProductName)
    New-ItemPath -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name NoAutoUpdate -Type DWORD -Value 0 -Force
    #Turn ON: Get latest updates as soon as they are available
    New-ItemPath -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name IsContinuousInnovationOptedIn -Type DWORD -Value 1 -Force
    Restart-Service wuauserv -Force
    #Build progress
    $stepCounter++
    #Write-Progress -Activity ('AVD Customizations [{0} of {1}]' -f $stepCounter,$Maxsteps) -Status ('Running {0}..this can take a while...' -f $ProductName) -PercentComplete ((($stepCounter) / $Maxsteps) * 100)
    Write-Host ("  [1 of 2]: Searching for {0}..." -f  $ProductName) -NoNewline

    Add-WUServiceManager -ServiceID "7971f918-a847-4430-9279-4a52d1efe18d" -Confirm:$false -Silent
    
    $Updates = Get-WindowsUpdate -Criteria $SearchCriteria
    $Null = $Updates | UnHide-WindowsUpdate -Criteria $SearchCriteria -Confirm:$false
    Write-Host ('Done. Found {0} updates' -f $Updates.count) -ForegroundColor Gree

    Write-Verbose ("RUNNING {0} CMDLET: Install-WindowsUpdate -Criteria '{1}' -MicrosoftUpdate -AcceptAll -ForceDownload -ForceInstall -IgnoreReboot" -f $ProductName.ToUpper(),$SearchCriteria)
    Write-Host ("  [2 of 2]: Installing {0}..." -f  $ProductName) -NoNewline
    $Null = Install-WindowsUpdate -Criteria $SearchCriteria -MicrosoftUpdate -AcceptAll -ForceDownload -ForceInstall -IgnoreReboot

    $WUHistory = Get-WUHistory -MaxDate (Get-Date -Format 'MM/dd/yyyy')

    $WUHistory | Select @{n="Message";e={("INSTALLED " + $ProductName.ToUpper() + ": " + $_.Title)}} | Select -ExpandProperty Message | Write-YaCMLogEntry
    Write-Verbose ("COMPLETED {0}: Pending reboot is: {1}" -f $ProductName.ToUpper(),(Get-WURebootStatus -Silent))

    # Disable Automatic Updates...
    Write-Host ('Disabling {0} agent...' -f $ProductName)
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name NoAutoUpdate -Type DWORD -Value 1 -Force
    Restart-Service wuauserv -Force

    If( (Get-WURebootStatus -Silent) -and $AllowRestart){
        Write-Host ('Installed {0} updates. A reboot will be required!' -f $WUHistory.count) -ForegroundColor Yellow
        Restart-Computer -Timeout $RestartTimeout -Force
    }Else{
        Write-Host ('Done. Installed {0} updates' -f $WUHistory.count) -ForegroundColor Green
    }
}