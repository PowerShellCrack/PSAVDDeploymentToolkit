try
{
    "Logging in to Azure..."
    #user when runing in Azure Automation
    #Connect-AzAccount -Identity -Environment AzureUSGovernment
    #Use this when running in PowerShell
    Connect-AzAccount -Environment AzureUSGovernment
}
catch {
    Write-Error -Message $_.Exception
    throw $_.Exception
}


#all VMs
$AllVms = Get-AzVM
#$AllResources = Get-AzResource
Write-Output ("Found {0} VM's" -f $AllVms.Count)

# Get the StartupOrder tag, if missing set to be run last (10)
$taggedVMs = @{}

# Grab all Virtual Machines with tags
# any VM with StartupOrder=0 will be skipped
ForEach ($vm in $AllVMs | Where Tags -ne $null) {

    If($null -ne $vm.Tags['StartupOrder']){
        if ($vm.Tags['StartupOrder'] -eq 0)
        {
            Write-Output ('VM [{0}] has [StartupOrder] tag value: 0; ignoring' -f $vm.name)
            Continue
            #do not add vm to list
            #$startupValue = $vm.Tags['StartupOrder']
        }
        Else
        {
            Write-Output ('VM [{0}] has [StartupOrder] tag value: {1}' -f $vm.name,$vm.Tags['StartupOrder'])
            $taggedVMs.Add($vm.name,$vm.Tags['StartupOrder'])
        }
    }Else{
        Write-Output ('VM [{0}] has no [StartupOrder] tag; ignoring' -f $vm.name)
        Continue
    }

}

#display vm with tags
Write-Output "Unordered VMs:"
$taggedVMs

#get max value of startup count and make that the start if the next loop
$StartupEndCount = $taggedVMs.values | Measure-Object -Maximum | Select -ExpandProperty Maximum

#increment number to tag that are null
foreach($key in $taggedVMs.Keys.Clone()){
    If ($taggedVMs[$key] -eq $null)
    {
        $StartupEndCount = $StartupEndCount + 1
        Write-Output ('Adding tag: {0}={1}' -f $key,$StartupEndCount)
        $taggedVMs[$key] += $StartupEndCount
    }
}

#display vm with tags
$OrderedVMs = $taggedVMs.GetEnumerator() | Sort-Object {[int]($_.Value -replace '(\d+).*', '$1')}

Write-Output "Startup order:"
$OrderedVMs.Key

# Start in order from 0 (will start with 1 on first iteration)
# this will ensure the count will equal ending startup number
$current = 0
#TEST ITERATION: $current = 2
Do{
    $current++
    #Always null VM to start
    $tobeStarted = $null
    # Get the VM tag that matched current iteration
    $tobeStarted = $taggedVMs.GetEnumerator().Where({$_.Value -eq $current}) | Select -ExpandProperty Key
    If($tobeStarted)
    {
        #Grab resource id from VM
        $VMResourceID = $AllVms | Where Name -eq $tobeStarted | Select -ExpandProperty ID

        Write-Output ("Starting VM [{0}] at [{1}]..." -f $tobeStarted,(Get-Date))
        Start-AzVM -id $VMResourceID -NoWait
        #Start-AzVM -id $VMResourceID -AsJob
    }
    Else{
        Write-Output ("No VM found with StartupOrder: {0}" -f $current)
    }

}
Until ($current -eq $StartupEndCount)