# Physical bring-up session — 2026-11-11

Status: **in progress; input characterization only**. No LED/ring/motor output
has been issued by the inspection tools. HW-1…HW-7 are not signed off.

## Environment and device identity

- App source: `803efa0dd81b266b7044849e82cc879eb225da64`.
- Host: macOS 27.2.1, Apple Swift 6.4.2, Apple silicon.
- CoreMIDI manufacturer / model / endpoint display name: Behringer / X-TOUCH
  COMPACT / X-TOUCH COMPACT.
- Input endpoint stable ID: `-1234209649`; output endpoint stable ID: `-535954037`.
- USB VID/PID: `0x1397 / 0x00B2` (5015 / 178).
- USB `bcdDevice`: `0x0200`. This descriptor is **not a verified firmware version**.
- USB serial-string descriptor: `1.0.1`. Whether this is a unique serial number
  or another device-provided string is unverified; no chassis serial recorded.
- Firmware version: unknown. Configured Global RX channel: unknown. TX channel:
  awaiting captured input. No hardware profile has been rewritten.

## Operator observations and setup

The operator initially reported a blue USB LED and a lit yellow MC MODE LED,
with the square USB B MIDI connector connected and the Mac accessory connection
allowed. CoreMIDI enumerated one matching source and destination.

After the documented power-on MC-button toggle, the operator reported MC MODE
off and USB still blue. This establishes the front-panel indication of Standard
mode; factory address mapping remains to be checked from input.

Reference: Behringer Quick Start Guide V6.0, printed page 24, [manufacturer guide
mirror](https://www.bhphotovideo.com/lit_files/1142317.pdf). No reset, editor preset
write or firmware update was performed.

## Capture method and evidence

The initial inspection used a temporary input-only CoreMIDI diagnostic compiled
under ignored `build/hardware-bringup/`, using the repository's MIDI1 UMP codec.
It connected only the explicitly identified Compact input. It created no output
port and contains no MIDI send call. This is direct input characterization,
**not acceptance of the app's native UI, state adapter or listening toggle**.

Local evidence (not committed):

- `build/hardware-bringup/initial-identity.json`: identity and operator reports.
- `build/hardware-bringup/stage1-standard-input.jsonl`: failed first capture;
  start marker only, no end marker; not hardware-behavior evidence.
- `build/hardware-bringup/stage1-standard-input-v2.jsonl`: replacement input capture.
- `build/hardware-bringup/self-test-3.jsonl`: synthetic virtual-source self-test;
  explicitly excluded from physical results.
- `build/hardware-bringup/passive-capture.swift`: diagnostic source.
- `build/hardware-bringup/summarize_capture.py`: local capture summary.

The diagnostic uses its own `xtouch.passive-raw.v1` schema, distinct from the
app monitor's schema. UMP words and MIDI 1 bytes are retained; SysEx messages are
not assembled. An end marker is required before treating a capture as complete.
Firmware and Global RX remain unknown; the capture makes no RX-channel inference.

## Results so far

| Item | Actual result | Status |
| --- | --- | --- |
| HW-1 identity | USB and CoreMIDI names/IDs above; operator-confirmed Standard indication | Partial; firmware and both channels pending |
| HW-7 layers and cross-layer touch release | Awaiting physical input | Pending |
| HW-2 buttons | Awaiting physical input | Pending |
| HW-3 encoders and pushes | Awaiting physical input | Pending |
| HW-5 LEDs and Program Change | No output issued | Pending Stage 1 review |
| HW-4 ring styles and local redraw | No output issued | Pending Stage 1 review |
| HW-6 motors and touch arbitration | No output issued | Pending Stage 2 review |

Initial operator step: select physical Layer A, touch/release F1 without moving,
then slowly move F1 bottom → top → bottom and release. The operator reported
completion, but the first diagnostic crashed on its input callback before
serializing a physical event. Crash logs identify a Swift actor-executor
assertion in the diagnostic's callback. This is a capture-tool failure, **not
evidence of a device fault**. The previous attribution to cross-turn process
lifetime was provisional and is superseded by this crash evidence.

The callback is now explicitly `@Sendable`; a separate synthetic virtual-source
self-test received exactly touch `[176,101,127]`, position `[176,1,64]`, and
release `[176,101,0]`, then closed with an end marker. That test sent no messages
to the physical device. The replacement diagnostic runs detached, keeps a
heartbeat and receives phase/stop commands via files, so it does not require a
terminal to stay attached. Physical F1 characterization awaits the repeat.

At the operator's request, this step-by-step text procedure was replaced with a
native **Hardware observation** workspace. The direct diagnostic v2 was stopped
and has an end marker with zero physical inputs; it establishes no device-control
result. At 19:47 local time, the native app was opened with `--hardware-observe`
and an explicitly selected evidence path:
`build/hardware-bringup/frontend-observe-20261111-194729.jsonl`.

The native app creates normal CoreMIDI transport ports, with all hardware MIDI
output blocked by the observation-mode send gate. Its physical-input path updates
observations and safety state without executing parameter assignments or Agent
actions. The native input capture uses the app's existing JSONL schema v1, not the
temporary diagnostic schema. It was started successfully; physical UI response
is awaiting operator observation. Synthetic previews and automated tests are
not physical results.

## Software checks during preparation

`python3 configs/setup_local_project.py`,
`python3 configs/macos_workflow.py build`, and
`swift test --build-path build/swiftpm --jobs 2` passed locally. These checks
do not establish physical hardware behavior or complete native mouse acceptance.

The observation feature additionally passed 48 Core tests, 43 App tests (9 XCTest
+ 34 Swift Testing), 3 localization tests, SwiftFormat checks, native Debug
build/signature verification and offscreen inspection of the three Chinese
observation previews. The feature's new tests cover all controls in both layers,
touch/release, host/physical position separation, wrong-channel raw input, output
locking, reconnect, reset preserving touch safety and input-only JSONL evidence.
