# Capture JSONL v1 interchange

XTouch's existing field names and meanings are the baseline. This document does
not rename fields, change the writer, normalize addresses, or make recordings
executable commands. Captures are UTF-8 JSON objects, one per LF-terminated line,
with no array wrapper. Object key order is irrelevant; the XTouch writer emits
sorted keys. A partial final line is invalid. A valid prefix without capture-end
is explicitly incomplete, never evidence of a successful stop/flush.

## Common records

| kind | Fields and meaning |
| --- | --- |
| capture-start | First and unique. `schemaVersion` is integer 1; `session` is an object. `timestamp` is wall-clock audit time. `byteFormat` describes captured byte coverage. |
| event | `sequence` is an integer starting at 1, contiguous across **all** stored events, including metadata-only events. `timestamp`, `source`, optional `direction`, `delivery`, `rawMIDI1Bytes` describe the observation or attempted delivery. |
| capture-end | Terminal and unique; no records may follow it. `eventCount` exactly matches the number of event records. Its `timestamp` is stop time. The writer flushes earlier events before the completion marker and flushes/closes afterward; a write/flush failure must not become a completed recording. |

`session.sessionID` identifies this recording (the writer normally uses a UUID).
`session.applicationVersion`, `sourceRevision`, `sourceTreeDirty` describe software
provenance; unavailable facts are JSON null. `session.deviceModel` declares the
recording's device family: XTouch writes `X-TOUCH COMPACT`; BCR writes `BCR2000`.
A model name is declared provenance, not physical-device qualification. Missing
legacy metadata stays unavailable; do not infer a model from MIDI bytes.

Common event fields:

| Field | XTouch meaning |
| --- | --- |
| source | `hardware`, `mock`, `agent`, or `application`. Origin/provenance, independent of direction and selected device mode. Mock is synthetic; Agent does not mean physical input. |
| direction | `IN` = device/Mock to host; `OUT` = host feedback/attempted output. Absent on metadata-only events. |
| delivery | `received`, `sent`, `suppressed`, or `failed` when known. `sent` means transport/Mock acceptance, **not** a physical-position/LED acknowledgement. Missing is unknown. |
| rawMIDI1Bytes | Canonical MIDI 1 bytes, **not** UMP words, status-stripped bytes, parameter values or a control identity. XTouch writes one channel voice message: status 0x80–0xEF, two bytes for Program Change/channel pressure, otherwise three, with seven-bit data bytes. Unsupported UMP, SysEx and realtime payloads are not captured by this writer. Metadata-only events omit the field. |
| timestamp | UTC ISO-8601 text with fractional seconds from the host's injected audit Date. XTouch's writer emits it on start/events/end. Legacy import permits it to be absent. It is wall time and can move backward; it is **not** monotonic execution time or physical arrival acknowledgement. |
| ignored | Whether the host ignored the event; XTouch writes a Boolean on every event. Ignored evidence remains part of sequence/counts. It is not permission to discard the record. |
| message / control | Optional human-readable diagnostics. Do not use display text as a portable MIDI mapping, execution instruction or stable machine control ID. |

The sequence is the authoritative order. XTouch replay follows sequence order,
not recorded wall-time intervals. The original file has no transferable live
clock origin. Another host may add `monotonicTimestamp` and a clock-domain
explanation, but those are additive host fields; do not compare their monotonic
values with another process or derive them from XTouch timestamps.

Common readers may inspect additional fields opaquely and preserve raw bytes.
Such inspection is not a claim that another device's extended payloads satisfy
XTouch's Standard MIDI decoder or safety evidence rules. Complete envelope/count
validation does not authorize replay. The XTouch importer is bounded to 16 MiB
and 100000 events; the streaming writer's format is not a promise that every
arbitrarily large file can be imported.

## XTouch extensions

| Location | Fields |
| --- | --- |
| session | `firmwareVersion`, `actualGlobalReceiveChannel` (unknown = null), `configuredTransmitChannel`, `configuredGlobalReceiveChannel`, `ledProtocol`, `hardwareMode`, `listenOnly`, `selectedInputID`, `selectedOutputID`, `connectedInput`, `connectedOutput`, `connectionGeneration`, `route`, `remoteBridgeHost`. |
| event | `hostLayer`, optional `deviceLayer`, `hardwareMode`, `listenOnly`, `transmitChannel`, `globalReceiveChannel`, `ledProtocol`, optional `decoded`, `connection`, `nonMotorTest`. |

Configured channels use 1–16. Raw status bytes use MIDI's zero-based channel nibble.
TX and Global RX are independent configurations; no reader may infer RX from TX.
LED protocol is `manual` or `observed114`, retaining their different velocity
encodings. These are recorded settings, not measured firmware facts.

`hostLayer` is software bank `a`/`b`; `deviceLayer` is independently reported input
layer evidence when available. A transmitted Program Change is not a physical
layer/position observation. The optional `decoded` object contains the factory
input control description, layer, value and isPressed when meaningful; physical
identity, MIDI address and layer remain separate concepts. Fader-touch CCs and
motor feedback addresses must never be interpreted using another device's map.

Session endpoints are objects `{id,name}` or null. A connection event records
`generation`, `connectedInput`, `connectedOutput`; reconnect/profile/layer evidence
boundaries matter to XTouch motor review. Unknown route/touch/layer facts stay
unknown. `nonMotorTest` is diagnostic audit metadata, not a command to execute.
Remote bridge metadata distinguishes development forwarding from local ports and
never qualifies USB hardware or undocumented firmware motion.

## Other-device import and audit

The offline importer reads another device's common fields and integrity counts
without constructing a Compact session/profile. It shows declared device,
sequence/source/direction/bytes/audit timestamps and an explicit replay refusal.
No foreign bytes reach FactoryStandardMap or either live/isolated Compact replay.
Compact's strict native decoder still rejects foreign device declarations.

Motor safety review returns `not-applicable` / insufficient evidence for another
device, never `no-recorded-violations` or hardware pass. The CLI's generic review
uses exit 4 for not-applicable; its strict Compact-only `audit()` API continues to
reject other devices. Native capture audits keep their existing evidence rules.

## Frozen examples

`Tests/Fixtures/Capture/xtouch-sample.jsonl` is a deterministic Mock recording with
14 events (faders, touches, encoder/push, buttons and synthetic feedback). The
macOS recorder test compares its current output byte-for-byte with this sample;
Core tests on all platforms verify common/native parsing, counts and replay gates.
BCR's sample is copied into the same fixture directory only as frozen test data;
`provenance.json` records its source commit/hash or explicitly identifies a
handwritten placeholder awaiting the other window. There is no cross-host source
or runtime dependency. Fixture timestamps and sessions are synthetic.
