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
normalized only to the edited range/step, and preserve unbound fader/encoder bank
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

Configuration JSON carries version 1 and device `X-TOUCH COMPACT`. BCR2000 or
unknown-version configurations are rejected before mutating the current session.
Import/export is explicit. Neutral and audio presets are available from Load preset.

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

Eight deterministic slots support Start → Running → Waiting for approval;
Approve resumes Running and completes after two seconds. Interrupt stops a
running slot. Waiting never approves itself. Buttons assigned to Agent actions
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
when Agent writes are enabled. Approval remains a user-interface action.

To exercise an explicitly enabled normal app, put its token in the environment
and run `python3 tools/mcp_integration.py`. Tests use an ephemeral loopback port
and memory token, never the user's Keychain. This is a local integration endpoint,
not an Internet service or a full OAuth/SSE server.

## OSC

OSC starts disabled, and its destination is not restored automatically. Choose a
parameter and destination in Settings, Apply output destination, then explicitly
enable output. Packets use address `/xtouch/value` and type `,f`, normalized to
0…1, limited to 0.25 units/second. The model owns the 250 ms output scheduler, independent of window lifetime.
Each output tick first validates the elapsed interval against the previous
one-second scheduler heartbeat, then refreshes it only if still timely. Stationary
values are valid indefinitely; no new parameter writes or physical movement are
required. A stalled scheduler, invalid value, changed destination or transport
failure disables output and posts a visible notification;
re-enabling performs the explicit off/on arm sequence. The core gate rejects
arming without a preceding disable and requires rearming after a trip.

There is deliberately no incoming OSC-to-motor route: no physical feedback model
has been characterized. External equipment must implement its own deadman/limits;
stopping packets cannot stop equipment that ignores connection liveness.

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
