<#
  The editor's blocks (2.26): the install and uninstall commands and the
  detection script shown as locked and editable blocks, read from the
  commands and written back to them (the pure work is in CatalogLogic.ps1:
  Get-InstallBlocks, New-InstallFromBlocks, Get-DetectionBlocks,
  New-DetectionFromBlocks) - and the package scripts (Install.ps1,
  Uninstall.ps1, Invoke-AppDeployToolkit.ps1) edited in the app.

  Nothing here saves the app: the editor puts the commands it gets back
  into its fields, and Save saves them as before. Package scripts are
  files of their own, saved here - checked, with a copy in Backups first.
#>

# ---------------------------------------------------------------- blocks

function Global:Get-WebInstallBlocks {
    # The app's commands as blocks (what the editor has now - nothing saved).
    param($Data)
    $r = Get-InstallBlocks -WingetId ([string]$Data.wingetId).Trim() -Install ([string]$Data.install) -Uninstall ([string]$Data.uninstall) -InstallContext ([string]$Data.context)
    return @{ ok = $true; form = $r.Form; own = [bool]$r.Own; blocks = @($r.Blocks); note = [string]$r.Note }
}

function Global:Get-WebInstallCompose {
    # The commands written from the blocks' values - checked here; the editor puts them in its fields.
    param($Data)
    $r = New-InstallFromBlocks -Form ([string]$Data.form) -Values $Data.values -WingetId ([string]$Data.wingetId).Trim() -Install ([string]$Data.install) -Uninstall ([string]$Data.uninstall) -InstallContext ([string]$Data.context)
    if (-not $r.Ok) { return @{ ok = $false; error = $r.Error } }
    return @{ ok = $true; install = $r.Install; uninstall = $r.Uninstall }
}

function Global:Get-WebDetectionBlocks {
    param($Data)
    $r = Get-DetectionBlocks ([ordered]@{ Type = 'Script'; Script_Content = [string]$Data.script })
    return @{ ok = $true; form = $r.Form; own = [bool]$r.Own; blocks = @($r.Blocks); note = [string]$r.Note }
}

function Global:Get-WebDetectionCompose {
    param($Data)
    $r = New-DetectionFromBlocks -Form ([string]$Data.form) -Values $Data.values -Rule ([ordered]@{ Type = 'Script'; Script_Content = [string]$Data.script })
    if (-not $r.Ok) { return @{ ok = $false; error = $r.Error } }
    return @{ ok = $true; script = $r.Script; detectedName = [string]$r.DetectedName }
}

# ---------------------------------------------------------------- package scripts

function Global:Resolve-WebPackageScript {
    <#
      The path of one of an app's package scripts - only Install.ps1,
      Uninstall.ps1 or Invoke-AppDeployToolkit.ps1 in that app's own folder
      under Packages, of an app in the catalog. @{ Ok; Path; Error }.
    #>
    param([string]$Name, [string]$File)
    if ($File -cnotin 'Install.ps1', 'Uninstall.ps1', 'Invoke-AppDeployToolkit.ps1') { return @{ Ok = $false; Error = 'Only Install.ps1, Uninstall.ps1 and Invoke-AppDeployToolkit.ps1 can be edited here.' } }
    $app = @((Read-WebCatalogRecords).Apps | Where-Object { $_.appName -eq $Name }) | Select-Object -First 1
    if (-not $app) { return @{ Ok = $false; Error = "'$Name' isn't in the catalog." } }
    $root = [IO.Path]::GetFullPath((Get-AppFolder -Kind Packages))
    $folder = Join-Path $root (Get-SafeFileNameForApp -Name $app.appName)
    $path = [IO.Path]::GetFullPath((Join-Path $folder $File))
    if (-not $path.StartsWith($root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return @{ Ok = $false; Error = 'That file is outside the Packages folder.' } }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @{ Ok = $false; Error = "$File isn't in $folder." } }
    # A link could point anywhere - only a plain file in a plain folder is edited (the app's folder and the file, checked each time).
    foreach ($item in @((Get-Item -LiteralPath $folder -Force), (Get-Item -LiteralPath $path -Force))) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return @{ Ok = $false; Error = "$($item.Name) is a link - edit the script where it points." } }
    }
    return @{ Ok = $true; Path = $path; App = $app.appName; Error = '' }
}

function Global:Get-WebTextHash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Global:Read-WebPackageScript {
    # One package script for the editor: its text, its fingerprint (to notice someone else's change on save) and its locked lines.
    param($Data)
    $p = Resolve-WebPackageScript -Name ([string]$Data.name) -File ([string]$Data.file)
    if (-not $p.Ok) { return @{ ok = $false; error = $p.Error } }
    if ((Get-Item -LiteralPath $p.Path).Length -gt 262144) { return @{ ok = $false; error = "$($Data.file) is larger than 256 KB - edit it outside the app." } }
    $text = [System.IO.File]::ReadAllText($p.Path)
    $files = @(foreach ($f in 'Install.ps1', 'Uninstall.ps1', 'Invoke-AppDeployToolkit.ps1') { if (Test-Path -LiteralPath (Join-Path (Split-Path $p.Path) $f) -PathType Leaf) { $f } })
    return @{ ok = $true; text = $text; hash = (Get-WebTextHash $p.Path); locked = @(Get-PackageScriptLockedLines $text); files = $files; folder = (Split-Path $p.Path) }
}

function Global:Test-WebPackageScript {
    # The editor's check while typing: does it parse, and are the locked lines as they were.
    param($Data)
    $r = Test-PackageScriptEdit -Old ([string]$Data.old) -New ([string]$Data.text)
    return @{ ok = $true; valid = [bool]$r.Ok; error = [string]$r.Error; errors = @($r.Errors) }
}

function Global:Get-WebScriptCopyFolder {
    return (Join-Path (Get-AppFolder -Kind Backups -Create) ('script-edit_' + (Get-Date -Format 'yyyy-MM-dd')))
}

function Global:Save-WebPackageScript {
    <#
      Saves a package script from the editor: only when nobody changed the
      file since it was opened (its fingerprint), when it parses and keeps
      its locked lines. The file as it was goes to Backups first (recorded,
      so the editor's "Previous version" can trust it); the change goes into
      the history, with who made it. The package needs building again.
    #>
    param($Data)
    $p = Resolve-WebPackageScript -Name ([string]$Data.name) -File ([string]$Data.file)
    if (-not $p.Ok) { return @{ ok = $false; error = $p.Error } }
    $text = [string]$Data.text
    return (Invoke-WithCatalogLock {
            # Checked again under the lock, right before writing: the folder or file can't have become a link meanwhile.
            $again = Resolve-WebPackageScript -Name ([string]$Data.name) -File ([string]$Data.file)
            if (-not $again.Ok -or $again.Path -ne $p.Path) { return @{ ok = $false; error = $(if ($again.Ok) { 'The script moved meanwhile.' } else { $again.Error }) } }
            if ((Get-WebTextHash $p.Path) -ne [string]$Data.hash) { return @{ ok = $false; conflict = $true; error = "$($Data.file) was changed since you opened it (by someone else, or outside the app). Nothing was saved - close it and open it again, then redo your change." } }
            $old = [System.IO.File]::ReadAllText($p.Path)
            $check = Test-PackageScriptEdit -Old $old -New $text
            if (-not $check.Ok) { return @{ ok = $false; error = $check.Error; errors = @($check.Errors) } }
            $dir = Get-WebScriptCopyFolder
            if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
            $copy = Join-Path $dir ("$(Get-Date -Format 'HHmmss')_$(Get-SafeFileNameForApp -Name $p.App)_$($Data.file)"); $n = 1
            while (Test-Path -LiteralPath $copy) { $n++; $copy = Join-Path $dir ("$(Get-Date -Format 'HHmmss')-$($n)_$(Get-SafeFileNameForApp -Name $p.App)_$($Data.file)") }
            Copy-Item -LiteralPath $p.Path -Destination $copy
            Add-WebCopyRecord $copy
            # UTF-8 with a BOM: Windows PowerShell 5.1 reads a file without one in the ANSI code page (umlauts break).
            [System.IO.File]::WriteAllText($p.Path, (ConvertTo-CanonicalLineEndings $text), (New-Object System.Text.UTF8Encoding($true)))
            Add-WebHistoryEntry -App $p.App -Kind 'catalog' -Text "$($Data.file) edited in the app - build the package again (the earlier one is in Backups)."
            Write-Log "[OK] $($p.App): $($Data.file) saved (the earlier one: $copy). Build the package again."
            return @{ ok = $true; hash = (Get-WebTextHash $p.Path); locked = @(Get-PackageScriptLockedLines ([System.IO.File]::ReadAllText($p.Path))) }
        })
}

function Global:Get-WebPackageScriptPrevious {
    # The newest copy of this script that this app put in Backups and nobody changed since - for "Previous version" in the editor (loaded, not saved).
    param($Data)
    $p = Resolve-WebPackageScript -Name ([string]$Data.name) -File ([string]$Data.file)
    if (-not $p.Ok) { return @{ ok = $false; error = $p.Error } }
    $backups = Get-AppFolder -Kind Backups
    if (-not (Test-Path -LiteralPath $backups)) { return @{ ok = $false; error = 'No earlier version in Backups.' } }
    # HHmmss[-n]_<app>_<file>: the whole rest compared, so "My_Tool" never takes Tool's copies.
    $want = "$(Get-SafeFileNameForApp -Name $p.App)_$($Data.file)"
    $copies = @(Get-ChildItem -LiteralPath $backups -Directory -Filter 'script-edit_*' -ErrorAction SilentlyContinue | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -ErrorAction SilentlyContinue } |
            Where-Object { $_.Name -match '^\d{6}(-\d+)?_(.+)$' -and [string]::Equals($Matches[2], $want, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object { $_.Directory.Name }, { $_.Name } -Descending)
    # The version marker as the current file has it now (a release may have moved it since): the copy can then be saved again.
    $current = [System.IO.File]::ReadAllText($p.Path)
    $mv = [regex]::Match($current, "-Name\s+Version\s+-Value\s+'((?:[^']|'')*)'")
    foreach ($c in $copies) {
        if ((Test-WebCopyRecord $c.FullName) -ne 'ok') { continue }
        $text = [System.IO.File]::ReadAllText($c.FullName)
        if ($mv.Success) { $text = (Set-MarkerScriptVersion -Text $text -Version ($mv.Groups[1].Value -replace "''", "'")).Text }
        # When it was kept (the folder's date and the copy's time), not when that version was first written.
        $at = if ($c.Directory.Name -match '^script-edit_\d{4}-\d{2}-\d{2}$') { '{0} {1}:{2}' -f $c.Directory.Name.Substring(12), $c.Name.Substring(0, 2), $c.Name.Substring(2, 2) } else { $c.LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        return @{ ok = $true; text = $text; at = $at }
    }
    return @{ ok = $false; error = $(if ($copies.Count) { 'The copies in Backups were changed outside the app - none is taken.' } else { 'No earlier version in Backups yet - one is kept each time you save.' }) }
}
