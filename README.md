# comfy-autostart

One PowerShell command per **Windows GPU box** makes **ComfyUI (one instance per
GPU) + the cloudflared tunnel start automatically on every boot, with no login**,
and keeps them alive with a watchdog that auto-restarts anything that dies
(handy for boxes that reboot themselves).

**Install-location agnostic.** It finds ComfyUI wherever it lives on the box and
works with both the **git-clone + `venv`** layout and the **portable
`ComfyUI_windows_portable` + `python_embeded`** build. Nothing is hardcoded to
one machine — anything auto-detection misses can be passed as a flag.

> This only **autostarts an existing ComfyUI install** — it does not install
> ComfyUI itself.

## Install (per box)
Open **PowerShell as Administrator** and paste:

```powershell
$R='https://raw.githubusercontent.com/liuyi530975719/comfy-autostart/main'
$d="$env:TEMP\comfy-autostart"; New-Item $d -Type Directory -Force | Out-Null
iwr "$R/bootstrap.ps1"       -OutFile "$d\bootstrap.ps1"
iwr "$R/autostart-comfy.ps1" -OutFile "$d\autostart-comfy.ps1"
& "$d\bootstrap.ps1"
```

It auto-detects everything and starts services immediately (no reboot needed to
verify). `bootstrap.ps1` finds `autostart-comfy.ps1` next to it, so there is no
second network fetch at runtime.

### If a box needs a hint
Installs differ per box, so pass overrides when needed:

```powershell
# portable build in a custom folder
& "$d\bootstrap.ps1" -MainPy 'D:\ComfyUI_windows_portable\ComfyUI\main.py' `
                     -Python 'D:\ComfyUI_windows_portable\python_embeded\python.exe'

# pin ports (e.g. dual-GPU box -> 8190 for GPU0, 8189 for GPU1)
& "$d\bootstrap.ps1" -Ports 8190,8189

# low-VRAM card throwing CUDA OOM on upscale
& "$d\bootstrap.ps1" -ExtraArgs '--normalvram'

# only if a box can't see its GPU headless: also enable Windows auto-login
& "$d\bootstrap.ps1" -AutoLogon
```

Defaults if you pass nothing: ports `8190, 8189, 8191, 8192...` (GPU0 first),
ComfyUI args `--highvram`, cloudflared service auto-detected, task runs at
startup as the current user with **no stored password** (LogonType S4U).

## Verify
```powershell
Get-ScheduledTask WaifumasterAutostart | Get-ScheduledTaskInfo
Get-Content C:\waifumaster-autostart\logs\autostart.log -Tail 20
curl.exe http://127.0.0.1:8190/system_stats      # expect JSON with your GPU
```
Then reboot once to confirm it comes back on its own.

## Uninstall
```powershell
& C:\waifumaster-autostart\uninstall.ps1
```

## Notes
- **No password by default.** The scheduled task uses LogonType **S4U** ("run
  whether logged on or not"), which stores no password and needs no login.
  Windows CUDA *compute* normally works this way. Only if a specific box can't
  see its GPU headless do you need `-AutoLogon` (that stores the login in the
  registry — fine for a dedicated render box, not a shared PC).
- **cloudflared** is set to Automatic + started (belt-and-suspenders; services
  already come back on boot). If a box's tunnel isn't a Windows service, that
  box's tunnel isn't managed here.
- **Re-runnable / idempotent.** Re-running `bootstrap.ps1` just refreshes the
  config + task.
- Config + logs live in `C:\waifumaster-autostart\` (one log per GPU instance).
