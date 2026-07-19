# Capture-CurrentEffect.ps1 — read the keyboard's current onboard effect and pin
# it as the Starry Night effect in config.json.
# Set your favorite effect on the keyboard first (Fn shortcuts or Glorious Core),
# then run this.
$ErrorActionPreference = 'Stop'
Add-Type -Path "$PSScriptRoot\GmmkHid.cs"

[AuraGmmkBridge.Gmmk]::Connect()
$info = [AuraGmmkBridge.Gmmk]::ReadState()
if (-not $info) { throw 'No reply from keyboard (device info query)' }
$profile = $info[18]

$led = [AuraGmmkBridge.Gmmk]::ReadLedSettings($profile)
if (-not $led) { throw 'No reply from keyboard (LED settings query)' }

$modeNames = @{ 1='horizontal wave'; 2='pulse'; 3='hurricane'; 4='breathing color'; 5='breathing';
    6='fixed/static'; 7='reactive single'; 8='reactive ripple'; 9='reactive horizontal'; 10='waterfall';
    11='swirl'; 12='vertical wave'; 13='sine'; 14='vortex'; 15='rain'; 16='diagonal wave';
    17='reactive color'; 18='ripple'; 19='off'; 20='custom' }

$captured = [ordered]@{
    comment      = "Onboard effect pinned to Armoury Crate's Starry Night. Re-capture with Capture-CurrentEffect.ps1. mode {0} = {1}." -f $led[8], $modeNames[[int]$led[8]]
    mode         = [int]$led[8]
    speed        = [int]$led[10]    # raw wire byte: 0 = fastest, 3 = slowest
    direction    = [int]$led[11]
    rgb          = @([int]$led[13], [int]$led[14], [int]$led[15])
    useAuraColor = $false
}

$configFile = "$PSScriptRoot\config.json"
$config = Get-Content $configFile -Raw | ConvertFrom-Json
$config.starryNight = [pscustomobject]$captured
$config | ConvertTo-Json -Depth 5 | Set-Content $configFile

Write-Host ("Captured: mode {0} ({1}), raw speed {2}, rgb {3},{4},{5} -> pinned to Starry Night in config.json" -f `
    $led[8], $modeNames[[int]$led[8]], $led[10], $led[13], $led[14], $led[15])
