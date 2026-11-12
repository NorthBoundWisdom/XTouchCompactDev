# Existing X-TOUCH COMPACT software and reference research

Verified against repository content and product documentation on 2026-11-11.

## Priority 1 — directly useful, permissive

### JetsonHacks/xtouch-compact (MIT)

- URL: https://github.com/jetsonhacks/xtouch-compact
- Purpose: Python typed control surface driver for *exactly the X-TOUCH COMPACT*, with faders, LED rings, buttons, layer, touch ownership, initialization and reconnection.
- Host: Linux ALSA Sequencer, Python 3.10+. **Not usable as-is in macOS Swift/CoreMIDI.**
- Scope: factory Standard MIDI mode; not MC mode nor arbitrary editor-modified presets.
- Best reuse: protocol facts, state-machine behaviors, hardware-observed exceptions, test scenarios. Port the concepts to Swift; reuse actual code only in compliance with its MIT notice obligations.
- Key files: `docs/xtouch-compact-midi.md`, `docs/hardware-observations.md`, `src/xtouch_compact/factory_profile.py`, `src/xtouch_compact/state.py`, `tests/`.
- License: MIT (`LICENSE`), permissive including commercial use with required notices.

## Priority 2 — physical resolution and advanced firmware research

### lem120/xtouch-compact-fader-resolution

- URL: https://github.com/lem120/xtouch-compact-fader-resolution
- Research has measured effectively 7-bit stock Mackie fader transmission: standard 14-bit MIDI Pitch Bend messages with low byte usually zero.
- Investigated firmware receive/transmit instructions and prototyped higher-resolution fader data, host-owned relative encoders and LED synchronization.
- As of repo's 2026-11-01 status: maintained TEST03c is a *development* baseline, **not a published installation package**; public firmware/download is in preparation. Do not describe repository ZIP as an installable firmware.
- Not a foundation dependency for P0. Firmware flashing, checksum/variant compatibility and recovery must be treated as a separate, opt-in R&D effort.
- Public release and redistribution rights must be checked before using modified firmware or source.

## Priority 3 — useful UI and sync patterns, noncommercial license

### lfpoulain/py-mix-panel

- URL: https://github.com/lfpoulain/py-mix-panel
- Windows/PySide6 + vMix application with a graphical twin of the Compact, page mapping, MIDI Learn-like control assignment, touch-aware motor feedback, coalescing, macro/actions, LED status and reconnect handling.
- Very good **behavioral/UI inspiration** for the BCRAgentConsole port.
- License: **PolyForm Noncommercial 1.0.0**. Do not copy its code into a potentially commercial/productized app without a separate applicable license. Merely studying publicly documented behavior is different from copying implementation.

## Priority 4 — DAW compatibility examples

### Quuikz/x-touch-compact-hui-translator

- URL: https://github.com/Quuikz/x-touch-compact-hui-translator
- Python/mido/python-rtmidi, macOS, translates Compact MC-mode events into basic Pro Tools HUI; covers fader touch, motor return, mute/solo/transport, first eight encoders.
- Useful if DAW integration later matters, but not needed for Agent console's native Standard mode.
- No LICENSE file was found via repository lookup during this survey. Do not copy source unless use permissions are clarified.

### alexpineda/Behringer-X-Touch-Compact-FL-Script

- URL: https://github.com/alexpineda/Behringer-X-Touch-Compact-FL-Script
- Python FL Studio script based on MCU translation, including touch-fader button behavior and DAW-specific mapping. Not a generic macOS device layer.

### SINTEF-9012/node-red-contrib-midi-xtouch

- URL: https://github.com/SINTEF-9012/node-red-contrib-midi-xtouch
- Legacy Node-RED parser/generator for Compact MIDI; secondary protocol cross-check.

### xetyr/MIDI2LR-X-Touch-Compact-config

- URL: https://github.com/xetyr/MIDI2LR-X-Touch-Compact-config
- Real-world X-TOUCH Editor preset data for Lightroom MIDI2LR; useful to check imported presets and mapping variability.

## Different model — design reference only

### Aldaviva/BehringerXTouchExtender (Apache-2.0)

- URL: https://github.com/Aldaviva/BehringerXTouchExtender
- Reviewed 2026-11-12 at commit `029a5a5` (local ignored checkout under `Downloads/`).
- C#/.NET Standard 2.0 library for the **X-TOUCH EXTENDER** in `Ctrl`, `CtrlRel` and HUI modes (no MC mode), built on DryWetMIDI and KoKo. Bundles the shared X-TOUCH/EXTENDER MIDI-mode PDF and EXTENDER firmware images.
- **Protocol is not applicable to the COMPACT.** EXTENDER `Ctrl` mode uses symmetric addresses (fader CC 70–77 in and out, touch Note 110–117, rings and encoders both CC 80–87, LED velocity 0–63 off / 64 blink / 65–127 on, LCD SysEx `F0 00 20 32 15 4C …`). The COMPACT Standard map uses asymmetric TX/RX addresses, CC touch, and 0/1/2 (manual) or 0/2/3 (observed 1.14) LED velocities; see [MIDI_PROTOCOL.md](MIDI_PROTOCOL.md).
- Useful design patterns: separate `DesiredPosition` and `ActualPosition` fader properties; motor writes skipped while the fader is touched; one codec class per hardware mode behind a shared control interface, a possible shape for a future MC codec; the relative encoder accepts only 65 (clockwise) and 1 (counterclockwise) and drops other values, so acceleration needs explicit handling; device I/O behind a mockable factory for full deterministic coverage; and a documented vendor SysEx device-ID error (`0x42` documented, `0x15` actual), which supports keeping firmware-observed encodings selectable.
- Cross-check result (2026-11-12): every applicable pattern already exists in this repository, so nothing was ported:
  - Desired and observed state: `CompactState` keeps `desiredFader`, `lastMotorCommands` and `observedFaders` separate. `StatePresentationTests.stateQueriesDistinguishDesiredObservedAndHeldControls` pins that a command never forges an observation.
  - Touch guard: `CompactState.setFader` withholds writes while touched, and `reconcileReleasedFader` replays them on release. The EXTENDER library drops them instead. Covered by `SurfaceStateTests.noMotorDriveWhileUserTouchesFader` and `MockDeviceTests.mockRejectsMotorCommandsWhileTouchedAndCountsThem`.
  - Per-mode codec: `FactoryStandardMap` is the only codec because MC mode and editor-modified (for example relative-encoder) presets are out of scope until characterized. Extract a shared codec interface only when a second characterized mode is added; relative 65/1 decoding and acceleration belong in that work, not in Standard mode, whose encoders send absolute 0–127.
  - Mockable I/O: the app `MIDIService` protocol and the core `MockXTouchCompact` device already fill this role.
  - Firmware-observed encodings: `ButtonLightProtocol.manual` / `.observed114` keeps both LED velocity encodings selectable.
- Counter-examples, not to copy: `CtrlFader` records the commanded value as `ActualPosition` immediately after sending, which treats the last transmitted command as an observation. A target requested while the fader is touched is dropped with no reconciliation on release. `Open()` rewrites all output state, which must never extend to motor recall here.
- Do not use its firmware files. Copying code is permitted under Apache-2.0 with notices, but nothing here justifies it, and its .NET runtime dependencies are out of scope.

## Official

- Behringer X-TOUCH COMPACT product/software: https://behringer.com/en/products/0808-AAE
- Quick Start Guide V6.0 mirrored PDF: https://www.bhphotovideo.com/lit_files/1142317.pdf
- Manufacturer device documentation: https://mediadl.musictribe.com/media/sys_master/ha6/h2b/8849640980510.pdf
- The manufacturer currently lists **X-TOUCH Editor v1.21.0** for macOS and Windows; it is needed for editing the hardware's Standard MIDI presets.

## Avoid model confusion

The X-TOUCH (full-size), X-TOUCH EXTENDER, X-TOUCH ONE, and X-TOUCH MINI are distinct products. Protocol notes describing Ethernet, scribble-strip LCD SysEx and X-Touch full-size MC mode are not automatically applicable to the COMPACT. The COMPACT has no full-size X-Touch scribble strips or Ethernet interface.
