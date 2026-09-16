function Global:Start-WingetSearch {
    param([string]$Query, [scriptblock]$OnComplete)

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($SearchQuery)

        $wingetCmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if (-not $wingetCmd) {
            throw "winget.exe not found on this machine. It ships with the 'App Installer' package on modern Windows 10/11 - make sure it's installed and in PATH."
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $wingetCmd.Source
        $psi.Arguments = "search `"$SearchQuery`" --accept-source-agreements --disable-interactivity"
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8

        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()

        # Kick off BOTH stream reads concurrently, in the background, before
        # waiting on the process at all. Reading stdout and stderr
        # sequentially (ReadToEnd on one, then the other) is a well-known
        # .NET deadlock: if winget writes enough to stderr to fill the OS
        # pipe buffer while we're still blocked reading stdout, winget
        # itself blocks trying to write - and neither side can ever
        # proceed. That made the 30s timeout below unreachable, since we'd
        # already be stuck on the ReadToEnd call before ever getting to it -
        # which is exactly why search could hang indefinitely with no
        # timeout ever kicking in.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit(30000)) {
            try { $proc.Kill() } catch { }
            throw "winget search timed out after 30 seconds."
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()

        if ($proc.ExitCode -ne 0 -and -not $stdout) {
            throw "winget search failed (exit code $($proc.ExitCode)): $stderr"
        }

        # winget's default output is a human-readable table sized to its
        # content, not fixed-width columns - so locate each column by where
        # its header text starts, then slice every data row at those same
        # character offsets. This is the standard, well-established approach
        # for parsing this output; it can still be thrown off by unusual
        # package names/locales, since winget doesn't offer a machine
        # readable format for search specifically.
        $lines = $stdout -split "`r?`n" | Where-Object { $_.TrimEnd() -ne "" }
        $headerIdx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^Name\s+Id\s+Version') { $headerIdx = $i; break }
        }
        if ($headerIdx -eq -1) {
            return ,@()   # "No package found..." or similar - just no results, not an error
        }

        $header = $lines[$headerIdx]
        $idPos      = $header.IndexOf("Id")
        $versionPos = $header.IndexOf("Version")
        $matchPos   = $header.IndexOf("Match")
        $sourcePos  = $header.IndexOf("Source")

        $results = New-Object System.Collections.Generic.List[object]
        for ($i = $headerIdx + 2; $i -lt $lines.Count; $i++) {
            $line = $lines[$i]
            if ($line.Length -lt $idPos) { continue }

            $name = $line.Substring(0, $idPos).Trim()
            $idEnd = if ($versionPos -gt $idPos -and $versionPos -le $line.Length) { $versionPos } else { $line.Length }
            $id = $line.Substring($idPos, [Math]::Max(0, $idEnd - $idPos)).Trim()

            $versionEnd =
                if ($matchPos -gt $versionPos -and $matchPos -le $line.Length) { $matchPos }
                elseif ($sourcePos -gt $versionPos -and $sourcePos -le $line.Length) { $sourcePos }
                else { $line.Length }
            $version = if ($versionPos -ge 0 -and $versionPos -lt $line.Length) { $line.Substring($versionPos, [Math]::Max(0, $versionEnd - $versionPos)).Trim() } else { "" }

            $source = if ($sourcePos -ge 0 -and $sourcePos -lt $line.Length) { $line.Substring($sourcePos).Trim() } else { "" }

            if ($name -and $id) {
                $results.Add([pscustomobject]@{ Name = $name; Id = $id; Version = $version; Source = $source })
            }
        }
        return ,$results.ToArray()
    }).AddArgument($Query)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $timer.Dispose()

        try {
            $raw = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) {
                $errMsg = Get-GraphRunspaceErrorMessage $ps.Streams.Error
                if ($OnComplete) { & $OnComplete $false $errMsg }
            }
            else {
                $results = if ($raw.Count -gt 0) { $raw[0] } else { @() }
                if ($OnComplete) { & $OnComplete $true $results }
            }
        }
        catch {
            if ($OnComplete) { & $OnComplete $false $_.Exception.Message }
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}

function Global:Start-IntuneAppLookup {
    param([scriptblock]$OnComplete)

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The Microsoft.Graph.Authentication module isn't installed.`n`nInstall it with:`nInstall-Module Microsoft.Graph.Authentication -Scope CurrentUser",
            "Module missing", "OK", "Warning") | Out-Null
        if ($OnComplete) { & $OnComplete $false "Module missing" }
        return
    }

    if (-not (Test-GraphCredentialsConfigured)) {
        if ($OnComplete) { & $OnComplete $false "Not configured" }
        return
    }

    if (-not $Global:App.BtnLookupIds.Enabled) {
        Write-Log "A lookup is already running - please wait for it to finish.`r`n" ([System.Drawing.Color]::Orange)
        return
    }

    $Global:App.BtnLookupIds.Enabled = $false
    Write-Log "=== Looking up app IDs from Intune (Microsoft Graph, app-only via certificate) ===`r`n" ([System.Drawing.Color]::DeepSkyBlue)
    $Global:App.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    # Plain (non-$Script:) local alias - closures reliably capture plain variables via
    # GetNewClosure(), but do NOT reliably see live $Script: state from inside the closure.
    # $Global:App.IntuneAppsCache is an ArrayList (reference type) so mutating it through this
    # alias is visible everywhere else that reads $Global:App.IntuneAppsCache normally.
    $cache = $Global:App.IntuneAppsCache

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($TenantId, $ClientId, $CertThumb)
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $ClientId) {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
        }
        $ctx = Get-MgContext -ErrorAction Stop

        $apps = New-Object System.Collections.Generic.List[object]
        $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$top=999"
        do {
            $result = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
            foreach ($item in $result.value) {
                $apps.Add([pscustomobject]@{ id = $item.id; displayName = $item.displayName })
            }
            $uri = $result.'@odata.nextLink'
        } while ($uri)

        [pscustomobject]@{
            Apps     = $apps.ToArray()
            AuthType = $ctx.AuthType
            AppName  = $ctx.AppName
            ClientId = $ctx.ClientId
            TenantId = $ctx.TenantId
        }
    }).AddArgument($Global:App.GraphTenantId).AddArgument($Global:App.GraphClientId).AddArgument($Global:App.GraphCertificateThumbprint)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $timer.Dispose()
        $Global:App.Form.Cursor = [System.Windows.Forms.Cursors]::Default
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
        # See the same pattern's note in Show-WingetSearchDialog - forces
        # an immediate cursor repaint instead of waiting on a mouse move.
        [System.Windows.Forms.Application]::DoEvents()
        [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position
        $Global:App.BtnLookupIds.Enabled = $true

        try {
            $raw = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) {
                $errMsg = Get-GraphRunspaceErrorMessage $ps.Streams.Error
                Write-Log "[FAILED] $errMsg`r`n" ([System.Drawing.Color]::Tomato)
                if ($OnComplete) { & $OnComplete $false $errMsg }
            }
            elseif ($raw.Count -eq 0) {
                Write-Log "[FAILED] No response came back from the lookup runspace.`r`n" ([System.Drawing.Color]::Tomato)
                if ($OnComplete) { & $OnComplete $false "No response from lookup" }
            }
            else {
                $info = $raw[0]
                $cache.Clear()
                foreach ($a in @($info.Apps)) { [void]$cache.Add($a) }
                Write-Log "Connected app-only as '$($info.AppName)' (client $($info.ClientId), tenant $($info.TenantId)).`r`n" ([System.Drawing.Color]::Gainsboro)
                Write-Log "Cache now holds $($cache.Count) app(s).`r`n" ([System.Drawing.Color]::Gainsboro)
                if ($cache.Count -eq 0) {
                    Write-Log "[WARN] Graph returned 0 apps from /deviceAppManagement/mobileApps.`r`n" ([System.Drawing.Color]::Orange)
                    Write-Log "[WARN] Check that this app registration's APPLICATION permission 'DeviceManagementApps.Read.All' (or ReadWrite.All) has admin consent - Delegated permissions used by interactive sign-in scripts do not carry over to app-only auth.`r`n" ([System.Drawing.Color]::Orange)
                }
                else {
                    Write-Log "[OK] Fetched $($cache.Count) apps from Intune. Names returned:`r`n" ([System.Drawing.Color]::LightGreen)
                    foreach ($n in ($cache | Sort-Object displayName | ForEach-Object { $_.displayName })) {
                        Write-Log "    - $n`r`n" ([System.Drawing.Color]::Gainsboro)
                    }
                }
                if ($OnComplete) { & $OnComplete $true $cache }
            }
        }
        catch {
            Write-Log "[FAILED] $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Tomato)
            if ($OnComplete) { & $OnComplete $false $_.Exception.Message }
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}

function Global:Start-StartupDriftCheck {
    # Opt-in (Settings' "Check for Intune drift when the app starts"),
    # off by default - see $Global:App.CheckDriftOnStartup's own comment
    # in MainApp.ps1 for why. Called once from Form.Add_Shown, after the
    # main window is already visible, so this never delays getting into
    # the app even on a slow connection.
    if (-not $Global:App.CheckDriftOnStartup) { return }

    # Same whitespace-aware check Update-CredentialWarningBanner uses, not
    # Test-GraphCredentialsConfigured directly - that one pops a blocking
    # MessageBox on failure, which a silent background startup check must
    # never do. Not configured yet just means nothing to check.
    if ([string]::IsNullOrWhiteSpace($Global:App.GraphTenantId) -or
        [string]::IsNullOrWhiteSpace($Global:App.GraphClientId) -or
        [string]::IsNullOrWhiteSpace($Global:App.GraphCertificateThumbprint)) {
        return
    }

    # Visible feedback that this is actually happening - otherwise the
    # only sign anything is running at all is a brief busy cursor (easy to
    # miss) and a line in the Log tab, which isn't the default active tab.
    # Neutral gray while in flight, not the banner's usual warning color -
    # this state isn't a problem, just "still working."
    $Global:App.LblDriftWarning.ForeColor = [System.Drawing.Color]::DimGray
    $Global:App.LblDriftWarning.Text = "Checking for Intune drift..."
    $Global:App.PanelDriftWarning.Visible = $true
    Update-StartupBusyIndicator -Delta 1

    # Reuses the exact same fetch (and $Global:App.IntuneAppsCache) as the
    # toolbar's own "Look up App IDs..." and Show-IntuneOnlyAppsDialog's
    # Refresh - no separate code path to keep in sync, just a different,
    # quiet caller. -OnComplete here runs on the main UI thread (this
    # function's own Timer.Add_Tick, not the background runspace), so
    # touching the banner's controls directly below is safe.
    Start-IntuneAppLookup -OnComplete {
        param($ok, $data)
        Update-StartupBusyIndicator -Delta -1
        if (-not $ok) {
            # Already logged in detail by Start-IntuneAppLookup itself -
            # this just clears the "Checking..." state so it doesn't sit
            # there forever looking like nothing ever happened.
            $Global:App.PanelDriftWarning.Visible = $false
            return
        }
        $drift = Get-IntuneCatalogDrift -Apps $Global:App.Apps -IntuneApps $data
        $total = $drift.Missing.Count + $drift.Renamed.Count + $drift.DeletedFromIntune.Count
        if ($total -eq 0) {
            $Global:App.PanelDriftWarning.Visible = $false
            return
        }
        $Global:App.LblDriftWarning.ForeColor = [System.Drawing.Color]::FromArgb(133, 100, 4)
        $Global:App.LblDriftWarning.Text = "Startup check found $total discrepanc$(if ($total -eq 1) { 'y' } else { 'ies' }) between Intune and this catalog: $($drift.Missing.Count) not in catalog, $($drift.Renamed.Count) renamed, $($drift.DeletedFromIntune.Count) deleted from Intune."
        $Global:App.PanelDriftWarning.Visible = $true
    }.GetNewClosure()
}

function Global:Start-StartupFullAuditCheck {
    # Opt-in (toolbar's "Also run full audit (slower)"), off by default,
    # independent of Start-StartupDriftCheck above - see
    # $Global:App.RunFullAuditOnStartup's own comment in MainApp.ps1 for
    # why this is a separate toggle: a full metadata fetch PER deployed
    # app, not one list call for the whole catalog. Headless version of
    # Show-IntuneAuditDialog's own two-fetch logic (Metadata/Groups/
    # Dependencies, then Unknown Assignments) - same embedded scripts,
    # same comparison functions, same LastAuditResults cache, just
    # accumulating counts for the banner below instead of grid rows, so
    # opening "Intune Audit..." afterward still shows fresh cached
    # results without needing its own re-run.
    if (-not $Global:App.RunFullAuditOnStartup) { return }

    if ([string]::IsNullOrWhiteSpace($Global:App.GraphTenantId) -or
        [string]::IsNullOrWhiteSpace($Global:App.GraphClientId) -or
        [string]::IsNullOrWhiteSpace($Global:App.GraphCertificateThumbprint)) {
        return
    }

    $deployedApps = @($Global:App.Apps | Where-Object { $_.appId })
    if ($deployedApps.Count -eq 0) { return }

    $appByName = @{}
    foreach ($a in $deployedApps) { $appByName[$a.appName] = $a }

    $Global:App.LblAuditWarning.ForeColor = [System.Drawing.Color]::DimGray
    $Global:App.LblAuditWarning.Text = "Running full Intune audit on $($deployedApps.Count) app(s)..."
    $Global:App.PanelAuditWarning.Visible = $true
    Update-StartupBusyIndicator -Delta 1

    $tenantId  = $Global:App.GraphTenantId
    $clientId  = $Global:App.GraphClientId
    $certThumb = $Global:App.GraphCertificateThumbprint
    $syncScript  = $Global:App.EmbeddedSyncMetadataScript
    $batchScript = $Global:App.EmbeddedBatchAssignScript

    # Same "how many app(s) have a difference in ANY category" tally
    # Show-IntuneAuditDialog's own grid would let you eyeball at a glance
    # (a row with anything other than "OK" in any column) - a HashSet
    # since one app can show up from both fetches below, and should only
    # count once toward the total no matter how many of its own
    # categories differ.
    $appsWithFindings = New-Object System.Collections.Generic.HashSet[string]
    $pendingBox = @{ Count = 2 }

    $finishOne = {
        $pendingBox.Count--
        if ($pendingBox.Count -gt 0) { return }
        Update-StartupBusyIndicator -Delta -1
        Save-LastAuditCache
        if ($appsWithFindings.Count -eq 0) {
            $Global:App.PanelAuditWarning.Visible = $false
            return
        }
        $Global:App.LblAuditWarning.ForeColor = [System.Drawing.Color]::FromArgb(133, 100, 4)
        $Global:App.LblAuditWarning.Text = "Full audit found $($appsWithFindings.Count) app(s) with at least one discrepancy (Metadata/Groups/Dependencies/Assignments) against Intune."
        $Global:App.PanelAuditWarning.Visible = $true
    }.GetNewClosure()

    # --- Fetch 1: Metadata + Groups + Dependencies, one pass ---
    $configApps1 = New-Object System.Collections.Generic.List[object]
    foreach ($a in $deployedApps) { $configApps1.Add([pscustomobject]@{ AppName = $a.appName; AppId = $a.appId }) }
    $configPath1 = Join-Path $env:TEMP (".intunepkg_startupaudit_sync_config_" + [guid]::NewGuid().ToString("N") + ".json")
    $resultPath1 = Join-Path $env:TEMP (".intunepkg_startupaudit_sync_result_" + [guid]::NewGuid().ToString("N") + ".json")
    $config1 = [pscustomobject]@{
        TenantId              = $tenantId
        ClientId              = $clientId
        CertificateThumbprint = $certThumb
        Apps                  = $configApps1.ToArray()
        OutputResultPath      = $resultPath1
    }
    try {
        $configJsonText1 = $config1 | ConvertTo-Json -Depth 10 -ErrorAction Stop
        [System.IO.File]::WriteAllText($configPath1, $configJsonText1, (New-Object System.Text.UTF8Encoding($false)))
        [void](Start-PipelineProcess -ScriptContent $syncScript -TempScriptName ".intunepkg_embedded_startupaudit_sync.ps1" -ArgumentString "-ConfigPath `"$configPath1`"" -OnComplete {
            param($code)
            Remove-Item $configPath1 -Force -ErrorAction SilentlyContinue
            if (Test-Path $resultPath1) {
                try {
                    $result1 = Get-Content -Path $resultPath1 -Raw | ConvertFrom-Json
                    Remove-Item $resultPath1 -Force -ErrorAction SilentlyContinue
                    if ($result1.success) {
                        foreach ($oneResult in @($result1.results)) {
                            if (-not $appByName.ContainsKey($oneResult.AppName)) { continue }
                            $catalogApp = $appByName[$oneResult.AppName]
                            if (-not $oneResult.Success) {
                                Set-LastAuditCacheEntry -AppName $oneResult.AppName -Metadata "Failed: $($oneResult.Error)" -Groups "Failed: $($oneResult.Error)" -Dependencies "Failed: $($oneResult.Error)"
                                [void]$appsWithFindings.Add($oneResult.AppName)
                                continue
                            }
                            $metaDiffs = Get-CatalogMetadataFieldDiffs -Local $catalogApp.metadata -Remote $oneResult.Metadata -OdataType $oneResult.OdataType
                            $metaText = if ($metaDiffs.Count -eq 0) { "OK" } else { "$($metaDiffs.Count) field(s) differ: $(($metaDiffs | ForEach-Object { $_.Field }) -join ', ')" }
                            $groupsText = if ($oneResult.GroupFetchOk) {
                                $groupDiffs = Get-GroupFieldDiffs -LocalApp $catalogApp -RemoteResult $oneResult
                                if ($groupDiffs.Count -eq 0) { "OK" } else { "$($groupDiffs.Count) differ: $(($groupDiffs | ForEach-Object { $_.Field }) -join ', ')" }
                            } else { "Failed: could not fetch live assignments" }
                            $liveDeps = @($oneResult.Metadata.dependencies) | Sort-Object
                            $localDeps = @($catalogApp.metadata.dependencies) | Sort-Object
                            $depsText = if (($liveDeps -join "|") -eq ($localDeps -join "|")) {
                                "OK"
                            } else {
                                $liveText = if ($liveDeps.Count -gt 0) { $liveDeps -join ", " } else { "(none)" }
                                $localText = if ($localDeps.Count -gt 0) { $localDeps -join ", " } else { "(none)" }
                                "Catalog has: $localText | Intune has: $liveText"
                            }
                            Set-LastAuditCacheEntry -AppName $oneResult.AppName -Metadata $metaText -Groups $groupsText -Dependencies $depsText
                            if ($metaText -ne "OK" -or $groupsText -ne "OK" -or $depsText -ne "OK") { [void]$appsWithFindings.Add($oneResult.AppName) }
                        }
                    }
                }
                catch { }
            }
            & $finishOne
        }.GetNewClosure())
    }
    catch {
        & $finishOne
    }

    # --- Fetch 2: Unknown Assignments ---
    $appsForScript2 = @($deployedApps | ForEach-Object {
        [pscustomobject]@{
            AppName         = $_.appName
            AppId           = $_.appId
            RequiredGroups  = @($_.requiredFor)
            AvailableGroups = @($_.availableFor)
            UninstallGroups = @($_.uninstallFor)
        }
    })
    $configPath2 = Join-Path $env:TEMP (".intunepkg_startupaudit_assign_config_" + [guid]::NewGuid().ToString("N") + ".json")
    $resultPath2 = Join-Path $env:TEMP (".intunepkg_startupaudit_assign_result_" + [guid]::NewGuid().ToString("N") + ".json")
    $config2 = [pscustomobject]@{
        TenantId              = $tenantId
        ClientId              = $clientId
        CertificateThumbprint = $certThumb
        Mode                  = "Preview"
        Apps                  = $appsForScript2
        OutputResultPath      = $resultPath2
    }
    try {
        $configJsonText2 = $config2 | ConvertTo-Json -Depth 8 -ErrorAction Stop
        [System.IO.File]::WriteAllText($configPath2, $configJsonText2, (New-Object System.Text.UTF8Encoding($false)))
        [void](Start-PipelineProcess -ScriptContent $batchScript -TempScriptName ".intunepkg_embedded_startupaudit_assign.ps1" -ArgumentString "-ConfigPath `"$configPath2`"" -OnComplete {
            param($code)
            Remove-Item $configPath2 -Force -ErrorAction SilentlyContinue
            if (Test-Path $resultPath2) {
                try {
                    $result2 = Get-Content -Path $resultPath2 -Raw | ConvertFrom-Json
                    Remove-Item $resultPath2 -Force -ErrorAction SilentlyContinue
                    if ($result2.success) {
                        foreach ($oneResult in @($result2.data)) {
                            if (-not $appByName.ContainsKey($oneResult.AppName)) { continue }
                            $toRemove = @($oneResult.ToRemove)
                            $unknownText = if ($toRemove.Count -eq 0) { "OK" } else { "$($toRemove.Count) unknown: $($toRemove -join ', ')" }
                            Set-LastAuditCacheEntry -AppName $oneResult.AppName -Unknown $unknownText
                            if ($unknownText -ne "OK") { [void]$appsWithFindings.Add($oneResult.AppName) }
                        }
                    }
                }
                catch { }
            }
            & $finishOne
        }.GetNewClosure())
    }
    catch {
        & $finishOne
    }
}

function Global:Start-Win32AppMinOsFetch {
    param([scriptblock]$OnComplete)

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($TenantId, $ClientId, $CertThumb)
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $ClientId) {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
        }

        $apps = New-Object System.Collections.Generic.List[object]
        $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$filter=isof('microsoft.graph.win32LobApp')&`$top=999"
        do {
            $result = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
            foreach ($item in $result.value) {
                # Same generic Hashtable-or-PSCustomObject handling as
                # Start-AppMetadataFetch's own minOS parsing - see the note
                # there.
                $itemMinOsPropName = $null
                if ($item.minimumSupportedOperatingSystem) {
                    $itemMinOsObj = $item.minimumSupportedOperatingSystem
                    if ($itemMinOsObj -is [System.Collections.IDictionary]) {
                        foreach ($key in $itemMinOsObj.Keys) {
                            if ($itemMinOsObj[$key] -eq $true) { $itemMinOsPropName = $key; break }
                        }
                    }
                    else {
                        foreach ($prop in $itemMinOsObj.PSObject.Properties) {
                            if ($prop.Value -eq $true) { $itemMinOsPropName = $prop.Name; break }
                        }
                    }
                }
                $apps.Add([pscustomobject]@{
                    id = $item.id
                    minOSPropertyName = $itemMinOsPropName
                    # See the note next to Start-AppMetadataFetch's own
                    # MinimumSupportedWindowsRelease field - this is the
                    # AUTHORITATIVE minimum-OS value whenever it's set;
                    # minOSPropertyName above only reflects the legacy
                    # property Microsoft has replaced it with.
                    minimumSupportedWindowsRelease = $item.minimumSupportedWindowsRelease
                })
            }
            $uri = $result.'@odata.nextLink'
        } while ($uri)

        $apps.ToArray()
    }).AddArgument($Global:App.GraphTenantId).AddArgument($Global:App.GraphClientId).AddArgument($Global:App.GraphCertificateThumbprint)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $timer.Dispose()
        try {
            $raw = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) {
                $errMsg = Get-GraphRunspaceErrorMessage $ps.Streams.Error
                if ($OnComplete) { & $OnComplete $false $errMsg }
            }
            else {
                if ($OnComplete) { & $OnComplete $true $raw }
            }
        }
        catch {
            if ($OnComplete) { & $OnComplete $false $_.Exception.Message }
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}

function Global:Start-EntraDirectoryLookup {
    param([scriptblock]$OnComplete)

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        [System.Windows.Forms.MessageBox]::Show(
            "The Microsoft.Graph.Authentication module isn't installed.`n`nInstall it with:`nInstall-Module Microsoft.Graph.Authentication -Scope CurrentUser",
            "Module missing", "OK", "Warning") | Out-Null
        if ($OnComplete) { & $OnComplete $false "Module missing" }
        return
    }

    if (-not (Test-GraphCredentialsConfigured)) {
        if ($OnComplete) { & $OnComplete $false "Not configured" }
        return
    }

    # Same guard as Start-IntuneAppLookup's own $Global:App.BtnLookupIds
    # check, but this function is called from several different dialogs
    # (not one dedicated toolbar button), so it needs its own dedicated
    # flag rather than borrowing a specific button's Enabled state. Without
    # it, double-clicking a Refresh button that calls this can launch two
    # concurrent runspaces; whichever finishes first resets the WaitCursor
    # back to Default while the other is still silently fetching.
    if ($Global:App.EntraDirectoryLookupRunning) {
        Write-Log "A lookup is already running - please wait for it to finish.`r`n" ([System.Drawing.Color]::Orange)
        if ($OnComplete) { & $OnComplete $false "A lookup is already running" }
        return
    }
    $Global:App.EntraDirectoryLookupRunning = $true

    Write-Log "=== Looking up groups and users from Entra ID (Microsoft Graph, app-only via certificate) ===`r`n" ([System.Drawing.Color]::DeepSkyBlue)
    $Global:App.Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    # Plain local alias - see note in Start-IntuneAppLookup.
    $cache = $Global:App.EntraDirectoryCache

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($TenantId, $ClientId, $CertThumb)
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $ClientId) {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
        }
        $ctx = Get-MgContext -ErrorAction Stop

        $entries = New-Object System.Collections.Generic.List[object]

        $uri = "https://graph.microsoft.com/v1.0/groups?`$select=id,displayName&`$top=999"
        do {
            $result = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
            foreach ($item in $result.value) {
                $entries.Add([pscustomobject]@{ displayName = $item.displayName; type = "Group"; id = $item.id; upn = "" })
            }
            $uri = $result.'@odata.nextLink'
        } while ($uri)

        $uri = "https://graph.microsoft.com/v1.0/users?`$select=id,displayName,userPrincipalName&`$top=999"
        do {
            $result = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
            foreach ($item in $result.value) {
                $entries.Add([pscustomobject]@{ displayName = $item.displayName; type = "User"; id = $item.id; upn = $item.userPrincipalName })
            }
            $uri = $result.'@odata.nextLink'
        } while ($uri)

        [pscustomobject]@{
            Entries  = $entries.ToArray()
            AppName  = $ctx.AppName
        }
    }).AddArgument($Global:App.GraphTenantId).AddArgument($Global:App.GraphClientId).AddArgument($Global:App.GraphCertificateThumbprint)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $timer.Dispose()
        $Global:App.Form.Cursor = [System.Windows.Forms.Cursors]::Default
        [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::Default
        # See the same pattern's note in Show-WingetSearchDialog - forces
        # an immediate cursor repaint instead of waiting on a mouse move.
        [System.Windows.Forms.Application]::DoEvents()
        [System.Windows.Forms.Cursor]::Position = [System.Windows.Forms.Cursor]::Position

        try {
            $raw = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) {
                $errMsg = Get-GraphRunspaceErrorMessage $ps.Streams.Error
                Write-Log "[FAILED] $errMsg`r`n" ([System.Drawing.Color]::Tomato)
                if ($OnComplete) { & $OnComplete $false $errMsg }
            }
            elseif ($raw.Count -eq 0) {
                Write-Log "[FAILED] No response came back from the lookup runspace.`r`n" ([System.Drawing.Color]::Tomato)
                if ($OnComplete) { & $OnComplete $false "No response from lookup" }
            }
            else {
                $info = $raw[0]
                $cache.Clear()
                foreach ($e in @($info.Entries)) { [void]$cache.Add($e) }
                $groupCount = @($cache | Where-Object { $_.type -eq "Group" }).Count
                $userCount  = @($cache | Where-Object { $_.type -eq "User" }).Count
                Write-Log "[OK] Connected app-only as '$($info.AppName)'. Loaded $groupCount group(s) and $userCount user(s).`r`n" ([System.Drawing.Color]::LightGreen)
                if ($OnComplete) { & $OnComplete $true $cache }
            }
        }
        catch {
            Write-Log "[FAILED] $($_.Exception.Message)`r`n" ([System.Drawing.Color]::Tomato)
            if ($OnComplete) { & $OnComplete $false $_.Exception.Message }
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
            $Global:App.EntraDirectoryLookupRunning = $false
        }
    }.GetNewClosure())
    $timer.Start()
}

function Global:Find-IntuneMatches {
    param([string]$Name)

    # Build the result as an explicit List and return it with a leading comma.
    # Without the comma, PowerShell unrolls the returned array onto the output
    # stream; an empty array unrolled produces ZERO output objects, so the
    # caller's "$candidates = Find-IntuneMatches ..." assignment would get
    # $null instead of an empty array - and $null.Count silently reads back
    # as $null too, which is why this looked like "no matches anywhere."
    $results = New-Object System.Collections.Generic.List[object]
    if (-not $Name) { return ,$results.ToArray() }

    $normalizedName = ($Name.Trim() -replace '\s+', ' ')

    foreach ($candidate in $Global:App.IntuneAppsCache) {
        $normDisplay = ($candidate.displayName.Trim() -replace '\s+', ' ')
        if ($normDisplay -eq $normalizedName) {
            $results.Add($candidate)
        }
    }
    foreach ($candidate in $Global:App.IntuneAppsCache) {
        $normDisplay = ($candidate.displayName.Trim() -replace '\s+', ' ')
        if ($normDisplay -ne $normalizedName -and (
            $normDisplay -like "*$normalizedName*" -or $normalizedName -like "*$normDisplay*"
        )) {
            $results.Add($candidate)
        }
    }
    return ,$results.ToArray()
}

function Global:Start-AppMetadataFetch {
    param([string]$AppId, [scriptblock]$OnComplete)

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        if ($OnComplete) { & $OnComplete $false "Microsoft.Graph.Authentication module isn't installed." $null }
        return
    }
    if (-not (Test-GraphCredentialsConfigured)) {
        if ($OnComplete) { & $OnComplete $false "Not configured" $null }
        return
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($TenantId, $ClientId, $CertThumb, $TargetAppId)
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $ClientId) {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
        }

        # Invoke-MgGraphRequest under Windows PowerShell 5.1 has a known,
        # reproducible bug decoding non-ASCII text in a JSON response body -
        # confirmed live on Company Portal's own (fixed, Microsoft-authored)
        # description, which came back with every curly apostrophe/quote/
        # dash mangled into the exact "a UTF-8 byte sequence read back as
        # Windows-1252" pattern (e.g. a right single quote, U+2019, turning
        # into the three characters "a-circumflex, Euro sign, trademark").
        # Re-encoding as Windows-1252 and re-decoding the resulting bytes as
        # UTF-8 reverses exactly that mistake. Gated on detecting the
        # tell-tale byte pattern first (rather than applied unconditionally)
        # so text that ISN'T mojibake is never touched, and the result is
        # only trusted if it re-decodes clean (no U+FFFD replacement
        # characters) - anything else returns the original text untouched.
        function Repair-MojibakeText {
            param([string]$Text)
            if (-not $Text) { return $Text }
            if ($Text.IndexOf([char]0x00C3) -lt 0 -and $Text.IndexOf(([string]([char]0x00E2) + [char]0x20AC)) -lt 0) { return $Text }
            try {
                $bytes = [System.Text.Encoding]::GetEncoding(1252).GetBytes($Text)
                $repaired = [System.Text.Encoding]::UTF8.GetString($bytes)
                if ($repaired.IndexOf([char]0xFFFD) -lt 0) { return $repaired }
            } catch { }
            return $Text
        }

        $app = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$TargetAppId" -Method GET -ErrorAction Stop

        # Same endpoint and filtering as the bulk Sync metadata script -
        # targetType -eq "child" specifically. Corrected after being wrong
        # the first time (was "parent") - see the detailed note next to
        # this same fix in the sync script for the concrete evidence that
        # settled the actual direction. Wrapped in its own try/catch so a
        # failure here doesn't sink the whole fetch - falling back to an
        # empty list is a smaller, more contained failure than losing
        # every other field along with it.
        $dependencyNames = @()
        try {
            $rels = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$TargetAppId/relationships" -Method GET -ErrorAction Stop
            $dependencyNames = @($rels.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.mobileAppDependency' -and $_.targetType -eq 'child' } | ForEach-Object { $_.targetDisplayName } | Where-Object { $_ })
        }
        catch { }

        # This app's CURRENT live Intune assignments, sorted by intent into
        # the same three buckets the catalog itself uses (requiredFor/
        # availableFor/uninstallFor) - same endpoint and per-group
        # displayName resolution already used by Invoke-QuickAssignGroups'
        # own "show current assignments before changing anything" step
        # (see the detailed note there). Non-group targets (All users/All
        # devices) are skipped - the catalog's own group-assignment model
        # has no representation for those. Wrapped the same defensively as
        # dependencies above: a failure here shouldn't sink the rest of
        # the fetch.
        $requiredGroupNames = @()
        $availableGroupNames = @()
        $uninstallGroupNames = @()
        try {
            $currentAssignments = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$TargetAppId/assignments" -Method GET -ErrorAction Stop
            foreach ($a in @($currentAssignments.value)) {
                if ($a.target.'@odata.type' -ne '#microsoft.graph.groupAssignmentTarget') { continue }
                $gid = $a.target.groupId
                $groupDisplayName = $gid
                try {
                    $groupInfo = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/groups/$gid`?`$select=displayName" -Method GET -ErrorAction Stop
                    if ($groupInfo.displayName) { $groupDisplayName = $groupInfo.displayName }
                }
                catch { }
                switch ($a.intent) {
                    "required"  { $requiredGroupNames += $groupDisplayName }
                    "available" { $availableGroupNames += $groupDisplayName }
                    "uninstall" { $uninstallGroupNames += $groupDisplayName }
                }
            }
        }
        catch { }

        # Structured the same way the GUI's submit-side config is, so the
        # populate-from-fetch logic can read these fields directly into the
        # same controls the submit logic reads them back out of.
        $detectionRule = $null
        foreach ($rule in @($app.detectionRules)) {
            $odType = $rule.'@odata.type'
            if ($odType -eq '#microsoft.graph.win32LobAppPowerShellScriptDetection' -and $rule.scriptContent) {
                $scriptText = $null
                try { $scriptText = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($rule.scriptContent)) } catch { }
                $detectionRule = [pscustomobject]@{ Type = "Script"; Script_Content = $scriptText }
                break
            }
            elseif ($odType -eq '#microsoft.graph.win32LobAppProductCodeDetection') {
                $detectionRule = [pscustomobject]@{
                    Type                 = "Msi"
                    Msi_ProductCode      = $rule.productCode
                    Msi_VersionOperator  = $rule.productVersionOperator
                    Msi_Version          = $rule.productVersion
                }
                break
            }
            elseif ($odType -eq '#microsoft.graph.win32LobAppFileSystemDetection') {
                $detectionRule = [pscustomobject]@{
                    Type                = "File"
                    File_Path            = $rule.path
                    File_Name            = $rule.fileOrFolderName
                    File_Check32Bit      = $rule.check32BitOn64System
                    File_DetectionType   = $rule.detectionType
                    File_Operator        = $rule.operator
                    File_DetectionValue  = $rule.detectionValue
                }
                break
            }
            elseif ($odType -eq '#microsoft.graph.win32LobAppRegistryDetection') {
                $detectionRule = [pscustomobject]@{
                    Type                = "Registry"
                    Reg_KeyPath          = $rule.keyPath
                    Reg_ValueName        = $rule.valueName
                    Reg_Check32Bit       = $rule.check32BitOn64System
                    Reg_DetectionType    = $rule.detectionType
                    Reg_Operator         = $rule.operator
                    Reg_DetectionValue   = $rule.detectionValue
                }
                break
            }
        }

        # minimumSupportedOperatingSystem comes back as either a Hashtable or
        # a PSCustomObject depending on how the Graph module happens to
        # deserialize this particular response - handled generically here
        # rather than assuming one or the other.
        $minOsPropName = $null
        if ($app.minimumSupportedOperatingSystem) {
            $minOsObj = $app.minimumSupportedOperatingSystem
            if ($minOsObj -is [System.Collections.IDictionary]) {
                foreach ($key in $minOsObj.Keys) {
                    if ($minOsObj[$key] -eq $true) { $minOsPropName = $key; break }
                }
            }
            else {
                foreach ($prop in $minOsObj.PSObject.Properties) {
                    if ($prop.Value -eq $true) { $minOsPropName = $prop.Name; break }
                }
            }
        }

        [pscustomobject]@{
            DisplayName             = $app.displayName
            Description             = Repair-MojibakeText $app.description
            Publisher               = Repair-MojibakeText $app.publisher
            Owner                   = Repair-MojibakeText $app.owner
            Developer               = Repair-MojibakeText $app.developer
            InformationUrl          = $app.informationUrl
            PrivacyInformationUrl   = $app.privacyInformationUrl
            Notes                   = Repair-MojibakeText $app.notes
            InstallCommandLine      = $app.installCommandLine
            UninstallCommandLine    = $app.uninstallCommandLine
            ApplicableArchitectures = $app.applicableArchitectures
            AllowedArchitectures    = $app.allowedArchitectures
            RunAsAccount            = $app.installExperience.runAsAccount
            MinOSPropertyName       = $minOsPropName
            # Microsoft has REPLACED minimumSupportedOperatingSystem (the
            # boolean-bag property MinOSPropertyName above reads) with this
            # plain string property, specifically to support Windows 11
            # requirements (W10_xxxx / W11_xxxx values) that the old
            # property's schema never had room for - confirmed directly
            # against the IntuneWin32App PowerShell module's own release
            # notes ("minimumSupportedOperatingSystem property is replaced
            # by minimumSupportedWindowsRelease") after a real app (set via
            # the Intune portal, to "Windows 11 21H2") came back with
            # MinOSPropertyName entirely blank despite genuinely having a
            # minimum OS set - this is why. No parsing needed, unlike the
            # legacy property above - it's already a plain value like
            # "W11_21H2" directly on the app.
            MinimumSupportedWindowsRelease = $app.minimumSupportedWindowsRelease
            # Same fields Show-SyncMetadataDialog's own embedded fetch
            # already captures for the main grid's Type/Version columns -
            # this is the OTHER live-fetch path (Deploy to Intune's own
            # auto-fetch for an existing app) that used to leave those two
            # columns blank forever unless "Pull metadata and groups from Intune..." was run
            # separately at least once.
            OdataType       = $app.'@odata.type'
            DisplayVersion  = [string]$app.displayVersion
            DetectionRule           = $detectionRule
            Dependencies            = $dependencyNames
            MinDiskSpaceMB          = $app.minimumFreeDiskSpaceInMB
            MinMemoryMB             = $app.minimumMemoryInMB
            MinProcessors           = $app.minimumNumberOfProcessors
            MinCpuSpeedMHz          = $app.minimumCpuSpeedInMHz
            InstallTimeMinutes      = $app.installExperience.maxRunTimeInMinutes
            DeviceRestartBehavior   = $app.installExperience.deviceRestartBehavior
            AllowAvailableUninstall = $app.allowAvailableUninstall
            # Same $null-pipe guard as the other embedded fetch script's
            # returnCodes mapping - see its comment for why this matters for
            # non-Win32 apps (e.g. "Microsoft Store app (new)").
            ReturnCodes             = if (@($app.returnCodes).Count -gt 0) { @($app.returnCodes | ForEach-Object { [pscustomobject]@{ returnCode = $_.returnCode; type = $_.type } }) } else { @() }
            RequiredGroupNames      = $requiredGroupNames
            AvailableGroupNames     = $availableGroupNames
            UninstallGroupNames     = $uninstallGroupNames
        }
    }).AddArgument($Global:App.GraphTenantId).AddArgument($Global:App.GraphClientId).AddArgument($Global:App.GraphCertificateThumbprint).AddArgument($AppId)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $timer.Dispose()
        try {
            $raw = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) {
                # $_.ToString() alone is just the message - for something
                # like a stray "'else' is not recognized..." (which reads
                # like a parse error, but can't be one in THIS script - see
                # Start-AppMetadataFetch's own scriptblock, which parses
                # clean) that's not enough to tell whether it came from our
                # own code or from deep inside the Graph module chain
                # (Import-Module/Connect-MgGraph/Invoke-MgGraphRequest).
                # Appending where it was thrown (script file + line, if
                # any) turns a mystery message into something diagnosable.
                $errMsg = Get-GraphRunspaceErrorMessage $ps.Streams.Error
                if ($OnComplete) { & $OnComplete $false $errMsg $null }
            }
            elseif ($raw.Count -eq 0) {
                if ($OnComplete) { & $OnComplete $false "No response came back." $null }
            }
            else {
                if ($OnComplete) { & $OnComplete $true "" $raw[0] }
            }
        }
        catch {
            # $_ here reflects the RE-THROW site (EndInvoke's own call site,
            # in THIS file) - not where the error actually originated inside
            # the background runspace's script, which by this point has
            # already been disposed of below. $ps.Streams.Error, if
            # anything made it there before the pipeline gave up, still
            # carries the REAL position (line/char within that in-memory
            # script, even without a filename since it was never a .ps1
            # file) - prefer that when present, same reasoning/format as
            # the sibling branch above.
            if ($ps.Streams.Error.Count -gt 0) {
                $errMsg = Get-GraphRunspaceErrorMessage $ps.Streams.Error
            }
            else {
                $where = $_.InvocationInfo.PositionMessage
                $exType = $_.Exception.GetType().FullName
                $errMsg = if ($where) { "$($_.Exception.Message) [$exType @ $($where.Trim())]" } else { "$($_.Exception.Message) [$exType]" }
            }
            if ($OnComplete) { & $OnComplete $false $errMsg $null }
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}

function Global:Start-TypeVersionBackfill {
    if ($Global:App.TypeVersionBackfillDone) { return }

    # Checked BEFORE Test-GraphCredentialsConfigured (which pops a blocking
    # "Not configured" MessageBox on failure) - not after, the way this used
    # to be ordered. This runs automatically on every startup/Reload/Open
    # other folder, unconditionally - a brand-new catalog, or one where
    # every app already has intuneAppType recorded, has nothing to back
    # fill at all, and was still getting an interruptive popup for a
    # background maintenance task the user never asked to run, before
    # they'd even seen the app's own (deliberately non-intrusive) yellow
    # credential-warning banner further down in MainApp.ps1's startup.
    $needsBackfill = @($Global:App.Apps | Where-Object { $_.appId -and -not $_.intuneAppType })
    if ($needsBackfill.Count -eq 0) {
        $Global:App.TypeVersionBackfillDone = $true
        return
    }

    if (-not (Test-GraphCredentialsConfigured)) { return }

    $Global:App.TypeVersionBackfillDone = $true
    Write-Log "Backfilling Type/Version for $($needsBackfill.Count) app(s) never synced before...`r`n" ([System.Drawing.Color]::Gainsboro)
    Update-StartupBusyIndicator -Delta 1

    $appsRef = $Global:App.Apps
    $linkedFilePathRef = $Global:App.LinkedFilePath
    $unsavedBoxRef = $Global:App.UnsavedChangesBox
    # Captured now, checked again before every write below - see
    # $Global:App.CatalogGeneration's own comment in MainApp.ps1 for why:
    # $appsRef above is the SAME list object Import-AppsFromFile mutates in
    # place on a Reload/Open other folder, so a generation mismatch is the
    # only way this queue can tell "the catalog I started against isn't the
    # one in front of the user anymore" and stop touching it.
    $startGeneration = $Global:App.CatalogGeneration

    $RunBackfillQueueBox = @{ Value = $null }
    $RunBackfillQueueBox.Value = {
        param($Queue, $QueueIndex, $UpdatedCount, $FailedCount)

        if ($Global:App.CatalogGeneration -ne $startGeneration) {
            Write-Log "[SKIPPED] Type/Version backfill stopped - the catalog was reloaded partway through.`r`n" ([System.Drawing.Color]::DimGray)
            Update-StartupBusyIndicator -Delta -1
            return
        }

        if ($QueueIndex -ge $Queue.Count) {
            if ($UpdatedCount -gt 0) {
                [void](Save-AppsToFile -Path $linkedFilePathRef)
                Update-Grid
            }
            $doneColor = if ($FailedCount -gt 0) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::LightGreen }
            $doneMsg = "Type/Version backfill done - $UpdatedCount app(s) updated."
            if ($FailedCount -gt 0) { $doneMsg += " $FailedCount app(s) failed - see above." }
            Write-Log "$doneMsg`r`n" $doneColor
            Update-StartupBusyIndicator -Delta -1
            return
        }

        $currentApp = $Queue[$QueueIndex]

        # Fresh aliases for this nested -OnComplete closure - see note at
        # the top of Show-CreateInIntuneDialog.
        $currentAppRef = $currentApp
        $appsRefRef = $appsRef
        $QueueRef = $Queue
        $QueueIndexRef = $QueueIndex
        $UpdatedCountRef = $UpdatedCount
        $FailedCountRef = $FailedCount
        $RunBackfillQueueBoxRef = $RunBackfillQueueBox
        $unsavedBoxRefRef = $unsavedBoxRef
        $startGenerationRef = $startGeneration

        Start-AppMetadataFetch -AppId $currentAppRef.appId -OnComplete {
            param($ok, $errMsg, $data)
            # Checked again here, not just at the top of the queue loop
            # above - THIS is where the actual write onto $appsRefRef
            # happens (by app NAME, against whatever is in that list right
            # now), and the catalog could have been reloaded in the time
            # this one Graph fetch was in flight, not just between queue
            # items. A stale generation here isn't a fetch failure (the
            # fetch itself may well have succeeded), so it's not counted
            # or logged as one - the top-of-loop check already logs the
            # one summary line for this queue being abandoned.
            if ($Global:App.CatalogGeneration -ne $startGenerationRef) {
                Update-StartupBusyIndicator -Delta -1
                return
            }

            $nextUpdatedCount = $UpdatedCountRef
            $nextFailedCount = $FailedCountRef
            if ($ok) {
                $target = $appsRefRef | Where-Object { $_.appName -eq $currentAppRef.appName } | Select-Object -First 1
                if ($target -and -not $target.intuneAppType) {
                    $target.intuneAppType = Get-FriendlyIntuneAppType -ODataType $data.OdataType
                    $target.intuneAppVersion = $data.DisplayVersion
                    $unsavedBoxRefRef.Value = $true
                    $nextUpdatedCount = $UpdatedCountRef + 1
                }
            }
            else {
                $nextFailedCount = $FailedCountRef + 1
                Write-Log "[FAILED] Type/Version backfill for `"$($currentAppRef.appName)`": $errMsg`r`n" ([System.Drawing.Color]::IndianRed)
            }
            & $RunBackfillQueueBoxRef.Value -Queue $QueueRef -QueueIndex ($QueueIndexRef + 1) -UpdatedCount $nextUpdatedCount -FailedCount $nextFailedCount
        }.GetNewClosure()
    }.GetNewClosure()

    & $RunBackfillQueueBox.Value -Queue $needsBackfill -QueueIndex 0 -UpdatedCount 0 -FailedCount 0
}

function Global:Start-GroupMembersFetch {
    param([string]$GroupName, [scriptblock]$OnComplete)

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        if ($OnComplete) { & $OnComplete $false "Microsoft.Graph.Authentication module isn't installed." $null }
        return
    }
    if (-not (Test-GraphCredentialsConfigured)) {
        if ($OnComplete) { & $OnComplete $false "Not configured" $null }
        return
    }

    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($TenantId, $ClientId, $CertThumb, $TargetGroupName)
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        $ctx = Get-MgContext -ErrorAction SilentlyContinue
        if ($null -eq $ctx -or $ctx.AuthType -ne 'AppOnly' -or $ctx.ClientId -ne $ClientId) {
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                -CertificateThumbprint $CertThumb -NoWelcome -ErrorAction Stop
        }

        $escapedName = $TargetGroupName.Replace("'", "''")
        $encodedFilter = [Uri]::EscapeDataString("displayName eq '$escapedName'")
        $existing = Invoke-MgGraphRequest -Uri "https://graph.microsoft.com/v1.0/groups?`$filter=$encodedFilter&`$select=id,displayName,description" -Method GET -ErrorAction Stop
        if (-not $existing.value -or $existing.value.Count -eq 0) {
            return [pscustomobject]@{ Found = $false; GroupId = $null; Description = $null; Members = @() }
        }
        $groupId = $existing.value[0].id
        $description = $existing.value[0].description

        $members = New-Object System.Collections.Generic.List[object]
        $uri = "https://graph.microsoft.com/v1.0/groups/$groupId/members?`$select=id,displayName&`$top=999"
        do {
            $result = Invoke-MgGraphRequest -Uri $uri -Method GET -ErrorAction Stop
            foreach ($m in $result.value) {
                $mType = if ($m.'@odata.type' -eq '#microsoft.graph.group') { "Group" } else { "User" }
                $members.Add([pscustomobject]@{ id = $m.id; displayName = $m.displayName; type = $mType })
            }
            $uri = $result.'@odata.nextLink'
        } while ($uri)

        [pscustomobject]@{ Found = $true; GroupId = $groupId; Description = $description; Members = $members.ToArray() }
    }).AddArgument($Global:App.GraphTenantId).AddArgument($Global:App.GraphClientId).AddArgument($Global:App.GraphCertificateThumbprint).AddArgument($GroupName)

    $handle = $ps.BeginInvoke()
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 300
    $timer.Add_Tick({
        if (-not $handle.IsCompleted) { return }
        $timer.Stop()
        $timer.Dispose()
        try {
            $raw = @($ps.EndInvoke($handle))
            if ($ps.Streams.Error.Count -gt 0) {
                $errMsg = Get-GraphRunspaceErrorMessage $ps.Streams.Error
                if ($OnComplete) { & $OnComplete $false $errMsg $null }
            }
            elseif ($raw.Count -eq 0) {
                if ($OnComplete) { & $OnComplete $false "No response came back." $null }
            }
            else {
                if ($OnComplete) { & $OnComplete $true "" $raw[0] }
            }
        }
        catch {
            if ($OnComplete) { & $OnComplete $false $_.Exception.Message $null }
        }
        finally {
            $ps.Dispose()
            $rs.Close()
            $rs.Dispose()
        }
    }.GetNewClosure())
    $timer.Start()
}
