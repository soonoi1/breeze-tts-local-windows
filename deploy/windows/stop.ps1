param(
  [ValidateSet('wsl', 'native')]
  [string]$Mode = 'wsl'
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
