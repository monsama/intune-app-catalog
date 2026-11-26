# ---------------------------------------------------------------- TeamViewer QuickSupport, fetched from TeamViewer
# "TeamViewer QuickSupport" in the starter set (2.38.66): TeamViewer's newest QuickSupport from TeamViewer's download
# address, used only when signed by TeamViewer. QuickSupport isn't installed - it is one program the user starts: it
# is put in C:\Program Files\TeamViewer QuickSupport (only administrators can change it there), with a shortcut in the
# Start menu and on the desktop. Found = the program is there. Nothing runs in the background.
# Log: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneAppCatalog-TeamViewerQS.log

function Get-DownloadTarget {
    return @{
        Name   = 'TeamViewer QuickSupport'
        Log    = 'TeamViewerQS'
        Url    = 'https://download.teamviewer.com/download/TeamViewerQS_x64.exe'
        File   = 'TeamViewerQS_x64.exe'
        Signer = '(^|,\s*)O="?TeamViewer (Germany )?GmbH"?(,|$)'
    }
}
$QsDir = Join-Path $(if ($env:ProgramFiles) { $env:ProgramFiles } else { 'C:\Program Files' }) 'TeamViewer QuickSupport'
$QsExe = Join-Path $QsDir 'TeamViewerQS.exe'
$QsLinks = @(
    (Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { 'C:\ProgramData' }) 'Microsoft\Windows\Start Menu\Programs\TeamViewer QuickSupport.lnk'),
    (Join-Path $(if ($env:PUBLIC) { $env:PUBLIC } else { 'C:\Users\Public' }) 'Desktop\TeamViewer QuickSupport.lnk')
)

function Test-AppInstalled { return (Test-Path -LiteralPath $QsExe -PathType Leaf) }

function Install-App([string]$File) {
    try {
        if (-not (Test-Path -LiteralPath $QsDir)) { [void](New-Item -ItemType Directory -Path $QsDir -Force) }
        Get-Process -Name 'TeamViewerQS*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $QsExe } | Stop-Process -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $File -Destination $QsExe -Force -ErrorAction Stop
        $shell = New-Object -ComObject WScript.Shell
        foreach ($l in $QsLinks) {
            try { $s = $shell.CreateShortcut($l); $s.TargetPath = $QsExe; $s.WorkingDirectory = $QsDir; $s.Description = 'TeamViewer QuickSupport - give support your ID'; $s.Save() }
            catch { Write-DownloadLog "  shortcut not made ($l): $($_.Exception.Message)" }
        }
        Write-DownloadLog "  put in $QsExe"
        return 0
    }
    catch { Write-DownloadLog "  failed: $($_.Exception.Message)"; return 1 }
}

function Uninstall-App {
    Get-Process -Name 'TeamViewerQS*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $QsExe } | Stop-Process -Force -ErrorAction SilentlyContinue
    foreach ($l in $QsLinks) { Remove-Item -LiteralPath $l -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $QsDir -Recurse -Force -ErrorAction SilentlyContinue
    return $(if (Test-Path -LiteralPath $QsExe) { 1 } else { 0 })
}
