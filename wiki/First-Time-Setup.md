# 🧑‍🏫 First-Time Setup (absolute beginner)

<div align="center">

[Home](Home) &#183; [Setup](First-Time-Setup) &#183; [Getting Started](Getting-Started) &#183; [Collect](Collect-from-the-Old-Laptop) &#183; [Verify](Verify-the-Package) &#183; [Restore](Restore-on-the-New-Laptop) &#183; [App Modes](App-Selection-and-Granularity) &#183; [Conflicts](Conflicts-and-Version-Mismatch) &#183; [Security](Security-and-Privacy) &#183; [No Admin](No-Administrator-Rights) &#183; [Troubleshooting](Troubleshooting) &#183; [FAQ](FAQ)

</div>

---

> [!NOTE]
> **Never used GitHub or PowerShell before?** This page assumes you know nothing.
> Follow it top to bottom and you will have the toolkit running. Nothing here installs
> software or changes your PC - you are only downloading three text files and running them.

**What this page covers**

1. Download the toolkit to your laptop
2. Open PowerShell in the `scripts` folder
3. Open PowerShell as Administrator (optional)
4. Allow the script to run
5. Run the script
6. What you should see
7. Errors on the first run - exact fixes
8. Mini PowerShell lesson (the only 6 things you need)
9. Checklist

---

## 1. Download the toolkit to your laptop

You only need the files in `scripts/`. You can get them **two ways** - pick one:

| | Option A - Download ZIP | Option B - Clone with git |
| :--: | :-- | :-- |
| 👍 Best for | Almost everyone | People who already have `git` |
| 🧰 Needs | Nothing | `git` installed |
| 🚀 Speed | 10 seconds | 10 seconds |
| 🔄 Updating later | Download again | `git pull` |

### ✅ Option A - Download the ZIP (recommended)

<details open>
<summary><b>Show the 8 clicks</b></summary>

1. Open your browser and go to:
   **`https://github.com/samayshetty/laptop-migration-toolkit`**
2. Find the green **`<> Code`** button (top-right of the file list) and **click it**.
3. In the small menu, click **`Download ZIP`**.
4. Your browser downloads a file called **`laptop-migration-toolkit-main.zip`** (usually to your **Downloads** folder).
5. Open **File Explorer** (`Windows key + E`) and go to **Downloads**.
6. **Right-click** the zip file &#8594; **Extract All...**
7. In the box, type this path (so the folder is short and easy to type later):

   ```text
   C:\Migration
   ```

   &#8594; click **Extract**.
8. Open `C:\Migration` - you now have a folder called **`laptop-migration-toolkit-main`**.

**Optional but recommended:** rename that folder to **`laptop-migration-toolkit`**
(right-click &#8594; Rename), so your final path is:

```text
C:\Migration\laptop-migration-toolkit\scripts
```

</details>

> [!TIP]
> Keep the path short and without spaces or `OneDrive` inside it (e.g. use `C:\Migration`).
> It makes every command below easier to type and avoids long-path problems.

### ✅ Option B - Clone with git

Open a PowerShell window (any way - see section 2 above) and run:

```powershell
git clone https://github.com/samayshetty/laptop-migration-toolkit.git C:\Migration\laptop-migration-toolkit
```

Then go to `C:\Migration\laptop-migration-toolkit\scripts` - done.

**If `git` is not installed** you will see `git : The term 'git' is not recognized...`.
Either use Option A instead, or install git once:

```powershell
winget install --id Git.Git -e --source winget
```

Close and reopen PowerShell after installing.

### What the folder should look like

```text
C:\Migration\laptop-migration-toolkit\
├── scripts\          <-- the 3 files you will run
│   ├── Collect-OldLaptop.ps1
│   ├── Verify-Package.ps1
│   └── Restore-NewLaptop.ps1
├── wiki\
├── assets\
├── README.md
└── LICENSE
```

### ⛔ Do not skip: unblock the downloaded files (Option A only)

Windows marks files that came from the internet. Run this **once** after extracting
(in a PowerShell opened in `C:\Migration\laptop-migration-toolkit`):

```powershell
Get-ChildItem -Recurse | Unblock-File
```

> [!WARNING]
> Skip this and the scripts may refuse to start with
> *"cannot be loaded because running scripts is disabled"* or *"is not digitally signed"*.
> The fix is in section 7 below.

---

## 2. Open PowerShell in the `scripts` folder

Open File Explorer and go into **`C:\Migration\laptop-migration-toolkit\scripts`**
(you should see the three `.ps1` files). Then open PowerShell **in that exact folder**
using **any one** of these three ways:

<details open>
<summary><b>Way 1 - type into the address bar (fastest)</b></summary>

1. Click once on the **address bar** at the top of the Explorer window
   (the long box showing `C:\Migration\laptop-migration-toolkit\scripts`).
2. Delete the text, type **`powershell`** and press **Enter**.
3. A blue/black **Windows PowerShell** window opens **already inside that folder**.

</details>

<details>
<summary><b>Way 2 - Shift + right-click</b></summary>

1. Inside the folder, **hold Shift** and **right-click** any empty white space.
2. Choose **Open in Terminal** (Windows 11) or **Open PowerShell window here**
   (Windows 10 / classic menu).

</details>

<details>
<summary><b>Way 3 - open PowerShell normally, then navigate there</b></summary>

1. Press **Windows key**, type **`powershell`**, press **Enter**.
2. In the window, type this and press Enter (use **quotes** because the path has no
   spaces here, but quoting is a good habit):

   ```powershell
   cd "C:\Migration\laptop-migration-toolkit\scripts"
   ```

</details>

### ✔️ Check you are in the right place

Type these two commands (press **Enter** after each):

```powershell
Get-Location
Get-ChildItem
```

**✅ You should see something like:**

```text
Path
----
C:\Migration\laptop-migration-toolkit\scripts

    Directory: C:\Migration\laptop-migration-toolkit\scripts

Mode      LastWriteTime      Length Name
----      -------------      ------ ----
-a---     18/10/2026  20:42   24465 Collect-OldLaptop.ps1
-a---     18/10/2026  20:44   13024 Verify-Package.ps1
-a---     18/10/2026  20:43   43575 Restore-NewLaptop.ps1
```

If `Get-ChildItem` lists no `.ps1` files, you are in the wrong folder - repeat step 2.

---

## 3. Open PowerShell as Administrator (optional)

**You probably do not need this.** Read the table, then decide.

| What you want to do | Administrator needed? |
| :-- | :--: |
| 🖥️ **Collect** everything except Wi-Fi passwords and the power scheme | ❌ No |
| 📶 **Collect Wi-Fi passwords** (so the new laptop joins Wi-Fi automatically) | ✅ Yes |
| ⚡ **Restore** apps, settings, visuals, dev configs, fonts, Wi-Fi, files | ❌ No |
| 🔌 Restore the **power scheme** | ✅ Yes (skipped automatically if you are not an admin) |

Full details: [No Administrator Rights](No-Administrator-Rights).

<details open>
<summary><b>How to open PowerShell as Administrator</b></summary>

1. Press the **Windows key**.
2. Type **`powershell`**.
3. On the right side, click **Run as administrator**.
   (Or right-click **Windows PowerShell** in the results &#8594; **Run as administrator**.)
4. Windows asks *"Do you want to allow this app to make changes to your device?"*
   &#8594; click **Yes**.
5. The window title now starts with **"Administrator:"** - that is how you know it worked.

**Shortcut:** instead of steps 1-3, press **`Ctrl + Shift + Enter`** in the Start menu search.

**Check it with a command:**

```powershell
([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
```

`True` = you are elevated. `False` = you are a normal user (which is perfectly fine -
continue anyway).

</details>

> [!IMPORTANT]
> On a **corporate laptop** you may not be able to elevate at all, and the UAC prompt may
> ask for a password you do not have. Don't fight it: just close the prompt and run the
> script normally. Everything except the power scheme (and Wi-Fi passwords on the old
> laptop) still works.

---

## 4. Allow the script to run (one line, per window)

Windows blocks downloaded scripts by default. This one line lifts the block **only in
this window** - it is forgotten the moment you close it, and it changes nothing on your
system permanently.

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
```

**✅ You should see:** nothing at all (no output = success).
If you get a red error, you typed it in the wrong window - or the policy is locked down
machine-wide; see section 7 below.

---

## 5. Run the script

`.\` means *"the file in the folder I am currently in"*. Use **Tab** to auto-complete
file names.

### 🖥️ On the OLD laptop - collect your setup

```powershell
.\Collect-OldLaptop.ps1 -OutputPath "$env:OneDriveCommercial\MigrationPackage"
```

Add `-InteractiveApps` if you want to tick which apps travel over:

```powershell
.\Collect-OldLaptop.ps1 -OutputPath "$env:OneDriveCommercial\MigrationPackage" -InteractiveApps
```

**No OneDrive? Use a USB stick or a plain folder:**

```powershell
.\Collect-OldLaptop.ps1 -OutputPath "E:\MigrationPackage"
.\Collect-OldLaptop.ps1 -OutputPath "C:\Migration\MigrationPackage"
```

### 💻 On the NEW laptop - check the package, then restore

```powershell
.\Verify-Package.ps1  -PackagePath "$env:OneDriveCommercial\MigrationPackage"
.\Restore-NewLaptop.ps1 -PackagePath "$env:OneDriveCommercial\MigrationPackage"
```

Add `-VerifyOnly` to the restore if you only want to see the plan:

```powershell
.\Restore-NewLaptop.ps1 -PackagePath "$env:OneDriveCommercial\MigrationPackage" -VerifyOnly
```

> [!TIP]
> **"`$env:OneDriveCommercial` - what is that?"** It is a shortcut that PowerShell replaces
> with your work OneDrive folder, so you never have to type `C:\Users\YourName\OneDrive - Company`.
> Not sure where it points? Type `$env:OneDriveCommercial` and press Enter. If it prints
> nothing, just use a full path like `"C:\Migration\MigrationPackage"`.

---

## 6. What you should see

**✅ A good collection run ends like this:**

```text
[20:44:34] OK    Wi-Fi profiles exported with passwords (keep the package private)
[20:44:34] OK    Archive created: ...\MigrationPackage.zip (0.4 MB)

=========================================================
 Collection finished: 7450.2 MB in 862 files, 4 warnings, 0 errors
=========================================================
```

**✅ A good restore run ends like this:**

```text
=========================================================
 Restore finished: 3 warnings, 0 errors
=========================================================
 Backups of overwritten files/registry keys: C:\Users\...\Desktop\MigrationBackup-20261018-2028
 Full log: ...\MigrationBackup-20261018-2028\restore-log.txt
 Sign out or reboot to fully apply everything.
```

**`0 errors` is the number that matters.** Warnings are normal and are explained in the
run: they usually mean "this one item was skipped on purpose".

**Where files end up**

| What | Where |
| :-- | :-- |
| 📦 Migration package | The `-OutputPath` folder you chose |
| 🗃️ Backup of anything overwritten | `MigrationBackup-<date>` on your **Desktop** |
| 🧾 Full log of the run | `restore-log.txt` inside the backup folder |

---

## 7. Errors on the first run - exact fixes

| ❌ Message you see | ✅ What it means / fix |
| :-- | :-- |
| `cannot be loaded because running scripts is disabled on this system` | You skipped step 4 above. Run `Set-ExecutionPolicy -Scope Process Bypass -Force` in the same window, then try again. |
| `...Collect-OldLaptop.ps1 is not digitally signed. You cannot run this script on the current system.` | Same fix as above, or unblock the files: `Get-ChildItem -Recurse &#124; Unblock-File`. |
| `The term '.\Collect-OldLaptop.ps1' is not recognized as the name of a cmdlet...` | You are in the wrong folder. Run `Get-Location` - it must end in `\scripts`. Fix with `cd "C:\Migration\laptop-migration-toolkit\scripts"`. |
| `The term 'Collect-OldLaptop.ps1' is not recognized...` (no `.\` at the start) | Add the `.\`: `.\Collect-OldLaptop.ps1 ...` |
| `Cannot bind argument to parameter 'OutputPath' because it is an empty string` or an error about a path | The path has **spaces** or `$env:...` printed nothing. Wrap the path in **double quotes**: `-OutputPath "C:\My Documents\Migration"`. |
| `Access to the path 'C:\...' is denied` | Pick a folder you own (e.g. `C:\Migration\MigrationPackage` or your OneDrive), not `C:\Program Files` or `C:\Windows`. |
| `Running scripts is disabled` even after the Bypass line | Someone locked the policy machine-wide. Try: `powershell -ExecutionPolicy Bypass -File .\Collect-OldLaptop.ps1 -OutputPath "C:\Migration\MigrationPackage"` |
| The window flashes and disappears | You double-clicked the `.ps1` file. Always **open PowerShell first**, then run the script inside it. |
| `winget : The term 'winget' is not recognized...` (restore) | Install **App Installer** from the Microsoft Store on the new laptop (see [Troubleshooting](Troubleshooting)). |
| Red text but the run continues | Red lines inside the log markers are usually just warnings for one skipped item. Check the final line: if it says `0 errors`, you are good. |

Still stuck? Copy the **last 10 lines** of the window and check
[Troubleshooting](Troubleshooting) or the [FAQ](FAQ).

---

## 8. Mini PowerShell lesson (the only 6 things you need)

| I want to... | Type this |
| :-- | :-- |
| 👀 See which folder I am in | `Get-Location` |
| 📂 Go to another folder | `cd "C:\Migration\laptop-migration-toolkit\scripts"` |
| 📋 List what is in this folder | `Get-ChildItem` (or just `ls`) |
| 🧹 Clear the screen | `cls` |
| 🛑 Stop a running script | press **`Ctrl + C`** |
| 📋 Paste | **`Ctrl + V`** (in Windows Terminal you can also **right-click**) |

**Reading the prompt**

```text
PS C:\Migration\laptop-migration-toolkit\scripts>
```

- `PS` = you are in PowerShell
- `C:\...\scripts` = your current folder
- `>` = PowerShell is waiting for you to type

**Two golden rules**

1. Type the command, then press **Enter** to run it.
2. Paths with **spaces** always go inside **double quotes**: `"...\My Folder\..."`.
   Nothing happens when you type - PowerShell only acts on **Enter**.

---

## 9. Checklist

Copy this into your notes and tick it off:

```text
[ ] 1. Downloaded the toolkit (ZIP extracted to C:\Migration, or git clone)
[ ] 2. Unblocked the files (Get-ChildItem -Recurse | Unblock-File)
[ ] 3. Opened PowerShell inside ...\laptop-migration-toolkit\scripts
[ ] 4. Checked Get-ChildItem shows the 3 .ps1 files
[ ] 5. (Optional) Opened PowerShell as Administrator for Wi-Fi passwords
[ ] 6. Ran: Set-ExecutionPolicy -Scope Process Bypass -Force
[ ] 7. Ran: .\Collect-OldLaptop.ps1 -OutputPath "<where the package should go>"
[ ] 8. Waited for "Collection finished: ... 0 errors"
[ ] 9. Let the folder finish syncing (or copy it to a USB stick)
[ ] 10. On the new laptop: opened PowerShell in the same scripts folder
[ ] 11. Ran: .\Verify-Package.ps1 -PackagePath "<package folder>"
[ ] 12. Ran: .\Restore-NewLaptop.ps1 -PackagePath "<package folder>"
```

---

**Next:** [🚀 Getting Started](Getting-Started) &#183; [📦 Collect from the Old Laptop](Collect-from-the-Old-Laptop)
