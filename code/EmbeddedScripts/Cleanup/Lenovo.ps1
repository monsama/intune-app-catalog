function Get-CleanupTargets {
    # What "Remove preinstalled vendor apps - Lenovo" removes (2.38.58). Name and Publisher take * as a wildcard;
    # Publisher may list several. Programs are removed in this order. Edit it here and in the detection rule alike.
    return @{
        Name     = 'Lenovo'
        Programs = @(
            @{ Name = 'McAfee WebAdvisor*'; Publisher = '*McAfee*' }
            @{ Name = 'McAfee*'; Publisher = '*McAfee*' }
            @{ Name = 'Lenovo Now*'; Publisher = '*Lenovo*' }
            @{ Name = 'Lenovo AI Now*'; Publisher = '*Lenovo*' }
            @{ Name = 'AI Now*'; Publisher = '*Lenovo*' }
            @{ Name = 'Lenovo Smart Meeting*'; Publisher = '*Lenovo*' }
            @{ Name = 'Smart Connect*'; Publisher = @('*Motorola*', '*Lenovo*') }
            @{ Name = 'Motorola Smart Connect*'; Publisher = '' }
        )
        # Store apps by package name (McAfee's is 5A894077.McAfeeSecurity, Lenovo's start with E046963F.).
        Packages = @('*McAfee*', '*LenovoNow*', '*AINow*', '*SmartMeeting*', '*SmartConnect*')
        # Never removed, even when a pattern above matches.
        Keep         = @('Lenovo Vantage*', 'Lenovo System Update*', 'Lenovo Commercial Vantage*')
        KeepPackages = @('*LenovoCompanion*', '*LenovoSettings*', '*LenovoCommercialVantage*')
        # McAfee's suite needs McAfee's removal tool (mccleanup.exe) in the packages folder - see the log.
        McAfeeTool = $true
        # Uninstallers that only ask (McAfee's suite: "tell us why you uninstall McAfee") - never started.
        NoUninstaller = @('*mcuihost.exe*', '*\McAfee\MSC\*')
    }
}
