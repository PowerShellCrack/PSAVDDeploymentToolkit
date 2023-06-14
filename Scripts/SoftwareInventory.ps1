Function Get-VersionInfo {
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
        switch($FilePath.Extension){
            '.msi' {
                try { 
                    $WindowsInstaller = New-Object -com WindowsInstaller.Installer 
                    $Database = $WindowsInstaller.GetType().InvokeMember("OpenDatabase", "InvokeMethod", $Null, $WindowsInstaller, @($FilePath.FullName, 0)) 
                    $Query = "SELECT Value FROM Property WHERE Property = 'ProductVersion'" 
                    $View = $database.GetType().InvokeMember("OpenView", "InvokeMethod", $Null, $Database, ($Query)) 
                    $View.GetType().InvokeMember("Execute", "InvokeMethod", $Null, $View, $Null) | Out-Null 
                    $Record = $View.GetType().InvokeMember( "Fetch", "InvokeMethod", $Null, $View, $Null ) 
                    $Version = $Record.GetType().InvokeMember( "StringData", "GetProperty", $Null, $Record, 1 ) 
                } catch { 
                    throw ("Failed to get MSI version: {0}." -f $_)
                }
            }
    
            '.exe' {
                $Version = (Get-ItemProperty $FilePath.FullName).VersionInfo.ProductVersion
            }
        }
    }
    end{return $Version }

}


Function Get-MSIInfo {
    param(
    [parameter(Mandatory=$true)]
    [IO.FileInfo]$Path,

    [parameter(Mandatory=$true)]
    [ValidateSet("ProductCode","ProductVersion","ProductName")]
    [string]$Property

    )
    try {
        $WindowsInstaller = New-Object -ComObject WindowsInstaller.Installer
        $MSIDatabase = $WindowsInstaller.GetType().InvokeMember("OpenDatabase","InvokeMethod",$Null,$WindowsInstaller,@($Path.FullName,0))
        $Query = "SELECT Value FROM Property WHERE Property = '$($Property)'"
        $View = $MSIDatabase.GetType().InvokeMember("OpenView","InvokeMethod",$null,$MSIDatabase,($Query))
        $View.GetType().InvokeMember("Execute", "InvokeMethod", $null, $View, $null)
        $Record = $View.GetType().InvokeMember("Fetch","InvokeMethod",$null,$View,$null)
        $Value = $Record.GetType().InvokeMember("StringData","GetProperty",$null,$Record,1)
        return $Value
        Remove-Variable $WindowsInstaller
    }
    catch {
        Write-Output $_.Exception.Message
    }

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