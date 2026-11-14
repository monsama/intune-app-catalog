# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    Adding apps: the Add apps dialog's three ways in.

    - Winget: search, pick one or several, and each is added with what
      "winget show" knows (publisher, description, homepage, privacy URL).
    - An installer (MSI or EXE), dropped on the page: uploaded in chunks
      (JSON, so every request is checked like any other), read - an MSI's
      properties, an EXE's version information and maker - and added as an
      own package with its commands and detection rule worked out, the file
      in its packages folder.
    - A PowerShell script app: Install.ps1 / Uninstall.ps1 from a template,
      detected by the version marker the install script writes.
#>

function Global:Get-WebAddGroupLists {
    # The groups the dialog sends, one per entry, trimmed.
    param($Data)
    return @{
        Required  = @(@($Data.requiredFor) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
        Available = @(@($Data.availableFor) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    }
}

function Global:Test-WebAddName {
    # '' when -Name can be a new app's name, else why not.
    param([string]$Name, $Apps)
    if (-not $Name.Trim()) { return 'The app needs a name.' }
    if ($Name.Length -gt 100) { return 'The name is too long (100 characters at most).' }
    if (@($Apps | Where-Object { [string]$_.appName -eq $Name.Trim() }).Count) { return "There is already an app called '$($Name.Trim())'." }
    return ''
}

function Global:Get-WebHttpUrl {
    # A URL the catalog accepts (http/https, no spaces), or ''.
    param([string]$Url)
    $u = ([string]$Url).Trim()
    if ($u -match '^https?://\S+$' -and $u.Length -le 2000) { return $u }
    return ''
}

# ---------------------------------------------------------------- winget

function Global:Get-WebWingetDetails {
    # What winget show knows about one package (Add apps shows it before adding).
    param($Data)
    $id = ([string]$Data.id).Trim()
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-_+]{0,127}$') { return @{ ok = $false; error = "'$id' isn't a Winget ID." } }
    try { $r = Invoke-Winget -Arguments @('show', '--id', $id, '--exact', '--accept-source-agreements', '--disable-interactivity') }
    catch { return @{ ok = $false; error = $_.Exception.Message } }
    $d = ConvertFrom-WingetShowOutput $r.StdOut
    if (-not $d.Id) { return @{ ok = $false; error = "winget doesn't know '$id'." } }
    return @{ ok = $true; details = $d }
}

function Global:Add-WebWingetApps {
    <#
      Adds the chosen Winget packages: each with winget's details, the
      groups given, and managed updates (pinned to winget's current
      version) when asked. Packages already in the catalog are skipped.
    #>
    param($Data)
    $groups = Get-WebAddGroupLists $Data
    $added = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($item in @($Data.items | Select-Object -First 50)) {
        $id = ([string]$item.id).Trim()
        $apps = @((Read-WebCatalogRecords).Apps)
        if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-_+]{0,127}$') { $skipped.Add("$id (not a Winget ID)"); continue }
        $twin = @($apps | Where-Object { [string]$_.wingetId -eq $id }) | Select-Object -First 1
        if ($twin) { $skipped.Add("$id (already in the catalog as $($twin.appName))"); continue }
        $det = Get-WebWingetDetails @{ id = $id }
        $d = if ($det.ok) { $det.details } else { @{ Name = [string]$item.name; Version = [string]$item.version } }
        $name = ([string]$(if ([string]$item.name) { $item.name } else { $d.Name })).Trim()
        if (Test-WebAddName $name $apps) { $name = "$name ($id)" }
        $why = Test-WebAddName $name $apps
        if ($why) { $skipped.Add("$id ($why)"); continue }
        $managed = [bool]$Data.managed
        $edit = [pscustomobject]@{ appName = $name; wingetId = $id; appId = ''; requiredFor = $groups.Required; availableFor = $groups.Available; uninstallFor = @(); excludeFor = @()
            managedUpdates = $managed
            metadata = [pscustomobject]@{ description = $(if ($d.Description) { ([string]$d.Description).Substring(0, [Math]::Min(([string]$d.Description).Length, 2000)) } else { $name }); publisher = [string]$d.Publisher
                informationUrl = (Get-WebHttpUrl $(if ($d.Homepage) { $d.Homepage } else { $d.PublisherUrl })); privacyUrl = (Get-WebHttpUrl $d.PrivacyUrl)
                appVersion = $(if ($managed -and (Test-ReleaseVersionText ([string]$d.Version))) { [string]$d.Version } else { '' }); owner = ''; developer = ''; notes = $(if ($d.License) { "License: $($d.License)" } else { '' })
                installCommand = ''; uninstallCommand = '' } }
        # The commands are the Winget defaults (the editor fills them the same way).
        $defaults = Get-DefaultAppMetadata -AppName $name -WingetId $id -Uncommon $false
        $edit.metadata.installCommand = [string]$defaults.installCommand; $edit.metadata.uninstallCommand = [string]$defaults.uninstallCommand
        $r = Save-WebApp @{ originalName = ''; version = ''; app = $edit }
        if ($r.ok) { $added.Add($r.name) } else { $skipped.Add("$id ($($r.error))") }
    }
    Write-Log "[OK] Add apps (winget): $($added.Count) added$(if ($skipped.Count) { ", skipped: $($skipped -join '; ')" })."
    return @{ ok = $true; added = $added.ToArray(); skipped = $skipped.ToArray() }
}

# ---------------------------------------------------------------- an installer, uploaded

function Global:Get-WebUploads {
    if (-not $Global:App.Uploads) { $Global:App.Uploads = [hashtable]::Synchronized(@{}) }
    return $Global:App.Uploads
}

function Global:Start-WebUpload {
    # Begins an installer upload: an .msi or .exe of at most 8 GB, into a temporary file of its own. @{ ok; uploadId }.
    param($Data)
    $name = [System.IO.Path]::GetFileName(([string]$Data.fileName).Trim())
    $size = [long]0; [void][long]::TryParse([string]$Data.size, [ref]$size)
    if ($name -notmatch '^[^<>:"/\\|?*\x00-\x1F]{1,150}\.(msi|exe)$') { return @{ ok = $false; error = 'Choose an .msi or .exe installer (the file name may not hold < > : " / \ | ? *).' } }
    if ($size -le 0 -or $size -gt 8GB) { return @{ ok = $false; error = 'The installer must be between 1 byte and 8 GB.' } }
    $uploads = Get-WebUploads
    # Unfinished uploads older than a day go (a closed tab never finishes its own).
    foreach ($k in @($uploads.Keys)) { if ($uploads[$k].Started -lt (Get-Date).AddDays(-1)) { Remove-Item -LiteralPath $uploads[$k].Path -Force -ErrorAction SilentlyContinue; $uploads.Remove($k) } }
    $id = [guid]::NewGuid().ToString('N')
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "intunecat-upload-$id"
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $uploads[$id] = @{ Path = (Join-Path $dir $name); FileName = $name; Size = $size; Received = [long]0; Started = (Get-Date); Info = $null }
    [System.IO.File]::WriteAllBytes($uploads[$id].Path, [byte[]]@())
    return @{ ok = $true; uploadId = $id }
}

function Global:Add-WebUploadChunk {
    # One piece of an upload (base64, at most 6 MB), at the offset the server expects next.
    param($Data)
    $u = (Get-WebUploads)[[string]$Data.uploadId]
    if (-not $u) { return @{ ok = $false; error = 'That upload is no longer known - start again.' } }
    $offset = [long]0; [void][long]::TryParse([string]$Data.offset, [ref]$offset)
    if ($offset -ne $u.Received) { return @{ ok = $false; error = "Upload out of order (expected byte $($u.Received))."; expected = $u.Received } }
    try { $bytes = [Convert]::FromBase64String([string]$Data.data) } catch { return @{ ok = $false; error = 'A piece of the upload was damaged.' } }
    if ($bytes.Length -eq 0 -or $bytes.Length -gt 6MB -or $u.Received + $bytes.Length -gt $u.Size) { return @{ ok = $false; error = 'That piece is larger than the file.' } }
    $fs = [System.IO.File]::Open($u.Path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
    $u.Received += $bytes.Length
    return @{ ok = $true; received = $u.Received }
}

function Global:Get-WebInstallerFacts {
    <#
      What an installer says about itself: an MSI's ProductName,
      ProductVersion, Manufacturer and ProductCode (Windows Installer); an
      EXE's product name, company and version, and its maker (Inno Setup,
      NSIS, ...). Off Windows only the file name is known.
    #>
    param([string]$Path)
    $info = [ordered]@{ Kind = ([System.IO.Path]::GetExtension($Path)).TrimStart('.').ToLowerInvariant(); FileName = [System.IO.Path]::GetFileName($Path); ProductName = ''; Manufacturer = ''; ProductVersion = ''; ProductCode = ''; ExeKind = ''; Signer = '' }
    if ($info.Kind -eq 'msi') {
        try {
            $wi = New-Object -ComObject WindowsInstaller.Installer
            $db = $wi.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $wi, @($Path, 0))
            foreach ($prop in 'ProductName', 'ProductVersion', 'Manufacturer', 'ProductCode') {
                $view = $db.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db, @("SELECT Value FROM Property WHERE Property='$prop'"))
                [void]$view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null)
                $rec = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
                if ($rec) { $info[$prop] = [string]$rec.GetType().InvokeMember('StringData', 'GetProperty', $null, $rec, 1) }
                [void]$view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null)
            }
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($db); [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wi)
        }
        catch { }
    }
    else {
        try {
            $vi = (Get-Item -LiteralPath $Path).VersionInfo
            $info.ProductName = ([string]$vi.ProductName).Trim(); $info.Manufacturer = ([string]$vi.CompanyName).Trim()
            $v = ([string]$vi.ProductVersion).Trim(); if (-not $v) { $v = ([string]$vi.FileVersion).Trim() }
            $info.ProductVersion = $v -replace ',\s*', '.'
        }
        catch { }
        try {
            $fs = [System.IO.File]::OpenRead($Path)
            try { $buf = New-Object byte[] ([Math]::Min($fs.Length, 4MB)); [void]$fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
            $info.ExeKind = Get-InstallerKind ([Text.Encoding]::ASCII.GetString($buf) + [Text.Encoding]::Unicode.GetString($buf))
        }
        catch { }
    }
    if (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue) {
        try { $sig = Get-AuthenticodeSignature -LiteralPath $Path; if ($sig.Status -eq 'Valid') { $info.Signer = [string]$sig.SignerCertificate.Subject } } catch { }
    }
    return $info
}

function Global:Complete-WebUpload {
    # The upload is whole: read the installer and propose how to add it.
    param($Data)
    $u = (Get-WebUploads)[[string]$Data.uploadId]
    if (-not $u) { return @{ ok = $false; error = 'That upload is no longer known - start again.' } }
    if ($u.Received -ne $u.Size) { return @{ ok = $false; error = "Only $($u.Received) of $($u.Size) bytes arrived - start again." } }
    $u.Info = Get-WebInstallerFacts $u.Path
    $p = Get-InstallerProposal $u.Info
    $u.Proposal = $p
    $apps = @((Read-WebCatalogRecords).Apps)
    return @{ ok = $true; fileName = $u.FileName; size = $u.Size; kind = $u.Info.Kind; exeKind = $u.Info.ExeKind; signer = $u.Info.Signer; productCode = $u.Info.ProductCode
        name = $p.Name; publisher = $p.Publisher; version = $p.Version; installCommand = $p.InstallCommand; uninstallCommand = $p.UninstallCommand
        detection = $(if ($p.Detection) { $p.Detection.Type } else { '' }); managedOk = [bool]$p.ManagedOk; notes = @($p.Notes); nameProblem = (Test-WebAddName $p.Name $apps) }
}

function Global:Add-WebInstallerApp {
    <#
      Adds the uploaded installer as an own-package app: the file goes into
      Packages\<app> (a folder that must not hold another installer yet),
      with Uninstall.ps1 for an EXE; the record gets the commands and the
      detection rule worked out, and the groups given. The page then builds
      the package when asked.
    #>
    param($Data)
    $u = (Get-WebUploads)[[string]$Data.uploadId]
    if (-not $u -or -not $u.Proposal) { return @{ ok = $false; error = 'That upload is no longer known - drop the installer again.' } }
    $name = ([string]$Data.name).Trim() -replace '\s+', ' '
    $why = Test-WebAddName $name @((Read-WebCatalogRecords).Apps)
    if ($why) { return @{ ok = $false; error = $why } }
    $p = $u.Proposal
    $version = ([string]$Data.version).Trim()
    if ($version -and -not (Test-ReleaseVersionText $version)) { return @{ ok = $false; error = "'$version' isn't a version (letters, digits and . - + _)." } }
    $folder = Join-Path (Get-AppFolder -Kind Packages -Create) (Get-SafeFileNameForApp -Name $name)
    if (Test-Path -LiteralPath $folder) {
        $other = @(Get-ChildItem -LiteralPath $folder -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.msi', '.exe' -and $_.Name -ne $u.FileName })
        if ($other.Count) { return @{ ok = $false; error = "$folder already holds another installer ($($other[0].Name)) - choose another name, or empty that folder first." } }
    }
    else { [void](New-Item -ItemType Directory -Path $folder -Force) }
    Copy-Item -LiteralPath $u.Path -Destination (Join-Path $folder $u.FileName) -Force
    if ($p.NeedsUninstallScript) {
        $label = if ($u.Info.ProductName) { $u.Info.ProductName } else { $name }
        [System.IO.File]::WriteAllText((Join-Path $folder 'Uninstall.ps1'), (New-InstalledAppUninstallScript -DisplayName $label -ExeKind $u.Info.ExeKind), (New-Object System.Text.UTF8Encoding($true)))
    }
    $groups = Get-WebAddGroupLists $Data
    $install = ([string]$Data.installCommand).Trim(); if (-not $install) { $install = $p.InstallCommand }
    $uninstall = ([string]$Data.uninstallCommand).Trim(); if (-not $uninstall) { $uninstall = $p.UninstallCommand }
    $edit = [pscustomobject]@{ appName = $name; wingetId = ''; appId = ''; requiredFor = $groups.Required; availableFor = $groups.Available; uninstallFor = @(); excludeFor = @(); managedUpdates = $false
        metadata = [pscustomobject]@{ description = $(if ([string]$Data.description) { [string]$Data.description } else { $name }); publisher = ([string]$Data.publisher).Trim(); appVersion = $version
            installCommand = $install; uninstallCommand = $uninstall; owner = ''; developer = ''; informationUrl = ''; privacyUrl = ''
            notes = "Added from $($u.FileName)$(if ($u.Info.Signer) { ", signed by $($u.Info.Signer)" })." } }
    $r = Save-WebApp @{ originalName = ''; version = ''; app = $edit }
    if (-not $r.ok) { return $r }
    $rule = $p.Detection
    if ($rule -and $version -and $rule.Type -eq 'Msi') { $rule.Msi_Version = $version }
    $managed = [bool]$Data.managed -and [bool]$p.ManagedOk
    [void](Update-WebCatalogApp -Name $r.name -Change {
            param($app)
            if ($rule) { $app.metadata.detectionRule = [pscustomobject]$rule }
            if ($managed) { $app.managedUpdates = $true; [void](Set-ManagedAppPin $app -ProductCode ([string]$u.Info.ProductCode)) }
        }.GetNewClosure())
    Remove-Item -LiteralPath (Split-Path $u.Path -Parent) -Recurse -Force -ErrorAction SilentlyContinue
    (Get-WebUploads).Remove([string]$Data.uploadId)
    Write-Log "[OK] Added $($r.name) from $($u.FileName) ($($p.Detection.Type) detection) - its installer is in $folder."
    return @{ ok = $true; name = $r.name; folder = $folder }
}

function Global:Remove-WebUpload {
    # The dialog was closed without adding: the temporary file goes.
    param($Data)
    $u = (Get-WebUploads)[[string]$Data.uploadId]
    if ($u) { Remove-Item -LiteralPath (Split-Path $u.Path -Parent) -Recurse -Force -ErrorAction SilentlyContinue; (Get-WebUploads).Remove([string]$Data.uploadId) }
    return @{ ok = $true }
}

# ---------------------------------------------------------------- a PowerShell script app

function Global:Get-WebScriptTemplates {
    param($Data)
    return @{ ok = $true; templates = @(Get-ScriptAppTemplates -Name ([string]$Data.name) -Version ([string]$Data.version)) }
}

function Global:Add-WebScriptApp {
    <#
      Adds a script app: Install.ps1 and Uninstall.ps1 in Packages\<app>,
      run with 64-bit PowerShell; detected by the version marker the install
      script writes (a registry rule by version - managed updates can follow
      it), or by a detection script of your own.
    #>
    param($Data)
    $name = ([string]$Data.name).Trim() -replace '\s+', ' '
    $why = Test-WebAddName $name @((Read-WebCatalogRecords).Apps)
    if ($why) { return @{ ok = $false; error = $why } }
    $version = ([string]$Data.version).Trim()
    if ($version -and -not (Test-ReleaseVersionText $version)) { return @{ ok = $false; error = "'$version' isn't a version (letters, digits and . - + _)." } }
    $install = [string]$Data.install; $uninstall = [string]$Data.uninstall
    if (-not $install.Trim()) { return @{ ok = $false; error = 'The install script is empty.' } }
    if (-not $uninstall.Trim()) { return @{ ok = $false; error = 'The uninstall script is empty.' } }
    $useMarker = -not ([string]$Data.detectScript).Trim()
    if ($useMarker -and $install -notmatch 'IntuneAppCatalog\\Apps') { return @{ ok = $false; error = "The install script doesn't write the version marker (HKLM:\SOFTWARE\IntuneAppCatalog\Apps\<name>) - keep the template's last lines, or give a detection script of your own." } }
    foreach ($text in $install, $uninstall, [string]$Data.detectScript) {
        if (-not $text) { continue }
        $errs = $null; [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
        if ($errs -and $errs.Count) { return @{ ok = $false; error = "A script doesn't parse: $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))." } }
    }
    $folder = Join-Path (Get-AppFolder -Kind Packages -Create) (Get-SafeFileNameForApp -Name $name)
    if ((Test-Path -LiteralPath (Join-Path $folder 'Install.ps1'))) { return @{ ok = $false; error = "$folder already holds an Install.ps1 - choose another name." } }
    [void](New-Item -ItemType Directory -Path $folder -Force)
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText((Join-Path $folder 'Install.ps1'), (ConvertTo-CanonicalLineEndings $install), $utf8)
    [System.IO.File]::WriteAllText((Join-Path $folder 'Uninstall.ps1'), (ConvertTo-CanonicalLineEndings $uninstall), $utf8)
    $ps = '%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
    $groups = Get-WebAddGroupLists $Data
    $edit = [pscustomobject]@{ appName = $name; wingetId = ''; appId = ''; requiredFor = $groups.Required; availableFor = $groups.Available; uninstallFor = @(); excludeFor = @(); managedUpdates = $false
        metadata = [pscustomobject]@{ description = $(if ([string]$Data.description) { [string]$Data.description } else { $name }); publisher = ([string]$Data.publisher).Trim(); appVersion = $version
            installCommand = "$ps .\Install.ps1"; uninstallCommand = "$ps .\Uninstall.ps1"; owner = ''; developer = ''; informationUrl = ''; privacyUrl = ''; notes = 'A script app: Install.ps1 and Uninstall.ps1 in its packages folder.' } }
    $r = Save-WebApp @{ originalName = ''; version = ''; app = $edit }
    if (-not $r.ok) { return $r }
    $rule = if ($useMarker) { Get-ScriptAppMarkerRule -Name $name -Version $version } else { [ordered]@{ Type = 'Script'; Script_Content = (ConvertTo-CanonicalLineEndings ([string]$Data.detectScript)).TrimEnd() } }
    # Managed updates by default when the version marker detects it (a version-comparing rule), unless turned off.
    $managed = $useMarker -and [bool]$version -and $Data.managed -ne $false
    [void](Update-WebCatalogApp -Name $r.name -Change { param($app) $app.metadata.detectionRule = [pscustomobject]$rule; if ($managed) { $app.managedUpdates = $true } }.GetNewClosure())
    Write-Log "[OK] Added the script app $($r.name) - Install.ps1 and Uninstall.ps1 are in $folder."
    return @{ ok = $true; name = $r.name; folder = $folder }
}
