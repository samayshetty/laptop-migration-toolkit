# 🎛️ App Selection and Granularity

<div align="center">

[Home](Home) &#183; [Setup](First-Time-Setup) &#183; [GUI](Using-the-GUI) &#183; [Getting Started](Getting-Started) &#183; [Collect](Collect-from-the-Old-Laptop) &#183; [Verify](Verify-the-Package) &#183; [Restore](Restore-on-the-New-Laptop) &#183; [App Modes](App-Selection-and-Granularity) &#183; [Conflicts](Conflicts-and-Version-Mismatch) &#183; [Security](Security-and-Privacy) &#183; [No Admin](No-Administrator-Rights) &#183; [Troubleshooting](Troubleshooting) &#183; [FAQ](FAQ)

</div>

---

You decide, per application, whether to install it and whether to carry over
its data. This works at two points:

1. **During collection** (`-InteractiveApps`) - chooses which apps go into the
   package selection (`apps/app-selection.json`).
2. **During restore** (press `a` in the plan editor) - final decision, can
   override the collection choice. This is the authoritative one.

## The four modes

| Mode | Installs the app | Restores its data | Typical use |
| --- | --- | --- | --- |
| `both` | yes | yes | Default for well-known apps |
| `app`  | yes | no | You want a fresh app without old settings |
| `data` | no | yes | App comes from IT/license, but you want your old settings |
| `skip` | no | no | Do not migrate this app at all |

In the apps editor, typing an app's number cycles its mode. Apps without known
data bundles cycle `app` <-> `skip` only.

## Apps with automatic data restore

| winget app | Data that is restored |
| --- | --- |
| `Microsoft.VisualStudioCode` | `settings.json`, keybindings, snippets, workspace storage + extension list reinstall |
| `Microsoft.WindowsTerminal` | `settings.json` (profiles, color schemes) |
| `Google.Chrome` | Bookmarks file |
| `Microsoft.Edge` | Bookmarks file |
| `Git.Git` | `~/.gitconfig` |

Data is only offered when it actually exists in the package - if the old laptop
had no VS Code settings, the app can only be installed (`app`/`skip`).

## Data bundles that are not tied to a specific app

These appear as their own rows in the plan editor and can be applied or skipped
independently:

- Agent/skill configs (`~/.config/opencode`, `~/.claude`, `~/.codex`, `~/.gemini`, `~/.cursor`, `AGENTS.md`, ...)
- Dotfiles (`.npmrc`, `.wslconfig`, `.vimrc`, `.aws`, `.kube`, ...)
- PowerShell profiles
- SSH keys
- Wi-Fi profiles
- Environment variables
- Visuals / personalization
- Personal folders

## How the pieces interact

- If an app is set to `both` or `data`, its data row in the plan is marked
  **"data tied to app selection"** and follows the app mode.
- If you set the app to `app` or `skip`, its data row is excluded - flip the
  app back to include the data again.
- Git config is special: it is also inside the "Dotfiles" bundle. If you use
  the Git app's data mode, only `.gitconfig` is restored; the Dotfiles row
  restores everything including `.gitconfig`.

## Examples

**Fresh VS Code, old settings:**
apps editor -> VS Code `data` (no install) -> VS Code is already on the new
laptop from IT, settings/extensions come from the package.

**Everything except games:**
collect with `-InteractiveApps`, untick games; or in restore, cycle each game
to `skip`.

**Only settings, no apps at all:**
run restore with `-SkipApps`.
