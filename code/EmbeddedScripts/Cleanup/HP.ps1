function Get-CleanupTargets {
    # What "Remove preinstalled vendor apps - HP" removes (2.38.58): HP Wolf Security and HP's add-ons; HP Support
    # Assistant and what drivers, keys, audio, docks and the BIOS need stay. Name and Publisher take * as a wildcard.
    # Programs are removed in this order - HP Wolf Security's parts first, the console before what it needs.
    # Edit it here and in the detection rule alike.
    return @{
        Name     = 'HP'
        Programs = @(
            @{ Name = 'HP Wolf Security'; Publisher = '*HP*' }
            @{ Name = 'HP Wolf Security - Console'; Publisher = '*HP*' }
            @{ Name = 'HP Sure Click*'; Publisher = '*HP*' }
            @{ Name = 'HP Sure Sense*'; Publisher = '*HP*' }
            @{ Name = 'HP Sure Run*'; Publisher = '*HP*' }
            @{ Name = 'HP Sure Recover*'; Publisher = '*HP*' }
            @{ Name = 'HP Wolf Security*'; Publisher = '*HP*' }
            @{ Name = 'HP Client Security Manager*'; Publisher = '*HP*' }
            @{ Name = 'HP Security Update Service*'; Publisher = '*HP*' }
            @{ Name = 'HP Connection Optimizer*'; Publisher = '*HP*' }
            @{ Name = 'HP Documentation*'; Publisher = '*HP*' }
            @{ Name = 'HP Notifications*'; Publisher = '*HP*' }
            @{ Name = 'HP Insights*'; Publisher = '*HP*' }
            @{ Name = 'HP Presence Video*'; Publisher = '*HP*' }
            @{ Name = 'HP PC Hardware Diagnostics Windows*'; Publisher = '*HP*' }
        )
        # HP's Store apps (their package names start with AD2F1837.).
        Packages = @('AD2F1837.myHP*', 'AD2F1837.HPPrivacySettings*', 'AD2F1837.HPQuickDrop*', 'AD2F1837.HPWorkWell*', 'AD2F1837.HPJumpStarts*',
            'AD2F1837.HPEasyClean*', 'AD2F1837.HPSureShieldAI*', 'AD2F1837.HPQuickTouch*', 'AD2F1837.HPDesktopSupportUtilities*',
            'AD2F1837.HPPCHardwareDiagnosticsWindows*', 'AD2F1837.HPSystemInformation*', 'AD2F1837.HPInsights*')
        # Never removed: HP Support Assistant, and what keys, audio, power, docks and the BIOS need.
        Keep         = @('HP Support Assistant*', 'HP Hotkey*', 'HP System Event*', 'HP Audio*', 'HP Power Manager*', 'HP MAC Address*', 'HP Dock*', 'HP BIOS*', 'HP Sure Start*', 'HP Image Assistant*')
        KeepPackages = @('AD2F1837.HPSupportAssistant*', 'AD2F1837.HPSystemEventUtilityHost*', 'AD2F1837.HPAudioControl*', 'AD2F1837.HPPowerManager*', 'AD2F1837.HPHotkey*')
        McAfeeTool = $false
    }
}
