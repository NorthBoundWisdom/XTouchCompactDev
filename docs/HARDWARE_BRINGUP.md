# X-TOUCH COMPACT physical bring-up record

**Physical bring-up is in progress:** see [2026-11-11 session](HARDWARE_SESSION_2026-11-11.md).
USB/CoreMIDI identity, Standard indication, partial Layer A touch input and the
operator's observation-UI acceptance have been recorded. Full control coverage,
LED and motor tests remain open. The fields below remain the full
acceptance template. Factory Standard MIDI mode only; no firmware
flashing, editor preset modifications or Mackie Control testing.

Operator / date / app commit: __________
macOS / Swift / device serial / firmware / VID / PID: __________
Manual TX channel (device → host): ____; configured Global RX channel (host → device): ____
LED protocol selected (manual 0/1/2 or observed-1.14 0/2/3): __________
Input/output endpoint names and stable IDs: __________

## Capture procedure and stage gates

### Current handoff — visual Stage 1 input acceptance

The C1/C2 software is ready. The new acceptance app is under
`build/hardware-bringup/InputReviewAcceptance.app`; its live capture/log paths
are recorded in `build/hardware-bringup/active-input-review-session.json`.
It opens **Hardware observation → A/B input review** with output locked and a
fresh observation scope. Earlier evidence stays unchanged in its original files.

1. Use physical Layer A, then B. For each layer, operate all nine faders to both
   ends, touch/release each cap, turn all sixteen encoders to 0 and 127 and
   push/release each, then press/release all 39 buttons. Use the control-group
   selector and incomplete filter to see missing items; also verify physical
   positions and printed legends match the panel. Viewer layer selection sends
   nothing to the hardware.
2. For cross-layer release, touch F1's metal cap on A and keep touching it;
   press physical B once, turn E1 a little to establish B input evidence, then
   release F1. Repeat B → A. Review the three layer fields, including a release
   that still reports the original layer. Record any missing release or mismatch.
3. Stop capture, then export the review. Keep the JSON, checksum and capture
   snapshot together. Report anything that does not match the physical unit.

This is the point that requires the operator. Stage 2 cannot be finalized from
synthetic tests: actual cross-layer release semantics and an independently
confirmed Global RX are prerequisites. No LED/ring/motor output has been enabled
by these changes. C3 tools have since been prepared in a locked state; C4, full
HW sign-off and the separate N5 console cases remain open.

### Stage 2 tools prepared, permission still required

After Stage 1 review, use **Nonmotor tests**. Enter the reviewed evidence reference,
firmware and independently read Global RX; the app will not infer them. Start
capture and explicitly enable nonmotor output. Preview one command, send once,
observe the actual device, then record matches/differs/no-response plus notes such
as steady versus blinking, period, ring pattern/color or resulting layer.

Both LED encodings remain explicit choices. Style and display commands are sent
independently; Program Change does not itself prove the layer changed, so turn
E1 afterward and inspect the received layer. Every route/reconnect change revokes
permission. Locking or leaving the tab sends nothing. Stop capture before exporting
the review. These tools are software-tested only; no real Stage 2 result has been
recorded by this development pass, and no motor test is provided here.

### Full capture procedure

1. Launch app (listening defaults on at every launch). In Mock mode, open Connection
   and confirm **Listen only — send no MIDI** is on before selecting Physical X-TOUCH.
   Select input/output endpoints explicitly. Confirm the passive indicator remains visible.
   Do not infer Global RX from incoming TX data; record both independently.
2. Open MIDI monitor → Start capture… and choose a `.jsonl` evidence file. Begin
   before each control group. The file streams every event independent of the 120-entry
   UI limit; Clear monitor does not clear capture. Stop capture to flush/close the file.
3. JSONL v1 contains start/end markers and sequenced events with timestamp, canonical
   MIDI 1 bytes, decoded input (control, device layer, value/press), host layer,
   independent TX/RX channels, selected LED encoding, mode and delivery status.
   `suppressed` means **never sent**, `sent` means transport accepted a command,
   not device acknowledgement. A missing end marker means incomplete capture.
   Unsupported SysEx/realtime/UMP message types are not retained: this is a Standard
   MIDI control-message capture, not a lossless packet sniffer. Use a separate MIDI
   diagnostic tool if unexpected messages need characterization.
4. Complete Stage 1 records (HW-1, HW-7, HW-2, HW-3) before enabling any output.
   In Stage 2, close/label the passive capture, explicitly turn listening off, then
   Realign current layer. That action asserts Program Change and nonmotor feedback;
   it does not observe layer/position or recall motors. Turning listening off itself
   sends nothing and cancels withheld motor writes. Start a new capture.
5. Complete Stage 2 (HW-5, HW-4, Program Change assumption) before Stage 3 (HW-6).
   Stage 3 requires a clear fader path, one fader and small moves. Never command a
   motor under touch. Stop immediately if any firmware assumption below fails;
   correct Core and add deterministic regressions before proceeding.

## HW-1 — identity, mode and channels (Stage 1)

Steps: keep listening on; record USB identity, firmware and endpoint names. Confirm
factory Standard MIDI mode by device documentation/front-panel state. Move one
control and record TX channel. Read configured Global RX from the device settings
or an independently verified record; **do not derive it from TX**.

Expected: input events captured; zero transmitted MIDI while listening, including
connect, reconnect, port/profile application and layer controls.

Actual (2026-11-12, partial): TX channel 1 on both layers. **Global RX channel 2**, found
by sending one button-LED Note On per channel: only channel 2 lit a button. The operator
had expected the default 1. Firmware version still unread.
Capture filename(s): `control-d2-2026-11-12.jsonl`, `button-light-2026-11-12.jsonl` (private)
Conclusion / deviations / follow-up: RX ≠ TX on this unit; see
[the session record](HARDWARE_SESSION_2026-11-12.md). Firmware remains open.

## HW-7 — physical layers and touch address (Stage 1)

Steps: listening on; move F1 on A, press physical B, move F1 again. Repeat with
F1 held through A/B switch and then released. Do not press host realignment yet.

Expected / assumption 1 (unverified): physical A/B key itself sends no message;
subsequent control TX addresses identify the new layer. Record exactly which layer's
address reports touch release across the switch. Host mismatch warning should appear
when input layer differs; motors remain blocked. A missing release must not be
worked around by clearing touch ownership.

Actual: __________
Assumption 1 established or rejected (including release address): __________
Capture filename(s): __________
Conclusion / required Core correction: __________

## HW-2 — every button's physical identity (Stage 1)

Steps: listening on; press/release all 39 buttons individually on both layers.
Annotate row/column and printed transport legend for each event.

Expected (unverified layout): 1–24 are three rows of 8 under the top encoders;
25–32 under strip faders; 33 under master; 34–39 transport, upper row rewind /
forward / loop, lower row record / stop / play. Input Note addresses differ by layer;
RX feedback addresses are independent. Compare with MIDI_PROTOCOL.md, not with
feedback guesses. If positions differ, update PanelLayout after evidence review.

Actual per-button table / attachment: __________
Capture filename(s): __________
Conclusion / layout corrections: __________

## HW-3 — encoders and pushes (Stage 1)

Steps: turn all 16 encoders slowly and quickly, then push/release individually on
both layers. Annotate physical position for every input.

Expected (unverified): 1–8 top row, 9–16 side block by row. Factory TX values are
absolute 0–127 with acceleration, not relative deltas; Note push addresses are
separate. Record endpoints, acceleration and any unexpected input shapes.

Actual: __________
Capture filename(s): __________
Conclusion / corrections: __________

## HW-5 — LED encoding and layer assertion (Stage 2)

Precondition: Stage 1 records reviewed. Start a new output capture; hands clear of
faders. Explicitly disable listening and use Realign current layer.

Steps: assert A and B separately; move a nonmotor control afterward to observe its
actual TX layer. Then test off/on/blink on **one button** with manual encoding;
repeat separately with observed-1.14 encoding if needed. Record exact commands,
physical LED response and blink period. Do not rewrite the hardware profile silently.

Expected / assumption 2 (unverified): Program Change really selects requested layer.
Host assertion alone is not proof. Manual LED velocities 0/1/2 and observed firmware
1.14 velocities 0/2/3 remain distinct choices until observed on this unit.

Actual / firmware / selected encoding / blink period (2026-11-12, LED half only): on
Global RX channel 2, velocity 0 = off, 1 = off, 2 = steady on, 3 = blink. Selected
encoding: **observed 1.14 (0/2/3)**; the manual's 0/1/2 is rejected for this unit. Firmware
unread; blink period not timed. Sent with the single-purpose `button-light` command, not
through the app's Nonmotor tests page.
Assumption 2 established or rejected: **established** (2026-11-12). Program Change 1 then 0 on
Global RX channel 2 lit the B then A layer key, and F1 touches arrived on CC 111 then CC 101.
Capture filename(s): `button-light-2026-11-12.jsonl`, `feedback-2026-11-12.jsonl`,
`layer-b-2026-11-12.jsonl`, `layer-a-2026-11-12.jsonl` (private)
Conclusion / corrections: use `observed114`; Program Change selects the layer in both directions.

## HW-4 — ring styles and colors (Stage 2)

Steps: issue one encoder's ring display and style commands independently. Record
single / pan / fan / spread / trim at low, center and high positions, off/all-on,
and blinking variants. Turn that encoder locally and press transport keys one at
a time to check local ring overwrite and transport-group LED redraw.

Expected: compare raw RX addresses with MIDI_PROTOCOL.md. UI non-single styles
are approximate until this test; capture photographs of actual segment patterns,
LED colors and timing. No motor command should appear.

Actual (2026-11-12, partial): display values 0, 1–13, 14–26, 27 and 28 behave as in the RX
table on channel 2 (single LED, blinking LED, all on, all blinking). A host display value
draws one LED under every style. A style message redraws the ring at once with its own
pattern and discards the host position (style 1 → LED 1, 2 → off, 3 → LED 7, 4 → LEDs 1–7,
each seen once). Colors, blink period and local-rotation behavior per style not recorded.
Capture filename(s): `feedback-2026-11-12.jsonl` (private)
Conclusion / corrections: see [the session record](HARDWARE_SESSION_2026-11-12.md). The
panel's pan / fan / spread drawings of a host position do not match the device, which shows
a single LED; local-rotation appearance still needs its own check.

## HW-6 — one motor, touch and feedback (Stage 3)

Precondition: Stage 2 reviewed, assumptions 1 and 2 established, clear travel path.
Keep other faders unchanged; avoid Recall all during initial characterization.

Steps: use a single software F1 write a few MIDI units from its known position.
Observe whether device TX reports progress. Repeat a write while F1 is touched:
there must be no outgoing motor command; on release verify the latest explicit
software target is issued once. Repeat with layer mismatch; no motor may be sent
until explicit realignment and a fresh write. Check reconnect and layer changes
never recall motors. Review capture for feedback loops before another move.

Expected / assumption 3 (unverified): any untouched position report may be motor
progress and must never drive any motor in response. Transmitted RX target is not
an observed position. Touch ownership survives layer/mode/reconnect boundaries.

Actual / position feedback / command count / stop behavior: __________
Assumption 3 established or rejected: __________
Capture filename(s): __________
Conclusion / required Core correction: __________

## Exit record

Restore listening on and stop capture. Confirm MCP and OSC are off if used.
All three assumptions: __________
Unresolved issues and blockers before further output: __________
HW-1…HW-7 sign-off / evidence reviewer: __________
F7 changes and protocol annotation updates: __________
No release tag or distribution claim is implied by these records.
