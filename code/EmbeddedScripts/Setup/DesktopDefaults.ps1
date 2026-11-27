# ---------------------------------------------------------------- Intune App Catalog: Windows desktop defaults
# "Windows desktop defaults" in the starter set (2.38.77): how a new PC looks the first time someone signs in.
#   Taskbar    - only File Explorer and Edge pinned (new profiles); search as an icon; no Widgets, Task view, Chat or
#                Copilot button; aligned left.
#   Desktop    - the picture in this app's packages folder (wallpaper.jpg / .png / .bmp) - else solid black; no
#                shortcuts on the shared desktop; This PC and the Recycle Bin shown; Edge doesn't put its shortcut back.
#   Look       - dark mode for Windows and apps.
#   Lock screen- no Windows spotlight, no "fun facts, tips, tricks"; the picture above when there is one (Windows
#                Enterprise and Education - on Pro it is Windows' own picture).
#   Suggestions- no tips, suggestions, "finish setting up" pages or apps installed by Windows on its own.
# Defaults, not rules: they go into the default profile (everyone who signs in for the first time) and into the
# profiles already on the PC (after they sign in again) - each user can change them afterwards. Only Edge's desktop
# shortcut is held back by a policy. Install.ps1, Uninstall.ps1 and the detection script are the same text: $Action
# says which part runs. A new $SettingsVersion applies them again on PCs that had the last one.
# Log: C:\ProgramData\Microsoft\IntuneManagementExtension\Logs\IntuneAppCatalog-WindowsDesktopDefaults.log

$SettingsVersion = '1'
$MarkerKey = 'HKLM:\SOFTWARE\IntuneAppCatalog\Setup\WindowsDesktopDefaults'
$LogFile = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { [System.IO.Path]::GetTempPath() }) 'Microsoft\IntuneManagementExtension\Logs\IntuneAppCatalog-WindowsDesktopDefaults.log'

function Write-SetupLog([string]$Text) {
    if ($Action -eq 'Detect') { return }
    try { Add-Content -LiteralPath $LogFile -Value ('{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) -Encoding UTF8 } catch { $null = $_ }
}

function Set-SetupValue([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    # One registry value - said in the log when Windows refuses it (it protects a few, e.g. the Widgets button in a
    # signed-in profile), and the rest goes on.
    try {
        if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -Path $Path -Force -ErrorAction Stop) }
        [void](New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop)
        return $true
    }
    catch { Write-SetupLog "  not set: $Path\$Name ($($_.Exception.Message))"; return $false }
}

function Get-SetupWallpaper {
    # The picture put in this app's packages folder (any name starting with "wallpaper"), copied where every user can
    # read it. $null: none - the desktop is then solid black.
    $pic = @(Get-ChildItem -LiteralPath $PSScriptRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^wallpaper.*\.(jpe?g|png|bmp)$' } | Sort-Object Name) | Select-Object -First 1
    if (-not $pic) { return $null }
    $dir = Join-Path $env:SystemRoot 'Web\Wallpaper\IntuneAppCatalog'
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $dest = Join-Path $dir ('wallpaper' + $pic.Extension.ToLowerInvariant())
    Copy-Item -LiteralPath $pic.FullName -Destination $dest -Force
    return $dest
}

function Set-SetupUserDefaults([string]$Root, [string]$Wallpaper) {
    # Everything that is per user, under one profile's registry root (Registry::HKEY_USERS\<the profile>).
    $cv = "$Root\Software\Microsoft\Windows\CurrentVersion"
    # Dark mode.
    [void](Set-SetupValue "$cv\Themes\Personalize" 'AppsUseLightTheme' 0)
    [void](Set-SetupValue "$cv\Themes\Personalize" 'SystemUsesLightTheme' 0)
    # Taskbar: aligned left, search as an icon, no Task view / Widgets / Chat / Copilot buttons.
    $adv = "$cv\Explorer\Advanced"
    [void](Set-SetupValue $adv 'TaskbarAl' 0)
    [void](Set-SetupValue $adv 'ShowTaskViewButton' 0)
    [void](Set-SetupValue $adv 'TaskbarMn' 0)
    [void](Set-SetupValue $adv 'ShowCopilotButton' 0)
    [void](Set-SetupValue $adv 'TaskbarDa' 0)
    [void](Set-SetupValue "$cv\Search" 'SearchboxTaskbarMode' 1)
    # Desktop: This PC and the Recycle Bin shown.
    foreach ($view in 'NewStartPanel', 'ClassicStartMenu') {
        $k = "$cv\Explorer\HideDesktopIcons\$view"
        [void](Set-SetupValue $k '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' 0)
        [void](Set-SetupValue $k '{645FF040-5081-101B-9F08-00AA002F954E}' 0)
    }
    # Background: the picture, filling the screen - or solid black.
    if ($Wallpaper) {
        [void](Set-SetupValue "$Root\Control Panel\Desktop" 'Wallpaper' $Wallpaper 'String')
        [void](Set-SetupValue "$Root\Control Panel\Desktop" 'WallpaperStyle' '10' 'String')
        [void](Set-SetupValue "$Root\Control Panel\Desktop" 'TileWallpaper' '0' 'String')
        [void](Set-SetupValue "$cv\Explorer\Wallpapers" 'BackgroundType' 0)
    }
    else {
        [void](Set-SetupValue "$Root\Control Panel\Desktop" 'Wallpaper' '' 'String')
        [void](Set-SetupValue "$Root\Control Panel\Colors" 'Background' '0 0 0' 'String')
        [void](Set-SetupValue "$cv\Explorer\Wallpapers" 'BackgroundType' 1)
    }
    # Lock screen without Windows spotlight and its "fun facts, tips, tricks"; no tips, suggestions, welcome pages or
    # apps Windows installs on its own.
    $cdm = "$cv\ContentDeliveryManager"
    foreach ($n in 'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled', 'SubscribedContent-338387Enabled', 'SubscribedContent-338388Enabled',
        'SubscribedContent-338389Enabled', 'SubscribedContent-310093Enabled', 'SubscribedContent-353694Enabled', 'SubscribedContent-353696Enabled',
        'SubscribedContent-353698Enabled', 'SystemPaneSuggestionsEnabled', 'SoftLandingEnabled', 'SilentInstalledAppsEnabled', 'OemPreInstalledAppsEnabled',
        'PreInstalledAppsEnabled', 'PreInstalledAppsEverEnabled', 'FeatureManagementEnabled') { [void](Set-SetupValue $cdm $n 0) }
    [void](Set-SetupValue "$cv\UserProfileEngagement" 'ScoobeSystemSettingEnabled' 0)
}

function Invoke-SetupOnHive([string]$File, [string]$Label, [string]$Wallpaper) {
    # A profile that isn't signed in: its registry file loaded for a moment, set, and unloaded again.
    $mount = 'IAC_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    & reg.exe load "HKU\$mount" $File 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-SetupLog "  $Label - its profile couldn't be loaded (in use?), left as it is"; return }
    try { Set-SetupUserDefaults "Registry::HKEY_USERS\$mount" $Wallpaper; Write-SetupLog "  $Label - set" }
    finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        for ($i = 0; $i -lt 5; $i++) { & reg.exe unload "HKU\$mount" 2>&1 | Out-Null; if ($LASTEXITCODE -eq 0) { break }; Start-Sleep -Seconds 1 }
    }
}

function Set-SetupTaskbarLayout {
    # Only File Explorer and Edge pinned - for every profile made from now on (Windows reads it at the first sign-in).
    $dir = Join-Path $env:SystemDrive 'Users\Default\AppData\Local\Microsoft\Windows\Shell'
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $xml = @'
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />
        <taskbar:DesktopApp DesktopApplicationID="MSEdge" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
'@
    Set-Content -LiteralPath (Join-Path $dir 'LayoutModification.xml') -Value $xml -Encoding UTF8
}

# ---------------------------------------------------------------- detection: found = this version applied
if ($Action -eq 'Detect') {
    $v = [string](Get-ItemProperty -LiteralPath $MarkerKey -Name Version -ErrorAction SilentlyContinue).Version
    if ($v -eq $SettingsVersion) { Write-Output "Windows desktop defaults $v applied."; exit 0 }
    exit 1
}

# ---------------------------------------------------------------- uninstall: what was set for the whole PC goes
if ($Action -eq 'Uninstall') {
    Write-SetupLog '---- Windows desktop defaults: removed'
    Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' -Name 'CreateDesktopShortcutDefault' -ErrorAction SilentlyContinue
    foreach ($n in 'LockScreenImagePath', 'LockScreenImageUrl', 'LockScreenImageStatus') { Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name $n -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Join-Path $env:SystemDrive 'Users\Default\AppData\Local\Microsoft\Windows\Shell\LayoutModification.xml') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $MarkerKey -Recurse -Force -ErrorAction SilentlyContinue
    # What each user has (dark mode, the taskbar, the background) stays as it is now - they may have changed it since.
    exit 0
}

# ---------------------------------------------------------------- install
Write-SetupLog "---- Windows desktop defaults $SettingsVersion"
$wallpaper = $null
try { $wallpaper = Get-SetupWallpaper } catch { Write-SetupLog "  the picture couldn't be copied: $($_.Exception.Message) - solid black instead" }
Write-SetupLog $(if ($wallpaper) { "  background: $wallpaper" } else { '  background: solid black (no wallpaper.* in the packages folder)' })

# The lock screen picture (Windows Enterprise and Education read it; Pro shows Windows' own picture).
if ($wallpaper) {
    $csp = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP'
    [void](Set-SetupValue $csp 'LockScreenImagePath' $wallpaper 'String')
    [void](Set-SetupValue $csp 'LockScreenImageUrl' $wallpaper 'String')
    [void](Set-SetupValue $csp 'LockScreenImageStatus' 1)
}
# Edge doesn't put its desktop shortcut back when it updates.
[void](Set-SetupValue 'HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate' 'CreateDesktopShortcutDefault' 0)

# The taskbar's pins for new profiles.
try { Set-SetupTaskbarLayout; Write-SetupLog '  taskbar: File Explorer and Edge for new profiles' } catch { Write-SetupLog "  taskbar layout not written: $($_.Exception.Message)" }

# No shortcuts on the shared desktop (installers put theirs there) and in the default profile's.
foreach ($desk in @((Join-Path $env:PUBLIC 'Desktop'), (Join-Path $env:SystemDrive 'Users\Default\Desktop'))) {
    foreach ($lnk in @(Get-ChildItem -LiteralPath $desk -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.lnk', '.url' })) {
        try { Remove-Item -LiteralPath $lnk.FullName -Force -ErrorAction Stop; Write-SetupLog "  removed from the desktop: $($lnk.Name)" } catch { Write-SetupLog "  not removed: $($lnk.FullName) ($($_.Exception.Message))" }
    }
}

# The default profile - everyone who signs in for the first time.
$defaultHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
if (Test-Path -LiteralPath $defaultHive) { Invoke-SetupOnHive $defaultHive 'default profile (new users)' $wallpaper }

# The profiles already on the PC - local, domain and Entra ID accounts; a signed-in one directly.
foreach ($p in @(Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^S-1-(5-21|12-1)-' })) {
    $sid = $p.PSChildName
    $dir = [string](Get-ItemProperty -LiteralPath $p.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
    if (Test-Path -LiteralPath "Registry::HKEY_USERS\$sid") { Set-SetupUserDefaults "Registry::HKEY_USERS\$sid" $wallpaper; Write-SetupLog "  $dir - set (signed in: after signing in again)" }
    elseif ($dir -and (Test-Path -LiteralPath (Join-Path $dir 'NTUSER.DAT'))) { Invoke-SetupOnHive (Join-Path $dir 'NTUSER.DAT') $dir $wallpaper }
}

[void](Set-SetupValue $MarkerKey 'Version' $SettingsVersion 'String')
[void](Set-SetupValue $MarkerKey 'Applied' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') 'String')
Write-SetupLog 'Done.'
exit 0
