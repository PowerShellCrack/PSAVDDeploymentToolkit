<#
.EXAMPLE
$SevenZipPath="C:\Windows\Temp\AVDToolkit\Tools\7za.exe"
$FilePath="C:\Windows\Temp\AVDToolkit\Applications\application_Microsoft365Appsforenterpriseenus_setup_16.0.16529.20226.zip.001"
$DestinationPath="C:\Windows\Temp\AVDToolkit\Applications\M365"
#>
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

        [switch] $ExtractHere,

        [switch] $Flatten,

        [switch] $Force,

        [switch] $ShowProgress
    )
    Begin{
        $env:SEE_MASK_NOZONECHECKS = 1
    }
    Process{
        If($Flatten){
            $ZipArgs = @('e')
        }Else{
            $ZipArgs = @('x')
        }

        #add first file path
        $ZipArgs += "`"$FilePath`""

        If($Force){$ZipArgs += '-aoa'}

        #always make this last
        If($ExtractHere){
            $ZipArgs += "-o`"$DestinationPath\`""
        }Else{
            If($DestinationPath -notmatch '\*$'){$DestinationPath=$DestinationPath + '\*'}
            $ZipArgs += "-o`"$DestinationPath`""
        }
ExtractHere
        $ZipArgsString = $ZipArgs -join ' '

        Write-Verbose "$SevenZipPath $ZipArgsString"
        If($ShowProgress){
            $result = Start-Process $SevenZipPath -ArgumentList $ZipArgs -RedirectStandardOutput "$env:temp\stdout.txt" -RedirectStandardError "$env:temp\stderr.txt" -PassThru -WindowStyle Hidden
        }Else{
            $result = Start-Process $SevenZipPath -ArgumentList $ZipArgs -PassThru -Wait -WindowStyle Hidden
        }


        if ($result.ExitCode -eq 0) {
            Write-Verbose "Folder expanded successfully."
        } else {
            Write-Error ("Error occurred while expanding the folder. {0}" -f $result.ExitCode)
        }

ExtractHere
    }
    End{
        $env:SEE_MASK_NOZONECHECKS = 0
    }
}

