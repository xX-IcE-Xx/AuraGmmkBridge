# Bridge.ps1 — Aura Sync -> Glorious GMMK RGB bridge.
# Watches the Aura 3.0 engine script that Armoury Crate writes whenever the lighting
# effect changes, maps the effect + color onto the closest GMMK onboard mode, and
# pushes it to the keyboard over HID.
#
# Usage:  .\Bridge.ps1          run the watch loop (for the scheduled task)
#         .\Bridge.ps1 -Once    parse + apply once, print what it did, exit
param(
    [switch]$Once
)

$ErrorActionPreference = 'Stop'
$AuraScript = 'C:\ProgramData\ASUS\RogAura30\SetV2EngineScript.xml'
$EneHalLog  = 'C:\ProgramData\ASUS\ARMOURY CRATE Diagnosis\OptionHAL\EneHal.log'
$LogFile    = "$PSScriptRoot\bridge.log"
$ConfigFile = "$PSScriptRoot\config.json"

Add-Type -Path "$PSScriptRoot\GmmkHid.cs"

$Config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
$script:profile = 0    # active onboard profile, refreshed on connect

# The keyboard occasionally drops a write right after a burst of commands
# (SetOutputReport succeeds but the firmware keeps the old value), so every
# brightness change is read back and retried until it sticks.
function Set-KbdBrightness([byte]$level) {
    for ($try = 1; $try -le 3; $try++) {
        [AuraGmmkBridge.Gmmk]::SetBrightness($level)
        Start-Sleep -Milliseconds 300
        $led = [AuraGmmkBridge.Gmmk]::ReadLedSettings($script:profile)
        if ($led -and $led[9] -eq $level) { return }
    }
    Write-Log "Brightness $level did not stick after 3 attempts"
}

function Write-Log([string]$msg) {
    $line = "{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $msg
    if ($Once) { Write-Host $line }
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 512KB) {
            Get-Content $LogFile -Tail 200 | Set-Content $LogFile
        }
        Add-Content $LogFile $line
    } catch {}
}

function Convert-HslToRgb([double]$h, [double]$s, [double]$l) {
    # standard HSL, h/s/l all 0..1; returns byte[3] R,G,B
    if ($s -eq 0) { $v = [byte][Math]::Round($l * 255); return @($v, $v, $v) }
    $q = if ($l -lt 0.5) { $l * (1 + $s) } else { $l + $s - $l * $s }
    $p = 2 * $l - $q
    $rgb = foreach ($t in (($h + 1/3), $h, ($h - 1/3))) {
        if ($t -lt 0) { $t += 1 }; if ($t -gt 1) { $t -= 1 }
        $c = if ($t -lt 1/6) { $p + ($q - $p) * 6 * $t }
             elseif ($t -lt 1/2) { $q }
             elseif ($t -lt 2/3) { $p + ($q - $p) * (2/3 - $t) * 6 }
             else { $p }
        [byte][Math]::Round($c * 255)
    }
    return $rgb
}

function Get-AuraState {
    # Returns @{ Effect = 'Star'; R=..; G=..; B=.. } or $null on parse failure
    try {
        [xml]$xml = Get-Content $AuraScript -Raw
    } catch { return $null }

    $effects = @($xml.SelectNodes('//effect[initColor]'))
    if ($effects.Count -eq 0) { return $null }

    # Effect keys look like "StarSingleEff0" / "StaticBackGroundSingleEff3".
    # The primary effect is the non-background one; pure static setups only have the background.
    $primary = $null
    foreach ($e in $effects) {
        $base = $e.key -replace 'SingleEff\d*$','' -replace '\d+$',''
        if ($base -and $base -ne 'StaticBackGround') { $primary = @{ Name = $base; Node = $e }; break }
    }
    if (-not $primary) {
        $e = $effects | Where-Object { $_.key -match '^StaticBackGround' } | Select-Object -First 1
        if (-not $e) { $e = $effects[0] }
        $primary = @{ Name = 'Static'; Node = $e }
    }

    $init = $primary.Node.initColor
    if (-not $init) { return $null }
    $rgb = Convert-HslToRgb ([double]$init.hue) ([double]$init.saturation) ([double]$init.lightness)

    # HSL lightness 0.5 is full saturation; Aura static uses ~0.5. Boost very dim
    # backgrounds so the keyboard isn't near-black on static-only profiles.
    if (($rgb[0] + $rgb[1] + $rgb[2]) -lt 30) {
        $rgb = Convert-HslToRgb ([double]$init.hue) ([double]$init.saturation) 0.5
    }

    return @{ Effect = $primary.Name; R = $rgb[0]; G = $rgb[1]; B = $rgb[2] }
}

function Apply-ToKeyboard($state) {
    # Starry Night is special: it gets the effect pinned in config.json
    # (captured off the keyboard by Capture-CurrentEffect.ps1).
    # Speed values are raw wire bytes: 0 = fastest, 3 = slowest.
    if ($state.Effect -match '^Star') {
        $pin = $Config.starryNight
        [AuraGmmkBridge.Gmmk]::SetMode([byte]$pin.mode)
        [AuraGmmkBridge.Gmmk]::SetSpeed([byte]$pin.speed)
        if ($pin.useAuraColor) {
            [AuraGmmkBridge.Gmmk]::SetColor($state.R, $state.G, $state.B)
        } else {
            [AuraGmmkBridge.Gmmk]::SetColor([byte]$pin.rgb[0], [byte]$pin.rgb[1], [byte]$pin.rgb[2])
        }
        # verify the mode took; retry once if the firmware dropped the burst
        $led = [AuraGmmkBridge.Gmmk]::ReadLedSettings($script:profile)
        if ($led -and $led[8] -ne $pin.mode) {
            Start-Sleep -Milliseconds 300
            [AuraGmmkBridge.Gmmk]::SetMode([byte]$pin.mode)
        }
        Write-Log ("Applied pinned mode 0x{0:X2} for Aura effect 'Star' (Starry Night)" -f [int]$pin.mode)
        return
    }

    # Map remaining Aura effect names to the closest GMMK onboard mode
    $mode = switch -Regex ($state.Effect) {
        '^Static'            { 'static'; break }
        '^Breath'            { 0x05;     break }   # breathing (single color)
        '^Strob|^Flash'      { 0x02;     break }   # pulse
        '^Rainbow|^Wave'     { 0x01;     break }   # horizontal wave
        '^ColorCycle|^Cycle' { 0x04;     break }   # breathing color (hue cycle)
        '^Comet|^Meteor'     { 0x10;     break }   # diagonal wave
        default              { 'static'; break }
    }

    if ($mode -eq 'static') {
        [AuraGmmkBridge.Gmmk]::SetStatic($state.R, $state.G, $state.B)
        Write-Log ("Applied STATIC  R={0} G={1} B={2}  (Aura effect '{3}')" -f $state.R, $state.G, $state.B, $state.Effect)
    } else {
        [AuraGmmkBridge.Gmmk]::SetMode([byte]$mode)
        [AuraGmmkBridge.Gmmk]::SetSpeed([byte]$Config.animationSpeed)
        [AuraGmmkBridge.Gmmk]::SetColor($state.R, $state.G, $state.B)
        Write-Log ("Applied mode 0x{0:X2}  R={1} G={2} B={3}  (Aura effect '{4}')" -f [int]$mode, $state.R, $state.G, $state.B, $state.Effect)
    }
}

# --- EneHal.log tail: on/off detection ----------------------------------------
# Armoury Crate's ENE DRAM HAL streams per-LED frames ("SetEft...Color:...") while
# lighting is on; "Aura off" writes all-zero frames and the stream stops. We tail
# the log: last frame black + stream idle -> lighting is off.

$script:enePos          = -1                 # file offset already consumed
$script:eneLastFrameOff = $false             # last seen SetEft frame was all-zero
$script:eneLastActivity = [datetime]::MinValue

function Read-EneChunk([long]$from, [long]$to) {
    $fs = [System.IO.File]::Open($EneHalLog, 'Open', 'Read', [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    try {
        $fs.Seek($from, 'Begin') | Out-Null
        $buf = New-Object byte[] ($to - $from)
        $n = $fs.Read($buf, 0, $buf.Length)
        return [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
    } finally { $fs.Dispose() }
}

function Update-EneState {
    # Returns 'off', 'on', or $null (nothing new / unknown). Also maintains script state.
    $f = Get-Item $EneHalLog -ErrorAction SilentlyContinue
    if (-not $f) { return $null }

    if ($script:enePos -lt 0 -or $f.Length -lt $script:enePos) {
        # first run or log rotated: read only the last 64KB to find current state
        $script:enePos = [Math]::Max(0, $f.Length - 64KB)
        $script:eneLastActivity = $f.LastWriteTimeUtc
    }

    $newData = $false
    if ($f.Length -gt $script:enePos) {
        $text = Read-EneChunk $script:enePos $f.Length
        $script:enePos = $f.Length
        $frames = [regex]::Matches($text, 'SetEft\(Idx:\d+\)[^,]*,Color:([0-9A-Fa-f,]+)')
        if ($frames.Count -gt 0) {
            $newData = $true
            $script:eneLastActivity = (Get-Date).ToUniversalTime()
            $last = $frames[$frames.Count - 1].Groups[1].Value.TrimEnd(',')
            $script:eneLastFrameOff = -not (($last -split ',') | Where-Object { $_ -notmatch '^0+$' })
        }
    }

    if ($newData -and -not $script:eneLastFrameOff) { return 'on' }
    # off = last frame black and the stream has been quiet for a few seconds
    if ($script:eneLastFrameOff -and ((Get-Date).ToUniversalTime() - $script:eneLastActivity).TotalSeconds -gt 8) { return 'off' }
    return $null
}

# --- main ---------------------------------------------------------------------

# single-instance guard (a killed instance leaves the mutex abandoned; that still
# counts as acquired)
$mutex = New-Object System.Threading.Mutex($false, 'Global\AuraGmmkBridge')
try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) { Write-Log 'Another instance is running; exiting.'; exit 0 }

try {
    [AuraGmmkBridge.Gmmk]::Connect()
    Write-Log ([AuraGmmkBridge.Gmmk]::Status)
    $info = [AuraGmmkBridge.Gmmk]::ReadState()
    if ($info) { $script:profile = $info[18] }

    $lastWrite = [datetime]::MinValue
    $lastApply = [datetime]::MinValue
    $lastState = ''
    $kbdOff    = $false

    # initial state: if the last HAL frame on record is black, lighting is off right now
    Update-EneState | Out-Null
    if ($script:eneLastFrameOff) {
        try {
            Set-KbdBrightness 0
            $kbdOff    = $true
            $lastWrite = (Get-Item $AuraScript -ErrorAction SilentlyContinue).LastWriteTimeUtc
            Write-Log 'Startup: Aura lighting is OFF -> keyboard RGB off'
        } catch { Write-Log "Startup off apply failed: $_" }
    }

    while ($true) {
        # --- lighting on/off tracking via ENE HAL frame stream ---
        $eneState = Update-EneState
        if ($eneState -eq 'off' -and -not $kbdOff) {
            try {
                Set-KbdBrightness 0
                $kbdOff = $true
                Write-Log 'Aura lighting is OFF -> keyboard RGB off'
            } catch { Write-Log "Off apply failed: $_" }
        }
        elseif ($eneState -eq 'on' -and $kbdOff) {
            $kbdOff    = $false
            $lastState = ''                       # force re-apply of current effect
            $lastApply = [datetime]::MinValue
            try { Set-KbdBrightness ([byte]$Config.brightness) } catch {}
            Write-Log 'Aura lighting is back ON -> restoring effect'
        }

        $doApply = $false
        $mtime = (Get-Item $AuraScript -ErrorAction SilentlyContinue).LastWriteTimeUtc
        if ($mtime -and $mtime -ne $lastWrite) { $doApply = $true; $kbdOff = $false }
        # periodic re-apply heals unplug/replug and sleep-resume
        if (((Get-Date).ToUniversalTime() - $lastApply).TotalMinutes -ge 5) { $doApply = $true }
        if ($kbdOff) { $doApply = $false }

        if ($doApply) {
            $state = Get-AuraState
            if ($state) {
                $key = '{0}|{1}|{2}|{3}' -f $state.Effect, $state.R, $state.G, $state.B
                try {
                    Apply-ToKeyboard $state
                    if ($key -ne $lastState) { Set-KbdBrightness ([byte]$Config.brightness) }
                    $lastState = $key
                    $lastWrite = $mtime
                    $lastApply = (Get-Date).ToUniversalTime()
                } catch {
                    Write-Log "Apply failed: $_"
                    Start-Sleep -Seconds 10
                    try { [AuraGmmkBridge.Gmmk]::Connect() } catch {}
                }
            } else {
                Write-Log "Could not parse Aura state from $AuraScript"
                $lastWrite = $mtime
                $lastApply = (Get-Date).ToUniversalTime()
            }
        }

        if ($Once) { break }
        Start-Sleep -Seconds 3
    }
}
finally {
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
}
