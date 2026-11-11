# Physical bring-up session — 2026-11-11

Status: **observation UI accepted by the operator; protocol bring-up remains
partial**. No LED/ring/motor output has been issued by the inspection tools.
HW-1…HW-7 are not signed off as complete.

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
- Firmware version: unknown. Actual configured Global RX channel: unknown. Captured
  touch inputs use TX channel 1, decoded from their status bytes; this establishes
  no RX-channel value. No hardware profile has been rewritten.

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
| Observation UI | Operator reported “全部生效，看起来没问题” after using the physical device | Visual acceptance passed for this workspace |
| HW-1 identity | USB/CoreMIDI identity, Standard indication, captured touch TX channel 1 | Partial; firmware and actual Global RX pending |
| Layer A touch input | 56 touch/release messages for F1–F5 and F7–F9, values 127/0 | Captured subset matches factory touch addresses |
| HW-7 layers and cross-layer touch release | No Layer B or cross-layer release in the reviewed input prefix | Pending |
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
temporary diagnostic schema. The operator subsequently confirmed that the
workspace responded correctly. Synthetic previews and automated tests are not
physical results.

## Accepted UI and reviewed input evidence

The accepted observation build corresponds to `ea812d5`. The operator's exact
report was **“全部生效，看起来没问题”**. This is acceptance of visible observation
feedback, not sign-off of unperformed LED, ring or motor output tests, and does
not close the separate N5 console mouse-acceptance cases.

At the 20:13 local review, the live native capture contained 56 physical input
events from 20:04:31.387 to 20:05:00.812 local (12:04:31.387–12:05:00.812 UTC).
Every event used MIDI status `B0`, the captured layer was A, and values were
127 for touch and 0 for release. There were **zero OUT records** in this prefix.

| Decoded touch | Input CC | Touch count | Release count |
| --- | --- | --- | --- |
| F1 | 101 | 3 | 3 |
| F2 | 102 | 3 | 3 |
| F3 | 103 | 5 | 5 |
| F4 | 104 | 2 | 2 |
| F5 | 105 | 1 | 1 |
| F7 | 107 | 2 | 2 |
| F8 | 108 | 1 | 1 |
| F9 | 109 | 11 | 11 |

F6, fader-position reports, encoder rotation/push, button notes, Layer B and
cross-layer releases are not present in this reviewed prefix. Absence from this
capture is not evidence of a defective control; those checks remain open.

The capture remains live, with no end marker at review time. A frozen local
copy of its complete-line prefix is `build/hardware-bringup/reviewed-ui-input-prefix.jsonl`
(25,104 bytes), with summary `build/hardware-bringup/reviewed-ui-input-summary.json`.
Prefix SHA-256:
`4b9d08b34f010dde9ca2fa3d32dfef748366cbcde9e044bd74f9a068de78e1e2`.
This fingerprint identifies the reviewed prefix only; it does not make the whole
recording complete. No running operator app was stopped to produce the review.

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

Follow-up refactor `343a354` moved the input accumulator into the pure Core and
centralized presentation mapping without changing the accepted UI. Local checks
passed 51 Core, 44 App and 3 localization tests, build, SwiftFormat/Ruff, isolated
waiting/touch/release previews and startup smoke. The new Core tests are runnable
on Linux, but this refactor has not yet been pushed through Linux CI. The
operator's accepted `ea812d5` app and live recording were left running; these
software checks are separate from the physical results above.
