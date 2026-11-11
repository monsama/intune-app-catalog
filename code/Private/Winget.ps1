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
        return @{ Ok = $true; Result = $(if ($publisher) { "Found ($publisher)" } else { 'Found' }) }
    }
    if ($StdOut -match 'No package found' -or $StdErr -match 'No package found') {
        return @{ Ok = $false; Result = "NOT FOUND - winget doesn't know this ID any more" }
    }
    $first = @((([string]$StdOut) + "`n" + ([string]$StdErr)) -split "`r?`n" | Where-Object { $_.Trim() -and $_ -notmatch '^[\s\\|/-]+$' }) | Select-Object -First 1
    return @{ Ok = $false; Result = "Could not check (exit code $ExitCode): $first" }
}

function Global:Invoke-Winget {
    # Runs winget with -Arguments and waits (at most -TimeoutSeconds): @{ ExitCode; StdOut; StdErr }.
    param([string[]]$Arguments, [int]$TimeoutSeconds = 30)
    $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "winget.exe isn't on this machine. It comes with the 'App Installer' package on Windows 10 and 11 - install that from the Microsoft Store." }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $cmd.Source
    # Each argument quoted on its own: a search text is the user's, and must stay one argument.
    $psi.Arguments = (@($Arguments | ForEach-Object { if ($_ -match '^--?[a-z-]+$') { $_ } else { '"' + ($_ -replace '"', '') + '"' } }) -join ' ')
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
    $r = Invoke-Winget -Arguments @('search', $Query, '--accept-source-agreements', '--disable-interactivity')
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
    return [pscustomobject]@{ AppName = $AppName; WingetId = $WingetId; Ok = [bool]$v.Ok; Result = [string]$v.Result }
}
