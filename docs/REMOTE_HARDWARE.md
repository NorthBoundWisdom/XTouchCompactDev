# Remote hardware for development

Use this when the controller is plugged into another Mac (for example the CI Mac mini)
and you want to develop against it from your own Mac. **For development only.** Real use
and hardware sign-off still use a controller plugged in directly over USB.

## How it works

```
your Mac                                          Mac with the controller
XTouchCompactApp ⇄ virtual MIDI ports ⇄ XTouchRemoteMIDI client ══ ssh ══ XTouchRemoteMIDI bridge ⇄ X-TOUCH COMPACT (USB)
                   "X-TOUCH COMPACT (via <host>)"
```

- The client starts the bridge over SSH and carries raw MIDI 1.0 packets over the SSH
  session's stdin/stdout. No port is opened on either Mac, and SSH handles
  authentication, so the existing ComputePool SSH trust applies.
- The virtual ports exist only while the bridge reports the controller. Unplugging it,
  losing the network, or stopping the client looks to the app like a USB unplug. The bridge
  and client ping each other every 2 s and drop the link after 6 s of silence. The client
  reconnects with backoff (1 → 15 s).
- The port name contains "X-TOUCH COMPACT", so the app's automatic matching selects it
  like a USB device. Stable unique IDs keep a manual port choice across restarts.
- Neither side parses, filters, generates or acknowledges MIDI. Touch ownership, layer
  gates, listen-only and every other safety rule stay in the app, unchanged.
- The bridge notices the controller being plugged in or unplugged while it runs. (Until
  2026-11-12 it only saw devices present at start, because CoreMIDI setup notifications
  need the creating thread's run loop.)
- The bridge never forwards a port whose name already contains "(via …)", so the link
  cannot loop through another bridge.

macOS Network MIDI (RTP-MIDI) was considered first. Over SSH on the Mac mini its session
stayed disabled, both from a plain SSH shell and from a job bootstrapped into the
logged-in user's launchd domain. Enabling it needs Audio MIDI Setup clicks on the remote
desktop, so this tool uses an SSH stream instead.

## Use

```sh
python3 configs/setup_local_project.py            # once, as for any build
python3 tools/remote_hardware.py deploy  --ssh henrys-mac-mini
python3 tools/remote_hardware.py devices --ssh henrys-mac-mini   # the controller should show [controller]
python3 tools/remote_hardware.py connect --ssh henrys-mac-mini   # keep running; Ctrl-C to stop
python3 tools/remote_hardware.py status  --ssh henrys-mac-mini   # read-only check, any time
```

`connect --listen-only` publishes the same ports but drops everything the local app sends,
in the client and again in the bridge. Use it while the app's own listen-only state is
uncertain: for example an app started with `--hardware-control` selects the remote port
automatically and immediately sends its layer assertion and LED sync.

`listen` (with or without `--ssh`) is a passive raw capture to stdout as JSON lines; it
cannot send MIDI. See [the startup readback procedure](STARTUP_READBACK_INVESTIGATION.md).

`summarize FILE` decodes a `listen` capture offline (control, layer, count, value range).

`status` starts nothing. It reports whether the deployed bridge matches a local build
(`current` / `outdated, run deploy` / `not deployed`), which bridges are running on the
remote Mac, which local clients are running, and whether the controller is visible there.

`deploy` builds a release binary in `build/remote-midi/` and installs it as
`~/.xtouch-remote/XTouchRemoteMIDI` on the remote Mac. Rerun `deploy` after changing the
bridge; a running bridge keeps its old binary until the next connection. The remote Mac
needs a logged-in user only for the controller's own driver; the bridge itself runs from
SSH. It does not touch the GitHub runner services.

Then start the app as usual. The Connection page labels the port **Remote** and shows
which Mac it comes through.

## Evidence

Captures record `route: "remote"` and `remoteBridgeHost` in the session header, and the
port name records the bridge host. Remote evidence is development data: it is never a USB
sign-off for HW-1…HW-7, C2–C4 or the N5 checklist. Latency comes from the Tailscale path
(about 110–125 ms through the peer relay on 2026-11-12, without a direct connection).
Motor tests over this route can race a hand already on a fader, so run them with nobody
touching the unit.

## Verified so far

On 2026-11-12 a physical X-TOUCH COMPACT was attached to the Mac mini (USB VID/PID
`0x1397 / 0x00B2`, `bcdDevice 0x0200`, the same identity as the 2026-11-11 session; the
descriptor's serial string reads `1.0.1` and is **not** a verified firmware version).

- `status` and `devices` over SSH see the controller's source and destination, so a bridge
  started from SSH can reach the real USB device.
- A 12 s passive `listen` capture that attached to the already-powered, connected, idle
  controller received no message (`captures/private/readback-attach-2026-11-12.jsonl`,
  not committed). This is case C of the startup-readback procedure only, without the control
  case D, so it does not yet show that the route delivers input.
- A 12 s `connect --listen-only` link came online with the real controller. A locally
  running app in hardware-control mode attached to the port at once and its first
  packet was suppressed: nothing was written to the device.
- **Not yet verified on the physical unit:** input arriving through the link (nobody
  operated a control during these checks), and any host-to-device output.

On 2026-11-12, with no controller plugged into the Mac mini, a temporary virtual
"X-TOUCH COMPACT" device stood in for it. The client published both ports locally, fader
CC from the remote device arrived in order, and a Note On sent locally reached the remote
device. The temporary device and its files were then removed. **A physical controller on the
remote Mac has not been tested yet.** Run `devices` once it is plugged in.
