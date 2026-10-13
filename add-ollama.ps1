#Requires -RunAsAdministrator
<#
  add-ollama.ps1  --  put Ollama under the same per-GPU autostart as ComfyUI.

  Run ONCE on a box that already has the autostart kit (C:\waifumaster-autostart)
  in an ADMIN PowerShell, from the kit folder (needs autostart-comfy.ps1 v2 next to it):

      powershell -ExecutionPolicy Bypass -File .\add-ollama.ps1

  What it does:
    1. finds ollama.exe (or pass -OllamaExe)
    2. stops the tray "Ollama" app + any running ollama serve, and removes the
       tray app from Startup (otherwise it grabs :11434 unpinned on every boot)
    3. adds an "ollama" block to autostart.config.json: one instance per GPU,
       gpu0 -> :11434 (the existing 6000chat port), gpu1 -> :11435, ...
       (same GPU list as the ComfyUI instances, so GPU0 = ComfyUI 'a' + Ollama #1,
        GPU1 = ComfyUI 'b' + Ollama #2)
    4. installs the v2 launcher and restarts the WaifumasterAutostart task
       (ComfyUI instances are separate processes and keep running)
    5. verifies the ports and shows nvidia-smi compute apps

  Params:
    -OllamaExe <path>     explicit ollama.exe
    -Ports 11434,11435    ports per GPU (default 11434 + 11435, 11436, ...)
    -NumParallel 2        requests each instance serves at once (96GB: 2-3)
    -MaxLoaded 3          models each instance keeps resident
    -ModelsDir <path>     only if OLLAMA_MODELS was customised for the tray app
    -Remove               take the ollama block out again (and restart the task)
  ASCII only.
#>
param(
    [string]$OllamaExe = "",
    [int[]]$Ports = @(),
    [int]$NumParallel = 2,
    [int]$MaxLoaded = 3,
    [string]$ModelsDir = "",
    [switch]$Remove
)
$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

$KitDir  = 'C:\waifumaster-autostart'
$CfgPath = Join-Path $KitDir 'autostart.config.json'
$Task    = 'WaifumasterAutostart'
if (-not (Test-Path $CfgPath)) { throw "autostart kit not installed here ($CfgPath missing) -- run bootstrap.ps1 first" }
$cfg = Get-Content $CfgPath -Raw | ConvertFrom-Json

# 1) ollama.exe ----------------------------------------------------------------
if (-not $Remove) {
    if (-not $OllamaExe) {
        $cands = @(
            (Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'),
            'C:\Program Files\Ollama\ollama.exe',
            'C:\Ollama\ollama.exe'
        )
        $OllamaExe = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $OllamaExe) {
            $c = Get-Command ollama.exe -ErrorAction SilentlyContinue
            if ($c) { $OllamaExe = $c.Source }
        }
    }
    if (-not $OllamaExe -or -not (Test-Path $OllamaExe)) { throw "ollama.exe not found -- pass -OllamaExe 'C:\...\ollama.exe'" }
    Say "ollama  : $OllamaExe" 'Cyan'
}

# 2) stop the tray app and take it out of Startup -------------------------------
Say "stopping tray Ollama / running ollama serve ..." 'Yellow'
Get-Process -Name 'ollama app', 'ollama' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
$startupLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Ollama.lnk'
if (Test-Path $startupLnk) { Remove-Item $startupLnk -Force; Say "removed Startup shortcut: $startupLnk" }
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ((Get-ItemProperty $runKey -ErrorAction SilentlyContinue).PSObject.Properties.Name -contains 'Ollama') {
    Remove-ItemProperty -Path $runKey -Name 'Ollama' -ErrorAction SilentlyContinue; Say "removed HKCU Run entry: Ollama"
}

# 3) config block ----------------------------------------------------------------
$gpus = @()
foreach ($inst in $cfg.instances) { $gpus += [int]$inst.gpu }
if (-not $gpus.Count) { $gpus = @(0) }
$gpus = $gpus | Sort-Object -Unique
$defaultPorts = @(11434, 11435, 11436, 11437, 11438, 11439, 11440, 11441)
$oinst = @()
for ($i = 0; $i -lt $gpus.Count; $i++) {
    $port = if ($i -lt $Ports.Count) { $Ports[$i] } else { $defaultPorts[$i] }
    $oinst += [ordered]@{ gpu = $gpus[$i]; port = $port }
}

# rebuild the config as an ordered hashtable so the json stays tidy
$new = [ordered]@{}
foreach ($p in $cfg.PSObject.Properties) { if ($p.Name -ne 'ollama') { $new[$p.Name] = $p.Value } }
if (-not $Remove) {
    $new['ollama'] = [ordered]@{
        exe          = $OllamaExe
        models_dir   = $ModelsDir
        keep_alive   = '30m'
        num_parallel = $NumParallel
        max_loaded   = $MaxLoaded
        instances    = $oinst
    }
}
Copy-Item $CfgPath ($CfgPath + '.bak.' + (Get-Date -Format 'yyyyMMddHHmmss')) -Force
($new | ConvertTo-Json -Depth 8) | Set-Content -Path $CfgPath -Encoding ASCII
if ($Remove) { Say "removed ollama block from $CfgPath" 'Yellow' }
else { Say ("wrote   : {0}  ->  {1}" -f $CfgPath, (($oinst | ForEach-Object { "gpu$($_.gpu):$($_.port)" }) -join ', ')) 'Cyan' }

# 4) launcher v2 + restart the task ---------------------------------------------------
$launcher = Join-Path $KitDir 'autostart-comfy.ps1'
$localSrc = Join-Path $PSScriptRoot 'autostart-comfy.ps1'
if (Test-Path $localSrc) {
    if (-not (Select-String -Path $localSrc -Pattern 'Start-Ollama' -Quiet)) { throw "the autostart-comfy.ps1 next to this script is the old v1 (no Ollama support)" }
    Copy-Item $localSrc $launcher -Force
    Say "installed launcher v2: $launcher"
} elseif (-not (Select-String -Path $launcher -Pattern 'Start-Ollama' -Quiet)) {
    throw "launcher at $launcher is v1 and no v2 autostart-comfy.ps1 found next to this script"
}
Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue
# the launcher loop itself may keep running as a child of the old task; make sure it is gone
Get-CimInstance Win32_Process | Where-Object { $_.Name -match 'powershell' -and $_.CommandLine -match 'autostart-comfy\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Start-ScheduledTask -TaskName $Task
Say "restarted task $Task (ComfyUI instances untouched: ports still alive => watchdog leaves them alone)" 'Green'

# 5) verify ---------------------------------------------------------------------------
if (-not $Remove) {
    Say "waiting 25s for ollama instances ..." 'Cyan'
    Start-Sleep -Seconds 25
    foreach ($oi in $oinst) {
        $ok = Test-NetConnection 127.0.0.1 -Port $oi.port -WarningAction SilentlyContinue
        Say ("  gpu{0} port {1}: {2}" -f $oi.gpu, $oi.port, $(if ($ok.TcpTestSucceeded) { 'UP' } else { 'not yet (see ' + $KitDir + '\logs\ollama_gpu*.log)' }))
    }
    Say ""
    Say "=== nvidia-smi compute apps (expect ollama on BOTH gpu uuids once a model is loaded) ===" 'Yellow'
    nvidia-smi --query-compute-apps=gpu_uuid,pid,process_name,used_memory --format=csv
    Say ""
    Say "Pull/keep models as usual (they are shared by all instances, same models dir):" 'DarkGray'
    Say "    ollama list" 'DarkGray'
    Say "Warm the second instance once:  curl.exe http://127.0.0.1:$($oinst[1].port)/api/tags" 'DarkGray'
    Say ""
    Say "To reach instance #2 from wifemaker:" 'Cyan'
    Say "  same LAN  -> fill  http://<this box ip>:$($oinst[1].port)  (allow it once in Windows Firewall)" 'Gray'
    Say "  via tunnel -> in this box's cloudflared config.yml add, ABOVE the catch-all rule:" 'Gray'
    Say "      - hostname: 6000chat2.bestyiever.vip" 'Gray'
    Say "        service: http://localhost:$($oinst[1].port)" 'Gray'
    Say "     then:  cloudflared tunnel route dns <tunnel name> 6000chat2.bestyiever.vip ; Restart-Service <cloudflared svc>" 'Gray'
    Say "     and add 6000chat2.bestyiever.vip to the Cloudflare Access application that protects 6000chat" 'Gray'
    Say "     (same service token then works). In shoot-mode: Ollama = https://6000chat.bestyiever.vip, https://6000chat2.bestyiever.vip" 'Gray'
}
