function Global:Show-DeleteLocalCertificateDialog {
    # A dedicated picker for LOCAL certificate deletion, entirely separate
    # from Show-CertificateSetupDialog's own $txtThumb field (the app's
    # ACTIVE, configured certificate). That field used to double as the
    # delete target too - deleting a different, old local certificate
    # meant first putting its thumbprint into the same field that also
    # represents "the certificate this app currently signs in with",
    # which looked exactly like reconfiguring the active certificate and
    # risked doing that for real if Save was clicked instead of Delete.
    # This dialog never touches that field - it returns the thumbprint of
    # whatever it actually deleted, and the caller decides whether that
    # happened to be the one currently shown in its own field.
    #
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Delete Local Certificate"
    $dlg.ClientSize = New-Object System.Drawing.Size(780, 440)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(640, 320)

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Certificates found in CurrentUser\My and LocalMachine\My. This only removes a certificate locally - it does NOT remove it from Entra ID (use Check certificates / Delete from Entra for that)."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(750,36)
    $lblIntro.Anchor = "Top,Left,Right"
    $dlg.Controls.Add($lblIntro)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(15,52)
    $grid.Size = New-Object System.Drawing.Size(750,310)
    $grid.Anchor = "Top,Bottom,Left,Right"
    $grid.ReadOnly = $true
    $grid.AllowUserToAddRows = $false
    $grid.AllowUserToDeleteRows = $false
    $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
    $grid.AutoGenerateColumns = $false
    $grid.AutoSizeColumnsMode = "Fill"
    $grid.RowHeadersVisible = $false

    $colSubject = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colSubject.Name = "Subject"; $colSubject.HeaderText = "Subject"; $colSubject.FillWeight = 38
    $grid.Columns.Add($colSubject) | Out-Null
    $colStore = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colStore.Name = "Store"; $colStore.HeaderText = "Store"; $colStore.FillWeight = 18
    $grid.Columns.Add($colStore) | Out-Null
    $colThumb = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colThumb.Name = "Thumbprint"; $colThumb.HeaderText = "Thumbprint"; $colThumb.FillWeight = 30
    $grid.Columns.Add($colThumb) | Out-Null
    $colExpiry = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colExpiry.Name = "Expiry"; $colExpiry.HeaderText = "Expires"; $colExpiry.FillWeight = 14
    $grid.Columns.Add($colExpiry) | Out-Null
    $dlg.Controls.Add($grid)

    # Scans both CurrentUser\My and LocalMachine\My, same two locations
    # Get-CertificateStatusText (and the delete logic this replaced)
    # already searched - Show-CertificatePickerDialog's own grid only
    # covers CurrentUser\My, which is right for THAT dialog (picking a
    # cert to actively use only makes sense from the location app-only
    # auth actually reads), but deletion should cover everywhere a stray
    # certificate could actually be sitting. Shared by the initial load
    # and the re-populate-after-delete refresh below, so both stay in
    # exact sync with whatever's actually on disk, never a stale copy.
    $PopulateGrid = {
        $grid.Rows.Clear()
        $found = New-Object System.Collections.Generic.List[object]
        foreach ($location in @("Cert:\CurrentUser\My", "Cert:\LocalMachine\My")) {
            $storeLabel = $location -replace '^Cert:\\', ''
            foreach ($c in @(Get-ChildItem -Path $location -ErrorAction SilentlyContinue)) {
                $found.Add([pscustomobject]@{
                    Subject    = $c.Subject
                    Thumbprint = $c.Thumbprint
                    Store      = $storeLabel
                    StorePath  = $location
                    Expiry     = $c.NotAfter
                })
            }
        }
        foreach ($c in ($found | Sort-Object Subject)) {
            $rowIdx = $grid.Rows.Add()
            $row = $grid.Rows[$rowIdx]
            $row.Cells["Subject"].Value = $c.Subject
            $row.Cells["Store"].Value = $c.Store
            $row.Cells["Thumbprint"].Value = $c.Thumbprint
            $row.Cells["Expiry"].Value = $c.Expiry.ToString("yyyy-MM-dd")
            $row.Tag = $c
            if ($c.Expiry -lt (Get-Date)) {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Firebrick
            }
        }
    }.GetNewClosure()
    & $PopulateGrid

    $lblEmpty = New-Object System.Windows.Forms.Label
    $lblEmpty.Text = "No certificates found."
    $lblEmpty.Location = New-Object System.Drawing.Point(15,370)
    $lblEmpty.AutoSize = $true
    $lblEmpty.ForeColor = [System.Drawing.Color]::DimGray
    $lblEmpty.Visible = ($grid.Rows.Count -eq 0)
    $dlg.Controls.Add($lblEmpty)

    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete selected..."
    $btnDelete.Location = New-Object System.Drawing.Point(15,370)
    $btnDelete.Size = New-Object System.Drawing.Size(150,28)
    $btnDelete.Anchor = "Bottom,Left"
    $btnDelete.Enabled = ($grid.SelectedRows.Count -gt 0)
    $dlg.Controls.Add($btnDelete)
    $deleteTip = New-Object System.Windows.Forms.ToolTip
    $deleteTip.SetToolTip($btnDelete, "Permanently removes the selected certificate from this machine only - does not touch Entra ID.")

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(685,370)
    $btnClose.Size = New-Object System.Drawing.Size(80,28)
    $btnClose.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnClose)

    # Tracks every thumbprint actually deleted this session (not just the
    # last one) - the caller only needs to know whether ITS OWN
    # currently-displayed thumbprint was among them, but a plain scalar
    # would silently lose that answer if the user deleted a different
    # certificate afterward before closing this dialog.
    $resultBox = @{ DeletedThumbprints = New-Object System.Collections.Generic.List[string] }

    $grid.Add_SelectionChanged({
        $btnDelete.Enabled = ($grid.SelectedRows.Count -gt 0)
    }.GetNewClosure())

    # $resultBox/$PopulateGrid/$grid/$lblEmpty are all plain local
    # variables (not $Script:-qualified) and this is only a single level
    # of .GetNewClosure() (not nested inside another already-closured
    # block) - that combination is reliably captured directly, no fresh
    # "Ref" alias needed. See Show-EntraMemberPicker's own note on when
    # that workaround actually is required (a doubly-nested closure, or a
    # $Script:-scoped variable) - neither applies here.
    $btnDelete.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { return }
        $entry = $grid.SelectedRows[0].Tag
        $foundPath = Join-Path $entry.StorePath $entry.Thumbprint

        $r = [System.Windows.Forms.MessageBox]::Show(
            "Permanently delete this certificate from $foundPath ?`n`n$($entry.Subject)`n`nThis only removes it from THIS machine - it does NOT remove it from Entra ID. Use Check certificates / Delete from Entra separately for that.",
            "Confirm local delete", "YesNo", "Warning")
        if ($r -ne "Yes") { return }

        try {
            Remove-Item -Path $foundPath -Force -ErrorAction Stop
            $resultBox.DeletedThumbprints.Add($entry.Thumbprint)
            & $PopulateGrid
            $lblEmpty.Visible = ($grid.Rows.Count -eq 0)
            # Not left to the grid's own SelectionChanged event alone -
            # Rows.Clear()/Add() inside $PopulateGrid may or may not raise
            # it reliably enough to depend on here, and a stale-enabled
            # Delete button pointed at a now-cleared selection is exactly
            # the kind of bug worth not gambling on.
            $btnDelete.Enabled = ($grid.SelectedRows.Count -gt 0)
            [System.Windows.Forms.MessageBox]::Show("Certificate deleted from $foundPath.", "Deleted", "OK", "Information") | Out-Null
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("Could not delete the certificate: $($_.Exception.Message)`n`nDeleting from LocalMachine\My usually needs an elevated (Run as Administrator) session.", "Delete failed", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)

    return @($resultBox.DeletedThumbprints)
}
