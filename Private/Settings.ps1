function Load-GraphSettings {
    if (-not (Test-Path $Script:SettingsFilePath)) { return }
    try {
        # -Encoding UTF8 explicitly - same reasoning as Load-AppsFromFile's
        # own per-app file read: this file is written BOM-less UTF8
        # (Write-SettingsFile), which Get-Content silently misreads as the
        # system ANSI codepage under Windows PowerShell 5.1 without this.
        $settings = Get-Content -Path $Script:SettingsFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
        # Trimmed and whitespace-checked here, not just truthiness-checked -
        # the Settings dialog's own save path already strips whitespace
        # before writing (see btnSave's Trim() / -replace '\s',''), but a
        # value that reached this file some other way (an older version of
        # this app, a manual edit) might not be. Loading a whitespace-only
        # value as if it were "set" is exactly what made
        # Test-GraphCredentialsConfigured and Get-CertificateStatusText
        # disagree in Diagnostics - fixed at the source here too, not just
        # in the two places that read these variables afterward.
        if (-not [string]::IsNullOrWhiteSpace($settings.TenantId))  { $Script:GraphTenantId = ([string]$settings.TenantId).Trim() }
        if (-not [string]::IsNullOrWhiteSpace($settings.ClientId))  { $Script:GraphClientId = ([string]$settings.ClientId).Trim() }
        if (-not [string]::IsNullOrWhiteSpace($settings.CertificateThumbprint)) { $Script:GraphCertificateThumbprint = ([string]$settings.CertificateThumbprint) -replace '\s', '' }
        if ($settings.FavoriteGroups) {
            $Script:FavoriteGroups.Clear()
            foreach ($g in @($settings.FavoriteGroups)) { [void]$Script:FavoriteGroups.Add([string]$g) }
        }
        # Missing entirely (an older settings file, or one from before this
        # existed) leaves $Script:DefaultAppSettings at its own built-in
        # factory values, untouched - same "fall back silently" reasoning
        # as everything else in this function. Only individual fields that
        # are ACTUALLY present get overwritten, so a settings file saved by
        # an older version of this dialog (missing a field added later)
        # can't accidentally null one out.
        if ($settings.DefaultAppSettings) {
            $das = $settings.DefaultAppSettings
            if ($null -ne $das.Architecture)             { $Script:DefaultAppSettings.Architecture = [string]$das.Architecture }
            if ($null -ne $das.InstallContext)            { $Script:DefaultAppSettings.InstallContext = [string]$das.InstallContext }
            if ($null -ne $das.MinOSKey)                  { $Script:DefaultAppSettings.MinOSKey = [string]$das.MinOSKey }
            if ($null -ne $das.MinDiskSpaceMB)             { $Script:DefaultAppSettings.MinDiskSpaceMB = [int]$das.MinDiskSpaceMB }
            if ($null -ne $das.MinMemoryMB)                { $Script:DefaultAppSettings.MinMemoryMB = [int]$das.MinMemoryMB }
            if ($null -ne $das.MinProcessors)              { $Script:DefaultAppSettings.MinProcessors = [int]$das.MinProcessors }
            if ($null -ne $das.MinCpuSpeedMHz)             { $Script:DefaultAppSettings.MinCpuSpeedMHz = [int]$das.MinCpuSpeedMHz }
            if ($null -ne $das.InstallTimeMinutes)         { $Script:DefaultAppSettings.InstallTimeMinutes = [int]$das.InstallTimeMinutes }
            if ($null -ne $das.DeviceRestartBehavior)      { $Script:DefaultAppSettings.DeviceRestartBehavior = [string]$das.DeviceRestartBehavior }
            if ($null -ne $das.AllowAvailableUninstall)    { $Script:DefaultAppSettings.AllowAvailableUninstall = [bool]$das.AllowAvailableUninstall }
            if (@($das.ReturnCodes).Count -gt 0) {
                $Script:DefaultAppSettings.ReturnCodes = @($das.ReturnCodes | ForEach-Object { [pscustomobject]@{ returnCode = [int]$_.returnCode; type = [string]$_.type } })
            }
            if ($null -ne $das.DefaultDependencyAppNames) {
                $Script:DefaultAppSettings.DefaultDependencyAppNames = @($das.DefaultDependencyAppNames | ForEach-Object { [string]$_ } | Where-Object { $_ })
            }
            # Back-compat with a settings file saved by the single-dependency
            # version of this dialog (a plain string field, no "s") - only
            # consulted when the new plural field above wasn't present at
            # all, so an already-migrated file's own (possibly now empty)
            # array is never silently overwritten by stale singular data.
            elseif ($null -ne $das.DefaultDependencyAppName -and [string]$das.DefaultDependencyAppName) {
                $Script:DefaultAppSettings.DefaultDependencyAppNames = @([string]$das.DefaultDependencyAppName)
            }
        }
    }
    catch {
        # Bad/corrupt settings file - fall back to the built-in defaults silently;
        # the Settings dialog will show whatever's actually active.
    }
}

function Write-SettingsFile {
    try {
        $settings = [pscustomobject]@{
            TenantId              = $Script:GraphTenantId
            ClientId              = $Script:GraphClientId
            CertificateThumbprint = $Script:GraphCertificateThumbprint
            FavoriteGroups        = @($Script:FavoriteGroups)
            DefaultAppSettings    = $Script:DefaultAppSettings
        }
        $json = $settings | ConvertTo-Json -Depth 5
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Script:SettingsFilePath, $json, $utf8NoBom)
        return $true
    }
    catch {
        Write-Log "[FAILED] Could not save settings: $($_.Exception.Message)`r`n" ([System.Drawing.Color]::IndianRed)
        [System.Windows.Forms.MessageBox]::Show("Could not save settings: $($_.Exception.Message)", "Save failed", "OK", "Error") | Out-Null
        return $false
    }
}

function Save-GraphSettings {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$CertificateThumbprint
    )
    $Script:GraphTenantId = $TenantId
    $Script:GraphClientId = $ClientId
    $Script:GraphCertificateThumbprint = $CertificateThumbprint
    return (Write-SettingsFile)
}

function Save-FavoriteGroups {
    return (Write-SettingsFile)
}

function Clear-DelegatedSignInCache {
    try {
        $msalCacheDir = Join-Path $env:LOCALAPPDATA ".IdentityService"
        foreach ($cacheFile in @("mg.msal.cache.cae", "mg.msal.cache.nocae")) {
            $cachePath = Join-Path $msalCacheDir $cacheFile
            if (Test-Path $cachePath) { Remove-Item -Path $cachePath -Force -ErrorAction SilentlyContinue }
        }
    } catch { }
}

function Test-GraphCredentialsConfigured {
    # -not [string]::IsNullOrWhiteSpace(...), not plain PowerShell truthiness
    # ($Script:GraphTenantId -and ...) - a value that's present but only
    # whitespace (e.g. a stray-space CertificateThumbprint loaded from an
    # unrimmed intune-deployment-settings.json - see Load-GraphSettings) is
    # truthy in PowerShell, so the old plain check reported "all set" here
    # while Get-CertificateStatusText's own (already whitespace-aware)
    # check correctly reported "No thumbprint set." for the exact same
    # value - two Diagnostics lines flatly contradicting each other. Both
    # now agree by using the same definition of "set".
    if ((-not [string]::IsNullOrWhiteSpace($Script:GraphTenantId)) -and
        (-not [string]::IsNullOrWhiteSpace($Script:GraphClientId)) -and
        (-not [string]::IsNullOrWhiteSpace($Script:GraphCertificateThumbprint))) { return $true }
    [System.Windows.Forms.MessageBox]::Show(
        "No Graph connection is configured yet. Open 'Settings...' in the Tools group and fill in your Tenant ID, Client ID, and certificate first.",
        "Not configured", "OK", "Warning") | Out-Null
    return $false
}

function Get-CertificateStatusText {
    param([string]$Thumbprint)

    if ([string]::IsNullOrWhiteSpace($Thumbprint)) {
        return @{ Text = "No thumbprint set."; Color = [System.Drawing.Color]::DarkOrange }
    }
    $clean = $Thumbprint -replace '\s', ''
    $cert = $null
    foreach ($location in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")) {
        try {
            $found = Get-ChildItem -Path $location -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $clean } | Select-Object -First 1
            if ($found) { $cert = $found; break }
        } catch { }
    }
    if (-not $cert) {
        return @{ Text = "Not found in CurrentUser\My or LocalMachine\My on this machine."; Color = [System.Drawing.Color]::Firebrick }
    }
    $daysLeft = ($cert.NotAfter - (Get-Date)).Days
    if ($daysLeft -lt 0) {
        return @{ Text = "Found - EXPIRED on $($cert.NotAfter.ToString('yyyy-MM-dd')). Subject: $($cert.Subject)"; Color = [System.Drawing.Color]::Firebrick }
    }
    elseif ($daysLeft -lt 30) {
        return @{ Text = "Found - expires in $daysLeft day(s) ($($cert.NotAfter.ToString('yyyy-MM-dd'))). Subject: $($cert.Subject)"; Color = [System.Drawing.Color]::DarkOrange }
    }
    else {
        return @{ Text = "Found - valid until $($cert.NotAfter.ToString('yyyy-MM-dd')). Subject: $($cert.Subject)"; Color = [System.Drawing.Color]::SeaGreen }
    }
}
