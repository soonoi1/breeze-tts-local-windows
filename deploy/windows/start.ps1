param(
  [ValidateSet('wsl', 'native')]
  [string]$Mode = 'wsl',
  [switch]$Wait,
  [int]$Port = 9000
)
$ErrorActionPreference = 'Stop'

function Start-IfPresent([string]$Name) {
  $task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
  if ($null -eq $task) { throw "Scheduled task not found: $Name — run deploy\windows\install.ps1 first." }
  Start-ScheduledTask -TaskName $Name
  Write-Host "STARTED=$Name"
}

if ($Mode -eq 'wsl') {
  Start-IfPresent 'Breeze TTS WSL'
  Start-IfPresent 'Breeze TTS PortProxy'
} else {
  Start-IfPresent 'Breeze TTS Native'
}

if ($Wait) {
  Write-Host "Waiting for http://127.0.0.1:$Port/health (first start compiles CUDA graphs; 3-10 minutes is normal)..."
  $url = "http://127.0.0.1`:$Port/health"
  $deadline = (Get-Date).AddMinutes(15)
  do {
    Start-Sleep -Seconds 5
    try {
      $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15
      Write-Host ("HEALTH=" + ($response | ConvertTo-Json -Compress))
      exit 0
    } catch { Write-Host "WAITING=$((([DateTime]$deadline - (Get-Date)).TotalSeconds -as [int]))s left" }
  } while ((Get-Date) -lt $deadline)
  Write-Warning 'Service did not become healthy within 15 minutes. Run deploy\windows\health.ps1 for diagnosis; see docs\TROUBLESHOOTING.md.'
  exit 1
}
