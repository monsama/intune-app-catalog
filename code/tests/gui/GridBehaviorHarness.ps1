<#
    Runs inside the PowerShell under test for GridBehavior.GuiTests.ps1:
    builds the catalog grid exactly as the app builds it - the same
    New-GridColumn columns, the same Update-Grid and Sort-Grid out of
    GuiHelpers.ps1 - over a fixed set of apps that is deliberately NOT in
    alphabetical order, and long enough that the grid actually scrolls.

    Then it does what the app does to that grid (sort it, select rows,
    scroll it, rebuild it) and records what survived. Writes one
    "key=value" per line to -StatusFile; GridBehavior.GuiTests.ps1 turns
    those into assertions.
#>
param([string]$RepoRoot, [string]$StatusFile)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$Global:App = @{}
. (Join-Path $RepoRoot 'code\Private\Catalog\CatalogLogic.ps1')
. (Join-Path $RepoRoot 'code\Private\GuiHelpers.ps1')
# Update-Grid asks where the packages folder is before it builds a row,
# so the resolver for that has to be here too - it only reads
# $Global:App.AppFolders, set below.
. (Join-Path $RepoRoot 'code\Private\AppFolders.ps1')

$status = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$Key, $Value) $status.Add("$Key=$Value") }

# Three named apps out of alphabetical order, then filler: the filler is
# what makes the grid scroll, and a scroll position can only be lost when
# there is somewhere to scroll to.
$names = @('Zulu App', 'Mike App', 'Alpha App') + (1..30 | ForEach-Object { 'Filler App {0:D2}' -f $_ })
$Global:App.Apps = New-Object System.Collections.Generic.List[Object]
foreach ($n in $names) {
    # A non-empty wingetId keeps every fixture app "common": Update-Grid
    # then never calls Resolve-AppPackagePath, so nothing here goes looking
    # around the filesystem for a package that was never built.
    [void]$Global:App.Apps.Add([pscustomobject]@{
        appName          = $n
        wingetId         = "Fixture.$($n -replace '\s', '')"
        requiredFor      = @()
        availableFor     = @()
        uninstallFor     = @()
        intuneAppType    = ''
        intuneAppVersion = ''
        appId            = $null
    })
}
$Global:App.UnsavedChangesBox = @{ Value = $false }
$Global:App.LinkedFilePath = 'C:\fixture\catalog'
$Global:App.LastAuditResults = @{}
$Global:App.RootPath = $RepoRoot

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Grid behaviour test'
$form.Size = New-Object System.Drawing.Size(900, 400)
$form.Font = Get-AppUiFont
$Global:App.StatusLabel = New-Object System.Windows.Forms.Label
$Global:App.TxtSearch = New-Object System.Windows.Forms.TextBox
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $true
$grid.AutoGenerateColumns = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.RowHeadersVisible = $false
$gridFont = $form.Font
foreach ($c in @(
    @('AppName', 'App Name'), @('WingetId', 'Winget ID'), @('Type', 'Type'),
    @('Version', 'Version'), @('Uncommon', 'Uncommon'), @('CustomConfig', 'Custom Config'),
    @('Folder', 'Package folder'), @('Required', 'Required'), @('Available', 'Available'),
    @('Uninstall', 'Uninstall'), @('AppId', 'App ID'), @('Status', 'Status'),
    @('IntuneAudit', 'Last Audit'))) {
    $grid.Columns.Add((New-GridColumn $c[0] $c[1] -Font $gridFont)) | Out-Null
}
$colIndex = New-GridColumn 'Index' 'Index' -Font $gridFont
$colIndex.Visible = $false
$grid.Columns.Add($colIndex) | Out-Null
$Global:App.Grid = $grid
$form.Controls.Add($grid)
$form.Controls.Add($Global:App.TxtSearch)
$form.Controls.Add($Global:App.StatusLabel)
$form.Show()
[System.Windows.Forms.Application]::DoEvents()

function Get-RowNames { @($grid.Rows | ForEach-Object { [string]$_.Cells['AppName'].Value }) }
function Get-SelectedNames { @($grid.SelectedRows | ForEach-Object { [string]$_.Cells['AppName'].Value }) | Sort-Object }
function Get-Glyph { param($Name) [string]$grid.Columns[$Name].HeaderCell.SortGlyphDirection }
function Select-RowByName {
    param([string[]]$Names)
    $grid.ClearSelection()
    foreach ($row in $grid.Rows) {
        if ($Names -contains [string]$row.Cells['AppName'].Value) { $row.Selected = $true }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

try {
    # 1. No sort asked for yet: the catalog's own order, untouched.
    Update-Grid
    Add-Line 'unsortedFirst3' ((Get-RowNames | Select-Object -First 3) -join '|')
    Add-Line 'glyphBeforeAnySort' (Get-Glyph 'AppName')

    # 2. First click on a header sorts ascending.
    Sort-Grid -ColumnName 'AppName'
    $asc = Get-RowNames
    Add-Line 'ascFirst' $asc[0]
    Add-Line 'ascLast' $asc[-1]
    Add-Line 'glyphAsc' (Get-Glyph 'AppName')
    Add-Line 'glyphOtherColumn' (Get-Glyph 'Status')

    # 3. Second click on the same header reverses it.
    Sort-Grid -ColumnName 'AppName'
    Add-Line 'descFirst' (Get-RowNames)[0]
    Add-Line 'glyphDesc' (Get-Glyph 'AppName')

    # 4. The sort has to survive a plain rebuild - Update-Grid is what every
    #    save, deploy and keystroke in the search box calls.
    Update-Grid
    Add-Line 'descFirstAfterRebuild' (Get-RowNames)[0]
    Add-Line 'glyphAfterRebuild' (Get-Glyph 'AppName')

    # 5. A selection has to survive that same rebuild, including a
    #    multi-row one - batch deploy and batch assign both act on it.
    Sort-Grid -ColumnName 'AppName'   # back to ascending
    Select-RowByName @('Mike App', 'Zulu App')
    Add-Line 'selectionBeforeRebuild' ((Get-SelectedNames) -join '|')
    Update-Grid
    Add-Line 'selectionAfterRebuild' ((Get-SelectedNames) -join '|')

    # 6. So does the scroll position, on its own.
    $grid.ClearSelection()
    $grid.FirstDisplayedScrollingRowIndex = 10
    [System.Windows.Forms.Application]::DoEvents()
    Add-Line 'scrollBeforeRebuild' $grid.FirstDisplayedScrollingRowIndex
    Update-Grid
    Add-Line 'scrollAfterRebuild' $grid.FirstDisplayedScrollingRowIndex

    # 7. An app the filter hides has no row to go back to. Nothing may be
    #    selected in its place - inheriting row 0 is how the wrong app gets
    #    deployed.
    Select-RowByName @('Zulu App')
    $Global:App.TxtSearch.Text = 'Alpha'
    Update-Grid
    Add-Line 'rowsWhenFiltered' $grid.Rows.Count
    Add-Line 'selectionWhenFilteredOut' ((Get-SelectedNames) -join '|')

    # 8. And it comes back when the filter does not hide it any more.
    $Global:App.TxtSearch.Text = ''
    Select-RowByName @('Mike App')
    $Global:App.TxtSearch.Text = 'Mike'
    Update-Grid
    Add-Line 'selectionWhenStillVisible' ((Get-SelectedNames) -join '|')

    # 9. The Uncommon column. Appended at the end deliberately: these three
    #    extra apps would shift the sort/scroll positions every scenario
    #    above pins down. Each one is a different answer to the same
    #    question - which package does this app install from?
    $Global:App.TxtSearch.Text = ''
    $uncommonCases = @(
        # Winget ID, no package of its own: installs from the shared winget
        # wrapper, so the column stays blank.
        @{ Name = 'Uncommon Case Winget'; WingetId = 'Fixture.Winget'; PackagePath = $null },
        # Winget ID AND a hand-picked .intunewin: that package wins, so this
        # is the case the plain "has no Winget ID" rule used to miss
        # entirely and the column called common.
        @{ Name = 'Uncommon Case Custom'; WingetId = 'Fixture.Custom'; PackagePath = 'C:\fixture\packages\custom\custom.intunewin' },
        # No Winget ID at all: uncommon the original way.
        @{ Name = 'Uncommon Case Plain';  WingetId = '';               PackagePath = $null }
    )
    foreach ($case in $uncommonCases) {
        [void]$Global:App.Apps.Add([pscustomobject]@{
            appName          = $case.Name
            wingetId         = $case.WingetId
            packagePath      = $case.PackagePath
            requiredFor      = @()
            availableFor     = @()
            uninstallFor     = @()
            intuneAppType    = ''
            intuneAppVersion = ''
            appId            = $null
        })
    }
    Update-Grid
    foreach ($case in $uncommonCases) {
        $cell = ''
        $statusCell = ''
        foreach ($row in $grid.Rows) {
            if ([string]$row.Cells['AppName'].Value -ne $case.Name) { continue }
            $cell = [string]$row.Cells['Uncommon'].Value
            $statusCell = [string]$row.Cells['Status'].Value
        }
        $key = $case.Name -replace '\s', ''
        Add-Line ('uncommonCell_' + $key) $cell
        Add-Line ('uncommonStatus_' + $key) $statusCell
    }

    Add-Line 'ran' 'true'
}
catch {
    Add-Line 'error' "$($_.Exception.Message) @ line $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    [IO.File]::WriteAllLines($StatusFile, $status)
    $form.Close()
    $form.Dispose()
}
