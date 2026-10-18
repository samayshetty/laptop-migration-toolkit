# 🔓 No Administrator Rights

<div align="center">

[Home](Home) &#183; [Setup](First-Time-Setup) &#183; [GUI](Using-the-GUI) &#183; [Getting Started](Getting-Started) &#183; [Collect](Collect-from-the-Old-Laptop) &#183; [Verify](Verify-the-Package) &#183; [Restore](Restore-on-the-New-Laptop) &#183; [App Modes](App-Selection-and-Granularity) &#183; [Conflicts](Conflicts-and-Version-Mismatch) &#183; [Security](Security-and-Privacy) &#183; [No Admin](No-Administrator-Rights) &#183; [Troubleshooting](Troubleshooting) &#183; [FAQ](FAQ)

</div>

---

Many corporate laptops are locked down: you are a **standard user** and cannot get
Administrator rights (UAC asks for credentials you do not have). The toolkit is built
to work in that situation.

## What still works without Administrator rights

On the **new laptop**, `Restore-NewLaptop.ps1` restores these without any elevation:

- Applications via `winget` (user-scope installs; some system-wide apps may need admin)
- VS Code settings and extensions
- Windows Terminal settings
- PowerShell profiles
- Agent/skill configs (opencode, Claude, Codex, Gemini, Cursor)
- Dotfiles (`.npmrc`, `.wslconfig`, `.vimrc`, `.gitconfig`, ...)
- Chrome / Edge bookmarks
- User-installed fonts (per-user install, `%LOCALAPPDATA%\Microsoft\Windows\Fonts`)
- Wi-Fi profiles (per-user, if you can add them)
- Environment variables (user scope)

## What is skipped

- **Power scheme** - `powercfg /import` needs Administrator rights.

The script detects that you are not an Administrator, does not ask you for elevation
you cannot grant, marks the power scheme as `SKIP` in the migration plan, and prints a
reminder at the end:

```
 Skipped (Administrator rights required): Power scheme.
 Everything else was restored. To apply the power scheme later, run this same
 script again from an Administrator PowerShell - re-running is safe.
```

Everything else is restored normally, and the run reports **0 errors** - a skipped
Administrator-only step is not a failure.

## Re-running later

If you get Administrator rights later (for example IT grants them), just run the same
command from an Administrator PowerShell:

```powershell
.\Restore-NewLaptop.ps1 -PackagePath "<package folder>"
```

The script is safe to re-run: existing settings are backed up again, and items you do
not need can be skipped in the plan editor.

## On the old laptop

Collecting also works without Administrator rights, with two limitations:

- Wi-Fi passwords are not exported (Windows requires elevation), so only profile names
  are collected
- The power scheme is not exported

Run the collector elevated on the old laptop when you can. If you cannot, everything
else is still collected and can be restored.

## Practical tips for locked-down laptops

- **Transfer medium**: if your corporate cloud drive (OneDrive/SharePoint) is sluggish
  or blocked, use a USB drive. The package is a plain folder (or a single `.zip` with
  `-Archive`).
- **winget**: some apps need Administrator rights to install system-wide. Use `winget`
  user scope when available, or ask IT to install the few apps that fail.
- **Keep the package private**: it can contain Wi-Fi passwords and sign-in tokens. Delete
  it once the migration is done.
