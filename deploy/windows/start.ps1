param(
  [ValidateSet('wsl', 'native')]
  [string]$Mode = 'wsl'
)
$ErrorActionPreference = 'Stop'

function Start-IfPresent([string]$Name) {
  $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if ($null -eq $task) { throw "Scheduled task not found: $Name" }
  Start-ScheduledTask -TaskName $Name
  Write-Host "STARTED=$Name"
}

if ($Mode -eq 'wsl') {
  Start-IfPresent 'Breeze TTS WSL'
  Start-IfPresent 'Breeze TTS PortProxy'
} else {
  Start-IfPresent 'Breeze TTS Native'
}
