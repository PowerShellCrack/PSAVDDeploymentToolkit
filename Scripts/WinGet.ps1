
function Get-WinGetList {
    <#
    .SYNOPSIS
        Gets winget list to psobject

    .EXAMPLE
        Get-WinGetList

        This example retrieves all software identified by winget

    .LINK
        ConvertFrom-FixedColumnTable
        Test-VSCode
        Test-IsISE
    #>
    $OriginalEncoding = [Console]::OutputEncoding
    If(Test-VSCode -eq $false -and Test-IsISE -eq $false){
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
    }

    # filter out progress-display and header-separator lines
    (winget list --accept-source-agreements) -match '^\p{L}' | ConvertFrom-FixedColumnTable

    #restore encoding settings
    If(Test-VSCode -eq $false -and Test-IsISE -eq $false){
        [Console]::OutputEncoding =  $OriginalEncoding
    }

}

function Get-WinGetUpgradeAvailable {
    <#
    .SYNOPSIS
        Gets winget apps that have an upgrade

    .EXAMPLE
        Get-WinGetUpgradeAvailable

        This example retrieves all software that has an available update

    .LINK
        ConvertFrom-FixedColumnTable
        Get-WinGetList
        Test-VSCode
        Test-IsISE
    #>
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)] $Id
    )
    Begin{
        $OriginalEncoding = [Console]::OutputEncoding
        If(Test-VSCode -eq $false -and Test-IsISE -eq $false){
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
        }

        # filter out progress-display and header-separator lines
        $List = Get-WinGetList

        $Upgradable = @()
    }
    Process{
        If($Id){
            $List += (winget list --id $Id) -split '`n'| Select -Skip 2 | ConvertFrom-FixedColumnTable
        }Else{
            #TEST $Item = $List | Where Available -ne '' | Select -first 1
            Foreach($Item in $List | Where Available -ne ''){
                Write-Verbose ("Searching {0}" -f $Item.Id)
                # filter out first two lines lines
                $Upgradable += (winget list --id $Item.Id) -split '`n'| Select -Skip 2 | ConvertFrom-FixedColumnTable
            }
        }
    }
    End{
        #restore encoding settings
        If(Test-VSCode -eq $false -and Test-IsISE -eq $false){
            [Console]::OutputEncoding =  $OriginalEncoding
        }
        Return $Upgradable
    }
}