# Adding apps

**Apps > Add** opens *Add apps*, with several ways in. Every one ends in an
app in the catalog that's ready to deploy; the editor (double-click the
app) changes anything afterwards. Groups for the new apps go in the boxes
at the bottom - click a favourite group to add it (Shift-click: to
*Available for*).

## Winget

Type in the search box - results appear as you type. Tick every package
you want (click a row to tick it and see what winget says about it on the
right) and **Add**. Each app gets:

- winget's publisher, description, homepage, privacy URL and license;
- the shared Winget package's install and uninstall commands;
- with **Managed updates** ticked, winget's current version pinned, so new
  versions go to the pilot groups first.

Packages already in the catalog are marked *in the catalog* and can't be
picked again.

**Microsoft Store apps** (IDs like `9NBLGGH4NNS1` or `XP...`, marked
*Store*) are sent to Intune as native *Microsoft Store app (new)* apps -
no package to build, Intune installs them from the Store and the Store
keeps them up to date, so managed updates stay off for them.

## An installer (MSI or EXE)

Drop the file on the drop zone - or anywhere on the Apps list - or click it
to choose one. The file is uploaded to the app (this PC only) and read:

| | MSI | EXE |
|---|---|---|
| Name, publisher, version | ProductName, Manufacturer, ProductVersion | the file's version information |
| Install | `msiexec /i "file.msi" /qn /norestart` | the file with its maker's silent switch (Inno Setup, NSIS, WiX bundle, InstallShield, Advanced Installer) |
| Uninstall | `msiexec /x {ProductCode} /qn /norestart` | `Uninstall.ps1`, written beside it: runs the uninstaller Windows lists for the app, silently |
| Detection | the product code, this version or newer - managed updates possible | a script: the app as Windows lists it, this version or newer |

Check the proposal - an EXE whose maker isn't recognised needs its silent
switch - and **Add**. The installer is copied into the app's packages
folder (Packages\\*App-Name*), and with **Build the package now** the
.intunewin is built right away.

For an EXE, check the detection after one test install: the script looks
for the app's name as *Settings > Apps* shows it. For managed updates,
change it to a file rule by version in the editor.

## A PowerShell script

For anything that isn't one installer: a configuration, files to copy, a
few installers in a row. Give a name and a version, pick a template - *Run
an installer with arguments*, *Copy files to Program Files*, *Set registry
values*, or *Empty* - and change the scripts. They are checked for syntax
when you add the app.

- Both scripts run as SYSTEM with 64-bit PowerShell, from the package
  folder: put any files they need into Packages\\*App-Name* too.
- **Detection:** the template's last lines write a version marker
  (`HKLM\\SOFTWARE\\IntuneAppCatalog\\Apps\\<name>`, value *Version*). The
  app is detected by it, this version or newer - so managed updates can
  follow it. When you release a new version, change the version in
  Install.ps1 too. Or choose *A detection script of my own*.

Then **Package** the app and **Deploy** it, as any other.

## PSADT (PowerShell App Deployment Toolkit 4)

For installers that need more than a silent switch: closing running apps,
asking the user, deferrals, logging. Give a name, vendor and version and
**Add**. The app gets:

- the PSADT 4 template, downloaded from its GitHub release into
  Packages\*App-Name* (untick the box if the template is already there);
- the vendor, name and version filled into Invoke-AppDeployToolkit.ps1,
  and a version marker written after the install (removed after the
  uninstall) - the detection rule reads it, so managed updates can follow;
- the toolkit's own commands:
  `Invoke-AppDeployToolkit.exe -DeploymentType Install -DeployMode Silent`.

Put the installer in the folder's Files subfolder, write the install steps
in Invoke-AppDeployToolkit.ps1, then build the package and send it to
Intune.
