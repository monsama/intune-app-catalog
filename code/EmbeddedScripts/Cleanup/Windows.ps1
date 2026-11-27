function Get-CleanupTargets {
    # What "Remove Windows extras" removes (2.38.77): the Store apps Windows comes with that a work PC doesn't need -
    # games and Xbox, consumer apps and the ones Microsoft promotes. For every user, and from the image, so a new user
    # doesn't get them again. Package names; * is a wildcard. Edit it here and in the detection rule alike.
    return @{
        Name     = 'Windows'
        Programs = @()
        Packages = @(
            # Games and Xbox (the Game Bar too).
            'Microsoft.XboxApp', 'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxSpeechToTextOverlay', 'Microsoft.Xbox.TCUI',
            'Microsoft.MicrosoftSolitaireCollection',
            # Microsoft's extras.
            'Clipchamp.Clipchamp', 'Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Microsoft.GetHelp', 'Microsoft.Getstarted',
            'Microsoft.WindowsFeedbackHub', 'Microsoft.Todos', 'Microsoft.PowerAutomateDesktop', 'MicrosoftCorporationII.MicrosoftFamily', 'Microsoft.People',
            'Microsoft.WindowsMaps', 'Microsoft.ZuneVideo', 'Microsoft.549981C3F5F10',
            # Mail: Outlook comes with Microsoft 365 - the old Mail and Calendar and the new Outlook for Windows go.
            'microsoft.windowscommunicationsapps', 'Microsoft.OutlookForWindows',
            # Teams (free), the personal one - Teams for work and school is MSTeams and stays.
            'MicrosoftTeams',
            # Mixed Reality and 3D.
            'Microsoft.MixedReality.Portal', 'Microsoft.Microsoft3DViewer', 'Microsoft.MSPaint',
            # Apps Windows promotes (installed by the Store on first sign-in on some editions).
            'king.com.*', 'SpotifyAB.SpotifyMusic', 'Disney.*', 'Facebook.*', '*.Instagram', 'BytedancePte.Ltd.TikTok', 'AmazonVideo.PrimeVideo', '4DF9E0F8.Netflix', '*.LinkedInforWindows'
        )
        # Never removed: the Store and what other apps need, and Windows' own tools.
        Keep         = @()
        KeepPackages = @('Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.DesktopAppInstaller', 'Microsoft.VCLibs*', 'Microsoft.UI.Xaml*', 'Microsoft.NET.Native*',
            'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.WindowsNotepad', 'Microsoft.Paint', 'Microsoft.ScreenSketch', 'Microsoft.WindowsTerminal',
            'Microsoft.WindowsCamera', 'Microsoft.WindowsSoundRecorder', 'Microsoft.WindowsAlarms', 'Microsoft.CompanyPortal', 'MSTeams', 'Microsoft.MicrosoftEdge*', 'Microsoft.XboxIdentityProvider')
        McAfeeTool = $false
        NoUninstaller = @()
    }
}
