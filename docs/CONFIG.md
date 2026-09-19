# 配置参考（CONFIG）

所有配置项、密钥文件格式和性能档位的权威说明。改之前不用读代码。

## 1. 配置是怎么生效的

三层，越往下优先级越低（上层覆盖下层）：

1. **命令行参数**（如 `install.ps1 -Port 9001`）
2. **环境变量**（`BREEZE_*`、`HF_ENDPOINT` 等）
3. **安装器写入的 `breeze.env`**（WSL 模式位于 `/opt/breeze-tts-data/breeze.env`，权限 600）

`deploy/wsl/run.sh` 启动时会自动 source `breeze.env`；想临时覆盖某项，直接
`BREEZE_IDLE_TIMEOUT=0 bash run.sh` 或编辑 `breeze.env` 后重启服务。
模板见 `config/.env.example`。

## 2. 运行时环境变量（BREEZE_*）

| 变量 | 默认 | 说明 |
|---|---|---|
| `BREEZE_PORT` | `7860` | API 在 WSL/native 内监听的端口（Windows 对外端口见下文 ProxyPort） |
| `BREEZE_FAST_MODE` | `fast-all` | 性能档位，见第 4 节 |
| `BREEZE_IDLE_TIMEOUT` | `120` | 空闲多少秒后卸载模型释放显存（18.5→4.4 GiB）。`0` = 永不卸载；设短会频繁重载（每次约 50 秒），反而更慢 |
| `BREEZE_GEN_TIMEOUT` | `180` | 单次合成总时长上限（秒），防止卡死永久占用 |
| `BREEZE_GEN_STALL` | `45` | 单次合成无输出多少秒判定 stall（秒） |
| `BREEZE_LOCK_TIMEOUT` | `300` | 请求锁被占多久后 watchdog 强制释放（秒），防取消请求后永久 409 |
| `BREEZE_MODEL_DIR` | 安装器写入 | 模型 checkpoint 目录（含 `config.json`） |
| `BREEZE_REPO_DIR` | 安装器写入 | 仓库在 WSL 内的副本路径 |
| `BREEZE_VENV` | 安装器写入 | Python 虚拟环境路径 |
| `BREEZE_LOG_FILE` | `$DATA_DIR/logs/breeze-api.log` | API 日志位置 |
| `TORCHINDUCTOR_CACHE_DIR` | `$DATA_DIR/torchinductor` | inductor 编译缓存；**必须放 /opt 等持久目录**，放 /tmp 会让 WSL 重启后重新编译 3–10 分钟 |
| `TRITON_CACHE_DIR` | `$DATA_DIR/triton` | triton 缓存，同上 |

## 3. 网络 / 镜像参数（install.ps1 参数）

| install.ps1 参数 | 默认（国内） | 换成 |
|---|---|---|
| `-HfEndpoint` | `https://hf-mirror.com` | 海外：`https://huggingface.co` |
| `-TorchIndexUrl` | `https://mirror.sjtu.edu.cn/pytorch-wheels/cu128` | 海外：`https://download.pytorch.org/whl/cu128` |
| `-PypiIndexUrl` | `https://pypi.org/simple` | 任何 PyPI 兼容镜像 |
| `-Port` | `9000` | 被占用时换任意空闲端口 |

加固后的安装脚本在镜像不可达时会**自动回退**：PyPI/SJTU 镜像失败 → 官方源；
HF 镜像失败 → 官方站。也可以用上面的参数手动指定。

WSL 模式下这些值会写进 `/opt/breeze-tts-data/breeze.env`（`HF_ENDPOINT` 等），
供日后手动重下模型时使用。

## 4. 性能档位（BREEZE_FAST_MODE）

| 档位 | 命令行 | 显存 | RTF（4090 实测） | 适用 |
|---|---|---|---|---|
| `fast-all`（默认/推荐） | `--fast-all` | ~21.5 GiB | **0.77–0.83**，首音频 ~80 ms | 实时对话、24 GB 卡 |
| `partial` | `--fast-text-encoder --fast-backbone-prefill --fast-backbone-decode --fast-codec --no-fast-depth-decoder` | 略低 | 介于两者 | fast-all 显存吃紧时的折中 |
| `eager` | `--no-fast-all` | ~7.8 GiB | ~4（即约 0.25 倍实时） | 无 WSL2 / 小显存 / 批量离线生成 |

要点：
- `fast-all` 依赖 Linux Triton + CUDA graphs，**只能在 WSL2 跑**；native Windows
  会被强制用 eager（脚本已处理，`disable_compile=True`）。
- 24 GB 卡上 `fast-all` **禁止双实例**（显存互抢必崩）。
- 首次启动需要编译 CUDA graph，3–10 分钟属正常；缓存持久化后重启不再编译。

## 5. 端口与转发

```text
客户端 → Windows :9000 (tcpproxy.py，计划任务 "Breeze TTS PortProxy")
       → WSL IP:7860 (breeze_infer.api，计划任务 "Breeze TTS WSL")
```

- WSL IP 每次重启可能变化，转发器**每个连接动态解析**，无需配置。
- native 模式没有转发层，API 直接监听 9000（"Breeze TTS Native" 任务）。
- 对外端口只由 `install.ps1 -Port` 决定，改了它 9000 相关命令都要跟着换。

## 6. 密钥与敏感文件格式

本仓库**不含也不需要**任何 API 密钥——模型完全本地推理。以下文件属于"部署后
由使用者自己管理"，永远不要提交进 git（`.gitignore` 已覆盖）：

| 文件 | 格式 | 说明 |
|---|---|---|
| `secrets.json` | `{"api_token": "..."}` | 可选。设置后所有 `/api/*` 要求 `Authorization: Bearer <token>`；**公网暴露前必须配置**。局域网使用可留空 |
| `voices/*.wav` + `voices/*.txt` | 24 kHz 单声道 WAV + UTF-8 逐字稿 | 声音克隆参考。成对出现、名字对应；txt 必须是音频里逐字内容 |
| `*.pem` / `*.key` | PEM | 若你在前面加 HTTPS 反代，证书放本地，勿提交 |
| `outputs/` | WAV | 生成的音频，本地产物 |

克隆声音的调用方式见 README「声音克隆」一节；参考音频必须 24 kHz 单声道，
逐字稿必须是**音频里实际说出的文字**（不是你想合成的话）。

## 7. 计划任务清单（安装器注册）

| 任务名 | 作用 | 模式 |
|---|---|---|
| `Breeze TTS WSL` | 在 WSL Ubuntu 里启动 `deploy/wsl/run.sh`（API 进程） | wsl |
| `Breeze TTS PortProxy` | 启动 `tcpproxy.py`，9000 → WSL:7860 | wsl |
| `Breeze TTS Native` | 直接在 Windows 跑 API（eager） | native |

任务属性：登录自启（AtLogOn）、无执行时长限制、`StopOnIdleEnd=false`、失败自动
重启 3 次（间隔 1 分钟）。这些属性是长期运维得出的稳定配置，勿改回默认。

## 8. 日志位置

| 日志 | 路径 |
|---|---|
| API（WSL 模式） | `wsl -d Ubuntu -u root -- tail -50 /opt/breeze-tts-data/logs/breeze-api.log` |
| 转发器 | `<repo>\data\breeze-proxy.log` |
| 计划任务最近退出码 | `Get-ScheduledTaskInfo -TaskName 'Breeze TTS WSL'` 的 `LastTaskResult` |
