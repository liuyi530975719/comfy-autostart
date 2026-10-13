<#
  node-ollama2.ps1  --  ONE Ollama per GPU on a Windows fleet box (autostart kit), each with its own tunnel
                        hostname, tuned for wifemaker's labeling pool (vlm_pool).

  Why: a single Ollama sees both cards and happily splits one model across them (half on each) or queues every
  request on one card. One instance per GPU (CUDA_VISIBLE_DEVICES pinned) = whole model on one card, both cards
  busy, and wifemaker can address each card as its own node.

  Run in an ADMIN PowerShell on the box (pro6000: GPU0 = pro6000a + 6000chat :11434, GPU1 = pro6000b + 6000chat2 :11435):

      powershell -ExecutionPolicy Bypass -File .\node-ollama2.ps1          # asks for the Cloudflare token (hidden paste)
      straight from GitHub (one line):
      iwr https://raw.githubusercontent.com/liuyi530975719/comfy-autostart/main/node-ollama2.ps1 -OutFile "$env:TEMP\node-ollama2.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\node-ollama2.ps1"
      (-CfToken '<token>' also works, but then the token lands in the PowerShell history.
       Do NOT run it as  & ([scriptblock]::Create((irm ...)))  -- a scriptblock's 'exit' closes the whole console.)

  What it does (idempotent, re-run any time):
    1. checks ollama.exe (>= 0.34.4 for Qwen 3.8; older = downloads the latest OllamaSetup.exe and installs it
       silently, models/settings are kept; -NoUpgrade to refuse) and counts GPUs (nvidia-smi)
    2. stops the tray Ollama and takes it out of Startup (it would grab :11434 unpinned on every boot)
    3+4. one pinned instance per GPU: gpu0 -> :11434, gpu1 -> :11435, ... with OLLAMA_CONTEXT_LENGTH=16384 /
       FLASH_ATTENTION=1 / KV_CACHE_TYPE=q8_0 (what the labeling pool needs), kept alive across reboots:
         - box WITH the autostart kit (C:\waifumaster-autostart): "ollama" block in autostart.config.json +
           launcher v3 (= v2 + env block), WaifumasterAutostart task restarted, ComfyUI untouched
         - box WITHOUT it (pro6000): C:\waifumaster-ollama\start_ollama.ps1 + ollama_keepalive.ps1 and a
           scheduled task "WaifumasterOllama" (SYSTEM, at boot + every 2 min), same shape deploy-extras.ps1 makes
    5. makes sure the labeling model exists (shared models dir, pulled once) and warms every instance
    6. Cloudflare (needs the API token: Tunnel:Edit, DNS:Edit, Access Apps:Edit, Zone:Read):
         finds this box's tunnel from the DNS of <Chat>.<Zone>, adds <Chat>2.<Zone> -> :11435 (and so on)
         to the tunnel ingress (remote-managed: via API; locally-managed: edits the config.yml + restarts
         cloudflared), creates the proxied CNAME, adds the hostname to the fleet's service-token Access app
    7. prints the one command to run on the Studio PC to put the new node into the labeling pool

  Params:
    -CfToken <tok>        Cloudflare API token (or $env:CF_API_TOKEN); not given = asked for at the start (hidden).
                          Enter at the prompt / -NoCf = skip step 6.
    -Zone bestyiever.vip  -Chat 6000chat (hostname prefix: gpu0 = 6000chat, gpu1 = 6000chat2, gpu2 = 6000chat3 ...)
    -Ports 11434,11435    -NumParallel 2   -MaxLoaded 2   -ContextLength 16384
    -Model <tag>          model that must exist (default huihui_ai/Qwen3.8-abliterated:27b-bf16); -NoModel = skip
    -ModelsDir <path>     where the models live (default: the tray app's OLLAMA_MODELS, else %USERPROFILE%\.ollama\models,
                          so the models already pulled on this box are reused); -OllamaExe <path>; -TunnelId <uuid>
    -TunnelConfig <yml>   locally-managed tunnel: the config.yml to edit (auto-detected from the cloudflared service/task)
    -CfOnly               skip the Ollama/kit steps, only do the Cloudflare part (-GpuCount N when there is no kit config)
    -NoUpgrade            never install a newer Ollama (stop with a message instead)
  ASCII only. No secrets inside: the token is only ever read from the parameter / environment at run time.
#>
[CmdletBinding()]
param(
    [string]$CfToken = $env:CF_API_TOKEN,
    [string]$Zone = 'bestyiever.vip',
    [string]$Chat = '6000chat',
    [int[]]$Ports = @(),
    [int]$NumParallel = 2,
    [int]$MaxLoaded = 2,
    [int]$ContextLength = 16384,
    [string]$Model = 'huihui_ai/Qwen3.8-abliterated:27b-bf16',
    [string]$OllamaExe = '',
    [string]$ModelsDir = '',
    [string]$TunnelId = '',
    [string]$TunnelConfig = '',
    [string]$AccessApp = $env:CF_ACCESS_APP,
    [int]$GpuCount = 2,
    [switch]$NoCf,
    [switch]$NoModel,
    [switch]$CfOnly,
    [switch]$NoUpgrade,
    [string]$ApiBase = $(if ($env:CF_API_BASE) { $env:CF_API_BASE } else { 'https://api.cloudflare.com/client/v4' })
)
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
function Say($m, $c = 'Gray') { Write-Host "[node-ollama2] $m" -ForegroundColor $c }
function Die($m) { Say $m 'Red'; exit 1 }

# ask for the Cloudflare token up front (hidden input) so the whole run is hands-off afterwards
if (-not $NoCf -and -not $CfToken -and [Environment]::UserInteractive) {
    try {
        $sec = Read-Host "Cloudflare API token (paste, input is hidden; just Enter = skip the tunnel/DNS/Access part)" -AsSecureString
        if ($sec -and $sec.Length -gt 0) {
            $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
            try { $CfToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
        }
    } catch { $CfToken = '' }
    $CfToken = "$CfToken".Trim()
}
$KitDir  = $(if ($env:WM_KIT_DIR) { $env:WM_KIT_DIR } else { 'C:\waifumaster-autostart' })   # env override only for tests
$CfgPath = $KitDir + [IO.Path]::DirectorySeparatorChar + 'autostart.config.json'
$Task    = 'WaifumasterAutostart'
$MinVer  = [version]'0.34.4'

# ============================================================ 1. checks
$cfg = $null
if (Test-Path $CfgPath) { $cfg = Get-Content $CfgPath -Raw | ConvertFrom-Json }
if (-not $CfOnly) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { Die "run this in an ADMIN PowerShell (the scheduled task + services need it)" }
    if ($cfg) { Say "autostart kit found ($CfgPath) -> Ollama instances go into its launcher" 'Cyan' }
    else { Say "no autostart kit on this box -> standalone mode (own scheduled task WaifumasterOllama)" 'Cyan' }
}

if (-not $CfOnly -and -not $OllamaExe) {
    $cands = @((Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'), 'C:\Program Files\Ollama\ollama.exe', 'C:\Ollama\ollama.exe')
    $OllamaExe = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $OllamaExe) { $c = Get-Command ollama.exe -ErrorAction SilentlyContinue; if ($c) { $OllamaExe = $c.Source } }
}
function Get-OllamaVersion([string]$exe) {
    $t = ''; try { $t = (& $exe --version 2>&1 | Out-String) } catch { $t = "$_" }
    if ($t -match '(\d+)\.(\d+)\.(\d+)') { return [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3]) }
    return $null
}
function Update-Ollama() {
    # downloads the current OllamaSetup.exe (Inno Setup, per-user, ~1-2 GB) and runs it silently. The installer kills a
    # running ollama / tray app itself, keeps models + settings, then starts the tray app again (step 2 stops it).
    $setup = Join-Path $env:TEMP 'OllamaSetup.exe'
    $urls = @('https://ollama.com/download/OllamaSetup.exe', 'https://github.com/ollama/ollama/releases/latest/download/OllamaSetup.exe')
    if ($env:WM_OLLAMA_SETUP_URL) { $urls = @($env:WM_OLLAMA_SETUP_URL -split ",") }   # tests only
    $got = $false
    foreach ($u in $urls) {
        try {
            Say "downloading $u -> $setup (1-2 GB, a few minutes) ..." 'Yellow'
            if (Test-Path $setup) { Remove-Item $setup -Force }
            $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
            if ($curl) {
                & $curl.Source -L --fail --retry 3 --retry-delay 5 -# -o $setup $u
                if ($LASTEXITCODE -ne 0) { throw "curl exit code $LASTEXITCODE" }
            } else {
                $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
                try { Invoke-WebRequest -Uri $u -OutFile $setup -UseBasicParsing } finally { $ProgressPreference = $pp }
            }
            $len = (Get-Item $setup).Length
            if ($len -lt 50MB) { throw "downloaded file is only $len bytes (not the installer)" }
            Say ("downloaded {0:N0} MB" -f ($len / 1MB)) 'Cyan'
            $got = $true; break
        } catch { Say "download failed: $($_.Exception.Message)" 'Yellow' }
    }
    if (-not $got) { return $false }
    Say "installing silently (/VERYSILENT; the installer closes any running Ollama itself; 1-3 minutes) ..." 'Yellow'
    $setupArgs = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    $code = -1
    if ($env:WM_TEST_RUNNER) { & $env:WM_TEST_RUNNER $setup @setupArgs | Out-Host; $code = $LASTEXITCODE }   # tests only
    else { $p = Start-Process -FilePath $setup -ArgumentList $setupArgs -Wait -PassThru; $code = $p.ExitCode }
    if ($code -ne 0) { Say "installer exit code $code" 'Yellow'; return $false }
    Start-Sleep -Seconds 8     # the installer launches the tray app on its way out; let it settle, step 2 stops it again
    return $true
}
if (-not $CfOnly) {
    if (-not $OllamaExe -or -not (Test-Path $OllamaExe)) { Die "ollama.exe not found -- install Ollama (https://ollama.com/download/windows) or pass -OllamaExe" }
    $ver = Get-OllamaVersion $OllamaExe
    Say ("ollama  : {0}  (version {1})" -f $OllamaExe, $(if ($ver) { $ver } else { '?' })) 'Cyan'
    if ($ver -and $ver -lt $MinVer) {
        Say "Ollama $ver is too old for Qwen 3.8 (RENDERER qwen3.8 needs >= $MinVer, 'unknown renderer' otherwise)." 'Yellow'
        if ($NoUpgrade) { Die "-NoUpgrade given: install the latest from https://ollama.com/download/windows yourself and re-run." }
        if (-not (Update-Ollama)) { Die "automatic upgrade did not work -- install the latest from https://ollama.com/download/windows (OllamaSetup.exe, keeps the models) and re-run." }
        $cands = @($OllamaExe, (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'), 'C:\Program Files\Ollama\ollama.exe')
        $found = $cands | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
        if ($found) { $OllamaExe = $found }
        $ver = Get-OllamaVersion $OllamaExe
        Say ("ollama  : {0}  (version {1} after upgrade)" -f $OllamaExe, $(if ($ver) { $ver } else { '?' })) 'Cyan'
        if (-not $ver -or $ver -lt $MinVer) { Die "still $ver after the upgrade -- run OllamaSetup.exe by hand (https://ollama.com/download/windows) and re-run." }
    }
}

$gpus = @()
if ($cfg) { foreach ($inst in $cfg.instances) { $gpus += [int]$inst.gpu } }
elseif ($Ports.Count) { for ($i = 0; $i -lt $Ports.Count; $i++) { $gpus += $i } }
else {
    $n = 0
    try { $idx = @(& nvidia-smi --query-gpu=index --format=csv,noheader 2>$null | Where-Object { "$_".Trim() -match '^\d+$' }); $n = $idx.Count } catch {}
    if ($n -lt 1) { $n = $GpuCount }
    for ($i = 0; $i -lt $n; $i++) { $gpus += $i }
}
if (-not $gpus.Count) { $gpus = @(0) }
$gpus = @($gpus | Sort-Object -Unique)
$defaultPorts = @(11434, 11435, 11436, 11437, 11438, 11439, 11440, 11441)
$oinst = @()
for ($i = 0; $i -lt $gpus.Count; $i++) {
    $port = if ($i -lt $Ports.Count) { $Ports[$i] } else { $defaultPorts[$i] }
    $oinst += [ordered]@{ gpu = $gpus[$i]; port = $port }
}
$hostOf = @{}    # port -> hostname
for ($i = 0; $i -lt $oinst.Count; $i++) { $hostOf[[int]$oinst[$i].port] = $(if ($i -eq 0) { "$Chat.$Zone" } else { "$Chat$($i + 1).$Zone" }) }
Say ("GPUs    : {0}" -f (($oinst | ForEach-Object { "gpu$($_.gpu) -> :$($_.port) ($($hostOf[[int]$_.port]))" }) -join ', ')) 'Cyan'
if ($gpus.Count -lt 2) { Say "only one GPU found -- fine, you get one pinned instance (no split possible anyway)" 'Yellow' }

if ($CfOnly) { Say "-CfOnly: skipping the Ollama / autostart steps" 'Yellow' }
else {
# ============================================================ 2. tray app out of the way
Say "stopping tray Ollama / stray 'ollama serve' (short downtime for :11434) ..." 'Yellow'
Get-Process -Name 'ollama app', 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$startupLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk'
if (Test-Path $startupLnk) { Remove-Item $startupLnk -Force; Say "removed Startup shortcut: $startupLnk" }
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$rk = Get-ItemProperty $runKey -ErrorAction SilentlyContinue
if ($rk -and ($rk.PSObject.Properties.Name -contains 'Ollama')) { Remove-ItemProperty -Path $runKey -Name 'Ollama' -ErrorAction SilentlyContinue; Say "removed HKCU Run entry: Ollama" }
if (-not $ModelsDir) {
    $um = [Environment]::GetEnvironmentVariable('OLLAMA_MODELS', 'User'); if ($um) { $ModelsDir = $um; Say "models dir (from the tray app's OLLAMA_MODELS): $ModelsDir" }
}
if (-not $ModelsDir -and -not $cfg) {
    # standalone instances run as SYSTEM, whose default models dir is NOT this user's -> point them at the models already here
    $ModelsDir = Join-Path $env:USERPROFILE '.ollama\models'
    Say "models dir: $ModelsDir (this user's Ollama models, reused by the pinned instances)"
}
# other scheduled tasks that (re)start an unpinned ollama would fight over :11434 -- say so
try {
    $others = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -notin @('WaifumasterOllama', 'WaifumasterAutostart') -and (@($_.Actions) | Where-Object { "$($_.Execute) $($_.Arguments)" -match 'ollama' }).Count -gt 0 })
    foreach ($o in $others) { Say "WARNING: scheduled task '$($o.TaskName)' also starts ollama ($($o.State)) -- disable it if it brings back an unpinned instance on :11434" 'Yellow' }
} catch {}

if ($cfg) {
# ============================================================ 3. config block (autostart kit)
$new = [ordered]@{}
foreach ($p in $cfg.PSObject.Properties) { if ($p.Name -ne 'ollama') { $new[$p.Name] = $p.Value } }
$new['ollama'] = [ordered]@{
    exe          = $OllamaExe
    models_dir   = $ModelsDir
    keep_alive   = '30m'
    num_parallel = $NumParallel
    max_loaded   = $MaxLoaded
    env          = [ordered]@{ OLLAMA_CONTEXT_LENGTH = "$ContextLength"; OLLAMA_FLASH_ATTENTION = '1'; OLLAMA_KV_CACHE_TYPE = 'q8_0' }
    instances    = $oinst
}
Copy-Item $CfgPath ($CfgPath + '.bak.' + (Get-Date -Format 'yyyyMMddHHmmss')) -Force
($new | ConvertTo-Json -Depth 8) | Set-Content -Path $CfgPath -Encoding ASCII
Say "wrote   : $CfgPath (ollama block: $($oinst.Count) instance(s), parallel $NumParallel, ctx $ContextLength, kv q8_0)" 'Cyan'

# ============================================================ 4. launcher v3
$launcherV3 = @'
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
'@
$launcher = Join-Path $KitDir 'autostart-comfy.ps1'
if (Test-Path $launcher) { Copy-Item $launcher ($launcher + '.bak.' + (Get-Date -Format 'yyyyMMddHHmmss')) -Force }
Set-Content -Path $launcher -Value $launcherV3 -Encoding ASCII
Say "installed launcher v3: $launcher" 'Cyan'

Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell' -and $_.CommandLine -match 'autostart-comfy\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
$t = Get-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
if (-not $t) { Die "scheduled task $Task not found -- the autostart kit is not registered on this box (run bootstrap.ps1)" }
Start-ScheduledTask -TaskName $Task
Say "restarted task $Task (ComfyUI instances untouched)" 'Green'
$LogHint = "$KitDir\logs\ollama_gpu<gpu>_<port>.log"
} else {
# ============================================================ 3+4. standalone: own launcher + keepalive task (no kit on this box)
$Root = 'C:\waifumaster-ollama'
$scripts = Join-Path $Root 'scripts'; $logs = Join-Path $Root 'logs'
New-Item -ItemType Directory -Force -Path $scripts, $logs | Out-Null
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('# Auto-generated by node-ollama2.ps1 -- one Ollama per GPU (pinned with CUDA_VISIBLE_DEVICES). Re-run node-ollama2.ps1 to change.')
[void]$sb.AppendLine("`$Exe = '$OllamaExe'")
[void]$sb.AppendLine("`$Logs = '$logs'")
foreach ($oi in $oinst) {
    $g = [int]$oi.gpu; $port = [int]$oi.port
    $sets = "set CUDA_VISIBLE_DEVICES=$g&& set OLLAMA_HOST=0.0.0.0:$port&& set OLLAMA_MODELS=$ModelsDir&& set OLLAMA_NUM_PARALLEL=$NumParallel&& set OLLAMA_MAX_LOADED_MODELS=$MaxLoaded&& set OLLAMA_KEEP_ALIVE=30m&& set OLLAMA_CONTEXT_LENGTH=$ContextLength&& set OLLAMA_FLASH_ATTENTION=1&& set OLLAMA_KV_CACHE_TYPE=q8_0&& "
    [void]$sb.AppendLine("# ----- GPU $g  port $port -----")
    [void]$sb.AppendLine("`$log = Join-Path `$Logs 'ollama_gpu$g.log'")
    [void]$sb.AppendLine("`$inner = '$sets' + '`"' + `$Exe + '`" serve 1>>`"' + `$log + '`" 2>>`"' + `$log + '`"'")
    [void]$sb.AppendLine("`$alive = `$false; try { Invoke-RestMethod 'http://127.0.0.1:$port/api/version' -TimeoutSec 3 | Out-Null; `$alive = `$true } catch {}")
    [void]$sb.AppendLine("if (`$alive) { Write-Host 'Ollama gpu $g already up on :$port' } else {")
    [void]$sb.AppendLine("  Start-Process -FilePath cmd.exe -ArgumentList ('/c ' + `$inner) -WindowStyle Hidden")
    [void]$sb.AppendLine("  Write-Host 'started Ollama gpu $g on :$port'")
    [void]$sb.AppendLine('  Start-Sleep -Seconds 3')
    [void]$sb.AppendLine('}')
}
$startOllama = Join-Path $scripts 'start_ollama.ps1'
if (Test-Path $startOllama) { Copy-Item $startOllama ($startOllama + '.bak.' + (Get-Date -Format 'yyyyMMddHHmmss')) -Force }
$sb.ToString() | Out-File -Encoding ascii $startOllama
Say "wrote   : $startOllama ($($oinst.Count) instance(s), parallel $NumParallel, ctx $ContextLength, kv q8_0, models $ModelsDir)" 'Cyan'
$kick = Join-Path $scripts 'ollama_keepalive.ps1'
$portList = (($oinst | ForEach-Object { [int]$_.port }) -join ',')
@"
# Auto-generated by node-ollama2.ps1. Every 2 min: start any Ollama instance whose port is not answering.
`$ports = @($portList)
`$dead = @()
foreach (`$p in `$ports) { try { Invoke-RestMethod "http://127.0.0.1:`$p/api/version" -TimeoutSec 5 | Out-Null } catch { `$dead += `$p } }
if (`$dead.Count -gt 0) { & '$startOllama' }
"@ | Out-File -Encoding ascii $kick
$act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$kick`""
$trg1 = New-ScheduledTaskTrigger -AtStartup
$trg2 = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 2) -RepetitionDuration (New-TimeSpan -Days 3650)
$prin = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
$set  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
Unregister-ScheduledTask -TaskName 'WaifumasterOllama' -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
Register-ScheduledTask -TaskName 'WaifumasterOllama' -Action $act -Trigger @($trg1, $trg2) -Principal $prin -Settings $set -Description 'Ollama per GPU for wifemaker labeling (keepalive every 2 min)' | Out-Null
Start-ScheduledTask -TaskName 'WaifumasterOllama'
Say "task WaifumasterOllama registered + started (SYSTEM, at boot + every 2 min)" 'Green'
$LogHint = "$logs\ollama_gpu<gpu>.log"
}

function Port-Up([int]$p) { try { $r = Invoke-RestMethod -Uri "http://127.0.0.1:$p/api/version" -TimeoutSec 3; return [string]$r.version } catch { return $null } }
foreach ($oi in $oinst) {
    $v = $null
    for ($k = 0; $k -lt 40 -and -not $v; $k++) { Start-Sleep -Seconds 3; $v = Port-Up ([int]$oi.port) }
    if ($v) { Say ("  gpu{0} :{1}  UP  (ollama {2})" -f $oi.gpu, $oi.port, $v) 'Green' }
    else { Say ("  gpu{0} :{1}  not up after 2 min -- see {2}" -f $oi.gpu, $oi.port, $LogHint) 'Red' }
}

# ============================================================ 5. model on every instance (shared models dir)
if (-not $NoModel -and $Model) {
    $env:OLLAMA_HOST = "127.0.0.1:$($oinst[0].port)"      # the CLI talks to the first instance
    $have = $false
    try { $tags = Invoke-RestMethod -Uri "http://127.0.0.1:$($oinst[0].port)/api/tags" -TimeoutSec 10; $have = @($tags.models | Where-Object { $_.name -eq $Model }).Count -gt 0 } catch {}
    if ($have) { Say "model   : $Model present" 'Cyan' }
    else {
        Say "pulling $Model (shared by all instances; minutes to tens of minutes) ..." 'Yellow'
        & $OllamaExe pull $Model
        if ($LASTEXITCODE -ne 0) { Say "pull failed -- check the tag on https://ollama.com/$($Model.Split(':')[0])/tags; the instances are up anyway" 'Red' }
    }
    foreach ($oi in $oinst) { try { $null = Invoke-RestMethod -Uri "http://127.0.0.1:$($oi.port)/api/tags" -TimeoutSec 10 } catch {} }
    Say "note: each instance loads the model on its OWN card on first use (no more half-and-half splits)" 'DarkGray'
}
}   # end of the Ollama / autostart steps

# ============================================================ 6. Cloudflare: hostname per instance
if ($NoCf -or -not $CfToken) {
    Say "Cloudflare: skipped (no -CfToken) -- tunnel hostname for instance #2 not created" 'Yellow'
} else {
    $script:CfBase = $ApiBase.TrimEnd('/')
    $script:CfHdr  = @{ Authorization = "Bearer $CfToken"; 'User-Agent' = 'wifemaker-node-ollama2/1.0' }
    function CfLog($m) { Write-Host "[cf] $m" -ForegroundColor DarkCyan }
    function Invoke-CfApi([string]$Method, [string]$Path, $Body = $null, [hashtable]$Params = $null, [switch]$Ok404) {
        $url = $script:CfBase + $Path
        if ($Params) {
            $qs = ($Params.GetEnumerator() | ForEach-Object { [uri]::EscapeDataString([string]$_.Key) + '=' + [uri]::EscapeDataString([string]$_.Value) }) -join '&'
            $url += $(if ($url.Contains('?')) { '&' } else { '?' }) + $qs
        }
        $a = @{ Method = $Method; Uri = $url; Headers = $script:CfHdr; ContentType = 'application/json' }
        if ($null -ne $Body) { $a.Body = ($Body | ConvertTo-Json -Depth 30 -Compress) }
        try { $r = Invoke-RestMethod @a }
        catch {
            $code = 0; $msg = ''
            try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            try { $msg = $_.ErrorDetails.Message } catch {}
            if (-not $msg) { try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $msg = $sr.ReadToEnd() } catch { $msg = $_.Exception.Message } }
            if ($code -eq 404 -and $Ok404) { return $null }
            try { $j = $msg | ConvertFrom-Json; if ($j.errors) { $msg = ($j.errors | ForEach-Object { "$($_.code): $($_.message)" }) -join '; ' } } catch {}
            throw "HTTP $code $Method $Path -> $msg"
        }
        if ($null -ne $r -and ($r.PSObject.Properties.Name -contains 'success') -and $r.success -eq $false) {
            throw "$Method $Path -> " + (($r.errors | ForEach-Object { "$($_.code): $($_.message)" }) -join '; ')
        }
        return $r
    }
    function Get-CfResult([string]$Method, [string]$Path, $Body = $null, [hashtable]$Params = $null, [switch]$Ok404) {
        $r = Invoke-CfApi $Method $Path $Body $Params -Ok404:$Ok404; if ($null -eq $r) { return $null }; return $r.result
    }
    function Get-CfPaged([string]$Path, [hashtable]$Params = $null) {
        $out = @(); $page = 1
        while ($true) {
            $p = @{ per_page = 100; page = $page }; if ($Params) { foreach ($k in $Params.Keys) { $p[$k] = $Params[$k] } }
            $r = Invoke-CfApi 'GET' $Path $null $p
            if ($r.result) { $out += @($r.result) }
            $tp = 1; try { if ($r.result_info.total_pages) { $tp = [int]$r.result_info.total_pages } } catch {}
            if ($page -ge $tp) { return ,$out }
            $page++
        }
    }
    function ToHash($o) {
        if ($null -eq $o) { return $null }
        if ($o -is [System.Collections.IDictionary]) { $h = [ordered]@{}; foreach ($k in $o.Keys) { $h[$k] = ToHash $o[$k] }; return $h }
        if ($o -is [System.Collections.IEnumerable] -and -not ($o -is [string])) { $l = @(); foreach ($x in $o) { $l += ,(ToHash $x) }; return ,$l }
        if ($o -is [System.Management.Automation.PSCustomObject]) { $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ToHash $p.Value }; return $h }
        return $o
    }
    function CfBare([string]$h) { return ($h -split '[/:]', 2)[0].ToLower() }
    function Get-CfAppHosts($App) {
        $hs = New-Object System.Collections.Generic.HashSet[string]
        if ($App.self_hosted_domains) { foreach ($d in @($App.self_hosted_domains)) { $null = $hs.Add(([string]$d).ToLower()) } }
        if ($App.destinations) { foreach ($d in @($App.destinations)) { if ((-not $d.type -or $d.type -eq 'public') -and $d.uri) { $null = $hs.Add(([string]$d.uri).ToLower()) } } }
        if ($App.domain) { $null = $hs.Add(([string]$App.domain).ToLower()) }
        return $hs
    }
    $script:CfReadOnly = @('id','aud','created_at','updated_at','uid','policies','scim_config','saas_app','account_id')
    function Add-CfAccessHosts([string]$Acct, $App, [string[]]$HostList) {
        $have = @{}; foreach ($h in (Get-CfAppHosts $App)) { $have[(CfBare $h)] = $true }
        $missing = @($HostList | Where-Object { -not $have.ContainsKey($_) })
        if ($missing.Count -eq 0) { CfLog "access   '$($App.name)' already covers $($HostList -join ', ')"; return $App }
        $body = @{}
        foreach ($p in $App.PSObject.Properties) { if ($script:CfReadOnly -notcontains $p.Name -and $null -ne $p.Value) { $body[$p.Name] = $p.Value } }
        $shd = @(); if ($App.self_hosted_domains) { $shd = @($App.self_hosted_domains) } elseif ($App.domain) { $shd = @($App.domain) }
        $body['self_hosted_domains'] = @($shd + $missing)
        if ($App.PSObject.Properties.Name -contains 'destinations' -and $null -ne $App.destinations) {
            $dest = @(); foreach ($d in @($App.destinations)) { $dest += ,@{ type = $(if ($d.type) { $d.type } else { 'public' }); uri = $d.uri } }
            foreach ($h in $missing) { $dest += ,@{ type = 'public'; uri = $h } }
            $body['destinations'] = $dest
        }
        if (-not $body.ContainsKey('type')) { $body['type'] = 'self_hosted' }
        if (-not $body.ContainsKey('domain')) { $body['domain'] = $(if ($shd.Count) { $shd[0] } else { $missing[0] }) }
        $before = 0; if ($App.policies) { $before = @($App.policies).Count }
        $null = Get-CfResult 'PUT' "/accounts/$Acct/access/apps/$($App.id)" $body
        CfLog "access   '$($App.name)' += $($missing -join ', ')"
        $after = Get-CfResult 'GET' "/accounts/$Acct/access/apps/$($App.id)"
        $got = @{}; foreach ($h in (Get-CfAppHosts $after)) { $got[(CfBare $h)] = $true }
        $still = @($missing | Where-Object { -not $got.ContainsKey($_) })
        if ($still.Count) { throw "Access app update did not stick for: $($still -join ', ')" }
        if ($before -gt 0 -and (-not $after.policies -or @($after.policies).Count -eq 0)) { CfLog "access   WARNING: the app lost its policies on update -- re-add the fleet service-token policy in the dashboard" }
        return $after
    }
    function Find-CfAccessApp([string]$Acct, [string]$ZoneName, [string]$MustHost, [string]$AppName) {
        $apps = @(Get-CfPaged "/accounts/$Acct/access/apps") | Where-Object { $_ -and (-not $_.type -or $_.type -eq 'self_hosted') }
        if ($AppName) { foreach ($a in $apps) { if ($a.name -and $a.name.Trim().ToLower() -eq $AppName.Trim().ToLower()) { return $a } }; throw "Access application named '$AppName' not found" }
        foreach ($a in $apps) { foreach ($h in (Get-CfAppHosts $a)) { if ((CfBare $h) -eq $MustHost.ToLower()) { return $a } } }
        $best = $null; $bestN = 0; $suffix = '.' + $ZoneName.ToLower()
        foreach ($a in $apps) {
            $n = 0; foreach ($h in (Get-CfAppHosts $a)) { $b = CfBare $h; if ($b.EndsWith($suffix) -or $b -eq $ZoneName.ToLower()) { $n++ } }
            if ($n -gt $bestN) { $best = $a; $bestN = $n }
        }
        return $best
    }
    function Set-CfDns([string]$Zid, [string]$HostName, [string]$Tid) {
        $target = "$Tid.cfargotunnel.com"
        $recs = @(Get-CfResult 'GET' "/zones/$Zid/dns_records" $null @{ name = $HostName }) | Where-Object { $_ -and $_.name -and $_.name.ToLower() -eq $HostName }
        if ($recs.Count -lt 1) { $null = Get-CfResult 'POST' "/zones/$Zid/dns_records" @{ type = 'CNAME'; name = $HostName; content = $target; proxied = $true; ttl = 1 }; CfLog ("dns      {0,-36} CNAME -> {1} (created)" -f $HostName, $target); return }
        $r = $recs[0]
        if ($r.type -ne 'CNAME') { CfLog ("dns      {0,-36} has a {1} record -- NOT touched" -f $HostName, $r.type); return }
        if ($r.content -eq $target -and $r.proxied) { CfLog ("dns      {0,-36} ok" -f $HostName); return }
        $null = Get-CfResult 'PATCH' "/zones/$Zid/dns_records/$($r.id)" @{ type = 'CNAME'; name = $HostName; content = $target; proxied = $true; ttl = 1 }
        CfLog ("dns      {0,-36} CNAME -> {1} (updated)" -f $HostName, $target)
    }
    function Find-CloudflaredRunner() {
        # how does cloudflared run on this box? -> @{ kind = service|task|none; name; path; config }
        if ($TunnelConfig) { return @{ kind = 'none'; name = ''; path = ''; config = $TunnelConfig } }
        $svcName = ''; if ($cfg) { $svcName = [string]$cfg.cloudflared_service }
        $svcs = @()
        try { $svcs = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { ($svcName -and $_.Name -eq $svcName) -or $_.Name -match 'cloudflared' -or $_.PathName -match 'cloudflared' }) } catch {}
        if ($svcs.Count) {
            $s = $svcs[0]; $conf = ''
            if ($s.PathName -match '--config\s+"?([^"]+?\.ya?ml)"?') { $conf = $Matches[1] }
            return @{ kind = 'service'; name = $s.Name; path = [string]$s.PathName; config = $conf }
        }
        $tasks = @(); try { $tasks = @(Get-ScheduledTask -ErrorAction Stop) } catch {}
        foreach ($tk in $tasks) {
            foreach ($ac in @($tk.Actions)) {
                if ("$($ac.Execute) $($ac.Arguments)" -match 'cloudflared') {
                    $conf = ''; if ("$($ac.Arguments)" -match '--config\s+"?([^"]+?\.ya?ml)"?') { $conf = $Matches[1] }
                    return @{ kind = 'task'; name = $tk.TaskName; path = "$($ac.Execute) $($ac.Arguments)"; config = $conf }
                }
            }
        }
        return @{ kind = 'none'; name = ''; path = ''; config = '' }
    }
    function Add-LocalIngress([string]$Yml, [hashtable]$HostMap) {
        # locally-managed tunnel: insert "- hostname/service" pairs above the catch-all rule of config.yml
        $lines = @(Get-Content $Yml)
        $catch = -1; for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^\s*-\s*service:\s*http_status:') { $catch = $i; break } }
        if ($catch -lt 0) { throw "no catch-all '- service: http_status:404' rule in $Yml -- add the ingress by hand" }
        $indent = '  '; foreach ($l in $lines) { if ($l -match '^(\s*)-\s*hostname:') { $indent = $Matches[1]; break } }
        $have = @{}; foreach ($l in $lines) { if ($l -match '^\s*-\s*hostname:\s*(\S+)') { $have[$Matches[1].ToLower()] = $true } }
        $ins = @()
        foreach ($h in ($HostMap.Keys | Sort-Object)) {
            if ($have.ContainsKey($h)) { CfLog "ingress  $h already in $Yml"; continue }
            $ins += ("{0}- hostname: {1}" -f $indent, $h); $ins += ("{0}  service: {1}" -f $indent, $HostMap[$h])
            CfLog ("ingress  {0,-36} -> {1} (config.yml)" -f $h, $HostMap[$h])
        }
        if (-not $ins.Count) { return $false }
        Copy-Item $Yml ($Yml + '.bak.' + (Get-Date -Format 'yyyyMMddHHmmss')) -Force
        $out = @(); for ($i = 0; $i -lt $lines.Count; $i++) { if ($i -eq $catch) { $out += $ins }; $out += $lines[$i] }
        Set-Content -Path $Yml -Value $out -Encoding ASCII
        return $true
    }

    try {
        $zs = @(Get-CfResult 'GET' '/zones' $null @{ name = $Zone })
        if ($zs.Count -lt 1 -or -not $zs[0]) { throw "zone $Zone not visible to this token (needs Zone:Read)" }
        $zid = $zs[0].id; $acct = $zs[0].account.id
        CfLog "zone $Zone -> $zid (account $acct)"
        $firstHost = $hostOf[[int]$oinst[0].port]
        if (-not $TunnelId) {
            $recs = @(Get-CfResult 'GET' "/zones/$zid/dns_records" $null @{ name = $firstHost }) | Where-Object { $_ -and $_.type -eq 'CNAME' -and $_.content -match '^([0-9a-f-]{36})\.cfargotunnel\.com$' }
            if ($recs.Count) { $TunnelId = ($recs[0].content -replace '\.cfargotunnel\.com$', '') }
        }
        if (-not $TunnelId) { throw "could not find this box's tunnel from the DNS of $firstHost -- pass -TunnelId <uuid> (Zero Trust -> Networks -> Tunnels)" }
        $tun = Get-CfResult 'GET' "/accounts/$acct/cfd_tunnel/$TunnelId"
        $src = [string]$tun.config_src
        CfLog "tunnel   $($tun.name) ($TunnelId) config_src=$src status=$($tun.status)"
        $newMap = @{}
        foreach ($oi in $oinst) { $h = $hostOf[[int]$oi.port]; $newMap[$h] = "http://localhost:$($oi.port)" }

        if ($src -eq 'cloudflare') {
            # remote-managed: merge into the tunnel configuration (keep every existing rule as-is)
            $cur = Get-CfResult 'GET' "/accounts/$acct/cfd_tunnel/$TunnelId/configurations" -Ok404
            $conf = [ordered]@{}; if ($cur -and $cur.config) { $conf = ToHash $cur.config }
            $ing = @(); $seen = @{}
            if ($conf.Contains('ingress')) { foreach ($e in @($conf['ingress'])) { if ($e -and $e.Contains('hostname') -and $e['hostname']) { $ing += ,$e; $seen[([string]$e['hostname']).ToLower()] = $true } } }
            foreach ($h in ($newMap.Keys | Sort-Object)) {
                if ($seen.ContainsKey($h)) { CfLog ("ingress  {0,-36} already routed" -f $h); continue }
                $ing += ,([ordered]@{ hostname = $h; service = $newMap[$h] }); CfLog ("ingress  {0,-36} -> {1} (added)" -f $h, $newMap[$h])
            }
            $ing += ,([ordered]@{ service = 'http_status:404' })
            $conf['ingress'] = $ing
            $null = Get-CfResult 'PUT' "/accounts/$acct/cfd_tunnel/$TunnelId/configurations" @{ config = $conf }
            CfLog "ingress  written (remote-managed tunnel picks it up within seconds)"
        } else {
            $run = Find-CloudflaredRunner
            $yml = $run.config
            if (-not $yml) {
                foreach ($c in @((Join-Path $env:USERPROFILE '.cloudflared\config.yml'), "$env:SystemRoot\System32\config\systemprofile\.cloudflared\config.yml")) { if (Test-Path $c) { $yml = $c; break } }
                if (-not $yml) { $cand = Get-ChildItem (Join-Path $env:USERPROFILE '.cloudflared') -Filter 'config*.yml' -ErrorAction SilentlyContinue | Select-Object -First 1; if ($cand) { $yml = $cand.FullName } }
            }
            if (-not $yml -or -not (Test-Path $yml)) { throw "locally-managed tunnel but no config.yml found (cloudflared runs as $($run.kind) '$($run.name)') -- add the ingress by hand and restart cloudflared" }
            CfLog "local config: $yml (cloudflared runs as $($run.kind) '$($run.name)')"
            $changed = Add-LocalIngress $yml $newMap
            if ($changed) {
                if ($TunnelConfig -and $run.kind -eq 'none') {
                    # explicit config path: still try to find who runs cloudflared so it gets restarted
                    $saved = $TunnelConfig; $TunnelConfig = ''; $run = Find-CloudflaredRunner; $TunnelConfig = $saved
                }
                if ($run.kind -eq 'service') { Restart-Service -Name $run.name -Force; CfLog "restarted service $($run.name)" }
                elseif ($run.kind -eq 'task') { Stop-ScheduledTask -TaskName $run.name -ErrorAction SilentlyContinue; Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep 2; Start-ScheduledTask -TaskName $run.name; CfLog "restarted task $($run.name)" }
                else { CfLog "restart cloudflared by hand so it reads the new config.yml" }
            }
        }
        foreach ($h in ($newMap.Keys | Sort-Object)) { Set-CfDns $zid $h $TunnelId }
        $app = Find-CfAccessApp $acct $Zone $firstHost $AccessApp
        if ($app) { $null = Add-CfAccessHosts $acct $app @($newMap.Keys | Sort-Object) }
        else { CfLog "access   no self-hosted Access app found for $Zone -- add the hostnames to the fleet app in the dashboard" }
        foreach ($h in ($newMap.Keys | Sort-Object)) {
            try { $r = Invoke-WebRequest -Uri "https://$h/api/version" -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 0 -ErrorAction Stop; $code = [int]$r.StatusCode } catch { $code = 0; try { $code = [int]$_.Exception.Response.StatusCode } catch {} }
            CfLog ("probe    https://{0}/api/version -> {1}" -f $h, $(if ($code -eq 302 -or $code -eq 403 -or $code -eq 401) { "$code (Cloudflare Access is in front = routed; the Studio passes its service token)" } elseif ($code -eq 200) { '200 (open?! no Access in front)' } elseif ($code -eq 0) { 'no answer yet (DNS may take a minute)' } else { "$code" }))
        }
    } catch {
        Say "Cloudflare step failed: $($_.Exception.Message)" 'Red'
        Say "the Ollama instances are up anyway; fix the token/permissions and re-run (idempotent)" 'Yellow'
    }
}

# ============================================================ 7. what to do on the Studio PC
Say "" ; Say "=== done ===" 'Green'
foreach ($oi in $oinst) { Say ("  gpu{0}  http://127.0.0.1:{1}  ->  https://{2}" -f $oi.gpu, $oi.port, $hostOf[[int]$oi.port]) 'Cyan' }
Say "nvidia-smi compute apps (after the first request each instance shows up on ITS OWN gpu):" 'DarkGray'
try { if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) { nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv } } catch {}
$extra = @(); for ($i = 1; $i -lt $oinst.Count; $i++) { $extra += "https://" + $hostOf[[int]$oinst[$i].port] }
if ($extra.Count) {
    Say "" ; Say "On the Studio PC (run.py running), put the new instance(s) into the labeling pool:" 'Yellow'
    foreach ($u in $extra) { Say "    python E:\waifumaster\ollama_node_setup.py --register-only --url $u" 'White' }
    Say "(or studio_add_nodes.py --names `"`" --chat $(($extra | ForEach-Object { ($_ -replace '^https://', '') -replace "\.$Zone$", '' }) -join ','))" 'DarkGray'
}
