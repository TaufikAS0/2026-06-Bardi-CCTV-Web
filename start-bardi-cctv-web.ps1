param(
  [string]$Camera1RtspUri = 'rtsp://192.168.1.9:554/V_ENC_001',
  [string]$Camera2RtspUri = 'rtsp://admin:12345678@192.168.1.43:8554/Streaming/Channels/102',
  [int]$Camera1StreamPort = 18080,
  [int]$Camera2StreamPort = 18082,
  [int]$UiPort = 18081,
  [string]$BindAddress = '0.0.0.0',
  [switch]$SkipCamera1,
  [switch]$SkipCamera2
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $scriptDir '.state'
$vlc1PidFile = Join-Path $stateDir 'vlc1.pid'
$vlc2PidFile = Join-Path $stateDir 'vlc2.pid'
$httpPidFile = Join-Path $stateDir 'http.pid'
$httpStdoutFile = Join-Path $stateDir 'http.stdout.log'
$httpStderrFile = Join-Path $stateDir 'http.stderr.log'
$cam1SceneDir = 'C:\Temp\bardi-cctv-web-cam1-scenes'
$vlcPath = 'C:\Program Files\VideoLAN\VLC\vlc.exe'
$serverScript = Join-Path $scriptDir 'server.py'

function Stop-RecordedProcess {
  param([string]$PidFile)

  if (-not (Test-Path -LiteralPath $PidFile)) {
    return
  }

  $pidText = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
  if ($pidText -match '^\d+$') {
    $existing = Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue
    if ($existing) {
      Stop-Process -Id $existing.Id -Force -ErrorAction SilentlyContinue
    }
  }

  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $vlcPath)) {
  throw "VLC tidak ditemukan di $vlcPath"
}

if (-not (Test-Path -LiteralPath $serverScript)) {
  throw "Server script tidak ditemukan di $serverScript"
}

$pythonExe = (Get-Command python -ErrorAction Stop).Source
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

Stop-RecordedProcess -PidFile $vlc1PidFile
Stop-RecordedProcess -PidFile $vlc2PidFile
Stop-RecordedProcess -PidFile $httpPidFile
Stop-RecordedProcess -PidFile (Join-Path $stateDir 'vlc.pid')

function Start-VlcBridge {
  param(
    [string]$CameraRtspUri,
    [int]$StreamPort,
    [string]$PidFile
  )

  $vlcArgs = @(
    '-I', 'dummy',
    $CameraRtspUri,
    '--network-caching=500',
    '--rtsp-tcp',
    '--no-audio',
    '--sout', "#transcode{vcodec=MJPG,vb=1200,acodec=none}:standard{access=http,mux=mpjpeg,dst=:$StreamPort/stream.mjpg}",
    '--sout-keep'
  )

  $vlcProcess = Start-Process -FilePath $vlcPath -ArgumentList $vlcArgs -WindowStyle Hidden -PassThru
  Set-Content -LiteralPath $PidFile -Value $vlcProcess.Id
  return $vlcProcess
}

function Start-VlcSceneBridge {
  param(
    [string]$CameraRtspUri,
    [string]$SceneDir,
    [string]$PidFile
  )

  New-Item -ItemType Directory -Force -Path $SceneDir | Out-Null
  Get-ChildItem -LiteralPath $SceneDir -Filter '*.jpg' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

  $vlcArgs = @(
    '-I', 'dummy',
    '--network-caching=500',
    '--rtsp-tcp',
    '--no-audio',
    '--video-filter=scene',
    '--scene-ratio=15',
    '--scene-format=jpg',
    '--scene-prefix=cam1',
    '--scene-path', $SceneDir,
    $CameraRtspUri
  )

  $vlcProcess = Start-Process -FilePath $vlcPath -ArgumentList $vlcArgs -WindowStyle Hidden -PassThru
  Set-Content -LiteralPath $PidFile -Value $vlcProcess.Id
  return $vlcProcess
}

function Wait-SceneFrames {
  param(
    [string]$SceneDir,
    [int]$TimeoutSeconds = 8
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $freshFile = Get-ChildItem -LiteralPath $SceneDir -Filter '*.jpg' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending |
      Select-Object -First 1

    if ($freshFile) {
      return $true
    }

    Start-Sleep -Milliseconds 500
  }

  return $false
}

function Wait-VlcBridgePort {
  param(
    [int]$StreamPort,
    [int]$TimeoutSeconds = 8
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $conn = Get-NetTCPConnection -State Listen -LocalPort $StreamPort -ErrorAction Stop
      if ($conn) {
        return
      }
    } catch {
    }
    Start-Sleep -Milliseconds 500
  }
  throw "Bridge stream pada port $StreamPort tidak listen dalam waktu yang diharapkan"
}

$cameraSpecs = @()
$cameraWarnings = @()

if (-not $SkipCamera1) {
  try {
    Start-VlcSceneBridge -CameraRtspUri $Camera1RtspUri -SceneDir $cam1SceneDir -PidFile $vlc1PidFile | Out-Null
    Start-Sleep -Seconds 1
    if (Wait-SceneFrames -SceneDir $cam1SceneDir) {
      $cameraSpecs += ('1|Bardi Camera 1|192.168.1.9|scene-dir|{0}' -f $cam1SceneDir)
    } else {
      $cameraWarnings += 'Kamera 1 tidak menghasilkan frame baru, jadi untuk sementara tidak dimasukkan ke Web UI.'
      Stop-RecordedProcess -PidFile $vlc1PidFile
    }
  } catch {
    $cameraWarnings += ('Kamera 1 gagal start: {0}' -f $_.Exception.Message)
    Stop-RecordedProcess -PidFile $vlc1PidFile
  }
}

if (-not $SkipCamera2) {
  try {
    Start-VlcBridge -CameraRtspUri $Camera2RtspUri -StreamPort $Camera2StreamPort -PidFile $vlc2PidFile | Out-Null
    try {
      Wait-VlcBridgePort -StreamPort $Camera2StreamPort
    } catch {
      $cameraWarnings += ('Bridge Kamera 2 belum listen stabil: {0}' -f $_.Exception.Message)
    }

    $cameraSpecs += ('2|Bardi Camera 2|192.168.1.43|mjpeg|http://127.0.0.1:{0}/stream.mjpg' -f $Camera2StreamPort)
  } catch {
    $cameraWarnings += ('Kamera 2 gagal start: {0}' -f $_.Exception.Message)
    Stop-RecordedProcess -PidFile $vlc2PidFile
  }
}

if ($cameraSpecs.Count -eq 0) {
  throw 'Tidak ada kamera yang berhasil dipersiapkan untuk Web UI.'
}

function Quote-Arg {
  param([string]$Value)

  if ($null -eq $Value) {
    return '""'
  }

  if ($Value -match '[\s|"]') {
    return '"' + $Value.Replace('"', '\"') + '"'
  }

  return $Value
}

$pythonArgs = @(
  (Quote-Arg $serverScript),
  '--port', $UiPort,
  '--bind', $BindAddress,
  '--directory', (Quote-Arg $scriptDir)
)

foreach ($cameraSpec in $cameraSpecs) {
  $pythonArgs += '--camera'
  $pythonArgs += (Quote-Arg $cameraSpec)
}

$pythonArgString = $pythonArgs -join ' '

$null = Remove-Item -LiteralPath $httpStdoutFile -Force -ErrorAction SilentlyContinue
$null = Remove-Item -LiteralPath $httpStderrFile -Force -ErrorAction SilentlyContinue
$httpProcess = Start-Process -FilePath $pythonExe -ArgumentList $pythonArgString -WorkingDirectory $scriptDir -WindowStyle Hidden -RedirectStandardOutput $httpStdoutFile -RedirectStandardError $httpStderrFile -PassThru
Set-Content -LiteralPath $httpPidFile -Value $httpProcess.Id

Start-Sleep -Seconds 3

$listenUrls = @("http://localhost:$UiPort/")
$lanIps = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object {
    $_.IPAddress -notlike '127.*' -and
    $_.IPAddress -notlike '169.254.*'
  } |
  Select-Object -ExpandProperty IPAddress -Unique

foreach ($ip in $lanIps) {
  $listenUrls += "http://${ip}:$UiPort/"
}

Write-Host "Bardi CCTV web bridge aktif."
Write-Host "Camera 1 RTSP: $Camera1RtspUri"
Write-Host "Camera 2 RTSP: $Camera2RtspUri"
Write-Host "Camera 1 Scene Dir: $cam1SceneDir"
Write-Host "Camera 2 MJPEG: http://localhost:$Camera2StreamPort/stream.mjpg"
if ($cameraSpecs -match '^1\|') {
  Write-Host "Browser Cam 1: http://localhost:$UiPort/camera/1/stream.mjpg"
}
if ($cameraSpecs -match '^2\|') {
  Write-Host "Browser Cam 2: http://localhost:$UiPort/camera/2/stream.mjpg"
}
foreach ($warning in $cameraWarnings) {
  Write-Warning $warning
}
Write-Host "Web UI:"
$listenUrls | ForEach-Object { Write-Host "  $_" }
Write-Host "Stop dengan: powershell -ExecutionPolicy Bypass -File `"$scriptDir\stop-bardi-cctv-web.ps1`""
