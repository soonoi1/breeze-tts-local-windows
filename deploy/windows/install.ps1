[CmdletBinding()]
param(
  [ValidateSet('auto', 'wsl', 'native')]
  [string]$Mode = 'auto',
  [string]$DistroName = 'Ubuntu',
  [switch]$SkipModel,
  [switch]$NoAutoStart,
  [string]$TorchIndexUrl = 'https://mirror.sjtu.edu.cn/pytorch-wheels/cu128',
  [string]$PypiIndexUrl = 'https://pypi.org/simple',
  [string]$HfEndpoint = 'https://hf-mirror.com',
  [int]$Port = 9000
)

$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$WindowsPython = $null

function Resolve-Python {
  $py = Get-Command py.exe -ErrorAction SilentlyContinue
  if ($null -ne $py) {
    $candidate = (& $py.Source -3 -c 'import sys; print(sys.executable)' 2>$null | Select-Object -Last 1).Trim()
    if ($candidate -and (Test-Path $candidate)) { return $candidate }
  }
  $python = Get-Command python.exe -ErrorAction SilentlyContinue
  if ($null -ne $python) { return $python.Source }
  return $null
}

function Ensure-Python {
  $script:WindowsPython = Resolve-Python
  if ($WindowsPython) { return }
  $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
  if ($null -eq $winget) {
    throw 'Python 3.11+ is required and winget.exe is unavailable. Install Python from python.org, then rerun this script.'
  }
  Write-Host 'Python not found; installing Python 3.12 for the Windows proxy/runtime...'
  & $winget.Source install --id Python.Python.3.12 --exact --scope user `
    --accept-package-agreements --accept-source-agreements
  if ($LASTEXITCODE -ne 0) { throw "winget Python install failed with exit code $LASTEXITCODE" }
  $script:WindowsPython = Resolve-Python
  if (-not $WindowsPython) {
    $known = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
    if (Test-Path $known) { $script:WindowsPython = $known }
  }
  if (-not $WindowsPython) { throw 'Python was installed but could not be found in this PowerShell process. Open a new PowerShell and rerun install.ps1.' }
}

function Get-GpuMemoryMb {
  $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
  if ($null -eq $smi) { return $null }
  $value = (& $smi.Source --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1).Trim()
  $number = 0
  if ([int]::TryParse($value, [ref]$number)) { return $number }
  return $null
}

function Test-UsableWsl {
  $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
  if ($null -eq $wsl) { return $false }
  try {
    & $wsl.Source -d $DistroName -- echo breeze-wsl-ready 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
  } catch { return $false }
}

function Stop-TaskIfPresent([string]$Name) {
  if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
    Write-Host "STOPPED_OLD_TASK=$Name"
  }
}

function Invoke-RegisterTasks([string]$ResolvedMode, [string]$NativePython, [string]$NativeModel) {
  $register = Join-Path $RepoRoot 'deploy\windows\register-tasks.ps1'
  $common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $register,
    '-Mode', $ResolvedMode, '-RepoRoot', $RepoRoot, '-DistroName', $DistroName,
    '-PythonPath', $NativePython, '-ProxyPort', "$Port")
  if ($ResolvedMode -eq 'native') { $common += @('-ModelDir', $NativeModel) }
  & powershell.exe @common
  if ($LASTEXITCODE -ne 0) { throw "Scheduled task registration failed with exit code $LASTEXITCODE" }
}

function Wait-ForHealth {
  $url = "http://127.0.0.1`:$Port/health"
  $deadline = (Get-Date).AddMinutes(10)
  do {
    Start-Sleep -Seconds 5
    try {
      $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 15
      if ($response.status -eq 'ok') {
        Write-Host ("HEALTH_OK=" + ($response | ConvertTo-Json -Compress))
        return
      }
      Write-Host ("HEALTH_WAIT=" + ($response | ConvertTo-Json -Compress))
    } catch {
      Write-Host 'HEALTH_WAIT=service is still starting'
    }
  } while ((Get-Date) -lt $deadline)
  Write-Warning "The service did not reach HTTP 200 within 10 minutes. It may still be compiling/loading; run deploy\windows\health.ps1 and inspect the task/log state."
}

Write-Host "REPO_ROOT=$RepoRoot"
Ensure-Python
$gpuMb = Get-GpuMemoryMb
$wslAvailable = Test-UsableWsl
if ($Mode -eq 'auto') {
  if ($wslAvailable -and $gpuMb -and $gpuMb -ge 22000) {
    $resolvedMode = 'wsl'
  } else {
    $resolvedMode = 'native'
  }
} else {
  $resolvedMode = $Mode
}
if ($resolvedMode -eq 'wsl' -and -not $wslAvailable) {
  throw "WSL distro '$DistroName' is not usable. Install/enable WSL2 and Ubuntu, reboot if Windows requests it, then rerun with -Mode wsl. Use -Mode auto to avoid a reboot and deploy native eager instead."
}
Write-Host "GPU_MEMORY_MB=$gpuMb WSL_AVAILABLE=$wslAvailable SELECTED_MODE=$resolvedMode"

if ($resolvedMode -eq 'wsl') {
  $wsl = (Get-Command wsl.exe -ErrorAction Stop).Source
  $wslRepo = (& $wsl -d $DistroName -- wslpath -a $RepoRoot 2>$null | Select-Object -Last 1).Trim()
  if (-not $wslRepo) { throw 'Could not translate the Windows repository path into WSL.' }
  $wslInstall = "$wslRepo/deploy/wsl/install.sh"
  $wslArgs = @('-d', $DistroName, '-u', 'root', '--', 'bash', $wslInstall,
    '--source-repo', $wslRepo,
    '--repo-dir', '/opt/breeze-tts-local-windows',
    '--data-dir', '/opt/breeze-tts-data',
    '--venv', '/opt/breeze-tts-venv',
    '--model-dir', '/opt/breeze-tts-data/models/Breeze-TTS-2',
    '--fast-mode', 'fast-all',
    '--torch-index-url', $TorchIndexUrl,
    '--pypi-index-url', $PypiIndexUrl,
    '--hf-endpoint', $HfEndpoint)
  if ($SkipModel) { $wslArgs += '--skip-model' }
  Write-Host 'Installing WSL2 dependencies/model/runtime...'
  & $wsl @wslArgs
  if ($LASTEXITCODE -ne 0) { throw "WSL installation failed with exit code $LASTEXITCODE" }
  Stop-TaskIfPresent 'Breeze TTS Native'
  Invoke-RegisterTasks -ResolvedMode 'wsl' -NativePython $WindowsPython -NativeModel ''
} else {
  $nativeRoot = Join-Path $RepoRoot '.venv-native'
  $nativePython = Join-Path $nativeRoot 'Scripts\python.exe'
  $modelDir = Join-Path $RepoRoot 'data\models\Breeze-TTS-2'
  New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'data\models') | Out-Null
  if (-not (Test-Path $nativePython)) {
    & $WindowsPython -m venv $nativeRoot
    if ($LASTEXITCODE -ne 0) { throw "native venv creation failed with exit code $LASTEXITCODE" }
  }
  Write-Host 'Installing native Windows Python dependencies...'
  & $nativePython -m pip install --upgrade pip --index-url $PypiIndexUrl
  & $nativePython -m pip install --upgrade --index-url $TorchIndexUrl torch==2.9.1 torchaudio==2.9.1
  & $nativePython -m pip install --upgrade --index-url $PypiIndexUrl -r (Join-Path $RepoRoot 'requirements.txt')
  if ($LASTEXITCODE -ne 0) { throw "native dependency installation failed with exit code $LASTEXITCODE" }
  if (-not $SkipModel) {
    & $nativePython (Join-Path $RepoRoot 'scripts\download_model.py') --dest $modelDir --endpoint $HfEndpoint
    if ($LASTEXITCODE -ne 0) { throw "model download failed with exit code $LASTEXITCODE" }
  }
  if (-not (Test-Path (Join-Path $modelDir 'config.json'))) {
    throw "Model checkpoint is missing: $modelDir\config.json. Remove -SkipModel or put a complete checkpoint there."
  }
  & $nativePython (Join-Path $RepoRoot 'scripts\patch_model_config.py') $modelDir
  $userEnv = @{
    BREEZE_MODEL_DIR = $modelDir
    BREEZE_FAST_MODE = 'eager'
    BREEZE_IDLE_TIMEOUT = '120'
    BREEZE_GEN_TIMEOUT = '180'
    BREEZE_GEN_STALL = '45'
    BREEZE_LOCK_TIMEOUT = '300'
    HF_ENDPOINT = $HfEndpoint
  }
  foreach ($entry in $userEnv.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'User')
  }
  Stop-TaskIfPresent 'Breeze TTS WSL'
  Stop-TaskIfPresent 'Breeze TTS PortProxy'
  Invoke-RegisterTasks -ResolvedMode 'native' -NativePython $nativePython -NativeModel $modelDir
}

if (-not $NoAutoStart) {
  $start = Join-Path $RepoRoot 'deploy\windows\start.ps1'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $start -Mode $resolvedMode
  if ($LASTEXITCODE -ne 0) { throw "service start failed with exit code $LASTEXITCODE" }
  Wait-ForHealth
}

Write-Host ''
Write-Host 'BREEZE_INSTALL_COMPLETE'
Write-Host "MODE=$resolvedMode"
Write-Host "API=http://127.0.0.1:$Port"
Write-Host 'NEXT=python .\examples\http_client.py --text "你好，这是本地 Breeze TTS。" --output .\outputs\hello.wav'
