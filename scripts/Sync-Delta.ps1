[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Collect', 'Apply')][string]$Mode,
    [string]$Path,
    [string]$Since,
    [string]$BackupPath,
    [switch]$IncludeUserFiles,
    [switch]$CloseApps,
    [switch]$SkipExtensions,
    [switch]$SkipChatRelink,
    [switch]$NonInteractive,
    [switch]$NoElevate
)

$ToolkitVersion = '1.2.1'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$script:Findings = New-Object System.Collections.Generic.List[string]
$stateDir = Join-Path $env:LOCALAPPDATA 'laptop-migration-toolkit'
$stateFile = Join-Path $stateDir 'last-sync.json'

function Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'STEP' { 'Cyan' } default { 'Gray' } }
    $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $color
    $script:Findings.Add($line)
}

function EnsureDir([string]$P) { if (-not (Test-Path -LiteralPath $P)) { New-Item -ItemType Directory -Path $P -Force | Out-Null }; $P }

. (Join-Path $PSScriptRoot 'ChatHistory.ps1')
$logSb = { param($m, $l) Log $m $(if ($l) { $l } else { 'INFO' }) }
$browsers = $script:BrowserDefs

$roots = [ordered]@{
    APPDATA      = $env:APPDATA
    LOCALAPPDATA = $env:LOCALAPPDATA
    USERPROFILE  = $env:USERPROFILE
}

$appProcesses = @('Code', 'Code - Insiders', 'notepad++', 'ONENOTE', 'Notepad', 'chrome', 'msedge')

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host (" laptop-migration-toolkit v{0} - DELTA SYNC ({1})" -f $ToolkitVersion, $Mode.ToUpper()) -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan

if ($Mode -eq 'Collect') {
    if (Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue) {
        Log 'Close VS Code and VS Code Insiders before delta collection. Run from standalone PowerShell so chats and SQLite state are fully saved.' 'ERROR'
        exit 1
    }
    if (-not $Path) {
        $base = if ($env:OneDriveCommercial) { $env:OneDriveCommercial } elseif ($env:OneDrive) { $env:OneDrive } else { [Environment]::GetFolderPath('Desktop') }
        $Path = Join-Path $base 'MigrationDelta'
    }
    EnsureDir $Path | Out-Null

    # Work out the cut-off: explicit -Since, else last delta, else the original full package timestamp.
    $sinceDate = $null
    $sinceSource = ''
    if ($Since) {
        try { $sinceDate = [datetime]::Parse($Since); $sinceSource = '-Since parameter' } catch { Log "Cannot parse -Since '$Since'" 'ERROR'; exit 1 }
    } elseif (Test-Path -LiteralPath $stateFile) {
        try { $sinceDate = [datetime](Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json).LastDeltaCollect; $sinceSource = 'previous delta collection' } catch { }
    }
    if (-not $sinceDate) {
        $candidates = @()
        if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot 'Package\system-info.json') }
        if ($env:OneDriveCommercial) { $candidates += (Join-Path $env:OneDriveCommercial 'MigrationPackage\system-info.json'); $candidates += (Join-Path $env:OneDriveCommercial 'DeviceMigration\Package\system-info.json'); $candidates += (Join-Path $env:OneDriveCommercial 'MigrationPackage.zip.json') }
        foreach ($c in $candidates) {
            if (Test-Path -LiteralPath $c) {
                try { $j = Get-Content -LiteralPath $c -Raw | ConvertFrom-Json; $sinceDate = [datetime]$(if ($j.CollectedAt) { $j.CollectedAt } else { $j.CreatedAt }); $sinceSource = "full package ($c)"; break } catch { }
            }
        }
    }
    if (-not $sinceDate) {
        Log 'Could not determine the last sync time. Enter a date in the "Changed since" box (e.g. 2026-10-17 09:49).' 'ERROR'
        exit 1
    }
    $collectStarted = Get-Date
    $sinceDate = $sinceDate.AddHours(-1)
    Log ("Collecting files changed since {0:yyyy-MM-dd HH:mm} (from {1})" -f $sinceDate, $sinceSource) 'STEP'

    $junk = '\\(node_modules|\.git|Cache|Code Cache|GPUCache|Crashpad|logs|CachedData|CachedExtensionVSIXs|Backups|History)\\|local-index[^\\]*\.db$|workspace-chunks\.json$'
    $sources = New-Object System.Collections.Generic.List[object]
    function Add-Source($Root, $Rel, [switch]$Force) { $sources.Add([pscustomobject]@{ Root = $Root; Rel = $Rel; Force = [bool]$Force }) }
    Add-Source APPDATA 'Code\User'
    Add-Source APPDATA 'Code - Insiders\User'
    Add-Source APPDATA 'Code\agentSessionData' -Force
    Add-Source APPDATA 'Code - Insiders\agentSessionData' -Force
    Add-Source APPDATA 'Notepad++'
    Add-Source APPDATA 'Microsoft\OneNote'
    Add-Source LOCALAPPDATA 'Packages\Microsoft.WindowsNotepad_8wekyb3d8bbwe\LocalState'
    Add-Source LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState'
    # Every browser profile (Default, Profile 1, ...) is taken in full, regardless of the cut-off date.
    $stageProfiles = @{}
    foreach ($b in $browsers) {
        $broot = Join-Path $env:LOCALAPPDATA $b.Rel
        if (-not (Test-Path -LiteralPath $broot)) { continue }
        foreach ($pd in Get-ChildItem -LiteralPath $broot -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^(Default|Profile \d+)$') {
            foreach ($f in 'Bookmarks', 'Preferences') { Add-Source LOCALAPPDATA ($b.Rel + '\' + $pd.Name + '\' + $f) -Force }
        }
        try {
            $ls = (New-Json).DeserializeObject((Read-SharedText (Join-Path $broot 'Local State')))
            $stageProfiles[$b.Name] = $ls['profile']['info_cache']
        } catch { Log "Could not read $($b.Name) profile list: $($_.Exception.Message)" 'WARN' }
    }
    foreach ($r in '.claude', '.claude.json', '.codex', '.gemini', '.copilot', '.kube', '.azure', '.gitconfig', '.npmrc', '.wslconfig', '.vimrc', '.editorconfig', '.terraformrc', '.bashrc', '.profile') { Add-Source USERPROFILE $r }
    Add-Source USERPROFILE 'Documents\WindowsPowerShell'
    Add-Source USERPROFILE 'Documents\PowerShell'
    if ($IncludeUserFiles) {
        foreach ($sf in 'Desktop', 'MyDocuments', 'MyPictures') {
            $full = [Environment]::GetFolderPath([Environment+SpecialFolder]$sf)
            if ($full -and $full.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase) -and $full -notmatch 'OneDrive') {
                Add-Source USERPROFILE $full.Substring($env:USERPROFILE.Length).TrimStart('\')
            } else { Log "Skipping $sf (redirected to OneDrive - already synced)" 'WARN' }
        }
    }

    $stage = Join-Path $env:TEMP ('lmt-delta-' + [guid]::NewGuid().ToString('N'))
    EnsureDir $stage | Out-Null
    $manifestFiles = New-Object System.Collections.Generic.List[object]
    $failed = 0
    foreach ($s in $sources) {
        $abs = Join-Path $roots[$s.Root] $s.Rel
        if (-not (Test-Path -LiteralPath $abs)) { continue }
        $files = @(Get-ChildItem -LiteralPath $abs -Recurse -File -Force -ErrorAction SilentlyContinue)
        if ((Get-Item -LiteralPath $abs -Force).PSIsContainer -eq $false) { $files = @(Get-Item -LiteralPath $abs -Force) }
        $n = 0
        foreach ($f in $files) {
            # Older full packages omitted chats; include complete bundles even when their dates predate the cutoff.
            $requiredChat = $s.Root -eq 'APPDATA' -and $s.Rel -match '^Code(?: - Insiders)?\\User$' -and (
                $f.FullName -match '\\(?:chatSessions|emptyWindowChatSessions|chatEditingSessions|checkpoints)\\' -or
                $f.FullName -match '\\GitHub\.copilot-chat\\transcripts\\' -or
                $f.FullName -match '\\(?:workspaceStorage\\[^\\]+|globalStorage)\\(?:state\.vscdb|workspace\.json)$')
            if (-not $s.Force -and -not $requiredChat -and $f.LastWriteTime -lt $sinceDate) { continue }
            if ($f.Attributes -band [IO.FileAttributes]::Offline) {
                if ($requiredChat -or $s.Force) { $failed++; Log "Required chat data is online-only; download it before collecting: $($f.FullName)" 'ERROR' }
                continue
            }
            if ($f.FullName -match $junk) { continue }
            $rel = $f.FullName.Substring($roots[$s.Root].Length).TrimStart('\')
            try {
                $destination = Join-Path (Join-Path $stage $s.Root) $rel
                if ($requiredChat -and $f.Name -eq 'state.vscdb') {
                    EnsureDir (Split-Path -Parent $destination) | Out-Null
                    [LmtSqlite]::Backup($f.FullName, $destination)
                    (Get-Item -LiteralPath $destination).LastWriteTime = $f.LastWriteTime
                } else { Copy-Shared $f.FullName $destination }
                $manifestFiles.Add([ordered]@{ Root = $s.Root; Rel = $rel; Length = $f.Length; Modified = $f.LastWriteTime.ToString('o') })
                $n++
            } catch { $failed++; Log "Could not copy $($f.FullName): $($_.Exception.Message)" 'WARN' }
        }
        if ($n -gt 0) { Log ("{0,5} changed file(s): {1}\{2}" -f $n, $s.Root, $s.Rel) 'OK' }
    }

    $reg = Join-Path $stage 'onenote-options.reg'
    reg export 'HKCU\Software\Microsoft\Office\16.0\OneNote' $reg /y 2>$null | Out-Null
    foreach ($fl in 'stable', 'insiders') {
        $cli = Get-VsCodeCli $fl
        if ($cli) { [IO.File]::WriteAllLines((Join-Path $stage "extensions-$fl.txt"), [string[]]@(& $cli --list-extensions 2>$null | Where-Object { $_ })) }
    }

    foreach ($bn in $stageProfiles.Keys) {
        [IO.File]::WriteAllText((Join-Path $stage "browser-profiles-$bn.json"), (New-Json).Serialize($stageProfiles[$bn]))
        Log "$bn profile list saved ($($stageProfiles[$bn].Count) profile(s))" 'OK'
    }

    if ($failed) {
        Log "Collection failed for $failed file(s). No zip published or sync cutoff advanced. Staged data: $stage" 'ERROR'
        exit 1
    }
    $now = Get-Date
    [ordered]@{
        ToolkitVersion = $ToolkitVersion; CreatedAt = $now.ToString('o'); Since = $sinceDate.ToString('o')
        Machine = $env:COMPUTERNAME; User = $env:USERNAME; Files = $manifestFiles
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'delta-manifest.json') -Encoding UTF8

    $zip = Join-Path $Path ('delta-' + $now.ToString('yyyyMMdd-HHmmss') + '.zip')
    if ((Test-Path -LiteralPath $zip) -or (Test-Path -LiteralPath ($zip + '.json'))) {
        Log "Delta name already exists: $zip. Retry collection; staged data remains at $stage." 'ERROR'
        exit 1
    }
    Log "Packing $($manifestFiles.Count) file(s) into one zip..." 'STEP'
    & tar.exe -a -cf $zip -C $stage . 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $zip)) {
        try { Write-PackageSidecar -Zip $zip -ErrorAction Stop }
        catch { Log "Checksum publication failed: $($_.Exception.Message). Sync cutoff was not advanced." 'ERROR'; exit 1 }
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        EnsureDir $stateDir | Out-Null
        [ordered]@{ LastDeltaCollect = $collectStarted.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
        Log ("Delta finished: {0} file(s), {1:N1} MB -> {2} ({3} warnings)" -f $manifestFiles.Count, ((Get-Item $zip).Length / 1MB), $zip, $failed) 'OK'
        Write-Host ' Now press "Delta: apply" on the new laptop - it waits for OneDrive by itself and starts once the file has fully arrived.' -ForegroundColor Gray
    } else {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction Stop }
        Log "Zip creation failed. Staged files are kept in $stage" 'ERROR'
        exit 1
    }
    exit 0
}

# ---------------- Apply ----------------
if (-not $Path) { Log 'Choose the folder (or zip) that holds the delta package.' 'ERROR'; exit 1 }
$applyState = Join-Path $stateDir 'last-apply.json'
$appliedZips = @()
if (Test-Path -LiteralPath $applyState) {
    try {
        $st = Get-Content -LiteralPath $applyState -Raw | ConvertFrom-Json
        $appliedZips = @($st.AppliedZips) + @($st.AppliedZip) | Where-Object { $_ } | Sort-Object -Unique
    } catch { }
}
$queue = @()
if (Test-Path -LiteralPath $Path -PathType Container) {
    # Each delta only holds changes since the previous one, so every unapplied zip is needed, oldest first.
    $names = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue | Where-Object Name -match '^delta-\d{8}-\d{4}(?:\d{2})?\.zip(\.json)?$' | ForEach-Object { $_.Name -replace '\.json$', '' } | Sort-Object -Unique)
    if ($names.Count -eq 0) { Log "No delta-*.zip in $Path yet. Run 'Delta: collect' on the old laptop first, or wait for OneDrive to show it." 'ERROR'; exit 1 }
    $queue = @($names | Where-Object { $appliedZips -notcontains $_ } | ForEach-Object { Join-Path $Path $_ })
    if ($queue.Count -eq 0) {
        Log "All $($names.Count) delta(s) in $Path were already applied. If you just collected a new one, OneDrive has not shown it here yet - try again in a few minutes." 'WARN'
        exit 0
    }
    Log ("{0} delta(s) to apply, oldest first: {1}" -f $queue.Count, (($queue | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')) 'STEP'
} else {
    $queue = @($Path)
}

$running = @(Get-Process -Name $appProcesses -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    $runningNames = ($running | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ', '
    if ($CloseApps) {
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Log "Closed: $runningNames" 'OK'
    } else {
        Log "Running now: $runningNames. Locked files may fail - tick 'Close apps first'." 'WARN'
    }
}

$runningCode = @(Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue)
if ($runningCode.Count -gt 0) {
    Log 'VS Code is still running. No delta will be applied: close both editors and run from standalone PowerShell.' 'ERROR'
    exit 1
}

$desktop = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($desktop) -or -not (Test-Path -LiteralPath $desktop)) { $desktop = $env:USERPROFILE }
$backup = if ($BackupPath) { $BackupPath } else { Join-Path $desktop ('MigrationBackup-delta-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
$applied = 0; $keptNewer = 0; $same = 0; $failedCount = 0
$works = New-Object System.Collections.Generic.List[string]
$lastWork = $null
foreach ($zipPath in $queue) {
    if ((Test-Path -LiteralPath ($zipPath + '.json')) -or -not (Test-Path -LiteralPath $zipPath)) {
        if (-not (Wait-PackageZip -Zip $zipPath -Log $logSb)) { $failedCount++; Log "Stopping: $(Split-Path -Leaf $zipPath) is not available, later deltas would be applied out of order." 'ERROR'; break }
    }
    $zi = Get-Item -LiteralPath $zipPath -Force
    Log "Applying $($zi.Name) ($([math]::Round($zi.Length / 1MB, 1)) MB)" 'STEP'
    $work = Join-Path $env:TEMP ('lmt-delta-apply-' + [IO.Path]::GetFileNameWithoutExtension($zi.Name))
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    EnsureDir $work | Out-Null
    $works.Add($work)
    & tar.exe -xf $zipPath -C $work 2>&1 | Out-Null
    $manifestPath = Join-Path $work 'delta-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { $failedCount++; Log "$($zi.Name): delta-manifest.json missing - extraction failed or not a delta zip" 'ERROR'; break }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    Log "Delta from $($manifest.Machine), created $($manifest.CreatedAt), $(@($manifest.Files).Count) file(s)" 'OK'

    $zipFailedBefore = $failedCount
    $chatDecisions = @{}
    $chatTargetFiles = @{}
    $chatDatabases = @{}
    foreach ($e in @($manifest.Files)) {
        if ($e.Root -ne 'APPDATA') { continue }
        if ($e.Rel -match '^(Code(?: - Insiders)?\\User\\(?:workspaceStorage\\[^\\]+|globalStorage))\\state\.vscdb$') {
            $chatDatabases[$Matches[1]] = $true
        }
        if ($e.Rel -notmatch '^(Code(?: - Insiders)?\\User\\(?:workspaceStorage\\[^\\]+\\chatSessions|globalStorage\\emptyWindowChatSessions))\\([^\\]+)\.(json|jsonl)$') { continue }
        $key = $Matches[1] + '\' + $Matches[2]
        try {
            $src = Join-Path (Join-Path $work 'APPDATA') $e.Rel
            $dst = Join-Path $env:APPDATA $e.Rel
            if ($chatDecisions.ContainsKey($key)) { throw 'Multiple incoming formats for the same chat; manual review required' }
            $incoming = Get-ChatSnapshot $src
            if ($incoming.SessionId -ne [IO.Path]::GetFileNameWithoutExtension($e.Rel)) { throw 'Session ID does not match the filename' }
            $alternate = [IO.Path]::ChangeExtension($dst, $(if ([IO.Path]::GetExtension($dst) -eq '.json') { '.jsonl' } else { '.json' }))
            $existingFiles = @($dst, $alternate | Where-Object { Test-Path -LiteralPath $_ })
            if ($existingFiles.Count -gt 1) { throw 'Multiple local formats for the same chat; manual review required' }
            $existing = if ($existingFiles.Count) {
                $chatTargetFiles[$key] = $existingFiles[0]
                Get-ChatSnapshot $existingFiles[0]
            } else { $null }
            $chatDecisions[$key] = [LmtChatSnapshot]::Compare($incoming, $existing)
            if ($chatDecisions[$key] -eq 'Conflict') { throw 'Divergent conversation versions; existing chat retained' }
        } catch {
            $chatDecisions[$key] = 'Conflict'
            $failedCount++
            Log "Cannot safely import $($e.Rel): $($_.Exception.Message)" 'ERROR'
        }
    }

    foreach ($e in @($manifest.Files)) {
        if (-not $roots.Contains($e.Root)) { continue }
        $src = Join-Path (Join-Path $work $e.Root) $e.Rel
        $dst = Join-Path $roots[$e.Root] $e.Rel
        if (-not (Test-Path -LiteralPath $src)) { $failedCount++; Log "Manifest file missing: $src" 'ERROR'; continue }
        try {
            $chatSelected = $false
            if ($e.Root -eq 'APPDATA') {
                if ($e.Rel -match '^(Code(?: - Insiders)?\\User\\(?:workspaceStorage\\[^\\]+|globalStorage))\\state\.vscdb(?:-wal|-shm|\.backup)?$') {
                    continue
                }
                $chatKey = $null
                if ($e.Rel -match '^(Code(?: - Insiders)?\\User\\(?:workspaceStorage\\[^\\]+\\chatSessions|globalStorage\\emptyWindowChatSessions))\\([^\\]+)\.(json|jsonl)$') {
                    $chatKey = $Matches[1] + '\' + $Matches[2]
                } elseif ($e.Rel -match '^(Code(?: - Insiders)?\\User\\workspaceStorage\\[^\\]+)\\(?:chatEditingSessions\\([^\\]+)\\|GitHub\.copilot-chat\\transcripts\\([^\\]+)\.jsonl$)') {
                    $sessionId = if ($Matches[2]) { $Matches[2] } else { $Matches[3] }
                    $chatKey = $Matches[1] + '\chatSessions\' + $sessionId
                    if (-not $chatDecisions.ContainsKey($chatKey) -and $e.Rel -match '^(Code(?: - Insiders)?\\User)\\') {
                        $emptyKey = $Matches[1] + '\globalStorage\emptyWindowChatSessions\' + $sessionId
                        if ($chatDecisions.ContainsKey($emptyKey)) { $chatKey = $emptyKey }
                    }
                }
                if ($chatKey -and $chatDecisions.ContainsKey($chatKey)) {
                    if ($chatDecisions[$chatKey] -in 'Conflict', 'Older') { $keptNewer++; continue }
                    if ($chatDecisions[$chatKey] -eq 'Same' -and $e.Rel -match '\\(?:chatEditingSessions|transcripts)\\' -and (Test-Path -LiteralPath $dst)) {
                        if ((Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $dst).Hash) { Log "Retained different local editing/transcript state for unchanged chat: $($e.Rel)" 'WARN' }
                        continue
                    }
                    $chatSelected = $true
                } elseif ($chatKey -and (Test-Path -LiteralPath $dst)) {
                    # Incremental editing data without a matching chat snapshot cannot safely replace local state.
                    Log "Retained existing chat support file without a matching conversation snapshot: $($e.Rel)" 'WARN'
                    continue
                }
            }
            $srcTime = (Get-Item -LiteralPath $src -Force).LastWriteTime
            $alternateTarget = if ($chatSelected -and $chatKey) { $chatTargetFiles[$chatKey] } else { $null }
            if ($alternateTarget -and $alternateTarget -ne $dst -and $e.Rel -match '\\(?:chatSessions|emptyWindowChatSessions)\\') {
                $alternateRel = [IO.Path]::ChangeExtension($e.Rel, [IO.Path]::GetExtension($alternateTarget))
                $bk = Join-Path (Join-Path $backup $e.Root) $alternateRel
                EnsureDir (Split-Path -Parent $bk) | Out-Null
                if (-not (Test-Path -LiteralPath $bk)) { Copy-Item -LiteralPath $alternateTarget -Destination $bk -ErrorAction Stop }
            }
            if (Test-Path -LiteralPath $dst) {
                $dstItem = Get-Item -LiteralPath $dst -Force
                $diff = ($srcTime - $dstItem.LastWriteTime).TotalSeconds
                if (-not $chatSelected -and [math]::Abs($diff) -le 2) { $same++; continue }
                if (-not $chatSelected -and $diff -lt 0) { $keptNewer++; continue }
                $bk = Join-Path (Join-Path $backup $e.Root) $e.Rel
                EnsureDir (Split-Path -Parent $bk) | Out-Null
                if (-not (Test-Path -LiteralPath $bk)) { Copy-Item -LiteralPath $dst -Destination $bk -Force -ErrorAction Stop }
            }
            if ($dst -match '\.db$') { Remove-Item -LiteralPath ($dst + '-wal'), ($dst + '-shm') -Force -ErrorAction SilentlyContinue }
            Copy-Shared $src $dst
            if ($chatSelected -and (Get-FileHash -LiteralPath $src).Hash -ne (Get-FileHash -LiteralPath $dst).Hash) { throw 'Chat file hash verification failed' }
            if ($alternateTarget -and $alternateTarget -ne $dst -and $e.Rel -match '\\(?:chatSessions|emptyWindowChatSessions)\\') {
                Remove-Item -LiteralPath $alternateTarget -Force -ErrorAction Stop
            }
            $applied++
        } catch { $failedCount++; Log "Could not write ${dst}: $($_.Exception.Message)" 'WARN' }
    }

    foreach ($rel in @($chatDatabases.Keys)) {
        try {
            $sourceDb = Join-Path (Join-Path $work 'APPDATA') ($rel + '\state.vscdb')
            $targetDb = Join-Path $env:APPDATA ($rel + '\state.vscdb')
            if (-not (Test-Path -LiteralPath $targetDb)) {
                EnsureDir (Split-Path -Parent $targetDb) | Out-Null
                [LmtSqlite]::Backup($sourceDb, $targetDb)
            }
            $key = 'chat.ChatSessionStore.index'
            $raw = [LmtSqlite]::Get($sourceDb, $key)
            if (-not $raw) { continue }
            $sourceIndex = (New-Json).DeserializeObject($raw)
            $targetRaw = [LmtSqlite]::Get($targetDb, $key)
            $targetIndex = if ($targetRaw) { (New-Json).DeserializeObject($targetRaw) } else { @{ version = $sourceIndex['version']; entries = @{} } }
            $changed = $false
            foreach ($id in @($sourceIndex['entries'].Keys)) {
                $sessionDir = if ($rel -match '\\globalStorage$') { '\emptyWindowChatSessions\' } else { '\chatSessions\' }
                $decision = $chatDecisions[$rel + $sessionDir + $id]
                if ($decision -notin 'Newer', 'Same') { continue }
                if ($decision -eq 'Same' -and $targetIndex['entries'].ContainsKey($id) -and [double]$targetIndex['entries'][$id]['lastMessageDate'] -ge [double]$sourceIndex['entries'][$id]['lastMessageDate']) { continue }
                $targetIndex['entries'][$id] = $sourceIndex['entries'][$id]
                $changed = $true
            }
            if ($changed) {
                $bk = Join-Path (Join-Path $backup 'APPDATA') ($rel + '\state.vscdb')
                if (-not (Test-Path -LiteralPath $bk)) {
                    EnsureDir (Split-Path -Parent $bk) | Out-Null
                    [LmtSqlite]::Backup($targetDb, $bk)
                }
                [LmtSqlite]::Set($targetDb, $key, (New-Json).Serialize($targetIndex))
                if ([LmtSqlite]::Get($targetDb, $key) -ne (New-Json).Serialize($targetIndex)) { throw 'Chat index verification failed' }
            }
            Log "Chat index checked; other existing database settings retained: $rel" 'INFO'
        } catch { $failedCount++; Log "Chat index merge failed for ${rel}: $($_.Exception.Message)" 'ERROR' }
    }

    $onenoteReg = Join-Path $work 'onenote-options.reg'
    if ((Test-Path -LiteralPath $onenoteReg) -and (Get-Item $onenoteReg).Length -gt 0) {
        reg import $onenoteReg 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Log 'OneNote options imported' 'OK' } else { Log 'OneNote options import failed' 'WARN' }
    }
    foreach ($b in $browsers) {
        Register-BrowserProfiles -Browser $b.Name -ProfilesJson (Join-Path $work "browser-profiles-$($b.Name).json") -BackupDir $backup -CloseBrowser:$CloseApps -Log $logSb
    }

    if ($failedCount -gt $zipFailedBefore) {
        Log "$($zi.Name) has unresolved failures and was NOT marked applied. Later deltas will not be applied." 'ERROR'
        break
    }
    $appliedZips = @($appliedZips) + $zi.Name | Sort-Object -Unique
    EnsureDir $stateDir | Out-Null
    [ordered]@{ LastDeltaApply = (Get-Date).ToString('o'); AppliedFrom = $manifest.CreatedAt; AppliedZip = $zi.Name; AppliedZips = $appliedZips } | ConvertTo-Json | Set-Content -LiteralPath $applyState -Encoding UTF8
    $lastWork = $work
}
Log "Files written: $applied, already identical: $same, kept because new laptop copy is newer: $keptNewer, failed: $failedCount" $(if ($failedCount) { 'ERROR' } else { 'OK' })
if (Test-Path -LiteralPath $backup) { Log "Overwritten files were backed up to $backup" 'INFO' }
if ($failedCount) {
    Log "Stopped before relinking or installing extensions. Review errors and backups; extracted delta data is retained in: $($works -join ', ')" 'ERROR'
    exit 1
}

# Must run before extension installs: the VS Code CLI starts Code.exe processes of its own.
$relink = Join-Path $PSScriptRoot 'Repair-WorkspaceChats.ps1'
if (-not $SkipChatRelink -and (Test-Path -LiteralPath $relink)) {
    if (Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue) {
        Log "VS Code is running - per-window chat history was NOT merged. Close VS Code and run 'Fix missing per-folder VS Code chats' in the GUI." 'WARN'
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $relink -Apply -BackupPath $backup *>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { Log 'Chat recovery reported unresolved cases. Review its output and run the repair preview.' 'ERROR'; exit 1 }
    }
}

if (-not $SkipExtensions -and $lastWork) {
    foreach ($fl in 'stable', 'insiders') {
        $list = Join-Path $lastWork "extensions-$fl.txt"
        $cli = Get-VsCodeCli $fl
        if (-not (Test-Path -LiteralPath $list) -or -not $cli) { continue }
        $have = @(& $cli --list-extensions 2>$null | ForEach-Object { $_.Trim().ToLower() })
        $todo = @(Get-Content -LiteralPath $list | Where-Object { $_.Trim() -and ($have -notcontains $_.Trim().ToLower()) })
        if ($todo.Count -eq 0) { Log "VS Code ($fl): all extensions already installed" 'OK'; continue }
        Set-NodeCaFromWindows
        Log "VS Code ($fl): installing $($todo.Count) missing extension(s)..." 'STEP'
        foreach ($id in $todo) {
            switch (Install-VsCodeExtension -Cli $cli -Id $id.Trim()) {
                'ok'      { Log "Installed $id" 'OK' }
                'timeout' { Log "Timed out (install it from the Extensions panel): $id" 'WARN' }
                default   { Log "Failed to install $id" 'WARN' }
            }
        }
    }
}

foreach ($w in $works) { Remove-Item -LiteralPath $w -Recurse -Force -ErrorAction SilentlyContinue }
$warns = @($script:Findings | Where-Object { $_ -match '\] WARN' }).Count
$errs = @($script:Findings | Where-Object { $_ -match '\] ERROR' }).Count
Log ("Delta finished: {0} file(s) applied, {1} warnings, {2} errors" -f $applied, $warns, $errs) 'OK'
Write-Host ' Reopen VS Code / Insiders / Notepad++ / OneNote to see the changes.' -ForegroundColor Gray
