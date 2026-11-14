function Global:Import-GraphSettings {
    if (-not (Test-Path -LiteralPath $Global:App.SettingsFilePath)) { return }
    try {
        # -Encoding UTF8 explicitly - same reasoning as Import-AppsFromFile's
        # own per-app file read: this file is written BOM-less UTF8
        # (Write-SettingsFile), which Get-Content silently misreads as the
        # system ANSI codepage under Windows PowerShell 5.1 without this.
        $settings = Get-Content -LiteralPath $Global:App.SettingsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        # Trimmed and whitespace-checked here, not just truthiness-checked -
        # the Settings page's save already strips whitespace before
        # writing, but a
        # value that reached this file some other way (an older version of
        # this app, a manual edit) might not be. Loading a whitespace-only
        # value as if it were "set" is exactly what made
        # Test-GraphCredentialsConfigured and Get-CertificateStatusText
        # disagree in Diagnostics - fixed at the source here too, not just
        # in the two places that read these variables afterward.
        if (-not [string]::IsNullOrWhiteSpace($settings.TenantId))  { $Global:App.GraphTenantId = ([string]$settings.TenantId).Trim() }
        if (-not [string]::IsNullOrWhiteSpace($settings.ClientId))  { $Global:App.GraphClientId = ([string]$settings.ClientId).Trim() }
        if (-not [string]::IsNullOrWhiteSpace($settings.CertificateThumbprint)) { $Global:App.GraphCertificateThumbprint = ([string]$settings.CertificateThumbprint) -replace '\s', '' }
        if ($settings.ReleasePolicy) {
            $rp = ConvertTo-ReleasePolicy $settings.ReleasePolicy
            foreach ($k in @($rp.Keys)) { $Global:App.ReleasePolicy[$k] = $rp[$k] }
        }
        if ($settings.ReleaseRings) { $Global:App.ReleaseRings = @(ConvertTo-ReleaseRings $settings.ReleaseRings) }
        if ($settings.Alerts) { $Global:App.Alerts = ConvertTo-AlertSettings $settings.Alerts }
        if ($settings.AssignmentProfiles) { $Global:App.AssignmentProfiles = @(ConvertTo-AssignmentProfiles $settings.AssignmentProfiles) }
        if ($settings.PilotGroups) {
            $Global:App.PilotGroups.Clear()
            foreach ($g in @($settings.PilotGroups)) { [void]$Global:App.PilotGroups.Add([string]$g) }
        }
        if ($settings.FavoriteGroups) {
            $Global:App.FavoriteGroups.Clear()
            foreach ($g in @($settings.FavoriteGroups)) { [void]$Global:App.FavoriteGroups.Add([string]$g) }
        }
        # -is [bool], not just truthiness - $settings.CheckDriftOnStartup
        # being $false is a real, meaningful saved choice, not "missing" -
        # a plain "if ($settings.CheckDriftOnStartup)" would silently treat
        # an explicit off the same as never-set-at-all, which happens to
        # read the same as leaving it at its own $false default, but only
        # by accident. Doesn't exist at all (older settings file) leaves
        # $Global:App.CheckDriftOnStartup at its own default, untouched.
        if ($settings.CheckDriftOnStartup -is [bool]) { $Global:App.CheckDriftOnStartup = $settings.CheckDriftOnStartup }
        if ($settings.CheckForUpdates -is [bool]) { $Global:App.CheckForUpdates = $settings.CheckForUpdates }
        if ([string]$settings.Packager -in 'auto', 'builtin', 'tool') { $Global:App.Packager = [string]$settings.Packager }
        if ($settings.DetailedGraphLog -is [bool]) { $Global:App.DetailedGraphLog = $settings.DetailedGraphLog }
        # Same -is [bool] reasoning as CheckDriftOnStartup above, and it
        # matters more here: PushGroupsOnCreate defaults to ON, so reading
        # a saved $false as "missing" would turn the user's deliberate off
        # back on at every startup.
        if ($settings.PushGroupsOnCreate -is [bool]) { $Global:App.PushGroupsOnCreate = $settings.PushGroupsOnCreate }
        if ($settings.PushGroupsOnUpdate -is [bool]) { $Global:App.PushGroupsOnUpdate = $settings.PushGroupsOnUpdate }
        # Same -is [bool] reasoning as CheckDriftOnStartup right above.
        if ($settings.RunFullAuditOnStartup -is [bool]) { $Global:App.RunFullAuditOnStartup = $settings.RunFullAuditOnStartup }
        # Same -is [bool] reasoning as CheckDriftOnStartup above.
        if ($settings.CheckIntuneOnDeployOpen -is [bool]) { $Global:App.CheckIntuneOnDeployOpen = $settings.CheckIntuneOnDeployOpen }
        # Where this install keeps things, when it doesn't keep them where
        # the app itself lives - see AppFolders.ps1. Read into a plain
        # hashtable because that is what Get-AppFolder looks in, and read
        # one key at a time so a folder that no longer exists as a concept
        # is simply ignored rather than carried around forever.
        $Global:App.AppFolders = @{}
        if ($settings.Folders) {
            foreach ($spec in (Get-AppFolderKinds)) {
                $value = $null
                if ($settings.Folders -is [System.Collections.IDictionary]) { $value = $settings.Folders[$spec.Key] }
                elseif ($settings.Folders.PSObject.Properties[$spec.Key]) { $value = $settings.Folders.PSObject.Properties[$spec.Key].Value }
                if (-not [string]::IsNullOrWhiteSpace([string]$value)) { $Global:App.AppFolders[$spec.Key] = [string]$value }
            }
        }
        # Missing entirely (an older settings file, or one from before this
        # existed) leaves $Global:App.DefaultAppSettings at its own built-in
        # factory values, untouched - same "fall back silently" reasoning
        # as everything else in this function. Only individual fields that
        # are ACTUALLY present get overwritten, so a settings file saved by
        # an older version of this dialog (missing a field added later)
        # can't accidentally null one out.
        if ($settings.DefaultAppSettings) {
            $das = $settings.DefaultAppSettings
            if ($null -ne $das.Architecture)             { $Global:App.DefaultAppSettings.Architecture = [string]$das.Architecture }
            if ($null -ne $das.InstallContext)            { $Global:App.DefaultAppSettings.InstallContext = [string]$das.InstallContext }
            if ($null -ne $das.MinOSKey)                  { $Global:App.DefaultAppSettings.MinOSKey = [string]$das.MinOSKey }
            if ($null -ne $das.MinDiskSpaceMB)             { $Global:App.DefaultAppSettings.MinDiskSpaceMB = [int]$das.MinDiskSpaceMB }
            if ($null -ne $das.MinMemoryMB)                { $Global:App.DefaultAppSettings.MinMemoryMB = [int]$das.MinMemoryMB }
            if ($null -ne $das.MinProcessors)              { $Global:App.DefaultAppSettings.MinProcessors = [int]$das.MinProcessors }
            if ($null -ne $das.MinCpuSpeedMHz)             { $Global:App.DefaultAppSettings.MinCpuSpeedMHz = [int]$das.MinCpuSpeedMHz }
            if ($null -ne $das.InstallTimeMinutes)         { $Global:App.DefaultAppSettings.InstallTimeMinutes = [int]$das.InstallTimeMinutes }
            if ($null -ne $das.DeviceRestartBehavior)      { $Global:App.DefaultAppSettings.DeviceRestartBehavior = [string]$das.DeviceRestartBehavior }
            if ($null -ne $das.AllowAvailableUninstall)    { $Global:App.DefaultAppSettings.AllowAvailableUninstall = [bool]$das.AllowAvailableUninstall }
            if ($das.WingetInstallMethod -in @("WAU", "Winget", "Managed")) { $Global:App.DefaultAppSettings.WingetInstallMethod = [string]$das.WingetInstallMethod }
            if (@($das.ReturnCodes).Count -gt 0) {
                $Global:App.DefaultAppSettings.ReturnCodes = @($das.ReturnCodes | ForEach-Object { [pscustomobject]@{ returnCode = [int]$_.returnCode; type = [string]$_.type } })
            }
            if ($null -ne $das.DefaultDependencyAppNames) {
                $Global:App.DefaultAppSettings.DefaultDependencyAppNames = @($das.DefaultDependencyAppNames | ForEach-Object { [string]$_ } | Where-Object { $_ })
            }
            # Back-compat with a settings file saved by the single-dependency
            # version of this dialog (a plain string field, no "s") - only
            # consulted when the new plural field above wasn't present at
            # all, so an already-migrated file's own (possibly now empty)
            # array is never silently overwritten by stale singular data.
            elseif ($null -ne $das.DefaultDependencyAppName -and [string]$das.DefaultDependencyAppName) {
                $Global:App.DefaultAppSettings.DefaultDependencyAppNames = @([string]$das.DefaultDependencyAppName)
            }
        }
    }
    catch {
        # Bad/corrupt settings file - fall back to the built-in defaults silently;
        # the Settings page shows whatever's actually active.
    }
}

function Global:Write-SettingsFile {
    # Graph test mode fills in made-up connection IDs in memory - they must
    # never reach the real settings file.
    if ($Global:App.TestGraph) { Write-Log '[WARN] Test mode: the settings file is not written.'; return $false }
    try {
        $settings = [pscustomobject]@{
            TenantId              = $Global:App.GraphTenantId
            ClientId              = $Global:App.GraphClientId
            CertificateThumbprint = $Global:App.GraphCertificateThumbprint
            FavoriteGroups        = @($Global:App.FavoriteGroups)
            PilotGroups           = @($Global:App.PilotGroups)
            ReleasePolicy         = $Global:App.ReleasePolicy
            ReleaseRings          = @($Global:App.ReleaseRings)
            Alerts                = $Global:App.Alerts
            AssignmentProfiles    = @($Global:App.AssignmentProfiles)
            DefaultAppSettings    = $Global:App.DefaultAppSettings
            CheckDriftOnStartup   = $Global:App.CheckDriftOnStartup
            CheckForUpdates       = [bool]$Global:App.CheckForUpdates
            Packager              = [string]$Global:App.Packager
            RunFullAuditOnStartup = $Global:App.RunFullAuditOnStartup
            CheckIntuneOnDeployOpen = [bool]$Global:App.CheckIntuneOnDeployOpen
            DetailedGraphLog      = [bool]$Global:App.DetailedGraphLog
            PushGroupsOnCreate    = [bool]$Global:App.PushGroupsOnCreate
            PushGroupsOnUpdate    = [bool]$Global:App.PushGroupsOnUpdate
            # Only the folders actually pointed somewhere else. A default
            # is not written down, so changing what the default IS in a
            # later version reaches every install that never overrode it.
            Folders               = $(if ($Global:App.AppFolders -is [System.Collections.IDictionary]) { $Global:App.AppFolders } else { @{} })
        }
        $json = $settings | ConvertTo-Json -Depth 5
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Global:App.SettingsFilePath, $json, $utf8NoBom)
        return $true
    }
    catch {
        Write-Log "[FAILED] Could not save settings: $($_.Exception.Message)`r`n"
        return $false
    }
}

function Global:Save-GraphSettings {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$CertificateThumbprint
    )
    $Global:App.GraphTenantId = $TenantId
    $Global:App.GraphClientId = $ClientId
    $Global:App.GraphCertificateThumbprint = $CertificateThumbprint
    return (Write-SettingsFile)
}

function Global:Test-GraphCredentialsConfigured {
    # -Quiet is kept for the callers that pass it; nothing is shown either way -
    # each caller says in its own words what is missing.
    param([switch]$Quiet)
    # -not [string]::IsNullOrWhiteSpace(...), not plain PowerShell truthiness
    # ($Global:App.GraphTenantId -and ...) - a value that's present but only
    # whitespace (e.g. a stray-space CertificateThumbprint loaded from an
    # unrimmed intune-deployment-settings.json - see Import-GraphSettings) is
    # truthy in PowerShell, so the old plain check reported "all set" here
    # while Get-CertificateStatusText's own (already whitespace-aware)
    # check correctly reported "No thumbprint set." for the exact same
    # value - two Diagnostics lines flatly contradicting each other. Both
    # now agree by using the same definition of "set".
    if ((-not [string]::IsNullOrWhiteSpace($Global:App.GraphTenantId)) -and
        (-not [string]::IsNullOrWhiteSpace($Global:App.GraphClientId)) -and
        (-not [string]::IsNullOrWhiteSpace($Global:App.GraphCertificateThumbprint))) { return $true }
    return $false
}

function Global:Get-CertificateStatusText {
    param([string]$Thumbprint)

    if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
        return @{ Text = "No thumbprint set."; Level = 'warn' }
    }
    $clean = $Thumbprint -replace '\s', ''
    $cert = $null
    foreach ($location in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")) {
        try {
            $found = Get-ChildItem -LiteralPath $location -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $clean } | Select-Object -First 1
            if ($found) { $cert = $found; break }
        } catch { }
    }
    if (-not $cert) {
        return @{ Text = "Not found in CurrentUser\My or LocalMachine\My on this machine."; Level = 'error' }
    }
    $daysLeft = ($cert.NotAfter - (Get-Date)).Days
    if ($daysLeft -lt 0) {
        return @{ Text = "Found - EXPIRED on $($cert.NotAfter.ToString('yyyy-MM-dd')). Subject: $($cert.Subject)"; Level = 'error' }
    }
    elseif ($daysLeft -lt 30) {
        return @{ Text = "Found - expires in $daysLeft day(s) ($($cert.NotAfter.ToString('yyyy-MM-dd'))). Subject: $($cert.Subject)"; Level = 'warn' }
    }
    else {
        return @{ Text = "Found - valid until $($cert.NotAfter.ToString('yyyy-MM-dd')). Subject: $($cert.Subject)"; Level = 'ok' }
    }
}

function Global:ConvertTo-ReleasePolicy {
    # Pure: the managed-updates policy from a settings file or the page, each value checked; anything missing or wrong is the default.
    param($Raw)
    $p = [ordered]@{ Days = 3; MaxFailedPercent = 5; MinInstalled = 1; AutoRelease = $false; AutoPromote = $false; CleanupOld = $false; RunAt = '03:00'
        FastTrackHours = 4; DeadlineDays = 0; RestartGraceMinutes = 0; Notifications = 'showAll'
        # The nightly run's other work: release window, automatic withdraw, drift, backup, monthly report, the test tenant's catalog.
        ReleaseDays = @(0, 1, 2, 3, 4, 5, 6); SkipLastWeek = $false; AutoWithdrawPercent = 0; DriftCheck = $true; DriftFix = $false
        BackupCatalog = $true; BackupGit = $false; MonthlyReport = $false; GatePath = '' }
    if (-not $Raw) { return $p }
    if ($null -ne $Raw.ReleaseDays) {
        $d = @(@($Raw.ReleaseDays) | Where-Object { "$_" -match '^[0-6]$' } | ForEach-Object { [int]"$_" } | Sort-Object -Unique)
        if ($d.Count) { $p.ReleaseDays = $d }
    }
    if ($null -ne $Raw.SkipLastWeek) { $p.SkipLastWeek = [bool]$Raw.SkipLastWeek }
    if ([string]$Raw.AutoWithdrawPercent -match '^\d{1,3}$' -and [int][string]$Raw.AutoWithdrawPercent -le 100) { $p.AutoWithdrawPercent = [int][string]$Raw.AutoWithdrawPercent }
    if ($null -ne $Raw.DriftCheck) { $p.DriftCheck = [bool]$Raw.DriftCheck }
    if ($null -ne $Raw.DriftFix) { $p.DriftFix = [bool]$Raw.DriftFix }
    if ($null -ne $Raw.BackupCatalog) { $p.BackupCatalog = [bool]$Raw.BackupCatalog }
    if ($null -ne $Raw.BackupGit) { $p.BackupGit = [bool]$Raw.BackupGit }
    if ($null -ne $Raw.MonthlyReport) { $p.MonthlyReport = [bool]$Raw.MonthlyReport }
    $gate = ([string]$Raw.GatePath).Trim()
    if ($gate -and $gate.Length -le 260 -and $gate -notmatch '[*?"<>|]' -and ($gate -match '^[A-Za-z]:\\' -or $gate -match '^\\\\[^\\]+\\' -or $gate -match '^/')) { $p.GatePath = $gate }
    if ([string]$Raw.FastTrackHours -match '^\d{1,2}$' -and [int][string]$Raw.FastTrackHours -ge 1 -and [int][string]$Raw.FastTrackHours -le 72) { $p.FastTrackHours = [int][string]$Raw.FastTrackHours }
    if ([string]$Raw.DeadlineDays -match '^\d{1,2}$' -and [int][string]$Raw.DeadlineDays -le 30) { $p.DeadlineDays = [int][string]$Raw.DeadlineDays }
    if ([string]$Raw.RestartGraceMinutes -match '^\d{1,5}$' -and [int][string]$Raw.RestartGraceMinutes -le 20160) { $p.RestartGraceMinutes = [int][string]$Raw.RestartGraceMinutes }
    if ([string]$Raw.Notifications -in 'showAll', 'showReboot', 'hideAll') { $p.Notifications = [string]$Raw.Notifications }
    if ([string]$Raw.Days -match '^\d{1,2}$') { $p.Days = [int][string]$Raw.Days }
    if ([string]$Raw.MaxFailedPercent -match '^\d{1,3}(\.\d+)?$' -and [double][string]$Raw.MaxFailedPercent -le 100) { $p.MaxFailedPercent = [double][string]$Raw.MaxFailedPercent }
    if ([string]$Raw.MinInstalled -match '^\d{1,4}$') { $p.MinInstalled = [int][string]$Raw.MinInstalled }
    if ($null -ne $Raw.AutoRelease) { $p.AutoRelease = [bool]$Raw.AutoRelease }
    if ($null -ne $Raw.AutoPromote) { $p.AutoPromote = [bool]$Raw.AutoPromote }
    if ($null -ne $Raw.CleanupOld) { $p.CleanupOld = [bool]$Raw.CleanupOld }
    if ([string]$Raw.RunAt -match '^([01]\d|2[0-3]):[0-5]\d$') { $p.RunAt = [string]$Raw.RunAt }
    return $p
}

function Global:ConvertTo-ReleaseRings {
    # Pure: the release rings from a settings file or the page - at most five, each with a name and its groups; anything else is dropped.
    param($Raw)
    return @(@($Raw) | Where-Object { $_ -and ([string]$_.Name).Trim() -and @($_.Groups | Where-Object { ([string]$_).Trim() }).Count } | Select-Object -First 5 | ForEach-Object {
        [ordered]@{ Name = ([string]$_.Name).Trim(); Groups = @(@($_.Groups) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique) }
    })
}

function Global:ConvertTo-AlertSettings {
    <#
      Pure: the nightly run's alert settings, each value checked; anything
      wrong is left empty. Level: off, attention or always. WebhookUrl: an
      https URL (a Teams "Workflows" webhook). MailFrom: the mailbox the
      email is sent from (needs Mail.Send); MailTo: addresses.
    #>
    param($Raw)
    $a = [ordered]@{ Level = 'off'; WebhookUrl = ''; MailFrom = ''; MailTo = @() }
    if (-not $Raw) { return $a }
    if ([string]$Raw.Level -in 'off', 'attention', 'always') { $a.Level = [string]$Raw.Level }
    $url = ([string]$Raw.WebhookUrl).Trim()
    if ($url -match '^https://[A-Za-z0-9.-]+(:\d+)?/[^\s"<>]*$' -and $url.Length -le 2000) { $a.WebhookUrl = $url }
    $mail = '^[A-Za-z0-9._%+''-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    if (([string]$Raw.MailFrom).Trim() -match $mail) { $a.MailFrom = ([string]$Raw.MailFrom).Trim() }
    $a.MailTo = @(@($Raw.MailTo) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match $mail } | Select-Object -Unique -First 20)
    return $a
}
