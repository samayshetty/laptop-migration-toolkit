# laptop-migration-toolkit Wiki

Welcome! This toolkit moves a Windows laptop setup (apps, settings, visuals,
developer and AI-agent configurations, files) from an old laptop to a new one -
with per-app control and safe conflict handling.

## Three steps

1. [Collect from the old laptop](Collect-from-the-Old-Laptop)
2. [Verify the package](Verify-the-Package)
3. [Restore on the new laptop](Restore-on-the-New-Laptop)

## Everything else

- [Getting Started](Getting-Started) - requirements and the 5-minute overview
- [App Selection and Granularity](App-Selection-and-Granularity) - install app + data, app only, data only, or skip
- [Conflicts and Version Mismatch](Conflicts-and-Version-Mismatch) - what happens when the laptops differ
- [Security and Privacy](Security-and-Privacy) - what is sensitive in a package and how to handle it
- [Troubleshooting](Troubleshooting) - common errors and fixes
- [FAQ](FAQ) - licenses, browsers, corporate laptops and more

## What the scripts are

| Script | Runs on | Purpose |
| --- | --- | --- |
| `Collect-OldLaptop.ps1` | Old laptop | Builds the migration package |
| `Verify-Package.ps1` | New laptop | Read-only package review |
| `Restore-NewLaptop.ps1` | New laptop | Interactive plan + restore |

All scripts are plain PowerShell - they work on any Windows 10/11 pair and need
no agents or vendor tools. Everything they change on the new laptop is backed up
first into a `MigrationBackup-<date>` folder on the Desktop.
