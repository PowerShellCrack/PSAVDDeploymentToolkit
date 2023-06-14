
Function Get-HrefMatches {
    param(
        ## The filename to parse
        [Parameter(Mandatory = $true)]
        [string] $content,

        ## The Regular Expression pattern with which to filter
        ## the returned URLs
        [string] $Pattern = "<\s*a\s*[^>]*?href\s*=\s*[`"']*([^`"'>]+)[^>]*?>"
    )

    $returnMatches = new-object System.Collections.ArrayList

    ## Match the regular expression against the content, and
    ## add all trimmed matches to our return list
    $resultingMatches = [Regex]::Matches($content, $Pattern, "IgnoreCase")
    foreach($match in $resultingMatches)
    {
        $cleanedMatch = $match.Groups[1].Value.Trim()
        [void] $returnMatches.Add($cleanedMatch)
    }

    $returnMatches
}

Function Get-Hyperlinks {
    param(
    [Parameter(Mandatory = $true)]
    [string] $content,
    [string] $Pattern = "<A[^>]*?HREF\s*=\s*""([^""]+)""[^>]*?>([\s\S]*?)<\/A>"
    )
    $resultingMatches = [Regex]::Matches($content, $Pattern, "IgnoreCase")

    $returnMatches = @()
    foreach($match in $resultingMatches){
        $LinkObjects = New-Object -TypeName PSObject
        $LinkObjects | Add-Member -Type NoteProperty `
            -Name Text -Value $match.Groups[2].Value.Trim()
        $LinkObjects | Add-Member -Type NoteProperty `
            -Name Href -Value $match.Groups[1].Value.Trim()

        $returnMatches += $LinkObjects
    }
    $returnMatches
}

Function Get-WebContentHeader{
    #https://stackoverflow.com/questions/41602754/get-website-metadata-such-as-title-description-from-given-url-using-powershell
    param(
        [Parameter(Mandatory=$true,Position=0,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        #[Microsoft.PowerShell.Commands.HtmlWebResponseObject]$WebContent,
        $WebContent,

        [Parameter(Mandatory=$false)]
        [ValidateSet('Keywords','Description','Title')]
        [string]$Property
    )

    ## -------- PARSE TITLE, DESCRIPTION AND KEYWORDS ----------
    $resultTable = @{}
    # Get the title
    $resultTable.title = $WebContent.ParsedHtml.title
    # Get the HTML Tag
    $HtmlTag = $WebContent.ParsedHtml.childNodes | Where-Object {$_.nodename -eq 'HTML'}
    # Get the HEAD Tag
    $HeadTag = $HtmlTag.childNodes | Where-Object {$_.nodename -eq 'HEAD'}
    # Get the Meta Tags
    $MetaTags = $HeadTag.childNodes| Where-Object {$_.nodename -eq 'META'}
    # You can view these using $metaTags | select outerhtml | fl
    # Get the value on content from the meta tag having the attribute with the name keywords
    $resultTable.keywords = $metaTags  | Where-Object {$_.name -eq 'keywords'} | Select-Object -ExpandProperty content
    # Do the same for description
    $resultTable.description = $metaTags  | Where-Object {$_.name -eq 'description'} | Select-Object -ExpandProperty content
    # Return the table we have built as an object

    switch($Property){
        'Keywords'       {Return $resultTable.keywords}
        'Description'    {Return $resultTable.description}
        'Title'          {Return $resultTable.title}
        default          {Return $resultTable}
    }
}


Function Initialize-FileDownload {
   param(
        [Parameter(Mandatory=$true,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [string]$Url,

        [Parameter(Mandatory=$true)]
        [Alias("TargetDest")]
        [string]$TargetFile,

        [Parameter(Mandatory=$false)]
        [Alias("Title")]
        [string]$Name,

        [Parameter(Mandatory=$false)]
        [switch]$HideProgress

    )
    Begin{
        ## Get the name of this function
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name

        ## Check running account
        [Security.Principal.WindowsIdentity]$CurrentProcessToken = [Security.Principal.WindowsIdentity]::GetCurrent()
        [Security.Principal.SecurityIdentifier]$CurrentProcessSID = $CurrentProcessToken.User
        [boolean]$IsLocalSystemAccount = $CurrentProcessSID.IsWellKnown([Security.Principal.WellKnownSidType]'LocalSystemSid')
        [boolean]$IsLocalServiceAccount = $CurrentProcessSID.IsWellKnown([Security.Principal.WellKnownSidType]'LocalServiceSid')
        [boolean]$IsNetworkServiceAccount = $CurrentProcessSID.IsWellKnown([Security.Principal.WellKnownSidType]'NetworkServiceSid')
        [boolean]$IsServiceAccount = [boolean]($CurrentProcessToken.Groups -contains [Security.Principal.SecurityIdentifier]'S-1-5-6')
        [boolean]$IsProcessUserInteractive = [Environment]::UserInteractive

        #Create secure channel
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        ## Load the System.Web DLL so that we can decode URLs
        Add-Type -Assembly System.Web

        #  Check if script is running with no user session or is not interactive
        If ( ($IsProcessUserInteractive -eq $false) -or $IsLocalSystemAccount -or $IsLocalServiceAccount -or $IsNetworkServiceAccount -or $IsServiceAccount) {
            $HideProgress = $true
        }
    }
    Process
    {
        $FileName = Split-Path $url -Leaf

        $uri = New-Object "System.Uri" "$url"
        $request = [System.Net.HttpWebRequest]::Create($uri)
        $request.set_Timeout(15000) #15 second timeout
        $response = $request.GetResponse()
        $totalLength = [System.Math]::Floor($response.get_ContentLength()/1024)
        $responseStream = $response.GetResponseStream()
        $targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $targetFile, Create

        $buffer = new-object byte[] 10KB
        $count = $responseStream.Read($buffer,0,$buffer.length)
        $downloadedBytes = $count

        If($Name){$Label = $Name}Else{$Label = $FileName}

        while ($count -gt 0)
        {
            $targetStream.Write($buffer, 0, $count)
            $count = $responseStream.Read($buffer,0,$buffer.length)
            $downloadedBytes = $downloadedBytes + $count

            # display progress
            If (!$HideProgress) {
                Write-Progress -Activity ("Downloading: {0} " -f $Label) -Status ("Retrieving: {0}k of {1}k" -f [System.Math]::Floor($downloadedBytes/1024),$totalLength) -PercentComplete (([System.Math]::Floor($downloadedBytes/1024))/$totalLength * 100)
            }
        }

        If (!$HideProgress) {
            #Write-Progress -activity "Finished downloading file '$($url.split('/') | Select-Object -Last 1)'"
            Write-Progress -Activity ("Downloading: {0} " -f $Label)  -Status ("Finished downloading file: {0}" -f $Label) -PercentComplete 100
        }
   }
   End{
        #change meta in file from internet to allow to run on system
        If(Test-Path $TargetFile){Unblock-File $TargetFile -ErrorAction SilentlyContinue | Out-Null}

        $targetStream.Flush()
        $targetStream.Close()
        $targetStream.Dispose()
        $responseStream.Dispose()
   }

}

Function Get-FileProperties{
    Param(
        [io.fileinfo]$FilePath
    )
    $objFileProps = Get-item $filepath | Get-ItemProperty | Select-Object *

    #Get required Comments extended attribute
    $objShell = New-object -ComObject shell.Application
    $objShellFolder = $objShell.NameSpace((get-item $filepath).Directory.FullName)
    $objShellFile = $objShellFolder.ParseName((get-item $filepath).Name)

    $strComments = $objShellfolder.GetDetailsOf($objshellfile,24)
    $Version = [version]($strComments | Select-string -allmatches '(\d{1,4}\.){3}(\d{1,4})').matches.Value
    $objShellFile = $null
    $objShellFolder = $null
    $objShell = $null

    Add-Member -InputObject $objFileProps -MemberType NoteProperty -Name Version -Value $Version
    Return $objFileProps
}

Function Get-FtpDir{
    param(
        [Parameter(Mandatory=$true)]
        [string]$url,

        [System.Management.Automation.PSCredential]$credentials
    )
    $request = [Net.WebRequest]::Create($url)
    $request.Method = [System.Net.WebRequestMethods+FTP]::ListDirectory

    if ($credentials) { $request.Credentials = $credentials }

    $response = $request.GetResponse()
    $reader = New-Object IO.StreamReader $response.GetResponseStream()
	$reader.ReadToEnd()
	$reader.Close()
	$response.Close()
}
