function Global:Write-Log {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::Gainsboro)
    if ($Global:App.LogBox.InvokeRequired) {
        $Global:App.LogBox.Invoke([Action]{ Write-Log -Text $Text -Color $Color })
        return
    }
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

function Global:Set-PipelineButtonsEnabled {
    param([bool]$Enabled)
    $Global:App.BtnRunLaunch.Enabled = $Enabled
    $Global:App.Progress.Visible = -not $Enabled
}

function Global:Ensure-Folders {
    $folders = @("app-packages","app-data","logs","backups")
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
            $logPath = Join-Path (Join-Path $Global:App.RootPath "logs") ("intune-deployment-" + (Get-Date -Format "yyyy-MM-dd") + ".log")
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
            # alias once here since Ensure-Folders only ever opens this
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
        $errText = "[ERROR] Could not write temp script: $($_.Exception.Message)`r`n"
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

    $escapedScript = $tempScriptPath -replace "'", "''"
    # Add-Content (not Tee-Object) deliberately - Tee-Object keeps an internal
    # buffered writer open for the whole pipeline and doesn't reliably flush to
    # disk as output is produced, only in unpredictable bursts. That left our
    # polling reader seeing wildly incomplete output on some runs. Add-Content
    # opens, writes, and fully closes the file handle on every single call, so
    # each line is guaranteed to be on disk (and visible to our reader) the
    # moment it's written, at the cost of only-trivial per-line overhead.
    #
    # Wrapped in a short retry loop - the reader side (below) explicitly opens
    # with FileShare.ReadWrite specifically to avoid locking out the writer,
    # but that only controls how OUR reader behaves; Add-Content's own
    # internal file handle isn't something this app can configure directly,
    # and it can occasionally land in the same instant the reader has the
    # file open, throwing "being used by another process." That's expected
    # to be rare and momentary (the other side always closes its handle
    # quickly), so a few short retries resolve it silently instead of
    # dropping that line of output and surfacing a visible error for what's
    # really just a timing collision, not a real failure.
    $innerCommand = "& '$escapedScript' $ArgumentString *>&1 | ForEach-Object { `$line = `$_; `$ok = `$false; for (`$i = 0; `$i -lt 5 -and -not `$ok; `$i++) { try { Add-Content -LiteralPath '$logFile' -Value `$line -Encoding UTF8 -ErrorAction Stop; `$ok = `$true } catch { Start-Sleep -Milliseconds 150 } } }"
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($innerCommand))

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $psi.UseShellExecute = $false
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
    # the embedded package script's default ".\IntuneWinAppUtil.exe").
    $psi.WorkingDirectory = $Global:App.RootPath

    Set-PipelineButtonsEnabled $false

    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    }
    catch {
        $errText = "[ERROR] Could not start process: $($_.Exception.Message)`r`n"
        Write-Log $errText ([System.Drawing.Color]::Tomato)
        if ($ExtraLogTarget) { $ExtraLogTarget.AppendText($errText) }
        Remove-Item $tempScriptPath -Force -ErrorAction SilentlyContinue
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
            $finishedText = if ($code -eq 0) { "`r`n[Finished - exit code 0]`r`n`r`n" } else { "`r`n[Finished - exit code $code]`r`n`r`n" }
            Write-Log $finishedText ([System.Drawing.Color]::LightGreen)
            # Mirror into the caller's own inline log too - otherwise every
            # -ExtraLogTarget dialog (Packaging, Deploy, Sync, Batch Assign,
            # Create in Intune) ends its local log right at the embedded
            # script's own last output line, with no visible confirmation
            # the run actually finished.
            if ($ExtraLogTarget) {
                $ExtraLogTarget.AppendText($finishedText)
                $ExtraLogTarget.SelectionStart = $ExtraLogTarget.TextLength
                $ExtraLogTarget.ScrollToCaret()
            }
            Remove-Item $logFile -Force -ErrorAction SilentlyContinue
            Remove-Item $tempScriptPath -Force -ErrorAction SilentlyContinue
            Set-PipelineButtonsEnabled $true
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
    Ensure-Folders
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
    $argStr = "-InputFolder '$(Join-Path $rootPath 'app-packages')' -Force"
    # Single quotes doubled (PowerShell's own escaping for a literal ' inside
    # a single-quoted string) - same idiom already used throughout this file
    # for OData filter values (see e.g. Resolve-GroupId's $GroupName.Replace("'",
    # "''")). $SingleFolderName/$FolderNames come from Get-SafeFileNameForApp,
    # which strips Windows-illegal filename characters but NOT a single quote
    # (a perfectly legal filename character) - left unescaped, an app display
    # name containing one would break out of the quoted -SingleFolderName/
    # -FolderNames value here and inject arbitrary PowerShell into $argStr,
    # which Start-PipelineProcess runs via `powershell.exe -EncodedCommand`.
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
