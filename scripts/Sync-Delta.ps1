[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Collect', 'Apply')][string]$Mode,
    [string]$Path,
    [string]$Since,
    [switch]$IncludeUserFiles,
    [switch]$CloseApps,
    [switch]$SkipExtensions,
    [switch]$SkipChatRelink,
    [switch]$NonInteractive,
    [switch]$NoElevate
)

$ToolkitVersion = '1.2.0'
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

# Copies with FileShare.ReadWrite so files held open by VS Code (sqlite db/wal) can still be read.
function Copy-Shared {
    param([string]$Source, [string]$Destination)
    EnsureDir (Split-Path -Parent $Destination) | Out-Null
    $in = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try {
        $out = [IO.File]::Create($Destination)
        try { $in.CopyTo($out) } finally { $out.Dispose() }
    } finally { $in.Dispose() }
    (Get-Item -LiteralPath $Destination -Force).LastWriteTime = (Get-Item -LiteralPath $Source -Force).LastWriteTime
}

$roots = [ordered]@{
    APPDATA      = $env:APPDATA
    LOCALAPPDATA = $env:LOCALAPPDATA
    USERPROFILE  = $env:USERPROFILE
}

function Get-VsCodeCli {
    param([ValidateSet('stable', 'insiders')][string]$Flavor)
    if ($Flavor -eq 'stable') {
        $c = Get-Command code -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        foreach ($p in @("$env:ProgramFiles\Microsoft VS Code\bin\code.cmd", "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd")) { if (Test-Path $p) { return $p } }
    } else {
        $c = Get-Command code-insiders -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        foreach ($p in @("$env:LOCALAPPDATA\Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd", "$env:ProgramFiles\Microsoft VS Code Insiders\bin\code-insiders.cmd")) { if (Test-Path $p) { return $p } }
    }
    return $null
}

$appProcesses = @('Code', 'Code - Insiders', 'notepad++', 'ONENOTE', 'Notepad', 'chrome', 'msedge')
. (Join-Path $PSScriptRoot 'MigrationCommon.ps1')
$logSb = { param($m, $l) Log $m $(if ($l) { $l } else { 'INFO' }) }

Add-Type -AssemblyName System.Web.Extensions
function New-Json { $j = New-Object System.Web.Script.Serialization.JavaScriptSerializer; $j.MaxJsonLength = [int]::MaxValue; $j }
function Read-SharedText([string]$P) {
    $tmp = Join-Path $env:TEMP ('lmt-' + [guid]::NewGuid().ToString('N'))
    try { Copy-Shared $P $tmp; [IO.File]::ReadAllText($tmp) } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
$browsers = @(
    @{ Name = 'chrome'; Rel = 'Google\Chrome\User Data'; Proc = 'chrome' },
    @{ Name = 'edge';   Rel = 'Microsoft\Edge\User Data'; Proc = 'msedge' }
)

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host (" laptop-migration-toolkit v{0} - DELTA SYNC ({1})" -f $ToolkitVersion, $Mode.ToUpper()) -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan

if ($Mode -eq 'Collect') {
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
        if ($env:OneDriveCommercial) { $candidates += (Join-Path $env:OneDriveCommercial 'MigrationPackage\system-info.json'); $candidates += (Join-Path $env:OneDriveCommercial 'DeviceMigration\Package\system-info.json') }
        foreach ($c in $candidates) {
            if (Test-Path -LiteralPath $c) {
                try { $sinceDate = [datetime](Get-Content -LiteralPath $c -Raw | ConvertFrom-Json).CollectedAt; $sinceSource = "full package ($c)"; break } catch { }
            }
        }
    }
    if (-not $sinceDate) {
        Log 'Could not determine the last sync time. Enter a date in the "Changed since" box (e.g. 2026-10-17 09:49).' 'ERROR'
        exit 1
    }
    $sinceDate = $sinceDate.AddHours(-1)
    Log ("Collecting files changed since {0:yyyy-MM-dd HH:mm} (from {1})" -f $sinceDate, $sinceSource) 'STEP'

    $junk = '\\(node_modules|\.git|Cache|Code Cache|GPUCache|Crashpad|logs|CachedData|CachedExtensionVSIXs|Backups|History|checkpoints)\\|local-index[^\\]*\.db$|workspace-chunks\.json$'
    $sources = New-Object System.Collections.Generic.List[object]
    function Add-Source($Root, $Rel, [switch]$Force) { $sources.Add([pscustomobject]@{ Root = $Root; Rel = $Rel; Force = [bool]$Force }) }
    Add-Source APPDATA 'Code\User'
    Add-Source APPDATA 'Code - Insiders\User'
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
        foreach ($sf in 'Desktop', 'Documents', 'Pictures') {
            $full = [Environment]::GetFolderPath($sf)
            if ($full -and $full.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase) -and $full -notmatch 'OneDrive') {
                Add-Source USERPROFILE $full.Substring($env:USERPROFILE.Length).TrimStart('\')
            } else { Log "Skipping $sf (redirected to OneDrive - already synced)" 'WARN' }
        }
    }

    $stage = Join-Path $env:TEMP ('lmt-delta-' + (Get-Date -Format 'yyyyMMddHHmmss'))
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
            if (-not $s.Force -and $f.LastWriteTime -lt $sinceDate) { continue }
            if ($f.Attributes -band [IO.FileAttributes]::Offline) { continue }
            if ($f.FullName -match $junk) { continue }
            $rel = $f.FullName.Substring($roots[$s.Root].Length).TrimStart('\')
            try {
                Copy-Shared $f.FullName (Join-Path (Join-Path $stage $s.Root) $rel)
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

    $now = Get-Date
    [ordered]@{
        ToolkitVersion = $ToolkitVersion; CreatedAt = $now.ToString('o'); Since = $sinceDate.ToString('o')
        Machine = $env:COMPUTERNAME; User = $env:USERNAME; Files = $manifestFiles
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $stage 'delta-manifest.json') -Encoding UTF8

    $zip = Join-Path $Path ('delta-' + $now.ToString('yyyyMMdd-HHmm') + '.zip')
    Log "Packing $($manifestFiles.Count) file(s) into one zip..." 'STEP'
    & tar.exe -a -cf $zip -C $stage . 2>&1 | Out-Null
    if (Test-Path -LiteralPath $zip) {
        Write-PackageSidecar -Zip $zip
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        EnsureDir $stateDir | Out-Null
        [ordered]@{ LastDeltaCollect = $now.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
        Log ("Delta finished: {0} file(s), {1:N1} MB -> {2} ({3} warnings)" -f $manifestFiles.Count, ((Get-Item $zip).Length / 1MB), $zip, $failed) 'OK'
        Write-Host ' Now press "Delta: apply" on the new laptop - it waits for OneDrive by itself and starts once the file has fully arrived.' -ForegroundColor Gray
    } else {
        Log "Zip creation failed. Staged files are kept in $stage" 'ERROR'
        exit 1
    }
    exit 0
}

# ---------------- Apply ----------------
if (-not $Path) { Log 'Choose the folder (or zip) that holds the delta package.' 'ERROR'; exit 1 }
$zipPath = $Path
if (Test-Path -LiteralPath $Path -PathType Container) {
    $lastApplied = $null
    $applyState = Join-Path $stateDir 'last-apply.json'
    if (Test-Path -LiteralPath $applyState) { try { $lastApplied = (Get-Content -LiteralPath $applyState -Raw | ConvertFrom-Json).AppliedZip } catch { } }
    # The small .json sidecar usually arrives before the zip, so look at both.
    $names = @(Get-ChildItem -LiteralPath $Path -File -ErrorAction SilentlyContinue | Where-Object Name -match '^delta-\d{8}-\d{4}\.zip(\.json)?$' | ForEach-Object { $_.Name -replace '\.json$', '' } | Sort-Object -Unique -Descending)
    if ($names.Count -eq 0) { Log "No delta-*.zip in $Path yet. Run 'Delta: collect' on the old laptop first, or wait for OneDrive to show it." 'ERROR'; exit 1 }
    if ($names[0] -eq $lastApplied) {
        Log "Newest delta ($($names[0])) was already applied. If you just collected a new one, OneDrive has not shown it here yet - try again in a few minutes." 'WARN'
        exit 0
    }
    $zipPath = Join-Path $Path $names[0]
}
if ((Test-Path -LiteralPath ($zipPath + '.json')) -or -not (Test-Path -LiteralPath $zipPath)) {
    if (-not (Wait-PackageZip -Zip $zipPath -Log $logSb)) { exit 1 }
}
$zi = Get-Item -LiteralPath $zipPath -Force
Log "Using $zipPath ($([math]::Round($zi.Length / 1MB, 1)) MB)" 'STEP'

$work = Join-Path $env:TEMP ('lmt-delta-apply-' + (Get-Date -Format 'yyyyMMddHHmmss'))
EnsureDir $work | Out-Null
& tar.exe -xf $zipPath -C $work 2>&1 | Out-Null
$manifestPath = Join-Path $work 'delta-manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { Log 'delta-manifest.json missing - extraction failed or not a delta zip' 'ERROR'; exit 1 }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
Log "Delta from $($manifest.Machine), created $($manifest.CreatedAt), $(@($manifest.Files).Count) file(s)" 'OK'

$running = @(Get-Process -Name $appProcesses -ErrorAction SilentlyContinue)
if ($running.Count -gt 0) {
    if ($CloseApps) {
        $running | Stop-Process -Force -ErrorAction SilentlyContinue
        Log "Closed: $((($running | Select-Object -ExpandProperty ProcessName -Unique) -join ', '))" 'OK'
    } else {
        Log "Running now: $((($running | Select-Object -ExpandProperty ProcessName -Unique) -join ', ')). Locked files may fail - tick 'Close apps first'." 'WARN'
    }
}

$backup = Join-Path ([Environment]::GetFolderPath('Desktop')) ('MigrationBackup-delta-' + (Get-Date -Format 'yyyyMMdd-HHmm'))
$applied = 0; $keptNewer = 0; $same = 0; $failedCount = 0
foreach ($e in @($manifest.Files)) {
    if (-not $roots.Contains($e.Root)) { continue }
    $src = Join-Path (Join-Path $work $e.Root) $e.Rel
    $dst = Join-Path $roots[$e.Root] $e.Rel
    if (-not (Test-Path -LiteralPath $src)) { continue }
    try {
        $srcTime = (Get-Item -LiteralPath $src -Force).LastWriteTime
        if (Test-Path -LiteralPath $dst) {
            $dstItem = Get-Item -LiteralPath $dst -Force
            $diff = ($srcTime - $dstItem.LastWriteTime).TotalSeconds
            if ([math]::Abs($diff) -le 2) { $same++; continue }
            if ($diff -lt 0) { $keptNewer++; continue }
            $bk = Join-Path (Join-Path $backup $e.Root) $e.Rel
            EnsureDir (Split-Path -Parent $bk) | Out-Null
            Copy-Item -LiteralPath $dst -Destination $bk -Force -ErrorAction SilentlyContinue
        }
        if ($dst -match '\.db$') { Remove-Item -LiteralPath ($dst + '-wal'), ($dst + '-shm') -Force -ErrorAction SilentlyContinue }
        Copy-Shared $src $dst
        $applied++
    } catch { $failedCount++; Log "Could not write ${dst}: $($_.Exception.Message)" 'WARN' }
}
Log "Files written: $applied, already identical: $same, kept because new laptop copy is newer: $keptNewer, failed: $failedCount" 'OK'
if (Test-Path -LiteralPath $backup) { Log "Overwritten files were backed up to $backup" 'INFO' }

$onenoteReg = Join-Path $work 'onenote-options.reg'
if ((Test-Path -LiteralPath $onenoteReg) -and (Get-Item $onenoteReg).Length -gt 0) {
    reg import $onenoteReg 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { Log 'OneNote options imported' 'OK' } else { Log 'OneNote options import failed' 'WARN' }
}

foreach ($b in $browsers) {
    $pj = Join-Path $work "browser-profiles-$($b.Name).json"
    $broot = Join-Path $env:LOCALAPPDATA $b.Rel
    $lsPath = Join-Path $broot 'Local State'
    if (-not (Test-Path -LiteralPath $pj) -or -not (Test-Path -LiteralPath $lsPath)) { continue }
    if (Get-Process -Name $b.Proc -ErrorAction SilentlyContinue) {
        if ($CloseApps) { Get-Process -Name $b.Proc -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2 }
        else { Log "$($b.Name) is running - profiles were copied but not registered. Close it and run Apply again (or tick 'Close ... first')." 'WARN'; continue }
    }
    try {
        $js = New-Json
        $old = $js.DeserializeObject((Get-Content -LiteralPath $pj -Raw))
        $ls = $js.DeserializeObject([IO.File]::ReadAllText($lsPath))
        if (-not $ls.ContainsKey('profile')) { $ls['profile'] = @{} }
        if (-not $ls['profile'].ContainsKey('info_cache')) { $ls['profile']['info_cache'] = @{} }
        $added = 0
        foreach ($k in @($old.Keys)) {
            if ($ls['profile']['info_cache'].ContainsKey($k) -or -not (Test-Path -LiteralPath (Join-Path $broot $k))) { continue }
            $ls['profile']['info_cache'][$k] = $old[$k]
            if ($ls['profile'].ContainsKey('profiles_order')) { $ls['profile']['profiles_order'] = @($ls['profile']['profiles_order']) + $k }
            $added++
        }
        if ($added -gt 0) {
            $bkLs = Join-Path (Join-Path $backup $b.Name) 'Local State'
            EnsureDir (Split-Path -Parent $bkLs) | Out-Null
            Copy-Item -LiteralPath $lsPath -Destination $bkLs -Force
            [IO.File]::WriteAllText($lsPath, $js.Serialize($ls), (New-Object System.Text.UTF8Encoding($false)))
        }
        Log "$($b.Name): $added profile(s) added to the profile picker" 'OK'
    } catch { Log "$($b.Name) profile registration failed: $($_.Exception.Message)" 'WARN' }
}

if (-not $SkipExtensions) {
    foreach ($fl in 'stable', 'insiders') {
        $list = Join-Path $work "extensions-$fl.txt"
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

$relink = Join-Path $PSScriptRoot 'Repair-WorkspaceChats.ps1'
if (-not $SkipChatRelink -and (Test-Path -LiteralPath $relink)) {
    if (Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue) {
        Log "VS Code is running - per-window chat history was NOT relinked. Close VS Code and run: .\Repair-WorkspaceChats.ps1 -Apply" 'WARN'
    } else {
        & $relink -Apply -BackupPath $backup *>&1 | ForEach-Object { Write-Host $_ }
    }
}

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
EnsureDir $stateDir | Out-Null
[ordered]@{ LastDeltaApply = (Get-Date).ToString('o'); AppliedFrom = $manifest.CreatedAt; AppliedZip = [IO.Path]::GetFileName($zipPath) } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDir 'last-apply.json') -Encoding UTF8
$warns = @($script:Findings | Where-Object { $_ -match '\] WARN' }).Count
$errs = @($script:Findings | Where-Object { $_ -match '\] ERROR' }).Count
Log ("Delta finished: {0} file(s) applied, {1} warnings, {2} errors" -f $applied, $warns, $errs) 'OK'
Write-Host ' Reopen VS Code / Insiders / Notepad++ / OneNote to see the changes.' -ForegroundColor Gray
