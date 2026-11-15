# XTouch hardware observations and display service

`XTouchSurfaceHardware` is a macOS-only, headless Contract 1.4 hardware source.
It does not use the GUI, saved profiles, Mock motor model, or business plug-in engine.
Its output API accepts only button light, ring display and ring style messages.
There is no motor, layer selection, mode switch or raw MIDI output API.
A local software delivery does not qualify a physical unit; attended acceptance is required.

## Build and start

```sh
SURFACE_PLUGINS_SOURCE=../SurfacePlugins python3 configs/surface_plugins_dependency.py ensure
swift build --product XTouchSurfaceHardware
# Generate a private 64-lowercase-hex token file beforehand (mode 0600).
.build/debug/XTouchSurfaceHardware --device 'X-TOUCH COMPACT' \
  --transmit-channel 1 --receive-channel 2 --light-protocol observed114 \
  --token-file /private/hardware-token --port 0 --ready-file /tmp/compact.ready.json
```

`--receive-channel` (1..16) and `--light-protocol manual|observed114` are mandatory,
including for `--describe`. Transmit channel defaults to 1, device substring to
`X-TOUCH COMPACT`; ambiguous matches are disconnected. RX is never inferred from TX.
The observed unit uses TX1/RX2 and 0/2/3 button light encoding; this is not a default
assumption about other units. Standard factory MIDI only; modified presets and MC are unsupported.

Other startup options match the simulator: `--surface-instance-id`, `--port`,
`--token-file` or dedicated-pipe `--token-stdin`, `--ready-file`,
`--surface-principal-file`, `--write-limit`, and `--write-limits`.
`--allow-surface-feedback` explicitly permits displays and defaults off. Input,
renewal and reset permissions do not exist for this service. `--describe` opens no MIDI,
network or credential store and gives discovery and hardware tool schemas.
A supplied principal file follows the simulator's strict 0600/create-only convention.

Ready JSON stdout/file contains `status`, `pid`, `port`, `url`, `source: hardware`,
`test_only: false`, and `surface_control` (expected identity, sequence, contract version).
Token validation, exclusive owned-ready cleanup, auth, loopback-only HTTP and MCP
versions 2025-11-25/2026-07-28 match the simulator. `initialize`, `ping`, `tools/list`
and seven surface tools are available. No remote method accepts device input.
A restart is a fresh instance/epoch. SIGTERM/SIGINT removes only its own ready inode.

## Profile and safety

`xtouch.compact.standard.hardware`, version `1.4`, declares 182 controls: each A/B
layer has 9 position + 9 touch + 16 absolute encoders + 16 encoder pushes + 39 buttons
+ 1 optional expression + 1 optional footswitch. Every `accepts_input` is false.
There are no physical layer-key controls because those keys send no dedicated event.
IDs follow `a|b.kind.index`: `b.fader.1` and `b.touch.1` are distinct.
Pedal entries describe optional factory inputs, not a claim that accessories are present.

Only 32 encoder controls have value display feedback (integer ring display 0..28),
and 78 button controls have indicator feedback (off/on/blink). Faders, touches,
encoder pushes and pedals have no feedback. A fader feedback request fails
`unsupported_feedback` and produces no output. Valid displays require explicit
permission, connected endpoints, and input address evidence of the matching layer.
No request can assert the layer; if unknown or mismatched it fails `invalid_transition`.
A physical layer change itself is silent; last input evidence is not proof of the current
bank after an unobserved layer-key action. The service never attempts to repair this
with a Program Change. Perform attended display checks on the bank just observed.

Mapping revision uses the shared control-descriptor algorithm. An explicit private
capability discloses TX channel, RX channel and light encoding; capabilities do not enter
that algorithm, so these settings alone do not change mapping_revision. Changing any configuration requires a
fresh process and therefore a fresh identity. No device profile is rewritten.

Inputs are unknown initially. Endpoints appearing, disappearing or being replaced
rotate epoch, clear all observations/displays and input-layer evidence, and update link.
No input or feedback is replayed. Both source and destination must be unambiguous
and online for link connected. New snapshots/events include link state. Endpoint scans
and buffered inputs are processed serially with HTTP; each send rechecks endpoint identity.
Input-buffer overflow invalidates the epoch. Invalid packets are diagnosed without guessing.
Startup, endpoint changes and exit create zero device output. Only authorized display
requests send; a transport failure returns an error without an accepted feedback event.
If a multi-message ring write partially reached transport, its outcome is unknown: do not retry.

Use SDK 1.4.0 with `accepted_sources=("hardware",)` and discover contract 1.4.
Old default clients fail closed. Hardware `input`, `renew`, and `reset` are rejected
with permission_denied, unsupported_hold, and unsupported_tool respectively.
Consumers must stop on link loss, epoch change or event gaps and explicitly prepare
again. A held enable is observed press-without-release in the same connected epoch,
not a simulation lease or an emergency stop guarantee.

Suggested B-bank chassis roles: enable `b.button.1`, speed `b.fader.1`, steering
`b.encoder.1`, stop `b.button.2`; use `b.touch.1` for independent touch observation.
Each factory address identifies its input layer. Choose the same `a.*` IDs when the
operator uses A; do not assume a starting bank or change it through software.
Consumer scaling, deadman policy and centered arming remain in Pipe.

## Development tests and delivery

In Debug builds only, `XTOUCH_HARDWARE_TEST_SCRIPT` selects a clearly labelled test-only local
file MIDI adapter instead of CoreMIDI (a release service refuses to start when it is set), and `XTOUCH_HARDWARE_TEST_REPORT` receives its output
capture. This is not a remote input feature and never qualifies physical hardware.
The JSON array is append-only by row count: `{"connected":true|false}`,
`{"bytes":[176,28,64]}`, and test failure injection `{"fail_send":true|false}`.
All such tests run isolated; production launches omit these variables. Ready metadata
sets test_only true. Scripts are never sent through HTTP.

`python3 configs/package_surface_hardware.py --output-root ../deliveries` packages
only the hardware service; it does not rebuild or replace old simulator deliveries.
The manifest records host/shared pins, Contract 1.4, SDK 1.4.0, profile/mapping and
file hashes. Runtime SDK includes runtime, checker and read-only diagnostics packages. The fake hardware double is confined to a separate `surface-control-test-support-1.4.0.zip`, explicitly test-only and hashed in the manifest; it never enters the runtime SDK ZIP.
Outside-source verification is limited to describe, descriptor/mapping/hash validation
and safe rejection/configuration checks without opening MIDI; it is not an HTTP or
hardware acceptance report. The attended checklist and its fake-only rehearsal are
prepared separately under the workspace `build/e/`.

The additional `surface-control-hardware-independent-v1.4.json` fixture selects
roles independently per scene. This host runs accepted button press/release and
recovery, position/touch separation, and successful/invalid/rejected value display
transactions. `button_ignored` is null because the normal observation pipeline
has no natural ignored-button route; that independent scene is explicitly skipped.
The original rich fixture retains its exact assertions and relative-role limitation.
The new transport rejection is injected in a test-only display adapter, with no
new public tool or production error code. Outside-source describe verification
uses the delivered checker to validate both hardware role-map entries.

## Device access disabled: offline diagnostics

`--device-access enabled|disabled` is a process-start choice; default `enabled`
retains the ordinary device service. Explicit `disabled` selects a permanent
no-device adapter. It creates no CoreMIDI client or ports, enumerates no sources
or destinations, connects no endpoint, and cannot send. It never loads a local
MIDI script: combining disabled access with either XTOUCH_HARDWARE_TEST_SCRIPT
or XTOUCH_HARDWARE_TEST_REPORT is refused before either transport factory runs.
There is no HTTP or runtime switch to enable access; use a fresh process with
explicit `--device-access enabled` when separately authorized to access devices.

RX channel and light protocol remain required even for offline profile inspection:

```sh
./XTouchSurfaceHardware --device-access disabled \
  --receive-channel 2 --light-protocol observed114 \
  --token-file /private/offline-token --port 0 --ready-file /private/offline.ready.json
```

Ready/describe identify `device_access: disabled`, `diagnostic_only: true`;
ready also has public `device_io` call counters. Link is permanently disconnected,
inputs/feedback remain unknown/empty and event sequences stay zero. The declared
source is still hardware Contract 1.4; it does not assert that a controller is
attached. SDK hardware opt-in does not override the disconnected gate. Even with
`--allow-surface-feedback`, valid displays fail `invalid_transition` on this link.
Input/renew/reset retain their fixed refusal codes and cannot create observations.

The disabled process emits JSONL audit records to stderr at startup, admitted RPC
completion and signal cleanup. Counts cover CoreMIDI/script factory calls, client
and port creation, endpoint enumeration/connection, MIDI sends and accepted
messages. Disabled mode keeps every count zero. Operation names are taken only
from a fixed known catalog; request strings or credentials are not reflected.
Signal cleanup uses pre-encoded immutable disabled-state evidence and async-safe
writes; owned-ready cleanup remains the same as the ordinary service.

`verify_hardware_http.py DELIVERY --evidence OUTSIDE_DIRECTORY` uses the delivered
binary and zipped SDK, with no fake MIDI environment, for real authenticated
127.0.0.1 HTTP. It labels read-only discovery/snapshot/events separately from
explicit refusal/admission probes. It checks zero access counters, unknown state,
SDK opt-in, fixed write denials, disconnected feedback denial, token/Origin,
new-process epochs and SIGTERM/SIGINT cleanup. It is diagnostic transport evidence,
not complete connected-device conformance or physical acceptance. The original
`verify_hardware_delivery.py` remains the static/describe-only check.

The SDK also carries independent `surface_control_diagnostics/` with its own
README, alongside the runtime, checker and test double. Its bounded capture calls
only discover/snapshot/events; offline verify reads the capture without HTTP.
Initial disconnected capture and verification both intentionally exit 1, with
`verified_recorded_invariants` and `incomplete_or_failed`. This is a well-formed
record of a disconnected service, not successful hardware diagnostics. The shared
capture schema is shipped separately and hashed. Source-independent verification
checks its read-only request allowlist and verifies that offline validation adds
no service request.
