<#
    Do the vendors' files still pass the signature checks the device scripts make? (2.38.71)

    Some scripts download a vendor's file when they run on a device and use it only when the vendor signed it.
    They check that by the certificate's organisation (O=):
      - Download\*.ps1: TeamViewer and QuickSupport.
      - Cleanup\Common.ps1: McAfee's removal tool, MCPR.
      - Package.ps1: Microsoft's packaging tool, IntuneWinAppUtil.
    A vendor that renames its company on a new certificate makes the device refuse the file. This downloads each
    file, as the device would, and runs the same check on it - the same functions, read from the same scripts.

    It reaches the internet, so it runs on its own schedule (.github/workflows/vendor-signatures.yml), never in
    the tests a pull request waits on. Windows only: Get-AuthenticodeSignature reads Authenticode there.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop')) { Write-Host 'Skipped: the signature checks need Windows.'; exit 0 }

$scripts = Join-Path (Split-Path -Parent $PSScriptRoot) 'EmbeddedScripts'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('vendor-signatures-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $work)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$failures = 0

function Save-VendorFile([string]$Url, [string]$Name) {
    # Three tries, as the device scripts do - a vendor's server can be slow for a moment.
    $file = Join-Path $work $Name
    for ($try = 1; $try -le 3; $try++) {
        try { Invoke-WebRequest -Uri $Url -OutFile $file -UseBasicParsing -TimeoutSec 600; return $file }
        catch { if ($try -eq 3) { throw }; Start-Sleep -Seconds (15 * $try) }
    }
}
function Write-Verdict([string]$What, [bool]$Ok, $Signature) {
    $subject = if ($Signature -and $Signature.SignerCertificate) { $Signature.SignerCertificate.Subject } else { '(no certificate)' }
    $status = if ($Signature) { $Signature.Status } else { '-' }
    if ($Ok) { Write-Host "[OK] $What - $status, $subject" }
    else { Write-Host "[FAILED] $What - $status, $subject" -ForegroundColor Red; $script:failures++ }
}

try {
    # TeamViewer and QuickSupport: each vendor file with Common.ps1, loaded only (no install), as the tests do.
    foreach ($vendor in @(Get-ChildItem -LiteralPath (Join-Path $scripts 'Download') -Filter '*.ps1' | Where-Object Name -ne 'Common.ps1')) {
        try {
            $r = & {
                Set-Variable -Name DownloadLoadOnly -Value $true; Set-Variable -Name Action -Value 'Detect'
                . $vendor.FullName; . (Join-Path $scripts 'Download\Common.ps1')
                $t = Get-DownloadTarget
                $f = Save-VendorFile $t.Url ($vendor.BaseName + '-' + $t.File)
                $sig = Get-AuthenticodeSignature -LiteralPath $f
                @{ Name = $t.Name; Sig = $sig; Ok = ($sig.Status -eq 'Valid' -and (Test-DownloadSigner ([string]$sig.SignerCertificate.Subject))) }
            }
            Write-Verdict "$($r.Name) ($($vendor.Name))" $r.Ok $r.Sig
        }
        catch { Write-Host "[FAILED] $($vendor.Name): $($_.Exception.Message)" -ForegroundColor Red; $failures++ }
    }

    # McAfee's removal tool: its address read from Cleanup\Common.ps1, checked with its Test-McAfeeSigned.
    try {
        $common = Join-Path $scripts 'Cleanup\Common.ps1'
        $url = [regex]::Match((Get-Content -LiteralPath $common -Raw), "https://download\.mcafee\.com/[^'`"]+").Value
        if (-not $url) { throw "No McAfee address found in $common" }
        $r = & {
            Set-Variable -Name CleanupLoadOnly -Value $true; Set-Variable -Name DetectOnly -Value $true
            . (Join-Path $scripts 'Cleanup\Lenovo.ps1'); . $common
            $f = Save-VendorFile $url 'MCPR.exe'
            @{ Sig = (Get-AuthenticodeSignature -LiteralPath $f); Ok = (Test-McAfeeSigned $f) }
        }
        Write-Verdict "McAfee MCPR ($url)" $r.Ok $r.Sig
    }
    catch { Write-Host "[FAILED] McAfee MCPR: $($_.Exception.Message)" -ForegroundColor Red; $failures++ }

    # IntuneWinAppUtil: the address and the check (Test-SignedByMicrosoft) from Package.ps1, read by the parser -
    # Package.ps1 itself runs a whole packaging when started.
    try {
        $pkg = Join-Path $scripts 'Package.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($pkg, [ref]$null, [ref]$null)
        $fns = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in 'Get-CertificateOrganization', 'Test-SignedByMicrosoft' }, $true)
        if (@($fns).Count -ne 2) { throw "Get-CertificateOrganization / Test-SignedByMicrosoft not found in $pkg" }
        $url = [regex]::Match((Get-Content -LiteralPath $pkg -Raw), 'https://github\.com/microsoft/Microsoft-Win32-Content-Prep-Tool/[^"'']+\.zip').Value
        if (-not $url) { throw "No IntuneWinAppUtil address found in $pkg" }
        $r = & {
            foreach ($fn in $fns) { . ([scriptblock]::Create($fn.Extent.Text)) }
            $zip = Save-VendorFile $url 'IntuneWinAppUtil.zip'
            $out = Join-Path $work 'IntuneWinAppUtil'
            Expand-Archive -LiteralPath $zip -DestinationPath $out -Force
            $exe = Get-ChildItem -LiteralPath $out -Filter 'IntuneWinAppUtil.exe' -Recurse | Select-Object -First 1
            if (-not $exe) { throw 'IntuneWinAppUtil.exe is not in the download' }
            $sig = Get-AuthenticodeSignature -LiteralPath $exe.FullName
            @{ Sig = $sig; Ok = (Test-SignedByMicrosoft $sig) }
        }
        Write-Verdict 'IntuneWinAppUtil.exe' $r.Ok $r.Sig
    }
    catch { Write-Host "[FAILED] IntuneWinAppUtil: $($_.Exception.Message)" -ForegroundColor Red; $failures++ }
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

if ($failures) {
    Write-Host "$failures vendor file(s) would be refused on the devices - see the subjects above. A new company name on the certificate goes into the script's list of allowed organisations." -ForegroundColor Red
    exit 1
}
Write-Host 'Every vendor file passes the check the devices make.'
