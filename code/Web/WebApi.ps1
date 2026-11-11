# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
  What the web interface's /api/ routes do. Each takes the request's JSON
  body (already token-checked) and returns a hashtable that is sent back
  as JSON: always "ok", and "error" when it isn't.

  Everything here reuses the app's own functions - catalog reading, the
  list row, the certificate status, the permission report, the setup
  checklist, the step runner.
#>

function Global:Get-WebState {
    $cert = Get-CertificateStatusText -Thumbprint $Global:App.GraphCertificateThumbprint
    return @{
        ok          = $true
        version     = $Global:App.AppVersion
        catalogPath = (Get-AppFolder -Kind Catalog)
        settings    = @{
            tenantId   = [string]$Global:App.GraphTenantId
            clientId   = [string]$Global:App.GraphClientId
            thumbprint = [string]$Global:App.GraphCertificateThumbprint
        }
        cert        = @{ text = [string]$cert.Text; level = ([string]$cert.Level) }
        configured  = [bool](Test-GraphCredentialsConfigured -Quiet)
        moduleOk    = [bool](Test-GraphModuleHere)
        # Settings > Automatic checks: what the page runs when it opens.
        startup     = @{ drift = [bool]$Global:App.CheckDriftOnStartup; fullAudit = [bool]$Global:App.RunFullAuditOnStartup }
    }
}

function Global:Get-WebCatalog {
    <#
      The catalog as list rows, read from disk on every call - someone
      else (or git) may change the folder, and a copy kept here would go
      stale.
    #>
    $catalog = Read-WebCatalogRecords
    $path = $catalog.Path
    $apps = $catalog.Apps
    $failed = $catalog.Failed
    $rows = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $path) {
        try { Load-LastAuditCache } catch { }
        $index = Get-PackageFolderIndex -Root (Get-AppFolder -Kind Packages)
        for ($i = 0; $i -lt $apps.Count; $i++) {
            $row = Get-CatalogRow -App $apps[$i] -Index $i -PackageIndex $index
            $rows.Add([ordered]@{
                name         = [string]$row.AppName
                wingetId     = [string]$row.WingetId
                appId        = [string]$apps[$i].appId
                type         = [string]$row.Type
                version      = [string]$row.Version
                customConfig = [string]$row.CustomConfig
                required     = [int]$row.Required
                available    = [int]$row.Available
                uninstall    = [int]$row.Uninstall
                status       = [string]$row.Status
                audit        = [string]$row.IntuneAudit
                hasAppId     = [bool]$row.HasAppId
                packageMissing = [bool]$row.PackageMissing
            })
        }
    }
    return @{ ok = $true; path = $path; exists = (Test-Path -LiteralPath $path); apps = $rows.ToArray(); failed = @($failed) }
}

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
    # Certificates on this machine that could sign in: with a private key, not expired.
    $now = Get-Date
    $list = foreach ($store in 'CurrentUser', 'LocalMachine') {
        Get-ChildItem -Path "Cert:\$store\My" -ErrorAction SilentlyContinue |
            Where-Object { $_.HasPrivateKey -and $_.NotAfter -gt $now } |
            ForEach-Object {
                [ordered]@{ subject = $_.Subject; thumbprint = $_.Thumbprint; notAfter = $_.NotAfter.ToString('yyyy-MM-dd'); store = $store }
            }
    }
    return @{ ok = $true; certificates = @($list) }
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
    $configPath = Join-Path $env:TEMP ".intunepkg_certupload_config_$tag.json"
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

function Global:Start-WebStepJob {
    <#
      Runs one of the app's step scripts (code\EmbeddedScripts) through the
      step runner, with the Graph and
      assignment helpers dot-sourced first - and registers it as a job the
      page polls (/api/job-poll). -ShowWindow for the steps that sign a
      person in (WAM needs a window). -After: what to do with the result
      once it has succeeded (see Complete-WebJob).
    #>
    param([string]$ScriptContent, [string]$Name, [string]$ConfigJson, [string]$ResultPath, [string]$Kind, [switch]$ShowWindow, [hashtable]$After = @{},
        # A step that takes its own parameters (Package.ps1) instead of -ConfigPath; @{} for none.
        [hashtable]$Parameters = $null,
        # Another PowerShell than the default one the steps use (installing the Graph module into each).
        [string]$Exe = '')
    $tag = [guid]::NewGuid().ToString('N')
    $configPath = Join-Path $env:TEMP ".intunepkg_$($Name)_config_$tag.json"
    $scriptPath = Join-Path $Global:App.RootPath ".intunepkg_embedded_$($Name)_$tag.ps1"
    $helperPath = Join-Path $Global:App.RootPath ".intunepkg_graphlog_$tag.ps1"
    $logPath = Join-Path $env:TEMP "intunepkg_$tag.log"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        if ($ConfigJson) { [System.IO.File]::WriteAllText($configPath, $ConfigJson, $utf8) }
        [System.IO.File]::WriteAllText($scriptPath, $ScriptContent, $utf8)
        [System.IO.File]::WriteAllText($helperPath, ((Get-GraphLogScriptHelpers) + "`n`n" + (Get-AssignmentScriptHelpers)), $utf8)
        [System.IO.File]::WriteAllText($logPath, '')
        $stepParams = if ($null -ne $Parameters) { $Parameters } else { @{ ConfigPath = $configPath } }
        $spec = @{ Script = $scriptPath; Parameters = $stepParams; GraphHelper = $helperPath; LogFile = $logPath }
        $psi = if ($Exe) { New-AppStepStartInfo -Exe $Exe -Spec $spec } else { New-AppStepStartInfo -Spec $spec }
        Set-WindowsPowerShellEnvironment -StartInfo $psi
        $psi.EnvironmentVariables['INTUNEPACKAGER_GRAPH_LOG'] = $(if ($Global:App.DetailedGraphLog) { 'detailed' } else { 'summary' })
        $psi.CreateNoWindow = -not $ShowWindow
        if ($ShowWindow) { $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized }
        $psi.WorkingDirectory = $Global:App.RootPath
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        Remove-Item -LiteralPath $scriptPath, $helperPath, $logPath, $configPath -Force -ErrorAction SilentlyContinue
        return @{ ok = $false; error = "Couldn't start the step: $($_.Exception.Message)" }
    }
    $Global:App.WebJobs[$tag] = @{
        Process = $proc; Log = $logPath; Result = $ResultPath
        Cleanup = @($scriptPath, $helperPath, $configPath); Mode = $Kind; Done = $false; After = $After
    }
    return @{ ok = $true; job = $tag }
}

function Global:Invoke-WithCatalogLock {
    <#
      Runs -Action holding the catalog lock. Requests run in parallel
      runspaces, and every change to an app's file is read - change - write:
      without the lock, a deploy saving its App ID while the editor saves
      the same app would lose one of the two changes.
    #>
    param([scriptblock]$Action)
    $lock = $Global:App.CatalogLock
    if ($null -eq $lock) { return (& $Action) }
    $taken = $false
    try {
        $taken = [System.Threading.Monitor]::TryEnter($lock, 30000)
        if (-not $taken) { return @{ ok = $false; error = 'The catalog is busy with another change - try again in a moment.' } }
        return (& $Action)
    }
    finally { if ($taken) { [System.Threading.Monitor]::Exit($lock) } }
}

function Global:Get-WebAppFileVersion {
    # A fingerprint of one app's saved file ('' when there is none), so a
    # save can tell whether the file changed since the editor opened it.
    param([string]$Name)
    $folder = Get-AppFolder -Kind Catalog
    if (-not $folder -or -not $Name) { return '' }
    $file = Join-Path $folder ((Get-SafeFileNameForApp -Name $Name) + '.json')
    if (-not (Test-Path -LiteralPath $file)) { return '' }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([System.IO.File]::ReadAllBytes($file))) -replace '-', '') }
    finally { $sha.Dispose() }
}

function Global:Update-WebCatalogApp {
    # Changes one app's saved file: reads it, lets -Change edit the record, writes it back (with a backup).
    param([string]$Name, [scriptblock]$Change)
    $catalog = Read-WebCatalogRecords
    $app = $catalog.Apps | Where-Object { $_.appName -eq $Name } | Select-Object -First 1
    if (-not $app) { throw "'$Name' is no longer in the catalog." }
    & $Change $app
    $file = Join-Path (Get-AppFolder -Kind Catalog -Create) ((Get-SafeFileNameForApp -Name $app.appName) + '.json')
    Backup-WebAppFile $file
    [System.IO.File]::WriteAllText($file, (ConvertTo-SingleAppJson -App $app), (New-Object System.Text.UTF8Encoding($false)))
    return $app
}

function Global:Complete-WebJob {
    <#
      After a step succeeded: what follows on from it.
      Deploy - the App ID (and the defaults it was deployed with, for an app
      that had none) saved to the catalog, and whether groups should follow.
    #>
    param([hashtable]$After, $Result, [string]$LogPath)
    switch ($After.Kind) {
        'grouprename' { return (Complete-WebGroupRename -After $After) }
        'checkdetails' { return (Complete-WebCheckDetails -After $After -Result $Result) }
        'checkassign' { return (Complete-WebCheckAssign -After $After -Result $Result) }
        'addtocatalog' { return (Complete-WebAddFromIntune -After $After -Result $Result) }
        'deleted' {
            $n = $After.AppName
            [void](Update-WebCatalogApp -Name $n -Change { param($a) $a.appId = ''; $a.intuneAppType = ''; $a.intuneAppVersion = '' })
            Write-Log "[OK] Deleted $n from Intune; its App ID is cleared in the catalog."
            return @{ ok = $true }
        }
        'pull' { return (Complete-WebPull -Result $Result) }
        'package' {
            # Package.ps1 ends with a summary ("Failed: N") but no exit code for
            # a single app failing - read it from the log.
            $text = ''
            try { $text = Get-Content -LiteralPath $LogPath -Raw -Encoding UTF8 } catch { }
            $failed = if ($text -match '(?m)Failed:\s*(\d+)') { [int]$Matches[1] } else { 0 }
            Write-Log "$(if ($failed) { '[WARN]' } else { '[OK]' }) Packaging finished$(if ($failed) { " - $failed failed, see the log" })."
            return @{ ok = $true; failed = $failed }
        }
        'deploy' {
            $newId = [string]$Result.appId
            $defaults = $After.Defaults
            [void](Update-WebCatalogApp -Name $After.AppName -Change {
                param($app)
                if ($newId) { $app.appId = $newId }
                $app.intuneAppType = 'Windows app (Win32)'
                if (-not $app.metadata -and $defaults) { $app.metadata = $defaults }
            }.GetNewClosure())
            Write-Log "[OK] Deployed $($After.AppName)$(if ($newId) { " (App ID $newId)" }) - saved to the catalog."
            $catalog = Read-WebCatalogRecords
            $app = $catalog.Apps | Where-Object { $_.appName -eq $After.AppName } | Select-Object -First 1
            $hasGroups = $app -and (@($app.requiredFor).Count + @($app.availableFor).Count + @($app.uninstallFor).Count) -gt 0
            $wanted = if ($After.WasUpdate) { [bool]$Global:App.PushGroupsOnUpdate } else { [bool]$Global:App.PushGroupsOnCreate }
            return @{ ok = $true; pushGroups = [bool]($hasGroups -and $wanted -and $app.appId) }
        }
        default { return @{ ok = $true } }
    }
}

function Global:Get-WebDeployPlan {
    <#
      What Deploy would do for the chosen apps, before anything runs: in
      dependency order, each app ready or skipped with the reason.
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ })
    $chosen = @($catalog.Apps | Where-Object { $names -contains $_.appName })
    if ($chosen.Count -eq 0) { return @{ ok = $false; error = 'Choose one or more apps first.' } }
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $order = Get-DependencyOrderedApps -Apps $chosen
    $index = Get-PackageFolderIndex -Root (Get-AppFolder -Kind Packages)
    # Settings > Automatic checks: before creating an app, look for one of the
    # same name already in Intune - creating a second is the mistake to stop.
    $inIntune = @{}
    $note = ''
    if ($Global:App.CheckIntuneOnDeployOpen -and @($chosen | Where-Object { -not $_.appId }).Count) {
        $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action {
            param($Graph)
            $names = New-Object System.Collections.Generic.List[object]
            $uri = 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id,displayName&$top=999'
            while ($uri) { $page = & $Graph $uri; foreach ($v in @($page.value)) { $names.Add($v) }; $uri = [string]$page.'@odata.nextLink' }
            , $names.ToArray()
        }
        if ($read.ok) { foreach ($v in @($read.value)) { $inIntune[([string]$v.displayName).Trim().ToLowerInvariant()] = [string]$v.id } }
        else { $note = "Couldn't look for apps of the same name in Intune: $($read.error)" }
    }
    $plan = foreach ($a in @($order.Ordered)) {
        $unc = Test-AppIsUncommon -App $a
        $pkg = Resolve-AppPackagePath -AppName $a.appName -Uncommon $unc -Index $index -PackagePath $a.packagePath
        $reason = ''
        # A same-name app in Intune first: building a package would only lead to a duplicate.
        if (-not $a.appId -and $inIntune.ContainsKey(([string]$a.appName).Trim().ToLowerInvariant())) { $reason = 'An app with this name is already in Intune - link it (Checks > Link) instead of creating a second one.' }
        elseif (-not $pkg.Found) {
            $reason = if ($unc) { "No package (.intunewin) yet - build it with More > Package." } else { "The shared Winget package (init.intunewin) isn't built yet - Settings > Packaging builds it." }
        }
        elseif ($unc -and -not ($a.metadata -and $a.metadata.detectionRule)) { $reason = "No detection rule yet - an app with its own package needs one (the editor's Deploy settings)." }
        [ordered]@{ name = $a.appName; update = [bool]$a.appId; ready = (-not $reason); reason = $reason }
    }
    return @{ ok = $true; apps = @($plan); circular = @($order.CircularNames); note = $note }
}

function Global:Start-WebDeploy {
    # Deploys ONE app (the page runs the plan's apps one after another).
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $a = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "'$name' is no longer in the catalog." } }
    $unc = Test-AppIsUncommon -App $a
    # -metadataOnly: Push settings - the catalog's settings to an app already in
    # Intune, without uploading a package.
    $metadataOnly = [bool]$Data.metadataOnly
    if ($metadataOnly) {
        if (-not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune yet - Deploy it first." } }
        if (-not $a.metadata) { return @{ ok = $false; error = "$name has no settings of its own yet - Pull them from Intune, or set them in the editor, first." } }
        $pkg = @{ Found = $true; Path = '' }
    }
    else {
        $pkg = Resolve-AppPackagePath -AppName $a.appName -Uncommon $unc -PackagePath $a.packagePath
        if (-not $pkg.Found) { return @{ ok = $false; error = "$name has no package to upload." } }
    }
    $defaults = $null
    $m = $a.metadata
    if (-not $m) { $defaults = Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon $unc; $m = $defaults }
    if (-not $m.detectionRule) { return @{ ok = $false; error = "$name has no detection rule - set one in the editor's Deploy settings." } }
    # Dependencies by name -> the App IDs they have now; one not deployed yet is left out (as Batch Deploy does).
    $depIds = @(@($m.dependencies) | Where-Object { $_ } | ForEach-Object {
        $depName = [string]$_
        $dep = $catalog.Apps | Where-Object { $_.appName -eq $depName } | Select-Object -First 1
        if ($dep -and $dep.appId) { $dep.appId }
    })
    $resultPath = Join-Path $env:TEMP (".intunepkg_createapp_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = [pscustomobject]@{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        Mode = $(if ($a.appId) { 'UpdateMetadata' } else { 'Create' }); ExistingAppId = [string]$a.appId
        AppName = $a.appName; Description = $m.description; Publisher = $m.publisher; Owner = $m.owner; Developer = $m.developer
        InformationUrl = $m.informationUrl; PrivacyUrl = $m.privacyUrl; Notes = $m.notes; AppVersion = $m.appVersion; IsFeatured = $m.isFeatured
        InstallCommand = $m.installCommand; UninstallCommand = $m.uninstallCommand; DetectionRule = $m.detectionRule
        InstallContext = $m.installContext; Architecture = $m.architecture; MinOSVersionKey = $m.minOSKey; PackagePath = $pkg.Path
        DependencyAppIds = $depIds; Supersedence = $m.supersedes; ReplaceContent = $false
        MinDiskSpaceMB = [int]$m.minDiskSpaceMB; MinMemoryMB = [int]$m.minMemoryMB; MinProcessors = [int]$m.minProcessors; MinCpuSpeedMHz = [int]$m.minCpuSpeedMHz
        InstallTimeMinutes = $(if ($m.installTimeMinutes) { [int]$m.installTimeMinutes } else { 60 }); DeviceRestartBehavior = $m.deviceRestartBehavior
        AllowAvailableUninstall = [bool]$m.allowAvailableUninstall; ReturnCodes = @($m.returnCodes); OutputResultPath = $resultPath
    }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedCreateAppScript -Name 'createapp' -ConfigJson (ConvertTo-CreateAppConfigJson -Config $config) -ResultPath $resultPath -Kind "$(if ($metadataOnly) { 'Push settings' } else { 'Deploy' }) $name" `
        -After @{ Kind = 'deploy'; AppName = $a.appName; Defaults = $defaults; WasUpdate = [bool]$a.appId }
    if ($started.ok) { Write-Log "[INFO] $(if ($metadataOnly) { "Pushing $name's settings to Intune" } else { "Deploying $name ($($config.Mode))" })..." }
    return $started
}

function Global:Start-WebPushGroups {
    <#
      Push groups for the chosen apps: Mode Preview lists what would be added
      and removed in Intune, Mode Apply does it (BatchAssign - Intune gets
      exactly the catalog's groups; missing groups are created). -single
      after a deploy pushes one app the way the single deploy does
      (TargetedAssign, no groups created).
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ })
    $apps = @($catalog.Apps | Where-Object { $names -contains $_.appName -and $_.appId })
    if ($apps.Count -eq 0) { return @{ ok = $false; error = 'None of the chosen apps is in Intune yet (no App ID).' } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_assign_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $creds = @{ TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint }
    if ([string]$Data.mode -eq 'AfterDeploy') {
        $a = $apps[0]
        $config = @{
            TenantId = $creds.TenantId; ClientId = $creds.ClientId; CertificateThumbprint = $creds.CertificateThumbprint
            AppId = $a.appId; AppName = $a.appName
            RequiredGroups = @($a.requiredFor); AvailableGroups = @($a.availableFor); UninstallGroups = @($a.uninstallFor); ExcludeGroups = @($a.excludeFor)
            CreateMissingGroups = $false; OutputResultPath = $resultPath
        }
        return (Start-WebStepJob -ScriptContent $Global:App.EmbeddedTargetedAssignScript -Name 'targetedassign' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind "Push groups $($a.appName)")
    }
    $mode = if ([string]$Data.mode -eq 'Apply') { 'Apply' } else { 'Preview' }
    $config = @{
        TenantId = $creds.TenantId; ClientId = $creds.ClientId; CertificateThumbprint = $creds.CertificateThumbprint
        Mode = $mode
        Apps = @($apps | ForEach-Object { @{ AppName = $_.appName; AppId = $_.appId; RequiredGroups = @($_.requiredFor); AvailableGroups = @($_.availableFor); UninstallGroups = @($_.uninstallFor); ExcludeGroups = @($_.excludeFor) } })
        OutputResultPath = $resultPath
    }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedBatchAssignScript -Name 'batchassign' -ConfigJson ($config | ConvertTo-Json -Depth 8) -ResultPath $resultPath -Kind "Push groups ($mode, $($apps.Count) app(s))"
    if ($started.ok) { Write-Log "[INFO] Push groups - $(if ($mode -eq 'Apply') { 'applying' } else { 'previewing' }) for $($apps.Count) app(s)..." }
    return $started
}

function Global:Get-WebPackaging {
    # What packaging needs and whether it's there: the tool, and the shared Winget package.
    $r = Get-PackagingReadiness
    return @{ ok = $true; toolPath = [string]$r.ToolPath; toolFound = [bool]$r.ToolFound; toolVersion = [string]$r.ToolVersion
        sharedPath = [string]$r.SharedPath; sharedFound = [bool]$r.SharedFound; packagesFolder = (Get-AppFolder -Kind Packages) }
}

function Global:Invoke-WebPackagingSetup {
    # Downloads the packaging tool, or builds init.intunewin (downloading the tool first if needed).
    param($Data)
    switch ([string]$Data.what) {
        'tool' { $r = Install-PackagingTool }
        'shared' {
            if (-not (Get-PackagingReadiness).ToolFound) {
                $t = Install-PackagingTool
                if (-not $t.Ok) { return @{ ok = $false; error = [string]$t.Message } }
            }
            $r = New-SharedWingetPackage
        }
        default { return @{ ok = $false; error = 'Unknown setup step.' } }
    }
    return @{ ok = [bool]$r.Ok; error = $(if (-not $r.Ok) { [string]$r.Message } else { '' }); message = [string]$r.Message; state = (Get-WebPackaging) }
}

function Global:Start-WebPackage {
    <#
      Builds .intunewin packages (Package.ps1) for apps with their own
      installer - one, several, or every one when -names is empty. Winget
      apps all deploy the shared init.intunewin and are skipped.
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $own = @($catalog.Apps | Where-Object { Test-AppIsUncommon -App $_ })
    if ($names.Count) { $own = @($own | Where-Object { $names -contains $_.appName }) }
    if ($names.Count -and $own.Count -eq 0) { return @{ ok = $false; error = 'None of the chosen apps has its own installer to package - Winget apps use the shared package.' } }
    $params = @{ InputFolder = (Get-AppFolder -Kind Packages -Create); Force = $true; ToolPath = (Get-PackagingToolPath) }
    $folders = @($own | ForEach-Object { Get-SafeFileNameForApp -Name $_.appName })
    if ($names.Count -eq 1) { $params.SingleFolderName = $folders[0] }
    elseif ($names.Count -gt 1) { $params.FolderNames = ($folders -join ',') }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedPackageScript -Name 'package' -ConfigJson '' -ResultPath '' -Kind 'Package' -Parameters $params -After @{ Kind = 'package' }
    if ($started.ok) { Write-Log "[INFO] Packaging $(if ($names.Count) { "$($own.Count) app(s)" } else { 'every app with its own installer' })..." }
    return $started
}

function Global:Start-WebPull {
    # Pull from Intune: reads each chosen app's settings and groups (SyncMetadata - only reads).
    param($Data)
    $catalog = Read-WebCatalogRecords
    $names = @($Data.names | ForEach-Object { [string]$_ })
    $apps = @($catalog.Apps | Where-Object { $names -contains $_.appName -and $_.appId })
    if ($apps.Count -eq 0) { return @{ ok = $false; error = 'None of the chosen apps is in Intune yet (no App ID).' } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_sync_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        Apps = @($apps | ForEach-Object { @{ AppName = $_.appName; AppId = $_.appId } }); OutputResultPath = $resultPath
    }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedSyncMetadataScript -Name 'syncmeta' -ConfigJson ($config | ConvertTo-Json -Depth 6) -ResultPath $resultPath -Kind "Pull ($($apps.Count) app(s))" -After @{ Kind = 'pull' }
    if ($started.ok) { Write-Log "[INFO] Reading $($apps.Count) app(s) from Intune..." }
    return $started
}

function Global:Complete-WebPull {
    <#
      What Pull found: an app whose catalog entry matches
      Intune (or has no settings yet) takes Intune's at once; one that
      differs is kept back for the user to choose, field by field.
    #>
    param($Result)
    $applied = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    $review = New-Object System.Collections.Generic.List[object]
    $pending = @{}
    foreach ($r in @($Result.results)) {
        if (-not $r.Success) { $failed.Add("$($r.AppName): $($r.Error)"); continue }
        $app = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $r.AppName } | Select-Object -First 1
        if (-not $app) { continue }
        $fieldDiffs = @(Get-CatalogMetadataFieldDiffs -Local $app.metadata -Remote $r.Metadata -OdataType $r.OdataType)
        $groupDiffs = if ($r.GroupFetchOk) { @(Get-GroupFieldDiffs -LocalApp $app -RemoteResult $r) } else { @() }
        if (($app.metadata -and $fieldDiffs.Count -gt 0) -or $groupDiffs.Count -gt 0) {
            $pending[$r.AppName] = $r
            $review.Add([ordered]@{ app = $r.AppName; diffs = @(@($fieldDiffs) + @($groupDiffs) | ForEach-Object { [ordered]@{ field = [string]$_.Field; local = (Get-CheckValueText $_.Local); intune = (Get-CheckValueText $_.Remote) } }) })
        }
        else {
            $rr = $r
            [void](Update-WebCatalogApp -Name $r.AppName -Change {
                param($a)
                $a.intuneAppType = Get-FriendlyIntuneAppType -ODataType $rr.OdataType
                $a.intuneAppVersion = [string]$rr.DisplayVersion
                $a.metadata = $rr.Metadata
            }.GetNewClosure())
            $applied.Add($r.AppName)
        }
    }
    $id = [guid]::NewGuid().ToString('N')
    if ($review.Count) { $Global:App.WebPending[$id] = $pending }
    Write-Log "[OK] Pulled from Intune: $($applied.Count) updated$(if ($review.Count) { ", $($review.Count) to review" })$(if ($failed.Count) { ", $($failed.Count) failed" })."
    return @{ ok = $true; pending = $(if ($review.Count) { $id } else { '' }); applied = $applied.ToArray(); review = $review.ToArray(); failed = $failed.ToArray() }
}

function Global:Invoke-WebPullApply {
    # The user's choice per reviewed app: which fields keep the catalog's value; the rest take Intune's.
    param($Data)
    $id = [string]$Data.pending
    if (-not $id -or -not $Global:App.WebPending.ContainsKey($id)) { return @{ ok = $false; error = 'Nothing waiting to be applied (run Pull again).' } }
    $pending = $Global:App.WebPending[$id]
    $done = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($pending.Keys)) {
        $r = $pending[$name]
        $keep = @($Data.keep.$name | ForEach-Object { [string]$_ })
        [void](Update-WebCatalogApp -Name $name -Change {
            param($a)
            $a.intuneAppType = Get-FriendlyIntuneAppType -ODataType $r.OdataType
            $a.intuneAppVersion = [string]$r.DisplayVersion
            $a.metadata = if ($a.metadata) { Merge-CatalogMetadata -Remote $r.Metadata -Local $a.metadata -KeepLocalFields $keep } else { $r.Metadata }
            if ($r.GroupFetchOk) {
                if ($keep -notcontains 'Required for') { $a.requiredFor = @($r.RequiredGroupNames) }
                if ($keep -notcontains 'Available for') { $a.availableFor = @($r.AvailableGroupNames) }
                if ($keep -notcontains 'Uninstall for') { $a.uninstallFor = @($r.UninstallGroupNames) }
            }
        }.GetNewClosure())
        $done.Add($name)
    }
    [void]$Global:App.WebPending.Remove($id)
    Write-Log "[OK] Applied the pull for: $($done -join ', ')."
    return @{ ok = $true; applied = $done.ToArray() }
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
        WingetInstallMethod = $(if ([string]$Form.wingetInstallMethod -eq 'Winget') { 'Winget' } else { 'WAU' })
    } }
}

function Global:Get-WebPrefs {
    $d = $Global:App.DefaultAppSettings
    return @{
        ok = $true
        checks = [ordered]@{
            checkDriftOnStartup = [bool]$Global:App.CheckDriftOnStartup; runFullAuditOnStartup = [bool]$Global:App.RunFullAuditOnStartup
            checkIntuneOnDeployOpen = [bool]$Global:App.CheckIntuneOnDeployOpen; pushGroupsOnCreate = [bool]$Global:App.PushGroupsOnCreate
            pushGroupsOnUpdate = [bool]$Global:App.PushGroupsOnUpdate; detailedGraphLog = [bool]$Global:App.DetailedGraphLog
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
    }
}

function Global:Save-WebPrefs {
    param($Data)
    if ($Data.defaults) {
        $converted = ConvertTo-WebDefaultSettings $Data.defaults
        if ($converted.Error) { return @{ ok = $false; error = $converted.Error } }
    }
    if ($Data.checks) {
        $c = $Data.checks
        $Global:App.CheckDriftOnStartup = [bool]$c.checkDriftOnStartup; $Global:App.RunFullAuditOnStartup = [bool]$c.runFullAuditOnStartup
        $Global:App.CheckIntuneOnDeployOpen = [bool]$c.checkIntuneOnDeployOpen; $Global:App.PushGroupsOnCreate = [bool]$c.pushGroupsOnCreate
        $Global:App.PushGroupsOnUpdate = [bool]$c.pushGroupsOnUpdate; $Global:App.DetailedGraphLog = [bool]$c.detailedGraphLog
    }
    if ($Data.folders) {
        foreach ($p in $Data.folders.PSObject.Properties) { Set-AppFolder -Kind $p.Name -Path ([string]$p.Value) }
    }
    if ($Data.defaults) { $Global:App.DefaultAppSettings = $converted.Settings }
    if ($null -ne $Data.favoriteGroups) {
        $Global:App.FavoriteGroups = New-Object System.Collections.Generic.List[string]
        foreach ($g in @($Data.favoriteGroups | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)) { $Global:App.FavoriteGroups.Add($g) }
    }
    if (-not (Write-SettingsFile)) { return @{ ok = $false; error = "Couldn't write the settings file." } }
    Write-Log '[OK] Settings saved.'
    return (Get-WebPrefs)
}

function Global:Start-WebDeleteFromIntune {
    <#
      Deletes ONE app from Intune (DeleteApp - removes it as a dependency of
      another app first when -dependentOf says so), then clears its App ID
      in the catalog. The catalog entry itself stays.
    #>
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $a = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a -or -not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune (no App ID)." } }
    $resultPath = Join-Path $env:TEMP (".intunepkg_delete_result_" + [guid]::NewGuid().ToString('N') + ".json")
    $config = @{
        TenantId = $Global:App.GraphTenantId; ClientId = $Global:App.GraphClientId; CertificateThumbprint = $Global:App.GraphCertificateThumbprint
        AppId = $a.appId; AppName = $a.appName; RemoveDependencyFromAppId = ''; OutputResultPath = $resultPath
    }
    $started = Start-WebStepJob -ScriptContent $Global:App.EmbeddedDeleteAppScript -Name 'deleteapp' -ConfigJson ($config | ConvertTo-Json -Depth 4) -ResultPath $resultPath -Kind "Delete $name from Intune" -After @{ Kind = 'deleted'; AppName = $a.appName }
    if ($started.ok) { Write-Log "[INFO] Deleting $name from Intune..." }
    return $started
}

function Global:Clear-WebAppId {
    # Forgets the Intune link in the catalog (App ID, Intune's type and version). Intune isn't touched.
    param($Data)
    $name = [string]$Data.name
    try { [void](Update-WebCatalogApp -Name $name -Change { param($a) $a.appId = ''; $a.intuneAppType = ''; $a.intuneAppVersion = '' }) }
    catch { return @{ ok = $false; error = $_.Exception.Message } }
    Write-Log "[OK] Cleared $name's App ID in the catalog."
    return @{ ok = $true }
}

function Global:Get-WebInstallStatus {
    # Every device's install state for one app, from Intune's install status report.
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $a = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a -or -not $a.appId) { return @{ ok = $false; error = "$name isn't in Intune (no App ID)." } }
    $id = [string]$a.appId
    $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) Get-AppInstallStatusRows -AppId $id -Invoke $Graph }
    if (-not $read.ok) { return $read }
    $report = $read.value
    $rows = @($report.Rows | ForEach-Object { [ordered]@{ device = [string]$_.DeviceName; user = [string]$_.UserName; state = [string]$_.State; detail = [string]$_.Detail; error = [string]$_.ErrorCode; version = [string]$_.Version; lastSeen = [string]$_.LastSeen } })
    return @{ ok = $true; app = $name; rows = $rows; truncated = [bool]$report.Truncated; summary = (Format-InstallStatusSummary @($report.Rows)) }
}

function Global:Get-WebJobPoll {
    # New output since -offset, and the result once the step has ended.
    param($Data)
    $id = [string]$Data.job
    if (-not $id -or -not $Global:App.WebJobs.ContainsKey($id)) { return @{ ok = $false; error = 'No such job.' } }
    $job = $Global:App.WebJobs[$id]
    $offset = [int64]$Data.offset
    $exited = $job.Process.HasExited
    $text = ''
    try {
        $fs = [System.IO.File]::Open($job.Log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            [void]$fs.Seek([Math]::Min($offset, $fs.Length), [System.IO.SeekOrigin]::Begin)
            $reader = New-Object System.IO.StreamReader($fs)
            $text = $reader.ReadToEnd()
            $offset = $fs.Position
        }
        finally { $fs.Dispose() }
    }
    catch { }
    $response = [ordered]@{ ok = $true; text = $text; offset = $offset; done = $false }
    if ($exited) {
        $response.done = $true
        $response.exitCode = $job.Process.ExitCode
        $response.result = $null
        if ($job.Result -and (Test-Path -LiteralPath $job.Result)) {
            try { $response.result = Get-Content -LiteralPath $job.Result -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        }
        elseif (-not $job.Result) {
            # A step without a result file (Package.ps1) - its exit code says it.
            $response.result = [pscustomobject]@{ success = ($job.Process.ExitCode -eq 0); error = $(if ($job.Process.ExitCode -ne 0) { "Exit code $($job.Process.ExitCode) - see the log." } else { '' }) }
        }
        # Cleaned up only once the page has read everything (an empty read
        # after the exit); until then the log stays for the next poll.
        if (-not $text) {
            # Under the catalog lock: the completion writes app files, and two
            # polls arriving together must not complete the same job twice.
            $after = Invoke-WithCatalogLock {
                if (-not $Global:App.WebJobs.ContainsKey($id)) { return @{ finished = $false } }
                [void]$Global:App.WebJobs.Remove($id)
                $done = $null
                if ($response.result -and $response.result.success -and $job.After -and $job.After.Count) {
                    try { $done = Complete-WebJob -After $job.After -Result $response.result -LogPath $job.Log }
                    catch { $done = @{ ok = $false; error = $_.Exception.Message }; Write-Log "[WARN] $($_.Exception.Message)" }
                }
                return @{ finished = $true; after = $done }
            }
            if ($after.finished) {
                if ($null -ne $after.after) { $response.after = $after.after }
                Remove-Item -LiteralPath (@($job.Cleanup) + $job.Log + @($job.Result | Where-Object { $_ })) -Force -ErrorAction SilentlyContinue
                Write-Log "$(if ($response.result -and $response.result.success) { '[OK]' } else { '[WARN]' }) Finished: $($job.Mode)."
            }
        }
    }
    return $response
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

function Global:Open-WebTarget {
    <#
      Opens something outside the browser window: Entra's API permissions
      page, the catalog, scripts or certificates folder, Entra. A
      fixed list - nothing from the request is started as given.
    #>
    param($Data)
    switch ([string]$Data.target) {
        'entra-permissions' {
            $url = Get-WebEntraPermissionsUrl -ClientId ([string]$Data.clientId)
            if (-not $url) { return @{ ok = $false; error = 'Fill in the Client (Application) ID first.' } }
            Start-Process $url
        }
        'catalog-folder' { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$(Get-AppFolder -Kind Catalog -Create)`"" }
        'entra-home' { Start-Process 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade/quickStartType~/null/sourceType/Microsoft_AAD_IAM' }
        'scripts-folder' { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$(Get-AppFolder -Kind Scripts -Create)`"" }
        'certificates-folder' {
            $folder = Join-Path $Global:App.RootPath 'data\certificates'
            if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
            Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$folder`""
        }
        default { return @{ ok = $false; error = 'Unknown target.' } }
    }
    return @{ ok = $true }
}

function Global:Get-WebLog {
    param($Data)
    $from = [int]$Data.from
    $all = @($Global:App.WebLog.ToArray())
    $from = [Math]::Max(0, [Math]::Min($from, $all.Count))
    return @{ ok = $true; next = $all.Count; lines = @($all | Select-Object -Skip $from) }
}

function Global:Read-WebCatalogRecords {
    <#
      Every app in the catalog folder as an app record, and the same list
      put into $Global:App.Apps - the shared functions that look at "the
      catalog" (default dependencies, known groups) read it from there.
      Read fresh each time: the folder may have changed since.
    #>
    $path = Get-AppFolder -Kind Catalog
    $apps = New-Object System.Collections.ArrayList
    $failed = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $path) {
        foreach ($file in @(Get-ChildItem -LiteralPath $path -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            try { [void]$apps.Add((ConvertTo-AppRecord (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json))) }
            catch { $failed.Add($file.Name) }
        }
    }
    $Global:App.Apps = $apps
    return @{ Path = $path; Apps = $apps; Failed = $failed.ToArray() }
}

function Global:Test-WebWingetId {
    # Pure: a Winget ID as winget itself allows them (letters, digits, . _ + -).
    param([string]$Id)
    if (-not $Id) { return $true }
    return ($Id -match '^[A-Za-z0-9][A-Za-z0-9._+\-]{0,127}$')
}

function Global:Get-WebAppEditable {
    # Pure: an app record as the editor's JSON - every field it shows.
    param($App)
    $m = $App.metadata
    return [ordered]@{
        appName      = [string]$App.appName
        wingetId     = [string]$App.wingetId
        appId        = [string]$App.appId
        intuneAppType = [string]$App.intuneAppType
        requiredFor  = @($App.requiredFor | ForEach-Object { [string]$_ })
        availableFor = @($App.availableFor | ForEach-Object { [string]$_ })
        uninstallFor = @($App.uninstallFor | ForEach-Object { [string]$_ })
        excludeFor   = @($App.excludeFor | ForEach-Object { [string]$_ })
        hasMetadata  = [bool]$m
        metadata     = [ordered]@{
            description      = [string]$(if ($m) { $m.description })
            publisher        = [string]$(if ($m) { $m.publisher })
            owner            = [string]$(if ($m) { $m.owner })
            developer        = [string]$(if ($m) { $m.developer })
            informationUrl   = [string]$(if ($m) { $m.informationUrl })
            privacyUrl       = [string]$(if ($m) { $m.privacyUrl })
            notes            = [string]$(if ($m) { $m.notes })
            appVersion       = [string]$(if ($m) { $m.appVersion })
            installCommand   = [string]$(if ($m) { $m.installCommand })
            uninstallCommand = [string]$(if ($m) { $m.uninstallCommand })
            installContext   = [string]$(if ($m) { $m.installContext })
        }
    }
}

function Global:ConvertTo-WebDeploySettings {
    <#
      Pure: the editor's "Deploy settings" section, checked, as
      @{ Error; Values } - Values are
      catalog metadata properties, ready to set. Error is '' when fine.
      -AppNames: the catalog's apps (a dependency must be one of them, and
      not the app itself, -Self).
    #>
    param($Form, [string[]]$AppNames = @(), [string]$Self = '')
    $ops = 'notConfigured', 'equal', 'notEqual', 'greaterThan', 'greaterThanOrEqual', 'lessThan', 'lessThanOrEqual'
    $d = $Form.detection
    $rule = $null
    switch ([string]$d.type) {
        'Script' {
            if (-not ([string]$d.script).Trim()) { return @{ Error = 'The detection script is empty.' } }
            $rule = [pscustomobject]@{ Type = 'Script'; Script_Content = (ConvertTo-CanonicalLineEndings ([string]$d.script)).TrimEnd() }
        }
        'Msi' {
            if (-not ([string]$d.productCode).Trim()) { return @{ Error = 'An MSI detection rule needs the product code.' } }
            if ([string]$d.operator -notin $ops) { return @{ Error = 'Unknown version operator.' } }
            $rule = [pscustomobject]@{ Type = 'Msi'; Msi_ProductCode = ([string]$d.productCode).Trim(); Msi_VersionOperator = [string]$d.operator; Msi_Version = ([string]$d.value).Trim() }
        }
        'File' {
            if (-not ([string]$d.path).Trim() -or -not ([string]$d.name).Trim()) { return @{ Error = 'A file detection rule needs the folder and the file name.' } }
            if ([string]$d.detectionType -notin 'exists', 'doesNotExist', 'modifiedDate', 'createdDate', 'version', 'sizeInMB') { return @{ Error = 'Unknown file detection type.' } }
            if ([string]$d.operator -notin $ops) { return @{ Error = 'Unknown operator.' } }
            $rule = [pscustomobject]@{ Type = 'File'; File_Path = ([string]$d.path).Trim(); File_Name = ([string]$d.name).Trim(); File_Check32Bit = [bool]$d.check32Bit
                File_DetectionType = [string]$d.detectionType; File_Operator = [string]$d.operator; File_DetectionValue = ([string]$d.value).Trim() }
        }
        'Registry' {
            if (-not ([string]$d.keyPath).Trim()) { return @{ Error = 'A registry detection rule needs the key path.' } }
            if ([string]$d.detectionType -notin 'exists', 'doesNotExist', 'string', 'integer', 'version') { return @{ Error = 'Unknown registry detection type.' } }
            if ([string]$d.operator -notin $ops) { return @{ Error = 'Unknown operator.' } }
            $rule = [pscustomobject]@{ Type = 'Registry'; Reg_KeyPath = ([string]$d.keyPath).Trim(); Reg_ValueName = ([string]$d.valueName).Trim(); Reg_Check32Bit = [bool]$d.check32Bit
                Reg_DetectionType = [string]$d.detectionType; Reg_Operator = [string]$d.operator; Reg_DetectionValue = ([string]$d.value).Trim() }
        }
        '' { $rule = $null }
        default { return @{ Error = 'Unknown detection rule type.' } }
    }
    # The requirement fields are the same as the default values' - one checker.
    $base = ConvertTo-WebDefaultSettings $Form
    if ($base.Error) { return @{ Error = $base.Error } }
    $deps = @(@($Form.dependencies) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    foreach ($dep in $deps) {
        if ($dep -eq $Self) { return @{ Error = "An app can't depend on itself." } }
        if ($AppNames -notcontains $dep) { return @{ Error = "Dependency '$dep' isn't an app in this catalog." } }
    }
    $b = $base.Settings
    return @{ Error = ''; Values = [ordered]@{
        detectionRule = $rule; architecture = $b.Architecture; minOSKey = $b.MinOSKey
        minDiskSpaceMB = $b.MinDiskSpaceMB; minMemoryMB = $b.MinMemoryMB; minProcessors = $b.MinProcessors; minCpuSpeedMHz = $b.MinCpuSpeedMHz
        installTimeMinutes = $b.InstallTimeMinutes; deviceRestartBehavior = $b.DeviceRestartBehavior; allowAvailableUninstall = $b.AllowAvailableUninstall
        returnCodes = @($b.ReturnCodes); dependencies = $deps
    } }
}

function Global:Get-WebDeployEditable {
    # Pure: an app's metadata as the editor's "Deploy settings" section.
    param($Metadata)
    $m = $Metadata
    $r = if ($m) { $m.detectionRule } else { $null }
    $det = [ordered]@{ type = ''; script = ''; productCode = ''; operator = 'notConfigured'; value = ''; path = ''; name = ''; check32Bit = $false; detectionType = 'exists'; keyPath = ''; valueName = '' }
    if ($r) {
        $det.type = [string]$r.Type
        switch ([string]$r.Type) {
            'Script' { $det.script = [string]$r.Script_Content }
            'Msi' { $det.productCode = [string]$r.Msi_ProductCode; $det.operator = [string]$r.Msi_VersionOperator; $det.value = [string]$r.Msi_Version }
            'File' { $det.path = [string]$r.File_Path; $det.name = [string]$r.File_Name; $det.check32Bit = [bool]$r.File_Check32Bit; $det.detectionType = [string]$r.File_DetectionType; $det.operator = [string]$r.File_Operator; $det.value = [string]$r.File_DetectionValue }
            'Registry' { $det.keyPath = [string]$r.Reg_KeyPath; $det.valueName = [string]$r.Reg_ValueName; $det.check32Bit = [bool]$r.Reg_Check32Bit; $det.detectionType = [string]$r.Reg_DetectionType; $det.operator = [string]$r.Reg_Operator; $det.value = [string]$r.Reg_DetectionValue }
        }
        if (-not $det.operator) { $det.operator = 'notConfigured' }
    }
    return [ordered]@{
        detection = $det
        architecture = @(([string]$(if ($m) { $m.architecture })) -split ',' | Where-Object { $_ }); installContext = $(if ($m -and [string]$m.installContext -eq 'User') { 'User' } else { 'System' })
        minOSKey = [string]$(if ($m) { $m.minOSKey }); minDiskSpaceMB = [int]$(if ($m) { $m.minDiskSpaceMB }); minMemoryMB = [int]$(if ($m) { $m.minMemoryMB })
        minProcessors = [int]$(if ($m) { $m.minProcessors }); minCpuSpeedMHz = [int]$(if ($m) { $m.minCpuSpeedMHz }); installTimeMinutes = [int]$(if ($m -and $m.installTimeMinutes) { $m.installTimeMinutes } else { 60 })
        deviceRestartBehavior = [string]$(if ($m -and $m.deviceRestartBehavior) { $m.deviceRestartBehavior } else { 'basedOnReturnCode' }); allowAvailableUninstall = [bool]$(if ($m) { $m.allowAvailableUninstall })
        returnCodes = @($(if ($m) { $m.returnCodes }) | Where-Object { $_ } | ForEach-Object { [ordered]@{ returnCode = [int]$_.returnCode; type = [string]$_.type } })
        dependencies = @($(if ($m) { $m.dependencies }) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
}

function Global:Get-WebApp {
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $app = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $app) { return @{ ok = $false; error = "No app called '$name' in the catalog (it may have been renamed or removed - Reload)." } }
    $editable = Get-WebAppEditable $app
    $meta = if ($app.metadata) { $app.metadata } else { try { Get-DefaultAppMetadata -AppName $app.appName -WingetId $app.wingetId -Uncommon (-not $app.wingetId) } catch { $null } }
    $editable.deploy = Get-WebDeployEditable $meta
    return @{ ok = $true; app = $editable; version = (Get-WebAppFileVersion $app.appName); knownGroups = @(Get-AllKnownGroups | Sort-Object -Unique)
        appNames = @($catalog.Apps | ForEach-Object { $_.appName } | Where-Object { $_ -ne $name } | Sort-Object); minOsChoices = @(Get-WebMinOsChoices) }
}

function Global:Merge-WebAppEdit {
    <#
      Pure: the app record after the editor's changes - everything the
      editor doesn't show (detection rule, dependencies, supersedence,
      package path, Intune's type and version, ...) carried over untouched.
      Metadata is only created for an app that had none when a metadata
      field was actually filled in, from the computed defaults.
    #>
    param($Existing, $Edit, $Defaults)
    $groups = {
        param($list)
        @(@($list) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    }
    $metaEdit = $Edit.metadata
    # installContext is in the Deploy settings section (ConvertTo-WebDeploySettings).
    $metaFields = 'description', 'publisher', 'owner', 'developer', 'informationUrl', 'privacyUrl', 'notes', 'appVersion', 'installCommand', 'uninstallCommand'
    $metadata = if ($Existing -and $Existing.metadata) { $Existing.metadata.PSObject.Copy() } else { $null }
    $anyMetaFilled = $metaEdit -and @($metaFields | Where-Object { [string]$metaEdit.$_ }).Count -gt 0
    if (-not $metadata -and $anyMetaFilled -and $Defaults) { $metadata = $Defaults.PSObject.Copy() }
    if ($metadata -and $metaEdit) {
        foreach ($f in $metaFields) {
            if ($metadata.PSObject.Properties.Name -contains $f) { $metadata.$f = [string]$metaEdit.$f }
            else { $metadata | Add-Member -NotePropertyName $f -NotePropertyValue ([string]$metaEdit.$f) }
        }
        if (-not $metadata.appVersion) { $metadata.appVersion = $null }
    }
    return [pscustomobject]@{
        appId            = ([string]$Edit.appId).Trim()
        appName          = (([string]$Edit.appName).Trim() -replace '\s+', ' ')
        wingetId         = ([string]$Edit.wingetId).Trim()
        intuneAppType    = $(if ($Existing) { [string]$Existing.intuneAppType } else { '' })
        intuneAppVersion = $(if ($Existing) { [string]$Existing.intuneAppVersion } else { '' })
        packagePath      = $(if ($Existing) { [string]$Existing.packagePath } else { '' })
        requiredFor      = & $groups $Edit.requiredFor
        availableFor     = & $groups $Edit.availableFor
        uninstallFor     = & $groups $Edit.uninstallFor
        excludeFor       = & $groups $Edit.excludeFor
        metadata         = $metadata
    }
}

function Global:Test-WebAppEdit {
    <#
      Pure: why an edited app can't be saved ('' when it can): a name, unique by name and by file name, a GUID or no
      App ID, a Winget ID winget would accept.
    #>
    param($Record, [string]$OriginalName, [object[]]$Others)
    if (-not $Record.appName) { return 'The app needs a name.' }
    if ($Record.appId -and $Record.appId -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') { return "The App ID must be a GUID (or empty for an app that isn't in Intune yet)." }
    if (-not (Test-WebWingetId $Record.wingetId)) { return "'$($Record.wingetId)' isn't a Winget ID winget accepts (letters, digits, . _ + -)." }
    $key = $Record.appName.ToLowerInvariant()
    $file = Get-SafeFileNameForApp -Name $Record.appName
    foreach ($o in @($Others)) {
        if (-not $o -or $o.appName -eq $OriginalName) { continue }
        if (($o.appName.Trim() -replace '\s+', ' ').ToLowerInvariant() -eq $key) { return "Another app is already called '$($o.appName)'." }
        if ((Get-SafeFileNameForApp -Name $o.appName) -eq $file) { return "'$($Record.appName)' and '$($o.appName)' would be saved to the same file ($file.json). Choose a different name." }
        if ($Record.appId -and $o.appId -eq $Record.appId) { return "'$($o.appName)' already has App ID $($Record.appId)." }
    }
    return ''
}

function Global:Backup-WebAppFile {
    # A copy of one app's file in the Backups folder before it's overwritten or removed.
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) { return }
    try {
        $dir = Join-Path (Get-AppFolder -Kind Backups -Create) ("app-edit_" + (Get-Date -Format 'yyyy-MM-dd'))
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Copy-Item -LiteralPath $FilePath -Destination (Join-Path $dir ((Get-Date -Format 'HHmmss') + '_' + (Split-Path $FilePath -Leaf))) -Force
    }
    catch { }
}

function Global:Save-WebApp {
    param($Data)
    $catalog = Read-WebCatalogRecords
    $original = [string]$Data.originalName
    $existing = if ($original) { $catalog.Apps | Where-Object { $_.appName -eq $original } | Select-Object -First 1 } else { $null }
    if ($original -and -not $existing) { return @{ ok = $false; error = "'$original' is no longer in the catalog (renamed or removed elsewhere?). Reload and try again." } }
    if ($existing -and $Data.version -and [string]$Data.version -ne (Get-WebAppFileVersion $existing.appName)) {
        return @{ ok = $false; stale = $true; error = "'$original' was changed since you opened it (a deploy, a pull or a fix saved it). Nothing was saved - close the editor, open the app again and redo your changes." }
    }
    $edit = $Data.app
    $defaults = $null
    if (-not ($existing -and $existing.metadata)) {
        $name = ([string]$edit.appName).Trim()
        $wid = ([string]$edit.wingetId).Trim()
        try { $defaults = Get-DefaultAppMetadata -AppName $name -WingetId $wid -Uncommon (-not $wid) } catch { $defaults = $null }
    }
    $record = Merge-WebAppEdit -Existing $existing -Edit $edit -Defaults $defaults
    $problem = Test-WebAppEdit -Record $record -OriginalName $original -Others @($catalog.Apps)
    if ($problem) { return @{ ok = $false; error = $problem } }
    foreach ($urlField in 'informationUrl', 'privacyUrl') {
        $u = [string]$edit.metadata.$urlField
        if ($u -and $u -notmatch '^https?://\S+$') { return @{ ok = $false; error = "The $(if ($urlField -eq 'informationUrl') { 'information' } else { 'privacy' }) URL must start with http:// or https://." } }
    }
    if ($edit.deploy) {
        $deploy = ConvertTo-WebDeploySettings -Form $edit.deploy -AppNames @($catalog.Apps | ForEach-Object { $_.appName }) -Self $record.appName
        if ($deploy.Error) { return @{ ok = $false; error = $deploy.Error } }
        # Deploy settings make an app's metadata exist, with the defaults underneath.
        if (-not $record.metadata) {
            $base = if ($defaults) { $defaults } else { try { Get-DefaultAppMetadata -AppName $record.appName -WingetId $record.wingetId -Uncommon (-not $record.wingetId) } catch { $null } }
            if ($base) { $record.metadata = $base.PSObject.Copy() }
        }
        if ($record.metadata) {
            foreach ($k in $deploy.Values.Keys) {
                if ($record.metadata.PSObject.Properties.Name -contains $k) { $record.metadata.$k = $deploy.Values[$k] }
                else { $record.metadata | Add-Member -NotePropertyName $k -NotePropertyValue $deploy.Values[$k] }
            }
            $record.metadata.installContext = $(if ([string]$edit.deploy.installContext -eq 'User') { 'User' } else { 'System' })
        }
    }

    $folder = Get-AppFolder -Kind Catalog -Create
    $newFile = Join-Path $folder ((Get-SafeFileNameForApp -Name $record.appName) + '.json')
    $oldFile = if ($existing) { Join-Path $folder ((Get-SafeFileNameForApp -Name $existing.appName) + '.json') } else { $null }
    Backup-WebAppFile $newFile
    try {
        [System.IO.File]::WriteAllText($newFile, (ConvertTo-SingleAppJson -App $record), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { return @{ ok = $false; error = "Couldn't write $newFile`: $($_.Exception.Message)" } }
    if ($oldFile -and $oldFile -ne $newFile -and (Test-Path -LiteralPath $oldFile)) {
        Backup-WebAppFile $oldFile
        Remove-Item -LiteralPath $oldFile -Force -ErrorAction SilentlyContinue
    }
    Write-Log "[OK] $(if ($existing) { 'Saved' } else { 'Added' }): $($record.appName)$(if ($existing -and $existing.appName -ne $record.appName) { " (was $($existing.appName))" })."
    return @{ ok = $true; name = $record.appName }
}

function Global:Remove-WebApp {
    # Removes an app from the catalog only - nothing in Intune changes.
    param($Data)
    $catalog = Read-WebCatalogRecords
    $name = [string]$Data.name
    $app = $catalog.Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $app) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    $file = Join-Path (Get-AppFolder -Kind Catalog) ((Get-SafeFileNameForApp -Name $app.appName) + '.json')
    Backup-WebAppFile $file
    try { Remove-Item -LiteralPath $file -Force -ErrorAction Stop }
    catch { return @{ ok = $false; error = "Couldn't remove $file`: $($_.Exception.Message)" } }
    Write-Log "[OK] Removed from the catalog: $name (a copy is in the Backups folder; nothing in Intune changed)."
    return @{ ok = $true }
}

function Global:Invoke-WebApi {
    # The route table. $Data is the token-checked request body.
    param([string]$Path, $Data)
    switch ($Path) {
        '/api/state'            { return (Get-WebState) }
        '/api/catalog'          { return (Get-WebCatalog) }
        '/api/settings-save'    { return (Save-WebSettings $Data) }
        '/api/cert-status'      { return (Get-WebCertStatus $Data) }
        '/api/certs-local'      { return (Get-WebLocalCertificates) }
        '/api/cert-new'         { return (New-WebCertificate $Data) }
        '/api/test-connection'  { return (Invoke-WebTestConnection $Data) }
        '/api/job-start'        { return (Start-WebCertJob $Data) }
        '/api/job-poll'         { return (Get-WebJobPoll $Data) }
        '/api/permission-choice' { return (Get-WebPermissionChoice) }
        '/api/open'             { return (Open-WebTarget $Data) }
        '/api/log'              { return (Get-WebLog $Data) }
        '/api/app-get'          { return (Get-WebApp $Data) }
        '/api/app-save'         { return (Invoke-WithCatalogLock { Save-WebApp $Data }) }
        '/api/app-remove'       { return (Invoke-WithCatalogLock { Remove-WebApp $Data }) }
        '/api/deploy-plan'      { return (Get-WebDeployPlan $Data) }
        '/api/deploy-start'     { return (Start-WebDeploy $Data) }
        '/api/push-start'       { return (Start-WebPushGroups $Data) }
        '/api/checks-run'       { return (Invoke-WebChecks $Data) }
        '/api/checks-details'   { return (Start-WebCheckDetails $Data) }
        '/api/checks-assign'    { return (Start-WebCheckAssign $Data) }
        '/api/checks-winget'    { return (Invoke-WebCheckWinget $Data) }
        '/api/winget-search'    { return (Find-WebWinget $Data) }
        '/api/add-from-intune'  { return (Start-WebAddFromIntune $Data) }
        '/api/batch-edit'       { return (Invoke-WithCatalogLock { Invoke-WebBatchEdit $Data }) }
        '/api/batch-groups'     { return (Invoke-WithCatalogLock { Invoke-WebBatchGroups $Data }) }
        '/api/diagnostics'      { return (Get-WebDiagnostics) }
        '/api/prereqs'          { return (Get-WebPrerequisites) }
        '/api/prereq-install'   { return (Start-WebPrerequisiteInstall $Data) }
        '/api/certs-all'        { return (Get-WebAllLocalCertificates) }
        '/api/cert-delete-local' { return (Remove-WebLocalCertificate $Data) }
        '/api/packaging'        { return (Get-WebPackaging) }
        '/api/packaging-setup'  { return (Invoke-WebPackagingSetup $Data) }
        '/api/package-start'    { return (Start-WebPackage $Data) }
        '/api/pull-start'       { return (Start-WebPull $Data) }
        '/api/pull-apply'       { return (Invoke-WithCatalogLock { Invoke-WebPullApply $Data }) }
        '/api/prefs'            { return (Get-WebPrefs) }
        '/api/prefs-save'       { return (Save-WebPrefs $Data) }
        '/api/delete-intune'    { return (Start-WebDeleteFromIntune $Data) }
        '/api/clear-appid'      { return (Invoke-WithCatalogLock { Clear-WebAppId $Data }) }
        '/api/install-status'   { return (Get-WebInstallStatus $Data) }
        '/api/checks-fix'       { return (Invoke-WithCatalogLock { Invoke-WebCheckFix $Data }) }
        '/api/scripts'          { return (Get-WebScripts) }
        '/api/script-get'       { return (Get-WebScriptDetail $Data) }
        '/api/script-save'      { return (Save-WebScript $Data) }
        '/api/script-delete'    { return (Remove-WebScript $Data) }
        '/api/script-runstatus' { return (Get-WebScriptRunStatus $Data) }
        '/api/scripts-save-local' { return (Save-WebScriptCopies) }
        '/api/groups'           { return (Get-WebGroups) }
        '/api/group-get'        { return (Get-WebGroupDetail $Data) }
        '/api/directory-search' { return (Find-WebDirectory $Data) }
        '/api/group-job'        { return (Start-WebGroupJob $Data) }
        default                 { return @{ ok = $false; error = 'unknown' } }
    }
}
