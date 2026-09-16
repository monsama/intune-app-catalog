function Global:Show-DiagnosticsDialog {
    # Plain local aliases - see note in Start-IntuneAppLookup. $certThumbRef
    # specifically fixes a real, confirmed-live bug: $btnRun.Add_Click below
    # is itself a .GetNewClosure()'d scriptblock, and reading
    # $Global:App.GraphCertificateThumbprint DIRECTLY from inside it (as this
    # used to) returned a stale/blank value even though the real, current
    # thumbprint was genuinely set - while Test-GraphCredentialsConfigured,
    # a real FUNCTION called from that same closure, correctly saw the live
    # value (functions always resolve $Script: fresh; a closure's direct
    # $Script: reads don't). That mismatch is exactly what produced the
    # impossible-looking "[OK] ... all set" immediately followed by
    # "[WARN] Certificate: No thumbprint set." - not a whitespace issue at
    # all, confirmed by an actual user's live DEBUG output showing
    # Test-GraphCredentialsConfigured() correctly returning true while a
    # direct $Script: read of the same variable, from the same closure, at
    # the same instant, read back empty.
    $appsRef = $Global:App.Apps
    $certThumbRef = $Global:App.GraphCertificateThumbprint

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Diagnostics"
    $dlg.ClientSize = New-Object System.Drawing.Size(700, 560)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false

    $lblIntro = New-Object System.Windows.Forms.Label
    $lblIntro.Text = "Read-only health check - no changes to Intune, Entra ID, or the local catalog. Checks Graph connectivity, certificate expiry, group permissions, catalog completeness (duplicate App IDs, orphaned package folders), and drift against what's actually in Intune."
    $lblIntro.Location = New-Object System.Drawing.Point(15,12)
    $lblIntro.Size = New-Object System.Drawing.Size(670,48)
    $dlg.Controls.Add($lblIntro)

    $rtbLog = New-Object System.Windows.Forms.RichTextBox
    $rtbLog.Location = New-Object System.Drawing.Point(15,66)
    $rtbLog.Size = New-Object System.Drawing.Size(670,436)
    Initialize-DarkLogBox -LogBox $rtbLog
    $dlg.Controls.Add($rtbLog)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Location = New-Object System.Drawing.Point(15,510)
    $lblStatus.Size = New-Object System.Drawing.Size(430,24)
    $lblStatus.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblStatus)

    $btnRun = New-Object System.Windows.Forms.Button
    $btnRun.Text = "Run diagnostics"
    $btnRun.Location = New-Object System.Drawing.Point(455,506)
    $btnRun.Size = New-Object System.Drawing.Size(140,32)
    $dlg.Controls.Add($btnRun)

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"
    $btnClose.Location = New-Object System.Drawing.Point(605,506)
    $btnClose.Size = New-Object System.Drawing.Size(80,32)
    $dlg.Controls.Add($btnClose)

    $okColor = [System.Drawing.Color]::LightGreen
    $warnColor = [System.Drawing.Color]::Orange
    $failColor = [System.Drawing.Color]::Tomato
    $infoColor = [System.Drawing.Color]::Gainsboro
    $headerColor = [System.Drawing.Color]::DeepSkyBlue

    $appendLine = {
        param($Text, $Color)
        $rtbLog.SelectionStart = $rtbLog.TextLength
        $rtbLog.SelectionLength = 0
        $rtbLog.SelectionColor = $Color
        $rtbLog.AppendText("$Text`r`n")
        $rtbLog.ScrollToCaret()
    }.GetNewClosure()

    # Mirrors $minOsRawValues inside Show-CreateInIntuneDialog - not a
    # shared reference to it (that list is local to that function,
    # deliberately, same as every other detection/operator map in this
    # app), so this is a second copy by necessity. Kept in sync manually;
    # if that list ever changes, update this one too. This is exactly the
    # class of drift the Min OS dropdown fix elsewhere this session was
    # about, so a live app using something outside this list is a real,
    # previously-silent finding, not a false positive.
    $knownMinOsValues = @("W10_1607", "W10_1703", "W10_1709", "W10_1803", "W10_1809", "W10_1903", "W10_1909", "W10_2004", "W10_20H2", "W10_21H1", "W10_21H2", "W10_22H2", "W11_21H2", "W11_22H2")

    $btnRun.Add_Click({
        $btnRun.Enabled = $false
        $btnClose.Enabled = $false
        $rtbLog.Clear()
        $lblStatus.Text = "Running... (Close is disabled until this finishes)"
        $lblStatus.ForeColor = [System.Drawing.Color]::DimGray

        & $appendLine "=== Configuration ===" $headerColor
        $moduleOk = [bool](Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)
        & $appendLine "$(if ($moduleOk) { '[OK]' } else { '[FAILED]' }) Microsoft.Graph.Authentication module installed" $(if ($moduleOk) { $okColor } else { $failColor })

        $credsOk = Test-GraphCredentialsConfigured
        & $appendLine "$(if ($credsOk) { '[OK]' } else { '[FAILED]' }) Tenant ID / Client ID / Certificate thumbprint all set" $(if ($credsOk) { $okColor } else { $failColor })

        if ($credsOk) {
            $certStatus = Get-CertificateStatusText -Thumbprint $certThumbRef
            $certOk = $certStatus.Color -eq [System.Drawing.Color]::SeaGreen
            $certWarn = $certStatus.Color -eq [System.Drawing.Color]::DarkOrange
            $certTag = if ($certOk) { "[OK]" } elseif ($certWarn) { "[WARN]" } else { "[FAILED]" }
            & $appendLine "$certTag Certificate: $($certStatus.Text)" $(if ($certOk) { $okColor } elseif ($certWarn) { $warnColor } else { $failColor })
        }

        & $appendLine "" $infoColor
        & $appendLine "=== Catalog completeness ($($appsRef.Count) app(s)) ===" $headerColor

        $noAppIdNoMetadata = @($appsRef | Where-Object { -not $_.appId -and -not $_.metadata })
        & $appendLine "$(if ($noAppIdNoMetadata.Count -eq 0) { '[OK]' } else { '[WARN]' }) $($noAppIdNoMetadata.Count) app(s) with no App ID and no saved metadata (nothing to deploy yet)" $(if ($noAppIdNoMetadata.Count -eq 0) { $okColor } else { $warnColor })
        foreach ($a in $noAppIdNoMetadata) { & $appendLine "    - $($a.appName)" $infoColor }

        $uncommonUnconfigured = @($appsRef | Where-Object { (Test-AppIsUncommon -App $_) -and -not $_.metadata })
        & $appendLine "$(if ($uncommonUnconfigured.Count -eq 0) { '[OK]' } else { '[WARN]' }) $($uncommonUnconfigured.Count) uncommon app(s) (no Winget ID) with no saved metadata - can't be deployed or defaulted as-is" $(if ($uncommonUnconfigured.Count -eq 0) { $okColor } else { $warnColor })
        foreach ($a in $uncommonUnconfigured) { & $appendLine "    - $($a.appName)" $infoColor }

        $neverSynced = @($appsRef | Where-Object { $_.appId -and -not $_.intuneAppType })
        & $appendLine "$(if ($neverSynced.Count -eq 0) { '[OK]' } else { '[INFO]' }) $($neverSynced.Count) deployed app(s) never synced (no Type/Version recorded) - run `"Pull metadata and groups from Intune...`" to pick this up" $(if ($neverSynced.Count -eq 0) { $okColor } else { $infoColor })

        $noGroups = @($appsRef | Where-Object { $_.appId -and @($_.requiredFor).Count -eq 0 -and @($_.availableFor).Count -eq 0 -and @($_.uninstallFor).Count -eq 0 })
        & $appendLine "$(if ($noGroups.Count -eq 0) { '[OK]' } else { '[WARN]' }) $($noGroups.Count) deployed app(s) with no group assignments at all (assigned to nobody)" $(if ($noGroups.Count -eq 0) { $okColor } else { $warnColor })
        foreach ($a in $noGroups) { & $appendLine "    - $($a.appName)" $infoColor }

        $dupeNames = @($appsRef | Group-Object { ($_.appName.Trim() -replace '\s+', ' ').ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })
        & $appendLine "$(if ($dupeNames.Count -eq 0) { '[OK]' } else { '[FAILED]' }) $($dupeNames.Count) duplicate app name(s) in the catalog" $(if ($dupeNames.Count -eq 0) { $okColor } else { $failColor })
        foreach ($d in $dupeNames) { & $appendLine "    - $($d.Name) ($($d.Count) entries)" $infoColor }

        $dupeAppIds = @($appsRef | Where-Object { $_.appId } | Group-Object { [string]$_.appId } | Where-Object { $_.Count -gt 1 })
        & $appendLine "$(if ($dupeAppIds.Count -eq 0) { '[OK]' } else { '[FAILED]' }) $($dupeAppIds.Count) duplicate App ID(s) - more than one catalog entry pointing at the same Intune app" $(if ($dupeAppIds.Count -eq 0) { $okColor } else { $failColor })
        foreach ($d in $dupeAppIds) { & $appendLine "    - $($d.Name): $(($d.Group | ForEach-Object { $_.appName }) -join ', ')" $infoColor }

        # Local-only, no network needed - a folder under app-packages that
        # doesn't match any current uncommon app's safe name (Get-SafeFileNameForApp)
        # is either a leftover from a renamed/removed app or build output that
        # never got cleaned up. Not necessarily a problem (Resolve-AppPackagePath
        # only ever looks for folders it DOES expect), just worth surfacing since
        # it's otherwise invisible from inside the app.
        $uncommonRootPath = Join-Path $Global:App.RootPath "data\app-packages"
        $expectedSafeNames = @($appsRef | Where-Object { Test-AppIsUncommon -App $_ } | ForEach-Object { Get-SafeFileNameForApp -Name $_.appName })
        $orphanFolders = @()
        if (Test-Path $uncommonRootPath) {
            $orphanFolders = @(Get-ChildItem -Path $uncommonRootPath -Directory -ErrorAction SilentlyContinue | Where-Object { $expectedSafeNames -notcontains $_.Name })
        }
        & $appendLine "$(if ($orphanFolders.Count -eq 0) { '[OK]' } else { '[INFO]' }) $($orphanFolders.Count) folder(s) under app-packages with no matching catalog entry" $(if ($orphanFolders.Count -eq 0) { $okColor } else { $infoColor })
        foreach ($f in $orphanFolders) { & $appendLine "    - $($f.Name)" $infoColor }

        if (-not $credsOk) {
            & $appendLine "" $infoColor
            & $appendLine "=== Live checks against Intune ===" $headerColor
            & $appendLine "[SKIPPED] Graph credentials aren't configured - see Settings..." $warnColor
            $btnRun.Enabled = $true
            $btnClose.Enabled = $true
            $lblStatus.Text = "Done."
            $lblStatus.ForeColor = [System.Drawing.Color]::SeaGreen
            return
        }

        & $appendLine "" $infoColor
        & $appendLine "=== Live checks against Intune ===" $headerColor
        & $appendLine "Connecting and fetching every app from Intune..." $infoColor
        $lblStatus.Text = "Connecting to Intune..."
        # Start-IntuneAppLookup/Start-Win32AppMinOsFetch/Start-EntraDirectoryLookup
        # each set $Global:App.Form.Cursor themselves, but that's the MAIN
        # window, which sits behind this modal dialog the whole time these
        # three chained fetches run - setting its cursor has no visible
        # effect here. Set/reset THIS dialog's own cursor instead, same
        # fix already applied to Show-CreateInIntuneDialog and Show-AppEditor.
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Fresh aliases for the nested -OnComplete closure - see note at the
        # top of Show-CreateInIntuneDialog for why this matters here too.
        $dlgRef = $dlg
        $appsRefRef = $appsRef
        $appendLineRef = $appendLine
        $knownMinOsValuesRef = $knownMinOsValues
        $btnRunRef = $btnRun
        $btnCloseRef = $btnClose
        $lblStatusRef = $lblStatus
        $okColorRef = $okColor
        $warnColorRef = $warnColor
        $failColorRef = $failColor
        $infoColorRef = $infoColor
        $headerColorRef = $headerColor

        Start-IntuneAppLookup -OnComplete {
            param($ok, $data)
            if (-not $ok) {
                & $appendLineRef "[FAILED] Could not connect to Intune: $data" $failColorRef
                $btnRunRef.Enabled = $true
                $btnCloseRef.Enabled = $true
                $lblStatusRef.Text = "Done - live checks failed."
                $lblStatusRef.ForeColor = $warnColorRef
                $dlgRef.Cursor = [System.Windows.Forms.Cursors]::Default
                [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
                [System.Windows.Forms.Application]::DoEvents()
                [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
                return
            }
            & $appendLineRef "[OK] Connected - $($data.Count) app(s) currently in Intune." $okColorRef

            $intuneById = @{}
            foreach ($ia in @($data)) { $intuneById[[string]$ia.id] = $ia }

            $deployedApps = @($appsRefRef | Where-Object { $_.appId })
            $deletedFromIntune = @($deployedApps | Where-Object { -not $intuneById.ContainsKey([string]$_.appId) })
            & $appendLineRef "$(if ($deletedFromIntune.Count -eq 0) { '[OK]' } else { '[FAILED]' }) $($deletedFromIntune.Count) catalog app(s) whose App ID no longer exists in Intune" $(if ($deletedFromIntune.Count -eq 0) { $okColorRef } else { $failColorRef })
            foreach ($a in $deletedFromIntune) { & $appendLineRef "    - $($a.appName) (App ID $($a.appId))" $infoColorRef }

            $renamed = @($deployedApps | Where-Object { $intuneById.ContainsKey([string]$_.appId) -and $intuneById[[string]$_.appId].displayName -ne $_.appName })
            & $appendLineRef "$(if ($renamed.Count -eq 0) { '[OK]' } else { '[WARN]' }) $($renamed.Count) catalog app(s) whose name doesn't match Intune's current name" $(if ($renamed.Count -eq 0) { $okColorRef } else { $warnColorRef })
            foreach ($a in $renamed) { & $appendLineRef "    - catalog: `"$($a.appName)`" / Intune: `"$($intuneById[[string]$a.appId].displayName)`"" $infoColorRef }

            $catalogAppIds = @($appsRefRef | ForEach-Object { [string]$_.appId } | Where-Object { $_ })
            $notInCatalogCount = @($data | Where-Object { $catalogAppIds -notcontains [string]$_.id }).Count
            & $appendLineRef "$(if ($notInCatalogCount -eq 0) { '[OK]' } else { '[INFO]' }) $notInCatalogCount app(s) in Intune with no matching catalog entry - see `"Intune sync check...`"" $(if ($notInCatalogCount -eq 0) { $okColorRef } else { $infoColorRef })

            & $appendLineRef "Fetching Minimum Windows values for deployed Win32 apps..." $infoColorRef

            # Fresh aliases for this second nested -OnComplete closure - see
            # note at the top of Show-CreateInIntuneDialog.
            $deployedAppsRef = $deployedApps
            $appendLineRef2 = $appendLineRef
            $knownMinOsValuesRef2 = $knownMinOsValuesRef
            $dlgRef2 = $dlgRef
            $btnRunRef2 = $btnRunRef
            $btnCloseRef2 = $btnCloseRef
            $lblStatusRef2 = $lblStatusRef
            $okColorRef2 = $okColorRef
            $warnColorRef2 = $warnColorRef
            $infoColorRef2 = $infoColorRef
            $headerColorRef2 = $headerColorRef

            Start-Win32AppMinOsFetch -OnComplete {
                param($minOsOk, $minOsData)
                if (-not $minOsOk) {
                    & $appendLineRef2 "[FAILED] Could not fetch Minimum Windows values: $minOsData" $warnColorRef2
                }
                else {
                    $minOsById = @{}
                    foreach ($m in @($minOsData)) { $minOsById[[string]$m.id] = $m }

                    # Show-CreateInIntuneDialog now reads/writes
                    # minimumSupportedWindowsRelease (see the note next to
                    # $Global:App.EmbeddedCreateAppScript's own $patchBody
                    # assignment for why) - a value here that doesn't parse
                    # to one of $knownMinOsValues is a genuine finding: the
                    # dropdown has no matching option for it (most likely a
                    # Windows release newer than this list knows about).
                    $minOsUnrecognized = @($deployedAppsRef | Where-Object {
                        if (-not $minOsById.ContainsKey([string]$_.appId)) { return $false }
                        $rawVal = $minOsById[[string]$_.appId].minimumSupportedWindowsRelease
                        if (-not $rawVal) { return $false }
                        $parsedVal = Get-ParsedMinOsRelease -RawValue $rawVal
                        -not (@($knownMinOsValuesRef2) | Where-Object {
                            $knownParsed = Get-ParsedMinOsRelease -RawValue $_
                            $knownParsed.Major -eq $parsedVal.Major -and $knownParsed.Release -eq $parsedVal.Release
                        })
                    })
                    & $appendLineRef2 "$(if ($minOsUnrecognized.Count -eq 0) { '[OK]' } else { '[WARN]' }) $($minOsUnrecognized.Count) app(s) with a Minimum Windows value this tool's own dropdown doesn't offer" $(if ($minOsUnrecognized.Count -eq 0) { $okColorRef2 } else { $warnColorRef2 })
                    foreach ($a in $minOsUnrecognized) { & $appendLineRef2 "    - $($a.appName): $(Get-FriendlyMinOsRelease -RawValue $minOsById[[string]$a.appId].minimumSupportedWindowsRelease)" $infoColorRef2 }

                    # Never had the new property set at all - only the
                    # legacy one (not touched since before Microsoft's
                    # switch). Informational, not a defect: opening
                    # "Intune Deployment" for one of these pre-selects the
                    # dropdown from the legacy value as a convenience, and
                    # the next save sets the current property.
                    $minOsLegacyOnly = @($deployedAppsRef | Where-Object {
                        $minOsById.ContainsKey([string]$_.appId) -and
                        -not $minOsById[[string]$_.appId].minimumSupportedWindowsRelease -and
                        $minOsById[[string]$_.appId].minOSPropertyName
                    })
                    & $appendLineRef2 "$(if ($minOsLegacyOnly.Count -eq 0) { '[OK]' } else { '[INFO]' }) $($minOsLegacyOnly.Count) app(s) still only have the OLDER Minimum Windows property set - will be updated to the current one next time they're saved" $(if ($minOsLegacyOnly.Count -eq 0) { $okColorRef2 } else { $infoColorRef2 })
                    foreach ($a in $minOsLegacyOnly) { & $appendLineRef2 "    - $($a.appName): $($minOsById[[string]$a.appId].minOSPropertyName)" $infoColorRef2 }
                }

                & $appendLineRef2 "Checking Entra ID group/user read permissions (needed for group assignment)..." $infoColorRef2

                # Fresh aliases for this third nested -OnComplete closure -
                # see note at the top of Show-CreateInIntuneDialog.
                $appendLineRef3 = $appendLineRef2
                $okColorRef3    = $okColorRef2
                $warnColorRef3  = $warnColorRef2
                $failColorRef3  = $failColorRef2
                $infoColorRef3  = $infoColorRef2
                $headerColorRef3 = $headerColorRef2
                $dlgRef3        = $dlgRef2
                $btnRunRef3     = $btnRunRef2
                $btnCloseRef3   = $btnCloseRef2
                $lblStatusRef3  = $lblStatusRef2

                Start-EntraDirectoryLookup -OnComplete {
                    param($groupsOk, $groupsData)
                    if ($groupsOk) {
                        & $appendLineRef3 "[OK] App registration can read Entra ID groups and users" $okColorRef3
                    }
                    else {
                        # Distinguish an actual permissions problem (the app
                        # registration lacks Group.Read.All / User.Read.All)
                        # from a generic connectivity hiccup - the fix for
                        # one is "grant the API permission in Entra ID", the
                        # fix for the other is unrelated, so lumping them
                        # into one generic failure would send the user down
                        # the wrong path.
                        $errText = [string]$groupsData
                        $isPermissionError = $errText -match 'Forbidden|Authorization_RequestDenied|403|Insufficient privileges'
                        if ($isPermissionError) {
                            & $appendLineRef3 "[FAILED] App registration is missing Graph permission to read groups/users (Group.Read.All / User.Read.All) - group assignment will fail" $failColorRef3
                        }
                        else {
                            & $appendLineRef3 "[WARN] Could not verify group/user read permissions: $errText" $warnColorRef3
                        }
                    }

                    & $appendLineRef3 "" $infoColorRef3
                    & $appendLineRef3 "=== Done ===" $headerColorRef3

                    $btnRunRef3.Enabled = $true
                    $btnCloseRef3.Enabled = $true
                    $lblStatusRef3.Text = "Done."
                    $lblStatusRef3.ForeColor = $okColorRef3
                    $dlgRef3.Cursor = [System.Windows.Forms.Cursors]::Default
                    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
                    [System.Windows.Forms.Application]::DoEvents()
                    [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
                }.GetNewClosure()
            }.GetNewClosure()
        }.GetNewClosure()
    }.GetNewClosure())

    $btnClose.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.CancelButton = $btnClose

    # Backstop for the window's own X button / Alt+F4 - $btnClose.Enabled
    # already being $false blocks the button itself while a run is in
    # progress, but neither the titlebar X nor Alt+F4 go through it at all.
    $dlg.Add_FormClosing({
        param($s, $e)
        if (-not $btnRun.Enabled) { $e.Cancel = $true }
    }.GetNewClosure())

    $dlg.Add_Shown({ $btnRun.PerformClick() }.GetNewClosure())

    Set-Theme -Control $dlg
    [void]$dlg.ShowDialog($Global:App.Form)
}
