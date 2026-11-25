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
  WebSettings.ps1, WebChecks.ps1, WebBatch.ps1, WebBulk.ps1, WebTenant.ps1, WebReleases.ps1, WebAutomation.ps1, WebAdd.ps1, WebConvenience.ps1, WebGroups.ps1,
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
        $busyApps = Get-WebBusyApps
        $sentStamps = Read-WebSentStamps
        for ($i = 0; $i -lt $apps.Count; $i++) {
            $row = Get-CatalogRow -App $apps[$i] -Index $i -PackageIndex $index
            # winget's newest version: of its own ID, or (an own package, 2.36.0) of the one it watches.
            $wk = [string]$(if ($apps[$i].wingetId) { $apps[$i].wingetId } else { $apps[$i].watchWinget })
            # Newer than what it has: its App version - or, watching winget, the installer already in its folder (2.38.0:
            # one fetched but not yet released was listed again and again).
            $ahead = [string]$(if ($apps[$i].metadata) { $apps[$i].metadata.appVersion })
            if (-not $apps[$i].wingetId -and $apps[$i].watchWinget -and $Global:App.WingetLatest -and $Global:App.WingetLatest[$wk.ToLowerInvariant()]) {
                try { $fi = Get-WebInstallerInfo $apps[$i].appName -SetupFile ([string]$apps[$i].setupFile); if ($fi.version -and (Compare-AppVersionText $ahead $fi.version) -eq 1) { $ahead = [string]$fi.version } } catch { }
            }
            # The pilot release, found once (a plain loop - a pipeline per field is slow for 500 apps on Windows PowerShell).
            $pr = $null; foreach ($r in @($apps[$i].releases)) { if ($r -and $r.state -eq 'pilot') { $pr = $r; break } }
            $rows.Add([ordered]@{
                name         = [string]$row.AppName
                wingetId     = [string]$row.WingetId
                appId        = [string]$apps[$i].appId
                type         = [string]$row.Type
                # Someone else (another window, another admin) is changing it right now.
                busy         = [string]$busyApps[(Get-SafeFileNameForApp -Name $apps[$i].appName)]
                # What changed in the catalog since it was last sent (settings / groups) - only known once it was sent with 2.26.4 or later.
                unsent       = $(if ($apps[$i].appId) { Get-WebUnsent -App $apps[$i] -Sent $sentStamps } else { '' })
                # The App version (what deploys and releases use) - Intune's own reported version apart.
                version      = [string]$(if ($apps[$i].metadata) { $apps[$i].metadata.appVersion })
                intuneVersion = [string]$row.Version
                # Own package without what Deploy needs (it refuses those): the stage says Draft, not Ready.
                hasDetection = [bool]($apps[$i].wingetId -or ($apps[$i].metadata -and $apps[$i].metadata.detectionRule))
                hasInstall   = [bool]($apps[$i].wingetId -or ($apps[$i].metadata -and ([string]$apps[$i].metadata.installCommand).Trim()))
                customConfig = [string]$row.CustomConfig
                required     = [int]$row.Required
                available    = [int]$row.Available
                uninstall    = [int]$row.Uninstall
                wingetVersion = [string]$(if ($Global:App.WingetLatest -and $wk) { $Global:App.WingetLatest[$wk.ToLowerInvariant()] })
                newerOnWinget = [bool]($Global:App.WingetLatest -and $wk -and (Compare-AppVersionText $ahead ([string]$Global:App.WingetLatest[$wk.ToLowerInvariant()])) -eq 1)
                watchWinget  = [string]$apps[$i].watchWinget
                managed      = [bool]$apps[$i].managedUpdates
                updatesItself = [bool](Test-AppUpdatesItself $apps[$i])
                # Company Portal, Microsoft 365 Apps, Store/other Intune types: nothing to package.
                # 2.38.20: also once it is in Intune (linked) - Company Portal linked without its Store ID showed as "own installer".
                msHint       = [string]$(if (-not $apps[$i].wingetId) { Get-NonPackageAppHint $apps[$i] })
                # Microsoft 365 Apps (2.38.21): its settings, and them in one line.
                office       = $apps[$i].office
                officeText   = [string]$(if ($apps[$i].office) { Get-OfficeSettingsSummary $apps[$i].office })
                previousVersions = @(Get-WebPreviousReleases $apps[$i] | ForEach-Object { [string]$_.version })
                rolledBackVersions = @(@($apps[$i].releases) | Where-Object { $_ -and $_.state -eq 'rolledback' } | ForEach-Object { [string]$_.version })
                releaseIds   = @(@($apps[$i].releases) | Where-Object { $_ -and $_.appId } | ForEach-Object { ([string]$_.appId).ToLowerInvariant() })
                retiringSince = [string]$apps[$i].retiringSince
                lobToRetire  = [string]$apps[$i].lobToRetire
                setupFile    = [string]$apps[$i].setupFile
                pilotVersion = [string]$(if ($pr) { $pr.version })
                # Which release ring the pilot release is in (0 = pilot), and how many there are - the next step is the next ring, not everyone.
                pilotRing    = [int]$(if ($pr) { $pr.ring })
                pilotFast    = [bool]$(if ($pr) { $pr.fastTrack })
                hasIcon      = [bool]($apps[$i].icon -and $apps[$i].icon.value)
                iconTag      = $(if ($apps[$i].icon -and $apps[$i].icon.value) { "$($apps[$i].icon.value.Length):$($apps[$i].icon.value.Substring([Math]::Max(0, $apps[$i].icon.value.Length - 12)))" } else { '' })
                groups       = @(@($apps[$i].requiredFor) + @($apps[$i].availableFor) + @($apps[$i].uninstallFor) + @($apps[$i].excludeFor) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
                # Per role too (2.38.3): Remove groups offers what the selected apps have in each - it found nothing without them.
                # As read (already clean strings): no pipeline per row - the list of 500 apps is timed on Windows PowerShell 5.1.
                requiredFor  = @($apps[$i].requiredFor)
                availableFor = @($apps[$i].availableFor)
                uninstallFor = @($apps[$i].uninstallFor)
                excludeFor   = @($apps[$i].excludeFor)
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
        [string]$Exe = '',
        # The apps a step changes in Intune - its success goes into their change history (-After's AppName when not given).
        [string[]]$Apps = @(),
        # The app this step holds (Enter-WebAppBusy) - let go when the step ends, whatever its result.
        [string]$BusyApp = '')
    $tag = [guid]::NewGuid().ToString('N')
    $configPath = Join-Path $env:TEMP ".intunepkg_$($Name)_config_$tag.json"
    # The server version (the container): the app's own folder is read-only - the step files go on the data volume.
    # On a PC (2.38.16): this user's own TEMP, not the app folder - a folder others can write to (one made right under
    # C:\ is) would let them swap the script between writing and running it, and it runs with the Intune certificate.
    $stepDir = Join-Path $env:TEMP 'IntuneAppCatalog-steps'
    if (-not (Test-WebServerMode) -and -not (Test-Path -LiteralPath $stepDir)) { [void](New-Item -ItemType Directory -Path $stepDir -Force) }
    if (Test-WebServerMode) { $stepDir = Join-Path $Global:App.RootPath 'data\run'; if (-not (Test-Path -LiteralPath $stepDir)) { [void](New-Item -ItemType Directory -Path $stepDir -Force) } }
    $scriptPath = Join-Path $stepDir ".intunepkg_embedded_$($Name)_$tag.ps1"
    $helperPath = Join-Path $stepDir ".intunepkg_graphlog_$tag.ps1"
    $logPath = Join-Path $env:TEMP "intunepkg_$tag.log"
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    try {
        if ($ConfigJson) { [System.IO.File]::WriteAllText($configPath, $ConfigJson, $utf8) }
        [System.IO.File]::WriteAllText($scriptPath, $ScriptContent, $utf8)
        [System.IO.File]::WriteAllText($helperPath, ((Get-GraphLogScriptHelpers) + "`n`n" + (Get-AssignmentScriptHelpers) + "`n`n" + (Get-PackagingScriptHelpers)), $utf8)
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
        if ($BusyApp) { Exit-WebAppBusy $BusyApp }
        return @{ ok = $false; error = "Couldn't start the step: $($_.Exception.Message)" }
    }
    $Global:App.WebJobs[$tag] = @{
        Process = $proc; Log = $logPath; Result = $ResultPath
        Cleanup = @($scriptPath, $helperPath, $configPath); Mode = $Kind; Step = $Name; Done = $false; After = $After; LastPoll = Get-Date; Started = Get-Date
        HistoryApps = @($(if ($Apps.Count) { $Apps } elseif ($After.AppName -and $After.Kind -in 'deploy', 'deleted', 'release') { [string]$After.AppName }) | Where-Object { $_ })
        HistorySource = [string]$Global:WebChangeSource
        BusyApp = $BusyApp
    }
    # What a send sends, taken now (2.38.42): the "sent" record is made from it when it ends - from the file then, an
    # edit saved while it ran counted as sent and dropped out of Changes to send.
    if ($Name -in 'createapp', 'createstoreapp', 'createofficeapp', 'targetedassign', 'batchassign' -and $Kind -notmatch '^(Release|Promote|Advance|Withdraw|Retire|Finish|Delete|Roll|Assign .+ to pilot$|Give )') {
        try {
            $names = @($Global:App.WebJobs[$tag].HistoryApps)
            $snap = @{}
            foreach ($x in @((Read-WebCatalogRecords).Apps | Where-Object { $names -contains $_.appName })) { $snap[[string]$x.appName] = Get-WebAppSentValues $x }
            $Global:App.WebJobs[$tag].SentSnap = $snap
        }
        catch { }
    }
    Save-WebJobRecord -Id $tag
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
    $taken = $false; $file = $null
    try {
        $taken = [System.Threading.Monitor]::TryEnter($lock, 30000)
        if (-not $taken) { return @{ ok = $false; error = 'The catalog is busy with another change - try again in a moment.' } }
        # Across processes too: the nightly run, or another PC using the same catalog folder (a share).
        $file = Enter-CatalogFileLock
        if ($file -is [string]) { return @{ ok = $false; error = $file } }
        return (& $Action)
    }
    finally {
        if ($file -and $file -isnot [string]) { Exit-CatalogFileLock $file }
        if ($taken) { [System.Threading.Monitor]::Exit($lock) }
    }
}

function Global:Enter-CatalogFileLock {
    <#
      The catalog folder's lock file (.catalog-write.lock), open with no
      sharing while a change is written - so the nightly run and other PCs
      using the same folder wait their turn. Re-entrant on one thread (a
      change inside a change). Returns the held lock, $null when there's
      nothing to hold (no folder yet, or it can't be written - then the
      in-process lock alone guards), or a string: why it couldn't be had.
    #>
    $tid = [System.Threading.Thread]::CurrentThread.ManagedThreadId
    $held = $Global:App.CatalogFileLock
    if ($held -and $held.Thread -eq $tid) { $held.Depth++; return $held }
    $folder = Get-AppFolder -Kind Catalog
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return $null }
    $path = Join-Path $folder '.catalog-write.lock'
    $deadline = (Get-Date).AddSeconds(20)
    while ($true) {
        try {
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $note = [Text.Encoding]::UTF8.GetBytes("$env:COMPUTERNAME $env:USERNAME $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture))")
            $fs.SetLength(0); $fs.Write($note, 0, $note.Length); $fs.Flush()
            $one = @{ Stream = $fs; Thread = $tid; Depth = 1 }
            $Global:App.CatalogFileLock = $one
            return $one
        }
        catch [System.IO.IOException] {
            if ((Get-Date) -gt $deadline) {
                $who = try { [System.IO.File]::ReadAllText($path) } catch { 'another process' }
                return "The catalog is being changed elsewhere ($(if ($who) { $who.Trim() } else { 'another process' })) - try again in a moment."
            }
            Start-Sleep -Milliseconds 250
        }
        catch { return $null }
    }
}

function Global:Exit-CatalogFileLock {
    param($Held)
    if (-not $Held) { return }
    $Held.Depth--
    if ($Held.Depth -gt 0) { return }
    try { $Held.Stream.Dispose() } catch { }
    if ($Global:App.CatalogFileLock -eq $Held) { $Global:App.CatalogFileLock = $null }
}

function Global:Update-WebCatalogApp {
    <#
      Changes one app's saved file: reads it, lets -Change edit the record, writes it back (with a backup) - holding
      the catalog lock (2.38.0; it can be taken again, so a caller holding it already is fine). A long step (an upload
      copied into the packages folder, a call to Intune) then needn't hold it the whole time - only this write does.
    #>
    param([string]$Name, [scriptblock]$Change, $Undo = $null)
    # Tried three times when the catalog is busy (2.38.34): a deploy's or release's new App ID that wasn't saved meant a
    # second app in Intune on the next send.
    for ($try = 1; ; $try++) {
        $r = Invoke-WithCatalogLock { Update-WebCatalogAppHeld -Name $Name -Change $Change -Undo $Undo }.GetNewClosure()
        $busy = $r -is [hashtable] -and $r.ContainsKey('ok') -and -not $r.ok
        if (-not $busy -or $try -ge 3 -or [string]$r.error -notmatch 'busy|lock') { break }
        Start-Sleep -Seconds 2
    }
    if ($r -is [hashtable] -and $r.ContainsKey('ok') -and -not $r.ok) { throw [string]$r.error }
    return $r
}

function Global:Update-WebCatalogAppHeld {
    # Update-WebCatalogApp with the catalog lock held.
    param([string]$Name, [scriptblock]$Change, $Undo = $null)
    $catalog = Read-WebCatalogRecords
    $app = $catalog.Apps | Where-Object { $_.appName -eq $Name } | Select-Object -First 1
    if (-not $app) { throw "'$Name' is no longer in the catalog." }
    & $Change $app
    Write-WebAppFile -App $app -Undo $Undo
    return $app
}

function Global:Get-WebJobRecordFolder { return (Join-Path $env:TEMP 'IntuneAppCatalog-jobs') }

function Global:Save-WebJobRecord {
    <#
      A running step written down (2.38.42) - what to do with its result, where the result goes, which process runs
      it - so a restart of the app or the server (an update of the container) still finishes it: Resume-WebSavedJobs.
      Before, its App ID or release was lost with the server, and a retry created a second app in Intune.
    #>
    param([string]$Id)
    $j = $Global:App.WebJobs[$Id]
    if (-not $j) { return }
    try {
        $dir = Get-WebJobRecordFolder
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $procStart = try { $j.Process.StartTime.ToUniversalTime().Ticks } catch { 0 }
        $rec = [ordered]@{ id = $Id; mode = [string]$j.Mode; step = [string]$j.Step; result = [string]$j.Result; log = [string]$j.Log; cleanup = @($j.Cleanup)
            after = $j.After; historyApps = @($j.HistoryApps); historySource = [string]$j.HistorySource; busyApp = [string]$j.BusyApp
            pid = $(try { $j.Process.Id } catch { 0 }); procStart = $procStart
            # Whose it is: the app that started it finishes it itself while it runs (the nightly run beside the app).
            owner = $PID; ownerStart = $(try { (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks } catch { 0 }); started = ([datetime]$j.Started).ToString('o') }
        [System.IO.File]::WriteAllText((Join-Path $dir "$Id.json"), (ConvertTo-Json -InputObject $rec -Depth 12 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-Log "[WARN] Couldn't write down the running step $($j.Mode): $($_.Exception.Message)" }
}

function Global:Remove-WebJobRecord {
    param([string]$Id)
    Remove-Item -LiteralPath (Join-Path (Get-WebJobRecordFolder) "$Id.json") -Force -ErrorAction SilentlyContinue
}

function Global:ConvertTo-WebHashtable {
    # The top level of a JSON object as a hashtable (a job's -After read back) - what lies below stays as read.
    param($Object)
    $h = @{}
    if ($Object) { foreach ($p in $Object.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

function Global:Resume-WebSavedJobs {
    <#
      At start: the steps a previous run of the app (or the server) left running. One still running (the same
      process) is followed again; one that ended is finished now as its page would have - App ID saved, release
      recorded, what was sent noted. One whose result is gone is said in the log: check that app (Checks finds an
      app created without its App ID).
    #>
    $dir = Get-WebJobRecordFolder
    if (-not (Test-Path -LiteralPath $dir)) { return }
    # Only the records themselves (<id>.json) - nothing else in the folder is read or removed.
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^[0-9a-f]{32}\.json$' })) {
        $rec = $null
        try { $rec = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        if (-not $rec -or -not ([string]$rec.id -match '^[0-9a-f]{32}$') -or $Global:App.WebJobs.ContainsKey([string]$rec.id)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; continue }
        # Still owned by a running app (the nightly run, a second window): left to it.
        $ownerAlive = $false
        if ([int]$rec.owner -gt 0 -and [int]$rec.owner -ne $PID) { try { $ownerAlive = ((Get-Process -Id ([int]$rec.owner) -ErrorAction Stop).StartTime.ToUniversalTime().Ticks -eq [int64]$rec.ownerStart) } catch { } }
        if ($ownerAlive) { continue }
        $proc = $null
        if ([int]$rec.pid -gt 0) {
            try { $p = [System.Diagnostics.Process]::GetProcessById([int]$rec.pid); if ($p.StartTime.ToUniversalTime().Ticks -eq [int64]$rec.procStart) { $proc = $p } } catch { }
        }
        $resultThere = [string]$rec.result -and (Test-Path -LiteralPath ([string]$rec.result))
        if (-not $proc -and -not $resultThere) {
            Write-Log "[WARN] $($rec.mode) was running when the app last stopped, and its result is gone - check $(if (@($rec.historyApps).Count) { @($rec.historyApps) -join ', ' } else { 'the app' }) in Intune (Checks finds an app created without its App ID)."
            $left = @(@($rec.cleanup) + @([string]$rec.log) | Where-Object { $_ })
            if ($left.Count) { Remove-Item -LiteralPath $left -Force -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        # Ended: a stand-in that has exited (its result file says how it went). Still running: that process.
        if (-not $proc) { $proc = [pscustomobject]@{ HasExited = $true; ExitCode = 0; Id = 0 } }
        if (-not (Test-Path -LiteralPath ([string]$rec.log))) { try { [System.IO.File]::WriteAllText([string]$rec.log, '') } catch { } }
        # The app it held is held again until it is finished - the next step of a flow shares it.
        if ($rec.busyApp) { [void](Enter-WebAppBusy -Name ([string]$rec.busyApp) -What ([string]$rec.mode)) }
        $Global:App.WebJobs[[string]$rec.id] = @{
            Process = $proc; Log = [string]$rec.log; Result = [string]$rec.result; Cleanup = @($rec.cleanup); Mode = [string]$rec.mode; Step = [string]$rec.step
            Done = $false; After = (ConvertTo-WebHashtable $rec.after); LastPoll = (Get-Date).AddHours(-1); Started = $(try { [datetime]$rec.started } catch { Get-Date })
            HistoryApps = @($rec.historyApps); HistorySource = [string]$rec.historySource; BusyApp = [string]$rec.busyApp
        }
        Write-Log "[INFO] Picked up $($rec.mode), left $(if ($proc.HasExited) { 'finished' } else { 'running' }) by the last run of the app - it is finished here."
    }
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
    param([int]$GraceSeconds = 120)
    foreach ($id in @($Global:App.WebJobs.Keys)) {
        $job = $Global:App.WebJobs[$id]
        if (-not $job -or -not $job.Process.HasExited) { continue }
        if (((Get-Date) - [datetime]$job.LastPoll).TotalSeconds -lt $GraceSeconds) { continue }
        try {
            $r = Get-WebJobPoll ([pscustomobject]@{ job = $id; offset = [int64]::MaxValue })
            if ($r.after -and $r.after.pushGroups) { Write-Log "[WARN] $($job.Mode): finished while the page wasn't watching, so its groups weren't pushed - use Send groups." }
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
    param([int]$TimeoutMinutes = 60,
        # The nightly run: a step still running at the deadline is stopped (and its files removed), not left behind.
        [switch]$StopUnfinished)
    $ids = @($Global:App.WebJobs.Keys)
    if ($ids.Count -eq 0) { return }
    Write-Host "  Waiting for $(Format-Count ($ids.Count) 'running step') to finish before stopping (Ctrl+C stops without waiting)..." -ForegroundColor Yellow
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    foreach ($id in $ids) {
        $job = $Global:App.WebJobs[$id]
        if (-not $job) { continue }
        while (-not $job.Process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (-not $job.Process.HasExited) {
            if ($StopUnfinished) {
                try { $job.Process.Kill() } catch { }
                Remove-Item -LiteralPath (@($job.Cleanup) + $job.Log + @($job.Result | Where-Object { $_ })) -Force -ErrorAction SilentlyContinue
                if ($job.BusyApp) { Exit-WebAppBusy $job.BusyApp }
                Remove-WebJobRecord -Id $id
                Write-Log "[WARN] Stopped, still running at the end of the run: $($job.Mode) - check that app in Intune."
            }
            else { Write-Log "[WARN] Stopped without waiting for: $($job.Mode)." }
            continue
        }
        # Past the end of the log: nothing left to read, so this poll completes it.
        $r = Get-WebJobPoll ([pscustomobject]@{ job = $id; offset = [int64]::MaxValue })
        if ($r.after -and $r.after.pushGroups) { Write-Log "[WARN] $($job.Mode): the app window was closed, so its groups weren't pushed - use Send groups." }
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
    # Any finished step can change what Home's Intune part says (a release, a promote, a deploy).
    $Global:App.HomeIntuneCache = $null
    switch ($After.Kind) {
        'grouprename' { return (Complete-WebGroupRename -After $After) }
        # Looked for again: winget is asked through the module from now on.
        'wingetmodule' { $Global:App.WingetClientModule = $null; return @{ ok = $true; module = [bool](Test-WingetClientModule) } }
        'groupsaved' { return (Complete-WebGroupSaved -After $After -Result $Result) }
        'retire' { return (Complete-WebRetire -After $After) }
        'pilotassigned' {
            $id = [string]$After.AppId
            [void](Update-WebCatalogApp -Name $After.AppName -Change { param($app) foreach ($r in @($app.releases)) { if ($r -and [string]$r.appId -eq $id) { $r.unassigned = $false } } }.GetNewClosure())
            return @{ ok = $true }
        }
        'retired' { $Global:App.IntuneAppsCache = $null; return (Complete-WebRetireFinish -Name ([string]$After.AppName)) }
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
        'release' {
            $r = Complete-WebRelease -After $After -Result $Result
            # What follows (2.38.42) is started here, not by the page: the pilot assignment - or, with no pilot groups,
            # the app's groups and the old release's taken off - so a reload doesn't leave a pilot assigned to nobody.
            if ($r.ok -and $After.Flow) {
                $steps = @(Get-WebReleaseFlowSteps ([string]$After.Flow))
                $cur = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$After.AppName } | Select-Object -First 1
                $next = Start-WebReleaseAssign @{ name = [string]$After.AppName; step = $steps[0]; flow = [string]$After.Flow; then = @($steps | Select-Object -Skip 1); expectAppId = [string]$(if ($cur) { $cur.appId }); shared = $true }
                if ($next.ok) { $r.nextJob = [string]$next.job; $r.nextStep = [string]$steps[0]; $r.assignPilot = $false }
                else { $r.nextError = [string]$next.error; Write-Log "[WARN] $($After.AppName) $($After.Version) is in Intune, but its next step couldn't start: $($next.error)" }
            }
            return $r
        }
        'flow' { return (Complete-WebReleaseFlow -After $After) }
        'deploy' {
            $newId = [string]$Result.appId
            $defaults = $After.Defaults
            # The app is in Intune now: if its App ID can't be saved, the log keeps it (2.38.34) - Checks then offers it
            # ("In Intune, App ID not set") instead of a second app being sent.
            try {
            [void](Update-WebCatalogApp -Name $After.AppName -Change {
                param($app)
                if ($newId) { $app.appId = $newId }
                $app.intuneAppType = $(if ($After.Office) { 'Microsoft 365 Apps (Windows 10 and later)' } elseif ($After.Store) { 'Microsoft Store app (new)' } else { 'Windows app (Win32)' })
                # It replaced an MSI line-of-business app: that one stays in Intune until it is retired (asked for, not done here).
                if ($After.ReplacesLobAppId -and $newId) { $app.lobToRetire = ([string]$After.ReplacesLobAppId).ToLowerInvariant() }
                if (-not $app.metadata -and $defaults) {
                    # An update with the defaults kept Intune's Featured flag and supersedence (sent as $null) - so they are
                    # stored as not recorded (2.38.42), not as the defaults' off / none that a later send would then set.
                    if ($After.WasUpdate) { $defaults = $defaults.PSObject.Copy(); $defaults.isFeatured = $null; $defaults.supersedes = $null }
                    $app.metadata = $defaults
                }
                if ($After.PackageStamp) { $app.packageStamp = [string]$After.PackageStamp }
                # A managed app is sent pinned (its commands, detection and return codes written for its version, as they
                # are today) - the file takes that form too (2.38.38), or Checks compared the old form with Intune for good.
                if ($app.managedUpdates -and $app.wingetId -and $app.metadata) { [void](Set-ManagedAppPin $app) }
                # The emptied fields this send carried went to Intune as empty (2.38.34) - only those: one emptied while it ran
                # still waits, and a Store app's Owner or Notes (its type has none to send) stays a difference to see.
                $sentCleared = @($After.SentCleared)
                if ($app.metadata -and $app.metadata.PSObject.Properties['clearedFields']) { $app.metadata.clearedFields = @(@($app.metadata.clearedFields) | Where-Object { $sentCleared -notcontains $_ }) }
            }.GetNewClosure())
            }
            catch {
                if ($newId) { Write-Log "[FAILED] $($After.AppName) was created in Intune as $newId, but the catalog couldn't be saved: $($_.Exception.Message). Run Checks and use 'Set App ID'." }
                throw
            }
            Write-Log "[OK] Deployed $($After.AppName)$(if ($newId) { " (App ID $newId)" }) - saved to the catalog."
            if ($After.ReplacesLobAppId -and $newId) {
                Add-WebHistoryEntry -App $After.AppName -Kind 'intune' -Text "Created as a Win32 app ($newId) - it replaces the MSI line-of-business app $($After.ReplacesLobAppId), still in Intune until it is retired"
                Write-Log "[INFO] $($After.AppName): the MSI line-of-business app it replaces ($($After.ReplacesLobAppId)) is still in Intune - retire it from the app's side panel once the Win32 app has its groups."
            }
            $catalog = Read-WebCatalogRecords
            $app = $catalog.Apps | Where-Object { $_.appName -eq $After.AppName } | Select-Object -First 1
            $hasGroups = $app -and (@($app.requiredFor).Count + @($app.availableFor).Count + @($app.uninstallFor).Count) -gt 0
            # Send to Intune says whether the groups go too; otherwise Settings' automatic pushes decide.
            $wanted = if ($null -ne $After.SendGroups) { [bool]$After.SendGroups } elseif ($After.WasUpdate) { [bool]$Global:App.PushGroupsOnUpdate } else { [bool]$Global:App.PushGroupsOnCreate }
            return @{ ok = $true; pushGroups = [bool]($hasGroups -and $wanted -and $app.appId) }
        }
        default { return @{ ok = $true } }
    }
}

function Global:Get-WebJobPoll {
    # New output since -offset, and the result once the step has ended.
    param($Data)
    $id = [string]$Data.job
    if (-not $id -or -not $Global:App.WebJobs.ContainsKey($id)) {
        # Finished by another page's poll (a second tab, another admin following it - 2.38.42): its result and what
        # came after are kept for a few minutes, so the page that started it still learns how it ended.
        if ($id -and $Global:App.WebJobsDone -and $Global:App.WebJobsDone.ContainsKey($id)) { $d = $Global:App.WebJobsDone[$id]; return @{ ok = $true; text = ''; offset = [int64]$Data.offset; done = $true; result = $d.Result; after = $d.After } }
        return @{ ok = $false; error = 'No such job.' }
    }
    $job = $Global:App.WebJobs[$id]
    $job.LastPoll = Get-Date
    $offset = [int64]$Data.offset
    $exited = $job.Process.HasExited
    $text = ''
    try {
        $fs = [System.IO.File]::Open($job.Log, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            # Whole lines only while the step runs: the secret filter
            # (Protect-LogText) must see a token or signature in one piece,
            # never split across two polls. The rest waits for the next poll.
            $from = [Math]::Min($offset, $fs.Length)
            [void]$fs.Seek($from, [System.IO.SeekOrigin]::Begin)
            $bytes = New-Object byte[] ([int]($fs.Length - $from))
            $read = 0
            while ($read -lt $bytes.Length) { $n = $fs.Read($bytes, $read, $bytes.Length - $read); if ($n -le 0) { break }; $read += $n }
            $start = if ($from -eq 0 -and $read -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
            $end = $read
            if (-not $exited) {
                $nl = if ($read -gt 0) { [Array]::LastIndexOf($bytes, [byte]10) } else { -1 }
                $end = if ($nl -ge $start) { $nl + 1 } else { $start }
            }
            $text = [System.Text.Encoding]::UTF8.GetString($bytes, $start, [Math]::Max(0, $end - $start))
            $offset = $from + $end
        }
        finally { $fs.Dispose() }
    }
    catch { }
    $response = [ordered]@{ ok = $true; text = (Protect-LogText $text); offset = $offset; done = $false }
    if ($exited) {
        $response.done = $true
        $response.exitCode = $(try { $job.Process.ExitCode } catch { $null })
        $response.result = $null
        if ($job.Result -and (Test-Path -LiteralPath $job.Result)) {
            try { $response.result = Get-Content -LiteralPath $job.Result -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        }
        elseif (-not $job.Result) {
            # A step without a result file (Package.ps1) - its exit code says it.
            $code = $response.exitCode
            $response.result = [pscustomobject]@{ success = ($code -eq 0); error = $(if ($code -ne 0) { "Exit code $code - see the log." } else { '' }) }
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
                # A flow's 'retire' that failed still completes the flow (2.38.42) - the new release has the groups already.
                elseif ($job.After -and [string]$job.After.Kind -eq 'flow' -and [string]$job.After.Step -eq 'retire') {
                    try { $done = Complete-WebReleaseFlow -After $job.After -Failed -FailedError ([string]$(if ($response.result) { $response.result.error } else { 'it did not finish' })) }
                    catch { $done = @{ ok = $false; error = $_.Exception.Message }; Write-Log "[WARN] $($_.Exception.Message)" }
                }
                # What was just sent becomes the "sent" fingerprint (settings, or groups) - a later catalog change shows as Changes to send.
                if ($response.result -and $response.result.success -and [string]$job.Mode -notmatch '^(Release|Promote|Advance|Withdraw|Retire|Finish|Delete|Roll|Assign .+ to pilot$|Give )') {
                    $part = switch ([string]$job.Step) { 'createapp' { 's' } 'createstoreapp' { 's' } 'createofficeapp' { 's' } 'targetedassign' { 'g' } 'batchassign' { 'g' } default { '' } }
                    if ($part) { try { Set-WebSentStamp -Names @($job.HistoryApps) -Part $part -Snapshots $job.SentSnap } catch { Write-Log "[WARN] Couldn't note what was sent: $($_.Exception.Message)" } }
                }
                if ($response.result -and $response.result.success) {
                    foreach ($n in @($job.HistoryApps)) { Add-WebHistoryEntry -App $n -Kind 'intune' -Text ([string]$job.Mode) -Source $(if ($job.HistorySource) { [string]$job.HistorySource } else { 'This app' }) }
                }
                return @{ finished = $true; after = $done }
            }
            # The catalog lock couldn't be had (Invoke-WithCatalogLock gave up): not finished yet - the next poll tries again.
            if ($after -and $after.ok -eq $false -and $null -eq $after.finished) { $response.done = $false }
            if ($after.finished) {
                Remove-WebJobRecord -Id $id
                if ($job.BusyApp) { Exit-WebAppBusy $job.BusyApp }
                if ($null -ne $after.after) { $response.after = $after.after }
                if (-not $Global:App.WebJobsDone) { $Global:App.WebJobsDone = [hashtable]::Synchronized(@{}) }
                foreach ($k in @($Global:App.WebJobsDone.Keys)) { if (((Get-Date) - $Global:App.WebJobsDone[$k].At).TotalMinutes -gt 10) { $Global:App.WebJobsDone.Remove($k) } }
                $Global:App.WebJobsDone[$id] = @{ Result = $response.result; After = $response.after; At = (Get-Date) }
                Remove-Item -LiteralPath (@($job.Cleanup) + $job.Log + @($job.Result | Where-Object { $_ })) -Force -ErrorAction SilentlyContinue
                Write-Log "$(if ($response.result -and $response.result.success) { '[OK]' } else { '[WARN]' }) Finished: $($job.Mode)."
            }
        }
    }
    return $response
}

function Global:Open-WebUrl {
    # A web page: in the browser of this PC - or, the server version, in the admin's (the page opens it).
    param([string]$Url)
    if (Test-WebServerMode) { return @{ ok = $true; url = $Url } }
    Start-Process $Url
    return @{ ok = $true }
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
    if (Test-WebServerMode) { return @{ ok = $false; error = "That folder is on the server (the data volume): $Path" } }
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
            return (Open-WebUrl $url)
        }
        'catalog-folder' { return (Open-WebFolder (Get-AppFolder -Kind Catalog -Create)) }
        'logs-folder' { return (Open-WebFolder (Get-AppFolder -Kind Logs -Create)) }
        'reports-folder' { $rd = Join-Path (Get-AppFolder -Kind Logs -Create) 'reports'; if (-not (Test-Path -LiteralPath $rd)) { [void](New-Item -ItemType Directory -Path $rd -Force) }; return (Open-WebFolder $rd) }
        'entra-home' { return (Open-WebUrl 'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade/quickStartType~/null/sourceType/Microsoft_AAD_IAM') }
        'coffee' { return (Open-WebUrl 'https://buymeacoffee.com/monsama') }
        'intune-app' {
            # The app's page in the Intune admin center - by its App ID from the catalog (a GUID, nothing else is opened).
            $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
            $id = [string]$(if ($a) { $a.appId })
            if ($id -notmatch '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$') { return @{ ok = $false; error = 'This app has no Intune App ID yet - Send to Intune creates it.' } }
            return (Open-WebUrl "https://intune.microsoft.com/#view/Microsoft_Intune_Apps/SettingsMenu/~/0/appId/$id")
        }
        'release' { $repo = [string]$Global:App.ReleaseRepo; if ($repo -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { return @{ ok = $false; error = 'No release repository set.' } }; return (Open-WebUrl "https://github.com/$repo/releases/latest") }
        # Settings > About (2.38.34): the project's pages - a fixed list, only the repository comes from the app's own settings.
        { $_ -in 'repo', 'changelog', 'license', 'issues', 'security' } {
            $repo = [string]$Global:App.ReleaseRepo; if ($repo -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { return @{ ok = $false; error = 'No release repository set.' } }
            $tail = @{ repo = ''; changelog = '/blob/main/CHANGELOG.md'; license = '/blob/main/LICENSE'; issues = '/issues'; security = '/blob/main/SECURITY.md' }[[string]$Data.target]
            return (Open-WebUrl "https://github.com/$repo$tail")
        }
        'scripts-folder' { return (Open-WebFolder (Get-AppFolder -Kind Scripts -Create)) }
        'package-folder' {
            $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
            if (-not $a) { return @{ ok = $false; error = 'No such app.' } }
            $pf = Join-Path (Get-AppFolder -Kind Packages -Create) (Get-SafeFileNameForApp -Name $a.appName)
            if (-not (Test-Path -LiteralPath $pf)) { return @{ ok = $false; error = "$pf doesn't exist." } }
            return (Open-WebFolder $pf)
        }
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
    # -from: the number of the last line the page has (0: none yet) - the lines after it, and the newest number.
    $from = [int64]$Data.from
    $all = @($Global:App.WebLog.ToArray())
    $lines = @($all | Where-Object { [int64]$_.Seq -gt $from })
    return @{ ok = $true; next = $(if ($all.Count) { [int64]$all[-1].Seq } else { $from }); lines = $lines }
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
        # Each file's text is kept until its time or size changes - on a network share, reading
        # every file for every request is what makes a big catalog slow. Records are made fresh
        # each time, so a caller changing one never changes what another sees.
        if (-not $Global:App.CatalogTextCache) { $Global:App.CatalogTextCache = [hashtable]::Synchronized(@{}) }
        $textCache = $Global:App.CatalogTextCache
        $seen = @{}
        foreach ($file in @(Get-ChildItem -LiteralPath $path -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
            try {
                $key = $file.FullName.ToLowerInvariant(); $stamp = "$($file.LastWriteTimeUtc.Ticks)|$($file.Length)"; $seen[$key] = $true
                $hit = $textCache[$key]
                $text = if ($hit -and $hit.Stamp -eq $stamp) { $hit.Text } else { $t = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8; $textCache[$key] = @{ Stamp = $stamp; Text = $t }; $t }
                [void]$apps.Add((ConvertTo-AppRecord ($text | ConvertFrom-Json)))
            }
            catch { $failed.Add($file.Name) }
        }
        foreach ($k in @($textCache.Keys)) { if ($k.StartsWith($path.ToLowerInvariant()) -and -not $seen.ContainsKey($k)) { $textCache.Remove($k) } }
    }
    $Global:App.Apps = $apps
    return @{ Path = $path; Apps = $apps; Failed = $failed.ToArray() }
}

function Global:Invoke-WebApi {
    # The route table. $Data is the token-checked request body.
    param([string]$Path, $Data)
    # Where catalog changes made by this request come from, for the change history (per runspace - each request has its own).
    Set-Variable -Name WebChangeSource -Scope Global -Value (Get-WebChangeSource $Path)
    switch ($Path) {
        '/api/state'            { return (Get-WebState) }
        '/api/catalog'          { return (Get-WebCatalog) }
        '/api/settings-save'    { return (Save-WebSettings $Data) }
        '/api/cert-status'      { return (Get-WebCertStatus $Data) }
        '/api/certs-local'      { return (Get-WebLocalCertificates) }
        '/api/cert-new'         { return (New-WebCertificate $Data) }
        '/api/cert-import'      { return (Import-WebPfx $Data) }
        '/api/signin-settings'  { if (-not (Test-WebServerMode)) { return @{ ok = $false; error = 'The desktop app has no sign-in.' } }; return (Get-WebSignInSettings) }
        '/api/signin-save'      { if (-not (Test-WebServerMode)) { return @{ ok = $false; error = 'The desktop app has no sign-in.' } }; return (Save-WebSignInSettings $Data) }
        '/api/cert-file'        { return (Get-WebCertificateFile $Data) }
        '/api/cert-export-pfx'  { return (Export-WebPfx $Data) }
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
        '/api/app-history'      { return (Get-WebAppHistory $Data) }
        '/api/catalog-values'   { return (Get-WebCatalogValues) }
        '/api/winget-versions'  { return (Get-WebWingetVersions $Data) }
        '/api/catalog-history'  { return (Get-WebCatalogHistory $Data) }
        '/api/winget-commands'  { return (Get-WebWingetCommands $Data) }
        '/api/fill-details'     { return (Invoke-WebFillDetails $Data) }
        '/api/fill-preview'     { return (Get-WebFillPreview $Data) }
        '/api/install-blocks'   { return (Get-WebInstallBlocks $Data) }
        '/api/install-compose'  { return (Get-WebInstallCompose $Data) }
        '/api/detection-blocks' { return (Get-WebDetectionBlocks $Data) }
        '/api/detection-compose' { return (Get-WebDetectionCompose $Data) }
        '/api/package-script'   { return (Read-WebPackageScript $Data) }
        '/api/package-script-check' { return (Test-WebPackageScript $Data) }
        '/api/package-script-save' { return (Save-WebPackageScript $Data) }
        '/api/package-script-previous' { return (Get-WebPackageScriptPrevious $Data) }
        '/api/app-quick'        { return (Invoke-WithCatalogLock { Update-WebAppQuick $Data }) }
        '/api/marker-version'   { if (-not @((Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name }).Count) { return @{ ok = $false; error = 'No such app.' } }; return (Invoke-WithCatalogLock { @{ ok = $true; changed = @(Update-WebMarkerVersion -Name ([string]$Data.name) -Version ([string]$Data.version)) } }) }
        '/api/history-undo'     { return (Invoke-WithCatalogLock { Undo-WebHistoryChange $Data }) }
        '/api/app-restore'      { return (Invoke-WithCatalogLock { Restore-WebAppBackup $Data }) }
        '/api/deploy-plan'      { return (Get-WebDeployPlan $Data) }
        '/api/deploy-start'     { return (Start-WebDeploy $Data) }
        '/api/push-start'       { return (Start-WebPushGroups $Data) }
        '/api/checks-run'       { return (Invoke-WebChecks $Data) }
        '/api/checks-details'   { return (Start-WebCheckDetails $Data) }
        '/api/checks-assign'    { return (Start-WebCheckAssign $Data) }
        '/api/checks-winget'    { return (Invoke-WebCheckWinget $Data) }
        '/api/winget-search'    { return (Find-WebWinget $Data) }
        '/api/store-search'     { return (Find-WebStoreApps $Data) }
        '/api/add-from-intune'  { return (Start-WebAddFromIntune $Data) }
        '/api/batch-edit'       { return (Invoke-WithCatalogLock { Invoke-WebBatchEdit $Data }) }
        '/api/batch-groups'     { return (Invoke-WithCatalogLock { Invoke-WebBatchGroups $Data }) }
        '/api/replace-group'    { return (Invoke-WithCatalogLock { Invoke-WebReplaceGroup $Data }) }
        '/api/undo-info'        { return (Get-WebUndoInfo) }
        '/api/release-info'     { return (Get-WebReleaseInfo $Data) }
        '/api/release-start'    { return (Start-WebRelease $Data) }
        '/api/release-assign'   { return (Start-WebReleaseAssign $Data) }
        '/api/release-flow'     { return (Start-WebReleaseFlow $Data) }
        '/api/release-promoted' { return (Invoke-WithCatalogLock { Complete-WebPromotion $Data }) }
        '/api/release-rolledback' { return (Invoke-WithCatalogLock { Complete-WebRollback $Data }) }
        '/api/release-cleanup'  { return (Remove-WebOldReleases $Data) }
        '/api/release-advanced' { return (Invoke-WithCatalogLock { Complete-WebAdvance $Data }) }
        '/api/alert-test'       { return (Send-WebTestAlert) }
        '/api/health'           { return (Get-WebHealth) }
        '/api/permission-check' { return (Get-WebPermissionCheck $Data) }
        '/api/filters' { return (Get-WebAssignmentFilters) }
        '/api/download-checks'  { return (Invoke-WebDownloadChecks) }
        '/api/retire-start'     { return (Start-WebRetire $Data) }
        # Not under the catalog lock as a whole (2.38.0): a call to Intune, files copied - their catalog write takes it.
        '/api/lob-retire'       { return (Remove-WebReplacedLobApp $Data) }
        '/api/app-installer'    { return (Set-WebAppInstaller $Data) }
        '/api/app-duplicate'    { return (Invoke-WithCatalogLock { Copy-WebApp $Data }) }
        '/api/folder-upload-start' { return (Start-WebFolderUpload $Data) }
        '/api/upload-setup'     { return (Set-WebUploadSetup $Data) }
        '/api/package-files'    { return (Get-WebPackageFiles $Data) }
        '/api/package-file-delete' { return (Invoke-WithCatalogLock { Remove-WebPackageFile $Data }) }
        '/api/package-setup'    { return (Invoke-WithCatalogLock { Set-WebPackageSetup $Data }) }
        '/api/retire-status'    { return (Get-WebRetireStatus $Data) }
        '/api/retire-finish'    { return (Start-WebRetireFinish $Data) }
        '/api/retired-list'     { return (Get-WebRetiredApps) }
        '/api/retired-restore'  { return (Invoke-WithCatalogLock { Restore-WebRetiredApp $Data }) }
        '/api/group-suggest'    { return (Find-WebGroupSuggestions $Data) }
        '/api/group-check'      { return (Test-WebGroupNames $Data) }
        '/api/icon-find'        { return (Find-WebAppIcon $Data) }
        '/api/installed-apps'   { return (Get-WebInstalledApps) }
        '/api/detection-from-installed' { return (Get-WebDetectionFromInstalled $Data) }
        '/api/entra-script'     { return (Get-WebEntraScript $Data) }
        '/api/installed-script' { return (Get-WebInstalledAppsScript) }
        '/api/detection-from-paste' { return (Get-WebDetectionFromPaste $Data) }
        '/api/winget-export-script' { return (Get-WebWingetExportScript) }
        '/api/watch-check'      { $w = Get-WebWatchedUpdate $Data; if ($w.app) { $w.Remove('app') }; return $w }
        '/api/watch-fetch'      { return (Save-WebWatchedInstaller $Data) }
        '/api/attention'        { return (Get-WebAttention $Data) }
        '/api/managed-default'  { return (Set-WebManagedDefault) }
        '/api/assignment-matrix' { return (Get-WebAssignmentMatrix) }
        '/api/assignments-set'  { return (Invoke-WithCatalogLock { Set-WebAssignments $Data }) }
        '/api/package-list'     { return (Read-WebPackageList $Data) }
        '/api/winget-details'   { return (Get-WebWingetDetails $Data) }
        '/api/add-winget'       { return (Invoke-WithCatalogLock { Add-WebWingetApps $Data }) }
        '/api/upload-start'     { return (Start-WebUpload $Data) }
        '/api/upload-chunk'     { return (Add-WebUploadChunk $Data) }
        '/api/upload-finish'    { return (Complete-WebUpload $Data) }
        '/api/upload-cancel'    { return (Remove-WebUpload $Data) }
        '/api/add-installer'    { return (Add-WebInstallerApp $Data) }
        '/api/script-templates' { return (Get-WebScriptTemplates $Data) }
        '/api/add-script'       { return (Invoke-WithCatalogLock { Add-WebScriptApp $Data }) }
        '/api/add-office'       { return (Invoke-WithCatalogLock { Add-WebOfficeFromDialog $Data }) }
        '/api/add-psadt'        { return (Invoke-WithCatalogLock { Add-WebPsadtApp $Data }) }
        '/api/inventory-suggestions' { return (Get-WebInventorySuggestions) }
        '/api/unattended-status' { return (Get-WebUnattendedStatus) }
        '/api/unattended-script' { return (New-WebUnattendedScript) }
        '/api/monthly-report'   { return (Send-WebMonthlyReport -Month $(if ([string]$Data.month -match '^\d{4}-(0[1-9]|1[0-2])$') { [string]$Data.month } else { '' })) }
        '/api/updates-trend'    { return (Get-WebUpdatesTrend) }
        '/api/release-withdrawn' { return (Invoke-WithCatalogLock { Complete-WebWithdrawal $Data }) }
        '/api/update-runs'      { return (Get-WebUpdateRuns) }
        '/api/update-run'       { return (Start-WebUpdateRun $Data) }
        '/api/update-schedule'  { return (Set-WebUpdateSchedule $Data) }
        '/api/office-from-intune' { return (Get-WebOfficeFromIntune $Data) }
        '/api/portal-store'     { return (Invoke-WithCatalogLock { Set-WebCompanyPortalStore $Data }) }
        '/api/wau-switch'       { if ($Data.preview) { return (Invoke-WebWauSwitch $Data) }; return (Invoke-WithCatalogLock { Invoke-WebWauSwitch $Data }) }
        '/api/managed-updates'  { return (Invoke-WithCatalogLock { Set-WebManagedUpdates $Data }) }
        '/api/winget-take-version' { return (Invoke-WithCatalogLock { Set-WebWingetVersions $Data }) }
        '/api/tenant-setup'     { return (Get-WebTenantSetup) }
        '/api/install-overview' { return (Get-WebInstallOverview) }
        '/api/updates-overview' { return (Get-WebUpdatesOverview) }
        '/api/app-icons'        { return (Get-WebAppIcons $Data) }
        '/api/app-icon-intune'  { return (Get-WebIntuneIcon $Data) }
        '/api/app-compare'      { return (Get-WebAppVersionCompare $Data) }
        '/api/undo-last'        { return (Invoke-WithCatalogLock { Invoke-WebUndo }) }
        '/api/csv-export'       { return (Export-WebCatalogCsv) }
        '/api/csv-import'       { return $(if ($Data.preview) { Import-WebCatalogCsv $Data } else { Invoke-WithCatalogLock { Import-WebCatalogCsv $Data } }) }
        '/api/diagnostics'      { return (Get-WebDiagnostics) }
        '/api/about'            { return (Get-WebAbout $Data) }
        '/api/prereqs'          { return (Get-WebPrerequisites) }
        '/api/prereq-install'   { return (Start-WebPrerequisiteInstall $Data) }
        '/api/winget-module-install' { return (Start-WebWingetModuleInstall) }
        '/api/certs-all'        { return (Get-WebAllLocalCertificates) }
        '/api/cert-delete-local' { return (Remove-WebLocalCertificate $Data) }
        '/api/packaging'        { return (Get-WebPackaging) }
        '/api/packages-cleanup' { return (Invoke-WithCatalogLock { Invoke-WebOrphanPackageCleanup }) }
        '/api/packaging-setup'  { return (Invoke-WebPackagingSetup $Data) }
        '/api/package-start'    { return (Start-WebPackage $Data) }
        '/api/pull-start'       { return (Start-WebPull $Data) }
        '/api/unsent-diff'      { return (Get-WebUnsentDiff $Data) }
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
        '/api/group-search'     { return (Find-WebEntraGroups $Data) }
        '/api/directory-search' { return (Find-WebDirectory $Data) }
        '/api/group-job'        { return (Start-WebGroupJob $Data) }
        default                 { return @{ ok = $false; error = 'unknown' } }
    }
}

# ---------------------------------------------------------------- what was sent (2.26.4)

function Global:Get-WebTextSha256 {
    param([string]$Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '') } finally { $sha.Dispose() }
}

function Global:Get-WebAppSentHashes {
    <#
      Fingerprints of what Intune gets from an app: s = its settings (the
      metadata - for a managed app without the version, commands, detection and
      return codes, which releases own), g = its groups and filter.
    #>
    param($App)
    $v = Get-WebAppSentValues $App
    return @{ s = (Get-WebTextSha256 (ConvertTo-Json -InputObject $v.s -Compress -Depth 10)); g = (Get-WebTextSha256 (ConvertTo-Json -InputObject $v.g -Compress -Depth 4)) }
}

function Global:Get-WebAppSentValues {
    # What Intune gets from an app, as values: s = settings, g = groups and filter - fingerprinted above, and kept
    # beside the fingerprint after a send (2.38.8) so "Changes to send" can say what changed.
    param($App)
    $m = $App.metadata
    $skip = if ($App.managedUpdates) { @('appVersion', 'installCommand', 'uninstallCommand', 'detectionRule', 'returnCodes') } else { @() }
    $o = [ordered]@{ name = [string]$App.appName }
    if ($m) { foreach ($p in @($m.PSObject.Properties | Sort-Object Name)) { if ($skip -notcontains $p.Name) { $o[$p.Name] = $p.Value } } }
    # Microsoft 365 Apps (2.38.21): its settings are what Intune gets - in words, so Changes to send can show them.
    if ($App.office) { $o['office'] = [string](Get-OfficeSettingsSummary $App.office) }
    $sort = { param($l) @(@($l) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique) }
    $g = [ordered]@{ r = (& $sort $App.requiredFor); a = (& $sort $App.availableFor); u = (& $sort $App.uninstallFor); x = (& $sort $App.excludeFor); f = [string]$App.assignmentFilter; fm = [string]$App.assignmentFilterMode }
    return @{ s = $o; g = $g }
}

function Global:Read-WebSentStamps {
    $file = Join-Path (Get-WebIntegrityFolder) 'sent.json'
    $map = @{}
    if (Test-Path -LiteralPath $file) {
        try { foreach ($p in (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties) { $map[$p.Name] = @{ s = [string]$p.Value.s; g = [string]$p.Value.g; sv = [string]$p.Value.sv; gv = [string]$p.Value.gv } } } catch { }
    }
    return $map
}

function Global:Set-WebSentStamp {
    # After a send that worked: -Part s (settings) or g (groups) of these apps is what Intune has now.
    param([string[]]$Names, [string]$Part,
        # What each app's send sent, taken when it started (Start-WebStepJob) - recorded instead of the file as it is now.
        [hashtable]$Snapshots)
    $names = @($Names | Where-Object { $_ })
    if (-not $names.Count) { return }
    $map = Read-WebSentStamps
    $apps = @((Read-WebCatalogRecords).Apps)
    foreach ($n in $names) {
        $a = $apps | Where-Object { $_.appName -eq $n } | Select-Object -First 1
        if (-not $a) { continue }
        $key = Get-SafeFileNameForApp -Name $a.appName
        $h = Get-WebAppSentHashes $a
        $v = Get-WebAppSentValues $a
        $snap = if ($Snapshots -and $Snapshots.ContainsKey([string]$a.appName)) { $Snapshots[[string]$a.appName] } else { $null }
        if ($snap) {
            # Groups: as they were sent. Settings: likewise - unless the app had none of its own (the send's defaults are
            # stored when it ends), and with the emptied fields as the end of the send left them (the ones sent are off).
            $use = $null
            if ($Part -eq 'g') { $use = $snap.g }
            elseif (@($snap.s.Keys).Count -gt 1) { $use = [ordered]@{}; foreach ($k in @($snap.s.Keys)) { $use[$k] = $snap.s[$k] }; if ($v.s.Contains('clearedFields')) { $use['clearedFields'] = $v.s['clearedFields'] } elseif ($use.Contains('clearedFields')) { $use.Remove('clearedFields') } }
            if ($null -ne $use) {
                $v = @{ s = $v.s; g = $v.g }; $v[$Part] = $use
                $h = @{ s = $h.s; g = $h.g }; $h[$Part] = (Get-WebTextSha256 (ConvertTo-Json -InputObject $use -Compress -Depth $(if ($Part -eq 'g') { 4 } else { 10 })))
            }
        }
        if (-not $map.ContainsKey($key)) { $map[$key] = @{ s = ''; g = ''; sv = ''; gv = '' } }
        $map[$key][$Part] = $h[$Part]
        # The values too - "Changes to send" shows them next to the catalog's.
        $map[$key]["$($Part)v"] = (ConvertTo-Json -InputObject $v[$Part] -Compress -Depth 10)
    }
    $o = [ordered]@{}; foreach ($k in @($map.Keys | Sort-Object)) { $o[$k] = [ordered]@{ s = $map[$k].s; g = $map[$k].g; sv = [string]$map[$k].sv; gv = [string]$map[$k].gv } }
    [System.IO.File]::WriteAllText((Join-Path (Get-WebIntegrityFolder -Create) 'sent.json'), (ConvertTo-Json -InputObject $o -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}

function Global:Get-WebUnsentDiff {
    <#
      "Changes to send", field by field (2.38.8): what was last sent next to what the catalog has now. From the values
      kept at the last send; an app last sent by an earlier version has only its fingerprint, so its catalog edits
      since its last send to Intune come from the change history instead.
    #>
    param($Data)
    $a = @((Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name }) | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = 'Not in the catalog.' } }
    $st = (Read-WebSentStamps)[(Get-SafeFileNameForApp -Name $a.appName)]
    $h = Get-WebAppSentHashes $a
    $now = Get-WebAppSentValues $a
    $labels = @{ r = 'Required for'; a = 'Available for'; u = 'Uninstall for'; x = 'Excluded'; f = 'Assignment filter'; fm = 'Filter mode'; name = 'Name' }
    $label = { param($k) if ($labels.ContainsKey($k)) { $labels[$k] } else { $t = ($k -creplace '([a-z0-9])([A-Z])', '$1 $2').ToLowerInvariant(); $t.Substring(0, 1).ToUpperInvariant() + $t.Substring(1) } }
    $text = { param($v) if ($null -eq $v) { '' } elseif ($v -is [string]) { $v } elseif ($v -is [System.Collections.IEnumerable] -and -not ($v -is [System.Collections.IDictionary]) -and -not ($v.PSObject.Properties['PSPath'])) { (@($v | ForEach-Object { if ($_ -is [string] -or $_ -is [ValueType]) { [string]$_ } else { ConvertTo-Json -InputObject $_ -Compress -Depth 8 } })) -join ', ' } elseif ($v -is [ValueType]) { [string]$v } else { ConvertTo-Json -InputObject $v -Compress -Depth 8 } }
    $rows = New-Object System.Collections.Generic.List[object]
    $fromHistory = $false
    $histParts = New-Object System.Collections.Generic.List[string]
    foreach ($part in 's', 'g') {
        if (-not $st -or -not $st[$part] -or $st[$part] -eq $h[$part]) { continue }
        $what = if ($part -eq 's') { 'settings' } else { 'groups' }
        if ($st["$($part)v"]) {
            $was = $st["$($part)v"] | ConvertFrom-Json
            $cur = $now[$part] | ConvertTo-Json -Depth 10 | ConvertFrom-Json
            $keys = @(@($was.PSObject.Properties.Name) + @($cur.PSObject.Properties.Name) | Select-Object -Unique)
            foreach ($k in $keys) {
                # A field the last send's record doesn't hold (a managed app's version, commands, detection and return
                # codes go with its releases, so they weren't kept) isn't "blank in Intune" - said as what it is (2.38.36).
                $l = if ($was.PSObject.Properties[$k]) { & $text $was.$k } else { '(not recorded)' }
                $r = & $text $cur.$k
                if ($l -cne $r) { $rows.Add([ordered]@{ part = $what; field = (& $label $k); sent = $l; now = $r }) }
            }
        }
        else { $fromHistory = $true; $histParts.Add($part) }
    }
    if ($fromHistory) {
        # Since the last change in Intune: the catalog's own edits, oldest value first, newest last.
        $dir = Join-Path (Get-WebIntegrityFolder) 'history'
        $entries = @(Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { Get-Content -LiteralPath $_.FullName -Encoding UTF8 } |
            ForEach-Object { try { $_ | ConvertFrom-Json } catch { } } | Where-Object { $_ -and $_.app -eq $a.appName })
        $lastSend = -1
        for ($i = 0; $i -lt $entries.Count; $i++) { if ($entries[$i].kind -eq 'intune') { $lastSend = $i } }
        $by = [ordered]@{}
        for ($i = $lastSend + 1; $i -lt $entries.Count; $i++) {
            foreach ($c in @($entries[$i].changes)) {
                if (-not $c -or -not $c.field) { continue }
                $f = [string]$c.field
                if (-not $by.Contains($f)) { $by[$f] = @{ sent = [string]$c.before; now = [string]$c.after } } else { $by[$f].now = [string]$c.after }
            }
        }
        # Only what Intune gets (settings, groups, filter); the history keeps each value as compact JSON.
        $groupFields = @{ requiredFor = 'r'; availableFor = 'a'; uninstallFor = 'u'; excludeFor = 'x'; assignmentFilter = 'f'; assignmentFilterMode = 'fm'; appName = 'name' }
        $decode = { param($j) $t = ([string]$j).Trim(); if (-not $t -or $t -eq 'null') { '' } else { try { & $text (ConvertFrom-Json -InputObject $t) } catch { $t } } }
        # Only the part whose sent values aren't kept (the other came from them above), and not what a managed app's
        # releases own (version, commands, detection, return codes - never in its settings fingerprint).
        $skipManaged = if ($a.managedUpdates) { @('appVersion', 'installCommand', 'uninstallCommand', 'detectionRule', 'returnCodes') } else { @() }
        foreach ($f in $by.Keys) {
            $k = $null
            if ($f -like 'metadata.*' -and $histParts -contains 's' -and $skipManaged -notcontains $f.Substring(9)) { $k = $f.Substring(9) }
            elseif ($groupFields.ContainsKey($f) -and (($histParts -contains 'g' -and $f -ne 'appName') -or ($histParts -contains 's' -and $f -eq 'appName'))) { $k = $groupFields[$f] }
            if (-not $k) { continue }
            $l = & $decode $by[$f].sent; $r = & $decode $by[$f].now
            if ($l -cne $r) { $rows.Add([ordered]@{ part = 'history'; field = (& $label $k); sent = $l; now = $r }) }
        }
    }
    return @{ ok = $true; name = $a.appName; rows = $rows.ToArray(); fromHistory = $fromHistory }
}

function Global:Get-WebUnsent {
    # '' when Intune has what the catalog says (or it isn't known), else 'settings', 'groups' or 'settings,groups'.
    param($App, [hashtable]$Sent)
    $st = $Sent[(Get-SafeFileNameForApp -Name $App.appName)]
    if (-not $st) { return '' }
    $h = Get-WebAppSentHashes $App
    return (@($(if ($st.s -and $st.s -ne $h.s) { 'settings' }), $(if ($st.g -and $st.g -ne $h.g) { 'groups' })) | Where-Object { $_ }) -join ','
}
