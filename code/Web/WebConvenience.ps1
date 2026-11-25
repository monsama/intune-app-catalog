# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    Conveniences: the group picker's suggestions and check, assignment
    profiles, icons found for an app,
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
    # Intune's own targets first when the text fits them (the picker leaves them out of Excluded).
    foreach ($b in '[All users]', '[All devices]') { if (-not $q -or $b -like "*$q*") { & $add $b 'built-in' } }
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
    # All users / All devices are Intune's own targets - never "missing" from Entra ID.
    $names = @(@($Data.names) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and -not (Get-AllTargetInfo $_) } | Select-Object -Unique -First 200)
    if (-not $names.Count -or -not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $true; checked = $false; missing = @() } }
    $read = Invoke-WebGraph -Permission 'Group.Read.All' -Action {
        param($Graph)
        $found = @{}
        foreach ($uri in @(Get-GroupLookupUris -Names $names)) { foreach ($g in @((& $Graph $uri).value)) { $found[([string]$g.displayName).ToLowerInvariant()] = $true } }
        $found
    }
    if (-not $read.ok) { return @{ ok = $true; checked = $false; missing = @(); note = [string]$read.error } }
    $missing = @($names | Where-Object { -not $read.value.ContainsKey($_.ToLowerInvariant()) })
    # A name that's only written differently (spacing, dash, &) is almost always meant to be the existing group - say which one.
    $close = [ordered]@{}
    foreach ($m in @($missing | Select-Object -First 5)) {
        # The leading letters and digits only: "SG-Sales" must also find "SG Sales" and "SG–Sales".
        $prefix = [regex]::Match($m, '^[\p{L}\p{N}]+').Value
        if ($prefix.Length -lt 2) { continue }
        $e = $prefix.Replace("'", "''")
        $near = Invoke-WebGraph -Permission 'Group.Read.All' -Action { param($Graph) @((& $Graph ("https://graph.microsoft.com/v1.0/groups?`$filter=" + [Uri]::EscapeDataString("startswith(displayName,'$e')") + '&$select=displayName&$top=999')).value | ForEach-Object { [string]$_.displayName }) }
        if ($near.ok) { $hit = Get-ClosestGroupName -Name $m -Candidates @($near.value); if ($hit) { $close[$m] = $hit } }
    }
    return @{ ok = $true; checked = $true; missing = $missing; close = $close }
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
        $exe = Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -eq '.exe' } | Select-Object -First 1
        if ($exe) { $png = ConvertTo-WebPngIcon $exe.FullName -FromExe; if ($png) { return @{ ok = $true; icon = @{ type = 'image/png'; value = $png }; from = "the installer $($exe.Name)" } } }
    }
    $site = [string]$(if ($a.metadata) { $a.metadata.informationUrl })
    if ($site -notmatch '^https://') { return @{ ok = $false; error = 'No icon found - the app needs an https Information URL (its homepage), or an .exe in its packages folder.' } }
    if ($Global:App.TestGraph) { return @{ ok = $false; error = 'Test mode: no homepage is read.' } }
    try {
        # https only, a megabyte at most - the page and each icon (Invoke-WebHttpsGet).
        $html = [System.Text.Encoding]::UTF8.GetString((Invoke-WebHttpsGet -Uri $site -MaxBytes 1MB -TimeoutSec 15 -PublicOnly))
        $base = [Uri]$site
        $cands = New-Object System.Collections.Generic.List[string]
        foreach ($m in [regex]::Matches($html, '<link[^>]+>', 'IgnoreCase')) {
            $tag = $m.Value
            if ($tag -match 'rel\s*=\s*"?[^">]*(apple-touch-icon|icon)' -and $tag -match 'href\s*=\s*"([^"]+)"') {
                $href = $Matches[1]; $u = New-Object Uri($base, [System.Net.WebUtility]::HtmlDecode($href))
                if ($u.Scheme -eq 'https' -and $u.AbsolutePath -match '\.(png|jpe?g)$') { if ($tag -match 'apple-touch-icon') { $cands.Insert(0, $u.AbsoluteUri) } else { $cands.Add($u.AbsoluteUri) } }
            }
        }
        $cands.Add((New-Object Uri($base, '/apple-touch-icon.png')).AbsoluteUri)
        foreach ($c2 in @($cands | Select-Object -Unique -First 5)) {
            try {
                $bytes = [byte[]](Invoke-WebHttpsGet -Uri $c2 -MaxBytes 750KB -TimeoutSec 15 -PublicOnly)
                $type = if ($bytes.Length -gt 8 -and $bytes[0] -eq 0x89 -and $bytes[1] -eq 0x50) { 'image/png' } elseif ($bytes.Length -gt 3 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) { 'image/jpeg' } else { '' }
                if ($type -and $bytes.Length -ge 200) { return @{ ok = $true; icon = @{ type = $type; value = [Convert]::ToBase64String($bytes) }; from = $c2 } }
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
    return (ConvertTo-WebDetectionForm $d)
}

function Global:ConvertTo-WebDetectionForm {
    # A detection rule from ConvertTo-DetectionFromInstalled, in the editor's form: @{ ok; detection; text }.
    param($d)
    $r = $d.Rule
    $form = [ordered]@{ type = $r.Type; productCode = [string]$r.Msi_ProductCode; operator = [string]$(if ($r.Msi_VersionOperator) { $r.Msi_VersionOperator } elseif ($r.File_Operator) { $r.File_Operator } else { $r.Reg_Operator })
        value = [string]$(if ($r.Type -eq 'Msi') { $r.Msi_Version } elseif ($r.Type -eq 'File') { $r.File_DetectionValue } else { $r.Reg_DetectionValue })
        path = [string]$r.File_Path; name = [string]$r.File_Name; keyPath = [string]$r.Reg_KeyPath; valueName = [string]$r.Reg_ValueName
        check32Bit = [bool]$(if ($r.Type -eq 'Registry') { $r.Reg_Check32Bit } else { $false }); detectionType = [string]$(if ($r.Type -eq 'File') { $r.File_DetectionType } elseif ($r.Type -eq 'Registry') { $r.Reg_DetectionType } else { '' }) }
    return @{ ok = $true; detection = $form; text = $d.Text }
}

# ---------------------------------------------------------------- Home: what needs attention

function Global:Get-WebShortGraphError {
    <#
      Home's one line for a failed step (2.38.12): Graph's raw "404 Not Found: {"error":{"code":...,"message":"..."}}"
      as "404 Not Found - <its message>", not a page of JSON. Other text stays as it is.
    #>
    param([string]$Text)
    if ($Text -notmatch '^(?<head>[^{]*?)\s*:?\s*(?<json>\{.*\})\s*$') { return $Text }
    $head = $Matches.head.Trim().TrimEnd(':').Trim(); $msg = ''
    try { $j = $Matches.json | ConvertFrom-Json; $msg = [string]$j.error.message; if (-not $msg) { $msg = [string]$j.error.code } } catch { }
    if ($msg.Length -gt 160) { $msg = $msg.Substring(0, 157) + '...' }
    if (-not $head) { return $(if ($msg) { $msg } else { $Text }) }
    return $(if ($msg) { "$head - $msg" } else { $head })
}

function Global:Get-WebAttention {
    <#
      The Home page: what needs a look, each with where to fix it. Reads
      the catalog, the packages, the last nightly run and the certificate -
      and, when connected, the Updates page's counts.
      -Data.part: 'local' - everything but Intune's install counts (fast, Home
      shows it at once); 'intune' - only those (items + summary), kept for
      45 seconds unless -Data.fresh. Neither: all of it (the nightly run).
    #>
    param($Data)
    $part = [string]$(if ($Data) { $Data.part })
    if ($part -eq 'intune') { return (Get-WebAttentionIntune -Fresh ([bool]$(if ($Data) { $Data.fresh }))) }
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
    # A page hit a permission the app registration doesn't have (Invoke-WebGraph notes it; it goes once a call works).
    if ($Global:App.MissingPermissions -and $Global:App.MissingPermissions.Count) {
        $miss = @($Global:App.MissingPermissions.Keys | Sort-Object)
        & $add 'warn' "Missing API permission$(if ($miss.Count -gt 1) { 's' }): $($miss -join ', ')" "Microsoft Graph refused a request for lack of it (last at $(@($Global:App.MissingPermissions.Values | Sort-Object)[-1])). Add it to the app registration (Settings > Connection, In Entra ID: Add required permissions..., on the server the Entra setup script) and grant admin consent - Diagnostics > Check permissions lists every one." 'settings:permissions'
    }
    # Winget apps whose Intune details are still empty (publisher, description, information link): Fill in details does it.
    # Not those whose remaining gaps winget was asked about already and doesn't have (same Winget ID).
    $askedDetails = Read-WebDetailsAsked
    $bare = @($apps | Where-Object {
            if (-not $_.wingetId -or (Test-StoreProductId ([string]$_.wingetId))) { return $false }   # Store apps: winget has no details for them (2.38.23)
            $gaps = @(Get-WebDetailsGaps -App $_ -Fill $null)
            if (-not $gaps.Count) { return $false }
            $k = $askedDetails[[string]$_.appName]
            -not ($k -and $k.id -eq [string]$_.wingetId -and -not @($gaps | Where-Object { @($k.missing) -notcontains $_ }).Count)
        })
    if ($bare.Count) { & $add 'info' "$($bare.Count) app(s) with details missing" ((@($bare | Select-Object -First 5 | ForEach-Object { $_.appName }) -join ', ') + $(if ($bare.Count -gt 5) { ', ...' } else { '' }) + " - no publisher, description or information link yet. winget knows them: fill them in (only empty fields, never the version).") 'do:filldetails' }
    if ($notDeployed.Count) { & $add 'info' "$($notDeployed.Count) app(s) not in Intune yet" ((@($notDeployed | Select-Object -First 5 | ForEach-Object { $_.appName }) -join ', ') + $(if ($notDeployed.Count -gt 5) { ', ...' })) 'apps:notdeployed' }
    # winget.exe answers in Windows' display language; its text is read in several languages, but Microsoft's WinGet module is exact in all of them.
    if (-not $Global:App.TestGraph -and @($apps | Where-Object { $_.wingetId -and -not (Test-StoreProductId ([string]$_.wingetId)) }).Count -and (Get-UICulture).TwoLetterISOLanguageName -ne 'en' -and (Get-Command winget.exe -ErrorAction SilentlyContinue) -and -not (Test-WingetClientModule)) {
        & $add 'info' 'Install the WinGet PowerShell module' "Windows here isn't in English, so winget's answers are read from translated text. For exact answers in any language, install Microsoft's WinGet module (for your user only, from the PowerShell Gallery) - Install it does it." 'do:wingetmodule'
    }
    # Winget-AutoUpdate is no longer used (2.19): apps still relying on it are switched to managed updates.
    $wau = @($apps | Where-Object { @(Get-WauUse $_).Count })
    if ($wau.Count) { & $add 'warn' "$($wau.Count) app(s) still use Winget-AutoUpdate" ((@($wau | Select-Object -First 5 | ForEach-Object { $_.appName }) -join ', ') + " - this catalog no longer uses WAU. Switch them to $(if ([string]$Global:App.DefaultAppSettings.WingetInstallMethod -eq 'Winget') { 'the winget command' } else { 'managed updates: a fixed version, released to the pilot groups first' }), and send the new commands to Intune.") 'do:wauswitch' }
    $wauApp = @($apps | Where-Object { (Test-WauAppName $_.appName) -or (Test-WauAppName $_.wingetId) })
    if ($wauApp.Count) {
        # Retire needs it in Intune; one only in the catalog is simply removed (devices that have WAU from elsewhere: uninstall it there).
        $wauText = if ($wauApp[0].appId) { "Managed updates replace it. Once no app uses it any more, take it off the devices: select $($wauApp[0].appName) on Apps, then More > Retire (it's uninstalled where it was assigned)." }
        else { "Managed updates replace it, and it isn't in Intune from this catalog - remove it from the catalog (select it on Apps, then More > Remove from catalog). If devices have WAU from elsewhere, uninstall it there." }
        & $add 'info' 'Winget-AutoUpdate is still in the catalog' $wauText 'apps:all'
    }
    # Microsoft's own app types (Company Portal, Microsoft 365 Apps, Store apps) have no package to build - said apart, not as "not built".
    # Not yet in Intune - or Company Portal linked without its Store ID (2.38.20: the button sets that too).
    $builtIn = @($apps | Where-Object { (-not $_.appId -or (-not $_.wingetId -and (Test-CompanyPortalName $_.appName))) -and (Get-NonPackageAppHint $_) })
    $noPkg = @($apps | Where-Object { -not $_.wingetId -and -not $_.appId -and -not $_.office -and -not (Get-NonPackageAppHint $_) -and -not (Resolve-AppPackagePath -AppName $_.appName -Uncommon $true -PackagePath $_.packagePath).Found })
    if ($noPkg.Count) { & $add 'warn' "$($noPkg.Count) own package(s) not built" ((@($noPkg | Select-Object -First 5 | ForEach-Object { $_.appName }) -join ', ') + ' - select them and use Build package (More).') 'apps:all' }
    # Company Portal can be fixed here (its Store ID); Microsoft 365 Apps by its editor (Installs from > Microsoft 365).
    $portal = @($builtIn | Where-Object { -not $_.wingetId -and (Test-CompanyPortalName $_.appName) })
    if ($builtIn.Count) { & $add 'info' "$($builtIn.Count) Microsoft app(s) that aren't packages" ((@($builtIn | Select-Object -First 3 | ForEach-Object { Get-NonPackageAppHint $_ }) -join ' ') + $(if ($portal.Count) { ' The button sets Company Portal up as the Store app.' } else { '' })) $(if ($portal.Count) { 'do:portalstore' } else { 'apps:all' }) }
    # Managed updates as the way apps are kept current: the default, every Winget app, and each with its version.
    if ([string]$Global:App.DefaultAppSettings.WingetInstallMethod -ne 'Managed') { & $add 'info' 'Managed updates aren''t the default yet' "New Winget apps install winget's latest version without a pilot ring ($($Global:App.DefaultAppSettings.WingetInstallMethod))." 'do:manageddefault' }
    # Not Store apps (the Store updates them) nor Winget-AutoUpdate itself (retired, not managed).
    # Nor apps that update themselves (2.38.40): winget's latest is the right choice for them, not something to fix.
    $unmanaged = @($apps | Where-Object { $_.wingetId -and -not $_.managedUpdates -and -not (Test-StoreProductId ([string]$_.wingetId)) -and -not (Test-WauAppName $_.appName) -and -not (Test-WauAppName $_.wingetId) -and -not (Test-AppUpdatesItself $_) })
    if ($unmanaged.Count) { & $add 'info' "$($unmanaged.Count) Winget app(s) without managed updates" ((@($unmanaged | Select-Object -First 5 | ForEach-Object { $_.appName }) -join ', ') + $(if ($unmanaged.Count -gt 5) { ', ...' }) + " - they install winget's latest, untested, and Intune can't tell which version a device has.") 'do:managedall' }
    $noVersion = @($apps | Where-Object { $_.wingetId -and $_.managedUpdates -and -not ($_.metadata -and [string]$_.metadata.appVersion) })
    if ($noVersion.Count) { & $add 'warn' "$($noVersion.Count) managed app(s) without a version yet" ((@($noVersion | Select-Object -First 5 | ForEach-Object { $_.appName }) -join ', ') + " - take winget's current version as the one they start from$(if (@($noVersion | Where-Object { $_.appId }).Count) { ', then Deploy the ones in Intune again (it updates them)' }).") 'do:takeversions' }
    # Pinned versions whose download is gone (the last check): new devices can't install them.
    $dlChecks = Get-WebDownloadChecks
    $dlGone = @($apps | Where-Object { $_.managedUpdates -and $_.wingetId -and $_.metadata -and [string]$_.metadata.appVersion } | Where-Object { $dc = $dlChecks["$($_.wingetId)|$([string]$_.metadata.appVersion)"]; $dc -and [string]$dc.status -in 'gone', 'notinwinget' })
    if ($dlGone.Count) { & $add 'err' "$($dlGone.Count) app(s) can't be installed on new devices" ((@($dlGone | Select-Object -First 5 | ForEach-Object { "$($_.appName) $([string]$_.metadata.appVersion)" }) -join ', ') + ' - winget no longer offers the version Intune installs (it keeps only recent ones). The nightly run releases the current one to pilot by itself; to do it now, Release new version on the Updates page.') 'updates' }
    $managedWinget = @($apps | Where-Object { $_.wingetId -and $_.managedUpdates })
    if ($managedWinget.Count -and -not (Test-Path -LiteralPath (Get-SharedPackagePath))) { & $add 'warn' 'Shared Winget package missing' 'Build init.intunewin - Winget apps can''t be deployed without it.' 'settings:packaging' }
    $runs = Get-WebUpdateRuns
    # The last full nightly run (2.38.32) - a fast-track or plan-only run said nothing about drift, and Home lost it.
    $last = @($runs.runs | Where-Object { -not $_.fastTrack -and -not $_.planOnly }) | Select-Object -First 1
    if ($last -and $last.failed) { & $add 'err' "The last nightly run had $($last.failed) problem(s)" ((@($last.items | Where-Object { $_.outcome -eq 'failed' } | Select-Object -First 3 | ForEach-Object { $t = Get-WebShortGraphError ([string]$_.text); if ($_.app -eq '(all)') { $t } else { "$($_.app): $t" } }) -join ' / ')) 'settings:automation' }
    $drift = @($last.items | Where-Object { $_.outcome -eq 'drift' })
    # 2.38.28: an app Checks compared since that run, and found as the catalog says, isn't "differs" any more - Home showed
    # last night's finding until the next night, while Checks (the same comparison, later) found nothing.
    if ($drift.Count) {
        # Read into a copy (2.38.31): loading into the shared table could put back older entries while a check is saving.
        $audit = @{}
        try { if ($Global:App.LastAuditCachePath -and (Test-Path -LiteralPath $Global:App.LastAuditCachePath)) { $raw = Get-Content -LiteralPath $Global:App.LastAuditCachePath -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($pr in @($raw.PSObject.Properties)) { $audit[$pr.Name] = $pr.Value } } } catch { }
        $runAt = [datetime]::MinValue; try { if ($last.started) { $runAt = ([datetime]$last.started).ToUniversalTime() } } catch { }
        $drift = @($drift | Where-Object {
                $e = $audit[[string]$_.app]
                if (-not $e -or -not $e.Timestamp) { return $true }
                $at = [datetime]::MinValue; try { $at = ([datetime]$e.Timestamp).ToUniversalTime() } catch { }
                $clean = -not @(@($e.Metadata, $e.Groups, $e.Dependencies, $e.Unknown) | Where-Object { $null -ne $_ -and [string]$_ -ne 'OK' -and [string]$_ -ne '' }).Count
                -not ($at -gt $runAt -and $clean)
            })
    }
    if ($drift.Count) { & $add 'warn' "$($drift.Count) app(s) differ from Intune" ((@($drift | Select-Object -First 5 | ForEach-Object { $_.app }) -join ', ') + ' (last night) - Checks has the details.') 'checks' }
    $sch = Get-WebUpdateSchedule
    # Scheduled, but no run for a day and a half: the PC was off, the task didn't start, or it can't sign in.
    $lastAt = [DateTimeOffset]::MinValue
    # The nightly task's own runs: not the fast-track checks (every 2 hours while a fix is in pilot) nor a plan-only click.
    $lastNightly = @($runs.runs | Where-Object { -not $_.fastTrack -and -not $_.planOnly }) | Select-Object -First 1
    if ($sch.exists -and $lastNightly -and [DateTimeOffset]::TryParse([string]$lastNightly.started, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$lastAt) -and ([DateTimeOffset]::Now - $lastAt).TotalHours -gt 36) {
        & $add 'warn' 'The nightly run hasn''t run lately' "The last run started $([int]([DateTimeOffset]::Now - $lastAt).TotalDays) day(s) ago, though it is scheduled every day - the computer may have been off, or the task couldn't start (Settings > Automation shows the schedule; Run now tries it)." 'settings:automation'
    }
    if (@($apps | Where-Object { $_.managedUpdates }).Count -and -not $sch.exists -and $sch.supported) { & $add 'info' 'Nightly run not scheduled' 'Managed updates only move when someone clicks - schedule the nightly run.' 'settings:automation' }
    $summary = $null
    if ($part -ne 'local') { $i = Get-WebAttentionIntune -Fresh $true; foreach ($x in @($i.items)) { $items.Add($x) }; $summary = $i.summary }
    # Getting started: the setup steps in order - Home shows them until every one is done.
    $tool = Get-PackagingToolPath
    $setup = @(
        [ordered]@{ done = $configured; title = 'Connect to Intune'; text = 'The app registration, its certificate and a test sign-in.'; go = 'settings:connection' }
        # Packaging is a step only when there is something to do: IntuneWinAppUtil.exe chosen and not here. The shared
        # Winget package builds itself (Initialize-SharedWingetPackage) - no step for it.
        $(if ((Get-PackagerChoice) -eq 'tool' -and -not ($tool -and (Test-Path -LiteralPath $tool))) { [ordered]@{ done = $false; title = 'Packaging'; text = 'IntuneWinAppUtil.exe is chosen and not here - download it, or switch to the built-in packager (Settings > Packaging).'; go = 'settings:packaging' } })
        [ordered]@{ done = [bool]@($Global:App.PilotGroups).Count; title = 'Choose the pilot groups'; text = 'A few test devices that get new versions first.'; go = 'settings:updates' }
        [ordered]@{ done = [bool]$apps.Count; title = 'Add your first apps'; text = 'From winget, an installer or a script - or the apps already in Intune (Checks).'; go = 'add' }
        [ordered]@{ done = [bool]@($apps | Where-Object { $_.appId }).Count; title = 'Send them to Intune'; text = 'Select apps on the Apps page and Send to Intune.'; go = 'apps:notdeployed' }
        [ordered]@{ done = [bool]($sch.exists -or -not $sch.supported); title = 'Schedule the nightly run'; text = 'It releases, promotes and checks by itself.'; go = 'settings:automation' }
    ) | Where-Object { $_ }
    $upd = Get-WebAppUpdate
    if ($upd.ok -and $upd.newer) { & $add 'info' "Intune App Catalog $($upd.version) is out (you have $($Global:App.AppVersion))" $(if ($upd.notes) { $upd.notes } else { 'See what is new on GitHub.' }) 'open:release' }
    $order = @{ err = 0; warn = 1; ok = 2; info = 3 }
    return @{ ok = $true; items = @($items | Sort-Object { $order[$_.level] }); setup = $setup; refused = @($(if ($Global:App.MissingPermissions) { @($Global:App.MissingPermissions.Keys | Sort-Object) })); apps = $apps.Count; deployed = @($apps | Where-Object { $_.appId }).Count
        managed = @($apps | Where-Object { $_.managedUpdates }).Count; summary = $summary; connected = $configured; lastRun = $(if ($last) { ConvertTo-WebIsoTime $last.started } else { '' }) }
}

function Global:Get-WebAttentionIntune {
    <#
      Home's part that asks Intune: the release and install counts (Get-WebUpdatesOverview without the inventory) as
      Home items. The slow part of Home - kept for 45 seconds (Home refreshes every minute and after each change);
      a finished step or -Fresh reads it again.
    #>
    param([bool]$Fresh)
    # Also new as soon as the catalog changes (any app's file) or winget's newest versions were read again.
    $folder = Get-AppFolder -Kind Catalog
    $sig = ((@(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)|$($_.LastWriteTimeUtc.Ticks)|$($_.Length)" })) -join ';') + "|w$(if ($Global:App.WingetLatest) { $Global:App.WingetLatest.Count })"
    $c = $Global:App.HomeIntuneCache
    if (-not $Fresh -and $c -and $c.Sig -eq $sig -and ([DateTime]::UtcNow - $c.At).TotalSeconds -lt 45) { return $c.Value }
    $items = New-Object System.Collections.Generic.List[object]
    $add = { param($level, $title, $text, $go) $items.Add([ordered]@{ level = $level; title = $title; text = $text; go = $go }) }
    $configured = [bool](Test-GraphCredentialsConfigured -Quiet)
    $apps = @((Read-WebCatalogRecords).Apps)
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
    # Graph permissions the catalog uses but the app registration lacks (2.38.6) - the same report as Settings >
    # Diagnostics > Check permissions, so Getting started doesn't call the connection done while a page can't work.
    $permMissing = @()
    if ($configured -and (-not $Global:App.TestGraph -or $Global:App.TestGraph.Answers.PSObject.Properties['TOKEN roles'])) {
        try {
            $pc = Get-WebPermissionCheck
            # Not those Graph already refused - Home says those (Missing API permission) with when it happened.
            $refused = @($(if ($Global:App.MissingPermissions) { @($Global:App.MissingPermissions.Keys) }))
            if ($pc.ok) { $permMissing = @($pc.rows | Where-Object { $_.status -in 'missing', 'partly' -and $refused -notcontains [string]$_.name }) }
        }
        catch { }
    }
    if ($permMissing.Count) {
        & $add 'warn' "$($permMissing.Count) Graph permission(s) missing" (((@($permMissing | ForEach-Object { "$($_.name) ($($_.for))" })) -join '; ') +
            ' - in Entra ID: Add required permissions... adds them (Settings > Connection; on the server: Entra setup script...).') 'settings:permissions'
    }
    $order = @{ err = 0; warn = 1; ok = 2; info = 3 }
    $value = @{ ok = $true; items = @($items | Sort-Object { $order[$_.level] }); summary = $summary; permMissing = @($permMissing | ForEach-Object { [string]$_.name }) }
    $Global:App.HomeIntuneCache = @{ At = [DateTime]::UtcNow; Sig = $sig; Value = $value }
    return $value
}

# ---------------------------------------------------------------- groups x apps

function Global:Get-WebAssignmentMatrix {
    # Every app and the groups it's assigned to, by role - the grid's data.
    $apps = @((Read-WebCatalogRecords).Apps | Sort-Object { $_.appName })
    # Plain strings, once each whatever the case - as the apps grid counts them.
    $set = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $apps) { foreach ($g in @(@($a.requiredFor) + @($a.availableFor) + @($a.uninstallFor) + @($a.excludeFor))) { if ($g -and ([string]$g).Trim()) { [void]$set.Add(([string]$g).Trim()) } } }
    $groups = [string[]]@($set)
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
        $problem = Test-WebGroupName ([string]$c.group) -Role ([string]$c.role); if ($problem) { return @{ ok = $false; error = $problem } }
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
    # The starter set (2.38.0): the apps most organisations deploy - each with its name, category and why.
    if ($Data.starter) {
        $all = @((Read-WebCatalogRecords).Apps)
        $have = @{}; foreach ($a in @($all | Where-Object { $_.wingetId })) { $have[([string]$a.wingetId).ToLowerInvariant()] = [string]$a.appName }
        # Microsoft's own two (2.38.21) are in the catalog by what they are, not only by an ID: Company Portal linked
        # without its Store ID, Microsoft 365 Apps with its settings or by its name.
        $cp = @($all | Where-Object { Test-CompanyPortalName ([string]$_.appName) }) | Select-Object -First 1
        if ($cp -and -not $have.ContainsKey('9wzdncrfj3pz')) { $have['9wzdncrfj3pz'] = [string]$cp.appName }
        # By name only the suite itself (2.38.23) - not "Office Timeline" or another app that starts with the word.
        $o365 = @($all | Where-Object { $_.office -or (-not $_.wingetId -and ([string]$_.appName).Trim() -match '^(Microsoft 365( Apps)?|Office 365|Microsoft Office)(\s+(for\s+)?(enterprise|business|ProPlus))?$') }) | Select-Object -First 1
        if ($o365) { $have[(Get-OfficeStarterId).ToLowerInvariant()] = [string]$o365.appName }
        return @{ ok = $true; starter = $true; items = @(Get-StarterAppSet | ForEach-Object { $k = ([string]$_.id).ToLowerInvariant()
            [ordered]@{ id = $_.id; name = $_.name; category = $_.category; recommended = [bool]$_.recommended; why = $_.why; inCatalog = $(if ($have.ContainsKey($k)) { $have[$k] } else { '' }) } }) }
    }
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

# ---------------------------------------------------------------- a newer version of this app

function Global:Get-WebAppUpdate {
    <#
      Is a newer release of this app out? Asks GitHub's API for the latest
      release (its tag and notes - nothing about this PC is sent beyond the
      request itself), at most twice a day; off in Settings or in test
      mode. @{ ok; newer; version; notes; url }. -Now (Settings > About's
      "Check now"): asks even when the automatic check is off, and not from
      the 12-hour memory.
    #>
    param([switch]$Now)
    if ($Global:App.TestGraph -or (-not $Now -and -not $Global:App.CheckForUpdates)) { return @{ ok = $true; newer = $false; off = $true } }
    $c = $Global:App.AppUpdateCache
    if (-not $Now -and $c -and ((Get-Date) - $c.At).TotalHours -lt 12) { return $c.Answer }
    $repo = [string]$Global:App.ReleaseRepo
    if ($repo -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$') { return @{ ok = $false; error = 'No release repository set.' } }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $p = @{ Uri = "https://api.github.com/repos/$repo/releases/latest"; Headers = @{ 'User-Agent' = 'IntuneAppCatalog'; Accept = 'application/vnd.github+json' }; TimeoutSec = 10; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSEdition -eq 'Desktop') { $p.UseBasicParsing = $true }
        $r = Invoke-RestMethod @p
        $o = Get-AppUpdateOffer -Current ([string]$Global:App.AppVersion) -Tag ([string]$r.tag_name) -Body ([string]$r.body)
        $answer = @{ ok = $true; newer = $o.Newer; version = $o.Version; notes = $o.Notes; url = "https://github.com/$repo/releases/latest" }
    }
    catch { $answer = @{ ok = $false; error = "GitHub couldn't be asked: $($_.Exception.Message)" } }
    $Global:App.AppUpdateCache = @{ At = (Get-Date); Answer = $answer }
    return $answer
}

function Global:Get-WebAbout {
    <#
      Settings > About (2.38.34): which version this is, where it runs and
      where its files are - what a bug report or a support question needs.
      -CheckNow also asks GitHub for a newer release.
    #>
    param($Data)
    $server = [bool](Test-WebServerMode)
    $os = try { [string][System.Runtime.InteropServices.RuntimeInformation]::OSDescription } catch { [string][Environment]::OSVersion }
    $apps = try { @((Read-WebCatalogRecords).Apps).Count } catch { 0 }
    $folders = @(foreach ($k in @(Get-AppFolderKinds)) { try { [ordered]@{ label = [string]$k.Label; path = [string](Get-AppFolder -Kind $k.Key) } } catch { } })
    $upd = if ($Data -and $Data.checkNow) { Get-WebAppUpdate -Now } elseif ($Global:App.AppUpdateCache) { $Global:App.AppUpdateCache.Answer } else { $null }
    return @{
        ok          = $true
        version     = [string]$Global:App.AppVersion
        server      = $server
        powershell  = "$($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
        os          = $os.Trim()
        apps        = $apps
        autoCheck   = [bool]$Global:App.CheckForUpdates
        update      = $upd
        repo        = [string]$Global:App.ReleaseRepo
        # Paths of the server's data volume mean nothing to the admin's browser - shown on the desktop app only.
        folders     = $(if ($server) { @() } else { $folders })
    }
}

# ---------------------------------------------------------------- assignment filters

function Global:Get-WebAssignmentFilters {
    # The tenant's assignment filters (Windows ones first) for the editor's filter box - @{ ok; filters = @(@{ name; platform; rule }) }.
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $true; filters = @(); note = 'Not connected - type the filter''s name.' } }
    $read = Invoke-WebGraph -Permission 'DeviceManagementConfiguration.Read.All' -Action {
        param($Graph)
        $all = New-Object System.Collections.Generic.List[object]
        $uri = "https://graph.microsoft.com/beta/deviceManagement/assignmentFilters?`$select=id,displayName,platform,rule"
        while ($uri) { $page = & $Graph $uri; foreach ($f in @($page.value)) { $all.Add($f) }; $uri = [string]$page.'@odata.nextLink' }
        , $all.ToArray()
    }
    if (-not $read.ok) { return @{ ok = $true; filters = @(); note = "Filters couldn't be read: $($read.error)" } }
    $rows = @(@($read.value) | Where-Object { $_ } | ForEach-Object { [ordered]@{ name = [string]$_.displayName; platform = [string]$_.platform; rule = [string]$_.rule } } |
        Sort-Object @{ Expression = { $_.platform -ne 'windows10AndLater' } }, @{ Expression = { $_.name } })
    return @{ ok = $true; filters = $rows }
}

# ---------------------------------------------------------------- permissions: granted vs used

function Global:Get-WebPermissionCheck {
    # Settings > Diagnostics > Check permissions: the app registration's Graph permissions (from the sign-in itself) against what is used here.
    if (-not (Test-GraphCredentialsConfigured -Quiet)) { return @{ ok = $false; error = 'Set up the connection in Settings first.' } }
    if ($Global:App.TestGraph) { $roles = @($Global:App.TestGraph.Answers.'TOKEN roles') }
    else {
        $read = Invoke-WebGraph -Permission 'DeviceManagementApps.ReadWrite.All' -Action { param($Graph) @((Get-MgContext).Scopes) }
        if (-not $read.ok) { return $read }
        $roles = @($read.value)
    }
    $scriptsDir = Get-AppFolder -Kind Scripts
    $usage = @{
        Scripts    = [bool](@(Get-ChildItem -LiteralPath $scriptsDir -Filter '*.ps1' -File -ErrorAction SilentlyContinue).Count)
        Inventory  = [bool](@((Read-WebCatalogRecords).Apps | Where-Object { $_.managedUpdates }).Count)
        Filters    = [bool](@((Read-WebCatalogRecords).Apps | Where-Object { $_.assignmentFilter }).Count)
        Mail       = [bool]($Global:App.Alerts.MailFrom -and @($Global:App.Alerts.MailTo).Count)
        GroupsPage = $true
        # Install status names the devices in deployed apps' groups (2.38.9).
        Devices    = [bool](@((Read-WebCatalogRecords).Apps | Where-Object { $_.appId -and (@($_.requiredFor) + @($_.availableFor) | Where-Object { $_ -and -not (Get-AllTargetInfo ([string]$_)) }) }).Count)
    }
    $rows = @(Get-PermissionReport -Granted $roles -Usage $usage)
    return @{ ok = $true; granted = @($roles); rows = $rows
        missing = @($rows | Where-Object { $_.status -in 'missing', 'partly' }).Count; unused = @($rows | Where-Object { $_.status -eq 'unused' }).Count }
}

function Global:Set-WebCompanyPortalStore {
    # Company Portal without a Winget ID becomes the Microsoft Store app (9WZDNCRFJ3PZ): Send to Intune creates it as Intune's Store type. With Undo.
    param($Data)
    $undo = New-WebUndo 'Company Portal as a Store app'
    $changed = New-Object System.Collections.Generic.List[string]
    # Linked to Intune already too: its App ID stays when it is the new Store app there - the catalog then knows it as
    # it is. Linked to anything else (the legacy Store app, 2.38.23): the App ID goes, Send to Intune creates the new one
    # (a winGetApp can't be patched onto the legacy type). Not one packaged on purpose (its own package or commands).
    foreach ($a in @((Read-WebCatalogRecords).Apps | Where-Object { -not $_.wingetId -and (Test-CompanyPortalName $_.appName) -and -not $_.packagePath -and -not ($_.metadata -and ([string]$_.metadata.installCommand).Trim() -and $_.metadata.detectionRule) })) {
        $a.wingetId = '9WZDNCRFJ3PZ'
        if ($a.appId -and [string]$a.intuneAppType -ne 'Microsoft Store app (new)') { $a.appId = ''; $a.intuneAppType = ''; $a.intuneAppVersion = '' }
        Write-WebAppFile -App $a -Undo $undo
        $changed.Add([string]$a.appName)
    }
    Save-WebUndo $undo
    if ($changed.Count) { Write-Log "[OK] $($changed -join ', ') set up as the Microsoft Store app (9WZDNCRFJ3PZ) - Send to Intune creates it." }
    return @{ ok = $true; changed = $changed.ToArray() }
}
