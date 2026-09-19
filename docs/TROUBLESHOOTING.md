# 故障排查手册（TROUBLESHOOTING）

按"症状 → 原因 → 处理"组织。先跑一条命令定位：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\windows\health.ps1
```

输出 `HEALTH_OK` 表示服务正常；失败时按下面的条目对症处理。

---

## 1. WSL dxg 失效（GPU 在 WSL 里"消失"）

**症状**
- `deploy/wsl/install.sh` 报 `/dev/dxg is missing`
- WSL 内 `nvidia-smi` 报错、超时或直接不存在
- 服务日志出现 `CUDA driver` / `dxg` 相关错误，之前一直正常

**背景**：WSL2 通过 `/dev/dxg` 设备直通 GPU。Windows 侧 NVIDIA 驱动**静默自动升级**
（已发生过的实例：驱动被自动升到 616.64）后，旧 WSL 实例的 dxg 通道可能直接失效，
症状就是上面这些，而且重启 WSL 内的进程救不回来。

**处理（按顺序试）**

```powershell
# 1) 完整重启 WSL 虚拟机（Windows PowerShell）
wsl --shutdown
# 等 8 秒以上，重新进入 WSL 再试 nvidia-smi
wsl -d Ubuntu -- nvidia-smi
```

2. 仍失败 → 重启 Windows（多数情况到这一步就好了）。
3. 仍失败 → 检查/回滚驱动：
   ```powershell
   nvidia-smi --query-gpu=driver_version --format=csv,noheader
   ```
   驱动正常应 ≥ 550（CUDA 12.8 wheel 的要求）。若刚被静默升级后异常，用 GeForce
   Experience 或设备管理器回滚；或在 NVIDIA 官网装干净版本并勾选"执行清洁安装"。
4. 恢复后**重新跑一遍** `deploy\windows\install.ps1 -Mode wsl -SkipModel`，
   再 `start.ps1`，因为 WSL 重启后计划任务里的旧 API 进程已不在。

**预防**：`install.ps1` 已内置 `/dev/dxg` 与 `nvidia-smi` 前置检查，坏了会在安装
最初 30 秒内明确报错，不会再装到一半才失败。建议在公司的电脑上把 NVIDIA 驱动
自动更新关掉（GeForce Experience → 设置 → 关闭"自动下载驱动"）。

---

## 2. 端口冲突（9000 / 7860 / 7000）

**症状**
- 9000 转发器起不来，或 health 一直是连接拒绝
- 安装器报 `Port 9000 is already used by PID ...`
- Python 报 `WinError 10013`（绑定被拒绝，但看不到占用进程）

**处理**

```powershell
# 谁占着 9000？
Get-NetTCPConnection -LocalPort 9000 -State Listen |
  ForEach-Object { (Get-CimInstance Win32_Process -Filter "ProcessId=$($_.OwningProcess)").CommandLine }
```

- 显示是旧 `tcpproxy.py` / `breeze_infer.api` → 新版安装器会自动停掉它；手动处理：
  `Stop-Process -Id <pid> -Force`
- 是别的程序 → 要么停掉它，要么换端口：`install.ps1 -Port 9001`（之后所有
  health/client 命令都用 9001）。
- 报 `WinError 10013` 但 `Get-NetTCPConnection` 查不到进程：该端口落在 Windows
  Hyper-V 的**动态保留端口段**内（`netsh interface ipv4 show excludedportrange protocol=v4`
  可见）。换一个不在段内的端口是唯一稳妥解法。

**WSL 侧 7860**：若 `run.sh` 报 "refusing to start a second listener"，说明有僵尸
进程或别的程序占着 7860：

```bash
pgrep -af breeze_infer   # 有旧进程就 kill
ss -ltnp | grep 7860
```

---

## 3. RTF 劣化（生成比实时慢、首字节明显变慢）

**基线**：RTX 4090 + `--fast-all` 实测 RTF ≈ 0.77–0.83、首音频约 80 ms。
RTF > 1（比实时慢）就不正常。

**按可能性排查**

1. **没跑在 fast-all**：native Windows eager 模式本来只有 RTF ≈ 4（约实时 0.25 倍速），
   这是预期不是故障。确认模式：
   ```powershell
   Get-ScheduledTask -TaskName 'Breeze TTS WSL'   # 存在且 Running = WSL fast-all 路径
   ```
2. **CUDA graph / inductor 缓存丢了**：WSL 重启会清 `/tmp`。启动脚本已把缓存重定向到
   `/opt/breeze-tts-data`（持久化），但如果你手动在 shell 里启动且没 source
   `breeze.env`，首次请求会重新编译 3–10 分钟——先等满 10 分钟再判定。
3. **显存被挤**：fast-all 占约 21.5 GiB。同一台机器上另开了第二个模型/游戏/浏览器
   大页面会掉帧：
   ```bash
   nvidia-smi   # 看 memory.used 和占用进程
   ```
   24 GB 卡**绝不要**同时跑第二个 Breeze 实例。
4. **懒加载在起作用**：空闲 120 秒（`BREEZE_IDLE_TIMEOUT`）后模型自动卸载省显存，
   下一句话要等约 50 秒重载——这是设计行为。不想要空闲卸载就把
   `BREEZE_IDLE_TIMEOUT` 设成 `0`（见 CONFIG.md）。
5. **走了读超时被断开的假象**：懒加载期间客户端 10 秒断连 = 转发器版本过旧
   （新 `tcpproxy.py` 建连后已取消读超时）。`git pull` 后重跑安装器更新它。

---

## 4. WSL 重启后转发失效（连接拒绝 / 9000 无响应）

**原因**：WSL2 每次重启可能换 NAT IP；9000 转发器（`tcpproxy.py`）对每个新连接
动态解析 WSL IP，但前提是**两个计划任务都在跑**。

**处理**

```powershell
# 任务在不在、状态对不对
Get-ScheduledTask -TaskName 'Breeze TTS WSL', 'Breeze TTS PortProxy' |
  Format-Table TaskName, State
# 不在跑就拉起来
powershell -ExecutionPolicy Bypass -File .\deploy\windows\start.ps1
```

- `Breeze TTS PortProxy` 缺失/停止 → `Start-ScheduledTask -TaskName 'Breeze TTS PortProxy'`
- 任务存在但反复失败 → 看转发器日志 `Get-Content <repo>\data\breeze-proxy.log -Tail 50`
- WSL 里 API 进程死了 → `wsl -d Ubuntu -u root -- bash /opt/breeze-tts-local-windows/deploy/wsl/run.sh`（前台验证用），
  正常运行仍应靠计划任务。
- 临时手动验证 WSL 内 API 活着：
  ```powershell
  wsl -d Ubuntu -u root -- curl -s http://127.0.0.1:7860/health
  ```

> 为什么不用 `netsh portproxy`：它把 WSL IP 写死成规则，WSL 重启换 IP 后必挂；
> `tcpproxy.py` 每连接动态解析，重启后自动恢复。

---

## 5. 懒加载期间请求被 10 秒掐断（RemoteDisconnected）

**症状**：空闲一段时间后第一句合成总在约 10 秒断开，之后正常。

**原因**：模型懒加载首字节可能要 ~50 秒。旧版转发器 `connect(timeout=10)` 的超时
被继承到读 socket，50 秒 > 10 秒就断。

**处理**：确认 `deploy/windows/tcpproxy.py` 是仓库当前版本（`connect_wsl()` 里
`settimeout(None)`），然后重启转发器：
`Stop-ScheduledTask 'Breeze TTS PortProxy'` → `Start-ScheduledTask 'Breeze TTS PortProxy'`。

---

## 6. 模型下载失败 / 慢

**症状**：`download_model.py` 超时、连接重置。

**处理**
- 国内网络保持默认 `--hf-endpoint https://hf-mirror.com`（安装器默认即是）；
- 安装器在镜像失败时自动重试 `huggingface.co`；手动重跑安装器即可——
  `huggingface_hub` 的 `snapshot_download` 支持**断点续传**，重跑不会从头下载；
- 代理环境注意：给 Python/PowerShell 设置的代理必须放行 `hf-mirror.com`，
  否则镜像也连不上；
- 磁盘满：模型 ~7.7 GB，安装器要求目标盘 ≥ 20 GB 空闲，否则在最开始就报错。

---

## 7. 注册计划任务 / 防火墙失败

- `Register-ScheduledTask` 报权限错误 → 用**管理员** PowerShell 重跑安装器。
- 防火墙规则创建失败的警告（非管理员）→ 只影响**局域网其他设备**访问 9000，
  本机 `127.0.0.1` 不受影响；需要局域网访问就以管理员重跑一次安装器。
- 任务注册成功但登录后没自启 → 计划任务触发器是"At log on <你的用户>"；
  确认是用安装时那个 Windows 账户登录的。

---

## 8. pip / apt 失败

- pip 对 SJTU 镜像失败 → 安装器自动回退 `download.pytorch.org`；若两条路都不通，
  手动指定可达的镜像：`install.ps1 -TorchIndexUrl <url>`。
- `apt-get update` 报 GPG/网络错误 → WSL 内 DNS 抽风是常见根因：
  ```bash
  # 临时修复
  echo "nameserver 223.5.5.5" | sudo tee /etc/resolv.conf
  ```
- 公司代理环境：WSL 内 apt/pip 不自动继承 Windows 代理，需要时在 WSL 里
  `export http_proxy=... https_proxy=...` 后再跑安装脚本。

---

## 9. 首次启动 10 分钟不健康

第一次启动要下载后编译 CUDA graph + inductor 缓存，**3–10 分钟属正常**。
判定标准不是"过 1 分钟没好"，而是看日志有没有在动：

```powershell
wsl -d Ubuntu -u root -- tail -f /opt/breeze-tts-data/logs/breeze-api.log
```

日志持续滚动（compiling / capturing / warmup）就继续等；`install.ps1` 本身会
最多等 10 分钟，超时只是**警告**不是失败——服务可能仍在后台完成预热。
