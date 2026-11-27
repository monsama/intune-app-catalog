# Every piece of app state, the settings and the step scripts, set up once
# when the app starts (code\Web\Start-WebApp.ps1). Request runspaces share
# this same $Global:App hashtable.
function Global:Initialize-AppState {
    param([Parameter(Mandatory = $true)][string]$RootPath)
    $Global:App = @{}

    # =====================================================================
    # Paths & state
    # =====================================================================
    $Global:App.RootPath   = $RootPath
    # Linux (the container) has no TEMP: the steps and their result files go to the system's temp folder.
    if (-not $env:TEMP) { $env:TEMP = [System.IO.Path]::GetTempPath().TrimEnd('/', '\') }
    # The container's working folder is on the data volume - a volume made by an older version doesn't have it yet.
    foreach ($t in @($env:TEMP, $env:TMPDIR)) { if ($t -and -not (Test-Path -LiteralPath $t)) { try { [void](New-Item -ItemType Directory -Path $t -Force) } catch { } } }
    # Created once here, not on first use: two requests at once would each make their own.
    $Global:App.WingetIndexLock = New-Object System.Object
    $Global:App.CatalogTextCache = [hashtable]::Synchronized(@{})
    $Global:App.Uploads = [hashtable]::Synchronized(@{})
    $Global:App.LibraryExports = [hashtable]::Synchronized(@{})
    $Global:App.AppVersion = "2.38.79"   # bump when shipping a meaningfully different build, so "which version are you on" is answerable at a glance
    # The catalog as last read (Read-WebCatalogRecords) - the shared
    # functions that look at "the catalog" (default dependencies, known
    # groups) read it from here.
    $Global:App.Apps = New-Object System.Collections.ArrayList
    # What each live check last found per app, keyed by app name - the Apps
    # list's Last audit column. Kept in its own file, not in the apps' own
    # JSON files, so an audit doesn't turn into diff noise across the catalog.
    # A missing or corrupt cache just reads as "Never audited".
    $Global:App.LastAuditResults = @{}
    $Global:App.LastAuditCachePath = Join-Path $RootPath "data\last-audit-cache.json"

    # App-only Graph sign-in (certificate). Never hardcoded: Settings writes
    # them to data\intune-deployment-settings.json, read below on every start.
    $Global:App.GraphTenantId              = ""
    $Global:App.GraphClientId              = ""
    $Global:App.GraphCertificateThumbprint = ""
    $Global:App.SettingsFilePath = Join-Path $RootPath "data\intune-deployment-settings.json"

    # Groups offered first wherever a group is chosen. Saved with the rest of
    # the settings (Write-SettingsFile always writes every setting together).
    $Global:App.FavoriteGroups = New-Object System.Collections.Generic.List[string]
    # Managed updates: new releases go Required to these groups first (Settings > Defaults).
    $Global:App.PilotGroups = New-Object System.Collections.Generic.List[string]
    # When a pilot release goes to everyone (Get-ReleaseDecision), and whether the nightly run releases and promotes by itself.
    $Global:App.ReleasePolicy = ConvertTo-ReleasePolicy $null
    # Release rings after the pilot groups (@{ Name; Groups }), one at a time, each judged by the same rule.
    $Global:App.ReleaseRings = @()
    # Alerts from the nightly run: a Teams (Workflows) webhook and/or an email sent with Graph.
    $Global:App.Alerts = ConvertTo-AlertSettings $null
    # Assignment profiles: named sets of groups (Required, Available, Excluded), applied in one click.
    $Global:App.AssignmentProfiles = @()
    # The profile new apps get (Add apps and a new app in the editor fill in its groups) - '' for none (2.35.0).
    $Global:App.DefaultProfile = ''

    # Settings > Automatic checks. Off by default: they need a connection to be
    # of any use, and the full audit reads every deployed app.
    $Global:App.CheckDriftOnStartup = $false       # Checks' quick part when the app opens
    $Global:App.Packager = 'auto'                  # 'auto' (IntuneWinAppUtil.exe when it's there, built in otherwise), 'builtin' or 'tool'
    $Global:App.CheckForUpdates = $true            # ask GitHub (at most twice a day) whether a newer version of this app is out
    $Global:App.ReleaseRepo = 'monsama/intune-app-catalog'
    $Global:App.RunFullAuditOnStartup = $false     # every deployed app in detail when the app opens
    # Deploy: before creating an app, look for one of the same name already in Intune.
    $Global:App.CheckIntuneOnDeployOpen = $true
    # Every Graph request on its own log line, not just writes, failures and a read summary - see GraphLog.ps1.
    $Global:App.DetailedGraphLog = $false

    # Whether Deploy also pushes the app's groups to Intune afterwards. Two
    # settings, because the two cases are not the same risk: a new app has no
    # assignments to overwrite, but the assign call REPLACES an existing app's
    # whole list, so a group added in the Intune portal would vanish because
    # an install command was edited here. On for new apps, off for updates.
    $Global:App.PushGroupsOnCreate = $true
    $Global:App.PushGroupsOnUpdate = $false

    # What a new app gets when it is deployed without settings of its own
    # (Settings > Default values) - see Get-FactoryAppSettings.
    $Global:App.DefaultAppSettings = Get-FactoryAppSettings

    Import-GraphSettings

    # =====================================================================
    # Step scripts
    # =====================================================================
    # Each packaging, deployment and assignment step is its own file under
    # code\EmbeddedScripts, read once here. Start-WebStepJob writes the one it
    # needs to a temporary .ps1 inside RootPath (several find the app's own
    # folders relative to themselves) and runs it through the step runner.
    $Global:App.EmbeddedPackageScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\Package.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedCreateAppScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\CreateApp.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedCreateStoreAppScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\CreateStoreApp.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedCreateOfficeAppScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\CreateOfficeApp.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedTargetedAssignScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\TargetedAssign.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedBatchAssignScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\BatchAssign.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedDeleteAppScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\DeleteApp.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedGroupManagerScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\GroupManager.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedSyncMetadataScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\SyncMetadata.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedCertUploadScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\CertUpload.ps1") -Raw -Encoding UTF8
    $Global:App.EmbeddedPlatformScriptsScript = Get-Content -Path (Join-Path $RootPath "code\EmbeddedScripts\PlatformScripts.ps1") -Raw -Encoding UTF8
}
