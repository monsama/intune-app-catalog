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
                    [pscustomobject]@{ Name = [string]$p.DisplayName; Publisher = [string]$p.Publisher; Key = [string]$k.PSChildName; RegPath = [string]$k.PSPath
                        Uninstall = [string]$p.UninstallString; Quiet = [string]$p.QuietUninstallString; Msi = ([string]$p.WindowsInstaller -eq '1'); Location = [string]$p.InstallLocation }
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
            # What the list says for it (2.38.78): its own time limit, and whether it is removed by hand when its uninstaller fails.
            $e | Add-Member -NotePropertyName Minutes -NotePropertyValue $(if ($t.Minutes) { [int]$t.Minutes } else { 10 }) -Force
            $e | Add-Member -NotePropertyName Force -NotePropertyValue ([bool]$t.Force) -Force
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
    if ($Entry.Quiet) { $cmd = Split-CleanupCommand $Entry.Quiet; $qcut = $cmd[0].LastIndexOfAny([char[]]'\/'); if ($qcut -gt 0) { Stop-CleanupProgramProcesses $cmd[0].Substring(0, $qcut) }; return (Invoke-CleanupProcess $cmd[0] $cmd[1]) }
    if (-not $Entry.Uninstall) { Write-CleanupLog '  it has no uninstall command'; return 1 }
    $cmd = Split-CleanupCommand $Entry.Uninstall
    $file = $cmd[0]; $arguments = $cmd[1]
    # Split by hand (a Windows path - the same wherever the tests run).
    $cut = $file.LastIndexOfAny([char[]]'\/'); $leaf = $file.Substring($cut + 1); $dir = if ($cut -gt 0) { $file.Substring(0, $cut) } else { '' }
    # The program and its services stopped first (2.38.63): an uninstaller that finds it running asks to close it - and
    # waits for an answer nobody can give (Lenovo AI Now's Uninstall.exe /S hung until the time limit).
    Stop-CleanupProgramProcesses $dir
    if ($leaf -match '(?i)^unins\d{3}\.exe$') { $arguments = "$arguments /VERYSILENT /SUPPRESSMSGBOXES /NORESTART".Trim() }
    elseif ($arguments -notmatch '(?i)(^|\s)[/-](s|silent|quiet|q|qn|verysilent)(\s|$)') { $arguments = "$arguments /S".Trim() }
    # An Electron app's uninstaller (electron-builder's NSIS: "Lenovo AINow Uninstall.exe", 2.38.78): installed for all
    # users it needs /allusers - without it, it starts itself again to ask for admin rights and, as SYSTEM, waits for
    # that forever (Lenovo AI Now hung until the time limit).
    $electron = $dir -and (Test-Path -LiteralPath ([System.IO.Path]::Combine($dir, 'resources', 'app.asar')))
    if ($electron -and $arguments -match '(?i)(^|\s)/S(\s|$)' -and $arguments -notmatch '(?i)/(allusers|currentuser)') { $arguments = "$arguments /allusers" }
    # An NSIS uninstaller (Uninstall.exe / uninst.exe, or an Electron app's) copies itself to the temp folder and returns
    # at once: _?= keeps it in place, so its end is waited for (its own folder then stays, empty of the program).
    if (($electron -or $leaf -match '(?i)^(uninstall|uninst)\.exe$') -and $arguments -match '(?i)(^|\s)/S(\s|$)' -and $arguments -notmatch '_\?=') { $arguments = "$arguments _?=$dir" }
    $minutes = if ($Entry.Minutes) { [int]$Entry.Minutes } else { 10 }
    return (Invoke-CleanupProcess $file $arguments $minutes)
}

function Remove-CleanupProgramByHand($Entry) {
    # When its own uninstaller fails or hangs (2.38.78) - only for what the list marks Force: its processes stopped, its
    # folder, its entry in Windows' list of programs and its shortcuts removed. Only a folder of its own under Program
    # Files or ProgramData - never one shared by several programs.
    $folder = [string]$Entry.Location
    if (-not $folder) { $cmd = Split-CleanupCommand $(if ($Entry.Quiet) { $Entry.Quiet } else { $Entry.Uninstall }); $cut = $cmd[0].LastIndexOfAny([char[]]'\/'); if ($cut -gt 0) { $folder = $cmd[0].Substring(0, $cut) } }
    $folder = $folder.Trim('"').TrimEnd('\')
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' }
    $under = @($roots | Where-Object { $folder.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) -and $folder.Length -gt $_.Length + 2 })
    if (-not $under.Count -or $folder -match '(?i)\\(common files|windowsapps|microsoft)(\\|$)') { Write-CleanupLog "  not removed by hand: $folder isn't a program folder of its own"; return $false }
    Write-CleanupLog "  its uninstaller didn't remove it - removing $($Entry.Name) by hand ($folder)"
    Stop-CleanupProgramProcesses $folder
    # Shortcuts that lead into its folder (Start menu, the shared desktop).
    try {
        $shell = New-Object -ComObject WScript.Shell
        foreach ($place in @((Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'), (Join-Path $env:PUBLIC 'Desktop'))) {
            foreach ($lnk in @(Get-ChildItem -LiteralPath $place -Filter '*.lnk' -Recurse -File -ErrorAction SilentlyContinue)) {
                $target = [string]$shell.CreateShortcut($lnk.FullName).TargetPath
                if ($target -and $target.StartsWith($folder + '\', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $lnk.FullName -Force -ErrorAction SilentlyContinue; Write-CleanupLog "  removed the shortcut $($lnk.FullName)" }
            }
        }
    }
    catch { Write-CleanupLog "  its shortcuts couldn't be looked at: $($_.Exception.Message)" }
    Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $folder) { Write-CleanupLog "  some of $folder is still there (in use) - it goes with the next restart's run" }
    if ($Entry.RegPath) { Remove-Item -LiteralPath $Entry.RegPath -Recurse -Force -ErrorAction SilentlyContinue; Write-CleanupLog '  removed from the list of programs' }
    return $true
}

function Stop-CleanupProgramProcesses([string]$Folder) {
    # Processes running from the program's folder, and services whose program is there - stopped before it is removed.
    # Not for a folder that is too general (Windows, Program Files itself) - nor anything in Windows or Common Files
    # (2.38.66): an uninstaller there (rundll32, a shared one) would stop what Windows itself runs from it.
    if (-not $Folder -or $Folder.Length -lt 12 -or $Folder -match '(?i)^[a-z]:\\(windows|program files( \(x86\))?|programdata)\\?$') { return }
    if ($Folder -match '(?i)^[a-z]:\\windows(\\|$)' -or $Folder -match '(?i)\\common files(\\|$)' -or ($env:windir -and $Folder.StartsWith($env:windir, [StringComparison]::OrdinalIgnoreCase))) { Write-CleanupLog "  not stopping what runs from $Folder (a folder Windows or other programs share)"; return }
    $base = $Folder.TrimEnd('\') + '\'
    try {
        foreach ($svc in @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { ([string]$_.PathName).Trim('"').StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or ([string]$_.PathName).StartsWith('"' + $base, [StringComparison]::OrdinalIgnoreCase) })) {
            Write-CleanupLog "  stopping the service $($svc.Name)"
            Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
        }
        foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and ([string]$_.ExecutablePath).StartsWith($base, [StringComparison]::OrdinalIgnoreCase) })) {
            Write-CleanupLog "  stopping $($p.Name) ($($p.ProcessId))"
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    catch { Write-CleanupLog "  couldn't stop what runs from $Folder`: $($_.Exception.Message)" }
}

function Remove-CleanupPackage($Package) {
    Write-CleanupLog "Removing the Store app $($Package.Name) ($($Package.Kind))"
    try {
        if ($Package.Kind -eq 'provisioned') { Remove-AppxProvisionedPackage -Online -PackageName $Package.Full -ErrorAction Stop | Out-Null }
        else { Remove-AppxPackage -Package $Package.Full -AllUsers -ErrorAction Stop }
    }
    catch { Write-CleanupLog "  failed: $($_.Exception.Message)" }
}

function Get-CertificateOrganization([string]$Subject) {
    # The O= values of a certificate subject, read field by field (2.38.71): a comma or "O=" inside another field's
    # quoted value stays part of that value - a subject like CN="x, O=Vendor", O=Someone gives only "Someone".
    $fields = New-Object System.Collections.Generic.List[string]; $cur = New-Object System.Text.StringBuilder; $quoted = $false
    for ($i = 0; $i -lt $Subject.Length; $i++) {
        $c = $Subject[$i]
        if ($c -eq '"') { $quoted = -not $quoted; [void]$cur.Append($c) }
        elseif ($c -eq '\' -and $i + 1 -lt $Subject.Length) { $i++; [void]$cur.Append($c).Append($Subject[$i]) }
        elseif (($c -eq ',' -or $c -eq '+') -and -not $quoted) { $fields.Add($cur.ToString()); [void]$cur.Clear() }
        else { [void]$cur.Append($c) }
    }
    $fields.Add($cur.ToString())
    foreach ($f in $fields) {
        $t = $f.Trim()
        if ($t -cmatch '^O=(.*)$') { $v = $Matches[1].Trim(); if ($v.Length -ge 2 -and $v.StartsWith('"') -and $v.EndsWith('"')) { $v = $v.Substring(1, $v.Length - 2).Replace('""', '"') }; $v }
    }
}

function Test-McAfeeSigned([string]$Path) {
    # Validly signed, by McAfee itself (2.38.66: any certificate with "McAfee" anywhere in its subject passed).
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = [string]$sig.SignerCertificate.Subject
    $orgs = @(Get-CertificateOrganization $subject)
    return ($sig.Status -eq 'Valid' -and $orgs.Count -eq 1 -and @('McAfee, LLC', 'McAfee LLC', 'McAfee, Inc.', 'McAfee Inc.', 'McAfee, Inc', 'McAfee Inc') -ccontains $orgs[0])
}

function New-CleanupPrivateFolder([string]$Parent, [string]$Prefix) {
    # A new folder only SYSTEM and Administrators can change (2.38.66): what is downloaded or unpacked there can't be
    # swapped by another user between being checked and being run. Older ones (a run that stopped) go first.
    foreach ($old in @(Get-ChildItem -LiteralPath $Parent -Directory -Filter "$Prefix*" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) })) { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    $dir = Join-Path $Parent ($Prefix + [guid]::NewGuid().ToString('N'))
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    # Windows PowerShell (what Intune runs) makes it with its permissions at once; PowerShell 7 sets them right after.
    try { [void][System.IO.Directory]::CreateDirectory($dir, $acl) }
    catch { [void](New-Item -ItemType Directory -Path $dir -Force); Set-Acl -LiteralPath $dir -AclObject $acl }
    return $dir
}

function Get-McAfeeRemovalTool {
    <#
      McAfee's removal tool from McAfee (2.38.63), for when its files aren't in the packages folder: MCPR.exe from
      McAfee's download server, used only when it is validly signed by McAfee. MCPR unpacks itself into its temp folder
      when it starts (its command-line part, mccleanup.exe, among the files) and then shows its window: it is started
      with its temp folder in a folder of its own, mccleanup.exe is taken from there once unpacked, and MCPR is stopped.
      2.38.66: everything happens in a folder only SYSTEM and Administrators can change, under the Intune Management
      Extension's folder - not the shared temp folder, where another user could put files of their own. $null when it
      doesn't work (no internet, another file, McAfee changed how MCPR unpacks) - the log says which step.
    #>
    $url = 'https://download.mcafee.com/molbin/iss-loc/SupportTools/MCPR/MCPR.exe'
    $parent = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { [System.IO.Path]::GetTempPath() }) 'Microsoft\IntuneManagementExtension'
    try {
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { Write-CleanupLog "  not used: $parent isn't there"; return $null }
        $work = New-CleanupPrivateFolder $parent 'IntuneAppCatalog-MCPR-'
        $unpack = Join-Path $work 'temp'
        [void](New-Item -ItemType Directory -Path $unpack -Force)
        $exe = Join-Path $work 'MCPR.exe'
        Write-CleanupLog "Fetching McAfee's removal tool: $url"
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $exe -UseBasicParsing -TimeoutSec 300 -ErrorAction Stop
        if (-not (Test-McAfeeSigned $exe)) { $s = Get-AuthenticodeSignature -LiteralPath $exe; Write-CleanupLog "  not used: its signature is $($s.Status) ($($s.SignerCertificate.Subject))"; return $null }
        # Its temp folder is ours: it unpacks there, where nobody else can add a file.
        $psi = New-Object System.Diagnostics.ProcessStartInfo($exe)
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $work
        $psi.EnvironmentVariables['TEMP'] = $unpack; $psi.EnvironmentVariables['TMP'] = $unpack
        $proc = [System.Diagnostics.Process]::Start($psi)
        $found = $null
        for ($i = 0; $i -lt 60 -and -not $found; $i++) {
            Start-Sleep -Seconds 2
            $found = @(Get-ChildItem -LiteralPath $unpack -Filter 'mccleanup.exe' -Recurse -Depth 4 -File -ErrorAction SilentlyContinue) | Select-Object -First 1
        }
        if ($found) {
            # Unpacking done when the folder stops growing.
            $last = -1
            for ($i = 0; $i -lt 15; $i++) { $n = @(Get-ChildItem -LiteralPath $found.DirectoryName -Recurse -File -ErrorAction SilentlyContinue).Count; if ($n -eq $last) { break }; $last = $n; Start-Sleep -Seconds 2 }
        }
        # MCPR and what it started are stopped - its window waits for a click nobody makes.
        foreach ($c in @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)" -ErrorAction SilentlyContinue)) { Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        if (-not $found) { Write-CleanupLog '  not used: MCPR didn''t unpack mccleanup.exe within 2 minutes'; return $null }
        if (-not (Test-McAfeeSigned $found.FullName)) { Write-CleanupLog "  not used: mccleanup.exe's signature is $((Get-AuthenticodeSignature -LiteralPath $found.FullName).Status)"; return $null }
        Write-CleanupLog "  got it: $($found.FullName)"
        return $found
    }
    catch { Write-CleanupLog "  couldn't fetch it: $($_.Exception.Message)"; return $null }
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
    # Not in the packages folder: fetched from McAfee (2.38.63) - see Get-McAfeeRemovalTool.
    if (-not $tool) { $tool = Get-McAfeeRemovalTool }
    if ($tool) {
        $code = Invoke-CleanupProcess $tool.FullName '-p StopServices,MFSY,PEF,MXD,CSP,Sustainability,MOCP,MFP,APPSTATS,Auth,EMproxy,FWdiver,HW,MAS,MAT,MBK,MCPR,McProxy,McSvcHost,VUL,MHN,MNA,MOBK,MPFP,MPFPCU,MPS,SHRED,MPSCU,MQC,MQCCU,MSAD,MSHR,MSK,MSKCU,MWL,NMC,RedirSvc,VS,REMEDIATION,MSC,YAP,TRUEKEY,LAM,PCB,Symlink,SafeConnect,MGS,WMIRemover,RESIDUE -v -s' 30
        Write-CleanupLog "  McAfee removal tool: exit code $code"
        $restart = $true
    }
    else { Write-CleanupLog 'McAfee''s suite needs McAfee''s removal tool and it couldn''t be fetched: put MCPR''s files (mccleanup.exe and the rest) in this app''s packages folder, then Build package and send it again.' }
}
# Store apps first (2.38.78): a program's uninstaller may wait on its Store part (Lenovo AI Now's AINowContextWin11).
foreach ($p in @(Get-CleanupPackages)) { Remove-CleanupPackage $p }
foreach ($e in @(Get-CleanupPrograms)) {
    # An uninstaller that can only ask (no quiet mode) is never started: it would wait for an answer nobody gives.
    if (Test-CleanupLike $e.Uninstall $Targets.NoUninstaller) { Write-CleanupLog "Not starting $($e.Name)'s own uninstaller - it only asks, it can't run unattended."; continue }
    $code = Remove-CleanupProgram $e
    Write-CleanupLog "  exit code $code"
    if ($code -in 1641, 3010) { $restart = $true }
    # Still listed after its uninstaller (failed, or stopped at its time limit): removed by hand when the list says so.
    elseif ($e.Force -and @(Get-CleanupPrograms | Where-Object { $_.Key -eq $e.Key }).Count) { [void](Remove-CleanupProgramByHand $e) }
}

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
