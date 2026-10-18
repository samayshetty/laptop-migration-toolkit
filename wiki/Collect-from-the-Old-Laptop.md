# Collect from the Old Laptop

`Collect-OldLaptop.ps1` gathers everything into one package folder. It is
**read-only** - it never changes anything on the old laptop.

## Basic command

```powershell
.\Collect-OldLaptop.ps1 -OutputPath "$env:OneDriveCommercial\MigrationPackage" -InteractiveApps
```

Run it in an **Administrator** PowerShell so Wi-Fi passwords and the power
scheme are included. You can run it as a standard user as well - everything else
is collected, only Wi-Fi passwords and the power scheme are skipped (see
[No Administrator Rights](No-Administrator-Rights)).

## Parameters

| Parameter | What it does |
| --- | --- |
| `-OutputPath <folder>` | Where to build the package. Default: `Desktop\MigrationPackage-<date>`. Point it at OneDrive or a USB drive. |
| `-InteractiveApps` | Show the app list and choose exactly which apps to carry over (saved as `app-selection.json`). You can change this later during restore anyway. |
| `-IncludeUserFiles` | Also copy Desktop, Documents, Downloads, Pictures, Videos, Music. Skip this if those folders are already OneDrive-synced on both laptops. |
| `-ExtraFolders "D:\Projects","C:\code"` | Copy additional folders that live outside your user profile. |
| `-SkipSSH` | Do not collect `~\.ssh`. Use this whenever the package goes to any cloud drive (corporate OneDrive!). |
| `-SkipApps` | Skip the application inventory (rarely needed). |
| `-IncludeVscodeHistory` | Also collect VS Code edit history and workspace storage. These are caches and are excluded by default because they add tens of thousands of tiny files to the package. |
| `-IncludeCursorExtensions` | Also collect installed Cursor extensions (`.cursor\extensions`). Excluded by default. |
| `-Archive` | Also write the package as a single `.zip` next to the folder (uses `tar.exe`). Much faster to copy to a USB drive or upload to a cloud drive. |
| `-NonInteractive` | Never prompt (for automation). |
| `-NoElevate` | Do not offer to relaunch as administrator. |

## What the package contains

```
system-info.json          machine, user, OS and build, toolkit version
apps/                     winget export + selection, full installed-program list
personalization/          theme, taskbar, wallpaper, mouse/keyboard/region (.reg)
terminals/                Windows Terminal settings
dev/                      VS Code, agent configs (opencode, Claude, Codex, ...),
                          dotfiles, PowerShell profiles, SSH (unless -SkipSSH),
                          browser bookmarks
env/                      user environment variables
wifi/                     Wi-Fi profiles (passwords included when elevated)
power/                    active power scheme
fonts/                    user-installed font files + registry inventory
files/                    personal folders (only with -IncludeUserFiles)
collection-report.json    full log of the run
```

## The app selection editor

With `-InteractiveApps` you get a two-column numbered list:

- type numbers (`1,5,9`) to toggle apps in or out
- `a` all, `n` none, `i` invert, `s` save and continue

The choice is stored in `apps/app-selection.json` and pre-fills the restore
plan. Apps that have known "data" (VS Code, Chrome, Edge, Windows Terminal, Git)
are marked with data available - the final per-app mode (install + data / app /
data / skip) is chosen during restore.

## Good to know

- Running without administrator: everything works except Wi-Fi passwords and
  the power scheme (both are flagged with warnings).
- The old laptop can keep working normally afterwards - nothing is modified.
- Never commit a package to a repository or leave it in a shared folder; see
  [Security and Privacy](Security-and-Privacy).

Next: [Verify the Package](Verify-the-Package)
