# Hardware session 2026-11-12 — input checks and nonmotor output

Controller attached by USB to the development Mac (VID/PID `0x1397 / 0x00B2`,
`bcdDevice 0x0200`; the descriptor serial string `1.0.1` is not a verified firmware
version). The input sections used `XTouchRemoteMIDI listen`, which has no output port, so
nothing was sent during them. With operator consent, the output sections sent button-LED
Note On, ring display (CC 26–41), ring style (CC 10–25) and Program Change messages only.
**No motor command (CC 1–9) and no mode switch (CC 127) was sent**; the sender cannot
express them. Raw captures are in `captures/private/` (not committed).

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

## Not established by this session

- Only control 1 of each kind was exercised: this is not HW-2/HW-3 coverage and not C2.
- Firmware version, and all motor behavior (HW-1 remainder, HW-6): no motor command was
  sent. Motors are expected to listen on channel 2 like LEDs and rings, but this is not observed.
- Ring behavior under local knob movement per style, ring LED colors, blink periods, and
  rings E7–E16 beyond the display values listed (E7, E8 were used for 27 and 28).
- Pedals were not connected.

## Startup readback

The same route now has a working control case, so the earlier silent attach captures are
meaningful: see [the investigation record](STARTUP_READBACK_INVESTIGATION.md).
