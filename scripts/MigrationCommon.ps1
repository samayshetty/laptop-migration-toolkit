# Shared helpers dot-sourced by the toolkit scripts.

Add-Type -AssemblyName System.Web.Extensions

$script:BrowserDefs = @(
    @{ Name = 'chrome'; Rel = 'Google\Chrome\User Data'; Proc = 'chrome' },
    @{ Name = 'edge';   Rel = 'Microsoft\Edge\User Data'; Proc = 'msedge' }
)

# Copies with FileShare.ReadWrite so files held open by a running app (sqlite db/wal, browser prefs) can still be read.
function Copy-Shared {
    param([string]$Source, [string]$Destination)
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $in = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]'ReadWrite, Delete')
    try {
        $out = [IO.File]::Create($Destination)
        try { $in.CopyTo($out) } finally { $out.Dispose() }
    } finally { $in.Dispose() }
    (Get-Item -LiteralPath $Destination -Force).LastWriteTime = (Get-Item -LiteralPath $Source -Force).LastWriteTime
}

function New-Json { $j = New-Object System.Web.Script.Serialization.JavaScriptSerializer; $j.MaxJsonLength = [int]::MaxValue; $j }

function Read-SharedText([string]$P) {
    $tmp = Join-Path $env:TEMP ('lmt-' + [guid]::NewGuid().ToString('N'))
    try { Copy-Shared $P $tmp; [IO.File]::ReadAllText($tmp) } finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}

# Adds profiles from an exported info_cache to the browser's "Local State" so they show in the profile picker.
function Register-BrowserProfiles {
    param(
        [Parameter(Mandatory)][string]$Browser,
        [Parameter(Mandatory)][string]$ProfilesJson,
        [string]$BackupDir,
        [switch]$CloseBrowser,
        [scriptblock]$Log = { param($m, $l) Write-Host $m }
    )
    $b = $script:BrowserDefs | Where-Object { $_.Name -eq $Browser } | Select-Object -First 1
    $broot = Join-Path $env:LOCALAPPDATA $b.Rel
    $lsPath = Join-Path $broot 'Local State'
    if (-not (Test-Path -LiteralPath $ProfilesJson)) { return }
    if (-not (Test-Path -LiteralPath $lsPath)) { & $Log "$Browser has never been started on this laptop - open it once, close it, then re-run to add the old profiles" 'WARN'; return }
    if (Get-Process -Name $b.Proc -ErrorAction SilentlyContinue) {
        if ($CloseBrowser) { Get-Process -Name $b.Proc -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2 }
        else { & $Log "$Browser is running - profiles were copied but not added to the picker. Close it and run again." 'WARN'; return }
    }
    try {
        $js = New-Json
        $old = $js.DeserializeObject([IO.File]::ReadAllText($ProfilesJson))
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
            if ($BackupDir) {
                $bk = Join-Path (Join-Path $BackupDir $Browser) 'Local State'
                New-Item -ItemType Directory -Path (Split-Path -Parent $bk) -Force | Out-Null
                Copy-Item -LiteralPath $lsPath -Destination $bk -Force
            }
            [IO.File]::WriteAllText($lsPath, $js.Serialize($ls), (New-Object System.Text.UTF8Encoding($false)))
        }
        & $Log "${Browser}: $added profile(s) added to the profile picker" 'OK'
    } catch { & $Log "$Browser profile registration failed: $($_.Exception.Message)" 'WARN' }
}

function Get-VsCodeCli {
    param([ValidateSet('stable', 'insiders')][string]$Flavor = 'stable')
    if ($Flavor -eq 'stable') {
        $c = Get-Command code -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        $cands = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd", "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd", "${env:ProgramFiles(x86)}\Microsoft VS Code\bin\code.cmd")
    } else {
        $c = Get-Command code-insiders -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        $cands = @("$env:LOCALAPPDATA\Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd", "$env:ProgramFiles\Microsoft VS Code Insiders\bin\code-insiders.cmd")
    }
    foreach ($p in $cands) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
    return $null
}

# Remembers the collection time on the old laptop so the first delta starts exactly there.
function Set-LastSyncTime([datetime]$When) {
    $dir = Join-Path $env:LOCALAPPDATA 'laptop-migration-toolkit'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [ordered]@{ LastDeltaCollect = $When.ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'last-sync.json') -Encoding UTF8
}

# Minimal key/value access to VS Code's state.vscdb (ItemTable) via the SQLite engine that ships with Windows.
if (-not ('LmtSqlite' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class LmtSqlite {
    const string Dll = "winsqlite3.dll";
    [DllImport(Dll, CharSet = CharSet.Unicode, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_open16(string file, out IntPtr db);
    [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_close(IntPtr db);
    [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_busy_timeout(IntPtr db, int ms);
    [DllImport(Dll, CharSet = CharSet.Unicode, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_prepare16_v2(IntPtr db, string sql, int nBytes, out IntPtr stmt, IntPtr tail);
    [DllImport(Dll, CharSet = CharSet.Unicode, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_bind_text16(IntPtr stmt, int idx, string val, int nBytes, IntPtr destructor);
    [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_step(IntPtr stmt);
    [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_column_text16(IntPtr stmt, int col);
    [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_finalize(IntPtr stmt);
    [DllImport(Dll, CharSet = CharSet.Ansi, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_backup_init(IntPtr destination, string destinationName, IntPtr source, string sourceName);
    [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_backup_step(IntPtr backup, int pages);
    [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern int sqlite3_backup_finish(IntPtr backup);
    [DllImport(Dll, CallingConvention = CallingConvention.StdCall)] static extern IntPtr sqlite3_errmsg16(IntPtr db);
    static readonly IntPtr Transient = new IntPtr(-1);

    static IntPtr Open(string path) {
        IntPtr db;
        if (sqlite3_open16(path, out db) != 0) { string m = Marshal.PtrToStringUni(sqlite3_errmsg16(db)); sqlite3_close(db); throw new Exception("open " + path + ": " + m); }
        sqlite3_busy_timeout(db, 5000);
        return db;
    }
    static IntPtr Prepare(IntPtr db, string sql) {
        IntPtr st;
        if (sqlite3_prepare16_v2(db, sql, -1, out st, IntPtr.Zero) != 0) throw new Exception(Marshal.PtrToStringUni(sqlite3_errmsg16(db)));
        return st;
    }
    public static string Get(string path, string key) {
        IntPtr db = Open(path);
        try {
            IntPtr st = Prepare(db, "SELECT value FROM ItemTable WHERE key = ?");
            try {
                sqlite3_bind_text16(st, 1, key, -1, Transient);
                int result = sqlite3_step(st);
                if (result == 100) return Marshal.PtrToStringUni(sqlite3_column_text16(st, 0));
                if (result == 101) return null;
                throw new Exception(Marshal.PtrToStringUni(sqlite3_errmsg16(db)));
            } finally { sqlite3_finalize(st); }
        } finally { sqlite3_close(db); }
    }
    public static void Set(string path, string key, string value) {
        IntPtr db = Open(path);
        try {
            IntPtr st = Prepare(db, "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)");
            try {
                sqlite3_bind_text16(st, 1, key, -1, Transient);
                sqlite3_bind_text16(st, 2, value, -1, Transient);
                if (sqlite3_step(st) != 101) throw new Exception(Marshal.PtrToStringUni(sqlite3_errmsg16(db)));
            } finally { sqlite3_finalize(st); }
        } finally { sqlite3_close(db); }
    }
    public static void Initialize(string path) {
        IntPtr db = Open(path);
        try {
            IntPtr st = Prepare(db, "CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE, value BLOB)");
            try {
                if (sqlite3_step(st) != 101) throw new Exception(Marshal.PtrToStringUni(sqlite3_errmsg16(db)));
            } finally { sqlite3_finalize(st); }
        } finally { sqlite3_close(db); }
    }
    public static void Backup(string source, string destination) {
        IntPtr src = Open(source);
        try {
            IntPtr dst = Open(destination);
            try {
                IntPtr backup = sqlite3_backup_init(dst, "main", src, "main");
                if (backup == IntPtr.Zero) throw new Exception(Marshal.PtrToStringUni(sqlite3_errmsg16(dst)));
                int result;
                try { result = sqlite3_backup_step(backup, -1); }
                finally { sqlite3_backup_finish(backup); }
                if (result != 101) throw new Exception("SQLite backup failed (rc=" + result + ")");
            } finally { sqlite3_close(dst); }
        } finally { sqlite3_close(src); }
    }
}
'@
}

function Write-PackageSidecar {
    param([Parameter(Mandatory)][string]$Zip)
    $item = Get-Item -LiteralPath $Zip
    [ordered]@{
        File      = $item.Name
        Length    = $item.Length
        SHA256    = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256).Hash
        CreatedAt = (Get-Date).ToString('o')
        Machine   = $env:COMPUTERNAME
    } | ConvertTo-Json | Set-Content -LiteralPath ($Zip + '.json') -Encoding UTF8
}

# Blocks until OneDrive (or any slow copy) has delivered the whole zip, verified by the small .json sidecar.
function Wait-PackageZip {
    param(
        [Parameter(Mandatory)][string]$Zip,
        [int]$TimeoutMinutes = 240,
        [scriptblock]$Log = { param($m, $l) Write-Host $m }
    )
    $sidecar = $Zip + '.json'
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $lastNote = [datetime]::MinValue
    $pinned = $false
    while ($true) {
        $meta = $null
        if (Test-Path -LiteralPath $sidecar) { try { $meta = Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json } catch { } }
        $item = if (Test-Path -LiteralPath $Zip) { Get-Item -LiteralPath $Zip -Force } else { $null }
        if ($item -and -not $pinned) {
            # Pinning tells OneDrive to download the file now instead of on first read.
            & attrib.exe +P -U "$Zip" 2>&1 | Out-Null
            $pinned = $true
        }
        $offline = $item -and ($item.Attributes -band [IO.FileAttributes]::Offline)
        $sizeOk = $item -and $meta -and ($item.Length -eq [int64]$meta.Length)
        if ($sizeOk -and -not $offline) {
            & $Log 'Verifying the download (checksum)...' 'STEP'
            try { $hash = (Get-FileHash -LiteralPath $Zip -Algorithm SHA256 -ErrorAction Stop).Hash } catch { $hash = $null }
            if ($hash -and $hash -eq $meta.SHA256) { & $Log 'Package fully downloaded and verified' 'OK'; return $true }
            if (-not $hash) { & $Log 'File still busy - waiting...' 'INFO' } else { & $Log 'Checksum not matching yet - OneDrive is still writing the file' 'INFO' }
        }
        if ((Get-Date) -gt $deadline) { & $Log "Gave up waiting after $TimeoutMinutes minutes. Check the OneDrive icon on BOTH laptops." 'ERROR'; return $false }
        if (((Get-Date) - $lastNote).TotalSeconds -ge 30) {
            $state = if (-not $item) { 'not arrived yet - still uploading from the old laptop' }
                     elseif (-not $meta) { 'zip visible, waiting for its checksum file' }
                     elseif ($offline) { ('downloading ({0:N0} MB) ...' -f ($meta.Length / 1MB)) }
                     else { ('{0:N0} of {1:N0} MB' -f ($item.Length / 1MB), ($meta.Length / 1MB)) }
            & $Log "Waiting for OneDrive: $([IO.Path]::GetFileName($Zip)) $state" 'INFO'
            $lastNote = Get-Date
        }
        Start-Sleep -Seconds 10
    }
}

# Accepts a package folder, a .zip, or a folder next to which "<folder>.zip" lives; returns a local, extracted folder.
function Resolve-MigrationPackage {
    param(
        [Parameter(Mandatory)][string]$Path,
        [scriptblock]$Log = { param($m, $l) Write-Host $m }
    )
    $full = [IO.Path]::GetFullPath($Path)
    if ((Test-Path -LiteralPath $full -PathType Container) -and (Test-Path -LiteralPath (Join-Path $full 'system-info.json'))) { return $full }
    $zip = $null
    if ($full -match '\.zip$') { $zip = $full }
    elseif (Test-Path -LiteralPath ($full.TrimEnd('\') + '.zip.json')) { $zip = $full.TrimEnd('\') + '.zip' }
    elseif (Test-Path -LiteralPath ($full.TrimEnd('\') + '.zip')) { $zip = $full.TrimEnd('\') + '.zip' }
    if (-not $zip) { return $full }
    if (-not (Wait-PackageZip -Zip $zip -Log $Log)) { throw "Package zip not available: $zip" }
    $hash = (Get-Content -LiteralPath ($zip + '.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json).SHA256
    $dest = Join-Path $env:LOCALAPPDATA 'laptop-migration-toolkit\package'
    $marker = Join-Path $dest '.source-hash'
    if ((Test-Path -LiteralPath $marker) -and $hash -and ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $hash)) {
        & $Log "Using the already extracted copy in $dest" 'OK'
    } else {
        Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        & $Log "Extracting package to $dest (local disk, avoids OneDrive slowness)..." 'STEP'
        & tar.exe -xf $zip -C $dest 2>&1 | Out-Null
        if ($hash) { Set-Content -LiteralPath $marker -Value $hash }
    }
    $info = Get-ChildItem -LiteralPath $dest -Filter 'system-info.json' -Recurse -Depth 1 -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $info) { throw "No system-info.json inside $zip" }
    return $info.DirectoryName
}

# Lets the VS Code CLI (Node) trust the same root/intermediate CAs as Windows, e.g. behind TLS inspection.
function Set-NodeCaFromWindows {
    if ($env:NODE_EXTRA_CA_CERTS -and (Test-Path -LiteralPath $env:NODE_EXTRA_CA_CERTS)) { return }
    $pem = Join-Path $env:TEMP 'lmt-windows-ca.pem'
    $sb = New-Object System.Text.StringBuilder
    $seen = @{}
    foreach ($store in 'LocalMachine\Root', 'LocalMachine\CA', 'CurrentUser\Root', 'CurrentUser\CA') {
        foreach ($c in Get-ChildItem "Cert:\$store" -ErrorAction SilentlyContinue) {
            if ($seen.ContainsKey($c.Thumbprint) -or $c.NotAfter -lt (Get-Date)) { continue }
            $seen[$c.Thumbprint] = $true
            [void]$sb.AppendLine('-----BEGIN CERTIFICATE-----')
            [void]$sb.AppendLine([Convert]::ToBase64String($c.RawData, 'InsertLineBreaks'))
            [void]$sb.AppendLine('-----END CERTIFICATE-----')
        }
    }
    [IO.File]::WriteAllText($pem, $sb.ToString())
    $env:NODE_EXTRA_CA_CERTS = $pem
}

# Runs "code --install-extension" with a hard timeout so one stuck marketplace download cannot hang the run.
function Install-VsCodeExtension {
    param([string]$Cli, [string]$Id, [int]$TimeoutSeconds = 240)
    $p = Start-Process -FilePath 'cmd.exe' -ArgumentList ('/c ""{0}" --install-extension {1} --force"' -f $Cli, $Id) -PassThru -WindowStyle Hidden
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) { & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null; return 'timeout' }
    if ($p.ExitCode -eq 0) { return 'ok' } else { return 'failed' }
}
