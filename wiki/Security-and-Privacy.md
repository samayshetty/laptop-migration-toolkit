# 🔐 Security and Privacy

<div align="center">

[Home](Home) &#183; [Setup](First-Time-Setup) &#183; [Getting Started](Getting-Started) &#183; [Collect](Collect-from-the-Old-Laptop) &#183; [Verify](Verify-the-Package) &#183; [Restore](Restore-on-the-New-Laptop) &#183; [App Modes](App-Selection-and-Granularity) &#183; [Conflicts](Conflicts-and-Version-Mismatch) &#183; [Security](Security-and-Privacy) &#183; [No Admin](No-Administrator-Rights) &#183; [Troubleshooting](Troubleshooting) &#183; [FAQ](FAQ)

</div>

---

A migration package contains personal data. Treat it like a copy of your keys.

## What is sensitive inside a package

| Item | Sensitivity |
| --- | --- |
| `wifi/*.xml` | Wi-Fi passwords in clear text when collected elevated (`keyMaterial`) |
| `dev/ssh/` | SSH **private keys** (only if you did not pass `-SkipSSH`) |
| `personalization/startup-run.reg` | Autostart entries, possibly with tokens in command lines |
| `env/user-env.json` | Environment variables, may include tokens or API keys |
| `dev/dotfiles/` | `.npmrc` (registry tokens), `.aws`, `.kube` credentials |
| `dev/agent-configs/` | opencode/Claude/Codex/Gemini configs, AGENTS.md files |
| `files/` | Your documents, photos, and anything else you chose to copy |

## Rules of thumb

1. **Never commit a package to git** or upload it anywhere public. The repo's
   `.gitignore` already excludes `Package/`, `MigrationPackage*/` and
   `MigrationBackup*/` folders.
2. **Corporate cloud drives**: if you transfer through a company OneDrive,
   use `-SkipSSH` during collection and move SSH keys separately (USB or
   re-generate them - `ssh-keygen` - which is often cleaner anyway).
3. **Delete the package** from the transfer medium when the migration is done.
4. Keep the `MigrationBackup-<date>` folder private too - it contains old copies
   of your files and registry settings.

## What the toolkit does NOT copy

- Browser passwords/cookies (use browser sync)
- Windows credentials, BitLocker/TPM data
- Certificate stores (personal certificates in `certmgr` are not exported)

## Corporate (Intune/MDM) laptops

On a managed laptop:

- Company policy always wins at sign-in - some settings may be re-applied by
  policy after restore. This is normal and not a toolkit error.
- Apps installed by IT (VPN clients, security agents, Office) are usually
  re-pushed by Company Portal automatically; the winget export may not contain
  them.
- Wi-Fi export and power scheme need the elevation prompt to be accepted. Without
  Administrator rights they are skipped and the rest of the package is unaffected.
- Follow your company's data-handling rules when copying personal folders.

## Verifying package safety

`Verify-Package.ps1` includes a filename-based secret scan and explicitly tells
you when SSH keys or Wi-Fi passwords are inside, so you know how carefully the
package must be handled.
