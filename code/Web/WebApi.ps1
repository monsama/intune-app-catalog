# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
  What the web interface's /api/ routes do. Each takes the request's JSON
  body (already token-checked) and returns a hashtable that is sent back
  as JSON: always "ok", and "error" when it isn't.

  Everything here reuses the app's own functions - catalog reading, the
  list row, the certificate status, the permission report, the setup
  checklist, the step runner - so the web interface and the classic window
  give the same answers.
#>

function Global:Get-WebStatusLevel {
    # Get-CertificateStatusText answers with a color; the page wants a word.
    param($Color)
    $name = if ($Color) { [string]$Color.Name } else { '' }
    switch ($name) {
        'Firebrick' { 'error' }
        'DarkOrange' { 'warn' }
        'SeaGreen' { 'ok' }
        default { 'info' }
    }
}

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
        cert        = @{ text = [string]$cert.Text; level = (Get-WebStatusLevel $cert.Color) }
        configured  = [bool](Test-GraphCredentialsConfigured -Quiet)
        moduleOk    = [bool](Test-GraphModuleHere)
    }
}

function Global:Get-WebCatalog {
    <#
      The catalog as list rows, read from disk on every call - the classic
      window may be open on the same folder, and a copy kept here would go
      stale the moment it saved something.
    #>
    $path = Get-AppFolder -Kind Catalog
    $rows = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $path) {
        $files = @(Get-ChildItem -LiteralPath $path -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
        $apps = New-Object System.Collections.Generic.List[object]
        foreach ($file in $files) {
            try { $apps.Add((ConvertTo-AppRecord (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json))) }
            catch { $failed.Add($file.Name) }
        }
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
    return @{ ok = $true; path = $path; exists = (Test-Path -LiteralPath $path); apps = $rows.ToArray(); failed = $failed.ToArray() }
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
    return @{ ok = $true; text = [string]$cert.Text; level = (Get-WebStatusLevel $cert.Color) }
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
      A new self-signed certificate in CurrentUser\My - the same settings as
      the classic window's "Generate certificate..." (non-exportable key) -
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
      The sign-in is dropped again afterwards, as the classic window does,
      so a token from before a consent is never reused.
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
      Check / Upload / Delete certificate and Add permissions: the same
      CertUpload step the classic window runs, through the step runner, with
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
    [System.IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))

    $scriptPath = Join-Path $Global:App.RootPath ".intunepkg_embedded_certupload_$tag.ps1"
    $helperPath = Join-Path $Global:App.RootPath ".intunepkg_graphlog_$tag.ps1"
    $logPath = Join-Path $env:TEMP "intunepkg_$tag.log"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($scriptPath, $Global:App.EmbeddedCertUploadScript, $utf8)
    [System.IO.File]::WriteAllText($helperPath, ((Get-GraphLogScriptHelpers) + "`n`n" + (Get-AssignmentScriptHelpers)), $utf8)
    [System.IO.File]::WriteAllText($logPath, '')
    try {
        $psi = New-AppStepStartInfo -Spec @{ Script = $scriptPath; Parameters = @{ ConfigPath = $configPath }; GraphHelper = $helperPath; LogFile = $logPath }
        Set-WindowsPowerShellEnvironment -StartInfo $psi
        $psi.EnvironmentVariables['INTUNEPACKAGER_GRAPH_LOG'] = 'summary'
        # The interactive sign-in (WAM) needs a window handle; minimized is enough.
        $psi.CreateNoWindow = $false
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
        $psi.WorkingDirectory = $Global:App.RootPath
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        Remove-Item -LiteralPath $scriptPath, $helperPath, $logPath, $configPath -Force -ErrorAction SilentlyContinue
        return @{ ok = $false; error = "Couldn't start the step: $($_.Exception.Message)" }
    }
    $Global:App.WebJobs[$tag] = @{
        Process = $proc; Log = $logPath; Result = $resultPath
        Cleanup = @($scriptPath, $helperPath, $configPath); Mode = $mode; Done = $false
    }
    Write-Log "[INFO] Started: $mode (sign in in the window that opens)."
    return @{ ok = $true; job = $tag }
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
        if (Test-Path -LiteralPath $job.Result) {
            try { $response.result = Get-Content -LiteralPath $job.Result -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        }
        # Cleaned up only once the page has read everything (an empty read
        # after the exit); until then the log stays for the next poll.
        if (-not $text) {
            Remove-Item -LiteralPath (@($job.Cleanup) + $job.Log + $job.Result) -Force -ErrorAction SilentlyContinue
            [void]$Global:App.WebJobs.Remove($id)
            Write-Log "$(if ($response.result -and $response.result.success) { '[OK]' } else { '[WARN]' }) Finished: $($job.Mode)."
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
      page, the catalog or certificates folder, or the classic window. A
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
        'certificates-folder' {
            $folder = Join-Path $Global:App.RootPath 'data\certificates'
            if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
            Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$folder`""
        }
        'classic' {
            $exe = (Get-Process -Id $PID).Path
            $entry = Join-Path $Global:App.RootPath 'IntuneDeployment.ps1'
            Start-Process -FilePath $exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$entry`" -Classic" -WorkingDirectory $Global:App.RootPath
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
        default                 { return @{ ok = $false; error = 'unknown' } }
    }
}
