<#
  Intune App Catalog - web interface: exporting apps to a .zip and importing them on another instance (2.38.65).

  The .zip holds:
    ica-export.json            what it is: the format, the app's version, when, and the apps in it
    apps/<file>.json           each app's catalog file - its settings, groups (by name), icon, detection, commands
    packages/<file>/...        each app's packages folder (its installer, scripts, other files) - never the
                               .intunewin, which the other instance builds from these files itself

  Export: the .zip is written in the background (a big library takes a while) and fetched in pieces by the page.
  Import: the .zip is uploaded like an installer (in pieces), shown first (new, already in the catalog), then added:
  apps not in the catalog are added, ones in it are skipped or replaced - as chosen. "Another tenant" leaves out what
  only means something in the tenant it came from (App IDs, releases, supersedence, the package last uploaded);
  groups stay by name and are found by name in the new tenant on the first Send.
#>

function Global:Get-WebLibraryExports {
    if (-not $Global:App.LibraryExports) { $Global:App.LibraryExports = [hashtable]::Synchronized(@{}) }
    return $Global:App.LibraryExports
}

function Global:Get-WebLibraryPackageFolder {
    # An app's packages folder (<Packages>\<its file name>) - '' when it has none, or it is (or goes through) a link.
    param([string]$Name)
    $folder = Join-Path (Get-AppFolder -Kind Packages) (Get-SafeFileNameForApp -Name $Name)
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) { return '' }
    if (Test-WebPathThroughLink $folder) { return '' }
    return $folder
}

function Global:Get-WebLibraryExportEntries {
    <#
      What goes into the .zip for -Apps: @{ Entries = @(@{ Name; Text } | @{ Name; Source }); Files; Bytes; Skipped }.
      Package files: everything in the app's packages folder but the .intunewin, links and files through a link.
    #>
    param($Apps)
    $entries = New-Object System.Collections.Generic.List[object]
    $list = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[string]
    [long]$bytes = 0; $files = 0
    $sep = [System.IO.Path]::DirectorySeparatorChar
    foreach ($a in @($Apps)) {
        $leaf = Get-SafeFileNameForApp -Name ([string]$a.appName)
        $entries.Add(@{ Name = "apps/$leaf.json"; Text = (ConvertTo-SingleAppJson -App $a) })
        $n = 0; [long]$b = 0
        $folder = Get-WebLibraryPackageFolder ([string]$a.appName)
        if ($folder) {
            foreach ($f in @(Get-PackageFolderFiles $folder)) {
                $src = Join-Path $folder ($f.path -replace '\\', $sep)
                $item = Get-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
                if (-not $item -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or (Test-WebPathThroughLink $src) -or -not (Test-PackageRelativePath $f.path)) { $skipped.Add("$($a.appName): $($f.path)"); continue }
                $entries.Add(@{ Name = "packages/$leaf/" + ($f.path -replace '\\', '/'); Source = $item.FullName })
                $n++; $b += [long]$f.size
            }
        }
        $files += $n; $bytes += $b
        $list.Add([ordered]@{ name = [string]$a.appName; file = "apps/$leaf.json"; packages = $(if ($n) { "packages/$leaf/" } else { '' }); files = $n; bytes = $b })
    }
    return @{ Entries = $entries; Apps = $list.ToArray(); Files = $files; Bytes = $bytes; Skipped = $skipped.ToArray() }
}

function Global:Remove-WebStaleLibraryExports {
    # Exports older than a day go (a page closed before it fetched the .zip never says it is done).
    $ex = Get-WebLibraryExports
    foreach ($k in @($ex.Keys)) {
        $e = $ex[$k]
        if ($e.Started -lt (Get-Date).AddDays(-1)) { Remove-WebLibraryExportFiles $e; $ex.Remove($k) }
    }
}

function Global:Remove-WebLibraryExportFiles {
    param($Export)
    try { if ($Export.PS) { $Export.PS.Dispose() } } catch { $null = $_ }
    Remove-Item -LiteralPath ([string]$Export.Path), ([string]$Export.Path + '.part') -Force -ErrorAction SilentlyContinue
}

function Global:Start-WebLibraryExport {
    <#
      Starts writing the .zip of -names (every app when none is given), in the background. @{ ok; exportId; apps; files;
      bytes; fileName }. The page asks /api/library-export-status until it is done, then fetches it in pieces.
    #>
    param($Data)
    $all = @((Read-WebCatalogRecords).Apps)
    $names = @(@($Data.names) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $pick = if ($names.Count) { @($all | Where-Object { $names -contains [string]$_.appName }) } else { $all }
    if (-not $pick.Count) { return @{ ok = $false; error = $(if ($names.Count) { 'None of these apps is in the catalog any more - Reload.' } else { 'The catalog is empty - nothing to export.' }) } }
    Remove-WebStaleLibraryExports
    $plan = Get-WebLibraryExportEntries $pick
    $manifest = [ordered]@{ format = 'intune-app-catalog-export'; formatVersion = 1; appVersion = [string]$Global:App.AppVersion
        exportedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'); apps = @($plan.Apps) }
    $plan.Entries.Insert(0, @{ Name = 'ica-export.json'; Text = ($manifest | ConvertTo-Json -Depth 6) })
    $id = [guid]::NewGuid().ToString('N')
    $dir = Join-Path ([System.IO.Path]::GetTempPath()) 'intunecat-export'
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    $path = Join-Path $dir "$id.zip"
    $status = [hashtable]::Synchronized(@{ Done = $false; Error = ''; Written = [long]0; Total = [long]$plan.Bytes })
    $work = {
        param([string]$ZipPath, $Entries, $Status)
        $ErrorActionPreference = 'Stop'
        try {
            Add-Type -AssemblyName System.IO.Compression
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $part = "$ZipPath.part"
            $fs = [System.IO.File]::Create($part)
            try {
                $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create, $true)
                try {
                    $utf8 = New-Object System.Text.UTF8Encoding($false)
                    $buf = New-Object byte[] 1048576
                    foreach ($e in $Entries) {
                        $entry = $zip.CreateEntry([string]$e.Name, [System.IO.Compression.CompressionLevel]::Fastest)
                        $out = $entry.Open()
                        try {
                            if ($null -ne $e.Text) { $b = $utf8.GetBytes([string]$e.Text); $out.Write($b, 0, $b.Length) }
                            else {
                                $in = [System.IO.File]::OpenRead([string]$e.Source)
                                try { while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $n); $Status.Written += $n } }
                                finally { $in.Dispose() }
                            }
                        }
                        finally { $out.Dispose() }
                    }
                }
                finally { $zip.Dispose() }
            }
            finally { $fs.Dispose() }
            [System.IO.File]::Move($part, $ZipPath)
        }
        catch { $Status.Error = $_.Exception.Message; try { [System.IO.File]::Delete("$ZipPath.part") } catch { $null = $_ } }
        finally { $Status.Done = $true }
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($work.ToString()).AddArgument($path).AddArgument($plan.Entries.ToArray()).AddArgument($status)
    $handle = $ps.BeginInvoke()
    $stamp = (Get-Date).ToString('yyyy-MM-dd')
    $fileName = if ($pick.Count -eq 1) { "$(Get-SafeFileNameForApp -Name ([string]$pick[0].appName))-$stamp.zip" } else { "intune-app-catalog-library-$stamp.zip" }
    (Get-WebLibraryExports)[$id] = @{ PS = $ps; Handle = $handle; Path = $path; Status = $status; Started = (Get-Date); FileName = $fileName }
    Write-Log "[INFO] Exporting $($pick.Count) app$(if ($pick.Count -ne 1) { 's' }) ($($plan.Files) package file$(if ($plan.Files -ne 1) { 's' }), $([Math]::Round($plan.Bytes / 1MB, 1)) MB) to a .zip..."
    foreach ($s in @($plan.Skipped)) { Write-Log "[WARN] Not exported (a link): $s" }
    return @{ ok = $true; exportId = $id; apps = $pick.Count; files = $plan.Files; bytes = $plan.Bytes; fileName = $fileName; skipped = @($plan.Skipped) }
}

function Global:Get-WebLibraryExportStatus {
    param($Data)
    $e = (Get-WebLibraryExports)[[string]$Data.exportId]
    if (-not $e) { return @{ ok = $false; error = 'That export is no longer known - start it again.' } }
    $s = $e.Status
    if ($s.Done -and $s.Error) { return @{ ok = $false; done = $true; error = "The .zip couldn't be written: $($s.Error)" } }
    $size = [long]0
    if ($s.Done) { $size = [long](Get-Item -LiteralPath $e.Path -ErrorAction SilentlyContinue).Length }
    return @{ ok = $true; done = [bool]$s.Done; written = [long]$s.Written; total = [long]$s.Total; size = $size; fileName = [string]$e.FileName }
}

function Global:Get-WebLibraryExportChunk {
    # One piece of the finished .zip (base64, at most 4 MB) from -offset.
    param($Data)
    $e = (Get-WebLibraryExports)[[string]$Data.exportId]
    if (-not $e -or -not $e.Status.Done -or $e.Status.Error -or -not (Test-Path -LiteralPath $e.Path)) { return @{ ok = $false; error = 'That export is not ready (or no longer known) - start it again.' } }
    $offset = [long]0; [void][long]::TryParse([string]$Data.offset, [ref]$offset)
    $fs = [System.IO.File]::OpenRead($e.Path)
    try {
        if ($offset -lt 0 -or $offset -gt $fs.Length) { return @{ ok = $false; error = 'Past the end of the .zip.' } }
        [void]$fs.Seek($offset, [System.IO.SeekOrigin]::Begin)
        $len = [int][Math]::Min([long]4MB, $fs.Length - $offset)
        $buf = New-Object byte[] $len
        $read = 0
        while ($read -lt $len) { $n = $fs.Read($buf, $read, $len - $read); if ($n -le 0) { break }; $read += $n }
        return @{ ok = $true; data = [Convert]::ToBase64String($buf, 0, $read); size = [long]$fs.Length }
    }
    finally { $fs.Dispose() }
}

function Global:Remove-WebLibraryExport {
    param($Data)
    $ex = Get-WebLibraryExports
    $e = $ex[[string]$Data.exportId]
    if ($e) {
        if (-not $e.Status.Done) { try { $e.PS.Stop() } catch { $null = $_ } }
        Remove-WebLibraryExportFiles $e; $ex.Remove([string]$Data.exportId)
    }
    return @{ ok = $true }
}

# ---------------------------------------------------------------- import

function Global:Read-WebLibraryZip {
    <#
      The apps in an export .zip, read without unpacking it: @{ ok; apps = @(@{ Record; Prefix; Files; Bytes; Problem }); exportedAt;
      appVersion } or @{ ok = $false; error }. Each app file is read as any catalog file (ConvertTo-AppRecord: only known
      fields, each checked); its package files are the entries under packages/<its file name>/ - each a safe path.
    #>
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $readText = {
        param($entry, [long]$max)
        if ($entry.Length -gt $max) { throw "$($entry.FullName) is too large." }
        $sr = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    }
    try { $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath) }
    catch { return @{ ok = $false; error = "This isn't a .zip that can be read: $($_.Exception.Message)" } }
    try {
        $man = $zip.GetEntry('ica-export.json')
        if (-not $man) { return @{ ok = $false; error = "This .zip isn't an export of Intune App Catalog (it has no ica-export.json). Export apps with Catalog > Export library... or More > Export...." } }
        try { $m = (& $readText $man 2MB) | ConvertFrom-Json } catch { return @{ ok = $false; error = "ica-export.json can't be read: $($_.Exception.Message)" } }
        if ([string]$m.format -ne 'intune-app-catalog-export') { return @{ ok = $false; error = 'This .zip is not an Intune App Catalog export.' } }
        if ([int]$m.formatVersion -gt 1) { return @{ ok = $false; error = "This export was made by a newer version ($($m.appVersion)) - update this app first." } }
        # Package entries by their app's folder, counted once.
        $pkg = @{}
        foreach ($e in $zip.Entries) {
            $full = ([string]$e.FullName) -replace '\\', '/'
            if ($full -notmatch '^packages/([^/]+)/(.+)$' -or $full.EndsWith('/')) { continue }
            $k = $Matches[1]
            if (-not $pkg.ContainsKey($k)) { $pkg[$k] = @{ Files = 0; Bytes = [long]0; Bad = '' } }
            if (-not (Test-PackageRelativePath $Matches[2])) { $pkg[$k].Bad = $Matches[2]; continue }
            $pkg[$k].Files++; $pkg[$k].Bytes += [long]$e.Length
        }
        $out = New-Object System.Collections.Generic.List[object]
        $seen = @{}
        foreach ($a in @($m.apps)) {
            $file = [string]$a.file
            if ($file -notmatch '^apps/[^/\\]+\.json$') { continue }
            $entry = $zip.GetEntry($file)
            if (-not $entry) { $out.Add(@{ Record = $null; Name = [string]$a.name; Problem = "$file is missing from the .zip." }); continue }
            try { $rec = ConvertTo-AppRecord ((& $readText $entry 20MB) | ConvertFrom-Json) }
            catch { $out.Add(@{ Record = $null; Name = [string]$a.name; Problem = "$file can't be read: $($_.Exception.Message)" }); continue }
            $name = ([string]$rec.appName).Trim()
            if (-not $name) { $out.Add(@{ Record = $null; Name = $file; Problem = 'It has no app name.' }); continue }
            if ($seen.ContainsKey($name.ToLowerInvariant())) { continue }
            $seen[$name.ToLowerInvariant()] = $true
            $leaf = Get-SafeFileNameForApp -Name $name
            $p = $pkg[$leaf]
            $problem = if ($p -and $p.Bad) { "Its package holds a path that isn't allowed ('$($p.Bad)')." } else { '' }
            $out.Add(@{ Record = $rec; Name = $name; Prefix = "packages/$leaf/"; Files = $(if ($p) { $p.Files } else { 0 }); Bytes = $(if ($p) { $p.Bytes } else { [long]0 }); Problem = $problem })
        }
        # PowerShell 7 reads an ISO time as a date - written back as one, not in this machine's format.
        $at = if ($m.exportedAt -is [datetime]) { $m.exportedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } else { [string]$m.exportedAt }
        return @{ ok = $true; apps = $out.ToArray(); exportedAt = $at; appVersion = [string]$m.appVersion }
    }
    finally { $zip.Dispose() }
}

function Global:Get-WebLibraryUploadPath {
    param($Data)
    $u = (Get-WebUploads)[[string]$Data.uploadId]
    if (-not $u -or $u.Kind -ne 'library') { return '' }
    if ($u.Received -ne $u.Size -or -not (Test-Path -LiteralPath $u.Path)) { return '' }
    return [string]$u.Path
}

function Global:Get-WebLibraryImportPreview {
    <#
      What importing the uploaded .zip would do, per app: new / exists (skipped or replaced, as chosen) / not possible
      (why). Nothing changes.
    #>
    param($Data)
    $path = Get-WebLibraryUploadPath $Data
    if (-not $path) { return @{ ok = $false; error = 'That upload is no longer known (or not finished) - choose the file again.' } }
    $z = Read-WebLibraryZip $path
    if (-not $z.ok) { return $z }
    $all = @((Read-WebCatalogRecords).Apps)
    $officeHere = @($all | Where-Object { $_.office -and -not $_.wingetId }) | Select-Object -First 1
    $rows = foreach ($a in @($z.apps)) {
        $state = 'new'; $why = [string]$a.Problem
        $rec = $a.Record
        if (-not $why) {
            $twin = @($all | Where-Object { [string]$_.appName -eq $a.Name }) | Select-Object -First 1
            if ($twin) { $state = 'exists' }
            else {
                $why = Test-WebAddName $a.Name $all
                if (-not $why -and $rec.office -and -not $rec.wingetId -and $officeHere) { $why = "The catalog has Microsoft 365 Apps already ($($officeHere.appName)) - there is one per catalog." }
            }
        }
        [ordered]@{ name = [string]$a.Name; state = $(if ($why) { 'blocked' } else { $state }); why = $why
            kind = $(if (-not $rec) { '' } elseif ($rec.office -and -not $rec.wingetId) { 'Microsoft 365 Apps' } elseif ($rec.wingetId) { 'Winget' } else { 'Own package' })
            files = [int]$a.Files; bytes = [long]$a.Bytes; hasAppId = [bool]($rec -and $rec.appId)
            groups = $(if ($rec) { @(@($rec.requiredFor) + @($rec.availableFor) + @($rec.uninstallFor) + @($rec.excludeFor) | Where-Object { $_ } | Select-Object -Unique).Count } else { 0 }) }
    }
    return @{ ok = $true; apps = @($rows); exportedAt = $z.exportedAt; appVersion = $z.appVersion }
}

function Global:Set-WebImportedRecord {
    <#
      Pure: the record to write for an imported app. -Mode 'other' (another tenant): what only means something in the tenant
      it came from goes - App ID, Intune's type and version, releases, the package last uploaded, the MSI to retire, being
      retired, supersedence (by App ID). -Existing (a replaced app): this catalog's link to Intune stays, whatever -Mode.
      The stored package path always goes - it named a place on the other machine.
    #>
    param($Record, [string]$Mode, $Existing)
    $r = $Record
    $r.packagePath = ''
    if ($Mode -ne 'same') {
        $r.appId = ''; $r.intuneAppType = ''; $r.intuneAppVersion = ''; $r.releases = @(); $r.packageStamp = ''; $r.lobToRetire = ''; $r.retiringSince = ''
        if ($r.metadata) { $r.metadata.supersedes = $null }
    }
    if ($Existing -and $Existing.appId) {
        foreach ($k in 'appId', 'intuneAppType', 'intuneAppVersion', 'releases', 'packageStamp', 'lobToRetire', 'retiringSince') { $r.$k = $Existing.$k }
        if ($r.metadata) { $r.metadata.supersedes = $(if ($Existing.metadata) { $Existing.metadata.supersedes } else { $null }) }
    }
    return $r
}

function Global:Import-WebLibrary {
    <#
      Adds the apps of the uploaded .zip (with the catalog lock held): -apps @(@{ name; action = add | replace | skip }),
      -mode other | same. A replaced app's file and packages folder go to Backups first. @{ ok; added; replaced; skipped;
      warnings }.
    #>
    param($Data)
    $path = Get-WebLibraryUploadPath $Data
    if (-not $path) { return @{ ok = $false; error = 'That upload is no longer known (or not finished) - choose the file again.' } }
    $mode = if ([string]$Data.mode -eq 'same') { 'same' } else { 'other' }
    $z = Read-WebLibraryZip $path
    if (-not $z.ok) { return $z }
    $want = @{}
    foreach ($x in @($Data.apps)) { if ($x -and $x.name) { $want[([string]$x.name).ToLowerInvariant()] = [string]$x.action } }
    $added = New-Object System.Collections.Generic.List[string]
    $replaced = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[object]
    $warnings = New-Object System.Collections.Generic.List[string]
    $zipName = [string](Get-WebUploads)[[string]$Data.uploadId].FileName
    $catalogDir = Get-AppFolder -Kind Catalog -Create
    $pkgRoot = Get-AppFolder -Kind Packages -Create
    foreach ($a in @($z.apps)) {
        $action = [string]$want[([string]$a.Name).ToLowerInvariant()]
        if (-not $action -or $action -eq 'skip') { continue }
        if ($a.Problem) { $skipped.Add(@{ name = $a.Name; why = $a.Problem }); continue }
        $all = @((Read-WebCatalogRecords).Apps)
        $existing = @($all | Where-Object { [string]$_.appName -eq $a.Name }) | Select-Object -First 1
        if ($existing -and $action -ne 'replace') { $skipped.Add(@{ name = $a.Name; why = 'It is in the catalog already.' }); continue }
        if (-not $existing) {
            $why = Test-WebAddName $a.Name $all
            if (-not $why -and $a.Record.office -and -not $a.Record.wingetId -and @($all | Where-Object { $_.office -and -not $_.wingetId }).Count) { $why = 'The catalog has Microsoft 365 Apps already - there is one per catalog.' }
            if ($why) { $skipped.Add(@{ name = $a.Name; why = $why }); continue }
        }
        $rec = Set-WebImportedRecord -Record $a.Record -Mode $mode -Existing $existing
        # Same spelling as the app it replaces - on Linux "Foo app" and "Foo App" are two files.
        if ($existing) { $rec.appName = [string]$existing.appName }
        # One Intune app, one catalog app: an App ID another app here has already goes (it would update that one).
        if ($rec.appId -and -not ($existing -and $existing.appId) -and @($all | Where-Object { [string]$_.appId -eq [string]$rec.appId }).Count) {
            $warnings.Add("$($rec.appName): its App ID belongs to another app in this catalog - imported without it, as a new app.")
            $rec.appId = ''; $rec.releases = @(); $rec.packageStamp = ''
        }
        try {
            $leaf = Get-SafeFileNameForApp -Name ([string]$rec.appName)
            $folder = Join-Path $pkgRoot $leaf
            if ($a.Files) {
                # The packages folder there now (the replaced app's, or one left behind) goes to Backups - the export's files
                # are the package. An app exported without package files keeps the folder it has here.
                if (Test-Path -LiteralPath $folder) { [void](Move-WebPackageFolderToBackups -Name ([string]$rec.appName)) }
                if (Test-WebPathThroughLink $folder) { throw "Its packages folder goes through a link - not written." }
                [void](Expand-ZipSafely -ZipPath $path -Destination $folder -Prefix $a.Prefix)
            }
            $file = Join-Path $catalogDir "$leaf.json"
            Backup-WebAppFile $file
            Save-WebAppJson -File $file -App $rec -Text $(if ($existing) { "Replaced from $zipName" } else { "Imported from $zipName" })
            if ($existing) { $replaced.Add([string]$rec.appName) } else { $added.Add([string]$rec.appName) }
        }
        catch { $skipped.Add(@{ name = $a.Name; why = $_.Exception.Message }) }
    }
    Write-Log "[OK] Imported from $($zipName): $($added.Count) added, $($replaced.Count) replaced, $($skipped.Count) not imported."
    foreach ($w in $warnings) { Write-Log "[WARN] $w" }
    return @{ ok = $true; added = $added.ToArray(); replaced = $replaced.ToArray(); skipped = $skipped.ToArray(); warnings = $warnings.ToArray() }
}
