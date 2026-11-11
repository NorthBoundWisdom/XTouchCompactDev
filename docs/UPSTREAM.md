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

## Official

- Behringer X-TOUCH COMPACT product/software: https://behringer.com/en/products/0808-AAE
- Quick Start Guide V6.0 mirrored PDF: https://www.bhphotovideo.com/lit_files/1142317.pdf
- Manufacturer device documentation: https://mediadl.musictribe.com/media/sys_master/ha6/h2b/8849640980510.pdf
- The manufacturer currently lists **X-TOUCH Editor v1.21.0** for macOS and Windows; it is needed for editing the hardware's Standard MIDI presets.

## Avoid model confusion

The X-TOUCH (full-size), X-TOUCH EXTENDER, X-TOUCH ONE, and X-TOUCH MINI are distinct products. Protocol notes describing Ethernet, scribble-strip LCD SysEx and X-Touch full-size MC mode are not automatically applicable to the COMPACT. The COMPACT has no full-size X-Touch scribble strips or Ethernet interface.
