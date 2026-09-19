param(
  [int]$Port = 9000,
  [string]$HostName = '127.0.0.1'
)
$ErrorActionPreference = 'Stop'
$url = "http://$HostName`:$Port/health"
try {
  $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15
  $response | ConvertTo-Json -Compress
  exit 0
} catch {
  Write-Host "HEALTH_FAILED=$url :: $($_.Exception.Message)"
  foreach ($name in @('Breeze TTS WSL', 'Breeze TTS PortProxy', 'Breeze TTS Native')) {
    $task = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
    if ($null -ne $task) {
      $info = Get-ScheduledTaskInfo -TaskName $name
      Write-Host "TASK=$name STATE=$($task.State) LAST_RESULT=$($info.LastTaskResult)"
    }
  }
  Write-Host ''
  Write-Host 'Quick checks:'
  Write-Host '  1. Task state above should be Running. LAST_RESULT other than 0 = the process crashed; check the log below.'
  Write-Host '  2. WSL mode API log: wsl -d Ubuntu -u root -- tail -50 /opt/breeze-tts-data/logs/breeze-api.log'
  Write-Host '  3. Proxy log: Get-Content <repo>\data\breeze-proxy.log -Tail 50'
  Write-Host '  4. GPU dead after a driver update? wsl -d Ubuntu -- nvidia-smi  (if this fails: wsl --shutdown, wait 8 s, retry — docs\TROUBLESHOOTING.md)'
  exit 1
}
