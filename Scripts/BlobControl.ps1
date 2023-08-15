#https://docs.microsoft.com/en-us/azure/storage/blobs/storage-quickstart-blobs-powershell
#https://docs.microsoft.com/en-us/azure/storage/scripts/storage-common-rotate-account-keys-powershell?toc=%2Fpowershell%2Fmodule%2Ftoc.json
Function Set-StorageBlobPublicAccess {
    Param(
        $ResourceGroup,
        $accountName,
        [switch]$Disable
    )
    # Read the AllowBlobPublicAccess property for the newly created storage account.
    (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $accountName).AllowBlobPublicAccess

    If($Disable){
        # Set AllowBlobPublicAccess set to false
        Set-AzStorageAccount -ResourceGroupName $ResourceGroup `
            -Name $accountName `
            -AllowBlobPublicAccess $false
    }
    # Read the AllowBlobPublicAccess property.
    (Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $accountName).AllowBlobPublicAccess
}

Function Set-StorageContainerPublicAccess {
    Param(
        $ResourceGroup,
        $accountName,
        $containerName
    )

    # Get context object.
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $accountName
    $ctx = $storageAccount.Context

    # Create a new container with public access setting set to Off.
    New-AzStorageContainer -Name $containerName -Permission Off -Context $ctx

    # Read the container's public access setting.
    Get-AzStorageContainerAcl -Container $containerName -Context $ctx

    # Update the container's public access setting to Container.
    Set-AzStorageContainerAcl -Container $containerName -Permission Container -Context $ctx

    # Read the container's public access setting.
    Get-AzStorageContainerAcl -Container $containerName -Context $ctx
}



Function Invoke-BlobContainerTransfer{
    param (
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string]$BlobUrl,

        [string]$Container,

        [ValidateSet('Global','USGov')]
        $AzureEnvironment,

        $StorageAccountName,

        $StorageAccountKey,

        [switch]$UseSAS,
        
        [Parameter(Mandatory)]
        [string]$SasToken,

        [string]$AzCopyPath = '.\AzCopy.exe'
    )

    $FileName = Split-Path $FilePath -Leaf

    Write-Host ("Copying file [{0}] to [{1}]..." -f $FileName,$BlobUrl) -NoNewline
    
    If($UseSAS){
        $Arguments= (
            'copy',
            "$FilePath",
            "https://$BlobUrl/$Container/$FileName`?$SasToken"
        )

        $Result = Start-Process $AzCopyPath -ArgumentList $Arguments -PassThru -NoNewWindow -Wait 
        #get results and see if they are valid
        If($Result.ExitCode -eq 0){
            Write-Host "Success" -ForegroundColor Green
        }Else{
            Write-Host ('Failed to copy: {0}' -f $Result.ExitCode) -ForegroundColor Red
        }
    }Else{
        Connect-AzAccount -Environment $AzureEnvironment

        $ctx = New-AzStorageContext `
                        -StorageAccountName $StorageAccountName `
                        -StorageAccountKey $StorageAccountKey `
                        -Protocol Https

        Try{
            Set-AzStorageBlobContent `
                        -File $FilePath `
                        -Container $Container `
                        -Blob $FileName `
                        -Context $ctx -ErrorAction Stop
            Write-Host "Success" -ForegroundColor Green
        }Catch{
            Write-Host ('Failed to copy: {0}' -f $_.Exception.Message) -ForegroundColor Red
        }
    }
}


Function Invoke-AzCopyToBlob {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        $AzCopyPath,
        [Parameter(Mandatory = $true,ValueFromPipeline = $true)]
        [Alias('Source')]
        [string[]] $SourcePath,
        [Parameter(Mandatory = $true)]
        [Alias('Destination')]
        [string] $DestinationURL,
        [string] $SasToken,
        [int] $ReportGap = 1,
        [switch] $SyncDir,
        [string] $ExcludeFolder,
        [string] $ExcludeWildcard,
        [switch] $ShowProgress,
        [String] $ProgressMsg,
        [string[]] $ValidExitCodes = @(0,1),
        [switch] $Force
        
    )
    Begin{
        $env:SEE_MASK_NOZONECHECKS = 1

        #region AzCopy params
        $AzCopyCommonArguments = @('--put-md5=true','--skip-version-check=true')
            
        If ($ExcludeFolder){
            $AzCopyCommonArguments += '--exclude-path={0}' -f $ExcludeFolder
        }

        If ($ExcludeWildcard){
            $AzCopyCommonArguments += '--exclude-pattern={0}' -f $ExcludeWildcard
        }

        If($SasToken){
            $FullURL = "$DestinationURL`?$SasToken"
        }Else{
            $FullURL = $DestinationURL
        }
    }
    Process{
        #build full argumen tlist
        If($SyncDir){
            $AzCopyArguments = @(
                'sync'
                """$SourcePath"""
                """$FullURL"""
            )
            $AzCopyCommonArguments += @(
                '--delete-destination=true'
                '--mirror-mode=true'
                '--recursive=true'
                '--skip-version-check=true'
            )
        }Else{
            $AzCopyArguments = @(
                'copy'
                """$SourcePath"""
                """$FullURL"""
                
            )
            
        }

        If($Force){
            $AzCopyCommonArguments += @(
                '--overwrite=true'
            )
        }
        $AzCopyArguments += $AzCopyCommonArguments

        #$AzCopyTestArguments = $AzCopyArguments + '--dry-run=true'
        # Begin the AzCopy process
        Write-Verbose -Message ('RUNNING COMMAND: {0} {1}' -f $AzCopyPath,($AzCopyArguments -join ' '));
        $AzCopy = Start-Process -FilePath $AzCopyPath -ArgumentList $AzCopyArguments -RedirectStandardOutput "$env:temp\stdout.txt" -RedirectStandardError "$env:temp\stderr.txt" -WindowStyle Hidden -PassThru
        Start-Sleep 5
        #endregion Start AzCopy

        $ErroredFiles = 0
        #region Progress bar loop
        while (!$AzCopy.HasExited) {
            Start-Sleep $ReportGap
            If($ShowProgress){
                $TransferStatus = Get-Content -Path "$env:temp\stdout.txt" | Select -Last 1
                If($TransferStatus -match '^\d+'){
                    
                    $DataSet = ($TransferStatus.split(',') -Replace '\w+$|%','')[0..4].Trim()
                    If([int]$DataSet[2] -ne 0){$ErroredFiles=$DataSet[2]}
                    If($ProgressMsg.Length -gt 0){Write-Status -Current $DataSet[0] -Total 100 -Statustext $ProgressMsg -CurStatusText ("Transferred {0}" -f $DataSet[0])}
                    Write-Progress -Activity ('Transferring files to [{0}]' -f $Destination) -Status ("Copied {0} of {1} files..." -f $DataSet[1], $DataSet[4]) -PercentComplete $DataSet[0]
                
                }ElseIf([string]::IsNullOrWhiteSpace($TransferStatus) ){
                    Write-Progress -Activity ('AzCopy status' -f $Destination) -Status "Nothing to report" -PercentComplete 100
                
                }Else{
                    Write-Progress -Activity ('AzCopy status' -f $Destination) -Status "$TransferStatus" -PercentComplete 100
                }
                
            }
        }
    }End{
        $env:SEE_MASK_NOZONECHECKS = 0

        #parse output file for last job status
        $Status = ([System.Text.RegularExpressions.Regex]::Match((Get-Content "$env:temp\stdout.txt" | Select -Last 2), '^(?<summary>.*):\s+(?<status>.*)$').Groups | Where Name -eq 'status').Value.Trim()

        #send out proper output
        switch ($Status){
            'Completed' {Write-Output $Status}
            default {Write-Error $Status}
        }
    }
}

function Write-Status 
{
  
  param([int]$Current,
        [int]$Total,
        [string]$Statustext,
        [string]$CurStatusText,
        [int]$ProgressbarLength = 35
    )

  # Save current Cursorposition for later
  [int]$XOrg = $host.UI.RawUI.CursorPosition.X

  # Create Progressbar
  [string]$progressbar = ""
  for ($i = 0 ; $i -lt $([System.Math]::Round($(([System.Math]::Round(($($Current) / $Total) * 100, 2) * $ProgressbarLength) / 100), 0)); $i++) {
    $progressbar = $progressbar + $([char]9608)
  }
  for ($i = 0 ; $i -lt ($ProgressbarLength - $([System.Math]::Round($(([System.Math]::Round(($($Current) / $Total) * 100, 2) * $ProgressbarLength) / 100), 0))); $i++) {
    $progressbar = $progressbar + $([char]9617)
  }
  # Overwrite Current Line with the current Status
  Write-Host -NoNewline "`r$Statustext $progressbar [$($Current.ToString("#,###").PadLeft($Total.ToString("#,###").Length)) / $($Total.ToString("#,###"))] ($($( ($Current / $Total) * 100).ToString("##0.00").PadLeft(6)) %) $CurStatusText"

  # There might be old Text behing the current Currsor, so let's write some blanks to the Position of $XOrg
  [int]$XNow = $host.UI.RawUI.CursorPosition.X
  for ([int]$i = $XNow; $i -lt $XOrg; $i++) {
    Write-Host -NoNewline " "
  }
  # Just for optical reasons: Go back to the last Position of current Line
  for ([int]$i = $XNow; $i -lt $XOrg; $i++) {
    Write-Host -NoNewline "`b"
  }
}

Function Invoke-RestCopyFromBlob{
        <#
    .SYNOPSIS
    Copy file from blob

    .DESCRIPTION
    This function leverages the Azure Rest API to download a file from blob storage using a SAS token.

    .PARAMETER BlobFile
    Provide blob file

    .PARAMETER DestinationPath
    Absolute path of the file will download to

    .PARAMETER BlobUrl
    Uri for blob container

    .PARAMETER SasToken
    Provide SAS token to access storage account

    .EXAMPLE
    Invoke-RestCopyFromBlob -BlobName "somefile.exe" -BlobUrl "BLOBSTORAGE_URI" -SasToken "SAS_TOKEN"

#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true,ValueFromPipeline = $true)]
        [Alias('FileName','BlobName')]
        [string[]] $BlobFile,

        [Parameter(Mandatory = $true)]
        [Alias('Destination')]
        [string] $DestinationPath,

        [Parameter(Mandatory=$true)]
        [Alias('BlobUri')]
        [string] $BlobUrl,

        [Parameter(Mandatory=$true)]
        [string] $SasToken,

        [switch] $Force
        
    )
    Begin{
        Write-Verbose ("Starting Blob transfer to {0}" -f $DestinationPath)
    }
    Process{
        If( (Test-Path "$DestinationPath\$BlobFile" -ErrorAction SilentlyContinue) -and !$Force){
            Write-host ("File path already exists! [{0}\{1}]" -f $DestinationPath,$BlobFile)
        }Else{
            $uri = ($BlobUrl + '/' + $BlobFile +'?' + $SasToken)
            $Extension = [System.IO.Path]::GetExtension($BlobFile)  
            switch($Extension){
                '.json' {$ContentType="application/json"}
                '.xml'  {$ContentType="text/xml"}
                '.ps1'  {$ContentType="text/plain"}
                '.zip'  {$ContentType="application/zip"}
                default {$ContentType="application/octet-stream"}
            }
            Write-Verbose ("Transferring file [{0}]..." -f $BlobFile )
            try{
                Write-Verbose ("COMMAND:  Invoke-WebRequest `"$uri`" -ContentType `"$ContentType`" -OutFile `"$DestinationPath`" -UseBasicParsing")
                Invoke-WebRequest $uri -ContentType $ContentType -OutFile "$DestinationPath" -UseBasicParsing
            }Catch{
                Write-Error ("Failed. {0}" -f $_.Exception.Message)
            }
        }
        
    }End{
        Write-Verbose ("Completed Blob transfer to {0}" -f $DestinationPath)
    }
}


function Invoke-RestCopyToBlob{
    <#
    .SYNOPSIS
    Add a file to a blob storage

    .DESCRIPTION
    This function leverages the Azure Rest API to upload a file into a blob storage using a SAS token.

    .PARAMETER file
    Absolute path of the file to upload

    .PARAMETER BlobUrl
    Uri for blob container

    .PARAMETER SasToken
    Provide SAS token to access storage account

    .EXAMPLE
    Invoke-RestCopyToBlob -FilePath "FULL_PATH" -BlobUrl "BLOBSTORAGE_URI" -SasToken "SAS_TOKEN"

#>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $true,ValueFromPipeline = $true)]
        [ValidateScript({Test-Path $_ })]
        [Alias('FilePath')]
        [string[]]$SourcePath,

        [Parameter(Mandatory=$true)]
        [string] $BlobUrl,

        [Parameter(Mandatory=$true)]
        [string] $SasToken
    )
    Begin{
        
    }
    Process{
        $Filename = Split-Path $SourcePath -Leaf
        $uri = ($BlobUrl + '/' + $Filename +'?' + $SasToken)
        $headers = @{"x-ms-blob-type" = "BlockBlob"}
        
        Write-Verbose ("Starting transfer [{0}] to blob" -f $SourcePath)
        try{
            Write-Verbose ("COMMAND: Invoke-WebRequest `"$uri`" -Method Put -InFile `"$SourcePath`" -Headers {0}" -f (($headers.GetEnumerator()| %{$_.Name + ": " + $_.Value}) -join ','))
            Invoke-WebRequest $uri -Method Put -InFile $SourcePath -Headers $headers
        }Catch{
            Write-Error ("Failed. {0}" -f $_.Exception.Message)
        }
    }End{
        Write-Verbose ("Completed transfer to [{0}]" -f $BlobUrl)
    }
}