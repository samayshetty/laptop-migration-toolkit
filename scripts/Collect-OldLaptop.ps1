[CmdletBinding()]
param(
    [string]$OutputPath,
    [switch]$InteractiveApps,
    [switch]$IncludeUserFiles,
    [string[]]$ExtraFolders = @(),
    [switch]$SkipApps,
    [switch]$SkipSSH,
    [switch]$IncludeVscodeHistory,
    [switch]$IncludeCursorExtensions,
    [switch]$Archive,
    [switch]$NonInteractive,
    [switch]$NoElevate
)

$ToolkitVersion = '1.2.1'
$PackageFormat = 2
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$script:NotInteractive = [bool]$NonInteractive -or (-not [Environment]::UserInteractive)
$script:Findings = New-Object System.Collections.Generic.List[string]

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

function Invoke-SelfElevate {
    param([switch]$NoElevate)
    if (Test-Admin) { return $false }
    if ($NoElevate -or $script:NotInteractive) { return $false }
    $answer = Read-Host 'Administrator rights make Wi-Fi password export work. Relaunch this script elevated? (Y/n)'
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

function CopyTree {
    param([string]$Source, [string]$Destination, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @())
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    try {
        EnsureDir $Destination | Out-Null
        $rcArgs = @($Source, $Destination, '/E', '/R:1', '/W:1', '/XJ', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
        foreach ($xd in $ExcludeDirs) { $rcArgs += @('/XD', $xd) }
        foreach ($xf in $ExcludeFiles) { $rcArgs += @('/XF', $xf) }
        robocopy @rcArgs | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "robocopy exit code $LASTEXITCODE" }
        return $true
    } catch {
        Log "Copy failed: $Source ($($_.Exception.Message))" 'ERROR'
        return $false
    }
}

function CopyFileSafe {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source)) { return $false }
    try {
        EnsureDir (Split-Path -Parent $Destination) | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        return $true
    } catch {
        Log "Copy failed: $Source ($($_.Exception.Message))" 'ERROR'
        return $false
    }
}

function Test-DataAvailable {
    param([string]$AppId)
    switch ($AppId) {
        'Microsoft.VisualStudioCode' { return (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Code\User')) }
        'Microsoft.VisualStudioCode.Insiders' { return (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Code - Insiders\User')) }
        'Google.Chrome'              { return (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Bookmarks')) }
        'Microsoft.Edge'             { return (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Bookmarks')) }
        'Microsoft.WindowsTerminal'  { return ((Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json')) -or (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json'))) }
        'Git.Git'                    { return (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.gitconfig')) }
        default                      { return $false }
    }
}

function Edit-AppSelection {
    param([System.Collections.Generic.List[object]]$Apps)
    while ($true) {
        Write-Host ''
        Write-Host 'APP SELECTION - enter item numbers (e.g. 1,5,9) to include or exclude apps.' -ForegroundColor Cyan
        Write-Host '  a = select all   n = select none   i = invert   s = save & continue' -ForegroundColor DarkGray
        $rows = [math]::Ceiling($Apps.Count / 2.0)
        for ($r = 0; $r -lt $rows; $r++) {
            $line = ''
            for ($c = 0; $c -lt 2; $c++) {
                $idx = $r + $c * $rows
                if ($idx -lt $Apps.Count) {
                    $a = $Apps[$idx]
                    $mark = if ($a.Install) { '[x]' } else { '[ ]' }
                    $line += ('{0,3} {1} {2}' -f ($idx + 1), $mark, $a.Id.PadRight(40))
                }
            }
            Write-Host $line
        }
        $sel = (Read-Host 'Choice').Trim()
        if ($sel -eq '') { continue }
        if ($sel -match '^(s|save)$') { return }
        if ($sel -match '^(a|all)$') { foreach ($a in $Apps) { $a.Install = $true }; continue }
        if ($sel -match '^(n|none)$') { foreach ($a in $Apps) { $a.Install = $false }; continue }
        if ($sel -match '^(i|invert)$') { foreach ($a in $Apps) { $a.Install = -not $a.Install }; continue }
        foreach ($token in ($sel -split '[,\s]+' | Where-Object { $_ })) {
            $n = 0
            if ([int]::TryParse($token, [ref]$n) -and $n -ge 1 -and $n -le $Apps.Count) {
                $Apps[$n - 1].Install = -not $Apps[$n - 1].Install
            } else {
                Write-Host "  '$token' is not a valid item number" -ForegroundColor Yellow
            }
        }
    }
}

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host (' laptop-migration-toolkit v' + $ToolkitVersion) -ForegroundColor Cyan
Write-Host ' COLLECT - run this on the OLD laptop                    ' -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan

if (Invoke-SelfElevate -NoElevate:$NoElevate) { exit 0 }
$isAdmin = Test-Admin
if (-not $isAdmin) { Log 'Running without Administrator rights - Wi-Fi passwords will not be exported' 'WARN' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmm'
$collectStarted = Get-Date
if (-not $OutputPath) {
    $desktopBase = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktopBase) -or -not (Test-Path -LiteralPath $desktopBase)) { $desktopBase = $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace($desktopBase)) { $desktopBase = $env:TEMP }
    $OutputPath = Join-Path $desktopBase "MigrationPackage-$stamp"
}
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
if ($ExtraFolders.Count -eq 1 -and $ExtraFolders[0] -like '*,*') { $ExtraFolders = $ExtraFolders[0] -split ',' }
. (Join-Path $PSScriptRoot 'MigrationCommon.ps1')
if (Get-Process -Name 'Code', 'Code - Insiders' -ErrorAction SilentlyContinue) {
    Log 'Close VS Code and VS Code Insiders before collecting. Run from standalone PowerShell so chats and SQLite state are fully saved.' 'ERROR'
    exit 1
}
$script:ZipTarget = $null
if ($Archive) {
    # Build on the local disk; only the single zip (+ checksum) goes to the cloud folder.
    $script:ZipTarget = $OutputPath.TrimEnd('\') + '.zip'
    EnsureDir (Split-Path -Parent $script:ZipTarget) | Out-Null
    $OutputPath = Join-Path $env:LOCALAPPDATA ('laptop-migration-toolkit\staging\' + (Split-Path -Leaf $OutputPath))
    Remove-Item -LiteralPath $OutputPath -Recurse -Force -ErrorAction SilentlyContinue
}
EnsureDir $OutputPath | Out-Null
Log "Package folder: $OutputPath"

Log 'Collecting system information...' 'STEP'
$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem
$themePath = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes' -ErrorAction SilentlyContinue).CurrentTheme
$info = [ordered]@{
    CollectedAt    = (Get-Date).ToString('s')
    ComputerName   = $env:COMPUTERNAME
    UserName       = $env:USERNAME
    UserDomain     = $env:USERDOMAIN
    UserProfile    = $env:USERPROFILE
    OS             = $os.Caption
    OSVersion      = $os.Version
    Manufacturer   = $cs.Manufacturer
    Model          = $cs.Model
    PSVersion      = $PSVersionTable.PSVersion.ToString()
    IsAdmin        = $isAdmin
    ActiveTheme    = $themePath
    ToolkitVersion = $ToolkitVersion
    PackageFormat  = $PackageFormat
}
$info | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputPath 'system-info.json') -Encoding UTF8
Log "System information saved ($($env:COMPUTERNAME), $($os.Caption), build $($os.Version))" 'OK'

$appSelection = New-Object System.Collections.Generic.List[object]
if (-not $SkipApps) {
    Log 'Collecting installed applications...' 'STEP'
    $appsDir = EnsureDir (Join-Path $OutputPath 'apps')
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if ($winget) {
        $exportFile = Join-Path $appsDir 'winget-export.json'
        $null = winget export -o $exportFile --accept-source-agreements 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log 'winget export saved (apps can be reinstalled automatically on the new laptop)' 'OK'
            $exported = $null
            try { $exported = Get-Content -LiteralPath $exportFile -Raw | ConvertFrom-Json } catch { $exported = $null }
            if ($exported) {
                $pkgs = @($exported.Sources | ForEach-Object { $_.Packages } | Where-Object { $_ -and $_.PackageIdentifier })
                foreach ($pkg in $pkgs) {
                    $id = [string]$pkg.PackageIdentifier
                    $dataAvailable = Test-DataAvailable -AppId $id
                    $appSelection.Add([pscustomobject]@{ Id = $id; Install = $true; Data = $dataAvailable })
                }
                Log "Apps found for migration: $($appSelection.Count)" 'OK'
            }
        } else {
            Log 'winget export failed - see winget-list.txt and installed-programs.csv instead' 'WARN'
        }
        Log 'Listing all installed packages (can take a minute)...'
        $null = winget list --accept-source-agreements 2>&1 | Out-File -FilePath (Join-Path $appsDir 'winget-list.txt') -Encoding UTF8
        Log 'winget list saved' 'OK'
    } else {
        Log 'winget is not available on this machine - app auto-install will not be possible' 'WARN'
    }
    $uninstallRoots = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName } |
        Select-Object DisplayName, DisplayVersion, Publisher, InstallDate |
        Sort-Object DisplayName |
        Export-Csv -LiteralPath (Join-Path $appsDir 'installed-programs.csv') -NoTypeInformation
    Get-AppxPackage -ErrorAction SilentlyContinue |
        Where-Object { -not $_.IsFramework } |
        Select-Object Name, Version |
        Sort-Object Name |
        Export-Csv -LiteralPath (Join-Path $appsDir 'store-apps.csv') -NoTypeInformation
    Log 'Installed program inventory saved' 'OK'

    if ($InteractiveApps -and $appSelection.Count -gt 0) {
        if ($script:NotInteractive) {
            Log '-InteractiveApps ignored: script is running non-interactively' 'WARN'
        } else {
            Edit-AppSelection -Apps $appSelection
        }
    }
    if ($appSelection.Count -gt 0) {
        $sel = [ordered]@{
            CreatedAt = (Get-Date).ToString('s')
            Machine   = $env:COMPUTERNAME
            Apps      = @($appSelection | ForEach-Object { [ordered]@{ Id = $_.Id; Install = $_.Install; Data = $_.Data } })
        }
        $sel | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $appsDir 'app-selection.json') -Encoding UTF8
        $selectedCount = @($appSelection | Where-Object { $_.Install }).Count
        Log "App selection saved: $selectedCount of $($appSelection.Count) apps selected for the new laptop" 'OK'
    }
} else {
    Log 'Skipping apps (asked to skip)' 'WARN'
}

Log 'Collecting user environment variables...' 'STEP'
$envDir = EnsureDir (Join-Path $OutputPath 'env')
[Environment]::GetEnvironmentVariables('User') | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $envDir 'user-env.json') -Encoding UTF8
Log 'Environment variables saved' 'OK'

Log 'Collecting personalization / visuals...' 'STEP'
$persoDir = EnsureDir (Join-Path $OutputPath 'personalization')
$regKeys = [ordered]@{
    'themes'            = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes'
    'desktop'           = 'HKCU\Control Panel\Desktop'
    'dwm'               = 'HKCU\Software\Microsoft\Windows\DWM'
    'explorer-advanced' = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    'taskband'          = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
    'taskbar-settings'  = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\StuckRects3'
    'startup-run'       = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
    'mouse'             = 'HKCU\Control Panel\Mouse'
    'keyboard'          = 'HKCU\Control Panel\Keyboard'
    'international'     = 'HKCU\Control Panel\International'
}
foreach ($name in $regKeys.Keys) {
    reg export $regKeys[$name] (Join-Path $persoDir "$name.reg") /y | Out-Null
    if ($LASTEXITCODE -eq 0) { Log "Registry exported: $($regKeys[$name])" 'OK' }
    else { Log "Registry export failed: $($regKeys[$name])" 'WARN' }
}
$wp = (Get-ItemProperty 'HKCU:\Control Panel\Desktop' -ErrorAction SilentlyContinue).WallPaper
if ($wp -and (Test-Path -LiteralPath $wp)) {
    $null = CopyFileSafe $wp (Join-Path $persoDir ('wallpaper' + [IO.Path]::GetExtension($wp)))
    Log 'Wallpaper file collected' 'OK'
}
$null = CopyFileSafe (Join-Path $env:APPDATA 'Microsoft\Windows\Themes\TranscodedWallpaper') (Join-Path $persoDir 'TranscodedWallpaper')
$null = CopyTree (Join-Path $env:APPDATA 'Microsoft\Windows\Themes\CachedFiles') (Join-Path $persoDir 'CachedFiles')

Log 'Collecting terminal settings...' 'STEP'
$terminals = [ordered]@{
    'WindowsTerminal'        = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json')
    'WindowsTerminalPreview' = (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json')
    'WindowsTerminalLegacy'  = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\settings.json')
}
$termRoot = EnsureDir (Join-Path $OutputPath 'terminals')
foreach ($k in $terminals.Keys) {
    if (CopyFileSafe $terminals[$k] (Join-Path (Join-Path $termRoot $k) 'settings.json')) { Log "Terminal settings collected: $k" 'OK' }
}

Log 'Collecting developer, agent and skill configurations...' 'STEP'
$devDir = EnsureDir (Join-Path $OutputPath 'dev')
# workspaceStorage is persistent chat data, not a disposable cache.
$flavors = @(
    @{ Name = 'VS Code'; User = 'Code'; Dir = 'vscode-user'; AgentDir = 'vscode-agentSessionData'; Ext = 'vscode-extensions.txt'; Cli = 'stable' },
    @{ Name = 'VS Code Insiders'; User = 'Code - Insiders'; Dir = 'vscode-insiders-user'; AgentDir = 'vscode-insiders-agentSessionData'; Ext = 'vscode-insiders-extensions.txt'; Cli = 'insiders' }
)
foreach ($fl in $flavors) {
    $codeRoot = Join-Path $env:APPDATA $fl.User
    $codeUser = Join-Path $codeRoot 'User'
    if (Test-Path -LiteralPath $codeUser) {
        $ex = @('CachedData', 'CachedExtensionVSIXs', 'Backups', 'logs') | ForEach-Object { Join-Path $codeUser $_ }
        if (-not $IncludeVscodeHistory) { $ex += (Join-Path $codeUser 'History') }
        if (CopyTree $codeUser (Join-Path $devDir $fl.Dir) $ex @('local-index*.db', 'workspace-chunks.json')) {
            Log "$($fl.Name) settings, prompts and per-folder chats collected" 'OK'
        }
    }
    if (CopyTree (Join-Path $codeRoot 'agentSessionData') (Join-Path $devDir $fl.AgentDir)) {
        Log "$($fl.Name) agent sessions and attachments collected" 'OK'
    }
}
foreach ($fl in $flavors) {
    $cli = Get-VsCodeCli $fl.Cli
    if ($cli) {
        $exts = @(& $cli --list-extensions 2>$null | Where-Object { $_ })
        [IO.File]::WriteAllLines((Join-Path $devDir $fl.Ext), [string[]]$exts)
        Log "$($fl.Name) extension list collected ($($exts.Count) extensions)" 'OK'
    }
}
$agentPaths = @(
    '.config\opencode', 'opencode.json', 'opencode.jsonc', 'AGENTS.md',
    '.claude', '.claude.json', '.opencode',
    '.codex', '.gemini', '.copilot', '.cursor', '.aider.conf.yml'
)
$agentRoot = EnsureDir (Join-Path $devDir 'agent-configs')
foreach ($rel in $agentPaths) {
    $src = Join-Path $env:USERPROFILE $rel
    if (Test-Path -LiteralPath $src) {
        $dst = Join-Path $agentRoot $rel
        if ((Get-Item -LiteralPath $src).PSIsContainer) {
            $ex = @()
            if ($rel -eq '.cursor' -and -not $IncludeCursorExtensions) { $ex += (Join-Path $src 'extensions') }
            $null = CopyTree $src $dst $ex
            if ($ex.Count -gt 0) { Log "Collected $rel (installed extensions skipped - use -IncludeCursorExtensions to keep them)" 'OK' }
            else { Log "Collected $rel" 'OK' }
        } else {
            $null = CopyFileSafe $src $dst
            Log "Collected $rel" 'OK'
        }
    }
}
$dotfiles = @('.gitconfig', '.gitignore_global', '.npmrc', '.yarnrc', '.wslconfig', '.vimrc', '.editorconfig', '.condarc', '.curlrc', '.terraformrc', '.profile', '.bashrc', '.zshrc', '.kube', '.aws', '.azure')
$dotRoot = EnsureDir (Join-Path $devDir 'dotfiles')
foreach ($rel in $dotfiles) {
    $src = Join-Path $env:USERPROFILE $rel
    if (Test-Path -LiteralPath $src) {
        if ((Get-Item -LiteralPath $src).PSIsContainer) { $null = CopyTree $src (Join-Path $dotRoot $rel) } else { $null = CopyFileSafe $src (Join-Path $dotRoot $rel) }
    }
}
Log 'Dotfiles collected' 'OK'
$null = CopyTree (Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell') (Join-Path $devDir 'powershell\WindowsPowerShell')
$null = CopyTree (Join-Path $env:USERPROFILE 'Documents\PowerShell') (Join-Path $devDir 'powershell\PowerShell7')
if (-not $SkipSSH) {
    if (CopyTree (Join-Path $env:USERPROFILE '.ssh') (Join-Path $devDir 'ssh')) {
        Log 'SSH keys collected - NEVER sync or share this package publicly!' 'WARN'
    }
}
$bookmarks = [ordered]@{
    'chrome-default' = (Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Bookmarks')
    'edge-default'   = (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Bookmarks')
}
foreach ($k in $bookmarks.Keys) {
    if (CopyFileSafe $bookmarks[$k] (Join-Path $devDir "browsers\$k-Bookmarks.json")) { Log "Browser bookmarks collected: $k" 'OK' }
}
if (Get-Command npm -ErrorAction SilentlyContinue) {
    $npmlines = @(npm ls -g --depth=0 2>&1 | ForEach-Object { "$_" })
    [IO.File]::WriteAllLines((Join-Path $devDir 'npm-global.txt'), $npmlines)
}
if (Get-Command python -ErrorAction SilentlyContinue) {
    $pylines = @(python -m pip freeze 2>&1 | ForEach-Object { "$_" })
    [IO.File]::WriteAllLines((Join-Path $devDir 'python-packages.txt'), $pylines)
}

Log 'Exporting Wi-Fi profiles...' 'STEP'
$wifiDir = EnsureDir (Join-Path $OutputPath 'wifi')
$null = cmd /c "netsh wlan export profile key=clear folder=""$wifiDir"" 2>&1"
if ($LASTEXITCODE -eq 0) {
    Log 'Wi-Fi profiles exported with passwords (keep the package private)' 'OK'
} else {
    $null = cmd /c "netsh wlan export profile folder=""$wifiDir"" 2>&1"
    if ($LASTEXITCODE -eq 0) { Log 'Wi-Fi profiles exported WITHOUT passwords - re-enter them on the new laptop' 'WARN' }
    else { Log 'Wi-Fi profiles could not be exported (no WLAN adapter, or run as Administrator to include passwords)' 'WARN' }
}

Log 'Exporting power scheme...' 'STEP'
$powerDir = EnsureDir (Join-Path $OutputPath 'power')
$active = (powercfg /getactivescheme | Out-String)
Set-Content -LiteralPath (Join-Path $powerDir 'active-scheme.txt') -Value $active -Encoding UTF8
if ($isAdmin) {
    if ($active -match '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
        $null = cmd /c "powercfg /export ""$(Join-Path $powerDir 'power-scheme.pow')"" $($matches[1]) 2>&1"
        if ($LASTEXITCODE -eq 0) { Log 'Power scheme exported' 'OK' } else { Log 'Power scheme export failed' 'WARN' }
    }
} else {
    Log 'Power scheme export needs Administrator rights - skipped (re-run elevated to include it)' 'WARN'
}

Log 'Collecting fonts...' 'STEP'
$fontsDir = EnsureDir (Join-Path $OutputPath 'fonts')
reg export 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts' (Join-Path $fontsDir 'fonts-hklm.reg') /y | Out-Null
reg export 'HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts' (Join-Path $fontsDir 'fonts-hkcu.reg') /y | Out-Null
$null = CopyTree (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Fonts') (Join-Path $fontsDir 'user-fonts')
Log 'Font inventory saved (user-installed font files copied)' 'OK'

if ($IncludeUserFiles) {
    Log 'Copying your personal folders (this can take a while)...' 'STEP'
    $filesRoot = EnsureDir (Join-Path $OutputPath 'files')
    foreach ($folder in @('Desktop', 'Documents', 'Downloads', 'Pictures', 'Videos', 'Music')) {
        if (CopyTree (Join-Path $env:USERPROFILE $folder) (Join-Path $filesRoot $folder)) { Log "Copied $folder" 'OK' }
    }
    foreach ($extra in $ExtraFolders) {
        if (Test-Path -LiteralPath $extra) {
            $leaf = Split-Path $extra -Leaf
            if (CopyTree $extra (Join-Path $filesRoot "extra\$leaf")) { Log "Copied extra folder: $extra" 'OK' }
        } else {
            Log "Extra folder not found: $extra" 'WARN'
        }
    }
} else {
    Log 'User files were NOT copied (no -IncludeUserFiles switch)' 'WARN'
}

$report = [ordered]@{
    PackageFolder    = $OutputPath
    CreatedAt        = (Get-Date).ToString('s')
    ToolkitVersion   = $ToolkitVersion
    PackageFormat    = $PackageFormat
    IncludeUserFiles = [bool]$IncludeUserFiles
    Findings         = $script:Findings
}
$report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $OutputPath 'collection-report.json') -Encoding UTF8

$collected = @(Get-ChildItem -LiteralPath $OutputPath -Recurse -File -Force -ErrorAction SilentlyContinue)
$sum = ($collected | Measure-Object -Property Length -Sum).Sum
if (-not $sum) { $sum = 0 }
$errors = @($script:Findings | Where-Object { $_ -match '\] ERROR' }).Count
$warns = @($script:Findings | Where-Object { $_ -match '\] WARN' }).Count

if ($Archive) {
    $zipPath = $script:ZipTarget
    $parent = Split-Path -Parent $OutputPath
    $leaf = Split-Path -Leaf $OutputPath
    if (Get-Command tar -ErrorAction SilentlyContinue) {
        Log 'Creating a single-file archive (much faster to move or sync than many small files)...' 'STEP'
        Remove-Item -LiteralPath $zipPath, ($zipPath + '.json') -Force -ErrorAction SilentlyContinue
        & tar -a -cf $zipPath -C $parent $leaf 2>&1 | Out-Null
        if ((Test-Path -LiteralPath $zipPath) -and $LASTEXITCODE -le 1) {
            Write-PackageSidecar -Zip $zipPath
            Log ("Archive created: {0} ({1:N1} MB)" -f $zipPath, ((Get-Item -LiteralPath $zipPath).Length / 1MB)) 'OK'
            Remove-Item -LiteralPath $OutputPath -Recurse -Force -ErrorAction SilentlyContinue
            $OutputPath = $zipPath
        } else {
            Log "Archive creation failed - the package folder is complete and usable at $OutputPath" 'WARN'
        }
    } else {
        Log 'tar.exe not found - cannot create the archive (use 7-Zip, or Explorer: right-click the folder, Compress to ZIP file)' 'WARN'
    }
}

$sensitivePaths = @(
    'dev\agent-configs\.codex\auth.json',
    'dev\dotfiles\.azure\msal_token_cache.bin',
    'dev\dotfiles\.azure\commands'
)

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host (" Collection finished: {0:N1} MB in {1} files, {2} warnings, {3} errors" -f ($sum / 1MB), $collected.Count, $warns, $errors) -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan
if ($collected.Count -gt 15000 -and -not $script:ZipTarget) {
    Write-Host ' Note: this package contains a very large number of small files.' -ForegroundColor Yellow
    Write-Host ' Cloud drives (OneDrive/SharePoint) can take many hours to sync that many' -ForegroundColor Yellow
    Write-Host ' files. Prefer a USB drive, or re-run with -Archive to get a single .zip.' -ForegroundColor Yellow
}
foreach ($rel in $sensitivePaths) {
    if (Test-Path -LiteralPath (Join-Path $OutputPath $rel)) {
        Write-Host " Contains sign-in tokens: $rel" -ForegroundColor Yellow
    }
}
Write-Host ' Next steps:' -ForegroundColor White
if ($errors -eq 0) { Set-LastSyncTime $collectStarted }
Write-Host '   1. Let the folder below finish uploading to your cloud drive (or copy it to a USB drive):' -ForegroundColor Gray
Write-Host "      $OutputPath" -ForegroundColor White
Write-Host '   2. On the NEW laptop, run the verifier first:' -ForegroundColor Gray
Write-Host '      .\Verify-Package.ps1 -PackagePath "<the copied package folder>"' -ForegroundColor White
Write-Host '   3. Then review and run the restore:' -ForegroundColor Gray
Write-Host '      .\Restore-NewLaptop.ps1 -PackagePath "<the copied package folder>"' -ForegroundColor White
Write-Host '   Keep this package private and delete it once the migration is done.' -ForegroundColor Gray
Write-Host ''
