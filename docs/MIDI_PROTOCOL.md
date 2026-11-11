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
| Footswitch / expression pedal | 2 | Reserved; typed input not yet implemented |

## TX (device → host; MIDI Channel 1 in default factory preset)

| Physical control | Layer A MIDI | Layer B MIDI |
|---|---|---|
| Fader 1...9 position | CC 1...9 | CC 28...36 |
| Fader 1...9 touch | CC 101...109 | CC 111...119 |
| Encoder 1...16 rotation | CC 10...25 | CC 37...52 |
| Encoder 1...16 push | Note 0...15 | Note 55...70 |
| Buttons 1...39 push | Note 16...54 | Note 71...109 |
| Expression / footswitch | CC 26 / CC 27 | CC 63 / CC 64 |

Inputs encoded as Note On velocity 127 for press and Note Off velocity 0 for release (empirical firmware 1.14), fader touch CC 127 and release CC 0. Encoder rotations are typically accelerated **absolute** 0...127 values under stock preset: turning an endless knob does not guarantee limitless software parameter increments.

## RX (host → device; configured Global MIDI Channel, possibly DIFFERENT from TX channel)

| Action | MIDI | Notes |
|---|---|---|
| Motor move fader 1...9 | CC 1...9, value 0...127 | Same RX address in both layers |
| Encoder ring mode 1...16 | CC 10...25 | 0 Single, 1 Pan, 2 Fan, 3 Spread, 4 Trim |
| Encoder ring display 1...16 | CC 26...41 | 0 off; 1...13 one LED; 14...26 blink LED; 27 all on; 28 all blink |
| Buttons 1...39 LED | Note 0...38 | Addresses differ from TX button notes |
| Select Layer A/B | Program Change 0 / 1 | Standard mode only; should be asserted on startup |
| Mode (Standard / MC) | CC 127 = 0 / 1 | Do not send automatically during P0 |

**Important documentation conflict:** Manufacturer RX table specifies button LED OFF/ON/BLINK via Note velocity 0/1/2. JetsonHacks measured actual firmware 1.14 behavior 0/2/3. Both modes are selectable in the Swift core to avoid silently assuming a firmware version.

**Global Channel:** RX messages use GLOBAL CH rather than necessarily the same channel as TX preset events. This is an explicit configuration field in the model.

## Device state traps observed on real hardware

1. **Motor touch ownership:** while a fader is touched, don't send motor moves; reconcile on release based on application authority. The hardware may suppress the motor while touched, but application state must not race it.
2. **Motor commands do not reliably echo position** after moving the slider. `commandedPosition` and `observedPosition` are different facts.
3. **Ring mode changes** and **local knob rotation** may overwrite remote ring illumination. Invalidate last-sent cache and reassert desired ring position.
4. **Six right-area transport buttons** may redraw the whole LED group locally. Invalidate the group cache after a button press.
5. **Physical A/B buttons** don't emit explicit layer-changed MIDI, so don't treat cached software layer as immutable. Assert startup layer via Program Change; on real hardware, characterize button transitions and recover if input addresses indicate a different layer.
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

## Mock test boundaries

This protocol core test suite is **not** a substitute for capture-based, per-firmware verification. It does not prove USB enumeration, physical position precision, motor servo calibration, patch loading or Mac DriverKit compatibility.
