param(
  [string]$Camera1RtspUri = 'rtsp://192.168.1.9:554/V_ENC_000',
  [string]$Camera2RtspUri = 'rtsp://admin:12345678@192.168.1.43:8554/Streaming/Channels/102',
  [string]$Camera2SharpRtspUri = 'rtsp://admin:12345678@192.168.1.43:8554/Streaming/Channels/101',
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
$cam2SharpPidFile = Join-Path $stateDir 'cam2sharp.pid'
$httpPidFile = Join-Path $stateDir 'http.pid'
$httpStdoutFile = Join-Path $stateDir 'http.stdout.log'
$httpStderrFile = Join-Path $stateDir 'http.stderr.log'
$cam1SceneDir = 'C:\Temp\cctv-hack-cam1-scenes'
$cam1RuntimeDir = 'C:\Temp\cctv-hack-cam1-runtime'
$cam2SharpSceneDir = 'C:\Temp\cctv-hack-cam2-sharp-scenes'
$cam2SharpRuntimeDir = 'C:\Temp\cctv-hack-cam2-sharp-runtime'
$vlcPath = 'C:\Program Files\VideoLAN\VLC\vlc.exe'
$serverScript = Join-Path $scriptDir 'server.py'
$cam1CaptureScript = Join-Path $scriptDir 'capture_rtsp_to_dir.py'
$placeholderSource = 'disabled://placeholder'

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

if (-not (Test-Path -LiteralPath $cam1CaptureScript)) {
  throw "Capture script kamera 1 tidak ditemukan di $cam1CaptureScript"
}

$pythonExe = (Get-Command python -ErrorAction Stop).Source
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null

Stop-RecordedProcess -PidFile $vlc1PidFile
Stop-RecordedProcess -PidFile $vlc2PidFile
Stop-RecordedProcess -PidFile $cam2SharpPidFile
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

function Start-OpenCvSceneBridge {
  param(
    [string]$CameraRtspUri,
    [string]$SceneDir,
    [string]$PidFile,
    [string]$RuntimeDir,
    [string]$Prefix = 'capture',
    [int]$IntervalMs = 900,
    [int]$JpegQuality = 82,
    [int]$KeepCount = 8,
    [int]$ReconnectSeconds = 18
  )

  New-Item -ItemType Directory -Force -Path $SceneDir | Out-Null
  New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
  Get-ChildItem -LiteralPath $SceneDir -Filter '*.jpg' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

  $runtimeCaptureScript = Join-Path $RuntimeDir 'capture_rtsp_to_dir.py'
  Copy-Item -LiteralPath $cam1CaptureScript -Destination $runtimeCaptureScript -Force

  $captureArgs = @(
    $runtimeCaptureScript,
    '--uri', $CameraRtspUri,
    '--output-dir', $SceneDir,
    '--prefix', $Prefix,
    '--interval-ms', "$IntervalMs",
    '--jpeg-quality', "$JpegQuality",
    '--keep-count', "$KeepCount",
    '--reconnect-seconds', "$ReconnectSeconds"
  )

  $captureProcess = Start-Process -FilePath $pythonExe -ArgumentList $captureArgs -WindowStyle Hidden -PassThru
  Set-Content -LiteralPath $PidFile -Value $captureProcess.Id
  return $captureProcess
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

function Wait-MjpegReadable {
  param(
    [string]$Url,
    [int]$TimeoutSeconds = 10,
    [int]$MinBytes = 512
  )

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $request = [System.Net.HttpWebRequest]::Create($Url)
      $request.Method = 'GET'
      $request.Timeout = 2500
      $request.ReadWriteTimeout = 2500
      $request.AllowReadStreamBuffering = $false

      $response = $request.GetResponse()
      $stream = $response.GetResponseStream()
      $buffer = New-Object byte[] 4096
      $bytesRead = $stream.Read($buffer, 0, $buffer.Length)

      if ($stream) { $stream.Close() }
      if ($response) { $response.Close() }

      if ($bytesRead -ge $MinBytes) {
        return $true
      }
    } catch {
    }

    Start-Sleep -Milliseconds 700
  }

  return $false
}

function Get-CameraSpec {
  param(
    [string]$CameraId,
    [string]$CameraName,
    [string]$CameraIp,
    [string]$Mode,
    [string]$Source,
    [string]$Profile = ''
  )

  if ($Profile) {
    return ('{0}|{1}|{2}|{3}|{4}|{5}' -f $CameraId, $CameraName, $CameraIp, $Mode, $Source, $Profile)
  }

  return ('{0}|{1}|{2}|{3}|{4}' -f $CameraId, $CameraName, $CameraIp, $Mode, $Source)
}

function Get-ActiveLanIps {
  $upInterfaces = Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object Status -eq 'Up' |
    Select-Object -ExpandProperty Name -Unique

  return Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
      $_.InterfaceAlias -in $upInterfaces -and
      $_.IPAddress -notlike '127.*' -and
      $_.IPAddress -notlike '169.254.*'
    } |
    Select-Object -ExpandProperty IPAddress -Unique
}

function Ensure-UiFirewallRule {
  param([int]$Port)

  $ruleName = "CCTV_HACK Ghost Grid UI $Port"
  try {
    $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $existing) {
      New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Any | Out-Null
    }
  } catch {
    Write-Warning "Rule firewall untuk port $Port belum bisa dipastikan: $($_.Exception.Message)"
  }
}

$cameraSpecs = @()
$cameraWarnings = @()

if (-not $SkipCamera1) {
  $camera1Candidates = @(
    $Camera1RtspUri,
    'rtsp://192.168.1.9:554/V_ENC_001'
  ) | Select-Object -Unique

  $camera1Ready = $false
  foreach ($candidateUri in $camera1Candidates) {
    try {
      Stop-RecordedProcess -PidFile $vlc1PidFile
      Start-OpenCvSceneBridge -CameraRtspUri $candidateUri -SceneDir $cam1SceneDir -PidFile $vlc1PidFile -RuntimeDir $cam1RuntimeDir -Prefix 'cam1' -IntervalMs 900 -JpegQuality 82 -KeepCount 8 -ReconnectSeconds 18 | Out-Null
      if (Wait-SceneFrames -SceneDir $cam1SceneDir -TimeoutSeconds 12) {
        $Camera1RtspUri = $candidateUri
        $cameraSpecs += (Get-CameraSpec -CameraId '1' -CameraName 'CCTV_HACK Node 1' -CameraIp '192.168.1.9' -Mode 'scene-dir' -Source $cam1SceneDir)
        $cameraWarnings += 'Kamera 1 memakai helper OpenCV RTSP terpisah karena VLC MJPEG tidak stabil pada stream ini.'
        $camera1Ready = $true
        break
      }

      $cameraWarnings += ('Capture Kamera 1 dari {0} belum menghasilkan JPG, coba profile lain.' -f $candidateUri)
    } catch {
      $cameraWarnings += ('Kamera 1 gagal start dari {0}: {1}' -f $candidateUri, $_.Exception.Message)
    }

    Stop-RecordedProcess -PidFile $vlc1PidFile
  }

  if (-not $camera1Ready) {
    $cameraWarnings += 'Kamera 1 tetap offline karena helper RTSP belum menghasilkan frame stabil.'
    $cameraSpecs += (Get-CameraSpec -CameraId '1' -CameraName 'CCTV_HACK Node 1' -CameraIp '192.168.1.9' -Mode 'placeholder' -Source $placeholderSource)
  }
} else {
  $cameraWarnings += 'Kamera 1 tidak dipaksa start, jadi panelnya tetap ada sebagai offline.'
  $cameraSpecs += (Get-CameraSpec -CameraId '1' -CameraName 'CCTV_HACK Node 1' -CameraIp '192.168.1.9' -Mode 'placeholder' -Source $placeholderSource)
}

if (-not $SkipCamera2) {
  try {
    Start-VlcBridge -CameraRtspUri $Camera2RtspUri -StreamPort $Camera2StreamPort -PidFile $vlc2PidFile | Out-Null
    try {
      Wait-VlcBridgePort -StreamPort $Camera2StreamPort
      if (-not (Wait-MjpegReadable -Url ('http://127.0.0.1:{0}/stream.mjpg' -f $Camera2StreamPort) -TimeoutSeconds 20)) {
        $cameraWarnings += 'Bridge Kamera 2 belum mengalirkan frame live saat startup, tetapi koneksinya tetap dijaga.'
      }
      $cameraSpecs += (Get-CameraSpec -CameraId '2' -CameraName 'CCTV_HACK Node 2' -CameraIp '192.168.1.43' -Mode 'mjpeg' -Source ('http://127.0.0.1:{0}/stream.mjpg' -f $Camera2StreamPort) -Profile 'fast')

      try {
        Stop-RecordedProcess -PidFile $cam2SharpPidFile
        Start-OpenCvSceneBridge -CameraRtspUri $Camera2SharpRtspUri -SceneDir $cam2SharpSceneDir -PidFile $cam2SharpPidFile -RuntimeDir $cam2SharpRuntimeDir -Prefix 'cam2sharp' -IntervalMs 450 -JpegQuality 90 -KeepCount 10 -ReconnectSeconds 15 | Out-Null
        if (Wait-SceneFrames -SceneDir $cam2SharpSceneDir -TimeoutSeconds 12) {
          $cameraSpecs += (Get-CameraSpec -CameraId '2' -CameraName 'CCTV_HACK Node 2' -CameraIp '192.168.1.43' -Mode 'scene-dir' -Source $cam2SharpSceneDir -Profile 'sharp')
        } else {
          $cameraWarnings += 'Mode SHARP Kamera 2 belum menghasilkan frame dari main stream 1080p.'
          Stop-RecordedProcess -PidFile $cam2SharpPidFile
        }
      } catch {
        $cameraWarnings += ('Mode SHARP Kamera 2 gagal start: {0}' -f $_.Exception.Message)
        Stop-RecordedProcess -PidFile $cam2SharpPidFile
      }
    } catch {
      $cameraWarnings += ('Bridge Kamera 2 belum listen stabil: {0}' -f $_.Exception.Message)
      $cameraSpecs += (Get-CameraSpec -CameraId '2' -CameraName 'CCTV_HACK Node 2' -CameraIp '192.168.1.43' -Mode 'placeholder' -Source $placeholderSource)
      Stop-RecordedProcess -PidFile $vlc2PidFile
      Stop-RecordedProcess -PidFile $cam2SharpPidFile
    }
  } catch {
    $cameraWarnings += ('Kamera 2 gagal start: {0}' -f $_.Exception.Message)
    $cameraSpecs += (Get-CameraSpec -CameraId '2' -CameraName 'CCTV_HACK Node 2' -CameraIp '192.168.1.43' -Mode 'placeholder' -Source $placeholderSource)
    Stop-RecordedProcess -PidFile $vlc2PidFile
    Stop-RecordedProcess -PidFile $cam2SharpPidFile
  }
} else {
  $cameraWarnings += 'Kamera 2 sedang dilewati, jadi panelnya ditampilkan sebagai offline.'
  $cameraSpecs += (Get-CameraSpec -CameraId '2' -CameraName 'CCTV_HACK Node 2' -CameraIp '192.168.1.43' -Mode 'placeholder' -Source $placeholderSource)
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

Ensure-UiFirewallRule -Port $UiPort

$listenUrls = @("http://localhost:$UiPort/")
$lanIps = Get-ActiveLanIps

foreach ($ip in $lanIps) {
  $listenUrls += "http://${ip}:$UiPort/"
}

Write-Host "CCTV_HACK Ghost Grid bridge aktif."
Write-Host "Camera 1 RTSP: $Camera1RtspUri"
Write-Host "Camera 2 RTSP: $Camera2RtspUri"
Write-Host "Camera 2 SHARP RTSP: $Camera2SharpRtspUri"
Write-Host "Camera 1 frames: $cam1SceneDir"
Write-Host "Camera 2 MJPEG: http://localhost:$Camera2StreamPort/stream.mjpg"
Write-Host "Camera 2 SHARP frames: $cam2SharpSceneDir"
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
Write-Host "Stop dengan menjalankan skrip stop yang ada di folder ini."
