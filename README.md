# AuraGmmkBridge

Sync ASUS Aura / Armoury Crate lighting to a Glorious GMMK keyboard — a board
Armoury Crate cannot control natively, since Aura Sync only supports
ASUS/Aura-partner hardware.

No OpenRGB, SignalRGB, or Glorious Core required at runtime: this is a small
PowerShell + C# bridge that reads what Armoury Crate is currently displaying and
drives the keyboard's onboard RGB controller directly over HID. Sibling project
of [AuraGpuBridge](https://github.com/xX-IcE-Xx/AuraGpuBridge), which does the
same for an MSI GPU.

## How it works

- **`GmmkHid.cs`** — talks to the keyboard's vendor HID collection (64-byte
  reports, ID `0x04`, 16-bit checksum). Compiled in-memory by PowerShell's
  `Add-Type`; no SDK or build step needed. The protocol was derived from USB
  captures of the official Glorious editor
  ([OpenRGB issue #2935](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/2935))
  and prior reverse engineering of the older GMMK revision in
  [dokutan/rgb_keyboard](https://github.com/dokutan/rgb_keyboard) and
  [francisrstokes/GMMK-Driver](https://github.com/francisrstokes/GMMK-Driver).
- **`Bridge.ps1`** — the watch loop:
  - Watches `C:\ProgramData\ASUS\RogAura30\SetV2EngineScript.xml`, which Armoury
    Crate rewrites whenever you change effect or color. Parses the effect name and
    HSL color, and maps it to the closest GMMK onboard mode.
  - Tails `C:\ProgramData\ASUS\ARMOURY CRATE Diagnosis\OptionHAL\EneHal.log` to
    detect the global lighting on/off toggle (brightness 0 = LEDs off). Expect
    roughly a 10-second lag on off/on.
  - Settings are stored in the keyboard's onboard memory, so it powers up
    already matching your scheme.
  - Logs decisions to `bridge.log` (self-trims at 512 KB).

### Effect mapping

| Aura effect          | GMMK onboard mode |
|----------------------|-------------------|
| Static               | Fixed             |
| Breathing            | Breathing         |
| Strobing             | Pulse             |
| Rainbow / Wave       | Horizontal wave   |
| Color Cycle          | Breathing color   |
| Comet                | Diagonal wave     |
| **Starry Night**     | **your pinned effect** (see below) |
| anything else        | Fixed (effect's color) |

Tweak it in the `switch` table inside `Apply-ToKeyboard` in `Bridge.ps1`.

### Pinning a favorite effect to Starry Night

Set your favorite onboard effect on the keyboard (Fn shortcuts or Glorious
Core), then run:

```powershell
.\Capture-CurrentEffect.ps1
```

This reads the current mode/speed/color off the keyboard and stores it in
`config.json`. From then on, selecting **Starry Night** in Armoury Crate shows
exactly that effect on the keyboard. Set `useAuraColor: true` in `config.json`
if you want the pinned effect to follow the Aura color instead of the captured
one.

## Requirements

- Glorious GMMK v1, 2021 revision (USB `320F:5064`, SONiX platform — the ID the
  keyboard reports on the `GMMK-RGB` TKL and full-size). The older `0C45:652F`
  revision speaks the same protocol family and likely works by changing
  `VidPid` in `GmmkHid.cs`, but is untested here.
- ASUS motherboard with Armoury Crate (tested: ROG Crosshair X870E Hero,
  Armoury Crate 6.5.7, Aura 3.0 / `RogAura30` plugin).
- Windows 11, PowerShell 7.

## Install

```powershell
git clone https://github.com/xX-IcE-Xx/AuraGmmkBridge
cd AuraGmmkBridge
.\Bridge.ps1 -Once     # test: applies the current Aura state to the keyboard once
.\Install-Task.ps1     # register the hidden autostart scheduled task
```

Remove with `Unregister-ScheduledTask AuraGmmkBridge`.

## Utilities

- `Capture-CurrentEffect.ps1` — pin the keyboard's current effect to Starry Night.
- `Set-KeyboardColor.ps1 -R 255 -G 0 -B 0` — manually set a static color (stop
  the bridge first, or it will overwrite within 5 minutes).

## Caveats

- Reverse-engineered against Armoury Crate 6.5.7's on-disk files; an ASUS update
  that changes those formats will break parsing (check `bridge.log`).
- Don't run alongside Glorious Core / OpenRGB / SignalRGB — two writers, one
  keyboard.
- Commands sent are the same ones the official Glorious editor sends, but as
  with anything that pokes hardware: use at your own risk.

## Credits & license

GPL-3.0-or-later (see `LICENSE`). The HID protocol understanding builds on
[dokutan/rgb_keyboard](https://github.com/dokutan/rgb_keyboard) (GPLv3),
[francisrstokes/GMMK-Driver](https://github.com/francisrstokes/GMMK-Driver),
and the USB captures shared in
[OpenRGB issue #2935](https://gitlab.com/CalcProgrammer1/OpenRGB/-/issues/2935)
— this tool exists because of their work.
