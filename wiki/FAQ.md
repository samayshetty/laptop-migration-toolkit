# ❓ FAQ

<div align="center">

[Home](Home) &#183; [Setup](First-Time-Setup) &#183; [GUI](Using-the-GUI) &#183; [Getting Started](Getting-Started) &#183; [Collect](Collect-from-the-Old-Laptop) &#183; [Verify](Verify-the-Package) &#183; [Restore](Restore-on-the-New-Laptop) &#183; [Delta Sync](Delta-Sync) &#183; [App Modes](App-Selection-and-Granularity) &#183; [Conflicts](Conflicts-and-Version-Mismatch) &#183; [Security](Security-and-Privacy) &#183; [No Admin](No-Administrator-Rights) &#183; [Troubleshooting](Troubleshooting) &#183; [FAQ](FAQ)

</div>

---

**Does it work between different Windows versions (10 -> 11)?**
Yes. Incompatible visual items (taskbar layout, theme, pinned items) are
pre-set to skip and everything is documented in the plan - you can override
item by item.

**Can I migrate between different hardware brands?**
Yes, it is fully hardware-independent. Manufacturer utilities (Lenovo Vantage,
Dell Command, HP Support Assistant) are apps like any other - some have no
winget package and must be installed from the vendor.

**Are browser passwords transferred?**
No, by design. Use Chrome/Edge sign-in sync (passwords, history, tabs) - it is
safer and works continuously afterwards. Bookmarks are transferred as a file.

**Is Windows/Office licensing transferred?**
No. Windows activation follows your hardware/digital license or corporate
activation automatically. Office and other licensed apps are company/vendor
managed - reinstall from the proper source.

**Can I migrate only SOME apps?**
Yes - that's the core feature. `-InteractiveApps` during collection and/or the
apps editor (`a`) during restore gives you per-app modes:
install + data, app only, data only, skip. See
[App Selection and Granularity](App-Selection-and-Granularity).

**Can I migrate data without installing the app?**
Yes - that's the `data` mode. Useful for apps IT installs for you.

**Does it copy my whole user profile?**
No. It copies selected folders (Desktop, Documents, ... with
`-IncludeUserFiles`) plus curated config folders (dev tools, agents, visuals).
Application caches, browser profiles, and AppData apps generally do not
transfer - that is intentional to avoid corruption.

**How big will the package be?**
Without files: typically under 200 MB (agent histories/conversations can add
GBs). With `-IncludeUserFiles`: as big as your chosen folders.

**Can I run the restore twice if something fails?**
Yes, it is idempotent and safe; already-installed apps and applied items are
detected, and overwritten things are backed up each time.

**What about my other machines' USB drive letter changing?**
`-PackagePath` accepts any path - just point it at the correct letter.

**Does the old laptop get modified?**
No. Collection is read-only (exports, copies). Nothing is changed or deleted.

**Can collection run unattended / scheduled?**
Yes: `-NonInteractive -NoElevate` - fully scriptable.

**Does restore need internet?**
Only for the winget app installations. Data/settings restore works offline.

**Will it work on Windows Server or in a VM?**
The scripts are plain PowerShell and mostly work; winget and some UI features
(Terminal settings, taskbar) may not apply. Treat it as best-effort outside
client Windows.

**Is there a rollback?**
Yes - every overwritten file and registry key is copied to
`MigrationBackup-<date>` on the Desktop with a full log. Restore files manually
or `reg import` the backups if you need to undo.

**Why does my corporate laptop block some steps?**
Intune/MDM policy can block registry changes or app installs. The toolkit logs
warnings and continues with what is allowed; policy-managed settings will be
re-applied by your company after sign-in regardless.
