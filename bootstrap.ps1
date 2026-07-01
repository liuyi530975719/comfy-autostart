#Requires -RunAsAdministrator
<#
  bootstrap.ps1  --  one-click boot autostart for a waifumaster fleet GPU box.

  Run ONCE per box in an ADMIN PowerShell. It detects ComfyUI + GPUs +
  cloudflared, installs a resilient boot launcher, and registers a scheduled
  task that starts everything on boot WITHOUT anyone logging in.

  Quick run (after you push this kit to GitHub -- see README):
    $R='https://raw.githubusercontent.com/<you>/wifemaker-comfy-addons/main/autostart-kit'
    $b="$env:TEMP\wm-bootstrap.ps1"; irm "$R/bootstrap.ps1" -OutFile $b; & $b -RepoRaw $R

  Params:
    -ComfyDir <path>     ComfyUI folder (auto-detected if omitted)
    -RepoRaw  <url>      raw GitHub base to fetch autostart-comfy.ps1 from
                         (omit if running from the kit folder)
    -Ports    8190,8189  ports per GPU (default 8190,8189,8191,8192)
    -ExtraArgs '--highvram'   extra ComfyUI args (default --highvram)
    -CloudflaredService <name>   override auto-detected service name
    -AutoLogon           also enable Windows auto-login (needed only if a box
                         can't see its GPU headless; prompts for password)
  ASCII only.
#>
param(
    [string]$ComfyDir = "",        # ComfyUI root (auto-detected if omitted)
    [string]$MainPy = "",          # explicit path to main.py (overrides detection)
    [string]$Python = "",          # explicit python.exe (venv or embedded)
    [string]$RepoRaw = $env:WM_REPO_RAW,
    [int[]]$Ports = @(),
    [string]$ExtraArgs = "--highvram",
    [string]$CloudflaredService = "",
    [switch]$AutoLogon
)
$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

$KitDir = 'C:\waifumaster-autostart'
New-Item -ItemType Directory -Force -Path $KitDir | Out-Null

# 1) locate ComfyUI (layout-agnostic) ---------------------------------------
# Handles: git clone + venv, ComfyUI_windows_portable + python_embeded, custom
# folders, any drive letter. main.py may sit at <root>\main.py OR
# <root>\ComfyUI\main.py (portable nests it). Nothing is hardcoded to one box.
function Resolve-MainPy {
    if ($MainPy -and (Test-Path $MainPy)) { return (Resolve-Path $MainPy).Path }
    $roots = @()
    if ($ComfyDir) { $roots += $ComfyDir }
    foreach ($d in @('C', 'D', 'E', 'F', 'G', 'H')) {
        foreach ($n in @('ComfyUI', 'comfyui', 'ComfyUI_windows_portable',
                'waifumaster\ComfyUI', 'StableDiffusion\ComfyUI', 'AI\ComfyUI',
                'apps\ComfyUI', 'tools\ComfyUI')) {
            $roots += "${d}:\$n"
        }
    }
    foreach ($root in $roots) {
        if (-not $root) { continue }
        foreach ($mp in @((Join-Path $root 'main.py'), (Join-Path $root 'ComfyUI\main.py'))) {
            if (Test-Path $mp) { return (Resolve-Path $mp).Path }
        }
    }
    # bounded scan: any top-level folder whose name contains "comfy"
    foreach ($d in @('C', 'D', 'E', 'F', 'G')) {
        $dirs = Get-ChildItem "${d}:\" -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'comfy' }
        foreach ($dir in $dirs) {
            foreach ($mp in @((Join-Path $dir.FullName 'main.py'), (Join-Path $dir.FullName 'ComfyUI\main.py'))) {
                if (Test-Path $mp) { return (Resolve-Path $mp).Path }
            }
        }
    }
    return $null
}
$MainPyPath = Resolve-MainPy
if (-not $MainPyPath) {
    throw "ComfyUI main.py not found. Re-run with -MainPy 'X:\...\ComfyUI\main.py' (and -Python if needed)."
}
$WorkDir = Split-Path -Parent $MainPyPath

# pick python: explicit -> project venv -> portable python_embeded -> system
$PyArgs = ''
if ($Python -and (Test-Path $Python)) {
    $Py = (Resolve-Path $Python).Path
} else {
    $parent = Split-Path -Parent $WorkDir
    $cands = @(
        (Join-Path $WorkDir 'venv\Scripts\python.exe'),
        (Join-Path $WorkDir '.venv\Scripts\python.exe'),
        (Join-Path $parent 'venv\Scripts\python.exe'),
        (Join-Path $parent 'python_embeded\python.exe'),
        (Join-Path $WorkDir 'python_embeded\python.exe')
    )
    $Py = $cands | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $Py) {
        $c = Get-Command python.exe -ErrorAction SilentlyContinue
        $Py = if ($c) { $c.Source } else { 'python' }
    }
}
if ($Py -match 'python_embeded') { $PyArgs = '-s' }   # portable build wants -s
Say "main.py : $MainPyPath" 'Cyan'
Say "workdir : $WorkDir" 'Cyan'
Say "python  : $Py $PyArgs" 'Cyan'

# 2) detect GPU count + assign ports ----------------------------------------
$gpuCount = 1
try {
    $idx = & nvidia-smi --query-gpu=index --format=csv,noheader 2>$null
    if ($idx) { $gpuCount = ($idx | Measure-Object).Count }
} catch { }
if ($gpuCount -lt 1) { $gpuCount = 1 }
$defaultPorts = @(8190, 8189, 8191, 8192, 8193, 8194, 8195, 8196)
$instances = @()
for ($i = 0; $i -lt $gpuCount; $i++) {
    $port = if ($i -lt $Ports.Count) { $Ports[$i] } else { $defaultPorts[$i] }
    $instances += @{ gpu = $i; port = $port }
}
Say ("GPUs    : {0}  ->  {1}" -f $gpuCount, (($instances | ForEach-Object { "gpu$($_.gpu):$($_.port)" }) -join ', ')) 'Cyan'

# 3) find the cloudflared service -------------------------------------------
if (-not $CloudflaredService) {
    $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'cloudflared' -or $_.DisplayName -match 'cloudflared' } | Select-Object -First 1
    if ($svc) { $CloudflaredService = $svc.Name }
}
Say ("cloudflared service: {0}" -f ($(if ($CloudflaredService) { $CloudflaredService } else { '(none found -- tunnel autostart not managed here)' }))) 'Cyan'

# 4) write config -----------------------------------------------------------
$cfg = [ordered]@{
    work_dir             = $WorkDir
    main_py              = $MainPyPath
    python               = $Py
    py_args              = $PyArgs
    extra_args           = $ExtraArgs
    cloudflared_service  = $CloudflaredService
    instances            = $instances
}
($cfg | ConvertTo-Json -Depth 6) | Set-Content -Path (Join-Path $KitDir 'autostart.config.json') -Encoding ASCII
Say "wrote  : $KitDir\autostart.config.json"

# 5) place the launcher -----------------------------------------------------
$launcher = Join-Path $KitDir 'autostart-comfy.ps1'
$localSrc = Join-Path $PSScriptRoot 'autostart-comfy.ps1'
if (Test-Path $localSrc) {
    Copy-Item $localSrc $launcher -Force
} elseif ($RepoRaw) {
    Invoke-WebRequest -Uri "$RepoRaw/autostart-comfy.ps1" -OutFile $launcher -UseBasicParsing
} else {
    throw "autostart-comfy.ps1 not found. Run from the kit folder, or pass -RepoRaw <github raw base>."
}
Say "wrote  : $launcher"

# 6) optional auto-login (only if a box can't see its GPU headless) ---------
if ($AutoLogon) {
    $u = Read-Host "Auto-login username (blank = $env:USERNAME)"
    if (-not $u) { $u = $env:USERNAME }
    $sec = Read-Host "Password for $u (typed on THIS machine only, stored by Windows)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    $pw = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Set-ItemProperty $wl 'AutoAdminLogon' '1'
    Set-ItemProperty $wl 'DefaultUserName' $u
    Set-ItemProperty $wl 'DefaultPassword' $pw
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null
    Say "auto-login enabled for $u (dedicated GPU box only)" 'Yellow'
}

# 7) make sure cloudflared comes back on boot too ---------------------------
if ($CloudflaredService) {
    Set-Service -Name $CloudflaredService -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name $CloudflaredService -ErrorAction SilentlyContinue
    Say "cloudflared service set to Automatic + running"
}

# 8) register the boot task -------------------------------------------------
$taskName = 'WaifumasterAutostart'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NoProfile -File `"$launcher`""
$triggers = @(New-ScheduledTaskTrigger -AtStartup)
if ($AutoLogon) { $triggers += New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME }
# S4U = "run whether logged on or not" with NO stored password. AtLogOn added
# only when auto-login is on (gives a real interactive session for the GPU).
$principal = if ($AutoLogon) {
    New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
} else {
    New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType S4U -RunLevel Highest
}
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit ([TimeSpan]::Zero)
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $triggers `
    -Principal $principal -Settings $settings `
    -Description 'Boot autostart: ComfyUI per GPU + cloudflared (waifumaster fleet)' | Out-Null
Say "registered scheduled task: $taskName (AtStartup, no login needed)" 'Green'

# 9) start it now so you don't have to reboot to verify ---------------------
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 12
Say ""
Say "=== done ===" 'Green'
foreach ($inst in $instances) {
    $ok = Test-NetConnection 127.0.0.1 -Port $inst.port -WarningAction SilentlyContinue
    Say ("  gpu{0} port {1}: {2}" -f $inst.gpu, $inst.port, $(if ($ok.TcpTestSucceeded) { 'UP' } else { 'starting... (check logs in ' + $KitDir + '\logs)' }))
}
Say ""
Say "Logs: $KitDir\logs\autostart.log  +  per-instance comfy logs." 'DarkGray'
Say "Verify externally once up:  curl.exe https://<this-box-subdomain>/system_stats" 'DarkGray'
Say "Uninstall:  & '$KitDir\uninstall.ps1'   (or run uninstall.ps1 from the kit)" 'DarkGray'
