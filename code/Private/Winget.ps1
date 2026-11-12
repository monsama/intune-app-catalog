# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

# winget, asked directly and waited for: search for a package, and check
# that a Winget ID still exists. No window code - the web interface calls
# these from a request, and the parsing is covered by CatalogLogic.Tests.ps1.

function Global:ConvertFrom-WingetSearchOutput {
    <#
      Pure: winget search's table as rows @{ Name; Id; Version; Source }.
      The columns are found from the header line's positions, since names
      contain spaces. No header (e.g. "No package found") means no rows.
    #>
    param([string]$Text)
    $lines = @(([string]$Text) -split "`r?`n" | Where-Object { $_.TrimEnd() -ne '' })
    $headerIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        # winget draws a progress spinner before the table; the header is
        # the line that names the columns.
        if ($lines[$i] -match '(^|\s)Name\s+Id\s+Version') { $headerIdx = $i; break }
    }
    if ($headerIdx -lt 0) { return @() }
    $header = $lines[$headerIdx]
    $namePos = [Math]::Max(0, $header.IndexOf('Name'))
    $idPos = $header.IndexOf('Id', $namePos + 4)
    $versionPos = $header.IndexOf('Version', $idPos)
    $matchPos = $header.IndexOf('Match', $versionPos)
    $sourcePos = $header.IndexOf('Source', $versionPos)
    $rows = New-Object System.Collections.Generic.List[object]
    for ($i = $headerIdx + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^[\s-]+$') { continue }   # the ----- rule under the header
        if ($line.Length -le $idPos) { continue }
        $name = $line.Substring($namePos, $idPos - $namePos).Trim()
        $idEnd = if ($versionPos -gt $idPos -and $versionPos -le $line.Length) { $versionPos } else { $line.Length }
        $id = $line.Substring($idPos, $idEnd - $idPos).Trim()
        $versionEnd = if ($matchPos -gt $versionPos -and $matchPos -le $line.Length) { $matchPos }
            elseif ($sourcePos -gt $versionPos -and $sourcePos -le $line.Length) { $sourcePos }
            else { $line.Length }
        $version = if ($versionPos -ge 0 -and $versionPos -lt $line.Length) { $line.Substring($versionPos, [Math]::Max(0, $versionEnd - $versionPos)).Trim() } else { '' }
        $source = if ($sourcePos -ge 0 -and $sourcePos -lt $line.Length) { $line.Substring($sourcePos).Trim() } else { '' }
        # An ID never has spaces; a row that would give one is a wrapped or
        # truncated line, not a package.
        if ($name -and $id -and $id -notmatch '\s') { $rows.Add([pscustomobject]@{ Name = $name; Id = $id; Version = $version; Source = $source }) }
    }
    return $rows.ToArray()
}

function Global:Get-WingetShowVerdict {
    <#
      Pure: what winget show --exact said about one ID, as
      @{ Ok; Result } - the same wording the Checks window has always used
      ("NOT FOUND ..." is what Get-WingetFindings looks for).
    #>
    param([int]$ExitCode, [string]$StdOut, [string]$StdErr)
    if ($ExitCode -eq 0 -and $StdOut -match '(?m)^\s*Version:') {
        $publisher = if ($StdOut -match '(?m)^\s*Publisher:\s*(.+)$') { $Matches[1].Trim() } else { '' }
        $version = if ($StdOut -match '(?m)^\s*Version:\s*(\S+)') { $Matches[1].Trim() } else { '' }
        return @{ Ok = $true; Result = $(if ($publisher) { "Found ($publisher)" } else { 'Found' }); Version = $version }
    }
    if ($StdOut -match 'No package found' -or $StdErr -match 'No package found') {
        return @{ Ok = $false; Result = "NOT FOUND - winget doesn't know this ID any more" }
    }
    $first = @((([string]$StdOut) + "`n" + ([string]$StdErr)) -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^[\s\\|/-]+$' }) | Select-Object -First 1
    return @{ Ok = $false; Result = "Could not check (exit code $ExitCode): $first" }
}

function Global:ConvertTo-WindowsArgument {
    <#
      Pure: one argument quoted for a Windows command line, the way
      CommandLineToArgvW reads it back - always as one argument, whatever
      it holds. Backslashes before a quote (or the closing quote) are
      doubled, quotes are escaped; without that a search text ending in
      "\" would swallow the closing quote and run into the next argument.
    #>
    param([string]$Value)
    if ($null -eq $Value) { $Value = '' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($c in $Value.ToCharArray()) {
        if ($c -eq '\') { $slashes++; continue }
        if ($c -eq '"') { [void]$sb.Append('\' * (2 * $slashes + 1)); [void]$sb.Append('"') }
        else { if ($slashes) { [void]$sb.Append('\' * $slashes) }; [void]$sb.Append($c) }
        $slashes = 0
    }
    if ($slashes) { [void]$sb.Append('\' * (2 * $slashes)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Global:Invoke-Winget {
    # Runs winget with -Arguments and waits (at most -TimeoutSeconds): @{ ExitCode; StdOut; StdErr }.
    param([string[]]$Arguments, [int]$TimeoutSeconds = 30)
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "winget.exe isn't on this machine. It comes with the 'App Installer' package on Windows 10 and 11 - install that from the Microsoft Store." }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd.Source
    # Every argument quoted on its own (ConvertTo-WindowsArgument): a search
    # text is the user's, and must stay exactly one argument - never an option.
    $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-WindowsArgument ([string]$_) }) -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEndAsync()
    $err = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
        try { $proc.Kill() } catch { }
        throw "winget didn't answer within $TimeoutSeconds seconds."
    }
    return @{ ExitCode = $proc.ExitCode; StdOut = $out.GetAwaiter().GetResult(); StdErr = $err.GetAwaiter().GetResult() }
}

function Global:Find-WingetPackage {
    # winget search, as rows (ConvertFrom-WingetSearchOutput).
    param([string]$Query)
    $r = Invoke-Winget -Arguments @('search', '--query', $Query, '--accept-source-agreements', '--disable-interactivity')
    $rows = @(ConvertFrom-WingetSearchOutput $r.StdOut)
    if ($r.ExitCode -ne 0 -and $rows.Count -eq 0 -and $r.StdOut -notmatch 'No package found') {
        throw "winget search failed (exit code $($r.ExitCode)): $(([string]$r.StdErr).Trim())"
    }
    return $rows
}

function Global:Test-WingetPackageId {
    # Is this Winget ID still known to winget? @{ AppName; WingetId; Ok; Result } - a row Get-WingetFindings reads.
    param([string]$AppName, [string]$WingetId)
    try {
        $r = Invoke-Winget -Arguments @('show', '--id', $WingetId, '--exact', '--accept-source-agreements', '--disable-interactivity')
        $v = Get-WingetShowVerdict -ExitCode $r.ExitCode -StdOut $r.StdOut -StdErr $r.StdErr
    }
    catch { $v = @{ Ok = $false; Result = "Could not check: $($_.Exception.Message)" } }
    return [pscustomobject]@{ AppName = $AppName; WingetId = $WingetId; Ok = [bool]$v.Ok; Result = [string]$v.Result; Version = [string]$v.Version }
}

function Global:Compare-AppVersionText {
    <#
      Pure: is version -Other newer (1), the same (0) or older (-1) than
      -Mine? Numbers are compared as numbers part by part (24.10 is newer
      than 24.9, at any length), other parts as text; a leading "v" is
      ignored, and a pre-release ("1.0-beta") is older than its release
      ("1.0"). No version of our own counts as older than any; $null when
      winget's is empty or either is "Unknown".
    #>
    param([string]$Mine, [string]$Other)
    $a = ([string]$Mine).Trim() -replace '^[vV](?=\d)', ''; $b = ([string]$Other).Trim() -replace '^[vV](?=\d)', ''
    if (-not $b -or $a -eq 'Unknown' -or $b -eq 'Unknown') { return $null }
    if (-not $a) { return 1 }
    $pa = @($a -split '[.\-+_ ]' | Where-Object { $_ -ne '' }); $pb = @($b -split '[.\-+_ ]' | Where-Object { $_ -ne '' })
    for ($i = 0; $i -lt [Math]::Max($pa.Count, $pb.Count); $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { $null }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { $null }
        # One side has run out: a further number (1.0 vs 1.0.1) is newer, a further word (1.0 vs 1.0-beta) is a pre-release - older.
        if ($null -eq $x) { if ($y -match '^\d+$') { if ($y.TrimStart('0')) { return 1 } else { continue } } else { return -1 } }
        if ($null -eq $y) { if ($x -match '^\d+$') { if ($x.TrimStart('0')) { return -1 } else { continue } } else { return 1 } }
        if ($x -match '^\d+$' -and $y -match '^\d+$') {
            # As digit strings (leading zeros dropped, then length, then
            # digits): any length, where [decimal] would overflow.
            $xs = $x.TrimStart('0'); $ys = $y.TrimStart('0')
            if ($xs.Length -ne $ys.Length) { return [Math]::Sign($ys.Length - $xs.Length) }
            $c = [string]::CompareOrdinal($ys, $xs)
            if ($c) { return [Math]::Sign($c) }
        }
        elseif ($x -ne $y) { return [Math]::Sign([string]::CompareOrdinal($y.ToLowerInvariant(), $x.ToLowerInvariant())) }
    }
    return 0
}
