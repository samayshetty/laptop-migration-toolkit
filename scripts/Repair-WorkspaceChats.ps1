<#
.SYNOPSIS
Preview or recover missing/stale per-folder chats in VS Code Stable and Insiders.
.DESCRIPTION
Run without -Apply for a read-only audit. Open the desired project folders once on
the new laptop first. For apply, close BOTH editions and use standalone PowerShell.
Recovery compares replayed conversation contents, not file dates. Matching editing
state and transcripts are copied with verified backups. Divergent, unreadable and
unindexed sessions are retained and reported, not silently replaced or republished.
Missing attachments/checkpoints require a fresh delta collection on the old laptop.
Stable and Insiders histories remain in their respective editions.
.EXAMPLE
.\Repair-WorkspaceChats.ps1
.EXAMPLE
.\Repair-WorkspaceChats.ps1 -Apply
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$BackupPath,
    # Kept for compatibility; workspace identity and chat content now determine the merge.
    [datetime]$NewLaptopSince = (Get-Item -LiteralPath $env:USERPROFILE).CreationTime,
    [switch]$Force,
    [switch]$NonInteractive,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ChatHistory.ps1')
$indexKey = 'chat.ChatSessionStore.index'
$flavors = @('Code', 'Code - Insiders')
function Log { param([string]$M, [string]$L = 'INFO') Write-Host ("[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'), $L, $M) }

function Read-ChatIndex([string]$Dir) {
    $db = Join-Path $Dir 'state.vscdb'
    if (-not (Test-Path -LiteralPath $db)) { return $null }
    $raw = [LmtSqlite]::Get($db, $indexKey)
    if (-not $raw) { return $null }
    $idx = (New-Json).DeserializeObject($raw)
    if (-not $idx.ContainsKey('entries')) { throw "Chat index has no entries: $db" }
    return $idx
}

Write-Host '=== Recover missing and stale VS Code per-folder chats ===' -ForegroundColor Cyan
if ($Apply -and (Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue)) {
    throw 'Close BOTH VS Code and VS Code Insiders, then run this from standalone PowerShell. -Force no longer bypasses this safety check.'
}
if (-not $BackupPath) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop -or -not (Test-Path -LiteralPath $desktop)) { $desktop = $env:USERPROFILE }
    $BackupPath = Join-Path $desktop ('MigrationBackup-chatmerge-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$planned = 0; $done = 0; $conflicts = 0; $failed = 0; $unindexed = 0
$verifiedBackups = @{}
foreach ($fl in $flavors) {
    $root = Join-Path $env:APPDATA "$fl\User\workspaceStorage"
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $rows = foreach ($dir in Get-ChildItem -LiteralPath $root -Directory) {
        $wj = Join-Path $dir.FullName 'workspace.json'
        if (-not (Test-Path -LiteralPath $wj)) { continue }
        try {
            $workspace = Get-Content -LiteralPath $wj -Raw | ConvertFrom-Json
            $uri = if ($workspace.folder) { $workspace.folder } else { $workspace.workspace }
            if ($uri) {
                [pscustomobject]@{ Dir = $dir.FullName; Identity = ([uri]::UnescapeDataString($uri)).TrimEnd('/').ToLowerInvariant() }
            }
        } catch { $failed++; Log "Cannot read ${wj}: $($_.Exception.Message)" 'ERROR' }
    }
    foreach ($group in ($rows | Group-Object Identity | Where-Object Count -gt 1)) {
        $versions = @{}
        $unreadable = @{}
        foreach ($row in $group.Group) {
            try {
                $idx = Read-ChatIndex $row.Dir
                $sessions = Join-Path $row.Dir 'chatSessions'
                if (-not (Test-Path -LiteralPath $sessions)) { continue }
                foreach ($file in Get-ChildItem -LiteralPath $sessions -File | Where-Object Extension -in '.json', '.jsonl') {
                    try {
                        $snapshot = Get-ChatSnapshot $file.FullName
                        $id = $snapshot.SessionId
                        if ($id -ne $file.BaseName -or $id -notmatch '^[a-zA-Z0-9-]+$') { throw 'Session ID does not match the filename or is unsafe' }
                        $entry = if ($idx -and $idx['entries'].ContainsKey($id)) { $idx['entries'][$id] } else { $null }
                        if (-not $versions.ContainsKey($id)) { $versions[$id] = @() }
                        $versions[$id] += [pscustomobject]@{ Dir = $row.Dir; File = $file.FullName; Snapshot = $snapshot; Entry = $entry; Index = $idx }
                    } catch {
                        $unreadable[$file.BaseName] = $true
                        $failed++; Log "Cannot read $($file.FullName): $($_.Exception.Message). This session will not be modified." 'ERROR'
                    }
                }
            } catch { $failed++; Log "Cannot inspect $($row.Dir): $($_.Exception.Message)" 'ERROR' }
        }
        foreach ($id in @($versions.Keys)) {
            if ($unreadable.ContainsKey($id)) { continue }
            $copies = @($versions[$id])
            $best = $copies[0]; $diverged = $false
            foreach ($copy in $copies | Select-Object -Skip 1) {
                $comparison = [LmtChatSnapshot]::Compare($copy.Snapshot, $best.Snapshot)
                if ($comparison -eq 'Conflict') { $diverged = $true; break }
                if ($comparison -eq 'Newer') { $best = $copy }
                elseif ($comparison -eq 'Same' -and $copy.Entry -and (-not $best.Entry -or [double]$copy.Entry['lastMessageDate'] -gt [double]$best.Entry['lastMessageDate'])) { $best = $copy }
            }
            if ($diverged) {
                $conflicts++
                Log "$fl | $($group.Name) | $id has divergent or ambiguous copies. All copies retained; manual review required." 'WARN'
                continue
            }
            if (-not $best.Entry -or -not $best.Index) {
                $unindexed++; continue
            }
            foreach ($target in $group.Group) {
                if ($target.Dir -eq $best.Dir) { continue }
                $existing = @($copies | Where-Object Dir -eq $target.Dir)
                if ($existing.Count -gt 1) { $failed++; Log "Multiple formats for $id in $($target.Dir); manual review required." 'ERROR'; continue }
                $current = if ($existing.Count) { $existing[0] } else { $null }
                $relation = [LmtChatSnapshot]::Compare($best.Snapshot, $(if ($current) { $current.Snapshot } else { $null }))
                $targetIndex = Read-ChatIndex $target.Dir
                $targetEntry = if ($targetIndex -and $targetIndex['entries'].ContainsKey($id)) { $targetIndex['entries'][$id] } else { $null }
                $metadataChanged = -not $targetEntry -or [double]$best.Entry['lastMessageDate'] -gt [double]$targetEntry['lastMessageDate']
                $sourceEdit = Join-Path $best.Dir "chatEditingSessions\$id"
                $targetEdit = Join-Path $target.Dir "chatEditingSessions\$id"
                $sourceState = Join-Path $sourceEdit 'state.json'
                $targetState = Join-Path $targetEdit 'state.json'
                $editingChanged = (Test-Path -LiteralPath $sourceState) -and (
                    -not (Test-Path -LiteralPath $targetState) -or
                    (Get-FileHash -LiteralPath $sourceState).Hash -ne (Get-FileHash -LiteralPath $targetState).Hash)
                if ($relation -eq 'Same' -and $editingChanged -and -not $metadataChanged) {
                    $conflicts++
                    Log "$fl | $id has equal chat content but different editing state with no newer index. Both states retained." 'WARN'
                    continue
                }
                if ($relation -ne 'Newer' -and -not $metadataChanged -and -not $editingChanged) { continue }
                $planned++
                $oldCount = if ($current) { $current.Snapshot.Count } else { 0 }
                $title = ($best.Entry['title'] -replace '\s+', ' ')
                if ($title.Length -gt 100) { $title = $title.Substring(0, 100) + '...' }
                Log "$fl | $title | $id | requests $oldCount -> $($best.Snapshot.Count) | target $(Split-Path -Leaf $target.Dir)" 'INFO'
                if (-not $Apply) { continue }
                try {
                    $backupKey = "$fl|$($target.Dir)"
                    if (-not $verifiedBackups.ContainsKey($backupKey)) {
                        $bk = Join-Path (Join-Path $BackupPath $fl) (Split-Path -Leaf $target.Dir)
                        if (Test-Path -LiteralPath $bk) { $bk += '-' + [guid]::NewGuid().ToString('N') }
                        Copy-ChatTree $target.Dir $bk
                        $verifiedBackups[$backupKey] = $bk
                    }
                    $bk = $verifiedBackups[$backupKey]
                    $destination = Join-Path (Join-Path $target.Dir 'chatSessions') (Split-Path -Leaf $best.File)
                    Copy-Shared $best.File $destination
                    if ((Get-FileHash -LiteralPath $best.File).Hash -ne (Get-FileHash -LiteralPath $destination).Hash) { throw 'Copied chat hash mismatch' }
                    if ($current -and $current.File -ne $destination) { Remove-Item -LiteralPath $current.File -Force }
                    Copy-ChatTree $sourceEdit $targetEdit
                    $transcript = "GitHub.copilot-chat\transcripts\$id.jsonl"
                    if (Test-Path -LiteralPath (Join-Path $best.Dir $transcript)) { Copy-Shared (Join-Path $best.Dir $transcript) (Join-Path $target.Dir $transcript) }
                    if (-not $targetIndex) { $targetIndex = @{ version = $best.Index['version']; entries = @{} } }
                    $targetIndex['entries'][$id] = $best.Entry
                    $targetDb = Join-Path $target.Dir 'state.vscdb'
                    if (-not (Test-Path -LiteralPath $targetDb)) { [LmtSqlite]::Initialize($targetDb) }
                    [LmtSqlite]::Set($targetDb, $indexKey, (New-Json).Serialize($targetIndex))
                    $verified = Read-ChatIndex $target.Dir
                    if ((New-Json).Serialize($verified['entries'][$id]) -ne (New-Json).Serialize($best.Entry)) { throw 'Chat index verification failed' }
                    $done++
                } catch { $failed++; Log "Recovery failed for $id in $($target.Dir): $($_.Exception.Message). Backup: $bk" 'ERROR' }
            }
        }
    }
}
if ($Apply) { Log "Recovered $done of $planned planned chat copies. Backup: $BackupPath" 'INFO' }
else { Log "Read-only preview: $planned chat copies need recovery. Close both editors, then rerun with -Apply." 'INFO' }
Log "Unresolved conflicts: $conflicts; unreadable/error cases: $failed; unindexed sessions retained without publishing: $unindexed" $(if ($conflicts -or $failed -or $unindexed) { 'WARN' } else { 'OK' })
if ($failed -or ($Apply -and $conflicts)) { exit 1 }
