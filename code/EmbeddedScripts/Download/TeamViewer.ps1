# ---------------------------------------------------------------- TeamViewer (the full app), fetched from TeamViewer
# "TeamViewer" in the starter set (2.38.66): TeamViewer's newest full client from TeamViewer's download address, used
# only when signed by TeamViewer, installed silently for all users. Found = Windows lists "TeamViewer" (not the Host or
# QuickSupport). TeamViewer updates itself afterwards, as set in its options.
# Log: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneAppCatalog-TeamViewer.log

function Get-DownloadTarget {
    return @{
        Name   = 'TeamViewer'
        Log    = 'TeamViewer'
        Url    = 'https://download.teamviewer.com/download/TeamViewer_Setup_x64.exe'
        File   = 'TeamViewer_Setup_x64.exe'
        # The publisher's certificate: TeamViewer Germany GmbH (TeamViewer GmbH on older ones).
        Signer = @('TeamViewer Germany GmbH', 'TeamViewer GmbH')
    }
}

function Get-TeamViewerEntry {
    # The full app as Windows lists it: "TeamViewer" or "TeamViewer 15" - not "TeamViewer Host" or QuickSupport.
    return @(Get-DownloadArpEntries '^TeamViewer( \d+)?$') | Select-Object -First 1
}
function Test-AppInstalled { return [bool](Get-TeamViewerEntry) }

function Install-App([string]$File) {
    # TeamViewer's setup is an NSIS installer: /S installs it silently.
    return (Invoke-DownloadProcess $File '/S' 30)
}

function Uninstall-App {
    $e = Get-TeamViewerEntry
    if (-not $e) { return 0 }
    $u = ([string]$e.Uninstall).Trim()
    $file = if ($u.StartsWith('"')) { $u.Substring(1, $u.IndexOf('"', 1) - 1) } else { ($u -split ' /')[0].Trim() }
    if (-not $file -or -not (Test-Path -LiteralPath $file)) { Write-DownloadLog "  its uninstaller isn't there: $u"; return 1 }
    # _?= keeps the NSIS uninstaller in place, so its end is waited for (else it copies itself away and returns at once).
    $dir = $file.Substring(0, $file.LastIndexOfAny([char[]]'\/'))
    # Only the installed app's own processes - not QuickSupport's TeamViewer.exe in a user's TEMP (a live support session).
    $own = $dir.TrimEnd('\') + '\'
    Get-Process -Name 'TeamViewer', 'TeamViewer_Desktop', 'tv_w32', 'tv_x64' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($own, [System.StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue
    return (Invoke-DownloadProcess $file "/S _?=$dir" 30)
}
