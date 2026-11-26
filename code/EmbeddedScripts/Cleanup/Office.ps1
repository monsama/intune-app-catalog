# ---------------------------------------------------------------- Intune App Catalog: removing preinstalled Office
# "Remove preinstalled Office" (2.38.58): the consumer Office a new PC comes with (the Microsoft 365 Family/Personal
# trial, OneNote) - in every language it has. Microsoft 365 Apps
# for enterprise or business, Visio, Project and volume-licensed Office stay. Install.ps1 and the detection script
# are the same text: Install.ps1 removes ($DetectOnly = $false), the detection script only looks ($DetectOnly = $true).
# How: each preinstalled language brings its own uninstall command (OfficeClickToRun.exe ... productstoremove=...);
# it is run with DisplayLevel=False - no download, nothing shown. One at a time, 30 minutes each at most.
# Log: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneAppCatalog-Cleanup-Office.log

function Get-OfficeRemovePattern {
    # The Office product IDs removed (Click-to-Run): the Microsoft 365 Family/Personal trial PCs come with, and the free
    # OneNote. Edit it here and in the detection rule alike. Not by default (2.38.61): bought perpetual Office - Home &
    # Student, Home & Business, Professional (add HomeStudent|HomeBusiness|Professional below if PCs bring those too).
    return '^(O365HomePrem|O365Personal|OneNoteFree)\d*Retail$'
}

$LogFile = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { [System.IO.Path]::GetTempPath() }) 'Microsoft\IntuneManagementExtension\Logs\IntuneAppCatalog-Cleanup-Office.log'
function Write-CleanupLog([string]$Text) {
    if ($DetectOnly) { return }
    try { Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) -Encoding UTF8 } catch { $null = $_ }
}

function Get-PreinstalledOffice {
    $pattern = Get-OfficeRemovePattern
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($root in $roots) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            $u = [string]$(if ($p) { $p.UninstallString })
            if ($u -notmatch '(?i)OfficeClickToRun\.exe' -or $u -notmatch '(?i)productstoremove=(\S+)') { continue }
            # "O365HomePremRetail.16_de-de_x-none" - the product before the first dot.
            $product = ($Matches[1] -split '\.')[0]
            if ($product -notmatch $pattern) { continue }
            if (@($found | Where-Object { $_.Uninstall -eq $u }).Count) { continue }
            $found.Add([pscustomobject]@{ Name = [string]$p.DisplayName; Product = $product; Uninstall = $u })
        }
    }
    return $found.ToArray()
}

if ($DetectOnly) {
    if (-not @(Get-PreinstalledOffice).Count) { Write-Output 'No preinstalled Office.'; exit 0 }
    exit 1
}

Write-CleanupLog '---- Remove preinstalled Office started'
foreach ($o in @(Get-PreinstalledOffice)) {
    Write-CleanupLog "Removing $($o.Name) ($($o.Product))"
    $c = $o.Uninstall.Trim()
    if ($c.StartsWith('"')) { $end = $c.IndexOf('"', 1); $file = $c.Substring(1, $end - 1); $arguments = $c.Substring($end + 1).Trim() }
    else { $m = [regex]::Match($c, '^(.+?\.exe)(\s+.*)?$', 'IgnoreCase'); $file = $m.Groups[1].Value; $arguments = $m.Groups[2].Value.Trim() }
    if ($arguments -notmatch '(?i)DisplayLevel=') { $arguments = "$arguments DisplayLevel=False" }
    try {
        $proc = Start-Process -FilePath $file -ArgumentList $arguments -PassThru -WindowStyle Hidden -ErrorAction Stop
        if (-not $proc.WaitForExit(30 * 60000)) { try { $proc.Kill() } catch { $null = $_ }; Write-CleanupLog '  stopped after 30 minutes' }
        else { Write-CleanupLog "  exit code $($proc.ExitCode)" }
    }
    catch { Write-CleanupLog "  could not start: $($_.Exception.Message)" }
}
$left = @(Get-PreinstalledOffice)
if ($left.Count) {
    # Office busy (an update, Microsoft 365 Apps being installed): failed for now - Intune tries again later.
    Write-CleanupLog "Still installed: $(($left | ForEach-Object { $_.Name }) -join ', ')"
    exit 1
}
Write-CleanupLog 'Done - no preinstalled Office left.'
exit 0
