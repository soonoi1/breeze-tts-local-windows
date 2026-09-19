param(
  [ValidateSet('wsl', 'native')]
  [string]$Mode = 'wsl',
  [switch]$Wait
)
$ErrorActionPreference = 'Continue'

$names = if ($Mode -eq 'wsl') {
  @('Breeze TTS PortProxy', 'Breeze TTS WSL')
} else {
  @('Breeze TTS Native')
}
foreach ($name in $names) {
  if (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    Write-Host "STOP_REQUESTED=$name"
  } else {
    Write-Host "NOT_REGISTERED=$name"
  }
}

if (-not $Wait) { exit 0 }

# Best-effort wait until the port is free again, so a stop-then-start sequence
# cannot race the old listener releasing the socket.
$deadline = (Get-Date).AddSeconds(20)
while ((Get-Date) -lt $deadline) {
  $listeners = if ($Mode -eq 'native') {
    Get-NetTCPConnection -LocalPort 9000 -State Listen -ErrorAction SilentlyContinue
  } else {
    $null
  }
  if (-not $listeners) { break }
  Start-Sleep -Seconds 1
}
Write-Host 'STOP_SEQUENCE_DONE'
