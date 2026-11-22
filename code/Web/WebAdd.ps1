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
        # A profile's excluded groups too (2.35.0 - the default profile, or one applied in Add apps).
        Exclude   = @(@($Data.excludeFor) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    }
}

function Global:Test-WebAddName {
    # '' when -Name can be a new app's name, else why not.
    param([string]$Name, $Apps)
    if (-not $Name.Trim()) { return 'The app needs a name.' }
    if ($Name.Length -gt 100) { return 'The name is too long (100 characters at most).' }
    if (@($Apps | Where-Object { [string]$_.appName -eq $Name.Trim() }).Count) { return "There is already an app called '$($Name.Trim())'." }
    # Different names, one file and one packages folder ("7-Zip", "7 Zip", "7.Zip"): one would change the other's installer (2.38.0).
    $file = Get-SafeFileNameForApp -Name $Name.Trim()
    $twin = @($Apps | Where-Object { $_ -and (Get-SafeFileNameForApp -Name ([string]$_.appName)) -eq $file }) | Select-Object -First 1
    if ($twin) { return "'$($Name.Trim())' would share '$($twin.appName)''s file and packages folder ($file) - choose a different name." }
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
        $isStore = Test-StoreProductId $id
        $managed = [bool]$Data.managed -and -not $isStore
        $edit = [pscustomobject]@{ appName = $name; wingetId = $id; appId = ''; requiredFor = $groups.Required; availableFor = $groups.Available; uninstallFor = @(); excludeFor = $groups.Exclude
            managedUpdates = $managed
            metadata = [pscustomobject]@{ description = $(if ($d.Description) { ([string]$d.Description).Substring(0, [Math]::Min(([string]$d.Description).Length, 2000)) } else { $name }); publisher = [string]$d.Publisher
                informationUrl = (Get-WebHttpUrl $(if ($d.Homepage) { $d.Homepage } else { $d.PublisherUrl })); privacyUrl = (Get-WebHttpUrl $d.PrivacyUrl)
                appVersion = $(if ($managed -and (Test-ReleaseVersionText ([string]$d.Version))) { [string]$d.Version } else { '' }); owner = [string]$Global:App.DefaultAppSettings.DefaultOwner; developer = ''; notes = (@($(if ($isStore) { 'A Microsoft Store app: sent to Intune as its Store type - the Store installs and updates it.' }), $(if ($d.License) { "License: $($d.License)" })) | Where-Object { $_ }) -join ' '
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
    if ($name -notmatch '^[^<>:"/\\|?*\x00-\x1F]{1,150}\.(msi|exe|zip)$') { return @{ ok = $false; error = 'Choose an .msi or .exe installer, or a .zip of its folder (the file name may not hold < > : " / \ | ? *).' } }
    if ($size -le 0 -or $size -gt 8GB) { return @{ ok = $false; error = 'The installer must be between 1 byte and 8 GB.' } }
    $uploads = Get-WebUploads
    # Unfinished uploads older than a day go (a closed tab never finishes its own).
    Remove-WebStaleUploads $uploads
    $id = [guid]::NewGuid().ToString('N')
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "intunecat-upload-$id"
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $uploads[$id] = @{ Path = (Join-Path $dir $name); FileName = $name; Size = $size; Received = [long]0; Started = (Get-Date); Info = $null
        Kind = $(if ($name -match '(?i)\.zip$') { 'zip' } else { 'file' }); Root = (Join-Path $dir 'tree'); Setup = '' }
    [System.IO.File]::WriteAllBytes($uploads[$id].Path, [byte[]]@())
    return @{ ok = $true; uploadId = $id }
}

function Global:Remove-WebStaleUploads {
    # Unfinished uploads older than a day go (a closed tab never finishes its own) - their whole temporary folder.
    param($Uploads)
    foreach ($k in @($Uploads.Keys)) { if ($Uploads[$k].Started -lt (Get-Date).AddDays(-1)) { Remove-Item -LiteralPath (Split-Path $Uploads[$k].Path -Parent) -Recurse -Force -ErrorAction SilentlyContinue; $Uploads.Remove($k) } }
}

function Global:Start-WebFolderUpload {
    <#
      Begins a folder upload (2.34.0): -files @(@{ path; size }) - paths relative to the folder, each one checked
      (Test-PackageRelativePath: nothing can land outside it), at most 5000 files and 8 GB. The files then come
      piece by piece (Add-WebUploadChunk with -index), into a temporary folder of their own.
    #>
    param($Data)
    $list = @($Data.files)
    if (-not $list.Count) { return @{ ok = $false; error = 'The folder is empty.' } }
    if ($list.Count -gt 5000) { return @{ ok = $false; error = "The folder holds $($list.Count) files - at most 5000 go into one package." } }
    $seen = @{}; [long]$total = 0
    $files = New-Object System.Collections.Generic.List[object]
    foreach ($f in $list) {
        $p = ([string]$f.path) -replace '/', '\'
        if (-not (Test-PackageRelativePath $p)) { return @{ ok = $false; error = "'$($f.path)' isn't a name a package file can have - nothing was uploaded." } }
        $key = $p.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { return @{ ok = $false; error = "'$p' is in the folder twice." } }
        $seen[$key] = $true
        $size = [long]0; [void][long]::TryParse([string]$f.size, [ref]$size)
        if ($size -lt 0) { return @{ ok = $false; error = "'$p' has no size." } }
        $total += $size
        $files.Add(@{ Path = $p; Size = $size; Received = [long]0 })
    }
    if ($total -gt 8GB) { return @{ ok = $false; error = 'The folder is larger than 8 GB.' } }
    $uploads = Get-WebUploads
    Remove-WebStaleUploads $uploads
    $id = [guid]::NewGuid().ToString('N')
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) "intunecat-upload-$id"
    $root = Join-Path $dir 'tree'
    [void](New-Item -ItemType Directory -Path $root -Force)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    # Every file made now - empty ones need no piece.
    foreach ($f in $files) {
        $dest = Join-Path $root ($f.Path -replace '\\', $sep)
        $d = Split-Path -Parent $dest; if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
        [System.IO.File]::WriteAllBytes($dest, [byte[]]@())
    }
    $name = ([string]$Data.folderName).Trim(); if (-not $name -or $name -match '[\\/:*?"<>|]') { $name = 'folder' }
    $uploads[$id] = @{ Path = (Join-Path $dir '.folder'); FileName = $name; Size = $total; Received = [long]0; Started = (Get-Date); Info = $null; Kind = 'folder'; Root = $root; Files = $files.ToArray(); Setup = '' }
    return @{ ok = $true; uploadId = $id }
}

function Global:Add-WebUploadChunk {
    # One piece of an upload (base64, at most 6 MB), at the offset the server expects next. One piece of an upload at
    # a time (2.38.0): two sent at once both passed the offset check, and both were appended.
    param($Data)
    $u = (Get-WebUploads)[[string]$Data.uploadId]
    if (-not $u) { return @{ ok = $false; error = 'That upload is no longer known - start again.' } }
    [System.Threading.Monitor]::Enter($u)
    try { return (Add-WebUploadChunkHeld -Upload $u -Data $Data) }
    finally { [System.Threading.Monitor]::Exit($u) }
}

function Global:Add-WebUploadChunkHeld {
    # Add-WebUploadChunk with the upload held.
    param($Upload, $Data)
    $u = $Upload
    $offset = [long]0; [void][long]::TryParse([string]$Data.offset, [ref]$offset)
    if ($u.Kind -eq 'folder') {
        # One piece of one of the folder's files (-index), in order.
        $i = -1; [void][int]::TryParse([string]$Data.index, [ref]$i)
        if ($i -lt 0 -or $i -ge @($u.Files).Count) { return @{ ok = $false; error = 'No such file in this upload.' } }
        $f = $u.Files[$i]
        if ($offset -ne $f.Received) { return @{ ok = $false; error = "Upload out of order (expected byte $($f.Received) of $($f.Path))."; expected = $f.Received } }
        try { $bytes = [Convert]::FromBase64String([string]$Data.data) } catch { return @{ ok = $false; error = 'A piece of the upload was damaged.' } }
        if ($bytes.Length -eq 0 -or $bytes.Length -gt 6MB -or $f.Received + $bytes.Length -gt $f.Size) { return @{ ok = $false; error = "That piece is larger than $($f.Path)." } }
        $fs = [System.IO.File]::Open((Join-Path $u.Root ($f.Path -replace '\\', [System.IO.Path]::DirectorySeparatorChar)), [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
        try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
        $f.Received += $bytes.Length; $u.Received += $bytes.Length
        return @{ ok = $true; received = $u.Received; fileReceived = $f.Received }
    }
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
        # Windows Installer on Windows, msitools on Linux (the container).
        $props = Get-MsiPropertyValues -Path $Path -Names @('ProductName', 'ProductVersion', 'Manufacturer', 'ProductCode')
        foreach ($k in @($props.Keys)) { $info[$k] = [string]$props[$k] }
    }
    else {
        # What it says about itself - read by Windows, or (the server) from its version block in the file:
        # Inno Setup and NSIS installers name the app and its version there (2.35.0).
        try {
            $vs = Get-ExeVersionStrings -Path $Path
            $info.ProductName = [string]$vs.ProductName; $info.Manufacturer = [string]$vs.CompanyName
            # A setup's own description ("Contoso Setup") isn't the app's name.
            if (-not $info.ProductName -and $vs.FileDescription -and $vs.FileDescription -notmatch '(?i)\b(setup|install(er)?)\b') { $info.ProductName = [string]$vs.FileDescription }
            $info.ProductVersion = Get-ExeVersionText -Path $Path
            if (-not $info.ProductVersion -and $vs.ProductVersion) { $info.ProductVersion = ([string]$vs.ProductVersion -replace ',\s*', '.') }
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
    if ($u.Kind -eq 'file') {
        $u.Info = Get-WebInstallerFacts $u.Path
        $u.Proposal = Get-InstallerProposal $u.Info
        return (Get-WebUploadAnswer $u)
    }
    # A .zip: unpacked without trusting it (Expand-ZipSafely); one folder at its top is the folder itself.
    if ($u.Kind -eq 'zip') {
        try { [void](Expand-ZipSafely -ZipPath $u.Path -Destination $u.Root) }
        catch { Remove-Item -LiteralPath $u.Root -Recurse -Force -ErrorAction SilentlyContinue; return @{ ok = $false; error = $_.Exception.Message } }
        Remove-Item -LiteralPath $u.Path -Force -ErrorAction SilentlyContinue
        $top = @(Get-ChildItem -LiteralPath $u.Root -Force)
        if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $u.Root = $top[0].FullName }
        if (-not @(Get-PackageFolderFiles $u.Root).Count) { return @{ ok = $false; error = 'The .zip holds no files.' } }
        $u.FileName = [System.IO.Path]::GetFileNameWithoutExtension($u.FileName)
    }
    $cands = @(Get-SetupFileCandidates (Get-PackageFolderFiles $u.Root))
    $u.Setup = $(if ($cands.Count) { [string]$cands[0].path } else { '' })
    Set-WebUploadProposal $u
    return (Get-WebUploadAnswer $u)
}

function Global:Set-WebUploadProposal {
    <#
      What an uploaded folder's setup file proposes ($u.Setup, a path in it): an .msi or .exe as a single
      installer does (its path in the commands); the PSADT 4 launcher its Install/Uninstall commands; an
      install.ps1 64-bit PowerShell. Nothing for none - the commands are then written in the editor.
    #>
    param($u)
    $rel = [string]$u.Setup
    $none = [ordered]@{ Name = [string]$u.FileName; Publisher = ''; Version = ''; InstallCommand = ''; UninstallCommand = ''; Detection = $null; NeedsUninstallScript = $false; Notes = @(); ManagedOk = $false }
    $u.Info = $null
    if (-not $rel) { $none.Notes = @('No installer found in it - choose the setup file, or write the commands in the editor.'); $u.Proposal = $none; return }
    $leaf = ($rel -split '[\\/]')[-1]
    $ps = '%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File'
    # In quotes when it needs them (2.38.0): "My App\install.ps1" ran ".\My" with "App\install.ps1" as its argument.
    $quote = { param([string]$p) if ($p -match '[^\w.\\\-]') { '"' + $p + '"' } else { $p } }
    if ($leaf -ieq 'Invoke-AppDeployToolkit.exe' -or $leaf -ieq 'Invoke-AppDeployToolkit.ps1') {
        $run = if ($leaf -ieq 'Invoke-AppDeployToolkit.exe') { & $quote $rel } else { "$ps $(& $quote $rel)" }
        $none.InstallCommand = "$run -DeploymentType Install -DeployMode Silent"; $none.UninstallCommand = "$run -DeploymentType Uninstall -DeployMode Silent"
        $none.Notes = @('A PSADT 4 package - set its detection rule in the editor (Install & detection).')
        $u.Proposal = $none; return
    }
    if ($leaf -ieq 'install.ps1') {
        $dir = Split-Path -Parent $rel
        $un = if ($dir) { "$dir\uninstall.ps1" } else { 'uninstall.ps1' }
        $none.InstallCommand = "$ps $(& $quote ".\$rel")"
        if (Test-Path -LiteralPath (Join-Path $u.Root ($un -replace '\\', [System.IO.Path]::DirectorySeparatorChar))) { $none.UninstallCommand = "$ps $(& $quote ".\$un")" }
        $none.Notes = @('A script package - set its detection rule in the editor (Install & detection).')
        $u.Proposal = $none; return
    }
    $u.Info = Get-WebInstallerFacts (Join-Path $u.Root ($rel -replace '\\', [System.IO.Path]::DirectorySeparatorChar))
    $u.Info.FileName = $rel
    $u.Proposal = Get-InstallerProposal $u.Info
    # A name only like "setup" or "install" says nothing - the folder's own name does.
    if (-not ([string]$u.Proposal.Name).Trim() -or ([string]$u.Proposal.Name) -match '^(?i)(setup|install|installer)\d*$') { $u.Proposal.Name = [string]$u.FileName }
}

function Global:Get-WebUploadAnswer {
    # What the page shows of a finished upload: the installer's facts and proposal, and for a folder its files and setup choices.
    param($u)
    $p = $u.Proposal; $i = $u.Info
    $apps = @((Read-WebCatalogRecords).Apps)
    $out = [ordered]@{ ok = $true; fileName = $u.FileName; size = $u.Size; kind = $(if ($i) { $i.Kind } else { '' }); exeKind = $(if ($i) { $i.ExeKind } else { '' }); signer = $(if ($i) { $i.Signer } else { '' }); productCode = $(if ($i) { $i.ProductCode } else { '' })
        name = $p.Name; publisher = $p.Publisher; version = $p.Version; installCommand = $p.InstallCommand; uninstallCommand = $p.UninstallCommand
        detection = $(if ($p.Detection) { $p.Detection.Type } else { '' }); managedOk = [bool]$p.ManagedOk; notes = @($p.Notes); nameProblem = (Test-WebAddName $p.Name $apps); folder = ($u.Kind -ne 'file') }
    if ($u.Kind -ne 'file') {
        $files = @(Get-PackageFolderFiles $u.Root)
        $out.fileCount = $files.Count
        $out.size = [long](($files | Measure-Object size -Sum).Sum)
        $out.files = @($files | Select-Object -First 300)
        $out.candidates = @(Get-SetupFileCandidates $files | ForEach-Object { $_.path })
        $out.setup = [string]$u.Setup
    }
    return $out
}

function Global:Set-WebUploadSetup {
    # Another setup file for an uploaded folder (one of its files): the proposal is made again from it.
    param($Data)
    $u = (Get-WebUploads)[[string]$Data.uploadId]
    if (-not $u -or $u.Kind -eq 'file' -or -not $u.Proposal) { return @{ ok = $false; error = 'That upload is no longer known - start again.' } }
    $rel = ([string]$Data.setup) -replace '/', '\'
    if ($rel -and -not ((Test-PackageRelativePath $rel) -and (Test-Path -LiteralPath (Join-Path $u.Root ($rel -replace '\\', [System.IO.Path]::DirectorySeparatorChar)) -PathType Leaf))) { return @{ ok = $false; error = "'$rel' isn't a file of this folder." } }
    $u.Setup = $rel
    Set-WebUploadProposal $u
    return (Get-WebUploadAnswer $u)
}

function Global:Copy-WebUploadInto {
    # The uploaded installer (or the uploaded folder's files) into -Folder; -Replace empties it first. The paths written.
    param($u, [string]$Folder, [switch]$Replace)
    if ($Replace -and (Test-Path -LiteralPath $Folder)) { Get-ChildItem -LiteralPath $Folder -Force | Remove-Item -Recurse -Force }
    if (-not (Test-Path -LiteralPath $Folder)) { [void](New-Item -ItemType Directory -Path $Folder -Force) }
    if ($u.Kind -eq 'file') { Copy-Item -LiteralPath $u.Path -Destination (Join-Path $Folder $u.FileName) -Force; return @($u.FileName) }
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $written = foreach ($f in @(Get-PackageFolderFiles $u.Root)) {
        $dest = Join-Path $Folder ($f.path -replace '\\', $sep)
        $d = Split-Path -Parent $dest; if (-not (Test-Path -LiteralPath $d)) { [void](New-Item -ItemType Directory -Path $d -Force) }
        Copy-Item -LiteralPath (Join-Path $u.Root ($f.path -replace '\\', $sep)) -Destination $dest -Force
        $f.path
    }
    return @($written)
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
        $other = @(Get-PackageFolderFiles $folder | Where-Object { $u.Kind -ne 'file' -or $_.path -ne $u.FileName })
        if ($other.Count) { return @{ ok = $false; error = "$folder already holds files ($($other[0].path)) - choose another name, or empty that folder first." } }
    }
    [void](Copy-WebUploadInto $u $folder)
    $setup = if ($u.Kind -eq 'file') { '' } else { [string]$u.Setup }
    if ($p.NeedsUninstallScript) {
        $label = if ($u.Info.ProductName) { $u.Info.ProductName } else { $name }
        [System.IO.File]::WriteAllText((Join-Path $folder 'Uninstall.ps1'), (New-InstalledAppUninstallScript -DisplayName $label -ExeKind $u.Info.ExeKind), (New-Object System.Text.UTF8Encoding($true)))
    }
    $groups = Get-WebAddGroupLists $Data
    $install = ([string]$Data.installCommand).Trim(); if (-not $install) { $install = $p.InstallCommand }
    $uninstall = ([string]$Data.uninstallCommand).Trim(); if (-not $uninstall) { $uninstall = $p.UninstallCommand }
    $edit = [pscustomobject]@{ appName = $name; wingetId = ''; appId = ''; requiredFor = $groups.Required; availableFor = $groups.Available; uninstallFor = @(); excludeFor = $groups.Exclude; managedUpdates = $false
        metadata = [pscustomobject]@{ description = $(if ([string]$Data.description) { [string]$Data.description } else { $name }); publisher = ([string]$Data.publisher).Trim(); appVersion = $version
            installCommand = $install; uninstallCommand = $uninstall; owner = [string]$Global:App.DefaultAppSettings.DefaultOwner; developer = ''; informationUrl = ''; privacyUrl = ''
            notes = "Added from $($u.FileName)$(if ($u.Info.Signer) { ", signed by $($u.Info.Signer)" })." } }
    $r = Save-WebApp @{ originalName = ''; version = ''; app = $edit }
    if (-not $r.ok) { return $r }
    $rule = $p.Detection
    if ($rule -and $version -and $rule.Type -eq 'Msi') { $rule.Msi_Version = $version }
    $managed = [bool]$Data.managed -and [bool]$p.ManagedOk
    [void](Update-WebCatalogApp -Name $r.name -Change {
            param($app)
            if ($setup) { $app.setupFile = $setup }
            if ($rule) { $app.metadata.detectionRule = [pscustomobject]$rule }
            if ($managed) { $app.managedUpdates = $true; [void](Set-ManagedAppPin $app -ProductCode ([string]$u.Info.ProductCode)) }
        }.GetNewClosure())
    Remove-Item -LiteralPath (Split-Path $u.Path -Parent) -Recurse -Force -ErrorAction SilentlyContinue
    (Get-WebUploads).Remove([string]$Data.uploadId)
    Write-Log "[OK] Added $($r.name) from $($u.FileName) ($($p.Detection.Type) detection) - its installer is in $folder."
    return @{ ok = $true; name = $r.name; folder = $folder }
}

function Global:Set-WebAppInstaller {
    <#
      An uploaded installer for an app already in the catalog (one with its own package, no Winget ID) - an app
      taken over from Intune comes without it (Intune never gives an .msi back). The file goes into its packages
      folder; what is still empty is filled in from it (install and uninstall command, detection rule, version,
      publisher) - what the app already has stays. Package then builds it; Send to Intune sends it.
    #>
    param($Data)
    $u = (Get-WebUploads)[[string]$Data.uploadId]
    if (-not $u -or -not $u.Proposal) { return @{ ok = $false; error = 'That upload is no longer known - choose the installer again.' } }
    $name = [string]$Data.name
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$name' in the catalog." } }
    if (([string]$a.wingetId).Trim()) { return @{ ok = $false; error = "$name installs from winget - it has no installer of its own." } }
    $folder = Join-Path (Get-AppFolder -Kind Packages -Create) (Get-SafeFileNameForApp -Name $a.appName)
    # Files there already: replaced, or added to (-mode) - asked, never guessed. A managed app's new version is a release.
    $have = @(Get-PackageFolderFiles $folder)
    $mode = [string]$Data.mode
    if ($have.Count) {
        if ($a.managedUpdates -and $a.appId) { return @{ ok = $false; error = "$($a.appName) has managed updates - a new installer goes through Release new version (Updates), pilot first." } }
        if ($mode -notin 'replace', 'add') { return @{ ok = $false; needsChoice = $true; existing = $have.Count; error = "Its packages folder already holds $($have.Count) file(s) - replace them, or add to them?" } }
    }
    $written = @(Copy-WebUploadInto $u $folder -Replace:($mode -eq 'replace'))
    $p = $u.Proposal; $info = $u.Info
    $setup = if ($u.Kind -eq 'file') { [string]$u.FileName } else { [string]$u.Setup }
    if ($p.NeedsUninstallScript -and -not (Test-Path -LiteralPath (Join-Path $folder 'Uninstall.ps1'))) {
        $label = if ($info.ProductName) { $info.ProductName } else { $a.appName }
        [System.IO.File]::WriteAllText((Join-Path $folder 'Uninstall.ps1'), (New-InstalledAppUninstallScript -DisplayName $label -ExeKind $info.ExeKind), (New-Object System.Text.UTF8Encoding($true)))
    }
    $filled = New-Object System.Collections.Generic.List[string]
    [void](Update-WebCatalogApp -Name $a.appName -Change {
            param($app)
            # The setup file Package uses: the one chosen (or the uploaded installer itself).
            if ($setup) { $app.setupFile = $setup }
            if (-not $app.metadata) { $app.metadata = Get-DefaultAppMetadata -AppName $app.appName -WingetId '' -Uncommon $true }
            $m = $app.metadata
            # The placeholder an app without settings gets (install.ps1 / uninstall.ps1 that aren't there) counts as empty.
            $tpl = Get-CreateAppTemplates -WingetId '' -Uncommon $true
            $empty = { param($k) $now = ([string]$m.$k).Trim(); -not $now -or (($now -eq $tpl.Install -or $now -eq $tpl.Uninstall) -and -not (Test-Path -LiteralPath (Join-Path $folder ($(if ($k -eq 'installCommand') { 'install.ps1' } else { 'uninstall.ps1' }))))) }
            $set = { param($k, $v, $label) if ($v -and (& $empty $k)) { $m | Add-Member -NotePropertyName $k -NotePropertyValue $v -Force; $filled.Add($label) } }
            & $set 'installCommand' ([string]$p.InstallCommand) 'the install command'
            & $set 'uninstallCommand' ([string]$p.UninstallCommand) 'the uninstall command'
            $v = [string]$p.Version
            if ($v -and (Test-ReleaseVersionText $v)) { & $set 'appVersion' $v 'the version' }
            & $set 'publisher' ([string]$p.Publisher) 'the publisher'
            if ($p.Detection -and -not $m.detectionRule) {
                $rule = $p.Detection
                $ver = [string]$m.appVersion
                if ($rule.Type -eq 'Msi' -and $ver) { $rule.Msi_Version = $ver }
                $m | Add-Member -NotePropertyName detectionRule -NotePropertyValue ([pscustomobject]$rule) -Force; $filled.Add("the detection rule ($($rule.Type))")
            }
        }.GetNewClosure())
    Remove-Item -LiteralPath (Split-Path $u.Path -Parent) -Recurse -Force -ErrorAction SilentlyContinue
    (Get-WebUploads).Remove([string]$Data.uploadId)
    $what = if ($u.Kind -eq 'file') { $u.FileName } else { "$($written.Count) file(s) from $($u.FileName)$(if ($setup) { " (setup: $setup)" })" }
    Add-WebHistoryEntry -App $a.appName -Kind 'catalog' -Text "$(if ($mode -eq 'replace') { 'Packages folder replaced with' } else { 'Added to its packages folder:' }) $what$(if ($filled.Count) { "; filled in: $($filled -join ', ')" })"
    Write-Log "[OK] $($a.appName): $what in its packages folder$(if ($filled.Count) { " - filled in $($filled -join ', ')" })."
    return @{ ok = $true; fileName = $u.FileName; files = $written.Count; setup = $setup; filled = $filled.ToArray(); kind = [string]$(if ($info) { $info.Kind }); folder = $folder }
}

# ---------------------------------------------------------------- an app's packages folder, as files (2.34.0)

function Global:Get-WebPackageFiles {
    # The files in an own-package app's packages folder (what Package builds into its .intunewin), the setup file, the built package.
    param($Data)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$($Data.name)' in the catalog." } }
    if (([string]$a.wingetId).Trim()) { return @{ ok = $false; error = "$($a.appName) installs from winget - it has no packages folder of its own." } }
    $folder = Join-Path (Get-AppFolder -Kind Packages) (Get-SafeFileNameForApp -Name $a.appName)
    $files = @(Get-PackageFolderFiles $folder)
    $built = @(Get-PackageFolderFiles $folder -All | Where-Object { $_.path -match '(?i)\.intunewin$' } | Select-Object -First 1)
    return @{ ok = $true; folder = $folder; files = $files; total = [long](($files | Measure-Object size -Sum).Sum); setupFile = [string]$a.setupFile
        package = $(if ($built.Count) { $built[0] } else { $null }) }
}

function Global:Remove-WebPackageFile {
    # One file out of an app's packages folder - only a file inside it. The chosen setup file, deleted, is forgotten.
    param($Data)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$($Data.name)' in the catalog." } }
    $rel = ([string]$Data.path) -replace '/', '\'
    if (-not (Test-PackageRelativePath $rel)) { return @{ ok = $false; error = "'$rel' isn't a file of its packages folder." } }
    $folder = Join-Path (Get-AppFolder -Kind Packages) (Get-SafeFileNameForApp -Name $a.appName)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    $root = [System.IO.Path]::GetFullPath($folder).TrimEnd($sep) + $sep
    $full = [System.IO.Path]::GetFullPath((Join-Path $folder ($rel -replace '\\', $sep)))
    if (-not $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $full -PathType Leaf)) { return @{ ok = $false; error = "'$rel' isn't a file of its packages folder." } }
    Remove-Item -LiteralPath $full -Force
    # Folders left empty go too (up to the packages folder itself).
    $d = Split-Path -Parent $full
    while ($d -and ($d.TrimEnd($sep) + $sep).Length -gt $root.Length -and -not @(Get-ChildItem -LiteralPath $d -Force).Count) { Remove-Item -LiteralPath $d -Force; $d = Split-Path -Parent $d }
    if ([string]$a.setupFile -and ([string]$a.setupFile).ToLowerInvariant() -eq $rel.ToLowerInvariant()) { [void](Update-WebCatalogApp -Name $a.appName -Change { param($x) $x.setupFile = '' }) }
    Add-WebHistoryEntry -App $a.appName -Kind 'catalog' -Text "Deleted $rel from its packages folder"
    Write-Log "[OK] $($a.appName): deleted $rel from its packages folder."
    return @{ ok = $true }
}

function Global:Set-WebPackageSetup {
    # The setup file Package uses for an app: one of its packages folder's files ('' - the best one found).
    param($Data)
    $a = (Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq [string]$Data.name } | Select-Object -First 1
    if (-not $a) { return @{ ok = $false; error = "No app called '$($Data.name)' in the catalog." } }
    $rel = ([string]$Data.path) -replace '/', '\'
    if ($rel) {
        $folder = Join-Path (Get-AppFolder -Kind Packages) (Get-SafeFileNameForApp -Name $a.appName)
        if (-not (Test-PackageRelativePath $rel) -or -not (@(Get-PackageFolderFiles $folder) | Where-Object { $_.path -eq $rel })) { return @{ ok = $false; error = "'$rel' isn't a file of its packages folder." } }
    }
    [void](Update-WebCatalogApp -Name $a.appName -Change { param($x) $x.setupFile = $rel }.GetNewClosure())
    return @{ ok = $true; setupFile = $rel }
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
    $edit = [pscustomobject]@{ appName = $name; wingetId = ''; appId = ''; requiredFor = $groups.Required; availableFor = $groups.Available; uninstallFor = @(); excludeFor = $groups.Exclude; managedUpdates = $false
        metadata = [pscustomobject]@{ description = $(if ([string]$Data.description) { [string]$Data.description } else { $name }); publisher = ([string]$Data.publisher).Trim(); appVersion = $version
            installCommand = "$ps .\Install.ps1"; uninstallCommand = "$ps .\Uninstall.ps1"; owner = [string]$Global:App.DefaultAppSettings.DefaultOwner; developer = ''; informationUrl = ''; privacyUrl = ''; notes = 'A script app: Install.ps1 and Uninstall.ps1 in its packages folder.' } }
    $r = Save-WebApp @{ originalName = ''; version = ''; app = $edit }
    if (-not $r.ok) { return $r }
    $rule = if ($useMarker) { Get-ScriptAppMarkerRule -Name $name -Version $version } else { [ordered]@{ Type = 'Script'; Script_Content = (ConvertTo-CanonicalLineEndings ([string]$Data.detectScript)).TrimEnd() } }
    # Managed updates by default when the version marker detects it (a version-comparing rule), unless turned off.
    $managed = $useMarker -and [bool]$version -and $Data.managed -ne $false
    [void](Update-WebCatalogApp -Name $r.name -Change { param($app) $app.metadata.detectionRule = [pscustomobject]$rule; if ($managed) { $app.managedUpdates = $true } }.GetNewClosure())
    Write-Log "[OK] Added the script app $($r.name) - Install.ps1 and Uninstall.ps1 are in $folder."
    return @{ ok = $true; name = $r.name; folder = $folder }
}

# ---------------------------------------------------------------- a PSADT (PowerShell App Deployment Toolkit) app

function Global:Save-WebPsadtTemplate {
    # The PSADT 4 template from its GitHub release into -Folder (https, 60 MB at most). '' when it worked, else why not.
    param([string]$Folder)
    if ($Global:App.TestGraph) { return 'Test mode: nothing is downloaded.' }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('psadt-' + [guid]::NewGuid().ToString('N'))
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $p = @{ Uri = 'https://api.github.com/repos/PSAppDeployToolkit/PSAppDeployToolkit/releases/latest'; Headers = @{ 'User-Agent' = 'IntuneAppCatalog'; Accept = 'application/vnd.github+json' }; TimeoutSec = 15; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSEdition -eq 'Desktop') { $p.UseBasicParsing = $true }
        $rel = Invoke-RestMethod @p
        $asset = @($rel.assets | Where-Object { [string]$_.name -match '^PSAppDeployToolkit_Template_v4\.zip$' }) | Select-Object -First 1
        if (-not $asset) { return "The PSADT release $($rel.tag_name) has no template zip - download it by hand from GitHub (PSAppDeployToolkit) into $Folder." }
        [void](New-Item -ItemType Directory -Path $tmp -Force)
        $zip = Join-Path $tmp 'template.zip'
        Invoke-WebHttpsGet -Uri ([string]$asset.browser_download_url) -MaxBytes 60MB -OutFile $zip -TimeoutSec 120
        $out = Join-Path $tmp 'x'
        Expand-Archive -LiteralPath $zip -DestinationPath $out -Force
        $main = Get-ChildItem -LiteralPath $out -Filter 'Invoke-AppDeployToolkit.ps1' -File -Recurse | Select-Object -First 1
        if (-not $main) { return 'The downloaded template has no Invoke-AppDeployToolkit.ps1.' }
        # It runs as SYSTEM on every device it goes to: the toolkit's module must be validly signed (Authenticode) - else nothing is copied.
        $module = @(Get-ChildItem -LiteralPath $main.DirectoryName -Filter 'PSAppDeployToolkit.psm1' -File -Recurse) | Select-Object -First 1
        if (-not $module) { return 'The downloaded template has no PSAppDeployToolkit module - not used.' }
        if (-not (Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue)) { return 'The template''s signature can only be checked on Windows - download it by hand.' }
        $sig = Get-AuthenticodeSignature -LiteralPath $module.FullName
        if ($sig.Status -ne 'Valid') { return "The PSADT module in release $($rel.tag_name) isn't validly signed ($($sig.Status)) - not used. Download the template by hand from GitHub (PSAppDeployToolkit) if you trust it." }
        Write-Log "[INFO] PSADT module signed by: $($sig.SignerCertificate.Subject)"
        # Not only the module: every program and module file runs on the devices too. The .exe, .psm1 and .psd1 files must carry
        # the same signer as the module (a swapped launcher next to the real module isn't accepted), .dll files a valid signature.
        $thumb = [string]$sig.SignerCertificate.Thumbprint
        foreach ($f in @(Get-ChildItem -LiteralPath $main.DirectoryName -File -Recurse | Where-Object { $_.Extension -in '.exe', '.psm1', '.psd1', '.dll' })) {
            $fs = Get-AuthenticodeSignature -LiteralPath $f.FullName
            $sameSigner = $fs.SignerCertificate -and [string]$fs.SignerCertificate.Thumbprint -eq $thumb
            if ($fs.Status -ne 'Valid' -or ($f.Extension -ne '.dll' -and -not $sameSigner)) { return "$($f.Name) in the PSADT release $($rel.tag_name) isn't signed by the toolkit's signer ($($fs.Status)) - the template isn't used. Download it by hand from GitHub (PSAppDeployToolkit) if you trust it." }
        }
        Copy-Item -Path (Join-Path $main.DirectoryName '*') -Destination $Folder -Recurse -Force
        Write-Log "[OK] PSADT $($rel.tag_name) template put in $Folder."
        return ''
    }
    catch { return "The PSADT template couldn't be downloaded: $($_.Exception.Message)" }
    finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Global:Add-WebPsadtApp {
    <#
      Adds an app packaged with the PowerShell App Deployment Toolkit 4: the
      template in Packages\<app> (downloaded, or already put there), its
      Invoke-AppDeployToolkit.ps1 filled in with the vendor, name and version
      and the version marker; installed and uninstalled with the toolkit's
      own commands, detected by the marker (managed updates can follow it).
    #>
    param($Data)
    $name = ([string]$Data.name).Trim() -replace '\s+', ' '
    $all = @((Read-WebCatalogRecords).Apps)
    $why = Test-WebAddName $name $all
    if ($why) { return @{ ok = $false; error = $why } }
    # Its packages folder is named like its catalog file - another app with the same file name would have its template rewritten.
    $clash = @($all | Where-Object { (Get-SafeFileNameForApp -Name $_.appName) -ieq (Get-SafeFileNameForApp -Name $name) }) | Select-Object -First 1
    if ($clash) { return @{ ok = $false; error = "'$name' would share its file and packages folder with '$($clash.appName)' - pick another name." } }
    $version = ([string]$Data.version).Trim()
    if (-not (Test-ReleaseVersionText $version)) { return @{ ok = $false; error = 'Give the version you are packaging (letters, digits and . - + _) - the detection rule checks for it.' } }
    $folder = Join-Path (Get-AppFolder -Kind Packages -Create) (Get-SafeFileNameForApp -Name $name)
    if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force) }
    $main = Join-Path $folder 'Invoke-AppDeployToolkit.ps1'
    if (-not (Test-Path -LiteralPath $main)) {
        if (-not $Data.download) { return @{ ok = $false; error = "Put the PSADT 4 template in $folder (Invoke-AppDeployToolkit.ps1 and the PSAppDeployToolkit folder), or tick Download." } }
        $err = Save-WebPsadtTemplate $folder
        if ($err) { return @{ ok = $false; error = $err } }
    }
    $fill = Set-PsadtTemplateValues -Text (Get-Content -LiteralPath $main -Raw -Encoding UTF8) -Name $name -Vendor ([string]$Data.publisher) -Version $version
    [System.IO.File]::WriteAllText($main, $fill.Text, (New-Object System.Text.UTF8Encoding($true)))
    $exe = Test-Path -LiteralPath (Join-Path $folder 'Invoke-AppDeployToolkit.exe')
    $run = if ($exe) { 'Invoke-AppDeployToolkit.exe' } else { '%SystemRoot%\sysnative\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File Invoke-AppDeployToolkit.ps1' }
    $groups = Get-WebAddGroupLists $Data
    $edit = [pscustomobject]@{ appName = $name; wingetId = ''; appId = ''; requiredFor = $groups.Required; availableFor = $groups.Available; uninstallFor = @(); excludeFor = $groups.Exclude; managedUpdates = $false
        metadata = [pscustomobject]@{ description = $(if ([string]$Data.description) { [string]$Data.description } else { $name }); publisher = ([string]$Data.publisher).Trim(); appVersion = $version
            installCommand = "$run -DeploymentType Install -DeployMode Silent"; uninstallCommand = "$run -DeploymentType Uninstall -DeployMode Silent"
            owner = [string]$Global:App.DefaultAppSettings.DefaultOwner; developer = ''; informationUrl = ''; privacyUrl = ''; notes = 'Packaged with the PowerShell App Deployment Toolkit 4 - edit Invoke-AppDeployToolkit.ps1 in its packages folder.' } }
    $r = Save-WebApp @{ originalName = ''; version = ''; app = $edit }
    if (-not $r.ok) { return $r }
    $rule = Get-ScriptAppMarkerRule -Name $name -Version $version
    $markerOk = @($fill.Missing | Where-Object { $_ -like 'marker*' }).Count -eq 0
    [void](Update-WebCatalogApp -Name $r.name -Change { param($app) $app.metadata.detectionRule = [pscustomobject]$rule; if ($markerOk) { $app.managedUpdates = $true } }.GetNewClosure())
    Write-Log "[OK] Added the PSADT app $($r.name) - edit Invoke-AppDeployToolkit.ps1 in $folder."
    return @{ ok = $true; name = $r.name; folder = $folder; filled = @($fill.Filled); missing = @($fill.Missing) }
}

function Global:Get-WebWingetVersions {
    # The versions winget has for one package, newest first - for picking an App version instead of typing it. Cached ten minutes.
    param($Data)
    $id = ([string]$Data.id).Trim()
    if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9.\-_+]{0,127}$') { return @{ ok = $false; error = "'$id' isn't a Winget ID." } }
    if (-not $Global:App.WingetVersionsCache) { $Global:App.WingetVersionsCache = [hashtable]::Synchronized(@{}) }
    $hit = $Global:App.WingetVersionsCache[$id.ToLowerInvariant()]
    if ($hit -and ((Get-Date) - $hit.at).TotalMinutes -lt 10) { return @{ ok = $true; versions = @($hit.versions) } }
    # Microsoft's WinGet module first (objects, any Windows language), else winget.exe's text.
    $viaModule = Find-WingetClientPackage -Id $id
    $v = @(if ($viaModule) { @($viaModule)[0].Versions | Select-Object -First 100 })
    if (-not $v.Count) {
        try { $r = Invoke-Winget -Arguments @('show', '--id', $id, '--exact', '--versions', '--accept-source-agreements', '--disable-interactivity') -TimeoutSeconds 45 }
        catch { return @{ ok = $false; error = $_.Exception.Message } }
        $v = @(ConvertFrom-WingetVersionsOutput $r.StdOut)
    }
    if (-not $v.Count) { return @{ ok = $false; error = "winget lists no versions for '$id'." } }
    $Global:App.WingetVersionsCache[$id.ToLowerInvariant()] = @{ at = (Get-Date); versions = $v }
    return @{ ok = $true; versions = $v }
}

function Global:Invoke-WebFillDetails {
    <#
      Fill in details: the Intune fields still empty on these apps (or every
      Winget app, without -names) taken from winget show - publisher,
      description, information and privacy links, developer - and the owner
      from Settings. Never the App version, never a field already set. winget
      is asked first (outside the lock), the apps are written after, with Undo.
    #>
    param($Data)
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue) -and -not (Test-WingetIndexUsable) -and -not $Global:App.TestGraph) { return @{ ok = $false; error = "winget.exe isn't on this machine, so there's nothing to fill the details from. It comes with the 'App Installer' package on Windows 10 and 11." } }
    $all = @((Read-WebCatalogRecords).Apps)
    $names = @($Data.names | ForEach-Object { [string]$_ } | Where-Object { $_ })
    $apps = @($all | Where-Object { $_.wingetId -and (-not $names.Count -or $names -contains $_.appName) })
    if (-not $apps.Count) { return @{ ok = $false; error = 'None of these apps has a Winget ID to ask winget about - fill their details in the editor.' } }
    $owner = [string]$Global:App.DefaultAppSettings.DefaultOwner
    $plans = New-Object System.Collections.Generic.List[object]
    $failed = New-Object System.Collections.Generic.List[string]
    $asked = Read-WebDetailsAsked
    $lacking = New-Object System.Collections.Generic.List[object]
    foreach ($a in ($apps | Select-Object -First 200)) {
        try {
            $r = Invoke-Winget -Arguments @('show', '--id', [string]$a.wingetId, '--exact', '--accept-source-agreements', '--disable-interactivity')
            $d = ConvertFrom-WingetShowOutput $r.StdOut
            if (-not $d.Id) { $failed.Add("$($a.appName) (winget doesn't know $($a.wingetId))"); continue }
            $fill = Get-AppDetailsFill -Metadata $a.metadata -Details $d -AppName $a.appName -DefaultOwner $owner
            if ($fill.Count) { $plans.Add(@{ name = $a.appName; fill = $fill }) }
            # What stays empty because winget's entry doesn't have it: Home stops asking for those (Get-WebDetailsGaps).
            $gaps = @(Get-WebDetailsGaps -App $a -Fill $fill)
            $asked[[string]$a.appName] = @{ id = [string]$a.wingetId; missing = $gaps }
            if ($gaps.Count) { $lacking.Add([ordered]@{ name = [string]$a.appName; fields = $gaps }) }
        }
        catch { $failed.Add("$($a.appName) ($($_.Exception.Message))") }
    }
    $done = New-Object System.Collections.Generic.List[object]
    if ($plans.Count) {
        $undo = New-WebUndo "Fill in details ($($plans.Count) app(s))"
        Invoke-WithCatalogLock {
            foreach ($p in $plans) {
                try {
                    [void](Update-WebCatalogApp -Name $p.name -Undo $undo -Change {
                            param($app)
                            if (-not $app.metadata) { $app | Add-Member -NotePropertyName metadata -NotePropertyValue ([pscustomobject]@{}) -Force }
                            foreach ($k in @($p.fill.Keys)) {
                                # Still empty now (someone may have typed it meanwhile): only then.
                                $cur = if ($app.metadata.PSObject.Properties[$k] -and $null -ne $app.metadata.$k) { [string]$app.metadata.$k } else { '' }
                                if ($cur.Trim() -and -not ($k -eq 'description' -and $cur.Trim() -eq ([string]$app.appName).Trim())) { continue }
                                if ($app.metadata.PSObject.Properties[$k]) { $app.metadata.$k = $p.fill[$k] } else { $app.metadata | Add-Member -NotePropertyName $k -NotePropertyValue $p.fill[$k] }
                            }
                        }.GetNewClosure())
                    $done.Add([ordered]@{ name = $p.name; fields = @($p.fill.Keys) })
                }
                catch { $failed.Add("$($p.name) ($($_.Exception.Message))") }
            }
        }
        if ($done.Count) { Save-WebUndo $undo }
    }
    try { Save-WebDetailsAsked $asked } catch { Write-Log "[WARN] Couldn't keep what winget lacks: $($_.Exception.Message)" }
    Write-Log "[OK] Fill in details: $($done.Count) app(s) filled$(if ($lacking.Count) { "; winget has no $((@($lacking | ForEach-Object { "$($_.name): $($_.fields -join ', ')" })) -join '; ')" })$(if ($failed.Count) { "; not asked or not known: $($failed -join '; ')" })."
    return @{ ok = $true; filled = $done.ToArray(); asked = $apps.Count; failed = $failed.ToArray(); lacking = $lacking.ToArray() }
}

# Home's "details missing" counts publisher, description and information link. When winget's entry simply has
# no such field, Fill in details can't fill it - what it lacked (per app and Winget ID) is kept next to the
# catalog (.integrity\details-asked.json), so Home stops asking for it until the Winget ID changes.
function Global:Get-WebDetailsGaps {
    # The Home fields that stay empty after -Fill (labels as people read them).
    param($App, $Fill)
    $m = $App.metadata
    $val = { param($k) if ($Fill -and $Fill.Contains($k)) { [string]$Fill[$k] } elseif ($m -and $m.PSObject.Properties[$k]) { [string]$m.$k } else { '' } }
    $gaps = @()
    if (-not (& $val 'publisher').Trim()) { $gaps += 'publisher' }
    $d = (& $val 'description').Trim()
    if (-not $d -or $d -eq ([string]$App.appName).Trim()) { $gaps += 'description' }
    if (-not (& $val 'informationUrl').Trim()) { $gaps += 'information link' }
    return $gaps
}
function Global:Read-WebDetailsAsked {
    $file = Join-Path (Get-WebIntegrityFolder) 'details-asked.json'
    $map = @{}
    if (Test-Path -LiteralPath $file) {
        try { foreach ($p in (Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties) { $map[$p.Name] = @{ id = [string]$p.Value.id; missing = @($p.Value.missing | ForEach-Object { [string]$_ }) } } } catch { }
    }
    return $map
}
function Global:Save-WebDetailsAsked {
    param([hashtable]$Map)
    $o = [ordered]@{}; foreach ($k in @($Map.Keys | Sort-Object)) { $o[$k] = $Map[$k] }
    [System.IO.File]::WriteAllText((Join-Path (Get-WebIntegrityFolder -Create) 'details-asked.json'), (ConvertTo-Json -InputObject $o -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
}

function Global:Get-WebFillPreview {
    # The editor's Fill from winget: what winget would fill into the fields as they are in the editor now (nothing saved).
    param($Data)
    $r = Get-WebWingetDetails @{ id = [string]$Data.id }
    if (-not $r.ok) { return $r }
    $cur = [pscustomobject]@{ publisher = [string]$Data.publisher; description = [string]$Data.description; informationUrl = [string]$Data.informationUrl; privacyUrl = [string]$Data.privacyUrl; developer = [string]$Data.developer; owner = [string]$Data.owner }
    $fill = Get-AppDetailsFill -Metadata $cur -Details $r.details -AppName ([string]$Data.name) -DefaultOwner ([string]$Global:App.DefaultAppSettings.DefaultOwner)
    return @{ ok = $true; fill = $fill }
}
