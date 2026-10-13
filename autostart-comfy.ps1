# autostart-comfy.ps1  --  boot-time launcher + watchdog for a fleet GPU box.
#
# Registered by bootstrap.ps1 as the scheduled task "WaifumasterAutostart"
# (runs at boot, no login required). It:
#   * starts one hidden ComfyUI per GPU (from autostart.config.json),
#   * optionally starts one hidden Ollama per GPU (config "ollama" block,
#     added by add-ollama.ps1 / node-ollama2.ps1) -- same CUDA_VISIBLE_DEVICES
#     pinning pattern, so GPU0 = ComfyUI 'a' + Ollama :11434, GPU1 = ComfyUI 'b' + Ollama :11435,
#   * restarts any instance that dies,
#   * makes sure the cloudflared tunnel service stays running.
#
# Reads C:\waifumaster-autostart\autostart.config.json. ASCII only.
# v2 (2026-09-30): ollama block. Without it the behaviour is exactly v1.
# v3 (2026-10-13): ollama.env = extra environment variables for every Ollama instance
#                  (OLLAMA_CONTEXT_LENGTH, OLLAMA_FLASH_ATTENTION, OLLAMA_KV_CACHE_TYPE ...). Without it = v2.

$ErrorActionPreference = 'SilentlyContinue'
$KitDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$CfgPath = Join-Path $KitDir 'autostart.config.json'
$LogDir  = Join-Path $KitDir 'logs'
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Log($m) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $m"
    Add-Content -Path (Join-Path $LogDir 'autostart.log') -Value $line
}

if (-not (Test-Path $CfgPath)) { Log "FATAL: config not found at $CfgPath"; exit 1 }
$cfg = Get-Content $CfgPath -Raw | ConvertFrom-Json

$WorkDir = $cfg.work_dir
$MainPy  = $cfg.main_py
$Py      = $cfg.python
$PyArgs  = [string]$cfg.py_args
$Extra   = [string]$cfg.extra_args
$Svc     = [string]$cfg.cloudflared_service
$Oll     = $cfg.ollama          # may be $null on boxes without the block

$ollCount = 0
if ($Oll -and $Oll.instances) { $ollCount = @($Oll.instances).Count }
Log "=== launcher start (v3) ===  workdir=$WorkDir  main=$MainPy  py=$Py $PyArgs  instances=$($cfg.instances.Count)  ollama=$ollCount  cloudflared_svc=$Svc"

function Port-Alive([int]$p) {
    try {
        $t = New-Object Net.Sockets.TcpClient
        $iar = $t.BeginConnect('127.0.0.1', $p, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(800)
        if ($ok -and $t.Connected) { $t.Close(); return $true }
        $t.Close(); return $false
    } catch { return $false }
}

function Start-Comfy([int]$gpu, [int]$port) {
    $log = Join-Path $LogDir ("comfy_gpu{0}_{1}.log" -f $gpu, $port)
    # Set CUDA_VISIBLE_DEVICES inside cmd.exe FIRST, then fork python from it so
    # the env var is guaranteed to be inherited (the reliable pattern from
    # start_comfy_fixed.ps1). Output is appended to a per-instance log.
    $inner = "set CUDA_VISIBLE_DEVICES=$gpu&& `"$Py`" $PyArgs `"$MainPy`" --listen 127.0.0.1 --port $port $Extra 1>>`"$log`" 2>>`"$log`""
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $inner" -WorkingDirectory $WorkDir -WindowStyle Hidden
    Log "started ComfyUI  gpu=$gpu  port=$port  log=$log"
}

function Start-Ollama([int]$gpu, [int]$port) {
    # One Ollama per GPU: a single instance only ever puts a model on one card
    # and queues requests on it, so the second card would sit idle. Same
    # cmd.exe env-propagation pattern as ComfyUI. Binds 0.0.0.0 so cloudflared
    # (localhost) and LAN clients both reach it.
    $exe = [string]$Oll.exe
    if (-not $exe -or -not (Test-Path $exe)) { Log "ollama exe not found: '$exe' (config ollama.exe)"; return }
    $log = Join-Path $LogDir ("ollama_gpu{0}_{1}.log" -f $gpu, $port)
    $keep = if ($Oll.keep_alive) { [string]$Oll.keep_alive } else { '30m' }
    $par  = if ($Oll.num_parallel) { [int]$Oll.num_parallel } else { 2 }
    $maxl = if ($Oll.max_loaded) { [int]$Oll.max_loaded } else { 3 }
    $sets = "set CUDA_VISIBLE_DEVICES=$gpu&& set OLLAMA_HOST=0.0.0.0:$port&& set OLLAMA_KEEP_ALIVE=$keep&& set OLLAMA_NUM_PARALLEL=$par&& set OLLAMA_MAX_LOADED_MODELS=$maxl&& "
    if ($Oll.models_dir) { $sets += "set OLLAMA_MODELS=$($Oll.models_dir)&& " }
    if ($Oll.origins)    { $sets += "set OLLAMA_ORIGINS=$($Oll.origins)&& " }
    if ($Oll.env) {
        foreach ($p in $Oll.env.PSObject.Properties) {
            if ($p.Name -match '^[A-Za-z_][A-Za-z0-9_]*$' -and "$($p.Value)" -notmatch '[&|<>^"]') { $sets += "set $($p.Name)=$($p.Value)&& " }
        }
    }
    $inner = $sets + "`"$exe`" serve 1>>`"$log`" 2>>`"$log`""
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $inner" -WorkingDirectory (Split-Path -Parent $exe) -WindowStyle Hidden
    Log "started Ollama  gpu=$gpu  port=$port  parallel=$par  log=$log"
}

function Ensure-Cloudflared() {
    if (-not $Svc) { return }
    $s = Get-Service -Name $Svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne 'Running') {
        Start-Service -Name $Svc -ErrorAction SilentlyContinue
        Log "cloudflared service '$Svc' was $($s.Status) -> started"
    }
}

# Give the network/driver a moment after a cold boot.
Start-Sleep -Seconds 15

while ($true) {
    foreach ($inst in $cfg.instances) {
        if (-not (Port-Alive([int]$inst.port))) {
            Start-Comfy ([int]$inst.gpu) ([int]$inst.port)
            Start-Sleep -Seconds 10
        }
    }
    if ($ollCount -gt 0) {
        foreach ($oi in $Oll.instances) {
            if (-not (Port-Alive([int]$oi.port))) {
                Start-Ollama ([int]$oi.gpu) ([int]$oi.port)
                Start-Sleep -Seconds 6
            }
        }
    }
    Ensure-Cloudflared
    Start-Sleep -Seconds 30
}
