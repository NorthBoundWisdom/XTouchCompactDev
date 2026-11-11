# XTouchCompactDev

Native Swift 6 / SwiftUI / CoreMIDI control surface for the **Behringer X-TOUCH COMPACT**. A sibling of [BCR2000Dev](https://github.com/NorthBoundWisdom/BCR2000Dev), sharing its value-oriented MIDI and testable hardware-session architecture, but designed for the Compact's motorized, touch-sensitive faders and asymmetric RX/TX mapping.

## Current stage — P0 developer baseline

- **Implemented and locally tested:** factory Standard MIDI mode protocol core, A/B-layer mappings, 9 motorized faders, 9 touch sensors, 16 encoders and pushes, 39 buttons; distinct input/feedback addressing; exact MIDI1 UMP codec; stateful feedback dedup/invalidation; touch ownership and deferred motor reconciliation; two application parameter banks; deterministic Swift tests.
- **macOS app code added:** SwiftUI virtual panel with 9 fader sliders, 16 encoder values and 39 backlit-button models; Mock/Hardware modes; input/output port selection, separate TX/Global RX channel configuration, live MIDI event monitor, manual LED velocity variant, explicit motor recall with confirmation. CoreMIDI uses hotplug notifications and automatic **name-matched** endpoint discovery. GUI code needs macOS CI compilation and real hardware testing.
- **Not implemented:** Mackie Control mode, firmware replacement, measured 14-bit physical fader resolution, persistence/import/export, advanced mapping/agent workflows/MCP/OSC, production app signing and notarization. These remain later work, not claimed capabilities.

## Test and run

```bash
swift test
swift build
# macOS 14+ only; mock mode works without a physical Compact:
swift run XTouchCompactApp
```

The SwiftPM executable is for development; a signed `.app` bundle, provisioning and notarization are not part of this baseline. On Linux the executable prints a platform explanation; the core/tests work unchanged.

## First physical connection

1. Use the **factory Standard MIDI** mapping on the hardware, not MC mode, and connect USB. Do not flash firmware.
2. Start in **Mock** mode, then switch to **Hardware** only after verifying both CoreMIDI source/destination endpoints. If discovery fails, select the exact source and destination.
3. Set the separately configured **Global RX channel** to match the hardware. The default is channel 1; that is a starting assumption, not auto-detection.
4. Keep all nine faders unobstructed. Connecting/reconnecting or changing layer **does not automatically move motors**. Use **Recall motors…** to confirm and move them deliberately.
5. Validate which button LED velocity encoding works on the actual unit (official manual vs firmware-1.14 observation). See `docs/MIDI_PROTOCOL.md`.

## Design

`XTouchCompactCore` has no CoreMIDI/SwiftUI dependencies. `FactoryStandardMap` handles protocol and factory addressing. `CompactState` owns the host-desired LED/motor states and touch policies. `CompactSession` maps device events to two simple parameter banks, while `CoreMIDIService` owns native transport and `ConsoleModel` routes UI inputs. This deliberately avoids binding physical input Note numbers to the same output Note numbers.

The initial virtual panel is a functional control-surface diagnostic, **not** yet a pixel-accurate replica. Real control-state observability should precede advanced styling and MCP/OSC integration.

## References and next steps

- [Exact manufacturer-vs-observed MIDI map](docs/MIDI_PROTOCOL.md)
- [Research, upstream projects, and licensing](docs/UPSTREAM.md)
- [Hardware checklist and backlog](docs/IMPLEMENTATION_PLAN.md)
- [Agent constraints](AGENTS.md)

Reference implementation: [jetsonhacks/xtouch-compact](https://github.com/jetsonhacks/xtouch-compact), an MIT-licensed Linux ALSA library with validated behavior. We model its documented observations independently in Swift; no Python ALSA dependency is included. Original BCR2000Dev code influenced CoreMIDI callback and session boundaries.
