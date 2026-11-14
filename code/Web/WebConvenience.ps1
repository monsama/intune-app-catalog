# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    Conveniences: the group picker's suggestions and check, assignment
    profiles, icons found for an app, a test install in Windows Sandbox,
    detection from an app installed on this PC, the Home page's "needs
    attention", the groups x apps grid, and a list of winget packages to
    add (a winget export file, or this PC's apps).
#>

# ---------------------------------------------------------------- group picker

function Global:Find-WebGroupSuggestions {
    <#
      Groups whose name starts with (then contains) the text: favourites
      first, then the groups the catalog uses, then Entra ID's (when
      connected). @{ ok; groups = @(@{ name; source }) }.
    #>
    param($Data)
    $q = ([string]$Data.q).Trim()
    if ($q.Length -gt 100) { return @{ ok = $false; error = 'Too long.' } }
    $seen = @{}; $out = New-Object System.Collections.Generic.List[object]
    $add = { param($n, $src) $k = ([string]$n).ToLowerInvariant(); if ($n -and -not $seen.ContainsKey($k)) { $seen[$k] = $true; $out.Add([ordered]@{ name = [string]$n; source = $src }) } }
    $rank = { param($list) @(@($list) | Where-Object { $_ -like "$q*" }) + @(@($list) | Where-Object { $_ -notlike "$q*" -and $_ -like "*$q*" }) }
    foreach ($g in & $rank @($Global:App.FavoriteGroups)) { & $add $g 'favourite' }
    $used = @((Read-WebCatalogRecords).Apps | ForEach-Object { @($_.requiredFor) + @($_.availableFor) + @($_.uninstallFor) + @($_.excludeFor) } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
    foreach ($g in & $rank $used) { & $add $g 'catalog' }
    $note = ''
    if ($q.Length -ge 2 -and (Test-GraphCredentialsConfigured -Quiet)) {
        $e = $q.Replace("'", "''")
        $read = Invoke-WebGraph -Permission 'Group.Read.All' -Action { param($Graph) @((& $Graph ("https://graph.microsoft.com/v1.0/groups?`$filter=" + [Uri]::EscapeDataString("startswith(displayName,'$e')") + '&$select=displayName&$top=20')).value | ForEach-Object { [string]$_.displayName }) }
        if ($read.ok) { foreach ($g in @($read.value)) { & $add $g 'entra' } } else { $note = "Entra ID wasn't searched: $($read.error)" }
    }
    return @{ ok = $true; groups = @($out | Select-Object -First 25); note = $note }
}

function Global:Test-WebGroupNames {
    # Which of the names aren't groups in Entra ID (pushing creates them) - only when connected. @{ ok; checked; missing }.
    param($Data)
    $names = @(@($Data.names) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique -First 200)
    if (-not $names.Count -or -not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $true; checked = $false; missing = @() } }
    $read = Invoke-WebGraph -Permission 'Group.Read.All' -Action {
        param($Graph)
        $found = @{}
        foreach ($uri in @(Get-GroupLookupUris -Names $names)) { foreach ($g in @((& $Graph $uri).value)) { $found[([string]$g.displayName).ToLowerInvariant()] = $true } }
        $found
    }
    if (-not $read.ok) { return @{ ok = $true; checked = $false; missing = @(); note = [string]$read.error } }
    return @{ ok = $true; checked = $true; missing = @($names | Where-Object { -not $read.value.ContainsKey($_.ToLowerInvariant()) }) }
}

# ---------------------------------------------------------------- icons

function Global:ConvertTo-WebPngIcon {
    # An image file (.ico, .exe's icon, .png) as a square PNG of at most 256 px, base64 - Windows only (System.Drawing). '' when it can't.
    param([string]$Path, [switch]$FromExe)
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $bmp = if ($FromExe) { ([System.Drawing.Icon]::ExtractAssociatedIcon($Path)).ToBitmap() } elseif ($Path -match '\.ico$') { (New-Object System.Drawing.Icon($Path, 256, 256)).ToBitmap() } else { [System.Drawing.Bitmap]::FromFile($Path) }
        $size = [Math]::Min(256, [Math]::Max($bmp.Width, $bmp.Height))
        $out = New-Object System.Drawing.Bitmap($size, $size)
        $gfx = [System.Drawing.Graphics]::FromImage($out); $gfx.InterpolationMode = 'HighQualityBicubic'; $gfx.DrawImage($bmp, 0, 0, $size, $size); $gfx.Dispose()
        $ms = New-Object System.IO.MemoryStream; $out.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $out.Dispose()
        return [Convert]::ToBase64String($ms.ToArray())
    }
    catch { return '' }
}

function Global:Find-WebAppIcon {
    <#
      An icon for an app, to preview in the editor: an own package's
      installer's icon (an .exe in its folder), else its homepage's own icon
      (apple-touch-icon or a PNG icon the page names - https only, at most
      1 MB). @{ ok; icon = @{ type; value }; from }.
    #>
    param($Data)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$($Data.name)'." } }
    if (-not $a.wingetId) {
        $folder = Join-Path (Get-AppFolder -Kind Packages) (Get-SafeFileNameForApp -Name $a.appName)
        $exe = Get-ChildItem -LiteralPath $folder -Filter '*.exe' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($exe) { $png = ConvertTo-WebPngIcon $exe.FullName -FromExe; if ($png) { return @{ ok = $true; icon = @{ type = 'image/png'; value = $png }; from = "the installer $($exe.Name)" } } }
    }
    $site = [string]$(if ($a.metadata) { $a.metadata.informationUrl })
    if ($site -notmatch '^https://') { return @{ ok = $false; error = 'No icon found - the app needs an https Information URL (its homepage), or an .exe in its packages folder.' } }
    if ($Global:App.TestGraph) { return @{ ok = $false; error = 'Test mode: no homepage is read.' } }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $p = @{ Uri = $site; TimeoutSec = 15; MaximumRedirection = 3; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSEdition -eq 'Desktop') { $p.UseBasicParsing = $true }
        $page = Invoke-WebRequest @p
        $base = [Uri]$site
        $cands = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches([string]$page.Content, '<link[^>]+>', 'IgnoreCase')) {
            $tag = $m.Value
            if ($tag -match 'rel\s*=\s*"?[^">]*(apple-touch-icon|icon)' -and $tag -match 'href\s*=\s*"([^"]+)"') {
                $href = $Matches[1]; $u = New-Object Uri($base, [System.Net.WebUtility]::HtmlDecode($href))
                if ($u.Scheme -eq 'https' -and $u.AbsolutePath -match '\.(png|jpe?g)$') { if ($tag -match 'apple-touch-icon') { $cands.Insert(0, $u.AbsoluteUri) } else { $cands.Add($u.AbsoluteUri) } }
            }
        }
        $cands.Add((New-Object Uri($base, '/apple-touch-icon.png')).AbsoluteUri)
        foreach ($c in @($cands | Select-Object -Unique -First 5)) {
            try {
                $p2 = @{ Uri = $c; TimeoutSec = 15; MaximumRedirection = 3; ErrorAction = 'Stop' }
                if ($PSVersionTable.PSEdition -eq 'Desktop') { $p2.UseBasicParsing = $true }
                $r = Invoke-WebRequest @p2
                $bytes = [byte[]]$r.Content
                $type = if ($bytes.Length -gt 8 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50) { 'image/png' } elseif ($bytes.Length -gt 3 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) { 'image/jpeg' } else { '' }
                if ($type -and $bytes.Length -le 750KB -and $bytes.Length -ge 200) { return @{ ok = $true; icon = @{ type = $type; value = [Convert]::ToBase64String($bytes) }; from = $c } }
            }
            catch { }
        }
    }
    catch { return @{ ok = $false; error = "The homepage couldn't be read: $($_.Exception.Message)" } }
    return @{ ok = $false; error = "No PNG icon found on $site." }
}

# ---------------------------------------------------------------- detection from an app on this PC

function Global:Get-WebInstalledApps {
    # The apps Windows lists on this PC (Uninstall keys: 64-bit, 32-bit, the user's), for "detection from an installed app".
    if (-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')) { return @{ ok = $true; apps = @(); note = 'Only on Windows.' } }
    $hives = @(@{ H = 'HKLM'; P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' }, @{ H = 'HKLM-WOW'; P = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' }, @{ H = 'HKCU'; P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' })
    $list = foreach ($h in $hives) {
        foreach ($e in @(Get-ItemProperty -Path $h.P -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName })) {
            [ordered]@{ name = [string]$e.DisplayName; version = [string]$e.DisplayVersion; publisher = [string]$e.Publisher; key = [string]$e.PSChildName; hive = $h.H }
        }
    }
    return @{ ok = $true; apps = @($list | Sort-Object { $_.name }) }
}

function Global:Get-WebDetectionFromInstalled {
    # The detection rule for one installed app (ConvertTo-DetectionFromInstalled), in the editor's form.
    param($Data)
    $hive = switch ([string]$Data.hive) { 'HKCU' { 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' } 'HKLM-WOW' { 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall' } default { 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall' } }
    $key = [string]$Data.key
    if ($key -notmatch '^[^\\/:*?"<>|]{1,200}$') { return @{ ok = $false; error = 'Not an installed app.' } }
    $e = Get-ItemProperty -LiteralPath (Join-Path $hive $key) -ErrorAction SilentlyContinue
    if (-not $e) { return @{ ok = $false; error = "It isn't listed any more." } }
    $exe = $null
    $icon = ([string]$e.DisplayIcon -replace ',\s*-?\d+$', '').Trim('"', ' ')
    $cand = if ($icon -match '\.exe$' -and $icon -notmatch 'unins|uninst|setup|installer') { $icon } elseif ($e.InstallLocation) { @(Get-ChildItem -LiteralPath ([string]$e.InstallLocation) -Filter '*.exe' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'unins|uninst|setup|update|crash' } | Sort-Object Length -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }) | Select-Object -First 1 } else { $null }
    if ($cand -and (Test-Path -LiteralPath $cand)) { $v = ([string](Get-Item -LiteralPath $cand).VersionInfo.FileVersion).Trim() -replace ',\s*', '.' -replace '\s.*$', ''; if ($v) { $exe = @{ Path = [string]$cand; Version = $v } } }
    $d = ConvertTo-DetectionFromInstalled @{ Key = $key; WindowsInstaller = $e.WindowsInstaller; DisplayVersion = $e.DisplayVersion; Hive = [string]$Data.hive; MainExe = $exe }
    $r = $d.Rule
    $form = [ordered]@{ type = $r.Type; productCode = [string]$r.Msi_ProductCode; operator = [string]$(if ($r.Msi_VersionOperator) { $r.Msi_VersionOperator } elseif ($r.File_Operator) { $r.File_Operator } else { $r.Reg_Operator })
        value = [string]$(if ($r.Type -eq 'Msi') { $r.Msi_Version } elseif ($r.Type -eq 'File') { $r.File_DetectionValue } else { $r.Reg_DetectionValue })
        path = [string]$r.File_Path; name = [string]$r.File_Name; keyPath = [string]$r.Reg_KeyPath; valueName = [string]$r.Reg_ValueName
        check32Bit = [bool]$(if ($r.Type -eq 'Registry') { $r.Reg_Check32Bit } else { $false }); detectionType = [string]$(if ($r.Type -eq 'File') { $r.File_DetectionType } elseif ($r.Type -eq 'Registry') { $r.Reg_DetectionType } else { '' }) }
    return @{ ok = $true; detection = $form; text = $d.Text }
}

# ---------------------------------------------------------------- a test install in Windows Sandbox

function Global:Start-WebSandboxTest {
    <#
      Tests an own package (or script app) in Windows Sandbox: its folder
      is copied into a test folder with run.ps1, which installs it with the
      app's install command, checks the detection rule, uninstalls it and
      checks again, writing result.json. A .wsb file maps the folder and
      runs it. @{ ok; id; folder }. Winget apps can't be tested this way
      (the Sandbox has no winget).
    #>
    param($Data)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$($Data.name)'." } }
    if ($a.wingetId) { return @{ ok = $false; error = "Windows Sandbox has no winget, so a Winget app can't be tested there - test it on a pilot device (managed updates)." } }
    $m = $a.metadata
    if (-not $m -or -not $m.installCommand -or -not $m.detectionRule) { return @{ ok = $false; error = 'The app needs an install command and a detection rule first (the editor).' } }
    $sb = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
    if (-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') -or -not (Test-Path -LiteralPath $sb)) { return @{ ok = $false; error = 'Windows Sandbox isn''t turned on here: Windows Features > Windows Sandbox (Windows Pro or Enterprise), then restart.' } }
    $src = Join-Path (Get-AppFolder -Kind Packages) (Get-SafeFileNameForApp -Name $a.appName)
    if (-not (Test-Path -LiteralPath $src)) { return @{ ok = $false; error = "The app's packages folder ($src) doesn't exist." } }
    $id = (Get-Date).ToString('yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    $root = Join-Path (Join-Path (Get-AppFolder -Kind Logs -Create) 'sandbox') $id
    $pkg = Join-Path $root 'package'
    [void](New-Item -ItemType Directory -Path $pkg -Force)
    Copy-Item -Path (Join-Path $src '*') -Destination $pkg -Recurse -Force
    # 64-bit inside the Sandbox: sysnative (for Intune's 32-bit agent) is System32 here.
    $fix = { param($c) ([string]$c) -replace '(?i)%SystemRoot%\\sysnative\\', '%SystemRoot%\System32\' }
    $q = { param($s) "'" + ([string]$s).Replace("'", "''") + "'" }
    $detect = ConvertTo-DetectionTestScript $m.detectionRule
    $run = @"
# Test of $($a.appName) in Windows Sandbox - written by Intune App Catalog.
`$out = 'C:\Test'
`$log = Join-Path `$out 'log.txt'
function Say(`$t) { Add-Content -LiteralPath `$log -Value ((Get-Date).ToString('HH:mm:ss') + ' ' + `$t) }
function Detected { try { [bool](& { $detect }) } catch { Say "Detection failed: `$(`$_.Exception.Message)"; `$false } }
function Run(`$cmd) { Say "Running: `$cmd"; `$p = Start-Process -FilePath cmd.exe -ArgumentList '/c', `$cmd -WorkingDirectory (Join-Path `$out 'package') -Wait -PassThru -WindowStyle Hidden; Say "Exit code `$(`$p.ExitCode)"; `$p.ExitCode }
`$r = [ordered]@{ before = Detected }
`$r.installExit = Run $(& $q (& $fix $m.installCommand))
Start-Sleep -Seconds 5
`$r.detectedAfterInstall = Detected
`$r.uninstallExit = $(if ($m.uninstallCommand) { "Run $(& $q (& $fix $m.uninstallCommand))" } else { '$null' })
Start-Sleep -Seconds 5
`$r.detectedAfterUninstall = Detected
`$r | ConvertTo-Json | Set-Content -LiteralPath (Join-Path `$out 'result.json') -Encoding UTF8
Say 'Done - you can close the Sandbox.'
"@
    [System.IO.File]::WriteAllText((Join-Path $root 'run.ps1'), $run, (New-Object System.Text.UTF8Encoding($true)))
    $wsb = @"
<Configuration>
  <MappedFolders><MappedFolder><HostFolder>$([System.Security.SecurityElement]::Escape($root))</HostFolder><SandboxFolder>C:\Test</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder></MappedFolders>
  <LogonCommand><Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Test\run.ps1</Command></LogonCommand>
  <Networking>Enable</Networking>
</Configuration>
"@
    $wsbPath = Join-Path $root 'test.wsb'
    [System.IO.File]::WriteAllText($wsbPath, $wsb, (New-Object System.Text.UTF8Encoding($false)))
    try { Start-Process -FilePath $sb -ArgumentList "`"$wsbPath`"" | Out-Null }
    catch { return @{ ok = $false; error = "Windows Sandbox didn't start: $($_.Exception.Message)" } }
    Write-Log "[INFO] Testing $($a.appName) in Windows Sandbox ($root)."
    return @{ ok = $true; id = $id; folder = $root }
}

function Global:Get-WebSandboxResult {
    # How a Sandbox test went: running (no result yet), or the result with the log.
    param($Data)
    $id = [string]$Data.id
    if ($id -notmatch '^\d{8}-\d{6}-[0-9a-f]{4}$') { return @{ ok = $false; error = 'Unknown test.' } }
    $root = Join-Path (Join-Path (Get-AppFolder -Kind Logs) 'sandbox') $id
    $log = if (Test-Path -LiteralPath (Join-Path $root 'log.txt')) { Get-Content -LiteralPath (Join-Path $root 'log.txt') -Raw } else { '' }
    $file = Join-Path $root 'result.json'
    if (-not (Test-Path -LiteralPath $file)) { return @{ ok = $true; done = $false; log = $log } }
    $r = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    $okInstall = ($r.installExit -in 0, 1707, 3010, 1641) -and $r.detectedAfterInstall
    $okUninstall = ($null -eq $r.uninstallExit) -or (($r.uninstallExit -in 0, 1605, 3010, 1641) -and -not $r.detectedAfterUninstall)
    return @{ ok = $true; done = $true; log = $log; result = $r; passed = [bool]($okInstall -and $okUninstall)
        verdict = @($(if (-not $okInstall) { if ($r.installExit -notin 0, 1707, 3010, 1641) { "The install command ended with exit code $($r.installExit)." } else { 'It installed, but the detection rule doesn''t find it.' } }),
            $(if (-not $okUninstall) { if ($r.uninstallExit -notin 0, 1605, 3010, 1641) { "The uninstall command ended with exit code $($r.uninstallExit)." } else { 'After the uninstall, the detection rule still finds it.' } })) -join ' ' }
}

# ---------------------------------------------------------------- Home: what needs attention

function Global:Get-WebAttention {
    <#
      The Home page: what needs a look, each with where to fix it. Reads
      the catalog, the packages, the last nightly run and the certificate -
      and, when connected, the Updates page's counts.
    #>
    $items = New-Object System.Collections.Generic.List[object]
    $add = { param($level, $title, $text, $go) $items.Add([ordered]@{ level = $level; title = $title; text = $text; go = $go }) }
    $configured = [bool](Test-GraphCredentialsConfigured -Quiet)
    if (-not $configured) { & $add 'warn' 'Not connected' 'Set up the connection to Intune to deploy and to see install counts.' 'settings:connection' }
    elseif (-not $Global:App.TestGraph) {
        $c = Get-WebConnectionCertificate
        $h = Get-CertificateHealth -NotAfter $(if ($c) { $c.Cert.NotAfter } else { $null }) -Now (Get-Date)
        if ($h.Level -ne 'ok') { & $add $(if ($h.Level -eq 'failed') { 'err' } else { 'warn' }) 'Certificate' $h.Text 'settings:connection' }
    }
    $apps = @((Read-WebCatalogRecords).Apps)
    $notDeployed = @($apps | Where-Object { -not $_.appId })
    if ($notDeployed.Count) { & $add 'info' "$($notDeployed.Count) app(s) not deployed yet" ((@($notDeployed | Select-Object -First 5 | ForEach-Object { $_.appName }) -join ', ') + $(if ($notDeployed.Count -gt 5) { ', ...' })) 'apps:notdeployed' }
    $noPkg = @($apps | Where-Object { -not $_.wingetId -and -not $_.appId -and -not (Resolve-AppPackagePath -AppName $_.appName -Uncommon $true -PackagePath $_.packagePath).Found })
    if ($noPkg.Count) { & $add 'warn' "$($noPkg.Count) own package(s) not built" ((@($noPkg | Select-Object -First 5 | ForEach-Object { $_.appName }) -join ', ') + ' - select them and use Package.') 'apps:all' }
    # Managed updates as the way apps are kept current: the default, every Winget app, and each with its version.
    if ([string]$Global:App.DefaultAppSettings.WingetInstallMethod -ne 'Managed') { & $add 'info' 'Managed updates aren''t the default yet' "New Winget apps install winget's latest version without a pilot ring ($($Global:App.DefaultAppSettings.WingetInstallMethod))." 'do:manageddefault' }
    $unmanaged = @($apps | Where-Object { $_.wingetId -and -not $_.managedUpdates })
    if ($unmanaged.Count) { & $add 'info' "$($unmanaged.Count) Winget app(s) without managed updates" ((@($unmanaged | Select-Object -First 5 | ForEach-Object { $_.appName }) -join ', ') + $(if ($unmanaged.Count -gt 5) { ', ...' }) + " - they install winget's latest, untested, and Intune can't tell which version a device has.") 'do:managedall' }
    $noVersion = @($apps | Where-Object { $_.wingetId -and $_.managedUpdates -and -not ($_.metadata -and [string]$_.metadata.appVersion) })
    if ($noVersion.Count) { & $add 'warn' "$($noVersion.Count) managed app(s) without a version yet" ((@($noVersion | Select-Object -First 5 | ForEach-Object { $_.appName }) -join ', ') + " - take winget's current version as the one they start from$(if (@($noVersion | Where-Object { $_.appId }).Count) { ', then Deploy the ones in Intune again (it updates them)' }).") 'do:takeversions' }
    $managedWinget = @($apps | Where-Object { $_.wingetId -and $_.managedUpdates })
    if ($managedWinget.Count -and -not (Test-Path -LiteralPath (Get-SharedPackagePath))) { & $add 'warn' 'Shared Winget package missing' 'Build init.intunewin - Winget apps can''t be deployed without it.' 'settings:packaging' }
    $runs = Get-WebUpdateRuns
    $last = @($runs.runs) | Select-Object -First 1
    if ($last -and $last.failed) { & $add 'err' "The last nightly run had $($last.failed) problem(s)" ((@($last.items | Where-Object { $_.outcome -eq 'failed' } | Select-Object -First 3 | ForEach-Object { "$($_.app): $($_.text)" }) -join ' / ')) 'settings:defaults' }
    $drift = @($last.items | Where-Object { $_.outcome -eq 'drift' })
    if ($drift.Count) { & $add 'warn' "$($drift.Count) app(s) differ from Intune" ((@($drift | Select-Object -First 5 | ForEach-Object { $_.app }) -join ', ') + ' (last night) - Checks has the details.') 'checks' }
    if (@($apps | Where-Object { $_.managedUpdates }).Count -and -not (Get-WebUpdateSchedule).exists -and (Get-WebUpdateSchedule).supported) { & $add 'info' 'Nightly run not scheduled' 'Managed updates only move when someone clicks - schedule the nightly run.' 'settings:defaults' }
    $summary = $null
    if ($configured -and @($apps | Where-Object { $_.managedUpdates }).Count) {
        try {
            $ov = Get-WebUpdatesOverview -NoInventory
            if ($ov.ok) {
                $summary = $ov.summary
                if ($ov.summary.held) { & $add 'err' "$($ov.summary.held) release(s) on hold" ((@($ov.rows | Where-Object { $_.pilot -and $_.pilot.action -eq 'hold' } | ForEach-Object { $_.name }) -join ', ') + ' - too many devices failed.') 'updates' }
                if ($ov.summary.ready) { & $add 'ok' "$($ov.summary.ready) release(s) ready to go on" ((@($ov.rows | Where-Object { $_.pilot -and $_.pilot.action -in 'promote', 'advance' } | ForEach-Object { "$($_.name) $($_.pilot.version)" }) -join ', ')) 'updates' }
                if ($ov.summary.available) { & $add 'info' "$($ov.summary.available) newer version(s) available" ((@($ov.rows | Where-Object { $_.available -and -not $_.pilot } | ForEach-Object { "$($_.name) $($_.available)" }) -join ', ')) 'updates' }
                $failing = @($ov.rows | Where-Object { [int]$_.failed -gt 0 })
                if ($failing.Count) { & $add 'warn' "Failed installs on $(($failing | ForEach-Object { [int]$_.failed } | Measure-Object -Sum).Sum) device(s)" ((@($failing | Select-Object -First 5 | ForEach-Object { "$($_.name) ($($_.failed))" }) -join ', ')) 'updates' }
            }
        }
        catch { }
    }
    $order = @{ err = 0; warn = 1; ok = 2; info = 3 }
    return @{ ok = $true; items = @($items | Sort-Object { $order[$_.level] }); apps = $apps.Count; deployed = @($apps | Where-Object { $_.appId }).Count
        managed = @($apps | Where-Object { $_.managedUpdates }).Count; summary = $summary; lastRun = $(if ($last) { $last.started } else { '' }) }
}

# ---------------------------------------------------------------- groups x apps

function Global:Get-WebAssignmentMatrix {
    # Every app and the groups it's assigned to, by role - the grid's data.
    $apps = @((Read-WebCatalogRecords).Apps | Sort-Object { $_.appName })
    $groups = @($apps | ForEach-Object { @($_.requiredFor) + @($_.availableFor) + @($_.uninstallFor) + @($_.excludeFor) } | Where-Object { $_ } | Select-Object -Unique | Sort-Object)
    return @{ ok = $true; groups = $groups
        apps = @($apps | ForEach-Object { [ordered]@{ name = $_.appName; deployed = [bool]$_.appId; required = @($_.requiredFor); available = @($_.availableFor); uninstall = @($_.uninstallFor); exclude = @($_.excludeFor) } }) }
}

function Global:Set-WebAssignments {
    <#
      The grid's changes: @(@{ name; group; role = required|available|
      uninstall|exclude|'' }) - the group leaves every role of that app and,
      unless role is '', joins that one. One Undo for all. Intune changes
      with Push groups.
    #>
    param($Data)
    $changes = @($Data.changes | Where-Object { $_ } | Select-Object -First 2000)
    if (-not $changes.Count) { return @{ ok = $false; error = 'Nothing to change.' } }
    $fields = @{ required = 'requiredFor'; available = 'availableFor'; uninstall = 'uninstallFor'; exclude = 'excludeFor' }
    foreach ($c in $changes) {
        $problem = Test-WebGroupName ([string]$c.group); if ($problem) { return @{ ok = $false; error = $problem } }
        if ([string]$c.role -and -not $fields.ContainsKey([string]$c.role)) { return @{ ok = $false; error = "Unknown role '$($c.role)'." } }
    }
    $undo = New-WebUndo "Assignments grid ($($changes.Count) change(s))"
    $byApp = $changes | Group-Object { [string]$_.name }
    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($g in $byApp) {
        $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $g.Name } | Select-Object -First 1
        if (-not $a) { continue }
        foreach ($c in $g.Group) {
            $grp = ([string]$c.group).Trim()
            foreach ($f in $fields.Values) { $a.$f = @(@($a.$f) | Where-Object { $_ -and $_ -ne $grp }) }
            if ([string]$c.role) { $f = $fields[[string]$c.role]; $a.$f = @(@($a.$f) + $grp) }
        }
        Write-WebAppFile -App $a -Undo $undo
        $changed.Add($a.appName)
    }
    Save-WebUndo $undo
    Write-Log "[OK] Assignments grid: $($changes.Count) change(s) to $($changed.Count) app(s)."
    return @{ ok = $true; apps = $changed.ToArray() }
}

# ---------------------------------------------------------------- a list of winget packages to add

function Global:Read-WebPackageList {
    <#
      Winget packages to add from a list: a "winget export" file's text
      (-json), or this PC's own apps (-thisPc: winget export run here).
      Each with whether the catalog has it. @{ ok; items = @(@{ id; inCatalog }) }.
    #>
    param($Data)
    $json = [string]$Data.json
    if ($Data.thisPc) {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("winget-export-" + [guid]::NewGuid().ToString('N') + ".json")
        try {
            $r = Invoke-Winget -Arguments @('export', '-o', $tmp, '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds 180
            if (-not (Test-Path -LiteralPath $tmp)) { return @{ ok = $false; error = "winget export didn't write a list (exit code $($r.ExitCode))." } }
            $json = Get-Content -LiteralPath $tmp -Raw
        }
        catch { return @{ ok = $false; error = $_.Exception.Message } }
        finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    if ($json.Length -gt 5MB) { return @{ ok = $false; error = 'That file is too large.' } }
    $p = ConvertFrom-WingetExportJson $json
    if ($p.Error) { return @{ ok = $false; error = $p.Error } }
    $have = @{}; foreach ($a in @((Read-WebCatalogRecords).Apps | Where-Object { $_.wingetId })) { $have[([string]$a.wingetId).ToLowerInvariant()] = [string]$a.appName }
    return @{ ok = $true; items = @($p.Ids | ForEach-Object { $k = $_.ToLowerInvariant(); [ordered]@{ id = $_; inCatalog = $(if ($have.ContainsKey($k)) { $have[$k] } else { '' }) } }) }
}
