# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    The web interface's Settings page: the connection, certificates, Test
    connection, the permission choice, packaging, automatic checks, folders,
    default values and favourite groups. The routes are in WebApi.ps1.
#>

function Global:Save-WebSettings {
    param($Data)
    $tenant = ([string]$Data.tenantId).Trim()
    $client = ([string]$Data.clientId).Trim()
    $thumb = ([string]$Data.thumbprint).Trim() -replace '\s', ''
    if (-not $tenant -or -not $client -or -not $thumb) { return @{ ok = $false; error = 'Tenant ID, Client ID and certificate thumbprint are all required.' } }
    if (-not (Save-GraphSettings -TenantId $tenant -ClientId $client -CertificateThumbprint $thumb)) { return @{ ok = $false; error = "Couldn't write the settings file." } }
    # A sign-in made with the old values must not be reused - see Reset-GraphSession.
    Reset-GraphSession
    Write-Log "[OK] Settings saved. Client: $client, Tenant: $tenant."
    return @{ ok = $true; state = (Get-WebState) }
}

function Global:Get-WebCertStatus {
    param($Data)
    $cert = Get-CertificateStatusText -Thumbprint ([string]$Data.thumbprint)
    return @{ ok = $true; text = [string]$cert.Text; level = ([string]$cert.Level) }
}

function Global:Get-WebLocalCertificates {
    # Certificates on this machine that could sign in: with a private key, not
    # expired - from the user's store and the machine's. How many were left
    # out, and why, so an empty list explains itself.
    $now = Get-Date
    $list = New-Object System.Collections.Generic.List[object]
    $expired = 0; $noKey = 0
    foreach ($store in 'CurrentUser', 'LocalMachine') {
        foreach ($c in @(Get-ChildItem -Path "Cert:\$store\My" -ErrorAction SilentlyContinue)) {
            if (-not $c.HasPrivateKey) { $noKey++; continue }
            if ($c.NotAfter -le $now) { $expired++; continue }
            $list.Add([ordered]@{ subject = $c.Subject; thumbprint = $c.Thumbprint; notAfter = $c.NotAfter.ToString('yyyy-MM-dd')
                store = $(if ($store -eq 'CurrentUser') { 'your user store' } else { 'the machine store' }) })
        }
    }
    return @{ ok = $true; certificates = $list.ToArray(); expired = $expired; noKey = $noKey }
}

function Global:New-WebCertificate {
    <#
      A new self-signed certificate in CurrentUser\My - a non-exportable key -
      and its public .cer saved to the app's certificates folder, which is
      the file Entra wants.
    #>
    param($Data)
    $subject = ([string]$Data.subject).Trim()
    if (-not $subject) { $subject = 'Intune Deployment' }
    if ($subject -notmatch '^CN=') { $subject = "CN=$subject" }
    try {
        $cert = New-SelfSignedCertificate -Subject $subject -CertStoreLocation 'Cert:\CurrentUser\My' `
            -KeyExportPolicy NonExportable -KeySpec Signature -KeyLength 2048 -KeyAlgorithm RSA `
            -HashAlgorithm SHA256 -NotAfter (Get-Date).AddYears(2) -ErrorAction Stop
    }
    catch { return @{ ok = $false; error = "Couldn't create the certificate: $($_.Exception.Message)" } }
    $folder = Join-Path $Global:App.RootPath 'data\certificates'
    $cerPath = $null
    try {
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
        $cerPath = Join-Path $folder "$($cert.Thumbprint).cer"
        [System.IO.File]::WriteAllBytes($cerPath, $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    }
    catch { $cerPath = $null }
    Write-Log "[OK] Certificate created: $subject ($($cert.Thumbprint))."
    return @{ ok = $true; thumbprint = $cert.Thumbprint; subject = $subject; notAfter = $cert.NotAfter.ToString('yyyy-MM-dd'); cerPath = $cerPath }
}

function Global:Get-SetupChecklistRows {
    # The checklist as rows for the page - Format-SetupChecklist's own
    # lines, parsed back, so there's still one place that decides them.
    param([hashtable]$State)
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in (Format-SetupChecklist -State $State)) {
        if ($line -match '^\s+\[(OK|FAILED|--)\]\s+(.+)$') {
            $rows.Add([ordered]@{ status = $(switch ($Matches[1]) { 'OK' { 'ok' } 'FAILED' { 'failed' } default { 'skip' } }); name = $Matches[2]; next = '' })
        }
        elseif ($line -match '^\s+Next:\s+(.+)$' -and $rows.Count -gt 0) { $rows[$rows.Count - 1].next = $Matches[1] }
    }
    return $rows.ToArray()
}

function Global:Invoke-WebTestConnection {
    <#
      Test connection: an app-only sign-in with the values on the page
      (saved or not), the token's permissions, and the setup checklist.
      The sign-in is dropped again afterwards, so a token from before a
      consent is never reused.
    #>
    param($Data)
    $tenant = ([string]$Data.tenantId).Trim()
    $client = ([string]$Data.clientId).Trim()
    $thumb = ([string]$Data.thumbprint).Trim() -replace '\s', ''
    $moduleOk = [bool](Test-GraphModuleHere)
    $localCert = if ($thumb) {
        Get-ChildItem Cert:\CurrentUser\My, Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $thumb } | Select-Object -First 1
    }
    $state = @{
        ModuleOk     = $moduleOk
        FieldsOk     = [bool]($tenant -and $client -and $thumb)
        CertFound    = [bool]$localCert
        CertHasKey   = [bool]($localCert -and $localCert.HasPrivateKey)
        CertNotAfter = $(if ($localCert) { $localCert.NotAfter } else { $null })
        SignInOk     = $null
        SignInError  = ''
        Report       = $null
        Saved        = ($tenant -eq [string]$Global:App.GraphTenantId -and $client -eq [string]$Global:App.GraphClientId -and $thumb -eq [string]$Global:App.GraphCertificateThumbprint)
    }
    $result = [ordered]@{ ok = $true; signedIn = $false; summary = ''; level = 'error'; report = @(); checklist = @(); conflict = '' }
    if (-not $moduleOk -or -not $state.FieldsOk) {
        $result.summary = if (-not $moduleOk) { "The Microsoft.Graph.Authentication module isn't installed yet." } else { 'Fill in Tenant ID, Client ID and certificate thumbprint first.' }
        $result.checklist = Get-SetupChecklistRows -State $state
        return $result
    }
    $conflicts = Get-GraphAssemblyConflictReport
    if (@($conflicts.Conflicts).Count -gt 0) {
        $result.conflict = Format-GraphAssemblyConflictText -Conflicts @($conflicts.Conflicts) -LoadedModules @($conflicts.LoadedModules) -NoProfile ([bool]$conflicts.NoProfile) -GraphVersion $conflicts.GraphVersion
    }
    try {
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Connect-MgGraph -TenantId $tenant -ClientId $client -CertificateThumbprint $thumb -NoWelcome -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction Stop
        $claims = $null; $claimsError = ''
        try { $claims = Get-GraphAppTokenClaims -TenantId $tenant -ClientId $client -Thumbprint $thumb }
        catch { $claimsError = $_.Exception.Message }
        try { Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null } catch { }

        $state.SignInOk = $true
        $result.signedIn = $true
        $signedIn = "Signed in as '$($ctx.AppName)' ($($ctx.AuthType))"
        if ($claimsError) {
            $result.summary = "$signedIn, but the token's permissions couldn't be read: $claimsError"
            $result.level = 'warn'
        }
        else {
            $report = Get-GraphRoleReport -Roles @($claims.roles)
            $state.Report = $report
            $blocked = @(@($report.Missing) | Where-Object { $_.Required }).Count
            $result.report = @(Format-GraphRoleReport -Report $report -TokenAppId ([string]$claims.appid) -SettingsClientId $client | ForEach-Object {
                $lvl = if ($_ -like '`[FAILED`]*') { 'error' } elseif ($_ -like '`[WARN`]*') { 'warn' } elseif ($_ -like '`[OK`]*') { 'ok' } else { 'info' }
                [ordered]@{ level = $lvl; text = [string]$_ }
            })
            if (@($report.Have).Count -eq 0) { $result.summary = "$signedIn, but the app registration has no API permissions granted yet."; $result.level = 'error' }
            elseif ($blocked -gt 0) { $result.summary = "$signedIn, but it's missing a permission the app needs."; $result.level = 'error' }
            elseif (@($report.Missing).Count -gt 0) { $result.summary = "$signedIn. Some optional features are missing a permission."; $result.level = 'warn' }
            else { $result.summary = "$signedIn, with every permission this app uses."; $result.level = 'ok' }
        }
        Write-Log "[INFO] Test connection: $($result.summary)"
    }
    catch {
        $failure = Get-InnermostErrorMessage $_.Exception
        $state.SignInOk = $false
        $state.SignInError = $failure
        $result.summary = "Failed: $(ConvertTo-FriendlyGraphError $failure)"
        if (-not $result.conflict -and (Test-GraphAssemblyConflictText $failure)) {
            $result.conflict = Format-GraphAssemblyConflictText -ErrorText $failure -NoProfile (Test-SessionStartedWithoutProfile)
        }
        Write-Log "[FAILED] Test connection: $failure"
    }
    $result.checklist = Get-SetupChecklistRows -State $state
    return $result
}

function Global:Start-WebCertJob {
    <#
      Check / Upload / Delete certificate and Add permissions: the
      CertUpload step, through the step runner, with
      a console window (the interactive sign-in needs one). The page polls
      /api/job-poll for its output and result.
    #>
    param($Data)
    $mode = [string]$Data.mode
    if ($mode -notin 'Check', 'Upload', 'DeleteCert', 'AddPermissions') { return @{ ok = $false; error = "Unknown action '$mode'." } }
    $tenant = ([string]$Data.tenantId).Trim()
    $client = ([string]$Data.clientId).Trim()
    if (-not $tenant -or -not $client) { return @{ ok = $false; error = 'Fill in Tenant ID and Client ID first.' } }
    if (-not (Test-GraphModuleHere)) { return @{ ok = $false; error = "The Microsoft.Graph.Authentication module isn't installed yet." } }

    $tag = [guid]::NewGuid().ToString('N')
    $resultPath = Join-Path $env:TEMP ".intunepkg_certupload_result_$tag.json"
    $config = [ordered]@{ Mode = $mode; TenantId = $tenant; ClientId = $client; OutputResultPath = $resultPath }
    if ($mode -eq 'Upload') {
        $thumb = ([string]$Data.thumbprint).Trim() -replace '\s', ''
        $cert = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb } | Select-Object -First 1
        if (-not $cert) { return @{ ok = $false; error = "No certificate with thumbprint $thumb in CurrentUser\My. Pick or create one first." } }
        $config.CertThumbprint = $thumb
        $config.CertSubject = $cert.Subject
        $config.CertBase64 = [Convert]::ToBase64String($cert.RawData)
        $config.CertNotBefore = $cert.NotBefore.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $config.CertNotAfter = $cert.NotAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    elseif ($mode -eq 'DeleteCert') {
        $keyId = [guid]::Empty
        if (-not [guid]::TryParse([string]$Data.keyId, [ref]$keyId)) { return @{ ok = $false; error = 'Pick the certificate to delete first.' } }
        $config.KeyIdToDelete = $keyId.ToString()
    }
    elseif ($mode -eq 'AddPermissions') {
        $config.Permissions = @($Data.permissions | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[A-Za-z]+(\.[A-Za-z]+)+$' })
        if (@($config.Permissions).Count -eq 0) { return @{ ok = $false; error = 'No permissions chosen.' } }
    }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedCertUploadScript -Name 'certupload' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind $mode -ShowWindow
    if ($started.ok) { Write-Log "[INFO] Started: $mode (sign in in the window that opens)." }
    return $started
}

function Global:Get-WebConnectionStatus {
    <#
      Is the connection really working - not just filled in? One small read
      from Intune (one app's id) with the saved settings. For the badge at
      the top: state none / ok / error, a short text and the detail.
    #>
    if (-not (Test-GraphCredentialsConfigured -Quiet)) {
        return @{ ok = $true; state = 'none'; text = 'Not connected'; detail = 'Fill in the connection in Settings - until then nothing is read from or sent to Intune.' }
    }
    if (-not $Global:App.TestGraph -and -not (Test-GraphModuleHere)) {
        return @{ ok = $true; state = 'error'; text = 'Connection problem'; detail = "The Microsoft.Graph.Authentication module isn't installed - Settings > Prerequisites installs it." }
    }
    $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action {
        param($Graph)
        [void](& $Graph 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id&$top=1')
        $ctx = if (Get-Command Get-MgContext -ErrorAction SilentlyContinue) { Get-MgContext -ErrorAction SilentlyContinue } else { $null }
        [string]$(if ($ctx -and $ctx.AppName) { $ctx.AppName })
    }
    $at = (Get-Date).ToString('HH:mm')
    if ($read.ok) {
        $who = if ($read.value) { "as '$($read.value)' " } else { '' }
        return @{ ok = $true; state = 'ok'; text = 'Connected'; detail = "Signed in $($who)to tenant $($Global:App.GraphTenantId) - Intune answered at $at." }
    }
    $first = (([string]$read.error) -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    Write-Log "[WARN] Connection check at $at failed: $first"
    return @{ ok = $true; state = 'error'; text = 'Connection problem'; detail = "Intune didn't answer at $($at): $first - Settings > Test connection shows what is missing." }
}

function Global:Get-WebPermissionChoice {
    # What "Add required permissions" offers, from the same list the report uses.
    $requirements = @(Get-GraphRoleRequirements)
    $required = @($requirements | Where-Object { $_.Required } | ForEach-Object { $_.Grant } | Select-Object -Unique)
    $optional = @($requirements | Where-Object { -not $_.Required } | ForEach-Object { $_.Grant } | Where-Object { $required -notcontains $_ } | Select-Object -Unique)
    $purpose = @{}
    foreach ($r in $requirements) { if (-not $purpose.ContainsKey($r.Grant)) { $purpose[$r.Grant] = $r.Purpose } }
    return @{
        ok       = $true
        required = @($required | ForEach-Object { [ordered]@{ name = $_; purpose = $purpose[$_] } })
        optional = @($optional | ForEach-Object { [ordered]@{ name = $_; purpose = $purpose[$_] } })
    }
}

function Global:Get-WebEntraPermissionsUrl {
    # Pure: the app registration's API permissions page, or '' for a Client ID that isn't a GUID.
    param([string]$ClientId)
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse(([string]$ClientId).Trim(), [ref]$parsed)) { return '' }
    return "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$parsed/isMSAApp~/false"
}

function Global:Get-WebPackaging {
    # What packaging needs and whether it's there: the tool, and the shared Winget package.
    $r = Get-PackagingReadiness
    return @{ ok = $true; toolPath = [string]$r.ToolPath; toolFound = [bool]$r.ToolFound; toolVersion = [string]$r.ToolVersion
        sharedPath = [string]$r.SharedPath; sharedFound = [bool]$r.SharedFound; packagesFolder = (Get-AppFolder -Kind Packages)
        packager = $(if ([string]$Global:App.Packager -in 'builtin', 'tool') { [string]$Global:App.Packager } else { 'auto' }); packagerInUse = (Get-PackagerChoice) }
}

function Global:Invoke-WebPackagingSetup {
    # Downloads the packaging tool, or builds init.intunewin (downloading the tool first if needed).
    param($Data)
    switch ([string]$Data.what) {
        'tool' { $r = Install-PackagingTool }
        'shared' {
            if ((Get-PackagerChoice) -eq 'tool' -and -not (Get-PackagingReadiness).ToolFound) {
                $t = Install-PackagingTool
                if (-not $t.Ok) { return @{ ok = $false; error = [string]$t.Message } }
            }
            $r = New-SharedWingetPackage
        }
        default { return @{ ok = $false; error = 'Unknown setup step.' } }
    }
    return @{ ok = [bool]$r.Ok; error = $(if (-not $r.Ok) { [string]$r.Message } else { '' }); message = [string]$r.Message; state = (Get-WebPackaging) }
}

function Global:Get-WebMinOsChoices {
    # The minimum OS values the deploy form offers, with readable labels.
    @('W10_1607', 'W10_1703', 'W10_1709', 'W10_1803', 'W10_1809', 'W10_1903', 'W10_1909', 'W10_2004', 'W10_20H2', 'W10_21H1', 'W10_21H2', 'W10_22H2', 'W11_21H2', 'W11_22H2') |
        ForEach-Object { [ordered]@{ value = $_; label = (Get-FriendlyMinOsRelease -RawValue $_) } }
}

function Global:ConvertTo-WebDefaultSettings {
    <#
      Pure: the "default values" form, checked, as @{ Settings; Error }. Error is '' when it's fine.
    #>
    param($Form)
    $arch = @(@($Form.architecture) | ForEach-Object { [string]$_ } | Where-Object { $_ -in 'x86', 'x64', 'arm64' } | Select-Object -Unique)
    if ($arch.Count -eq 0) { return @{ Error = 'Choose at least one architecture.' } }
    $ints = @{}
    foreach ($k in 'minDiskSpaceMB', 'minMemoryMB', 'minProcessors', 'minCpuSpeedMHz', 'installTimeMinutes') {
        $v = [string]$Form.$k
        if ($v -notmatch '^\d{1,9}$') { return @{ Error = "$k must be a whole number of 0 or more." } }
        $ints[$k] = [int]$v
    }
    $codes = @(@($Form.returnCodes) | Where-Object { $_ } | ForEach-Object {
        if ([string]$_.returnCode -notmatch '^-?\d{1,10}$' -or [string]$_.type -notin 'success', 'softReboot', 'hardReboot', 'retry', 'failed') { $null }
        else { [pscustomobject]@{ returnCode = [int][string]$_.returnCode; type = [string]$_.type } }
    })
    if ($codes.Count -eq 0 -or @($codes | Where-Object { $null -eq $_ }).Count) { return @{ Error = 'Every return code needs a number and a type, and there must be at least one.' } }
    if ([string]$Form.installContext -notin 'System', 'User') { return @{ Error = 'Install for must be System or User.' } }
    if ([string]$Form.deviceRestartBehavior -notin 'basedOnReturnCode', 'allow', 'suppress', 'force') { return @{ Error = 'Unknown restart behaviour.' } }
    if ([string]$Form.minOSKey -notmatch '^W1[01]_\w+$') { return @{ Error = 'Unknown minimum OS.' } }
    return @{ Error = ''; Settings = [pscustomobject]@{
        Architecture = ($arch -join ','); InstallContext = $(if ([string]$Form.installContext -eq 'User') { 'User' } else { 'System' }); MinOSKey = [string]$Form.minOSKey
        MinDiskSpaceMB = $ints.minDiskSpaceMB; MinMemoryMB = $ints.minMemoryMB; MinProcessors = $ints.minProcessors; MinCpuSpeedMHz = $ints.minCpuSpeedMHz
        InstallTimeMinutes = (Get-NormalizedInstallTimeMinutes $ints.installTimeMinutes)
        DeviceRestartBehavior = [string]$Form.deviceRestartBehavior; AllowAvailableUninstall = [bool]$Form.allowAvailableUninstall
        ReturnCodes = $codes
        DefaultDependencyAppNames = @(@($Form.defaultDependencyAppNames) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
        WingetInstallMethod = $(if ([string]$Form.wingetInstallMethod -in 'WAU', 'Winget') { [string]$Form.wingetInstallMethod } else { 'Managed' })
    } }
}

function Global:Get-WebPrefs {
    $d = $Global:App.DefaultAppSettings
    return @{
        ok = $true
        checks = [ordered]@{
            checkDriftOnStartup = [bool]$Global:App.CheckDriftOnStartup; runFullAuditOnStartup = [bool]$Global:App.RunFullAuditOnStartup
            checkIntuneOnDeployOpen = [bool]$Global:App.CheckIntuneOnDeployOpen; pushGroupsOnCreate = [bool]$Global:App.PushGroupsOnCreate
            pushGroupsOnUpdate = [bool]$Global:App.PushGroupsOnUpdate; detailedGraphLog = [bool]$Global:App.DetailedGraphLog; checkForUpdates = [bool]$Global:App.CheckForUpdates
        }
        folders = @(Get-AppFolderKinds | ForEach-Object {
            $chosen = if ($Global:App.AppFolders -is [System.Collections.IDictionary] -and $Global:App.AppFolders.Contains($_.Key)) { [string]$Global:App.AppFolders[$_.Key] } else { '' }
            [ordered]@{ key = $_.Key; label = $_.Label; why = $_.Why; chosen = $chosen; default = (Get-AppFolderDefault -Kind $_.Key) }
        })
        defaults = [ordered]@{
            architecture = @(([string]$d.Architecture) -split ',' | Where-Object { $_ }); installContext = [string]$d.InstallContext; minOSKey = [string]$d.MinOSKey
            minDiskSpaceMB = [int]$d.MinDiskSpaceMB; minMemoryMB = [int]$d.MinMemoryMB; minProcessors = [int]$d.MinProcessors; minCpuSpeedMHz = [int]$d.MinCpuSpeedMHz
            installTimeMinutes = [int]$d.InstallTimeMinutes; deviceRestartBehavior = [string]$d.DeviceRestartBehavior; allowAvailableUninstall = [bool]$d.AllowAvailableUninstall
            returnCodes = @($d.ReturnCodes | ForEach-Object { [ordered]@{ returnCode = [int]$_.returnCode; type = [string]$_.type } })
            defaultDependencyAppNames = @($d.DefaultDependencyAppNames); wingetInstallMethod = [string]$d.WingetInstallMethod
        }
        minOsChoices = @(Get-WebMinOsChoices)
        favoriteGroups = @($Global:App.FavoriteGroups)
        pilotGroups    = @($Global:App.PilotGroups)
        releasePolicy  = $Global:App.ReleasePolicy
        profiles       = @($Global:App.AssignmentProfiles | ForEach-Object { [ordered]@{ name = $_.Name; required = @($_.Required); available = @($_.Available); exclude = @($_.Exclude) } })
        releaseRings   = @($Global:App.ReleaseRings | ForEach-Object { [ordered]@{ name = $_.Name; groups = @($_.Groups) } })
        # The webhook URL is a secret (anyone with it can post to the channel): the page only learns whether one is saved.
        alerts         = [ordered]@{ level = $Global:App.Alerts.Level; webhookSet = [bool]$Global:App.Alerts.WebhookUrl; mailFrom = $Global:App.Alerts.MailFrom; mailTo = @($Global:App.Alerts.MailTo) }
    }
}

function Global:Save-WebPrefs {
    param($Data)
    if ($Data.defaults) {
        $converted = ConvertTo-WebDefaultSettings $Data.defaults
        if ($converted.Error) { return @{ ok = $false; error = $converted.Error } }
    }
    if ($Data.folders) {
        $kinds = @(Get-AppFolderKinds | ForEach-Object { $_.Key })
        foreach ($p in $Data.folders.PSObject.Properties) {
            if ($kinds -notcontains $p.Name) { return @{ ok = $false; error = "Unknown folder '$($p.Name)'." } }
            $why = Test-AppFolderPath ([string]$p.Value)
            if ($why) { return @{ ok = $false; error = "$(@(Get-AppFolderKinds | Where-Object { $_.Key -eq $p.Name })[0].Label): $why" } }
        }
    }
    if ($Data.checks) {
        $c = $Data.checks
        $Global:App.CheckDriftOnStartup = [bool]$c.checkDriftOnStartup; $Global:App.RunFullAuditOnStartup = [bool]$c.runFullAuditOnStartup
        $Global:App.CheckIntuneOnDeployOpen = [bool]$c.checkIntuneOnDeployOpen; $Global:App.PushGroupsOnCreate = [bool]$c.pushGroupsOnCreate
        $Global:App.PushGroupsOnUpdate = [bool]$c.pushGroupsOnUpdate; $Global:App.DetailedGraphLog = [bool]$c.detailedGraphLog
        if ($null -ne $c.checkForUpdates) { $Global:App.CheckForUpdates = [bool]$c.checkForUpdates }
    }
    if ($null -ne $Data.packager) {
        if ([string]$Data.packager -notin 'auto', 'builtin', 'tool') { return @{ ok = $false; error = 'Unknown packager.' } }
        $Global:App.Packager = [string]$Data.packager
    }
    if ($Data.folders) {
        foreach ($p in $Data.folders.PSObject.Properties) { Set-AppFolder -Kind $p.Name -Path ([string]$p.Value) }
    }
    if ($Data.defaults) { $Global:App.DefaultAppSettings = $converted.Settings }
    if ($null -ne $Data.releasePolicy) {
        $rp = ConvertTo-ReleasePolicy $Data.releasePolicy
        foreach ($k in @($rp.Keys)) { $Global:App.ReleasePolicy[$k] = $rp[$k] }
    }
    # An empty list clears them - so "is it there", not "is it not null" (@() -ne $null is empty, so false).
    if (@($Data.PSObject.Properties.Name) -contains 'profiles') {
        $raw = @(@($Data.profiles) | ForEach-Object { @{ Name = [string]$_.name; Required = @($_.required); Available = @($_.available); Exclude = @($_.exclude) } })
        foreach ($p in $raw) { foreach ($g in @($p.Required) + @($p.Available) + @($p.Exclude)) { if (([string]$g).Trim()) { $problem = Test-WebGroupName ([string]$g).Trim(); if ($problem) { return @{ ok = $false; error = "Profile '$($p.Name)': $problem" } } } } }
        if (@($raw | Where-Object { -not ([string]$_.Name).Trim() }).Count) { return @{ ok = $false; error = 'Every profile needs a name.' } }
        if (@($raw | Group-Object { ([string]$_.Name).Trim() } | Where-Object { $_.Count -gt 1 }).Count) { return @{ ok = $false; error = 'Two profiles have the same name.' } }
        $Global:App.AssignmentProfiles = @(ConvertTo-AssignmentProfiles $raw)
    }
    if ($null -ne $Data.releaseRingsText) {
        $rr = ConvertFrom-ReleaseRingText ([string]$Data.releaseRingsText)
        if ($rr.Error) { return @{ ok = $false; error = "Release rings: $($rr.Error)" } }
        foreach ($ring in @($rr.Rings)) { foreach ($g in @($ring.Groups)) { $problem = Test-WebGroupName $g; if ($problem) { return @{ ok = $false; error = "Release rings ($($ring.Name)): $problem" } } } }
        $Global:App.ReleaseRings = @(ConvertTo-ReleaseRings $rr.Rings)
    }
    if ($null -ne $Data.alerts) {
        $al = $Data.alerts
        $url = ([string]$al.webhookUrl).Trim()
        $next = ConvertTo-AlertSettings @{ Level = [string]$al.level; WebhookUrl = $(if ($al.clearWebhook) { '' } elseif ($url) { $url } else { $Global:App.Alerts.WebhookUrl }); MailFrom = [string]$al.mailFrom; MailTo = @($al.mailTo) }
        if ($url -and -not $al.clearWebhook -and -not $next.WebhookUrl) { return @{ ok = $false; error = 'Alerts: the webhook address must start with https://.' } }
        if (([string]$al.mailFrom).Trim() -and -not $next.MailFrom) { return @{ ok = $false; error = "Alerts: '$($al.mailFrom)' isn't an email address." } }
        $badTo = @(@($al.mailTo) | Where-Object { ([string]$_).Trim() -and @($next.MailTo) -notcontains ([string]$_).Trim() })
        if ($badTo.Count) { return @{ ok = $false; error = "Alerts: '$($badTo[0])' isn't an email address." } }
        if ($next.MailTo.Count -and -not $next.MailFrom) { return @{ ok = $false; error = 'Alerts: say which mailbox the email is sent from.' } }
        $Global:App.Alerts = $next
    }
    if ($null -ne $Data.pilotGroups) {
        $pilot = @($Data.pilotGroups | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
        foreach ($g in $pilot) { $problem = Test-WebGroupName $g; if ($problem) { return @{ ok = $false; error = "Pilot groups: $problem" } } }
        $Global:App.PilotGroups = New-Object System.Collections.Generic.List[string]
        foreach ($g in $pilot) { $Global:App.PilotGroups.Add($g) }
    }
    if ($null -ne $Data.favoriteGroups) {
        $Global:App.FavoriteGroups = New-Object System.Collections.Generic.List[string]
        foreach ($g in @($Data.favoriteGroups | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)) { $Global:App.FavoriteGroups.Add($g) }
    }
    if (-not (Write-SettingsFile)) { return @{ ok = $false; error = "Couldn't write the settings file." } }
    Write-Log '[OK] Settings saved.'
    return (Get-WebPrefs)
}
