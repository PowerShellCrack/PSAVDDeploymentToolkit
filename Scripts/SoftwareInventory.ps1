Function Get-VersionInfo {
    [CmdletBinding()]
    param (
        [parameter(Mandatory=$true)] 
        [ValidateNotNullOrEmpty()] 
        [System.IO.FileInfo] $FilePath
    )
    Begin{}
    Process{
        if (!(Test-Path $FilePath.FullName)) { 
            throw "File '{0}' does not exist" -f $FilePath.FullName 
        }
        Write-Verbose ("Getting version of file: {0}" -f $FilePath.FullName)
        switch($FilePath.Extension){
            '.msi' {
                $Version = Get-MsiInfo -Path $FilePath.FullName -Property ProductVersion
            }
    
            '.exe' {
                $Version = (Get-ItemProperty $FilePath.FullName).VersionInfo.ProductVersion
            }
        }
    }
    end{return $Version.Trim() }

}


Function Get-MsiInfo {
    [CmdletBinding()]
    Param(
        [parameter(Mandatory=$true)]
        [IO.FileInfo]$Path,

        [parameter(Mandatory=$true)]
        [ValidateSet("ProductCode","ProductVersion","ProductName")]
        [string]$Property

    )

    Write-Verbose ("Fetching {0} from msi [{1}]" -f $Property,$Path)
    try {
        $WindowsInstaller = New-Object -ComObject WindowsInstaller.Installer
        $MSIDatabase = $WindowsInstaller.GetType().InvokeMember("OpenDatabase","InvokeMethod",$Null,$WindowsInstaller,@($Path.FullName,0))
        $Query = "SELECT Value FROM Property WHERE Property = '$($Property)'"
        $View = $MSIDatabase.GetType().InvokeMember("OpenView","InvokeMethod",$null,$MSIDatabase,($Query))
        $View.GetType().InvokeMember("Execute", "InvokeMethod", $null, $View, $null)
        $Record = $View.GetType().InvokeMember("Fetch","InvokeMethod",$null,$View,$null)
        $Value = $Record.GetType().InvokeMember("StringData","GetProperty",$null,$Record,1)
        Write-Verbose ("{0} is: {1}" -f $Property,$Value)
    }
    catch {
        Write-Error ("Error trying to retrieve installer info from {0}. {1}" -f $Path,$_.Exception.Message)
    }Finally{
        Remove-Variable $WindowsInstaller -ErrorAction SilentlyContinue
    }
    return $Value
}

Function Wait-FileUnlock {
    Param(
        [Parameter()]
        [IO.FileInfo]$File,
        [int]$SleepInterval=500
    )
    while(1){
        try{
            $fs=$file.Open('open','read', 'Read')
            $fs.Close()
            Write-Verbose "$file not open"
        }
        catch{
           Start-Sleep -Milliseconds $SleepInterval
        }
	}
}

Function IsFileLocked {
    param(
        [Parameter(Mandatory=$true)]
        [string]$filePath
    )

    Rename-Item $filePath $filePath -ErrorVariable errs -ErrorAction SilentlyContinue
    return ($errs.Count -ne 0)
}

Function Get-FileSize{
    param(
        [Parameter(Mandatory=$true)]
        [string]$filePath
    )

    $result = Get-ChildItem $filePath | Measure-Object length -Sum | % {
        New-Object psobject -prop @{
            Size = $(
                switch ($_.sum) {
                    {$_ -gt 1tb} { '{0:N2}TB' -f ($_ / 1tb); break }
                    {$_ -gt 1gb} { '{0:N2}GB' -f ($_ / 1gb); break }
                    {$_ -gt 1mb} { '{0:N2}MB' -f ($_ / 1mb); break }
                    {$_ -gt 1kb} { '{0:N2}KB' -f ($_ / 1Kb); break }
                    default { '{0}B ' -f $_ }
                }
            )
        }
    }

    $result | Select-Object -ExpandProperty Size
}


function Get-InstalledSoftware {
    <#
    .SYNOPSIS
        Retrieves a list of all software installed
    .PARAMETER Name
        The software title you'd like to limit the query to.

    .PARAMETER IncludeExeTypes 
        Inlcudes non MSI instaled apps

    .EXAMPLE
        Get-InstalledSoftware

        This example retrieves all software installed on the local computer
    
    .EXAMPLE
        Get-InstalledSoftware -IncludeExeTypes

        This example retrieves all software installed on the local computer
    #>
    [OutputType([System.Management.Automation.PSObject])]
    [CmdletBinding()]
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Name,
        [switch]$IncludeExeTypes
    )

    $UninstallKeys = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall", "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    $null = New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS
    $UninstallKeys += Get-ChildItem HKU: -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'S-\d-\d+-(\d+-){1,14}\d+$' } | ForEach-Object { "HKU:\$($_.PSChildName)\Software\Microsoft\Windows\CurrentVersion\Uninstall" }
    if (-not $UninstallKeys) {
        Write-Verbose 'No software registry keys found'
    } else {
        foreach ($UninstallKey in $UninstallKeys) {

            If($PSBoundParameters.ContainsKey('Name')){
                $NameFilter = "$Name*"
            }Else{
                $NameFilter = "*"
            }

            if ($PSBoundParameters.ContainsKey('IncludeExeTypes')) {
                $WhereBlock = { ($_.PSChildName -like '*') -and ($_.GetValue('DisplayName') -like $NameFilter) -and (-Not[string]::IsNullOrEmpty($_.GetValue('DisplayName'))) }
            } else {
                $WhereBlock = { ($_.PSChildName -match '^{[A-Z0-9]{8}-([A-Z0-9]{4}-){3}[A-Z0-9]{12}}$') -and ($_.GetValue('DisplayName') -like $NameFilter) -and (-Not[string]::IsNullOrEmpty($_.GetValue('DisplayName'))) }
            }
            $gciParams = @{
                Path        = $UninstallKey
                ErrorAction = 'SilentlyContinue'
            }
            $selectProperties = @(
                @{n='Name'; e={$_.GetValue('DisplayName')}},
                @{n='GUID'; e={$_.PSChildName}},
                @{n='Version'; e={$_.GetValue('DisplayVersion')}},
                @{n='Uninstall'; e={$_.GetValue('UninstallString')}}
            )
            
            Get-ChildItem @gciParams | Where $WhereBlock | Select-Object -Property $selectProperties
        }
    }
}


Function Test-ApplicationDetection {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        $ApplicationObject
    )

    If($ApplicationObject.detectionType){
        $DetectedApp = Get-InstalledSoftware -Name $ApplicationObject.productName -IncludeExeTypes
        
        Try{
            switch($ApplicationObject.detectionType){
                'productName' {
                    
                    If( $DetectedApp ){
                        Write-Verbose ("Application [{0} ({1})] is installed..." -f $DetectedApp.Name,$DetectedApp.Version)
                        Return $true
                    }
                }
                'exeVersion'{
                    If( $DetectedApp.Version -eq (Get-VersionInfo ($ApplicationObject.Localpath + '\' + $ApplicationObject.fileName)) ){
                        Write-Verbose ("Application [{0} ({1})] is installed..." -f $DetectedApp.Name,$DetectedApp.Version)
                        Return $true
                    }
                }
                'msiGuid' {
                    #get local installed guid compared to installer file guid
                    If( $DetectedApp.GUID -eq (Get-MsiInfo -Path ($ApplicationObject.Localpath + '\' + $ApplicationObject.fileName) -Property ProductCode) ){
                        Write-Verbose ("Guid [{2}] as application [{0} ({1})] is installed..." -f $DetectedApp.Name,$DetectedApp.Version,$DetectedApp.GUID)
                        Return $true
                    }
                }
                'msiVersion' {
                    #get local installed version compared to installer file version
                    If( $DetectedApp.Version -eq (Get-MsiInfo ($ApplicationObject.Localpath + '\' + $ApplicationObject.fileName) -Property ProductVersion) ){
                        Write-Verbose ("Application [{0} ({1})] is installed..." -f $DetectedApp.Name,$DetectedApp.Version)
                        Return $true
                    }
                }
                'fileExists' {
                    If( Test-Path $ApplicationObject.detectionPath -PathType Leaf){
                        Write-Verbose ("Found [{0}]..." -f $ApplicationObject.productName)
                        Return $true
                    }
                }
                'folderExists' {
                    If( Test-Path $ApplicationObject.detectionPath -PathType Container){
                        Write-Verbose ("Found [{0}]..." -f $ApplicationObject.productName)
                        Return $true
                    }
                }
                default {
                    Write-Verbose ("Application [{0}] not detected" -f $ApplicationObject.productName)
                    Return $false
                }
            }
        }Catch{
            Write-Verbose ("Unable to detect application [{0}]: {1}" -f $ApplicationObject.productName, $_.Exception.Message)
            Return $false
        }
    }Else{
        Return $false
    }
    
}

Function Get-FriendlyMsiExecMsg($exit) {
    Switch($exit){
      0    {$meaning = 'ERROR_SUCCESS'; $description = 'The action completed successfully.'}
      13   {$meaning = 'ERROR_INVALID_DATA'; $description = 'The data is invalid.'}
      87   {$meaning = 'ERROR_INVALID_PARAMETER'; $description = 'One of the parameters was invalid.'}
      120  {$meaning = 'ERROR_CALL_NOT_IMPLEMENTED'; $description = 'This value is returned when a custom action attempts to call a function that cannot be called from custom actions. The function returns the value ERROR_CALL_NOT_IMPLEMENTED. Available beginning with Windows Installer version 3.0.'}
      1259 {$meaning = 'ERROR_APPHELP_BLOCK'; $description = 'If Windows Installer determines a product may be incompatible with the current operating system, it displays a dialog box informing the user and asking whether to try to install anyway. This error code is returned if the user chooses not to try the installation.'}
      1601 {$meaning = 'ERROR_INSTALL_SERVICE_FAILURE'; $description = 'The Windows Installer service could not be accessed. Contact your support personnel to verify that the Windows Installer service is properly registered.'}
      1602 {$meaning = 'ERROR_INSTALL_USEREXIT'; $description = 'The user cancels installation.'}
      1603 {$meaning = 'ERROR_INSTALL_FAILURE'; $description = 'A fatal error occurred during installation.'}
      1604 {$meaning = 'ERROR_INSTALL_SUSPEND'; $description = 'Installation suspended, incomplete.'}
      1605 {$meaning = 'ERROR_UNKNOWN_PRODUCT'; $description = 'This action is only valid for products that are currently installed.'}
      1606 {$meaning = 'ERROR_UNKNOWN_FEATURE'; $description = 'The feature identifier is not registered.'}
      1607 {$meaning = 'ERROR_UNKNOWN_COMPONENT'; $description = 'The component identifier is not registered.'}
      1608 {$meaning = 'ERROR_UNKNOWN_PROPERTY'; $description = 'This is an unknown property.'}
      1609 {$meaning = 'ERROR_INVALID_HANDLE_STATE'; $description = 'The handle is in an invalid state.'}
      1610 {$meaning = 'ERROR_BAD_CONFIGURATION'; $description = 'The configuration data for this product is corrupt. Contact your support personnel.'}
      1611 {$meaning = 'ERROR_INDEX_ABSENT'; $description = 'The component qualifier not present.'}
      1612 {$meaning = 'ERROR_INSTALL_SOURCE_ABSENT'; $description = 'The installation source for this product is not available. Verify that the source exists and that you can access it.'}
      1613 {$meaning = 'ERROR_INSTALL_PACKAGE_VERSION'; $description = 'This installation package cannot be installed by the Windows Installer service. You must install a Windows service pack that contains a newer version of the Windows Installer service.'}
      1614 {$meaning = 'ERROR_PRODUCT_UNINSTALLED'; $description = 'The product is uninstalled.'}
      1615 {$meaning = 'ERROR_BAD_QUERY_SYNTAX'; $description = 'The SQL query syntax is invalid or unsupported.'}
      1616 {$meaning = 'ERROR_INVALID_FIELD'; $description = 'The record field does not exist.'}
      1618 {$meaning = 'ERROR_INSTALL_ALREADY_RUNNING'; $description = 'Another installation is already in progress. Complete that installation before proceeding with this install.'}
      1619 {$meaning = 'ERROR_INSTALL_PACKAGE_OPEN_FAILED'; $description = 'This installation package could not be opened. Verify that the package exists and is accessible, or contact the application vendor to verify that this is a valid Windows Installer package.'}
      1620 {$meaning = 'ERROR_INSTALL_PACKAGE_INVALID'; $description = 'This installation package could not be opened. Contact the application vendor to verify that this is a valid Windows Installer package.'}
      1621 {$meaning = 'ERROR_INSTALL_UI_FAILURE'; $description = 'There was an error starting the Windows Installer service user interface. Contact your support personnel.'}
      1622 {$meaning = 'ERROR_INSTALL_LOG_FAILURE'; $description = 'There was an error opening installation log file. Verify that the specified log file location exists and is writable.'}
      1623 {$meaning = 'ERROR_INSTALL_LANGUAGE_UNSUPPORTED'; $description = 'This language of this installation package is not supported by your system.'}
      1624 {$meaning = 'ERROR_INSTALL_TRANSFORM_FAILURE'; $description = 'There was an error applying transforms. Verify that the specified transform paths are valid.'}
      1625 {$meaning = 'ERROR_INSTALL_PACKAGE_REJECTED'; $description = 'This installation is forbidden by system policy. Contact your system administrator.'}
      1626 {$meaning = 'ERROR_FUNCTION_NOT_CALLED'; $description = 'The function could not be executed.'}
      1627 {$meaning = 'ERROR_FUNCTION_FAILED'; $description = 'The function failed during execution.'}
      1628 {$meaning = 'ERROR_INVALID_TABLE'; $description = 'An invalid or unknown table was specified.'}
      1629 {$meaning = 'ERROR_DATATYPE_MISMATCH'; $description = 'The data supplied is the wrong type.'}
      1630 {$meaning = 'ERROR_UNSUPPORTED_TYPE'; $description = 'Data of this type is not supported.'}
      1631 {$meaning = 'ERROR_CREATE_FAILED'; $description = 'The Windows Installer service failed to start. Contact your support personnel.'}
      1632 {$meaning = 'ERROR_INSTALL_TEMP_UNWRITABLE'; $description = 'The Temp folder is either full or inaccessible. Verify that the Temp folder exists and that you can write to it.'}
      1633 {$meaning = 'ERROR_INSTALL_PLATFORM_UNSUPPORTED'; $description = 'This installation package is not supported on this platform. Contact your application vendor.'}
      1634 {$meaning = 'ERROR_INSTALL_NOTUSED'; $description = 'Component is not used on this machine.'}
      1635 {$meaning = 'ERROR_PATCH_PACKAGE_OPEN_FAILED'; $description = 'This patch package could not be opened. Verify that the patch package exists and is accessible, or contact the application vendor to verify that this is a valid Windows Installer patch package.'}
      1636 {$meaning = 'ERROR_PATCH_PACKAGE_INVALID'; $description = 'This patch package could not be opened. Contact the application vendor to verify that this is a valid Windows Installer patch package.'}
      1637 {$meaning = 'ERROR_PATCH_PACKAGE_UNSUPPORTED'; $description = 'This patch package cannot be processed by the Windows Installer service. You must install a Windows service pack that contains a newer version of the Windows Installer service.'}
      1638 {$meaning = 'ERROR_PRODUCT_VERSION'; $description = 'Another version of this product is already installed. Installation of this version cannot continue. To configure or remove the existing version of this product, use Add/Remove Programs in Control Panel.'}
      1639 {$meaning = 'ERROR_INVALID_COMMAND_LINE'; $description = 'Invalid command line argument. Consult the Windows Installer SDK for detailed command-line help.'}
      1640 {$meaning = 'ERROR_INSTALL_REMOTE_DISALLOWED'; $description = 'The current user is not permitted to perform installations from a client session of a server running the Terminal Server role service.'}
      1641 {$meaning = 'ERROR_SUCCESS_REBOOT_INITIATED'; $description = 'The installer has initiated a restart. This message is indicative of a success.'}
      1642 {$meaning = 'ERROR_PATCH_TARGET_NOT_FOUND'; $description = 'The installer cannot install the upgrade patch because the program being upgraded may be missing or the upgrade patch updates a different version of the program. Verify that the program to be upgraded exists on your computer and that you have the correct upgrade patch.'}
      1643 {$meaning = 'ERROR_PATCH_PACKAGE_REJECTED'; $description = 'The patch package is not permitted by system policy.'}
      1644 {$meaning = 'ERROR_INSTALL_TRANSFORM_REJECTED'; $description = 'One or more customizations are not permitted by system policy.'}
      1645 {$meaning = 'ERROR_INSTALL_REMOTE_PROHIBITED'; $description = 'Windows Installer does not permit installation from a Remote Desktop Connection.'}
      1646 {$meaning = 'ERROR_PATCH_REMOVAL_UNSUPPORTED'; $description = 'The patch package is not a removable patch package. Available beginning with Windows Installer version 3.0.'}
      1647 {$meaning = 'ERROR_UNKNOWN_PATCH'; $description = 'The patch is not applied to this product. Available beginning with Windows Installer version 3.0.'}
      1648 {$meaning = 'ERROR_PATCH_NO_SEQUENCE'; $description = 'No valid sequence could be found for the set of patches. Available beginning with Windows Installer version 3.0.'}
      1649 {$meaning = 'ERROR_PATCH_REMOVAL_DISALLOWED'; $description = 'Patch removal was disallowed by policy. Available beginning with Windows Installer version 3.0.'}
      1650 {$meaning = 'ERROR_INVALID_PATCH_XML'; $description = 'The XML patch data is invalid. Available beginning with Windows Installer version 3.0.'}
      1651 {$meaning = 'ERROR_PATCH_MANAGED_ADVERTISED_PRODUCT'; $description = 'Administrative user failed to apply patch for a per-user managed or a per-machine application that is in advertise state. Available beginning with Windows Installer version 3.0.'}
      1652 {$meaning = 'ERROR_INSTALL_SERVICE_SAFEBOOT'; $description = 'Windows Installer is not accessible when the computer is in Safe Mode. Exit Safe Mode and try again or try using System Restore to return your computer to a previous state. Available beginning with Windows Installer version 4.0.'}
      1653 {$meaning = 'ERROR_ROLLBACK_DISABLED'; $description = 'Could not perform a multiple-package transaction because rollback has been disabled. Multiple-Package Installations cannot run if rollback is disabled. Available beginning with Windows Installer version 4.5.'}
      1654 {$meaning = 'ERROR_INSTALL_REJECTED'; $description = 'The app that you are trying to run is not supported on this version of Windows. A Windows Installer package, patch, or transform that has not been signed by Microsoft cannot be installed on an ARM computer.'}
      3010 {$meaning = 'ERROR_SUCCESS_REBOOT_REQUIRED'; $description = 'A restart is required to complete the install. This message is indicative of a success. This does not include installs where the ForceReboot action is run.'}
    }
    return ("[{0}] {1}" -f $meaning,$description)
}