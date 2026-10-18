# ⚡ Restore on the New Laptop

<div align="center">

[Home](Home) &#183; [Getting Started](Getting-Started) &#183; [Collect](Collect-from-the-Old-Laptop) &#183; [Verify](Verify-the-Package) &#183; [Restore](Restore-on-the-New-Laptop) &#183; [App Modes](App-Selection-and-Granularity) &#183; [Conflicts](Conflicts-and-Version-Mismatch) &#183; [Security](Security-and-Privacy) &#183; [No Admin](No-Administrator-Rights) &#183; [Troubleshooting](Troubleshooting) &#183; [FAQ](FAQ)

</div>

---

`Restore-NewLaptop.ps1` applies a package to the new laptop. It shows an
**editable migration plan** first - nothing is changed until you confirm.

## Command

```powershell
.\Restore-NewLaptop.ps1 -PackagePath "$env:OneDriveCommercial\MigrationPackage"
```

An **Administrator** PowerShell is recommended (the power scheme import needs it).
If you are not an Administrator, do not worry: the script detects that, does not ask
for elevation you cannot grant, marks the power scheme as SKIP, restores everything
else and reminds you at the end - see [No Administrator Rights](No-Administrator-Rights).

## The plan editor

You get a table like:

```
  1) [APPLY] Applications (install with winget)
        selected: 48 of 61; with data: 5. Press 'a' to change modes.
  2) [APPLY] Agent/skill configs (opencode, Claude, Codex, Gemini, Cursor)
  3) [APPLY] Visuals, theme, taskbar, wallpaper (3 pre-set to SKIP - press 'p' to review)
        OS changed (...): taskbar layout, theme, pinned items are pre-set to SKIP - you can override.
  ...
 Commands: numbers toggle apply/skip | a = apps | p = personalization | f = files policy | s = save & run | q = quit
```

| Key | Action |
| --- | --- |
| numbers (`2,5`) | Toggle that item APPLY/SKIP |
| `a` | Open the **apps editor** - per-app modes (see [App Selection](App-Selection-and-Granularity)) |
| `p` | Open the **visuals editor** - toggle individual registry items (theme, taskbar, audio/input, region, ...) |
| `f` | **Files policy** for personal folders: `k` keep existing (default), `r` replace, `s` skip all |
| `s` | Save the plan and run it |
| `q` | Quit without changing anything |

Then confirm with `Y` and let it run.

## Other modes

| Flag | Purpose |
| --- | --- |
| `-VerifyOnly` | Build + print the plan and exit. Nothing is changed - perfect first run. |
| `-NonInteractive` | No prompts; uses recommended defaults (automation). |
| `-SkipApps` | Never touch applications; restore only data/settings |
| `-SkipRegistry` | Skip all visuals/personalization registry items |
| `-SkipWifi` / `-SkipFonts` / `-SkipEnvVars` / `-SkipSSH` / `-SkipUserFiles` | Skip that specific bundle |
| `-SkipExplorerRestart` | Do not restart Explorer at the end (takes effect after next sign-in instead) |
| `-NoElevate` | Never prompt to relaunch as administrator |

## During the restore

- Apps are installed with a single `winget import` - already-installed apps are
  detected and skipped log-wise before that.
- Per-app data (when the app mode includes data) is restored right after apps.
- Everything that would overwrite an existing file or registry key is copied to
  a `MigrationBackup-<date>` folder on your Desktop first.
- Personal folders already synced by OneDrive are skipped to avoid duplicates.
- At the end, Explorer restarts once so taskbar/theme changes appear; a full
  **sign out or reboot** is recommended to apply everything (fonts, env vars,
  power scheme).

## After the restore

1. Sign out or reboot.
2. Check the apps: `apps\winget-list.txt` in the package lists everything the
   old laptop had - install anything winget could not get (licensed software
   like Office/Adobe usually comes from your IT department or vendor).
3. If something looked wrong, review `MigrationBackup-<date>\restore-log.txt`
   and the backups themselves.

## Running restore twice

It is safe. The second run detects installed apps, keeps existing files
according to your policy, and backs up anything it overwrites again.
