# Shared by the classic window (MainApp.ps1) and the web interface
# (code\Web\Start-WebApp.ps1): every piece of app state, settings and
# embedded step scripts, set up the same way for both. Moved here verbatim
# from MainApp.ps1 - $PSScriptRoot became -RootPath, nothing else changed.
function Global:Initialize-AppState {
    param([Parameter(Mandatory = $true)][string]$RootPath)
    $Global:App = @{}

    # =====================================================================
    # Paths & state
    # =====================================================================
    $Global:App.RootPath        = $RootPath
    # Points at a FOLDER of per-app JSON files now (one file per app, e.g.
    # "app-data/7zip.json"), not a single input.json - kept the same variable
    # name despite the changed meaning to minimize how many of the many
    # existing references throughout this script needed touching, given the
    # genuine risk of a change this size.
    $Global:App.LinkedFilePath  = Join-Path $Global:App.RootPath "data\app-data"
    $Global:App.Apps            = New-Object System.Collections.ArrayList
    $Global:App.UnsavedChangesBox = @{ Value = $false }   # container (never reassigned) so closures can mutate it safely
    $Global:App.IntuneAppsCache = New-Object System.Collections.ArrayList   # populated by Start-IntuneAppLookup: array of @{ id; displayName } - mutated in place (Clear+Add), never reassigned, so every closure that references it stays in sync
    $Global:App.EntraDirectoryCache = New-Object System.Collections.ArrayList   # populated by Start-EntraDirectoryLookup: array of @{ displayName; type ("Group"/"User"); id; upn } - same mutate-in-place pattern as above
    $Global:App.EntraDirectoryLookupRunning = $false   # guards against two overlapping Start-EntraDirectoryLookup runs - see its own comment
    $Global:App.EntraDirectoryCacheFetchedAt = $null   # when the cache above was last filled by a SUCCESSFUL lookup; only -ReuseCacheWithinSeconds callers read it
    # Populated whenever any live-vs-Intune check runs for an app - the
    # single-app auto-fetch inside Show-CreateInIntuneDialog, or
    # Show-ChecksDialog's own bulk run - keyed by appName. Persisted to
    # its OWN file ($Global:App.LastAuditCachePath), deliberately NOT round-tripped
    # through ConvertTo-AppRecord/ConvertTo-SingleAppJson (both are strict,
    # hand-rolled field whitelists that exist specifically so a Git diff for
    # one app's change only ever touches that one app's file - an audit
    # timestamp that changes on every check would turn every audit run into
    # diff noise across every checked app's own catalog file, working against
    # the whole reason that per-app-file design exists). See
    # Load-LastAuditCache/Save-LastAuditCache/Set-LastAuditCacheEntry/
    # Get-LastAuditSummary. A missing or corrupt cache file just leaves this
    # empty, same as it always was before persistence existed - nothing here
    # is load-bearing for the app to function; the main grid's own
    # "Last Audit" column simply falls back to "Never audited".
    $Global:App.LastAuditResults = @{}
    $Global:App.LastAuditCachePath = Join-Path $Global:App.RootPath "data\last-audit-cache.json"
    # Bumped by Import-AppsFromFile every time it (re)loads the catalog -
    # Reload, Open other folder..., or startup itself. Start-TypeVersionBackfill
    # captures the value in effect when its background queue starts and checks
    # it again before every write; Import-AppsFromFile mutates $Global:App.Apps
    # IN PLACE (.Clear()/.Add(), never replaces the list object itself), so a
    # backfill queue still in flight from a folder the user has since moved
    # away from would otherwise happily go on matching by app NAME against
    # whatever is now in that same list - silently writing borrowed Intune
    # type/version data onto an unrelated app in the newly-loaded catalog that
    # just happens to share a name with one from the old one.
    $Global:App.CatalogGeneration = 0
    $Global:App.LogFileWriter = $null   # opened in Initialize-Folders, written to by Write-Log, closed on FormClosing - see both below
    $Global:App.LogFlushTimer = $null   # periodic flush timer for the above - see Initialize-Folders
    $Global:App.AppVersion = "1.10.0"   # bump when shipping a meaningfully different build, so "which version are you on" is answerable at a glance rather than by diffing the whole file

    # App-only Graph auth (certificate) - must match the values in the Assign step /
    # your Entra ID app registration. Left blank on purpose - no tenant/client
    # ID or certificate thumbprint should ever be hardcoded in a script that
    # lives in a repo. Configure these via "Settings..." in the app on first
    # run; they're then saved to intune-deployment-settings.json next to this
    # script and loaded automatically from there on every subsequent launch
    # (see Import-GraphSettings below). The certificate itself must already be
    # installed in this user's certificate store - Settings can also pick an
    # existing one or generate a new one.
    $Global:App.GraphTenantId              = ""
    $Global:App.GraphClientId              = ""
    $Global:App.GraphCertificateThumbprint = ""
    $Global:App.SettingsFilePath = Join-Path $Global:App.RootPath "data\intune-deployment-settings.json"

    # Group names marked as "favorites" - shown as ready-to-tick options in
    # every app's Required/Available/Uninstall lists (new and existing alike),
    # instead of those lists defaulting to every group ever used by any app in
    # the whole catalog. Persisted in the same settings file as Graph
    # credentials, so both need to be written together on every save - see the
    # comment on Write-SettingsFile below for why.
    $Global:App.FavoriteGroups = New-Object System.Collections.Generic.List[string]

    # Opt-in, off by default - a shared catalog file (multiple people pointed
    # at the same folder/repo) can drift from what's actually live in Intune
    # without anyone noticing until they happen to run "Intune sync check..."
    # themselves. When on, the same comparison that dialog runs happens once,
    # quietly, in the background after the main window is shown - see
    # Start-StartupDriftCheck below. Off by default because it needs Graph
    # credentials already configured to be useful at all, and adds a
    # background fetch proportional to catalog size that a single, solo user
    # working offline-ish has no reason to want on every launch.
    $Global:App.CheckDriftOnStartup = $false

    # "Detailed Graph log" (Log tab): every Graph request on its own log line,
    # not just writes and failures plus a read summary - see GraphLog.ps1.
    $Global:App.DetailedGraphLog = $false

    # Whether Deploy also pushes the app's groups to Intune afterwards.
    #
    # Two settings, not one, because the two cases are not the same risk. A
    # brand-new app has no assignments in Intune to overwrite, so pushing is
    # purely additive and is what "deploy this app" plainly means - on by
    # default. An UPDATE is different: the assign call replaces an app's
    # ENTIRE assignment list, so a group somebody added in the Intune portal
    # would vanish because an install command was edited here. That stays off
    # unless asked for, every time.
    #
    # Both live in Settings > Automatic checks and nowhere else. Deploy reads
    # them when the button is pressed and has no checkbox of its own - asked
    # for deliberately: one switch is easier to reason about than a switch
    # plus a per-deploy box that has to be remembered, and the setting is
    # where someone looks when a deploy did something they did not expect.
    $Global:App.PushGroupsOnCreate = $true
    $Global:App.PushGroupsOnUpdate = $false

    # Separate from, and off by default independent of, CheckDriftOnStartup
    # above - that one is a single cheap "list every app in Intune" call;
    # this is "Intune Audit..."'s own full check (Metadata/Groups/
    # Dependencies/Assignments), which needs a live fetch PER deployed app,
    # not one call for the whole catalog. Meaningfully slower on a large
    # catalog, which is exactly why it's a second, separately-labeled
    # opt-in rather than folded into the drift toggle - see
    # Start-StartupFullAuditCheck (GraphFetch.ps1).
    $Global:App.RunFullAuditOnStartup = $false
    # Whether "Deploy to Intune" asks Intune for an existing app's current
    # values the moment it opens. On means every open waits for that round
    # trip; off means the dialog shows what's saved here and only asks before
    # an update is actually sent - which is where it protects anything, since
    # that's the write that could otherwise overwrite a newer Intune value.
    # The startup audit already keeps an eye on drift either way.
    $Global:App.CheckIntuneOnDeployOpen = $true

    # The computed defaults Get-DefaultAppMetadata hands out for a brand-new
    # Winget app (what "Set default values..." and the custom-field
    # highlighting in Show-CreateInIntuneDialog both compare against, and what
    # Batch Deploy falls back to for an app with no saved metadata). Starts as
    # exactly the values this app has always hardcoded here - so behavior is
    # byte-for-byte identical until someone actually opens "Edit default
    # values..." and changes something - then persisted in the same settings
    # file as Graph credentials/Favorite groups, for the same
    # write-everything-together reason documented on Write-SettingsFile below.
    $Global:App.DefaultAppSettings = Get-FactoryAppSettings   # one definition of the built-in values - see Get-FactoryAppSettings

    # Guards Start-TypeVersionBackfill (see its own definition) against two
    # of its fetch queues running at once. It is kicked off on startup and
    # after Reload/Open other folder, not on every grid refresh (typing in
    # the search box refreshes the grid on every keystroke - firing a Graph
    # fetch queue on each one would be absurd).
    #
    # "Running", not "already done once", which is what this used to be. The
    # old flag was set even when there was NOTHING to back fill - so on a
    # catalog where every app already had a type, or an empty one about to be
    # filled from Intune, it was set within seconds of launch and the
    # backfill could never run again that session. Any app that arrived
    # afterwards without a type kept blank Type and Version columns until the
    # next restart.
    $Global:App.TypeVersionBackfillRunning = $false

    # How many background startup tasks are currently in flight (Start-
    # StartupDriftCheck, Start-TypeVersionBackfill - both silent otherwise,
    # the backfill especially so: it never even set a busy cursor, only Log
    # tab entries on a tab that isn't the default active one). A shared
    # counter, not a plain boolean, since both can legitimately overlap on
    # the same startup - the indicator this drives (LblStartupBusy, built
    # alongside the search box further down) only needs to know "is anything
    # still running," not which one.
    $Global:App.StartupBusyCount = 0

    # =====================================================================
    # Styling - single, consistent light palette applied to every control
    # =====================================================================
    # A designed palette, not raw SystemColors - the previous version themed
    # every control to whatever the OS's own Control/Window/Highlight colors
    # happened to be, which is exactly the dated, mismatched-grey Windows look
    # this was meant to move away from. Colors below are fixed values instead,
    # so the app looks the same, deliberately, on every machine regardless of
    # the user's own Windows accent color or theme. Only colors change here -
    # no controls gain new fixed sizes/positions, so this carries none of the
    # layout risk a font-size change would (many dialogs use hand-tuned pixel
    # coordinates already sized for the current font).
    $Global:App.LightPalette = @{
        FormBack       = [System.Drawing.Color]::FromArgb(246,247,249)
        ControlFore    = [System.Drawing.Color]::FromArgb(32,33,36)
        FieldBack      = [System.Drawing.Color]::White
        ButtonBack     = [System.Drawing.Color]::White
        ButtonHoverBack = [System.Drawing.Color]::FromArgb(237,242,253)
        ButtonPressBack = [System.Drawing.Color]::FromArgb(222,231,250)
        GridBack       = [System.Drawing.Color]::White
        GridAltBack    = [System.Drawing.Color]::FromArgb(248,249,251)
        GridHeaderBack = [System.Drawing.Color]::FromArgb(241,243,246)
        BorderColor    = [System.Drawing.Color]::FromArgb(216,219,224)
        SelectionBack  = [System.Drawing.Color]::FromArgb(37,99,235)
        SelectionFore  = [System.Drawing.Color]::White
        # Status text colors, picked to stay readable on white and on the grid's
        # alternating rows (at least 4.5:1 contrast) - the named colors used
        # before (DarkOrange, SeaGreen, SteelBlue) were well under that.
        StatusGood     = [System.Drawing.Color]::FromArgb(21,128,61)
        StatusWarn     = [System.Drawing.Color]::FromArgb(180,83,9)
        StatusInfo     = [System.Drawing.Color]::FromArgb(29,78,216)
        StatusMuted    = [System.Drawing.Color]::FromArgb(100,106,115)
    }

    # Applies the current theme to a control and everything nested inside it,
    # recursively - call on any Form/dialog right before ShowDialog() (after all
    # its controls have been built and added) so its whole tree gets themed.
    # RichTextBoxes used as log consoles are deliberately skipped - they already
    # have their own explicit dark styling set wherever they're created (a
    # console look regardless of the app's overall theme), and re-theming them
    # here would fight that.


    # Overrides $Global:App.GraphTenantId/ClientId/CertificateThumbprint from
    # intune-deployment-settings.json if that file exists, so choices made in the Settings
    # dialog persist across restarts without editing this script's source.

    # Always writes EVERY setting this file holds, not just the ones the
    # caller happens to be updating - Save-GraphSettings and
    # Save-FavoriteGroups both route through this single function rather
    # than each independently overwriting the whole file with only their own
    # fields, which would silently wipe out whichever setting the OTHER
    # function manages. The same class of bug already found and fixed once
    # this session (the App Editor overwriting metadata because it rebuilt
    # the whole app record from only its own fields) - fixed here from the
    # start by construction, not by patching around it after the fact.


    # Favorites are stored as their own list, mutated directly by whichever
    # UI manages them, then persisted the same way Save-GraphSettings does -
    # through the one shared writer above, so this never touches (or risks
    # clobbering) the Graph credential fields it doesn't manage.

    # Clears the delegated user's sign-in used for Check/Upload/Delete in
    # Settings - deletes the same MSAL token cache files Microsoft Graph
    # PowerShell persists to disk by default. Deliberately tied to the WHOLE
    # APP closing, not to Settings closing - closing and reopening Settings
    # during the same session (e.g. to do something else, then come back and
    # run another cert operation) shouldn't force a fresh sign-in each time.
    # Only when the app itself exits does the cached credential get cleared.

    Import-GraphSettings

    # The catalog folder is set above from the built-in default, because the
    # settings file had not been read yet at that point. Now it has: an
    # install that keeps its catalog somewhere else - a share, another drive -
    # opens there instead of opening the default and looking empty.
    $Global:App.LinkedFilePath = Get-AppFolder -Kind Catalog

    # =====================================================================
    # Embedded pipeline scripts
    # =====================================================================
    # Every packaging, deployment, and assignment step's full script content -
    # each one lives as its own real file under .\code\EmbeddedScripts, loaded here
    # once at startup relative to this script's own location ($RootPath),
    # not embedded as a literal here-string in this file anymore. At runtime,
    # Start-PipelineProcess writes whichever one is needed out to a temp .ps1
    # file INSIDE $Global:App.RootPath (not $env:TEMP), because several of these
    # scripts use $RootPath internally to find app-data / IntuneWinAppUtil.exe
    # - the temp file has to live in the real deployment folder for that to
    # resolve correctly. It's deleted again as soon as the child process exits,
    # successfully or not.
    $Global:App.EmbeddedPackageScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\Package.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedCreateAppScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\CreateApp.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedTargetedAssignScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\TargetedAssign.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedBatchAssignScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\BatchAssign.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedDeleteAppScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\DeleteApp.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedGroupManagerScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\GroupManager.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedSyncMetadataScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\SyncMetadata.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedCertUploadScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\CertUpload.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedPlatformScriptsScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\PlatformScripts.ps1") -Raw -Encoding UTF8
}
