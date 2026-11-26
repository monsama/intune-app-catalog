# ---------------------------------------------------------------- Intune App Catalog: apps fetched from their vendor (2.38.66)
# The vendor's file is downloaded when the app installs - the newest one, from the vendor's own address - and used
# only when it is validly signed by the vendor. No hash is kept here, so a vendor replacing the file at the same
# address (winget's "installer hash mismatch", 0x8A150011) never stops it. Install.ps1, Uninstall.ps1 and the
# detection script are the same text: $Action says which part runs (Install, Uninstall, Detect).
# The download goes into a new folder only SYSTEM and Administrators can change (under the Intune Management
# Extension's folder) - nobody else can swap the file between its check and its start.

# The vendor file above says what (Get-DownloadTarget): its name, log, address, file and signer.
$Target = Get-DownloadTarget
$LogFile = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { [System.IO.Path]::GetTempPath() }) "Microsoft\IntuneManagementExtension\Logs\IntuneAppCatalog-$($Target.Log).log"
function Write-DownloadLog([string]$Text) {
    if ($Action -eq 'Detect') { return }
    try { Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) -Encoding UTF8 } catch { $null = $_ }
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

function Test-DownloadSigner([string]$Subject) {
    # Pure: whether a certificate's subject is the vendor's own - exactly one organisation (O=), one of $Target.Signer.
    $orgs = @(Get-CertificateOrganization $Subject)
    return ($orgs.Count -eq 1 -and @($Target.Signer) -ccontains $orgs[0])
}

function Get-DownloadArpEntries([string]$Pattern) {
    # The programs Windows lists (both views) whose name matches -Pattern: @{ Name; Version; Uninstall; Quiet }.
    $roots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    $found = foreach ($root in $roots) {
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and [string]$p.DisplayName -match $Pattern) { [pscustomobject]@{ Name = [string]$p.DisplayName; Version = [string]$p.DisplayVersion; Uninstall = [string]$p.UninstallString; Quiet = [string]$p.QuietUninstallString } }
        }
    }
    return @($found)
}

function Invoke-DownloadProcess([string]$File, [string]$Arguments, [int]$Minutes = 30) {
    # Runs a program hidden and waits for it - at most -Minutes, then it is stopped (1460, Intune's "timed out").
    Write-DownloadLog "  run: $File $Arguments"
    try {
        $proc = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -WindowStyle Hidden -ErrorAction Stop
        if (-not $proc.WaitForExit($Minutes * 60000)) { try { $proc.Kill() } catch { $null = $_ }; Write-DownloadLog "  stopped after $Minutes minutes"; return 1460 }
        Write-DownloadLog "  exit code $($proc.ExitCode)"
        return [int]$proc.ExitCode
    }
    catch { Write-DownloadLog "  could not start: $($_.Exception.Message)"; return 1 }
}

function New-DownloadPrivateFolder([string]$Parent, [string]$Prefix) {
    # A new folder only SYSTEM and Administrators can change; older ones (a run that stopped) go first.
    foreach ($old in @(Get-ChildItem -LiteralPath $Parent -Directory -Filter "$Prefix*" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) })) { Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    $dir = Join-Path $Parent ($Prefix + [guid]::NewGuid().ToString('N'))
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18', 'S-1-5-32-544') {
        $id = New-Object System.Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($id, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    try { [void][System.IO.Directory]::CreateDirectory($dir, $acl) }
    catch { [void](New-Item -ItemType Directory -Path $dir -Force); Set-Acl -LiteralPath $dir -AclObject $acl }
    return $dir
}

function Get-DownloadedFile {
    # The vendor's file, downloaded and checked: @{ File; Folder } - $null when that fails (the log says why).
    $parent = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { [System.IO.Path]::GetTempPath() }) 'Microsoft\IntuneManagementExtension'
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { Write-DownloadLog "  $parent isn't there"; return $null }
    $folder = New-DownloadPrivateFolder $parent "IntuneAppCatalog-$($Target.Log)-"
    $file = Join-Path $folder $Target.File
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    for ($try = 1; $try -le 3; $try++) {
        try {
            Write-DownloadLog "Downloading $($Target.Url) (try $try)"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $Target.Url -OutFile $file -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
            break
        }
        catch { Write-DownloadLog "  failed: $($_.Exception.Message)"; if ($try -eq 3) { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue; return $null }; Start-Sleep -Seconds (15 * $try) }
    }
    $sig = Get-AuthenticodeSignature -LiteralPath $file
    if ($sig.Status -ne 'Valid' -or -not (Test-DownloadSigner ([string]$sig.SignerCertificate.Subject))) {
        Write-DownloadLog "  not used: its signature is $($sig.Status) ($($sig.SignerCertificate.Subject))"
        Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue
        return $null
    }
    $v = (Get-Item -LiteralPath $file).VersionInfo
    Write-DownloadLog "  got $($Target.File) $($v.ProductVersion), signed by $($sig.SignerCertificate.Subject)"
    return @{ File = $file; Folder = $folder }
}

# The app's tests load the functions only.
if ($DownloadLoadOnly) { return }

switch ($Action) {
    'Detect' {
        if (Test-AppInstalled) { Write-Output "$($Target.Name) is installed."; exit 0 }
        exit 1
    }
    'Uninstall' {
        Write-DownloadLog "---- Removing $($Target.Name)"
        $code = Uninstall-App
        if (Test-AppInstalled) { Write-DownloadLog "Still installed (exit code $code)."; exit $(if ($code) { $code } else { 1 }) }
        Write-DownloadLog 'Removed.'
        exit 0
    }
    default {
        Write-DownloadLog "---- Installing $($Target.Name)"
        $dl = Get-DownloadedFile
        if (-not $dl) { exit 1 }
        try { $code = Install-App $dl.File }
        finally { Remove-Item -LiteralPath $dl.Folder -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-AppInstalled) { Write-DownloadLog 'Installed.'; exit 0 }
        Write-DownloadLog "Not installed (exit code $code)."
        exit $(if ($code) { $code } else { 1 })
    }
}
