# Hardware session 2026-11-12 — input checks, nonmotor output and one motor

Controller attached by USB to the development Mac (VID/PID `0x1397 / 0x00B2`,
`bcdDevice 0x0200`; the descriptor serial string `1.0.1` is not a verified firmware
version). The input sections used `XTouchRemoteMIDI listen`, which has no output port, so
nothing was sent during them. With operator consent, the output sections sent button-LED
Note On, ring display (CC 26–41), ring style (CC 10–25) and Program Change messages only.
No mode switch (CC 127) was sent; the sender cannot express it. Motor commands were sent
only in the last section below: five single CC 1 messages to fader 1, each announced to the
operator first. Raw captures are in `captures/private/` (not committed).

## What the operator did

One control of each kind, on both layers: touch and release F1, move F1 up and back,
turn encoder 1, push encoder 1, press button 1. The unit was on layer B at the start, so
the sequence ran on B first and then on A after the physical layer key.

## Observed (capture `control-d2-2026-11-12.jsonl`, 209 messages, all channel 1)

| Control | Layer A | Layer B | Factory table |
| --- | --- | --- | --- |
| Fader 1 position | CC 1 | CC 28 | matches |
| Fader 1 touch | CC 101, 127 / 0 | CC 111, 127 / 0 | matches |
| Encoder 1 rotation | CC 10 | CC 37 | matches |
| Encoder 1 push | Note On 0 vel 127, Note Off 0 vel 0 | Note 55, same shape | matches |
| Button 1 | Note On 16 vel 127, Note Off 16 vel 0 | Note 71, same shape | matches |

- Every fader position message fell between that fader's touch-down and touch-up
  (184 of 184 here, 110 of 110 in the earlier `control-d` capture). Touch-down preceded the
  first position message by 0.01–0.25 s.
- Fader travel reported consecutive values with no gaps over the range moved (0–48).
- Pressing the physical layer key produced no MIDI message: between the last layer-B
  message and the first layer-A message nothing was received. The host can only learn the
  layer from the address of the next input.
- No message outside the factory table appeared.

## Encoder 1 reporting mode (capture `encoder-mode-2026-11-12.jsonl`, 176 messages)

Layer A, CC 10 only. The operator turned slowly, then to both ends, then quickly.

- **Absolute 0–127.** Slow turning sent one message per step with consecutive values
  (2, 3, 4 … 48). This is not relative 1 / 65 encoding.
- **Clamped at both ends, and it keeps transmitting.** Turning past the top sent 127
  again 33 times; past the bottom, 0 again 8 times. The knob is endless but the value is
  not.
- **Accelerated.** Fast turning skipped values, with steps of up to 6–7 per message
  (1 → 80 in 0.14 s over 16 messages).

This matches the model contract's "accelerated absolute" description and the mock. In
the session, each repeated end-stop message produces one ring reassertion and no extra
undo step (checked with a throwaway test, 33 repeats → 33 ring messages, 1 undo step).
Only encoder 1 on layer A was measured.

## Button LEDs and the Global RX channel (output log `button-light-2026-11-12.jsonl`)

Sent with `XTouchRemoteMIDI button-light`, one Note On at a time; the operator reported
the LED after each. The operator had stated the Global RX channel as the default 1.

| Sent | Operator saw |
| --- | --- |
| B1, channel 1, velocity 0, 1, 1, 2, 3 | B1 never lit |
| B*n* on channel *n*, velocity 2, for *n* = 1…16 | **only B2 lit** |
| B2, channel 2, velocity 0 | B2 off |
| B1, channel 2, velocity 1 | off |
| B1, channel 2, velocity 2 | steady on |
| B1, channel 2, velocity 3 | blinking |
| B1, channel 2, velocity 0 | (sent to leave the unit dark; result not reported) |

- **This unit receives on Global RX channel 2**, while it transmits on channel 1. Of 16
  channels only channel 2 had any effect. The factory-default assumption (1) was wrong for
  this unit, and TX really does not predict RX.
- **Button LED velocities are 0 off, 2 on, 3 blink** — the `observed114` encoding. Velocity
  1, which the manual documents as "on", leaves the LED off. Assumption 3 of the bring-up
  (manual 0/1/2) is rejected for this unit; the JetsonHacks firmware-1.14 observation holds.
- Feedback addressing is confirmed for two buttons: RX Note 0 is B1 and Note 1 is B2,
  different from their TX notes (16 and 17 on layer A).
- Blink period was not timed. Only B1 and B2 were lit; LED colors were not recorded.

**Consequence for the app:** its saved device profile has had Global RX = 1, so button-LED,
ring and layer-assertion feedback sent before this session cannot have reached the device.
The profile is not rewritten automatically. Set *Global 接收通道* to 2 and enable *按键 LED
使用固件 1.14 实测值* on the Connection page, then apply.

A second XTouchCompactApp process was running during these sends. With its receive
channel at 1 it could not have altered LEDs on channel 2, but the run was not isolated.

## Rings and layer selection (output log `feedback-2026-11-12.jsonl`, 39 messages)

Sent with `XTouchRemoteMIDI ring-display`, `ring-style` and `select-layer` on channel 2;
the operator reported the rings after each batch. An XTouchCompactApp process was running
throughout, so the run was not isolated; the operator did not touch the unit between a
batch and its report except where noted.

**Ring display (CC 26–41), default style.** All matched the RX table:

| Value | Seen |
| --- | --- |
| 0 | ring off |
| 1, 4, 7, 10, 13 | that single LED lit; 1 is bottom left, 7 top center, 13 bottom right |
| 20 | LED 7 blinking (14–26 = LED *n* − 13 blinking) |
| 27 | all 13 lit |
| 28 | all 13 blinking |

Rings listen on channel 2, like button LEDs.

**Ring style (CC 10–25).** Styles 0–4 on E1–E5:

- Style first, then display value 4: all five rings showed LED 4 alone.
- Style sent again afterwards, with no display message: the ring was redrawn at once with a
  pattern of its own, and the earlier position was not kept. Style 1 → LED 1; style 2 →
  ring off; style 3 → LED 7; style 4 → LEDs 1–7. (E1, style 0, was not resent and kept
  LED 4.)
- Display value 10 sent after that: all of E1–E6 showed LED 10 alone, including E6, which
  never received a style.

So a host display value always draws **one LED**, whatever the style, and a style message
redraws the ring immediately, discarding the host's position. The style evidently governs
how the device draws the ring for local knob movement; that was not tested here. Each
style pattern was seen once, so no rule is derived from them. The core's "replay the
host position after a style change" matches this. The app sends no style today.

**Layer selection (Program Change).** `select-layer b` lit the B layer key, and the
operator's F1 touches then arrived on CC 111 (8 messages, all layer B).
`select-layer a` followed, and touches arrived on CC 101 (12 messages, all layer A).
Bring-up assumption 2 holds on this unit: Program Change 0 / 1 on the Global RX channel
really selects the layer, in both directions.

## Fader 1 motor (output log `fader-move-2026-11-12.jsonl`, 5 commands)

Sent with `XTouchRemoteMIDI fader-move --fader 1 --channel 2`, one CC 1 message per run,
layer A. No XTouchCompactApp process was running. The tool listened for 1 s before each
send and for 4–5 s after. Positions are the operator's readings of the printed scale.

| Sent | Operator's hand | Device TX after the send | F1 afterwards |
| --- | --- | --- | --- |
| 20 | off | none in 4 s | moved, about −45 |
| 60 | off | none in 4 s | about −12 |
| 0 | off | none in 4 s | bottom, −∞ |
| 60 | tapping; released at the send | touch messages only | about −12 |
| 0 | holding still, before and throughout | none in 5 s | stayed about −12; still there after release |

- **Motors listen on the Global RX channel (2)**, like LEDs and rings.
- **The device sent no position message for any motor move.** A host gets no arrival
  report, so a transmitted target stays unconfirmed. Assumption 3's concern (motor progress
  echoed as untouched position reports) did not occur in these four moves.
- **Held fader: the command had no effect and was not applied on release.** The operator
  felt no force while holding; nothing was sent after the release, and F1 stayed at about
  −12 with the last command being 0. Observed once, on F1, with a light steady hold.
  Whether the firmware drops the command or the motor was simply too weak to feel is not
  separated, but the missing catch-up on release is direct. A host that wants its target
  after a touch must send it again on release; the firmware does not.
- In the fourth run the tool's guard saw 7 touch messages while listening, the last a
  release, and sent. A touch-down arrived 64 ms after the send, a release at 193 ms, then
  no touch message until 2.5 s. The fader reached the target, so this run says nothing
  about a touched fader. The guard has since been changed to refuse on any touch message
  for the fader during the listening window, not only when the latest one is down.
- A hand resting on the cap since before the listening window sends nothing (fifth run:
  0 messages), so the tool cannot see it. That stays an operator precaution.

## App-level motor gating on F1 (after midnight; app built from `663771d` plus the uncommitted tool change)

`XTouchCompactApp --hardware-control`, RX channel 2, with `XTouchRemoteMIDI listen` running
beside it as an independent record of device TX. Captures: `app-hw6-listen-2026-11-13.jsonl`,
`XTouchCompact-capture-1794500725.jsonl`, `XTouchCompact-capture-1794501019.jsonl`. The
operator drove the app; no tool command was sent.

- **Touch blocking and release.** With F1 held about 11 s and the software-write slider
  moved, the app's monitor showed no output; on release it showed one `CC ch2 #1=81`.
  Evidence for this run is a monitor screenshot (second resolution) plus the listener's
  touch times, not a capture file. Earlier attempts with unsteady touch are not counted.
- **Layer mismatch.** After the physical B key and an F1 touch on CC 111, the app reported
  device B / host A. A slider write then produced no output at all. "Realign current
  layer" sent Program Change 0, 16 ring and 39 LED messages and no motor command, and did
  not replay the withheld write. A later slider drag sent five motor commands within
  0.11 s (44, 47, 54, 61, 63): one per intermediate drag value.
- **Reconnect and app layer buttons.** USB unplug/replug: on reconnect the app sent Program
  Change 0 plus the same 55 nonmotor messages, no motor command. Clicking B, then A, each
  sent one Program Change plus 55 nonmotor messages, no motor command.
- **The firmware moves the fader on a layer change.** F1 travelled to the bottom and back
  to where it was on the physical B key (no MIDI involved), on "Realign current layer",
  on the reconnect, and on each app layer click. The device transmitted nothing during
  any of these. So Program Change is not motor-neutral on this unit, and firmware motor
  travel is not reported. For the reconnect it is not separated whether the travel came
  from power-up or from the Program Change sent 1 ms after the connection appeared. The
  operator saw only F1 move; where F2–F9 stood was not recorded.
- **App defect seen, since fixed.** After clicking A the hardware lit A while the app still
  highlighted B. In hardware mode the layer buttons highlighted the layer of the last
  device *input* (an F1 touch on B, five minutes earlier), not the host selection. They
  now show the host selection; the last input layer remains the separate text line. The
  fix and the corrected "moves no fader" wording were not rechecked on the hardware.
- The listener recorded two more source losses at 00:33:06 and 00:33:31 local, after the
  last capture ended: the operator unplugged the unit twice.
- Slider drags are not rate limited (five commands in 0.11 s above). The fader reached the
  final value; no limit was added.

## Faders 2–9 and layer B motors (output log `fader-move-2026-11-13.jsonl`, 12 commands)

Sent with `XTouchRemoteMIDI fader-move` and `select-layer` on channel 2, app not running,
the listener still recording device TX. Each command was announced first.

- **F2–F9, layer A.** One `CC n = 40` each, about 5 s apart. All eight moved; the operator
  read them between −24 and −26. F1 did not move. No device TX followed any of them.
- **Program Change to B.** The B key lit and all nine faders travelled to the bottom and
  back to where they were. No device TX.
- **F1 on layer B.** `CC 1 = 60` moved it slightly (from about −10), `CC 1 = 20` moved it to
  about −45. The motor address is the same CC on both layers.
- **Program Change back to A.** All nine travelled to the bottom and back; F1 ended at
  about −45, the position given on layer B, not the −10 it had on layer A. The firmware
  did not restore a separate layer A position. The operator did not report the A key.

So on this unit every layer change, from the key or from Program Change, cycles all nine
motors and returns them to the same physical positions, and reports nothing. F2–F9 were
tested at one value on layer A only.

## Not established by this session

- Only control 1 of each kind was exercised: this is not HW-2/HW-3 coverage and not C2.
- Firmware version (HW-1 remainder).
- Motor behavior beyond the sections above: F2–F9 on layer B, positions other than those
  listed, repeatability, a held fader other than F1, and what a layer change does to a
  fader that is being touched. The app-level checks above were each done once, on F1,
  layer A as host layer.
- Ring behavior under local knob movement per style, ring LED colors, blink periods, and
  rings E7–E16 beyond the display values listed (E7, E8 were used for 27 and 28).
- Pedals were not connected.

## Startup readback

The same route now has a working control case, so the earlier silent attach captures are
meaningful: see [the investigation record](STARTUP_READBACK_INVESTIGATION.md).
