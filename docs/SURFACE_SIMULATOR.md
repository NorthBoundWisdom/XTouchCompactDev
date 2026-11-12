# XTouch software Surface Provider

`XTouchSurfaceSimulator` is an isolated, hardware-free executable. It imports the
same pinned shared control contract as BCR and uses the existing
`CompactSession` / `MockXTouchCompact` interaction engine. It never initializes
CoreMIDI, loads user profiles, accesses Keychain, opens OSC output, or starts the
GUI. No physical controller or actuator qualification is implied.

## Build and deliver

Acquire the committed dependency through the normal manager, then build:

```sh
python3 configs/surface_plugins_dependency.py ensure
swift build --jobs 2 --product XTouchSurfaceSimulator
```

Use `SURFACE_PLUGINS_SOURCE=/path/to/committed/SurfacePlugins` only to fetch a committed
revision that is not yet published (see `docs/SURFACE_PLUGINS.md`).

For a clean, independently consumable delivery:

```sh
python3 configs/package_surface_simulator.py
```

The default output is `build/deliveries/xtouch-surface-simulator-<short SHA>`, named
after this repository's HEAD only (no other host's commit appears in the name). Pass
`--output` to choose another new directory; an existing directory is never reused.

The output contains the binary, `manifest.json`, dependency lock, `LICENSE`,
`control-contract.json` (`--describe`: actual discovery plus the seven tool schemas),
this guide as `README.md`, `minimal_consumer.py`, and `examples/surface_roundtrip.py`.
The shared SurfacePlugins files come byte for byte from the locked managed dependency
`build/dependencies/SurfacePlugins` (their single source; this repository keeps no copy):

| Delivery file | Shared source |
| --- | --- |
| `surface-control-sdk-1.2.0.zip` (`surface_control/__init__.py`) | `clients/python/surface_control/__init__.py` |
| `control-tools.json` | `docs/surface-control-tools.json` |
| `surface-control-scenario.schema.json` | `docs/surface-control-scenario.schema.json` |
| `surface-control-software-v1.json`, `surface-control-software-v1.1.json`, `surface-control-software-v1.2.json` | `fixtures/` |
| `surface-control.md`, `surface-control-scenarios.md`, `surface-control-delivery.md` | `docs/` |

The shared SDK tests and the Pipe integration example (`integrations/pipe/`) are not part
of this generic delivery. The manifest's common fields have the same names and meanings as
the other host's (shared `docs/surface-control-delivery.md`): `schema_version`, `artifact`
(`surface-control-simulator`), `surface_control_contract` (`"1.2"`), `surface_control_sdk`
(`"1.2.0"`), `source`, `source_commit`, `source_dirty`, `profile_id`, `profile_version`,
`mapping_revision`, `surface_plugins_revision`, `files_sha256` (every delivered file), and
`surface_plugins_files_sha256` (each shared source file). Profile identity and
`mapping_revision` are taken from the delivered binary's own `--describe` output, so they
describe the default demonstration configuration; a running instance is still pinned through
`surface_control_discover`. Private fields (`product`, platform, architecture, build
configuration, start/stop notes) are not part of the convention. `examples/surface_roundtrip.py` imports the SDK only from the
delivery zip after checking the manifest pin and every file hash. It is a local software
delivery, without a release tag or notarization claim.

## Start, readiness, stop

Every process receives a fresh random instance ID by default. Use a separate process, credential, and ready path per simulator. `--surface-instance-id` is an explicit test override; consumers must still pin the fresh epoch and should not reuse a test instance identity for a restarted production-like session.
Like the BCR Provider, an explicit instance ID must be 1–128 bytes of visible ASCII
(33–126); anything else is refused at startup.
The process has no persistent state directory and does not access user stores.
Read-only is the default. Each mutation category has a separate explicit flag.
The token has the same shape as the BCR Provider's: exactly 64 lowercase hexadecimal
characters. Generate a private token and pass it through a dedicated pipe; like the
BCR Provider, `--token-stdin` refuses a stdin that is not a pipe (a redirected file or a
terminal), because a redirected file would bypass the private-file checks below:

```sh
umask 077
python3 -c 'import secrets; print(secrets.token_hex(32))' > build/simulator-token
cat build/simulator-token | .build/debug/XTouchSurfaceSimulator \
  --token-stdin --surface-instance-id car.a --port 0 \
  --ready-file build/simulator-a.ready.json \
  --allow-surface-input --allow-surface-feedback --allow-surface-reset
```

The executable binds only `127.0.0.1`. Port `0` chooses an available port; an
explicit UInt16 port is also supported. It prints one compact ready JSON line to
stdout after binding, including PID, URL, and the public identity pin; credentials
are omitted. `--ready-file` is optional, is created exclusively (an existing file or
symlink at the path is refused), and is removed when the process exits through a
startup failure, SIGTERM, or SIGINT. Only the exact file this process created is
removed: if the path was replaced by another file, it is left alone. A SIGKILL or crash
cannot clean up; remove a stale ready file explicitly before reusing its path.
`--token-file` is an alternative to `--token-stdin`; use only one. The file must be a
regular file (not a symlink) owned by the current user with no group/other permission
bits (`mode & 0o077 == 0`, e.g. `0600`). Stop by terminating this isolated process.
A restart receives a fresh random epoch and never replays input, restores control
authority, or touches another instance.

```sh
python3 minimal_consumer.py --ready-file build/simulator-a.ready.json \
  --token-file build/simulator-token
```

Add `--exercise` to send one explicit ordinary input and a separate link display
update. The example discovers mapping IDs and uses the documented tools; it does
not import host source. It never retries a mutation after an unknown response.

## Optional simulation configuration

`--simulation-configuration <file>` strictly loads a SurfaceConfiguration JSON for this
isolated process. It never reads or writes a saved user profile. Both v1 and v2 are supported;
v1 must omit `externallyProtected`, while v2 may explicitly set it to false. Unknown fields,
duplicate assignments, nonexistent controls, action bindings, read-only and protected
parameters are refused before readiness. The default profile and mapping revision
`2fc51394e3593d7c` stay unchanged when this option is omitted.

The delivery includes `examples/chassis.json` and `examples/CHASSIS.md`: seven neutral
parameters for enable, two axes, stop, and three displays, all mapped to public controls.
Inspect it without credentials or opening a listener:

```sh
./XTouchSurfaceSimulator --simulation-configuration examples/chassis.json --describe
```

A parameter-bound touch is momentary in this standalone simulator: press writes maximum,
release or lease expiry writes minimum. Expiry restores its original layer's parameter
binding even if the active layer changed. Mock/session touch safety still runs first.
Hardware parameter toggle semantics remain unchanged. Only accepted touches declare hold;
a blocked touch declares none. Display feedback remains independent intent.

## Optional control contract 1.2

`POST /mcp` accepts authenticated stateless JSON-RPC requests using MCP `2025-11-25` or `2026-07-28`. Initialization negotiates these versions; no session ID is required. Set
`Authorization: Bearer <token>` and `Content-Type: application/json`. Browser
Origin requests are rejected. Each complete HTTP request has one absolute three-second read budget, including partial headers and bodies. Discovery reports `contract_version: "1.2"`. The new executable exposes only these seven tools,
alongside `initialize`, `ping`, and `tools/list`:

| Tool | Operation |
| --- | --- |
| `surface_control_discover` | Profile, capabilities, identity, and latest sequence |
| `surface_control_snapshot` | Seeded/last accepted raw input, independent display feedback, and server time |
| `surface_control_input` | Explicit simulated gesture through the existing Mock/session |
| `surface_control_feedback` | Display intent only; never an input or parameter write |
| `surface_control_events` | Bounded input/feedback journal with server time |
| `surface_control_renew` | Silent lease renewal: no sequence, no event (contract 1.1) |
| `surface_control_reset` | Clear isolated state and rotate epoch |

The GUI's existing three tools and shared business tools retain their own
interfaces and permissions. This optional contract does not rename or replace
them. It is separately discoverable and requires explicit adoption by a consumer.

Every mutation supplies all five `expected` identity fields. Input and reset require a
canonical `expected_sequence` decimal string. Feedback may omit `expected_sequence`
(`feedback.unsequenced`): it validates the identity pin, skips only the sequence comparison,
and still records a feedback event that occupies a sequence. Supplying a feedback sequence
keeps the contract 1.1 comparison behavior. Renew remains sequence-free and silent. Accepted and ignored events advance that
sequence; a duplicate old request fails `stale_sequence`. An input rejected with `stale_sequence` was definitely not executed. The SDK's
`refresh_sequence()` reads one snapshot to update its local sequence; the caller can then
explicitly choose a new input. It never resends a write. Get a fresh snapshot
before choosing a *new* operation. Do not retry an uncertain operation by updating
its sequence. Failed validation leaves engine, Mock, and journal unchanged.
Failures use the shared stable code in `structuredContent`, with `isError: true`.
A transport failure means the operation's outcome is unknown. Malformed JSON-RPC uses
standard codes instead: `-32700` parse error (body is not JSON), `-32600` invalid
request (not a JSON-RPC 2.0 request object, invalid `id`, or non-structured `params`),
`-32601` unknown method, and `-32602` invalid params (`tools/call` without a tool name).
An unknown tool name remains a tool result with the stable code `unsupported_tool`.

A reset rotates epoch and sets the event cursor to zero. Input state is seeded
from the new Mock, without generating input events. Snapshot input values contain initial Mock state and last accepted raw input; they are not actual telemetry or operations that should be replayed. Consumers
react only to subsequent `accepted` input events. Remapping, restart, and the in-process
`selectLayer(_:epoch:)` invalidate old pins (layer keys do not); event gaps require snapshot/re-arm rather
than event replay. The journal retains at most 1024 events; queries report
`event_gap` for lost or future cursors. Successful mutations share a 60-per-second
budget. A mutation is charged only after it has been fully validated and processed on a
copy of the simulator, immediately before commit; permission, CAS, value, mapping,
and other failures never consume budget. A `rate_limited` mutation changes nothing.
`surface_control_renew` needs `--allow-surface-input` and is charged to the same budget.

The mapping revision is derived from the profile (FNV-1a of the canonical mapping
document, shared `ControlProfile.mappingRevision`). It is the same for every instance and
restart with the same configuration, changes only when the mapping content changes, and
is unchanged by reset, layer keys, and epoch rotation. A request whose mapping changed
returns `stale_mapping`; `stale_epoch` means same mapping, new epoch. Numbers are
normalized by the shared session (`80` and `80.0` are the same value), and
`ignored/no_change` uses the shared `isUnchanged`.

### Leases (`input.hold`)

The input-eligible fader touch controls `a.touch.1` … `a.touch.9` and `b.touch.1` … `b.touch.9` declare
`hold: {rest_value: false, max_hold_s: 10}`. A touch is the simulated hand on a motor
fader: while touched, fader feedback is withheld. A lease ensures that a lost client cannot
leave a fader touched indefinitely. Other controls declare no lease, and `hold_s` on them
fails `unsupported_hold`; in particular parameter buttons toggle on press, so a lease on
them would restore nothing.

`surface_control_input` with `value: true` and `hold_s` in (0, 10] touches the fader and
returns `hold_deadline = time + hold_s`. If the fader is already touched, the same input only
attaches or replaces the lease; the touch gesture is not repeated. Any other accepted input on
that control, including `false` or `true` without `hold_s`, clears the lease. `surface_control_renew({expected, control_id, hold_s})`
moves the deadline to `now + hold_s` for a held, unexpired lease and returns
`{control_id, hold_deadline, server_time}`; otherwise it returns `hold_expired`. Renewal never
consumes a sequence or writes an event. Snapshots and event pages list current active leases in `holds`, omitting it when empty.
An event page reports current deadlines, including silent renewals, independently of its event cursor.

Expiry runs on the process's monotonic clock. Every wait of the single serving thread
(for a connection, for more request bytes, and for a slow reader of a response) ends at the
earliest lease deadline, processes every due lease, and then continues the wait. Each request
also processes due leases at its own time before doing anything else. A due lease is released
through the same Mock touch-release gesture as an input, on whichever layer is active (touch
is per fader), so a withheld motor intent reconciles as on a real release. The shared session
then records `input / accepted / origin remote / reason hold_expired` with value `false`.
Reset clears every lease. Consumers renew well before the deadline and treat `hold_expired`
as "released, prepare a new input"; a lost renewal response is an unknown outcome.

**Expiry latency bound.** The `hold_expired` event time is never later than the lease
deadline plus 0.5 s. This is the guaranteed bound, asserted by a real process test; the
design target and expected value is well under 100 ms. It is independent of client behavior: a peer that connects and stalls, drips an
unauthenticated request for its whole three-second read budget, or does not read its
response cannot postpone expiry, and no client cooperation or further request is needed.
The lateness consists of the poll wake-up latency (timeouts are rounded up to 1 ms) plus at
most one request's in-memory processing, which is bounded by the 16 KiB body limit and
involves no I/O. Measured on the development Mac with a slow drip holding the reader
across the deadline: 0.8–2.0 ms (the integration test writes its measurements to
`build/surface-expiry-latency.json`). The bound does not hold while the process itself cannot run: it is suspended
(SIGSTOP, debugger, system sleep) or starved of CPU by the host. `systemUptime` does not
advance during system sleep, so a lease is then extended by the sleep rather than expired
during it. Expiry is still always processed before any later read or write, so
`hold_expiry_pending` is never observable through this executable; the code is passed
through unchanged if it ever occurs. Mutations stay strictly serial: lease processing and
request handling run on the same thread and never interleave within an operation.

Capabilities use the shared 1.2 vocabulary: `simulation`, `controls.stable_ids`,
`controls.layered`, `input.absolute`, `input.button`, `input.hold`, `feedback.value`,
`feedback.indicator`, `feedback.unsequenced`, `controls.input_declared`, plus the XTouch-private `x.xtouch.touch_protection` (motor commands
are withheld while a fader is touched).

## XTouch profile and semantics

`xtouch.compact.standard.simulation` version `1.2` declares 184 controls. Version 1.2 adds
`accepts_input` to every descriptor, which changes the derived mapping revision. Each layer
A/B has `a.fader.1` … `a.fader.9`, `a.touch.1` … `a.touch.9`,
`a.encoder.1` … `a.encoder.16`, `a.push.1` … `a.push.16`,
`a.button.1` … `a.button.39`, the optional pedals `a.expression.1` and
`a.footswitch.1`, and corresponding `b.*` IDs. Two layer-independent buttons,
`global.layer.a` and `global.layer.b`, are the physical A/B layer keys. Version `1.0`
had only the 178 layered controls; 1.1 is an additive change, with the same IDs and
semantics for those controls.

Faders, stock encoders, and the expression pedal accept integer absolute scalar values `0…127`.
An endless knob is not advertised as a relative MIDI encoder. Touch, push,
footswitch, button, and layer-key gestures accept booleans. Unsupported IDs, profiles,
relative encodings, fractional scalar values, and out-of-range values fail visibly.

The headless demonstration starts in layer A. Each descriptor's `accepts_input` describes
whether that control accepts input **when its own layer is active**, rather than the current
layer selection. Unassigned controls, global layer keys, and controls bound to writable,
unprotected parameters declare `true`; action bindings and non-writable or protected parameter
bindings declare `false`. The default demonstration declares `true` on all 184 controls.

Input permission is checked before layer state: `accepts_input: false` always fails
`permission_denied`, including on an inactive layer. This intentionally changes action-bound
input from the previous `unsupported_mapping` error, and inactive action/protected inputs from
`ignored/inactive_layer` to refusal. Eligible inactive-layer input, and all inactive-layer
feedback, remains `ignored` with `inactive_layer`. Switching layers changes this runtime
state, not the declarations, profile, mapping revision, or epoch. Pressing a layer key (`true`) is an ordinary accepted
input event (`mapped_value` is `"a"` or `"b"`) that selects that layer in the Mock and
the session together, exactly like the physical key. It does **not** change the epoch,
instance, or mapping revision: control IDs and their meaning are unchanged, and only
which layer's inputs are `ignored` changes. Pressing the already active layer's key
still records an accepted input but changes nothing; releasing a key (`false`) is
accepted and changes nothing; repeating the same raw key value is `ignored`
`no_change`, as for every button, so release a key (`false`) before pressing it again. Consumers that must know the active layer track their own accepted
layer-key events. The in-process Swift `selectLayer(_:epoch:)` remains a host lifecycle
operation that rotates the epoch. No layer operation recalls motors: on a layer key
press the session discards pending motor intents, fader display overlays are released
(below), and ring/indicator display overlays of the now active layer are redrawn.

Pedals use the Mock's expression and footswitch gestures and the session's existing
pedal decoding. They have no feedback address, so they declare no feedback kinds. A
pedal mapping is advertised only for a parameter assignment. Any other assignment
(for example a footswitch `set` action) is not advertised, and input on that pedal fails
`permission_denied` without changing the Mock, engine, or journal, the same as other
action bindings. An expression pedal has no initial reading, so it is omitted from the
seeded snapshot inputs until its first accepted input; the footswitch starts `false`.
Identical raw input is `ignored` with `no_change`, preventing repeated button-down from toggling twice.
Simulation writes preserve `agentWritable` and `externallyProtected`; action
assignments require a separate explicit composition and are not executed here.

**Controls without a mapping accept simulated input.** Most of the 184 controls have no
`mapping` in the demonstration configuration (for example `a.fader.1` … `a.fader.9`,
`a.encoder.6` … `a.encoder.16`, `a.button.3` … `a.button.39`, every touch and push, and all
of layer B). On the active layer they behave like any other control: input is `accepted`,
advances the sequence, appears in the journal and in snapshot `inputs`, and moves the Mock
and the session's layer bank (an encoder also redraws its ring). No parameter changes and the
event has no `mapped_value`. Identical raw input is `ignored/no_change` and inactive-layer
input is `ignored/inactive_layer`, as for mapped controls. Feedback on such a control is the
same display intent as on a mapped one. A consumer may therefore own the meaning of unmapped
controls entirely on its side; `mapping` only tells it which host parameter, if any, also
follows. The one exception is a control bound to an action rather than a parameter, which declares `accepts_input: false` and fails
`permission_denied`; the demonstration configuration has none.

Simulated gestures are ordinary input through `CompactSession.receive`, like a local
hand movement. The App's Agent motor permission (`setParameter(drivesMotors:)`) applies
only to Agent writes, so it does not affect simulated input: other faders bound to the same
parameter follow, unless they are touched.

Feedback supports scalar fader/encoder display values and button indicators
`off`, `on`, `blink`. Encoders render the existing 13-segment ring policy. Fader
feedback is explicit display intent and still cannot move a touched fader; release
can reconcile pending desire. Feedback never alters parameters, emits input,
updates the physical-observation cache, or treats last-sent as actual measurement.
Business display state is restored after local redraws without emitting events. A
fader display overlay is a one-shot motor intent, not a lock. When an accepted input
moves that fader, or a layer key is pressed, the overlay no longer drives the motor:
later redraws never pull a hand-placed fader back to an older display value. A new
`surface_control_feedback` request for that fader re-arms it. The snapshot keeps
reporting the last accepted display intent. Ring and indicator overlays, including on
the control being input, are always reasserted after an accepted input; they never move
a physical part.
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

`swift test --jobs 2` includes a runner for all three pinned shared versioned fixtures,
using real Mock/session values and an injected clock. It emits
`build/surface-scenario-report.json` (v1, 40 steps),
`build/surface-scenario-report-v1.1.json` (v1.1, 65 steps, including lease scenarios), and
`build/surface-scenario-report-v1.2.json` (v1.2, 83 steps, including unsequenced feedback,
explicit input sequence refresh, current event-page holds, and declared input refusal) with exact source/fixture hashes, mapping revision, role mapping
(`hold_input` is `a.touch.1`), and per-step results. The `advance` operation calls
the same `processHoldExpiries` the executable's scheduler uses. These deterministic
reports are separate from real HTTP/process evidence.
Run the latter with
`python3 -m unittest discover -s Tests/SimulatorIntegration -v` after building the
executable. The tests copy the binary to an isolated working directory, exercise
both public MCP versions, discard a write response, reject stale CAS, restart a
default instance at the same port, and isolate A/B processes. They also cover layer
keys and pedals, JSON-RPC error codes, write-budget ordering, instance-ID and token
rules, private token files, ready-file ownership and cleanup on SIGTERM/SIGINT,
`minimal_consumer.py --exercise`, the stdin-pipe requirement, the shared SDK 1.2 round trip
over both MCP versions, mapping-revision pinning, `surface_control_renew` (silent,
permissioned, budgeted), real-clock lease expiry with no request in flight, and the
500 ms expiry bound while a slow drip holds the reader for its whole read budget. They import
the SDK from `build/dependencies/SurfacePlugins/clients/python` without writing bytecode.
The 1.2 tests also run two real HTTP writers concurrently: all unsequenced feedback is
accepted, and a stale input is proven unexecuted before an explicit SDK refresh and new input.
No test here starts a production Pipe service or connects physical hardware.

## Chassis mapping example

The default demonstration configuration can supply the seven controls selected by Pipe's
`surface_sim_chassis_roles.example.json`. Start the isolated binary with
`--allow-surface-input --allow-surface-feedback` (and `--allow-surface-reset` when the
consumer owns reset), using the token and readiness procedure above. Layer A is active at
startup; select `global.layer.a` before using these layer-A roles after a layer switch.

| Pipe role | Control ID | accepts_input | Input kind / encoding | Feedback kinds | Hold |
| --- | --- | --- | --- | --- | --- |
| enable | `a.touch.1` | true | button / boolean | none | rest=false, max=10s |
| linear | `a.fader.1` | true | absolute / scalar 0…127 | value | none |
| steer | `a.encoder.9` | true | absolute / scalar 0…127 | value | none |
| stop | `a.button.3` | true | button / boolean | indicator | none |
| speed feedback | `a.encoder.10` | true | absolute / scalar 0…127 | value | none |
| steer feedback | `a.encoder.11` | true | absolute / scalar 0…127 | value | none |
| stopped feedback | `a.button.4` | true | button / boolean | indicator | none |

The default profile is `xtouch.compact.standard.simulation` version `1.2`, with
`mapping_revision: 2fc51394e3593d7c`. Discover the running instance and pin its actual identity;
copying a profile pin from documentation never authorizes an instance.

All seven are unassigned in the host demonstration configuration: the consumer owns their
business meaning. A feedback role's `accepts_input: true` also allows simulated hand input;
feedback remains display intent and does not create input. Pipe's example chooses a 1s enable
lease, within the descriptor's 10s maximum.

Run the read-only compatibility probe from this checkout:

```sh
python3 -B Tests/SimulatorIntegration/check_pipe_chassis_roles.py \
  --binary .build/debug/XTouchSurfaceSimulator \
  --report build/pipe-chassis-roles-proof.json
```

It passes the binary's actual `--describe` discovery to Pipe's unmodified
`resolve_chassis_roles`, importing Pipe with bytecode disabled, and updates only the example's
profile version and mapping pin in memory. A missing Pipe checkout is reported as skipped.
The existing contract-1.1 binary and example assemble successfully. The Pipe consumer checked
for this delivery accepts only contract 1.1 and its registered vocabulary lacks
`feedback.unsequenced` and `controls.input_declared`. Its original example therefore refuses
1.2 with `unsupported_contract`; explicitly adding 1.2 to the in-memory config is refused
by its version allowlist. Pipe needs its contract allowlist, capability vocabulary, and reviewed
example profile version/mapping pin updated before this 1.2 delivery can assemble there. The
probe reports that refusal separately from the supplier's descriptor checks; it does not patch
the consumer or claim an accepted 1.2 assembly.
