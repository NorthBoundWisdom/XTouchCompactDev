# Software-only workflows

The built-in neutral configuration provides independent A/B generic parameters
for 9 faders and 16 encoders per layer, plus Agent 1–8 on buttons 1–8. It never
learns or rewrites the hardware preset. The audio example is an explicit menu
choice, not an automatic hardware configuration.

## Parameters and assignments

Open the Parameters workspace. Edit configuration copies the current definitions
into a draft. Change names, groups, units, min/max/default/step, switch behavior
or Agent write permission; Apply configuration validates the complete draft.
The parameter list sliders write the active configuration, not unsaved drafts.
Apply configuration and bulk assignment preserve existing parameter IDs' values,
normalized only to the edited range/step (zero-anchored grid, endpoints included,
with lower values chosen on ties), and preserve unbound fader/encoder bank
targets on both layers. Presets and imported configurations instead use the new
configuration's declared defaults, even for matching IDs: there is no proportional
unit conversion. When the current workspace has non-default values, replacement
requests one confirmation using the reset dialog; cancellation leaves it unchanged.
Fresh startup also uses the saved configuration's defaults, since parameter values
are session state. Reset parameter values remains a separate confirmed action.
Loading refreshes only
non-motor feedback and cancels previous deferred motor intents. It does not recall
motors. Applying only a MIDI channel/LED profile preserves both banks' values.

Bulk assignment applies a range on the current layer. Faders and encoders bind
to continuous parameters; buttons and encoder pushes can trigger parameter toggle,
Agent primary operation, group reset, step, set or cycle. The editor's cycle
creates a two-value cycle (0 and the entered value); imported configurations can
specify longer cycles. Shared parameter bindings synchronize their feedback;
touched faders defer motor commands and reconcile after release.

Ordinary configuration JSON remains version 1 with device `X-TOUCH COMPACT`.
Version 2 is required when a definition carries the independent
`externallyProtected` flag. The new app reads both versions; a version-1 file
carrying that field is rejected, including an explicit false value. Earlier app
versions reject version 2 rather than silently dropping the protection. Neutral
and audio presets retain their version-1 shape. BCR2000 and unknown-version
configurations are rejected before changing session state. Import/export is explicit.

## Persistence and diagnostics

The normal app stores configuration and applied device profile together in
`~/Library/Application Support/XTouchCompactConsole/workspace.json`. It saves
only applied MIDI channels, LED protocol and explicit port selections; port
selection drafts do not silently change the saved profile. Missing manual
endpoints stay missing instead of selecting another controller. Parameter values,
Agent activity and external-output enable flags are intentionally session state.

Writes are atomic. Invalid files remain untouched and gain a deterministic
FNV-1a fingerprint backup (`*.invalid-<fingerprint>.backup`). This fingerprint
identifies content; it is not an integrity/security hash. Saving is blocked until
the user repairs or moves the original. A persistent notification offers Retry
save; failure never appears as success. Other runtime notices can be dismissed.

The bounded monitor retains the latest 120 events and supports Clear. Entries
contain an injected-clock timestamp, direction, source, MIDI message, optional
physical control and ignored status. Program Change has no fabricated physical
control. Incoming data on an inactive source or wrong channel is marked ignored.

## Mock Agents

Eight slots use the shared seven-state AgentPlugin: idle, queued, running,
waitingApproval, completed, interrupted and error. Start queues the task; running
begins after 0.45 seconds and approval is requested after 2.65 seconds. Approval
resumes running and completes after 2.25 seconds. Interrupt stops queued or running
work. The host injects time independently of the window. Waiting never approves itself. Buttons assigned to Agent actions
use the same operations. Running is LED on, waiting is LED blink, other phases
are off, with both manual and observed-firmware velocity encodings preserved.
These are Mock Agents, not real CLI sessions or external approvals.

## MCP

MCP starts disabled and binds only `127.0.0.1:8765/mcp` when explicitly enabled in
Settings. Copy access token reads/creates a 256-bit random bearer token in the
app's Keychain item. The separate Allow Agent writes switch defaults off;
parameter-level `agentWritable` is checked as well. HTTP requests containing
Origin are rejected. Authentication applies to all endpoints; there is no CORS
allow-list or unauthenticated discovery. Limits are 60 authenticated requests per
minute, 16 concurrent connections, 8 KiB headers, 16 KiB body and a five-second
connection deadline. Batches are bounded to 16 items and reserve the full per-item budget before execution. Invalid request envelopes
or insufficient budget reject the entire batch before any tool executes. Once
accepted, tool-level failures are per-item JSON-RPC errors alongside successful
results; batches are not transactions. Unknown RPC methods return -32601.

The stateless JSON Streamable HTTP endpoint supports `initialize`, `ping`,
`tools/list`, `tools/call` and notification acceptance. It pins protocol version
2025-03-26, returns JSON rather than SSE, and returns 405 to GET. Transport basis:
[official MCP specification](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports).
The tools are `get_state`, `set_parameter` and `agent_primary`. State exposes
layer, parameter permissions, touched and deferred faders. Writes use the same
parameter/session pipeline as UI writes; they do not bypass touch ownership.
Calls appear in the monitor without credentials or request arguments. Remote
`agent_primary` can start or interrupt but cannot approve a waiting slot, even
when Agent writes are enabled. Local interface and hardware actions can approve; remote actions cannot.

To exercise an explicitly enabled normal app, put its token in the environment
and run `python3 tools/mcp_integration.py`. Tests use an ephemeral loopback port
and memory token, never the user's Keychain. This is a local integration endpoint,
not an Internet service or a full OAuth/SSE server.

## OSC

OSC starts disabled. Its codec and motion safety decisions now come from the
same SurfacePlugins output module used by the other host. The destination and
one-parameter `/xtouch/value` float packet remain unchanged; normalization is
0…1 with a maximum velocity of 0.25 units/second and a 0.1 per-cycle cap.
Float32 rounding stays inside the permitted interval.

Enabling requires a fresh destination actual-state sample and an independent
heartbeat supplied by a trusted host adapter. Both expire after 0.3 seconds.
There is currently no production telemetry receiver in this app, so an ordinary
launch keeps output closed with a visible reason. Setting a parameter, sending a
packet or running the 250 ms scheduler cannot create measured actual state or
refresh the destination heartbeat. Tests supply explicit trusted telemetry fixtures.

Each emitted packet must be allowed by the shared gate. Missing/stale telemetry,
a scheduler pause, invalid target or transport failure closes output and posts a
notification. Re-enabling requires an explicit off/on sequence and fresh facts;
a late heartbeat cannot silently rearm output. The existing settings and stored
destination shape are retained, with this deliberate safety tightening.

No incoming data drives fader motors. Trusted external samples only inform the
OSC safety gate; last transmitted commands are never physical observations.

## Optional shared business modules

The default composition installs only Agent. Launch flags explicitly add modules:

```sh
swift run XTouchCompactApp --robot-plugin --chassis-plugin --output-plugin
```

Each module can be selected alone. Reference robot and Ackermann chassis are
simulations with independent lifetime IDs, initially uninitialized and disabled.
Their status appears in the Agents workspace. Installation does not add device
bindings or move faders. Parameter output starts disconnected and disabled.

`--reference-arm-example` explicitly loads a version-2 reference-arm parameter
set with no control assignments. The enable parameter retains both independent
protection flags; no simulator, output destination or physical actuator is
implicitly enabled by this data preset.

## Isolated native checks and screenshots

`--startup-smoke` opens a real native window, prints
`{"type":"xtouch.native_startup","hardwareAccessed":false}` and exits.
`--integration-test` keeps the isolated Mock app running. Both skip CoreMIDI,
user workspace loading and persistent credentials, using memory tokens instead.
`python3 tools/capture_readme_screenshots.py` renders app-owned offscreen SwiftUI
hosting views in English, Simplified and Traditional Chinese, plus settings and
parameter previews. It never captures the desktop or another application.

The package workflow builds native Release app/ZIP/DMG with icon, ad-hoc
signature and SHA-256 sidecars, then runs the isolated native smoke check.
Developer ID signing, notarization and all physical HW checklist items remain
out of scope. Generated packages and previews are under ignored `build/`.

## Review safety policies

Factory TX decoding identifies A/B from disjoint addresses, independently of the
host layer. Touch ownership is tracked across layers. Other-layer input is
physical evidence, not an edit to the active bank; a known layer mismatch blocks
all motor output until the mismatch is resolved. Hardware touch is tracked even
in Mock mode and remains a separate safety owner across transport switches and
reconnects. Switching transports cancels old queued motor intents.

Physical fader input may update a snapped/switch parameter and shared bindings,
but never drives that physical fader's own motor or queues a self-snap on release.
Untouched fader reports never drive any motor, since they could be motor-progress
reports. A known touched gesture may synchronize other bound faders; it still
cannot drive itself. This also prevents shared bindings from bouncing motor
reports back to the original fader. A received position is still an observation,
not acknowledgement of sent output.
Action buttons never implicitly latch LEDs. Agent LED semantics are cached in the
session and restored synchronously across layers, reconnects and configuration
changes; user approval does not emit an intermediate LED-off command.

Idle runtime ticks publish no changes. Agent/bank/output publication occurs only
when the corresponding observable value actually changes. OSC transport and time
are injected in App tests; tests cover expiration, missing parameters, failure,
repeated enable and model-owned scheduling without a window. Physical HW-6/HW-7
characterization is still pending; software tests establish policies, not measured
firmware behavior.

## Explicit layer realignment and disconnected touches

Use **Connection → Realign current layer**, or click the current A/B layer button,
to reassert Program Change even without changing banks. This discards old layer
mismatch evidence and cancels deferred motor intents, but does not claim a physical
acknowledgement, clear touch ownership or recall motors. New other-layer input
will report a mismatch again. Motor movement still needs a subsequent intentional
software write or motor recall, and remains blocked while touched.

If the controller is unplugged while a fader is touched, the host deliberately
keeps that safety latch: the release may have happened while disconnected. After
reconnecting, touch and release each affected physical fader once to obtain a fresh
release report. Reconnection cancels pending motor intents, so the release does not
automatically recall the old target. Realign is not a way to bypass this latch.

The UI/runtime error formatter marks operation and control names as localized
arguments. They are translated when rendered, so switching language also updates
existing errors; user names, MIDI data and file paths remain literal.

## Passive hardware capture

### Visual hardware observation

The pure-core `CompactInputObserver` owns accumulated input facts and bounded
history, with no transport or presentation dependency. `PanelPresentation.swift`
owns observation display types; the single adapter creates a consistent snapshot,
converts core channel numbers for display and selects the current input layer's
encoder readings. Views render those values and their coverage rows directly.

Choose **Hardware observation** in the console header. The dedicated workspace
switches to physical input with listening initially locked on; returning to the console
locks output again. The separate nonmotor permission flow below can allow one
explicit test command; ordinary observation never recalls motors or asserts a layer. Incoming
controls update the physical panel, a large last-input readout, touch/hold state,
the latest 12 input events and counts of observed physical controls. These counts
are input coverage, not hardware-test sign-off. Reset observations clears this
display only; safety touch ownership and the MIDI capture remain intact.

Unreported positions and touch states remain unknown. Fader caps stay hidden until
a position arrives, and follow reported positions after release. Host targets and
feedback commands never supply those positions. Input-layer evidence is displayed
separately from the host bank; a physical A/B press is not visible until subsequent
control input. Encoder values retain separate A/B observations. Highlights indicate
received operations, not measured LED/ring output. Wrong-channel or unsupported
messages remain visible as raw input without changing the device profile.

The observation path updates physical/layer safety without invoking parameter
assignments or Agent actions. Input connection status uses the input endpoint;
an output endpoint is unnecessary for observation. The dedicated page also offers
input-port selection and the existing JSONL capture controls.

For an on-device observation session without loading or saving the user's workspace:

```sh
open build/app/debug/XTouchCompactApp.app --args --hardware-observe
```

An explicitly supplied `--capture-path /absolute/path/new-session.jsonl` starts
the app's normal JSONL capture. Use a new evidence filename. Capture stops on the
page's Stop capture action or normal app termination. No MCP/OSC service is
enabled by this launch option. `--integration-test --hardware-observe` remains
hardware-isolated. App-owned snapshot scenes `observation-waiting`, `observation`
and `observation-release` use clearly labeled synthetic preview data and never
open hardware ports.

#### A/B input review and export

Use the **A/B input review** tab, or add `--input-review` to the observation
launch. Each layer has 89 separate physical input actions. Fader/encoder range
coverage requires received 0 and 127; touch, encoder push and button coverage
requires a real press/release pair. These are evidence counters, never automatic
hardware sign-off. The viewer's A/B choice sends no MIDI; it can follow input
addresses or remain on a manually selected review layer.

Cross-layer review retains the press layer, another layer observed while held,
and the release message's layer. The UI asks the operator to turn E1 after
pressing the physical other-layer selector while touching F1. That establishes
intervening input-layer evidence even if release uses the original address.
The release pairs with its original press, not a fabricated press in the other
layer. Repeated presses and unpaired releases remain visible. Counters/history
are independent; clearing observations preserves safety touch ownership and raw
capture. Changing input identity (including through a disconnect) or applying
a different TX channel starts new coverage rather than mixing interpretations.

**Export input review…** exclusively creates a JSON report and `.json.sha256`
checksum. When the current observation has an associated recording, it also
creates a `.capture.jsonl` byte-for-byte snapshot with its own SHA-256 in the
report. A valid recording without an end marker is explicitly incomplete;
sequence gaps, malformed/partial lines, duplicate endings or post-end events
are rejected. Reports without raw recording say so, including in the UI.
Observer counters cover the current reset scope, while a raw capture snapshot
can include earlier events or omit later unrecorded inputs. Both scopes are
recorded; they are not silently equated. Firmware, actual Global RX and hardware
acceptance remain unknown. No file is overwritten to recover an export failure.

Connection observations are additive JSONL v1 application events containing
connected endpoint IDs/names. They retain identity when the initial asynchronous
connection arrives after the capture start header, and preserve reconnect/source
changes without inventing a MIDI message or physical acknowledgement.

The app-owned `observation-review` preview uses labeled synthetic inputs. It
does not satisfy Stage 1; see the acceptance handoff in HARDWARE_BRINGUP.md.

#### Nonmotor test workbench (C3 software)

The **Nonmotor tests** tab starts locked. Previewing a command sends nothing and
requires an explicitly selected test RX. Enabling output requires operator-confirmed
factory Standard mode, reviewed complete Stage 1 evidence, firmware read from the
device/editor, independently checked Global RX and its source, both endpoints and
active capture. These are recorded operator attestations, not facts inferred by
the app; machine-observed firmware/actual RX fields remain unknown.

Only one typed factory RX command can be sent: a button off/on/blink using the
explicit manual or observed-1.14 encoding, a ring display, a ring style, or a
Program Change layer assertion. Preview must match the requested command. The
allowlist excludes motor CC 1–9, mode CC 127, Pitch Bend and unrelated messages.
Layer B TX fader CC 28 is independently RX ring-display feedback; it is not
classified using the input map. Test choices never rewrite the applied profile.

Permission is transient and bound to endpoint IDs and the transport's reconnect
generation. The serial CoreMIDI send queue checks both again, so a same-ID
reconnection before the UI callback cannot reuse old permission. Every connection
callback revokes permission. Profile/port/layer changes, observation reset, leaving
the test page, recording stop/failure and send failure also lock output. Locking
sends no cleanup MIDI and performs no retry. Ordinary parameter/Agent feedback
stays blocked in this workspace even while explicit nonmotor output is permitted.

Permission and each request are written and flushed before activation/transmission.
Delivery and explicit operator observations are separate audit events. A failed
post-send audit cannot retract a transport-accepted command; it stops recording
and locks permission, retains the pending/partial evidence and does not retry.
Only the latest accepted command on the unchanged route can receive an operator
observation, with active recording. A sent command never fills physical LED/ring
or layer readings. Incoming input is still observed without executing assignments.

JSONL `nonMotorTest` entries contain approval/attempt IDs, reviewed route generation,
operator evidence, test RX, command/encoding, transport delivery and nullable
operator-reported response. Input-review exports include the latest 32 attempt
summaries; the raw recording retains all events. Neither a successful send nor a
matching operator observation automatically signs off Stage 2 or enables motors.

Launch with `--hardware-observe --nonmotor-tests` for the locked workbench. The
`nonmotor-tests`, `nonmotor-armed` and `nonmotor-result` snapshot scenes use labeled
synthetic inputs and an in-memory writer. The result scene exercises a simulated
transport and operator report; none accesses a physical port or transmits real MIDI.

Hardware output is blocked by default on every launch. Connection's Listen only
switch gates the single MIDI send boundary, including connect/reconnect assertions,
LED sync, gestures, software/Agent writes and recall. Suppressed commands are marked
explicitly and never treated as accepted transport writes. Disabling listening sends
nothing and clears withheld motor writes without discarding touch/layer evidence;
realignment and a new explicit motor write remain separate actions.

MIDI monitor's Start capture…/Stop capture stream JSONL v1 to a user-selected file.
Evidence filenames are exclusively created: existing files and final-component
symbolic links are refused, including when another process wins creation. The
start marker includes session metadata, connected/selected endpoints, applied
channel settings and packaged build revision/dirty status. Unavailable build
identity, firmware and actual Global RX stay null; configured RX is not a hardware
observation. Write/flush failure closes capture with a visible error; incomplete
files are retained rather than replaced or labeled successful on a later stop.
The screen remains bounded at 120 events; capture has no event-count truncation and
survives Clear monitor. Rows include canonical MIDI 1 bytes, decoder fields, host
and device layer, independent channel settings and received/sent/suppressed/failed
status. Writes are synchronous and errors close capture with a visible notification.
Stop capture flushes and writes an end marker. This does not capture unsupported
SysEx/realtime/UMP packet types. See HARDWARE_BRINGUP.md for exact scope and record
forms. None of this constitutes physical verification or N5 mouse acceptance.
