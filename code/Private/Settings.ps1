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
            if ($das.WingetInstallMethod -in @("WAU", "Winget")) { $Global:App.DefaultAppSettings.WingetInstallMethod = [string]$das.WingetInstallMethod }
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
            DefaultAppSettings    = $Global:App.DefaultAppSettings
            CheckDriftOnStartup   = $Global:App.CheckDriftOnStartup
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
