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
Startup restores saved parameter values (see Persistence) as host intent only:
banks, rings and LEDs follow; restoring values sends no motor CC. Firmware travel
from layer assertions is separate (see safety policies below). Reset parameter values remains a
separate confirmed action.
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

## Naming, groups, links, scenes and undo

These are configuration and host-intent features. None sends a motor command on its own.

- **Name, color, group.** Select a fader or encoder. The inspector's *Name and organize*
  card renames the bound parameter, sets one of eight color tags, and sets or picks a group.
  Renaming an unbound fader or encoder creates a continuous parameter on the current
  layer, initialized from that control's bank value, so nothing jumps. Buttons and pushes
  carry actions and are not renamed here. The panel shows a color strip under each fader
  cap and a dot on each encoder.
- **Group highlight.** The *Organize* tab lists groups. The eye button dims every control
  outside that group. This is session-only display state.
- **Fader links.** A link has one leader and one or more members. When the leader moves by Δ
  (as a fraction of its range), each member moves by the same Δ of its own range, clamped.
  Members never move the leader or each other. A follower belongs to at most one link, and a
  follower cannot lead, so links never chain or loop. Member motors use the normal path:
  a touched member defers until release; without Agent motor permission an Agent write
  neither commands nor queues any linked motor; an Agent write skips members that refuse
  Agent writes. A physical leader leads only while touched, because an untouched position
  report may be motor progress.
- **Scenes.** *Save current values* stores every parameter value under a name (an
  existing name is updated). *Recall* is one undoable step that updates targets, banks,
  rings and LEDs; faders move only through the explicit motor recall.
- **Undo / redo.** Covers value changes from the panel, inspector, Agent, scenes and links.
  A drag, or consecutive edits of one control, is one step. History holds 50 steps and
  clears on reset or preset replacement. Undo is a software write, so touched faders defer
  as usual. Menu: Edit › Undo value change (⌥⌘Z) / Redo value change (⇧⌥⌘Z); text fields
  keep ⌘Z.

Configurations gain optional `color` on parameters and `links` / `scenes` arrays. Files
without them still load; import accepts version 1 and 2.

## Persistence and diagnostics

The normal app stores configuration and applied device profile together in
`~/Library/Application Support/XTouchCompactConsole/workspace.json`. It saves
only applied MIDI channels, LED protocol and explicit port selections; port
selection drafts do not silently change the saved profile. Missing manual
endpoints stay missing instead of selecting another controller. Parameter values
are saved as optional `parameterValues` (validated against the saved configuration's
IDs; older files without it load defaults). They are flushed at most once per second
by the runtime tick and on normal termination; a file is not created for untouched
defaults. Restored values are software intent: they never produce a motor command on
launch, reconnect or hardware mode entry. Physical recall stays explicit. Agent
activity, MCP permissions and external-output enable flags remain session state.

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
The legacy tools remain `get_state`, `set_parameter` and `agent_primary`. State exposes
layer, parameter permissions, touched and deferred faders. Writes use the same
parameter/session pipeline as UI writes; they do not bypass touch ownership.
Allow Agent motor moves is a separate, session-only switch, off by default, that
requires Allow Agent writes. Without it, `set_parameter` still updates the value,
banks, rings and LEDs, but no motor command is sent or queued for faders bound to
that parameter, and any older withheld target for those faders is discarded so a touch
release cannot replay it. The result lists those faders in `motorsWithheld`;
`get_state.permissions` reports `writes`, `motors` and `simulationAdministration`.
Local interface and hardware writes are not affected.
Calls appear in the monitor without credentials or request arguments. Remote
`agent_primary` can start or interrupt but cannot approve a waiting slot, even
when Agent writes are enabled. Local interface and hardware actions can approve; remote actions cannot.

Shared business tools use the `surface_` prefix and the exact shared input/output
schemas. `surface_capabilities` lists installed instances; `surface_events` reads
the bounded 1024-record journal using epoch, decimal cursor and limit. Old epochs,
future cursors or evicted history report `gap`; refetch snapshots after a gap.
Snapshots and event reads never advance plugins or replay actions, and failed
mutations append no event. Agent tools are `surface_agent_snapshot`,
`surface_agent_primary` and `surface_agent_interrupt`. Optional robot/chassis/output
tools appear only when that module is explicitly installed.

Every new mutation checks Allow Agent writes and an independent 60-write/second
host budget. Reset additionally requires the separate simulation-administration
permission, off by default. Remote advance is denied because the host owns the
realtime clock; the administration switch does not permit manual fast-forward. The authenticated
host supplies monotonic time and fresh opaque control grants; request data cannot
claim a local origin, provide grant entropy or create actual/heartbeat samples.
Output enabling is denied by default even when Agent writes are allowed. GUI,
clock, legacy operations and new tools use one canonical plugin instance.

New-tool success returns the raw shared JSON as text and, for object results,
matching `structuredContent`. A new-tool failure has `isError: true` and the stable
`{code, fields}` object in both forms. Legacy tool envelopes/error behavior remain
unchanged. See [shared-tool reference](SHARED_REMOTE.md) for discovery and examples.

To exercise an explicitly enabled normal app, put its token in the environment
and run `python3 tools/mcp_integration.py`. Tests use an ephemeral loopback port
and memory token, never the user's Keychain. This is a local integration endpoint,
not an Internet service or a full OAuth/SSE server.

## OSC

OSC starts disabled. Its codec and motion safety decisions now come from the
same SurfacePlugins output module used by the other host. The destination and
one-parameter `/xtouch/value` float packet remain unchanged; normalization is
0…1 with a maximum velocity of 0.25 units/second and a 0.1 per-cycle cap.
Float32 rounding stays inside the permitted interval. On first enable or rearm,
the measured baseline must itself be exactly representable by the OSC Float wire
format; an unsafe arbitrary Double sample keeps output closed with an explicit
precision message. The host delegates this check to the shared gate and does not
round measurements to manufacture an acceptable observation.

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
session and restored synchronously across explicit layer and configuration
changes; user approval does not emit an intermediate LED-off command.

Idle runtime ticks publish no changes. Agent/bank/output publication occurs only
when the corresponding observable value actually changes. OSC transport and time
are injected in App tests; tests cover expiration, missing parameters, failure,
repeated enable and model-owned scheduling without a window. HW-6 has a limited operator sign-off on F1 plus the recorded F2–F9/A and F1/B
motor samples; HW-7 and the remaining H-group cases are open. The
[2026-11-12/13 session](HARDWARE_SESSION_2026-11-12.md) measured no motor-position
TX, held-F1 command drop without catch-up, and silent all-nine motor travel on
layer changes. These observations do not establish every control or firmware
behavior; software tests do not extend the physical sign-off.

## Explicit layer realignment and disconnected touches

Use **Connection → Realign current layer**, or click the current A/B layer button,
to reassert Program Change even without changing banks. In hardware listening,
this only selects the host bank and retains actual input-layer evidence. A first
transport failure also retains known mismatch and keeps motors blocked. Only an
accepted Program Change invalidates that evidence (U8; 未在实机复核). This discards old layer
mismatch evidence and cancels deferred motor intents, but does not claim a physical
acknowledgement, clear touch ownership or recall motors. New other-layer input
will report a mismatch again. **Program Change itself cycles all nine motors on
this unit**, to the bottom and back, even though no motor CC or bank-target recall
is sent. Physical A/B keys do the same. In hardware-send mode any input or safety
touch blocks layer selection, realignment and light sync as a whole: a visible
refusal leaves the operation unqueued; release all faders and retry explicitly.
Mock layer selection is unchanged. U2 is software-tested only, **未在实机复核**.

U3: hardware attachment, disconnect/reconnect, endpoint replacement and transport
generation changes send no MIDI. Old layer and position observations are
invalidated, touch latches retained, and pending motor intents discarded. The
header marks lights unsynchronized; **Sync lights to device** explicitly asserts
the selected layer and sends its rings/LEDs. A successful sync marks transport
delivery only, never physical acknowledgement; a failure keeps sync pending.
Changing to hardware-send also replays nothing. Later fresh writes retain their
usual touch/mismatch rules. Startup power-up versus assertion travel remains H5;
U2/U3 behavior requires H6 and is **未在实机复核**.

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

The **Nonmotor tests** tab starts locked. Its historical name describes the MIDI
address allowlist, not physical motor neutrality: its Program Change layer test
cycles all nine motors on the measured unit and is refused under touch.
 Previewing a command sends nothing and
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
switch gates the single MIDI send boundary, including explicit layer assertions,
LED sync, gestures, software/Agent writes and recall. Suppressed commands are marked
explicitly and never treated as accepted transport writes. Disabling listening sends
nothing and clears withheld motor writes without discarding touch/layer evidence;
realignment and a new explicit motor write remain separate actions.

The observation page's **Enable writeback** action returns to the console and
disables listening without sending MIDI or replaying old targets. Touch ownership
and layer mismatch evidence remain intact. The same action is available in the
console header while listening. An explicit `--hardware-control` launch selects
physical hardware with writeback enabled; attachment/reconnect is silent and
leaves layer/light synchronization pending until an explicit user action. `--hardware-observe` takes precedence, and isolated test launches
ignore `--hardware-control`. The observation panel no longer shows the recent-input
debug card; raw input capture and touch safety remain available.

Four device status groups above the master fader represent USB, MIDI IN/OUT,
FOOT SW/EXP and MC MODE. Mock USB is on and MC is off. Simulated
device-side MIDI receipt/transmission pulses the matching indicator for 200 ms.
In Mock mode the panel header shows FOOT controls: hold **SW** to press the
footswitch (lit while held), drag **EXP** to move the expression pedal (pulses
200 ms). They transmit on the physical layer's address (A: CC 26 / 27, B:
CC 63 / 64) through the normal input path; hardware mode shows no pedal control.
Pulse timing and pedal/MIDI colors are UI approximations, not hardware measurements.
Physical status remains unreported (nil, shown as unknown), independently of host
port connections, USB MIDI activity and sent feedback.

Operator-reported encoder rotation patterns are represented separately as
`EncoderPresentation.localRingAppearance`: top E1–E8 alternate single/adjacent-pair
LEDs, while side E9–E16 shrink the left half to the center LED before growing the right half.
The software matches the operator samples in [the calibration record](RING_CALIBRATION_2026-11-12.md),
using interpolation between sampled states. Complete transition thresholds,
MIDI style IDs and behavior across layers have not been measured. This appearance
is a panel simulation of software values, not LED readback. Explicit host styles
and off/all/blink commands retain precedence. Input observation views keep rings
unlit, and MIDI commands, profile data and motor behavior are unchanged.

## Startup hardware readings

The normal physical panel displays actual last-received continuous values separately
from software targets. A Layer B input can update the physical display while the
software bank stays A and the layer-mismatch motor gate remains engaged. The header
identifies both layers; it never treats received input as permission to realign.

`workspace.json` optionally stores `hardwareValues`: the input endpoint UID, applied
TX channel, timestamped fader readings and per-layer encoder readings. Existing
version-1 workspaces without this optional field remain valid. Only decoded device
inputs populate it. Writes are coalesced to once a second and flushed at normal app
termination; storage protection and visible errors use the existing workspace store.
Isolated observation launches without a storage root do not save history.

On a matching route/channel, prior readings appear dimmed with `≈` and timestamps
in the inspector. Never-reported controls show `—`, with no invented fader cap or
encoder pointer. Reconnect clears live freshness; changing the input endpoint or TX
channel prevents incompatible history from appearing. Touches and held buttons are
never restored. Physical observations remain nil after a restart even if display
history exists. Sending a motor command makes a prior fader input stale; the sent
target does not enter reading history. Inspector/workspace software targets remain
explicit independent values.

During the 2026-11-12 session, touch-only inputs used CC101…109 (A) and CC111…119
(B) with 127/0. A subsequent F1 movement produced CC28 values 1 through 8: actual
Layer B position input while the software bank was A. The former panel continued
drawing A's software default after release; the new mirror renders the independent
physical input. This confirms movement readout for this example, not startup full
state retrieval. Full startup-state reading is **unverified, not ruled out**;
absence of a full-position query in the RX table is not proof of lack of support.
The history described here is a fallback, not a substitute for investigating
startup/USB/client state bursts or documented read-only requests. See the
[corrected investigation record](STARTUP_READBACK_INVESTIGATION.md). No undocumented
SysEx probing, preset change or motor movement is used here.
Hardware changes while the app is closed cannot be confirmed by cached readings.
The `startup-readings`, `startup-readings-live` and `startup-readings-empty` preview
scenes use isolated, labeled endpoints and temporary storage, never physical MIDI.

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


### Shared event traffic and simulation clocks

Idle robot/chassis ticks are silent. Continuous motion produces at most four
periodic events per second per instance; phase, control, fault and completion
changes remain immediate. Heartbeat/actual bookkeeping is silent, and unchanged
output status/reason/parameterID/limited does not add events. Every latest value and UI update
still commits. The 1024-record journal therefore retains meaningful Agent,
command and fault history during steady traffic; clients still handle gap.

A host clock gap over two seconds faults/revokes simulations and freezes positions
without main-thread catch-up. Restoring small ticks does not resume motion or
restore ownership. The default remote instance IDs match the other host, but
clients should always discover them through surface_capabilities.

## Unattended software work, 2026-11-13

This round used Mock, deterministic tests and existing captures only; **未在实机复核**.
The mock counts silent firmware cycles without simulating timing or intermediate
travel. Existing evidence can be checked with the
[read-only motor safety audit](CAPTURE_MOTOR_AUDIT.md); absence of motor CC cannot
prove absence of firmware travel. H1–H7, full HW-1…HW-5/HW-7 and N5 are not signed
off by this work. Begin the next attended review with H1 and H6.
