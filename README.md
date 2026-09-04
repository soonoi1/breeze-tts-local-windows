# Breeze TTS Local Windows

> 一键把 Breeze TTS 2 本地模型部署到 Windows NVIDIA GPU 电脑，提供流式语音生成 API。
>
> This repository packages the official Breeze TTS 2 PyTorch inference code together with a
> reproducible Windows/WSL2 deployment layer. It intentionally does **not** contain model
> weights, API keys, certificates, or anyone's reference voice recording.

## 你要做什么

在公司 Windows 电脑上打开 PowerShell，执行：

```powershell
git clone https://github.com/soonoi1/breeze-tts-local-windows.git
cd breeze-tts-local-windows
powershell -ExecutionPolicy Bypass -File .\deploy\windows\install.ps1
```

安装器会：

1. 检测 NVIDIA GPU、Python 和 WSL2；
2. 如果已有可用 Ubuntu WSL2 且显存约 24 GB，默认部署 Linux `--fast-all`；
3. 如果没有 WSL2，自动走 native Windows eager 模式（速度较慢但不需要重启）；
4. 安装 CUDA 版 PyTorch、Breeze 依赖和 Linux Triton（WSL2 模式）；
5. 从 Hugging Face 下载 `BreezeBlue/Breeze-TTS-2` 模型（约 7.7 GB）；
6. 自动修补 Windows 不支持 `flash_attention_2` 的模型配置；
7. 注册登录自启任务；
8. 启动服务并等待 `/health` 变为 `200`。

如果公司电脑已经装好 WSL2，推荐明确指定：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\windows\install.ps1 -Mode wsl
```

如果只允许原生 Windows：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\windows\install.ps1 -Mode native
```

> 第一次下载模型和 WSL2 fast-all 的 CUDA graph 预热需要较长时间。安装器会等待健康检查，
> 不要因为前几分钟没有声音就重复启动第二个实例。

## 安装完成后的 API

默认通过 Windows 主机的 `9000` 端口访问：

- `GET http://127.0.0.1:9000/health`
- `POST http://127.0.0.1:9000/v1/audio/speech`
- 返回：单声道、24 kHz、16-bit little-endian PCM 流
- 表单字段：`text`、`instruction`、`cfg_scale`、`seed`
- 声音克隆：`ref_audio` 和 `ref_text` 必须同时提供

本机生成 WAV：

```powershell
python .\examples\http_client.py `
  --url http://127.0.0.1:9000 `
  --text "你好，这是公司电脑上的本地 Breeze TTS。" `
  --instruction "一位温和、清晰、自然的中文助手。" `
  --cfg-scale 4 `
  --output .\outputs\hello.wav
```

Linux/WSL 中也可以直接调用：

```bash
python examples/http_client.py \
  --url http://127.0.0.1:9000 \
  --text "Hello from local Breeze TTS" \
  --output outputs/hello.wav
```

克隆一个声音时，参考音频与逐字稿必须匹配：

```powershell
python .\examples\http_client.py `
  --text "这是一段新的语音。" `
  --ref-audio .\voices\my-reference.wav `
  --ref-text "参考音频中实际说出的完整文字。" `
  --output .\outputs\clone.wav
```

## 服务管理

```powershell
# 查看/启动/停止/重启计划任务
powershell -ExecutionPolicy Bypass -File .\deploy\windows\health.ps1
powershell -ExecutionPolicy Bypass -File .\deploy\windows\start.ps1
powershell -ExecutionPolicy Bypass -File .\deploy\windows\stop.ps1
```

默认任务名：

- `Breeze TTS WSL`：WSL2 中的模型 API
- `Breeze TTS PortProxy`：Windows 9000 → 当前 WSL2 IP:7860 的 TCP 转发
- `Breeze TTS Native`：native 模式时直接运行的 Windows API

更新仓库代码后：

```powershell
git pull
powershell -ExecutionPolicy Bypass -File .\deploy\windows\install.ps1 -Mode auto -SkipModel
```

`-SkipModel` 只跳过模型下载，不跳过依赖安装和服务注册；仅当模型目录已经存在时使用。

## 选择下载镜像

脚本默认采用当前已验证的网络设置：

- Hugging Face：`https://hf-mirror.com`
- PyTorch CUDA 12.8：`https://mirror.sjtu.edu.cn/pytorch-wheels/cu128`
- 其他 Python 包：PyPI

公司电脑网络不同，可以覆盖：

```powershell
powershell -ExecutionPolicy Bypass -File .\deploy\windows\install.ps1 `
  -TorchIndexUrl "https://download.pytorch.org/whl/cu128" `
  -PypiIndexUrl "https://pypi.org/simple" `
  -HfEndpoint "https://huggingface.co"
```

## 两种运行模式

### WSL2 `--fast-all`（推荐）

Linux Triton + CUDA graphs 是 Breeze 的实时路径。已验证的 RTX 4090 基线约为：首音频
80 ms 左右、RTF 约 0.77–0.83；fast-all 会占用约 21.5 GiB 显存，24 GB 显卡上不要同时
启动第二个模型实例。

WSL2 安装需要 Windows 的 `VirtualMachinePlatform` 和 `Windows Subsystem for Linux`。
如果这两个功能不存在，`-Mode wsl` 会明确停止并提示重启；`-Mode auto` 则不会强行重启
公司的电脑，而是回退到 native eager。

### native Windows eager（回退）

不依赖 WSL2，使用 `--no-fast-all` 和 eager attention。RTX 4090 上已有实测约 7.8 GiB
显存，但速度约为实时的 0.25 倍，适合验证和非实时批量生成，不适合追求自然的实时对话。

## 目录约定

```text
breeze-tts-local-windows/
├── breeze_infer/                 # 官方推理 API + 本地 idle/watchdog 补丁
├── models/                       # 官方模型实现 + Windows 可用的 CUDA graph 补丁
├── infer.py                      # 单文件 WAV CLI
├── examples/http_client.py       # 无第三方客户端依赖的 HTTP → WAV 示例
├── scripts/download_model.py     # 可重复下载模型
├── scripts/patch_model_config.py # eager attention 配置补丁
├── deploy/windows/               # 一键安装、计划任务、健康检查、转发器
├── deploy/wsl/                   # WSL2 依赖、启动、停止脚本
├── config/.env.example           # 可覆盖的运行参数
└── voices/                       # 本地参考音频目录（仅保留 .gitkeep）
```

## 已包含的必要本地补丁

1. `breeze_infer/runtime.py` 默认设置 `disable_compile=True`，避免 native Windows
   误触发不兼容的 Triton/torch.compile。
2. 模型配置下载后自动把 `flash_attention_2` 改成 `eager`。
3. `models/text_encoder_graph.py` 允许 voice clone 的新文本长度按需捕获 CUDA graph，
   不会因为 warmup 后遇到新长度而报错。
4. API 支持 `BREEZE_IDLE_TIMEOUT=120`：空闲 120 秒卸载 GPU 模型，下次请求自动加载；
   加载在后台线程中执行，避免阻塞 HTTP accept loop。
5. API 有生成超时、无输出 stall 保护，以及带 owner id 的 request lease，避免取消请求
   后永久返回 `409`。
6. Windows 转发器只对 `connect()` 设置 10 秒建连超时，连接成功后立即
   `settimeout(None)`；模型懒加载首字节可能需要约 50 秒，不能让读 socket 继承 10 秒超时。

## 给公司电脑上的 AI 的操作指令

如果你让 Codex/Claude/其他 AI 读取这个仓库，请让它遵循：

1. 先读本 README 和 `docs/architecture.md`；
2. 直接运行 `deploy/windows/install.ps1`，不要手写绝对路径；
3. 先运行 `health.ps1`，确认旧服务状态后再重启；
4. 不要把 `.env`、`secrets.json`、证书、`*.safetensors`、`voices/` 下的真实录音提交；
5. 不要启动第二个 Breeze 实例，24 GB 显存会互相争抢；
6. 生成失败时先看 `health.ps1` 和任务状态，不要重复安装模型。

## 许可证和模型使用限制

本仓库中的推理源代码来自 BreezeBlue 官方仓库，源代码采用 Apache License 2.0；模型权重、
派生模型和自托管输出受 BreezeBlue 的 Research and Non-Commercial License 约束。请在
使用前阅读根目录 `LICENSE` 以及模型仓库的许可证，不要把研究/非商业权重用于未经许可的
商业服务。

- Upstream source: https://github.com/breezeblue-ai/breeze-tts
- Model: https://huggingface.co/BreezeBlue/Breeze-TTS-2
- Upstream baseline commit: `ca632ce6c4d05f7985da4eab29b1a5d445b43f7b`
