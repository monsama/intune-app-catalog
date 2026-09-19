function Global:Show-WingetHealthCheckDialog {
    <#
      Does every Winget ID in the catalog still exist?

      Winget package IDs get renamed or dropped upstream. Nothing breaks
      for devices that already have the app - the installed copy stays,
      and Winget-AutoUpdate keeps it current - but every NEW device fails
      to install it, and that only shows up as install failures later.
      This asks winget about each ID and lists the ones it no longer
      knows.

      Versions deliberately aren't compared: the deployed install command
      takes whatever Winget ships at install time, and the generated
      detection rule matches on the package ID rather than a version, so
      "a newer version exists upstream" means nothing here.
    #>
    # -HostTabPage: become one tab of Show-ChecksDialog instead of a window
    # of its own - see Move-DialogToTabPage.
    param([System.Windows.Forms.TabPage]$HostTabPage, [System.Windows.Forms.Form]$HostForm)

    $appsWithWingetId = @($Global:App.Apps | Where-Object { $_.wingetId })
    if ($appsWithWingetId.Count -eq 0) {
        # Embedded, say it on the tab instead of in a popup over a window
        # the user opened for the other checks.
        if ($HostTabPage) {
            $lblNothing = New-Object System.Windows.Forms.Label
            $lblNothing.Text = "No app in this catalog has a Winget ID, so there is nothing for winget to check."
            $lblNothing.Location = New-Object System.Drawing.Point(15,15)
            $lblNothing.Size = New-Object System.Drawing.Size(700,40)
            $lblNothing.ForeColor = [System.Drawing.Color]::DimGray
            $HostTabPage.Controls.Add($lblNothing)
            return
        }
        [System.Windows.Forms.MessageBox]::Show("No app in this catalog has a Winget ID, so there's nothing to check.", "Nothing to check", "OK", "Information") | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    # Which window this check's controls actually live in - this dialog
    # standalone, or the host it was moved into as a tab. The poll timer
    # below stops when that window is gone, and embedded it is the HOST
    # that gets closed and disposes these controls: checking $dlg there
    # would keep the timer writing into a dead grid. A box, not a plain
    # variable, so the hosted branch at the bottom can repoint it after
    # the closures below have already captured it.
    $liveFormBox = @{ Form = $dlg }
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Winget package check"
    $dlg.ClientSize = New-Object System.Drawing.Size(760, 520)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Asks winget on THIS machine whether each catalog app's Winget ID still exists. An ID that no longer resolves keeps working on devices that already have the app, but fails to install on every new one. Read-only - nothing is installed, and Intune isn't contacted."
    $lblIntro.Location = New-Object System.Drawing.Point(15, 12)
    $lblIntro.Size = New-Object System.Drawing.Size(730, 48)
    $dlg.Controls.Add($lblIntro)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15, 66)
    $lblStatus.Size = New-Object System.Drawing.Size(560, 20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $lblStatus.Text = "Checking $($appsWithWingetId.Count) app(s)..."
    $dlg.Controls.Add($lblStatus)

    $btnRecheck = New-Object System.Windows.Forms.Button
    $btnRecheck.Text = "Check again"
    $btnRecheck.Location = New-Object System.Drawing.Point(615, 62)
    $btnRecheck.Size = New-Object System.Drawing.Size(130, 26)
    $btnRecheck.Enabled = $false
    $dlg.Controls.Add($btnRecheck)

    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(15, 90)
    $progress.Size = New-Object System.Drawing.Size(730, 8)
    $progress.Minimum = 0
    $progress.Maximum = [Math]::Max(1, $appsWithWingetId.Count)
    $dlg.Controls.Add($progress)

    $grid = New-Object System.Windows.Forms.DataGridView
    Set-AppGridStyle -Grid $grid
    $grid.Location = New-Object System.Drawing.Point(15, 108)
    $grid.Size = New-Object System.Drawing.Size(730, 340)
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.ReadOnly = $true
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false
    $grid.AutoGenerateColumns = $false
    $grid.BackgroundColor = [System.Drawing.SystemColors]::Window
    foreach ($col in @(
        @{ Name = "AppName";  Header = "App"; Weight = 30 }
        @{ Name = "WingetId"; Header = "Winget ID"; Weight = 30 }
        @{ Name = "Result";   Header = "Result"; Weight = 40 }
    )) {
        $gridCol = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $gridCol.Name = $col.Name
        $gridCol.HeaderText = $col.Header
        $gridCol.FillWeight = $col.Weight
        $gridCol.ReadOnly = $true
        [void]$grid.Columns.Add($gridCol)
    }
    $dlg.Controls.Add($grid)

    $btnCopy = New-Object System.Windows.Forms.Button
    $btnCopy.Text = "Copy list"
    $btnCopy.Location = New-Object System.Drawing.Point(15, 460)
    $btnCopy.Size = New-Object System.Drawing.Size(120, 30)
    $dlg.Controls.Add($btnCopy)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(660, 460)
    $btnClose.Size = New-Object System.Drawing.Size(85, 30)
    $dlg.Controls.Add($btnClose)

    $stateBox = @{ Running = $false; Cancelled = $false }

    $runCheck = {
        if ($stateBox.Running) { return }
        $stateBox.Running = $true
        $stateBox.Cancelled = $false
        $btnRecheck.Enabled = $false
        $grid.Rows.Clear()
        $progress.Value = 0
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
        $lblStatus.Text = "Checking $($appsWithWingetId.Count) app(s)..."

        # One runspace for the whole list rather than one per app: winget is
        # a process launch each time, and a handful of them in parallel just
        # fights over the same source cache.
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        [void]$ps.AddScript({
            param($Apps)
            $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
            if (-not $wingetCmd) {
                throw "winget.exe isn't on this machine. It ships with the 'App Installer' package on Windows 10/11 - install that first."
            }
            foreach ($app in $Apps) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $wingetCmd.Source
                $psi.Arguments = "show --id `"$($app.WingetId)`" --exact --accept-source-agreements --disable-interactivity"
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
                $proc = New-Object System.Diagnostics.Process
                $proc.StartInfo = $psi
                [void]$proc.Start()
                # Both streams read before waiting - see the same note in
                # Start-WingetSearch for why the other order deadlocks.
                $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
                $stderrTask = $proc.StandardError.ReadToEndAsync()
                if (-not $proc.WaitForExit(30000)) {
                    try { $proc.Kill() } catch { }
                    Write-Output ([pscustomobject]@{ AppName = $app.AppName; WingetId = $app.WingetId; Ok = $false; Result = "winget didn't answer within 30 seconds" })
                    continue
                }
                $stdout = $stdoutTask.GetAwaiter().GetResult()
                $stderr = $stderrTask.GetAwaiter().GetResult()
                $found = ($proc.ExitCode -eq 0) -and ($stdout -match '(?m)^\s*Version:')
                $result = if ($found) {
                    $publisher = if ($stdout -match '(?m)^\s*Publisher:\s*(.+)$') { $Matches[1].Trim() } else { "" }
                    if ($publisher) { "Found ($publisher)" } else { "Found" }
                }
                elseif ($stdout -match 'No package found' -or $stderr -match 'No package found') {
                    "NOT FOUND - winget doesn't know this ID any more"
                }
                else {
                    $firstLine = (@(($stdout + "`n" + $stderr) -split "`r?`n" | Where-Object { $_.Trim() }) | Select-Object -First 1)
                    "Could not check (exit code $($proc.ExitCode)): $firstLine"
                }
                Write-Output ([pscustomobject]@{ AppName = $app.AppName; WingetId = $app.WingetId; Ok = $found; Result = $result })
            }
        }).AddArgument(@($appsWithWingetId | ForEach-Object { [pscustomobject]@{ AppName = [string]$_.appName; WingetId = [string]$_.wingetId } }))

        # Results land in this collection as the runspace writes them, so a
        # 50-app catalog fills the grid as it goes instead of after minutes
        # of nothing.
        $outputCollection = New-Object System.Management.Automation.PSDataCollection[psobject]
        $handle = $ps.BeginInvoke([System.Management.Automation.PSDataCollection[psobject]]::new(), $outputCollection)

        # Fresh aliases for the timer's closure - see the note at the top of
        # Show-CreateInIntuneDialog.
        $liveFormBoxRef = $liveFormBox
        $gridRef = $grid
        $lblStatusRef = $lblStatus
        $progressRef = $progress
        $btnRecheckRef = $btnRecheck
        $stateBoxRef = $stateBox
        $psRef = $ps
        $rsRef = $rs
        $handleRef = $handle
        $outputRef = $outputCollection
        $totalRef = $appsWithWingetId.Count
        $takenBox = @{ Count = 0 }

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 400
        $timer.Add_Tick({
            $closed = $liveFormBoxRef.Form.IsDisposed
            if (-not $closed) {
                while ($takenBox.Count -lt $outputRef.Count) {
                    $item = $outputRef[$takenBox.Count]
                    $takenBox.Count++
                    $index = $gridRef.Rows.Add([string]$item.AppName, [string]$item.WingetId, [string]$item.Result)
                    if (-not $item.Ok) { $gridRef.Rows[$index].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Firebrick }
                    $gridRef.Rows[$index].Cells[2].ToolTipText = [string]$item.Result
                    $progressRef.Value = [Math]::Min($progressRef.Maximum, $takenBox.Count)
                    $lblStatusRef.Text = "Checked $($takenBox.Count) of $totalRef..."
                }
                $gridRef.ClearSelection()
                $gridRef.CurrentCell = $null
            }
            if (-not $handleRef.IsCompleted) { return }
            $timer.Stop()
            $timer.Dispose()
            try {
                [void]$psRef.EndInvoke($handleRef)
                if (-not $closed) {
                    if ($psRef.Streams.Error.Count -gt 0) {
                        $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                        $lblStatusRef.Text = "Could not check: $(@($psRef.Streams.Error | ForEach-Object { $_.ToString() }) -join '; ')"
                    }
                    else {
                        $broken = @(0..($gridRef.Rows.Count - 1) | Where-Object { $gridRef.Rows.Count -gt 0 -and [string]$gridRef.Rows[$_].Cells[2].Value -like 'NOT FOUND*' }).Count
                        $lblStatusRef.ForeColor = if ($broken -gt 0) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::SeaGreen }
                        $lblStatusRef.Text = if ($broken -gt 0) {
                            "$broken of $totalRef Winget ID(s) no longer exist - new devices can't install those apps."
                        } else {
                            "All $totalRef Winget ID(s) still exist."
                        }
                    }
                }
            }
            catch {
                if (-not $closed) {
                    $lblStatusRef.ForeColor = [System.Drawing.Color]::Firebrick
                    $lblStatusRef.Text = "Could not check: $($_.Exception.Message)"
                }
            }
            finally {
                $psRef.Dispose()
                $rsRef.Close()
                $rsRef.Dispose()
                $stateBoxRef.Running = $false
                if (-not $closed) { $btnRecheckRef.Enabled = $true }
            }
        }.GetNewClosure())
        $timer.Start()
    }.GetNewClosure()

    $btnRecheck.Add_Click({ & $runCheck }.GetNewClosure())
    $btnCopy.Add_Click({
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("Winget package check")
        $lines.Add("App`tWinget ID`tResult")
        foreach ($r in $grid.Rows) {
            if ($r.IsNewRow) { continue }
            $lines.Add((@(0..2 | ForEach-Object { [string]$r.Cells[$_].Value }) -join "`t"))
        }
        try {
            [System.Windows.Forms.Clipboard]::SetText(($lines -join "`r`n"))
            $lblStatus.ForeColor = [System.Drawing.Color]::SeaGreen
            $lblStatus.Text = "Copied $($grid.Rows.Count) row(s) to the clipboard."
        }
        catch {
            $lblStatus.ForeColor = [System.Drawing.Color]::Firebrick
            $lblStatus.Text = "Could not copy: $($_.Exception.Message)"
        }
    }.GetNewClosure())
    $dlg.Add_Shown({ & $runCheck }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    # Enter dismisses this report, same as Esc - the check itself is read-only.
    $dlg.AcceptButton = $btnClose

    Set-Theme -Control $dlg
    if ($HostTabPage) {
        $btnClose.Visible = $false
        # From here on the controls belong to the host window, so that is
        # what "is this still open?" has to mean - see $liveFormBox above.
        $liveFormBox.Form = $HostForm
        [void](Move-DialogToTabPage -Dialog $dlg -Page $HostTabPage)
        # What the Add_Shown above would have done, run by the host when
        # this tab is first opened - this one shells out to winget once per
        # catalog app, which is not something to start behind a tab nobody
        # has looked at yet.
        # IsBusy but deliberately no BlockClose: this check was always
        # closable mid-run standalone, and its poll timer stops on its own
        # once the window holding these controls is gone (see $liveFormBox).
        # Run all still waits for it - one winget process per app is exactly
        # the thing not to start a second check on top of.
        $HostTabPage.Tag = @{
            Fill        = $grid
            FillStopAbove = $btnCopy
            OnFirstShow = { & $runCheck }.GetNewClosure()
            IsBusy      = { [bool]$stateBox.Running }.GetNewClosure()
        }
        return
    }
    [void]$dlg.ShowDialog($Global:App.Form)
}
