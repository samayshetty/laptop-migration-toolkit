[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [switch]$VerifyOnly,
    [switch]$NonInteractive,
    [switch]$NoElevate,
    [switch]$SkipExplorerRestart,
    [switch]$SkipApps,
    [switch]$SkipRegistry,
    [switch]$SkipWifi,
    [switch]$SkipFonts,
    [switch]$SkipEnvVars,
    [switch]$SkipSSH,
    [switch]$SkipUserFiles
)

$ToolkitVersion = '1.2.1'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:NotInteractive = [bool]$NonInteractive -or (-not [Environment]::UserInteractive)
$script:Findings = New-Object System.Collections.Generic.List[string]
$script:Plan = New-Object System.Collections.Generic.List[object]
$script:AppSel = New-Object System.Collections.Generic.List[object]
$script:FilesPolicy = 'keep'
$script:RegistryApplied = $false
$script:WingetDump = ''

$script:AppDataMap = [ordered]@{
    'Microsoft.VisualStudioCode' = @{ Bundle = 'vs-code';          Name = 'VS Code settings & extensions' }
    'Microsoft.VisualStudioCode.Insiders' = @{ Bundle = 'vscode-insiders'; Name = 'VS Code Insiders settings & extensions' }
    'Google.Chrome'              = @{ Bundle = 'browser-chrome';   Name = 'Chrome bookmarks' }
    'Microsoft.Edge'             = @{ Bundle = 'browser-edge';     Name = 'Edge bookmarks' }
    'Microsoft.WindowsTerminal'  = @{ Bundle = 'windows-terminal'; Name = 'Windows Terminal settings' }
    'Git.Git'                    = @{ Bundle = 'git-config';       Name = 'Git config (.gitconfig)' }
}

function Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    $line = "[{0}] {1,-5} {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    Write-Host $line -ForegroundColor $color
    $script:Findings.Add($line)
}

function Test-Admin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-AdminGroup {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $sid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        return [bool]($id.Groups -contains $sid)
    } catch {
        return $false
    }
}

function Invoke-SelfElevate {
    param([switch]$NoElevate)
    if (Test-Admin) { return $false }
    if ($NoElevate -or $script:NotInteractive) { return $false }
    if (-not $script:InAdminGroup) {
        Log 'This account has no Administrator rights - continuing in standard-user mode (Administrator-only steps will be skipped)' 'WARN'
        return $false
    }
    $answer = Read-Host 'The power scheme step works best elevated. Relaunch this script as Administrator? (Y/n)'
    if ($answer -match '^(n|no)') { return $false }
    $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $PSCommandPath + '"'))
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -eq 'NoElevate') { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v.IsPresent) { $forward += @("-$k") } }
        elseif ($v -is [array]) { $forward += @("-$k", ($v -join ',')) }
        else { $forward += @("-$k", "$v") }
    }
    $forward += '-NoElevate'
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $forward | Out-Null
        return $true
    } catch {
        Log 'Elevation was cancelled - continuing without Administrator rights' 'WARN'
        return $false
    }
}

function EnsureDir {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path -Force | Out-Null }
    return $Path
}

function BackupPath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    EnsureDir $script:BackupRoot | Out-Null
    $name = ($Path -replace '^[A-Za-z]:', '') -replace '[\\/:*?"<>|]', '_'
    Copy-Item -LiteralPath $Path -Destination (Join-Path $script:BackupRoot $name) -Recurse -Force -ErrorAction SilentlyContinue
}

function RestoreFile {
    param([string]$Source, [string]$Destination)
    EnsureDir (Split-Path -Parent $Destination) | Out-Null
    BackupPath $Destination
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
}

function RestoreTree {
    param([string]$Source, [string]$Destination)
    BackupPath $Destination
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    robocopy $Source $Destination /E /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { Log "Restore failed: $Destination (robocopy $LASTEXITCODE)" 'ERROR' }
    else { Log "Restored: $Destination" 'OK' }
}

function Get-CodeCli {
    $cmd = Get-Command code -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd'),
        (Join-Path $env:ProgramFiles 'Microsoft VS Code\bin\code.cmd'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft VS Code\bin\code.cmd')
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

function Test-BundlePresent {
    param([string]$Bundle)
    $pkg = $script:PackagePath
    switch ($Bundle) {
        'vs-code'          { return ((Test-Path -LiteralPath (Join-Path $pkg 'dev\vscode-user')) -or (Test-Path -LiteralPath (Join-Path $pkg 'dev\vscode-extensions.txt'))) }
        'vscode-insiders'  { return ((Test-Path -LiteralPath (Join-Path $pkg 'dev\vscode-insiders-user')) -or (Test-Path -LiteralPath (Join-Path $pkg 'dev\vscode-insiders-extensions.txt'))) }
        'windows-terminal' { return (@(Get-ChildItem -LiteralPath (Join-Path $pkg 'terminals') -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }).Count -gt 0) }
        'powershell'       { return ((Test-Path -LiteralPath (Join-Path $pkg 'dev\powershell\WindowsPowerShell')) -or (Test-Path -LiteralPath (Join-Path $pkg 'dev\powershell\PowerShell7'))) }
        'agent-configs'    { return (@(Get-ChildItem -LiteralPath (Join-Path $pkg 'dev\agent-configs') -Force -ErrorAction SilentlyContinue).Count -gt 0) }
        'dotfiles'         { return (@(Get-ChildItem -LiteralPath (Join-Path $pkg 'dev\dotfiles') -Force -ErrorAction SilentlyContinue).Count -gt 0) }
        'git-config'       { return (Test-Path -LiteralPath (Join-Path $pkg 'dev\dotfiles\.gitconfig')) }
        'browser-chrome'   { return (Test-Path -LiteralPath (Join-Path $pkg 'dev\browsers\chrome-default-Bookmarks.json')) }
        'browser-edge'     { return (Test-Path -LiteralPath (Join-Path $pkg 'dev\browsers\edge-default-Bookmarks.json')) }
        'ssh'              { return (@(Get-ChildItem -LiteralPath (Join-Path $pkg 'dev\ssh') -Force -ErrorAction SilentlyContinue).Count -gt 0) }
        'wifi'             { return (@(Get-ChildItem -LiteralPath (Join-Path $pkg 'wifi') -Filter '*.xml' -ErrorAction SilentlyContinue).Count -gt 0) }
        'power'            { return (Test-Path -LiteralPath (Join-Path $pkg 'power\power-scheme.pow')) }
        'fonts'            { return (@(Get-ChildItem -LiteralPath (Join-Path $pkg 'fonts\user-fonts') -File -ErrorAction SilentlyContinue).Count -gt 0) }
        'env'              { return (Test-Path -LiteralPath (Join-Path $pkg 'env\user-env.json')) }
        default            { return $false }
    }
}

function Test-OneDriveRedirected {
    param([string]$FolderName)
    try {
        $usf = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction SilentlyContinue
        $raw = $null
        switch ($FolderName) {
            'Desktop'   { $raw = $usf.Desktop }
            'Documents' { $raw = $usf.Personal }
            'Pictures'  { $raw = $usf.'My Pictures' }
            'Music'     { $raw = $usf.'My Music' }
            'Videos'    { $raw = $usf.'My Videos' }
            default     { return $false }
        }
        if (-not $raw) { return $false }
        $expanded = [Environment]::ExpandEnvironmentVariables($raw)
        return ($expanded -match 'OneDrive')
    } catch { return $false }
}

function New-PlanItem {
    param([string]$Id, [string]$Name, [bool]$Present, [bool]$Apply, [string]$Note = '', [object]$Sub = $null)
    $script:Plan.Add([pscustomobject]@{ Id = $Id; Name = $Name; Present = $Present; Apply = $Apply; Note = $Note; Sub = $Sub })
}

function Get-VersionInfo {
    $ov = $null; $nv = $null
    try { $ov = [version]([string]$script:OldInfo.OSVersion) } catch { $ov = $null }
    try { $nv = [version]((Get-CimInstance Win32_OperatingSystem).Version) } catch { $nv = $null }
    $oldIs11 = ([string]$script:OldInfo.OS) -match 'Windows 11'
    $newIs11 = $script:NewCaption -match 'Windows 11'
    $result = [pscustomobject]@{ CaptionChanged = $false; ReleaseChanged = $false; SkipFiles = @(); Summary = '' }
    if ($oldIs11 -ne $newIs11) {
        $result.CaptionChanged = $true
        $result.SkipFiles = @('taskband', 'taskbar-settings', 'explorer-advanced', 'themes', 'dwm')
        $result.Summary = "OS changed ($($script:OldInfo.OS) -> $script:NewCaption): taskbar layout, theme, pinned items are pre-set to SKIP - you can override in the menu."
    } elseif ($ov -and $nv -and ([math]::Floor($ov.Build / 100) -ne [math]::Floor($nv.Build / 100))) {
        $result.ReleaseChanged = $true
        $result.SkipFiles = @('taskband', 'taskbar-settings')
        $result.Summary = "Windows build changed ($($script:OldInfo.OSVersion) -> $($nv.ToString())): taskbar layout is pre-set to SKIP - you can override in the menu."
    } else {
        $result.Summary = "Operating systems are compatible."
    }
    return $result
}

function Build-AppSel {
    $selFile = Join-Path $script:PackagePath 'apps\app-selection.json'
    $exportFile = Join-Path $script:PackagePath 'apps\winget-export.json'
    if (Test-Path -LiteralPath $selFile) {
        try {
            $sel = Get-Content -LiteralPath $selFile -Raw | ConvertFrom-Json
            foreach ($a in @($sel.Apps)) {
                if (-not $a.Id) { continue }
                $id = [string]$a.Id
                $bundle = $null
                if ($script:AppDataMap.Contains($id)) { $bundle = $script:AppDataMap[$id].Bundle }
                $hasData = $false
                if ($bundle) { $hasData = Test-BundlePresent -Bundle $bundle }
                $mode = 'skip'
                if ([bool]$a.Install -and [bool]$a.Data -and $hasData) { $mode = 'both' }
                elseif ([bool]$a.Install) { $mode = 'app' }
                elseif ([bool]$a.Data -and $hasData) { $mode = 'data' }
                $script:AppSel.Add([pscustomobject]@{ Id = $id; Mode = $mode; HasData = $hasData; DataBundle = $bundle })
            }
            Log "App selection loaded from the old laptop: $(@($script:AppSel | Where-Object { $_.Mode -ne 'skip' }).Count) of $($script:AppSel.Count) active"
        } catch { Log "Could not read app-selection.json: $($_.Exception.Message)" 'WARN' }
    }
    if ($script:AppSel.Count -eq 0 -and (Test-Path -LiteralPath $exportFile)) {
        try {
            $exported = Get-Content -LiteralPath $exportFile -Raw | ConvertFrom-Json
            foreach ($pkg in @($exported.Sources | ForEach-Object { $_.Packages })) {
                if (-not $pkg -or -not $pkg.PackageIdentifier) { continue }
                $id = [string]$pkg.PackageIdentifier
                $bundle = $null
                if ($script:AppDataMap.Contains($id)) { $bundle = $script:AppDataMap[$id].Bundle }
                $hasData = $false
                if ($bundle) { $hasData = Test-BundlePresent -Bundle $bundle }
                $mode = 'app'; if ($hasData) { $mode = 'both' }
                $script:AppSel.Add([pscustomobject]@{ Id = $id; Mode = $mode; HasData = $hasData; DataBundle = $bundle })
            }
            Log "No app selection file found - defaulting to all $($script:AppSel.Count) apps"
        } catch { Log "Could not read winget-export.json: $($_.Exception.Message)" 'WARN' }
    }
}

function Build-Plan {
    $script:Claimed = @{}
    $script:ClaimedAny = @{}
    foreach ($a in ($script:AppSel | Where-Object { $_.DataBundle })) {
        $script:ClaimedAny[$a.DataBundle] = $true
        if ($a.Mode -in @('both', 'data')) { $script:Claimed[$a.DataBundle] = $true }
    }

    if (-not $SkipApps -and $script:AppSel.Count -gt 0) {
        $active = @($script:AppSel | Where-Object { $_.Mode -ne 'skip' }).Count
        $withData = @($script:AppSel | Where-Object { $_.Mode -in @('both', 'data') }).Count
        New-PlanItem -Id 'apps' -Name 'Applications (install with winget)' -Present $true -Apply ($active -gt 0) -Note "selected: $active of $($script:AppSel.Count); with data: $withData. Press 'a' to change modes."
    }

    $bundleDefs = @(
        @{ Id = 'vs-code';          Name = 'VS Code settings & extensions' },
        @{ Id = 'vscode-insiders';  Name = 'VS Code Insiders settings & extensions' },
        @{ Id = 'windows-terminal'; Name = 'Windows Terminal settings' },
        @{ Id = 'powershell';       Name = 'PowerShell profiles' },
        @{ Id = 'agent-configs';    Name = 'Agent/skill configs (opencode, Claude, Codex, Gemini, Cursor)' },
        @{ Id = 'dotfiles';         Name = 'Dotfiles (.npmrc, .wslconfig, .vimrc, ...)' },
        @{ Id = 'git-config';       Name = 'Git config (.gitconfig)' },
        @{ Id = 'browser-chrome';   Name = 'Chrome bookmarks' },
        @{ Id = 'browser-edge';     Name = 'Edge bookmarks' },
        @{ Id = 'ssh';              Name = 'SSH keys (sensitive)' },
        @{ Id = 'wifi';             Name = 'Wi-Fi profiles' },
        @{ Id = 'power';            Name = 'Power scheme' },
        @{ Id = 'fonts';            Name = 'User-installed fonts' },
        @{ Id = 'env';              Name = 'Environment variables' }
    )
    foreach ($def in $bundleDefs) {
        if (-not (Test-BundlePresent -Bundle $def.Id)) { continue }
        $apply = $true
        $note = ''
        if ($script:ClaimedAny.ContainsKey($def.Id)) {
            if ($script:Claimed.ContainsKey($def.Id)) { $note = 'data tied to app selection' }
            else { $apply = $false; $note = 'excluded by app selection (change app mode to include its data)' }
        }
        if ($def.Id -eq 'ssh' -and $SkipSSH) { $apply = $false; $note = 'skipped by switch' }
        if ($def.Id -eq 'wifi' -and $SkipWifi) { $apply = $false; $note = 'skipped by switch' }
        if ($def.Id -eq 'fonts' -and $SkipFonts) { $apply = $false; $note = 'skipped by switch' }
        if ($def.Id -eq 'env' -and $SkipEnvVars) { $apply = $false; $note = 'skipped by switch' }
        if ($def.Id -eq 'power' -and -not $script:IsAdmin) { $apply = $false; $note = 'needs Administrator - skipped now (re-run this script elevated later to apply it)' }
        New-PlanItem -Id $def.Id -Name $def.Name -Present $true -Apply $apply -Note $note
    }

    if (-not $SkipRegistry) {
        $persoDir = Join-Path $script:PackagePath 'personalization'
        $subs = New-Object System.Collections.Generic.List[object]
        $regFiles = @(Get-ChildItem -LiteralPath $persoDir -Filter '*.reg' -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($rf in $regFiles) {
            $base = [IO.Path]::GetFileNameWithoutExtension($rf.Name)
            $apply = $true; $reason = ''
            if ($script:VersionInfo.SkipFiles -contains $base) { $apply = $false; $reason = 'version mismatch - recommended SKIP' }
            $subs.Add([pscustomobject]@{ File = $rf.Name; Apply = $apply; Reason = $reason })
        }
        if ($subs.Count -gt 0) {
            $skipCount = @($subs | Where-Object { -not $_.Apply }).Count
            $name = 'Visuals, theme, taskbar, wallpaper'
            if ($skipCount -gt 0) { $name += " ($skipCount pre-set to SKIP - press 'p' to review)" }
            New-PlanItem -Id 'personalization' -Name $name -Present $true -Apply $true -Note $script:VersionInfo.Summary -Sub $subs
        }
    }

    if ((Test-Path -LiteralPath (Join-Path $script:PackagePath 'files')) -and -not $SkipUserFiles) {
        New-PlanItem -Id 'files' -Name 'Personal folders (Desktop, Documents, Downloads, ...)' -Present $true -Apply $true -Note "policy: $($script:FilesPolicy) - press 'f' to change"
    }
}

function Show-Plan {
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor Cyan
    Write-Host (' MIGRATION PLAN  |  old: ' + $script:OldCaption + '  ->  new: ' + $script:NewCaption) -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor Cyan
    $i = 0
    foreach ($p in $script:Plan) {
        $i++
        $state = if ($p.Apply) { 'APPLY' } else { 'SKIP ' }
        $color = if ($p.Apply) { 'Green' } else { 'DarkGray' }
        Write-Host ('{0,3}) [{1}] {2}' -f $i, $state, $p.Name) -ForegroundColor $color
        if ($p.Note) { Write-Host ('        ' + $p.Note) -ForegroundColor Yellow }
    }
    Write-Host ''
}

function Edit-Plan {
    while ($true) {
        Show-Plan
        Write-Host " Commands: numbers toggle apply/skip | a = apps | p = personalization | f = files policy | s = save & run | q = quit" -ForegroundColor White
        $sel = (Read-Host 'Choice').Trim().ToLower()
        if ($sel -eq '') { continue }
        if ($sel -match '^(s|save|run)$') { return 'run' }
        if ($sel -match '^(q|quit|exit)$') { return 'quit' }
        if ($sel -match '^(a|apps)$') { Edit-Apps; continue }
        if ($sel -match '^(p|perso|personalization)$') { Edit-Personalization; continue }
        if ($sel -match '^(f|files)$') { Edit-FilesPolicy; continue }
        foreach ($token in ($sel -split '[,\s]+' | Where-Object { $_ })) {
            $n = 0
            if ([int]::TryParse($token, [ref]$n) -and $n -ge 1 -and $n -le $script:Plan.Count) {
                $script:Plan[$n - 1].Apply = -not $script:Plan[$n - 1].Apply
            } else {
                Write-Host "  '$token' is not a valid item number" -ForegroundColor Yellow
            }
        }
    }
}

function Edit-Apps {
    while ($true) {
        Write-Host ''
        Write-Host 'APP MODES - enter numbers to cycle a mode. Legend:' -ForegroundColor Cyan
        Write-Host '  [both] install app + restore its data    [app ] install app only' -ForegroundColor Gray
        Write-Host '  [data] restore data only, no install     [skip] ignore completely' -ForegroundColor Gray
        Write-Host '  b = back' -ForegroundColor White
        $i = 0
        foreach ($a in $script:AppSel) {
            $i++
            $modeText = '{0,-4}' -f $a.Mode
            $note = ''
            if ($a.HasData) { $note = '  (data: ' + $script:AppDataMap[$a.Id].Name + ')' }
            $color = 'DarkGray'
            if ($a.Mode -ne 'skip') { $color = 'Green' }
            Write-Host ('{0,4}) [{1}] {2}{3}' -f $i, $modeText, $a.Id, $note) -ForegroundColor $color
        }
        $sel = (Read-Host 'Choice').Trim().ToLower()
        if ($sel -eq '') { continue }
        if ($sel -match '^(b|back)$') { return }
        foreach ($token in ($sel -split '[,\s]+' | Where-Object { $_ })) {
            $n = 0
            if ([int]::TryParse($token, [ref]$n) -and $n -ge 1 -and $n -le $script:AppSel.Count) {
                $a = $script:AppSel[$n - 1]
                if ($a.HasData) {
                    switch ($a.Mode) {
                        'both' { $a.Mode = 'app' }
                        'app'  { $a.Mode = 'data' }
                        'data' { $a.Mode = 'skip' }
                        default { $a.Mode = 'both' }
                    }
                } else {
                    if ($a.Mode -eq 'app') { $a.Mode = 'skip' } else { $a.Mode = 'app' }
                }
            } else {
                Write-Host "  '$token' is not a valid item number" -ForegroundColor Yellow
            }
        }
    }
}

function Edit-Personalization {
    $item = $script:Plan | Where-Object { $_.Id -eq 'personalization' }
    if (-not $item) { return }
    while ($true) {
        Write-Host ''
        Write-Host 'VISUALS / REGISTRY ITEMS - enter numbers to toggle. b = back' -ForegroundColor Cyan
        $i = 0
        foreach ($sub in $item.Sub) {
            $i++
            $state = if ($sub.Apply) { 'APPLY' } else { 'SKIP ' }
            $color = if ($sub.Apply) { 'Green' } else { 'DarkGray' }
            Write-Host ('{0,3}) [{1}] {2} {3}' -f $i, $state, $sub.File, $sub.Reason) -ForegroundColor $color
        }
        $sel = (Read-Host 'Choice').Trim().ToLower()
        if ($sel -eq '') { continue }
        if ($sel -match '^(b|back)$') { return }
        foreach ($token in ($sel -split '[,\s]+' | Where-Object { $_ })) {
            $n = 0
            if ([int]::TryParse($token, [ref]$n) -and $n -ge 1 -and $n -le $item.Sub.Count) {
                $item.Sub[$n - 1].Apply = -not $item.Sub[$n - 1].Apply
            } else {
                Write-Host "  '$token' is not a valid item number" -ForegroundColor Yellow
            }
        }
    }
}

function Edit-FilesPolicy {
    Write-Host ''
    Write-Host 'FILES POLICY - how should files already on THIS laptop be treated?' -ForegroundColor Cyan
    Write-Host '  k = keep existing (copy only files that do not exist yet) [default]' -ForegroundColor Gray
    Write-Host '  r = replace       (old laptop versions overwrite this laptop copies)' -ForegroundColor Gray
    Write-Host '  s = skip          (do not restore personal files at all)' -ForegroundColor Gray
    $answer = (Read-Host 'Choice (k/r/s)').Trim().ToLower()
    if ($answer -eq 'r') { $script:FilesPolicy = 'replace' }
    elseif ($answer -eq 's') { $script:FilesPolicy = 'skip' }
    else { $script:FilesPolicy = 'keep' }
    $item = $script:Plan | Where-Object { $_.Id -eq 'files' }
    if ($item) { $item.Note = "policy: $($script:FilesPolicy) - press 'f' to change" }
}

function Invoke-AppExec {
    Log 'Checking which selected apps are already installed...' 'STEP'
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $script:WingetDump = (winget list --accept-source-agreements 2>&1 | Out-String)
    }
    $toInstall = New-Object System.Collections.Generic.List[string]
    foreach ($a in $script:AppSel) {
        if ($a.Mode -in @('both', 'app')) {
            if ($script:WingetDump -and ($script:WingetDump -match [regex]::Escape($a.Id))) {
                Log "Already installed - skipping install: $($a.Id)" 'OK'
            } else {
                $toInstall.Add($a.Id)
            }
        }
    }
    if ($toInstall.Count -gt 0) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            Log 'winget is not available - install apps manually from apps\winget-list.txt' 'WARN'
        } else {
            $exportFile = Join-Path $script:PackagePath 'apps\winget-export.json'
            $sourceDetails = $null
            if (Test-Path -LiteralPath $exportFile) {
                try {
                    $exported = Get-Content -LiteralPath $exportFile -Raw | ConvertFrom-Json
                    $sourceDetails = $exported.Sources[0].SourceDetails
                } catch { $sourceDetails = $null }
            }
            if (-not $sourceDetails) {
                $sourceDetails = [ordered]@{ Argument = 'https://cdn.winget.microsoft.com/cache'; Identifier = 'Microsoft.Winget.Source_8wekyb3d8bbwe'; Name = 'winget'; Type = 'Microsoft.PreIndexed.Package' }
            }
            $importObj = [ordered]@{
                '$schema'    = 'https://aka.ms/winget-packages.schema.2.0.json'
                CreationDate = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
                Sources      = @([ordered]@{
                    Packages      = @($toInstall | ForEach-Object { [ordered]@{ PackageIdentifier = $_ } })
                    SourceDetails = $sourceDetails
                })
            }
            $tmp = Join-Path $env:TEMP ('winget-import-' + (Get-Date -Format 'yyyyMMddHHmmss') + '.json')
            $importObj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $tmp -Encoding UTF8
            Log "Installing $($toInstall.Count) apps with winget - this can take a long time..." 'STEP'
            $null = winget import -i $tmp --accept-package-agreements --accept-source-agreements --ignore-unavailable 2>&1
            if ($LASTEXITCODE -ne 0) {
                Log 'Retrying winget import without --ignore-unavailable...' 'WARN'
                $null = winget import -i $tmp --accept-package-agreements --accept-source-agreements 2>&1
            }
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
            if ($LASTEXITCODE -eq 0) { Log 'App installation pass finished' 'OK' }
            else { Log 'Some apps may have failed - review the winget output above' 'WARN' }
        }
    } else {
        Log 'No apps need installing (all selected apps already installed)' 'OK'
    }
    foreach ($a in $script:AppSel) {
        if ($a.DataBundle -and ($a.Mode -in @('both', 'data'))) { Invoke-Bundle -Bundle $a.DataBundle }
    }
}

function Restore-VsCodeBundle {
    param([string]$UserDir, [string]$PackageDir, [string]$AgentDir)
    if (Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue) {
        throw 'Close BOTH VS Code editions before restoring chat data. Run from standalone PowerShell.'
    }
    $src = Join-Path $script:PackagePath "dev\$PackageDir"
    if (Test-Path -LiteralPath $src) { RestoreTree $src (Join-Path $env:APPDATA "$UserDir\User") }
    $src = Join-Path $script:PackagePath "dev\$AgentDir"
    if (Test-Path -LiteralPath $src) { RestoreTree $src (Join-Path $env:APPDATA "$UserDir\agentSessionData") }
}

function Install-CodeExtensionLists {
    foreach ($fl in @(
        @{ Bundle = 'vs-code'; File = 'vscode-extensions.txt'; Cli = 'stable' },
        @{ Bundle = 'vscode-insiders'; File = 'vscode-insiders-extensions.txt'; Cli = 'insiders' }
    )) {
        if (-not ($script:Plan | Where-Object { $_.Id -eq $fl.Bundle -and $_.Apply -and $_.Present })) { continue }
        $extFile = Join-Path $script:PackagePath "dev\$($fl.File)"
        if (-not (Test-Path -LiteralPath $extFile)) { continue }
        $cli = Get-VsCodeCli $fl.Cli
        if (-not $cli) { Log "VS Code ($($fl.Cli)) CLI not found - install the editor and rerun to add extensions" 'WARN'; continue }
        $exts = @(Get-Content -LiteralPath $extFile | Where-Object { $_.Trim() })
        Set-NodeCaFromWindows
        $bad = @()
        foreach ($ext in $exts) {
            if ((Install-VsCodeExtension -Cli $cli -Id $ext.Trim()) -ne 'ok') { $bad += $ext.Trim() }
        }
        if ($bad.Count) { Log "VS Code ($($fl.Cli)) extensions not installed: $($bad -join ', ')" 'WARN' }
        else { Log "VS Code ($($fl.Cli)): $($exts.Count) extensions installed" 'OK' }
    }
}

function Invoke-Bundle {
    param([string]$Bundle)
    switch ($Bundle) {
        'vs-code' {
            Restore-VsCodeBundle 'Code' 'vscode-user' 'vscode-agentSessionData'
        }
        'vscode-insiders' {
            Restore-VsCodeBundle 'Code - Insiders' 'vscode-insiders-user' 'vscode-insiders-agentSessionData'
        }
        'windows-terminal' {
            $termMap = [ordered]@{
                'WindowsTerminal'        = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState')
                'WindowsTerminalPreview' = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState')
                'WindowsTerminalLegacy'  = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal')
            }
            foreach ($k in $termMap.Keys) {
                $src = Join-Path (Join-Path $script:PackagePath 'terminals') $k
                if (Test-Path -LiteralPath $src) { RestoreTree $src $termMap[$k] }
            }
        }
        'powershell' {
            $psMap = [ordered]@{
                'WindowsPowerShell' = (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell')
                'PowerShell7'       = (Join-Path $env:USERPROFILE 'Documents\PowerShell')
            }
            foreach ($k in $psMap.Keys) {
                $src = Join-Path (Join-Path $script:PackagePath 'dev\powershell') $k
                if (Test-Path -LiteralPath $src) { RestoreTree $src $psMap[$k] }
            }
        }
        'agent-configs' {
            $src = Join-Path $script:PackagePath 'dev\agent-configs'
            if (Test-Path -LiteralPath $src) {
                foreach ($item in Get-ChildItem -Force -LiteralPath $src) {
                    $dest = Join-Path $env:USERPROFILE $item.Name
                    if ($item.PSIsContainer) { RestoreTree $item.FullName $dest } else { RestoreFile $item.FullName $dest }
                }
                Log 'Agent/skill configs restored (opencode, Claude, Codex, Gemini, Cursor)' 'OK'
            }
        }
        'dotfiles' {
            $src = Join-Path $script:PackagePath 'dev\dotfiles'
            if (Test-Path -LiteralPath $src) {
                foreach ($item in Get-ChildItem -Force -LiteralPath $src) {
                    $dest = Join-Path $env:USERPROFILE $item.Name
                    if ($item.PSIsContainer) { RestoreTree $item.FullName $dest } else { RestoreFile $item.FullName $dest }
                }
                Log 'Dotfiles restored' 'OK'
            }
        }
        'git-config' {
            $src = Join-Path $script:PackagePath 'dev\dotfiles\.gitconfig'
            if (Test-Path -LiteralPath $src) {
                RestoreFile $src (Join-Path $env:USERPROFILE '.gitconfig')
                Log 'Git config restored' 'OK'
            }
        }
        'browser-chrome' {
            $src = Join-Path $script:PackagePath 'dev\browsers\chrome-default-Bookmarks.json'
            if (Test-Path -LiteralPath $src) {
                $dest = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Bookmarks'
                EnsureDir (Split-Path -Parent $dest) | Out-Null
                RestoreFile $src $dest
                Log 'Chrome bookmarks restored (close Chrome fully, then reopen)' 'OK'
            }
        }
        'browser-edge' {
            $src = Join-Path $script:PackagePath 'dev\browsers\edge-default-Bookmarks.json'
            if (Test-Path -LiteralPath $src) {
                $dest = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Bookmarks'
                EnsureDir (Split-Path -Parent $dest) | Out-Null
                RestoreFile $src $dest
                Log 'Edge bookmarks restored (close Edge fully, then reopen)' 'OK'
            }
        }
        'ssh' {
            $src = Join-Path $script:PackagePath 'dev\ssh'
            if (Test-Path -LiteralPath $src) {
                $sshDest = Join-Path $env:USERPROFILE '.ssh'
                RestoreTree $src $sshDest
                $principal = "$env:USERDOMAIN\$env:USERNAME"
                $null = icacls $sshDest /inheritance:r 2>&1
                $null = icacls $sshDest /grant:r ($principal + ':(F)') 2>&1
                Get-ChildItem -LiteralPath $sshDest -Force -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^id_(rsa|dsa|ecdsa|ed25519)$' } |
                    ForEach-Object {
                        $null = icacls $_.FullName /inheritance:r 2>&1
                        $null = icacls $_.FullName /grant:r ($principal + ':(R)') 2>&1
                    }
                Log 'SSH keys restored with locked-down permissions' 'OK'
            }
        }
        'wifi' {
            $wifiDir = Join-Path $script:PackagePath 'wifi'
            $xmls = @(Get-ChildItem -LiteralPath $wifiDir -Filter '*.xml' -ErrorAction SilentlyContinue)
            $ok = 0
            foreach ($x in $xmls) {
                $null = cmd /c "netsh wlan add profile filename=""$($x.FullName)"" user=current 2>&1"
                if ($LASTEXITCODE -eq 0) { $ok++ } else { Log "Wi-Fi profile failed: $($x.BaseName)" 'WARN' }
            }
            Log "Wi-Fi profiles processed: $ok of $($xmls.Count)" 'OK'
        }
        'power' {
            $pow = Join-Path $script:PackagePath 'power\power-scheme.pow'
            if (Test-Path -LiteralPath $pow) {
                $out = cmd /c "powercfg /import ""$pow"" 2>&1"
                if ($out -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') {
                    $null = powercfg /setactive $matches[1] 2>&1
                    Log 'Power scheme imported and activated' 'OK'
                } else {
                    Log 'Power scheme import failed (Administrator rights required)' 'WARN'
                }
            }
        }
        'fonts' {
            $uf = Join-Path $script:PackagePath 'fonts\user-fonts'
            if (Test-Path -LiteralPath $uf) {
                Log 'Restoring user-installed fonts...' 'STEP'
                $fontDest = EnsureDir (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts')
                $count = 0
                Get-ChildItem -LiteralPath $uf -File -ErrorAction SilentlyContinue | ForEach-Object {
                    if ($_.Extension -match '(?i)\.(ttf|otf|ttc|fon)$') {
                        $target = Join-Path $fontDest $_.Name
                        Copy-Item -LiteralPath $_.FullName -Destination $target -Force
                        $fontName = [IO.Path]::GetFileNameWithoutExtension($_.Name) + ' (TrueType)'
                        Set-ItemProperty 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts' -Name $fontName -Value $target -ErrorAction SilentlyContinue
                        $count++
                    }
                }
                Log "Fonts restored: $count" 'OK'
            }
        }
        'env' {
            $envJson = Join-Path $script:PackagePath 'env\user-env.json'
            if (Test-Path -LiteralPath $envJson) {
                Log 'Restoring user environment variables...' 'STEP'
                $oldEnv = Get-Content -LiteralPath $envJson -Raw | ConvertFrom-Json
                $currentPath = [Environment]::GetEnvironmentVariable('Path', 'User')
                $pathParts = @()
                if ($currentPath) { $pathParts += ($currentPath.Split(';') | Where-Object { $_ }) }
                foreach ($prop in $oldEnv.PSObject.Properties) {
                    $val = [string]$prop.Value
                    if ($prop.Name -ieq 'Path') {
                        foreach ($p in ($val.Split(';') | Where-Object { $_ })) {
                            $np = $p
                            if ($script:OldProfile -and $np.StartsWith($script:OldProfile, [StringComparison]::OrdinalIgnoreCase)) { $np = $np.Replace($script:OldProfile, $env:USERPROFILE) }
                            if ($pathParts -notcontains $np) { $pathParts += $np }
                        }
                        continue
                    }
                    if ($script:OldProfile -and $val.Contains($script:OldProfile)) { $val = $val.Replace($script:OldProfile, $env:USERPROFILE) }
                    [Environment]::SetEnvironmentVariable($prop.Name, $val, 'User')
                }
                [Environment]::SetEnvironmentVariable('Path', ($pathParts -join ';'), 'User')
                Log 'Environment variables restored (PATH merged, old user paths translated)' 'OK'
            }
        }
    }
}

function Invoke-Personalization {
    $item = $script:Plan | Where-Object { $_.Id -eq 'personalization' }
    if (-not $item) { return }
    $persoDir = Join-Path $script:PackagePath 'personalization'
    foreach ($sub in $item.Sub) {
        if (-not $sub.Apply) { Log "Skipped registry item: $([IO.Path]::GetFileNameWithoutExtension($sub.File))" 'WARN'; continue }
        $regFile = Join-Path $persoDir $sub.File
        if (-not (Test-Path -LiteralPath $regFile)) { continue }
        $keyLine = Get-Content -LiteralPath $regFile -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\[' } | Select-Object -First 1
        if ($keyLine) {
            $regKey = $keyLine.Trim('[', ']').TrimStart('-')
            if (Test-Path -LiteralPath ('Registry::' + $regKey)) {
                EnsureDir $script:BackupRoot | Out-Null
                reg export $regKey (Join-Path $script:BackupRoot ('regbackup-' + [IO.Path]::GetFileNameWithoutExtension($sub.File) + '.reg')) /y | Out-Null
            }
        }
        reg import $regFile | Out-Null
        if ($LASTEXITCODE -eq 0) { Log "Applied registry item: $([IO.Path]::GetFileNameWithoutExtension($sub.File))" 'OK'; $script:RegistryApplied = $true }
        else { Log "Registry import failed: $($sub.File)" 'WARN' }
    }
    $wpSource = Get-ChildItem -LiteralPath $persoDir -Filter 'wallpaper.*' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($wpSource) {
        $themesDir = EnsureDir (Join-Path $env:APPDATA 'Microsoft\Windows\Themes')
        $wpDest = Join-Path $themesDir ('MigrationWallpaper' + $wpSource.Extension)
        Copy-Item -LiteralPath $wpSource.FullName -Destination $wpDest -Force
        $transcoded = Join-Path $persoDir 'TranscodedWallpaper'
        if (Test-Path -LiteralPath $transcoded) { Copy-Item -LiteralPath $transcoded -Destination (Join-Path $themesDir 'TranscodedWallpaper') -Force }
        $cached = Join-Path $persoDir 'CachedFiles'
        if (Test-Path -LiteralPath $cached) {
            EnsureDir (Join-Path $themesDir 'CachedFiles') | Out-Null
            robocopy $cached (Join-Path $themesDir 'CachedFiles') /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        }
        Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name Wallpaper -Value $wpDest -ErrorAction SilentlyContinue
        Add-Type -Namespace MigrateWin32 -Name User32 -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Auto, SetLastError=true)] public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);' -ErrorAction SilentlyContinue
        [MigrateWin32.User32]::SystemParametersInfo(0x14, 0, $wpDest, 3) | Out-Null
        Log 'Wallpaper applied' 'OK'
    }
}

function Copy-FolderContent {
    param([string]$Source, [string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    if ($script:FilesPolicy -eq 'replace') {
        robocopy $Source $Destination /E /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
    } else {
        robocopy $Source $Destination /E /XN /XO /XC /R:1 /W:1 /XJ /NFL /NDL /NJH /NJS /NP | Out-Null
    }
    if ($LASTEXITCODE -ge 8) { Log "Restore failed: $Destination (robocopy $LASTEXITCODE)" 'ERROR' }
    else { Log "Restored folder: $(Split-Path $Destination -Leaf)" 'OK' }
}

function Invoke-Files {
    if ($script:FilesPolicy -eq 'skip') { Log 'User files skipped by choice' 'WARN'; return }
    $filesRoot = Join-Path $script:PackagePath 'files'
    if (-not (Test-Path -LiteralPath $filesRoot)) { return }
    Log 'Copying personal folders...' 'STEP'
    foreach ($folder in (Get-ChildItem -LiteralPath $filesRoot -Directory)) {
        if ($folder.Name -eq 'extra') {
            foreach ($sub in Get-ChildItem -LiteralPath $folder.FullName -Directory) {
                Copy-FolderContent -Source $sub.FullName -Destination (Join-Path $env:USERPROFILE $sub.Name)
            }
            continue
        }
        if (Test-OneDriveRedirected -FolderName $folder.Name) {
            Log "$($folder.Name) is already synced by OneDrive on this laptop - skipping to avoid duplicates" 'WARN'
            continue
        }
        Copy-FolderContent -Source $folder.FullName -Destination (Join-Path $env:USERPROFILE $folder.Name)
    }
}

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host (' laptop-migration-toolkit v' + $ToolkitVersion) -ForegroundColor Cyan
Write-Host ' RESTORE - run this on the NEW laptop                    ' -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan

$script:InAdminGroup = Test-AdminGroup
if (Invoke-SelfElevate -NoElevate:$NoElevate) { exit 0 }
$isAdmin = Test-Admin
$script:IsAdmin = $isAdmin
if (-not $isAdmin) {
    if ($script:InAdminGroup) { Log 'Running without Administrator rights - the power scheme step will be skipped (re-run elevated later to include it)' 'WARN' }
    else { Log 'Standard user account (no Administrator rights) - Administrator-only steps will be skipped; everything else is restored normally' 'WARN' }
}

. (Join-Path $PSScriptRoot 'MigrationCommon.ps1')
try { $PackagePath = Resolve-MigrationPackage -Path $PackagePath -Log { param($m, $l) Log $m $(if ($l) { $l } else { 'INFO' }) } }
catch { Log $_.Exception.Message 'ERROR'; throw }
$script:PackagePath = [IO.Path]::GetFullPath($PackagePath)
$infoFile = Join-Path $script:PackagePath 'system-info.json'
if (-not (Test-Path -LiteralPath $infoFile)) {
    Log "No system-info.json found in $script:PackagePath - this does not look like a migration package" 'ERROR'
    throw 'Invalid package folder'
}
$script:OldInfo = Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json
$script:OldProfile = [string]$script:OldInfo.UserProfile
$script:NewCaption = (Get-CimInstance Win32_OperatingSystem).Caption
$script:OldCaption = [string]$script:OldInfo.OS

Log "Package from $($script:OldInfo.ComputerName) / user $($script:OldInfo.UserName), collected $($script:OldInfo.CollectedAt)"
if ($script:OldInfo.ToolkitVersion) { Log "Package created with toolkit v$($script:OldInfo.ToolkitVersion)" }
else { Log 'Package created with an older toolkit version - fully supported' }
if ($script:OldProfile -and ($script:OldProfile -ine $env:USERPROFILE)) {
    Log "User profile path differs ($script:OldProfile -> $env:USERPROFILE) - paths will be translated where possible" 'WARN'
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$backupBase = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($backupBase) -or -not (Test-Path -LiteralPath $backupBase)) { $backupBase = $env:USERPROFILE }
if ([string]::IsNullOrWhiteSpace($backupBase)) { $backupBase = $env:TEMP }
$script:BackupRoot = Join-Path $backupBase ("MigrationBackup-$stamp")
EnsureDir $script:BackupRoot | Out-Null
Log "Anything overwritten will be backed up to: $script:BackupRoot"

$script:VersionInfo = Get-VersionInfo
Log $script:VersionInfo.Summary 'STEP'

Build-AppSel
Build-Plan

if ($script:Plan.Count -eq 0) {
    Log 'Nothing to restore - the package contains no supported items' 'ERROR'
    exit 1
}

if ($VerifyOnly) {
    Show-Plan
    $applyCount = @($script:Plan | Where-Object { $_.Apply }).Count
    Write-Host " VERIFY ONLY: $applyCount of $($script:Plan.Count) items would be applied. No changes were made." -ForegroundColor Cyan
    Write-Host " Run again without -VerifyOnly to execute." -ForegroundColor Gray
    exit 0
}

if (-not $script:NotInteractive) {
    $decision = Edit-Plan
    if ($decision -eq 'quit') { Log 'Cancelled by user - nothing was changed' 'WARN'; exit 0 }
    $answer = Read-Host 'Proceed with the migration now? (Y/n)'
    if ($answer -match '^(n|no)') { Log 'Cancelled by user - nothing was changed' 'WARN'; exit 0 }
} else {
    Log 'Running non-interactively - using recommended defaults' 'WARN'
}

foreach ($p in $script:Plan) {
    if (-not $p.Apply -or -not $p.Present) { continue }
    switch ($p.Id) {
        'apps'            { Invoke-AppExec }
        'personalization' { Invoke-Personalization }
        'files'            { Invoke-Files }
        default           { Invoke-Bundle -Bundle $p.Id }
    }
}

# Extension CLIs can start editor processes; run them after both editions' data is restored.
Install-CodeExtensionLists

if ($script:RegistryApplied -and -not $SkipExplorerRestart) {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Log 'Explorer restarted to apply taskbar and theme changes' 'OK'
}

$reportPath = Join-Path $script:BackupRoot 'restore-log.txt'
$script:Findings | Set-Content -LiteralPath $reportPath -Encoding UTF8
$errors = @($script:Findings | Where-Object { $_ -match '\] ERROR' }).Count
$warns = @($script:Findings | Where-Object { $_ -match '\] WARN' }).Count

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host (" Restore finished: {0} warnings, {1} errors" -f $warns, $errors) -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host " Backups of overwritten files/registry keys: $script:BackupRoot" -ForegroundColor Gray
Write-Host " Full log: $reportPath" -ForegroundColor Gray
if (-not $script:IsAdmin) {
    Write-Host ' Skipped (Administrator rights required): Power scheme.' -ForegroundColor Yellow
    Write-Host ' Everything else was restored. To apply the power scheme later, run this same' -ForegroundColor Gray
    Write-Host ' script again from an Administrator PowerShell - re-running is safe.' -ForegroundColor Gray
}
Write-Host ' Sign out or reboot to fully apply everything.' -ForegroundColor White
Write-Host ''
