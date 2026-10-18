# laptop-migration-toolkit

Move an entire Windows setup from one laptop to another - applications, settings,
visuals, developer and AI-agent configurations, Wi-Fi profiles, fonts and personal
files - with **per-app granularity** and **built-in conflict handling**.

Built as three PowerShell scripts that work on any Windows 10/11 laptop pair
(work, personal, mixed - no vendor tools required):

| Script | Run it on | What it does |
| --- | --- | --- |
| `scripts/Collect-OldLaptop.ps1` | Old laptop | Collects everything into one portable "migration package" |
| `scripts/Verify-Package.ps1` | New laptop | Read-only review of the package before you restore |
| `scripts/Restore-NewLaptop.ps1` | New laptop | Interactive plan editor + restore engine |

## Quick start

```powershell
# On the OLD laptop - an Administrator PowerShell is recommended (Wi-Fi passwords),
# but a standard user works too:
.\Collect-OldLaptop.ps1 -OutputPath "$env:OneDriveCommercial\MigrationPackage" -InteractiveApps

# On the NEW laptop:
.\Verify-Package.ps1 -PackagePath "$env:OneDriveCommercial\MigrationPackage"
.\Restore-NewLaptop.ps1 -PackagePath "$env:OneDriveCommercial\MigrationPackage"
```

The restore script shows an editable migration plan. Press `a` to choose per-app
modes, numbers to toggle items, `s` to run.

No Administrator rights on the new laptop? Everything is restored except the power
scheme, which the script skips automatically - see
[No Administrator Rights](wiki/No-Administrator-Rights.md).

## What gets migrated

- **Applications** - winget-based inventory; reinstall on the new laptop, choose exactly which ones
- **Per-app data** - VS Code (settings + extensions), Chrome/Edge bookmarks, Windows Terminal, Git config and more
- **Visuals** - theme, taskbar layout and pinned items, wallpaper, mouse/keyboard/region settings
- **Developer & agent configs** - opencode, Claude, Codex, Gemini, Cursor, PowerShell profiles, dotfiles
- **SSH keys** - optional, with locked-down permissions (never commit/share packages containing them)
- **Wi-Fi profiles** - with stored passwords when run elevated
- **User fonts**, **environment variables**, **power scheme**
- **Personal folders** - Desktop, Documents, Downloads, Pictures, Videos, Music (optional)

## Per-app granularity

For every app you can pick one of four modes (interactive editor, or saved in the
package during collection with `-InteractiveApps`):

| Mode | Meaning |
| --- | --- |
| `both` | Install the app **and** restore its data |
| `app`  | Install the app only |
| `data` | Restore the app's data only (no install) |
| `skip` | Ignore this app completely |

## Conflict and version-mismatch handling

- Windows 10 -> 11 (or newer build) detected: taskbar layout, theme and pinned items
  are **pre-set to skip** and flagged, because they frequently break across generations.
  You can override anything in the plan editor.
- Old/new laptops with different user names or domains: profile paths are translated.
- Existing files/settings on the new laptop: everything overwritten is backed up first
  (Desktop `MigrationBackup-<date>` folder), and personal files use a keep/replace/skip policy.
- Desktop/Documents already synced by OneDrive are skipped for files to avoid duplicates.
- Apps already installed are detected and not reinstalled.

## Requirements

- Windows 10 1809+ or Windows 11, PowerShell 5.1 (built-in)
- `winget` (App Installer) for automatic app installation
- Administrator rights are **optional**: only Wi-Fi passwords (on the old laptop) and
  the power scheme need them. A standard user can collect and restore everything else
- Any transfer medium: OneDrive/SharePoint, USB drive, network share

## Package size

The collector skips VS Code caches (`History`, `workspaceStorage`, ...) and installed
Cursor extensions by default, which keeps packages small. Add `-IncludeVscodeHistory`
or `-IncludeCursorExtensions` to keep them. If you use a cloud drive, `-Archive`
additionally writes a single `.zip`, which is much faster to upload than tens of
thousands of small files. Use a USB drive for the fastest transfer.

## Documentation

Full step-by-step wiki documentation lives in [`wiki/`](wiki/) - start with
`wiki/Getting-Started.md`. See `docs/PUBLISH-WIKI.md` to publish it as the GitHub wiki.

## Repository layout

```
scripts/   Collect-OldLaptop.ps1 | Verify-Package.ps1 | Restore-NewLaptop.ps1
wiki/      Full documentation (Getting-Started, Collect, Verify, Restore, ...)
docs/      Publishing helper for the GitHub wiki
```

## Security notes

Packages can contain personal data: Wi-Fi passwords, bookmark files, dotfiles and
(if enabled) SSH private keys. Keep packages in a private location and never commit
them to a repository - the included `.gitignore` already excludes them.

## License

MIT - see [LICENSE](LICENSE).
