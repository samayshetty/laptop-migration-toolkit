# ⚠️ Conflicts and Version Mismatch

<div align="center">

[Home](Home) &#183; [Setup](First-Time-Setup) &#183; [GUI](Using-the-GUI) &#183; [Getting Started](Getting-Started) &#183; [Collect](Collect-from-the-Old-Laptop) &#183; [Verify](Verify-the-Package) &#183; [Restore](Restore-on-the-New-Laptop) &#183; [Delta Sync](Delta-Sync) &#183; [App Modes](App-Selection-and-Granularity) &#183; [Conflicts](Conflicts-and-Version-Mismatch) &#183; [Security](Security-and-Privacy) &#183; [No Admin](No-Administrator-Rights) &#183; [Troubleshooting](Troubleshooting) &#183; [FAQ](FAQ)

</div>

---

Migrating between two *different* laptops always involves differences. The
toolkit detects the common ones and either handles them automatically or asks
you - never silently breaking things.

## Windows version mismatch

During restore the old and new OS are compared:

| Situation | What happens |
| --- | --- |
| Windows 10 -> Windows 11 (or 11 -> 10) | Taskbar layout (`Taskband`, `StuckRects3`), theme, Explorer tweaks and DWM colors are **pre-set to SKIP** and flagged yellow in the plan. These frequently break across generations. Press `p` to review each item and override if you want. |
| Same generation, different build (feature update) | `Taskband` and taskbar settings are pre-set to skip; everything else applies. |
| Same generation and build | No pre-skips - everything applies. |

Everything else (wallpaper, input settings, region formats, apps, files,
configs) is version-tolerant and applies normally.

## Existing files and settings on the new laptop

Nothing is overwritten silently:

- **Every file, folder or registry key that gets replaced is first copied** to
  `MigrationBackup-<date>` on the Desktop (registry keys as `.reg` files).
- **Personal folders** use a policy you choose in the plan editor:
  - `keep` (default) - copy only files that do not exist yet
  - `replace` - old laptop versions overwrite new ones
  - `skip` - do not restore personal files at all
- **Desktop / Documents / Pictures** already redirected to OneDrive on the new
  laptop are skipped automatically to avoid duplicates in the cloud.

## Different user name or domain

- `C:\Users\olduser` -> `C:\Users\newuser` differences are translated in:
  - environment variables (including PATH entries)
  - the wallpaper file reference
- A different domain/account (e.g. moving between employers) cannot be
  translated - sign-in related things (SSH keys, Git credentials, browser
  logins) may require one-time re-authentication after restore. The verifier
  warns about this up front.

## Apps already installed

Before installing, the toolkit lists currently installed winget packages.
Apps that already exist are skipped at install time (`app`/`both` modes still
restore their data if selected) - so restoring onto a laptop that already has
some apps does not reinstall or downgrade them.

## Wi-Fi profile duplicates

`netsh wlan add profile` overwrites a profile with the same name with the old
laptop's version (including its saved password). Profiles that only exist on
the new laptop are untouched.

## SSH keys already on the new laptop

The restore **overwrites** `~\.ssh` with the package copy (after backing it up)
and re-applies locked-down NTFS permissions (user-only read for private keys).
If you generated fresh keys on the new laptop and want to keep them, skip the
SSH row in the plan editor.

## Power scheme

Imported as a new power plan and set active. If the old laptop used
manufacturer-specific schemes (Lenovo/Dell/HP software), the import may fail -
you get a warning and the current plan stays.

## Fonts

User-installed fonts are copied and registered per-user. System fonts and
licensing (e.g. corporate-licensed fonts installed machine-wide) are not
touched - reinstall those from their source.

## What is never migrated

- Browser passwords and cookies (by design - use the browser's own sync)
- Windows licenses, BitLocker keys, TPM-bound credentials
- Anything managed by company policy (Intune/MDM): VPN, certificates, security
  agents - Company Portal reinstalls those automatically on a corporate laptop
- Display scaling, monitor arrangement, default printer
