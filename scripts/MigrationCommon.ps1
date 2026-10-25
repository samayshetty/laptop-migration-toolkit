# Shared helpers dot-sourced by the toolkit scripts.

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
