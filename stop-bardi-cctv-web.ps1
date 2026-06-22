$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$stateDir = Join-Path $scriptDir '.state'
$pidFiles = @(
  (Join-Path $stateDir 'vlc1.pid'),
  (Join-Path $stateDir 'vlc2.pid'),
  (Join-Path $stateDir 'vlc.pid'),
  (Join-Path $stateDir 'http.pid')
)

foreach ($pidFile in $pidFiles) {
  if (-not (Test-Path -LiteralPath $pidFile)) {
    continue
  }

  $pidText = (Get-Content -LiteralPath $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
  if ($pidText -match '^\d+$') {
    $existing = Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue
    if ($existing) {
      Stop-Process -Id $existing.Id -Force -ErrorAction SilentlyContinue
      Write-Host "Stopped PID $pidText"
    }
  }

  Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
}
