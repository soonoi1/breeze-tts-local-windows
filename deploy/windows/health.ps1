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
  exit 1
}
