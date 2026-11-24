<#
  The editor's blocks (2.26): the install and uninstall commands and the
  detection script shown as locked and editable blocks, read from the
  commands and written back to them (the pure work is in CatalogLogic.ps1:
  Get-InstallBlocks, New-InstallFromBlocks, Get-DetectionBlocks,
  New-DetectionFromBlocks) - and the package scripts (Install.ps1,
  Uninstall.ps1, Invoke-AppDeployToolkit.ps1) edited in the app.

  Nothing here saves the app: the editor puts the commands it gets back
  into its fields, and Save saves them as before. Package scripts are
  files of their own, saved here - checked, with a copy in Backups first.
#>

# ---------------------------------------------------------------- blocks

function Global:Get-WebInstallBlocks {
    # The app's commands as blocks (what the editor has now - nothing saved).
    param($Data)
    $r = Get-InstallBlocks -WingetId ([string]$Data.wingetId).Trim() -Install ([string]$Data.install) -Uninstall ([string]$Data.uninstall) -InstallContext ([string]$Data.context)
    return @{ ok = $true; form = $r.Form; own = [bool]$r.Own; blocks = @($r.Blocks); note = [string]$r.Note }
}

function Global:Get-WebInstallCompose {
    # The commands written from the blocks' values - checked here; the editor puts them in its fields.
    param($Data)
    $r = New-InstallFromBlocks -Form ([string]$Data.form) -Values $Data.values -WingetId ([string]$Data.wingetId).Trim() -Install ([string]$Data.install) -Uninstall ([string]$Data.uninstall) -InstallContext ([string]$Data.context)
    if (-not $r.Ok) { return @{ ok = $false; error = $r.Error } }
    return @{ ok = $true; install = $r.Install; uninstall = $r.Uninstall }
}

function Global:Get-WebDetectionBlocks {
    param($Data)
    $r = Get-DetectionBlocks ([ordered]@{ Type = 'Script'; Script_Content = [string]$Data.script })
    return @{ ok = $true; form = $r.Form; own = [bool]$r.Own; blocks = @($r.Blocks); note = [string]$r.Note }
}

function Global:Get-WebDetectionCompose {
    param($Data)
    $r = New-DetectionFromBlocks -Form ([string]$Data.form) -Values $Data.values -Rule ([ordered]@{ Type = 'Script'; Script_Content = [string]$Data.script })
    if (-not $r.Ok) { return @{ ok = $false; error = $r.Error } }
    return @{ ok = $true; script = $r.Script; detectedName = [string]$r.DetectedName }
}

# ---------------------------------------------------------------- package scripts

function Global:Resolve-WebPackageScript {
    <#
      The path of one of an app's package scripts - a .ps1 directly in that
      app's own folder under Packages (Install.ps1, Uninstall.ps1,
      Invoke-AppDeployToolkit.ps1, or whatever its commands run), of an app
      in the catalog. @{ Ok; Path; Error }.
    #>
    param([string]$Name, [string]$File)
    # A plain file name: no folder, no drive, no "..", only letters, digits, space, dot, dash and underscore.
    # 2.38.17: also the text files a setup reads next to it (SilentClient.cfg, setup.ini, login.xml, a .cmd...).
    if ($File -notmatch (Get-WebPackageTextPattern) -or $File -match '\.\.') { return @{ Ok = $false; Error = 'Only a script or text file (.ps1, .cfg, .ini, .xml, .txt, .cmd, .bat, .inf, .iss, .json, .reg, .config) directly in the app''s own package folder can be edited here.' } }
    $app = @((Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $Name }) | Select-Object -First 1
    if (-not $app) { return @{ Ok = $false; Error = "'$Name' isn't in the catalog." } }
    $root = [IO.Path]::GetFullPath((Get-AppFolder -Kind Packages))
    $folder = Join-Path $root (Get-SafeFileNameForApp -Name $app.appName)
    $path = [IO.Path]::GetFullPath((Join-Path $folder $File))
    if (-not $path.StartsWith($root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return @{ Ok = $false; Error = 'That file is outside the Packages folder.' } }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{ Ok = $false; Error = "$File isn't in $folder." } }
    # A link could point anywhere - only a plain file in a plain folder is edited (the app's folder and the file, checked each time).
    foreach ($item in @((Get-Item -LiteralPath $folder -Force), (Get-Item -LiteralPath $path -Force))) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return @{ Ok = $false; Error = "$($item.Name) is a link - edit the script where it points." } }
    }
    return @{ Ok = $true; Path = $path; App = $app.appName; Error = '' }
}

function Global:Get-WebPackageTextPattern {
    # The package files the code editor opens: scripts and the plain text files setups read.
    return '^[A-Za-z0-9][A-Za-z0-9 ._\-]{0,80}\.(ps1|cfg|ini|xml|txt|cmd|bat|inf|iss|json|reg|config)$'
}

function Global:Read-WebTextFile {
    <#
      A text file as it is: its text and how it was written (utf8bom, utf8, utf16le, utf16be, ansi; crlf or lf) -
      saved back the same way, because an older setup reads its .ini/.cfg only in the encoding it was given.
    #>
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $enc = 'utf8'; $text = ''
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = 'utf8bom'; $text = (New-Object System.Text.UTF8Encoding($false)).GetString($bytes, 3, $bytes.Length - 3) }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = 'utf16le'; $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2) }
    elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) { $enc = 'utf16be'; $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2) }
    else {
        try { $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes) }
        catch { $enc = 'ansi'; $text = (Get-WebAnsiEncoding).GetString($bytes) }
    }
    return @{ Text = $text; Encoding = $enc; LineEnd = $(if ($text -match "`r`n") { 'crlf' } elseif ($text -match "`n") { 'lf' } else { 'crlf' }) }
}

function Global:Get-WebAnsiEncoding {
    # Windows' Western code page - the one these setups' files are in when they aren't UTF-8 (also on Linux and PowerShell 7).
    try { return [System.Text.Encoding]::GetEncoding(1252) } catch { return [System.Text.Encoding]::Default }
}

function Global:Write-WebTextFile {
    param([string]$Path, [string]$Text, [hashtable]$As)
    $t = ($Text -replace "`r`n", "`n") -replace "`r", "`n"
    if ($As.LineEnd -eq 'crlf') { $t = $t -replace "`n", "`r`n" }
    $e = switch ($As.Encoding) {
        'utf8bom' { New-Object System.Text.UTF8Encoding($true) }
        'utf16le' { New-Object System.Text.UnicodeEncoding($false, $true) }
        'utf16be' { New-Object System.Text.UnicodeEncoding($true, $true) }
        'ansi' { Get-WebAnsiEncoding }
        default { New-Object System.Text.UTF8Encoding($false) }
    }
    [System.IO.File]::WriteAllText($Path, $t, $e)
}

function Global:Test-WebPackageTextFile {
    # A text file's check while typing: an .xml must still be well-formed (a setup or client that reads it fails otherwise).
    param([string]$File, [string]$Text)
    if ($File -notmatch '(?i)\.(xml|config)$' -or -not $Text.Trim()) { return @{ Ok = $true; Error = ''; Errors = @() } }
    try { $doc = New-Object System.Xml.XmlDocument; $doc.XmlResolver = $null; $doc.LoadXml($Text); return @{ Ok = $true; Error = ''; Errors = @() } }
    catch {
        $x = $_.Exception; while ($x.InnerException -and -not ($x -is [System.Xml.XmlException])) { $x = $x.InnerException }
        $line = if ($x -is [System.Xml.XmlException]) { $x.LineNumber } else { 1 }; $col = if ($x -is [System.Xml.XmlException]) { $x.LinePosition } else { 1 }
        return @{ Ok = $false; Error = "It isn't well-formed XML: $($x.Message)"; Errors = @([ordered]@{ line = [Math]::Max(1, $line); column = [Math]::Max(1, $col); message = $x.Message }) }
    }
}

function Global:Read-WebScriptText {
    # A script as text: UTF-8 (with or without a BOM) - or, when it isn't valid UTF-8, Windows' ANSI code page (an older script with umlauts), never replacement characters.
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $start = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { 3 } else { 0 }
    try { return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, $start, $bytes.Length - $start) }
    catch { return [System.Text.Encoding]::Default.GetString($bytes) }
}

function Global:Get-WebTextHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Global:Read-WebPackageScript {
    # One package script for the editor: its text, its fingerprint (to notice someone else's change on save) and its locked lines.
    param($Data)
    $p = Resolve-WebPackageScript -Name ([string]$Data.name) -File ([string]$Data.file)
    if (-not $p.Ok) { return @{ ok = $false; error = $p.Error } }
    if ((Get-Item -LiteralPath $p.Path).Length -gt 262144) { return @{ ok = $false; error = "$($Data.file) is larger than 256 KB - edit it outside the app." } }
    $isPs = [string]$Data.file -match '(?i)\.ps1$'
    $text = if ($isPs) { Read-WebScriptText $p.Path } else { (Read-WebTextFile $p.Path).Text }
    # The files next to it (the editor's other tabs): the scripts first (the usual ones first), then the text files.
    $usual = @('Install.ps1', 'Uninstall.ps1', 'Invoke-AppDeployToolkit.ps1')
    $pattern = Get-WebPackageTextPattern
    $files = @(Get-ChildItem -LiteralPath (Split-Path $p.Path) -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $pattern } |
            Sort-Object { if ($_.Extension -ne '.ps1') { 200 } else { $i = [Array]::IndexOf($usual, $_.Name); if ($i -lt 0) { 99 } else { $i } } }, Name | Select-Object -First 30 | ForEach-Object { $_.Name })
    return @{ ok = $true; text = $text; hash = (Get-WebTextHash $p.Path); locked = @($(if ($isPs) { Get-PackageScriptLockedLines $text })); files = $files; folder = (Split-Path $p.Path); kind = $(if ($isPs) { 'script' } else { 'text' }) }
}

function Global:Test-WebPackageScript {
    # The editor's check while typing: does it parse, and are the locked lines as they were.
    param($Data)
    $r = if ([string]$Data.file -and [string]$Data.file -notmatch '(?i)\.ps1$') { Test-WebPackageTextFile -File ([string]$Data.file) -Text ([string]$Data.text) } else { Test-PackageScriptEdit -Old ([string]$Data.old) -New ([string]$Data.text) }
    return @{ ok = $true; valid = [bool]$r.Ok; error = [string]$r.Error; errors = @($r.Errors) }
}

function Global:Get-WebScriptCopyFolder {
    return (Join-Path (Get-AppFolder -Kind Backups -Create) ('script-edit_' + (Get-Date -Format 'yyyy-MM-dd')))
}

function Global:Save-WebPackageScript {
    <#
      Saves a package script from the editor: only when nobody changed the
      file since it was opened (its fingerprint), when it parses and keeps
      its locked lines. The file as it was goes to Backups first (recorded,
      so the editor's "Previous version" can trust it); the change goes into
      the history, with who made it. The package needs building again.
    #>
    param($Data)
    $p = Resolve-WebPackageScript -Name ([string]$Data.name) -File ([string]$Data.file)
    if (-not $p.Ok) { return @{ ok = $false; error = $p.Error } }
    $text = [string]$Data.text
    return (Invoke-WithCatalogLock {
            # Checked again under the lock, right before writing: the folder or file can't have become a link meanwhile.
            $again = Resolve-WebPackageScript -Name ([string]$Data.name) -File ([string]$Data.file)
            if (-not $again.Ok -or $again.Path -ne $p.Path) { return @{ ok = $false; error = $(if ($again.Ok) { 'The script moved meanwhile.' } else { $again.Error }) } }
            if ((Get-WebTextHash $p.Path) -ne [string]$Data.hash) { return @{ ok = $false; conflict = $true; error = "$($Data.file) was changed since you opened it (by someone else, or outside the app). Nothing was saved - close it and open it again, then redo your change." } }
            $isPs = [string]$Data.file -match '(?i)\.ps1$'
            $was = Read-WebTextFile $p.Path
            $old = if ($isPs) { Read-WebScriptText $p.Path } else { $was.Text }
            $check = if ($isPs) { Test-PackageScriptEdit -Old $old -New $text } else { Test-WebPackageTextFile -File ([string]$Data.file) -Text $text }
            if (-not $check.Ok) { return @{ ok = $false; error = $check.Error; errors = @($check.Errors) } }
            $dir = Get-WebScriptCopyFolder
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            $copy = Join-Path $dir ("$(Get-Date -Format 'HHmmss')_$(Get-SafeFileNameForApp -Name $p.App)_$($Data.file)"); $n = 1
            while (Test-Path -LiteralPath $copy) { $n++; $copy = Join-Path $dir ("$(Get-Date -Format 'HHmmss')-$($n)_$(Get-SafeFileNameForApp -Name $p.App)_$($Data.file)") }
            Copy-Item -LiteralPath $p.Path -Destination $copy
            Add-WebCopyRecord $copy
            # Scripts: UTF-8 with a BOM (Windows PowerShell 5.1 reads a file without one in the ANSI code page - umlauts break).
            # Other files: written back exactly as they were (encoding and line ends) - their setup expects that.
            if ($isPs) { [System.IO.File]::WriteAllText($p.Path, (ConvertTo-CanonicalLineEndings $text), (New-Object System.Text.UTF8Encoding($true))) }
            else { Write-WebTextFile -Path $p.Path -Text $text -As $was }
            Add-WebHistoryEntry -App $p.App -Kind 'catalog' -Text "$($Data.file) edited in the app - build the package again (the earlier one is in Backups)."
            Write-Log "[OK] $($p.App): $($Data.file) saved (the earlier one: $copy). Build the package again."
            return @{ ok = $true; hash = (Get-WebTextHash $p.Path); locked = @($(if ($isPs) { Get-PackageScriptLockedLines (Read-WebScriptText $p.Path) })) }
        })
}

function Global:Get-WebPackageScriptPrevious {
    # The newest copy of this script that this app put in Backups and nobody changed since - for "Previous version" in the editor (loaded, not saved).
    param($Data)
    $p = Resolve-WebPackageScript -Name ([string]$Data.name) -File ([string]$Data.file)
    if (-not $p.Ok) { return @{ ok = $false; error = $p.Error } }
    $backups = Get-AppFolder -Kind Backups
    if (-not (Test-Path -LiteralPath $backups)) { return @{ ok = $false; error = 'No earlier version in Backups.' } }
    # HHmmss[-n]_<app>_<file>: the whole rest compared, so "My_Tool" never takes Tool's copies.
    $want = "$(Get-SafeFileNameForApp -Name $p.App)_$($Data.file)"
    $copies = @(Get-ChildItem -LiteralPath $backups -Directory -Filter 'script-edit_*' -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue } |
            Where-Object { $_.Name -match '^\d{6}(-\d+)?_(.+)$' -and [string]::Equals($Matches[2], $want, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object { $_.Directory.Name }, { $_.Name } -Descending)
    # The version marker as the current file has it now (a release may have moved it since): the copy can then be saved again.
    $isPs = [string]$Data.file -match '(?i)\.ps1$'
    $current = if ($isPs) { Read-WebScriptText $p.Path } else { '' }
    $mv = [regex]::Match($current, "-Name\s+Version\s+-Value\s+'((?:[^']|'')*)'")
    foreach ($c in $copies) {
        if ((Test-WebCopyRecord $c.FullName) -ne 'ok') { continue }
        $text = if ($isPs) { Read-WebScriptText $c.FullName } else { (Read-WebTextFile $c.FullName).Text }
        if ($mv.Success) { $text = (Set-MarkerScriptVersion -Text $text -Version ($mv.Groups[1].Value -replace "''", "'")).Text }
        # When it was kept (the folder's date and the copy's time), not when that version was first written.
        $at = if ($c.Directory.Name -match '^script-edit_\d{4}-\d{2}-\d{2}$') { '{0} {1}:{2}' -f $c.Directory.Name.Substring(12), $c.Name.Substring(0, 2), $c.Name.Substring(2, 2) } else { $c.LastWriteTime.ToString('yyyy-MM-dd HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
        return @{ ok = $true; text = $text; at = $at }
    }
    return @{ ok = $false; error = $(if ($copies.Count) { 'The copies in Backups were changed outside the app - none is taken.' } else { 'No earlier version in Backups yet - one is kept each time you save.' }) }
}
