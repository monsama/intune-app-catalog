# Intune App Catalog & Deployment
# Copyright (C) 2026 Viktor Ljuca <https://monsama.ch>
# SPDX-License-Identifier: GPL-2.0-or-later

# What Diagnostics says about the catalog itself - no Graph, no window, so
# CatalogLogic.Tests.ps1 covers it. Each line is @{ Level; Text }, Level
# being ok, warn, failed or info; a list under a line is its Items.

function Global:Get-CatalogDiagnosticLines {
    <#
      -Apps: the catalog. -PackageFolders: the folders directly under the
      packages folder, as @{ Name; FullName } (empty when it doesn't exist).
    #>
    param($Apps, $PackageFolders = @())
    $apps = @($Apps | Where-Object { $_ })
    $lines = New-Object System.Collections.Generic.List[object]
    $add = {
        param([bool]$Fine, [string]$Bad, [string]$Text, $Items = @())
        $lines.Add([pscustomobject]@{ Level = $(if ($Fine) { 'ok' } else { $Bad }); Text = $Text; Items = @($Items) })
    }

    $nothing = @($apps | Where-Object { -not $_.appId -and -not $_.metadata })
    & $add ($nothing.Count -eq 0) 'warn' "$($nothing.Count) app(s) with no App ID and no settings yet (nothing to deploy)" @($nothing | ForEach-Object { $_.appName })

    $uncommon = @($apps | Where-Object { (Test-AppIsUncommon -App $_) -and -not $_.metadata })
    & $add ($uncommon.Count -eq 0) 'warn' "$($uncommon.Count) app(s) with their own package but no settings - they need a detection rule before they can be deployed" @($uncommon | ForEach-Object { $_.appName })

    $neverSynced = @($apps | Where-Object { $_.appId -and -not $_.intuneAppType })
    & $add ($neverSynced.Count -eq 0) 'info' "$($neverSynced.Count) deployed app(s) never read back from Intune (no type or version recorded) - Pull from Intune picks it up" @($neverSynced | ForEach-Object { $_.appName })

    $noGroups = @($apps | Where-Object { $_.appId -and @($_.requiredFor | Where-Object { $_ }).Count -eq 0 -and @($_.availableFor | Where-Object { $_ }).Count -eq 0 -and @($_.uninstallFor | Where-Object { $_ }).Count -eq 0 })
    & $add ($noGroups.Count -eq 0) 'warn' "$($noGroups.Count) deployed app(s) assigned to nobody" @($noGroups | ForEach-Object { $_.appName })

    $dupeNames = @($apps | Group-Object { (([string]$_.appName).Trim() -replace '\s+', ' ').ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
    & $add ($dupeNames.Count -eq 0) 'failed' "$($dupeNames.Count) app name(s) used more than once" @($dupeNames | ForEach-Object { "$($_.Group[0].appName) ($($_.Count) entries)" })

    $dupeIds = @($apps | Where-Object { $_.appId } | Group-Object { ([string]$_.appId).ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
    & $add ($dupeIds.Count -eq 0) 'failed' "$($dupeIds.Count) App ID(s) used by more than one app" @($dupeIds | ForEach-Object { "$($_.Name): $(@($_.Group | ForEach-Object { $_.appName }) -join ', ')" })

    # A package folder no app's name leads to, and no app points at on purpose:
    # a leftover from a renamed or removed app. Harmless, but invisible otherwise.
    $expected = @($apps | Where-Object { Test-AppIsUncommon -App $_ } | ForEach-Object { Get-SafeFileNameForApp -Name $_.appName })
    $claimed = @($apps | Where-Object { $_.packagePath } | ForEach-Object {
        $p = ([string]$_.packagePath).TrimEnd('\', '/')
        if ($p -match '\.intunewin$') { $p = $p -replace '[\\/][^\\/]*$', '' }
        $p.TrimEnd('\', '/').ToLowerInvariant()
    })
    $orphans = @($PackageFolders | Where-Object { $_ -and $expected -notcontains [string]$_.Name -and $claimed -notcontains ([string]$_.FullName).TrimEnd('\', '/').ToLowerInvariant() })
    & $add ($orphans.Count -eq 0) 'info' "$($orphans.Count) folder(s) in the packages folder that no app uses - leftovers from a renamed or removed app, safe to delete once checked" @($orphans | ForEach-Object { $_.Name })

    return $lines.ToArray()
}
