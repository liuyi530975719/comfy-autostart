#Requires -RunAsAdministrator
# uninstall.ps1 -- remove the boot autostart. Leaves ComfyUI + cloudflared and
# any already-running processes untouched; only removes the scheduled task.
$ErrorActionPreference = 'SilentlyContinue'
$task = 'WaifumasterAutostart'
Stop-ScheduledTask   -TaskName $task
Unregister-ScheduledTask -TaskName $task -Confirm:$false
Write-Host "Removed scheduled task '$task'." -ForegroundColor Green
Write-Host "Kit files remain in C:\waifumaster-autostart (delete manually if you want)." -ForegroundColor DarkGray
Write-Host "If you enabled -AutoLogon, disable it with:" -ForegroundColor DarkGray
Write-Host "  Set-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' AutoAdminLogon '0'" -ForegroundColor DarkGray
Write-Host "Running ComfyUI/cloudflared are left alone. Reboot to fully stop, or kill them manually." -ForegroundColor DarkGray
