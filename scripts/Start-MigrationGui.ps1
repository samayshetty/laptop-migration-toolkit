[CmdletBinding()]
param()

$GuiVersion = '1.2.1'
$ErrorActionPreference = 'Stop'

if (-not [Environment]::UserInteractive) { exit 0 }

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
} catch {
    Write-Host 'Windows Forms is not available on this system.'
    exit 1
}

if ([Threading.Thread]::CurrentThread.ApartmentState -ne [Threading.ApartmentState]::STA) {
    $relaunch = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $PSCommandPath + '"'
    Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunch | Out-Null
    exit 0
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ScriptRoot = Split-Path -Parent $PSCommandPath
$script:Running = $false
$script:Proc = $null
$script:LogFile = $null
$script:ArgsFile = $null
$script:RunnerFile = $null
$script:LogLength = 0
$script:Interactive = $false
$script:Started = $null
$script:OptChecks = @{}

$colBg = [System.Drawing.ColorTranslator]::FromHtml('#0b1120')
$colPanel = [System.Drawing.ColorTranslator]::FromHtml('#152238')
$colPanel2 = [System.Drawing.ColorTranslator]::FromHtml('#1e293b')
$colText = [System.Drawing.ColorTranslator]::FromHtml('#e2e8f0')
$colMuted = [System.Drawing.ColorTranslator]::FromHtml('#94a3b8')
$colAccent = [System.Drawing.ColorTranslator]::FromHtml('#38bdf8')
$colOk = [System.Drawing.ColorTranslator]::FromHtml('#34d399')
$colWarn = [System.Drawing.ColorTranslator]::FromHtml('#fbbf24')
$colErr = [System.Drawing.ColorTranslator]::FromHtml('#f87171')
$colPink = [System.Drawing.ColorTranslator]::FromHtml('#f472b6')
$colDarkText = [System.Drawing.ColorTranslator]::FromHtml('#04121f')
$colFaint = [System.Drawing.ColorTranslator]::FromHtml('#475569')
$colGrid = [System.Drawing.ColorTranslator]::FromHtml('#334155')
$colLogBg = [System.Drawing.ColorTranslator]::FromHtml('#020617')

function Test-IsAdmin {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DefaultPackagePath {
    if ($env:OneDriveCommercial) { return (Join-Path $env:OneDriveCommercial 'MigrationPackage') }
    if ($env:OneDrive) { return (Join-Path $env:OneDrive 'MigrationPackage') }
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop) { return (Join-Path $desktop 'MigrationPackage') }
    return (Join-Path $env:USERPROFILE 'MigrationPackage')
}

function Get-DefaultDeltaPath {
    $base = if ($env:OneDriveCommercial) { $env:OneDriveCommercial } elseif ($env:OneDrive) { $env:OneDrive } else { [Environment]::GetFolderPath('Desktop') }
    return (Join-Path $base 'MigrationDelta')
}

$script:ModeDefs = [ordered]@{
    'deltacollect' = @{
        Script    = 'Sync-Delta.ps1'
        PathLabel = 'Where to write the delta zip (one file):'
        PathArg   = '-Path'
        Browse    = 'Choose where to write the delta zip'
        Note      = 'Close BOTH VS Code editions first. Packs changed files plus complete chat bundles, attachments and checkpoints.'
        Fixed     = @('-Mode', 'Collect')
        Since     = $true
        Options   = @(
            @{ Id = 'IncludeUserFiles'; Text = 'Also include changed Desktop / Documents / Pictures' }
        )
    }
    'deltaapply' = @{
        Script    = 'Sync-Delta.ps1'
        PathLabel = 'Folder holding delta-*.zip (all unapplied, oldest first):'
        PathArg   = '-Path'
        Browse    = 'Choose the folder with the delta zip'
        Note      = 'Close both VS Code editions first. Files are backed up; chat relinking compares conversation contents.'
        Fixed     = @('-Mode', 'Apply')
        Options   = @(
            @{ Id = 'CloseApps';      Text = 'Close VS Code, Notepad++, OneNote and browsers first'; Default = $true }
            @{ Id = 'SkipExtensions'; Text = 'Do not install missing VS Code extensions' }
        )
    }
    'repairchats' = @{
        Script    = 'Repair-WorkspaceChats.ps1'
        PathLabel = 'No folder needed for this step.'
        NoPath    = $true
        Browse    = ''
        Note      = 'Open project folders once, close BOTH VS Code editions, then run. Repairs stale messages and editing state; divergent chats are retained and reported.'
        Options   = @(
            @{ Id = 'Apply'; Text = 'Apply (untick for a read-only preview)'; Default = $true }
        )
    }
    'collect' = @{
        Script            = 'Collect-OldLaptop.ps1'
        PathLabel         = 'Where to create the migration package:'
        PathArg           = '-OutputPath'
        Browse            = 'Choose where to create the migration package'
        Note              = 'Close BOTH VS Code editions first. Start as Administrator if you want Wi-Fi passwords included.'
        Options           = @(
            @{ Id = 'InteractiveApps';        Text = 'Choose which apps to carry over (opens a console window)' }
            @{ Id = 'IncludeUserFiles';       Text = 'Also copy Desktop, Documents, Downloads, Pictures...' }
            @{ Id = 'Archive';                Text = 'Pack into a single .zip (recommended for OneDrive)'; Default = $true }
            @{ Id = 'SkipSSH';                Text = 'Do not collect SSH keys' }
            @{ Id = 'IncludeVscodeHistory';   Text = 'Keep the VS Code edit history (larger package)' }
            @{ Id = 'IncludeCursorExtensions'; Text = 'Keep installed Cursor extensions (larger package)' }
            @{ Id = 'SkipApps';               Text = 'Skip the application inventory' }
        )
    }
    'verify' = @{
        Script    = 'Verify-Package.ps1'
        PathLabel = 'Migration package folder:'
        PathArg   = '-PackagePath'
        Browse    = 'Choose the migration package folder'
        Note      = 'Read-only: nothing on this laptop is changed.'
        Options   = @()
    }
    'restore' = @{
        Script    = 'Restore-NewLaptop.ps1'
        PathLabel = 'Migration package folder:'
        PathArg   = '-PackagePath'
        Browse    = 'Choose the migration package folder'
        Note      = 'The GUI applies the recommended plan. Use the console editor to toggle individual items.'
        Options   = @(
            @{ Id = 'VerifyOnly';            Text = 'Dry run only - show the plan, change nothing' }
            @{ Id = 'ConsoleEditor';         Text = 'Open the interactive plan editor in a console window'; Interactive = $true }
            @{ Id = 'SkipApps';              Text = 'Do not install applications' }
            @{ Id = 'SkipRegistry';          Text = 'Skip visuals, theme, taskbar and wallpaper' }
            @{ Id = 'SkipWifi';              Text = 'Skip Wi-Fi profiles' }
            @{ Id = 'SkipFonts';             Text = 'Skip user fonts' }
            @{ Id = 'SkipEnvVars';           Text = 'Skip environment variables' }
            @{ Id = 'SkipSSH';               Text = 'Skip SSH keys' }
            @{ Id = 'SkipUserFiles';         Text = 'Skip personal folders' }
            @{ Id = 'SkipExplorerRestart';   Text = 'Do not restart Explorer at the end' }
        )
    }
}

$script:RunnerTemplate = @'
param([string]$Target, [string]$Log, [string]$ArgsFile)
$utf8 = New-Object System.Text.UTF8Encoding($false)
# The GUI polls this log, so open it shared and retry briefly instead of failing on a transient lock.
function Write-LogLine([string]$Text) {
    $bytes = $utf8.GetBytes($Text + "`r`n")
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $fs = [System.IO.File]::Open($Log, 'Append', 'Write', 'ReadWrite, Delete')
            try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
            return
        } catch [System.IO.IOException] { Start-Sleep -Milliseconds 50 }
    }
}
trap {
    Write-LogLine ('RUNNER ERROR: ' + $_.Exception.Message)
    exit 1
}
$tokens = @(Get-Content -LiteralPath $ArgsFile -Encoding UTF8)
$params = @{}
$index = 0
while ($index -lt $tokens.Count) {
    $token = $tokens[$index]
    if ($token -like '-*') {
        $name = $token.Substring(1)
        $value = $true
        if (($index + 1) -lt $tokens.Count -and $tokens[$index + 1] -notlike '-*') {
            $value = $tokens[$index + 1]
            $index++
        }
        $params[$name] = $value
    }
    $index++
}
& $Target @params *>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.InformationRecord]) { $line = [string]$_.MessageData }
    elseif ($_ -is [System.Management.Automation.ErrorRecord]) { $line = 'ERROR: ' + $_.ToString() }
    else { $line = [string]$_ }
    Write-LogLine $line
}
'@

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [System.Drawing.Color]$Color, [int]$Size = 9, [bool]$Bold = $false)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, [int]($Size * 2 + 6))
    $label.ForeColor = $Color
    $style = [System.Drawing.FontStyle]::Regular
    if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
    $label.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $style)
    return $label
}

function New-Button {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [System.Drawing.Color]$Back, [System.Drawing.Color]$Fore)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($W, $H)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $Back
    $button.ForeColor = $Fore
    $button.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    return $button
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'laptop-migration-toolkit'
$form.ClientSize = New-Object System.Drawing.Size(1040, 740)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.BackColor = $colBg
$form.ForeColor = $colText
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
$form.MaximizeBox = $false

$header = New-Object System.Windows.Forms.Panel
$header.Dock = [System.Windows.Forms.DockStyle]::Top
$header.Height = 78
$header.BackColor = $colPanel
$form.Controls.Add($header)

$titleLabel = New-Label -Text 'laptop-migration-toolkit' -X 20 -Y 6 -W 500 -Color $colAccent -Size 17 -Bold $true
$header.Controls.Add($titleLabel)
$subLabel = New-Label -Text 'Collect, verify and restore a Windows setup - apps, settings, visuals, dev configs, Wi-Fi, fonts' -X 22 -Y 50 -W 670 -Color $colMuted
$header.Controls.Add($subLabel)

$adminText = 'Standard user (no admin rights needed)'
$adminColor = $colWarn
if (Test-IsAdmin) { $adminText = 'Administrator'; $adminColor = $colOk }
$adminLabel = New-Label -Text $adminText -X 700 -Y 50 -W 320 -Color $adminColor -Bold $true
$adminLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$header.Controls.Add($adminLabel)
$versionLabel = New-Label -Text ('v' + $GuiVersion) -X 700 -Y 14 -W 320 -Color $colMuted
$versionLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$header.Controls.Add($versionLabel)

$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Dock = [System.Windows.Forms.DockStyle]::Left
$leftPanel.Width = 400
$leftPanel.BackColor = $colBg
$leftPanel.Padding = New-Object System.Windows.Forms.Padding(16, 12, 8, 8)
$form.Controls.Add($leftPanel)

$modeGroup = New-Object System.Windows.Forms.GroupBox
$modeGroup.Text = ' 1. What do you want to do? '
$modeGroup.Location = New-Object System.Drawing.Point(12, 8)
$modeGroup.Size = New-Object System.Drawing.Size(372, 190)
$modeGroup.ForeColor = $colAccent
$leftPanel.Controls.Add($modeGroup)

$radioCollect = New-Object System.Windows.Forms.RadioButton
$radioCollect.Text = 'Collect on this (old) laptop'
$radioCollect.Location = New-Object System.Drawing.Point(14, 26)
$radioCollect.Size = New-Object System.Drawing.Size(340, 22)
$radioCollect.ForeColor = $colText
$radioCollect.Checked = $true
$modeGroup.Controls.Add($radioCollect)

$radioVerify = New-Object System.Windows.Forms.RadioButton
$radioVerify.Text = 'Verify the package (read-only)'
$radioVerify.Location = New-Object System.Drawing.Point(14, 52)
$radioVerify.Size = New-Object System.Drawing.Size(340, 22)
$radioVerify.ForeColor = $colText
$modeGroup.Controls.Add($radioVerify)

$radioRestore = New-Object System.Windows.Forms.RadioButton
$radioRestore.Text = 'Restore on this (new) laptop'
$radioRestore.Location = New-Object System.Drawing.Point(14, 78)
$radioRestore.Size = New-Object System.Drawing.Size(340, 22)
$radioRestore.ForeColor = $colText
$modeGroup.Controls.Add($radioRestore)

$radioDeltaCollect = New-Object System.Windows.Forms.RadioButton
$radioDeltaCollect.Text = 'Delta: collect changes since last sync (old)'
$radioDeltaCollect.Location = New-Object System.Drawing.Point(14, 104)
$radioDeltaCollect.Size = New-Object System.Drawing.Size(340, 22)
$radioDeltaCollect.ForeColor = $colText
$modeGroup.Controls.Add($radioDeltaCollect)

$radioDeltaApply = New-Object System.Windows.Forms.RadioButton
$radioDeltaApply.Text = 'Delta: apply changes (new laptop)'
$radioDeltaApply.Location = New-Object System.Drawing.Point(14, 130)
$radioDeltaApply.Size = New-Object System.Drawing.Size(340, 22)
$radioDeltaApply.ForeColor = $colText
$modeGroup.Controls.Add($radioDeltaApply)

$radioRepairChats = New-Object System.Windows.Forms.RadioButton
$radioRepairChats.Text = 'Fix missing per-folder VS Code chats (new)'
$radioRepairChats.Location = New-Object System.Drawing.Point(14, 156)
$radioRepairChats.Size = New-Object System.Drawing.Size(340, 22)
$radioRepairChats.ForeColor = $colText
$modeGroup.Controls.Add($radioRepairChats)

$pathGroup = New-Object System.Windows.Forms.GroupBox
$pathGroup.Text = ' 2. Folder '
$pathGroup.Location = New-Object System.Drawing.Point(12, 206)
$pathGroup.Size = New-Object System.Drawing.Size(372, 112)
$pathGroup.ForeColor = $colPink
$leftPanel.Controls.Add($pathGroup)

$pathLabel = New-Label -Text 'Where to create the migration package:' -X 14 -Y 24 -W 344 -Color $colMuted -Size 8
$pathGroup.Controls.Add($pathLabel)

$pathBox = New-Object System.Windows.Forms.TextBox
$pathBox.Location = New-Object System.Drawing.Point(14, 44)
$pathBox.Size = New-Object System.Drawing.Size(344, 24)
$pathBox.BackColor = $colPanel2
$pathBox.ForeColor = $colText
$pathBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$pathGroup.Controls.Add($pathBox)

$browseButton = New-Button -Text 'Browse...' -X 14 -Y 74 -W 110 -H 28 -Back $colPanel2 -Fore $colAccent
$pathGroup.Controls.Add($browseButton)

$openScriptsButton = New-Button -Text 'Open scripts folder' -X 134 -Y 74 -W 130 -H 28 -Back $colPanel2 -Fore $colMuted
$pathGroup.Controls.Add($openScriptsButton)

$autoButton = New-Button -Text 'Use default' -X 274 -Y 74 -W 84 -H 28 -Back $colPanel2 -Fore $colMuted
$pathGroup.Controls.Add($autoButton)

$optGroup = New-Object System.Windows.Forms.GroupBox
$optGroup.Text = ' 3. Options '
$optGroup.Location = New-Object System.Drawing.Point(12, 326)
$optGroup.Size = New-Object System.Drawing.Size(372, 250)
$optGroup.ForeColor = $colOk
$leftPanel.Controls.Add($optGroup)

$optPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$optPanel.Location = New-Object System.Drawing.Point(10, 22)
$optPanel.Size = New-Object System.Drawing.Size(352, 216)
$optPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
$optPanel.WrapContents = $false
$optPanel.AutoScroll = $true
$optPanel.BackColor = $colBg
$optGroup.Controls.Add($optPanel)

$noteLabel = New-Label -Text '' -X 12 -Y 584 -W 372 -Color $colMuted -Size 8
$leftPanel.Controls.Add($noteLabel)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Location = New-Object System.Drawing.Point(428, 94)
$logBox.Size = New-Object System.Drawing.Size(596, 470)
$logBox.BackColor = $colLogBg
$logBox.ForeColor = $colText
$logBox.Font = New-Object System.Drawing.Font('Consolas', 9)
$logBox.ReadOnly = $true
$logBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$logBox.WordWrap = $false
$logBox.HideSelection = $false
$logBox.ScrollBars = [System.Windows.Forms.RichTextBoxScrollBars]::Both
$form.Controls.Add($logBox)

$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(428, 572)
$progress.Size = New-Object System.Drawing.Size(596, 8)
$progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
$progress.MarqueeAnimationSpeed = 0
$form.Controls.Add($progress)

$statusLabel = New-Label -Text 'Ready.' -X 428 -Y 588 -W 596 -Color $colMuted
$form.Controls.Add($statusLabel)

$runButton = New-Button -Text 'Run' -X 428 -Y 618 -W 130 -H 40 -Back $colAccent -Fore $colDarkText
$form.Controls.Add($runButton)

$stopButton = New-Button -Text 'Stop' -X 566 -Y 618 -W 110 -H 40 -Back $colPanel2 -Fore $colErr
$stopButton.Enabled = $false
$form.Controls.Add($stopButton)

$openPackageButton = New-Button -Text 'Package folder' -X 684 -Y 618 -W 160 -H 40 -Back $colPanel2 -Fore $colText
$openPackageButton.Enabled = $false
$form.Controls.Add($openPackageButton)

$openBackupButton = New-Button -Text 'Backups' -X 852 -Y 618 -W 172 -H 40 -Back $colPanel2 -Fore $colText
$openBackupButton.Enabled = $false
$form.Controls.Add($openBackupButton)

$saveLogButton = New-Button -Text 'Save log' -X 428 -Y 666 -W 200 -H 34 -Back $colPanel2 -Fore $colMuted
$saveLogButton.Enabled = $false
$form.Controls.Add($saveLogButton)

$copyLogButton = New-Button -Text 'Copy log' -X 636 -Y 666 -W 180 -H 34 -Back $colPanel2 -Fore $colMuted
$form.Controls.Add($copyLogButton)

$clearButton = New-Button -Text 'Clear' -X 824 -Y 666 -W 200 -H 34 -Back $colPanel2 -Fore $colMuted
$form.Controls.Add($clearButton)

$footerLabel = New-Label -Text ('Scripts folder: ' + $script:ScriptRoot) -X 20 -Y 712 -W 960 -Color $colFaint -Size 8
$form.Controls.Add($footerLabel)

function Add-LogLine {
    param([string]$Text, [System.Drawing.Color]$Color, [bool]$Scroll = $true)
    if ($logBox.TextLength -gt 400000) { $logBox.Clear() }
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.SelectionLength = 0
    $logBox.SelectionColor = $Color
    $logBox.AppendText($Text + "`r`n")
    $logBox.SelectionColor = $logBox.ForeColor
    if ($Scroll) { $logBox.SelectionStart = $logBox.TextLength; $logBox.ScrollToCaret() }
}

function Get-LineColor {
    param([string]$Line)
    if ($Line -match '\] ERROR|\bERROR:') { return $colErr }
    if ($Line -match '\] WARN') { return $colWarn }
    if ($Line -match '\] OK') { return $colOk }
    if ($Line -match '\] STEP') { return $colAccent }
    if ($Line -match '^\s*=+\s*$') { return $colGrid }
    if ($Line -match 'Collection finished|Restore finished|VERIFY ONLY|PASSED|PROBLEM') { return $colPink }
    return $colText
}

function Get-ScriptPath {
    param([string]$Name)
    return (Join-Path $script:ScriptRoot $Name)
}

function Show-ModeOptions {
    $optPanel.Controls.Clear()
    $script:OptChecks = @{}
    $mode = Get-CurrentMode
    $def = $script:ModeDefs[$mode]
    $pathLabel.Text = $def.PathLabel
    $noteLabel.Text = $def.Note
    foreach ($opt in $def.Options) {
        $check = New-Object System.Windows.Forms.CheckBox
        $check.Text = $opt.Text
        $check.Tag = $opt.Id
        $check.AutoSize = $false
        $check.Size = New-Object System.Drawing.Size(330, 30)
        $check.ForeColor = $colText
        $check.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $check.Checked = [bool]$opt.Default
        $optPanel.Controls.Add($check)
        $script:OptChecks[$opt.Id] = $check
    }
    $script:SinceBox = $null
    if ($def.Since) {
        $sinceLabel = New-Label -Text 'Changed since (blank = auto from last sync):' -X 4 -Y 4 -W 330 -Color $colMuted -Size 8
        $optPanel.Controls.Add($sinceLabel)
        $script:SinceBox = New-Object System.Windows.Forms.TextBox
        $script:SinceBox.Size = New-Object System.Drawing.Size(330, 24)
        $script:SinceBox.BackColor = $colPanel2
        $script:SinceBox.ForeColor = $colText
        $optPanel.Controls.Add($script:SinceBox)
    }
    if ($def.Options.Count -eq 0) {
        $none = New-Label -Text 'No options - this step is read-only.' -X 4 -Y 4 -W 300 -Color $colMuted
        $optPanel.Controls.Add($none)
    }
    if ($script:OptChecks.ContainsKey('VerifyOnly')) { $script:OptChecks['VerifyOnly'].Checked = $false }
    $openPackageButton.Enabled = (Test-Path -LiteralPath $pathBox.Text)
}

function Get-CurrentMode {
    if ($radioRepairChats.Checked) { return 'repairchats' }
    if ($radioDeltaCollect.Checked) { return 'deltacollect' }
    if ($radioDeltaApply.Checked) { return 'deltaapply' }
    if ($radioVerify.Checked) { return 'verify' }
    if ($radioRestore.Checked) { return 'restore' }
    return 'collect'
}

function Reset-Log {
    $logBox.Clear()
    $script:LogLength = 0
    $statusLabel.Text = 'Ready.'
    $statusLabel.ForeColor = $colMuted
}

function Set-Running {
    param([bool]$Value)
    $script:Running = $Value
    $runButton.Enabled = -not $Value
    $stopButton.Enabled = $Value
    $radioCollect.Enabled = -not $Value
    $radioVerify.Enabled = -not $Value
    $radioRestore.Enabled = -not $Value
    $radioDeltaCollect.Enabled = -not $Value
    $radioDeltaApply.Enabled = -not $Value
    $radioRepairChats.Enabled = -not $Value
    $browseButton.Enabled = -not $Value
    $pathBox.Enabled = -not $Value
    $optPanel.Enabled = -not $Value
    if ($Value) {
        $progress.MarqueeAnimationSpeed = 30
    } else {
        $progress.MarqueeAnimationSpeed = 0
    }
}

function Start-Run {
    $mode = Get-CurrentMode
    $def = $script:ModeDefs[$mode]
    $target = Get-ScriptPath $def.Script
    if (-not (Test-Path -LiteralPath $target)) {
        Add-LogLine -Text ("Script not found: " + $target) -Color $colErr
        return
    }
    $path = $pathBox.Text.Trim()
    if ($def.NoPath) { $path = '' }
    elseif ([string]::IsNullOrWhiteSpace($path)) {
        Add-LogLine -Text 'Please choose a folder first (step 2).' -Color $colWarn
        return
    }
    $pathExists = (Test-Path -LiteralPath $path) -or (Test-Path -LiteralPath ($path.TrimEnd('\') + '.zip')) -or (Test-Path -LiteralPath ($path.TrimEnd('\') + '.zip.json'))
    if (-not $def.NoPath -and $mode -notin @('collect', 'deltacollect', 'deltaapply') -and -not $pathExists) {
        $answer = [System.Windows.Forms.MessageBox]::Show("Nothing found at:`n$path`n`nIf OneDrive is still syncing, the restore will wait for it. Run anyway?", 'Package not found yet', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { return }
    }

    Reset-Log
    $modeName = @{ 'collect' = 'Collect'; 'verify' = 'Verify'; 'restore' = 'Restore'; 'deltacollect' = 'Delta collect'; 'deltaapply' = 'Delta apply'; 'repairchats' = 'Chat repair' }[$mode]
    Add-LogLine -Text ('=== ' + $modeName + ' started ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ===') -Color $colAccent
    Add-LogLine -Text ('Script: ' + $target) -Color $colMuted

    $arguments = @()
    if ($def.Fixed) { $arguments += $def.Fixed }
    if (-not $def.NoPath) {
        $arguments += $def.PathArg
        $arguments += $path
    }
    if ($script:SinceBox -and $script:SinceBox.Text.Trim()) { $arguments += '-Since'; $arguments += $script:SinceBox.Text.Trim() }
    $script:Interactive = $false
    foreach ($id in $script:OptChecks.Keys) {
        if (-not $script:OptChecks[$id].Checked) { continue }
        if ($id -eq 'ConsoleEditor') { $script:Interactive = $true; continue }
        if ($id -eq 'InteractiveApps') { $script:Interactive = $true }
        $arguments += ('-' + $id)
    }
    if ($mode -eq 'restore' -and -not $script:Interactive) { $arguments += '-NonInteractive' }
    $arguments += '-NoElevate'

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $script:LogFile = Join-Path $env:TEMP ('lmt-gui-' + $stamp + '.log')
    $script:ArgsFile = Join-Path $env:TEMP ('lmt-gui-' + $stamp + '.args')
    $script:RunnerFile = Join-Path $env:TEMP 'lmt-gui-runner.ps1'
    $script:LogLength = 0
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($script:ArgsFile, [string[]]$arguments, $utf8)
    [System.IO.File]::WriteAllText($script:RunnerFile, $script:RunnerTemplate, $utf8)
    [System.IO.File]::WriteAllText($script:LogFile, '', $utf8)

    try {
        if ($script:Interactive) {
            $argString = '-NoProfile -ExecutionPolicy Bypass -File "' + $target + '" ' + ((($arguments | ForEach-Object { if ($_ -match '^-') { $_ } else { '"' + $_ + '"' } }) -join ' '))
            $script:Proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argString -PassThru
            Add-LogLine -Text 'Opened in a separate console window - finish it there, then close that window.' -Color $colWarn
            $statusLabel.Text = 'Running in a console window...'
        } else {
            $argString = '-NoProfile -ExecutionPolicy Bypass -File "' + $script:RunnerFile + '" -Target "' + $target + '" -Log "' + $script:LogFile + '" -ArgsFile "' + $script:ArgsFile + '"'
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = $argString
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
            $script:Proc = [System.Diagnostics.Process]::Start($psi)
            $statusLabel.Text = 'Running...'
        }
    } catch {
        Add-LogLine -Text ('Could not start: ' + $_.Exception.Message) -Color $colErr
        return
    }

    $script:Started = Get-Date
    Set-Running -Value $true
    $statusLabel.ForeColor = $colAccent
    $script:Timer.Start()
}

function Pump-Log {
    if (-not $script:LogFile) { return }
    if (-not (Test-Path -LiteralPath $script:LogFile)) { return }
    try {
        $fs = [System.IO.File]::Open($script:LogFile, 'Open', 'Read', 'ReadWrite, Delete')
        try {
            $reader = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)))
            $text = $reader.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return }
    if ($text.Length -le $script:LogLength) { return }
    $new = $text.Substring($script:LogLength)
    $script:LogLength = $text.Length
    foreach ($line in ($new -split "`r?`n")) {
        if ($line -eq '') { continue }
        Add-LogLine -Text $line -Color (Get-LineColor $line)
        if ($line -match '\] STEP\s+(.+)$') {
            $statusLabel.Text = $matches[1]
            $statusLabel.ForeColor = $colAccent
        }
    }
}

function Complete-Run {
    $script:Timer.Stop()
    Pump-Log
    $exitCode = $null
    if ($script:Proc) { $exitCode = $script:Proc.ExitCode }
    $elapsed = ''
    if ($script:Started) {
        $span = (Get-Date) - $script:Started
        $elapsed = (' ({0:N0}s)' -f $span.TotalSeconds)
    }
    $text = $logBox.Text
    $summary = [regex]::Match($text, '(Collection|Restore|Verification|Delta) finished[:,]?[^\r\n]*|Relinked [^\r\n]*|Nothing to relink[^\r\n]*|\d+ window\(s\) would be relinked[^\r\n]*')
    if ($summary.Success) {
        $statusLabel.Text = $summary.Value.Trim() + $elapsed
        $statusLabel.ForeColor = $colPink
    } elseif ($script:Interactive) {
        $statusLabel.Text = 'Console window closed' + $elapsed
        $statusLabel.ForeColor = $colMuted
    } else {
        $statusLabel.Text = ('Finished with exit code ' + $exitCode + $elapsed)
        $statusLabel.ForeColor = $colWarn
    }
    if ($text -match '(\d+)\s+errors') {
        if ([int]$matches[1] -gt 0) { $statusLabel.ForeColor = $colErr }
    }
    Add-LogLine -Text ('=== finished ' + (Get-Date -Format 'HH:mm:ss') + $elapsed + ' ===') -Color $colMuted
    Set-Running -Value $false
    $script:Proc = $null
    $openPackageButton.Enabled = (Test-Path -LiteralPath $pathBox.Text)
    $openBackupButton.Enabled = ($null -ne (Get-BackupFolder))
    $saveLogButton.Enabled = $true
}

function Get-BackupFolder {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { return $null }
    $folders = @(Get-ChildItem -LiteralPath $desktop -Directory -Filter 'MigrationBackup-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($folders.Count -eq 0) { return $null }
    return $folders[0].FullName
}

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 250
$script:Timer.Add_Tick({
    Pump-Log
    if ($script:Proc -and $script:Proc.HasExited) { Complete-Run }
})

function Refresh-Mode {
    $mode = Get-CurrentMode
    $suggested = Get-DefaultPackagePath
    if ($mode -in @('deltacollect', 'deltaapply')) {
        $deltaPath = Get-DefaultDeltaPath
        if ([string]::IsNullOrWhiteSpace($pathBox.Text) -or $pathBox.Text -eq $suggested) { $pathBox.Text = $deltaPath }
    } elseif ($pathBox.Text -eq (Get-DefaultDeltaPath)) {
        $pathBox.Text = $suggested
    }
    if ($mode -eq 'collect') {
        if ([string]::IsNullOrWhiteSpace($pathBox.Text)) { $pathBox.Text = $suggested }
    } else {
        if (Test-Path -LiteralPath $suggested) { if ([string]::IsNullOrWhiteSpace($pathBox.Text)) { $pathBox.Text = $suggested } }
    }
    Show-ModeOptions
}

$radioCollect.Add_CheckedChanged({ if ($radioCollect.Checked) { Refresh-Mode } })
$radioVerify.Add_CheckedChanged({ if ($radioVerify.Checked) { Refresh-Mode } })
$radioRestore.Add_CheckedChanged({ if ($radioRestore.Checked) { Refresh-Mode } })
$radioDeltaCollect.Add_CheckedChanged({ if ($radioDeltaCollect.Checked) { Refresh-Mode } })
$radioDeltaApply.Add_CheckedChanged({ if ($radioDeltaApply.Checked) { Refresh-Mode } })
$radioRepairChats.Add_CheckedChanged({ if ($radioRepairChats.Checked) { Refresh-Mode } })

$browseButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $script:ModeDefs[(Get-CurrentMode)].Browse
    $dialog.ShowNewFolderButton = $true
    if ($pathBox.Text -and (Test-Path -LiteralPath $pathBox.Text)) { $dialog.SelectedPath = $pathBox.Text }
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $pathBox.Text = $dialog.SelectedPath
        $openPackageButton.Enabled = $true
    }
})

$autoButton.Add_Click({
    $pathBox.Text = Get-DefaultPackagePath
    $openPackageButton.Enabled = (Test-Path -LiteralPath $pathBox.Text)
})

$openScriptsButton.Add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $script:ScriptRoot + '"') })

$openPackageButton.Add_Click({
    $path = $pathBox.Text.Trim()
    if (Test-Path -LiteralPath $path) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $path + '"') }
})

$openBackupButton.Add_Click({
    $folder = Get-BackupFolder
    if ($folder) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $folder + '"') }
})

$saveLogButton.Add_Click({
    $dialog = New-Object System.Windows.Forms.SaveFileDialog
    $dialog.Filter = 'Text file (*.txt)|*.txt|All files (*.*)|*.*'
    $dialog.FileName = ('migration-log-' + (Get-Date -Format 'yyyyMMdd-HHmm') + '.txt')
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Set-Content -LiteralPath $dialog.FileName -Value $logBox.Text -Encoding UTF8
    }
})

$copyLogButton.Add_Click({
    if ($logBox.TextLength -gt 0) { [System.Windows.Forms.Clipboard]::SetText($logBox.Text) }
})

$clearButton.Add_Click({ Reset-Log })

$runButton.Add_Click({ Start-Run })

$stopButton.Add_Click({
    if ($script:Proc -and -not $script:Proc.HasExited) {
        Add-LogLine -Text 'Stopping...' -Color $colWarn
        try { Stop-Process -Id $script:Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
    }
})

$pathBox.Add_TextChanged({ $openPackageButton.Enabled = (Test-Path -LiteralPath $pathBox.Text) })

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if ($script:Running) {
        $answer = [System.Windows.Forms.MessageBox]::Show('A migration step is still running. Stop it and close?', 'Still running', 'YesNo', 'Warning')
        if ($answer -ne 'Yes') { $eventArgs.Cancel = $true; return }
        if ($script:Proc -and -not $script:Proc.HasExited) {
            try { Stop-Process -Id $script:Proc.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
    }
})

$form.Add_Shown({
    $pathBox.Text = Get-DefaultPackagePath
    Show-ModeOptions
    Add-LogLine -Text 'laptop-migration-toolkit GUI - pick a step, choose a folder, then press Run.' -Color $colAccent
    Add-LogLine -Text ('Scripts: ' + $script:ScriptRoot) -Color $colMuted
    Add-LogLine -Text '' -Color $colMuted
})

[void]$form.ShowDialog()
$script:Timer.Dispose()
$form.Dispose()
