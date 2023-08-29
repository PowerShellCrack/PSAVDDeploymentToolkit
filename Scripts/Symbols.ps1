Function Get-Symbol{
    Param(
    [ValidateSet(   'AccessDenied',
                    'Alert',
                    'Announcement',
                    'Clipboard',
                    'Cloud',
                    'Enveloppe',
                    'Folder',
                    'GreenCheckmark',
                    'Hourglass',
                    'Information',
                    'Lightbulb',
                    'Lock',
                    'MagnifyingGlass',
                    'Package',
                    'Pencil',
                    'Planet',
                    'Police',
                    'RedX',
                    'Report',
                    'Rocket',
                    'Script',
                    'SmallBlueBullet',
                    'Snowflake',
                    'Speech',
                    'Target',
                    'WarningSign',
                    'Watch',
                    'Whale',
                    'WhiteCircle',
                    'YellowCircle'
    )]
    [string]$Symbol
    )

    switch($Symbol){
       'AccessDenied' { Return [char]::ConvertFromUtf32(0x1F6AB)}
       'Alert' { Return [char]::ConvertFromUtf32(0x1F514)}
       'Announcement' { Return [char]::ConvertFromUtf32(0x1F4E2)}
       'Clipboard' { Return [char]::ConvertFromUtf32(0x1F4CB)}
       'Cloud' { Return [char]::ConvertFromUtf32(0x2601)}
       'Enveloppe' { Return [char]::ConvertFromUtf32(0x2709)}
       'Folder' { Return [char]::ConvertFromUtf32(0x1F4C1)}
       'GreenCheckmark' { Return [char]::ConvertFromUtf32(0x2705)}
       'Hourglass' { Return [char]::ConvertFromUtf32(0x231B)}
       'Information' { Return [char]::ConvertFromUtf32(0x2139)}
       'Lightbulb' { Return [char]::ConvertFromUtf32(0x1F4A1)}
       'Lock' { Return [char]::ConvertFromUtf32(0x1F512)}
       'MagnifyingGlass' { Return [char]::ConvertFromUtf32(0x1f50d)}
       'Package' { Return [char]::ConvertFromUtf32(0x1F4E6)}
       'Pencil' { Return [char]::ConvertFromUtf32(0x270F)}
       'Planet' { Return [char]::ConvertFromUtf32(0x1F30F)}
       'Police' { Return [char]::ConvertFromUtf32(0x1F46E)}
       'RedX' { Return [char]::ConvertFromUtf32(0x274C)}
       'Report' { Return [char]::ConvertFromUtf32(0x1F4CA)}
       'Rocket' { Return [char]::ConvertFromUtf32(0x1F680)}
       'Script' { Return [char]::ConvertFromUtf32(0x1F4DC)}
       'SmallBlueBullet' { Return [char]::ConvertFromUtf32(0x1F539)}
       'Snowflake' { Return [char]::ConvertFromUtf32(0x2744)}
       'Speech' { Return [char]::ConvertFromUtf32(0x1F4AC)}
       'Target' { Return [char]::ConvertFromUtf32(0x1F3AF)}
       'WarningSign' { Return [char]::ConvertFromUtf32(0x26A0)}
       'Watch' { Return [char]::ConvertFromUtf32(0x231A)}
       'Whale' { Return [char]::ConvertFromUtf32(0x1F40B)}
       'WhiteCircle' { Return [char]::ConvertFromUtf32(0x26AA)}
       'YellowCircle' { Return [char]::ConvertFromUtf32(0x1F7E1)}
    }

}
