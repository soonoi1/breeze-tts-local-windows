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

# Minimum NVIDIA Windows driver for CUDA 12.8 wheels inside WSL2. Older
# drivers are the most common cause of a dead /dev/dxg after a silent update.
$MinDriverVersion = [version]'550.0'

function Write-Step([string]$Message) {
  Write-Host ''
  Write-Host "=== $Message ==="
}

function Invoke-Checked {
  # PowerShell does not stop on failed external commands even with
  # $ErrorActionPreference = 'Stop'; check $LASTEXITCODE explicitly.
  param([string]$Description, [scriptblock]$Command)
  & $Command
  if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE" }
}

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

function Get-GpuDriverVersion {
  $smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
  if ($null -eq $smi) { return $null }
  $value = (& $smi.Source --query-gpu=driver_version --format=csv,noheader 2>$null | Select-Object -First 1).Trim()
  $parsed = $null
  if ([version]::TryParse($value, [ref]$parsed)) { return $parsed }
  return $null
}

function Assert-PortFree([int]$ListenPort) {
  $conns = Get-NetTCPConnection -LocalPort $ListenPort -State Listen -ErrorAction SilentlyContinue
  if (-not $conns) {
    Write-Host "PORT_FREE=$ListenPort"
    return
  }
  foreach ($conn in $conns) {
    $cmdline = ''
    try {
      $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId=$($conn.OwningProcess)").CommandLine
    } catch { }
    if ($cmdline -match 'tcpproxy\.py' -or $cmdline -match 'breeze_infer\.api') {
      Write-Host "PORT_BUSY_WITH_OLD_BREEZE=$ListenPort pid=$($conn.OwningProcess); stopping it"
      Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue
      Start-Sleep -Seconds 1
    } else {
      throw ("Port $ListenPort is already used by PID $($conn.OwningProcess) ($cmdline). " +
             "Stop that program, or rerun install.ps1 with -Port <other>.")
    }
  }
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
Write-Step 'STEP 1/6 Python'
Ensure-Python

Write-Step 'STEP 2/6 GPU & driver'
$smi = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
if ($null -eq $smi) {
  throw 'nvidia-smi.exe was not found. Install the NVIDIA Game Ready / Studio driver (it bundles the WSL CUDA driver) and rerun.'
}
$gpuMb = Get-GpuMemoryMb
$driverVersion = Get-GpuDriverVersion
Write-Host "GPU_MEMORY_MB=$gpuMb DRIVER_VERSION=$driverVersion"
if ($null -ne $driverVersion -and $driverVersion -lt $MinDriverVersion) {
  Write-Warning ("NVIDIA driver $driverVersion is older than $MinDriverVersion. " +
    'CUDA 12.8 wheels in WSL2 need a 550+ driver; update it before reporting a broken /dev/dxg.')
}
if (-not $gpuMb) {
  throw 'nvidia-smi exists but could not report GPU memory. The GPU or its WSL driver is not healthy; see docs/TROUBLESHOOTING.md (dxg).'
}

Write-Step 'STEP 3/6 WSL & port'
$wslAvailable = Test-UsableWsl
if ($Mode -eq 'auto') {
  if ($wslAvailable -and $gpuMb -ge 22000) {
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
Write-Host "WSL_AVAILABLE=$wslAvailable SELECTED_MODE=$resolvedMode"
if ($resolvedMode -eq 'native' -and $gpuMb -lt 8000) {
  Write-Warning 'Native eager mode needs ~8 GiB VRAM; this GPU reports less and generation may fail or swap to system memory.'
}
Assert-PortFree $Port

if ($resolvedMode -eq 'wsl') {
  Write-Step 'STEP 4/6 WSL2 dependencies + model'
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
  Write-Step 'STEP 5/6 register scheduled tasks'
  Invoke-RegisterTasks -ResolvedMode 'wsl' -NativePython $WindowsPython -NativeModel ''
} else {
  Write-Step 'STEP 4/6 native Windows dependencies + model'
  $nativeRoot = Join-Path $RepoRoot '.venv-native'
  $nativePython = Join-Path $nativeRoot 'Scripts\python.exe'
  $modelDir = Join-Path $RepoRoot 'data\models\Breeze-TTS-2'
  New-Item -ItemType Directory -Force -Path (Join-Path $RepoRoot 'data\models') | Out-Null
  if (-not (Test-Path $nativePython)) {
    Invoke-Checked 'native venv creation' { & $WindowsPython -m venv $nativeRoot }
  }
  Write-Host 'Installing native Windows Python dependencies...'
  Invoke-Checked 'pip upgrade' { & $nativePython -m pip install --upgrade pip --index-url $PypiIndexUrl }
  Invoke-Checked 'torch install' { & $nativePython -m pip install --upgrade --index-url $TorchIndexUrl torch==2.9.1 torchaudio==2.9.1 }
  Invoke-Checked 'requirements install' { & $nativePython -m pip install --upgrade --index-url $PypiIndexUrl -r (Join-Path $RepoRoot 'requirements.txt') }
  if (-not $SkipModel) {
    Invoke-Checked 'model download' { & $nativePython (Join-Path $RepoRoot 'scripts\download_model.py') --dest $modelDir --endpoint $HfEndpoint }
  }
  if (-not (Test-Path (Join-Path $modelDir 'config.json'))) {
    throw "Model checkpoint is missing: $modelDir\config.json. Remove -SkipModel or put a complete checkpoint there."
  }
  Invoke-Checked 'config patch' { & $nativePython (Join-Path $RepoRoot 'scripts\patch_model_config.py') $modelDir }
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
  Write-Step 'STEP 5/6 register scheduled tasks'
  Invoke-RegisterTasks -ResolvedMode 'native' -NativePython $nativePython -NativeModel $modelDir
}

if (-not $NoAutoStart) {
  Write-Step 'STEP 6/6 start service and wait for /health'
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
