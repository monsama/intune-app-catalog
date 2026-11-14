# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    The unattended managed-updates run: IntuneDeployment.ps1 -RunUpdates,
    started nightly by a Windows scheduled task (or "Run now").

    For every app with managed updates:
      - a version in pilot: ask Intune how the pilot devices did and apply
        the release rule (Get-ReleaseDecision) - promote it when it's ready
        and "promote automatically" is on, otherwise report wait / hold;
      - a Winget app with nothing in pilot: ask winget for the newest
        version - release it to pilot when "release automatically" is on,
        otherwise report it;
      - an own package: report a newer installer waiting in its folder
        (a person releases it - it's their installer).
    Writes a report (HTML and JSON, Logs\reports) and the Activity log.
    -PlanOnly: decides and reports, changes nothing.
    -FastTrackOnly: only the fast-track releases (urgent ones, judged in
    hours) - started every two hours by a second scheduled task; quiet when
    there is none.
    A release that passes the rule in one release ring goes on to the next
    ('advance'), and to everyone from the last one.
    After the run: the report keeps the share of devices on each app's
    current version (the Updates page's trend), and an alert goes to Teams
    and/or email when Settings > Alerts says so.

    Steps run exactly as from the page (Start-WebRelease, Start-WebReleaseAssign,
    Complete-WebPromotion), waited for here (Wait-WebStepJob).
#>

function Global:Wait-WebStepJob {
    # Runs a started step to its end, the way the page's polling does (completion included): @{ ok; error; after; log }.
    param($Started, [int]$TimeoutMinutes = 90)
    if (-not $Started.ok) { return @{ ok = $false; error = [string]$Started.error; log = '' } }
    $job = [string]$Started.job; $offset = 0
    $log = New-Object System.Text.StringBuilder
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        $r = Get-WebJobPoll @{ job = $job; offset = $offset }
        if (-not $r.ok) { return @{ ok = $false; error = [string]$r.error; log = $log.ToString() } }
        if ($r.text) { [void]$log.Append($r.text); $offset = $r.offset }
        if ($r.done -and -not $r.text) {
            $ok = [bool]($r.result -and $r.result.success)
            return @{ ok = $ok; error = $(if (-not $ok) { [string]$(if ($r.result) { $r.result.error } else { 'It did not finish.' }) } else { '' }); after = $r.after; log = $log.ToString() }
        }
        if ((Get-Date) -gt $deadline) { return @{ ok = $false; error = "Still running after $TimeoutMinutes minutes - left to finish on its own."; log = $log.ToString() } }
        Start-Sleep -Milliseconds 700
    }
}

function Global:Invoke-ManagedUpdateRun {
    <#
      One run over the catalog's managed apps (see the file's header).
      Returns the process exit code: 0 when everything went as planned, 1
      when a step failed or the run couldn't start.
    #>
    param([switch]$PlanOnly, [switch]$FastTrackOnly)
    $started = Get-Date
    $policy = $Global:App.ReleasePolicy
    $items = New-Object System.Collections.Generic.List[object]
    $say = { param($App, $Outcome, $Text) $items.Add([ordered]@{ app = [string]$App; outcome = [string]$Outcome; text = [string]$Text }); Write-Log "[$(if ($Outcome -eq 'failed') { 'WARN' } else { 'INFO' })] Managed updates: $App - $Text" }
    $reportDir = Join-Path (Get-AppFolder -Kind Logs -Create) 'reports'
    if (-not (Test-Path -LiteralPath $reportDir)) { [void](New-Item -ItemType Directory -Path $reportDir -Force) }

    # One run at a time (a nightly one may still be going when someone clicks Run now).
    $lockFile = Join-Path $reportDir 'managed-updates.lock'
    if (Test-Path -LiteralPath $lockFile) {
        $other = [int](Get-Content -LiteralPath $lockFile -Raw -ErrorAction SilentlyContinue)
        if ($other -and (Get-Process -Id $other -ErrorAction SilentlyContinue)) { Write-Host "Another managed-updates run is going (process $other)."; return 1 }
    }
    Set-Content -LiteralPath $lockFile -Value $PID
    $failed = 0
    try {
        if (-not (Test-GraphCredentialsConfigured -Quiet)) { & $say '(all)' 'failed' 'The connection isn''t set up (Settings > Connection).'; $failed++ }
        else {
            # Health first: what every later step needs (certificate, sign-in, packages).
            if (-not $FastTrackOnly) {
                foreach ($h in @(Get-WebHealthChecks)) {
                    if ($h.level -eq 'failed') { & $say '(health)' 'failed' $h.text; $failed++ }
                    elseif ($h.level -eq 'warn') { & $say '(health)' 'health' $h.text }
                }
            }
            $window = Test-ReleaseWindow -Now (Get-Date) -Policy $policy
            # A test tenant's catalog gates which Winget versions this one releases by itself.
            $gateApps = $null
            if ($policy.GatePath) {
                $gateApps = Read-WebCatalogFolder $policy.GatePath
                if ($null -eq $gateApps) { & $say '(test tenant)' 'failed' "The test tenant's catalog folder ($($policy.GatePath)) can't be read - nothing is released automatically."; $failed++; $gateApps = @() }
            }
            $catalog = Read-WebCatalogRecords
            $managed = @($catalog.Apps | Where-Object { $_.managedUpdates -and $_.appId })
            if ($FastTrackOnly) { $managed = @($managed | Where-Object { $p = Get-WebAppRelease $_; $p -and $p.fastTrack }) }
            if (-not $managed.Count -and -not $FastTrackOnly) { & $say '(all)' 'none' 'No deployed app has managed updates.' }
            # The newest winget versions, for the Winget apps with nothing in pilot.
            $askWinget = @($managed | Where-Object { $_.wingetId -and -not (Get-WebAppRelease $_) -and -not $FastTrackOnly })
            if ($askWinget.Count) {
                if (-not $Global:App.WingetLatest) { $Global:App.WingetLatest = [hashtable]::Synchronized(@{}) }
                if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
                    foreach ($a in $askWinget) {
                        $w = Test-WingetPackageId -AppName $a.appName -WingetId $a.wingetId
                        if ($w.Ok -and $w.Version) { $Global:App.WingetLatest[([string]$a.wingetId).ToLowerInvariant()] = [string]$w.Version }
                        elseif (-not $w.Ok) { & $say $a.appName 'failed' "winget couldn't be asked: $($w.Result)"; $failed++ }
                    }
                }
                else { & $say '(winget)' 'failed' 'winget.exe isn''t on this machine, so new Winget versions weren''t looked for.'; $failed++ }
            }
            foreach ($a in $managed) {
                $pilot = Get-WebAppRelease $a
                $current = [string]$(if ($a.metadata) { $a.metadata.appVersion })
                if ($pilot) {
                    $st = Get-WebPilotStatus $pilot -App $a
                    if (-not $st.ok) { & $say $a.appName 'failed' "$($pilot.version) in pilot - its install status couldn't be read: $($st.error)"; $failed++; continue }
                    # Too many failed: withdrawn by itself, when that switch is on (any day - the release window is for giving out, not taking back).
                    if (Test-AutoWithdraw -Counts $st.counts -Percent ([double]$policy.AutoWithdrawPercent)) {
                        $why = Get-WebHoldReason $pilot
                        if ($PlanOnly) { & $say $a.appName 'hold' "$($pilot.version) would be withdrawn: $($st.reason)$(if ($why) { " Why: $why" })"; continue }
                        $w1 = Wait-WebStepJob (Start-WebReleaseAssign @{ name = $a.appName; step = 'withdraw' })
                        if (-not $w1.ok) { & $say $a.appName 'failed' "Withdrawing $($pilot.version) failed: $($w1.error)"; $failed++; continue }
                        $w2 = Invoke-WithCatalogLock { Complete-WebWithdrawal @{ name = $a.appName } }
                        & $say $a.appName 'withdrawn' "$($pilot.version) withdrawn automatically - at least $($policy.AutoWithdrawPercent) % of devices failed ($($st.reason))$(if ($why) { " Why: $why" })$(if (-not $w2.deleted) { " It couldn't be deleted from Intune: $($w2.error)" })"
                        continue
                    }
                    if ($st.action -eq 'hold') { $why = Get-WebHoldReason $pilot; if ($why) { $st.reason = "$($st.reason) Why: $why" } }
                    # A fast-track release was marked urgent by a person: it goes on when ready even with automatic promotion off.
                    $auto = $policy.AutoPromote -or $st.fastTrack
                    # Outside the release window, nothing is given out by itself (a fast-track release doesn't wait).
                    if ($auto -and -not $st.fastTrack -and -not $window.Open -and $st.action -in 'advance', 'promote') { & $say $a.appName 'ready' "$($pilot.version) is ready ($($st.reason)) - waiting for the release window: $($window.Reason)."; continue }
                    if ($st.action -eq 'advance') {
                        if ($PlanOnly -or -not $auto) { & $say $a.appName 'ready' "$($pilot.version) is ready for the next ring: $($st.reason)$(if (-not $auto) { ' Give it to the next ring (automatic promotion is off).' })"; continue }
                        $adv = Wait-WebStepJob (Start-WebReleaseAssign @{ name = $a.appName; step = 'advance' })
                        if (-not $adv.ok) { & $say $a.appName 'failed' "Giving $($pilot.version) to the next ring failed - nothing else changed: $($adv.error)"; $failed++; continue }
                        $done = Invoke-WithCatalogLock { Complete-WebAdvance @{ name = $a.appName } }
                        & $say $a.appName 'advanced' "$($pilot.version) is in ring $([int]$done.ring + 1) ($($done.ringName)) now ($($st.reason))"
                        continue
                    }
                    if ($st.action -ne 'promote') { & $say $a.appName $st.action "$($pilot.version) in $(if ($st.ringCount -gt 1 -and -not $st.fastTrack) { "ring $($st.ring + 1) ($($st.ringName))" } else { 'pilot' }): $($st.reason)"; continue }
                    if ($PlanOnly -or -not $auto) { & $say $a.appName 'ready' "$($pilot.version) is ready for everyone: $($st.reason)$(if (-not $auto) { ' Promote it (automatic promotion is off).' })"; continue }
                    $p1 = Wait-WebStepJob (Start-WebReleaseAssign @{ name = $a.appName; step = 'promote' })
                    if (-not $p1.ok) { & $say $a.appName 'failed' "Promoting $($pilot.version) failed - nothing else changed: $($p1.error)"; $failed++; continue }
                    $p2 = Wait-WebStepJob (Start-WebReleaseAssign @{ name = $a.appName; step = 'retire' })
                    $done = Invoke-WithCatalogLock { Complete-WebPromotion @{ name = $a.appName } }
                    if ($done.ok) { & $say $a.appName 'promoted' "$($pilot.version) promoted to everyone ($($st.reason))$(if (-not $p2.ok) { " - but $current kept its assignments: $($p2.error)" })$(if (@($done.notes).Count) { ' ' + (@($done.notes) -join ' ') })" }
                    else { & $say $a.appName 'failed' "Promoting $($pilot.version): $($done.error)"; $failed++ }
                    continue
                }
                if ($a.wingetId) {
                    $latest = [string]$Global:App.WingetLatest[([string]$a.wingetId).ToLowerInvariant()]
                    if (-not $latest -or (Compare-AppVersionText $current $latest) -ne 1) { & $say $a.appName 'current' "$current is the newest on winget."; continue }
                    if ($null -ne $gateApps) {
                        $gate = Get-GateVersion -App $a -GateApps $gateApps
                        if (-not $gate.Version) { & $say $a.appName 'available' "winget offers $latest (now $current) - not released: $($gate.Reason)."; continue }
                        $latest = $gate.Version
                    }
                    if ($PlanOnly -or -not $policy.AutoRelease) { & $say $a.appName 'available' "winget offers $latest (now $current).$(if (-not $policy.AutoRelease) { ' Release it to pilot (automatic release is off).' })"; continue }
                    if (-not $window.Open) { & $say $a.appName 'available' "$latest is ready to release (now $current) - waiting for the release window: $($window.Reason)."; continue }
                    $made = Wait-WebStepJob (Start-WebRelease @{ name = $a.appName; version = $latest })
                    if (-not $made.ok) { & $say $a.appName 'failed' "Releasing $latest failed: $($made.error)"; $failed++; continue }
                    $assigned = Wait-WebStepJob (Start-WebReleaseAssign @{ name = $a.appName; step = 'pilot' })
                    if ($assigned.ok) { & $say $a.appName 'released' "$latest released to the pilot groups (now $current for everyone else)." }
                    else { & $say $a.appName 'failed' "$latest is in Intune but not assigned to pilot: $($assigned.error)"; $failed++ }
                    continue
                }
                # Own packages: a newer installer - downloaded from the app's address, when it has one - released by itself when the app says so.
                $dl = ''
                if ($a.autoRelease -and $a.downloadUrl -and -not $PlanOnly) {
                    $got = Save-WebInstallerDownload $a
                    if (-not $got.ok) { & $say $a.appName 'failed' $got.text; $failed++ } else { $dl = " $($got.text)" }
                }
                $inst = Get-WebInstallerInfo $a.appName
                if (-not ($inst.version -and (Compare-AppVersionText $current $inst.version) -eq 1)) { & $say $a.appName 'current' "$current - no newer installer in its folder.$dl"; continue }
                if (-not $a.autoRelease -or $PlanOnly) { & $say $a.appName 'available' "The installer in its folder is $($inst.version) (now $current)$(if (-not $a.autoRelease) { ' - release it from the app (automatic release is off for this app).' } else { '.' })$dl"; continue }
                if (-not $window.Open) { & $say $a.appName 'available' "The installer in its folder is $($inst.version) (now $current) - waiting for the release window: $($window.Reason).$dl"; continue }
                $built = Wait-WebStepJob (Start-WebPackage @{ names = @($a.appName) })
                if (-not $built.ok) { & $say $a.appName 'failed' "Building the package for $($inst.version) failed: $($built.error)"; $failed++; continue }
                $made = Wait-WebStepJob (Start-WebRelease @{ name = $a.appName; version = $inst.version; productCode = $inst.productCode })
                if (-not $made.ok) { & $say $a.appName 'failed' "Releasing $($inst.version) failed: $($made.error)"; $failed++; continue }
                $assigned = Wait-WebStepJob (Start-WebReleaseAssign @{ name = $a.appName; step = 'pilot' })
                if ($assigned.ok) { & $say $a.appName 'released' "$($inst.version) ($($inst.file)) released to the pilot groups (now $current for everyone else).$dl" }
                else { & $say $a.appName 'failed' "$($inst.version) is in Intune but not assigned to pilot: $($assigned.error)"; $failed++ }
            }
        }
        # Superseded releases beyond the newest one (kept for rollback): deleted from Intune when the switch is on.
        if (-not $FastTrackOnly -and (Test-GraphCredentialsConfigured -Quiet)) {
            foreach ($a in @((Read-WebCatalogRecords).Apps | Where-Object { $_.managedUpdates -and @(Get-WebPreviousReleases $_).Count -gt 1 })) {
                if ($PlanOnly -or -not $policy.CleanupOld) {
                    $plan = Remove-WebOldReleases @{ name = $a.appName; planOnly = $true }
                    & $say $a.appName 'cleanup' "Superseded release(s) $(@($plan.plan) -join ', ') could be deleted from Intune ($(@($plan.kept) -join ', ') is kept for rollback)$(if (-not $policy.CleanupOld) { ' - automatic clean-up is off.' } else { '.' })"
                    continue
                }
                $c = Remove-WebOldReleases @{ name = $a.appName }
                if (@($c.removed).Count) { & $say $a.appName 'cleaned' "Deleted superseded release(s) $(@($c.removed) -join ', ') from Intune; kept $(@($c.kept) -join ', ') for rollback." }
                if (@($c.failed).Count) { & $say $a.appName 'failed' "Couldn't delete: $(@($c.failed) -join '; ')"; $failed++ }
            }
        }
        # Full nightly runs only: drift (and its fix), the catalog backup, the monthly report on the month's first run.
        if (-not $FastTrackOnly -and -not $PlanOnly -and (Test-GraphCredentialsConfigured -Quiet)) {
            if ($policy.DriftCheck) {
                foreach ($d in @(Invoke-WebNightlyDrift -Fix:([bool]$policy.DriftFix))) { & $say $d.app $d.outcome $d.text; if ($d.outcome -eq 'failed') { $failed++ } }
            }
            if ($policy.MonthlyReport) {
                $lastMonth = (Get-Date).AddMonths(-1).ToString('yyyy-MM')
                if (-not (Test-Path -LiteralPath (Join-Path $reportDir "monthly-$lastMonth.html"))) {
                    $m = Send-WebMonthlyReport -Month $lastMonth
                    & $say 'Monthly report' $(if ($m.error) { 'failed' } else { 'report' }) "$lastMonth report written$(if (@($m.sent).Count) { " and sent ($(@($m.sent) -join ', '))" })$(if ($m.error) { " - sending failed: $($m.error)" })."
                    if ($m.error) { $failed++ }
                }
            }
        }
        if (-not $FastTrackOnly -and -not $PlanOnly -and $policy.BackupCatalog) {
            $b = Invoke-WebCatalogBackup
            & $say '(backup)' $(if ($b.ok) { 'backup' } else { 'failed' }) $b.text
            if (-not $b.ok) { $failed++ }
        }
    }
    catch { & $say '(run)' 'failed' "The run stopped: $($_.Exception.Message)"; $failed++ }
    finally { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }

    # A fast-track pass with nothing on the fast track leaves no report (it runs every two hours).
    if ($FastTrackOnly -and -not $items.Count) { Write-Host 'No fast-track release.'; return 0 }
    # The trend: how many devices have each app's current version, kept with the report (nightly runs only).
    $trend = $null
    if (-not $FastTrackOnly) {
        try {
            $ov = Get-WebUpdatesOverview -NoInventory
            if ($ov.ok -and $ov.connected) {
                $trend = [ordered]@{ onCurrentPercent = $ov.summary.onCurrentPercent; devices = $ov.summary.devices
                    apps = @(@($ov.rows) | Where-Object { $null -ne $_.onCurrentPercent } | ForEach-Object { [ordered]@{ app = $_.name; version = $_.current; percent = $_.onCurrentPercent } }) }
            }
        }
        catch { Write-Log "[WARN] Managed updates: the device counts for the trend couldn't be read: $($_.Exception.Message)" }
    }
    $report = [ordered]@{ started = $started.ToString('yyyy-MM-dd HH:mm'); finished = (Get-Date).ToString('yyyy-MM-dd HH:mm'); planOnly = [bool]$PlanOnly; fastTrackOnly = [bool]$FastTrackOnly; failed = $failed
        policy = $policy; items = $items.ToArray(); trend = $trend }
    # The alert (Teams / email) - its own failure is reported, not fatal.
    $sent = Send-ManagedUpdateAlert $report
    if ($sent.error) { $report.items = @($report.items) + @([ordered]@{ app = '(alert)'; outcome = 'failed'; text = $sent.error }); $report.failed = ++$failed }
    $base = Join-Path $reportDir ("managed-updates-" + $started.ToString('yyyy-MM-dd-HHmmss'))
    [System.IO.File]::WriteAllText("$base.json", ($report | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText("$base.html", (ConvertTo-ManagedUpdateReportHtml $report), (New-Object System.Text.UTF8Encoding($false)))
    # Older reports beyond the last 60 runs go.
    @(Get-ChildItem -LiteralPath $reportDir -Filter 'managed-updates-*.json' -File | Sort-Object Name -Descending | Select-Object -Skip 60) | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath ($_.FullName -replace '\.json$', '.html') -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Report: $base.html"
    Write-Log "[$(if ($failed) { 'WARN' } else { 'OK' })] Managed updates run$(if ($PlanOnly) { ' (plan only)' }): $($items.Count) item(s), $failed failure(s). Report: $base.html"
    return $(if ($failed) { 1 } else { 0 })
}

# ---------------------------------------------------------------- the nightly run's other work

function Global:Get-WebConnectionCertificate {
    # The connection's certificate on this PC: @{ Cert; Store } or $null.
    $t = ([string]$Global:App.GraphCertificateThumbprint) -replace '\s', ''
    if (-not $t) { return $null }
    foreach ($loc in 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My') {
        try {
            $c = Get-ChildItem -LiteralPath $loc -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $t } | Select-Object -First 1
            if ($c) { return @{ Cert = $c; Store = $loc } }
        }
        catch { }
    }
    return $null
}

function Global:Get-WebHealthChecks {
    <#
      What the nightly run needs to keep working: the connection's
      certificate (found, private key, not expiring within 30 days), a
      Graph call that works, the shared Winget package and the packaging
      tool when apps need them, and free disk space.
      @(@{ level = ok|warn|failed; text }).
    #>
    $out = New-Object System.Collections.Generic.List[object]
    $add = { param($l, $t) $out.Add([ordered]@{ level = $l; text = $t }) }
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { & $add 'failed' "The connection isn't set up (Settings > Connection)."; return , $out.ToArray() }
    if ($Global:App.TestGraph) { & $add 'ok' "Test mode: the certificate isn't checked." }
    else {
        $found = Get-WebConnectionCertificate
        $h = Get-CertificateHealth -NotAfter $(if ($found) { $found.Cert.NotAfter } else { $null }) -Now (Get-Date)
        & $add $h.Level $h.Text
        if ($found -and -not $found.Cert.HasPrivateKey) { & $add 'failed' "The connection certificate in $($found.Store) has no private key - sign-in fails." }
    }
    $probe = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) [void](& $Graph 'https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?$select=id&$top=1'); $true }
    if ($probe.ok) { & $add 'ok' 'Signing in to Microsoft Graph works.' } else { & $add 'failed' "Signing in to Microsoft Graph failed: $($probe.error)" }
    $apps = @((Read-WebCatalogRecords).Apps | Where-Object { $_.managedUpdates })
    if (@($apps | Where-Object { $_.wingetId }).Count -and -not (Test-Path -LiteralPath (Get-SharedPackagePath))) { & $add 'warn' "The shared Winget package (init.intunewin) is missing - Winget releases can't be created. Settings > Packaging & folders builds it." }
    if (@($apps | Where-Object { -not $_.wingetId -and $_.autoRelease }).Count) {
        $tool = Get-PackagingToolPath
        if (-not $tool -or -not (Test-Path -LiteralPath $tool)) { & $add 'warn' "The packaging tool (IntuneWinAppUtil.exe) is missing - own packages can't be built. Settings > Packaging & folders downloads it." }
    }
    try {
        $root = [System.IO.Path]::GetPathRoot((Get-AppFolder -Kind Catalog))
        if ($root) { $free = (New-Object System.IO.DriveInfo($root)).AvailableFreeSpace; if ($free -lt 1GB) { & $add 'warn' "Only $([Math]::Round($free / 1MB)) MB free on $root." } }
    }
    catch { }
    return , $out.ToArray()
}

function Global:Invoke-WebNightlyDrift {
    <#
      Checks in detail, unattended: every deployed app against Intune
      (settings, groups, dependencies) and the assignments Intune has that
      the catalog doesn't. @(@{ app; outcome = drift|fixed|failed; text }).
      -Fix: Push groups for the apps whose assignments drifted.
    #>
    param([switch]$Fix)
    $items = New-Object System.Collections.Generic.List[object]
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($start in @({ Start-WebCheckDetails @{} }, { Start-WebCheckAssign @{} })) {
        $s = & $start
        if (-not $s.ok) { if ($s.error -notlike 'No deployed app*') { $items.Add([ordered]@{ app = '(drift)'; outcome = 'failed'; text = "The drift check couldn't start: $($s.error)" }) }; continue }
        $r = Wait-WebStepJob $s
        if (-not $r.ok) { $items.Add([ordered]@{ app = '(drift)'; outcome = 'failed'; text = "The drift check failed: $($r.error)" }); continue }
        foreach ($f in @($r.after.findings)) { if ($f -and -not $f.failed) { $rows.Add($f) } }
    }
    $fixable = New-Object System.Collections.Generic.List[string]
    foreach ($g in @($rows | Group-Object { [string]$(if ($_.catalogName) { $_.catalogName } else { $_.app }) })) {
        $areas = @($g.Group | ForEach-Object { [string]$_.area } | Select-Object -Unique)
        $what = @($g.Group | Select-Object -First 3 | ForEach-Object { "$($_.area): $($_.problem)" }) -join '; '
        $items.Add([ordered]@{ app = $g.Name; outcome = 'drift'; text = "Intune differs from the catalog - $what$(if ($g.Count -gt 3) { "; $($g.Count - 3) more" }). Checks has the details." })
        if (@($areas | Where-Object { $_ -in 'Groups', 'Unknown assignments' }).Count -and $g.Name) { $fixable.Add($g.Name) }
    }
    if ($Fix -and $fixable.Count) {
        $p = Wait-WebStepJob (Start-WebPushGroups @{ names = $fixable.ToArray(); mode = 'Apply' })
        if ($p.ok) { $items.Add([ordered]@{ app = ($fixable -join ', '); outcome = 'fixed'; text = "Pushed the catalog's groups again - Intune's assignments match the catalog." }) }
        else { $items.Add([ordered]@{ app = ($fixable -join ', '); outcome = 'failed'; text = "Pushing the catalog's groups failed: $($p.error)" }) }
    }
    return , $items.ToArray()
}

function Global:Get-WebHoldReason {
    # Why pilot devices failed a release: the install status report's error codes, most common first ('' when none could be read).
    param($Pilot)
    $id = [string]$Pilot.appId
    $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) Get-AppInstallStatusRows -AppId $id -Invoke $Graph -MaxRows 1000 }
    if (-not $read.ok) { return '' }
    return [string](Get-InstallErrorSummary -Rows @($read.value.Rows)).Text
}

function Global:Test-WebGitRepoSafe {
    <#
      Why the catalog folder's git repository mustn't be run ('' when it may):
      its .git owned by someone other than this user, a filter (which runs a
      command on add) in its .gitattributes or config, or an fsmonitor.
    #>
    param([string]$Folder)
    $gitDir = Join-Path $Folder '.git'
    try {
        $owner = (Get-Acl -LiteralPath $gitDir).Owner
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ($owner -and $me -and $owner -ne $me -and $owner -notmatch '\\Administrators$') { return "its .git belongs to $owner, not you." }
    }
    catch { }
    foreach ($f in @((Join-Path $Folder '.gitattributes'), (Join-Path $gitDir 'info\attributes'))) {
        if ((Test-Path -LiteralPath $f) -and ((Get-Content -LiteralPath $f -Raw) -match 'filter\s*=')) { return "$f sets a filter." }
    }
    $cfg = Join-Path $gitDir 'config'
    if ((Test-Path -LiteralPath $cfg) -and ((Get-Content -LiteralPath $cfg -Raw) -match '(?im)^\s*\[filter|^\s*fsmonitor\s*=|^\s*hookspath\s*=')) { return 'its config sets a filter, an fsmonitor or a hooks path.' }
    return ''
}

function Global:Invoke-WebCatalogBackup {
    # A zip of the catalog's app files in the Backups folder (the last 30 kept); a commit too when the catalog folder is a git repository.
    $cat = Get-AppFolder -Kind Catalog
    $files = @(Get-ChildItem -LiteralPath $cat -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if (-not $files.Count) { return @{ ok = $true; text = 'No app files to back up.' } }
    $dir = Get-AppFolder -Kind Backups -Create
    $zip = Join-Path $dir ("catalog-" + (Get-Date).ToString('yyyy-MM-dd-HHmmss') + ".zip")
    try { Compress-Archive -LiteralPath @($files | ForEach-Object { $_.FullName }) -DestinationPath $zip -CompressionLevel Optimal -ErrorAction Stop }
    catch { return @{ ok = $false; text = "The catalog backup failed: $($_.Exception.Message)" } }
    @(Get-ChildItem -LiteralPath $dir -Filter 'catalog-*.zip' -File | Sort-Object Name -Descending | Select-Object -Skip 30) | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    $text = "Backed up $($files.Count) app file(s) to $zip."
    $gitDir = Join-Path $cat '.git'
    if ($Global:App.ReleasePolicy.BackupGit -and (Test-Path -LiteralPath $gitDir) -and (Get-Command git -ErrorAction SilentlyContinue)) {
        # Only a repository this user owns, with no hooks, fsmonitor or filters of its own: on a share, someone
        # else could otherwise put a command in its .git that runs here, as the user who holds the certificate.
        $why = Test-WebGitRepoSafe $cat
        if ($why) { return @{ ok = $true; text = "$text The changes weren't committed: $why" } }
        $hooks = Join-Path ([System.IO.Path]::GetTempPath()) ('intunecat-nohooks-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $hooks -Force)
        $safe = @('-c', 'core.fsmonitor=false', '-c', "core.hooksPath=$hooks", '-c', 'core.untrackedCache=false')
        $changes = & git -C $cat @safe status --porcelain -- '*.json' 2>$null
        if ($changes) {
            & git -C $cat @safe add -- '*.json' 2>$null | Out-Null
            & git -C $cat @safe commit --no-verify -q -m "Catalog as of $((Get-Date).ToString('yyyy-MM-dd HH:mm')) (nightly run)" 2>$null | Out-Null
            $text += $(if ($LASTEXITCODE -eq 0) { ' Committed the changes to the catalog''s git repository.' } else { ' The git commit failed - see git status in the catalog folder.' })
        }
        Remove-Item -LiteralPath $hooks -Recurse -Force -ErrorAction SilentlyContinue
    }
    return @{ ok = $true; text = $text }
}

function Global:Read-WebCatalogFolder {
    # Every app in another catalog folder (the test tenant's), as app records - read only.
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $null }
    return @(Get-ChildItem -LiteralPath $Path -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
            try { ConvertTo-AppRecord (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
        })
}

function Global:Invoke-WebHttpsGet {
    <#
      A GET that stays on https (a redirect elsewhere is refused) and stops at
      -MaxBytes - read into memory, or into -OutFile. Returns the bytes (no
      -OutFile) or $null; throws with the reason.
    #>
    param([string]$Uri, [long]$MaxBytes, [string]$OutFile, [int]$TimeoutSec = 60)
    if ($Uri -notmatch '^https://') { throw 'Only https addresses are read.' }
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $true; $handler.MaxAutomaticRedirections = 5
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)
    [void]$client.DefaultRequestHeaders.UserAgent.TryParseAdd('IntuneAppCatalog')
    try {
        $resp = $client.GetAsync($Uri, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        $final = $resp.RequestMessage.RequestUri
        if ($final.Scheme -ne 'https') { throw "It was redirected off https ($($final.Host))." }
        if (-not $resp.IsSuccessStatusCode) { throw "$([int]$resp.StatusCode) $($resp.ReasonPhrase)" }
        $len = $resp.Content.Headers.ContentLength
        if ($len -and $len -gt $MaxBytes) { throw "It is larger than $([Math]::Round($MaxBytes / 1MB)) MB." }
        $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $out = if ($OutFile) { [System.IO.File]::Create($OutFile) } else { New-Object System.IO.MemoryStream }
        try {
            $buf = New-Object byte[] 81920; $total = 0
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $total += $n
                if ($total -gt $MaxBytes) { throw "It is larger than $([Math]::Round($MaxBytes / 1MB)) MB." }
                $out.Write($buf, 0, $n)
            }
            if (-not $OutFile) { return , $out.ToArray() }
            return $null
        }
        finally { $out.Dispose(); $in.Dispose() }
    }
    finally { $client.Dispose() }
}

function Global:Save-WebInstallerDownload {
    <#
      Own packages: the installer from the app's download address into its
      folder - only an .msi or .exe with a valid digital signature, from the
      same publisher as the installer already there (when that one is
      signed). The installer keeps the folder's file name, so the install
      command still finds it. @{ ok; changed; text }.
    #>
    param($App)
    $url = [string]$App.downloadUrl
    if ($Global:App.TestGraph) { return @{ ok = $true; changed = $false; text = 'Test mode: nothing downloaded.' } }
    if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) { return @{ ok = $false; changed = $false; text = 'Checking an installer''s signature needs Windows.' } }
    $folder = Join-Path (Get-AppFolder -Kind Packages) (Get-SafeFileNameForApp -Name $App.appName)
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    $old = Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msi', '.exe' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $urlName = [System.IO.Path]::GetFileName(([Uri]$url).AbsolutePath)
    $ext = if ($old) { $old.Extension } else { [System.IO.Path]::GetExtension($urlName) }
    if ($ext -notin '.msi', '.exe') { return @{ ok = $false; changed = $false; text = "The download address doesn't name an .msi or .exe, and the folder has no installer to take the name from." } }
    $tmp = Join-Path $env:TEMP ("intunecat-dl-" + [guid]::NewGuid().ToString('N') + $ext)
    try {
        # Released by itself to devices as SYSTEM: only from a publisher already trusted for this app - the signer
        # (subject and issuer) of a validly signed installer already in its folder. No such installer: nothing is downloaded.
        if (-not $old) { return @{ ok = $false; changed = $false; text = 'Put a signed installer from this vendor in the app''s folder first - downloads must be signed by the same publisher.' } }
        $oldSig = Get-AuthenticodeSignature -LiteralPath $old.FullName
        if ($oldSig.Status -ne 'Valid') { return @{ ok = $false; changed = $false; text = "The installer in the app's folder ($($old.Name)) isn't validly signed, so a download can't be checked against it - not downloaded." } }
        Invoke-WebHttpsGet -Uri $url -MaxBytes 8GB -OutFile $tmp -TimeoutSec 900
        $sig = Get-AuthenticodeSignature -LiteralPath $tmp
        if ($sig.Status -ne 'Valid') { return @{ ok = $false; changed = $false; text = "The downloaded installer isn't validly signed ($($sig.Status)) - not used." } }
        if ($oldSig.SignerCertificate.Subject -ne $sig.SignerCertificate.Subject -or $oldSig.SignerCertificate.Issuer -ne $sig.SignerCertificate.Issuer) { return @{ ok = $false; changed = $false; text = "The downloaded installer is signed by '$($sig.SignerCertificate.Subject)' (issuer '$($sig.SignerCertificate.Issuer)'), not like the one in the folder - not used." } }
        if ((Get-FileHash -LiteralPath $tmp).Hash -eq (Get-FileHash -LiteralPath $old.FullName).Hash) { return @{ ok = $true; changed = $false; text = 'The download is the installer already in the folder.' } }
        $target = $old.FullName
        Move-Item -LiteralPath $tmp -Destination $target -Force
        return @{ ok = $true; changed = $true; text = "Downloaded a new installer ($([System.IO.Path]::GetFileName($target)), signed by $($sig.SignerCertificate.Subject))." }
    }
    catch { return @{ ok = $false; changed = $false; text = "Downloading the installer failed: $($_.Exception.Message)" } }
    finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Global:Send-WebMonthlyReport {
    <#
      The month's managed-updates report (Get-MonthlyReportData over the
      nightly reports): an HTML file in Logs\reports, and the same by email
      / a Teams card when alerts are set up. -Month: yyyy-MM (default: last
      month). @{ ok; path; sent; error }.
    #>
    param([string]$Month)
    if (-not $Month) { $Month = (Get-Date).AddMonths(-1).ToString('yyyy-MM') }
    $dir = Join-Path (Get-AppFolder -Kind Logs -Create) 'reports'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $reports = @(Get-ChildItem -LiteralPath $dir -Filter "managed-updates-$Month-*.json" -File -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } })
    $d = Get-MonthlyReportData -Reports $reports -Month $Month
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $ov = $null; try { $ov = Get-WebUpdatesOverview -NoInventory } catch { }
    $appRows = if ($ov -and $ov.ok) { @($ov.rows | ForEach-Object { "<tr><td>$(& $enc $_.name)</td><td>$(& $enc $_.current)</td><td>$(if ($null -ne $_.onCurrentPercent) { & $enc "$($_.onCurrentPercent) %" } else { '-' })</td><td>$(if ($_.pilot) { & $enc "$($_.pilot.version) ($($_.pilot.action))" } else { '-' })</td></tr>" }) } else { @() }
    $evRows = @($d.events | ForEach-Object { "<tr><td>$(& $enc $_.at)</td><td>$(& $enc $_.app)</td><td>$(& $enc $_.outcome)</td><td>$(& $enc $_.text)</td></tr>" })
    $html = @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Managed updates $(& $enc $Month)</title>
<style>body{font:14px system-ui,Segoe UI,sans-serif;margin:24px;color:#101828}table{border-collapse:collapse;width:100%;margin-bottom:20px}th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #eaecf0;vertical-align:top}th{color:#475467;font-size:12px}</style></head>
<body><h1>Managed updates - $(& $enc $Month)</h1>
<p>$($d.runs) nightly run(s). Released: $($d.released), promoted: $($d.promoted), withdrawn: $($d.withdrawn), held: $($d.held), failures: $($d.failed).$(if ($null -ne $d.endPercent) { " Devices on the current version: $(& $enc $d.startPercent) % at the start of the month, $(& $enc $d.endPercent) % at the end." })</p>
<h2>Apps now</h2><table><thead><tr><th>App</th><th>Current version</th><th>Devices on it</th><th>In release</th></tr></thead><tbody>$($appRows -join '')</tbody></table>
<h2>What happened</h2><table><thead><tr><th>Run</th><th>App</th><th>Outcome</th><th>Details</th></tr></thead><tbody>$(if ($evRows.Count) { $evRows -join '' } else { '<tr><td colspan="4">Nothing was released, promoted or held this month.</td></tr>' })</tbody></table>
</body></html>
"@
    $path = Join-Path $dir "monthly-$Month.html"
    [System.IO.File]::WriteAllText($path, $html, (New-Object System.Text.UTF8Encoding($false)))
    $summary = @{ items = @([ordered]@{ app = 'Monthly report'; outcome = 'report'; text = "$Month - released $($d.released), promoted $($d.promoted), withdrawn $($d.withdrawn), held $($d.held)$(if ($null -ne $d.endPercent) { "; $($d.endPercent) % of devices on the current version" }). The full report is in Logs\reports\monthly-$Month.html." }); failed = 0; planOnly = $false; policy = $null; html = $html; subject = "Managed updates - $Month" }
    $al = $Global:App.Alerts
    $sent = if ($al.WebhookUrl -or ($al.MailFrom -and @($al.MailTo).Count)) { Send-ManagedUpdateAlert $summary -Force } else { @{ sent = @(); error = '' } }
    Write-Log "[OK] Monthly report for ${Month}: $path$(if (@($sent.sent).Count) { " - sent ($(@($sent.sent) -join ', '))" })"
    return @{ ok = $true; path = $path; month = $Month; sent = @($sent.sent); error = [string]$sent.error }
}

function Global:Send-ManagedUpdateAlert {
    <#
      Sends a run's alert, when Settings > Alerts says the report is worth
      one (Get-ManagedRunAlert): an Adaptive Card to the Teams webhook
      and/or an email with Graph (sendMail from MailFrom - Mail.Send).
      -Force: send whatever the level (the Send a test button).
      @{ sent = @('Teams', 'email'); error = '' or what failed }.
      In test mode the webhook isn't called: the card is kept in
      $Global:App.TestAlerts, and the email goes to the test answers.
    #>
    param($Report, [switch]$Force)
    $al = $Global:App.Alerts
    $msg = Get-ManagedRunAlert -Report $Report -Level $(if ($Force) { 'always' } else { [string]$al.Level })
    $sent = New-Object System.Collections.Generic.List[string]
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not $msg.Send) { return @{ sent = @(); error = '' } }
    $mail = [bool]($al.MailFrom -and @($al.MailTo).Count)
    if (-not $al.WebhookUrl -and -not $mail) { return @{ sent = @(); error = $(if ($Force) { 'Set a Teams webhook or an email first, and save.' } else { '' }) } }
    # Teams renders markdown: brackets become parentheses, so a name or an error can't make a link in the channel.
    $lines = @($msg.Lines | ForEach-Object { ([string]$_) -replace '\[', '(' -replace '\]', ')' })
    $shown = @($lines | Select-Object -First 30)
    if ($lines.Count -gt $shown.Count) { $shown += "... and $($lines.Count - $shown.Count) more - see the report." }
    if ($al.WebhookUrl) {
        $body = @(@{ type = 'TextBlock'; text = $(if ($Report.subject) { [string]$Report.subject } else { $msg.Title }); weight = 'Bolder'; size = 'Medium'; wrap = $true }) + @($shown | ForEach-Object { @{ type = 'TextBlock'; text = [string]$_; wrap = $true; spacing = 'Small' } })
        $card = @{ type = 'message'; attachments = @(@{ contentType = 'application/vnd.microsoft.card.adaptive'; contentUrl = $null
                    content = @{ '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'; type = 'AdaptiveCard'; version = '1.4'; body = $body } }) }
        $json = $card | ConvertTo-Json -Depth 12
        try {
            if ($Global:App.TestGraph) { if (-not $Global:App.TestAlerts) { $Global:App.TestAlerts = New-Object System.Collections.Generic.List[string] }; $Global:App.TestAlerts.Add($json) }
            else {
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                [void](Invoke-RestMethod -Uri $al.WebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 30 -ErrorAction Stop)
            }
            $sent.Add('Teams')
        }
        # The address is a secret: the error names the host only.
        catch { $errors.Add("Teams ($(([Uri]$al.WebhookUrl).Host)): $($_.Exception.Message)") }
    }
    if ($mail) {
        $html = if ($Report.html) { [string]$Report.html } elseif ($Report.policy) { ConvertTo-ManagedUpdateReportHtml $Report } else { '<p>' + (($shown | ForEach-Object { [System.Net.WebUtility]::HtmlEncode([string]$_) }) -join '<br>') + '</p>' }
        $mailBody = @{ message = @{ subject = $(if ($Report.subject) { [string]$Report.subject } else { $msg.Title }); body = @{ contentType = 'HTML'; content = $html }; toRecipients = @(@($al.MailTo) | ForEach-Object { @{ emailAddress = @{ address = [string]$_ } } }) }; saveToSentItems = $false }
        $from = [Uri]::EscapeDataString([string]$al.MailFrom)
        $r = Invoke-WebGraph -Permission 'Mail.Send' -Action { param($Graph) [void](& $Graph "https://graph.microsoft.com/v1.0/users/$from/sendMail" 'POST' $mailBody); $true }
        if ($r.ok) { $sent.Add('email') } else { $errors.Add("Email: $($r.error)") }
    }
    if ($sent.Count) { Write-Log "[OK] Managed updates alert sent ($($sent -join ', ')): $($msg.Title)" }
    if ($errors.Count) { Write-Log "[WARN] Managed updates alert: $($errors -join ' ')" }
    return @{ sent = $sent.ToArray(); error = ($errors -join ' ') }
}

function Global:Send-WebTestAlert {
    # Settings > Alerts > Send a test.
    $report = @{ items = @(@{ app = 'Intune App Catalog'; outcome = 'ready'; text = 'A test alert from Settings > Alerts - the next ones come after the nightly runs.' }); failed = 0; planOnly = $false }
    $r = Send-ManagedUpdateAlert $report -Force
    if ($r.error) { return @{ ok = $false; error = $r.error } }
    return @{ ok = $true; message = "Test alert sent ($(@($r.sent) -join ' and '))." }
}

function Global:ConvertTo-ManagedUpdateReportHtml {
    # Pure: a run's report as a self-contained HTML page (no scripts, no outside files).
    param($Report)
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $colors = @{ withdrawn = '#b54708'; drift = '#b54708'; health = '#b54708'; fixed = '#1b7f3b'; backup = '#475467'; report = '#175cd3'; advanced = '#1b7f3b'; promoted = '#1b7f3b'; released = '#1b7f3b'; cleaned = '#1b7f3b'; cleanup = '#175cd3'; failed = '#b42318'; hold = '#b54708'; ready = '#175cd3'; available = '#175cd3'; wait = '#475467'; current = '#475467'; none = '#475467' }
    $rows = foreach ($i in @($Report.items)) {
        $c = if ($colors.ContainsKey([string]$i.outcome)) { $colors[[string]$i.outcome] } else { '#475467' }
        "<tr><td>$(& $enc $i.app)</td><td style=""color:$c;font-weight:600"">$(& $enc $i.outcome)</td><td>$(& $enc $i.text)</td></tr>"
    }
    $p = $Report.policy
    return @"
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Managed updates $(& $enc $Report.started)</title>
<style>body{font:14px system-ui,Segoe UI,sans-serif;margin:24px;color:#101828}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:6px 10px;border-bottom:1px solid #eaecf0;vertical-align:top}th{color:#475467;font-size:12px}</style></head>
<body><h1>Managed updates</h1>
<p>$(& $enc $Report.started) to $(& $enc $Report.finished)$(if ($Report.planOnly) { ' - plan only, nothing was changed' }) - $(@($Report.items).Count) item(s), $(& $enc $Report.failed) failure(s).</p>
$(if ($Report.trend -and $null -ne $Report.trend.onCurrentPercent) { "<p>Devices on the current version: $(& $enc $Report.trend.onCurrentPercent) % of $(& $enc $Report.trend.devices).</p>" })
<p>Release rule: at least $(& $enc $p.Days) days in each ring (fast track: $(& $enc $p.FastTrackHours) hours), at most $(& $enc $p.MaxFailedPercent) % failed, at least $(& $enc $p.MinInstalled) installed. Automatic release: $(if ($p.AutoRelease) { 'on' } else { 'off' }); automatic promotion: $(if ($p.AutoPromote) { 'on' } else { 'off' }); clean-up of old versions: $(if ($p.CleanupOld) { 'on' } else { 'off' }).</p>
<table><thead><tr><th>App</th><th>Outcome</th><th>What happened</th></tr></thead><tbody>
$($rows -join "`n")
</tbody></table></body></html>
"@
}

function Global:Get-WebUpdateRuns {
    # The last runs' reports, newest first, for Settings > Managed updates.
    $dir = Join-Path (Get-AppFolder -Kind Logs) 'reports'
    $runs = @()
    if (Test-Path -LiteralPath $dir) {
        $runs = @(Get-ChildItem -LiteralPath $dir -Filter 'managed-updates-*.json' -File | Sort-Object Name -Descending | Select-Object -First 10 | ForEach-Object {
                try {
                    $r = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                    [ordered]@{ id = $_.BaseName; started = [string]$r.started; planOnly = [bool]$r.planOnly; failed = [int]$r.failed; items = @($r.items) }
                }
                catch { }
            })
    }
    $running = Test-Path -LiteralPath (Join-Path $dir 'managed-updates.lock')
    return @{ ok = $true; runs = $runs; running = [bool]$running; schedule = (Get-WebUpdateSchedule) }
}

function Global:Start-WebUpdateRun {
    # Run now (or plan only): the same run as the nightly one, in a process of its own - this page doesn't wait for it.
    param($Data)
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $script = Join-Path $Global:App.RootPath 'IntuneDeployment.ps1'
    $exe = (Get-Process -Id $PID).Path
    $runArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-RunUpdates')
    if ($Data.planOnly) { $runArgs += '-PlanOnly' }
    try {
        $start = @{ FilePath = $exe; ArgumentList = $runArgs; PassThru = $true }
        if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { $start.WindowStyle = 'Hidden' }
        $p = Start-Process @start
        Write-Log "[INFO] Managed updates run started$(if ($Data.planOnly) { ' (plan only)' }) - process $($p.Id)."
        return @{ ok = $true; pid = $p.Id }
    }
    catch { return @{ ok = $false; error = "Couldn't start the run: $($_.Exception.Message)" } }
}

function Global:Get-WebUpdateTaskName { 'Intune App Catalog - managed updates' }
function Global:Get-WebFastTrackTaskName { 'Intune App Catalog - fast-track updates' }

function Global:Get-WebUpdateSchedule {
    # The nightly scheduled task, if there is one: @{ supported; exists; runAt; user }.
    if (-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') -or -not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) { return @{ supported = $false; exists = $false } }
    $t = Get-ScheduledTask -TaskName (Get-WebUpdateTaskName) -ErrorAction SilentlyContinue
    if (-not $t) { return @{ supported = $true; exists = $false } }
    $at = @($t.Triggers | Where-Object { $_.StartBoundary } | Select-Object -First 1 | ForEach-Object { ([datetime]$_.StartBoundary).ToString('HH:mm') })
    return @{ supported = $true; exists = $true; runAt = [string]$(if ($at.Count) { $at[0] }); user = [string]$t.Principal.UserId; state = [string]$t.State }
}

function Global:Set-WebUpdateSchedule {
    <#
      Creates (or changes) the scheduled task that runs managed updates every
      night at -runAt, as the signed-in user (whose certificate store holds
      the connection's certificate), or removes it (-on false).
    #>
    param($Data)
    $now = Get-WebUpdateSchedule
    if (-not $now.supported) { return @{ ok = $false; error = 'Scheduled tasks are only available on Windows.' } }
    $name = Get-WebUpdateTaskName
    if (-not $Data.on) {
        if ($now.exists) { Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction Stop }
        if (Get-ScheduledTask -TaskName (Get-WebFastTrackTaskName) -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName (Get-WebFastTrackTaskName) -Confirm:$false -ErrorAction SilentlyContinue }
        Write-Log "[OK] Removed the scheduled task '$name'."
        return @{ ok = $true; schedule = (Get-WebUpdateSchedule) }
    }
    $runAt = [string]$Data.runAt
    if ($runAt -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { return @{ ok = $false; error = 'The time must be HH:mm (24 hours), e.g. 03:00.' } }
    $script = Join-Path $Global:App.RootPath 'IntuneDeployment.ps1'
    $exe = (Get-Process -Id $PID).Path
    try {
        $action = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -RunUpdates" -WorkingDirectory $Global:App.RootPath
        $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::ParseExact($runAt, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture))
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
        [void](Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Description 'Releases and promotes managed app updates (Intune App Catalog). Report: Logs\reports.' -Force -ErrorAction Stop)
        # Fast-track releases are judged in hours: a second task looks at only those, every two hours (quiet when there is none).
        $fastAction = New-ScheduledTaskAction -Execute $exe -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -RunUpdates -FastTrackOnly" -WorkingDirectory $Global:App.RootPath
        $fastTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddMinutes(7) -RepetitionInterval (New-TimeSpan -Hours 2)
        $fastSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
        [void](Register-ScheduledTask -TaskName (Get-WebFastTrackTaskName) -Action $fastAction -Trigger $fastTrigger -Settings $fastSettings -Description 'Promotes fast-track (urgent) app releases once they are ready (Intune App Catalog).' -Force -ErrorAction Stop)
    }
    catch { return @{ ok = $false; error = "Couldn't create the scheduled task: $($_.Exception.Message)" } }
    $Global:App.ReleasePolicy.RunAt = $runAt
    try { [void](Write-SettingsFile) } catch { }
    Write-Log "[OK] Scheduled task '$name': every day at $runAt, as $env:USERNAME."
    return @{ ok = $true; schedule = (Get-WebUpdateSchedule) }
}

# ---------------------------------------------------------------- running unattended

function Global:Get-WebUnattendedStatus {
    <#
      Can the nightly task run while nobody is signed in? It can when the
      task logs on without a password (S4U) and the certificate is in the
      computer's store (LocalMachine\My) - a task without a signed-in user
      can't use the user's own private keys. @{ supported; ready; steps }.
    #>
    $sch = Get-WebUpdateSchedule
    if (-not $sch.supported) { return @{ ok = $true; supported = $false; ready = $false; steps = @('Scheduled tasks need Windows.') } }
    $found = Get-WebConnectionCertificate
    $logon = ''
    if ($sch.exists) { try { $logon = [string](Get-ScheduledTask -TaskName (Get-WebUpdateTaskName)).Principal.LogonType } catch { } }
    $steps = New-Object System.Collections.Generic.List[object]
    $steps.Add([ordered]@{ done = [bool]$sch.exists; text = $(if ($sch.exists) { "The nightly task exists (every day at $($sch.runAt))." } else { 'Schedule the nightly task first (above).' }) })
    $inMachine = [bool]($found -and $found.Store -like '*LocalMachine*')
    $steps.Add([ordered]@{ done = $inMachine; text = $(if (-not $found) { 'The connection certificate is not on this PC.' } elseif ($inMachine) { 'The certificate is in the computer''s store (LocalMachine\My).' } else { 'The certificate is in your own store only (CurrentUser\My) - a task without a signed-in user can''t use it.' }) })
    $s4u = $logon -eq 'S4U'
    $steps.Add([ordered]@{ done = $s4u; text = $(if ($s4u) { 'The tasks run whether you are signed in or not (no password stored).' } else { "The tasks run only while you are signed in$(if ($logon) { " (logon: $logon)" })." }) })
    return @{ ok = $true; supported = $true; ready = [bool]($sch.exists -and $inMachine -and $s4u); steps = $steps.ToArray() }
}

function Global:New-WebUnattendedScript {
    <#
      Writes a script for an administrator (Logs\unattended-setup.ps1): it
      copies the connection certificate into the computer's store, lets
      this user read its private key, and sets both scheduled tasks to run
      whether the user is signed in or not (S4U - no password stored).
      Nothing here runs it: it needs "Run as administrator".
    #>
    $sch = Get-WebUpdateSchedule
    if (-not $sch.supported) { return @{ ok = $false; error = 'Scheduled tasks need Windows.' } }
    if (-not $sch.exists) { return @{ ok = $false; error = 'Schedule the nightly task first.' } }
    $thumb = ([string]$Global:App.GraphCertificateThumbprint) -replace '[^0-9A-Fa-f]', ''
    if (-not $thumb) { return @{ ok = $false; error = 'Set up the connection first.' } }
    $user = "$env:USERDOMAIN\$env:USERNAME"
    $tasks = @((Get-WebUpdateTaskName), (Get-WebFastTrackTaskName))
    $q = { param($s) ConvertTo-PsLiteral $s }
    $script = @"
# Intune App Catalog - run the nightly tasks while nobody is signed in.
# Written by the app on $((Get-Date).ToString('yyyy-MM-dd HH:mm')). Run it once, in PowerShell started with "Run as administrator".
#Requires -RunAsAdministrator
`$ErrorActionPreference = 'Stop'
`$thumb = $(& $q $thumb)
`$user = $(& $q $user)
`$tasks = @($(($tasks | ForEach-Object { & $q $_ }) -join ', '))

# 1. The certificate into the computer's store (skipped when it is there already).
if (-not (Test-Path "Cert:\LocalMachine\My\`$thumb")) {
    `$cert = Get-Item "Cert:\CurrentUser\My\`$thumb"
    `$pfx = Join-Path `$env:TEMP ("intunecat-" + [guid]::NewGuid().ToString('N') + '.pfx')
    `$pw = ConvertTo-SecureString ([guid]::NewGuid().ToString('N')) -AsPlainText -Force
    try {
        Export-PfxCertificate -Cert `$cert -FilePath `$pfx -Password `$pw | Out-Null
        Import-PfxCertificate -FilePath `$pfx -CertStoreLocation Cert:\LocalMachine\My -Password `$pw | Out-Null
    }
    catch { throw "Couldn't copy the certificate (`$(`$_.Exception.Message)). If its private key can't be exported, import the original .pfx into the computer's store (certlm.msc > Personal > Import) and run this script again." }
    finally { Remove-Item -LiteralPath `$pfx -Force -ErrorAction SilentlyContinue }
    Write-Host 'Copied the certificate to LocalMachine\My.'
}

# 2. This user may read its private key.
`$machine = Get-Item "Cert:\LocalMachine\My\`$thumb"
`$keyName = `$null
try { `$keyName = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey(`$machine).Key.UniqueName } catch { }
if (-not `$keyName) { try { `$keyName = `$machine.PrivateKey.CspKeyContainerInfo.UniqueKeyContainerName } catch { } }
`$keyFile = @("`$env:ProgramData\Microsoft\Crypto\Keys\`$keyName", "`$env:ProgramData\Microsoft\Crypto\RSA\MachineKeys\`$keyName") | Where-Object { `$keyName -and (Test-Path -LiteralPath `$_) } | Select-Object -First 1
if (`$keyFile) { icacls `$keyFile /grant "`${user}:R" | Out-Null; Write-Host "`$user may read the private key." }
else { Write-Warning "The private key file wasn't found - in certlm.msc, right-click the certificate > All Tasks > Manage Private Keys, and give `$user Read." }

# 3. The tasks run whether the user is signed in or not, without a stored password.
`$principal = New-ScheduledTaskPrincipal -UserId `$user -LogonType S4U -RunLevel Limited
foreach (`$t in `$tasks) {
    if (Get-ScheduledTask -TaskName `$t -ErrorAction SilentlyContinue) { Set-ScheduledTask -TaskName `$t -Principal `$principal | Out-Null; Write-Host "Task '`$t': runs whether `$user is signed in or not." }
}
Write-Host 'Done. Check it once: sign out, wait for the next run (or start the task from Task Scheduler), then look at Settings > Managed updates.'
"@
    # In this user's own profile - not the Logs folder, which can be a share: an administrator runs this file.
    $dir = Join-Path $(if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [System.IO.Path]::GetTempPath() }) 'IntuneAppCatalog'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $path = Join-Path $dir 'unattended-setup.ps1'
    [System.IO.File]::WriteAllText($path, $script, (New-Object System.Text.UTF8Encoding($true)))
    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    Write-Log "[INFO] Wrote $path (SHA256 $hash) - run it as administrator to let the nightly tasks run while nobody is signed in."
    return @{ ok = $true; path = $path; sha256 = $hash }
}

function Global:Get-WebHealth {
    # Settings > Managed updates > Check health now.
    return @{ ok = $true; checks = @(Get-WebHealthChecks) }
}

function Global:Set-WebManagedDefault {
    # Home > "Make managed updates the default": new Winget apps get a pinned version and the pilot ring.
    $Global:App.DefaultAppSettings.WingetInstallMethod = 'Managed'
    if (-not (Write-SettingsFile)) { return @{ ok = $false; error = "Couldn't write the settings file." } }
    Write-Log '[OK] Managed updates are the default for new Winget apps.'
    return @{ ok = $true }
}
