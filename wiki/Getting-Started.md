# Getting Started

## Requirements

- Windows 10 (1809 or newer) or Windows 11 on both laptops
- PowerShell 5.1 (built into Windows - no installation needed)
- `winget` (App Installer) on the new laptop for automatic app installation
- Administrator rights are **optional** - a standard user can run everything:
  - old laptop: only Wi-Fi passwords and the power scheme need elevation
  - new laptop: only the power scheme import needs elevation (skipped automatically
    if you are not an Administrator - see [No Administrator Rights](No-Administrator-Rights))
- A transfer medium: OneDrive/SharePoint folder, USB drive, or a network share

## Step 0 - get the scripts

Clone/download this repository, or copy the three files from `scripts/` to a
folder that is reachable from both laptops (for example OneDrive):

```
Collect-OldLaptop.ps1
Verify-Package.ps1
Restore-NewLaptop.ps1
```

## Step 1 - open an Administrator PowerShell

Any of these ways:

- Start menu -> type `powershell` -> right-click **Windows PowerShell** -> *Run as administrator*
- Or in Windows Terminal: right-click the tab > *Run as administrator*

Every example below assumes this administrator window. If you prefer not to use
administrator rights, you can still run everything - the scripts just warn that
Wi-Fi passwords and the power scheme will be skipped.

## Step 2 - allow the script to run (per window, nothing permanent)

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
Set-Location "C:\path\to\laptop-migration-toolkit\scripts"
```

`-Scope Process` only affects the current window and is reset when you close it.

## Step 3 - end-to-end commands

**On the OLD laptop:**

```powershell
.\Collect-OldLaptop.ps1 -OutputPath "$env:OneDriveCommercial\MigrationPackage" -InteractiveApps
```

(`$env:OneDriveCommercial` = your work OneDrive. For USB, use the drive letter,
e.g. `-OutputPath "E:\MigrationPackage"`.)

**On the NEW laptop** (after the package has fully synced/copied):

```powershell
.\Verify-Package.ps1 -PackagePath "$env:OneDriveCommercial\MigrationPackage"
.\Restore-NewLaptop.ps1 -PackagePath "$env:OneDriveCommercial\MigrationPackage"
```

The restore shows a plan you can edit before anything is applied. When it
finishes, sign out or reboot to apply everything.

## Time and size expectations

- Collection: a few minutes without personal files, 10-60+ minutes with
  `-IncludeUserFiles` depending on size (7+ GB is normal)
- Verification: seconds
- Restore: mostly the app installation time (`winget`), everything else is fast

Next: [Collect from the Old Laptop](Collect-from-the-Old-Laptop)
