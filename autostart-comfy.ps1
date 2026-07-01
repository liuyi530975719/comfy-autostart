# autostart-comfy.ps1  --  boot-time launcher + watchdog for a fleet GPU box.
#
# Registered by bootstrap.ps1 as the scheduled task "WaifumasterAutostart"
# (runs at boot, no login required). It:
#   * starts one hidden ComfyUI per GPU (from autostart.config.json),
#   * restarts any instance that dies,
#   * makes sure the cloudflared tunnel service stays running.
#
# Reads C:\waifumaster-autostart\autostart.config.json. ASCII only.

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

Log "=== launcher start ===  workdir=$WorkDir  main=$MainPy  py=$Py $PyArgs  instances=$($cfg.instances.Count)  cloudflared_svc=$Svc"

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
    Ensure-Cloudflared
    Start-Sleep -Seconds 30
}
