function Show-PackagingProgressDialog {
    param([string]$SingleFolderName = "", [string[]]$FolderNames = @())

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Packaging"
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 400)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Packaging in progress..."
    $lblStatus.Location = New-Object System.Drawing.Point(15,12)
    $lblStatus.Size = New-Object System.Drawing.Size(590,20)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,40)
    $rtbLog.Size = New-Object System.Drawing.Size(590,312)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Enabled = $false
    $btnClose.Location = New-Object System.Drawing.Point(520,362)
    $btnClose.Size = New-Object System.Drawing.Size(85,28)
    $dlg.Controls.Add($btnClose)

    # Mutable container, not a plain bool - written from inside the nested
    # -OnComplete closure below, read from FormClosing. Blocks the window
    # (X button / Alt+F4) from being closed out from under a still-running
    # packaging process, same as this dialog's Close button starting disabled.
    $runningBox = @{ Running = $true }

    # Fresh aliases for the nested -OnComplete closure - see note at the top
    # of Show-CreateInIntuneDialog for why this matters here too.
    $dlgRef = $dlg
    $btnCloseRef = $btnClose
    $lblStatusRef = $lblStatus
    $runningBoxRef = $runningBox
    $rtbLogRef = $rtbLog

    $btnClose.Add_Click({ $dlgRef.Close() }.GetNewClosure())
    $dlg.Add_FormClosing({
        param($s, $e)
        if ($runningBoxRef.Running) { $e.Cancel = $true }
    }.GetNewClosure())

    $dlg.Add_Shown({
        # Re-aliased HERE, fresh, in the immediately-enclosing (Add_Shown)
        # closure's own body - reusing $rtbLogRef/$btnCloseRef/etc. directly
        # inside the -OnComplete closure below (as this used to) is exactly
        # the "nested closure doesn't reliably see a variable only captured
        # by an OUTER closure" gap this app's own established convention
        # exists to avoid (see the note in Show-BatchDeployDialog's own
        # $RunNextBox handler) - it was just missed here. Confirmed live:
        # the finally block's own $btnCloseRef.Enabled = $true silently
        # never took effect, leaving Close permanently greyed out even
        # though the run itself completed successfully (exit code 0,
        # "[Finished]" printed) - a doubly-nested closure failing to see an
        # outer closure's own capture, not a Refresh-Grid exception (that
        # path was already defended with its own try/catch/finally, which
        # is why this went unnoticed until now).
        $btnCloseRef2 = $btnCloseRef
        $lblStatusRef2 = $lblStatusRef
        $runningBoxRef2 = $runningBoxRef
        $rtbLogRef2 = $rtbLogRef

        Invoke-LaunchStep -ExtraLogTarget $rtbLogRef2 -SingleFolderName $SingleFolderName -FolderNames $FolderNames -OnComplete {
            param($code)
            # Refresh-Grid wrapped in try/finally - it's local catalog/filesystem
            # work with no reason to fail, but this runs from inside a Timer.Tick
            # handler (see Start-PipelineProcess), where an unhandled exception
            # can be silently swallowed by the .NET event dispatch instead of
            # surfacing anywhere - which previously would have skipped every
            # statement after it, leaving Close permanently disabled and the
            # dialog's FormClosing guard blocking the window forever. Whatever
            # happens in Refresh-Grid, the dialog must still unlock.
            try {
                Refresh-Grid
            }
            catch {
                $rtbLogRef2.AppendText("`r`n[WARN] Grid refresh after packaging failed: $($_.Exception.Message)`r`n")
            }
            finally {
                $runningBoxRef2.Running = $false
                $btnCloseRef2.Enabled = $true
                if ($code -eq 0) {
                    $lblStatusRef2.Text = "Packaging complete."
                    $lblStatusRef2.ForeColor = [System.Drawing.Color]::SeaGreen
                }
                else {
                    $lblStatusRef2.Text = "Packaging finished with exit code $code - see the log above."
                    $lblStatusRef2.ForeColor = [System.Drawing.Color]::Orange
                }
            }
        }.GetNewClosure()
    }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($form)
}
