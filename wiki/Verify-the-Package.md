# 🔍 Verify the Package

<div align="center">

[Home](Home) &#183; [Setup](First-Time-Setup) &#183; [GUI](Using-the-GUI) &#183; [Getting Started](Getting-Started) &#183; [Collect](Collect-from-the-Old-Laptop) &#183; [Verify](Verify-the-Package) &#183; [Restore](Restore-on-the-New-Laptop) &#183; [App Modes](App-Selection-and-Granularity) &#183; [Conflicts](Conflicts-and-Version-Mismatch) &#183; [Security](Security-and-Privacy) &#183; [No Admin](No-Administrator-Rights) &#183; [Troubleshooting](Troubleshooting) &#183; [FAQ](FAQ)

</div>

---

> [!TIP]
> **First time running a PowerShell script?** [🧑‍🏫 First-Time Setup](First-Time-Setup) shows the
> exact clicks before you run this one.

`Verify-Package.ps1` is a **read-only** review of the collected package. Run it
on the new laptop before restoring - it answers "is everything really in there,
and what will happen when I restore?"

## Command

```powershell
.\Verify-Package.ps1 -PackagePath "$env:OneDriveCommercial\MigrationPackage"
```

No administrator rights needed.

## What it checks

1. **Structure** - is this really a package (`system-info.json` present)?
2. **Old machine info** - computer, user, domain, OS and build.
3. **Old vs new comparison**
   - Windows generation mismatch (10 <-> 11) -> warns that taskbar/theme items
     will be pre-set to skip during restore
   - different user profile path -> warns that paths will be translated
   - different domain/account -> warns that sign-ins (SSH, Git) may need re-auth
4. **Apps** - `winget-export.json` parses, how many apps; app selection from the
   old laptop (if any); missing/invalid inventory files
5. **Every bundle** - which of these are present: VS Code, Windows Terminal,
   PowerShell profiles, agent configs, dotfiles, Git config, bookmarks, SSH,
   Wi-Fi, power scheme, fonts, environment variables, personalization, files
6. **Registry files** - count and basic sanity (valid `.reg` headers)
7. **Wi-Fi profiles** - count and how many contain stored passwords
8. **Personal folders** - per-folder file counts and sizes
9. **Security scan** - looks for suspicious files by name (`id_rsa`, `*.pem`,
   `*.key`, `token`, ...) and warns; explicit warning when SSH keys are included

## Output

- Colored findings: `OK` (green), `WARN` (yellow), `ERROR` (red)
- Final verdict: package size, warnings, problems
- A report file is written next to the package: `verify-report.txt`
- Exit code: `0` = no problems, `1` = problems found (useful for automation)

The last line of the output shows the exact restore command to run next
(or `Restore-NewLaptop.ps1 -VerifyOnly` to preview the restore plan first).

## Typical warnings and what they mean

| Warning | Meaning |
| --- | --- |
| "OS GENERATION MISMATCH" | Normal for a Win10 -> Win11 move. The restore pre-skips incompatible visual items; you can override. |
| "Collected with an older toolkit" | The package was built by an older version - fully supported. |
| "profile path differs" | Different user name on the new laptop - handled automatically. |
| "Domain/account differs" | Sign-in related items may need re-authentication after restore. |
| "SSH keys ARE in this package" | Keep the package private; see [Security and Privacy](Security-and-Privacy). |

Next: [Restore on the New Laptop](Restore-on-the-New-Laptop)
