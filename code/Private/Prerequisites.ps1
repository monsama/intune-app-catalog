# The one PowerShell module this app depends on - Microsoft.Graph.Authentication
# (Connect-MgGraph / Invoke-MgGraphRequest) - and the in-app way to install it
# (Settings > Prerequisites), instead of telling the user to run Install-Module
# by hand.
#
# Two places load it:
#   - the PowerShell running the app's server - the reads the page asks for
#   - Windows PowerShell 5.1 - Start-WebStepJob runs the deployment and
#     assignment steps with powershell.exe
# Installing into the app's own PowerShell covers both: every 5.1 step gets
# Get-WindowsPowerShellModulePath, which adds the folder this PowerShell loads
# the module from. The 5.1 side is still checked separately, by actually
# importing the module there the way a step would.

function Global:Get-GraphModuleName { "Microsoft.Graph.Authentication" }

function Global:Get-WindowsPowerShellPath {
    Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
}

function Global:Get-WindowsPowerShellModulePath {
    <#
      The PSModulePath every Windows PowerShell 5.1 child of this app runs with.
      Set explicitly rather than inherited: under PowerShell 7 the inherited
      value is PowerShell 7's, which (confirmed live) hides 5.1's own per-user
      module folder and puts PowerShell 7's $PSHOME\Modules - its .NET builds
      of PowerShellGet, PackageManagement, ... - in front of 5.1's.
      = 5.1's own defaults (per-user folder + the machine/user PSModulePath
        entries 5.1 would read itself)
      + under PowerShell 7: the folder(s) this PowerShell loads the Graph
        module from, so one install serves both.
    #>
    $paths = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string]$p)
        $p = "$p".Trim().TrimEnd('\')
        if (-not $p) { return }
        foreach ($existing in $paths) { if ($existing -ieq $p) { return } }
        $paths.Add($p)
    }
    & $add (Join-Path ([Environment]::GetFolderPath("MyDocuments")) "WindowsPowerShell\Modules")
    foreach ($scope in "User", "Machine") {
        foreach ($p in "$([Environment]::GetEnvironmentVariable('PSModulePath', $scope))" -split ';') { & $add $p }
    }
    & $add (Join-Path $env:ProgramFiles "WindowsPowerShell\Modules")
    & $add (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\Modules")
    if ($PSVersionTable.PSEdition -eq "Core") {
        $moduleName = Get-GraphModuleName
        foreach ($m in Get-Module -ListAvailable -Name $moduleName) {
            # ...\Modules\<name>\<version>  or  ...\Modules\<name>
            $dir = Split-Path $m.ModuleBase -Parent
            if ((Split-Path $dir -Leaf) -ieq $moduleName) { $dir = Split-Path $dir -Parent }
            if (-not $dir.StartsWith($PSHOME, [System.StringComparison]::OrdinalIgnoreCase)) { & $add $dir }
        }
    }
    return ($paths -join ";")
}

function Global:Set-WindowsPowerShellEnvironment {
    # Applies Get-WindowsPowerShellModulePath to a ProcessStartInfo that's about
    # to start Windows PowerShell (no-op for anything else).
    param([System.Diagnostics.ProcessStartInfo]$StartInfo)
    $exe = [System.IO.Path]::GetFileName($StartInfo.FileName)
    if ($exe -ieq "powershell.exe" -or $exe -ieq "powershell") {
        $StartInfo.EnvironmentVariables["PSModulePath"] = Get-WindowsPowerShellModulePath
    }
}

function Global:Invoke-HiddenPowerShell {
    # Runs a short command in a separate, windowless PowerShell - with the same
    # environment Start-WebStepJob gives its steps, so the answer matches
    # what those steps will actually see. Returns the last line of output, or
    # $null on failure/timeout.
    param([string]$Exe, [string]$Command, [int]$TimeoutMs = 30000)
    try {
        # Through the step runner, not -EncodedCommand - see New-AppStepStartInfo.
        $psi = New-AppStepStartInfo -Exe $Exe -NonInteractive -Spec @{ Command = "`$ProgressPreference = 'SilentlyContinue'; " + $Command }
        $psi.CreateNoWindow = $true
        # Both streams captured - an inherited stderr would put the child's
        # progress/CLIXML noise into this app's own error output.
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        Set-WindowsPowerShellEnvironment -StartInfo $psi
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEndAsync()
        [void]$proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutMs)) { try { $proc.Kill() } catch { }; return $null }
        $lines = @($out.Result -split "`r?`n" | Where-Object { $_.Trim() })
        if ($lines.Count -eq 0) { return $null }
        return $lines[-1].Trim()
    }
    catch { return $null }
}

function Global:Test-GraphModuleHere {
    # Installed in the PowerShell running the app? A yes is remembered for
    # the session (nothing here uninstalls); a no is re-checked every time, in
    # case the user installed it some other way meanwhile.
    if ($Global:App.GraphModuleHereConfirmed) { return $true }
    if (Get-Module -ListAvailable -Name (Get-GraphModuleName)) {
        $Global:App.GraphModuleHereConfirmed = $true
        return $true
    }
    return $false
}

function Global:Get-GraphModuleStatus {
    <#
      One row per PowerShell this app loads the module in: Name (for
      display), Version ('' when unusable there), Problem (why, if not just
      "not installed"). Row 0 is always the PowerShell running the app -
      the one Install missing installs into.
      The Windows PowerShell row starts a separate powershell.exe and imports
      the module there - a few seconds; Settings > Prerequisites runs this
      off the UI thread.
    #>
    $moduleName = Get-GraphModuleName
    $rows = New-Object System.Collections.Generic.List[object]
    $isCore = $PSVersionTable.PSEdition -eq "Core"
    $here = Get-Module -ListAvailable -Name $moduleName | Sort-Object Version -Descending | Select-Object -First 1
    $hereName = if ($isCore) { "PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) - runs this app" } else { "Windows PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) - runs this app and the deployment steps" }
    $rows.Add([pscustomobject]@{
        Name    = $hereName
        Exe     = (Get-Process -Id $PID).Path
        Version = if ($here) { [string]$here.Version } else { "" }
        Problem = ""
    })
    # Only on Windows: elsewhere there is no Windows PowerShell to ask ($IsWindows
    # doesn't exist in 5.1, where this branch doesn't run anyway).
    if ($isCore -and $IsWindows) {
        # Imported for real, not just listed - a module that's only visible
        # there but can't load under .NET Framework would still fail every step.
        $answer = Invoke-HiddenPowerShell -Exe (Get-WindowsPowerShellPath) -TimeoutMs 60000 -Command "if (-not (Get-Module -ListAvailable -Name $moduleName)) { 'RESULT=missing' } else { try { Import-Module $moduleName -ErrorAction Stop; 'RESULT=ok ' + (Get-Module $moduleName).Version } catch { 'RESULT=error ' + `$_.Exception.Message } }"
        $row = [pscustomobject]@{ Name = "Windows PowerShell 5.1 - deployment steps"; Exe = (Get-WindowsPowerShellPath); Version = ""; Problem = "" }
        if ($answer -like "RESULT=ok *") { $row.Version = $answer.Substring(10) }
        elseif ($answer -like "RESULT=error *") { $row.Problem = "Installed, but won't load: " + $answer.Substring(13) }
        elseif ($answer -ne "RESULT=missing") { $row.Problem = "Couldn't check (Windows PowerShell didn't answer)" }
        $rows.Add($row)
    }
    # Plain output, one row per object - callers wrap it in @().
    return $rows.ToArray()
}

function Global:Get-GraphModuleInstallScript {
    # The installer for the Graph module, run in each PowerShell that's missing it (Settings > Prerequisites).
    $moduleName = Get-GraphModuleName
    return @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    if ($PSVersionTable.PSEdition -ne 'Core') {
        $nuget = Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue | Where-Object { $_.Version -ge [version]'2.8.5.201' }
        if (-not $nuget) {
            '[INFO] Installing the NuGet package provider for your user account...'
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
    }
    '[INFO] Downloading __MODULE__ from the PowerShell Gallery...'
    if ($env:INTUNEPACKAGER_TEST_MODULE_DIR) {
        # GUI tests only: same download, into a throwaway folder instead of
        # the user profile (that folder is on the test app's PSModulePath).
        Save-Module -Name __MODULE__ -Path $env:INTUNEPACKAGER_TEST_MODULE_DIR -Repository PSGallery -Force
        $env:PSModulePath = "$env:INTUNEPACKAGER_TEST_MODULE_DIR;$env:PSModulePath"
    }
    else {
        Install-Module -Name __MODULE__ -Scope CurrentUser -Repository PSGallery -Force -AllowClobber
    }
    $m = Get-Module -ListAvailable -Name __MODULE__ | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $m) { throw 'Install-Module finished, but the module still isn''t found.' }
    "[OK] __MODULE__ $($m.Version) installed ($($m.ModuleBase))"
    exit 0
}
catch {
    "[FAILED] $($_.Exception.Message)"
    exit 1
}
'@.Replace("__MODULE__", $moduleName)
}

