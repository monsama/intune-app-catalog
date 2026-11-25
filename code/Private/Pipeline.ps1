function Global:Get-OwnPowerShellPath {
    <#
      The PowerShell this app runs in, as a file path (2.38.46). (Get-Process -Id $PID).Path reads the process's
      main module - in some containers that read is refused and the path came back empty: a step then failed with
      "a file name has not been provided". .NET's own ProcessPath first, then that, then pwsh in $PSHOME.
    #>
    $p = ''
    try { $p = [string][System.Environment]::ProcessPath } catch { }
    if (-not $p) { try { $p = [string](Get-Process -Id $PID -ErrorAction Stop).Path } catch { } }
    if (-not $p) { foreach ($n in 'pwsh', 'pwsh.exe', 'powershell.exe') { $c = Join-Path $PSHOME $n; if (Test-Path -LiteralPath $c -PathType Leaf) { $p = $c; break } } }
    if (-not $p) { throw "The PowerShell this app runs in couldn't be found (PSHOME: $PSHOME)." }
    return $p
}

function Global:New-AppStepStartInfo {
    <#
      A ProcessStartInfo that runs one background step through
      code\Runner\Invoke-AppStep.ps1 - a readable "-File <app script>"
      command line instead of "-EncodedCommand <base64>", which endpoint
      protection (Cortex XDR, Defender ASR, ...) blocks or flags as malware.
      What to run goes into a small JSON spec in %TEMP% that the runner
      reads and deletes straight away. -Spec keys: see the runner's header.
    #>
    param(
        # Windows PowerShell 5.1 on Windows; on Linux (the container) the PowerShell this app runs in.
        [string]$Exe = $(if ($IsLinux -or $IsMacOS) { Get-OwnPowerShellPath } else { "powershell.exe" }),
        [hashtable]$Spec,
        [switch]$NonInteractive
    )
    $runner = Join-Path $Global:App.RootPath "code\Runner\Invoke-AppStep.ps1"
    if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "The step runner is missing: $runner. Re-extract the app's folder." }
    $specPath = Join-Path $env:TEMP (".intunepkg_step_" + [guid]::NewGuid().ToString("N") + ".json")
    [System.IO.File]::WriteAllText($specPath, ($Spec | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = "-NoLogo -NoProfile$(if ($NonInteractive) { ' -NonInteractive' }) -ExecutionPolicy Bypass -File `"$runner`" -Spec `"$specPath`""
    $psi.UseShellExecute = $false
    return $psi
}

