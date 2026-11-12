# X-TOUCH COMPACT factory Standard MIDI — model contract

Manufacturer sources: X-TOUCH COMPACT Quick Start Guide V6.0, MIDI maps and RX MIDI DATA. Hardware deviations: JetsonHacks/xtouch-compact's empirical characterization on firmware 1.14. **This is a document of intended test behavior, not proof that the user's unit has the factory preset.**

## Geometry

| Element | Count | Normalized ID |
|---|---:|---|
| Touch-sensitive motor faders | 9 | `fader(1...9)` (9 = master) |
| Fader touch inputs | 9 | `faderTouch(1...9)` |
| Endless physical encoders | 16 | `encoder(1...16)` |
| Encoder push actions | 16 | `encoderPush(1...16)` |
| Lighted buttons | 39 | `button(1...39)` |
| Physical A/B selector buttons | 2 | Local layer selection, not a dedicated outbound MIDI event |
| Footswitch / expression pedal | 2 | `footswitch`, `expression` (optional accessories, outside the 89 bring-up actions) |

## TX (device → host; MIDI Channel 1 in default factory preset)

| Physical control | Layer A MIDI | Layer B MIDI |
|---|---|---|
| Fader 1...9 position | CC 1...9 | CC 28...36 |
| Fader 1...9 touch | CC 101...109 | CC 111...119 |
| Encoder 1...16 rotation | CC 10...25 | CC 37...52 |
| Encoder 1...16 push | Note 0...15 | Note 55...70 |
| Buttons 1...39 push | Note 16...54 | Note 71...109 |
| Expression / footswitch | CC 26 / CC 27 | CC 63 / CC 64 |

Pedals: expression decodes as an absolute 0...127 value; footswitch decodes as pressed when the CC value is above 0. Footswitch polarity, expression range and whether a disconnected jack transmits anything are **not physically tested**. Pedals have no RX feedback address: CC 26 / 27 on RX are encoder 1 / 2 ring displays on the Global channel, a different address space from TX CC 26 / 27.

Inputs encoded as Note On velocity 127 for press and Note Off velocity 0 for release (empirical firmware 1.14), fader touch CC 127 and release CC 0. Encoder rotations are typically accelerated **absolute** 0...127 values under stock preset: turning an endless knob does not guarantee limitless software parameter increments.

## RX (host → device; configured Global MIDI Channel, possibly DIFFERENT from TX channel)

| Action | MIDI | Notes |
|---|---|---|
| Motor move fader 1...9 | CC 1...9, value 0...127 | Same RX address in both layers |
| Encoder ring mode 1...16 | CC 10...25 | 0 Single, 1 Pan, 2 Fan, 3 Spread, 4 Trim |
| Encoder ring display 1...16 | CC 26...41 | 0 off; 1...13 one LED; 14...26 blink LED; 27 all on; 28 all blink. Observed on the project's unit (2026-11-12): as listed, and always a single LED whatever the ring style |
| Buttons 1...39 LED | Note 0...38 | Addresses differ from TX button notes |
| Select Layer A/B | Program Change 0 / 1 | Standard mode only; host command, not physical-layer readback; suppressed while listening |
| Mode (Standard / MC) | CC 127 = 0 / 1 | Do not send automatically during P0 |

**Important documentation conflict:** Manufacturer RX table specifies button LED OFF/ON/BLINK via Note velocity 0/1/2. JetsonHacks measured actual firmware 1.14 behavior 0/2/3. Both modes are selectable in the Swift core to avoid silently assuming a firmware version. **Observed on the project's unit (2026-11-12): 0 off, 1 off, 2 on, 3 blink**, i.e. the 0/2/3 encoding; its firmware version is still unread.

**Global Channel:** RX messages use GLOBAL CH rather than necessarily the same channel as TX preset events. This is an explicit configuration field in the model. **Observed on the project's unit (2026-11-12): it transmits on channel 1 and receives button LEDs only on channel 2.**

## Device state traps observed on real hardware

1. **Motor touch ownership:** while a fader is touched, don't send motor moves; reconcile on release based on application authority. The hardware may suppress the motor while touched, but application state must not race it.
2. **Motor commands do not reliably echo position** after moving the slider. `commandedPosition` and `observedPosition` are different facts.
3. **Ring mode changes** and **local knob rotation** may overwrite remote ring illumination. Invalidate last-sent cache and reassert desired ring position.
4. **Six right-area transport buttons** may redraw the whole LED group locally. Invalidate the group cache after a button press.
5. **Physical A/B buttons** don't emit explicit layer-changed MIDI, so don't treat cached software layer as immutable. Active connections currently assert the software layer via Program Change; suppress this during passive startup-state investigation because it changes the state being measured. Characterize button transitions and retain input-address layer evidence independently of the host bank.
6. **MC fader resolution:** stock MC mode carries fader positions in Pitch Bend-shaped messages but independent measurements show mostly zero low byte (roughly 7 bits effective). Standard mode already uses CC 0...127. Advanced firmware research exists but should not be a P0 dependency.

## Example: the common mistake to avoid

```
Physical: Button 1, Layer A
   press IN: Note On #16, velocity 127
   LED ON OUT: Note On #0, velocity 1 (manual) OR 2 (observed 1.14)

Physical: Fader 1, Layer B
   position IN: CC #28, value 100
   motor OUT:  CC #1, value 100 (Global Channel)
```

Using one symmetric `MIDIControlID` for both `IN` and `OUT` would update the wrong button or fail to move the correct motor.

## Physical evidence and simulation boundaries

### Startup full-state readback — unverified

Whether startup, USB reattachment, client attachment or a documented read-only
request can return all nine physical fader positions remains open. Missing input
in the current app, touch-only messages, and absence of a query from the RX table
do not prove the device lacks this capability. Last-input history is a fallback;
verified fresh full-state input should take priority. Reading does not authorize
motor recall. See [the corrected investigation record](STARTUP_READBACK_INVESTIGATION.md).

### Partial physical evidence — 2026-11-11

The operator accepted the native observation workspace's visible response. Its
reviewed capture prefix contains 56 Layer A touch/release inputs on TX channel 1:
CC 101–105 and 107–109, touch 127 / release 0. These match the documented touch
subset; CC 106 and every Layer B input remain unverified in this capture. No
position, encoder, button-note or output message is present in the prefix.
Firmware and actual Global RX are still unknown. See the
[session record and evidence fingerprint](HARDWARE_SESSION_2026-11-11.md).
This limited observation does not verify the remaining TX/RX tables or the three
motor-safety firmware assumptions.

### Simulation boundaries

`MockXTouchCompact` deterministically models the tables above with separate configured TX and Global RX channels. Motors arrive immediately without emitting a position acknowledgement; touched motors reject commands and increment a diagnostic counter. Physical layer selection emits no messages and leaves faders in place. Encoders retain a separate local absolute value: RX ring commands change illumination, not that value.

Local redraws are intentionally disruptive so tests exercise reassertion: rotation and ring-style changes redraw from the local encoder value; a transport press clears the other five LEDs and lights the pressed key; release turns that key off. These redraw patterns, encoder accumulator behavior across layer changes, initial simulated positions and instantaneous motor motion are simulation choices, **not per-firmware physical measurements**.

This protocol core test suite is **not** a substitute for capture-based, per-firmware verification. It does not prove USB enumeration, physical position precision, motor servo calibration, patch loading or Mac DriverKit compatibility.

## Address inspection

`FactoryStandardMap.inputAddress(for:layer:)` returns a structured `MIDIAddress`
for each supported physical input. `feedbackAddress(for:)` returns the motor,
ring-display or button LED address independently of layer and TX channel. Fader
touch and encoder push have no feedback address. Encoder ring style is available
separately through `encoderRingStyleAddress(encoder:)`.

Addresses carry message type, zero-based channel and number; their descriptions
use human-readable channels 1–16, e.g. `CC ch1 #28`. `Note` describes the shared
Note On/Off number, not a velocity or a LED encoding. Invalid control indices
return nil. These APIs describe the factory profile only; they do not send MIDI,
learn a device preset or establish a position observation. The inspector reads
the applied session profile rather than uncommitted channel edits.

## Cross-layer safety evidence

Factory TX CC and Note ranges identify the sending layer without relying on the
host's selected bank. The decoder reports that actual address layer, including
other-layer touch/release. A/B buttons still emit no dedicated layer-change event;
subsequent factory TX addresses provide evidence of a mismatch. The state tracks
physical touch independently of bank, and blocks motors during a known mismatch.
Physical fader reports update observations/parameters but do not echo a quantized
command to their own motor. Real-unit behavior remains subject to HW-6/HW-7.

Explicit layer realignment can reassert the currently selected layer and discard
old mismatch evidence without recalling motors or clearing touch. A disconnect
while touched keeps the latch until a fresh touch/release cycle is received after
reconnection; neither reassertion nor reconnect fabricates a release observation.
