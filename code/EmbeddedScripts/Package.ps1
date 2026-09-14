<#
.SYNOPSIS
    Universal Intune packager - handles both installers and PowerShell scripts
.DESCRIPTION
    Automatically scans folders and packages:
    - Traditional installers (.exe, .msi) - packaged as AppName.intunewin
    - PowerShell scripts (install.ps1) - packaged as AppName.intunewin
    Downloads IntuneWinAppUtil.exe automatically if not present.
    By default, saves .intunewin files in their source app folders.
.PARAMETER InputFolder
    Root folder to scan for apps
.PARAMETER OutputFolder
    Where to save all .intunewin packages (optional - if not specified, saves in each app's folder)
.PARAMETER ToolPath
    Path to IntuneWinAppUtil.exe
.PARAMETER Recursive
    Scan subfolders recursively
.PARAMETER SkipExisting
    Skip apps that are already packaged
.PARAMETER Force
    Overwrite existing packages
.EXAMPLE
    .\2_PackageApps.ps1
    (Saves .intunewin files in each app's source folder)
.EXAMPLE
    .\2_PackageApps.ps1 -OutputFolder "packages"
    (Saves all .intunewin files to central packages folder)
.EXAMPLE
    .\2_PackageApps.ps1 -Recursive -Force
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$InputFolder = "apps_common",
    
    [Parameter(Mandatory=$false)]
    [string]$OutputFolder = "",
    
    [Parameter(Mandatory=$false)]
    [string]$ToolPath = ".\IntuneWinAppUtil.exe",
    
    [Parameter(Mandatory=$false)]
    [switch]$Recursive,
    
    [Parameter(Mandatory=$false)]
    [switch]$SkipExisting,
    
    [Parameter(Mandatory=$false)]
    [switch]$Force,

    [Parameter(Mandatory=$false)]
    [string]$SingleFolderName = "",

    [Parameter(Mandatory=$false)]
    [string]$FolderNames = ""
)

$ErrorActionPreference = "Stop"

#region Tool Download
function Download-IntuneWinAppUtil {
    param([string]$DestinationPath)
    
    Write-Host "IntuneWinAppUtil.exe not found. Downloading..." -ForegroundColor Yellow
    
    $ToolFolder = Split-Path $DestinationPath -Parent
    if (-not (Test-Path $ToolFolder)) {
        New-Item -ItemType Directory -Path $ToolFolder -Force | Out-Null
    }
    
    $DownloadUrl = "https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/heads/master.zip"
    $ZipPath = Join-Path $env:TEMP "IntuneWinAppUtil.zip"
    $ExtractPath = Join-Path $env:TEMP "IntuneWinAppUtil_Extract"
    
    try {
        Write-Host "  Downloading from GitHub..." -ForegroundColor Gray
        
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipPath -UseBasicParsing
        $ProgressPreference = 'Continue'
        
        if (-not (Test-Path $ZipPath)) {
            throw "Download failed - zip file not found"
        }
        
        Write-Host "  Extracting..." -ForegroundColor Gray
        
        if (Test-Path $ExtractPath) {
            Remove-Item $ExtractPath -Recurse -Force
        }
        
        Expand-Archive -Path $ZipPath -DestinationPath $ExtractPath -Force
        
        $ExeFile = Get-ChildItem -Path $ExtractPath -Filter "IntuneWinAppUtil.exe" -Recurse | Select-Object -First 1
        
        if (-not $ExeFile) {
            throw "IntuneWinAppUtil.exe not found in downloaded package"
        }
        
        Write-Host "  Installing to: $DestinationPath" -ForegroundColor Gray
        Copy-Item -Path $ExeFile.FullName -Destination $DestinationPath -Force
        
        Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue
        
        if (Test-Path $DestinationPath) {
            Write-Host "  Successfully installed!" -ForegroundColor Green
            return $true
        } else {
            throw "Installation failed"
        }
    }
    catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $ExtractPath) { Remove-Item $ExtractPath -Recurse -Force -ErrorAction SilentlyContinue }
        return $false
    }
}
#endregion

#region Installer Functions
function Find-BestInstaller {
    param([string]$FolderPath)
    
    $Installers = Get-ChildItem -Path $FolderPath -File | Where-Object {
        $_.Extension -match '\.(exe|msi)$'
    }
    
    if ($Installers.Count -eq 0) { return $null }
    if ($Installers.Count -eq 1) { return $Installers[0] }

    # Prefer setup files with x64 in name
    $SetupX64 = $Installers | Where-Object { $_.Name -match '(setup|install)' -and $_.Name -match '(x64|64bit|amd64|win64)' } | Select-Object -First 1
    if ($SetupX64) { return $SetupX64 }

    # Then any setup file
    $Setup = $Installers | Where-Object { $_.Name -match '(setup|install)' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($Setup) { return $Setup }

    # Then MSI x64
    $MsiX64 = $Installers | Where-Object { $_.Extension -eq '.msi' -and $_.Name -match '(x64|64bit|amd64|win64)' } | Select-Object -First 1
    if ($MsiX64) { return $MsiX64 }

    # Then any MSI
    $Msi = $Installers | Where-Object { $_.Extension -eq '.msi' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($Msi) { return $Msi }

    # Then EXE x64
    $ExeX64 = $Installers | Where-Object { $_.Extension -eq '.exe' -and $_.Name -match '(x64|64bit|amd64|win64)' } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($ExeX64) { return $ExeX64 }

    # Then newest file
    $Newest = $Installers | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($Newest) { return $Newest }

    # Finally largest file
    return $Installers | Sort-Object Length -Descending | Select-Object -First 1
}

function Get-AppNameFromFile {
    param([string]$FileName)
    
    $Name = $FileName -replace '\.(exe|msi|ps1)$', ''
    $Name = $Name -replace '^(install|uninstall|detect)-', ''
    $Name = $Name -replace '[-_](x64|x86|64bit|32bit|amd64|win64|win32)', ''
    $Name = $Name -replace '[-_](setup|install|installer)', ''
    $Name = $Name -replace '[-_]v?\d+(\.\d+)*', ''
    $Name = $Name -replace 'Standalone|Enterprise', ''
    $Name = $Name -replace '[-_]+', ' '
    $Name = $Name.Trim()
    
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $FileName
    }
    
    return (Get-Culture).TextInfo.ToTitleCase($Name.ToLower())
}
#endregion

#region PowerShell Script Functions
function Get-AppNameFromScript {
    param([string]$ScriptPath)
    
    try {
        $Content = Get-Content -Path $ScriptPath -Raw -ErrorAction SilentlyContinue
        
        # Try to extract AppName from $AppConfig
        if ($Content -match '\$AppConfig\s*=\s*@\{[^}]*AppName\s*=\s*[''"]([^''"]+)[''"]') {
            return $Matches[1]
        }
        
        # Try to extract from WingetId
        if ($Content -match '\$AppConfig\s*=\s*@\{[^}]*WingetId\s*=\s*[''"]([^''"]+)[''"]') {
            $WingetId = $Matches[1]
            $Parts = $WingetId -split '\.'
            $AppPart = $Parts[-1]
            $Name = $AppPart -replace '[^a-zA-Z0-9\s]', ' '
            $Name = $Name.Trim()
            if ($Name) {
                return (Get-Culture).TextInfo.ToTitleCase($Name.ToLower())
            }
        }
        
        return $null
    }
    catch {
        return $null
    }
}

function Get-AppScope {
    param([string]$InstallScriptPath)
    
    try {
        $Content = Get-Content -Path $InstallScriptPath -Raw -ErrorAction SilentlyContinue
        
        if ($Content -match '\$AppConfig\s*=\s*@\{[^}]*Scope\s*=\s*[''"]([^''"]*)[''"]') {
            $Scope = $Matches[1]
            
            if ([string]::IsNullOrWhiteSpace($Scope)) {
                return ""
            }
            
            return $Scope
        }
        
        return ""
    }
    catch {
        return ""
    }
}

function Test-ScriptValidity {
    param([string]$ScriptPath)
    
    if (-not (Test-Path $ScriptPath)) {
        return $false
    }
    
    try {
        $Errors = $null
        $Content = Get-Content -Path $ScriptPath -Raw
        $null = [System.Management.Automation.PSParser]::Tokenize($Content, [ref]$Errors)
        return ($Errors.Count -eq 0)
    }
    catch {
        return $false
    }
}
#endregion

#region Helper Functions
function Get-SafeFileName {
    param([string]$Name)
    
    # Remove only characters that are invalid in Windows filenames: < > : " / \ | ? *
    $safeName = $Name -replace '[<>:"/\\|?*]', ''
    
    # Replace multiple spaces with single space, then spaces with hyphens
    $safeName = $safeName -replace '\s+', ' '
    $safeName = $safeName -replace '\s', '-'
    
    # Replace multiple hyphens/dots with single hyphen
    $safeName = $safeName -replace '[.-]+', '-'
    
    # Trim hyphens
    $safeName = $safeName.Trim('-')
    
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = "App-" + (Get-Random -Minimum 1000 -Maximum 9999)
    }
    
    return $safeName
}
#endregion

#region Main Script
Clear-Host
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  Universal Intune Packager" -ForegroundColor Cyan
Write-Host "  Handles: Installers (.exe, .msi) & PowerShell Scripts" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# Ensure IntuneWinAppUtil.exe is available
if (-not (Test-Path $ToolPath)) {
    if (-not (Download-IntuneWinAppUtil -DestinationPath $ToolPath)) {
        Write-Host ""
        Write-Host "Failed to download IntuneWinAppUtil.exe automatically." -ForegroundColor Red
        Write-Host "Please download manually from:" -ForegroundColor Yellow
        Write-Host "https://github.com/Microsoft/Microsoft-Win32-Content-Prep-Tool/releases" -ForegroundColor Yellow
        exit 1
    }
    Write-Host ""
}

# Validate input folder
if (-not (Test-Path $InputFolder)) {
    Write-Host "Error: Input folder not found: $InputFolder" -ForegroundColor Red
    exit 1
}

# Determine if using central output folder or per-app folders
$UseCentralOutput = -not [string]::IsNullOrWhiteSpace($OutputFolder)

if ($UseCentralOutput) {
    # Create central output folder if needed
    if (-not (Test-Path $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
        Write-Host "Created output folder: $OutputFolder" -ForegroundColor Green
        Write-Host ""
    }
    $OutputMode = "Central folder: $OutputFolder"
} else {
    $OutputMode = "Per-app folders (in source)"
}

Write-Host "Configuration:" -ForegroundColor White
Write-Host "  Input:         $InputFolder" -ForegroundColor Gray
Write-Host "  Output:        $OutputMode" -ForegroundColor Gray
Write-Host "  Tool:          $ToolPath" -ForegroundColor Gray
Write-Host "  Recursive:     $(if ($Recursive) { 'Yes' } else { 'No' })" -ForegroundColor Gray
Write-Host "  Skip existing: $(if ($SkipExisting) { 'Yes' } else { 'No' })" -ForegroundColor Gray
Write-Host "  Force:         $(if ($Force) { 'Yes' } else { 'No' })" -ForegroundColor Gray
Write-Host ""

Write-Host "Scanning for apps..." -ForegroundColor Cyan

# Find all apps (installers or scripts)
$AppsToProcess = @()

if ($Recursive) {
    $AllFolders = Get-ChildItem -Path $InputFolder -Recurse -Directory
} else {
    $AllFolders = Get-ChildItem -Path $InputFolder -Directory
}

if ($SingleFolderName) {
    $AllFolders = @($AllFolders | Where-Object { $_.Name -eq $SingleFolderName })
    if ($AllFolders.Count -eq 0) {
        Write-Host "Error: Folder '$SingleFolderName' not found under $InputFolder" -ForegroundColor Red
        exit 1
    }
}
elseif ($FolderNames) {
    $wantedNames = @($FolderNames -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $AllFolders = @($AllFolders | Where-Object { $wantedNames -contains $_.Name })
    if ($AllFolders.Count -eq 0) {
        Write-Host "Error: None of the requested folders were found under $InputFolder" -ForegroundColor Red
        exit 1
    }
}

foreach ($Folder in $AllFolders) {
    # Check for PowerShell script (install.ps1)
    $InstallScript = Get-ChildItem -Path $Folder.FullName -File -Filter "install.ps1" -ErrorAction SilentlyContinue
    
    if ($InstallScript) {
        # PowerShell-based WinGet app
        $AppName = Get-AppNameFromScript -ScriptPath $InstallScript.FullName
        
        if (-not $AppName) {
            $AppName = $Folder.Name
        }
        
        $Scope = Get-AppScope -InstallScriptPath $InstallScript.FullName
        
        $UninstallScript = Get-ChildItem -Path $Folder.FullName -File -Filter "uninstall.ps1" -ErrorAction SilentlyContinue
        $DetectScript = Get-ChildItem -Path $Folder.FullName -File -Filter "detect.ps1" -ErrorAction SilentlyContinue
        
        $AppsToProcess += [PSCustomObject]@{
            Type             = "Script"
            FolderName       = $Folder.Name
            FolderPath       = $Folder.FullName
            AppName          = $AppName
            Scope            = $Scope
            SourceFile       = $InstallScript
            SourceFileName   = "install.ps1"
            UninstallScript  = $UninstallScript
            DetectScript     = $DetectScript
            HasUninstall     = ($null -ne $UninstallScript)
            HasDetect        = ($null -ne $DetectScript)
        }
    }
    else {
        # Check for traditional installer
        $Installer = Find-BestInstaller -FolderPath $Folder.FullName
        
        if ($Installer) {
            $AppName = Get-AppNameFromFile -FileName $Installer.Name
            
            # Use folder name as fallback
            if ($AppName -eq $Installer.Name) {
                $AppName = $Folder.Name
            }
            
            $AppsToProcess += [PSCustomObject]@{
                Type             = "Installer"
                FolderName       = $Folder.Name
                FolderPath       = $Folder.FullName
                AppName          = $AppName
                Scope            = "machine"
                SourceFile       = $Installer
                SourceFileName   = $Installer.Name
                UninstallScript  = $null
                DetectScript     = $null
                HasUninstall     = $false
                HasDetect        = $false
            }
        }
    }
}

if ($AppsToProcess.Count -eq 0) {
    Write-Host "No apps found!" -ForegroundColor Red
    Write-Host ""
    Write-Host "Expected structures:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  PowerShell Scripts:" -ForegroundColor Cyan
    Write-Host "    $InputFolder\" -ForegroundColor Gray
    Write-Host "      AppName1\        <-- Folder with scripts" -ForegroundColor Gray
    Write-Host "        install.ps1    <-- Required" -ForegroundColor Gray
    Write-Host "        uninstall.ps1  <-- Optional" -ForegroundColor Gray
    Write-Host "        detect.ps1     <-- Optional" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Traditional Installers:" -ForegroundColor Cyan
    Write-Host "    $InputFolder\" -ForegroundColor Gray
    Write-Host "      Chrome\          <-- Folder with installer" -ForegroundColor Gray
    Write-Host "        setup.exe      <-- .exe or .msi file" -ForegroundColor Gray
    exit 1
}

$InstallerCount = ($AppsToProcess | Where-Object { $_.Type -eq "Installer" }).Count
$ScriptCount = ($AppsToProcess | Where-Object { $_.Type -eq "Script" }).Count

Write-Host "Found $($AppsToProcess.Count) app(s):" -ForegroundColor Green
Write-Host "  Traditional Installers: $InstallerCount" -ForegroundColor Cyan
Write-Host "  PowerShell Scripts:     $ScriptCount" -ForegroundColor Cyan
Write-Host ""

$SuccessCount = 0
$FailCount = 0
$SkipCount = 0
$Results = @()
$Counter = 0

foreach ($App in $AppsToProcess) {
    $Counter++
    
    Write-Host "[$Counter/$($AppsToProcess.Count)] $($App.Type): $($App.AppName)" -ForegroundColor Yellow
    if ($App.Type -eq "Script") {
        $u = if ($App.UninstallScript) { "uninstall:Y" } else { "uninstall:N" }
        $d = if ($App.DetectScript) { "detect:Y" } else { "detect:N" }
        Write-Host "  install:Y  $u  $d" -ForegroundColor Gray

        # Validate script syntax
        $scriptsToCheck = @($App.SourceFile.FullName)
        if ($App.UninstallScript) { $scriptsToCheck += $App.UninstallScript.FullName }
        if ($App.DetectScript) { $scriptsToCheck += $App.DetectScript.FullName }
        
        $AllValid = $true
        foreach ($ScriptPath in $scriptsToCheck) {
            if (-not (Test-ScriptValidity -ScriptPath $ScriptPath)) {
                Write-Host "  ERROR: Invalid syntax in $([System.IO.Path]::GetFileName($ScriptPath))" -ForegroundColor Red
                $AllValid = $false
            }
        }
        
        if (-not $AllValid) {
            $FailCount++
            Write-Host ""
            continue
        }
    }
    
    # Generate output filename
    $SafeAppName = Get-SafeFileName -Name $App.AppName
    $OutputFileName = "$SafeAppName.intunewin"
    
    # Determine final output path - either central folder or app's source folder
    if ($UseCentralOutput) {
        $FinalOutputPath = Join-Path $OutputFolder $OutputFileName
    } else {
        $FinalOutputPath = Join-Path $App.FolderPath $OutputFileName
    }
    
    # Check if package already exists
    if ((Test-Path $FinalOutputPath) -and $SkipExisting -and -not $Force) {
        $ExistingFile = Get-Item $FinalOutputPath
        $SourceModified = $App.SourceFile.LastWriteTime
        
        if ($SourceModified -le $ExistingFile.LastWriteTime) {
            Write-Host "  Package exists and is up-to-date - Skipping" -ForegroundColor DarkGray
            $SkipCount++
            Write-Host ""
            continue
        }
        Write-Host "  Repackaging (source newer than package)" -ForegroundColor Yellow
    }
    
    if ((Test-Path $FinalOutputPath) -and -not $Force -and -not $SkipExisting) {
        Write-Host "  WARNING: Package exists, use -Force to overwrite" -ForegroundColor Yellow
        $SkipCount++
        Write-Host ""
        continue
    }
    
    Write-Host "  Packaging..." -ForegroundColor Cyan
    
    try {
        # Create a unique temporary output folder for this app
        $TempOutputFolder = Join-Path $env:TEMP ("IntunePackaging_Output_" + (Get-Random))
        New-Item -ItemType Directory -Path $TempOutputFolder -Force | Out-Null
        
        # For installers, copy to temp folder first
        if ($App.Type -eq "Installer") {
            $TempSourceFolder = Join-Path $env:TEMP ("IntunePackaging_Source_" + (Get-Random))
            New-Item -ItemType Directory -Path $TempSourceFolder -Force | Out-Null
            Copy-Item -Path $App.SourceFile.FullName -Destination $TempSourceFolder -Force
            $PackageSourceFolder = $TempSourceFolder
            $SetupFile = $App.SourceFileName
        }
        else {
            # For scripts, use the folder directly
            $PackageSourceFolder = $App.FolderPath
            $SetupFile = $App.SourceFileName
        }
        
        # Build arguments for IntuneWinAppUtil - use temp output folder
        $Args = @(
            "-c", "`"$PackageSourceFolder`"",
            "-s", "`"$SetupFile`"",
            "-o", "`"$TempOutputFolder`"",
            "-q"
        )
        
        # Convert relative path to absolute path for ProcessStartInfo
        if (-not [System.IO.Path]::IsPathRooted($ToolPath)) {
            $ToolFullPath = Join-Path $PSScriptRoot $ToolPath
        } else {
            $ToolFullPath = $ToolPath
        }
        
        # Run packaging tool - suppress all output
        $ProcessInfo = New-Object System.Diagnostics.ProcessStartInfo
        $ProcessInfo.FileName = $ToolFullPath
        $ProcessInfo.Arguments = $Args -join " "
        $ProcessInfo.RedirectStandardError = $true
        $ProcessInfo.RedirectStandardOutput = $true
        $ProcessInfo.UseShellExecute = $false
        $ProcessInfo.CreateNoWindow = $true
        
        $Process = New-Object System.Diagnostics.Process
        $Process.StartInfo = $ProcessInfo
        $Process.Start() | Out-Null
        $Process.WaitForExit()
        
        $ExitCode = $Process.ExitCode
        
        # Clean up temp source folder for installers
        if ($App.Type -eq "Installer" -and (Test-Path $TempSourceFolder)) {
            Remove-Item $TempSourceFolder -Recurse -Force -ErrorAction SilentlyContinue
        }
        
        if ($ExitCode -eq 0) {
            # IntuneWinAppUtil creates "<setupfile>.intunewin" in the temp output folder
            $CreatedFile = Get-ChildItem -Path $TempOutputFolder -Filter "*.intunewin" -File | Select-Object -First 1

            if ($CreatedFile) {
                # Remove existing file if it exists
                if (Test-Path $FinalOutputPath) {
                    Remove-Item $FinalOutputPath -Force
                }
                
                # Move to final location with correct name
                Move-Item -Path $CreatedFile.FullName -Destination $FinalOutputPath -Force
                
                # Clean up temp output folder
                Remove-Item $TempOutputFolder -Recurse -Force -ErrorAction SilentlyContinue
                
                $Size = [math]::Round((Get-Item $FinalOutputPath).Length / 1KB, 2)
                
                # Show relative path if in app folder, otherwise full path
                if ($UseCentralOutput) {
                    $DisplayPath = $OutputFileName
                } else {
                    $DisplayPath = Join-Path $App.FolderName $OutputFileName
                }
                
                Write-Host "  Success: $DisplayPath ($Size KB)" -ForegroundColor Green
                
                $SuccessCount++
                
                $Results += [PSCustomObject]@{
                    Type         = $App.Type
                    App          = $App.AppName
                    Folder       = $App.FolderName
                    Scope        = $App.Scope
                    HasUninstall = $App.HasUninstall
                    HasDetect    = $App.HasDetect
                    Status       = "Success"
                    Package      = $OutputFileName
                    Location     = if ($UseCentralOutput) { $OutputFolder } else { $App.FolderPath }
                    SizeKB       = $Size
                }
            }
            else {
                Write-Host "  Failed: Output file not created" -ForegroundColor Red
                
                # Clean up temp folder
                if (Test-Path $TempOutputFolder) {
                    Remove-Item $TempOutputFolder -Recurse -Force -ErrorAction SilentlyContinue
                }
                
                $FailCount++
                
                $Results += [PSCustomObject]@{
                    Type         = $App.Type
                    App          = $App.AppName
                    Folder       = $App.FolderName
                    Scope        = $App.Scope
                    HasUninstall = $App.HasUninstall
                    HasDetect    = $App.HasDetect
                    Status       = "Failed"
                    Package      = ""
                    Location     = ""
                    SizeKB       = 0
                }
            }
        }
        else {
            Write-Host "  Failed (Exit code: $ExitCode)" -ForegroundColor Red
            
            # Clean up temp folder
            if (Test-Path $TempOutputFolder) {
                Remove-Item $TempOutputFolder -Recurse -Force -ErrorAction SilentlyContinue
            }
            
            $FailCount++
            
            $Results += [PSCustomObject]@{
                Type         = $App.Type
                App          = $App.AppName
                Folder       = $App.FolderName
                Scope        = $App.Scope
                HasUninstall = $App.HasUninstall
                HasDetect    = $App.HasDetect
                Status       = "Failed"
                Package      = ""
                Location     = ""
                SizeKB       = 0
            }
        }
    }
    catch {
        Write-Host "  Error: $($_.Exception.Message)" -ForegroundColor Red
        $FailCount++
    }
    
    Write-Host ""
}

# Summary
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Processed:  $($AppsToProcess.Count)" -ForegroundColor White
Write-Host "Success:    $SuccessCount" -ForegroundColor Green
Write-Host "Failed:     $FailCount" -ForegroundColor Red
Write-Host "Skipped:    $SkipCount" -ForegroundColor Yellow
Write-Host ""

if ($UseCentralOutput) {
    Write-Host "Output location: $OutputFolder" -ForegroundColor Cyan
} else {
    Write-Host "Output location: Each app's source folder" -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Done!" -ForegroundColor Green
#endregion
