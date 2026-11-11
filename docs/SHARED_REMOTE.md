# Shared plugin tools

The local MCP server exposes the old `get_state`, `set_parameter`, `agent_primary`
tools plus shared `surface_` tools. Authentication, loopback binding, rate limits,
write permission and touch arbitration remain host responsibilities.

`surface_capabilities` with `{}` returns the installed `instance_id` values and
manifests. Default composition has only `agent`. The explicitly selected optional
instances are `robot`, `chassis`, `output`; their schemas appear in `tools/list`.
Each new tool advertises the shared `inputSchema` and `outputSchema` unchanged.

```json
{"method":"tools/call","params":{"name":"surface_agent_snapshot","arguments":{"instance_id":"agent"}}}
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
this host's 256-record journal capacity). A first request may use an old epoch:

```json
{"method":"tools/call","params":{"name":"surface_events","arguments":{"epoch":"new-client","after":"0","limit":128}}}
```

Retain the returned epoch and latestSequence for the next read, converting the
cursor to a decimal string. A changed epoch or evicted/future cursor reports gap;
refetch snapshots. Reading never advances clocks, repeats actions or adds events.
Successful mutations and actual simulation changes share one journal; failures
commit neither state nor events. Typed host telemetry changes also carry events.
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
