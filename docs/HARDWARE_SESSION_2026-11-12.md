# Hardware session 2026-11-12 — input checks and button-LED output

Controller attached by USB to the development Mac (VID/PID `0x1397 / 0x00B2`,
`bcdDevice 0x0200`; the descriptor serial string `1.0.1` is not a verified firmware
version). The input sections used `XTouchRemoteMIDI listen`, which has no output port, so
nothing was sent during them. The button-LED section sent 26 button-LED Note On messages
with operator consent and nothing else: no Control Change, so no motor, ring, layer or
mode command. Raw captures are in `captures/private/` (not committed).

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

## Not established by this session

- Only control 1 of each kind was exercised: this is not HW-2/HW-3 coverage and not C2.
- Firmware version, ring styles and displays over RX, Program Change layer selection and
  all motor behavior (HW-1 remainder, HW-4, the layer half of HW-5, HW-6): none of these was
  sent. Whether rings and motors also listen on channel 2 is expected but not observed.
- Pedals were not connected.

## Startup readback

The same route now has a working control case, so the earlier silent attach captures are
meaningful: see [the investigation record](STARTUP_READBACK_INVESTIGATION.md).
