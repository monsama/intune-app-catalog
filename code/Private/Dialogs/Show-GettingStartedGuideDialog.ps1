function Global:Show-GettingStartedGuideDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Getting started"
    $dlg.ClientSize = New-Object System.Drawing.Size(620, 560)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $txtGuide = New-Object System.Windows.Forms.TextBox
    $txtGuide.Location = New-Object System.Drawing.Point(15,15)
    $txtGuide.Size = New-Object System.Drawing.Size(590,490)
    $txtGuide.Multiline = $true
    $txtGuide.ReadOnly = $true
    $txtGuide.ScrollBars = "Vertical"
    $txtGuide.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $guideText = @"
This app manages a local catalog (one JSON file per app) alongside whatever's actually deployed in Intune. The two aren't the same thing until you make them match - here's how, for the situations that come up most.

CATALOG IS EMPTY, INTUNE ALREADY HAS APPS
(a fresh checkout of an existing catalog folder, or your first time using this catalog against an established tenant)

1. Open "Intune sync check..." (More actions > Intune).
2. Click "Refresh from Intune" if the grid is empty - every app in Intune will show up as "Not in catalog," since nothing's been imported yet.
3. Bring them in one of two ways, mixed as you like:
     - Tick the ones you want ("Select all" / "Select none" help), then "Add checked to catalog" - fast, just records the name and App ID.
     - Or "Add to catalog..." on a single row instead - opens the full App Editor for that app so you can also set its winget ID and Required/Available/Uninstall groups right away.
4. Anything added the fast way can be filled in later - open it in the App Editor whenever you're ready to add a winget ID or groups.

CATALOG HAS APPS, NOTHING DEPLOYED TO INTUNE YET
(building out a new catalog from scratch, or bringing a batch of planned apps live for the first time)

1. Add each app via "+ Add app..." - just a name to start; a winget ID is optional (leave it blank for an app with its own custom install script instead).
2. Use "Deploy to Intune..." from inside the app editor to create it in Intune (or "Batch deploy..." from the toolbar to do several apps at once, in dependency order).
3. Assign groups either while deploying, or afterward via "Push groups to Intune (single app)..." / "Push groups to Intune (multiple apps)...".

KEEPING THE TWO IN SYNC GOING FORWARD

- "Intune sync check..." (above) is also the tool for ongoing drift, not just first-time import - it flags apps renamed in Intune since, and catalog apps whose App ID no longer exists in Intune at all (deleted outside this tool), not just brand-new ones.
- The "Check Intune drift on start" toggle (toolbar, Sync group) runs that same check quietly once every time the app opens, and only says something if it actually finds a difference - useful if more than one person works from this catalog, so drift doesn't sit unnoticed until something fails.
- "Pull metadata and groups from Intune..." goes the other direction - updates the LOCAL catalog to match what's live in Intune for apps that already have an App ID, for when Intune is the one with the current truth (e.g. someone changed something there directly).
"@
    $txtGuide.Text = ConvertTo-DisplayLineEndings $guideText
    $dlg.Controls.Add($txtGuide)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(515,515)
    $btnClose.Size = New-Object System.Drawing.Size(90,30)
    $dlg.Controls.Add($btnClose)
    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose
    $dlg.AcceptButton = $btnClose

    # Same fix as Show-AppRegistrationGuideDialog's own version of this -
    # $txtGuide is first in tab order, so it's what gets focus by default
    # when the form is shown, and a read-only multiline TextBox getting
    # focus that way highlights its ENTIRE text blue (a known WinForms
    # quirk, confirmed live there). Point initial focus at Close instead.
    $dlg.Add_Shown({ $btnClose.Focus() }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
