# ---------------------------------------------------------------- Intune App Catalog: removing preinstalled apps
# The shared part of the "Remove preinstalled vendor apps" scripts (2.38.58). Install.ps1 and the detection script
# are the same text: Install.ps1 removes ($DetectOnly = $false), the detection script only looks ($DetectOnly = $true).
# What is removed is the list in Get-CleanupTargets above - edit it in both (Install.ps1 and the detection rule).
#
# Programs: Windows' list of installed programs (64- and 32-bit), matched by name and publisher, removed unattended:
# an MSI with msiexec /x /qn, else the vendor's quiet uninstall command, an Inno Setup uninstaller with /VERYSILENT,
# any other with /S. Each gets 10 minutes (an MSI 30), then it is stopped.
# Store apps (Appx): removed for every user, and from the image so new users don't get them.
# Log: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneAppCatalog-Cleanup-<name>.log (Intune's
# "Collect diagnostics" picks it up).

$Targets = Get-CleanupTargets
$LogFile = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { [System.IO.Path]::GetTempPath() }) ('Microsoft\IntuneManagementExtension\Logs\IntuneAppCatalog-Cleanup-' + $Targets.Name + '.log')

function Write-CleanupLog([string]$Text) {
    if ($DetectOnly) { return }
    try { Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) -Encoding UTF8 } catch { $null = $_ }
}

function Test-CleanupLike([string]$Text, $Patterns) {
    foreach ($p in @($Patterns)) { if ($p -and $Text -like $p) { return $true } }
    return $false
}

function Get-CleanupPrograms($Entries) {
    # In the order of the list (HP Wolf Security's parts need theirs), each program once. -Entries: for the tests.
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    $entries = if ($null -ne $Entries) { @($Entries) } else { @(foreach ($root in $roots) {
            foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
                if ($p -and [string]$p.DisplayName) {
                    [pscustomobject]@{ Name = [string]$p.DisplayName; Publisher = [string]$p.Publisher; Key = [string]$k.PSChildName
                        Uninstall = [string]$p.UninstallString; Quiet = [string]$p.QuietUninstallString; Msi = ([string]$p.WindowsInstaller -eq '1') }
                }
            }
        }) }
    $found = New-Object System.Collections.Generic.List[object]
    foreach ($t in @($Targets.Programs)) {
        foreach ($e in $entries) {
            if ($e.Name -notlike $t.Name) { continue }
            if ($t.Publisher -and -not (Test-CleanupLike $e.Publisher $t.Publisher)) { continue }
            if (Test-CleanupLike $e.Name $Targets.Keep) { continue }
            if (@($found | Where-Object { $_.Key -eq $e.Key }).Count) { continue }
            $found.Add($e)
        }
    }
    return $found.ToArray()
}

function Get-CleanupPackages {
    $found = New-Object System.Collections.Generic.List[object]
    try {
        foreach ($a in @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)) {
            if ((Test-CleanupLike $a.Name $Targets.Packages) -and -not (Test-CleanupLike $a.Name $Targets.KeepPackages)) { $found.Add([pscustomobject]@{ Kind = 'installed'; Name = [string]$a.Name; Full = [string]$a.PackageFullName }) }
        }
        foreach ($a in @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)) {
            if ((Test-CleanupLike $a.DisplayName $Targets.Packages) -and -not (Test-CleanupLike $a.DisplayName $Targets.KeepPackages)) { $found.Add([pscustomobject]@{ Kind = 'provisioned'; Name = [string]$a.DisplayName; Full = [string]$a.PackageName }) }
        }
    }
    catch { Write-CleanupLog "Store apps not read: $($_.Exception.Message)" }
    return $found.ToArray()
}

function Split-CleanupCommand([string]$Command) {
    # A command line as program and arguments: "C:\a b\x.exe" /y, or C:\a\x.exe /y.
    $c = $Command.Trim()
    if ($c.StartsWith('"')) { $end = $c.IndexOf('"', 1); if ($end -gt 0) { return @($c.Substring(1, $end - 1), $c.Substring($end + 1).Trim()) } }
    $m = [regex]::Match($c, '^(.+?\.exe)(\s+.*)?$', 'IgnoreCase')
    if ($m.Success) { return @($m.Groups[1].Value, $m.Groups[2].Value.Trim()) }
    return @($c, '')
}

function Invoke-CleanupProcess([string]$File, [string]$Arguments, [int]$Minutes = 10) {
    Write-CleanupLog "  run: $File $Arguments"
    try {
        $start = @{ FilePath = $File; PassThru = $true; WindowStyle = 'Hidden'; ErrorAction = 'Stop' }
        if ($Arguments) { $start.ArgumentList = $Arguments }
        $proc = Start-Process @start
        if (-not $proc.WaitForExit($Minutes * 60000)) { try { $proc.Kill() } catch { $null = $_ }; Write-CleanupLog "  stopped after $Minutes minutes"; return 1460 }
        return [int]$proc.ExitCode
    }
    catch { Write-CleanupLog "  could not start: $($_.Exception.Message)"; return 1 }
}

function Remove-CleanupProgram($Entry) {
    Write-CleanupLog "Removing $($Entry.Name) ($($Entry.Publisher))"
    $guid = if ($Entry.Key -match '^\{[0-9A-Fa-f-]{36}\}$') { $Entry.Key } else { [regex]::Match($Entry.Uninstall, '\{[0-9A-Fa-f-]{36}\}').Value }
    if ($guid -and ($Entry.Msi -or $Entry.Uninstall -match '(?i)msiexec')) { return (Invoke-CleanupProcess 'msiexec.exe' "/x $guid /qn /norestart REBOOT=ReallySuppress" 30) }
    if ($Entry.Quiet) { $cmd = Split-CleanupCommand $Entry.Quiet; return (Invoke-CleanupProcess $cmd[0] $cmd[1]) }
    if (-not $Entry.Uninstall) { Write-CleanupLog '  it has no uninstall command'; return 1 }
    $cmd = Split-CleanupCommand $Entry.Uninstall
    $file = $cmd[0]; $arguments = $cmd[1]
    if ([System.IO.Path]::GetFileName($file) -match '(?i)^unins\d{3}\.exe$') { $arguments = "$arguments /VERYSILENT /SUPPRESSMSGBOXES /NORESTART".Trim() }
    elseif ($arguments -notmatch '(?i)(^|\s)[/-](s|silent|quiet|q|qn|verysilent)(\s|$)') { $arguments = "$arguments /S".Trim() }
    return (Invoke-CleanupProcess $file $arguments)
}

function Remove-CleanupPackage($Package) {
    Write-CleanupLog "Removing the Store app $($Package.Name) ($($Package.Kind))"
    try {
        if ($Package.Kind -eq 'provisioned') { Remove-AppxProvisionedPackage -Online -PackageName $Package.Full -ErrorAction Stop | Out-Null }
        else { Remove-AppxPackage -Package $Package.Full -AllUsers -ErrorAction Stop }
    }
    catch { Write-CleanupLog "  failed: $($_.Exception.Message)" }
}

# The app's tests load the functions only.
if ($CleanupLoadOnly) { return }

# ---------------------------------------------------------------- detection: found = nothing of the list left
if ($DetectOnly) {
    if (-not @(Get-CleanupPrograms).Count -and -not @(Get-CleanupPackages).Count) { Write-Output 'Nothing of the list is installed.'; exit 0 }
    exit 1
}

# ---------------------------------------------------------------- removal
Write-CleanupLog "---- Remove preinstalled apps ($($Targets.Name)) started"
$restart = $false
# McAfee's own suite has no quiet uninstaller - its own one only asks why (a survey nobody answers). McAfee's removal
# tool (MCPR, its command-line mccleanup.exe) does it when its files are put next to this script (the app's packages
# folder, then Build package) - first, so the suite is gone before the list below (2.38.63).
if ($Targets.McAfeeTool -and @(Get-CleanupPrograms | Where-Object { $_.Name -like 'McAfee*' }).Count) {
    $tool = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'mccleanup.exe' -Recurse -File -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($tool) {
        $code = Invoke-CleanupProcess $tool.FullName '-p StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,WMIRemover,RESIDUE -v -s' 30
        Write-CleanupLog "  McAfee removal tool: exit code $code"
        $restart = $true
    }
    else { Write-CleanupLog 'McAfee''s suite needs McAfee''s removal tool: put MCPR''s files (mccleanup.exe and the rest) in this app''s packages folder, then Build package and send it again.' }
}
foreach ($e in @(Get-CleanupPrograms)) {
    # An uninstaller that can only ask (no quiet mode) is never started: it would wait for an answer nobody gives.
    if (Test-CleanupLike $e.Uninstall $Targets.NoUninstaller) { Write-CleanupLog "Not starting $($e.Name)'s own uninstaller - it only asks, it can't run unattended."; continue }
    $code = Remove-CleanupProgram $e
    Write-CleanupLog "  exit code $code"
    if ($code -in 1641, 3010) { $restart = $true }
}
foreach ($p in @(Get-CleanupPackages)) { Remove-CleanupPackage $p }

$left = @(@(Get-CleanupPrograms | ForEach-Object { $_.Name }) + @(Get-CleanupPackages | ForEach-Object { $_.Name }) | Select-Object -Unique)
# Some uninstallers (NSIS) hand over to a copy of themselves and return at once: up to 3 minutes for them to finish.
for ($wait = 0; $left.Count -and $wait -lt 12; $wait++) {
    Start-Sleep -Seconds 15
    $left = @(@(Get-CleanupPrograms | ForEach-Object { $_.Name }) + @(Get-CleanupPackages | ForEach-Object { $_.Name }) | Select-Object -Unique)
}
if ($left.Count) {
    Write-CleanupLog "Still installed: $($left -join ', ')$(if ($restart) { ' - a restart may finish it' })"
    # A restart may finish it (McAfee, some MSI): Intune restarts and the detection decides; else it failed and Intune tries again later.
    if ($restart) { exit 3010 }
    exit 1
}
Write-CleanupLog 'Done - nothing of the list is installed.'
if ($restart) { exit 3010 }
exit 0
