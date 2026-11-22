# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    PC helpers - the server version's way to what only a Windows PC can do: a
    script (or a zip) the page downloads and someone runs on a Windows PC.

      - Entra setup: the certificate and the API permissions onto the app
        registration (you sign in there) - the desktop version's Upload and
        Add permissions, the very same step (CertUpload.ps1)
      - Sandbox test: the app's package with the test, and a starter that
        opens Windows Sandbox and says how it went
      - Detection from an installed app: lists the PC's apps, the chosen one's
        details go to the clipboard - pasted into the editor, the server
        makes the detection rule from them
      - This PC's apps: winget export - the file goes to Add apps > From a list

    A file too large for an answer (the Sandbox zip) is served once, by a
    random link that ends after 5 minutes (/download/<id>).
#>

function Global:ConvertTo-WebScriptFile {
    # A script as the page saves it: UTF-8 with a BOM (Windows PowerShell 5.1 reads it right), Windows line ends, base64.
    param([string]$Text, [string]$Name)
    $t = (([string]$Text) -replace "`r`n", "`n") -replace "`n", "`r`n"
    $bytes = (New-Object System.Text.UTF8Encoding($true)).GetPreamble() + [Text.Encoding]::UTF8.GetBytes($t)
    return @{ ok = $true; name = $Name; file = [Convert]::ToBase64String([byte[]]$bytes) }
}

function Global:Get-WebHelperHeader {
    # The first lines of every helper script: what it is, which server wrote it, when.
    param([string]$What)
    # Free text (an app's name - from an installer's own ProductName) never ends the comment block, nor the line.
    $What = ($What -replace '[\x00-\x1f\x7f]', ' ') -replace '<#|#>', '_'
    return @"
<#
  Intune App Catalog - $What
  Written by the server version $($Global:App.AppVersion) on $((Get-Date).ToString('yyyy-MM-dd HH:mm')).
  Run it on a Windows PC: right-click > Run with PowerShell, or: powershell -ExecutionPolicy Bypass -File <this file>
  It is plain PowerShell - read it before you run it.
#>
"@
}

# ---------------------------------------------------------------- downloads by a single-use link

function Global:New-WebDownload {
    # A file to be fetched once at /download/<id> within 5 minutes; -RemoveAfter: delete it (a temporary zip) once sent or expired.
    param([string]$Path, [string]$Name, [string]$ContentType = 'application/octet-stream', [switch]$RemoveAfter)
    foreach ($k in @($Global:App.Downloads.Keys)) {
        $d = $Global:App.Downloads[$k]
        if ($d -and $d.Expires -lt (Get-Date)) { $Global:App.Downloads.Remove($k); if ($d.Remove) { Remove-Item -LiteralPath $d.Path -Force -ErrorAction SilentlyContinue } }
    }
    $bytes = New-Object byte[] 16; $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create(); try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $id = -join ($bytes | ForEach-Object { $_.ToString('x2') })
    $Global:App.Downloads[$id] = @{ Path = $Path; Name = $Name; Type = $ContentType; Expires = (Get-Date).AddMinutes(5); Remove = [bool]$RemoveAfter }
    return "/download/$id"
}

function Global:Send-WebDownload {
    # The file behind a /download/<id> link, once (404 when unknown, used or expired) - streamed, not read into memory.
    param($Client, [string]$Id)
    $d = if ($Global:App.Downloads) { $Global:App.Downloads[$Id] } else { $null }
    if ($d) { $Global:App.Downloads.Remove($Id) }
    if (-not $d -or $d.Expires -lt (Get-Date) -or -not (Test-Path -LiteralPath $d.Path -PathType Leaf)) {
        Send-WebResponse $Client '404 Not Found' 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes('This download link was used already or has expired - start the download again.'))
        return
    }
    try {
        $name = ([string]$d.Name -replace '[^\w .()-]', '_')
        $len = (Get-Item -LiteralPath $d.Path).Length
        $head = "HTTP/1.1 200 OK`r`nContent-Type: $($d.Type)`r`nContent-Length: $len`r`nContent-Disposition: attachment; filename=`"$name`"`r`nCache-Control: no-store`r`nX-Content-Type-Options: nosniff`r`nReferrer-Policy: no-referrer`r`nConnection: close`r`n`r`n"
        $ns = $Client.GetStream()
        $hb = [Text.Encoding]::ASCII.GetBytes($head); $ns.Write($hb, 0, $hb.Length)
        $fs = [System.IO.File]::OpenRead($d.Path)
        try { $fs.CopyTo($ns, 1MB) } finally { $fs.Dispose() }
        $ns.Flush()
    }
    finally { if ($d.Remove) { Remove-Item -LiteralPath $d.Path -Force -ErrorAction SilentlyContinue } }
}

# ---------------------------------------------------------------- Entra setup (certificate and API permissions)

function Global:Get-WebEntraScript {
    <#
      The Entra setup script: the CertUpload step the desktop version runs (unchanged), and what it should do -
      add the chosen certificate's public part (when one is chosen) and the chosen Graph application
      permissions - then the API permissions page opens for the admin consent.
    #>
    param($Data)
    $tenant = ([string]$Data.tenantId).Trim(); $client = ([string]$Data.clientId).Trim()
    $g = [guid]::Empty
    if (-not [guid]::TryParse($tenant, [ref]$g) -and $tenant -notmatch '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$') { return @{ ok = $false; error = 'Fill in the Tenant ID first (Settings > Connection).' } }
    if (-not [guid]::TryParse($client, [ref]$g)) { return @{ ok = $false; error = 'Fill in the Client (Application) ID first.' } }
    $steps = New-Object System.Collections.Generic.List[object]
    $thumb = ([string]$Data.thumbprint) -replace '\s', ''
    if ($thumb) {
        $cert = Find-AppStoreCertificate $thumb
        if (-not $cert) { return @{ ok = $false; error = "No certificate with thumbprint $thumb here - choose, create or import one first." } }
        $steps.Add([ordered]@{ Mode = 'Upload'; TenantId = $tenant; ClientId = $client; CertThumbprint = $cert.Thumbprint; CertSubject = $cert.Subject
                CertBase64 = [Convert]::ToBase64String($cert.RawData); CertNotBefore = $cert.NotBefore.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); CertNotAfter = $cert.NotAfter.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') })
    }
    $perms = @($Data.permissions | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^[A-Za-z]+(\.[A-Za-z]+)+$' } | Select-Object -Unique)
    if ($perms.Count) { $steps.Add([ordered]@{ Mode = 'AddPermissions'; TenantId = $tenant; ClientId = $client; Permissions = $perms }) }
    # The server version: the address Sign in with Microsoft comes back to, on the same app registration.
    if ((Test-WebServerMode) -and $steps.Count) { $steps.Add([ordered]@{ Mode = 'AddRedirectUri'; TenantId = $tenant; ClientId = $client; RedirectUri = (Get-WebEntraRedirectUri) }) }
    if (-not $steps.Count) { return @{ ok = $false; error = 'Choose a certificate or at least one permission.' } }
    $step = $Global:App.EmbeddedCertUploadScript
    if ($step -match "(?m)^'@") { return @{ ok = $false; error = 'The Entra step could not be put into a script.' } }
    $json = ConvertTo-Json -InputObject @($steps.ToArray()) -Depth 5
    $consent = "https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$client/isMSAApp~/false"
    $text = (Get-WebHelperHeader 'Entra setup: the certificate and the API permissions on the app registration') + @"

# You sign in with your own account (an admin of the tenant) - the same step the desktop version runs
# (CertUpload.ps1, below as it is): $(@($steps | ForEach-Object { if ($_.Mode -eq 'Upload') { "add the certificate $(([string]$_.CertSubject) -replace '[\x00-\x1f\x7f]', ' ') ($($_.CertThumbprint))" } else { "add $($perms.Count) Microsoft Graph application permission(s)" } }) -join ', then ').
`$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
    Write-Host 'Installing the Microsoft.Graph.Authentication module for your user (PowerShell Gallery)...' -ForegroundColor Cyan
    Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber
}
`$work = Join-Path `$env:TEMP ('ica-entra-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path `$work -Force | Out-Null
`$stepFile = Join-Path `$work 'CertUpload.ps1'
Set-Content -LiteralPath `$stepFile -Encoding UTF8 -Value @'
$step
'@
`$all = ConvertFrom-Json @'
$json
'@
`$failed = `$false
foreach (`$cfg in @(`$all)) {
    `$cfg | Add-Member -NotePropertyName OutputResultPath -NotePropertyValue (Join-Path `$work "result-`$(`$cfg.Mode).json") -Force
    `$cfgFile = Join-Path `$work "config-`$(`$cfg.Mode).json"
    `$cfg | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath `$cfgFile -Encoding UTF8
    & `$stepFile -ConfigPath `$cfgFile
    `$r = Get-Content -LiteralPath `$cfg.OutputResultPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
    if (-not `$r -or -not `$r.success) { Write-Host "[FAILED] `$(`$cfg.Mode): `$(`$r.error)" -ForegroundColor Red; `$failed = `$true; break }
}
Remove-Item -LiteralPath `$work -Recurse -Force -ErrorAction SilentlyContinue
if (-not `$failed -and @(`$all | Where-Object { `$_.Mode -eq 'AddPermissions' }).Count) {
    Write-Host ''
    Write-Host 'Last step: grant admin consent on the page that opens now, then Test connection in the app.' -ForegroundColor Green
    Start-Process '$consent'
}
Write-Host ''
Read-Host 'Press Enter to close'
"@
    return (ConvertTo-WebScriptFile -Text $text -Name 'Intune-App-Catalog-Entra-setup.ps1')
}

# ---------------------------------------------------------------- Windows Sandbox test

function Global:Get-WebSandboxPackage {
    <#
      A test in Windows Sandbox as a zip, for a Windows PC: the app's package folder, the test
      (run.ps1, as the desktop version writes it) and Start-Test.ps1, which opens the Sandbox with the
      unpacked folder, waits for the result and says how it went. Served once by a download link.
    #>
    param($Data)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$($Data.name)'." } }
    if ($a.wingetId) { return @{ ok = $false; error = "Windows Sandbox has no winget, so a Winget app can't be tested there - test it on a pilot device (managed updates)." } }
    $m = $a.metadata
    if (-not $m -or -not $m.installCommand -or -not $m.detectionRule) { return @{ ok = $false; error = 'The app needs an install command and a detection rule first (the editor).' } }
    $src = Join-Path (Get-AppFolder -Kind Packages) (Get-SafeFileNameForApp -Name $a.appName)
    if (-not (Test-Path -LiteralPath $src)) { return @{ ok = $false; error = "The app's packages folder isn't there - add its installer first." } }
    $size = (@(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.intunewin' }) | Measure-Object Length -Sum).Sum
    if ($size -gt 4GB) { return @{ ok = $false; error = 'The package folder is larger than 4 GB - too large to download as a test.' } }
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ('ica-sandbox-' + [guid]::NewGuid().ToString('N'))
    $root = Join-Path $work 'test'
    $pkg = Join-Path $root 'package'
    try {
        [void](New-Item -ItemType Directory -Path $pkg -Force)
        # The installer and its files - not the built .intunewin, which the test doesn't use.
        foreach ($i in @(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ne '.intunewin' })) { Copy-Item -LiteralPath $i.FullName -Destination $pkg -Recurse -Force }
        $utf8bom = New-Object System.Text.UTF8Encoding($true)
        [System.IO.File]::WriteAllText((Join-Path $root 'run.ps1'), ((New-WebSandboxRunScript -Metadata $m) -replace "`r?`n", "`r`n"), $utf8bom)
        $start = (Get-WebHelperHeader "a test of $($a.appName) in Windows Sandbox") + @'

# Unpack the zip first. This opens Windows Sandbox with this folder as C:\Test: run.ps1 installs the app with
# its install command, checks its detection rule, uninstalls it and checks again. You see how it went here.
$root = $PSScriptRoot
$sb = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
if (-not (Test-Path -LiteralPath $sb)) { Write-Host "Windows Sandbox isn't turned on: Windows Features > Windows Sandbox (Windows Pro or Enterprise), then restart." -ForegroundColor Yellow; Read-Host 'Press Enter to close'; exit 1 }
Remove-Item -LiteralPath (Join-Path $root 'result.json'), (Join-Path $root 'log.txt') -Force -ErrorAction SilentlyContinue
$wsb = "<Configuration><MappedFolders><MappedFolder><HostFolder>$([System.Security.SecurityElement]::Escape($root))</HostFolder><SandboxFolder>C:\Test</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder></MappedFolders><LogonCommand><Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Test\run.ps1</Command></LogonCommand><Networking>Enable</Networking></Configuration>"
$wsbPath = Join-Path $root 'test.wsb'
Set-Content -LiteralPath $wsbPath -Value $wsb -Encoding UTF8
Start-Process -FilePath $sb -ArgumentList "`"$wsbPath`""
Write-Host 'Windows Sandbox is starting - the test runs by itself (a few minutes). Waiting for it...' -ForegroundColor Cyan
$shown = 0
for ($i = 0; $i -lt 360 -and -not (Test-Path -LiteralPath (Join-Path $root 'result.json')); $i++) {
    Start-Sleep -Seconds 5
    $lines = @(Get-Content -LiteralPath (Join-Path $root 'log.txt') -ErrorAction SilentlyContinue)
    if ($lines.Count -gt $shown) { $lines[$shown..($lines.Count - 1)] | ForEach-Object { Write-Host "  $_" }; $shown = $lines.Count }
}
$file = Join-Path $root 'result.json'
if (-not (Test-Path -LiteralPath $file)) { Write-Host 'No result after 30 minutes - see log.txt in this folder.' -ForegroundColor Yellow; Read-Host 'Press Enter to close'; exit 1 }
$r = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
$okInstall = ($r.installExit -in 0, 1707, 3010, 1641) -and $r.detectedAfterInstall
$okUninstall = ($null -eq $r.uninstallExit) -or (($r.uninstallExit -in 0, 1605, 3010, 1641) -and -not $r.detectedAfterUninstall)
Write-Host ''
if ($okInstall -and $okUninstall) { Write-Host 'PASSED: it installs, is detected, uninstalls and is gone again.' -ForegroundColor Green }
else {
    if (-not $okInstall) { if ($r.installExit -notin 0, 1707, 3010, 1641) { Write-Host "The install command ended with exit code $($r.installExit)." -ForegroundColor Red } else { Write-Host "It installed, but the detection rule doesn't find it." -ForegroundColor Red } }
    if (-not $okUninstall) { if ($r.uninstallExit -notin 0, 1605, 3010, 1641) { Write-Host "The uninstall command ended with exit code $($r.uninstallExit)." -ForegroundColor Red } else { Write-Host 'After the uninstall, the detection rule still finds it.' -ForegroundColor Red } }
}
# The name Windows listed it under: what a detection rule (Edit app > Detection > from an installed app) looks for.
foreach ($e in @($r.installed)) { if ($e.name) { Write-Host "Windows listed it as: $($e.name)$(if ($e.version) { "  (version $($e.version))" })" -ForegroundColor Cyan } }
Write-Host 'You can close the Sandbox now.'
Read-Host 'Press Enter to close'
'@
        [System.IO.File]::WriteAllText((Join-Path $root 'Start-Test.ps1'), ($start -replace "`r?`n", "`r`n"), $utf8bom)
        $zip = Join-Path $work 'test.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        [System.IO.Compression.ZipFile]::CreateFromDirectory($root, $zip)
        $final = Join-Path ([System.IO.Path]::GetTempPath()) ('ica-sandbox-' + [guid]::NewGuid().ToString('N') + '.zip')
        Move-Item -LiteralPath $zip -Destination $final
    }
    finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    $name = "Sandbox-test-$(Get-SafeFileNameForApp -Name $a.appName).zip"
    return @{ ok = $true; url = (New-WebDownload -Path $final -Name $name -ContentType 'application/zip' -RemoveAfter); name = $name }
}

# ---------------------------------------------------------------- detection from an app installed on a PC

function Global:Get-WebInstalledAppsScript {
    # Lists the PC's apps (as Windows lists them), one is picked, its details go to the clipboard - to paste into the editor.
    $text = (Get-WebHelperHeader 'detection from an app installed on this PC') + @'

# Lists the apps Windows has installed (the Uninstall keys: 64-bit, 32-bit, yours). Pick one: its details go to
# the clipboard - paste them into the app editor (Install & detection > From an app on a PC), which makes the
# detection rule from them. Nothing is changed on this PC.
$hives = @(@{ H = 'HKLM'; P = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' }, @{ H = 'HKLM-WOW'; P = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' }, @{ H = 'HKCU'; P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*' })
$apps = foreach ($h in $hives) {
    foreach ($e in @(Get-ItemProperty -Path $h.P -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent -and -not $_.ParentKeyName })) {
        [pscustomobject]@{ Name = [string]$e.DisplayName; Version = [string]$e.DisplayVersion; Publisher = [string]$e.Publisher; Hive = $h.H; Key = [string]$e.PSChildName; Entry = $e }
    }
}
$apps = @($apps | Sort-Object Name)
$pick = $null
if (Get-Command Out-GridView -ErrorAction SilentlyContinue) { $pick = $apps | Select-Object Name, Version, Publisher, Hive, Key | Out-GridView -Title 'Pick the app - then OK' -OutputMode Single }
else {
    for ($i = 0; $i -lt $apps.Count; $i++) { Write-Host ("{0,4}  {1} {2}" -f ($i + 1), $apps[$i].Name, $apps[$i].Version) }
    $n = Read-Host 'Number of the app'
    if ($n -match '^\d+$' -and [int]$n -ge 1 -and [int]$n -le $apps.Count) { $pick = $apps[[int]$n - 1] }
}
if (-not $pick) { Write-Host 'Nothing picked.'; Read-Host 'Press Enter to close'; exit }
$app = $apps | Where-Object { $_.Key -eq $pick.Key -and $_.Hive -eq $pick.Hive } | Select-Object -First 1
$e = $app.Entry
# Its program file and version, when there is one to find (the icon's file, or the largest .exe where it's installed).
$exe = $null; $exeVersion = ''
$icon = ([string]$e.DisplayIcon -replace ',\s*-?\d+$', '').Trim('"', ' ')
$cand = if ($icon -match '\.exe$' -and $icon -notmatch 'unins|uninst|setup|installer') { $icon } elseif ($e.InstallLocation) { @(Get-ChildItem -LiteralPath ([string]$e.InstallLocation) -Filter '*.exe' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch 'unins|uninst|setup|update|crash' } | Sort-Object Length -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }) | Select-Object -First 1 } else { $null }
if ($cand -and (Test-Path -LiteralPath $cand)) { $v = ([string](Get-Item -LiteralPath $cand).VersionInfo.FileVersion).Trim() -replace ',\s*', '.' -replace '\s.*$', ''; if ($v) { $exe = [string]$cand; $exeVersion = $v } }
$out = [ordered]@{ intuneAppCatalog = 'installed-app'; name = $app.Name; key = $app.Key; hive = $app.Hive; windowsInstaller = [int]$e.WindowsInstaller; displayVersion = [string]$e.DisplayVersion; mainExe = $exe; mainExeVersion = $exeVersion }
$json = $out | ConvertTo-Json -Compress
try { Set-Clipboard -Value $json; Write-Host "Copied - paste it into the app editor (From an app on a PC):" -ForegroundColor Green } catch { Write-Host 'Copy this into the app editor (From an app on a PC):' -ForegroundColor Green }
Write-Host $json
Read-Host 'Press Enter to close'
'@
    return (ConvertTo-WebScriptFile -Text $text -Name 'Intune-App-Catalog-Installed-app.ps1')
}

function Global:Get-WebDetectionFromPaste {
    # The detection rule from what the installed-app script copied (Get-WebInstalledAppsScript) - in the editor's form.
    param($Data)
    $t = ([string]$Data.text).Trim()
    if ($t.Length -gt 4000) { return @{ ok = $false; error = "That's too long to be what the script copied." } }
    try { $j = $t | ConvertFrom-Json -ErrorAction Stop } catch { return @{ ok = $false; error = "That isn't what the script copied - run it, pick the app, then paste here." } }
    if ([string]$j.intuneAppCatalog -ne 'installed-app') { return @{ ok = $false; error = "That isn't what the script copied - run it, pick the app, then paste here." } }
    $key = [string]$j.key
    if ($key -notmatch '^[^\\/:*?"<>|]{1,200}$') { return @{ ok = $false; error = 'Not an installed app.' } }
    $hive = if ([string]$j.hive -in 'HKLM', 'HKLM-WOW', 'HKCU') { [string]$j.hive } else { 'HKLM' }
    $exe = $null
    if ([string]$j.mainExe -match '^[A-Za-z]:\\[^"<>|*?]{1,250}\.exe$' -and [string]$j.mainExeVersion -match '^[0-9][0-9.]{0,40}$') { $exe = @{ Path = [string]$j.mainExe; Version = [string]$j.mainExeVersion } }
    $d = ConvertTo-DetectionFromInstalled @{ Key = $key; WindowsInstaller = [int]$j.windowsInstaller; DisplayVersion = ([string]$j.displayVersion).Substring(0, [Math]::Min(60, ([string]$j.displayVersion).Length)); Hive = $hive; MainExe = $exe }
    return (ConvertTo-WebDetectionForm $d)
}

# ---------------------------------------------------------------- this PC's apps (winget export)

function Global:Get-WebWingetExportScript {
    # winget export on a PC - the file goes to Add apps > From a list.
    $text = (Get-WebHelperHeader "this PC's apps for Add apps > From a list") + @'

# Runs winget export: the apps on this PC that winget knows, with their Winget IDs, into a file on your desktop.
# Then, in the app: Add apps > From a list > Choose an export file... - and pick the ones to add.
$w = Get-Command winget.exe -ErrorAction SilentlyContinue
if (-not $w) { Write-Host "winget isn't on this PC - it comes with the 'App Installer' package (Microsoft Store)." -ForegroundColor Yellow; Read-Host 'Press Enter to close'; exit 1 }
$file = Join-Path ([Environment]::GetFolderPath('Desktop')) ('winget-apps-' + $env:COMPUTERNAME + '.json')
& $w.Source export -o $file --accept-source-agreements --disable-interactivity
if (Test-Path -LiteralPath $file) { Write-Host "Saved: $file - choose it in Add apps > From a list." -ForegroundColor Green } else { Write-Host 'winget export did not write the file.' -ForegroundColor Red }
Read-Host 'Press Enter to close'
'@
    return (ConvertTo-WebScriptFile -Text $text -Name 'Intune-App-Catalog-This-PCs-apps.ps1')
}
