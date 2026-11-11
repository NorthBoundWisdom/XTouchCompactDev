# XTouchCompactDev

Native Swift 6 / SwiftUI / CoreMIDI control surface for the **Behringer X-TOUCH COMPACT**. A sibling of [BCR2000Dev](https://github.com/NorthBoundWisdom/BCR2000Dev), sharing its value-oriented MIDI and testable hardware-session architecture, but designed for the Compact's motorized, touch-sensitive faders and asymmetric RX/TX mapping.

## Current stage — P0 software complete, hardware bring-up not started

- **Implemented and locally tested without hardware:** factory Standard MIDI protocol core with distinct input/feedback addressing and layer-independent decoding; 9 motorized faders, 9 touch sensors, 16 encoders and pushes, 39 buttons; touch ownership across layers, transports and reconnects; deferred motor reconciliation and a layer-mismatch motor interlock; typed parameters and per-layer control assignments; protected configuration persistence; eight Mock Agent slots; opt-in localhost MCP; guarded OSC output; deterministic mock device and Swift tests.
- **macOS app:** SwiftUI virtual panel laid out like the device, control inspector, and workspaces for values, parameters, Agents, MIDI monitor and connection; Mock/Hardware modes; separate TX and Global RX channel configuration; manual LED velocity variant; explicit motor recall with confirmation; English, Simplified Chinese and Traditional Chinese.
- **Not verified:** anything on a physical unit. The panel's button/encoder numbering, LED velocity encoding, ring styles, physical A/B behavior and motor behavior are assumptions until the hardware checklist in [TODO.md](TODO.md) is done. Remote CI covers build, tests, packaging and startup smoke on Linux and macOS; it does not exercise hardware.
- **Not implemented:** Mackie Control mode, firmware replacement, measured 14-bit fader resolution, real external Agent processes, incoming OSC motor feedback, production signing and notarization.

## Test and run

```bash
swift test
swift build
# macOS 14+ only; mock mode works without a physical Compact:
swift run XTouchCompactApp
```

For VS Code FreeCM integration, open **FreeCM: Show Workflow Panel**, run **Config**,
then use **Build / Run / Test / Package**. The repository provides local ad-hoc
signed `.app` bundles and Release ZIP/DMG packages; production signing and notarization remain
out of scope. See [FreeCM commands and local configuration](docs/FREECM.md).
On Linux the executable prints a platform explanation; the core/tests work unchanged.

## Interface language

The interface defaults to the system's preferred supported language, with English,
Simplified Chinese and Traditional Chinese translations. Open **Settings…** using
the gear button or **⌘,**, then choose **Follow System / English / 简体中文 / 繁體中文**.
Changes apply immediately and persist across launches. Switching language preserves
the MIDI session and parameter values. Labels, motor confirmation, errors and
existing monitor messages follow the selected language; device names and raw MIDI
data remain unchanged. Unsupported system languages fall back to English.

## First physical connection

1. Use the **factory Standard MIDI** mapping on the hardware, not MC mode, and connect USB. Do not flash firmware.
2. Start in **Mock** mode, verify **Listen only — send no MIDI** in Connection (on at every launch), then switch to **Hardware** after selecting the correct CoreMIDI endpoints. Use MIDI monitor → Start capture… to stream evidence to JSONL. Follow [physical bring-up](docs/HARDWARE_BRINGUP.md) before explicitly enabling output; turning listening off itself sends nothing.
3. Set the separately configured **Global RX channel** to match the hardware. The default is channel 1; that is a starting assumption, not auto-detection.
4. Keep all nine faders unobstructed. Connecting/reconnecting or changing layer **does not automatically move motors**. Use **Recall motors…** to confirm and move them deliberately.
5. Validate which button LED velocity encoding works on the actual unit (official manual vs firmware-1.14 observation). See `docs/MIDI_PROTOCOL.md`.

## Design

`XTouchCompactCore` has no CoreMIDI/SwiftUI dependencies. `FactoryStandardMap` handles protocol and factory addressing. `CompactState` owns the host-desired LED/motor states and touch policies. `CompactSession` routes device events through the parameter engine into two per-layer banks, while `CoreMIDIService` owns native transport and `ConsoleModel` routes UI inputs. This deliberately avoids binding physical input Note numbers to the same output Note numbers.

Views render a `PanelSnapshot` and emit `PanelIntents` (`PanelPresentation.swift`); `ConsoleModel+Panel.swift` is the single adapter between the UI and the session. Mock panel gestures produce factory TX messages through `MockXTouchCompact`, traverse the session, and consume RX feedback; inspector writes remain software commands. Snapshots expose touch, deferred motors, held controls and host-desired lights. Observed fader positions come only from actual input reports, never from motor commands. Unreported positions, ring styles and labels stay nil. The inspector describes factory TX and Global RX addresses from the applied session mapping, including separate encoder ring display/style addresses. The panel's button and encoder numbering by position is an assumption to be checked on hardware.

## References and next steps

- [Exact manufacturer-vs-observed MIDI map](docs/MIDI_PROTOCOL.md)
- [Research, upstream projects, and licensing](docs/UPSTREAM.md)
- [Actionable task list and frontend/backend split](TODO.md)
- [Hardware checklist and backlog](docs/IMPLEMENTATION_PLAN.md)
- [Agent constraints](AGENTS.md)

Reference implementation: [jetsonhacks/xtouch-compact](https://github.com/jetsonhacks/xtouch-compact), an MIT-licensed Linux ALSA library with validated behavior. We model its documented observations independently in Swift; no Python ALSA dependency is included. Original BCR2000Dev code influenced CoreMIDI callback and session boundaries.

## Software workflows

Parameters and bulk assignments, protected configuration persistence, eight Mock
Agent slots, structured MIDI monitoring, opt-in localhost MCP and guarded OSC
output are available without hardware. See [software workflows and safety boundaries](docs/SOFTWARE_WORKFLOWS.md).

![Isolated Mock console](docs/images/console-en.png)

[Settings preview](docs/images/settings.png) · [Traditional Chinese preview](docs/images/console-zh-Hant.png)
