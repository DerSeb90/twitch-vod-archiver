<#
.SYNOPSIS
  Prepares local development on Windows. Everything lands in .\dev (gitignored),
  nothing is installed system-wide and no admin rights are needed.

  - dev\tools\venv          Python venv with streamlink
  - dev\tools\ffmpeg        ffmpeg.exe / ffprobe.exe (gyan.dev release essentials)
  - dev\data, recordings, archive   runtime folders for the Go server
  - .env                    copied from deploy\.env.example if missing
  - -Demo                   generates a small demo VOD (test pattern + chat) so the
                            UI can be tried without waiting for a live stream

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\dev-setup.ps1 -Demo
#>
param([switch]$Demo)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dev = Join-Path $root 'dev'
$tools = Join-Path $dev 'tools'
foreach ($d in 'data', 'recordings', 'archive', 'tools') { New-Item -ItemType Directory -Force (Join-Path $dev $d) | Out-Null }

# --- streamlink ------------------------------------------------------------
$venv = Join-Path $tools 'venv'
$streamlink = Join-Path $venv 'Scripts\streamlink.exe'
if (-not (Test-Path $streamlink)) {
    Write-Host '==> streamlink (Python venv)'
    python -m venv $venv
    & (Join-Path $venv 'Scripts\python.exe') -m pip install --quiet --upgrade pip streamlink
} else {
    Write-Host '==> streamlink: updating'
    & (Join-Path $venv 'Scripts\python.exe') -m pip install --quiet --upgrade streamlink
}
& $streamlink --version

# --- ffmpeg ----------------------------------------------------------------
$ffdir = Join-Path $tools 'ffmpeg'
if (-not (Test-Path (Join-Path $ffdir 'ffmpeg.exe'))) {
    Write-Host '==> ffmpeg (download ~100 MB)'
    $zip = Join-Path $tools 'ffmpeg.zip'
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip' -OutFile $zip
    $tmp = Join-Path $tools 'ffmpeg-tmp'
    Expand-Archive $zip -DestinationPath $tmp -Force
    New-Item -ItemType Directory -Force $ffdir | Out-Null
    Get-ChildItem $tmp -Recurse -Filter '*.exe' | Where-Object { $_.Directory.Name -eq 'bin' } | Move-Item -Destination $ffdir -Force
    Remove-Item $zip, $tmp -Recurse -Force
}
& (Join-Path $ffdir 'ffmpeg.exe') -hide_banner -version | Select-Object -First 1

# --- .env ------------------------------------------------------------------
$envFile = Join-Path $root '.env'
if (-not (Test-Path $envFile)) {
    Copy-Item (Join-Path $root 'deploy\.env.example') $envFile
    Write-Host "==> .env created - put TWITCH_CLIENT_ID and TWITCH_CLIENT_SECRET in: $envFile" -ForegroundColor Yellow
}

# --- demo VOD --------------------------------------------------------------
if ($Demo) {
    if (Test-Path (Join-Path $dev 'data\archive.db')) {
        Write-Host '==> demo skipped: dev\data\archive.db already exists (delete dev\ to start fresh)' -ForegroundColor Yellow
    } else {
        Write-Host '==> generating demo VOD'
        $env:PATH = "$ffdir;$env:PATH"
        $env:KEEP_DIR = $dev
        Push-Location (Join-Path $root 'server')
        try { go test -tags integration -count=1 -run TestFinalizePipeline ./internal/finalize/ } finally { Pop-Location; Remove-Item Env:KEEP_DIR }
    }
}

Write-Host ''
Write-Host 'Ready. In VS Code: Run and Debug -> "Server + App (Chrome)" (or "Server + App (Windows)").' -ForegroundColor Green
Write-Host 'Management UI: http://localhost:8080/admin'
