# Shared plugin tools

The local MCP server exposes the old `get_state`, `set_parameter`, `agent_primary`
tools plus shared `surface_` tools. Authentication, loopback binding, rate limits,
write permission and touch arbitration remain host responsibilities.

`surface_capabilities` with `{}` returns the installed `instance_id` values and
manifests. Discover instances through capabilities before issuing calls. The aligned
defaults are `agent.mock`, `robot.reference`, `chassis.reference` and
`output.parameters`; only Agent is installed by default. Optional schemas appear
when explicitly selected. The pre-publication short IDs have no compatibility aliases.
Each new tool advertises the shared `inputSchema` and `outputSchema` unchanged.

```json
{"method":"tools/call","params":{"name":"surface_agent_snapshot","arguments":{"instance_id":"agent.mock"}}}
```

Start/interrupt uses `surface_agent_primary` with `instance_id` and integer `slot`.
`surface_agent_interrupt` explicitly interrupts without approving. Remote primary
cannot approve a waiting slot. Extra fields such as `origin` are rejected, and
no request field can impersonate local interface or hardware input.

Robot and chassis tools expose snapshot/trace plus explicit initialize, acquire,
enable, renew, release, stop, advance and reset. Robot adds move, chassis adds
drive. Trace results are objects with a `samples` array. They manipulate simulations only. Ownership proofs include generation,
opaque host-issued control token and strictly increasing sequence; clients recover
from state after a lost mutation response rather than blindly retrying. A stopped
or stopping plugin cannot be revived by a remote write.

Output exposes snapshot/enable/disable. This host rejects remote output enable by
default. There is no tool that supplies trusted actual state or heartbeat, and
normal requests cannot make physical output ready. Existing OSC settings use the
same binding and gate when explicitly enabled with trusted telemetry.

`surface_events` takes `epoch`, decimal-string `after`, and integer `limit` (up to
this host's 1024-record journal capacity). A first request may use an old epoch:

```json
{"method":"tools/call","params":{"name":"surface_events","arguments":{"epoch":"new-client","after":"0","limit":128}}}
```

Retain the returned epoch. When events are present, the next `after` cursor is
the **last returned event.sequence**, converted to a decimal string.
`latestSequence` is only the current high-water mark: using it as the next cursor
when a page is partial would skip events that have not been returned. Keep the
current cursor when an ordinary read returns no events.

A changed epoch or evicted/future cursor reports `gap`. First refetch the current
snapshots, then re-anchor to the returned epoch/high-water mark and resume; do not
claim the missing events were consumed. Reading never advances clocks, repeats actions or adds events.
Successful mutations and actual simulation changes share one journal; failures
commit neither state nor events. Heartbeat and actual-value bookkeeping commits silently. Output evaluation logs
only changes to status, reason, affected parameter or limited; the latest state still commits every step.
Events never include control tokens or command proofs.

Success is the raw shared JSON in text content; object payloads also appear
unchanged in structuredContent. Every shared output schema has an object root,
including trace results wrapped in `samples`. New-tool
errors use `isError: true` and stable `{code, fields}` JSON, with the same object
in structuredContent. Old-tool return shapes and errors are unchanged.

The precise fields, strict schemas and error mappings live in the locked package's
`docs/remote-tools.md` and independent binding targets. The host does not duplicate
those parsers or select domains inside its runtime. All plugin values live in one
RemoteRegistry, shared by the GUI, host scheduler and both tool generations.


Shared mutations additionally pass this host's independent 60-write/second budget;
exhaustion returns permissionDenied with fields.reason=writeRate. The existing HTTP
request limit and all three legacy-tool policies are unchanged. Simulation reset
requires both Allow Agent writes and the separate Allow simulation administration
switch, which defaults off. Remote robot/chassis advance is always denied while
the host owns realtime progression, including when administration is enabled.

The default journal capacity is 1024. Idle simulation ticks produce no records;
continuous motion updates are coalesced to at most 4 Hz per instance, with critical
transitions and commands immediate. Telemetry bookkeeping and unchanged output
decisions do not evict meaningful history. Silent commits still validate the
independent host write clock; this does not turn a regressing write into a valid one.

The host and shared simulators use a 2-second maximum catch-up gap. A longer stall
faults and revokes control without replaying the missing motion or inventing new
actual positions. Small subsequent ticks do not clear the fault, restore ownership
or resume motion. Recovery requires explicit authorized reset/initialization/control.
