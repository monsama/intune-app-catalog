<#
  Microsoft.Graph.Authentication sharing this window's process with a
  module that brought its own copy of the same .NET libraries.

  Every sign-in this window makes itself (Test connection, the lookups and
  pickers) imports the Graph module into a runspace of THIS process. .NET
  loads one version of an assembly per process, so when something already
  loaded Azure.Identity / Azure.Core / MSAL in a different version - Az,
  ExchangeOnlineManagement, PnP.PowerShell, MicrosoftTeams or an older
  Microsoft.Graph, usually from the PowerShell profile - the Graph module
  gets those instead of its own, and sign-in dies with something like:

    Method 'RefreshCacheAsync' in type '...InMemoryTokenCacheOptions' from
    assembly 'Microsoft.Graph.Authentication.Core, Version=2.41.2.0' does
    not have an implementation.

  Nothing in the tenant or the settings is wrong, and nothing short of a new
  process fixes it. So: recognise it (from the error, or beforehand from what
  is already loaded), say which module is in the way, and offer to start the
  app again without the profile. Pipeline steps aren't affected - they run
  in their own powershell.exe -NoProfile.
#>

function Global:Test-GraphAssemblyConflictText {
    <#
      $true when an error message is the "two versions of one assembly"
      failure rather than anything about the tenant. English and German
      wording, since the .NET Framework message is localized.
    #>
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $shapes = @(
        'does not have an implementation'
        'hat keine Implementierung'
        'Method not found'
        'Methode nicht gefunden'
        'Could not load (?:file or )?assembly'
        'Die Datei oder Assembly .{0,200}? konnte nicht geladen werden'
        'Assembly with same name is already loaded'
        'Eine Assembly mit dem gleichen Namen wurde bereits geladen'
        'Could not load type'
        'Der Typ .{0,200}? konnte nicht .{0,40}?geladen werden'
    )
    $libraries = 'Microsoft\.Graph|Azure\.Identity|Azure\.Core|Microsoft\.Identity\.Client|Microsoft\.IdentityModel|RefreshCacheAsync|TokenCache'
    foreach ($shape in $shapes) {
        if ($Text -match $shape -and $Text -match $libraries) { return $true }
    }
    return $false
}

function Global:Get-ModuleNameFromAssemblyPath {
    # "C:\...\Modules\Az.Accounts\2.12.1\lib\netfx\Azure.Core.dll" -> "Az.Accounts 2.12.1".
    # '' when the path isn't under a Modules folder.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if ($Path -match '[\\/]Modules[\\/]([^\\/]+)[\\/](\d+(?:\.\d+){1,3})[\\/]') { return "$($Matches[1]) $($Matches[2])" }
    if ($Path -match '[\\/]Modules[\\/]([^\\/]+)[\\/]') { return $Matches[1] }
    return ''
}

function Global:Get-GraphAssemblyConflicts {
    <#
      Pure: which already-loaded assemblies would collide with the Graph
      module's own.
        -ModuleAssemblies  @{ 'Azure.Core' = '1.44.1.0'; ... } - what the
                           module ships (name -> version, or several)
        -ModuleBase        the module's folder, to tell its own copies apart
        -LoadedAssemblies  objects with Name, Version, Location
      One row per collision: Name, Loaded, Expected, Location, Owner (the
      module that brought it, when the path says), SameModule ($true when
      it's another version of Microsoft.Graph.Authentication itself).
    #>
    param(
        [hashtable]$ModuleAssemblies,
        [string]$ModuleBase,
        [object[]]$LoadedAssemblies
    )
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not $ModuleAssemblies -or $ModuleAssemblies.Count -eq 0) { return @() }
    $base = if ($ModuleBase) { $ModuleBase.TrimEnd('\', '/') } else { '' }
    $seen = @{}
    foreach ($loaded in @($LoadedAssemblies)) {
        if (-not $loaded -or -not $loaded.Name) { continue }
        $name = [string]$loaded.Name
        # Only the sign-in libraries. The module also ships System.* and
        # similar helpers that PowerShell 7 itself loads in newer versions,
        # which is normal and harmless - flagging those would be crying wolf.
        if ($name -notmatch '^(Azure\.|Microsoft\.Identity|Microsoft\.IdentityModel\.|Microsoft\.Graph|Microsoft\.Kiota)') { continue }
        if (-not $ModuleAssemblies.ContainsKey($name)) { continue }
        # A version per copy the module ships (Desktop and Core folders can
        # differ) - matching any of them is fine.
        $expectedAll = @(@($ModuleAssemblies[$name]) | ForEach-Object { [string]$_ } | Where-Object { $_ })
        $have = [string]$loaded.Version
        if ($expectedAll.Count -eq 0 -or -not $have -or $expectedAll -contains $have) { continue }
        $expected = $expectedAll -join ' or '
        $location = [string]$loaded.Location
        # The module's own copy is never the problem, whatever it reports.
        if ($base -and $location -and $location.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $key = "$name|$have"
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $owner = Get-ModuleNameFromAssemblyPath $location
        $rows.Add([pscustomobject]@{
            Name       = $name
            Loaded     = $have
            Expected   = $expected
            Location   = $location
            Owner      = $owner
            SameModule = [bool]($owner -like 'Microsoft.Graph.Authentication*')
        })
    }
    return $rows.ToArray()
}

function Global:Test-SessionStartedWithoutProfile {
    # Whether this process was started with -NoProfile (or a short form of it).
    param([string[]]$Arguments = [Environment]::GetCommandLineArgs())
    foreach ($a in @($Arguments)) {
        if ($a -match '^[-/]nop(r(o(f(i(le?)?)?)?)?)?$') { return $true }
    }
    return $false
}

function Global:Format-GraphAssemblyConflictText {
    <#
      Pure: the explanation shown to the user, as plain text (so it can be
      copied straight out of the message box with Ctrl+C).
    #>
    param(
        [object[]]$Conflicts,
        [string[]]$LoadedModules,
        [string]$ErrorText,
        [bool]$NoProfile,
        [string]$GraphVersion
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("Microsoft Graph sign-in can't work in this window: another PowerShell module already loaded different versions of the libraries the Graph module$(if ($GraphVersion) { " $GraphVersion" }) needs. .NET can only hold one version per process, so nothing in Settings or the tenant can fix this - only a fresh PowerShell process can.")
    $lines.Add("")
    $conflicts = @($Conflicts | Where-Object { $_ })
    if ($conflicts.Count -gt 0) {
        $lines.Add("Already loaded in this window:")
        foreach ($c in $conflicts) {
            $from = if ($c.Owner) { "from $($c.Owner)" } elseif ($c.Location) { "from $($c.Location)" } else { "" }
            $lines.Add("  - $($c.Name) $($c.Loaded) (Graph needs $($c.Expected)) $from".TrimEnd())
        }
        $lines.Add("")
    }
    $modules = @($LoadedModules | Where-Object { $_ })
    if ($modules.Count -gt 0) {
        $lines.Add("Modules loaded in this window that commonly cause this: $($modules -join ', ')")
        $lines.Add("")
    }
    $sameModule = @($conflicts | Where-Object { $_.SameModule }).Count -gt 0
    if ($sameModule) {
        $lines.Add("More than one version of Microsoft.Graph.Authentication is installed. Keep only the newest:")
        $lines.Add("  Get-InstalledModule Microsoft.Graph.Authentication -AllVersions | Sort-Object Version -Descending | Select-Object -Skip 1 | Uninstall-Module -Force")
        $lines.Add("")
    }
    if ($NoProfile) {
        $lines.Add("This window was already started without a PowerShell profile, so a restart only helps if the module above was imported by something else in this session. If it comes back, remove the conflicting module version or start the app from a new console.")
    }
    else {
        $lines.Add("Usually the PowerShell profile imported the other module. Restarting the app without the profile avoids it:")
        $lines.Add("  powershell -NoProfile -ExecutionPolicy Bypass -File .\IntuneDeployment.ps1")
    }
    if ($ErrorText) {
        $lines.Add("")
        $lines.Add("Error: $($ErrorText.Trim())")
    }
    return ($lines -join "`r`n")
}

function Global:Get-GraphModuleAssemblyMap {
    <#
      Name -> version of every .dll the Graph module that Import-Module
      would pick ships with, plus its folder and version. Cached for the
      session (keyed by folder) - the module folder doesn't change under a
      running app, and this reads a few dozen files.
    #>
    # Cached as a whole: Get-Module -ListAvailable walks every module folder
    # on the machine (seconds, with a big PSModulePath or OneDrive), and
    # this runs before every Test connection. Installing the module from
    # Prerequisites... clears it.
    if ($Global:App.GraphModuleAssemblyMapCache) { return $Global:App.GraphModuleAssemblyMapCache }
    $module = Get-Module -ListAvailable -Name (Get-GraphModuleName) | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $module) { return $null }
    $map = @{}
    foreach ($dll in @(Get-ChildItem -LiteralPath $module.ModuleBase -Filter '*.dll' -Recurse -File -ErrorAction SilentlyContinue)) {
        try {
            $an = [System.Reflection.AssemblyName]::GetAssemblyName($dll.FullName)
            if (-not $map.ContainsKey($an.Name)) { $map[$an.Name] = @() }
            if ($map[$an.Name] -notcontains [string]$an.Version) { $map[$an.Name] += [string]$an.Version }
        }
        catch { }   # native DLLs and the like have no assembly name
    }
    $result = @{ ModuleBase = $module.ModuleBase; Version = [string]$module.Version; Assemblies = $map }
    $Global:App.GraphModuleAssemblyMapCache = $result
    return $result
}

function Global:Get-GraphAssemblyConflictReport {
    <#
      What's loaded in this process right now, measured against the Graph
      module. Conflicts is empty when nothing is in the way.
    #>
    $report = [pscustomobject]@{ Conflicts = @(); LoadedModules = @(); GraphVersion = ''; NoProfile = (Test-SessionStartedWithoutProfile) }
    try {
        $map = Get-GraphModuleAssemblyMap
        if (-not $map) { return $report }
        $report.GraphVersion = $map.Version
        $loaded = foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
            if ($asm.IsDynamic) { continue }
            $location = ''
            try { $location = $asm.Location } catch { }
            $an = $asm.GetName()
            [pscustomobject]@{ Name = $an.Name; Version = [string]$an.Version; Location = $location }
        }
        $report.Conflicts = @(Get-GraphAssemblyConflicts -ModuleAssemblies $map.Assemblies -ModuleBase $map.ModuleBase -LoadedAssemblies @($loaded))
        $suspects = 'Az.Accounts', 'Az', 'AzureAD', 'AzureADPreview', 'ExchangeOnlineManagement', 'PnP.PowerShell', 'MicrosoftTeams', 'MSAL.PS', 'Microsoft.Online.SharePoint.PowerShell', 'Microsoft.Graph.Authentication', 'Microsoft.Entra.Authentication'
        $report.LoadedModules = @(Get-Module | Where-Object { $suspects -contains $_.Name } | ForEach-Object { "$($_.Name) $($_.Version)" })
    }
    catch { }
    return $report
}

