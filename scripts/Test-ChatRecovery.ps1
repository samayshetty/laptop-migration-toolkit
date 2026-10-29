$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ChatHistory.ps1')
$testRoot = Join-Path $env:TEMP ('lmt-chat-tests-' + [guid]::NewGuid().ToString('N'))
$originalAppData = $env:APPDATA
$originalLocalAppData = $env:LOCALAPPDATA
$originalUserProfile = $env:USERPROFILE
$passed = 0
$extraCleanup = New-Object System.Collections.Generic.List[string]

function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:passed++
    Write-Host "PASS: $Message"
}
function Write-JsonFile([string]$Path, $Value) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 30 -Compress))
}
function New-Request([string]$Id, [double]$Time) {
    @{ requestId = $Id; timestamp = $Time; message = @{ text = "prompt $Id" }; response = @(); responseTimestamp = $Time + 1 }
}
function New-State([string]$Id, [object[]]$Requests) {
    @{ version = 3; sessionId = $Id; creationDate = 1; customTitle = 'Recovery regression'; requests = $Requests; pendingRequests = @() }
}

if (-not ('LmtTestDb' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LmtTestDb {
    [DllImport("winsqlite3.dll", CharSet=CharSet.Unicode)] static extern int sqlite3_open16(string path, out IntPtr db);
    [DllImport("winsqlite3.dll", CharSet=CharSet.Ansi)] static extern int sqlite3_exec(IntPtr db, string sql, IntPtr callback, IntPtr arg, out IntPtr error);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_close(IntPtr db);
    public static void Create(string path) {
        IntPtr db, error;
        if (sqlite3_open16(path, out db) != 0) throw new Exception("Test database open failed");
        try {
            if (sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE, value BLOB)", IntPtr.Zero, IntPtr.Zero, out error) != 0)
                throw new Exception("Test table creation failed");
        } finally { sqlite3_close(db); }
    }
}
'@
}

try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $id = '11111111-1111-1111-1111-111111111111'
    $old = New-State $id @((New-Request 'r1' 10))
    $new = New-State $id @((New-Request 'r1' 10), (New-Request 'r2' 20))
    $oldFile = Join-Path $testRoot 'old.json'
    $newFile = Join-Path $testRoot 'new.json'
    Write-JsonFile $oldFile $old
    Write-JsonFile $newFile $new
    $a = Get-ChatSnapshot $newFile
    $b = Get-ChatSnapshot $oldFile
    Assert ([LmtChatSnapshot]::Compare($a, $b) -eq 'Newer') 'Longer ordered history wins despite file dates'
    Assert ([LmtChatSnapshot]::Compare($b, $a) -eq 'Older') 'New-laptop continuation is preserved'
    Assert ([LmtChatSnapshot]::Compare($a, $a) -eq 'Same') 'Identical history is idempotent'
    $branchFile = Join-Path $testRoot 'branch.json'
    Write-JsonFile $branchFile (New-State $id @((New-Request 'r1' 10), (New-Request 'branch' 30)))
    Assert ([LmtChatSnapshot]::Compare((Get-ChatSnapshot $branchFile), $a) -eq 'Conflict') 'Divergent branches are not overwritten'
    $edited = New-State $id @((New-Request 'r1' 10))
    $edited.requests[0].message.text = 'edited prompt'
    Write-JsonFile $branchFile $edited
    Assert ([LmtChatSnapshot]::Compare((Get-ChatSnapshot $branchFile), $b) -eq 'Conflict') 'Edited prompts with reused IDs are protected'

    $journal = Join-Path $testRoot 'journal.jsonl'
    $records = @(
        @{ kind = 0; v = $old },
        @{ kind = 2; k = @('requests'); v = @((New-Request 'discarded' 15)) },
        @{ kind = 2; k = @('requests'); i = 1 },
        @{ kind = 2; k = @('requests'); v = @((New-Request 'r2' 20)); i = 1 },
        @{ kind = 1; k = @('requests', 1, 'completionTokens'); v = 12 },
        @{ kind = 3; k = @('requests', 1, 'completionTokens') }
    )
    [IO.File]::WriteAllLines($journal, [string[]]@($records | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 30 -Compress }))
    $replayed = Get-ChatSnapshot $journal
    Assert ($replayed.Count -eq 2 -and $replayed.RequestIds[1] -eq 'r2') 'Journal set, append, truncate, replacement and deletion replay correctly'
    Assert ([LmtChatSnapshot]::Compare($replayed, $a) -eq 'Same') 'Replayed journal matches a materialized JSON snapshot'
    $invalid = Join-Path $testRoot 'invalid.jsonl'
    [IO.File]::WriteAllText($invalid, '{"kind":2,"k":["requests"],"i":0}')
    $rejected = $false
    try { Get-ChatSnapshot $invalid | Out-Null } catch { $rejected = $true }
    Assert $rejected 'Journal without initial snapshot fails explicitly'

    $treeSource = Join-Path $testRoot 'tree-source'
    $treeTarget = Join-Path $testRoot 'tree-target'
    Write-JsonFile (Join-Path $treeSource 'state.json') @{ marker = 'A' }
    Write-JsonFile (Join-Path $treeTarget 'state.json') @{ marker = 'B' }
    (Get-Item (Join-Path $treeTarget 'state.json')).LastWriteTime = (Get-Item (Join-Path $treeSource 'state.json')).LastWriteTime
    Copy-ChatTree $treeSource $treeTarget
    Assert ((Get-FileHash (Join-Path $treeSource 'state.json')).Hash -eq (Get-FileHash (Join-Path $treeTarget 'state.json')).Hash) 'Editing files with identical size and dates are still copied by content'

    $env:APPDATA = Join-Path $testRoot 'APPDATA'
    $root = Join-Path $env:APPDATA 'Code\User\workspaceStorage'
    $source = Join-Path $root 'old-workspace'
    $target = Join-Path $root 'new-workspace'
    foreach ($dir in $source, $target) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-JsonFile (Join-Path $dir 'workspace.json') @{ folder = 'file:///c%3A/example/project' }
        [LmtTestDb]::Create((Join-Path $dir 'state.vscdb'))
        [LmtSqlite]::Set((Join-Path $dir 'state.vscdb'), 'unrelated.setting', 'keep-me')
    }
    $sourceChat = Join-Path $source "chatSessions\$id.json"
    $targetChat = Join-Path $target "chatSessions\$id.json"
    Write-JsonFile $sourceChat $new
    Write-JsonFile $targetChat $old
    (Get-Item -LiteralPath $targetChat).LastWriteTime = (Get-Date).AddDays(1)
    foreach ($dir in $source, $target) {
        $time = if ($dir -eq $source) { 20 } else { 10 }
        $entries = @{}
        $entries[$id] = @{ sessionId = $id; title = 'Recovery regression'; lastMessageDate = $time; hasPendingEdits = ($dir -eq $source) }
        [LmtSqlite]::Set((Join-Path $dir 'state.vscdb'), 'chat.ChatSessionStore.index', (New-Json).Serialize(@{ version = 1; entries = $entries }))
        Write-JsonFile (Join-Path $dir "chatEditingSessions\$id\state.json") @{ marker = $time }
        Write-JsonFile (Join-Path $dir "chatEditingSessions\$id\contents\checkpoint.json") @{ marker = $time }
    }
    $before = (Get-FileHash -LiteralPath $targetChat).Hash
    $emptyWorkspace = Join-Path $root 'empty-workspace'
    Write-JsonFile (Join-Path $emptyWorkspace 'workspace.json') @{ folder = 'file:///c%3A/example/project' }
    & (Join-Path $PSScriptRoot 'Repair-WorkspaceChats.ps1') -NonInteractive
    Assert ((Get-FileHash -LiteralPath $targetChat).Hash -eq $before) 'Preview does not change history'
    if (Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue) {
        $blocked = $false
        try { & (Join-Path $PSScriptRoot 'Repair-WorkspaceChats.ps1') -Apply -Force } catch { $blocked = $true }
        Assert $blocked 'Live editor writes are blocked even with Force'
    }

    # Only the isolated fixture is writable; hide real editor processes for this test invocation.
    function Get-Process { param($Name, $ErrorAction) return }
    $backup = Join-Path $testRoot 'backup'
    & (Join-Path $PSScriptRoot 'Repair-WorkspaceChats.ps1') -Apply -BackupPath $backup -NonInteractive
    Assert ((Get-ChatSnapshot $targetChat).Count -eq 2) 'Apply recovers the complete history'
    Assert ((Get-FileHash -LiteralPath $sourceChat).Hash -eq (Get-FileHash -LiteralPath $targetChat).Hash) 'Recovered chat is byte-identical'
    $bkChat = Join-Path $backup "Code\new-workspace\chatSessions\$id.json"
    Assert ((Get-FileHash -LiteralPath $bkChat).Hash -eq $before) 'Original chat is backed up before replacement'
    $sourceEdit = Join-Path $source "chatEditingSessions\$id\state.json"
    $targetEdit = Join-Path $target "chatEditingSessions\$id\state.json"
    Assert ((Get-FileHash -LiteralPath $sourceEdit).Hash -eq (Get-FileHash -LiteralPath $targetEdit).Hash) 'Matching editing state is recovered'
    $index = (New-Json).DeserializeObject([LmtSqlite]::Get((Join-Path $target 'state.vscdb'), 'chat.ChatSessionStore.index'))
    Assert ($index['entries'][$id]['lastMessageDate'] -eq 20 -and $index['entries'][$id]['hasPendingEdits']) ("Existing SQLite index entry is updated, not inserted as a duplicate. Actual: " + (New-Json).Serialize($index['entries'][$id]))
    Assert ([LmtSqlite]::Get((Join-Path $target 'state.vscdb'), 'unrelated.setting') -eq 'keep-me') 'Unrelated SQLite settings survive'
    Assert ((Get-ChatSnapshot (Join-Path $emptyWorkspace "chatSessions\$id.json")).Count -eq 2) 'Repair initializes the chat index for a workspace without a database'
    $beforeSecond = (Get-FileHash -LiteralPath $targetChat).Hash
    & (Join-Path $PSScriptRoot 'Repair-WorkspaceChats.ps1') -Apply -BackupPath $backup -NonInteractive
    Assert ((Get-FileHash -LiteralPath $targetChat).Hash -eq $beforeSecond) 'Repeated apply preserves recovered history'

    $env:LOCALAPPDATA = Join-Path $testRoot 'LOCALAPPDATA'
    $stage = Join-Path $testRoot 'delta-stage'
    $relative = 'Code\User\workspaceStorage\new-workspace'
    $deltaWorkspace = Join-Path (Join-Path $stage 'APPDATA') $relative
    New-Item -ItemType Directory -Path $deltaWorkspace -Force | Out-Null
    Copy-ChatTree (Join-Path $source 'chatSessions') (Join-Path $deltaWorkspace 'chatSessions')
    Copy-ChatTree (Join-Path $source 'chatEditingSessions') (Join-Path $deltaWorkspace 'chatEditingSessions')
    [LmtSqlite]::Backup((Join-Path $source 'state.vscdb'), (Join-Path $deltaWorkspace 'state.vscdb'))
    $deltaGlobal = Join-Path $stage 'APPDATA\Code\User\globalStorage'
    $targetGlobal = Join-Path $env:APPDATA 'Code\User\globalStorage'
    foreach ($dir in $deltaGlobal, $targetGlobal) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [LmtTestDb]::Create((Join-Path $dir 'state.vscdb'))
        $entries = @{}
        $entries[$id] = @{ sessionId = $id; title = 'Empty-window regression'; lastMessageDate = $(if ($dir -eq $deltaGlobal) { 20 } else { 10 }) }
        if ($dir -eq $targetGlobal) { $entries['local-only'] = @{ sessionId = 'local-only'; title = 'Local chat'; lastMessageDate = 100 } }
        [LmtSqlite]::Set((Join-Path $dir 'state.vscdb'), 'chat.ChatSessionStore.index', (New-Json).Serialize(@{ version = 1; entries = $entries }))
    }
    Write-JsonFile (Join-Path $deltaGlobal "emptyWindowChatSessions\$id.json") $new
    $alternateChat = Join-Path $targetGlobal "emptyWindowChatSessions\$id.jsonl"
    [IO.Directory]::CreateDirectory((Split-Path -Parent $alternateChat)) | Out-Null
    [IO.File]::WriteAllText($alternateChat, (ConvertTo-Json -InputObject @{ kind = 0; v = $old } -Depth 30 -Compress))
    Write-JsonFile $targetChat $old
    (Get-Item -LiteralPath $targetChat).LastWriteTime = (Get-Date).AddDays(1)
    Write-JsonFile $targetEdit @{ marker = 10 }
    $index['entries'][$id]['lastMessageDate'] = 10
    [LmtSqlite]::Set((Join-Path $target 'state.vscdb'), 'chat.ChatSessionStore.index', (New-Json).Serialize($index))
    $manifestFiles = @(Get-ChildItem -LiteralPath (Join-Path $stage 'APPDATA') -Recurse -File | ForEach-Object {
        @{ Root = 'APPDATA'; Rel = $_.FullName.Substring((Join-Path $stage 'APPDATA').Length).TrimStart('\'); Modified = $_.LastWriteTime.ToString('o'); Length = $_.Length }
    })
    Write-JsonFile (Join-Path $stage 'delta-manifest.json') @{ Machine = 'isolated-test'; CreatedAt = (Get-Date).ToString('o'); Files = $manifestFiles }
    $zip = Join-Path $testRoot ('delta-test-' + [guid]::NewGuid().ToString('N') + '.zip')
    & tar.exe -a -cf $zip -C $stage .
    if ($LASTEXITCODE) { throw 'Test archive creation failed' }
    & (Join-Path $PSScriptRoot 'Sync-Delta.ps1') -Mode Apply -Path $zip -BackupPath (Join-Path $testRoot 'delta-backup') -SkipExtensions -SkipChatRelink -NonInteractive
    Assert ((Get-ChatSnapshot $targetChat).Count -eq 2) 'Delta import uses chat contents, not newer local file dates'
    Assert ((Get-FileHash -LiteralPath $sourceEdit).Hash -eq (Get-FileHash -LiteralPath $targetEdit).Hash) 'Delta imports the matching editing-state bundle'
    $deltaIndex = (New-Json).DeserializeObject([LmtSqlite]::Get((Join-Path $target 'state.vscdb'), 'chat.ChatSessionStore.index'))
    Assert ($deltaIndex['entries'][$id]['lastMessageDate'] -eq 20) 'Delta merges the matching session index'
    Assert ([LmtSqlite]::Get((Join-Path $target 'state.vscdb'), 'unrelated.setting') -eq 'keep-me') 'Delta preserves unrelated workspace database entries'
    Assert (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'laptop-migration-toolkit\last-apply.json')) 'Successful delta is recorded after verification'
    $globalIndex = (New-Json).DeserializeObject([LmtSqlite]::Get((Join-Path $targetGlobal 'state.vscdb'), 'chat.ChatSessionStore.index'))
    Assert ($globalIndex['entries'][$id]['lastMessageDate'] -eq 20 -and $globalIndex['entries'].ContainsKey('local-only')) 'Empty-window index recovery preserves new-laptop-only chats'
    Assert ((Get-ChatSnapshot (Join-Path $targetGlobal "emptyWindowChatSessions\$id.json")).Count -eq 2) 'Empty-window conversation is recovered'
    Assert (-not (Test-Path -LiteralPath $alternateChat)) 'Delta replaces the alternate chat format only after verification'
    Assert (Test-Path -LiteralPath (Join-Path $testRoot "delta-backup\APPDATA\Code\User\globalStorage\emptyWindowChatSessions\$id.jsonl")) 'Alternate chat format is backed up before replacement'

    Write-JsonFile (Join-Path $deltaWorkspace "chatSessions\$id.json") (New-State $id @((New-Request 'r1' 10), (New-Request 'branch' 30)))
    $conflictZip = Join-Path $testRoot ('delta-conflict-' + [guid]::NewGuid().ToString('N') + '.zip')
    & tar.exe -a -cf $conflictZip -C $stage .
    if ($LASTEXITCODE) { throw 'Conflict archive creation failed' }
    $extraCleanup.Add((Join-Path $env:TEMP ('lmt-delta-apply-' + [IO.Path]::GetFileNameWithoutExtension($conflictZip))))
    $command = "function Get-Process { param(`$Name,`$ErrorAction) }; & '$(Join-Path $PSScriptRoot 'Sync-Delta.ps1')' -Mode Apply -Path '$conflictZip' -BackupPath '$(Join-Path $testRoot 'conflict-backup')' -SkipExtensions -SkipChatRelink -NonInteractive"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
    Assert ($LASTEXITCODE -eq 1) 'Delta conflict returns a failure exit code'
    Assert ((Get-FileHash -LiteralPath $targetChat).Hash -eq $beforeSecond) 'Conflicting delta does not overwrite the current conversation'
    $applyState = Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'laptop-migration-toolkit\last-apply.json') -Raw | ConvertFrom-Json
    Assert (@($applyState.AppliedZips) -notcontains (Split-Path -Leaf $conflictZip)) 'Unresolved delta is not marked applied'

    Write-JsonFile $targetChat (New-State $id @((New-Request 'r1' 10), (New-Request 'r2' 20), (New-Request 'local-r3' 30)))
    $localIndex = (New-Json).DeserializeObject([LmtSqlite]::Get((Join-Path $target 'state.vscdb'), 'chat.ChatSessionStore.index'))
    $localIndex['entries'][$id]['lastMessageDate'] = 30
    [LmtSqlite]::Set((Join-Path $target 'state.vscdb'), 'chat.ChatSessionStore.index', (New-Json).Serialize($localIndex))
    $queueFolder = Join-Path $testRoot 'queue'
    New-Item -ItemType Directory -Path $queueFolder | Out-Null
    Copy-Item -LiteralPath $zip -Destination (Join-Path $queueFolder 'delta-20260101-1200.zip')
    Copy-Item -LiteralPath $zip -Destination (Join-Path $queueFolder 'delta-20260101-120001.zip')
    $queueStateRoot = Join-Path $testRoot 'queue-LOCALAPPDATA'
    $command = @"
`$env:LOCALAPPDATA = '$queueStateRoot'
function Get-Process { param(`$Name,`$ErrorAction) }
& '$(Join-Path $PSScriptRoot 'Sync-Delta.ps1')' -Mode Apply -Path '$queueFolder' -BackupPath '$(Join-Path $testRoot 'queue-backup')' -SkipExtensions -SkipChatRelink -NonInteractive
"@
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
    Assert ($LASTEXITCODE -eq 0) 'Delta folder accepts both legacy minute and new second filenames'
    $queueStateFile = Join-Path $queueStateRoot 'laptop-migration-toolkit\last-apply.json'
    $queueState = Get-Content -LiteralPath $queueStateFile -Raw | ConvertFrom-Json
    Assert (@($queueState.AppliedZips).Count -eq 2 -and $queueState.AppliedZip -eq 'delta-20260101-120001.zip') 'All unapplied deltas run oldest first'
    Assert ((Get-ChatSnapshot $targetChat).Count -eq 3) 'Delta import preserves a longer new-laptop continuation'
    $localIndex = (New-Json).DeserializeObject([LmtSqlite]::Get((Join-Path $target 'state.vscdb'), 'chat.ChatSessionStore.index'))
    Assert ($localIndex['entries'][$id]['lastMessageDate'] -eq 30) 'Delta import preserves the newer local continuation index'
    $stateHash = (Get-FileHash -LiteralPath $queueStateFile).Hash
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
    Assert ($LASTEXITCODE -eq 0 -and (Get-FileHash -LiteralPath $queueStateFile).Hash -eq $stateHash) 'Reapplying a delta folder is idempotent'
    $env:USERPROFILE = Join-Path $testRoot 'PROFILE'
    New-Item -ItemType Directory -Path $env:USERPROFILE -Force | Out-Null
    $collectAppData = Join-Path $testRoot 'collect-APPDATA'
    foreach ($fl in 'Code', 'Code - Insiders') {
        $ws = Join-Path $collectAppData "$fl\User\workspaceStorage\fixture"
        Write-JsonFile (Join-Path $ws 'workspace.json') @{ folder = 'file:///c%3A/example/project' }
        Write-JsonFile (Join-Path $ws "chatSessions\$id.json") $new
        Write-JsonFile (Join-Path $ws "chatEditingSessions\$id\state.json") @{ marker = 20 }
        Write-JsonFile (Join-Path $ws "chatEditingSessions\$id\contents\checkpoint.json") @{ marker = 20 }
        Write-JsonFile (Join-Path $ws "checkpoints\$id\snapshot.json") @{ marker = 20 }
        Write-JsonFile (Join-Path $ws "GitHub.copilot-chat\transcripts\$id.jsonl") @{ marker = 20 }
        [LmtTestDb]::Create((Join-Path $ws 'state.vscdb'))
        $global = Join-Path $collectAppData "$fl\User\globalStorage"
        Write-JsonFile (Join-Path $global "emptyWindowChatSessions\$id.json") $new
        [LmtTestDb]::Create((Join-Path $global 'state.vscdb'))
        Write-JsonFile (Join-Path $collectAppData "$fl\agentSessionData\$id\attachments\image.json") @{ marker = 20 }
        Write-JsonFile (Join-Path $collectAppData "$fl\User\unrelated.json") @{ marker = 'exclude-old-settings' }
    }
    Get-ChildItem -LiteralPath $collectAppData -Recurse -File | ForEach-Object { $_.LastWriteTime = (Get-Date).AddDays(-10) }
    $env:APPDATA = $collectAppData
    $collectOutput = Join-Path $testRoot 'collect-output'
    $fakeCli = Join-Path $testRoot 'fake-code.ps1'
    [IO.File]::WriteAllText($fakeCli, "'fixture.extension'")
    $command = @"
function Get-Process { param(`$Name,`$ErrorAction) }
function Get-Command { param(`$Name,`$ErrorAction) [pscustomobject]@{ Source = '$fakeCli' } }
function reg { `$global:LASTEXITCODE = 1 }
& '$(Join-Path $PSScriptRoot 'Sync-Delta.ps1')' -Mode Collect -Path '$collectOutput' -Since '$((Get-Date).AddDays(-1).ToString('o'))' -IncludeUserFiles -NonInteractive
"@
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
    Assert ($LASTEXITCODE -eq 0) 'Delta collect accepts Desktop, Documents and Pictures folder lookups'
    $collectedZip = Get-ChildItem -LiteralPath $collectOutput -Filter '*.zip' | Select-Object -First 1
    Assert ($null -ne $collectedZip -and (Test-Path -LiteralPath ($collectedZip.FullName + '.json'))) 'Collection publishes a zip and checksum sidecar'
    $collectedStage = Join-Path $testRoot 'collected-unpacked'
    New-Item -ItemType Directory -Path $collectedStage | Out-Null
    & tar.exe -xf $collectedZip.FullName -C $collectedStage
    if ($LASTEXITCODE) { throw 'Collected test archive extraction failed' }
    $collectedManifest = Get-Content -LiteralPath (Join-Path $collectedStage 'delta-manifest.json') -Raw | ConvertFrom-Json
    foreach ($fl in 'Code', 'Code - Insiders') {
        $paths = @($collectedManifest.Files.Rel)
        foreach ($rel in @(
            "$fl\User\workspaceStorage\fixture\chatSessions\$id.json",
            "$fl\User\workspaceStorage\fixture\chatEditingSessions\$id\state.json",
            "$fl\User\workspaceStorage\fixture\chatEditingSessions\$id\contents\checkpoint.json",
            "$fl\User\workspaceStorage\fixture\checkpoints\$id\snapshot.json",
            "$fl\User\workspaceStorage\fixture\GitHub.copilot-chat\transcripts\$id.jsonl",
            "$fl\User\workspaceStorage\fixture\state.vscdb",
            "$fl\User\workspaceStorage\fixture\workspace.json",
            "$fl\User\globalStorage\state.vscdb",
            "$fl\User\globalStorage\emptyWindowChatSessions\$id.json",
            "$fl\agentSessionData\$id\attachments\image.json"
        )) { Assert ($paths -contains $rel) "Collection includes pre-cutoff chat bundle: $rel" }
        Assert ($paths -notcontains "$fl\User\unrelated.json") "Collection remains incremental for $fl non-chat settings"
    }

    $collectStateFile = Join-Path $env:LOCALAPPDATA 'laptop-migration-toolkit\last-sync.json'
    $cutoffHash = (Get-FileHash -LiteralPath $collectStateFile).Hash
    $failedOutput = Join-Path $testRoot 'failed-collect'
    $failedTemp = Join-Path $testRoot 'failed-temp'
    New-Item -ItemType Directory -Path $failedTemp | Out-Null
    $command = @"
`$env:TEMP = '$failedTemp'
function Get-Process { param(`$Name,`$ErrorAction) }
function Get-Command { param(`$Name,`$ErrorAction) [pscustomobject]@{ Source = '$fakeCli' } }
function reg { `$global:LASTEXITCODE = 1 }
function tar.exe { Set-Content -LiteralPath `$args[2] -Value 'partial archive'; `$global:LASTEXITCODE = 1 }
& '$(Join-Path $PSScriptRoot 'Sync-Delta.ps1')' -Mode Collect -Path '$failedOutput' -Since '$((Get-Date).AddDays(-1).ToString('o'))' -NonInteractive
"@
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
    Assert ($LASTEXITCODE -eq 1) 'Archive failure returns a collection failure'
    Assert ((Get-FileHash -LiteralPath $collectStateFile).Hash -eq $cutoffHash) 'Failed collection does not advance the sync cutoff'
    Assert (@(Get-ChildItem -LiteralPath $failedOutput -File).Count -eq 0) 'Failed collection does not leave a partial zip for import'

    $script:PackagePath = Join-Path $testRoot 'full-package'
    $env:APPDATA = Join-Path $testRoot 'full-restore-APPDATA'
    foreach ($fl in @(
        @{ User = 'Code'; Prefix = 'vscode' },
        @{ User = 'Code - Insiders'; Prefix = 'vscode-insiders' }
    )) {
        Copy-ChatTree (Join-Path $collectAppData "$($fl.User)\User") (Join-Path $script:PackagePath "dev\$($fl.Prefix)-user")
        Copy-ChatTree (Join-Path $collectAppData "$($fl.User)\agentSessionData") (Join-Path $script:PackagePath "dev\$($fl.Prefix)-agentSessionData")
        [IO.File]::WriteAllText((Join-Path $script:PackagePath "dev\$($fl.Prefix)-extensions.txt"), 'fixture.extension')
    }
    $tokens = $null; $parseErrors = $null
    $restoreAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'Restore-NewLaptop.ps1'), [ref]$tokens, [ref]$parseErrors)
    foreach ($definition in $restoreAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -in 'Restore-VsCodeBundle', 'Install-CodeExtensionLists', 'Invoke-Bundle'
    }, $true)) { Invoke-Expression $definition.Extent.Text }
    function RestoreTree { param($Source, $Destination) Copy-ChatTree $Source $Destination }
    function Log { param($Message, $Level) Write-Host "$Level $Message" }
    function Get-VsCodeCli { param($Flavor) 'fixture-cli' }
    function Set-NodeCaFromWindows { }
    $script:extensionCalls = 0
    function Install-VsCodeExtension { param($Cli, $Id) $script:extensionCalls++; 'ok' }
    Invoke-Bundle 'vs-code'
    Invoke-Bundle 'vscode-insiders'
    foreach ($fl in 'Code', 'Code - Insiders') {
        Assert ((Get-ChatSnapshot (Join-Path $env:APPDATA "$fl\User\workspaceStorage\fixture\chatSessions\$id.json")).Count -eq 2) "Full restore includes $fl chats"
        Assert (Test-Path -LiteralPath (Join-Path $env:APPDATA "$fl\agentSessionData\$id\attachments\image.json")) "Full restore includes $fl attachments"
    }
    Assert ($script:extensionCalls -eq 0) 'Full restore defers extension CLI calls until all editor data is copied'
    $script:Plan = @(
        [pscustomobject]@{ Id = 'vs-code'; Apply = $true; Present = $true },
        [pscustomobject]@{ Id = 'vscode-insiders'; Apply = $true; Present = $true }
    )
    Install-CodeExtensionLists
    Assert ($script:extensionCalls -eq 2) 'Full restore installs selected Stable and Insiders extension lists'
    Write-Host "All $passed assertions passed."
} finally {
    $env:APPDATA = $originalAppData
    $env:LOCALAPPDATA = $originalLocalAppData
    $env:USERPROFILE = $originalUserProfile
    foreach ($path in $extraCleanup) { if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Recurse -Force } }
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
exit 0
