# Hardware session 2026-11-12 — passive input checks

Controller attached by USB to the development Mac (VID/PID `0x1397 / 0x00B2`,
`bcdDevice 0x0200`; the descriptor serial string `1.0.1` is not a verified firmware
version). Everything here used `XTouchRemoteMIDI listen`, which has no output port:
**nothing was sent to the device.** Raw captures are in `captures/private/` (not committed).

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

## Not established by this session

- Only control 1 of each kind was exercised: this is not HW-2/HW-3 coverage and not C2.
- Encoder mode: three rotation messages in total (values 1, 2, 1). That is too little to
  tell absolute from relative reporting, or to see acceleration.
- Firmware version, Global RX channel, LED encodings, ring styles and all motor behavior
  (HW-1 remainder, HW-4, HW-5, HW-6) are untouched: no output was sent.
- Pedals were not connected.

## Startup readback

The same route now has a working control case, so the earlier silent attach captures are
meaningful: see [the investigation record](STARTUP_READBACK_INVESTIGATION.md).
