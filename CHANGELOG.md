# Changelog

All notable changes to this project are documented in this file.

## [1.2.1] - 2026-10-29

Reliable VS Code / Insiders conversation recovery after a full backup or delta.

### Fixed

- Compare replayed `.json` / `.jsonl` conversation contents instead of file timestamps:
  reopening a stale chat no longer makes it win over a complete conversation.
- Preserve divergent, unreadable and ambiguous sessions for manual review. Keep backups
  and verify copied chat files; a failed delta is not recorded as applied.
- Merge matching chat-index entries in `state.vscdb` instead of replacing existing
  workspace/global databases. Preserve unrelated settings and new-laptop-only chats.
- Carry matching editing state, transcripts, attachments (`agentSessionData`) and
  checkpoints. Each fresh delta includes complete chat bundles even when their dates
  predate the cutoff, recovering chats omitted by older full backups.
- Handle transitions between JSON and JSONL chat storage with backups and verification.
- Use valid Windows special-folder names for optional Documents/Pictures collection.
- Process all unapplied deltas oldest first, retaining compatibility with older filenames.
  New delta filenames include seconds to avoid overwriting a previous run in the same minute.
- Do not advance the delta cutoff on copy/archive failures; snapshot SQLite databases
  with the Windows SQLite backup API.

### Changed

- Full collection keeps per-folder chats by default for both Stable and Insiders, plus
  attachments and `.copilot` configuration. `-IncludeVscodeHistory` only controls edit history.
- Both VS Code editions must be closed before collecting, restoring chat data, applying
  deltas or applying chat repairs. Launch the GUI from standalone Windows PowerShell.
- Full restore supports Insiders data/extensions and defers extension installation until
  both editions' data is restored.
- GUI hints, upgrade steps and troubleshooting now describe content-based recovery.

### Added

- Shared `ChatHistory.ps1` journal replay/comparison helpers.
- `Test-ChatRecovery.ps1`: isolated regression tests using synthetic chats, attachments,
  checkpoints and SQLite databases, without modifying live editor history.

## [1.2.0] - 2026-10-25

One-touch OneDrive transfers, delta sync, and fixes found during a real migration.

### Added

- `Sync-Delta.ps1` + GUI tasks **Delta: collect** / **Delta: apply**: carry over only what
  changed on the old laptop since the last sync, as one zip. Covers VS Code and VS Code
  Insiders (incl. Copilot chats and custom agents/prompts), Windows Notepad, Notepad++,
  OneNote options, all Chrome/Edge profiles, agent configs and dotfiles. Apply writes a file
  only when the old laptop's copy is newer, backs up everything it overwrites and skips a zip
  that was already applied. See wiki **Delta Sync**.
- `Repair-WorkspaceChats.ps1` + GUI task **Fix missing per-folder VS Code chats**: VS Code keys
  per-window chat history by folder path *and creation time*, so restored chats did not show
  in re-created folders. The script relinks them (backup first, preview by default).
- `MigrationCommon.ps1`: shared helpers (zip checksum sidecar, OneDrive wait, local extract,
  Windows CA bundle for the VS Code CLI, extension install with timeout).

### Changed

- `-Archive` now builds the package on the local disk and puts **only** `MigrationPackage.zip`
  plus a `.zip.json` checksum into the output location (no 40 000-file OneDrive upload). The
  GUI ticks it by default.
- Verify and Restore accept a zipped package (`-PackagePath` = the zip, or the folder name
  next to which the zip lives). They **wait for OneDrive** to deliver the whole file, verify
  its SHA-256 and extract it to `%LOCALAPPDATA%\laptop-migration-toolkit\package`.
- VS Code extensions are installed with the Windows certificate store handed to the CLI
  (fixes `unable to get local issuer certificate` behind TLS-inspecting proxies), with a
  per-extension timeout, and failures are now listed instead of reported as success.

### Fixed

- GUI: the title was clipped; the live log could crash a run with "file is being used by
  another process" because log reads locked the file.

## [1.1.0] - 2026-10-18

A window on top of the same toolkit - plus even friendlier documentation.

### Added

- `Start-MigrationGui.ps1`: an optional Windows Forms window (no install, no admin
  rights, nothing outside what ships with Windows) with
  - a task picker: Collect / Verify / Restore
  - folder field with `Browse...`, `Use default` and `Open scripts folder`
  - the relevant switches as checkboxes per task
  - a live, colour-coded log (green OK, amber warning, red error) streamed from the
    real script, a status line, elapsed time and a marquee progress bar
  - `Run` / `Stop`, `Package folder` / `Backups` openers, `Save log` / `Copy log`
  - a header that shows whether you are running as Administrator
  - the two genuinely interactive options (the app picker and the plan editor) open a
    normal console window, since they need typing
  - it runs the existing scripts unchanged via a generated helper that reports every
    output stream back into the window
- Wiki page **Using the GUI**, linked from Home, Getting Started and First-Time Setup.

### Changed

- All scripts bumped to `1.1.0`.
- README: GUI row in the scripts table, a "not a terminal person?" tip in Quick start,
  and the wiki table now lists Using the GUI.

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
- The README and the wiki were restyled: SVG banner, shields.io badges, emoji
  section headings, a consistent navigation bar on every wiki page, colour-coded
  GitHub alerts, collapsible parameters reference and a Mermaid flow diagram.
- New wiki page **First-Time Setup (absolute beginner)**: how to download the ZIP or
  clone the repo, where the files land, how to open PowerShell inside the `scripts`
  folder (three ways), how to open it as Administrator, how to unblock the files, the
  one-line execution-policy fix, sample good output, a table of first-run errors with
  exact fixes, a mini PowerShell lesson and a tick-off checklist. `Getting Started` was
  rewritten as a 6-step overview that links to it.

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
