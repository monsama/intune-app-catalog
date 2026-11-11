function Global:Write-Log {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Gainsboro)
    if ($Global:App.LogBox.InvokeRequired) {
        $Global:App.LogBox.Invoke([Action]{ Write-Log -Text $Text -Color $Color })
        return
    }
    # Some callers build multi-line text (e.g. joining several PowerShell
    # error records) with a bare `n, which a RichTextBox's native edit
    # control won't render as a line break - see ConvertTo-DisplayLineEndings
    # (GuiHelpers.ps1) for the full story. Normalizing once here, right
    # before AppendText, covers every caller instead of needing each one
    # to remember to do it themselves.
    $Text = ConvertTo-DisplayLineEndings $Text
    $Global:App.LogBox.SelectionStart = $Global:App.LogBox.TextLength
    $Global:App.LogBox.SelectionLength = 0
    $Global:App.LogBox.SelectionColor = $Color
    $Global:App.LogBox.AppendText($Text)
    $Global:App.LogBox.ScrollToCaret()

    if ($Global:App.LogFileWriter) {
        try {
            $stamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
            $Global:App.LogFileWriter.Write("[$stamp] $Text")
        }
        catch { }
    }
}

function Global:Get-LogTabText {
    # The Log tab's text with Windows line endings (a RichTextBox's Text uses bare `n) - $null when it's empty
    $text = [string]$Global:App.LogBox.Text
    if (-not $text.Trim()) { return $null }
    return ($text -replace "\r?\n", "`r`n")
}

function Global:Set-PipelineButtonsEnabled {
    param([bool]$Enabled)
    $Global:App.BtnRunLaunch.Enabled = $Enabled
    $Global:App.Progress.Visible = -not $Enabled
}

function Global:Initialize-Folders {
    $folders = @("data\app-packages","data\app-data","data\logs","data\backups")
    foreach ($f in $folders) {
        $p = Join-Path $Global:App.RootPath $f
        if (-not (Test-Path $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            Write-Log "[+] Created folder: $f`r`n" ([System.Drawing.Color]::LightGreen)
        }
    }

    # Persistent, timestamped record of everything this app does -
    # separate from the in-app Log tab, which is lost the moment the
    # window closes. Worth having given this tool performs real
    # destructive, audit-relevant actions (deleting apps, changing group
    # membership, granting certificate trust).
    if (-not $Global:App.LogFileWriter) {
        try {
            $logPath = Join-Path (Get-AppFolder -Kind Logs -Create) ("intune-deployment-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
            $Global:App.LogFileWriter = New-Object System.IO.StreamWriter($logPath, $true, [System.Text.Encoding]::UTF8)
            # Flushed periodically (below) rather than on every single
            # Write-Log call - AutoFlush forces a synchronous disk write on
            # every call, which runs on the UI thread and could cause
            # noticeable lag during high-volume logging (a busy batch
            # operation streaming a lot of child-process output). A
            # 2-second periodic flush keeps worst-case data loss on a
            # crash small (a couple of seconds of log lines) without
            # paying that cost on every single line.
            $Global:App.LogFileWriter.AutoFlush = $false

            # Plain local alias, referenced by the timer handler instead of
            # $Global:App.LogFileWriter directly - even code inside a function
            # (not just nested dialog closures) doesn't reliably see
            # $Script:-qualified variables from within an event handler
            # scriptblock; see the note in Start-IntuneAppLookup. Safe to
            # alias once here since Initialize-Folders only ever opens this
            # writer once per app session (guarded by the outer "if (-not
            # $Global:App.LogFileWriter)" check above), so this reference never
            # goes stale during the run.
            $logWriterRef = $Global:App.LogFileWriter

            $Global:App.LogFlushTimer = New-Object System.Windows.Forms.Timer
            $Global:App.LogFlushTimer.Interval = 2000
            $Global:App.LogFlushTimer.Add_Tick({
                try { $logWriterRef.Flush() } catch { }
            }.GetNewClosure())
            $Global:App.LogFlushTimer.Start()
        }
        catch {
            # A file-logging failure shouldn't take down the app itself -
            # the in-app Log tab still works fine either way.
            $Global:App.LogFileWriter = $null
        }
    }
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

function Global:Start-PipelineProcess {
    param(
        [string]$ScriptContent,
        [string]$TempScriptName,
        [string]$ArgumentString,
        [scriptblock]$OnComplete,
        # Optional - lets a caller (like Show-CreateInIntuneDialog, which is
        # modal and blocks the main window entirely) show live output locally
        # instead of only in the Pipeline tab's log, which the user can't
        # reach while a modal dialog is open.
        [System.Windows.Forms.RichTextBox]$ExtraLogTarget = $null,
        # Only needed for interactive Entra ID sign-in (certificate
        # upload/check). WAM (Windows' broker for interactive auth) needs an
        # actual parent window handle to attach its sign-in prompt to, and
        # fails outright ("A window handle must be configured") from a
        # hidden/windowless process - confirmed as a genuine WAM
        # requirement across multiple independent reports, including
        # Microsoft's own docs, which state Set-MgGraphOption
        # -DisableLoginByWAM has no effect in current module versions. A
        # normal, visible console window is the one fix confirmed to
        # actually work, so this is opt-in rather than default - every
        # other embedded script here uses app-only certificate auth and has
        # no reason to ever show a window.
        [switch]$ShowConsoleWindow
    )

    # Steps that talk to Graph fail deep inside a hidden process without the
    # module - check first (and offer to install it, once per session)
    # instead. These run under Windows PowerShell 5.1, so both PowerShells
    # are checked.
    if ($ScriptContent -match 'Import-Module\s+Microsoft\.Graph\.Authentication' -and -not (Test-GraphModuleAvailable -PromptOnce)) {
        $errText = "[FAILED] Not started - the Microsoft.Graph.Authentication module isn't available (More actions > Verify > Prerequisites... installs it).`r`n"
        Write-Log $errText ([System.Drawing.Color]::Tomato)
        if ($ExtraLogTarget) { $ExtraLogTarget.AppendText($errText) }
        if ($OnComplete) { & $OnComplete -1 }
        return
    }

    # The temp file has to live inside $Global:App.RootPath (not $env:TEMP), because
    # both embedded scripts use $PSScriptRoot internally to find input.json /
    # IntuneWinAppUtil.exe - see the note above $Global:App.EmbeddedPackageScript.
    $tempScriptPath = Join-Path $Global:App.RootPath $TempScriptName
    try {
        # No BOM, matching how the catalog file itself is written.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempScriptPath, $ScriptContent, $utf8NoBom)
    }
    catch {
        $errText = "[FAILED] Could not write temp script: $($_.Exception.Message)`r`n"
        Write-Log $errText ([System.Drawing.Color]::Tomato)
        if ($ExtraLogTarget) { $ExtraLogTarget.AppendText($errText) }
        Set-PipelineButtonsEnabled $true
        # Still notify the caller even though the process never started -
        # otherwise anything gating on -OnComplete (like Show-PackagingProgressDialog's
        # Close button) would stay stuck forever on this early-failure path.
        if ($OnComplete) { & $OnComplete -1 }
        return
    }

    $logFile = Join-Path $env:TEMP ("intunepkg_" + [guid]::NewGuid().ToString("N") + ".log")
    New-Item -Path $logFile -ItemType File -Force | Out-Null


    # Graph request logging (GraphLog.ps1): steps that talk to Graph get the
    # helper functions dot-sourced first, and print the pending read summary
    # when they end. Their exit code is passed through unchanged (every
    # embedded Graph script ends with an explicit exit 0/1).
    # The assignment logic (Assignments.ps1) rides along in the same file:
    # the scripts that push an app's groups need exactly the answer the
    # GUI's own preview and the audit use, and a second copy inside each
    # script would be a copy to keep in sync.
    $usesGraph = $ScriptContent -match 'Import-Module\s+Microsoft\.Graph\.Authentication'
    $graphHelperPath = $null
    if ($usesGraph) {
        # Next to the step script in the app's folder, not %TEMP%: code that
        # runs from %TEMP% is another thing endpoint protection flags.
        $graphHelperPath = Join-Path $Global:App.RootPath (".intunepkg_graphlog_" + [guid]::NewGuid().ToString("N") + ".ps1")
        try {
            $helperText = (Get-GraphLogScriptHelpers) + "`n`n" + (Get-AssignmentScriptHelpers)
            [System.IO.File]::WriteAllText($graphHelperPath, $helperText, (New-Object System.Text.UTF8Encoding($false)))
        }
        catch { $graphHelperPath = $null }
    }
    # The runner appends each output line to $logFile as it's produced
    # (Add-Content with a short retry - see code\Runner\Invoke-AppStep.ps1),
    # and the timer below reads it back while the step runs.
    try {
        $psi = New-AppStepStartInfo -Spec @{
            Script      = $tempScriptPath
            Arguments   = $ArgumentString
            GraphHelper = $(if ($graphHelperPath) { $graphHelperPath } else { '' })
            LogFile     = $logFile
        }
    }
    catch {
        $errText = "[FAILED] Could not prepare the step: $($_.Exception.Message)`r`n"
        Write-Log $errText ([System.Drawing.Color]::Tomato)
        if ($ExtraLogTarget) { $ExtraLogTarget.AppendText($errText) }
        Remove-Item -LiteralPath $tempScriptPath -Force -ErrorAction SilentlyContinue
        if ($graphHelperPath) { Remove-Item -LiteralPath $graphHelperPath -Force -ErrorAction SilentlyContinue }
        if ($OnComplete) { & $OnComplete -1 }
        return
    }
    # Windows PowerShell's own module path (plus wherever this window loads
    # the Graph module from), not whatever this process happens to have -
    # see Get-WindowsPowerShellModulePath.
    Set-WindowsPowerShellEnvironment -StartInfo $psi
    $psi.EnvironmentVariables["INTUNEPACKAGER_GRAPH_LOG"] = $(if ($Global:App.DetailedGraphLog) { "detailed" } else { "summary" })
    $psi.CreateNoWindow = -not $ShowConsoleWindow
    if ($ShowConsoleWindow) {
        # Minimized rather than Normal - WAM (Windows' interactive sign-in
        # broker) needs SOME window handle to exist to attach its prompt to,
        # confirmed as a genuine requirement directly from Microsoft's own
        # MSAL docs ("trying to infer a window is not feasible"). What isn't
        # confirmed anywhere is that the window has to be VISIBLE rather
        # than just existing - a minimized window still has a valid handle,
        # it's just collapsed to the taskbar instead of sitting on screen as
        # a distracting black console. This is a reasonable, low-risk
        # experiment based on how window handles generally work, not a
        # documented guarantee - if sign-in starts failing with "A window
        # handle must be configured" again, this line is exactly what to
        # revert (back to the default Normal style).
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Minimized
    }
    # Without this, the child process inherits whatever folder the GUI itself happened
    # to be launched from - breaking relative paths inside the target script (e.g.
    # the embedded package script's default ".\tools\IntuneWinAppUtil.exe").
    $psi.WorkingDirectory = $Global:App.RootPath

    Set-PipelineButtonsEnabled $false

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        $errText = "[FAILED] Could not start process: $($_.Exception.Message)`r`n"
        Write-Log $errText ([System.Drawing.Color]::Tomato)
        if ($ExtraLogTarget) { $ExtraLogTarget.AppendText($errText) }
        Remove-Item $tempScriptPath -Force -ErrorAction SilentlyContinue
            if ($graphHelperPath) { Remove-Item -LiteralPath $graphHelperPath -Force -ErrorAction SilentlyContinue }
        Set-PipelineButtonsEnabled $true
        # See the note on the "Could not write temp script" catch block above.
        if ($OnComplete) { & $OnComplete -1 }
        return
    }

    $readPos = [ref]0L
    $ReadNewLogContent = {
        if (-not (Test-Path $logFile)) { return }
        try {
            $stream = [System.IO.File]::Open($logFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $stream.Seek($readPos.Value, [System.IO.SeekOrigin]::Begin) | Out-Null
            $reader = New-Object System.IO.StreamReader($stream)
            $newText = $reader.ReadToEnd()
            $readPos.Value = $stream.Position
            $reader.Close(); $stream.Close()
            if ($newText) {
                Write-Log $newText
                if ($ExtraLogTarget) {
                    $ExtraLogTarget.AppendText($newText)
                    $ExtraLogTarget.SelectionStart = $ExtraLogTarget.TextLength
                    $ExtraLogTarget.ScrollToCaret()
                }
            }
        } catch { }
    }.GetNewClosure()

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({
        & $ReadNewLogContent
        if ($proc.HasExited) {
            $timer.Stop()
            $timer.Dispose()
            # The process reporting HasExited doesn't guarantee every last buffered
            # write has landed on disk yet - give it a brief moment, then do one more
            # read so a burst of output right at exit isn't silently dropped.
            Start-Sleep -Milliseconds 300
            & $ReadNewLogContent

            $code = $proc.ExitCode
            # Everything between here and -OnComplete is cosmetic: writing
            # the ending into two log boxes and deleting three temp files.
            # None of it is allowed to decide whether the caller is told
            # the process finished. Un-guarded, a throw from any of it (a
            # log box belonging to a dialog that has since been closed is
            # the one already seen in the wild) is swallowed by WinForms'
            # event dispatch and takes the -OnComplete call down with it -
            # leaving the caller waiting on a process that exited minutes
            # ago, with no error anywhere to say so.
            try {
                $finishedText = if ($code -eq 0) { "`r`n[Finished - exit code 0]`r`n`r`n" } else { "`r`n[Finished - exit code $code]`r`n`r`n" }
                Write-Log $finishedText ([System.Drawing.Color]::LightGreen)
                # Mirror into the caller's own inline log too - otherwise every
                # -ExtraLogTarget dialog (Packaging, Deploy, Sync, Batch Assign,
                # Create in Intune) ends its local log right at the embedded
                # script's own last output line, with no visible confirmation
                # the run actually finished.
                if ($ExtraLogTarget -and -not $ExtraLogTarget.IsDisposed) {
                    $ExtraLogTarget.AppendText($finishedText)
                    $ExtraLogTarget.SelectionStart = $ExtraLogTarget.TextLength
                    $ExtraLogTarget.ScrollToCaret()
                }
            } catch { }
            try {
                Remove-Item $logFile -Force -ErrorAction SilentlyContinue
                Remove-Item $tempScriptPath -Force -ErrorAction SilentlyContinue
                if ($graphHelperPath) { Remove-Item -LiteralPath $graphHelperPath -Force -ErrorAction SilentlyContinue }
                Set-PipelineButtonsEnabled $true
            } catch { }
            if ($OnComplete) { & $OnComplete $code }
        }
    }.GetNewClosure())
    $timer.Start()
    return $proc
}

function Global:Invoke-LaunchStep {
    param(
        [scriptblock]$OnComplete,
        [string]$SingleFolderName = "",
        [string[]]$FolderNames = @(),
        # Optional - see the note on Start-PipelineProcess's own -ExtraLogTarget
        # param for why this exists.
        [System.Windows.Forms.RichTextBox]$ExtraLogTarget = $null
    )
    Initialize-Folders
    $rootPath = $Global:App.RootPath   # plain local alias - see note in Start-IntuneAppLookup
    if ($SingleFolderName) {
        Write-Log "=== Package single app: $SingleFolderName ===`r`n" ([System.Drawing.Color]::DeepSkyBlue)
    }
    elseif ($FolderNames.Count -gt 0) {
        Write-Log "=== Package selected apps ($($FolderNames.Count)) ===`r`n" ([System.Drawing.Color]::DeepSkyBlue)
    }
    else {
        Write-Log "=== Package all apps (app-packages) ===`r`n" ([System.Drawing.Color]::DeepSkyBlue)
    }
    $argStr = "-InputFolder '$((Join-Path $rootPath 'data\app-packages') -replace "'", "''")' -Force"
    # Single quotes doubled (PowerShell's own escaping for a literal ' inside
    # a single-quoted string) - same idiom already used throughout this file
    # for OData filter values (see e.g. Resolve-GroupId's $GroupName.Replace("'",
    # "''")). $SingleFolderName/$FolderNames come from Get-SafeFileNameForApp,
    # which strips Windows-illegal filename characters but NOT a single quote
    # (a perfectly legal filename character) - left unescaped, an app display
    # name containing one would break out of the quoted -SingleFolderName/
    # -FolderNames value here and inject arbitrary PowerShell into $argStr,
    # which the step runner (code\Runner\Invoke-AppStep.ps1) parses as PowerShell.
    # Since a display name can come from Intune itself (synced in by anyone
    # with rights to create/rename an app there, not just this tool's own
    # user), this was a real code-execution path, not just a theoretical one.
    if ($SingleFolderName) {
        $argStr += " -SingleFolderName '$($SingleFolderName -replace "'", "''")'"
    }
    elseif ($FolderNames.Count -gt 0) {
        $safeFolderNames = @($FolderNames | ForEach-Object { $_ -replace "'", "''" })
        $argStr += " -FolderNames '$($safeFolderNames -join ',')'"
    }
    Start-PipelineProcess -ScriptContent $Global:App.EmbeddedPackageScript -TempScriptName ".intunepkg_embedded_launch.ps1" -ArgumentString $argStr -OnComplete $OnComplete -ExtraLogTarget $ExtraLogTarget
}
