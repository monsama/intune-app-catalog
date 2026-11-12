# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
  What the web interface's /api/ routes do. Each takes the request's JSON
  body (already token-checked) and returns a hashtable that is sent back
  as JSON: always "ok", and "error" when it isn't.

  This file has the route table (Invoke-WebApi) and what every page
  shares: reading the catalog, the catalog lock, step jobs and their
  completion, the Activity log. The pages: WebEditor.ps1, WebDeploy.ps1,
  WebSettings.ps1, WebChecks.ps1, WebBatch.ps1, WebBulk.ps1, WebTenant.ps1, WebGroups.ps1,
  WebScripts.ps1, WebSetup.ps1; Graph reads go through WebGraph.ps1.
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
        # Graph answers come from a file (INTUNE_CATALOG_TEST_GRAPH) - the page says so.
        testMode    = [bool]$Global:App.TestGraph
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
                wingetVersion = [string]$(if ($Global:App.WingetLatest -and $apps[$i].wingetId) { $Global:App.WingetLatest[([string]$apps[$i].wingetId).ToLowerInvariant()] })
                newerOnWinget = [bool]($Global:App.WingetLatest -and $apps[$i].wingetId -and $apps[$i].metadata -and (Compare-AppVersionText ([string]$apps[$i].metadata.appVersion) ([string]$Global:App.WingetLatest[([string]$apps[$i].wingetId).ToLowerInvariant()])) -eq 1)
                hasIcon      = [bool]($apps[$i].icon -and $apps[$i].icon.value)
                iconTag      = $(if ($apps[$i].icon -and $apps[$i].icon.value) { "$($apps[$i].icon.value.Length):$($apps[$i].icon.value.Substring([Math]::Max(0, $apps[$i].icon.value.Length - 12)))" } else { '' })
                groups       = @(@($apps[$i].requiredFor) + @($apps[$i].availableFor) + @($apps[$i].uninstallFor) + @($apps[$i].excludeFor) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
                status       = [string]$row.Status
                audit        = [string]$row.IntuneAudit
                hasAppId     = [bool]$row.HasAppId
                packageMissing = [bool]$row.PackageMissing
            })
        }
    }
    return @{ ok = $true; path = $path; exists = (Test-Path -LiteralPath $path); apps = $rows.ToArray(); failed = @($failed) }
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
        Cleanup = @($scriptPath, $helperPath, $configPath); Mode = $Kind; Done = $false; After = $After; LastPoll = Get-Date; Started = Get-Date
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

function Global:Update-WebCatalogApp {
    # Changes one app's saved file: reads it, lets -Change edit the record, writes it back (with a backup).
    param([string]$Name, [scriptblock]$Change, $Undo = $null)
    $catalog = Read-WebCatalogRecords
    $app = $catalog.Apps | Where-Object { $_.appName -eq $Name } | Select-Object -First 1
    if (-not $app) { throw "'$Name' is no longer in the catalog." }
    & $Change $app
    Write-WebAppFile -App $app -Undo $Undo
    return $app
}

function Global:Get-WebRunningJobs {
    # Steps the server knows about that haven't been completed yet, oldest first - for a page opened while they run.
    $list = foreach ($id in @($Global:App.WebJobs.Keys)) {
        $j = $Global:App.WebJobs[$id]
        if ($j) { [ordered]@{ job = $id; kind = [string]$j.Mode; started = $(if ($j.Started) { ([datetime]$j.Started).ToString('o') } else { '' }) } }
    }
    return @{ ok = $true; jobs = @($list | Sort-Object { $_.started }) }
}

function Global:Complete-WebOrphanJobs {
    <#
      Steps that ended while no page was polling them (the page was
      reloaded or closed): completed here after -GraceSeconds, so a
      deploy's App ID still reaches the catalog. Called from the server's
      main loop.
    #>
    param([int]$GraceSeconds = 15)
    foreach ($id in @($Global:App.WebJobs.Keys)) {
        $job = $Global:App.WebJobs[$id]
        if (-not $job -or -not $job.Process.HasExited) { continue }
        if (((Get-Date) - [datetime]$job.LastPoll).TotalSeconds -lt $GraceSeconds) { continue }
        try {
            $r = Get-WebJobPoll ([pscustomobject]@{ job = $id; offset = [int64]::MaxValue })
            if ($r.after -and $r.after.pushGroups) { Write-Log "[WARN] $($job.Mode): finished while the page wasn't watching, so its groups weren't pushed - use Push groups." }
        }
        catch { Write-Log "[WARN] Couldn't finish $($job.Mode): $($_.Exception.Message)" }
    }
}

function Global:Complete-WebJobsAtExit {
    <#
      When the app stops while steps are running: waits for each (Ctrl+C
      stops waiting) and completes it like the page's last poll does -
      App ID saved, groups renamed, results read. What the page would have
      started next (pushing groups after a deploy) is logged instead.
    #>
    param([int]$TimeoutMinutes = 60)
    $ids = @($Global:App.WebJobs.Keys)
    if ($ids.Count -eq 0) { return }
    Write-Host "  Waiting for $($ids.Count) running step(s) to finish before stopping (Ctrl+C stops without waiting)..." -ForegroundColor Yellow
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    foreach ($id in $ids) {
        $job = $Global:App.WebJobs[$id]
        if (-not $job) { continue }
        while (-not $job.Process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (-not $job.Process.HasExited) { Write-Log "[WARN] Stopped without waiting for: $($job.Mode)."; continue }
        # Past the end of the log: nothing left to read, so this poll completes it.
        $r = Get-WebJobPoll ([pscustomobject]@{ job = $id; offset = [int64]::MaxValue })
        if ($r.after -and $r.after.pushGroups) { Write-Log "[WARN] $($job.Mode): the app window was closed, so its groups weren't pushed - use Push groups." }
        Write-Host "  Finished: $($job.Mode)" -ForegroundColor DarkGray
    }
}

function Global:Complete-WebJob {
    <#
      After a step succeeded: what follows on from it.
      Deploy - the App ID (and the defaults it was deployed with, for an app
      that had none) saved to the catalog, and whether groups should follow.
    #>
    param([hashtable]$After, $Result, [string]$LogPath)
    # A deploy or a delete changes which apps the tenant has - the Apps list reads them again.
    if ($After.Kind -in 'deploy', 'deleted', 'addtocatalog') { $Global:App.IntuneAppsCache = $null }
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

function Global:Get-WebJobPoll {
    # New output since -offset, and the result once the step has ended.
    param($Data)
    $id = [string]$Data.job
    if (-not $id -or -not $Global:App.WebJobs.ContainsKey($id)) { return @{ ok = $false; error = 'No such job.' } }
    $job = $Global:App.WebJobs[$id]
    $job.LastPoll = Get-Date
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
    $response = [ordered]@{ ok = $true; text = (Protect-LogText $text); offset = $offset; done = $false }
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

function Global:Open-WebFolder {
    <#
      Shows a folder in Explorer, in front. Started by this server - a
      background process - Explorer's window would otherwise open behind the
      app window (Windows doesn't let a background process take the
      foreground), and the button looks like it did nothing. A window already
      showing the folder is reused. Returns @{ ok; error }.
    #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return @{ ok = $false; error = "The folder doesn't exist: $Path" } }
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath.TrimEnd('\')
    if (-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')) { return @{ ok = $false; error = "Opening folders needs Windows Explorer. The folder is $full" } }
    try {
        if (-not ('Iac.Foreground' -as [type])) {
            Add-Type -Namespace 'Iac' -Name 'Foreground' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
[DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
'@
        }
        $shell = New-Object -ComObject Shell.Application
        $find = {
            foreach ($w in @($shell.Windows())) {
                try { if ($w.Document -and $w.Document.Folder -and ([string]$w.Document.Folder.Self.Path).TrimEnd('\') -ieq $full) { return $w } } catch { }
            }
            return $null
        }
        $window = & $find
        if (-not $window) {
            Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$full`""
            for ($i = 0; $i -lt 30 -and -not $window; $i++) { Start-Sleep -Milliseconds 100; $window = & $find }
        }
        if ($window) {
            $hwnd = [IntPtr]([int64]$window.HWND)
            if ([Iac.Foreground]::IsIconic($hwnd)) { [void][Iac.Foreground]::ShowWindow($hwnd, 9) }   # SW_RESTORE
            # A key press (Alt, down and up) is what lets a background process hand the foreground over.
            [Iac.Foreground]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [Iac.Foreground]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
            [void][Iac.Foreground]::SetForegroundWindow($hwnd)
        }
        return @{ ok = $true; path = $full }
    }
    catch {
        # Explorer can still open it the plain way, even if bringing it forward failed.
        try { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$full`""; return @{ ok = $true; path = $full } }
        catch { return @{ ok = $false; error = "Couldn't open $full`: $($_.Exception.Message)" } }
    }
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
        'catalog-folder' { return (Open-WebFolder (Get-AppFolder -Kind Catalog -Create)) }
        'entra-home' { Start-Process 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade/quickStartType~/null/sourceType/Microsoft_AAD_IAM' }
        'coffee' { Start-Process 'https://buymeacoffee.com/monsama' }
        'scripts-folder' { return (Open-WebFolder (Get-AppFolder -Kind Scripts -Create)) }
        'certificates-folder' {
            $folder = Join-Path $Global:App.RootPath 'data\certificates'
            if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
            return (Open-WebFolder $folder)
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
        '/api/connection-status' { return (Get-WebConnectionStatus) }
        '/api/job-start'        { return (Start-WebCertJob $Data) }
        '/api/job-poll'         { return (Get-WebJobPoll $Data) }
        '/api/jobs'             { return (Get-WebRunningJobs) }
        '/api/permission-choice' { return (Get-WebPermissionChoice) }
        '/api/open'             { return (Open-WebTarget $Data) }
        '/api/log'              { return (Get-WebLog $Data) }
        '/api/app-get'          { return (Get-WebApp $Data) }
        '/api/app-save'         { return (Invoke-WithCatalogLock { Save-WebApp $Data }) }
        '/api/app-remove'       { return (Invoke-WithCatalogLock { Remove-WebApp $Data }) }
        '/api/app-backups'      { return (Get-WebAppBackups $Data) }
        '/api/app-restore'      { return (Invoke-WithCatalogLock { Restore-WebAppBackup $Data }) }
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
        '/api/replace-group'    { return (Invoke-WithCatalogLock { Invoke-WebReplaceGroup $Data }) }
        '/api/undo-info'        { return (Get-WebUndoInfo) }
        '/api/winget-take-version' { return (Invoke-WithCatalogLock { Set-WebWingetVersions $Data }) }
        '/api/tenant-setup'     { return (Get-WebTenantSetup) }
        '/api/install-overview' { return (Get-WebInstallOverview) }
        '/api/app-icons'        { return (Get-WebAppIcons $Data) }
        '/api/app-icon-intune'  { return (Get-WebIntuneIcon $Data) }
        '/api/app-compare'      { return (Get-WebAppVersionCompare $Data) }
        '/api/undo-last'        { return (Invoke-WithCatalogLock { Invoke-WebUndo }) }
        '/api/csv-export'       { return (Export-WebCatalogCsv) }
        '/api/csv-import'       { return $(if ($Data.preview) { Import-WebCatalogCsv $Data } else { Invoke-WithCatalogLock { Import-WebCatalogCsv $Data } }) }
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
        '/api/clear-appids'     { return (Invoke-WithCatalogLock { Clear-WebAppIds $Data }) }
        '/api/intune-apps'      { return (Get-WebIntuneApps $Data) }
        '/api/install-status'   { return (Get-WebInstallStatus $Data) }
        '/api/checks-fix'       { return (Invoke-WithCatalogLock { Invoke-WebCheckFix $Data }) }
        '/api/scripts'          { return (Get-WebScripts) }
        '/api/script-get'       { return (Get-WebScriptDetail $Data) }
        '/api/script-save'      { return (Save-WebScript $Data) }
        '/api/script-delete'    { return (Remove-WebScript $Data) }
        '/api/script-runstatus' { return (Get-WebScriptRunStatus $Data) }
        '/api/scripts-save-local' { return (Save-WebScriptCopies) }
        '/api/groups'           { return (Get-WebGroups) }
        '/api/groups-status'    { return (Get-WebGroupsStatus) }
        '/api/group-get'        { return (Get-WebGroupDetail $Data) }
        '/api/directory-search' { return (Find-WebDirectory $Data) }
        '/api/group-job'        { return (Start-WebGroupJob $Data) }
        default                 { return @{ ok = $false; error = 'unknown' } }
    }
}
