#Requires -Version 5.0
<#
.SYNOPSIS
    启动 WhisperX 转写（wanggang-run-oss）。实际逻辑按 PowerShell 7 执行。
.DESCRIPTION
    无参运行后交互选择：样例转写或指定音频。单选默认样例。
.PARAMETER Mode
    direct = 本机直接运行；docker = 不支持（本项目无 compose）。
.PARAMETER Port
    保留参数；本 CLI 不使用端口。
.PARAMETER Service
    内部用：跳过菜单，直接启动指定 Id（sample / custom）。
.PARAMETER Audio
    自定义音频路径（Service=custom 时可用）。
.PARAMETER Model
    Whisper 模型名，默认 small（样例）或由菜单内覆盖。
#>
[CmdletBinding()]
param(
    [ValidateSet('direct', 'docker')]
    [string]$Mode = 'direct',

    [int]$Port = 0,

    [string]$Service = '',

    [string]$Audio = '',

    [string]$Model = ''
)

$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if (-not $pwsh) {
        throw '未找到 PowerShell 7 (pwsh)。请先全局安装：winget install --id Microsoft.PowerShell -e'
    }
    $argList = @('-NoProfile', '-File', $PSCommandPath)
    foreach ($key in $PSBoundParameters.Keys) {
        $argList += "-$key"
        $val = $PSBoundParameters[$key]
        if ($val -isnot [System.Management.Automation.SwitchParameter]) {
            $argList += [string]$val
        }
    }
    & $pwsh.Source @argList
    exit $LASTEXITCODE
}

Set-Location $PSScriptRoot

$FfmpegBin = 'E:\Programs\ffmpeg-master-latest-win64-gpl\bin'
if (Test-Path $FfmpegBin) {
    $env:Path = "$FfmpegBin;$env:Path"
} else {
    Write-Warning "未找到本机 ffmpeg：$FfmpegBin"
}

if (-not $env:HF_ENDPOINT) {
    $env:HF_ENDPOINT = 'https://hf-mirror.com'
}
if (-not $env:UV_INDEX_URL) {
    $env:UV_INDEX_URL = 'https://pypi.tuna.tsinghua.edu.cn/simple'
}

function Show-GpuStatus {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) {
        Write-Warning '未检测到 nvidia-smi，跳过 GPU 检查。'
        return
    }
    Write-Host '=== GPU 状态 ===' -ForegroundColor Cyan
    & nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu --format=csv
}

function Test-PortBusy {
    param([int]$TargetPort)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $TargetPort)
        $listener.Start()
        return $false
    } catch {
        return $true
    } finally {
        if ($null -ne $listener) { $listener.Stop() }
    }
}

function Get-FreePort {
    param(
        [int]$StartPort,
        [int]$MaxTries = 50
    )
    if ($StartPort -lt 1) { $StartPort = 1024 }
    $end = $StartPort + $MaxTries - 1
    if ($end -gt 65535) { $end = 65535 }
    $p = $StartPort
    while ($p -le $end) {
        if (-not (Test-PortBusy -TargetPort $p)) {
            if ($p -ne $StartPort) {
                Write-Host "端口 $StartPort 已占用，顺延到 $p" -ForegroundColor Yellow
            }
            return $p
        }
        $p++
    }
    throw "从 $StartPort 起连续探测均被占用，放弃。"
}

function Select-ServicesInteractive {
    param([object[]]$AllServices)

    if ($AllServices.Count -eq 0) {
        throw '未配置 $Services，请按项目改写模板。'
    }
    if ($AllServices.Count -eq 1) {
        Write-Host "仅一个服务，直接启动：$($AllServices[0].Label)" -ForegroundColor Cyan
        return @($AllServices[0])
    }

    Write-Host ''
    Write-Host '=== 启动哪些任务？===' -ForegroundColor Cyan
    for ($i = 0; $i -lt $AllServices.Count; $i++) {
        $svc = $AllServices[$i]
        $portHint = if ($svc.NeedsPort) { "端口起点 $($svc.PreferredPort)" } else { 'CLI，无端口' }
        Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $svc.Label, $portHint)
    }
    Write-Host ("  [{0}] 全部开" -f ($AllServices.Count + 1))
    Write-Host '  [0] 取消'
    Write-Host ''

    $defaultChoice = '1'
    $raw = Read-Host "请选择（可多选，逗号分隔，如 1,2；默认 $defaultChoice）"
    if ([string]::IsNullOrWhiteSpace($raw)) { $raw = $defaultChoice }

    if ($raw.Trim() -eq '0') {
        throw '已取消启动。'
    }

    $allIndex = $AllServices.Count + 1
    $parts = $raw.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    $selected = [System.Collections.Generic.List[object]]::new()

    foreach ($part in $parts) {
        $n = 0
        if (-not [int]::TryParse($part, [ref]$n)) {
            throw "无效选项：$part"
        }
        if ($n -eq $allIndex) {
            return @($AllServices)
        }
        if ($n -lt 1 -or $n -gt $AllServices.Count) {
            throw "选项超出范围：$n"
        }
        $selected.Add($AllServices[$n - 1])
    }

    if ($selected.Count -eq 0) {
        throw '未选择任何服务。'
    }

    $byId = [ordered]@{}
    foreach ($s in $selected) { $byId[$s.Id] = $s }
    return @($byId.Values)
}

function Assert-GpuOkForSelection {
    param([object[]]$Selected)

    $gpuServices = @($Selected | Where-Object { $_.UsesGpu })
    if ($gpuServices.Count -le 1) { return }

    $labels = ($gpuServices | ForEach-Object { $_.Label }) -join ', '
    Write-Host ''
    Write-Host "已选多个占卡任务：$labels" -ForegroundColor Yellow
    Write-Host '16GB 显存下同时加载多个推理任务容易 OOM。请确认剩余显存足够，或改回只开一个。' -ForegroundColor Yellow
    $confirm = Read-Host '仍要继续？[y/N]'
    if ($confirm -notmatch '^[yY]') {
        throw '已取消：多服务占卡未确认。'
    }
}

function Ensure-SampleAudio {
    $samplesDir = Join-Path $PSScriptRoot 'samples'
    $samplePath = Join-Path $samplesDir 'sample.wav'
    if (Test-Path $samplePath) { return $samplePath }

    New-Item -ItemType Directory -Path $samplesDir -Force | Out-Null
    $flac = Join-Path $samplesDir 'jfk.flac'
    $url = 'https://github.com/openai/whisper/raw/main/tests/jfk.flac'
    Write-Host "下载样例音频：$url" -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $url -OutFile $flac -UseBasicParsing -TimeoutSec 60
    } catch {
        throw "样例音频下载失败：$($_.Exception.Message)。请手动放到 $samplePath"
    }
    if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) {
        throw "已下载 $flac，但找不到 ffmpeg，无法转 wav。"
    }
    & ffmpeg -y -i $flac $samplePath
    if (-not (Test-Path $samplePath)) {
        throw "ffmpeg 转换失败：$samplePath"
    }
    return $samplePath
}

$Services = @(
    [pscustomobject]@{
        Id            = 'sample'
        Label         = '样例转写（JFK / small / CUDA）'
        PreferredPort = 0
        NeedsPort     = $false
        UsesGpu       = $true
    }
    [pscustomobject]@{
        Id            = 'custom'
        Label         = '指定音频转写'
        PreferredPort = 0
        NeedsPort     = $false
        UsesGpu       = $true
    }
)

function Start-ProjectService {
    param(
        [Parameter(Mandatory)]
        [object]$Service,

        [Parameter(Mandatory)]
        [string]$RunMode,

        [int]$ListenPort = 0
    )

    if ($RunMode -eq 'docker') {
        throw '本项目未提供 Docker Compose，请用 -Mode direct。'
    }

    $venvPython = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
    if (-not (Test-Path $venvPython)) {
        throw "未找到 $venvPython。请先在本目录手动执行：uv sync --all-extras --dev（见 RUN.md）。"
    }
    & $venvPython -c "import torch" 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "当前 .venv 缺少依赖（如 torch）。空壳 .venv 不能用。请手动执行：uv sync --all-extras --dev（见 RUN.md），完成前不要启动。"
    }

    $outDir = Join-Path $PSScriptRoot 'output'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    function Invoke-WhisperX {
        param([Parameter(Mandatory)][string[]]$CliArgs)
        # 绕过可能损坏的 uv console-script trampoline；用仓库内包 + venv python。
        & $venvPython -c "import sys; sys.path.insert(0, r'$PSScriptRoot'); from whisperx.__main__ import cli; sys.argv=['whisperx']+sys.argv[1:]; raise SystemExit(cli() or 0)" @CliArgs
    }

    switch ($Service.Id) {
        'sample' {
            $audioPath = Ensure-SampleAudio
            $modelName = if ($Model) { $Model } else { 'small' }
            Write-Host "转写样例：$audioPath  model=$modelName" -ForegroundColor Cyan
            Invoke-WhisperX -CliArgs @(
                $audioPath,
                '--model', $modelName,
                '--device', 'cuda',
                '--compute_type', 'float16',
                '--language', 'en',
                '--batch_size', '8',
                '--output_dir', $outDir
            )
            if ($LASTEXITCODE -ne 0) { throw "whisperx 退出码 $LASTEXITCODE" }
            Write-Host "完成。结果目录：$outDir" -ForegroundColor Green
            return
        }
        'custom' {
            $audioPath = $Audio
            if (-not $audioPath) {
                $audioPath = Read-Host '请输入音频文件路径'
            }
            if (-not $audioPath -or -not (Test-Path -LiteralPath $audioPath)) {
                throw "音频不存在：$audioPath"
            }
            $modelName = if ($Model) { $Model } else { 'small' }
            Write-Host "转写：$audioPath  model=$modelName" -ForegroundColor Cyan
            Invoke-WhisperX -CliArgs @(
                $audioPath,
                '--model', $modelName,
                '--device', 'cuda',
                '--compute_type', 'float16',
                '--batch_size', '8',
                '--output_dir', $outDir
            )
            if ($LASTEXITCODE -ne 0) { throw "whisperx 退出码 $LASTEXITCODE" }
            Write-Host "完成。结果目录：$outDir" -ForegroundColor Green
            return
        }
        default {
            throw "未知服务 Id：$($Service.Id)"
        }
    }
}

Show-GpuStatus

if ($Service) {
    $match = @($Services | Where-Object { $_.Id -eq $Service })
    if ($match.Count -eq 0) {
        throw "未知服务 Id：$Service。可选：$($Services.Id -join ', ')"
    }
    $chosen = $match
} else {
    $chosen = Select-ServicesInteractive -AllServices $Services
    Assert-GpuOkForSelection -Selected $chosen
}

$multi = $chosen.Count -gt 1

if ($multi) {
    $started = @()
    foreach ($svc in $chosen) {
        $listen = 0
        if ($svc.NeedsPort) {
            $listen = Get-FreePort -StartPort $svc.PreferredPort
            Write-Host "$($svc.Label) 使用端口 $listen" -ForegroundColor Cyan
        }

        $argList = [System.Collections.Generic.List[string]]::new()
        $argList.AddRange([string[]]@('-NoProfile', '-File', $PSCommandPath, '-Mode', $Mode, '-Service', $svc.Id))
        if ($listen -gt 0) {
            $argList.Add('-Port')
            $argList.Add("$listen")
        }
        if ($Model) {
            $argList.Add('-Model')
            $argList.Add($Model)
        }
        if ($Audio -and $svc.Id -eq 'custom') {
            $argList.Add('-Audio')
            $argList.Add($Audio)
        }

        $p = Start-Process -FilePath 'pwsh' -ArgumentList $argList -PassThru -WorkingDirectory $PSScriptRoot
        $started += [pscustomobject]@{ Id = $svc.Id; Label = $svc.Label; Port = $listen; Pid = $p.Id }
        Write-Host "已后台启动 $($svc.Label) PID=$($p.Id)" -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '=== 已启动 ===' -ForegroundColor Cyan
    foreach ($s in $started) {
        $portInfo = if ($s.Port -gt 0) { " port=$($s.Port)" } else { '' }
        Write-Host ("- {0}{1} pid={2}" -f $s.Label, $portInfo, $s.Pid)
    }
    Write-Host '各任务在独立进程中运行；结束请自行停对应 PID。' -ForegroundColor Yellow
    return
}

$svc = $chosen[0]
$listen = 0
if ($svc.NeedsPort) {
    $startPort = $svc.PreferredPort
    if ($Port -gt 0) { $startPort = $Port }
    $listen = Get-FreePort -StartPort $startPort
    Write-Host "$($svc.Label) 使用端口 $listen" -ForegroundColor Cyan
}

Start-ProjectService -Service $svc -RunMode $Mode -ListenPort $listen