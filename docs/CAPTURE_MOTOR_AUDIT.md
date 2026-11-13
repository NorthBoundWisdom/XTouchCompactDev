# Offline motor safety review

Run `python3 tools/audit_motor_safety.py CAPTURE.jsonl` on an app JSONL v1 capture.
This reads the original bytes only, emits JSON to stdout and never opens CoreMIDI.
It checks capture sequencing/completion, reports its SHA-256, and separates sent
hardware outputs from suppressed, failed, mock and unknown-delivery records.

The report lists event sequences for motor CC 1–9 while the same physical fader is
held, motor CC during known host/input-layer mismatch, and Program Change while
any fader is held. TX touch addresses on both layers refer to the same physical
fader. Actual Global RX is still unknown; sent motor addresses are counted even
when the configured RX might be wrong. A layer assertion invalidates old layer
evidence without establishing a physical acknowledgement. Disconnects never
fabricate a release.

Each release window lists same-fader motor outputs until its next touch-down,
connection, mode or configured TX change, or capture end. Repeated release messages do not create extra
windows. These counts include later explicit writes: timestamps and command
counts cannot establish that a command was caused by release reconciliation.
Unknown initial touch/layer state, missing delivery facts and incomplete prefixes
are explicit. `assessment` is `no-recorded-violations`, `violations`, or
`inconclusive`; `evidenceSufficient` only concerns the recorded checks. Exit 0
means no recorded violation with sufficient recorded state; 1 means recorded
violations; 2 means unreadable/malformed evidence; **3 means incomplete or
insufficient evidence**. None is hardware sign-off.
Unreported firmware travel from physical layer keys or Program Change cannot be
measured by this audit. 未在实机复核。

## Existing private evidence, reviewed read-only on 2026-11-13

| Capture suffix | Events | Sent motor CC | Known touch / mismatch violations | Release-window counts | Sent layer assertions |
| --- | ---: | ---: | --- | --- | ---: |
| `1794500725` | 63 | 5 | 0 / 0 | F1 sequence 2 → end: 5 | 1 |
| `1794501019` | 170 | 0 | 0 / 0 | No release observed | 3 |

Both captures are complete. With the stricter U11 audit, both return **exit 3 /
`inconclusive`**, with zero recorded violations. Neither capture has fresh touch
evidence for all nine faders before its layer assertions. In the first, motor sequences 59–63 have unknown
layer after a sent assertion; their touch state follows the recorded release.
The session record attributes these five commands to a subsequent slider drag,
not to release catch-up. The second contains no input messages, so it cannot
validate touch arbitration. See [the session record](HARDWARE_SESSION_2026-11-12.md).

SHA-256 respectively:

- `88bd603622d9754b8e8f49e6fd7d7f850f506e69fc640829714ea28ebd858219`
- `4b1817517330c69739ee3606bce9a5c4cd635b4b614d519a8f51b3ddd5696e3a`

The private files are neither modified nor committed. Tests use synthetic data
only and run with the existing BuildWorkflowTests suite on macOS and Linux.

Layer-switch output batches now record the newly committed software bank for every
event (U9; 未在实机复核). Older captures can tag that batch with the previous host
bank, so review the raw Program Change and session record together; do not rewrite
private originals or treat that tag as physical layer acknowledgement.

U11 also tracks physical safety touches received while the app uses Mock. A route,
mode or configured TX change closes release windows and invalidates layer/released
state; known held latches survive conservatively. Identical known connection
snapshots do not erase mismatch evidence. Missing or contradictory event metadata
is rejected instead of silently skipping potential hardware outputs. Null route
facts remain unknown and are reported for motor/layer outputs. All-nine touch
coverage is required to assess Program Change under touch; F1 alone is insufficient.
These stricter offline results remain **未在实机复核**.

## Native offline review (U16)

The app's **Offline capture** workspace imports a regular JSONL file read-only.
It shows its frozen-byte SHA-256, completion status, violations, unknown evidence
and release windows. Import is bounded to 16 MiB / 100000 events and runs off the
main actor; a stale or cancelled import cannot replace a newer review. Invalid
input leaves the original file and previous valid review intact. No user profile,
live session, CoreMIDI mode, current target or MIDI permission is changed.

The native `RecordedCapture` / `CaptureMotorAudit` core has no Python runtime or
CoreMIDI dependency and runs on Linux. Shared synthetic fixtures independently
compare its complete report with the existing Python CLI. The app computes the
SHA-256 from exactly the frozen bytes parsed. Imports never write those bytes.
The UI displays at most 200 matching sequence numbers and 100 release windows per
section; all totals use the complete imported prefix. No result is hardware sign-off.

Views consume `PanelSnapshot.offlineCapture` and emit only the two new import/clear
PanelIntents; `ConsoleModel+Panel.swift` remains the adapter. Visual desktop
acceptance and hardware remain **未在实机复核**.

## Isolated Mock replay (U17)

The same workspace offers Step, Run to end, Pause and Reset. Playback follows the
recorded sequence, not wall-clock timing. It uses its own neutral `CompactSession`
and `MockXTouchCompact`; the live panel/session, device profile, cache, permissions,
MCP/OSC and transport are not reachable from the replay engine. Background playback
yields in bounded batches and cancellation generations prevent stale work after a
reset, clear, replacement import or pause. No playback starts automatically.

Only active-source recorded IN is replayed. Inactive hardware safety-touch inputs
are retained separately; ignored/unsupported inputs are skipped. Every recorded
OUT is skipped, including motors, LEDs, rings and Program Change. A recorded
accepted layer assertion only invalidates older input-layer evidence in memory;
it does not execute Program Change or invent a firmware cycle or position report.
Route/mode/TX boundaries discard old motor intent while preserving touch latches.

**Test targets (Mock only)** permits explicit neutral-fader writes while paused,
so touch deferral/release can be examined without hardware. Simulated cap position,
recorded input position and target are separate values. Reset restores the initial
simulation and clears these test writes. Missing header TX/RX/LED settings are
kept nil as source facts; declared simulation defaults are used only inside the
Mock until recorded metadata is available. No actual Global RX is inferred.

The source does not contain the original parameter assignments or all software
write intent. Agent/business actions are counted but never invoked. Replay is not
a reconstruction of the full original app session or evidence of physical travel.
It cannot reproduce an unrecorded physical layer key. UI/physical review remains
**未在实机复核**. H1–H7, N5 and organization visual acceptance remain open.
