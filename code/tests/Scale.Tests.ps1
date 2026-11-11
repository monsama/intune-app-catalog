<#
.SYNOPSIS
    A large catalog: 500 generated apps in a temporary catalog folder, the
    real server pointed at it (Settings > Folders > Catalog), and the
    requests that read the whole catalog timed - the Apps list, Checks
    (catalog-only, no tenant), the editor, a save, Diagnostics, Groups.

    Fails when one of them takes longer than its limit. The limits are
    generous on purpose (CI machines vary); the timings are printed, so a
    slow change shows up in the log before it reaches a limit.

    pwsh -NoProfile -File code/tests/Scale.Tests.ps1
#>
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$failures = New-Object System.Collections.Generic.List[string]
$passed = 0
function Check([bool]$Condition, [string]$Name, [string]$Detail = '') {
    if ($Condition) { $script:passed++ } else { $script:failures.Add("$Name $Detail") ; Write-Host "FAIL: $Name $Detail" -ForegroundColor Red }
}

$count = 500
$work = Join-Path ([System.IO.Path]::GetTempPath()) ("scale-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$catalog = Join-Path $work 'catalog'
[void](New-Item -ItemType Directory -Path $catalog -Force)
$groups = @(1..40 | ForEach-Object { "SG-Scale-$_" })
$utf8 = New-Object System.Text.UTF8Encoding($false)
for ($i = 1; $i -le $count; $i++) {
    $n = '{0:D3}' -f $i
    $app = [ordered]@{
        appId        = $(if ($i % 2) { [guid]::NewGuid().ToString() } else { '' })
        appName      = "Scale App $n"
        wingetId     = "Vendor.ScaleApp$n"
        requiredFor  = @($groups[$i % 40], $groups[($i + 7) % 40])
        availableFor = @($groups[($i + 13) % 40])
        uninstallFor = @()
        excludeFor   = @()
        metadata     = [ordered]@{
            description = "Generated app $n for the scale test."; publisher = 'Vendor'; owner = ''; developer = ''
            informationUrl = ''; privacyUrl = ''; notes = ''; appVersion = "1.0.$i"
            installCommand = "install.cmd $n"; uninstallCommand = "uninstall.cmd $n"
            architecture = 'x64'; installContext = 'System'; minOSKey = 'W10_22H2'
            dependencies = @($(if ($i -gt 1 -and $i % 10 -eq 0) { 'Scale App {0:D3}' -f ($i - 1) }) | Where-Object { $_ })
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $catalog "Scale-App-$n.json"), ($app | ConvertTo-Json -Depth 6), $utf8)
}

$settingsPath = Join-Path $repoRoot "data\intune-deployment-settings.json"
$settingsBackup = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw } else { $null }
[void](New-Item -ItemType Directory -Path (Split-Path $settingsPath -Parent) -Force)
Set-Content -LiteralPath $settingsPath -Value (@{ Folders = @{ Catalog = $catalog; Backups = (Join-Path $work 'backups') } } | ConvertTo-Json -Compress) -Encoding UTF8

$hostExe = (Get-Process -Id $PID).Path
$outFile = Join-Path $work 'server.out'
$startArgs = @{
    FilePath               = $hostExe
    ArgumentList           = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $repoRoot 'IntuneDeployment.ps1')`"", '-NoBrowser')
    RedirectStandardOutput = $outFile
    PassThru               = $true
}
if ($IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop') { $startArgs.WindowStyle = 'Hidden' }
$proc = Start-Process @startArgs

try {
    $url = $null
    $deadline = (Get-Date).AddSeconds(90)
    while (-not $url -and (Get-Date) -lt $deadline -and -not $proc.HasExited) {
        Start-Sleep -Milliseconds 500
        if (Test-Path -LiteralPath $outFile) {
            $m = Select-String -LiteralPath $outFile -Pattern 'Open:\s+(http://127\.0\.0\.1:\d+)/#t=([0-9a-f]{32})' | Select-Object -First 1
            if ($m) { $url = $m.Matches[0].Groups[1].Value; $token = $m.Matches[0].Groups[2].Value }
        }
    }
    if (-not $url) { throw "no server: $(if (Test-Path $outFile) { Get-Content $outFile -Raw })" }
    $port = [int]($url -replace '.*:(\d+)$', '$1')

    function Invoke-Api([string]$Path, [hashtable]$Data = @{}) {
        $Data.token = $token
        $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $port)
        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes(($Data | ConvertTo-Json -Compress -Depth 10))
            $head = [Text.Encoding]::ASCII.GetBytes("POST $Path HTTP/1.1`r`nHost: 127.0.0.1:$port`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
            $stream = $client.GetStream(); $stream.ReadTimeout = 120000
            $stream.Write($head, 0, $head.Length); $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
            $text = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
            return ($text.Substring($text.IndexOf("`r`n`r`n") + 4) | ConvertFrom-Json)
        }
        finally { $client.Close() }
    }
    # Each request twice; the second time counts (the first warms the runspace up).
    function Measure-Api([string]$Name, [string]$Path, [hashtable]$Data, [double]$LimitSeconds, [scriptblock]$Valid) {
        [void](Invoke-Api $Path $Data.Clone())
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Api $Path $Data.Clone()
        $s = $sw.Elapsed.TotalSeconds
        Write-Host ("  {0,-34} {1,6:N2} s  (limit {2} s)" -f $Name, $s, $LimitSeconds)
        Check ($r.ok -and (& $Valid $r)) "$($count) apps: $Name answers correctly" (($r | ConvertTo-Json -Compress -Depth 3) -replace '^(.{300}).*', '$1...')
        Check ($s -le $LimitSeconds) "$($count) apps: $Name within $LimitSeconds s" ("{0:N2} s" -f $s)
    }

    Write-Host "Timings with $count apps:"
    Measure-Api 'Apps list (/api/catalog)' '/api/catalog' @{} 6 { param($r) @($r.apps).Count -eq $count }
    Measure-Api 'Checks, catalog only' '/api/checks-run' @{} 15 { param($r) $r.PSObject.Properties.Name -contains 'findings' }
    Measure-Api 'Open one app in the editor' '/api/app-get' @{ name = 'Scale App 250' } 6 { param($r) $r.app.appName -eq 'Scale App 250' }
    Measure-Api 'Diagnostics' '/api/diagnostics' @{} 15 { param($r) @($r.sections).Count -ge 2 }
    Measure-Api 'Groups the catalog uses' '/api/groups' @{} 6 { param($r) @($r.groups).Count -eq 40 }
    $got = Invoke-Api '/api/app-get' @{ name = 'Scale App 250' }
    $edit = @{ originalName = 'Scale App 250'; version = $got.version; app = @{ appName = 'Scale App 250'; wingetId = 'Vendor.ScaleApp250'; appId = ''; requiredFor = @('SG-Scale-1'); metadata = @{ description = 'saved by the scale test' } } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $saved = Invoke-Api '/api/app-save' $edit
    $s = $sw.Elapsed.TotalSeconds
    Write-Host ("  {0,-34} {1,6:N2} s  (limit {2} s)" -f 'Save one app', $s, 6)
    Check ($saved.ok) "$($count) apps: a save goes through" ($saved | ConvertTo-Json -Compress)
    Check ($s -le 6) "$($count) apps: a save within 6 s" ("{0:N2} s" -f $s)

    [void](Invoke-Api '/api/quit')
    [void]$proc.WaitForExit(15000)
}
finally {
    if (-not $proc.HasExited) { try { $proc.Kill() } catch { } }
    if ($null -ne $settingsBackup) { Set-Content -LiteralPath $settingsPath -Value $settingsBackup -Encoding UTF8 } else { Remove-Item -LiteralPath $settingsPath -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($failures.Count -eq 0) { Write-Host "PASSED: $passed check(s)." -ForegroundColor Green; exit 0 }
Write-Host "FAILED: $($failures.Count) of $($passed + $failures.Count)." -ForegroundColor Red
exit 1
