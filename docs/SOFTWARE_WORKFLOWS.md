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
Loading a configuration resets values to its declared defaults, refreshes only
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
connection deadline. Batches are bounded to 16 items and consume per-item budget.

The stateless JSON Streamable HTTP endpoint supports `initialize`, `ping`,
`tools/list`, `tools/call` and notification acceptance. It pins protocol version
2025-03-26, returns JSON rather than SSE, and returns 405 to GET. Transport basis:
[official MCP specification](https://modelcontextprotocol.io/specification/2025-03-26/basic/transports).
The tools are `get_state`, `set_parameter` and `agent_primary`. State exposes
layer, parameter permissions, touched and deferred faders. Writes use the same
parameter/session pipeline as UI writes; they do not bypass touch ownership.
Calls appear in the monitor without credentials or request arguments.

To exercise an explicitly enabled normal app, put its token in the environment
and run `python3 tools/mcp_integration.py`. Tests use an ephemeral loopback port
and memory token, never the user's Keychain. This is a local integration endpoint,
not an Internet service or a full OAuth/SSE server.

## OSC

OSC starts disabled, and its destination is not restored automatically. Choose a
parameter and destination in Settings, Apply output destination, then explicitly
enable output. Packets use address `/xtouch/value` and type `,f`, normalized to
0…1, limited to 0.25 units/second. The app's 250 ms liveness tick refreshes a
one-second heartbeat only after validating the previous heartbeat. A stalled
UI, invalid value, changed destination or transport failure disables output;
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
