# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
  winget's package source, read without winget - for Linux (the container),
  where winget.exe doesn't exist.

  winget itself reads the same two things: the source's index (source.msix
  from cdn.winget.microsoft.com - a zip with a SQLite database of every
  package, its names and versions, and where each version's manifest is) and
  the manifest of one version (a YAML file on the same CDN). The index is
  downloaded at most every 6 hours into data\winget-index and read with the
  sqlite3 program; manifests are kept there too, by ID and version.

  What the app asks winget, answered from these:
    - search, an ID, its versions   -> Find-WingetIndexPackage (rows like
      Microsoft's WinGet module gives - Find-WingetClientPackage uses it)
    - winget show [--version]      -> Get-WingetIndexShowText (the text
      winget show writes, in English - the app's parsers read it as before)
#>

function Global:Get-WingetCdn { 'https://cdn.winget.microsoft.com/cache' }

function Global:Test-WingetIndexUsable {
    # Linux with sqlite3: the index stands in for winget.exe. Never in test mode (no internet there).
    if ($Global:App.TestGraph) { return $false }
    return [bool](($IsLinux -or $IsMacOS) -and (Get-Command sqlite3 -ErrorAction SilentlyContinue))
}

function Global:Get-WingetIndexFolder {
    $f = Join-Path $Global:App.RootPath 'data\winget-index'
    if (-not (Test-Path -LiteralPath $f)) { [void](New-Item -ItemType Directory -Path $f -Force) }
    return $f
}

function Global:Update-WingetIndex {
    <#
      The index database, downloaded again when it's older than -MaxAgeHours (or
      missing). One download at a time; a failed download keeps the old index.
      Returns its path (throws when there is none at all).
    #>
    param([int]$MaxAgeHours = 6)
    $folder = Get-WingetIndexFolder
    $db = Join-Path $folder 'index.db'
    $fresh = (Test-Path -LiteralPath $db) -and (((Get-Date) - (Get-Item -LiteralPath $db).LastWriteTime).TotalHours -lt $MaxAgeHours)
    if ($fresh) { return $db }
    $lock = $Global:App.WingetIndexLock
    if (-not $lock) { $lock = $Global:App.WingetIndexLock = New-Object System.Object }
    [System.Threading.Monitor]::Enter($lock)
    try {
        if ((Test-Path -LiteralPath $db) -and (((Get-Date) - (Get-Item -LiteralPath $db).LastWriteTime).TotalHours -lt $MaxAgeHours)) { return $db }
        # A download that failed isn't tried again for 30 minutes while there is an index: without the CDN every
        # search would otherwise wait for its own failed download first.
        if ((Test-Path -LiteralPath $db) -and $Global:App.WingetIndexTried -and ((Get-Date) - $Global:App.WingetIndexTried).TotalMinutes -lt 30) { return $db }
        $Global:App.WingetIndexTried = Get-Date
        $msix = Join-Path $folder 'source.msix.download'
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri "$(Get-WingetCdn)/source.msix" -OutFile $msix -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zip = [System.IO.Compression.ZipFile]::OpenRead($msix)
            try {
                $entry = $zip.Entries | Where-Object { $_.FullName -eq 'Public/index.db' } | Select-Object -First 1
                if (-not $entry) { throw "winget's source has no Public/index.db." }
                $tmp = "$db.new"
                $in = $entry.Open(); $out = [System.IO.File]::Create($tmp)
                try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
            }
            finally { $zip.Dispose() }
            Move-Item -LiteralPath $tmp -Destination $db -Force
            Write-Log "[OK] winget's package index read again ($([Math]::Round((Get-Item -LiteralPath $db).Length / 1MB)) MB)."
        }
        catch {
            if (Test-Path -LiteralPath $db) { Write-Log "[WARN] winget's package index couldn't be read again - the one from $((Get-Item -LiteralPath $db).LastWriteTime.ToString('yyyy-MM-dd HH:mm')) is used: $($_.Exception.Message)" }
            else { throw "winget's package index couldn't be downloaded from cdn.winget.microsoft.com: $($_.Exception.Message)" }
        }
        finally { Remove-Item -LiteralPath $msix -Force -ErrorAction SilentlyContinue }
        return $db
    }
    finally { [System.Threading.Monitor]::Exit($lock) }
}

function Global:ConvertTo-SqlText {
    # Pure: a text as an SQL string literal ('' for a quote) - the only way user text goes into a query.
    param([string]$Text)
    return "'" + ([string]$Text).Replace("'", "''") + "'"
}

function Global:Invoke-WingetIndexQuery {
    # Rows of -Sql from the index (sqlite3 -json), read-only.
    param([string]$Sql)
    $db = Update-WingetIndex
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Get-Command sqlite3).Source
    foreach ($a in @('-readonly', '-json', $db, $Sql)) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $out = $p.StandardOutput.ReadToEndAsync(); $err = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(30000)) { try { $p.Kill() } catch { }; throw "Reading winget's index took too long." }
    if ($p.ExitCode -ne 0) { throw "Reading winget's index failed: $(([string]$err.Result).Trim())" }
    $text = ([string]$out.Result).Trim()
    if (-not $text) { return @() }
    return @($text | ConvertFrom-Json)
}

function Global:Find-WingetIndexPackage {
    <#
      Packages in winget's source, as rows @{ Name; Id; Version; Source; Versions } (newest version first) -
      what Microsoft's WinGet module's Find-WinGetPackage gives. -Id: exactly that ID (any case);
      -Query: ID, name or moniker containing it - the closest first, at most 50.
    #>
    param([string]$Query, [string]$Id)
    $select = 'SELECT i.id AS id, n.name AS name, v.version AS version FROM manifest m JOIN ids i ON i.rowid = m.id JOIN names n ON n.rowid = m.name JOIN versions v ON v.rowid = m.version'
    if ($Id) {
        $rows = Invoke-WingetIndexQuery "$select WHERE lower(i.id) = lower($(ConvertTo-SqlText $Id))"
    }
    else {
        $q = ([string]$Query).Trim()
        if ($q.Length -lt 2) { return @() }
        if ($q.Length -gt 100) { $q = $q.Substring(0, 100) }
        # LIKE with \ as the escape: % and _ the user typed are just characters.
        $like = ConvertTo-SqlText ('%' + ($q -replace '([\\%_])', '\$1') + '%')
        $ids = "SELECT DISTINCT m.id FROM manifest m JOIN ids i ON i.rowid = m.id JOIN names n ON n.rowid = m.name JOIN monikers k ON k.rowid = m.moniker WHERE i.id LIKE $like ESCAPE '\' OR n.name LIKE $like ESCAPE '\' OR k.moniker LIKE $like ESCAPE '\' LIMIT 200"
        $rows = Invoke-WingetIndexQuery "$select WHERE m.id IN ($ids)"
    }
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($g in @($rows | Group-Object id)) {
        $versions = [System.Collections.Generic.List[string]]::new()
        foreach ($r in $g.Group) { if (-not $versions.Contains([string]$r.version)) { $versions.Add([string]$r.version) } }
        # Newest first, compared as winget does (numbers as numbers).
        $sorted = [System.Collections.Generic.List[string]]::new()
        foreach ($v in $versions) {
            $at = 0
            # Past every one that is newer than (or the same as) this one.
            while ($at -lt $sorted.Count -and (Compare-AppVersionText $v $sorted[$at]) -in 1, 0) { $at++ }
            $sorted.Insert($at, $v)
        }
        $newest = @($g.Group | Where-Object { $_.version -eq $sorted[0] })[0]
        $out.Add([pscustomobject]@{ Name = [string]$newest.name; Id = [string]$g.Name; Version = $sorted[0]; Source = 'winget'; Versions = @($sorted) })
    }
    if ($Id) { return , $out.ToArray() }
    # Closest first: the exact ID or name, then those starting with it, then the rest by name.
    $ql = ([string]$Query).Trim().ToLowerInvariant()
    $rank = { param($p) $i = $p.Id.ToLowerInvariant(); $n = $p.Name.ToLowerInvariant(); if ($i -eq $ql -or $n -eq $ql) { 0 } elseif ($i.StartsWith($ql) -or $n.StartsWith($ql)) { 1 } else { 2 } }
    return , @($out | Sort-Object { & $rank $_ }, Name | Select-Object -First 50)
}

function Global:Get-WingetIndexManifest {
    <#
      One version's manifest (the newest without -Version) as a hashtable, from the CDN, kept in
      data\winget-index\manifests. $null when winget's source has no such package or version.
    #>
    param([string]$Id, [string]$Version)
    $where = "lower(i.id) = lower($(ConvertTo-SqlText $Id))"
    if ($Version) { $where += " AND v.version = $(ConvertTo-SqlText $Version)" }
    $rows = @(Invoke-WingetIndexQuery "SELECT i.id AS id, v.version AS version, m.pathpart AS pp FROM manifest m JOIN ids i ON i.rowid = m.id JOIN versions v ON v.rowid = m.version WHERE $where")
    if (-not $rows.Count) { return $null }
    $pick = $rows[0]
    foreach ($r in $rows) { if ((Compare-AppVersionText ([string]$pick.version) ([string]$r.version)) -eq 1) { $pick = $r } }
    $safe = ([string]$pick.id -replace '[^A-Za-z0-9.\-_+]', '_')
    $cacheDir = Join-Path (Get-WingetIndexFolder) "manifests/$safe"
    $cache = Join-Path $cacheDir ((([string]$pick.version) -replace '[^A-Za-z0-9.\-_+]', '_') + '.yaml')
    if (-not (Test-Path -LiteralPath $cache)) {
        $parts = @(Invoke-WingetIndexQuery "WITH RECURSIVE p(r, parent, part, d) AS (SELECT rowid, parent, pathpart, 0 FROM pathparts WHERE rowid = $([int64]$pick.pp) UNION ALL SELECT pp.rowid, pp.parent, pp.pathpart, p.d + 1 FROM pathparts pp JOIN p ON pp.rowid = p.parent) SELECT part FROM p ORDER BY d DESC")
        $rel = (@($parts | ForEach-Object { [string]$_.part }) -join '/')
        if ($rel -notmatch '^manifests/[A-Za-z0-9/._+\-]+$') { throw "winget's index gave an unexpected manifest path for $Id." }
        $ProgressPreference = 'SilentlyContinue'
        $text = (Invoke-WebRequest -Uri "$(Get-WingetCdn)/$rel" -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
        if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
        if (-not (Test-Path -LiteralPath $cacheDir)) { [void](New-Item -ItemType Directory -Path $cacheDir -Force) }
        [System.IO.File]::WriteAllText($cache, [string]$text, (New-Object System.Text.UTF8Encoding($false)))
    }
    return (ConvertFrom-WingetManifestYaml ([System.IO.File]::ReadAllText($cache)))
}

function Global:ConvertFrom-WingetManifestYaml {
    <#
      Pure: the parts of a merged winget manifest the app reads - the top-level values (one line, quoted,
      or a | / > block), top-level lists (Tags), and each installer's own values (Installers). Not a whole
      YAML reader: nesting deeper than the installers' values is skipped.
    #>
    param([string]$Text)
    $m = [ordered]@{ Installers = @() }
    $lines = @(([string]$Text) -split "`r?`n")
    $installers = New-Object System.Collections.Generic.List[object]
    $unquote = {
        param([string]$v)
        $v = $v.Trim()
        if ($v.Length -ge 2 -and $v[0] -eq "'" -and $v[-1] -eq "'") { return $v.Substring(1, $v.Length - 2).Replace("''", "'") }
        if ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[-1] -eq '"') {
            # YAML's escapes in a double-quoted value: \uXXXX, \xXX, \n, \", \\.
            $inner = $v.Substring(1, $v.Length - 2)
            return [regex]::Replace($inner, '\\(u[0-9A-Fa-f]{4}|x[0-9A-Fa-f]{2}|n|t|"|\\|/)', {
                    param($mm) $e = $mm.Groups[1].Value
                    switch -CaseSensitive ($e[0]) { 'u' { [string][char][Convert]::ToInt32($e.Substring(1), 16) } 'x' { [string][char][Convert]::ToInt32($e.Substring(1), 16) } 'n' { "`n" } 't' { "`t" } default { $e } }
                })
        }
        return $v
    }
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        $t = [regex]::Match($line, '^([A-Za-z][A-Za-z0-9]*):\s*(.*)$')
        if (-not $t.Success) { $i++; continue }
        $key = $t.Groups[1].Value; $val = $t.Groups[2].Value
        $i++
        if ($val -match '^[|>][-+]?\s*$') {
            # A block: the indented lines that follow.
            $block = New-Object System.Collections.Generic.List[string]
            while ($i -lt $lines.Count -and ($lines[$i] -match '^\s+\S' -or $lines[$i] -eq '')) { $block.Add($lines[$i].Trim()); $i++ }
            $m[$key] = if ($val.StartsWith('>')) { ($block -join ' ').Trim() } else { ($block -join "`n").Trim() }
            continue
        }
        if ($val) {
            # A quoted value may go on over more lines (indented).
            $v = $val
            if (($v.StartsWith("'") -and -not ($v.Length -gt 1 -and $v.EndsWith("'"))) -or ($v.StartsWith('"') -and -not ($v.Length -gt 1 -and $v.EndsWith('"')))) {
                # A blank line inside the quotes is a line break (YAML folding) - not the value's end.
                while ($i -lt $lines.Count -and ($lines[$i] -match '^\s+' -or $lines[$i] -eq '')) {
                    if ($lines[$i] -eq '' -or $lines[$i].Trim() -eq '') { $v = $v.TrimEnd() + "`n"; $i++; continue }
                    $v += $(if ($v.EndsWith("`n")) { '' } else { ' ' }) + $lines[$i].Trim(); $i++
                    if ($v.EndsWith("'") -or $v.EndsWith('"')) { break }
                }
            }
            $m[$key] = & $unquote $v
            continue
        }
        # A list (or a nested map) under the key.
        if ($key -eq 'Installers') {
            $cur = $null
            while ($i -lt $lines.Count -and ($lines[$i] -match '^[\s-]' -or $lines[$i] -eq '')) {
                $l = $lines[$i]; $i++
                $mi = [regex]::Match($l, '^-\s+([A-Za-z][A-Za-z0-9]*):\s*(.*)$')
                if ($mi.Success) { $cur = [ordered]@{}; $installers.Add($cur); $cur[$mi.Groups[1].Value] = & $unquote $mi.Groups[2].Value; continue }
                $mk = [regex]::Match($l, '^  ([A-Za-z][A-Za-z0-9]*):\s*(\S.*)$')
                if ($mk.Success -and $cur) { $cur[$mk.Groups[1].Value] = & $unquote $mk.Groups[2].Value }
            }
            continue
        }
        $items = New-Object System.Collections.Generic.List[string]
        while ($i -lt $lines.Count -and ($lines[$i] -match '^[\s-]' -or $lines[$i] -eq '')) {
            $li = [regex]::Match($lines[$i], '^-\s+(.*)$')
            if ($li.Success -and $li.Groups[1].Value -notmatch '^[A-Za-z][A-Za-z0-9]*:\s') { $items.Add((& $unquote $li.Groups[1].Value)) }
            $i++
        }
        $m[$key] = $items.ToArray()
    }
    $m.Installers = $installers.ToArray()
    return $m
}

function Global:Select-WingetIndexInstaller {
    # Pure: the installer winget would pick on a 64-bit Windows device - x64, else x86, else neutral, else the first.
    param($Installers)
    $list = @($Installers)
    foreach ($arch in 'x64', 'x86', 'neutral') {
        $hit = @($list | Where-Object { $_.Architecture -eq $arch }) | Select-Object -First 1
        if ($hit) { return $hit }
    }
    return ($list | Select-Object -First 1)
}

function Global:Format-WingetShowText {
    # Pure: a manifest as "winget show" writes it (English) - what ConvertFrom-WingetShowOutput and ConvertFrom-WingetInstallerUrl read.
    param($Manifest)
    $m = $Manifest
    $sb = New-Object System.Text.StringBuilder
    $add = { param($label, $value) if ([string]$value) { [void]$sb.AppendLine("${label}: $(([string]$value) -replace "`r?`n", ' ')") } }
    [void]$sb.AppendLine("Found $($m.PackageName) [$($m.PackageIdentifier)]")
    & $add 'Version' $m.PackageVersion
    & $add 'Publisher' $m.Publisher
    & $add 'Publisher Url' $m.PublisherUrl
    & $add 'Publisher Support Url' $m.PublisherSupportUrl
    & $add 'Author' $m.Author
    & $add 'Moniker' $m.Moniker
    & $add 'Description' $(if ($m.ShortDescription) { $m.ShortDescription } else { $m.Description })
    & $add 'Homepage' $m.PackageUrl
    & $add 'License' $m.License
    & $add 'License Url' $m.LicenseUrl
    & $add 'Privacy Url' $m.PrivacyUrl
    & $add 'Copyright' $m.Copyright
    $tags = @($m.Tags | Where-Object { $_ })
    if ($tags.Count) { [void]$sb.AppendLine('Tags:'); foreach ($t in $tags) { [void]$sb.AppendLine("  $t") } }
    $inst = Select-WingetIndexInstaller $m.Installers
    if ($inst) {
        [void]$sb.AppendLine('Installer:')
        # A manifest can keep the type (and scope) once for all its installers.
        $itype = if ($inst.InstallerType) { $inst.InstallerType } else { $m.InstallerType }
        if ($itype) { [void]$sb.AppendLine("  Installer Type: $itype") }
        if ($inst.InstallerUrl) { [void]$sb.AppendLine("  Installer Url: $($inst.InstallerUrl)") }
        if ($inst.InstallerSha256) { [void]$sb.AppendLine("  Installer SHA256: $($inst.InstallerSha256)") }
    }
    return $sb.ToString()
}

function Global:Invoke-WingetIndex {
    <#
      Invoke-Winget on Linux: the winget commands the app runs, answered from the index - @{ ExitCode;
      StdOut; StdErr } as winget.exe would give them. show (with --version or --versions) and search;
      anything else (export - this PC's apps) isn't there in the server version.
    #>
    param([string[]]$Arguments)
    $a = @($Arguments)
    $val = { param($name) $k = [Array]::IndexOf($a, $name); if ($k -ge 0 -and $k + 1 -lt $a.Count) { [string]$a[$k + 1] } else { '' } }
    $notFound = -1978335212
    switch ([string]$a[0]) {
        'show' {
            $id = & $val '--id'
            if ($a -contains '--versions') {
                $p = @(Find-WingetIndexPackage -Id $id)
                if (-not $p.Count) { return @{ ExitCode = $notFound; StdOut = 'No package found matching input criteria.'; StdErr = '' } }
                $text = "Found $($p[0].Name) [$($p[0].Id)]`nVersion`n-------`n" + (@($p[0].Versions) -join "`n") + "`n"
                return @{ ExitCode = 0; StdOut = $text; StdErr = '' }
            }
            $m = Get-WingetIndexManifest -Id $id -Version (& $val '--version')
            if (-not $m) { return @{ ExitCode = $notFound; StdOut = 'No package found matching input criteria.'; StdErr = '' } }
            return @{ ExitCode = 0; StdOut = (Format-WingetShowText $m); StdErr = '' }
        }
        'search' {
            $rows = @(Find-WingetIndexPackage -Query (& $val '--query'))
            if (-not $rows.Count) { return @{ ExitCode = $notFound; StdOut = 'No package found matching input criteria.'; StdErr = '' } }
            $w1 = [Math]::Max(4, (@($rows | ForEach-Object { $_.Name.Length }) | Measure-Object -Maximum).Maximum) + 1
            $w2 = [Math]::Max(2, (@($rows | ForEach-Object { $_.Id.Length }) | Measure-Object -Maximum).Maximum) + 1
            $w3 = [Math]::Max(7, (@($rows | ForEach-Object { $_.Version.Length }) | Measure-Object -Maximum).Maximum) + 1
            $lines = @(('Name'.PadRight($w1) + 'Id'.PadRight($w2) + 'Version'.PadRight($w3) + 'Source'), ('-' * ($w1 + $w2 + $w3 + 6)))
            $lines += @($rows | ForEach-Object { $_.Name.PadRight($w1) + $_.Id.PadRight($w2) + $_.Version.PadRight($w3) + 'winget' })
            return @{ ExitCode = 0; StdOut = ($lines -join "`n"); StdErr = '' }
        }
        default { throw "This isn't available in the server version (winget $($a[0]) needs a Windows PC)." }
    }
}
