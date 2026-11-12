# Startup full-state readback — investigation remains open

Recorded 2026-11-12 after the operator questioned the earlier conclusion. The
controller was offline for this clarification; no new hardware experiment was run.

## Corrected conclusion

**Whether factory Standard MIDI mode can return all nine current physical fader
positions at startup is unverified. It must not be described as impossible.**
The earlier inference from “the current app did not receive or display them” to
“the device cannot supply them” was not justified. The absence of a full-position
query in the [manufacturer's RX table](https://www.bhphotovideo.com/lit_files/1142317.pdf)
does not establish that power-on/USB attachment cannot emit a state burst, or that
no documented device-specific read-only request exists.

## Evidence so far

- Captured touch-only events used CC101–109 on A or CC111–119 on B, with 127/0.
  Those events reported touch/release; they did not contain fader positions.
  This does not characterize every startup or request-triggered response.
- A later manual F1 movement produced Layer B CC28 values 1 through 8. The host
  was on A, and the old panel continued drawing A's software value. This was a
  display/authority separation bug, not evidence that positions were unreadable.
- No controlled full startup-state capture or read-only full-state request test
  has established either support or lack of support. Ring calibration and input
  coverage do not substitute for that test.

## Next hardware session

Distinguish device power-on, USB reattachment, and app/client attachment while the
controller is already powered. Capture each with a listener ready before the
relevant event, keeping the physical faders still and retaining raw MIDI/UMP,
including SysEx fragments. Check that app filtering or late listener attachment
has not discarded an initial burst. Record the mode, firmware, route, TX channel,
and the timing and completeness of any nine-position response.

Use passive capture: the normal active connection currently asserts the software
layer and restores nonmotor feedback, which would alter the initial state under
investigation. If a documented read-only request is identified, characterize it
separately from unsolicited startup traffic. Do not invent SysEx commands, rewrite
presets, switch to uncharacterized modes, flash firmware, or move motors to obtain
readings. TX evidence never establishes the Global RX channel.

If a complete physical response is verified, prioritize it as the startup panel
source. Feed received positions through the physical-observation path; do not
implement synchronization by sending stored targets back to the motors.

## Capture procedure (ready to run)

`XTouchRemoteMIDI listen` is a passive raw listener: it creates no output port, so it
cannot send MIDI, and it never asserts a layer or restores feedback. It connects to the
controller's source as soon as it appears (also after the listener started) and prints
one JSON line per packet with raw UMP words, SysEx included, and a monotonic `t`.

```sh
python3 configs/setup_local_project.py
mkdir -p captures/private          # ignored by Git
# Controller on this Mac:
python3 tools/remote_hardware.py listen --seconds 20 > captures/private/readback-<case>.jsonl
# Controller on another Mac (after `deploy`):
python3 tools/remote_hardware.py listen --ssh henrys-mac-mini > captures/private/readback-<case>.jsonl
```

Quit XTouchCompactApp and any other MIDI software first, so nothing else writes to the
device. Put the nine faders at distinct, noted positions (for example a staircase), do not
touch them during a case, and let `--seconds` end each capture (or press Ctrl-C about 10 s
after the event).

| Case | Start the listener, then… | File |
| --- | --- | --- |
| A power-on | Power switch off → start listener → power on | `readback-poweron.jsonl` |
| B USB reattach | Powered, USB unplugged → start listener → plug USB | `readback-usb.jsonl` |
| C client attach | Powered and connected, idle 10 s → start listener | `readback-attach.jsonl` |
| D control | Right after C, move F1 slightly | `readback-control.jsonl` |

Case D proves the listener and route work, so that silence in A–C is meaningful.
Record firmware, mode (Standard), route (local or remote host), and the fader positions
you set. Reading the result: `source-connected` marks when CoreMIDI exposed the device;
position reports are `20B0nnvv` words with `nn` = 01–09 (layer A) or 1C–24 (layer B).
Nine such words shortly after `source-connected`, matching the set positions, would
verify an unsolicited startup report for that case. Their absence in all of A–C, with D
working, shows only that **these three events** do not trigger a report in this
configuration; it still says nothing about request-triggered readback.

A remote capture adds network delay to `t` ordering only on the SSH stream, not to the
timestamps, which are taken on the Mac with the controller.

To read a capture without decoding hex by hand:

```sh
python3 tools/remote_hardware.py summarize captures/private/readback-<case>.jsonl
```

It lists the listener events, then each control seen with its layer, message count, value
range and channel, using the factory Standard TX table. Words outside that table are
listed raw. It is a reading aid that assumes the factory preset, not a sign-off.

### Results so far

| Date | Case | Route | Result |
| --- | --- | --- | --- |
| 2026-11-12 | C client attach | remote, `henrys-mac-mini` | `source-connected` at 0.585 s, then no message for 12 s. Fader positions were not noted and control case D was not run, so this shows only that this attach produced no unsolicited report; it does not yet prove the route delivers input. |

| 2026-11-12 | C client attach | local USB | `source-connected` at 0.020 s, then no message for 15 s. |
| 2026-11-12 | idle | local USB | A 240 s capture with nobody operating the unit: no message at all, so the idle device sends no periodic or keep-alive traffic that the listener can see. |

Three attach captures (one remote, two local) agree: attaching a client to an
already-powered, idle controller triggers no unsolicited position report. **Control case D
is still missing**, so none of these captures has yet been shown to receive input over
the same route. Cases A, B and D need someone at the unit.

## Current fallback and safety policy

The app currently implements timestamped last-input history, displayed as stale
after restart, and unknown markers where no input has been recorded. **This is a
fallback while full-state readback remains unverified, not a decision that full
readback is unsupported.** A cache cannot confirm changes made while the app was
closed. Fresh verified device input should supersede it.

Reading and actuation are independent: never command a touched motor, and never
automatically recall motor positions on startup, reconnect, or layer selection.
Those safety rules remain in force even if startup full-state reading is supported.
