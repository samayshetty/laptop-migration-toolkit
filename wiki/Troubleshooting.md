# 🧰 Troubleshooting

<div align="center">

[Home](Home) &#183; [Setup](First-Time-Setup) &#183; [Getting Started](Getting-Started) &#183; [Collect](Collect-from-the-Old-Laptop) &#183; [Verify](Verify-the-Package) &#183; [Restore](Restore-on-the-New-Laptop) &#183; [App Modes](App-Selection-and-Granularity) &#183; [Conflicts](Conflicts-and-Version-Mismatch) &#183; [Security](Security-and-Privacy) &#183; [No Admin](No-Administrator-Rights) &#183; [Troubleshooting](Troubleshooting) &#183; [FAQ](FAQ)

</div>

---

## Scripts will not run

**"running scripts is disabled on this system"**

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
```

Run it in the same PowerShell window before the script (it resets when the
window closes - nothing permanent, no admin needed).

**"cannot be loaded because ... is not digitally signed"** - same fix.

**"not recognized as the name of a cmdlet"** - you are in the wrong folder.
Use `Set-Location` to the folder containing the scripts, then `.\ScriptName.ps1`.

## Administrator issues

- **Elevation prompt never appears** - you are probably already running in a
  session that cannot elevate (e.g. over SSH). Run the script from a normal
  desktop PowerShell right-clicked -> *Run as administrator*.
- **Wi-Fi passwords missing** - collection was not elevated. Re-run collect
  elevated, or just re-enter Wi-Fi passwords on the new laptop.
- **"Power scheme import failed"** - restore was not elevated. Re-run the
  restore elevated; everything else in the plan is already applied and safe to
  re-run.
- **I have no Administrator rights at all** - that is fine. The restore detects it,
  skips the power scheme (the only Administrator-only step), restores everything else
  and prints a reminder. The run still reports 0 errors. See
  [No Administrator Rights](No-Administrator-Rights).
- **Elevation prompt repeats / "The operation was canceled by the user"** - the UAC
  prompt was dismissed. The restore continues without Administrator rights, so just
  let it run; no action is needed.

## winget problems

**winget is not available** - install **App Installer** from the Microsoft
Store on that laptop, or install apps manually from `apps\winget-list.txt`.

**"--ignore-unavailable is not recognized"** - very old winget; the script
automatically retries without the flag.

**App installs take forever** - that is normal for large packages; `winget`
downloads and installs everything sequentially. It is safe to leave running.

**Some apps fail to install** - licensed software (Office, Adobe, ERP clients)
cannot come from winget. Install those through your company portal or vendor.

**App installs but data missing** - check the app's mode in the plan (must be
`both` or `data`) and that the data exists in the package (verifier lists it).

## VS Code extensions not installed

The script needs the `code` CLI. If VS Code was installed *during* the same
restore run, Windows PATH may not be refreshed - just run the restore again
(it will skip everything already done and install the extensions).

## Taskbar / theme / colors did not change

- The pre-set skips may have excluded taskbar items because the two laptops run
  different Windows generations (see [Conflicts](Conflicts-and-Version-Mismatch)).
  Check the plan output for yellow notes.
- Registry changes apply to Explorer after restart: sign out and back in, or
  the script already restarted Explorer once at the end.
- Not everything visual transfers between Windows 10 and 11 (e.g. widget layout).

## Wallpaper is black or missing

The wallpaper file itself is copied, but the `.reg` item referencing it may
have been skipped, or a theme was applied. Set it manually:
Settings -> Personalization -> Background. (The toolkit copies the old
wallpaper to your new profile - it is in the package under `personalization\`.)

## Files did not copy

- Desktop/Documents on the new laptop are OneDrive-managed - the toolkit
  deliberately skips them to avoid duplicates (log line: "already synced by
  OneDrive - skipping").
- Files policy was `keep` and same-named files were newer on the new laptop.
- Check the restore log for per-folder results.

## OneDrive says "sync pending" / files are placeholders

Restoring **from** a package that has not fully synced will copy placeholders.
Wait for the green checkmarks on the package folder (or use "Always keep on
this device") before running the restore.

## Fonts installed but not visible in apps

Sign out/in once. Some apps cache their font list (close and reopen them).
Fonts restricted by license may not render in all apps.

## Restore stopped midway

Nothing is corrupted - the restore is re-runnable. Fix the cause (e.g. install
winget, grant admin) and run the same command again. Already-restored items are
detected or harmlessly re-applied after being backed up.

## Something broke and I want to undo

Open the `MigrationBackup-<date>` folder on the Desktop:

- overwritten files are stored by sanitized full path name
- registry keys are stored as `regbackup-<name>.reg` - import with
  `reg import <file>` after signing in as the same user
- `restore-log.txt` lists everything the restore did with timestamps

## Report an issue

Open an issue in the repository with:
- the command you ran
- the colored output (or the contents of `collection-report.json` /
  `MigrationBackup-<date>\restore-log.txt`)
- both laptops' Windows versions (`winver`)
