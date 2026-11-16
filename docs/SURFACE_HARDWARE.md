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
and seven surface tools are available to the owner. With scoped credentials, `tools/list`
returns only the authenticated role's catalogue: operator gets discover, snapshot, input,
events and renew; display gets discover, snapshot, feedback and events. This does not
authorize any hardware input or lease operation: their existing execution refusals remain.
No remote method accepts device input.
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
a hardware root plus a separate complete `simulation/` artifact from the same clean host HEAD; it never replaces any previous delivery.
The manifest records host/shared pins, Contract 1.4, SDK 1.4.0, profile/mapping and
file hashes. Runtime SDK includes runtime, checker and read-only diagnostics packages. The fake hardware double is confined to a separate `surface-control-test-support-1.4.0.zip`, explicitly test-only and hashed in the manifest; it never enters the runtime SDK ZIP.
The static hardware verifier is limited to describe, descriptor/mapping/hash validation without opening MIDI. The separate HTTP verifier uses permanently disabled device access. Neither is connected hardware acceptance. The attended checklist and its fake-only rehearsal are
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

## Separate feedback credentials and attended checklist (F)

The explicit three-token pipe mode `--surface-client-tokens-stdin` is shared with the
simulator (see `simulation/README.md` in the combined delivery, section SC-R05).
It reads strict JSON `{owner, operator, display}` through EOF, <=512 bytes; values are
distinct 64-character lowercase hexadecimal tokens, never files or command arguments.
It conflicts with the legacy `--token-file` / `--token-stdin`; the legacy mode is unchanged.
Secondary writers are host-issued opaque IDs, distinct per client for this process,
rotating at restart; `--surface-principal-file` v1 still preserves only owner/interface/system.
Operator can read and invoke input/renew, which **remain refused** in hardware sessions.
Display can read and invoke feedback, still requiring `--allow-surface-feedback`, connected
endpoints and matching layer evidence. Secondary credentials never gain reset or other tools.
Scopes do not grant process permissions or extra write budgets. Use SDK 1.4.0's explicit
`accepted_sources=("hardware",)` for both hardware clients; input must come from the device.

The default checklist is this repository's `build/e/xtouch-attended.json` and its same-content
`xtouch-attended.md`; generator/operator entry is `configs/hardware_attended.py`.
To use a workspace-level `build/e/` location instead, explicitly pass `--workspace-root PATH`.
The prepared field runner records the repository and output paths in a local, credential-free
`field-context.json`, so copying the runner never guesses a sibling checkout name. Standalone
preparation and rehearsal do not write outside this repository unless that option is supplied.
It has nine stages: read-only startup; observe position/touch/encoder/button inputs on the
user-confirmed bank; save epoch; physically disconnect/reconnect and verify unknown/no replay;
restart with display permission; explicitly confirm one button light; explicitly confirm ring
value/style; reject fader feedback; stop and check no motor/Program Change output. Agent runs
software, user observes/acts; sending stages require fresh in-person confirmation. The fake-only
rehearsal exercises the software sequence and confers no physical qualification.

Prepare/rehearse without devices, after a Debug build (paths resolve from this checkout):

```sh
python3 configs/hardware_attended.py prepare
XTOUCH_HARDWARE_BINARY=build/swiftpm/debug/XTouchSurfaceHardware python3 configs/hardware_attended.py rehearse
```

For the historical workspace layout, run the same commands with `--workspace-root ..`.
The checklist JSON/Markdown contents and all nine step commands remain byte-identical;
run those relative commands from the selected repository or workspace root respectively.

The combined candidate root is hardware Contract 1.4; `simulation/` is a separate explicit
simulation Contract 1.3 executable, profile, schema, four fixtures and SDK/checker. The root
manifest hashes that entire subdirectory, including its own manifest. Neither profile nor
instance/mapping identity may be substituted for the other. Root offline `--device-access disabled`
remains permanent disconnected read-only diagnostics with zero MIDI access; it is not simulation
and is not connected hardware acceptance. Physical qualification awaits joint attended acceptance.

Source-independent checks (run from a directory outside this checkout and the delivery):

```sh
python3 "$DELIVERY/verify_simulation_delivery.py" "$DELIVERY" --evidence "$OUT/simulation"
python3 "$DELIVERY/verify_hardware_delivery.py" "$DELIVERY"
python3 "$DELIVERY/verify_hardware_http.py" "$DELIVERY" --evidence "$OUT/hardware"
```

The first command runs all four delivered simulation fixtures with the delivered checker,
then captures and verifies bounded read-only simulation diagnostics. The full-profile capture honestly reports incomplete/exit 1 for the two unknown optional expression-pedal controls; a separately pinned four-observed-control capture completes/exit 0. Both reports retain their scope and do not fill unknown values. The latter commands
cover hardware static/read-only diagnostics and explicitly labeled rejection probes, with
zero CoreMIDI access. Evidence stays outside the immutable delivery. The manifests record
`source_commit`, `source_dirty: false`, the distinct `source_origin_main` base and
`source_ahead`/`source_behind` counts, plus `delivery_status: local-unpushed-candidate` when ahead (otherwise `remote-head-unreleased-candidate`). They
do not claim a push or release. Fast-forwarding those exact SHAs preserves this artifact;
rebasing to different SHAs requires rebuilding and updating consumer pins.

## Display catalogue (H-1)

The delivery includes `display-targets.md`, generated from its default discovery profile.
It lists every non-fader display target, range, style knowledge and qualification boundary.
Check the table without any device access:

```sh
python3 check_display_targets.py --contract control-contract.json --table display-targets.md
```

The discover response already supplies stable IDs, feedback kinds and allowed ranges;
current ring style and physical qualification are not discoverable contract fields.
The table states those limits explicitly. No profile, simulation discovery bytes or
physical qualification changed. Hardware faders still declare no feedback kinds.

## Display budget (H-2)

See packaged `display-budget.md` for 12 sustained real-process/fake-MIDI conditions,
limits and the existing explicit feedback=300 recommendation. Defaults remain unchanged.
Input event reading had no loss/gap but its worst measured p99 increased by 29.315ms.
The reliable physical USB MIDI ceiling is unknown until attended measurement.
The source checkout’s `configs/hardware_attended.py prepare` indexes the prepared-only
`build/e/xtouch-panel-attended.{json,md}` supplement alongside the original nine steps.

## Multiple display writers (H-4)

The optional dedicated-pipe startup record may add `displays`, an array of 1..7 extra
64-lowercase-hex display tokens, alongside required owner/operator/display tokens. The
extended JSON limit is 2048 bytes; all tokens are distinct and duplicate/unknown keys or
malformed arrays fail startup. Original three-role records keep their 512-byte bound and
shared quota behavior. Never put a credential in argv, configuration, logs or reports.

In extended mode each display credential has a host-issued distinct opaque writer and an
independent feedback bucket (default60/s, existing --write-limits.feedback overrides it,
range1..10000). It does not consume owner/operator aggregate/category quotas. No extra
principal is persisted. The role catalogue remains four display tools; remote hardware
input/renew/reset refusals, matching-layer gate and lifecycle zero sends remain unchanged.

Same-target writes are last-accepted-writer-wins, without platform arbitration; every
accepted event identifies its writer. The consumer must reject intersecting mappings before
starting a panel beside an operation bridge, and fail on an unexpected writer. Sharing one
display token gives one indistinguishable writer/shared quota, so use distinct display
credentials to detect conflicts between processes. Real hardware has not been exercised.
