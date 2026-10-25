[CmdletBinding()]
param(
    [switch]$Apply,
    [string]$BackupPath,
    # Workspace dirs whose workspace.json is newer than this were created on THIS laptop (default: when this Windows profile was created).
    [datetime]$NewLaptopSince = (Get-Item -LiteralPath $env:USERPROFILE).CreationTime,
    [switch]$NonInteractive,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Continue'
$flavors = @(
    @{ Name = 'Code';           Dir = Join-Path $env:APPDATA 'Code\User\workspaceStorage' },
    @{ Name = 'Code - Insiders'; Dir = Join-Path $env:APPDATA 'Code - Insiders\User\workspaceStorage' }
)

function Log { param([string]$M, [string]$L = 'INFO') Write-Host ("[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'), $L, $M) }

# VS Code derives the workspace-storage id from the folder's creation time, so a folder re-created on a
# new laptop gets a new id and its old chats look "missing". Copy the old data into the new id.
Write-Host ''
Write-Host '=== Relink VS Code per-window chat history ===' -ForegroundColor Cyan
if ($Apply -and (Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue)) {
    Log 'Close VS Code and VS Code Insiders first, then run again.' 'ERROR'
    exit 1
}
if (-not $BackupPath) { $BackupPath = Join-Path ([Environment]::GetFolderPath('Desktop')) ('MigrationBackup-chatrelink-' + (Get-Date -Format 'yyyyMMdd-HHmm')) }

$planned = 0; $done = 0
foreach ($fl in $flavors) {
    if (-not (Test-Path -LiteralPath $fl.Dir)) { continue }
    $rows = foreach ($d in Get-ChildItem -LiteralPath $fl.Dir -Directory) {
        $wj = Join-Path $d.FullName 'workspace.json'
        if (-not (Test-Path -LiteralPath $wj)) { continue }
        $folder = $null
        try { $o = Get-Content -LiteralPath $wj -Raw | ConvertFrom-Json; $folder = if ($o.folder) { $o.folder } else { $o.workspace } } catch { }
        if (-not $folder) { continue }
        $cs = Join-Path $d.FullName 'chatSessions'
        $n = if (Test-Path -LiteralPath $cs) { @(Get-ChildItem -LiteralPath $cs -File).Count } else { 0 }
        [pscustomobject]@{ Dir = $d; Folder = $folder; Chats = $n; Native = ((Get-Item -LiteralPath $wj).LastWriteTime -ge $NewLaptopSince) }
    }
    foreach ($g in ($rows | Group-Object Folder)) {
        $source = $g.Group | Where-Object { -not $_.Native } | Sort-Object Chats -Descending | Select-Object -First 1
        if (-not $source -or $source.Chats -eq 0) { continue }
        foreach ($t in ($g.Group | Where-Object { $_.Native -and $_.Chats -lt $source.Chats })) {
            $planned++
            $label = [uri]::UnescapeDataString($g.Name)
            Log ("{0}: {1}`n        old {2} ({3} chats) -> this laptop's {4} ({5} chats)" -f $fl.Name, $label, $source.Dir.Name, $source.Chats, $t.Dir.Name, $t.Chats)
            if ($Apply) {
                $bk = Join-Path (Join-Path $BackupPath $fl.Name) $t.Dir.Name
                robocopy $t.Dir.FullName $bk /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
                Remove-Item -LiteralPath (Join-Path $t.Dir.FullName 'state.vscdb-wal'), (Join-Path $t.Dir.FullName 'state.vscdb-shm') -Force -ErrorAction SilentlyContinue
                robocopy $source.Dir.FullName $t.Dir.FullName /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP /XF workspace.json | Out-Null
                if ($LASTEXITCODE -lt 8) { $done++ } else { Log "robocopy failed for $($t.Dir.Name) (rc=$LASTEXITCODE)" 'WARN' }
            }
        }
    }
}
if ($planned -eq 0) { Log 'Nothing to relink. Tip: open each project folder once in VS Code on this laptop, close VS Code, then run this again.' 'OK' }
elseif ($Apply) { Log ("Relinked {0} of {1} window(s). Previous state backed up in {2}" -f $done, $planned, $BackupPath) 'OK' }
else { Log ("{0} window(s) would be relinked. Re-run with -Apply (VS Code closed) to do it." -f $planned) 'WARN' }
