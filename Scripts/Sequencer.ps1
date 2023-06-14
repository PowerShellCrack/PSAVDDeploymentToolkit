Function ConvertTo-AIBLocalCommand{

    [CmdletBinding()]
    Param(
        [string]$FilePath,
        [string]$Arguments,
        [string[]]$ExitCodes,
        [switch]$ExportPoshCmd
    )

    <# EXAMPLES
    [string]$FilePath = 'C:\Temp\Applications\FoxitPDFReader\FoxitPDFReader1201_enu_Setup.msi'
    [string]$Arguments = "/quiet ADDLOCAL='FX_PDFVIEWER'"
    [string]$FilePath = 'C:\Temp\Applications\NotepadPlusPlus\npp.8.4.4.Installer.x64.exe'
    [string]$Arguments = "/S"
    [string[]]$ExitCodes = '3010'

    #>
    #Step 1. Run command
    $object = New-Object -TypeName PSObject
    $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
    $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Running " + $FilePath)
    $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
    $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
    #build splat arguments
    $cmdparams = [ordered]@{}

    $File = Split-Path $FilePath -Leaf
    If($Arguments){
        #double qoute arguments if qoutes exists in argument
        $Arguments = $Arguments.replace('"','""').replace("'",'""')
    }

    switch ( [System.IO.Path]::GetExtension($File) ){
        '.vbs' {
            If($CustomData.arguments.Length -gt 0){
                $cmdparams += @{
                    FilePath='c:\windows\system32\cscript.exe'
                    ArgumentList="`"//Nologo `"`"$FilePath`"`" $Arguments`""
                }
            }Else{
                $cmdparams += @{
                    FilePath='c:\windows\system32\cscript.exe'
                    ArgumentList="`"//Nologo `"`"$FilePath`"`"`""
                }
            }
        }

        '.wsf' {
            If($CustomData.arguments.Length -gt 0){
                $cmdparams += @{
                    FilePath='c:\windows\system32\cscript.exe'
                    ArgumentList="`"//Nologo `"`"$FilePath`"`" $Arguments`""
                }
            }Else{
                $cmdparams += @{
                    FilePath='c:\windows\system32\cscript.exe'
                    ArgumentList="`"//Nologo `"`"$FilePath`"`"`""
                }
            }
        }

        '.msi' {
            If($CustomData.arguments.Length -gt 0){
                $cmdparams += @{
                    FilePath='c:\windows\system32\msiexec.exe'
                    ArgumentList="`"/i `"`"$FilePath`"`" $Arguments`""
                }
            }Else{
                $cmdparams += @{
                    FilePath='c:\windows\system32\msiexec.exe'
                    ArgumentList="`"/i `"`"$FilePath`"`" /qn /norestart`""
                }
            }
        }

        '.exe' {
            If($CustomData.arguments.Length -gt 0){
                $cmdparams += @{
                    FilePath="`"$FilePath`""
                    ArgumentList="`"$Arguments`""
                }
            }Else{
                $cmdparams += @{
                    FilePath="`"$FilePath`""
                }
            }
        }
    }

    $cmdparams += @{
        Wait=$true
        PassThru=$true
    }

    If([System.IO.Path]::GetExtension($File) -eq '.ps1'){
        If($CustomData.arguments.Length -gt 0){

            $InlineCommands = @(
                "& `"`"$FilePath`"`" $Arguments"
            )
        }Else{
            $InlineCommands = @(
                "& `"`"$FilePath`"`""
            )
        }
    }Else{
        #convert splat into a string
        $command = ($cmdparams.GetEnumerator() | %{If($_.value -eq $true){'-' + $_.key}Else{'-' + $_.key + ' ' + $_.value}}) -join ' '
        $InlineCommands = @(
            "`$Result = Start-Process $command",
            "Return `$Result.ExitCode"
        )
    }

    $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands

    If($ExitCodes){
        $object | Add-Member -MemberType NoteProperty -Name 'validExitCodes' -Value $ExitCodes
    }

    #when outputting as posh commands; remove Return as each consecutive command will run.
    If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands.replace('Return','').trim()}
    Return $object
}


Function ConvertTo-AIBCustomization{
    <#
    .SYNOPSIS
    Convert customization properties to AIB support format

    .NOTES
    $BlobUrl = (Get-Content .\Control\settings-gov.json -raw | ConvertFrom-Json).Resources.resourceBlobURI
    $SequenceData = Get-Content .\Control\Win10avdBaselineImage\aib.json -raw | ConvertFrom-Json | Select -expandProperty customSequence
    [System.Object[]]$CustomData = $SequenceData | Where Type -eq 'Application' | Select -index 4
    [System.Object[]]$CustomData = $SequenceData | Where Type -eq 'Script' | Select -first 1

    {
        "type": "PowerShell",
        "name":   "<name>",
        "scriptUri": "<path to script>",
        "runElevated": <true false>,
        "sha256Checksum": "<sha256 checksum>"
    },
    {
        "type": "PowerShell",
        "name": "<name>",
        "inline": "<PowerShell syntax to run>",
        "validExitCodes": <exit code>,
        "runElevated": <true or false>
    }
    {
        "type": "File",
        "name": "<name>",
        "sourceUri": "<source location>",
        "destination": "<destination>",
        "sha256Checksum": "<sha256 checksum>"
    }


    .LINK
    https://docs.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-json?tabs=azure-powershell
    #>
    [CmdletBinding()]
    Param(
        $BlobURL,
        [System.Object[]]$CustomData,
        [string]$FileCopyDest = "C:\Temp",
        [switch]$SkipChecksum,
        [switch]$ExportPoshCmd,
        [switch]$Cleanup,
        [switch]$Passthru
    )

    $ObjectArray = @()
    Write-Verbose ("Parsing {0}" -f $CustomData.type)
    switch($CustomData.type){
        #convert application into a variety of AIB Customization support types based on extension
        'Application' {

            # Step 1: Determine file retrieval
            #---------------------------------
            If($CustomData.fileDependency.count -gt 0){
                Foreach($file in $CustomData.fileDependency | Where {$_ -ne $CustomData.executable}){
                    #to use Blob shared access token, you must use Azcopy with sas token instead of uri copies
                    If(($CustomData.sasToken.length -gt 0) -and ([System.IO.Path]::GetExtension($file) -match "zip$")){
                        #Step 1,2,3: create working directory, Copy file using azcopy, and extract
                        $InlineCommands = @(
                            "$FileCopyDest\azcopy.exe copy `"https://$BlobUrl/application-$($CustomData.workingDirectory.ToLower())/$($file)?$($CustomData.sasToken)`" `"$FileCopyDest\Applications\$($CustomData.workingDirectory)\$file`"",
                            "Expand-Archive -Path `"$FileCopyDest\Applications\$($CustomData.workingDirectory)\$file`" -DestinationPath `"$FileCopyDest\Applications\$($CustomData.workingDirectory)`" -Force"
                        )

                        $object = New-Object -TypeName PSObject
                        $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
                        $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Extracting " + $file)
                        $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
                        $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
                        $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
                        If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
                        $ObjectArray += $object

                        Write-Verbose ('Added {0} Azcopy to uri: https://' + $BlobURL + '/application-' + $CustomData.workingDirectory.ToLower() + '/' + $file,([System.IO.Path]::GetExtension($file)))

                    }Else{

                        $object = New-Object -TypeName PSObject
                        $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "File"
                        $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Copying " + $file)
                        $object | Add-Member -MemberType NoteProperty -Name 'sourceUri' -Value ('https://' + $BlobURL + '/application-' + $CustomData.workingDirectory.ToLower()  + '/' + $file)
                        $object | Add-Member -MemberType NoteProperty -Name 'destination' -Value ($FileCopyDest + '\Applications\' + $CustomData.workingDirectory + '\' + $file)
                        #get local copy to determine hash
                        If( (Test-Path ('.\Applications\' + $CustomData.workingDirectory + '\' + $file)) -and !$SkipChecksum){
                            $CheckSum = Get-FileHash ('.\Applications\' + $CustomData.workingDirectory + '\' + $file) | Select -ExpandProperty Hash
                            $object | Add-Member -MemberType NoteProperty -Name 'sha256Checksum' -Value $CheckSum
                        }
                        If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value "Invoke-WebRequest `"https://$BlobURL/application-$($CustomData.workingDirectory.ToLower())/$file`" -OutFile `"$FileCopyDest\Applications\$($CustomData.workingDirectory)\$file`""}
                        $ObjectArray += $object

                        Write-Verbose ("Added file uri downloader: {0}" -f ($FileCopyDest + '\' + $CustomData.workingDirectory + '\' + $file))
                    }
                }
            }

            #to use Blob shared access token, you must use Azcopy with sas token instead of uri copies
            If($null -eq $CustomData.sasToken){
                # Step 2 Determine execution command based on extension
                #-------------------------------------------------------
                switch -regex ( [System.IO.Path]::GetExtension($CustomData.executable) ){
                    'ps1$' {

                        #AIB does not support arguments, so the process must be broken down into copy file and inline script call
                        If($CustomData.arguments.Length -gt 0){
                            $Arguments = $CustomData.arguments -replace '<destination>',($FileCopyDest + '\Applications\' + $CustomData.workingDirectory)

                            #Step 2a: Gen File copy for ps1 file
                            $object = New-Object -TypeName PSObject
                            $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "File"
                            $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Copying " + $CustomData.workingDirectory)
                            $object | Add-Member -MemberType NoteProperty -Name 'sourceUri' -Value ('https://' + $BlobURL + '/application-' + $CustomData.workingDirectory.ToLower()  + '/' + $CustomData.executable)
                            $object | Add-Member -MemberType NoteProperty -Name 'destination' -Value ($FileCopyDest + '\Applications\' + $CustomData.workingDirectory + '\' + $CustomData.executable)
                            #get local copy to determine hash
                            If( (Test-Path ('.\Applications\' + $CustomData.workingDirectory + '\' + $CustomData.executable)) -and !$SkipChecksum){
                                $CheckSum = Get-FileHash ('.\Applications\' + $CustomData.workingDirectory + '\' + $CustomData.executable) | Select -ExpandProperty Hash
                                $object | Add-Member -MemberType NoteProperty -Name 'sha256Checksum' -Value $CheckSum
                            }
                            If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value "Invoke-WebRequest `"https://$BlobURL/application-$($CustomData.workingDirectory.ToLower())/$($CustomData.executable)`" -OutFile `"$FileCopyDest\Applications\$($CustomData.workingDirectory)\$($CustomData.executable)`""}
                            $ObjectArray += $object

                            #Step 2b: Gen inline with argument for ps1 call
                            $InlineCommands = @(
                                "& $FileCopyDest\$($CustomData.workingDirectory)\$($CustomData.executable) $Arguments"
                            )
                            $object = New-Object -TypeName PSObject
                            $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
                            $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ($CustomData.name -replace '\s+','').ToLower()
                            $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
                            $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
                            $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
                            #this is to export to ps1 file for testing
                            If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
                            $ObjectArray += $object
                            Write-Verbose ("Added powershell command to run: {0} {1}" -f ($FileCopyDest + '\' + $CustomData.workingDirectory + '\' + $CustomData.executable), $Arguments)

                        }Else{

                            $object = New-Object -TypeName PSObject
                            $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
                            $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ($CustomData.name -replace '\s+','').ToLower()
                            $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
                            $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
                            $object | Add-Member -MemberType NoteProperty -Name 'scriptUri' -Value ('https://' + $BlobURL + '/application-' + $CustomData.workingDirectory.ToLower() + '/' + $CustomData.executable)
                            #get local copy to determine hash
                            If( (Test-Path ('.\Applications\' + $CustomData.workingDirectory + '\' + $CustomData.executable)) -and !$SkipChecksum){
                                $CheckSum = Get-FileHash ('.\Applications\' + $CustomData.workingDirectory + '\' + $CustomData.executable) | Select -ExpandProperty Hash
                                $object | Add-Member -MemberType NoteProperty -Name 'sha256Checksum' -Value $CheckSum
                            }
                            If($CustomData.exitCodes){
                                $object | Add-Member -MemberType NoteProperty -Name 'validExitCodes' -Value $CustomData.exitCodes
                            }
                            If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value @(
                                    "Invoke-WebRequest `"https://$BlobURL/application-$($CustomData.workingDirectory.ToLower())/$($CustomData.executable)`" -OutFile `"$FileCopyDest\Applications\$($CustomData.workingDirectory)\$($CustomData.executable)`"",
                                    "& `"$FileCopyDest\Applications\$($CustomData.workingDirectory)\$($CustomData.executable)`""
                                )
                            }
                            $ObjectArray += $object

                            Write-Verbose ('Added script downloader to uri: https://' + $BlobURL + '/application-' + $CustomData.workingDirectory.ToLower() + '/' + $CustomData.executable)
                        }
                    }

                    'exe$|msi$' {

                        #Step 2a: Gen File copy for executable file
                        $object = New-Object -TypeName PSObject
                        $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "File"
                        $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Copying " + $CustomData.workingDirectory)
                        $object | Add-Member -MemberType NoteProperty -Name 'sourceUri' -Value ('https://' + $BlobURL + '/application-' + $CustomData.workingDirectory.ToLower()  + '/' + $CustomData.executable)
                        $object | Add-Member -MemberType NoteProperty -Name 'destination' -Value ($FileCopyDest + '\' + $CustomData.workingDirectory + '\' + $CustomData.executable)
                        #get local copy to determine hash
                        If( (Test-Path ('.\Applications\' + $CustomData.workingDirectory + '\' + $CustomData.executable)) -and !$SkipChecksum){
                            $CheckSum = Get-FileHash ('.\Applications\' + $CustomData.workingDirectory + '\' + $CustomData.executable) | Select -ExpandProperty Hash
                            $object | Add-Member -MemberType NoteProperty -Name 'sha256Checksum' -Value $CheckSum
                        }
                        If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value "Invoke-WebRequest `"https://$BlobURL/application-$($CustomData.workingDirectory.ToLower())/$($CustomData.executable)`" -OutFile `"$FileCopyDest\Applications\$($CustomData.workingDirectory)\$($CustomData.executable)`""}
                        $ObjectArray += $object

                        Write-Verbose ('Added {0} downloader to uri: https://' + $BlobURL + '/application-' + $CustomData.workingDirectory.ToLower() + '/' + $CustomData.executable,([System.IO.Path]::GetExtension($CustomData.executable)))

                        $CommandParams = @{
                            FilePath="$FileCopyDest\Applications\$($CustomData.workingDirectory)\$($CustomData.executable)"
                        }
                        If($ExportPoshCmd){$CommandParams += @{ExportPoshCmd=$true}}
                        If($CustomData.arguments.Length -gt 0){$CommandParams += @{Arguments=$CustomData.arguments}}
                        If($CustomData.exitCodes){$CommandParams += @{ExitCodes=$CustomData.exitCodes}}

                        $ObjectArray += ConvertTo-AIBLocalCommand @CommandParams

                        <#
                        #Step 4. Gen powershell inline command to call executable
                        $object = New-Object -TypeName PSObject
                        $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
                        $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Installing " + $CustomData.workingDirectory)
                        $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
                        $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
                        #if msi change installer to msiexec

                        switch([System.IO.Path]::GetExtension($CustomData.executable) ){
                            '.exe' {$FilePath= ($FileCopyDest + '\Applications\' +  $CustomData.workingDirectory + '\' + $CustomData.executable)}
                            '.msi' {$FilePath='C:\Windows\system32\msiexec.exe';$Arguments = "$FileCopyDest\Applications\$($CustomData.workingDirectory)\$($CustomData.executable)" + ' ' + $Arguments}
                        }
                        If($CustomData.arguments.Length -gt 0){
                            $Arguments = $CustomData.arguments -replace '<destination>',$FileCopyDest

                            $InlineCommands = @(
                                "`$Result = Start-Process -FilePath $FilePath -ArgumentList '$Arguments' -Wait -PassThru"
                                "Return `$Result.ExitCode"
                            )
                        }Else{
                            $InlineCommands = @(
                                "`$Result = Start-Process -FilePath $FilePath -Wait -PassThru",
                                "Return `$Result.ExitCode"
                            )
                        }
                        $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands

                        If($CustomData.exitCodes){
                            $object | Add-Member -MemberType NoteProperty -Name 'validExitCodes' -Value $CustomData.exitCodes
                        }
                        If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
                        $ObjectArray += $object
                        #>
                        Write-Verbose ("Added command to run: {0} {1}" -f ("$FileCopyDest\Applications\$($CustomData.workingDirectory)\$($CustomData.executable)"), $CustomData.arguments)
                    }
                }

            }Else{

                $CommandParams = @{
                    FilePath="$FileCopyDest\Applications\$($CustomData.workingDirectory)\$($CustomData.executable)"
                }
                If($ExportPoshCmd){$CommandParams += @{ExportPoshCmd=$true}}
                If($CustomData.arguments.Length -gt 0){$CommandParams += @{Arguments=$CustomData.arguments}}
                If($CustomData.exitCodes){$CommandParams += @{ExitCodes=$CustomData.exitCodes}}

                $ObjectArray += ConvertTo-AIBLocalCommand @CommandParams
            }
        }

        'ModernApp' {

            # Step 1: Determine file retrieval
            #---------------------------------
            If($CustomData.appxDependency.count -gt 0){

                #if sas token exists and depency is a zip then use azcopy
                If(($CustomData.sasToken.length -gt 0) -and ([System.IO.Path]::GetExtension($CustomData.appxBundle[0]) -match "zip$")){
                    Foreach($appx in $CustomData.appxDependency | Where {$_ -ne $CustomData.appxBundle}){
                        #to use Blob shared access token, you must use Azcopy with sas token instead of uri copies
                        $InlineCommands = @(
                            "$FileCopyDest\azcopy.exe copy `"https://$BlobUrl/application-$($CustomData.workingDirectory.ToLower())/$($appx)?$($CustomData.sasToken)`" `"$FileCopyDest\ModernApps\$($CustomData.workingDirectory)\$appx`"",
                            "Expand-Archive -Path `"$FileCopyDest\ModernApps\$($CustomData.workingDirectory)\$appx`" -DestinationPath `"$FileCopyDest\ModernApps\$($CustomData.workingDirectory)`" -Force"
                        )

                        $object = New-Object -TypeName PSObject
                        $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
                        $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Extracting " + $appx)
                        $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
                        $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
                        $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
                        If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
                        $ObjectArray += $object

                        Write-Verbose ('Added {0} Azcopy to uri: https://' + $BlobURL + '/application-' + $CustomData.workingDirectory.ToLower() + '/' + $appx,([System.IO.Path]::GetExtension($appx)))
                    }#end loop appxdependency

                }Else{

                    #otherwise download each appx dependency plus the bundle files and license
                    $AppxFiles = @()
                    $AppxFiles += $CustomData.appxDependency
                    $AppxFiles += $CustomData.appxBundle
                    $AppxFiles += $CustomData.appxLicense

                    Foreach($appx in $AppxFiles){
                        $object = New-Object -TypeName PSObject
                        $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "File"
                        $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Copying " + $appx)
                        $object | Add-Member -MemberType NoteProperty -Name 'sourceUri' -Value ('https://' + $BlobURL + '/application-' + $CustomData.workingDirectory.ToLower()  + '/' + $appx)
                        $object | Add-Member -MemberType NoteProperty -Name 'destination' -Value ($FileCopyDest + '\ModernApps\' + $CustomData.workingDirectory + '\' + $appx)
                        #get local copy to determine hash
                        If( (Test-Path ('.\Application\' + $CustomData.workingDirectory + '\' + $appx)) -and !$SkipChecksum){
                            $CheckSum = Get-FileHash ('.\Application' + $CustomData.workingDirectory + '\' + $appx) | Select -ExpandProperty Hash
                            $object | Add-Member -MemberType NoteProperty -Name 'sha256Checksum' -Value $CheckSum
                        }
                        If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value "Invoke-WebRequest `"https://$BlobURL/application-$($CustomData.workingDirectory.ToLower())/$appx`" -OutFile `"$FileCopyDest\ModernApps\$($CustomData.workingDirectory)\$appx`""}
                        $ObjectArray += $object

                        Write-Verbose ("Added appx uri downloader: {0}" -f ($FileCopyDest + '\' + $CustomData.workingDirectory + '\' + $appx))
                    }
                }

                #build single line for all dependency packages
                $DependencyArgs =( $CustomData.appxDependency | %{'/DependencyPackagePath:"' + $FileCopyDest + '\ModernApps\' + $CustomData.workingDirectory + '\' + $_ + '"'}) -join ' '

                $InlineCommands = @(
                    "dism /online /add-provisionedappxpackage /PackagePath:`"$FileCopyDest\ModernApps\$($CustomData.workingDirectory)\$($CustomData.appxBundle)`" $DependencyArgs /LicensePath:`"$FileCopyDest\ModernApps\$($CustomData.workingDirectory)\$($CustomData.appxLicense)`""
                )
                $object = New-Object -TypeName PSObject
                $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
                $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Provisioning appx: " + $CustomData.appxBundle)
                $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
                $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
                $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
                If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
                $ObjectArray += $object
            }
        }

        'Archive' {

            #to use Blob shared access token, you must use Azcopy with sas token instead of uri copies
            If($CustomData.sasToken.length -gt 0){
                #Step 1,2,3: create working directory, Copy file using azcopy, and extract
                $InlineCommands = @(
                    "$FileCopyDest\azcopy.exe copy `"https://$BlobUrl/archive-$($CustomData.workingDirectory.ToLower())/$($CustomData.archiveFile)?$($CustomData.sasToken)`" `"$FileCopyDest\Archives\$($CustomData.workingDirectory)\$($CustomData.archiveFile)`"",
                    "Expand-Archive -Path `"$FileCopyDest\Archives\$($CustomData.workingDirectory)\$($CustomData.archiveFile)`" -DestinationPath `"$($CustomData.destination)`" -Force"
                )

                $object = New-Object -TypeName PSObject
                $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
                $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Extracting " + $CustomData.archiveFile)
                $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
                $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
                $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
                If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
                $ObjectArray += $object

                Write-Verbose ('Added {0} downloader to uri: https://' + $BlobURL + '/archive-' + $CustomData.workingDirectory.ToLower() + '/' + $CustomData.executable,([System.IO.Path]::GetExtension($CustomData.executable)))

            }Else{

                #Step 2: Copy file
                $object = New-Object -TypeName PSObject
                $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "File"
                $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Copying " + $CustomData.workingDirectory)
                $object | Add-Member -MemberType NoteProperty -Name 'sourceUri' -Value ('https://' + $BlobURL + '/archive-' + $CustomData.workingDirectory.ToLower()  + '/' + $CustomData.archiveFile)
                $object | Add-Member -MemberType NoteProperty -Name 'destination' -Value ($FileCopyDest + '\' + $CustomData.workingDirectory + '\' + $CustomData.archiveFile)
                If( (Test-Path ('.\Archives\' + $CustomData.workingDirectory + '\' + $CustomData.archiveFile)) -and !$SkipChecksum){
                    $CheckSum = Get-FileHash ('.\Archives\' + $CustomData.workingDirectory + '\' + $CustomData.archiveFile) | Select -ExpandProperty Hash
                    $object | Add-Member -MemberType NoteProperty -Name 'sha256Checksum' -Value $CheckSum
                }
                If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value "Invoke-WebRequest `"https://$BlobURL/archive-$($CustomData.workingDirectory.ToLower())/$($CustomData.archiveFile)`" -OutFile `"$FileCopyDest\Archives\$($CustomData.workingDirectory)\$($CustomData.archiveFile)`""}
                $ObjectArray += $object

                #Step 3. Extract file
                $InlineCommands = @(
                    "Expand-Archive -Path `"$FileCopyDest\Archives\$($CustomData.workingDirectory)\$($CustomData.archiveFile)`" -DestinationPath `"$($CustomData.destination)`" -Force"
                )
                $object = New-Object -TypeName PSObject
                $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
                $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Extracting " + $CustomData.archiveFile)
                $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
                $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
                $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
                If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
                $ObjectArray += $object
            }
        }

        'Command'{
            $CommandParams = @{
                FilePath=$CustomData.command
            }
            If($ExportPoshCmd){$CommandParams += @{ExportPoshCmd=$true}}
            If($CustomData.arguments.Length -gt 0){$CommandParams += @{Arguments=$CustomData.arguments}}
            If($CustomData.exitCodes){$CommandParams += @{ExitCodes=$CustomData.exitCodes}}

            $ObjectArray += ConvertTo-AIBLocalCommand @CommandParams
        }

        'PowerShell'{
            $object = New-Object -TypeName PSObject
            $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
            $object | Add-Member -MemberType NoteProperty -Name 'name' -Value $CustomData.name
            $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
            $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
            $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $CustomData.Commands
            If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $CustomData.Commands}
            $ObjectArray += $object
        }

        'LanguagePackage' {
            $ProvisionCommand = @()
            #https://docs.microsoft.com/en-us/azure/virtual-desktop/language-packs
            If($CustomData.packageDependency.count -gt 0){
                Foreach($package in $CustomData.packageDependency | Where {$_ -ne $CustomData.executable}){
                    $object = New-Object -TypeName PSObject
                    $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "File"
                    $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Copying " + $package)
                    $object | Add-Member -MemberType NoteProperty -Name 'sourceUri' -Value ('https://' + $BlobURL + '/package-' + $CustomData.languageLocale.ToLower() + '/' + $package)
                    $object | Add-Member -MemberType NoteProperty -Name 'destination' -Value ($FileCopyDest + '\Packages\' + $CustomData.languageLocale + '\' + $package)
                    If( (Test-Path ('.\Packages\' + $CustomData.languageLocale + '\' + $package)) -and !$SkipChecksum){
                        $CheckSum = Get-FileHash ('.\Packages\' + $CustomData.languageLocale + '\' + $package) | Select -ExpandProperty Hash
                        $object | Add-Member -MemberType NoteProperty -Name 'sha256Checksum' -Value $CheckSum
                    }
                    If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value @(
                            "Invoke-WebRequest `"https://$BlobURL/package-$($CustomData.languageLocale.ToLower())/$package`" -OutFile `"$FileCopyDest\Packages\$($CustomData.languageLocale)\$package`""
                        )
                    }
                    $ObjectArray += $object
                }
                $ProvisionCommand += "Add-WindowsPackage -Online -PackagePath `"$FileCopyDest\Packages\$($CustomData.languageLocale)\$package`""
            }

            #Step 3. Extract file
            $InlineCommands = @(
                "Add-AppProvisionedPackage -Online -PackagePath `"$FileCopyDest\Packages\$($CustomData.LanguageLocale)\LanguageExperiencePack.$($CustomData.languageLocale.ToLower()).Neutral.appx`" -LicensePath `"$FileCopyDest\Packages\$($CustomData.LanguageLocale)\License.xml`""
            )

            $InlineCommands += $ProvisionCommand
            $InlineCommands += @(
                "`$LanguageList = Get-WinUserLanguageList",
                "`$LanguageList.Add(`"$($CustomData.LanguageLocale.ToLower())`")",
                "Set-WinUserLanguageList `$LanguageList -force"
            )

            $object = New-Object -TypeName PSObject
            $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
            $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Adding Language pack for locale: " + $CustomData.LanguageLocale)
            $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
            $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
            $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
            If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
            $ObjectArray += $object
        }

        'Script' {
            $object = New-Object -TypeName PSObject
            $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
            $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ('Run' + $CustomData.name)
            $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
            $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
            $object | Add-Member -MemberType NoteProperty -Name 'scriptUri' -Value ('https://' + $BlobURL + '/scripts/' + $CustomData.scriptfile)
            If($CustomData.exitCodes){
                $object | Add-Member -MemberType NoteProperty -Name 'validExitCodes' -Value $CustomData.exitCodes
            }
            If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value @(
                    "Invoke-WebRequest `"https://$BlobURL/scripts/$($CustomData.scriptfile)`" -OutFile `"$FileCopyDest\Scripts\$($CustomData.scriptfile)`""
                    "& `"$FileCopyDest\Scripts\$($CustomData.scriptfile)`""
                )
            }
            $ObjectArray += $object
        }

        'Restart' {
            $object = New-Object -TypeName PSObject
            $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "WindowsRestart"
            $object | Add-Member -MemberType NoteProperty -Name 'restartCheckCommand' -Value "write-host 'restarting after $($CustomData.name)'"
            $object | Add-Member -MemberType NoteProperty -Name 'restartTimeout' -Value "5m"
            If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value "Restart-Computer -Timeout 5 -Wait -Force -WhatIf"}
            $ObjectArray += $object
        }

        'WindowsUpdate' {
            $Filters = @(
                "exclude:`$_.Title -like '*Preview*'",
                "include:`$true"
            )
            $object = New-Object -TypeName PSObject
            $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "WindowsUpdate"
            $object | Add-Member -MemberType NoteProperty -Name 'searchCriteria' -Value "IsInstalled=0"
            $object | Add-Member -MemberType NoteProperty -Name 'filters' -Value $Filters
            $object | Add-Member -MemberType NoteProperty -Name 'updateLimit' -Value 40
            If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value "# Do Windows Update"}
            $ObjectArray += $object
        }
    }

    #Step 5. Gen app working directory deletion
    If($Cleanup){
        $InlineCommands = @(
            "Remove-Item -path `"$FileCopyDest\$($CustomData.type)s\$($CustomData.workingDirectory)`" -recurse -ErrorAction SilentlyContinue"
        )
        $object = New-Object -TypeName PSObject
        $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
        $object | Add-Member -MemberType NoteProperty -Name 'name' -Value ("Removing folders")
        $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
        $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
        $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
        If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
        $ObjectArray += $object
    }

    #add an additional restart AIB customization if exists
    If( ($CustomData.restart -eq $True) -or ($CustomData.restartTimeout.length -gt 0) ){
        $object = New-Object -TypeName PSObject
        $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "WindowsRestart"
        If($CustomData.name.Length -gt 0){
            $object | Add-Member -MemberType NoteProperty -Name 'restartCheckCommand' -Value "write-host 'restarting after $($CustomData.name)'"
        }Else{
            $object | Add-Member -MemberType NoteProperty -Name 'restartCheckCommand' -Value "write-host 'restarting system'"
        }

        If($CustomData.restartTimeout.length -gt 0){
            $object | Add-Member -MemberType NoteProperty -Name 'restartTimeout' -Value $CustomData.restartTimeout
            If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value "Restart-Computer -Timeout $($CustomData.restartTimeout) -Wait -Force -WhatIf"}
        }ElseIf($CustomData.type -eq 'WindowsUpdate'){
            $object | Add-Member -MemberType NoteProperty -Name 'restartTimeout' -Value "10m"
            If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value "Restart-Computer -Timeout 10 -Wait -Force -WhatIf"}
        }Else{
            $object | Add-Member -MemberType NoteProperty -Name 'restartTimeout' -Value "5m"
            If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value "Restart-Computer -Timeout 5 -Wait -Force -WhatIf"}
        }
        $ObjectArray += $object
    }

    If($Passthru){
        $ObjectArray
    }Else{
        $Json = $ObjectArray | ConvertTo-Json
        #fix the \u0027 issue
        ([regex]'(?i)\\u([0-9a-h]{4})').Replace($Json, {param($Match) "$([char][int64]"0x$($Match.Groups[1].Value)")"})
    }

}


Function ConvertFrom-CustomSequence{
    <#
    .SYNOPSIS
    Convert sequence properties to AIB support format

    .NOTES


    .EXAMPLE
    $AIBTemplate = Get-Content "\\192.168.1.10\Development\GitHub\PowerShellCrack\PSAIBDeploymentToolkit\Control\Win10avdHardenedImage\aib.json" | Convertfrom-Json
    $SequenceData = $AIBTemplate.customSequence[0]
    ConvertFrom-CustomSequence -BlobURL $BlobUrl -SequenceData $SequenceData
    .LINK
    https://docs.microsoft.com/en-us/azure/virtual-machines/linux/image-builder-json?tabs=azure-powershell
    #>
    [CmdletBinding()]
    Param(
        $BlobURL,
        [System.Object[]]$SequenceData,
        [string]$FileCopyDest = "C:\Temp",
        [switch]$ProvisionVMMode,
        [switch]$ExportPoshCmd,
        [switch]$Passthru
    )

    $CustomSequences = @()

    #Step 1: Build working directories inline command
    If($SequenceData.type -match "Application|Archive|Script|Package|ModernApp"){
        $Name = "Build working directories"
        $InlineCommands = @(
                "New-Item `"$FileCopyDest`" -ItemType Directory -ErrorAction SilentlyContinue"
        )
        #build folder structure based on certain types
        Foreach($Data in $SequenceData | Where type -match "Application|Archive|Script|Package|ModernApp" ){
            $InlineCommands += @(
                "New-Item `"$FileCopyDest\$($Data.Type)s`" -ItemType Directory -ErrorAction SilentlyContinue"
            )
            #collect each working directory
            Foreach($directory in $Data.workingDirectory | Select -Unique){
                $InlineCommands += @(
                    "New-Item `"$FileCopyDest\$($Data.Type)s\$directory`" -ItemType Directory -ErrorAction SilentlyContinue"
                )
            }
        }

        $object = New-Object -TypeName PSObject
        $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
        $object | Add-Member -MemberType NoteProperty -Name 'name' -Value $Name
        $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
        $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
        $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
        #this is to export to ps1 file for testing
        If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
        $CustomSequences += $object
    }

    #to use Blob shared access token, you must use Azcopy. First is to download it
    If($SequenceData.sasToken.count -gt 0){
        $Name = "Get Azcopy"
        $InlineCommands = @(
            "Invoke-WebRequest -uri `"https://aka.ms/downloadazcopy-v10-windows`" -OutFile `"$FileCopyDest\azcopy.zip`"",
            "Expand-Archive `"$FileCopyDest\azcopy.zip`" `"$FileCopyDest`"",
            "Copy-Item `"$FileCopyDest\azcopy_windows_amd64_*\azcopy.exe\`" -Destination `"$FileCopyDest`"",
            "Remove-Item `"$FileCopyDest\azcopy_windows_amd64_*`" -Recurse -ErrorAction SilentlyContinue"
        )
        $object = New-Object -TypeName PSObject
        $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
        $object | Add-Member -MemberType NoteProperty -Name 'name' -Value $Name
        $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
        $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
        $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
        #this is to export to ps1 file for testing
        If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
        $CustomSequences += $object
    }

    #collect all data types of Modules and build a single inline command
    If("Module" -in $SequenceData.type){
        $InlineCommands = @()
        #TEST $Repo = ($SequenceData.trustedRepos | Select -Unique).Psobject.properties
        Foreach($Repo in ($SequenceData.trustedRepos | Select -Unique).Psobject.properties){
            $InlineCommands += @(
                "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
                "Install-PackageProvider -Name Nuget -ForceBootstrap -RequiredVersion '2.8.5.201' -Force | Out-Null",
                "If(`$PSRepo = Get-PSRepository -Name `"$($Repo.Name)`"){If(`$PSRepo.InstallationPolicy -ne 'Trusted'){Set-PSRepository -Name `"$($Repo.Name)`" -InstallationPolicy Trusted}}Else{Register-PSRepository -Name `"$($Repo.Name)`" -SourceLocation `"$($Repo.Value)`" -InstallationPolicy Trusted}"
            )
        }
        $Modules = ($SequenceData.modules | Select -Unique) -Join ','
        $InlineCommands += @(
            "Install-Module -Name $Modules -Scope AllUsers -Force",
            "Import-Module -Name $Modules -Global -Force"
        )
        #Step 1: Gen inline to set repository to trusted
        $object = New-Object -TypeName PSObject
        $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
        $object | Add-Member -MemberType NoteProperty -Name 'name' -Value "Install Modules"
        $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
        $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
        $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
        #this is to export to ps1 file for testing
        If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
        $CustomSequences += $object
    }

    #loop through aib.json CustomSequence section and generate in AIB format
    <# TEST
    $Sequence = $SequenceData[0]
    $CustomData = $Params.CustomData
    #>
    Foreach($Sequence in $SequenceData){
        $Params = @{
            BlobURL=$BlobURL
            FileCopyDest=$FileCopyDest
            CustomData=$Sequence
            SkipCheckSum=$true
        }
        If($Passthru){$Params += @{Passthru=$True}}
        If($ExportPoshCmd){$Params += @{ExportPoshCmd=$True}}
        If($VerbosePreference){$Params += @{Verbose=$True}}

        $CustomSequences += ConvertTo-AIBCustomization @Params
    }


    If($ProvisionVMMode){
        # Fix for first login delays due to Windows Module Installer
         $InlineCommands = @(
            "((Get-Content -path C:\DeprovisioningScript.ps1 -Raw) -replace 'Sysprep.exe /oobe /generalize /quiet /quit', 'Sysprep.exe /oobe /generalize /quit /mode:vm' ) | Set-Content -Path C:\DeprovisioningScript.ps1"
        )
         #Step 1: Gen inline to set repository to trusted
         $object = New-Object -TypeName PSObject
         $object | Add-Member -MemberType NoteProperty -Name 'type' -Value "PowerShell"
         $object | Add-Member -MemberType NoteProperty -Name 'name' -Value "Edit Deprovisioing"
         $object | Add-Member -MemberType NoteProperty -Name 'runElevated' -Value $True
         $object | Add-Member -MemberType NoteProperty -Name 'runAsSystem' -Value $True
         $object | Add-Member -MemberType NoteProperty -Name 'inline' -Value $InlineCommands
         If($ExportPoshCmd){$object | Add-Member -MemberType NoteProperty -Name 'PoshCommand' -Value $InlineCommands}
         $CustomSequences += $object
    }

    If($Passthru){
        $CustomSequences
    }Else{
        $Json = $CustomSequences | ConvertTo-Json
        #fix the \u0027 issue
        ([regex]'(?i)\\u([0-9a-h]{4})').Replace($Json, {param($Match) "$([char][int64]"0x$($Match.Groups[1].Value)")"})
    }
}



Function ConvertTo-PoshCommands{
    Param(
        $BlobURL,
        [string]$FileCopyDest = "C:\Temp",
        [System.Object[]]$SequenceData
    )
    $Commands = @()
    $Commands += "##*============================================="
    $Commands += "# FOR TESTING ONLY: RUN ON REFERENCE IMAGE"
    $Commands += "##*============================================="
    $Commands += "# Build working directory"
    $Commands += "`$ErrorActionPreference = `"Stop`""
    $Commands += "New-Item `"$FileCopyDest`" -ItemType Directory -ErrorAction SilentlyContinue"
    #collect each working directory
    Foreach($Data in $SequenceData | Where type -match "Application|Archive|Script|Package|ModernApp" ){
        $Commands += @(
            "New-Item `"$FileCopyDest\$($Data.Type)s`" -ItemType Directory -ErrorAction SilentlyContinue"
        )
        #collect each working directory
        Foreach($directory in $Data.workingDirectory | Select -Unique){
            $Commands += @(
                "New-Item `"$FileCopyDest\$($Data.Type)s\$directory`" -ItemType Directory -ErrorAction SilentlyContinue"
            )
        }
    }

    #to use Blob shared access token, you must use Azcopy. First is to download it
    If($SequenceData.runAsSystem -gt $true){
        $Commands += "# get PSexec"
        $Commands += @(
            "Invoke-WebRequest -uri `"https://download.sysinternals.com/files/PSTools.zip`" -OutFile `"$FileCopyDest\PSTools.zip`"",
            "Expand-Archive `"$FileCopyDest\PSTools.zip`" `"$FileCopyDest`"",
            "Expand-Archive `"C:\temp\PSTools.zip`" `"$FileCopyDest`""
            "Remove-Item -Path `"$FileCopyDest\*.*`" -Exclude psexec* -Force"
            "Remove-Item `"$FileCopyDest\PSTools.zip`" -ErrorAction SilentlyContinue"
        )
        $Commands += ''
    }

    #to use Blob shared access token, you must use Azcopy. First is to download it
    If($SequenceData.sasToken.count -gt 0){
        $Commands += "# get Azcopy"
        $Commands += @(
            "Invoke-WebRequest -uri `"https://aka.ms/downloadazcopy-v10-windows`" -OutFile `"$FileCopyDest\azcopy.zip`"",
            "Expand-Archive `"$FileCopyDest\azcopy.zip`" `"$FileCopyDest`"",
            "Get-ChildItem `"$FileCopyDest`" -Recurse -Filter azcopy.exe | Copy-Item -Destination `"$FileCopyDest`" -Force",
            "Remove-Item `"$FileCopyDest\azcopy_windows_amd64_*`" -Recurse -ErrorAction SilentlyContinue"
            "Remove-Item `"$FileCopyDest\azcopy.zip`" -ErrorAction SilentlyContinue"
        )
        $Commands += ''
    }

    If("Module" -in $SequenceData.type){
        Foreach($Repo in $SequenceData.trustedRepos | Select -Unique){
            $Commands += "# Update modules support"
            $Commands += @(
                "Set-PSRepository -Name `"$Repo`" -InstallationPolicy Trusted",
                "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
                "Install-PackageProvider -Name Nuget -Scope AllUsers -Force"
            )
        }

        $Modules = ($SequenceData.modules | Select -Unique) -Join ','
        $Commands += @(
            "Install-Module -Name $Modules -Scope AllUsers -Force",
            "Import-Module -Name $Modules -Global -Force"
        )
        $Commands += ''
    }

    Foreach($Sequence in $SequenceData){
        If($Sequence.Name){$Commands += "# $($Sequence.Name)"}
        $Commands += (ConvertTo-AIBCustomization -BlobURL $BlobURL -FileCopyDest $FileCopyDest -CustomData $Sequence -Passthru -SkipCheckSum -ExportPoshCmd).PoshCommand
        $Commands += ''
    }


    return $Commands
}

<#
. .\Scripts\Sequencer.ps1

$BlobUrl = (Get-Content .\Control\settings-ritracyi-gov.json -raw | ConvertFrom-Json).Resources.resourceBlobURI
$SequenceData = Get-Content .\Control\Win10avdTestImage\aib.json -raw | ConvertFrom-Json | Select -expandProperty customSequence
$SequenceData = Get-Content .\Control\Win10avdBaselineImage\aib.json -raw | ConvertFrom-Json | Select -expandProperty customSequence
$SequenceData = Get-Content .\Control\Win10avdSimpleImage\aib.json -raw | ConvertFrom-Json | Select -expandProperty customSequence
$SequenceData = Get-Content .\Control\Win10avdHardenedImage\aib.json -raw | ConvertFrom-Json | Select -expandProperty customSequence
$SequenceData = Get-Content .\Control\Win10avdMarketImage\aib.json -raw | ConvertFrom-Json | Select -expandProperty customSequence
$SequenceData = Get-Content .\Control\Win11avdDevBox\aib.json -raw | ConvertFrom-Json | Select -expandProperty customSequence
[System.Object[]]$CustomData = $SequenceData | Where Type -eq 'Application' | Select -first 1
[System.Object[]]$CustomData = $SequenceData | Where Type -eq 'Script' | Select -first 1

$Customizations = ConvertFrom-CustomSequence -BlobURL $BlobUrl -SequenceData $SequenceData -ProvisionVMMode -Passthru
$Customizations | COnvertTo-Json
ConvertTo-PoshCommands -BlobURL $BlobUrl -SequenceData $SequenceData
#>
