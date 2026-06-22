param(
  [string]$Camera1RtspUri = 'rtsp://192.168.1.9:554/V_ENC_001',
  [string]$Camera2RtspUri = 'rtsp://admin:12345678@192.168.1.43:8554/Streaming/Channels/102',
  [int]$Camera1StreamPort = 18080,
  [int]$Camera2StreamPort = 18082,
  [int]$UiPort = 18081,
  [string]$BindAddress = '0.0.0.0'
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

Start-VlcSceneBridge -CameraRtspUri $Camera1RtspUri -SceneDir $cam1SceneDir -PidFile $vlc1PidFile | Out-Null
Start-Sleep -Seconds 1
Start-VlcBridge -CameraRtspUri $Camera2RtspUri -StreamPort $Camera2StreamPort -PidFile $vlc2PidFile | Out-Null
Wait-VlcBridgePort -StreamPort $Camera2StreamPort
Start-Sleep -Seconds 6

$camera1Spec = '1|Bardi Camera 1|192.168.1.9|scene-dir|{0}' -f $cam1SceneDir
$camera2Spec = '2|Bardi Camera 2|192.168.1.43|mjpeg|http://127.0.0.1:{0}/stream.mjpg' -f $Camera2StreamPort

$pythonArgString = ('"{0}" --port {1} --bind {2} --directory "{3}" --camera "{4}" --camera "{5}"' -f
  $serverScript,
  $UiPort,
  $BindAddress,
  $scriptDir,
  $camera1Spec,
  $camera2Spec
)

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
Write-Host "Browser Cam 1: http://localhost:$UiPort/camera/1/stream.mjpg"
Write-Host "Browser Cam 2: http://localhost:$UiPort/camera/2/stream.mjpg"
Write-Host "Web UI:"
$listenUrls | ForEach-Object { Write-Host "  $_" }
Write-Host "Stop dengan: powershell -ExecutionPolicy Bypass -File `"$scriptDir\stop-bardi-cctv-web.ps1`""
