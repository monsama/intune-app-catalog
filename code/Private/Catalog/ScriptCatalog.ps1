# A local catalog of platform scripts, the same shape the app catalog has:
# one JSON file per script under data\script-data, holding everything Intune
# needs to recreate it.
#
# Why it exists: a platform script lived only in Intune. There was nowhere to
# write one before it went live, nowhere to keep the one that is live, and
# nothing to compare against afterwards - so a script edited in the portal by
# someone else simply became the truth, and a deleted one was gone. Apps have
# had a local copy since the beginning, for exactly those reasons.

function Global:ConvertTo-ScriptRecord {
    <#
      Anything script-shaped - a Graph response, a row from the grid, a
      record read back off disk - as the one catalog shape. Graph's own
      names win where they exist, since that is what a pull hands over.
      Unknown or missing fields come back as sensible empties rather than
      $null, so a record is always safe to write out and read back.
    #>
    param($Script)
    $get = {
        param([string[]]$Names)
        foreach ($name in $Names) {
            if ($null -eq $Script) { break }
            $value = if ($Script -is [System.Collections.IDictionary]) {
                if ($Script.Contains($name)) { $Script[$name] } else { $null }
            } else { $Script.$name }
            if ($null -ne $value -and "$value" -ne '') { return $value }
        }
        return $null
    }
    # 'RunAs' is the grid's own column name - see ConvertTo-PlatformScriptRow
    $runAs = [string](& $get @('runAsAccount', 'RunAsAccount', 'RunAs'))
    # The grid shows "Signed-in user"/"System"; Graph wants user/system.
    $runAsAccount = if ($runAs -match '^(user|Signed-in user)$') { 'user' } else { 'system' }
    $content = [string](& $get @('scriptContent', 'ScriptContent'))
    return [pscustomobject]@{
        scriptId              = [string](& $get @('scriptId', 'id', 'Id'))
        displayName           = [string](& $get @('displayName', 'DisplayName'))
        description           = [string](& $get @('description', 'Description'))
        fileName              = [string](& $get @('fileName', 'FileName'))
        runAsAccount          = $runAsAccount
        runAs32Bit            = [bool](ConvertTo-ScriptBool (& $get @('runAs32Bit', 'RunAs32Bit')))
        enforceSignatureCheck = [bool](ConvertTo-ScriptBool (& $get @('enforceSignatureCheck', 'EnforceSignatureCheck', 'Signature')))
        scriptContent         = $content
        assignedGroups        = @(@(& $get @('assignedGroups', 'AssignedGroups')) | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
}

function Global:ConvertTo-ScriptBool {
    <#
      The same flag arrives as $true, "True", "Yes", "Required" or 1
      depending on whether it came from Graph, the grid or a JSON file.
    #>
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    return ("$Value" -match '^(true|yes|required|1)$')
}

function Global:Get-SafeFileNameForScript {
    # Same rules as an app's file name - one file per script, named after it.
    param([string]$Name)
    $safeName = Get-SafeFileNameForApp -Name $Name
    if ($safeName -eq 'App') { $safeName = 'Script' }
    return $safeName
}

function Global:Get-ScriptFieldDiffs {
    <#
      Which fields of a local script differ from the one in Intune, as
      @{ Field; Local; Remote } rows - the same shape the app metadata
      drift check produces, so the two read the same way.

      The script body is compared with line endings normalised: a file
      saved here and the same file read back from Intune differ by CRLF
      alone, which is not a change anybody made.
    #>
    param($Local, $Remote)
    $localRecord = ConvertTo-ScriptRecord $Local
    $remoteRecord = ConvertTo-ScriptRecord $Remote
    $diffs = New-Object System.Collections.Generic.List[object]
    foreach ($field in @('displayName', 'description', 'fileName', 'runAsAccount', 'runAs32Bit', 'enforceSignatureCheck')) {
        $localValue = "$($localRecord.$field)"
        $remoteValue = "$($remoteRecord.$field)"
        if ($localValue -ne $remoteValue) {
            $diffs.Add(@{ Field = $field; Local = $localValue; Remote = $remoteValue })
        }
    }
    $localBody = (ConvertTo-CanonicalLineEndings $localRecord.scriptContent).TrimEnd()
    $remoteBody = (ConvertTo-CanonicalLineEndings $remoteRecord.scriptContent).TrimEnd()
    if ($localBody -ne $remoteBody) {
        $diffs.Add(@{ Field = 'scriptContent'; Local = "$($localBody.Length) characters"; Remote = "$($remoteBody.Length) characters" })
    }
    # Order doesn't matter for an assignment, only membership
    $localGroups = @($localRecord.assignedGroups | Sort-Object)
    $remoteGroups = @($remoteRecord.assignedGroups | Sort-Object)
    if (($localGroups -join '|') -ne ($remoteGroups -join '|')) {
        $diffs.Add(@{
            Field  = 'assignedGroups'
            Local  = if ($localGroups.Count) { $localGroups -join ', ' } else { '(none)' }
            Remote = if ($remoteGroups.Count) { $remoteGroups -join ', ' } else { '(none)' }
        })
    }
    return $diffs.ToArray()
}

function Global:ConvertTo-SingleScriptJson {
    # One script as the JSON written to disk - same hand-built style as
    # ConvertTo-SingleAppJson, so the files stay readable and diffable.
    param($Script)
    $record = ConvertTo-ScriptRecord $Script
    $fields = New-Object System.Collections.Generic.List[string]
    $fields.Add("  `"scriptId`": $(ConvertTo-JsonStringLiteral $record.scriptId)")
    $fields.Add("  `"displayName`": $(ConvertTo-JsonStringLiteral $record.displayName)")
    $fields.Add("  `"description`": $(ConvertTo-JsonStringLiteral $record.description)")
    $fields.Add("  `"fileName`": $(ConvertTo-JsonStringLiteral $record.fileName)")
    $fields.Add("  `"runAsAccount`": $(ConvertTo-JsonStringLiteral $record.runAsAccount)")
    $fields.Add("  `"runAs32Bit`": $(if ($record.runAs32Bit) { 'true' } else { 'false' })")
    $fields.Add("  `"enforceSignatureCheck`": $(if ($record.enforceSignatureCheck) { 'true' } else { 'false' })")
    $groupList = @($record.assignedGroups)
    $groupsJson = if ($groupList.Count -eq 0) { "[]" } else {
        "[" + (($groupList | ForEach-Object { ConvertTo-JsonStringLiteral $_ }) -join ", ") + "]"
    }
    $fields.Add("  `"assignedGroups`": $groupsJson")
    $fields.Add("  `"scriptContent`": $(ConvertTo-JsonStringLiteral (ConvertTo-CanonicalLineEndings $record.scriptContent))")
    return "{`n" + ($fields -join ",`n") + "`n}"
}

function Global:Save-ScriptsToFolder {
    <#
      Writes one JSON per script into -Path, and removes files for scripts
      that are no longer in the set - the folder IS the catalog, the same
      way data\app-data is.

      Returns @{ Saved; Removed; Errors }.
    #>
    # -NoPrune: write what is here, and leave everything else alone.
    #
    # Pruning is right when the caller read the tenant successfully and
    # this set IS the tenant. It is catastrophic when the caller failed to
    # read anything: an empty set then means "delete every local copy you
    # have", and a transient failure takes the whole local catalog with
    # it. The caller knows which of the two it is; this cannot.
    param([string]$Path, $Scripts, [switch]$NoPrune)
    $result = @{ Saved = 0; Removed = 0; Errors = New-Object System.Collections.Generic.List[string] }
    try { [void][IO.Directory]::CreateDirectory($Path) }
    catch { $result.Errors.Add("Could not create $Path : $($_.Exception.Message)"); return $result }

    $wanted = New-Object System.Collections.Generic.HashSet[string] ([StringComparer]::OrdinalIgnoreCase)
    foreach ($script in @($Scripts)) {
        $record = ConvertTo-ScriptRecord $script
        if (-not $record.displayName) { $result.Errors.Add("A script with no name was skipped."); continue }
        $fileName = (Get-SafeFileNameForScript -Name $record.displayName) + ".json"
        [void]$wanted.Add($fileName)
        try {
            [System.IO.File]::WriteAllText((Join-Path $Path $fileName), (ConvertTo-SingleScriptJson $record), (New-Object System.Text.UTF8Encoding($false)))
            $result.Saved++
        }
        catch { $result.Errors.Add("$($record.displayName): $($_.Exception.Message)") }
    }
    if ($NoPrune) { return $result }
    foreach ($stale in @(Get-ChildItem -Path $Path -Filter "*.json" -ErrorAction SilentlyContinue)) {
        if ($wanted.Contains($stale.Name)) { continue }
        try { Remove-Item -LiteralPath $stale.FullName -Force -ErrorAction Stop; $result.Removed++ }
        catch { $result.Errors.Add("$($stale.Name): $($_.Exception.Message)") }
    }
    return $result
}

function Global:Import-ScriptsFromFolder {
    <#
      Every script JSON in -Path, as records. A file that won't parse is
      reported rather than swallowed - a catalog that silently drops an
      entry is worse than one that says which file is broken.

      Returns @{ Scripts; Errors }.
    #>
    param([string]$Path)
    $scripts = New-Object System.Collections.Generic.List[object]
    $errors = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Scripts = $scripts.ToArray(); Errors = $errors.ToArray() } }
    foreach ($file in @(Get-ChildItem -Path $Path -Filter "*.json" -ErrorAction SilentlyContinue | Sort-Object Name)) {
        try {
            # -Encoding UTF8 explicitly, same reasoning as the app catalog's
            # own read: these are written BOM-less and Windows PowerShell
            # otherwise reads them as the system codepage.
            $raw = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            $scripts.Add((ConvertTo-ScriptRecord ($raw | ConvertFrom-Json)))
        }
        catch { $errors.Add("$($file.Name): $($_.Exception.Message)") }
    }
    return @{ Scripts = $scripts.ToArray(); Errors = $errors.ToArray() }
}
