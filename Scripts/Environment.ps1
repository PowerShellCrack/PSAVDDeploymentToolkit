Function Test-IsISE {
    <#
    .SYNOPSIS
    Determines if script running in ISE
    
    .EXAMPLE
    Test-IsISE
    #>
    try {
        return ($null -ne $psISE);
    }
    catch {
        return $false;
    }
}
#endregion

#region FUNCTION: Check if running in Visual Studio Code
Function Test-VSCode{
    <#
    .SYNOPSIS
    Determines if script running in VScode
    
    .EXAMPLE
    Test-VSCode
    #>
    if($env:TERM_PROGRAM -eq 'vscode') {
        return $true;
    }
    Else{
        return $false;
    }
}
#endregion

function ConvertFrom-FixedColumnTable {
    <#
    .SYNOPSIS
        Converts string output to psobject
    
    .DESCRIPTION
        Converts string output in table format (with header) to psobject

    .PARAMETER InputObject
        Specify the input to convert. Accepts input only via the pipeline

    .EXAMPLE
        (winget list) -match '^\p{L}' | ConvertFrom-FixedColumnTable

        This example retrieves all software identified by winget

    .NOTES
    The input is assumed to have a header line whose column names to mark the start of each field
    #>
    [CmdletBinding()]
    param(
      [Parameter(ValueFromPipeline)] $InputObject
    )
    
    Begin {
        Set-StrictMode -Version 1
        $LineIndex = 0
         # data line
        $List = @()
    }
    Process {
        $lines = if ($InputObject.Contains("`n")) { $InputObject.TrimEnd("`r", "`n") -split '\r?\n' } else { $InputObject }

        foreach ($line in $lines) {
            ++$LineIndex
            Write-Verbose ("LINE [{1}]: {0}" -f $line,$LineIndex)
            if ($LineIndex -eq 1) { 
                # header line
                $headerLine = $line 
            }
            elseif ($LineIndex -eq 2 ) { 
                
                # separator line
                # Get the indices where the fields start.
                $fieldStartIndex = [regex]::Matches($headerLine, '\b\S').Index
                # Calculate the field lengths.
                $fieldLengths = foreach ($i in 1..($fieldStartIndex.Count-1)) { 
                $fieldStartIndex[$i] - $fieldStartIndex[$i - 1] - 1
                }
                # Get the column names
                $colNames = foreach ($i in 0..($fieldStartIndex.Count-1)) {
                    if ($i -eq $fieldStartIndex.Count-1) {
                        $headerLine.Substring($fieldStartIndex[$i]).Trim()
                    } else {
                        $headerLine.Substring($fieldStartIndex[$i], $fieldLengths[$i]).Trim()
                    }
                } 
            }
            else {
               
                $i = 0
                # ordered helper hashtable for object constructions.
                $ObjectHash = [ordered] @{} 
                foreach ($colName in $colNames) {
                    Write-Verbose ("COLUMN: {0}" -f $colName)
                    $ObjectHash[$colName] = 
                        if ($fieldStartIndex[$i] -lt $line.Length) {
                            if ($fieldLengths[$i] -and $fieldStartIndex[$i] + $fieldLengths[$i] -le $line.Length) {
                                $line.Substring($fieldStartIndex[$i], $fieldLengths[$i]).Trim()
                            }
                            else {
                                $line.Substring($fieldStartIndex[$i]).Trim()
                            }
                        }
                    ++$i
                }
                $List += [pscustomobject] $ObjectHash
            }
        }
    }End{
        # Convert the helper hashable to an object and output it.
        Return $List
    }
}


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



Function Get-GroupMembership {
    <#
    .SYNOPSIS
        Grabs group membership
    .DESCRIPTION
        Grabs group membership including Azure AD members
    .PARAMETER Computer
        Specify computer name. Default is localhost. Requires WinRM for remote host
    .PARAMETER Group
        Specify group name. Default is Administrators.
    .EXAMPLE
        Get-GroupMembership -Group 'FSLogix ODFC Exclude List'

        Gets list of user added to the 'FSLogix ODFC Exclude List' group
    .EXAMPLE
        Get-GroupMembership -Computer 'RemoteHost'

        Gets list of user added to the 'Administrators' group on device named 'remotehost'
    #>
    [cmdletbinding()]
    Param(
        [string]$Computer=$env:computername,
        [string]$Group='Administrators'
    )

    $query="Associators of {Win32_Group.Domain='$Computer',Name='$Group'} where Role=GroupComponent"

    write-verbose "Querying $computer"
    write-verbose $query
    $CIMParams = @{
        Query=$query
    }
    If($Computer -ne $env:computername){
        $CIMParams += @{
            ComputerName=$Computer
        }
    }

    Try{
        Get-CimInstance @CIMParams -ErrorAction Stop |
            Select @{Name="Member";Expression={$_.Caption}},Disabled,LocalAccount,
            @{Name="Type";Expression={([regex]"User|Group").matches($_.Class)[0].Value}},
            @{Name="Computername";Expression={$_.ComputerName.ToUpper()}},
            @{Name="Group";Expression={$group}}
    }
    Catch{
        Write-host ("Unable to query group {0}. {1}" -f $Group, $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Get-LocalAdministrators {  
    <#
    .SYNOPSIS
        Grabs local administrators
    .DESCRIPTION
        Grabs local administrators including Azure AD user SIDs
    .PARAMETER Computer
        Specify computer name. Default is localhost. Requires WinRM for remote host
    .EXAMPLE
        Get-GroupMembership

        Gets list of user part of the 'Administrators' group
    .EXAMPLE
        Get-GroupMembership -Computer 'RemoteHost'

        Gets list of user part of the 'Administrators' group on device named 'remotehost'
    #>
    [cmdletbinding()]
    Param(
        [string]$Computer=$env:computername
    )  

    $CIMParams = @{
        Class='win32_groupuser'
    }
    If($Computer -ne $env:computername){
        $CIMParams += @{
            Computer=$Computer
        }
    }

    Try{
        $admins = Get-CimInstance @CIMParams  
        $admins = $admins | Where-Object {$_.GroupComponent -like '*Administrators*'}  

        $admins | ForEach-Object {  
            $_.PartComponent -match ".+Name\ = (.+)\, Domain\ = (.+)$" > $null  
            #$_.PartComponent -match ".+Domain\=(.+)\,Name\=(.+)$" > $null  
            $matches[2].trim(')').trim('"') + "\" + $matches[1].trim('"')
        }
    }
    Catch{
        Write-host ("Unable to Local Administrators. {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }  
}

Function Expand-StringVariables{
    [cmdletbinding()]
    param (
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [PSCustomObject]$Object,
        [String]$Property,
        [switch]$IncludeVariables,
        [int]$MaxVariables=3,
        [switch]$ExpandProperty

    )
    
    #convert settings object to hashtable to easily enumerate
    $ReplaceKeyValues = @{}
    $Object.psobject.properties | Where TypeNameOfValue -eq 'System.String' | Foreach { $ReplaceKeyValues[$_.Name] = $_.Value }
    
    #Get all values within brackets
    $BracketVariables = ($Property |Select-String '(?<=\[)[^]]+(?=\])' -AllMatches).Matches.Value
    If($BracketVariables.count -gt 0){Write-Verbose ("Found bracket values: {0}" -f ($BracketVariables -join ','))}
    $cnt=0
    Foreach($VariableName in $BracketVariables){
        $cnt++
        #iterate through hashtable name and replace all matching keys with corrisponding values
        If($ReplaceKeyValues[$VariableName]){
            Write-Verbose ("Replacing bracket value [{0}] with object value: {1}" -f $VariableName,$ReplaceKeyValues[$VariableName])
            $Property = $Property.replace("[$VariableName]", $ReplaceKeyValues[$VariableName]) 
        }
            
        If($IncludeVariables){
            $VariableValue = (Get-Variable | Where Name -eq $VariableName).Value
            If($VariableValue){
                Write-Verbose ("Replacing value [{0}] with variable value: {1}" -f $VariableName,$VariableValue)
                $Property = $Property.replace("[$VariableName]", $VariableValue)
            }
        }
    }
    #Write-Verbose $cnt

    if ($cnt -lt $MaxVariables){
        #Attempt to do it again until all bracket names are completed
        $BracketVariables = ($Property |Select-String '(?<=\[)[^]]+(?=\])' -AllMatches).Matches.Value
        If($BracketVariables.count -gt 0){
            $Property = Expand-StringVariables -Object $Object -Property $Property -IncludeVariables -MaxVariables $BracketVariables.count
        }
    }

    If($ExpandProperty){
        return $ExecutionContext.InvokeCommand.ExpandString($Property)
    }Else{
        return $Property
    }
    
}


Function ConvertTo-Variables{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true,ValueFromPipeline = $true)]
        $object,
        [switch]$Passthru
    )
    Begin{$variablelist=@()}
    Process{
        foreach ($x in $object | get-member) {
            if ($x.MemberType -ne "Method" -and $x.Name -notlike "__*") {
                
                If(Get-Variable -Name $x.Name -ErrorAction SilentlyContinue){
                    Write-Verbose ("Updating variable name [{1}] to value [{2}] as type [{0}]" -f $x.Definition.Split(" ")[0],$x.Name,$object.$($x.Name))
                    Set-Variable -Name $x.Name -Value $object.$($x.Name) -Force
                }Else{
                    Write-Verbose ("Adding {0} type variable name [{1}] with value [{2}]" -f $x.Definition.Split(" ")[0],$x.Name,$object.$($x.Name))
                    New-Variable -Name $x.Name -Value $object.$($x.Name) -Force
                }
                $variablelist += $x.Name
            }
        }
    }
    End{
        If($Passthru){
            Return $variablelist
        }

    }
}



Function Get-7zipUtilities{
    Param(
        [Parameter(Mandatory = $true)]
        [string]$DestPath,
        [switch]$Install
    )

    #Test if 7zip files exist
    $sevenzipfiles = @(
        "$ToolsPath\7za.exe" #standalone console version of 7-Zip with reduced formats support.
        "$ToolsPath\7za.dll" #library for working with 7z archives
        "$ToolsPath\7zxa.exe" #library for extracting from 7z archives
        "$ToolsPath\7zxa.dll" #library for extracting from 7z archives
    )

    # Modern websites require TLS 1.2
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    
    # Let's go directly to the website and see what it lists as the current version
    $BaseUri = "https://www.7-zip.org/"
    $BasePage = Invoke-WebRequest -Uri ( $BaseUri + 'download.html' ) -UseBasicParsing

    # The most recent 'current' (non-beta/alpha) is listed at the top, so we only need the first.
    If($Install){
        $ChildPath = $BasePage.Links | Where-Object { $_.href -like '*7z*-x64.msi' } | Select-Object -First 1 | Select-Object -ExpandProperty href
    }
    Else{
        $ChildPath = $BasePage.Links | Where-Object { $_.href -like '*7z*-extra.7z' } | Select-Object -First 1 | Select-Object -ExpandProperty href
    }
    
    # Let's build the required download link
    $DownloadUrl = $BaseUri + $ChildPath
    
    $OutFilePath = $DestPath + '\' + (Split-Path -Path $DownloadUrl -Leaf)

    Write-Host "Downloading the latest 7-Zip to the temp folder"
    Try{
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutFilePath -ErrorAction Stop | Out-Null
    }
    Catch{
        Write-Host ("Unable to download 7-Zip. {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }

    Try{
        If($Install){
            Write-Host "Installing the latest 7-Zip"
            Start-Process -FilePath "$env:SystemRoot\system32\msiexec.exe" -ArgumentList "/a", $OutFilePath -Wait 
        }Else{
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [System.IO.Compression.ZipFile]::ExtractToDirectory($OutFilePath, $env:temp, $true)
            #Expand-Archive -Path $OutFilePath -DestinationPath $DestPath -Force | Out-Null
        }
    }
    Catch{
        Write-Host ("Unable to setup 7-Zip. {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }   
}

Function Compress-7zipArchive {
    <#
    .NOTES
        -a Archive
        -ai	Include the archive filenames
        -an	Disable the parsing of the archive name
        -ao	Overwrite mode
        -ax	Exclude the archive filenames
        -so	Write the data to StdOut
        -si	Read the data from StdIn
        -i	Include the filenames
        -m	Set the compression method
        -o	Set the output directory
        -p	Set the password
        -r	Recurse the subdirectories
        -t	Type of archive
        -u	Update the options
        -v	Create the volumes
        -w	Set the working directory
        -x	Exclude the filenames
        -y	Assume Yes on all the queries
        -tzip
        -t7z
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $SevenZipPath,
        
        [Parameter(Mandatory = $true,ValueFromPipeline = $true)]
        [Alias('Folder')]
        [string[]] $Path,
        
        [Parameter(Mandatory = $true)]
        [Alias('Destination')]
        [string] $DestinationPath,
        
        [ValidateSet('100m','500m','1g')]
        [String]$SplitSize,
        
        [switch] $Force,

        [switch] $ShowProgress
        
    )
    Begin{
        $env:SEE_MASK_NOZONECHECKS = 1
    }
    Process{
        $ZipArgs = @(
            'a'
            '-r'
        )
        If($SplitSize){$ZipArgs += "-v$SplitSize"}
        If($Force){$ZipArgs += '-aoa'}
        
        if (-not (Test-Path -Path $SevenZipPath -PathType Leaf)) {
            throw "7 zip file '$SevenZipPath' not found"
        }

        $ZipArgs = $ZipArgs -join ' '
        Write-Verbose "Start-Process $SevenZipPath -ArgumentList `"$ZipArgs `"$DestinationPath`" `"$Path`" -PassThru -Wait -WindowStyle Hidden"
        If($ShowProgress){
            $result = Start-Process $SevenZipPath -ArgumentList "$ZipArgs `"$DestinationPath`" `"$Path`"" -RedirectStandardOutput "$env:temp\stdout.txt" -RedirectStandardError "$env:temp\stderr.txt"  -PassThru -WindowStyle Hidden
            <#
            $ErroredFiles = 0
            #region Progress bar loop
            while (!$AzCopy.HasExited) {
                Start-Sleep $ReportGap
                If($ShowProgress){
                    $TransferStatus = Get-Content -Path "$env:temp\stdout.txt" | Select -Last 1
                    If($TransferStatus -match '^\d+'){
                        $DataSet = ($TransferStatus.split(',') -Replace '\w+$|%','')[0..4].Trim()
                        If([int]$DataSet[2] -ne 0){$ErroredFiles=$DataSet[2]}
                        Write-Progress -Activity ('Transferring files to [{0}]' -f $Destination) -Status ("Copied {0} of {1} files..." -f $DataSet[1], $DataSet[4]) -PercentComplete $DataSet[0]
                    }ElseIf([string]::IsNullOrWhiteSpace($TransferStatus) ){
                        Write-Progress -Activity ('AzCopy status' -f $Destination) -Status "Nothing to report" -PercentComplete 100
                    }
                    Else{
                        Write-Progress -Activity ('AzCopy status' -f $Destination) -Status "$TransferStatus" -PercentComplete 100
                    }
                }
            }
            #>
        
        }Else{
            $result = Start-Process $SevenZipPath -ArgumentList "$ZipArgs `"$DestinationPath`" `"$Path`"" -PassThru -Wait -WindowStyle Hidden
        }
        
        
        if ($result.ExitCode -eq 0) {
            Write-Verbose "Folder archived successfully."
        } else {
            Write-Error ("Error occurred while archiving the folder. {0}" -f $result.ExitCode)
        }
    }
    End{
        $env:SEE_MASK_NOZONECHECKS = 0
    }
}

Function Expand-7zipArchive{

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $SevenZipPath,
        
        [Parameter(Mandatory = $true,ValueFromPipeline = $true)]
        [Alias('File')]
        [string[]] $FilePath,
        
        [Alias('Destination')]
        [string] $DestinationPath,

        [switch] $Force,

        [switch] $ShowProgress
    )
    Begin{
        $env:SEE_MASK_NOZONECHECKS = 1
    }
    Process{
        $ZipArgs = @('e')
        If($Force){$ZipArgs += '-aoa'}
        
        #add first file path
        $ZipArgs += "`"$FilePath`""
    
        #always make this last
        $ZipArgs += '-o'
        $ZipArgs = $ZipArgs -join ' '
        
        If($DestinationPath -notmatch '\*$'){$DestinationPath=$DestinationPath + '*'}

        Write-Verbose "Start-Process $SevenZipPath -ArgumentList `"$ZipArgs`"$DestinationPath`"`" -PassThru -Wait -WindowStyle Hidden"
        If($ShowProgress){
            $result = Start-Process $SevenZipPath -ArgumentList "$ZipArgs`"$DestinationPath`"" -RedirectStandardOutput "$env:temp\stdout.txt" -RedirectStandardError "$env:temp\stderr.txt" -PassThru -WindowStyle Hidden
        }Else{
            $result = Start-Process $SevenZipPath -ArgumentList "$ZipArgs`"$DestinationPath`"" -PassThru -Wait -WindowStyle Hidden
        }
        
        
        if ($result.ExitCode -eq 0) {
            Write-Verbose "Folder expanded successfully."
        } else {
            Write-Error ("Error occurred while expanding the folder. {0}" -f $result.ExitCode)
        }
    }
    End{
        $env:SEE_MASK_NOZONECHECKS = 0
    }
}



# function to generate password; compatible with .Net core
function New-Password{
    [CmdletBinding(PositionalBinding=$false)]
    param (
        [Parameter(
            Mandatory = $false,
            HelpMessage = "Minimum password length"
        )]
        [ValidateRange(1,[int]::MaxValue)]
        [int]$MinimumLength = 24,

        [Parameter(
            Mandatory = $false,
            HelpMessage = "Maximum password length"
        )]
        [ValidateRange(1,[int]::MaxValue)]
        [int]$MaximumLength = 42,

        [Parameter(
            Mandatory = $false,
            HelpMessage = "Characters which can be used in the password"
        )]
        [ValidateNotNullOrEmpty()]
        [string]$Characters = '1234567890qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM@#%*-_+:,.)(/\'
    )
    #looping and randomizing characters within min to max lengths to generate password
    #then join them as a string
    (1..(Get-Random -Minimum $MinimumLength -Maximum $MaximumLength) `
    | %{ `
        $Characters.GetEnumerator() | Get-Random `
    }) -join ''
}


function Test-IsPendingReboot {
    if (Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -EA Ignore) { return $true }
    if (Get-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -EA Ignore) { return $true }
    if (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -EA Ignore) { return $true }
    try { 
        $util = [wmiclass]"\\.\root\ccm\clientsdk:CCM_ClientUtilities"
        $status = $util.DetermineIfRebootPending()
        if (($status -ne $null) -and $status.RebootPending) {
            return $true
        }
    }
    catch { }

    return $false
}