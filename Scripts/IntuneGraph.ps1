function Get-IntuneApplication {
    <#
    .SYNOPSIS
    This function is used to get applications from the Graph API REST interface
    .DESCRIPTION
    The function connects to the Graph API Interface and gets any applications added
    .PARAMETER DisplayName
    The Display Name of the app to search for
    .PARAMETER ID
    The Application ID to search for
    .EXAMPLE
    Get-IntuneApplication
    Returns any applications configured in Intune
    #>
    [cmdletbinding(DefaultParameterSetName='All')]
    param (
        [Parameter(ParameterSetName='DisplayName')]
        [string] $DisplayName,

        [Parameter(Mandatory,ParameterSetName="ID")]
        [guid] $ID
    )

    $apiVersion = 'beta'
    $resource = 'deviceAppManagement/mobileApps'

    #convert specials into supported char
    #$DisplayName = ([uri]::EscapeDataString($DisplayName))
    $DisplayName = $DisplayName -replace '&','%26'

    switch ($PSCmdlet.ParameterSetName)
    {
        'DisplayName' {
            $resource = $resource + "?`$expand=assignments&`$filter=displayName eq '$DisplayName'"
            break
        }
        'ID' {
            $resource = $resource + '/' + $ID + "?`$expand=assignments"
            break
        }
    }

    try {
        $uri = "$($script:settings.graphURL)/$apiVersion/$resource"
        $return = Invoke-MgGraphRequest -Method Get -Uri $uri
    }
    catch {
        New-Exception -Exception $_.Exception
    }

    if ($PSCmdlet.ParameterSetName -eq 'DisplayName') {
        $return.value
    }
    else {
        $return
    }
}


function Get-IntuneApplicationAssignment {
    <#
    .SYNOPSIS
    This function is used to get an application assignment from the Graph API REST interface
    .DESCRIPTION
    The function connects to the Graph API Interface and gets an application assignment
    .PARAMETER ApplicationId
    The ID (GUID) of the Intnune application to search for
    .PARAMETER GroupId
    The ID (GUID) of the AAD Group to search the app assignment list
    .EXAMPLE
    Get-IntuneApplicationAssignment
    Returns an Application Assignment configured in Intune
    #>
    [cmdletbinding()]
    param (
        [Parameter(Mandatory)]
        [guid] $ApplicationId,

        [Parameter()]
        [guid] $GroupId
    )

    $apiVersion = 'beta'
    $resource = "deviceAppManagement/mobileApps/$ApplicationId/?`$expand=categories,assignments"

    try {
        $uri = "$($script:settings.graphURL)/$apiVersion/$resource"
        $response = Invoke-MgGraphRequest -Method Get -Uri $uri
    }
    catch {
        New-Exception -Exception $_.Exception
    }

    if ($GroupId) {
        return $response.assignments.where({$_.target.groupId -eq $GroupId})
    }

    $response
}


function Invoke-IntuneWinAppUtil {
    <#
    .SYNOPSIS
    This function runs the IntuneWinAppUtil tool
    .EXAMPLE
    Invoke-IntuneWinAppUtil -IntuneWinAppPath PathToIntuneWinAppExecutable -PackageSourcePath PathToPackageSource -IntuneAppPackage IntuneAppPackageName
    This function runs the IntuneWinAppUtil tool
    #>
    [cmdletbinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('PS1','EXE','MSI')]
        [string] $AppType,

        [Parameter(Mandatory)]
        [string] $IntuneWinAppPath,

        [Parameter(Mandatory)]
        [string] $PackageSourcePath,

        [Parameter(Mandatory)]
        [string] $IntuneAppPackage
    )

    begin {
        Write-Log -Message "$($MyInvocation.InvocationName) function..."
    }
    process {

        $packagePath = $PackageSourcePath
        $packageName = $IntuneAppPackage
        $PackageSourcePath = $PackageSourcePath + '\source'

        Write-Log -Message "AppType: [$AppType]"
        Write-Log -Message "Using IntuneWinAppUtil path: [$IntuneWinAppPath]"
        Write-Log -Message "Using Package Source path: [$PackageSourcePath]"
        Write-Log -Message "IntuneAppPackage: [$IntuneAppPackage]"

        if ($AppType -eq 'PS1') {
            Write-Log -Message "Configuring Package Name to include .PS1 extension..."
            $IntuneAppPackage = "$IntuneAppPackage.ps1"
            Write-Log -Message "IntuneAppPackage re-written as: [$IntuneAppPackage]"
        }
        elseIf ($AppType -eq 'EXE') {
            Write-Log -Message "Configuring Package Name to include .EXE extension..."
            $IntuneAppPackage = "$IntuneAppPackage.exe"
            Write-Log -Message "IntuneAppPackage re-written as: [$IntuneAppPackage]"
        }
        elseIf ($AppType -eq 'MSI') {
            Write-Log -Message "Configuring Package Name to include .MSI extension..."
            $IntuneAppPackage = "$IntuneAppPackage.msi"
            Write-Log -Message "IntuneAppPackage re-written as: [$IntuneAppPackage]"
        }

        if (!(Test-Path $IntuneWinAppPath)) {
            Write-Log -Message "Error - $IntuneWinAppPath not found, exiting..." -LogLevel 3
            $script:exitCode = -1
            Return
        }
        if (!(Test-Path "$packagePath\IntuneWin")) {
            Write-Log -Message "Output path: [$packagePath\IntuneWin] not found, creating..."
            try {
                New-Item -Path "$packagePath\IntuneWin" -ItemType Directory -Force | out-null
            }
            catch {
                Write-Log -Message "Error creating output path: [$packagePath\IntuneWin]" -LogLevel 3
                $script:exitCode = -1
            }
        }
        else {
            Write-Log -Message "Existing output path: [$packagePath\IntuneWin] found, re-creating..."
            try {
                Remove-Item -Path "$packagePath\IntuneWin" -Recurse -Force | out-null
                New-Item -Path "$packagePath\IntuneWin" -ItemType Directory -Force | out-null
            }
            catch {
                Write-Log -Message "Error re-creating output path: [$packagePath\IntuneWin]" -LogLevel 3
                $script:exitCode = -1
            }
        }

        <#
            -q Quiet mode.
            -c Folder for all setup files. All files in this folder will be compressed into an .intunewin file.
            -s Setup file (such as setup.exe or setup.msi).
            -o Output folder for the generated .intunewin file.
        #>
        $Arguments = "-q -c ""$PackageSourcePath"" -s ""$PackageSourcePath\$IntuneAppPackage"" -o ""$packagePath\IntuneWin"""
        Write-Log -Message "Arguments built as: $Arguments"

        Write-Log -Message "Running IntuneWinApp..."
        Start-Process -FilePath $IntuneWinAppPath -ArgumentList $Arguments -WindowStyle Hidden -Wait

        Write-Log -Message "Checking for IntuneWin output package..."
        $script:SourceFile = "$packagePath\IntuneWin\$packageName.intunewin"
        if (Test-Path $SourceFile) {
            Write-Log -Message "File created: [$SourceFile]"
        }
        else {
            Write-Log -Message "Error - something went wrong creating IntuneWin package: [$SourceFile]" -LogLevel 3
            $script:exitCode = -1
        }
    }
    end {
        #if (!($script:exitCode -eq 0)) {
        #     return $script:exitCode
        # }
        # Write-Log -Message "Returning..."
        # return $script:exitCode = 0
    }
}



function New-IntuneApplicationPackage {
    <#
    .SYNOPSIS
    This function builds the necessary config scaffold for uploading the new IntuneWin package
    .DESCRIPTION
    This function builds the necessary config scaffold for uploading the new IntuneWin package
    .EXAMPLE
    New-IntuneApplicationPackage
    This function builds the necessary config scaffold for uploading the new IntuneWin package
    .NOTES
    #TEST
    $AppSourcePath = (($PWD.ProviderPath, $PSScriptRoot)[[bool]$PSScriptRoot] + "\IntuneApps")
    $Appname = "Install-BGInfo"
    [string[]] $JSONFileList = $AppSourcePath+"\"+$Appname+"\groups.json"
    $AppManifest = (Get-Content ($AppSourcePath+"\"+$Appname+"\config.json")) | ConvertFrom-Json
    #>
    #>
    [cmdletbinding()]
    param (
        [Parameter(Mandatory, ParameterSetName='default')]
        [ValidateSet('PS1','EXE','MSI','Edge')]
        [string] $AppType,

        [Parameter(ParameterSetName='default')]
        [ValidateSet('TAGFILE','FILE','REGTAG')]
        [string] $RuleType,

        [Parameter(ParameterSetName='default')]
        [string] $ReturnCodeType = 'Default',

        [Parameter(ParameterSetName='default')]
        [ValidateSet('System','User')]
        [string] $InstallExperience,

        [Parameter(ParameterSetName='default')]
        [string] $LogoFile,

        [Parameter(ParameterSetName='default')]
        [string] $RequiredGroupName,

        [Parameter(ParameterSetName='default')]
        [string] $AvailableGroupName,

        [Parameter(ParameterSetName='default')]
        [string] $UninstallGroupName,

        [Parameter(Mandatory, ParameterSetName='Manifest')]
        [psobject] $AppManifest
    )

    if ($AppManifest) {
        $AppType = $AppManifest.AppType
        $RuleType = $AppManifest.RuleType
        $ReturnCodeType = $AppManifest.ReturnCodeType
        $InstallExperience = $AppManifest.InstallExperience
        $LogoFile = $AppManifest.LogoFile
        $requiredgroup = $AppManifest.requiredgroup #-replace "^(group-)"
        $AvailableGroup = $AppManifest.availablegroup #-replace "^(group-)"
        $uninstallgroup = $AppManifest.uninstallgroup #replace "^(group-)"
        If([string]::IsNullOrEmpty($requiredgroup) -eq $false){
            If($requiredgroup -match "^(group-)"){
                $installReqGroup = Get-AADGroup -NameId $requiredgroup
            }Else{
                $installReqGroup = (Get-MgGroup -Filter "DisplayName eq '$requiredgroup'")
            }
        }
        If([string]::IsNullOrEmpty($AvailableGroup) -eq $false){
            If($AvailableGroup -match "^(group-)"){
                $installAvailGroup = Get-AADGroup -NameId $AvailableGroup
            }Else{
                $installAvailGroup = (Get-MgGroup -Filter "DisplayName eq '$AvailableGroup'")
            }
        }
        If([string]::IsNullOrEmpty($uninstallGroup) -eq $false){
            If($uninstallGroup -match "^(group-)"){
                $uninstallGroup = Get-AADGroup -NameId $uninstallgroup
            }Else{
                $uninstallGroup = ((Get-MgGroup -Filter "DisplayName eq '$uninstallgroup'"))
            }
        }
        $scopetag = $AppManifest.scopetag
    }
    Else{
        If($RequiredGroupName){
            $installReqGroup = Get-MgGroup -DisplayName $RequiredGroupName
        }
        If($AvailableGroupName){
            $installAvailGroup = Get-MgGroup -DisplayName $AvailableGroupName
        }
        If($UninstallGroupName){
            $uninstallGroup = Get-MgGroup -DisplayName $UninstallGroupName
        }
    }

    $packageName = $AppManifest.packageName

    if ( $AppType -ne "Edge" ) {
        if ( ( $AppType -eq "PS1" ) -and ( $RuleType -eq "TAGFILE" ) ) {
            Write-Log -Message "Building variables for AppType: $AppType with RuleType: $RuleType"

            if ($installExperience -eq "User") {
                $installCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -Install -userInstall"
                $uninstallCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -UnInstall -userInstall"
            }
            else {
                $installCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -Install"
                $uninstallCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -UnInstall"
            }

            Write-Log -Message "installCmdLine: [$installCmdLine]"
            Write-Log -Message "uninstallCmdLine: [$uninstallCmdLine]"
        }
        elseif ( ( $AppType -eq "PS1" ) -and ( $RuleType -eq "REGTAG" ) ) {
            Write-Log -Message "Building variables for AppType: $AppType with RuleType: $RuleType"

            if ($installExperience -eq "User") {
                $installCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -Install -userInstall -regTag"
                $uninstallCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -UnInstall -userInstall -regTag"
            }
            else {
                $installCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -Install -regTag"
                $uninstallCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -UnInstall -regTag"
            }

            Write-Log -Message "installCmdLine: [$installCmdLine]"
            Write-Log -Message "uninstallCmdLine: [$uninstallCmdLine]"
        }
        elseif ($AppType -eq "EXE") {
            Write-Log -Message "Building variables for AppType: $AppType"
            #$installCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -Install"
            #$uninstallCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -UnInstall"
            Write-Log -Message "installCmdLine: [$installCmdLine]"
            Write-Log -Message "uninstallCmdLine: [$uninstallCmdLine]"
        }
        elseif ($AppType -eq "MSI") {
            Write-Log -Message "Building variables for AppType: $AppType"
            #$installCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -Install"
            #$uninstallCmdLine = "powershell.exe -windowstyle hidden -noprofile -executionpolicy bypass -file .\$PackageName.ps1 -UnInstall"
            Write-Log -Message "installCmdLine: [$installCmdLine]"
            Write-Log -Message "uninstallCmdLine: [$uninstallCmdLine]"
        }

        if ( ( $RuleType -eq "TAGFILE" ) -and ( ! ( $AppType -eq "MSI" ) ) ) {
            Write-Log -Message "Building variables for RuleType: $RuleType"
            if ($installExperience -eq "System") {
                Write-Log -Message "Creating TagFile detection rule for System install"
                $FileRule = New-DetectionRule -File -Path "%PROGRAMDATA%\Microsoft\IntuneApps\$PackageName" `
                    -FileOrFolderName "$PackageName.tag" -FileDetectionType exists -check32BitOn64System False
            }
            elseif ($installExperience -eq "User") {
                Write-Log -Message "Creating TagFile detection rule for User install"
                $FileRule = New-DetectionRule -File -Path "%LOCALAPPDATA%\Microsoft\IntuneApps\$PackageName" `
                    -FileOrFolderName "$PackageName.tag" -FileDetectionType exists -check32BitOn64System False
            }
            Write-Log -Message "FileRule: [$FileRule]"

            # Creating Array for detection Rule
            $DetectionRule = @($FileRule)
        }
        elseif ( ( $RuleType -eq "FILE" ) -and ( ! ( $AppType -eq "MSI" ) ) ) {
            Write-Log -Message "Building variables for RuleType: $RuleType"
            $fileDetectPath = split-path -parent $FilePath
            $fileDetectFile = split-path -leaf $FilePath
            Write-Log -Message "fileDetectPath: $fileDetectPath"
            Write-Log -Message "fileDetectFile: $fileDetectFile"

            $FileRule = New-DetectionRule -File -Path $fileDetectPath `
                -FileOrFolderName $fileDetectFile -FileDetectionType exists -check32BitOn64System False
            Write-Log -Message "FileRule: [$FileRule]"

            # Creating Array for detection Rule
            $DetectionRule = @($FileRule)
        }
        elseif ( ( $RuleType -eq "REGTAG" ) -and ( ! ( $AppType -eq "MSI" ) ) ) {
            Write-Log -Message "Building variables for RuleType: $RuleType"
            if ($installExperience -eq "System") {
                Write-Log -Message "Creating RegTag detection rule for System install"

                $RegistryRule = New-DetectionRule -Registry -RegistryKeyPath "HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\IntuneApps\$PackageName" `
                    -RegistryDetectionType exists -check32BitRegOn64System True -RegistryValue "Installed"
            }
            elseif ($installExperience -eq "User") {
                Write-Log -Message "Creating RegTag detection rule for User install"

                $RegistryRule = New-DetectionRule -Registry -RegistryKeyPath "HKEY_CURRENT_USER\SOFTWARE\Microsoft\IntuneApps\$PackageName" `
                    -RegistryDetectionType exists -check32BitRegOn64System True -RegistryValue "Installed"
            }

            # Creating Array for detection Rule
            $DetectionRule = @($RegistryRule)
        }
        else {
            Write-Log -Message "Using MSI detection rule"
            $DetectionRule = "MSI"
        }
        if ($ReturnCodeType -eq "DEFAULT") {
            Write-Log -Message "Building variables for ReturnCodeType: $ReturnCodeType"
            $ReturnCodes = Get-DefaultReturnCodes
        }
        $Icon = New-IntuneWin32AppIcon -FilePath "$($AppManifest.packagePath)\$LogoFile"
    }

    $intuneApplication = Get-IntuneApplication -DisplayName $AppManifest.displayName

    #Check if package already exists
    if ( $intuneApplication.Id ) {
        Write-Log -Message "Detected existing package in Intune: $displayName"
        Write-Log -Message "Manual upload of the new IntuneWin package required."
        Write-Log -Message "Upload content: "
        Write-Host "$script:SourceFile" -ForegroundColor Cyan
        return
    }
    else {
        Write-Log -Message "Existing package not found"
    }

    switch ( $AppType ) {
        'PS1' {
            $win32LobParams = @{
                PS1 = $true
                SourceFile = $SourceFile
                publisher = $AppManifest.publisher
                Description = $AppManifest.description
                DetectionRules = $DetectionRule
                ReturnCodes = $ReturnCodes
                DisplayName = $AppManifest.displayName
                PS1InstallCommandLine = $InstallCmdLine
                PS1UninstallCommandLine = $UninstallCmdLine
                InstallExperience = $installExperience
                Logo = $Icon
                Category = $AppManifest.category
            }
            $intuneApplication = Upload-Win32Lob @win32LobParams
        }
        'EXE' {
            $win32LobParams = @{
                EXE = $true
                SourceFile = $SourceFile
                publisher = $AppManifest.publisher
                Description = $AppManifest.description
                DetectionRules = $DetectionRule
                ReturnCodes = $ReturnCodes
                DisplayName = $AppManifest.displayName
                InstallCommandLine = $InstallCmdLine
                UninstallCommandLine = $UninstallCmdLine
                InstallExperience = $installExperience
                Logo = $Icon
                Category = $AppManifest.category
            }
            $intuneApplication = Upload-Win32Lob @win32LobParams
        }
        'MSI' {
            if ( ( ! ( IsNull( $installCmdLine) ) ) -and ( ! ( IsNull( $uninstallCmdLine ) ) ) ) {
                $intuneApplication = Upload-Win32Lob -MSI -SourceFile "$SourceFile" -publisher "$Publisher" -description "$Description" -detectionRules $DetectionRule `
                    -returnCodes $ReturnCodes -displayName $displayName -msiInstallCommandLine $installCmdLine -msiUninstallCommandLine $uninstallCmdLine -installExperience $installExperience -logo $Icon -Category $Category
            }
            elseif ( ( ! ( IsNull( $installCmdLine ) ) ) -and ( IsNull( $uninstallCmdLine ) ) ) {
                $intuneApplication = Upload-Win32Lob -MSI -SourceFile "$SourceFile" -publisher "$Publisher" -description "$Description" -detectionRules $DetectionRule `
                    -returnCodes $ReturnCodes -displayName $displayName -msiInstallCommandLine $installCmdLine -installExperience $installExperience -logo $Icon -Category $Category
            }
            elseif ( ( IsNull( $installCmdLine ) ) -and ( ! ( IsNull( $uninstallCmdLine ) ) ) ) {
                $intuneApplication = Upload-Win32Lob -MSI -SourceFile "$SourceFile" -publisher "$Publisher" -description "$Description" -detectionRules $DetectionRule `
                    -returnCodes $ReturnCodes -displayName $displayName -msiUninstallCommandLine $uninstallCmdLine -installExperience $installExperience -logo $Icon -Category $Category
            }
            elseif ( ( IsNull( $installCmdLine ) ) -and ( IsNull( $uninstallCmdLine ) ) ) {
                $intuneApplication = Upload-Win32Lob -MSI -SourceFile "$SourceFile" -publisher "$Publisher" -description "$Description" -detectionRules $DetectionRule `
                    -returnCodes $ReturnCodes -displayName $displayName -installExperience $installExperience -logo $Icon -Category $Category
            }
        }
        'Edge' {
            $win32LobParams = @{
                Edge = $true
                Publisher = $AppManifest.publisher
                Description = $AppManifest.description
                DisplayName = $AppManifest.displayName
                Channel = $channel
            }
            $intuneApplication = Upload-Win32Lob @win32LobParams
        }
    }

    If($installReqGroup.id){
        $null = Set-IntuneApplicationAssignment -ApplicationId $intuneApplication.Id -TargetGroupId $installReqGroup.id -Intent 'Required'
    }
    If($installAvailGroup.id){
        $null = Set-IntuneApplicationAssignment -ApplicationId $intuneApplication.Id -TargetGroupId $installAvailGroup.id -Intent 'Available'
    }
    If($uninstallGroup.id){
        $null = Set-IntuneApplicationAssignment -ApplicationId $intuneApplication.Id -TargetGroupId $uninstallGroup.id -Intent 'Uninstall'
        $null = Set-IntuneApplicationAssignment -ApplicationId $intuneApplication.Id -TargetGroupId $uninstallGroup.id -Intent 'Required'  -Exclude
        $null = Set-IntuneApplicationAssignment -ApplicationId $intuneApplication.Id -TargetGroupId $uninstallGroup.id -Intent 'Available' -Exclude
    }

    #Removed requirement. Remove from code after next release 2201
  #  if ( $AppManifest.espApp -eq $true ) {
   #     $espReqGroup = (Get-MgGroup -Filter "DisplayName eq 'PAW-CSM-Devices-Autopilot-GroupTag'")
   #     $assignment = Set-IntuneApplicationAssignment -ApplicationId $intuneApplication.Id -TargetGroupId $espReqGroup.id   -Intent 'Required'
   # }

    Set-RBACScopeTag -Application $AppManifest.displayName -scopetag $scopetag

}



function New-IntuneApplicationTemplate {
    <#
    .SYNOPSIS
    This function is used to prepare folder for a new Intune application
    .DESCRIPTION
    This function is used to prepare folder for a new Intune application
    .PARAMETER $Name
    The name of the new application
    #>
    param(
      [parameter(Mandatory)]
      [string] $Name
    )

    $NewPackageName = "$PSScriptRoot\$Name"
    $checkoutPath = "$PSScriptRoot\_Template\CopyMeAsStartingPointForNewPackages"

    Write-Host "Cloning ..."

    try {
        Copy-Item -Path $checkoutPath -Destination $NewPackageName -Recurse -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "$($env:computername.ToUpper()) : $($_.Exception.message)"
        exit
    }

    try {
        Rename-Item -Path "$NewPackageName\Source\Install-Template - only required if AppType is PS1.ps1" -NewName "$Name.ps1" -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "$($env:computername.ToUpper()) : $($_.Exception.message)"
        exit
    }

    Write-Host ''
    Write-Host '-----------------------------------------------------------------------' -ForegroundColor cyan
    Write-Host ' New package folder created' -ForegroundColor Yellow
    Write-Host
    Write-Host ' Next Steps:-'
    Write-Host
    Write-Host ' 1. Copy the package content into ' -nonewline
    Write-Host $NewPackageName'\Source' -ForegroundColor green
    Write-Host ' 2. Copy the logo png file into ' -nonewline
    Write-Host $NewPackageName -ForegroundColor green
    Write-Host " 3. Run .\init-config.ps1 -Name $Name"
    Write-Host '-----------------------------------------------------------------------' -ForegroundColor cyan
    Write-Host ''
}



function Remove-IntuneApplicationList {
    <#
    .SYNOPSIS
    Removes a list of Intune Applications
    .PARAMETER JSONFileList
    The list of json files that contain the Intune Applications to remove
    .EXAMPLE
    $jsonFileList = Get-ChildItem -Path .\JSON\DeviceConfiguration\ | Select -ExpandProperty FullName
    Remove-IntuneApplicationList -JSONFileList $jsonFileList

    In this example, the list of json files is created with the Get-ChildItem cmdlet and the
    results are passed directly to the Remove-IntuneApplicationList for processing
    #>
    [cmdletbinding()]
    param (
        [Parameter(Mandatory)]
        [string[]] $JSONFileList
    )

    Write-Host "`nIntune Applications:"

    foreach ($JSONFile in $JSONFileList) {

        $IntuneApplicationJSON = Get-JSONContent -JSONFile $JSONFile -ExcludeProperty 'id','createdDateTime','lastModifiedDateTime','priority'

        if (Test-IntuneApplication -DisplayName $IntuneApplicationJSON.displayName) {
            Write-Host '  Removing:' $IntuneApplicationJSON.DisplayName -f Red

            $appConfiguration = Get-IntuneApplication -DisplayName $IntuneApplicationJSON.displayName

            $apiVersion = 'beta'
            $resource = "deviceAppManagement/mobileApps/$($appConfiguration.Id)"

            try {
                $uri = "$($script:settings.graphURL)/$apiVersion/$resource"
                Invoke-MgGraphRequest -Method Delete -Uri $uri
            }
            catch {
                New-Exception -Exception $_.Exception
            }
        }
        else {
            Write-Host '  Not Found:' $IntuneApplicationJSON.DisplayName -ForegroundColor Yellow
        }
    }
}


function Remove-NewStoreAppsAADGroupAssignmentList {
    <#
    .SYNOPSIS
    Removes a list of Intune Applications
    .PARAMETER JSONFileList
    The list of json files that contain the Intune Applications to remove
    .EXAMPLE
    $jsonFileList = Get-ChildItem -Path .\JSON\DeviceConfiguration\ | Select -ExpandProperty FullName
    Remove-NewStoreAppsAADGroupAssignmentList -JSONFileList $jsonFileList

    In this example, the list of json files is created with the Get-ChildItem cmdlet and the
    results are passed directly to the Remove-NewStoreAppsAADGroupAssignmentList for processing
    #>
    [cmdletbinding()]
    param (
        [Parameter(Mandatory)]
        [string[]] $JSONFileList
    )

    Write-Host "`nIntune Store App:"

    foreach ($JSONFile in $JSONFileList) {
        $appAssignmentJSON = Get-JSONContent -JSONFile $JSONFile

        If($appAssignmentJSON."@odata.type" -eq  "#microsoft.graph.officeSuiteApp" -or $appAssignmentJSON."@odata.type" -eq  "#microsoft.graph.windowsMicrosoftEdgeApp" ){

            if (Test-IntuneApplication -DisplayName $appAssignmentJSON.displayName) {
                Write-Host '  Removing:' $appAssignmentJSON.DisplayName -f Red

                $intuneApplication = Get-IntuneApplication -DisplayName $appAssignmentJSON.displayName

                $apiVersion = 'beta'
                $resource = "deviceAppManagement/mobileApps/$($intuneApplication.Id)"

                try {
                    $uri = "$($script:settings.graphURL)/$apiVersion/$resource"
                    Invoke-MgGraphRequest -Method Delete -Uri $uri
                }
                catch {
                    New-Exception -Exception $_.Exception
                }
            }
            else {
                Write-Host '  Not Found:' $appAssignmentJSON.DisplayName -ForegroundColor Yellow
            }

        }else{
            $appList = Get-Content -Path $JSONFile | ConvertFrom-Json

            #TEST $app = $appList[0]
            #TEST $app = $appList[1]
            foreach ($app in $appList) {

                if (Test-IntuneApplication -DisplayName $app.packageName) {
                    Write-Host '  Removing:' $app.packageName -f Red

                    $appConfiguration = Get-IntuneApplication -DisplayName $app.packageName

                    $apiVersion = 'beta'
                    $resource = "deviceAppManagement/mobileApps/$($appConfiguration.Id)"

                    try {
                        $uri = "$($script:settings.graphURL)/$apiVersion/$resource"
                        Invoke-MgGraphRequest -Method Delete -Uri $uri
                    }
                    catch {
                        New-Exception -Exception $_.Exception
                    }
                }
                else {
                    Write-Host '  Not Found:' $app.packageName -ForegroundColor Yellow
                }
            }
        }

    }
}


function Set-IntuneApplication {
    <#
    .PARAMETER PackagePath
    The path to package folder containing Config.xml file
    .PARAMETER intuneWinAppUtilPath
    The folder path containing IntuneWinAppUtil.exe
    #>
    [CmdLetBinding()]
    param(
        [Parameter(Mandatory)]
        [psobject] $AppManifest,

        [Parameter()]
        [string] $intuneWinAppUtilPath = "$PSScriptRoot\..\..\private\utilities\IntuneWinAppUtil.exe",

        [Parameter()]
        [string]$IntuneAppProjectPath = $script:settings.IntuneAppPath
    )

    #### THIS sets a bunchd of scriopt level  variables that needs to go
    # Just read the fiel as [xml] and pass the object to the functions
    #Get-XMLConfig -XMLFile "$PackagePath\Config.xml"

    #[xml] $config = Get-XMLConfig -XMLFile "$PackagePath\Config.xml"

    if ( $AppManifest.AppType -eq "Edge" ) {

        $RuleType = 'skip'
        $ReturnCodeType = 'skip'
        $InstallExperience = 'skip'
        $LogoFile = 'skip'
    }
    else {
        if ( ( $AppManifest.AppType -eq "EXE" ) -or ( $AppManifest.AppType -eq "MSI" ) ) {
        }
        if ($RuleType -eq "FILE") {
        }
    }

    $AppManifest.packagePath = "$($IntuneAppProjectPath)\$($AppManifest.packageName)"

    if ( $AppManifest.AppType -ne "Edge" ) {
        Invoke-IntuneWinAppUtil -AppType $AppManifest.appType -IntuneWinAppPath $IntuneWinAppUtilPath -PackageSourcePath $AppManifest.packagePath -IntuneAppPackage $AppManifest.packageName

        if ( $script:exitCode -eq "-1" ) {
            Write-Log -Message "Error - from IntuneWin, exiting."
            exit
        }
    }

    #New-IntuneApplicationPackage -AppType $AppManifest.appType -RuleType $AppManifest.RuleType -ReturnCodeType $AppManifest.returnCodeType -InstallExperience $AppManifest.installExperience -Logo $AppManifest.logoFile -AADGroupName $AADGroupName
    # Create the needed groups
  #  foreach($group in @($AppManifest.requiredgroup, $AppManifest.availablegroup, $AppManifest.uninstallGroup)) {
   #     if(-Not (Get-MgGroup -Filter "DisplayName eq '$group'")){
    #       # $groupObject = Get-CSMGroup -Id $group
     #       $null = New-IntuneAppGroup -AppManifest $AppManifest -group $group
      #  }
   # }

 #  if ($CoreApp -eq $true){
  #  foreach($group in @($AppManifest.requiredgroup, $AppManifest.availablegroup, $AppManifest.uninstallGroup)) {
  #      $exists = Test-AADGroup -NameId $group
  #      if($exists -eq $false){
  #          $groupObject = Get-CSMGroup -Id $group
  #          $null = Set-AADGroup -GroupObject $groupObject
  #      }
 #   }}
    $groups = $IntuneAppProjectPath+"\"+$($AppManifest.packageName)+"\groups.json"
        Import-aadgrouplist -JSONFileList $groups

    $app = $IntuneAppProjectPath+"\"+$($AppManifest.packageName)+"\config.json"
    Write-Log -Message "`n Intune Win32 Applications:" -WriteHost White


    New-IntuneApplicationPackage -AppManifest $AppManifest


    if ( $script:exitCode -eq "-1" ) {
        Write-Log -Message "Error - from New-IntuneApplicationPackage, exiting."
        exit
    }

    Remove-Item -Path "$($AppManifest.packagePath)\IntuneWin" -Recurse -Force

    return $script:exitCode
}



function Set-IntuneApplicationAssignment
{
    <#
    .SYNOPSIS
    Add an assignment to a Win32 app.
    .DESCRIPTION
    Add an assignment to a Win32 app.
    .PARAMETER ID
    Specify the ID for a Win32 application.
    .PARAMETER Target
    Specify the target of the assignment, either AllUsers, AllDevices or Group.
    .PARAMETER Intent
    Specify the intent of the assignment, either required or available.
    .PARAMETER TargetGroupId
    Specify the ID for an Azure AD group.
    .PARAMETER Notification
    Specify the notification setting for the assignment of the Win32 app.
    .PARAMETER Available
    Specify a date time object for the availability of the assignment.
    .PARAMETER Deadline
    Specify a date time object for the deadline of the assignment.
    .PARAMETER UseLocalTime
    Specify to use either UTC of device local time for the assignment, set to 'True' for device local time and 'False' for UTC.
    .PARAMETER DeliveryOptimizationPriority
    Specify to download content in the background using default value of 'notConfigured', or set to download in foreground using 'foreground'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [guid] $ApplicationID,

        [Parameter()]
        [ValidateSet('AllUsers', 'AllDevices', 'Group')]
        [string] $Target = 'Group',

        [Parameter()]
        [switch] $Exclude,

        [Parameter()]
        [ValidateSet('Required', 'Available', 'Uninstall')]
        [string] $Intent = 'Available',

        [Parameter()]
        [ValidateSet('Win32', 'Store', 'Edge', 'winGet')]
        [string] $AppType = 'Win32',

        [Parameter()]
        [ValidateSet('User', 'Device')]
        [string] $LicenseType = 'User',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [guid] $TargetGroupId,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [ValidateSet('ShowAll', 'ShowReboot', 'HideAll')]
        [string] $Notification = 'ShowAll',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [datetime] $Available,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [datetime] $Deadline,

        [Parameter()]
        [switch] $UseLocalTime,

        [Parameter()]
        [ValidateSet('NotConfigured', 'Foreground')]
        [string] $DeliveryOptimizationPriority = 'NotConfigured'
    )
    begin
    {

        # Validate group identifier is passed as input if target is set to Group
        if ($Target -like "Group")
        {
            if (-not($PSBoundParameters["TargetGroupId"]))
            {
                Write-Warning -Message "Validation failed for parameter input, target set to Group but TargetGroupId parameter was not specified"; break
            }
        }

        # Validate that Available parameter input datetime object is in the past if the Deadline parameter is not passed on the command line
        if ($PSBoundParameters["Available"])
        {
            if (-not($PSBoundParameters["Deadline"]))
            {
                if ($Available -gt (Get-Date).AddDays(-1))
                {
                    Write-Warning -Message "Validation failed for parameter input, available date time needs to be before the current used 'as soon as possible' deadline date and time, with a offset of 1 day"; break
                }
            }
        }

        # Validate that Deadline parameter input datetime object is in the future if the Available parameter is not passed on the command line
        if ($PSBoundParameters["Deadline"])
        {
            if (-not($PSBoundParameters["Available"]))
            {
                if ($Deadline -lt (Get-Date))
                {
                    Write-Warning -Message "Validation failed for parameter input, deadline date time needs to be after the current used 'as soon as possible' available date and time"; break
                }
            }
        }
    }
    process
    {

        # Determine target property body based on parameter input
        $targetAssignment = @{
        }

        switch ($Target)
        {
            'AllUsers'
            {
                $targetAssignment.Add("@odata.type",'#microsoft.graph.allLicensedUsersAssignmentTarget')
            }
            'AllDevices'
            {
                $targetAssignment.Add("@odata.type",'#microsoft.graph.allDevicesAssignmentTarget')
            }
            'Group'
            {
                if($Exclude)
                {
                    $targetAssignment.Add("@odata.type",'#microsoft.graph.exclusionGroupAssignmentTarget')
                    $targetAssignment.Add('groupId', $TargetGroupId)
                } else
                {
                    $targetAssignment.Add("@odata.type",'#microsoft.graph.groupAssignmentTarget')
                    $targetAssignment.Add('groupId', $TargetGroupId)
                }
            }
        }

        $Win32AppAssignmentBody = [ordered]@{
            '@odata.type' = '#microsoft.graph.mobileAppAssignment'
            intent        = $Intent
            source        = 'direct'
            target        = $targetAssignment
        }

        switch ($AppType)
        {
            'Win32'
            {
                if (-not $Exclude)
                {
                    $Win32AppAssignmentBody.add('settings', @{
                            '@odata.type'                = '#microsoft.graph.win32LobAppAssignmentSettings'
                            notifications                = $Notification
                            restartSettings              = $null
                            deliveryOptimizationPriority = $DeliveryOptimizationPriority
                            installTimeSettings          = $null
                        }
                    )
                }
                break
            }
            'Store'
            {
                $Win32AppAssignmentBody.add('settings', @{
                        '@odata.type'    = '#microsoft.graph.microsoftStoreForBusinessAppAssignmentSettings'
                        useDeviceContext = $false
                    })
                if ($LicenseType -eq "Device")
                {
                    $Win32AppAssignmentBody.settings.useDeviceContext = $true
                }
                break
            }
            'Edge'
            {
                $Win32AppAssignmentBody.add('settings', $null )
            }
            'winGet' {
                $Win32AppAssignmentBody.add('settings', @{
                    '@odata.type'                = '#microsoft.graph.winGetAppAssignmentSettings'
                    notifications                = $Notification
                    restartSettings              = $null
                    installTimeSettings          = $null
                }
                )
                break
            }
        }

        # Amend installTimeSettings property if Available parameter is specified
        if (($PSBoundParameters["Available"]) -and (-not($PSBoundParameters["Deadline"])))
        {
            $Win32AppAssignmentBody.settings.installTimeSettings = @{
                "useLocalTime"     = $UseLocalTime
                "startDateTime"    = (ConvertTo-JSONDate -InputObject $Available)
                "deadlineDateTime" = $null
            }
        }

        # Amend installTimeSettings property if Deadline parameter is specified
        if (($PSBoundParameters["Deadline"]) -and (-not($PSBoundParameters["Available"])))
        {
            $Win32AppAssignmentBody.settings.installTimeSettings = @{
                "useLocalTime"     = $UseLocalTime
                "startDateTime"    = $null
                "deadlineDateTime" = (ConvertTo-JSONDate -InputObject $Deadline)
            }
        }

        # Amend installTimeSettings property if Available and Deadline parameter is specified
        if (($PSBoundParameters["Available"]) -and ($PSBoundParameters["Deadline"]))
        {
            $Win32AppAssignmentBody.settings.installTimeSettings = @{
                "useLocalTime"     = $UseLocalTime
                "startDateTime"    = (ConvertTo-JSONDate -InputObject $Available)
                "deadlineDateTime" = (ConvertTo-JSONDate -InputObject $Deadline)
            }
        }

        try
        {
            $apiVersion = 'beta'
            $resource = "deviceAppManagement/mobileApps/$ApplicationID/assignments"

            $jsonBody = $Win32AppAssignmentBody | ConvertTo-Json -Depth 3

            $uri = "$($script:settings.graphURL)/$apiVersion/$resource"
            $null = Invoke-MgGraphRequest -Method Post -Uri $uri -Body $jsonBody -ContentType 'application/json'
        }
        catch [System.Exception]{
            Write-Warning -Message "An error occurred while creating a $AppType app assignment: $($TargetFilePath). Error message: $($_.Exception.Message)"
        }
    }
}


function Set-IntuneNewStoreApplication {
    <#
    .SYNOPSIS
    This function is used to add an app from Microsoft store new from the Graph API REST interface
    .DESCRIPTION
    The function connects to the Graph API Interface and adds an app from Microsoft store new
    .EXAMPLE
    Set-IntuneNewStoreApplication -Name $Name -AppId $id
    #>
    [cmdletbinding()]
    param (
        [Parameter(Mandatory)]
        [string] $Name,
        [Parameter(Mandatory)]
        [string] $AppId
    )

    $apiVersion = 'beta'
    $resource = 'deviceAppManagement/mobileApps'

    $body = @{
        '@odata.type' = '#microsoft.graph.winGetApp'
        displayName	  = $Name
        packageIdentifier = $AppId
        installExperience = @{
            "runAsAccount"= "user"
        }
    } | ConvertTo-Json

    try {
        $uri = "$($script:settings.graphURL)/$apiVersion/$resource"
        Invoke-MgGraphRequest -Method Post -Uri $uri -Body $body -ContentType 'application/json'
    }
    catch {
        New-Exception -Exception $_.Exception
    }
}


function Set-IntuneOfficeSuiteApp {
    <#
    .SYNOPSIS
    This function is used to add an app from Microsoft store new from the Graph API REST interface
    .DESCRIPTION
    The function connects to the Graph API Interface and adds an app from Microsoft store new
    .EXAMPLE
    Set-IntuneOfficeSuiteApplication -Name $Name -AppId $id
    #>
    [cmdletbinding()]
    param (
        [Parameter(Mandatory)]
        [psobject] $AppManifest
    )

    $apiVersion = 'beta'
    $resource = 'deviceAppManagement/mobileApps'


    $body = $AppManifest | ConvertTo-Json -Depth 5
    #write-host $body
    try {
        $uri = "$($script:settings.graphURL)/$apiVersion/$resource"
        Invoke-MgGraphRequest -Method Post -Uri $uri -Body $body -ContentType 'application/json'
    }
    catch {
        New-Exception -Exception $_.Exception
    }
}



function Set-IntuneOfficeSuiteAppAssignment {
    <#
    .SYNOPSIS
    This function is used to assign a Office suite App within Intune to a given AAD group
    .DESCRIPTION
    This function is used to assign a Office suite App within Intune to a given AAD group
    .PARAMETER SId

    .PARAMETER AssignmentID

    #>
    [cmdletbinding()]
    param (
        [Parameter(Mandatory)]
        [string] $AppId,

        [Parameter(Mandatory)]
        [guid] $AssignmentId,

        [Parameter(Mandatory)]
        [ValidateSet('required','available','uninstall')]
        [string] $AssignType
    )

    $apiVersion = 'beta'
    $resource = "deviceAppManagement/mobileApps/$AppId/assignments"

    $body = @{
        #mobileAppAssignments = @(
         #   @{
                "@odata.type"= "#microsoft.graph.mobileAppAssignment"
                intent = $AssignType
                target = @{
                    '@odata.type' = '#microsoft.graph.groupAssignmentTarget'
                    deviceAndAppManagementAssignmentFilterId = $null
                    deviceAndAppManagementAssignmentFilterType= "none"
                    groupId = $AssignmentId
                }
            #}
        #)

    } | ConvertTo-Json -Depth 5

    try {
        $uri = "$($script:settings.graphURL)/$apiVersion/$resource"
        Invoke-MgGraphRequest -Method Post -Uri $uri -Body $body -ContentType 'application/json'
    }
    catch {
        New-Exception -Exception $_.Exception
    }
}


function Test-IntuneApplication {
    <#
    .SYNOPSIS
    A simple function that looks for the Intune application and returns $true is found
    $false if not found
    .NOTES
    Long term this will do a deep comparison of the template and what is deployed
    in the customer tenant
    #>

    [OutputType([bool])]
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string] $DisplayName
    )

    if (Get-IntuneApplication -DisplayName $DisplayName) {
        return $true
    }
    return $false
}