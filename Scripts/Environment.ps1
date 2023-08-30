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

Function Test-IsAdmin
{
<#
.SYNOPSIS
   Function used to detect if current user is an Administrator.

.DESCRIPTION
   Function used to detect if current user is an Administrator. Presents a menu if not an Administrator

.NOTES
    Name: Test-IsAdmin
    Author: Dick Tracy
    DateCreated: 30April2011

.EXAMPLE
    Test-IsAdmin

#>
    Write-Verbose "Checking to see if current user context is Administrator"
    If (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator"))
    {
        Write-Verbose "You are not currently running this under an Administrator account! `nThere is potential that this command could fail if not running under an Administrator account."
        return $false
    }
    Else
    {
        Write-Verbose "Passed Administrator check"
        return $true
    }
}

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


Function Test-IsDuplicateDirectoryExists{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true,Position=0)]
        $DestinationPath,
        [switch]$Passthru
    )

    $WorkingFolder = Split-Path $DestinationPath -Leaf
    If(Get-ChildItem -Path $DestinationPath -Directory -Filter $WorkingFolder){
        If($Passthru){
            return $WorkingFolder
        }Else{
            return $true
        }
    }Else{
        return $false
    }
}


Function Move-ItemUpDirectory {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true,Position=0)]
        $CurrentPath
    )

    $UpOneDirectory = Split-Path (Get-Item -Path $CurrentPath).FullName -Parent
    $CurrentRootFolder = Split-Path -Path $CurrentPath -Leaf
    $Files = Get-ChildItem -Path $CurrentPath -Recurse -File
    #TEST $File = $Files[0]
    #TEST $File = $Files[2]
    #TEST $File = $Files[-1]


    foreach ($File in $Files) {

        $CurrentFolders = (Split-Path -Path $File.FullName -Parent).replace("$UpOneDirectory\",'').replace("$CurrentRootFolder",'').TrimStart('\')
        #$Destination_Path = Split-Path -Path $CurrentDirectory -Parent
        $NewDirectory = Join-Path $UpOneDirectory -ChildPath $CurrentFolders
        $OldDirectory = Join-Path $CurrentPath -ChildPath $CurrentFolders

        If(-NOT(Test-Path -Path $NewDirectory -ErrorAction SilentlyContinue)){
            New-Item -Path $NewDirectory -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }

        Move-Item -Path $File.FullName -Destination $NewDirectory -Force
        if ($null -eq (Get-ChildItem -Path $OldDirectory -File -Recurse)) {

            Remove-Item -Path $OldDirectory -Force | Out-Null
        }
    }

    if ($null -eq (Get-ChildItem -Path $CurrentPath -File -Recurse)) {

        Remove-Item -Path $CurrentPath -Force -Recurse | Out-Null
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