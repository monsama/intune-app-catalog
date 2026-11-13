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
    param([switch]$PlanOnly)
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
            $catalog = Read-WebCatalogRecords
            $managed = @($catalog.Apps | Where-Object { $_.managedUpdates -and $_.appId })
            if (-not $managed.Count) { & $say '(all)' 'none' 'No deployed app has managed updates.' }
            # The newest winget versions, for the Winget apps with nothing in pilot.
            $askWinget = @($managed | Where-Object { $_.wingetId -and -not (Get-WebAppRelease $_) })
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
                    $st = Get-WebPilotStatus $pilot
                    if (-not $st.ok) { & $say $a.appName 'failed' "$($pilot.version) in pilot - its install status couldn't be read: $($st.error)"; $failed++; continue }
                    if ($st.action -ne 'promote') { & $say $a.appName $st.action "$($pilot.version) in pilot: $($st.reason)"; continue }
                    if ($PlanOnly -or -not $policy.AutoPromote) { & $say $a.appName 'ready' "$($pilot.version) is ready for everyone: $($st.reason)$(if (-not $policy.AutoPromote) { ' Promote it (automatic promotion is off).' })"; continue }
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
                    if ($PlanOnly -or -not $policy.AutoRelease) { & $say $a.appName 'available' "winget offers $latest (now $current).$(if (-not $policy.AutoRelease) { ' Release it to pilot (automatic release is off).' })"; continue }
                    $made = Wait-WebStepJob (Start-WebRelease @{ name = $a.appName; version = $latest })
                    if (-not $made.ok) { & $say $a.appName 'failed' "Releasing $latest failed: $($made.error)"; $failed++; continue }
                    $assigned = Wait-WebStepJob (Start-WebReleaseAssign @{ name = $a.appName; step = 'pilot' })
                    if ($assigned.ok) { & $say $a.appName 'released' "$latest released to the pilot groups (now $current for everyone else)." }
                    else { & $say $a.appName 'failed' "$latest is in Intune but not assigned to pilot: $($assigned.error)"; $failed++ }
                    continue
                }
                $inst = Get-WebInstallerInfo $a.appName
                if ($inst.version -and (Compare-AppVersionText $current $inst.version) -eq 1) { & $say $a.appName 'available' "The installer in its folder is $($inst.version) (now $current) - release it from the app (own packages aren't released automatically)." }
                else { & $say $a.appName 'current' "$current - no newer installer in its folder." }
            }
        }
    }
    catch { & $say '(run)' 'failed' "The run stopped: $($_.Exception.Message)"; $failed++ }
    finally { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }

    $report = [ordered]@{ started = $started.ToString('yyyy-MM-dd HH:mm'); finished = (Get-Date).ToString('yyyy-MM-dd HH:mm'); planOnly = [bool]$PlanOnly; failed = $failed
        policy = $policy; items = $items.ToArray() }
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

function Global:ConvertTo-ManagedUpdateReportHtml {
    # Pure: a run's report as a self-contained HTML page (no scripts, no outside files).
    param($Report)
    $enc = { param($t) [System.Net.WebUtility]::HtmlEncode([string]$t) }
    $colors = @{ promoted = '#1b7f3b'; released = '#1b7f3b'; failed = '#b42318'; hold = '#b54708'; ready = '#175cd3'; available = '#175cd3'; wait = '#475467'; current = '#475467'; none = '#475467' }
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
<p>Release rule: at least $(& $enc $p.Days) days in pilot, at most $(& $enc $p.MaxFailedPercent) % failed, at least $(& $enc $p.MinInstalled) installed. Automatic release: $(if ($p.AutoRelease) { 'on' } else { 'off' }); automatic promotion: $(if ($p.AutoPromote) { 'on' } else { 'off' }).</p>
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
    }
    catch { return @{ ok = $false; error = "Couldn't create the scheduled task: $($_.Exception.Message)" } }
    $Global:App.ReleasePolicy.RunAt = $runAt
    try { [void](Write-SettingsFile) } catch { }
    Write-Log "[OK] Scheduled task '$name': every day at $runAt, as $env:USERNAME."
    return @{ ok = $true; schedule = (Get-WebUpdateSchedule) }
}
