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
        [string]$Exe = "powershell.exe",
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

