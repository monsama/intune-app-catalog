<#
.SYNOPSIS
    The app's button sizing scheme, checked against the source.

.DESCRIPTION
    Every button in this app is absolutely positioned, so nothing keeps
    two of them the same size except somebody remembering to. This suite
    is that memory.

    The scheme, as measured across the app rather than invented here:

      34px  the empty-catalog call-to-action buttons, and only those
      32px  a dialog's footer row and its primary actions (Save, Close,
            Cancel, OK, and the one button the dialog exists to press)
      30px  a wide button stacked with others to fill a panel's width
      28px  the same idea at a smaller scale - a toolbar strip or a
            warning bar sitting above content
      26px  a small button attached to a control: Browse, Search,
            Refresh, Add row, Select all/none under a list

    What is deliberately NOT asserted: which of those heights a given
    button should have. That follows from where it sits, which the source
    text does not say - a footer Cancel and an inline Cancel are both
    correct at their own height, and pinning one number per label would
    be wrong. What IS asserted is the part that is objectively visible:
    no stray heights, and no two buttons side by side at different
    heights or different baselines.

    Pure text analysis, no WinForms - same reason CatalogLogic.Tests.ps1
    can run on Linux.

.EXAMPLE
    pwsh -NoProfile -File code/tests/ButtonStyle.Tests.ps1
#>

$ErrorActionPreference = "Stop"
$script:failures = New-Object System.Collections.Generic.List[string]
$script:passCount = 0

function Assert-True {
    param([bool]$Condition, [string]$Because)
    if (-not $Condition) { $script:failures.Add("$Because`n    Expected: truthy`n    Actual:   falsy") }
    else { $script:passCount++ }
}

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$sourceFiles = @(Get-ChildItem -Path (Join-Path $repoRoot 'code/Private') -Filter *.ps1 -Recurse) +
               @(Get-Item (Join-Path $repoRoot 'MainApp.ps1'))

# Every button, with the size and position it is given. Read from the text
# rather than by running the app: this has to work on a Linux runner with
# no WinForms at all, and a dialog that is never constructed still ships.
function Get-ButtonLayout {
    param([string]$Path)
    $text = Get-Content -Raw -LiteralPath $Path
    $isButton = @{}
    foreach ($m in [regex]::Matches($text, '\$(\w+)\s*=\s*New-Object\s+System\.Windows\.Forms\.Button')) {
        $isButton[$m.Groups[1].Value] = $true
    }
    $locations = @{}
    foreach ($m in [regex]::Matches($text, '\$(\w+)\.Location\s*=\s*New-Object\s+System\.Drawing\.Point\(\s*(\d+)\s*,\s*(\d+)\s*\)')) {
        $name = $m.Groups[1].Value
        if (-not $isButton.ContainsKey($name)) { continue }
        if (-not $locations.ContainsKey($name)) { $locations[$name] = New-Object System.Collections.Generic.List[object] }
        $locations[$name].Add([pscustomobject]@{ Pos = $m.Index; X = [int]$m.Groups[2].Value; Y = [int]$m.Groups[3].Value })
    }
    # Which container each button is added to. A Y coordinate only means
    # anything next to another Y in the SAME parent - a button at y=59
    # inside a group box and one at y=64 on the form itself are nowhere
    # near each other on screen, and comparing them finds rows that do not
    # exist. Show-CertificateSetupDialog has exactly that pair.
    $parents = @{}
    foreach ($m in [regex]::Matches($text, '\$(\w+)\.Controls\.Add\(\s*\$(\w+)\s*\)')) {
        $child = $m.Groups[2].Value
        if (-not $isButton.ContainsKey($child)) { continue }
        if (-not $parents.ContainsKey($child)) { $parents[$child] = $m.Groups[1].Value }
    }
    $found = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($m in [regex]::Matches($text, '\$(\w+)\.Size\s*=\s*New-Object\s+System\.Drawing\.Size\(\s*(\d+)\s*,\s*(\d+)\s*\)')) {
        $name = $m.Groups[1].Value
        if (-not $isButton.ContainsKey($name)) { continue }
        # A button resized a second time is the same button laid out again
        # for the tab-hosted variant of its dialog - a separate layout, not
        # a second button sitting beside the first. Only the first (the
        # standalone window) is compared, or the two would look like a row
        # of two buttons at the same spot disagreeing about their height.
        if ($seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        # Only a Location written right beside this Size counts as this
        # button's position. A dialog that computes its stack with a
        # running $y has no literal Point() to find, and pairing its Size
        # with some other layout block's Point() several hundred lines
        # away invents a position the button never has.
        $where = $null
        if ($locations.ContainsKey($name)) {
            $where = $locations[$name] |
                Where-Object { [Math]::Abs($_.Pos - $m.Index) -le 200 } |
                Sort-Object { [Math]::Abs($_.Pos - $m.Index) } | Select-Object -First 1
        }
        $found.Add([pscustomobject]@{
            Var    = $name
            W      = [int]$m.Groups[2].Value
            H      = [int]$m.Groups[3].Value
            X      = if ($where) { $where.X } else { $null }
            Y      = if ($where) { $where.Y } else { $null }
            Parent = if ($parents.ContainsKey($name)) { $parents[$name] } else { '(unknown)' }
        })
    }
    return $found
}

$allowedHeights = @(26, 28, 30, 32, 34)
$everyButton = New-Object System.Collections.Generic.List[object]
foreach ($file in $sourceFiles) {
    foreach ($button in (Get-ButtonLayout -Path $file.FullName)) {
        $everyButton.Add([pscustomobject]@{
            File = $file.Name; Var = $button.Var; W = $button.W; H = $button.H
            X = $button.X; Y = $button.Y; Parent = $button.Parent
        })
    }
}

Assert-True ($everyButton.Count -gt 100) "the audit actually found the app's buttons (found $($everyButton.Count))"

# -----------------------------------------------------------------
# 1. No stray heights
# -----------------------------------------------------------------
$strayHeights = @($everyButton | Where-Object { $allowedHeights -notcontains $_.H })
$strayText = ($strayHeights | ForEach-Object { "$($_.File):`$$($_.Var) is $($_.W)x$($_.H)" }) -join '; '
Assert-True ($strayHeights.Count -eq 0) `
    "every button is one of the scheme's heights ($($allowedHeights -join '/')) - $strayText"

# -----------------------------------------------------------------
# 2. Buttons sharing a row share a height and a baseline
# -----------------------------------------------------------------
# The one mismatch a user can actually see without opening two dialogs
# side by side. A "row" is buttons with the same parent whose tops are
# within 6px - far enough apart to be a separate row in every layout here.
$rowProblems = New-Object System.Collections.Generic.List[string]
foreach ($group in ($everyButton | Where-Object { $null -ne $_.Y } | Group-Object { "$($_.File)|$($_.Parent)" })) {
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($button in ($group.Group | Sort-Object Y, X)) {
        $placed = $false
        foreach ($row in $rows) {
            if ([Math]::Abs($row[0].Y - $button.Y) -le 6) { $row.Add($button); $placed = $true; break }
        }
        if (-not $placed) {
            $newRow = New-Object System.Collections.Generic.List[object]
            $newRow.Add($button)
            $rows.Add($newRow)
        }
    }
    foreach ($row in $rows) {
        if ($row.Count -lt 2) { continue }
        $heights = @($row | ForEach-Object { $_.H } | Sort-Object -Unique)
        $bottoms = @($row | ForEach-Object { $_.Y + $_.H } | Sort-Object -Unique)
        if ($heights.Count -eq 1 -and $bottoms.Count -eq 1) { continue }
        $detail = ($row | Sort-Object X | ForEach-Object { "`$$($_.Var) $($_.W)x$($_.H)@$($_.X),$($_.Y)" }) -join ' | '
        $rowProblems.Add("$($row[0].File) row at y~$($row[0].Y) in `$$($row[0].Parent): $detail")
    }
}
Assert-True ($rowProblems.Count -eq 0) `
    "buttons in the same row share a height and a bottom edge - $($rowProblems -join ' ;; ')"

# -----------------------------------------------------------------
# 3. Select all / Select none are always the same width as each other
# -----------------------------------------------------------------
# Seven dialogs have this pair, and it is the one place in the app where
# two buttons of obviously equal weight sit right next to each other -
# so an unequal width shows immediately. Matched on the variable name
# rather than the label, because the label lives in a separate statement.
$pairProblems = New-Object System.Collections.Generic.List[string]
foreach ($group in ($everyButton | Group-Object File)) {
    $all  = @($group.Group | Where-Object { $_.Var -match '^btnSelectAll' })
    $none = @($group.Group | Where-Object { $_.Var -match '^btnSelectNone' })
    if ($all.Count -ne 1 -or $none.Count -ne 1) { continue }
    if ($all[0].W -eq $none[0].W -and $all[0].H -eq $none[0].H) { continue }
    $pairProblems.Add("$($group.Name): all=$($all[0].W)x$($all[0].H) none=$($none[0].W)x$($none[0].H)")
}
Assert-True ($pairProblems.Count -eq 0) `
    "Select all and Select none are the same size as each other - $($pairProblems -join '; ')"

# -----------------------------------------------------------------
# Report
# -----------------------------------------------------------------
Write-Host ""
if ($script:failures.Count -eq 0) {
    Write-Host "PASSED: $($script:passCount) assertion(s), 0 failure(s)." -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILED: $($script:failures.Count) of $($script:passCount + $script:failures.Count) assertion(s)." -ForegroundColor Red
    foreach ($f in $script:failures) { Write-Host "`n$f" -ForegroundColor Red }
    exit 1
}
