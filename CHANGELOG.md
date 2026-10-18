# Changelog

All notable changes to this project are documented in this file.

## [1.0.1] - 2026-10-18

Standard-user support and smaller, faster packages.

### Added

- `Restore-NewLaptop.ps1` standard-user mode: when the account is not an
  Administrator, the script no longer asks for elevation it cannot get. It detects
  this automatically, skips Administrator-only steps (the power scheme) with a clear
  note in the plan, and reminds you at the end so you can re-run it elevated later.
  Every other item (apps with winget, VS Code, terminals, PowerShell profiles, agent
  configs, dotfiles, fonts, bookmarks, Wi-Fi profiles, environment variables) restores
  normally without Administrator rights.
- `Collect-OldLaptop.ps1 -Archive`: also write the package as a single `.zip` next to
  the folder (uses the built-in `tar.exe`). A single file is far easier to copy to a
  USB drive or upload than tens of thousands of small files.
- Package summary now reports the number of files as well as the size, warns when the
  package has a very large number of small files (cloud drives like OneDrive or
  SharePoint can take hours to sync that many), and lists any collected sign-in tokens
  so you remember to keep the package private and delete it afterwards.
- New wiki page: **No Administrator Rights**.

### Changed

- `Collect-OldLaptop.ps1` no longer copies the VS Code edit history and workspace
  storage (`History`, `workspaceStorage`, `CachedData`, `CachedExtensionVSIXs`,
  `Backups`, `logs`) by default, and no longer copies installed Cursor extensions
  (`.cursor\extensions`) by default. These are caches that made the package balloon to
  tens of thousands of files. Settings, keybindings, snippets and global storage are
  still collected. Use `-IncludeVscodeHistory` and `-IncludeCursorExtensions` to keep
  the old behaviour.
- All scripts bumped to `1.0.1`.

## [1.0.0] - 2026-10-17

First public release.

### Added

- `Collect-OldLaptop.ps1` - collects a portable migration package from the old laptop:
  - System information (OS, build, user profile, toolkit version)
  - Application inventory (winget export, winget list, registry inventory, Store apps)
  - Interactive app selection (`-InteractiveApps`) written to `apps/app-selection.json`
  - Visuals and personalization (theme, taskbar, wallpaper, input settings) as .reg exports
  - Developer and agent configurations (VS Code, Windows Terminal, PowerShell profiles,
    opencode / Claude / Codex / Gemini / Cursor configs, dotfiles, SSH keys - opt-out)
  - Browser bookmarks (Chrome / Edge)
  - Wi-Fi profiles (with passwords when run elevated)
  - Power scheme, user fonts, environment variables
  - Optional personal folders (`-IncludeUserFiles`, `-ExtraFolders`)
  - Self-elevation prompt (Administrator recommended for Wi-Fi passwords)
- `Verify-Package.ps1` - read-only package review before restoring:
  - Structure, JSON validity, counts and sizes per bundle
  - Old vs new machine comparison (OS, user profile, domain)
  - Secret scan (SSH keys, tokens, Wi-Fi passwords) with warnings
  - Recommended action list
- `Restore-NewLaptop.ps1` - applies a package on the new laptop:
  - Interactive migration plan editor (apply / skip per item)
  - Per-app granularity: install + data, app only, data only, skip
  - Version conflict handling (Windows 10 <-> 11, build changes) with recommended skips
  - Conflict handling for existing settings (backups kept), OneDrive-redirected folders,
    existing SSH keys, Wi-Fi duplicates
  - Old-to-new user profile path translation
  - `-VerifyOnly` pre-flight mode, `-NonInteractive` automation mode
  - Full backup of overwritten files and registry keys, detailed logs
- Wiki documentation (collect, verify, restore, app granularity, conflicts, security,
  troubleshooting, FAQ) and a helper to publish it.

### Notes

- Backward compatible: `Restore-NewLaptop.ps1` v1.0.0 can restore packages produced by
  the early (pre-release) collector.
