# Implementation plan — full XTouchCompactDev application

## Architectural decision

Create a **sibling project** (`NorthBoundWisdom/XTouchCompactDev` when a new remote repository is available), not an invasive rewrite of `BCR2000Dev` during its current BCR hardware validation. Reuse the BCR **application/domain** concepts, while implementing a distinct hardware `CompactDeviceProfile` and mock. After both stabilize, evaluate extracting a shared `SurfaceCore` package.

This seed provides `XTouchCompactCore`, not the final app. Do not conflate a working protocol model with successful real-device interaction.

## P0 — software before device arrival

1. Keep the established BCRAgentConsole architecture boundaries: Swift 6/SwiftUI for macOS 14+, CoreMIDI in App, pure hardware-independent state transitions in Core, MCP Server, parameter mapping, Agent actions, OSC safety gate, persistence and test infrastructure.
2. Port in a *physical device profile* (`CompactControl`, `FactoryStandardMap`) that distinctly represents input events and feedback commands. Use Standard Mode only, and map exact physical layout (9 faders, 16 encoders, 39 buttons, A/B layer).
3. Introduce a motor-fader control model: separate `target`, `observed`, `touched`, `pendingExternalUpdate`, `lastMotorCommand`. Suppress all motor commands while a human touches a fader; explicitly choose arbitration policy for simultaneous Agent/user writes.
4. Build the SwiftUI mirror with accurate physical positions and separate rendering of simulated and observed states. Show all 9 motor faders; display `IN`, `desired`, `OUT` and Touch clearly in diagnostics.
5. Provide a Mock device with deterministic events, touch/release, LED status, motor requests, A/B switching and simulated disconnect/reconnect. Do not require physical hardware in CI.
6. Generic parameter features (MCP/OSC/Agent/task control) should *reuse the original semantics*. Configuration imports should be versioned and tagged with a device model; never apply an unvalidated BCR preset to Compact.
7. Add unit tests for protocol bytes, layer mapping, LED ON/BLINK variant, feedback coalescing, physical button group redraw, reconnect snapshot restore and no motor movement during touch.

**Acceptance:** all mock tests green; 9/16/39 controls visually represented; fake external MCP write updates visible virtual faders; no firmware flashing or DriverKit required.

## P1 — hardware bring-up (when physical unit arrives)

1. Power up, connect USB-B, confirm macOS Audio MIDI Setup / CoreMIDI endpoints; log VID/PID, firmware (if available), CoreMIDI source/destination strings, USB descriptor, X-TOUCH Editor configuration, TX channel and RX Global Channel. Use the original BCR project's CoreMIDI endpoint diagnostic patterns; avoid assuming Port 1 by name.
2. Export/backup user preset with official X-TOUCH Editor v1.21.0 before editing; keep A/B factory mapping for tests. Boot in Standard Mode, not Mackie Control.
3. Passive capture, one control at a time: 9 faders full range, 9 touch/release, 16 encoder turns, 16 pushes, all 39 buttons; verify Layer A and B separately and explicitly determine what happens on physical A/B press.
4. Output tests require opt-in, operator confirmation and safe surface space. Start with one button LED, then one encoder ring, then **only one motor fader** at a slow single target step (e.g. current position toward midpoint, no simultaneous large sweep). Stop when touched; confirm hold/release behavior and no unexpected motor feedback loop.
5. Characterize button LED OFF/ON/BLINK velocities (0/1/2 vs 0/2/3) and Global receive channel. Read back the motor's *actual* physical position by operating it; do not interpret a sent MIDI command as proof of movement.
6. Test reconnection, layer switching, feedback invalidation, host snapshots and physical touch while external MCP value changes.
7. Verify CoreMIDI device claim and simultaneous MIDI clients on actual macOS. Unlike BCR's documented USB/DriverKit issue, do not infer Compact needs a DriverKit workaround until reproducible evidence exists.

**Acceptance:** hardware-captured transcript of each control family; 9 faders touch-safe; all 39 LED outputs and 16 rings confirmed; A/B mapping and Global Channel discovered; no unsolicited motor motions after reconnect.

## P2 — advanced / opt-in

- Add MC mode via dedicated Mackie Control codec including Pitch Bend (7-bit *effective* stock Compact resolution), V-Pot and touch semantics. Do not reuse full X-TOUCH or EXTENDER LCD/SysEx protocols indiscriminately.
- Consider editor preset import, high-precision parameter handling, relative encoder modes and user-adjustable A/B modes after documented actual support.
- Track `lem120/xtouch-compact-fader-resolution` for a *public* documented firmware patch with a safe rollback method. Hardware firmware modification is **not** necessary for this project's initial success and should not be automatic.
- Evaluate video/robot/lighting control adapters only after parameter safety gates and touch ownership are validated.

## Source-code reuse/licensing policy

- `jetsonhacks/xtouch-compact`: MIT; protocol patterns and tests can be ported with attribution if substantive code is reused.
- `lfpoulain/py-mix-panel`: PolyForm Noncommercial; research/UI conceptual reference only, no copied code for a potential commercial app.
- `Quuikz/x-touch-compact-hui-translator`: no verified license; use documented behavior as reference, not source-code redistribution.
- `lem120/xtouch-compact-fader-resolution`: not a published ready-to-install firmware; keep out of P0.

## Current status and known limitations

- P0 is complete in software: parameter/assignment engine, protected persistence, Mock Agent slots, localhost MCP, guarded OSC output, mock device, native app and local ad-hoc `.app`/ZIP/DMG packaging. See `docs/SOFTWARE_WORKFLOWS.md`; open follow-ups are listed in `TODO.md`.
- P1 has not started. No behavior in this repository has been verified on a physical unit. Swift tests establish host policies against a deterministic mock, not firmware timing, channel settings or motor behavior.
- The motor-safety policy depends on three unverified firmware assumptions (other-layer TX addresses after a physical A/B press, Program Change layer selection, and position reports during motor travel). They are listed with the HW checklist in `TODO.md` and must be checked before any wider output test.
- Production signing/notarization, real external Agent processes, incoming OSC-to-motor feedback and DAW-specific mappings are not implemented.
