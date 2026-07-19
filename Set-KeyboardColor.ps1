# Set-KeyboardColor.ps1 — manually set a static color (stop the bridge first,
# or it will overwrite within 5 minutes).
param(
    [Parameter(Mandatory)][byte]$R,
    [Parameter(Mandatory)][byte]$G,
    [Parameter(Mandatory)][byte]$B
)
$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\GmmkHid.cs"
[AuraGmmkBridge.Gmmk]::Connect()
[AuraGmmkBridge.Gmmk]::SetStatic($R, $G, $B)
Write-Host "Keyboard set to static $R,$G,$B"
