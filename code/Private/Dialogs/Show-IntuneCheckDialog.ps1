function Global:Show-IntuneCheckDialog {
    <#
      Everything this app can ask about how the catalog compares to Intune,
      in one window.

      They were three: "Look up App IDs" (which Intune app is this entry?),
      "Intune audit" (which entries disagree with Intune?) and "Sync
      metadata" (which fields disagree, and pull them back). Three menu
      entries, three windows, and all three began with the same read of
      every app in the tenant - so answering the obvious next question
      meant closing one window, opening another, and waiting for the same
      fetch again.

      Each tab is still its own dialog, unchanged, moved onto a page - see
      Move-DialogToTabPage. They share this window's Close and, more to the
      point, the one fetch that fills $Global:App.IntuneAppsCache.
    #>
    param([int[]]$ScopedIndices = @())

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Font = Get-AppUiFont
    $dlg.Text = "Check against Intune"
    $dlg.ClientSize = New-Object System.Drawing.Size(1320, 700)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "Sizable"
    $dlg.MinimumSize = New-Object System.Drawing.Size(900, 560)
    $dlg.MaximizeBox = $true
    $dlg.MinimizeBox = $false

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(15,12)
    $tabs.Size = New-Object System.Drawing.Size(1290, 636)
    $tabs.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor
                   [System.Windows.Forms.AnchorStyles]::Right -bor [System.Windows.Forms.AnchorStyles]::Bottom
    $dlg.Controls.Add($tabs)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Size = New-Object System.Drawing.Size(90,30)
    $btnClose.Location = New-Object System.Drawing.Point(1215,658)
    $btnClose.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom -bor [System.Windows.Forms.AnchorStyles]::Right
    $dlg.Controls.Add($btnClose)
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    # Enter closes the window. Every check on the tabs inside is read-only.
    $dlg.AcceptButton = $btnClose

    # Built in the order they're usually needed: which app is which, then
    # what disagrees, then pulling it back.
    foreach ($spec in @(
        @{ Title = 'App IDs';       Build = { param($page) Show-AppIdMatchDialog -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Audit';         Build = { param($page) Show-IntuneAuditDialog -ScopedIndices $ScopedIndices -HostTabPage $page -HostForm $dlg } }
        @{ Title = 'Metadata sync'; Build = { param($page) Show-SyncMetadataDialog -ScopedIndices $ScopedIndices -HostTabPage $page -HostForm $dlg } }
    )) {
        $page = New-Object System.Windows.Forms.TabPage
        $page.Text = [string]$spec.Title
        $page.UseVisualStyleBackColor = $true
        [void]$tabs.TabPages.Add($page)
        # One tab failing to build must not take the other two with it -
        # each is a separate dialog with its own reasons to give up (no
        # apps returned from Intune, nothing eligible to sync).
        try { & $spec.Build $page }
        catch {
            $lblFailed = New-Object System.Windows.Forms.Label
            $lblFailed.Text = "This check couldn't be opened: $($_.Exception.Message)"
            $lblFailed.Location = New-Object System.Drawing.Point(15,15)
            $lblFailed.Size = New-Object System.Drawing.Size(600,60)
            $lblFailed.ForeColor = [System.Drawing.Color]::Firebrick
            $page.Controls.Add($lblFailed)
        }
    }

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
    $dlg.Dispose()
}
