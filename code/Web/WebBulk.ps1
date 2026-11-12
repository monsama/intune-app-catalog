# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

<#
.SYNOPSIS
    Changes to many apps' files at once, and taking them back: the undo
    record every bulk change keeps, replacing a group across the catalog,
    and editing the catalog as a spreadsheet (CSV export and import).

    Writes run under the catalog lock (the route table, WebApi.ps1).
#>

# ---------------------------------------------------------------- undo

function Global:New-WebUndo {
    # An empty undo record for one bulk change; -Label says what it was ("Batch edit", "CSV import").
    param([string]$Label)
    return @{ label = $Label; time = (Get-Date); items = (New-Object System.Collections.Generic.List[object]) }
}

function Global:Get-WebFileHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Global:Write-WebAppFile {
    <#
      Writes one app's file: a copy of the old file to the Backups folder
      first, then the new content. With -Undo, the change is recorded so
      Undo can put the copy back while nobody changed the file since.
    #>
    param($App, $Undo)
    $file = Join-Path (Get-AppFolder -Kind Catalog -Create) ((Get-SafeFileNameForApp -Name $App.appName) + '.json')
    $backup = Backup-WebAppFile $file -PassThru
    [System.IO.File]::WriteAllText($file, (ConvertTo-SingleAppJson -App $App), (New-Object System.Text.UTF8Encoding($false)))
    if ($Undo -and $backup) { $Undo.items.Add(@{ name = [string]$App.appName; file = $file; backup = [string]$backup; hash = (Get-WebFileHash $file) }) }
}

function Global:Save-WebUndo {
    # Keeps -Undo as the last bulk change (replacing the one before) when it changed anything.
    param($Undo)
    if ($Undo -and $Undo.items.Count) { $Global:App.LastUndo = $Undo }
}

function Global:Get-WebUndoInfo {
    $u = $Global:App.LastUndo
    if (-not $u -or -not $u.items.Count) { return @{ ok = $true; undo = $null } }
    return @{ ok = $true; undo = @{ label = [string]$u.label; time = ([datetime]$u.time).ToString('HH:mm'); count = $u.items.Count; apps = @($u.items | ForEach-Object { $_.name }) } }
}

function Global:Invoke-WebUndo {
    <#
      Takes the last bulk change back: each file it wrote gets its copy
      from before. A file changed since (an editor save, a deploy's App
      ID) is left alone and named. The current files are backed up first,
      so the undo itself can be undone from Earlier versions.
    #>
    $u = $Global:App.LastUndo
    if (-not $u -or -not $u.items.Count) { return @{ ok = $false; error = 'There is no bulk change to undo.' } }
    $restored = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    foreach ($it in $u.items) {
        if ((Get-WebFileHash $it.file) -ne $it.hash) { $skipped.Add("$($it.name) (changed since)"); continue }
        if (-not (Test-Path -LiteralPath $it.backup)) { $skipped.Add("$($it.name) (its copy is gone)"); continue }
        Backup-WebAppFile $it.file
        Copy-Item -LiteralPath $it.backup -Destination $it.file -Force
        $restored.Add($it.name)
    }
    $Global:App.LastUndo = $null
    Write-Log "[OK] Undid '$($u.label)': $($restored.Count) app(s) restored$(if ($skipped.Count) { "; left alone: $($skipped -join ', ')" })."
    return @{ ok = $true; label = [string]$u.label; restored = $restored.ToArray(); skipped = $skipped.ToArray() }
}

# ---------------------------------------------------------------- replace a group

function Global:Invoke-WebReplaceGroup {
    <#
      Replaces one group name with another in the apps' lists (every role),
      in the catalog only - for a group that has another name in this
      tenant, or doesn't exist (Rename on the Groups page renames it in
      Entra ID instead). -names limits it to some apps.
    #>
    param($Data)
    $old = ([string]$Data.old).Trim(); $new = ([string]$Data.new).Trim()
    foreach ($n in $old, $new) { $problem = Test-WebGroupName $n; if ($problem) { return @{ ok = $false; error = $problem } } }
    if ($old -ceq $new) { return @{ ok = $false; error = 'The new name is the same as the old one.' } }
    $catalog = Read-WebCatalogRecords
    $only = @($Data.names | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $apps = @($catalog.Apps | Where-Object { -not $only.Count -or $only -contains $_.appName })
    $changed = @(Rename-WebGroupInApps -Apps $apps -Old $old -New $new)
    if (-not $changed.Count) { return @{ ok = $false; error = "No app$(if ($only.Count) { ' of those chosen' }) in the catalog uses '$old'." } }
    $undo = New-WebUndo "Replace $old with $new"
    foreach ($n in $changed) { Write-WebAppFile -App ($apps | Where-Object { $_.appName -eq $n } | Select-Object -First 1) -Undo $undo }
    Save-WebUndo $undo
    Write-Log "[OK] Replaced '$old' with '$new' in $($changed.Count) app(s) in the catalog: $($changed -join ', ')."
    return @{ ok = $true; changed = $changed; deployed = @($apps | Where-Object { $_.appId -and $changed -contains $_.appName } | ForEach-Object { $_.appName }) }
}

# ---------------------------------------------------------------- CSV

function Global:Get-WebCsvColumns {
    # The spreadsheet's columns: catalog fields first (read-only ones marked), then the batch-editable details.
    [ordered]@{
        appName = 'key'; appId = 'readonly'; wingetId = 'readonly'
        requiredFor = 'groups'; availableFor = 'groups'; uninstallFor = 'groups'; excludeFor = 'groups'
        dependencies = 'meta'; description = 'meta'; publisher = 'meta'; owner = 'meta'; developer = 'meta'; notes = 'meta'
        informationUrl = 'meta'; privacyUrl = 'meta'; architecture = 'meta'; minOSKey = 'meta'; installContext = 'meta'
        installTimeMinutes = 'meta'; deviceRestartBehavior = 'meta'; installCommand = 'meta'; uninstallCommand = 'meta'
    }
}

function Global:Get-WebCellText {
    # Pure: one value as a cell - lists joined with " | ", everything else as text.
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [System.Collections.IEnumerable]) { return ((@($Value) | Where-Object { $null -ne $_ -and "$_" -ne '' } | ForEach-Object { [string]$_ }) -join ' | ') }
    return [string]$Value
}

function Global:Protect-WebCsvCell {
    # Pure: a cell Excel would run as a formula (= + - @, tab, CR first) gets a leading ' - shown as text, and taken off again on import.
    param([string]$Text)
    if ($Text -match '^[=+\-@\t\r]') { return "'" + $Text }
    return $Text
}

function Global:Unprotect-WebCsvCell {
    # Pure: undoes Protect-WebCsvCell - the ' only where it guarded a formula character.
    param([string]$Text)
    if ($Text -match "^'[=+\-@\t\r]") { return $Text.Substring(1) }
    return $Text
}

function Global:Split-WebCellList {
    # Pure: a list cell back to its items (" | " or line breaks between them), trimmed, without empties or repeats.
    param([string]$Text)
    $out = New-Object System.Collections.Generic.List[string]
    # " | " with the spaces (what Export writes) or a line break: a group name with a bare | in it stays whole.
    foreach ($p in @(([string]$Text) -split ' \| |\r?\n')) {
        $t = $p.Trim()
        if ($t -and -not @($out | Where-Object { $_ -ieq $t }).Count) { $out.Add($t) }
    }
    return , $out.ToArray()
}

function Global:Export-WebCatalogCsv {
    # The catalog as CSV text (semicolons, as Excel expects in most of Europe; "sep=;" tells Excel elsewhere).
    $catalog = Read-WebCatalogRecords
    $cols = Get-WebCsvColumns
    $rows = foreach ($a in @($catalog.Apps | Sort-Object appName)) {
        $m = if ($a.metadata) { $a.metadata } else { Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon (Test-AppIsUncommon -App $a) }
        $o = [ordered]@{}
        foreach ($c in $cols.Keys) { $o[$c] = Protect-WebCsvCell (Get-WebCellText $(if ($cols[$c] -eq 'meta') { $m.$c } else { $a.$c })) }
        [pscustomobject]$o
    }
    $csv = @($rows | ConvertTo-Csv -Delimiter ';' -NoTypeInformation)
    if (-not $csv.Count) { $csv = @((($cols.Keys | ForEach-Object { '"' + $_ + '"' }) -join ';')) }
    return @{ ok = $true; text = ("sep=;`r`n" + ($csv -join "`r`n") + "`r`n"); count = @($rows).Count }
}

function Global:ConvertFrom-WebCsvText {
    # Pure: CSV text as rows - the delimiter taken from the header line (; , or tab), a "sep=" line and a byte-order mark skipped.
    param([string]$Text)
    $t = ([string]$Text).TrimStart([char]0xFEFF)
    $lines = $t -split "`r?`n"
    if ($lines.Count -and $lines[0] -match '^sep=(.)\s*$') { $delim = $Matches[1]; $t = ($lines | Select-Object -Skip 1) -join "`n" }
    else {
        $head = if ($lines.Count) { $lines[0] } else { '' }
        $counts = @{ ';' = ($head.Split(';').Count); ',' = ($head.Split(',').Count); "`t" = ($head.Split("`t").Count) }
        $delim = ($counts.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
    }
    return , @($t | ConvertFrom-Csv -Delimiter $delim)
}

function Global:Import-WebCatalogCsv {
    <#
      A CSV (from Export, edited in Excel) back into the catalog. Rows are
      matched by appName; only cells that differ from the catalog change,
      checked with the editor's rules. -preview: only says what would
      change. Apps not in the catalog, appId and wingetId are never
      changed here.
    #>
    param($Data)
    $text = [string]$Data.text
    if (-not $text.Trim()) { return @{ ok = $false; error = 'The file is empty.' } }
    if ($text.Length -gt 5MB) { return @{ ok = $false; error = 'The file is too large for a catalog (over 5 MB).' } }
    try { $rows = ConvertFrom-WebCsvText $text } catch { return @{ ok = $false; error = "The file couldn't be read as CSV: $($_.Exception.Message)" } }
    if (-not @($rows).Count) { return @{ ok = $false; error = 'The file has no rows.' } }
    $header = @($rows[0].PSObject.Properties.Name)
    if ($header -notcontains 'appName') { return @{ ok = $false; error = "The file has no appName column - start from Export CSV, and keep its first row." } }
    $cols = Get-WebCsvColumns
    $unknown = @($header | Where-Object { -not $cols.Contains($_) })
    $catalog = Read-WebCatalogRecords
    $all = @($catalog.Apps)
    $allNames = @($all | ForEach-Object { $_.appName })
    $changes = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    $notFound = New-Object System.Collections.Generic.List[string]
    $pending = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($r in @($rows)) {
        foreach ($prop in @($r.PSObject.Properties)) { $prop.Value = Unprotect-WebCsvCell ([string]$prop.Value) }
        $name = ([string]$r.appName).Trim()
        if (-not $name) { continue }
        if ($seen.ContainsKey($name.ToLowerInvariant())) { $errors.Add("$name`: in the file twice - only the first row counts."); continue }
        $seen[$name.ToLowerInvariant()] = $true
        $a = $all | Where-Object { $_.appName -ieq $name } | Select-Object -First 1
        if (-not $a) { $notFound.Add($name); continue }
        $base = if ($a.metadata) { $a.metadata } else { Get-DefaultAppMetadata -AppName $a.appName -WingetId $a.wingetId -Uncommon (Test-AppIsUncommon -App $a) }
        $form = [ordered]@{}; $diffs = New-Object System.Collections.Generic.List[object]; $groupSets = @{}; $bad = ''
        foreach ($c in $header) {
            if (-not $cols.Contains($c)) { continue }
            $kind = $cols[$c]; $cell = [string]$r.$c
            if ($kind -eq 'groups') {
                $want = Split-WebCellList $cell
                foreach ($g in $want) { $p = Test-WebGroupName $g; if ($p) { $bad = "$c`: $p" } }
                $now = @($a.$c | Where-Object { $_ } | ForEach-Object { [string]$_ })
                $same = (@($now | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object) -join "`n") -eq (@($want | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object) -join "`n")
                if (-not $same) { $groupSets[$c] = $want; $diffs.Add([ordered]@{ app = $a.appName; field = $c; old = (Get-WebCellText $now); new = (Get-WebCellText $want) }) }
            }
            elseif ($kind -eq 'meta') {
                $old = (Get-WebCellText $base.$c).Trim()
                $newText = $cell.Trim()
                if ($c -eq 'dependencies') { $newText = (Split-WebCellList $cell) -join ' | ' }
                if ($c -eq 'architecture') { $newText = (@($cell -split '[,|\s]+' | Where-Object { $_ }) -join ',') }
                if ($newText -ceq $old) { continue }
                $form[$c] = $(if ($c -eq 'dependencies') { @(Split-WebCellList $cell) } elseif ($c -eq 'architecture') { @($newText -split ',') } else { $newText })
                $diffs.Add([ordered]@{ app = $a.appName; field = $c; old = $old; new = $newText })
            }
        }
        if ($bad) { $errors.Add("$($a.appName): $bad"); continue }
        $checked = if ($form.Count) { ConvertTo-WebBatchChanges -Form $form -AppNames $allNames } else { @{ Error = ''; Changes = [ordered]@{} } }
        if ($checked.Error) { $errors.Add("$($a.appName): $($checked.Error)"); continue }
        if (-not $diffs.Count) { continue }
        foreach ($d in $diffs) { $changes.Add($d) }
        $pending.Add(@{ App = $a; Base = $base; Changes = $checked.Changes; Groups = $groupSets })
    }
    $result = @{ ok = $true; preview = [bool]$Data.preview; changes = $changes.ToArray(); apps = @($pending | ForEach-Object { $_.App.appName })
        errors = $errors.ToArray(); notFound = $notFound.ToArray(); ignoredColumns = @($unknown) }
    if ($Data.preview) { return $result }
    if ($errors.Count) { return @{ ok = $false; error = "Fix these rows first (nothing was changed): $($errors -join '; ')" } }
    $undo = New-WebUndo 'CSV import'
    foreach ($p in $pending) {
        $a = $p.App
        if ($p.Changes.Count) { $a.metadata = (Set-WebBatchChanges -App $a -Metadata $p.Base -Changes $p.Changes).Metadata }
        foreach ($k in $p.Groups.Keys) { $a.$k = @($p.Groups[$k]) }
        Write-WebAppFile -App $a -Undo $undo
    }
    Save-WebUndo $undo
    Write-Log "[OK] CSV import: $($changes.Count) change(s) on $($pending.Count) app(s) in the catalog."
    $result.deployed = @($pending | Where-Object { $_.App.appId } | ForEach-Object { $_.App.appName })
    return $result
}
