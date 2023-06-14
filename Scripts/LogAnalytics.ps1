#region send data to log analytics
Function Send-LogAnalyticsData {
	<#
   .SYNOPSIS
	   Send log data to Azure Monitor by using the HTTP Data Collector API

   .DESCRIPTION
	   Send log data to Azure Monitor by using the HTTP Data Collector API

   .NOTES
	   Author:      Jan Ketil Skanke
	   Contact:     @JankeSkanke
	   Created:     2022-01-14
	   Updated:     2022-01-14

	   Version history:
	   1.0.0 - (2022-01-14) Function created
   #>
   param(
		[string]$WorkspaceId,
   		[string]$WorkspaceKey,
		[array]$Body,
		[string]$LogType,
        [ValidateSet('AzureUSPublic','AzureUSGovernment')]
        [string]$Cloud,
        $TimeStampField = ""
   )
   #Defining method and datatypes
   $method = "POST"
   $contentType = "application/json"
   $date = [DateTime]::UtcNow.ToString("r")
   $contentLength = $Body.Length
   #Construct authorization signature
   $xHeaders = "x-ms-date:" + $date
   $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource
   $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
   $keyBytes = [Convert]::FromBase64String($WorkspaceKey)
   $sha256 = New-Object System.Security.Cryptography.HMACSHA256
   $sha256.Key = $keyBytes
   $calculatedHash = $sha256.ComputeHash($bytesToHash)
   $encodedHash = [Convert]::ToBase64String($calculatedHash)
   $signature = 'SharedKey {0}:{1}' -f $WorkspaceId, $encodedHash

   switch($Cloud){
    'AzureUSPublic' {$Endpoint = "ods.opinsights.azure.com";$ApiVersion = "2016-04-01"}
    'AzureUSGovernment' {$Endpoint = "ods.opinsights.azure.us";$ApiVersion = "2016-04-01"}
   }

   #Construct uri
   $uri = "https://" + $WorkspaceId + '.' + $Endpoint + '/api/logs?api-version=' + $ApiVersion

   #validate that payload data does not exceed limits
   if ($Body.Length -gt (31.9 *1024*1024))
   {
	   throw("Upload payload is too big and exceed the 32Mb limit for a single upload. Please reduce the payload size. Current payload size is: " + ($Body.Length/1024/1024).ToString("#.#") + "Mb")
   }
   $payloadsize = ("Upload payload size is " + ($Body.Length/1024).ToString("#.#") + "Kb ")

   #Create authorization Header
   $headers = @{
	   "Authorization"        = $signature;
	   "Log-Type"             = $LogType;
	   "x-ms-date"            = $date;
	   "time-generated-field" = $TimeStampField;
   }
   #Sending data to log analytics
   $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $Body -UseBasicParsing
   $statusmessage = "$($response.StatusCode) : $($payloadsize)"
   return $statusmessage
}
#endregion

Function Write-AIBStatus {
    param(
		[string]$WorkspaceId,
   		[string]$WorkspaceKey,
		[string]$DeploymentName,
        [string]$RunOutputName,
        [string]$TemplateName,
        [string]$ImageName,
        [string]$ImageVersion,
        $JsonTemplate,
        [int]$CustomizationCount,
        $CustomizationList,
        $StartDateTime,
        $EndDateTime,
        $TotalTime,
        [string]$Status,
        [string]$Message,
        [ValidateSet('AzureUSPublic','AzureUSGovernment')]
        [string]$Cloud,
        [switch]$Passthru

   )
    <#
    SAMPLE
    $WorkspaceId = $Settings.LogAnalytics.workspaceId
    $WorkspaceKey = $Settings.LogAnalytics.WorkspaceKey
    $DeploymentName = $TemplateConfigs.Template.imageTemplateName
    $TemplateName = $TemplateConfigs.Template.imageTemplateName
    $JsonTemplate = $FormattedAIBTemplate
    $CustomizationCount = $TemplateData.resources.properties.customize.count
    $ImageName = $TemplateConfigs.ImageDefinition.Name
    $RunOutputName = $buildOutputName
    $ImageVersion = $NewVersion
    $StartDateTime = $StartTime
    $EndDateTime = $endTime
    $TotalTime = $totalTime
    $Status = $AzAIBTemplate.LastRunStatusRunState
    $Message = $AzAIBTemplate.LastRunStatusMessage

    #>
    $StatusData = New-Object -TypeName PSObject
    $StatusData | Add-Member -MemberType NoteProperty -Name "DeploymentName" -Value $DeploymentName -Force
    $StatusData | Add-Member -MemberType NoteProperty -Name "TemplateName" -Value $TemplateName -Force
    $StatusData | Add-Member -MemberType NoteProperty -Name "RunOutputName" -Value $RunOutputName -Force
    $StatusData | Add-Member -MemberType NoteProperty -Name "ImageName" -Value $ImageName -Force
    $StatusData | Add-Member -MemberType NoteProperty -Name "ImageVersion" -Value $ImageVersion -Force
    $StatusData | Add-Member -MemberType NoteProperty -Name "JsonTemplate" -Value $JsonTemplate -Force
    $StatusData | Add-Member -MemberType NoteProperty -Name "CustomizationSteps" -Value $CustomizationCount -Force
    #$StatusData | Add-Member -MemberType NoteProperty -Name "CustomizationList" -Value $CustomizationList -Force
    $StatusData | Add-Member -MemberType NoteProperty -Name "Start" -Value $StartDateTime -Force
    $StatusData | Add-Member -MemberType NoteProperty -Name "End" -Value $EndDateTime -Force
    $StatusData | Add-Member -MemberType NoteProperty -Name "ElapsedTime" -Value $TotalTime -Force
    $StatusData | Add-Member -MemberType NoteProperty -Name "Status" -Value $Status -Force
    $StatusData | Add-Member -MemberType NoteProperty -Name "Message" -Value $Message -Force

	# Convert to jSON before sending data
	$AIBDataPayload = $StatusData | ConvertTo-Json
    #$Body=([System.Text.Encoding]::UTF8.GetBytes($AIBDataPayload))
    #$LogType="AIBDeploymentStatus"
	# Sending the data to Log Analytics Workspace
	$ResponseAIBDeploymentStatus = Send-LogAnalyticsData -WorkspaceId $WorkspaceId -WorkspaceKey $WorkspaceKey -Body ([System.Text.Encoding]::UTF8.GetBytes($AIBDataPayload)) -LogType "AIBDeploymentStatus" -Cloud $Cloud

	if ($ResponseAIBDeploymentStatus -match "200 :") {

		$OutputMessage = $OutPutMessage + " AIBDeploymentStatus:OK " + $ResponseAIBDeploymentStatus
	}
	else {
		$OutputMessage = $OutPutMessage + " AIBDeploymentStatus:Fail "
	}
    If($Passthru){
        Return $Status
    }
}


Function Find-CustomizationLogEntry{
    Param(
        # Folder of logs to parse
        $LogFolder = ".\Logs\customization.log",
        [string[]]$Strings = @('(telemetry)','ended with'),
        $Extension = ".log"
    )

    # Finding all logs in the folder (add -Recurse to get all logs in sub folders too)
    $Logs = Get-ChildItem -Path $LogFolder | Where {$_.Name -match $Extension} | Select Name,FullName
    # Counting log files
    $LogCount = $Logs  | Measure | Select -ExpandProperty Count
    $LogCounter = 0
    # Creating array to store results
    $LogResults = [System.Collections.ArrayList]@()
    # Parsing each log
    ForEach ($Log in $Logs)
    {
        $LogCounter ++
        # Setting variables
        $LogName = $Log.Name
        $LogPath = $Log.FullName
        # Output to host
        "ProcessingLog: $LogCounter/$LogCount
        File: $LogName"
        # Loading the log content
        $LogContent = Get-Content $LogPath
        # For each string to match, checking log
        ForEach($String in $Strings)
        {
            # Finding matches
            $FoundMatches = $LogContent | Select-String -Pattern $String
            # loop through each find
            ForEach($item in $FoundMatches)
            {
                $StringFound = $LogContent | Select-String -Pattern $String | Select -First 1
                # Adding to array
                $LogResult = New-Object PSObject
                $LogResult | Add-Member -MemberType NoteProperty -Name "String" -Value $String
                $LogResult | Add-Member -MemberType NoteProperty -Name "Message" -Value $StringFound
                $LogResult | Add-Member -MemberType NoteProperty -Name "Log" -Value $LogName
                $LogResult | Add-Member -MemberType NoteProperty -Name "Path" -Value $LogPath
                $LogResults.Add($LogResult) | Out-Null
            }
        }
        # End of for each log file below
    }
    # End of for each log file above
    #
    # Showing result
    $LogResults | Sort Matches -Desc | Format-Table -AutoSize
}


Function Send-AIBMessage{
    Param(
        [string]$TemplateName,
        [string]$ResourceGroup,
        [string]$Message,
        [ValidateSet(1,2,3)]
        [int16]$Severity = 3,
        [switch]$Cleanup,
        [switch]$BreakonError,
        [switch]$Passthru
    )

    switch($Severity){
        1 {$FgColor = 'Green'}
        2 {$FgColor = 'Yellow'}
        3 {$FgColor = 'Red'}
        default {$FgColor = 'Red'}
    }

    If($Message){
        If($BreakonError -and ($Severity -eq 3)){
            Write-Host ("{0}" -f $Message) -ForegroundColor Black -BackgroundColor Red
        }Else{
            Write-Host ("{0}" -f $Message) -ForegroundColor $FgColor
        }
    }

    If($Cleanup){
        If(Get-AzImageBuilderTemplate -ResourceGroupName $ResourceGroup -Name $TemplateName -ErrorAction SilentlyContinue){
            Try{
                Write-Host ("Removing Azure Image template [{0}]..." -f $TemplateName) -ForegroundColor Yellow -NoNewline
                Remove-AzImageBuilderTemplate -ResourceGroupName $ResourceGroup -ImageTemplateName $TemplateName | Out-Null
                Write-Host "Done" -ForegroundColor Green
                $CleanupCompleted = $true
            }
            Catch{
                Write-Host ("Failed: {0}" -f $_.Exception.message) -BackgroundColor Red
                $CleanupCompleted = $false
            }
        }
    }

    If($BreakonError -and ($Severity -eq 3)){
        Stop-Transcript;Break
    }

    If($Passthru){
        Return $CleanupCompleted
    }
}

#https://docs.microsoft.com/en-us/azure/automation/automation-send-email
