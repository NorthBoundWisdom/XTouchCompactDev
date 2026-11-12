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
