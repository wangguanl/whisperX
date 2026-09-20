# 运行命令

- 项目：whisperX（语音转写 + 字级时间戳 + 可选说话人分离）
- 生成时间：2026-09-08
- 运行方式：直接运行（`uv` + 本地 CLI，无 Docker）
- 硬件评估：**满足**
  - 官方：faster-whisper large-v2 约需 <8GB 显存（beam_size=5）；README 建议 CUDA Toolkit 12.8
  - 本机：RTX 4080 16GB；评估时已用约 3.5GB，剩余约 12.8GB，足够 large-v2 / float16
  - 磁盘：E: 剩余约 383GB；内存充足
  - 缺口：系统未装 CUDA Toolkit（`nvcc` 不在 PATH）。推理走 PyTorch `cu128` 轮子自带运行时，一般可跑；若编译扩展失败再装 [CUDA 12.8](https://developer.nvidia.com/cuda-12-8-1-download-archive)

## 环境准备

```powershell
# ffmpeg（本机已有）
$env:Path = "E:\Programs\ffmpeg-master-latest-win64-gpl\bin;$env:Path"

# 国内源：PyPI 用清华；Hugging Face 官方超时，用镜像
$env:UV_INDEX_URL = "https://pypi.tuna.tsinghua.edu.cn/simple"
$env:HF_ENDPOINT = "https://hf-mirror.com"

# 开发安装（仓库已有 uv.lock；requires-python <3.14，用 3.10）
cd E:\AI\local-voice\whisperX
uv sync --all-extras --dev
```

说话人分离（`--diarize`）需 Hugging Face token，并在网页接受 [pyannote/speaker-diarization-community-1](https://huggingface.co/pyannote/speaker-diarization-community-1) 协议。无 token 时用默认转写路径即可。

## 启动

- 推荐：`pwsh -NoProfile -File .\start.ps1`
- 说明：交互菜单可选「样例转写」或「指定音频」；默认样例转写（small + float16 + CUDA）
- 等价手动命令：

```powershell
$env:Path = "E:\Programs\ffmpeg-master-latest-win64-gpl\bin;$env:Path"
$env:HF_ENDPOINT = "https://hf-mirror.com"
cd E:\AI\local-voice\whisperX

# 样例（首次会下载 whisper / 对齐模型）
uv run whisperx .\samples\sample.wav --model small --device cuda --compute_type float16 --language en --batch_size 8 --output_dir .\output

# 自定义音频
uv run whisperx "D:\path\to\audio.wav" --model large-v2 --device cuda --compute_type float16 --batch_size 8 --output_dir .\output

# 说话人分离（需 HF token）
uv run whisperx "D:\path\to\audio.wav" --model large-v2 --diarize --hf_token $env:HF_TOKEN --device cuda --compute_type float16 --batch_size 8 --output_dir .\output
```

## 验证

- CLI 退出码 0
- `.\output\` 下生成 `.json` / `.srt` / `.txt` 等，文本非空
- 无 CUDA OOM / 致命 traceback

## 备注

- 端口：CLI 工具，无服务端口
- 镜像：`UV_INDEX_URL=清华`；`HF_ENDPOINT=https://hf-mirror.com`；PyTorch 索引仍用 `https://download.pytorch.org/whl/cu128`（可达）
- ffmpeg：`E:\Programs\ffmpeg-master-latest-win64-gpl\bin`
- 显存紧张时：`--batch_size 4`、`--model base`、`--compute_type int8`（降级需你确认后再用）
- 当前 GPU 上另有 `python.exe` 占卡，启动前可用 `nvidia-smi` 再看一眼

## 审计备注（2026-09-09）
- 路径已改为 `E:\AI\local-voice\whisperX`。
- 当前 `.venv` 几乎为空（缺 torch 等），**启动前需手动**在本目录执行：`uv sync --all-extras --dev`（本审计未自动安装依赖）。
- `start.ps1` 会检测 torch；未就绪则立刻报错。就绪后用 venv python + 本地 `whisperx` 包启动，不依赖 uv trampoline。
