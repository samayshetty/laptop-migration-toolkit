# 🖼️ Using the GUI

<div align="center">

[Home](Home) &#183; [Setup](First-Time-Setup) &#183; [GUI](Using-the-GUI) &#183; [Getting Started](Getting-Started) &#183; [Collect](Collect-from-the-Old-Laptop) &#183; [Verify](Verify-the-Package) &#183; [Restore](Restore-on-the-New-Laptop) &#183; [App Modes](App-Selection-and-Granularity) &#183; [Conflicts](Conflicts-and-Version-Mismatch) &#183; [Security](Security-and-Privacy) &#183; [No Admin](No-Administrator-Rights) &#183; [Troubleshooting](Troubleshooting) &#183; [FAQ](FAQ)

</div>

---

<img src="https://raw.githubusercontent.com/samayshetty/laptop-migration-toolkit/main/assets/banner.svg" alt="laptop-migration-toolkit" width="100%">

Prefer clicking to typing? `Start-MigrationGui.ps1` is a small window that drives the same
three scripts for you: pick the task, pick the folder, tick a few boxes, press **Run** and
watch the live log.

> [!NOTE]
> It is the **same toolkit** - the GUI only runs the existing scripts and shows their output.
> It needs nothing extra: no install, no admin rights, no external modules. Windows
> PowerShell 5.1 and the WinForms library that ships with Windows are enough.

---

## 🚀 Launch it

Open PowerShell in the `scripts` folder (see [First-Time Setup](First-Time-Setup) if unsure)
and run:

```powershell
.\Start-MigrationGui.ps1
```

<details>
<summary><b>Blocked by "running scripts is disabled"?</b></summary>

Use this instead - it bypasses the policy for this one window only:

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-MigrationGui.ps1
```

</details>

<details>
<summary><b>Prefer no terminal at all?</b></summary>

In File Explorer, go into the `scripts` folder, **right-click `Start-MigrationGui.ps1`**
&#8594; **Run with PowerShell**. If Windows blocks it, right-click the file &#8594;
**Properties** &#8594; tick **Unblock** &#8594; OK, then try again.

</details>

> [!TIP]
> For **Wi-Fi passwords on the old laptop**, start the GUI as Administrator once
> (right-click *Windows PowerShell* &#8594; *Run as administrator*, then run the command above).
> The header shows whether you are elevated.

---

## 🧭 What the window does

| Area | What it is |
| :-- | :-- |
| **1. What do you want to do?** | Pick **Collect**, **Verify** or **Restore** |
| **2. Folder** | Where the package lives (or will be created). `Browse...` picks it, `Use default` suggests OneDrive/Desktop |
| **3. Options** | The switches that matter for the selected task (see below) |
| **Log** | Live output, colour-coded: green = OK, amber = warning, red = error |
| **Run / Stop** | Starts the task, or stops it if something is wrong |
| **Package folder / Backups** | Opens the package folder, or the `MigrationBackup-<date>` folder created by a restore |
| **Save log / Copy log** | Keeps a copy of the run, e.g. to send to someone for help |

### Options per task

| Collect | Verify | Restore |
| :-- | :-- | :-- |
| Choose which apps to carry over | *(nothing - read-only)* | Dry run only (show the plan, change nothing) |
| Also copy Desktop, Documents, Downloads... | | Open the interactive plan editor in a console window |
| Also write a single `.zip` next to the folder | | Do not install applications |
| Do not collect SSH keys | | Skip visuals, theme, taskbar and wallpaper |
| Keep the VS Code edit history (larger) | | Skip Wi-Fi profiles |
| Keep installed Cursor extensions (larger) | | Skip user fonts |
| Skip the application inventory | | Skip environment variables / SSH keys / personal folders |
| | | Do not restart Explorer at the end |

---

## ⌨️ The two options that open a console window

Two things genuinely need a keyboard, so the GUI hands them over to a normal console window:

1. **Collect &#8594; Choose which apps to carry over** (the `-InteractiveApps` app picker)
2. **Restore &#8594; Open the interactive plan editor** (toggle individual items and per-app modes)

The GUI stays open; finish the prompts in the console window, then close it. Everything else
runs quietly inside the window with a live log.

> [!IMPORTANT]
> Without those two options, the GUI applies the **recommended defaults** - the same ones the
> scripts recommend on screen. If you want to exclude a single item or set a per-app mode
> (`both` / `app` / `data` / `skip`), use the plan editor option, or run the scripts directly
> as described in [Restore on the New Laptop](Restore-on-the-New-Laptop).

---

## ✅ A typical run

1. **Old laptop:** task = *Collect*, folder = `...\MigrationPackage`, options = your choice, **Run**.
2. Wait for the line **`Collection finished: ... 0 errors`** in the log.
3. Let OneDrive finish syncing (or copy the folder to a USB stick).
4. **New laptop:** task = *Verify*, folder = the package, **Run** - read the report in the log.
5. Task = *Restore*, folder = the package, **Run** - tick *Dry run only* first if you want a preview.
6. Sign out or reboot when it finishes. Use **Backups** to see what was changed.

`0 errors` is the number that matters - warnings are normal and explained in the log.

---

## 🚑 GUI problems

| Problem | Fix |
| :-- | :-- |
| `running scripts is disabled` when launching | Use `powershell -ExecutionPolicy Bypass -File .\Start-MigrationGui.ps1` |
| Window opens but closes instantly | You are not in an interactive desktop session, or the file is still blocked - unblock it (Properties &#8594; Unblock) |
| "Please choose a folder first" | Fill in step 2, or press **Use default** |
| Wi-Fi passwords missing after Collect | The GUI was not started as Administrator - see the tip above |
| Nothing seems to happen for a second or two | Normal - the child process is starting up; the log fills as it goes |
| Log is cut short after Stop | Stop kills the running step; re-run it - the scripts are safe to re-run |

---

**Next:** [📦 Collect from the Old Laptop](Collect-from-the-Old-Laptop) &#183; [⚡ Restore on the New Laptop](Restore-on-the-New-Laptop)
