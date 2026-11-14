# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    Views of the whole connected tenant: what setting up a tenant from the
    catalog still needs, every app's install status at once, app icons
    (from the catalog and from Intune), and the history of one app's file.
#>

# ---------------------------------------------------------------- set up a tenant

function Global:Get-WebTenantSetup {
    <#
      What the connected tenant still lacks for the catalog, in the order to
      do it: App IDs the tenant doesn't know (copied from another tenant),
      groups Entra ID doesn't have, apps not deployed, and deployed apps
      whose groups to push. Reads only.
    #>
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $apps = @((Read-WebCatalogRecords).Apps)
    $tenant = Get-WebIntuneApps @{ force = $true }
    if (-not $tenant.ok) { return @{ ok = $false; error = "Couldn't read the apps in Intune: $($tenant.error)" } }
    $ids = @{}; foreach ($i in @($tenant.ids)) { $ids[[string]$i] = $true }
    $groups = Get-WebGroupsStatus
    $missingGroups = @()
    $groupsNote = ''
    if ($groups.state -eq 'ok') {
        $found = @{}; foreach ($f in @($groups.found)) { $found[([string]$f.name).ToLowerInvariant()] = $true }
        $missingGroups = @(Get-WebCatalogGroupNames -Apps $apps | Where-Object { -not $found.ContainsKey(([string]$_).ToLowerInvariant()) })
    }
    else { $groupsNote = "Entra ID couldn't be asked: $($groups.error)" }
    $stale = @($apps | Where-Object { $_.appId -and -not $ids.ContainsKey(([string]$_.appId).ToLowerInvariant()) } | ForEach-Object { $_.appName })
    $notDeployed = @($apps | Where-Object { -not $_.appId } | ForEach-Object { $_.appName })
    $deployed = @($apps | Where-Object { $_.appId -and $ids.ContainsKey(([string]$_.appId).ToLowerInvariant()) })
    $withGroups = @($deployed | Where-Object { @(@($_.requiredFor) + @($_.availableFor) + @($_.uninstallFor) + @($_.excludeFor) | Where-Object { $_ }).Count } | ForEach-Object { $_.appName })
    # What Deploy would say about the apps not in Intune: ready, or why not (no package, no detection rule, the shared Winget package missing).
    $notReady = @()
    $sharedMissing = $false
    if ($notDeployed.Count) {
        $plan = Get-WebDeployPlan @{ names = $notDeployed }
        if ($plan.ok) {
            $notReady = @($plan.apps | Where-Object { -not $_.ready } | ForEach-Object { [ordered]@{ name = [string]$_.name; reason = [string]$_.reason } })
            $sharedMissing = [bool](@($notReady | Where-Object { $_.reason -like '*init.intunewin*' }).Count)
        }
    }
    return @{ ok = $true; apps = $apps.Count; stale = $stale; missingGroups = $missingGroups; groupsNote = $groupsNote
        notDeployed = $notDeployed; notReady = $notReady; sharedMissing = $sharedMissing; deployed = @($deployed | ForEach-Object { $_.appName }); pushGroups = $withGroups }
}

# ---------------------------------------------------------------- install status of every app

function Global:Get-WebInstallCounts {
    <#
      Install counts (devices) for Intune apps by App ID: the apps install
      summary report once, then each app the report doesn't list from its
      own installSummary. Runs inside Invoke-WebGraph (-Graph is its call).
      @{ Counts = @{ id -> @{ installed; failed; pending; notInstalled; notApplicable } or $null }; Note }.
    #>
    param([scriptblock]$Graph, [string[]]$Ids)
    $byId = @{}
    $note = ''
    try {
        $skip = 0
        while ($true) {
            $body = @{ select = @('ApplicationId', 'DisplayName', 'InstalledDeviceCount', 'FailedDeviceCount', 'PendingInstallDeviceCount', 'NotInstalledDeviceCount', 'NotApplicableDeviceCount'); skip = $skip; top = 500 }
            $page = & $Graph 'https://graph.microsoft.com/beta/deviceManagement/reports/getAppsInstallSummaryReport' 'POST' $body
            $rows = @(ConvertFrom-GraphReportTable $page)
            foreach ($r in $rows) { if ($r.ApplicationId) { $byId[([string]$r.ApplicationId).ToLowerInvariant()] = $r } }
            if ($rows.Count -lt 500 -or $skip -ge 5000) { break }
            $skip += 500
        }
    }
    catch { $note = "The summary report wasn't available ($(Get-InnermostErrorMessage $_.Exception)) - read app by app." }
    $counts = @{}
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($raw in @($Ids | Where-Object { $_ } | Select-Object -Unique)) {
        $id = ([string]$raw).ToLowerInvariant()
        $r = $byId[$id]
        if ($r) { $counts[$id] = @{ installed = [int]$r.InstalledDeviceCount; failed = [int]$r.FailedDeviceCount; pending = [int]$r.PendingInstallDeviceCount; notInstalled = [int]$r.NotInstalledDeviceCount; notApplicable = [int]$r.NotApplicableDeviceCount } }
        else { $missing.Add($id) }
    }
    # The ones the report doesn't list: their installSummary, 20 to a $batch call.
    if ($missing.Count) {
        $batch = @{}
        try { $batch = Invoke-WebGraphBatch -Graph $Graph -Requests @($missing | ForEach-Object { @{ id = $_; url = "/deviceAppManagement/mobileApps/$_/installSummary" } }) } catch { $batch = @{} }
        foreach ($id in $missing) {
            $one = $batch[$id]
            if ($one -and $one.status -eq 200 -and $one.body) {
                $sum = $one.body
                $counts[$id] = @{ installed = [int]$sum.installedDeviceCount; failed = [int]$sum.failedDeviceCount; pending = [int]$sum.pendingInstallDeviceCount; notInstalled = [int]$sum.notInstalledDeviceCount; notApplicable = [int]$sum.notApplicableDeviceCount }
            }
            else { $counts[$id] = $null }
        }
    }
    return @{ Counts = $counts; Note = $note }
}

function Global:Get-WebInstallOverview {
    <#
      Install counts for every deployed catalog app at once: installed,
      failed, pending, not installed, not applicable (devices).
    #>
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $apps = @((Read-WebCatalogRecords).Apps | Where-Object { $_.appId })
    if (-not $apps.Count) { return @{ ok = $true; rows = @(); note = 'No app in the catalog is in Intune yet.' } }
    $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) Get-WebInstallCounts -Graph $Graph -Ids @($apps | ForEach-Object { [string]$_.appId }) }
    if (-not $read.ok) { return $read }
    $rows = foreach ($a in $apps) {
        $id = ([string]$a.appId).ToLowerInvariant()
        $c = $read.value.Counts[$id]
        [ordered]@{ name = [string]$a.appName; appId = $id; known = ($null -ne $c)
            installed = $(if ($c) { $c.installed } else { 0 }); failed = $(if ($c) { $c.failed } else { 0 }); pending = $(if ($c) { $c.pending } else { 0 })
            notInstalled = $(if ($c) { $c.notInstalled } else { 0 }); notApplicable = $(if ($c) { $c.notApplicable } else { 0 }) }
    }
    return @{ ok = $true; rows = @($rows); note = [string]$read.value.Note; at = (Get-Date).ToString('HH:mm') }
}

function Global:Get-WebUpdatesOverview {
    <#
      The Updates page: every app with managed updates - its current
      version and how many devices have it, the version in pilot and what
      the release rule says, the newest version available (winget, or the
      installer in an own package's folder), the superseded versions, the
      devices Intune's inventory finds with an older version - and totals
      over all of them. -NoInventory: without the inventory (the nightly
      run's trend needs only the counts).
    #>
    param([switch]$NoInventory)
    $all = @((Read-WebCatalogRecords).Apps)
    $managed = @($all | Where-Object { $_.managedUpdates })
    $connected = [bool](Test-GraphCredentialsConfigured -Quiet)
    $counts = @{}; $note = ''; $older = @{}; $invNote = ''
    if ($connected -and $managed.Count) {
        $ids = @($managed | ForEach-Object { $_.appId; (Get-WebAppRelease $_).appId } | Where-Object { $_ })
        if ($ids.Count) {
            $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) Get-WebInstallCounts -Graph $Graph -Ids $ids }
            if ($read.ok) { $counts = $read.value.Counts; $note = [string]$read.value.Note } else { $note = "Install counts couldn't be read: $($read.error)" }
        }
        if (-not $NoInventory) {
            $deployed = @($managed | Where-Object { $_.appId -and $_.metadata -and $_.metadata.appVersion })
            if ($deployed.Count) {
                $inv = Invoke-WebGraph -Permission 'DeviceManagementManagedDevices.Read.All' -Action { param($Graph) Get-WebOlderOnDevices -Graph $Graph -Apps $deployed }
                if ($inv.ok) { if ($inv.value -is [hashtable]) { $older = $inv.value } } else { $invNote = "Older versions on devices couldn't be read: $($inv.error)" }
            }
        }
    }
    $gateApps = if ($Global:App.ReleasePolicy.GatePath) { Read-WebCatalogFolder $Global:App.ReleasePolicy.GatePath } else { $null }
    $rows = foreach ($a in $managed) {
        $current = [string]$(if ($a.metadata) { $a.metadata.appVersion })
        $curKey = ([string]$a.appId).ToLowerInvariant()
        $cur = if ($a.appId) { $counts[$curKey] } else { $null }
        $pilot = Get-WebAppRelease $a
        $pilotKey = if ($pilot) { ([string]$pilot.appId).ToLowerInvariant() } else { '' }
        $pc = if ($pilot) { $counts[$pilotKey] } else { $null }
        $decision = if ($pilot -and $pc) { Get-WebReleaseDecision -App $a -Pilot $pilot -Counts $pc } else { $null }
        # On hold: why the devices failed, from the install status report.
        if ($decision -and $decision.Action -eq 'hold' -and -not $NoInventory) { $why = Get-WebHoldReason $pilot; if ($why) { $decision.Reason = "$($decision.Reason) Why: $why" } }
        $gateText = ''
        if ($null -ne $gateApps -and $a.wingetId) { $gateText = (Get-GateVersion -App $a -GateApps $gateApps).Reason }
        $nameKey = [string]$a.appName
        $rings = @(Get-WebReleaseRings)
        $ringNo = if ($pilot) { [Math]::Min([int]$pilot.ring, $rings.Count - 1) } else { 0 }
        $available = ''
        if ($a.wingetId) {
            $wKey = ([string]$a.wingetId).ToLowerInvariant()
            $latest = if ($Global:App.WingetLatest) { [string]$Global:App.WingetLatest[$wKey] } else { '' }
            if ($latest -and (Compare-AppVersionText $current $latest) -eq 1) { $available = $latest }
        }
        else {
            $inst = Get-WebInstallerInfo $a.appName
            if ($inst.version -and (Compare-AppVersionText $current $inst.version) -eq 1) { $available = $inst.version }
        }
        $tried = if ($cur) { $cur.installed + $cur.failed + $cur.pending + $cur.notInstalled } else { 0 }
        [ordered]@{ name = [string]$a.appName; kind = $(if ($a.wingetId) { 'winget' } else { 'package' }); deployed = [bool]$a.appId; current = $current
            installed = $(if ($cur) { $cur.installed } else { $null }); failed = $(if ($cur) { $cur.failed } else { $null }); pending = $(if ($cur) { $cur.pending } else { $null })
            notInstalled = $(if ($cur) { $cur.notInstalled } else { $null }); onCurrentPercent = $(if ($tried) { [Math]::Round(100.0 * $cur.installed / $tried, 1) } else { $null })
            pilot = $(if ($pilot) { [ordered]@{ version = [string]$pilot.version; at = [string]$pilot.at; installed = $(if ($pc) { $pc.installed } else { $null }); failed = $(if ($pc) { $pc.failed } else { $null }); pending = $(if ($pc) { $pc.pending } else { $null })
                        action = $(if ($decision) { $decision.Action } else { '' }); reason = $(if ($decision) { $decision.Reason } else { '' })
                        fastTrack = [bool]$pilot.fastTrack; ring = $ringNo; ringCount = $rings.Count; ringName = [string]$rings[$ringNo].Name } } else { $null })
            ownRule = [bool]$a.releaseRule; autoRelease = [bool]$a.autoRelease; gate = $gateText
            older = $(if ($older.ContainsKey($nameKey)) { $older[$nameKey] } else { $null })
            available = $available; previous = @(Get-WebPreviousReleases $a | ForEach-Object { [string]$_.version }) }
    }
    $rows = @($rows)
    $withCounts = @($rows | Where-Object { $null -ne $_.installed })
    $installed = ($withCounts | ForEach-Object { [int]$_.installed } | Measure-Object -Sum).Sum
    $total = ($withCounts | ForEach-Object { [int]$_.installed + [int]$_.failed + [int]$_.pending + [int]$_.notInstalled } | Measure-Object -Sum).Sum
    $olderDevices = (@($rows | Where-Object { $_.older } | ForEach-Object { [int]$_.older.devices }) | Measure-Object -Sum).Sum
    return @{ ok = $true; connected = $connected; note = (@($note, $invNote) | Where-Object { $_ }) -join ' '; at = (Get-Date).ToString('HH:mm'); rows = $rows
        rings = @(Get-WebReleaseRings | ForEach-Object { [ordered]@{ name = $_.Name; groups = @($_.Groups) } }); inventory = [bool]($connected -and -not $NoInventory -and -not $invNote)
        notManaged = @($all | Where-Object { -not $_.managedUpdates }).Count
        summary = [ordered]@{ managed = $rows.Count; inPilot = @($rows | Where-Object { $_.pilot }).Count
            ready = @($rows | Where-Object { $_.pilot -and $_.pilot.action -eq 'promote' }).Count; held = @($rows | Where-Object { $_.pilot -and $_.pilot.action -eq 'hold' }).Count
            available = @($rows | Where-Object { $_.available -and -not $_.pilot }).Count
            onCurrentPercent = $(if ($total) { [Math]::Round(100.0 * $installed / $total, 1) } else { $null }); devices = [int]$total; olderDevices = [int]$olderDevices } }
}

function Global:Get-WebOlderOnDevices {
    <#
      Intune's inventory of apps on devices (detectedApps) for each managed
      app - by its name on devices (detectedName, else the catalog's name),
      the entries whose version is older than the app's current one: those
      devices still have an old version, whether Intune installed it or
      someone did by hand. Runs inside Invoke-WebGraph.
      @{ appName -> @{ devices; versions = @(@{ version; devices }) } }.
    #>
    param([scriptblock]$Graph, $Apps)
    $out = @{}
    $list = @($Apps)
    $relUrl = { param($a) $n = if ($a.detectedName) { [string]$a.detectedName } else { [string]$a.appName }
        "/deviceManagement/detectedApps?`$filter=" + [Uri]::EscapeDataString("startswith(displayName,'" + $n.Replace("'", "''") + "')") + "&`$select=id,displayName,version,deviceCount&`$top=999" }
    # Every app's first page in $batch calls of 20; further pages (rare) one by one.
    $first = Invoke-WebGraphBatch -Graph $Graph -Requests @(for ($k = 0; $k -lt $list.Count; $k++) { @{ id = "$k"; url = (& $relUrl $list[$k]) } })
    for ($k = 0; $k -lt $list.Count; $k++) {
        $a = $list[$k]
        $name = if ($a.detectedName) { [string]$a.detectedName } else { [string]$a.appName }
        $current = [string]$a.metadata.appVersion
        $found = New-Object System.Collections.Generic.List[object]
        $one = $first["$k"]
        # A missing permission is everyone's problem - said once, by the caller; anything else skips just this app.
        if ($one.status -in 401, 403) { throw "$($one.status) Forbidden: $(if ($one.body -and $one.body.error) { $one.body.error.message } else { 'no permission to read the inventory of apps on devices' })" }
        if ($one.status -ne 200 -or -not $one.body) { continue }
        foreach ($d in @($one.body.value)) { if ($d) { $found.Add($d) } }
        $uri = [string]$one.body.'@odata.nextLink'; $pages = 1
        try {
            while ($uri -and $pages -lt 10) {
                $page = & $Graph $uri
                foreach ($d in @($page.value)) { if ($d) { $found.Add($d) } }
                $uri = [string]$page.'@odata.nextLink'; $pages++
            }
        }
        catch { if ("$($_.Exception.Message)" -match '^(401|403)\b') { throw } }
        $byVersion = @{}
        # The name itself, or followed by a version or "(x64)" - not "<name> Meeting Add-in", another product.
        $same = '^' + [regex]::Escape($name) + '(\s+(v?\d[\w.\-]*|\([^)]*\)))*\s*$'
        foreach ($d in $found) {
            if ([string]$d.displayName -notmatch $same) { continue }
            $v = ([string]$d.version).Trim()
            if (-not $v -or (Compare-AppVersionText $v $current) -ne 1) { continue }
            $byVersion[$v] = [int]$byVersion[$v] + [int]$d.deviceCount
        }
        if ($byVersion.Count) {
            $versions = @($byVersion.Keys | Sort-Object { $byVersion[$_] } -Descending | ForEach-Object { [ordered]@{ version = $_; devices = $byVersion[$_] } })
            $appKey = [string]$a.appName
            $out[$appKey] = [ordered]@{ devices = ($byVersion.Values | Measure-Object -Sum).Sum; versions = $versions }
        }
    }
    return $out
}

function Global:Get-WebUpdatesTrend {
    <#
      The Updates page's trend: from the nightly runs' reports (the last 60
      are kept), the share of devices on the current version - one point a
      day (that day's last run), overall and per app.
    #>
    $dir = Join-Path (Get-AppFolder -Kind Logs) 'reports'
    $byDay = [ordered]@{}
    if (Test-Path -LiteralPath $dir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'managed-updates-*.json' -File | Sort-Object Name)) {
            try { $r = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if (-not $r.trend -or $null -eq $r.trend.onCurrentPercent) { continue }
            $day = ([string]$r.started).Substring(0, [Math]::Min(10, ([string]$r.started).Length))
            $byDay[$day] = [ordered]@{ day = $day; percent = [double]$r.trend.onCurrentPercent; devices = [int]$r.trend.devices
                apps = @(@($r.trend.apps) | ForEach-Object { [ordered]@{ app = [string]$_.app; version = [string]$_.version; percent = [double]$_.percent } }) }
        }
    }
    return @{ ok = $true; points = @($byDay.Values | Select-Object -Last 30) }
}

# ---------------------------------------------------------------- icons

function Global:Get-WebAppIcons {
    # The icons of the named apps (or all), as data: addresses for the page - only apps that have one.
    param($Data)
    $names = @($Data.names | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $out = @{}
    foreach ($a in @((Read-WebCatalogRecords).Apps)) {
        if ($names.Count -and $names -notcontains $a.appName) { continue }
        if ($a.icon -and $a.icon.value) { $out[[string]$a.appName] = "data:$($a.icon.type);base64,$($a.icon.value)" }
    }
    return @{ ok = $true; icons = $out }
}

function Global:Get-WebIntuneIcon {
    # One app's icon as Intune has it (largeIcon is only returned when asked for by name).
    param($Data)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a -or -not $a.appId) { return @{ ok = $false; error = "$($Data.name) isn't in Intune (no App ID)." } }
    $id = [string]$a.appId
    $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) & $Graph "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$id`?`$select=id,largeIcon" }
    if (-not $read.ok) { return $read }
    $icon = ConvertTo-AppIcon $read.value.largeIcon
    if (-not $icon) { return @{ ok = $false; error = "Intune has no icon for $($a.appName) (or not as PNG or JPEG)." } }
    return @{ ok = $true; icon = @{ type = $icon.type; value = $icon.value } }
}

# ---------------------------------------------------------------- history of one app

function Global:Get-WebAppFieldTexts {
    # Pure: one app record as field -> text, for comparing two versions of it.
    param($App)
    $o = [ordered]@{}
    if (-not $App) { return $o }
    foreach ($k in 'appName', 'appId', 'wingetId', 'requiredFor', 'availableFor', 'uninstallFor', 'excludeFor') { $o[$k] = Get-WebBatchValueText $App.$k }
    $o['icon'] = $(if ($App.icon -and $App.icon.value) { "$($App.icon.type), $([int]($App.icon.value.Length * 3 / 4 / 1024)) KB" } else { '' })
    if ($App.metadata) {
        foreach ($p in $App.metadata.PSObject.Properties) {
            $v = $p.Value
            $o[$p.Name] = if ($p.Name -eq 'detectionRule' -or $p.Name -eq 'supersedes') { if ($null -eq $v) { '' } else { ($v | ConvertTo-Json -Depth 6 -Compress) } } else { Get-WebBatchValueText $v }
        }
    }
    return $o
}

function Global:Compare-WebAppVersions {
    # Pure: the fields that differ between two versions of an app, as { field; old; new }.
    param($Old, $New)
    $a = Get-WebAppFieldTexts $Old; $b = Get-WebAppFieldTexts $New
    $keys = @(@($a.Keys) + @($b.Keys) | Select-Object -Unique)
    return @(foreach ($k in $keys) {
        $x = [string]$a[$k]; $y = [string]$b[$k]
        if ($x -cne $y) { [ordered]@{ field = $k; old = $x; new = $y } }
    })
}

function Global:Get-WebAppVersionCompare {
    <#
      One kept copy of an app next to the app as it is now, field by field
      (-id from Get-WebAppBackups), and what the save right after that
      copy changed (-id against the next newer copy, or now).
    #>
    param($Data)
    $list = Get-WebAppBackups $Data
    if (-not $list.ok) { return $list }
    $ids = @($list.backups | ForEach-Object { $_.id })
    $i = [array]::IndexOf($ids, [string]$Data.id)
    if ($i -lt 0) { return @{ ok = $false; error = 'That is not a backup of this app.' } }
    $root = Get-AppFolder -Kind Backups
    $read = { param($id) ConvertTo-AppRecord (Get-Content -LiteralPath (Join-Path $root ($id -replace '/', [IO.Path]::DirectorySeparatorChar)) -Raw -Encoding UTF8 | ConvertFrom-Json) }
    try { $old = & $read $ids[$i] } catch { return @{ ok = $false; error = "That copy can't be read: $($_.Exception.Message)" } }
    $now = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    # Backups are newest first: the copy kept by the next save is at $i - 1.
    $after = if ($i -gt 0) { try { & $read $ids[$i - 1] } catch { $null } } else { $now }
    return @{ ok = $true; when = $list.backups[$i].when; versusNow = @(Compare-WebAppVersions $old $now); thatSave = @(Compare-WebAppVersions $old $after) }
}

function Global:Get-WebInventorySuggestions {
    <#
      Apps worth adding to the catalog: Intune's inventory of apps on
      devices (detectedApps, up to 20 pages of 999), grouped by name, on at
      least three devices, minus the catalog's own apps and parts of
      Windows (Get-InventorySuggestions).
    #>
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    $read = Invoke-WebGraph -Permission 'DeviceManagementManagedDevices.Read.All' -Action {
        param($Graph)
        $all = New-Object System.Collections.Generic.List[object]
        $uri = 'https://graph.microsoft.com/beta/deviceManagement/detectedApps?$select=id,displayName,version,deviceCount&$top=999'
        $pages = 0
        while ($uri -and $pages -lt 20) { $page = & $Graph $uri; foreach ($d in @($page.value)) { if ($d) { $all.Add($d) } }; $uri = [string]$page.'@odata.nextLink'; $pages++ }
        @{ Items = $all.ToArray(); More = [bool]$uri }
    }
    if (-not $read.ok) { return $read }
    $s = @(Get-InventorySuggestions -Detected @($read.value.Items) -Apps @((Read-WebCatalogRecords).Apps))
    return @{ ok = $true; suggestions = $s; scanned = @($read.value.Items).Count; more = [bool]$read.value.More }
}
