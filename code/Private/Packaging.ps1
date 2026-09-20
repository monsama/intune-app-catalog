# The two things this app needs before it can package anything, and how to
# get hold of them without leaving the app.
#
# Both used to be somebody else's problem. IntuneWinAppUtil.exe was
# downloaded silently by the packaging step the first time it ran, which is
# fine until the machine has no internet at the moment you press Package,
# and init.intunewin simply had to be there - a missing one failed every
# Winget app with "Package missing" and nothing offering to fix it.

function Global:Get-PackagingToolPath {
    <# Where IntuneWinAppUtil.exe is, whether or not it exists yet. #>
    return (Join-Path (Get-AppFolder -Kind Tools) 'IntuneWinAppUtil.exe')
}

function Global:Get-SharedPackagePath {
    <#
      Where init.intunewin is - the one package every Winget app deploys,
      since Winget itself does the installing and the package content is
      never used.

      Looks where it has always been kept first, so an install that
      already has one keeps using it wherever that is.
    #>
    $preferred = Join-Path (Get-AppFolder -Kind Shared) 'init.intunewin'
    if (Test-Path -LiteralPath $preferred) { return $preferred }
    $found = Get-ChildItem -Path $Global:App.RootPath -Recurse -Filter 'init.intunewin' -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $preferred
}

function Global:Get-PackagingReadiness {
    <#
      What is missing before anything can be packaged, as
      @{ ToolPath; ToolFound; ToolVersion; SharedPath; SharedFound }.
      One place to ask, so the Settings page and the packaging step agree.
    #>
    $toolPath = Get-PackagingToolPath
    $toolFound = Test-Path -LiteralPath $toolPath
    $version = ''
    if ($toolFound) {
        try { $version = (Get-Item -LiteralPath $toolPath).VersionInfo.FileVersion } catch { }
    }
    $sharedPath = Get-SharedPackagePath
    return @{
        ToolPath    = $toolPath
        ToolFound   = $toolFound
        ToolVersion = $version
        SharedPath  = $sharedPath
        SharedFound = (Test-Path -LiteralPath $sharedPath)
    }
}

function Global:Install-PackagingTool {
    <#
      Fetches Microsoft's Win32 Content Prep Tool into the Tools folder.

      The same source and the same steps the packaging step already used
      on its own - the difference is that this can be done deliberately,
      before a machine goes somewhere without internet, and it says where
      the file went.

      Returns @{ Ok; Message }. -LogBox gets the running commentary.
    #>
    param([System.Windows.Forms.RichTextBox]$LogBox)
    $target = Get-PackagingToolPath
    $folder = Split-Path $target -Parent
    $zip = Join-Path ([IO.Path]::GetTempPath()) "IntuneWinAppUtil-$([guid]::NewGuid().ToString('N').Substring(0,8)).zip"
    $extract = Join-Path ([IO.Path]::GetTempPath()) "IntuneWinAppUtil-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $say = {
        param($Text, $Color)
        Write-Log "$Text`r`n" $Color
        if ($LogBox) { Write-DialogLogLine -LogBox $LogBox -Text "$Text`r`n" }
    }
    try {
        if (-not (Test-Path -LiteralPath $folder)) { [void](New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop) }
        & $say "Downloading the Win32 Content Prep Tool from github.com/microsoft/Microsoft-Win32-Content-Prep-Tool..." ([System.Drawing.Color]::DeepSkyBlue)
        $previous = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try {
            Invoke-WebRequest -Uri 'https://github.com/microsoft/Microsoft-Win32-Content-Prep-Tool/archive/refs/heads/master.zip' -OutFile $zip -UseBasicParsing -ErrorAction Stop
        }
        finally { $ProgressPreference = $previous }

        Expand-Archive -Path $zip -DestinationPath $extract -Force -ErrorAction Stop
        $exe = Get-ChildItem -Path $extract -Filter 'IntuneWinAppUtil.exe' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $exe) { throw "The download did not contain IntuneWinAppUtil.exe." }
        Copy-Item -LiteralPath $exe.FullName -Destination $target -Force -ErrorAction Stop
        & $say "[OK] Packaging tool saved to $target" ([System.Drawing.Color]::LightGreen)
        return @{ Ok = $true; Message = "Saved to $target" }
    }
    catch {
        & $say "[FAILED] Could not get the packaging tool: $($_.Exception.Message)" ([System.Drawing.Color]::Tomato)
        return @{ Ok = $false; Message = $_.Exception.Message }
    }
    finally {
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Global:New-SharedWingetPackage {
    <#
      Builds init.intunewin.

      Every Winget app is deployed with this one package and none of them
      read a byte of it: the install command runs Winget-Install.ps1 on the
      device, and the detection rule asks Winget what is installed. So the
      content only has to be a valid package - a single readable file
      saying what it is, which is friendlier than an empty folder to
      anyone who opens it later.

      Returns @{ Ok; Message }. Needs the packaging tool, and says so
      rather than silently downloading it - one button, one thing.
    #>
    param([System.Windows.Forms.RichTextBox]$LogBox)
    $say = {
        param($Text, $Color)
        Write-Log "$Text`r`n" $Color
        if ($LogBox) { Write-DialogLogLine -LogBox $LogBox -Text "$Text`r`n" }
    }
    $tool = Get-PackagingToolPath
    if (-not (Test-Path -LiteralPath $tool)) {
        & $say "[FAILED] The packaging tool isn't here yet - use 'Download packaging tool' first." ([System.Drawing.Color]::Tomato)
        return @{ Ok = $false; Message = 'IntuneWinAppUtil.exe not found' }
    }
    $source = Join-Path ([IO.Path]::GetTempPath()) "init-source-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $outDir = Get-AppFolder -Kind Shared -Create
    try {
        [void](New-Item -ItemType Directory -Path $source -Force -ErrorAction Stop)
        $readme = @"
This package is deliberately empty.

Every Winget app in this catalog is deployed with it, because Winget does
the installing on the device (Winget-Install.ps1) and the detection rule
asks Winget what is present. Intune requires a package to be uploaded, so
this is that package - its contents are never read.

Generated by Intune App Catalog & Deployment.
"@
        Set-Content -LiteralPath (Join-Path $source 'init.txt') -Value $readme -Encoding UTF8 -ErrorAction Stop

        & $say "Building init.intunewin with $tool..." ([System.Drawing.Color]::DeepSkyBlue)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $tool
        $psi.Arguments = "-c `"$source`" -s `"$(Join-Path $source 'init.txt')`" -o `"$outDir`" -q"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(120000)) {
            try { $proc.Kill() } catch { }
            throw "IntuneWinAppUtil.exe did not finish within two minutes."
        }
        $built = Join-Path $outDir 'init.intunewin'
        if (-not (Test-Path -LiteralPath $built)) {
            $detail = (($stdout.Result + "`n" + $stderr.Result) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' / '
            throw "IntuneWinAppUtil.exe exited $($proc.ExitCode) without producing init.intunewin. $detail"
        }
        & $say "[OK] Shared Winget package built: $built" ([System.Drawing.Color]::LightGreen)
        return @{ Ok = $true; Message = $built }
    }
    catch {
        & $say "[FAILED] Could not build init.intunewin: $($_.Exception.Message)" ([System.Drawing.Color]::Tomato)
        return @{ Ok = $false; Message = $_.Exception.Message }
    }
    finally {
        Remove-Item -LiteralPath $source -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Global:Initialize-SharedWingetPackage {
    <#
      Makes sure init.intunewin exists, and offers to make it if it does
      not - fetching the packaging tool first when that is missing too.

      This is the one missing file this app can put back by itself. Every
      Winget app deploys with the same shared package, so "it isn't there"
      has exactly one answer, and sending somebody to Browse... for a file
      that has never existed on this machine is not it.

      Asks before doing anything: it downloads from the internet and
      writes into the Shared folder, neither of which should happen
      because somebody pressed Deploy. Returns $true when the package is
      there afterwards.
    #>
    param([System.Windows.Forms.RichTextBox]$LogBox)
    $state = Get-PackagingReadiness
    if ($state.SharedFound) { return $true }

    $question = "Every Winget app is deployed with one shared package, init.intunewin, and it isn't here yet:`r`n`r`n$($state.SharedPath)`r`n`r`nBuild it now?"
    if (-not $state.ToolFound) {
        $question += "`r`n`r`nMicrosoft's Win32 Content Prep Tool builds it, and isn't here either - it will be downloaded from github.com/microsoft first."
    }
    $question += "`r`n`r`nBoth folders can be changed under Settings > Folders."
    $answer = [System.Windows.Forms.MessageBox]::Show($question, "Shared package missing", "YesNo", "Question")
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return $false }

    $previousCursor = [System.Windows.Forms.Cursor]::Current
    [System.Windows.Forms.Cursor]::Current = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        if (-not $state.ToolFound -and -not (Install-PackagingTool -LogBox $LogBox).Ok) { return $false }
        return [bool](New-SharedWingetPackage -LogBox $LogBox).Ok
    }
    finally { [System.Windows.Forms.Cursor]::Current = $previousCursor }
}
