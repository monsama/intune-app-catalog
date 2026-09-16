# The one PowerShell module this app depends on - Microsoft.Graph.Authentication
# (Connect-MgGraph / Invoke-MgGraphRequest) - and the in-app way to install it,
# instead of a MessageBox telling the user to go run Install-Module by hand.
#
# Two places load it:
#   - the PowerShell running this GUI - every Graph lookup runs in a runspace
#   - Windows PowerShell 5.1 - Start-PipelineProcess always launches the
#     embedded deployment/assignment scripts with powershell.exe
# Installing into the GUI's own PowerShell covers both: every 5.1 child gets
# Get-WindowsPowerShellModulePath, which adds the folder this PowerShell loads
# the module from. The 5.1 side is still checked separately, by actually
# importing the module there the way a step would.

# This file's own path - Show-PrerequisitesDialog loads it into a background
# runspace to run the (slow) status check off the UI thread.
$Global:IntunePackagerPrerequisitesScript = $PSCommandPath

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
    # environment Start-PipelineProcess gives its steps, so the answer matches
    # what those steps will actually see. Returns the last line of output, or
    # $null on failure/timeout.
    param([string]$Exe, [string]$Command, [int]$TimeoutMs = 30000)
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("`$ProgressPreference = 'SilentlyContinue'; " + $Command))
        $psi.UseShellExecute = $false
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
    # Installed in the PowerShell running this window? A yes is remembered for
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
      "not installed"). Row 0 is always the PowerShell running this window -
      the one Install missing installs into.
      The Windows PowerShell row starts a separate powershell.exe and imports
      the module there - a few seconds; Show-PrerequisitesDialog runs this
      off the UI thread.
    #>
    $moduleName = Get-GraphModuleName
    $rows = New-Object System.Collections.Generic.List[object]
    $isCore = $PSVersionTable.PSEdition -eq "Core"
    $here = Get-Module -ListAvailable -Name $moduleName | Sort-Object Version -Descending | Select-Object -First 1
    $hereName = if ($isCore) { "PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) - this window" } else { "Windows PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) - this window and deployment steps" }
    $rows.Add([pscustomobject]@{
        Name    = $hereName
        Exe     = (Get-Process -Id $PID).Path
        Version = if ($here) { [string]$here.Version } else { "" }
        Problem = ""
    })
    if ($isCore) {
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

function Global:Test-GraphModuleAvailable {
    <#
      $true when the module is usable everywhere this app needs it.
      Otherwise opens Show-PrerequisitesDialog (unless -Quiet) so the user can
      install it right there, and returns whether it's available afterward.
      -CurrentHostOnly: only the PowerShell running this window matters (for
      callers that never reach a pipeline step, e.g. background fetches).
      -PromptOnce: don't offer the dialog again this session once the user
      closed it without installing (for code paths that run many steps in a
      row, like an audit - one offer, not one per app).
    #>
    param([switch]$Quiet, [switch]$CurrentHostOnly, [switch]$PromptOnce)
    $moduleName = Get-GraphModuleName
    if ($CurrentHostOnly) {
        if (Test-GraphModuleHere) { return $true }
    }
    else {
        if ($Global:App.GraphModuleConfirmed) { return $true }
        # Cheap check first: without the module here, the (slow) Windows
        # PowerShell check can't come out any better.
        if (Test-GraphModuleHere) {
            $missing = @(Get-GraphModuleStatus | Where-Object { -not $_.Version })
            if ($missing.Count -eq 0) { $Global:App.GraphModuleConfirmed = $true; return $true }
        }
    }
    if ($Quiet) { return $false }
    if ($PromptOnce -and $Global:App.GraphModulePromptDeclined) { return $false }
    $ok = [bool](Show-PrerequisitesDialog -Reason "This needs the $($moduleName) PowerShell module, which isn't installed yet.")
    if (-not $ok) { $Global:App.GraphModulePromptDeclined = $true }
    return $ok
}
function Global:Show-PrerequisitesDialog {
    <#
      Shows where the Graph module is / isn't installed and installs what's
      missing (current user, PowerShell Gallery), streaming the installer's
      output into the log box. Returns $true if everything is installed when
      the dialog closes.
    #>
    param([string]$Reason)
    $moduleName = Get-GraphModuleName

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Prerequisites"
    $dlg.ClientSize = New-Object System.Drawing.Size(640, 470)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(610,50)
    $lblIntro.Text = (@(
        $(if ($Reason) { $Reason })
        "Everything that talks to Intune or Entra ID uses Microsoft's $($moduleName) module, in each PowerShell listed below."
    ) | Where-Object { $_ }) -join " "
    $dlg.Controls.Add($lblIntro)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,68)
    $grid.Size = New-Object System.Drawing.Size(610,82)
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.RowHeadersVisible = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.ColumnHeadersDefaultCellStyle.WrapMode = [System.Windows.Forms.DataGridViewTriState]::False
    [void]$grid.Columns.Add("Where", "PowerShell")
    [void]$grid.Columns.Add("Status", "Microsoft.Graph.Authentication")
    $grid.Columns["Where"].FillWeight = 62
    $grid.Columns["Status"].FillWeight = 38
    $dlg.Controls.Add($grid)

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Location = New-Object System.Drawing.Point(15,158)
    $lblNote.Size = New-Object System.Drawing.Size(610,48)
    $lblNote.ForeColor = [System.Drawing.Color]::DimGray
    $lblNote.Text = "Install missing downloads it from the PowerShell Gallery into the PowerShell running this window, for your user account only - no admin rights needed, but internet access is. The deployment steps pick it up from there too."
    $dlg.Controls.Add($lblNote)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,212)
    $rtbLog.Size = New-Object System.Drawing.Size(610,200)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = "Install missing"
    $btnInstall.Location = New-Object System.Drawing.Point(15,424)
    $btnInstall.Size = New-Object System.Drawing.Size(150,32)
    $dlg.Controls.Add($btnInstall)

    $btnRecheck = New-Object System.Windows.Forms.Button
    $btnRecheck.Text = "Check again"
    $btnRecheck.Location = New-Object System.Drawing.Point(175,424)
    $btnRecheck.Size = New-Object System.Drawing.Size(120,32)
    $dlg.Controls.Add($btnRecheck)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(535,424)
    $btnClose.Size = New-Object System.Drawing.Size(90,32)
    $dlg.Controls.Add($btnClose)
    $dlg.CancelButton = $btnClose

    # Mutable state shared by the handlers below (see the closure notes
    # elsewhere in this app - containers, never reassigned variables).
    $state = @{ Rows = @(); Busy = $false; Checking = $false; AllInstalled = $false; AfterCheck = $null }
    $prereqScript = $Global:IntunePackagerPrerequisitesScript

    $ShowRows = {
        $grid.Rows.Clear()
        foreach ($r in $state.Rows) {
            $i = $grid.Rows.Add($r.Name, $(if ($r.Version) { "Installed ($($r.Version))" } elseif ($r.Problem) { $r.Problem } else { "Missing" }))
            if ($r.Problem) { $grid.Rows[$i].Cells["Status"].ToolTipText = $r.Problem }
            $grid.Rows[$i].Cells["Status"].Style.ForeColor = if ($r.Version) { [System.Drawing.Color]::SeaGreen } else { [System.Drawing.Color]::Firebrick }
        }
        $grid.ClearSelection()
        $missingCount = @($state.Rows | Where-Object { -not $_.Version }).Count
        $state.AllInstalled = ($missingCount -eq 0)
        if ($state.AllInstalled) { $Global:App.GraphModuleConfirmed = $true }
        # Installing only ever targets this window's own PowerShell (row 0) -
        # see the note at the top of this file.
        $btnInstall.Enabled = (-not $state.Busy) -and ($state.Rows.Count -gt 0) -and (-not $state.Rows[0].Version)
        $btnRecheck.Enabled = -not $state.Busy
    }.GetNewClosure()

    # Runs Get-GraphModuleStatus in a background runspace (it may start
    # Windows PowerShell and import the module - seconds), shows "Checking..."
    # meanwhile, then runs $state.AfterCheck, if set, once the rows are in.
    $Refresh = {
        if ($state.Checking) { return }
        $state.Checking = $true
        $btnInstall.Enabled = $false
        $btnRecheck.Enabled = $false
        $grid.Rows.Clear()
        [void]$grid.Rows.Add("Checking...", "")
        $grid.ClearSelection()

        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($ScriptPath)
            $Global:App = @{}
            . $ScriptPath
            Get-GraphModuleStatus
        }).AddArgument($prereqScript)
        $handle = $ps.BeginInvoke()

        # Fresh aliases - a closure nested in an already-closured handler only
        # reliably sees variables assigned in its immediately enclosing scope.
        $stateRef = $state
        $dlgRef = $dlg
        $showRowsRef = $ShowRows
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 300
        $timer.Add_Tick({
            if (-not $handle.IsCompleted) { return }
            $timer.Stop(); $timer.Dispose()
            try { $stateRef.Rows = @($ps.EndInvoke($handle)) }
            catch { $stateRef.Rows = @([pscustomobject]@{ Name = "Status check failed"; Exe = ""; Version = ""; Problem = $_.Exception.Message }) }
            finally { $ps.Dispose(); $rs.Close(); $rs.Dispose() }
            $stateRef.Checking = $false
            if ($dlgRef.IsDisposed) { return }
            & $showRowsRef
            if ($stateRef.AfterCheck) {
                $next = $stateRef.AfterCheck
                $stateRef.AfterCheck = $null
                & $next
            }
        }.GetNewClosure())
        $timer.Start()
    }.GetNewClosure()

    # The installer, run in each PowerShell that's missing the module. Output
    # goes to a log file this dialog polls, same approach as
    # Start-PipelineProcess (a hidden child's stdout can't be read from the
    # UI thread without blocking it).
    $installScript = @'
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

    $StartInstallBox = @{ Value = $null }
    $StartInstall = {
        param([object[]]$Queue, [int]$Index)
        if ($Index -ge $Queue.Count) {
            $state.Busy = $false
            $btnClose.Enabled = $true
            $doneStateRef = $state
            $doneLogRef = $rtbLog
            $doneModuleRef = $moduleName
            $state.AfterCheck = {
                if ($doneStateRef.AllInstalled) {
                    Write-DialogLogLine -LogBox $doneLogRef -Text "[OK] Everything's installed.`r`n" -MirrorToMainLog
                }
                else {
                    Write-DialogLogLine -LogBox $doneLogRef -Text "[WARN] Still missing somewhere - see the messages above. You can also run, in that PowerShell: Install-Module $doneModuleRef -Scope CurrentUser`r`n" -MirrorToMainLog
                }
            }.GetNewClosure()
            & $Refresh
            return
        }
        $target = $Queue[$Index]
        Write-DialogLogLine -LogBox $rtbLog -Text "[INFO] $($target.Name):`r`n" -MirrorToMainLog

        $tag = [guid]::NewGuid().ToString("N")
        $scriptPath = Join-Path $env:TEMP ".intunepkg_prereq_$tag.ps1"
        $logPath = Join-Path $env:TEMP ".intunepkg_prereq_$tag.log"
        [System.IO.File]::WriteAllText($scriptPath, $installScript, (New-Object System.Text.UTF8Encoding($false)))
        [System.IO.File]::WriteAllText($logPath, "")
        $escScript = $scriptPath -replace "'", "''"
        $escLog = $logPath -replace "'", "''"
        $inner = "& '$escScript' *>&1 | ForEach-Object { Add-Content -LiteralPath '$escLog' -Value `$_ -Encoding UTF8 }; exit `$LASTEXITCODE"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $target.Exe
        $psi.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inner))
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        # Everything worth showing goes to the log file; the raw streams are
        # captured and dropped so they don't land in this app's own output.
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        Set-WindowsPowerShellEnvironment -StartInfo $psi
        try {
            $proc = [System.Diagnostics.Process]::Start($psi)
            [void]$proc.StandardOutput.ReadToEndAsync()
            [void]$proc.StandardError.ReadToEndAsync()
        }
        catch {
            Write-DialogLogLine -LogBox $rtbLog -Text "[FAILED] Could not start $($target.Exe): $($_.Exception.Message)`r`n" -MirrorToMainLog
            & $StartInstallBox.Value -Queue $Queue -Index ($Index + 1)
            return
        }

        $readPos = @{ Value = 0L }
        $logBoxRef = $rtbLog
        $ReadNew = {
            try {
                $fs = [System.IO.File]::Open($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                [void]$fs.Seek($readPos.Value, [System.IO.SeekOrigin]::Begin)
                $sr = New-Object System.IO.StreamReader($fs)
                $text = $sr.ReadToEnd()
                $readPos.Value = $fs.Position
                $sr.Close(); $fs.Close()
                foreach ($line in ($text -split "`r?`n" | Where-Object { $_.Trim() })) {
                    $shown = if ($line -match '^\s*\[(OK|FAILED|WARN|INFO)\]') { $line } else { "    $line" }
                    Write-DialogLogLine -LogBox $logBoxRef -Text "$shown`r`n" -MirrorToMainLog
                }
            } catch { }
        }.GetNewClosure()

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 400
        $queueRef = $Queue; $indexRef = $Index; $startBoxRef = $StartInstallBox
        $timer.Add_Tick({
            & $ReadNew
            if ($proc.HasExited) {
                $timer.Stop(); $timer.Dispose()
                Start-Sleep -Milliseconds 300
                & $ReadNew
                if ($proc.ExitCode -ne 0) {
                    Write-DialogLogLine -LogBox $logBoxRef -Text "[FAILED] Installer exited with code $($proc.ExitCode).`r`n" -MirrorToMainLog
                }
                Remove-Item -LiteralPath $scriptPath, $logPath -Force -ErrorAction SilentlyContinue
                & $startBoxRef.Value -Queue $queueRef -Index ($indexRef + 1)
            }
        }.GetNewClosure())
        $timer.Start()
    }.GetNewClosure()
    $StartInstallBox.Value = $StartInstall

    $btnInstall.Add_Click({
        $queue = @($state.Rows[0] | Where-Object { -not $_.Version })
        if ($queue.Count -eq 0) { return }
        $state.Busy = $true
        $btnInstall.Enabled = $false
        $btnRecheck.Enabled = $false
        # An installer can't be cancelled halfway cleanly - keep the dialog
        # open until every run has finished.
        $btnClose.Enabled = $false
        & $StartInstallBox.Value -Queue $queue -Index 0
    }.GetNewClosure())

    $btnRecheck.Add_Click({ & $Refresh }.GetNewClosure())
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.Add_FormClosing({
        param($s, $e)
        if ($state.Busy) { $e.Cancel = $true }
    }.GetNewClosure())

    $dlg.Add_Shown({
        $shownStateRef = $state
        $shownLogRef = $rtbLog
        $shownModuleRef = $moduleName
        $state.AfterCheck = {
            if ($shownStateRef.AllInstalled) {
                Write-DialogLogLine -LogBox $shownLogRef -Text "[OK] $shownModuleRef is installed everywhere this app needs it.`r`n"
            }
            else {
                $first = if ($shownStateRef.Rows.Count) { $shownStateRef.Rows[0] } else { $null }
                $hint = if ($first -and -not $first.Version) { " - click `"Install missing`"." } else { " - see the status above." }
                Write-DialogLogLine -LogBox $shownLogRef -Text "[WARN] Not usable everywhere yet$hint`r`n"
            }
        }.GetNewClosure()
        & $Refresh
    }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
    return [bool]$state.AllInstalled
}
