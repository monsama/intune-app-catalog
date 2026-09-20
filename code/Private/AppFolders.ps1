# Where this app keeps things, and how that can be changed.
#
# Every one of these paths used to be built where it was needed, as
# Join-Path $Global:App.RootPath "data\<something>" - ten call sites, seven
# different folders, and no way to put any of them anywhere else. On a
# machine where the app lives under Program Files, or where the catalog
# belongs on a share and the logs do not, that is the wrong answer in both
# directions.
#
# One resolver instead: a default per folder, an optional override per
# folder from the settings file, and everywhere else asks for it by name.

function Global:Get-AppFolderKinds {
    <#
      The folders that can be pointed somewhere else, in the order the
      Settings dialog shows them. Label is what a person reads; Default is
      relative to the app's own folder; Why explains what lands there, for
      the dialog and for anyone reading this list.

      Deliberately NOT here: the settings file itself, which has to be
      found before anything can be read out of it, so it stays beside the
      app.
    #>
    return @(
        @{ Key = 'Catalog';  Label = 'Catalog (one JSON file per app)'; Default = 'data\app-data';     Why = 'The apps themselves - what "Open other folder..." switches between, and what belongs in git.' }
        @{ Key = 'Packages'; Label = 'Packages (.intunewin)';           Default = 'data\app-packages'; Why = 'Built packages. Large and rebuildable, so a scratch disk is a fine place for them.' }
        @{ Key = 'Shared';   Label = 'Shared Winget package';           Default = 'init';              Why = 'init.intunewin, the one package every Winget app deploys with. Built on demand.' }
        @{ Key = 'Tools';    Label = 'Packaging tool';                  Default = 'tools';             Why = 'IntuneWinAppUtil.exe, Microsoft''s Win32 Content Prep Tool. Downloaded on demand.' }
        @{ Key = 'Scripts';  Label = 'Platform script copies';          Default = 'data\script-data';  Why = 'Local copies of the tenant''s platform scripts, shaped like the catalog.' }
        @{ Key = 'Logs';     Label = 'Logs';                            Default = 'data\logs';         Why = 'One file per day of everything this app did.' }
        @{ Key = 'Backups';  Label = 'Catalog backups';                 Default = 'data\backups';      Why = 'Copies taken before the catalog is rewritten.' }
    )
}

function Global:Get-AppFolderDefault {
    <# Where a folder goes when nothing has been chosen for it. #>
    param([Parameter(Mandatory)][string]$Kind)
    $spec = @(Get-AppFolderKinds) | Where-Object { $_.Key -eq $Kind } | Select-Object -First 1
    if (-not $spec) { throw "Unknown app folder '$Kind' - see Get-AppFolderKinds." }
    return (Join-Path $Global:App.RootPath $spec.Default)
}

function Global:Get-AppFolder {
    <#
      Where a folder actually is: what was chosen for it, or its default.

      -Create makes it exist first, for callers about to write into it. A
      path that cannot be created falls back to the default rather than
      failing the thing the caller was doing - being unable to write a log
      into a share that has gone away should not stop a deployment.
    #>
    param([Parameter(Mandatory)][string]$Kind, [switch]$Create)
    $chosen = $null
    if ($Global:App.AppFolders -is [System.Collections.IDictionary] -and $Global:App.AppFolders.Contains($Kind)) {
        $chosen = [string]$Global:App.AppFolders[$Kind]
    }
    $path = if ([string]::IsNullOrWhiteSpace($chosen)) { Get-AppFolderDefault -Kind $Kind } else { $chosen }
    if ($Create -and -not (Test-Path -LiteralPath $path)) {
        try { [void](New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop) }
        catch {
            $fallback = Get-AppFolderDefault -Kind $Kind
            if ($fallback -ne $path) {
                Write-Log "[WARN] Could not use the $Kind folder '$path' ($($_.Exception.Message)) - falling back to $fallback.`r`n" ([System.Drawing.Color]::Orange)
                $path = $fallback
                try { [void](New-Item -ItemType Directory -Path $path -Force -ErrorAction Stop) } catch { }
            }
        }
    }
    return $path
}

function Global:Set-AppFolder {
    <#
      Chooses a folder, or clears the choice when given nothing - a blank
      path means "use the default", which is how the Settings dialog's
      "Use default" works. Saving is the caller's job, so a dialog can
      offer Cancel.
    #>
    param([Parameter(Mandatory)][string]$Kind, [string]$Path)
    if (-not $Global:App.AppFolders -or $Global:App.AppFolders -isnot [System.Collections.IDictionary]) {
        $Global:App.AppFolders = @{}
    }
    [void](Get-AppFolderDefault -Kind $Kind)   # rejects an unknown kind before anything is stored
    if ([string]::IsNullOrWhiteSpace($Path)) { $Global:App.AppFolders.Remove($Kind) }
    else { $Global:App.AppFolders[$Kind] = $Path.Trim() }
}
