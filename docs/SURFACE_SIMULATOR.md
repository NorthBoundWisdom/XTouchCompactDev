# XTouch software Surface Provider

`XTouchSurfaceSimulator` is an isolated, hardware-free executable. It imports the
same pinned shared control contract as BCR and uses the existing
`CompactSession` / `MockXTouchCompact` interaction engine. It never initializes
CoreMIDI, loads user profiles, accesses Keychain, opens OSC output, or starts the
GUI. No physical controller or actuator qualification is implied.

## Build and deliver

Acquire the committed dependency through the normal manager, then build:

```sh
SURFACE_PLUGINS_SOURCE=/path/to/committed/SurfacePlugins python3 configs/surface_plugins_dependency.py update
swift build --jobs 2 --product XTouchSurfaceSimulator
```

For a clean, independently consumable delivery:

```sh
python3 configs/package_surface_simulator.py --output build/deliveries/surface-simulator-v1
```

The output contains the binary, `manifest.json`, dependency lock,
`control-contract.json` (shared tool schemas plus the actual profile), this guide,
`minimal_consumer.py`, and `surface-control-sdk-1.0.0.zip`. The same public Python SDK and `examples/surface_roundtrip.py` can consume both hosts using a pinned manifest; upstream file provenance is in `surface-control-sdk-source.json`. the optional `examples/pipe_surface_trial.py` requires an explicitly isolated Pipe taskless-trial deployment and owned state. The manifest hashes every other file and records exact
host/shared revisions, platform, architecture, and build configuration. It is a
local software delivery, without a release tag or notarization claim.

## Start, readiness, stop

Every process receives a fresh random instance ID by default. Use a separate process, credential, and ready path per simulator. `--surface-instance-id` is an explicit test override; consumers must still pin the fresh epoch and should not reuse a test instance identity for a restarted production-like session.
The process has no persistent state directory and does not access user stores.
Read-only is the default. Each mutation category has a separate explicit flag.
Generate a private token of at least 16 characters and send it on stdin:

```sh
umask 077
python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > build/simulator-token
cat build/simulator-token | .build/debug/XTouchSurfaceSimulator \
  --token-stdin --surface-instance-id car.a --port 0 \
  --ready-file build/simulator-a.ready.json \
  --allow-surface-input --allow-surface-feedback --allow-surface-reset
```

The executable binds only `127.0.0.1`. Port `0` chooses an available port; an
explicit UInt16 port is also supported. It prints one compact ready JSON line to
stdout after binding, including PID, URL, and the public identity pin; credentials
are omitted. `--ready-file` is optional and refuses to overwrite an existing file.
`--token-file` is an alternative to `--token-stdin`; use only one. Stop by
terminating this isolated process. A restart receives a fresh random epoch and
never replays input, restores control authority, or touches another instance.
Remove an old ready file explicitly before reusing its path.

```sh
python3 minimal_consumer.py --ready-file build/simulator-a.ready.json \
  --token-file build/simulator-token
```

Add `--exercise` to send one explicit ordinary input and a separate link display
update. The example discovers mapping IDs and uses the documented tools; it does
not import host source. It never retries a mutation after an unknown response.

## Optional control contract 1.0

`POST /mcp` accepts authenticated stateless JSON-RPC requests using MCP `2025-11-25` or `2026-07-28`. Initialization negotiates these versions; no session ID is required. Set
`Authorization: Bearer <token>` and `Content-Type: application/json`. Browser
Origin requests are rejected. Each complete HTTP request has one absolute three-second read budget, including partial headers and bodies. The new executable exposes only these six tools,
alongside `initialize`, `ping`, and `tools/list`:

| Tool | Operation |
| --- | --- |
| `surface_control_discover` | Profile, capabilities, identity, and latest sequence |
| `surface_control_snapshot` | Seeded/last accepted raw input, independent display feedback, and server time |
| `surface_control_input` | Explicit simulated gesture through the existing Mock/session |
| `surface_control_feedback` | Display intent only; never an input or parameter write |
| `surface_control_events` | Bounded input/feedback journal with server time |
| `surface_control_reset` | Clear isolated state and rotate epoch |

The GUI's existing three tools and shared business tools retain their own
interfaces and permissions. This optional contract does not rename or replace
them. It is separately discoverable and requires explicit adoption by a consumer.

Every mutation supplies all five `expected` identity fields and a canonical
`expected_sequence` decimal string. Accepted and ignored events advance that
sequence; a duplicate old request fails `stale_sequence`. Get a fresh snapshot
before choosing a *new* operation. Do not retry an uncertain operation by updating
its sequence. Failed validation leaves engine, Mock, and journal unchanged.
Failures use the shared stable code in `structuredContent`, with `isError: true`.
A transport failure means the operation's outcome is unknown.

A reset rotates epoch and sets the event cursor to zero. Input state is seeded
from the new Mock, without generating input events. Snapshot input values contain initial Mock state and last accepted raw input; they are not actual telemetry or operations that should be replayed. Consumers
react only to subsequent `accepted` input events. Remapping, restart, and local
layer selection invalidate old pins; event gaps require snapshot/re-arm rather
than event replay. The journal retains at most 1024 events; queries report
`event_gap` for lost or future cursors. Mutations share a 60-per-second budget.

## XTouch profile and semantics

`xtouch.compact.standard.simulation` version `1.0` declares 178 controls across
layers A/B. IDs are `a.fader.1` … `a.fader.9`, `a.touch.1` … `a.touch.9`,
`a.encoder.1` … `a.encoder.16`, `a.push.1` … `a.push.16`,
`a.button.1` … `a.button.39`, and corresponding `b.*` IDs.

Faders and stock encoders accept integer absolute scalar values `0…127`.
An endless knob is not advertised as a relative MIDI encoder. Touch, push, and
button gestures accept booleans. Unsupported IDs, profiles, relative encodings,
fractional scalar values, and out-of-range values fail visibly.

The headless demonstration starts in layer A. Inactive-layer input/feedback is
`ignored` with `inactive_layer`; the Swift host API can explicitly select a layer
with a fresh epoch. No layer operation recalls motors. Identical raw input is
`ignored` with `no_change`, preventing repeated button-down from toggling twice.
Simulation writes preserve `agentWritable` and `externallyProtected`; action
assignments require a separate explicit composition and are not executed here.

Feedback supports scalar fader/encoder display values and button indicators
`off`, `on`, `blink`. Encoders render the existing 13-segment ring policy. Fader
feedback is explicit display intent and still cannot move a touched fader; release
can reconcile pending desire. Feedback never alters parameters, emits input,
updates the physical-observation cache, or treats last-sent as actual measurement.
Business display state is restored after local redraws without emitting events.
All events and discovery identify `source: simulation`; remote requests cannot
choose hardware origin. The contract does not expose a hardware readback API.

The demonstration binds ordinary parameters `simulation.arm`, `simulation.start`,
`simulation.pause`, `simulation.cancel` to A encoders 1–4. Three additional configured parameter mapping IDs are `simulation.state` (A button 1), `simulation.progress` (A encoder 5), and
`simulation.link` (A button 2). Feedback remains display-only even for these real parameter assignments. These names provide an example mapping; the
consumer owns preparation/start/pause/cancel semantics and authoritative status.
A Surface simulator does not execute a Pipe workflow or grant production approval.
Use an explicitly isolated simulation deployment for business trials. Existing
production operator bridges that require hardware input remain ineligible.


## Verification

`swift test --jobs 2` includes a runner for the pinned shared versioned fixture,
using real Mock/session values and an injected clock. It emits
`build/surface-scenario-report.json` with exact source/fixture hashes and per-step
results. This deterministic report is separate from real HTTP/process evidence.
Run the latter with
`python3 -m unittest discover -s Tests/SimulatorIntegration -v` after building the
executable. The tests copy the binary to an isolated working directory, exercise
both public MCP versions with the common SDK, discard a write response, reject
stale CAS, restart a default instance at the same port, and isolate A/B processes.
No test here starts a production Pipe service or connects physical hardware.
