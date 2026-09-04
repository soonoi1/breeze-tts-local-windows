param(
  [ValidateSet('wsl', 'native')]
  [string]$Mode = 'wsl',
  [Parameter(Mandatory = $true)]
  [string]$RepoRoot,
  [string]$DistroName = 'Ubuntu',
  [string]$PythonPath = '',
  [string]$ModelDir = '',
  [int]$ProxyPort = 9000,
  [switch]$NoFirewall
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($PythonPath)) {
  $PythonPath = (Get-Command python.exe -ErrorAction SilentlyContinue).Source
}
if ([string]::IsNullOrWhiteSpace($PythonPath)) {
  throw 'python.exe was not found; install Python 3.11+ before registering tasks.'
}

$runAs = "$env:USERDOMAIN\$env:USERNAME"
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $runAs
$settings = New-ScheduledTaskSettingsSet `
  -ExecutionTimeLimit ([TimeSpan]::Zero) `
  -RestartCount 3 `
  -RestartInterval (New-TimeSpan -Minutes 1) `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries
# Windows may expose this property only on newer builds; leave the task usable
# if an older Task Scheduler API rejects the assignment.
try { $settings.IdleSettings.StopOnIdleEnd = $false } catch { Write-Warning $_ }

function Register-BreezeTask {
  param([string]$Name, $Action)
  try { Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue } catch { }
  Register-ScheduledTask -TaskName $Name -Action $Action -Trigger $trigger `
    -Settings $settings -User $runAs -RunLevel Limited `
    -Description "Breeze TTS local service (managed by breeze-tts-local-windows)" -Force | Out-Null
  Write-Host "REGISTERED=$Name"
}

if ($Mode -eq 'wsl') {
  $wsl = (Get-Command wsl.exe -ErrorAction Stop).Source
  $wslRun = '/opt/breeze-tts-local-windows/deploy/wsl/run.sh'
  $wslArg = "-d `"$DistroName`" -u root -- bash `"$wslRun`""
  $wslAction = New-ScheduledTaskAction -Execute $wsl -Argument $wslArg
  $proxyScript = Join-Path $RepoRoot 'deploy\windows\tcpproxy.py'
  $proxyLog = Join-Path $RepoRoot 'data\breeze-proxy.log'
  $proxyArg = "`"$proxyScript`" --distro `"$DistroName`" --listen-host 0.0.0.0 --listen-port $ProxyPort --wsl-port 7860 --log-file `"$proxyLog`""
  $proxyAction = New-ScheduledTaskAction -Execute $PythonPath -Argument $proxyArg -WorkingDirectory $RepoRoot
  Register-BreezeTask -Name 'Breeze TTS WSL' -Action $wslAction
  Register-BreezeTask -Name 'Breeze TTS PortProxy' -Action $proxyAction
} else {
  if ([string]::IsNullOrWhiteSpace($ModelDir)) { throw '-ModelDir is required in native mode.' }
  $nativeArg = "-m breeze_infer.api `"$ModelDir`" --host 0.0.0.0 --port $ProxyPort --no-fast-all"
  $nativeAction = New-ScheduledTaskAction -Execute $PythonPath -Argument $nativeArg -WorkingDirectory $RepoRoot
  Register-BreezeTask -Name 'Breeze TTS Native' -Action $nativeAction
}

if (-not $NoFirewall) {
  try {
    $ruleName = "Breeze TTS Local API $ProxyPort"
    if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
      New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Protocol TCP `
        -LocalPort $ProxyPort -Action Allow -Profile Private -RemoteAddress LocalSubnet | Out-Null
    }
    Write-Host "FIREWALL_RULE=$ruleName"
  } catch {
    Write-Warning "Could not create the Private-profile firewall rule (run PowerShell as Administrator if LAN access is needed): $($_.Exception.Message)"
  }
}
