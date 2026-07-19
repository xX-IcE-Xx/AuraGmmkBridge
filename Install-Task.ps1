# Install-Task.ps1 — register the AuraGmmkBridge scheduled task (hidden, at logon).
# Run from the folder containing Bridge.ps1.
$ErrorActionPreference = 'Stop'

# Task Scheduler can't resolve bare "pwsh.exe" for Store installs, and the real
# WindowsApps package path is version-pinned (breaks on updates) — prefer the
# stable per-user alias, then the current process, then PATH.
$pwshPath = "$env:LOCALAPPDATA\Microsoft\WindowsApps\pwsh.exe"
if (-not (Test-Path $pwshPath)) { $pwshPath = (Get-Process -Id $PID).Path }
if (-not $pwshPath -or $pwshPath -notmatch 'pwsh') { $pwshPath = 'pwsh.exe' }

$bridge   = Join-Path $PSScriptRoot 'Bridge.ps1'

# Launch through "conhost --headless": on Windows 11 a console app started by an
# interactive task gets hosted by the user's default terminal (Windows Terminal),
# so closing the terminal window kills the bridge with 0xC000013A. Forcing a
# headless classic conhost keeps the bridge alive with no window at all.
$action   = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
                -Argument "--headless `"$pwshPath`" -NoProfile -ExecutionPolicy Bypass -File `"$bridge`""
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName 'AuraGmmkBridge' -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Sync ASUS Aura lighting effect to Glorious GMMK keyboard RGB (AuraGmmkBridge)' -Force | Out-Null
Start-ScheduledTask -TaskName 'AuraGmmkBridge'

Write-Host "AuraGmmkBridge task registered and started ($pwshPath)."
Write-Host "Watch $PSScriptRoot\bridge.log to see what it's doing."
