[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackagePath
)

$ToolkitVersion = '1.0.0'
$ErrorActionPreference = 'Continue'
$script:Findings = New-Object System.Collections.Generic.List[string]
$script:ProblemCount = 0
$script:WarnCount = 0

function Log {
    param([string]$Message, [string]$Level = 'INFO')
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'STEP'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host ("[{0,-5}] {1}" -f $Level, $Message) -ForegroundColor $color
    $script:Findings.Add("[$Level] $Message")
    if ($Level -eq 'ERROR') { $script:ProblemCount++ }
    if ($Level -eq 'WARN') { $script:WarnCount++ }
}

function Get-FolderStats {
    param([string]$Path)
    $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)
    $size = ($files | Measure-Object -Property Length -Sum).Sum
    if (-not $size) { $size = 0 }
    return [pscustomobject]@{ Count = $files.Count; MB = [math]::Round($size / 1MB, 1) }
}

function Test-BundlePresent {
    param([string]$Bundle, [string]$Pkg)
    switch ($Bundle) {
        'vs-code'          { return ((Test-Path -LiteralPath (Join-Path $Pkg 'dev\vscode-user')) -or (Test-Path -LiteralPath (Join-Path $Pkg 'dev\vscode-extensions.txt'))) }
        'windows-terminal' { return (@(Get-ChildItem -LiteralPath (Join-Path $Pkg 'terminals') -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer }).Count -gt 0) }
        'powershell'       { return ((Test-Path -LiteralPath (Join-Path $Pkg 'dev\powershell\WindowsPowerShell')) -or (Test-Path -LiteralPath (Join-Path $Pkg 'dev\powershell\PowerShell7'))) }
        'agent-configs'    { return (@(Get-ChildItem -LiteralPath (Join-Path $Pkg 'dev\agent-configs') -Force -ErrorAction SilentlyContinue).Count -gt 0) }
        'dotfiles'         { return (@(Get-ChildItem -LiteralPath (Join-Path $Pkg 'dev\dotfiles') -Force -ErrorAction SilentlyContinue).Count -gt 0) }
        'git-config'       { return (Test-Path -LiteralPath (Join-Path $Pkg 'dev\dotfiles\.gitconfig')) }
        'browser-chrome'   { return (Test-Path -LiteralPath (Join-Path $Pkg 'dev\browsers\chrome-default-Bookmarks.json')) }
        'browser-edge'     { return (Test-Path -LiteralPath (Join-Path $Pkg 'dev\browsers\edge-default-Bookmarks.json')) }
        'ssh'              { return (@(Get-ChildItem -LiteralPath (Join-Path $Pkg 'dev\ssh') -Force -ErrorAction SilentlyContinue).Count -gt 0) }
        'wifi'             { return (@(Get-ChildItem -LiteralPath (Join-Path $Pkg 'wifi') -Filter '*.xml' -ErrorAction SilentlyContinue).Count -gt 0) }
        'power'            { return (Test-Path -LiteralPath (Join-Path $Pkg 'power\power-scheme.pow')) }
        'fonts'            { return (@(Get-ChildItem -LiteralPath (Join-Path $Pkg 'fonts\user-fonts') -File -ErrorAction SilentlyContinue).Count -gt 0) }
        'env'              { return (Test-Path -LiteralPath (Join-Path $Pkg 'env\user-env.json')) }
        default            { return $false }
    }
}

Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host (' laptop-migration-toolkit v' + $ToolkitVersion) -ForegroundColor Cyan
Write-Host ' VERIFY PACKAGE - read-only review of the collected data ' -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan

$Pkg = [IO.Path]::GetFullPath($PackagePath)
if (-not (Test-Path -LiteralPath $Pkg)) {
    Log "Package folder not found: $Pkg" 'ERROR'
    exit 1
}

$infoFile = Join-Path $Pkg 'system-info.json'
$oldInfo = $null
if (Test-Path -LiteralPath $infoFile) {
    try {
        $oldInfo = Get-Content -LiteralPath $infoFile -Raw | ConvertFrom-Json
        Log "System info OK: machine $($oldInfo.ComputerName), user $($oldInfo.UserName)$(if ($oldInfo.UserDomain) { '@' + $oldInfo.UserDomain }), $($oldInfo.OS) build $($oldInfo.OSVersion)" 'OK'
        Log "Collected: $($oldInfo.CollectedAt); profile path: $($oldInfo.UserProfile)"
        if ($oldInfo.ToolkitVersion) { Log "Toolkit version used for collect: $($oldInfo.ToolkitVersion)" }
        else { Log 'Collected with an older toolkit version - the restore tool still supports it' 'WARN' }
    } catch {
        Log "system-info.json cannot be parsed: $($_.Exception.Message)" 'ERROR'
    }
} else {
    Log 'system-info.json is missing - this is not a valid migration package' 'ERROR'
}

$osNow = Get-CimInstance Win32_OperatingSystem
Log "This laptop: $env:COMPUTERNAME, user $env:USERNAME, $($osNow.Caption) build $($osNow.Version)"
if ($oldInfo) {
    $oldIs11 = ([string]$oldInfo.OS) -match 'Windows 11'
    $newIs11 = $osNow.Caption -match 'Windows 11'
    if ($oldIs11 -ne $newIs11) {
        Log 'OS GENERATION MISMATCH: old and new laptops run different Windows generations - the restore tool will pre-set the taskbar/theme items to SKIP (you can override)' 'WARN'
    } else {
        Log 'Windows generations match - low conflict risk' 'OK'
    }
    if ($oldInfo.UserProfile -and ($oldInfo.UserProfile -ine $env:USERPROFILE)) {
        Log "User profile path differs: $($oldInfo.UserProfile) -> $env:USERPROFILE (paths will be translated during restore)" 'WARN'
    }
    if ($oldInfo.UserDomain -and ($env:USERDOMAIN -ine [string]$oldInfo.UserDomain)) {
        Log "Domain/account differs: $($oldInfo.UserDomain) -> $env:USERDOMAIN - sign-in related items (SSH, Git credentials) may need re-authentication" 'WARN'
    }
}

Log '---- Package contents ----' 'STEP'

$bundleInfo = [ordered]@{}

if (Test-Path -LiteralPath (Join-Path $Pkg 'apps')) {
    $stats = Get-FolderStats (Join-Path $Pkg 'apps')
    Log "Apps inventory: $($stats.Count) files, $($stats.MB) MB" 'OK'
    $exportFile = Join-Path $Pkg 'apps\winget-export.json'
    if (Test-Path -LiteralPath $exportFile) {
        try {
            $w = Get-Content -LiteralPath $exportFile -Raw | ConvertFrom-Json
            $count = @($w.Sources | ForEach-Object { $_.Packages }).Count
            Log "winget export parses correctly: $count apps can be auto-installed" 'OK'
        } catch {
            Log "winget-export.json does not parse - app auto-install will not work: $($_.Exception.Message)" 'ERROR'
        }
    }
    $selFile = Join-Path $Pkg 'apps\app-selection.json'
    if (Test-Path -LiteralPath $selFile) {
        try {
            $sel = Get-Content -LiteralPath $selFile -Raw | ConvertFrom-Json
            $total = @($sel.Apps).Count
            $chosen = @($sel.Apps | Where-Object { $_.Install }).Count
            Log "App selection saved on the old laptop: $chosen of $total apps chosen (editable during restore)" 'OK'
        } catch { Log 'app-selection.json exists but cannot be parsed - defaults will be used' 'WARN' }
    } else {
        Log 'No app-selection.json - restore will default to ALL apps (editable during restore)'
    }
} else {
    Log 'apps\ folder missing - no application inventory in this package' 'WARN'
}

$bundlesToCheck = @('vs-code', 'windows-terminal', 'powershell', 'agent-configs', 'dotfiles', 'git-config', 'browser-chrome', 'browser-edge', 'ssh', 'wifi', 'power', 'fonts', 'env')
foreach ($b in $bundlesToCheck) { $bundleInfo[$b] = (Test-BundlePresent -Bundle $b -Pkg $Pkg) }

$names = [ordered]@{
    'vs-code'          = 'VS Code settings & extensions'
    'windows-terminal' = 'Windows Terminal settings'
    'powershell'       = 'PowerShell profiles'
    'agent-configs'    = 'Agent/skill configs'
    'dotfiles'         = 'Dotfiles'
    'git-config'       = 'Git config'
    'browser-chrome'   = 'Chrome bookmarks'
    'browser-edge'     = 'Edge bookmarks'
    'ssh'              = 'SSH keys'
    'wifi'             = 'Wi-Fi profiles'
    'power'            = 'Power scheme'
    'fonts'            = 'User fonts'
    'env'              = 'Environment variables'
}
foreach ($b in $names.Keys) {
    if ($bundleInfo[$b]) { Log "Present: $($names[$b])" 'OK' }
}

$persoDir = Join-Path $Pkg 'personalization'
if (Test-Path -LiteralPath $persoDir) {
    $regs = @(Get-ChildItem -LiteralPath $persoDir -Filter '*.reg' -ErrorAction SilentlyContinue)
    $badRegs = 0
    foreach ($r in $regs) {
        $head = Get-Content -LiteralPath $r.FullName -TotalCount 1 -ErrorAction SilentlyContinue
        if ($head -notmatch 'Windows Registry Editor') { $badRegs++ }
    }
    Log "Personalization: $($regs.Count) registry files, wallpaper $(if (Get-ChildItem -LiteralPath $persoDir -Filter 'wallpaper.*' -ErrorAction SilentlyContinue) { 'present' } else { 'not found' })" 'OK'
    if ($badRegs -gt 0) { Log "$badRegs registry file(s) look malformed" 'WARN' }
} else {
    Log 'personalization\ folder missing - visuals will not transfer' 'WARN'
}

$envFile = Join-Path $Pkg 'env\user-env.json'
if (Test-Path -LiteralPath $envFile) {
    try {
        $envObj = Get-Content -LiteralPath $envFile -Raw | ConvertFrom-Json
        $varCount = @($envObj.PSObject.Properties).Count
        Log "Environment variables: $varCount user variables" 'OK'
    } catch { Log 'env\user-env.json cannot be parsed' 'WARN' }
}

$wifiDir = Join-Path $Pkg 'wifi'
if (Test-Path -LiteralPath $wifiDir) {
    $xmls = @(Get-ChildItem -LiteralPath $wifiDir -Filter '*.xml' -ErrorAction SilentlyContinue)
    $withPass = 0
    foreach ($x in $xmls) {
        if (Select-String -LiteralPath $x.FullName -Pattern 'keyMaterial' -Quiet -ErrorAction SilentlyContinue) { $withPass++ }
    }
    Log "Wi-Fi profiles: $($xmls.Count) (with stored passwords: $withPass) - treat the package as sensitive" 'OK'
}

$fontsDir = Join-Path $Pkg 'fonts\user-fonts'
if (Test-Path -LiteralPath $fontsDir) {
    $fontFiles = @(Get-ChildItem -LiteralPath $fontsDir -File -ErrorAction SilentlyContinue)
    Log "User-installed fonts: $($fontFiles.Count) files" 'OK'
}

$agentDir = Join-Path $Pkg 'dev\agent-configs'
if (Test-Path -LiteralPath $agentDir) {
    $agents = @(Get-ChildItem -LiteralPath $agentDir -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($agents.Count -gt 0) { Log "Agent/skill configs: $($agents -join ', ')" 'OK' }
}
$extFile = Join-Path $Pkg 'dev\vscode-extensions.txt'
if (Test-Path -LiteralPath $extFile) {
    $extCount = @(Get-Content -LiteralPath $extFile | Where-Object { $_.Trim() }).Count
    Log "VS Code extensions listed: $extCount" 'OK'
}

$filesRoot = Join-Path $Pkg 'files'
if (Test-Path -LiteralPath $filesRoot) {
    $stats = Get-FolderStats $filesRoot
    Log "Personal folders: $($stats.Count) files, $($stats.MB) MB" 'OK'
    foreach ($d in Get-ChildItem -LiteralPath $filesRoot -Directory -ErrorAction SilentlyContinue) {
        $ds = Get-FolderStats $d.FullName
        Log "  - $($d.Name): $($ds.Count) files, $($ds.MB) MB"
    }
    if ($stats.Count -eq 0) { Log 'files\ folder exists but is empty' 'WARN' }
} else {
    Log 'No files\ folder - personal folders were not collected (collect without -IncludeUserFiles?)'
}

Log '---- Security scan ----' 'STEP'
$secretPatterns = 'id_rsa|id_ed25519|id_ecdsa|\.pem$|\.key$|\.pfx$|\.p12$|\.kdbx$|unattend\.xml|credential|token|secret'
$suspects = @(Get-ChildItem -LiteralPath $Pkg -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $secretPatterns })
if ($suspects.Count -gt 0) {
    foreach ($s in $suspects) { Log "Sensitive file in package: $($s.FullName.Replace($Pkg, '.'))" 'WARN' }
    Log 'Package contains potentially sensitive files - keep it private, never share or commit it' 'WARN'
} else {
    Log 'No obvious secrets found by filename scan (Wi-Fi XMLs may still contain passwords - check the wifi section above)' 'OK'
}
if ($bundleInfo['ssh']) {
    Log 'SSH private keys ARE in this package - make sure it never lands in a shared/public location' 'WARN'
} else {
    Log 'SSH keys are not in this package' 'OK'
}

$sum = (Get-ChildItem -LiteralPath $Pkg -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
if (-not $sum) { $sum = 0 }
Write-Host ''
Write-Host '=========================================================' -ForegroundColor Cyan
Write-Host (" VERIFY RESULT: {0:N1} MB | {1} warnings | {2} problems" -f ($sum / 1MB), $script:WarnCount, $script:ProblemCount) -ForegroundColor Cyan
Write-Host '=========================================================' -ForegroundColor Cyan
if ($script:ProblemCount -gt 0) {
    Write-Host ' Fix the problems above before restoring (or ignore if they are not important to you).' -ForegroundColor Yellow
}
Write-Host ' Next step:' -ForegroundColor White
Write-Host "   .\Restore-NewLaptop.ps1 -PackagePath `"$Pkg`"" -ForegroundColor White
Write-Host '   (add -VerifyOnly first to preview the plan without changing anything)' -ForegroundColor Gray

$script:Findings | Set-Content -LiteralPath (Join-Path $Pkg 'verify-report.txt') -Encoding UTF8
Write-Host " Report saved: $(Join-Path $Pkg 'verify-report.txt')" -ForegroundColor Gray

if ($script:ProblemCount -gt 0) { exit 1 }
exit 0
