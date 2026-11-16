# Neutral controller regression executor (H-10)

The sole scenario source is SurfacePlugins `fixtures/controller-regression-v1.json`.
This host does not keep another copy and does not invoke existing tests by name. The
executor is in `Tests/XTouchCompactAppTests/ControllerRegressionExecutorTests.swift`;
its transport-fault helper is `Tests/H10Support/response_drop.py`. They run only fake
devices, isolated models and owned loopback ports. No product `Sources/` behavior changes.

Simulation feedback preview arrays are raw projection witnesses only. They are never
recorded as accepted I/O. The actual simulator event/mock state and primary isolation
are observed independently; unexposed internal simulator transport calls are not invented.
Each received packet is applied to the fake device once before the real receive path.

The host supports absolute input, motors, physical contexts/global context motion,
display styles and independent input/output addresses in its characterized Factory
Standard mode. Relative input, BCL/preset transactions and device preset restoration
are outside that supported protocol; T05/T19/T20 explicitly report protocol NA.
Missing authority/provenance/GUI permission integration is a failure, never device NA.

The XCTest/Swift Testing entry verifies a complete, structurally valid 30-row report.
Its passing does **not** mean all scenarios conform. The shared validator separately
prints `validation`, `conformance`, scenario counts and checked assertions. Actual
failures remain in the JSON and in the final comparison table; no expected-failure
annotation, retry or assertion relaxation is used to hide them.

## Owners and observations

Core cases drive `CompactSession`, `MockXTouchCompact`, real plugin action dispatch
and actual native plans. GUI/MCP/undo cases drive isolated `ConsoleModel` instances
through their existing entry points and a recording fake transport. Display identity
cases use actual `ControlFeedback.expected`, `CompactHardwareSurface.transition`,
`displayPlan` and success-only `recordFeedback`. T15 uses the existing model apply/send failure path with actual rejected transport and
read-only reflection of `CompactState.lastSentRings` before/after; the desired ring is
recorded separately from the invalidated sent cache. No fixture-created ack/commit order
is used to prove T15. The route test first proves its
current request produces a legal plan, then observes the exact stale-epoch rejection.

Fake transport records calls and acceptance without implementing controller filtering,
permissions, deduplication, authority or reconnect policy. Output counters come from
those records. Numeric projection counts include accepted ring-value messages only,
not styles or rejected attempts. Sent values stay in actual wire/cache units (e.g.7);
there is no semantic fixture cache containing the requested64.

T07/T08 retain a real native plan and call the existing `filterFeedbackForDelivery`.
Prepared and revoked motor-plan counts are observations of actual arrays/multiset
differences, separate from I/O effects. A revoked packet can coexist with a still-valid
deferred desired value: the real `pendingMotor` remains visible rather than being
cleared in the fixture. The final oracle follows the original scope: only T17 binds
the second fader to the same parameter. The earlier9332 fixture/results are preserved
as semantic-review history, not overwritten or called product safety defects.

T11 uses a real connected new generation, actual retained safety touch and existing
explicit output authorization, restores layer evidence using an unbound encoder,
then tries the affected motor through the real model boundary. A disconnected or
unprivileged no-output result cannot satisfy that probe. T18 captures the real model's
suppressed output records for GUI and MCP before comparing their post-gate results.
T25 uses the two existing journal and GUI-continuity facets independently, as the
original scenario's “or” permits; it does not invent cross-facet lock propagation.

T24 starts the existing `LocalMCPServer` on port0 with an in-memory token and an
isolated GUI Mock's real `routeMCP`. A real `agent_primary` dispatch changes idle to
queued; a local proxy consumes the successful upstream reply and closes downstream.
The existing SDK's low-level `rpc` observes `transport_unknown`, one request and no
retry. This is the retained GUI `agent_primary` tool over its actual modern stateless route,
not a claim that control-simulator
input supports action mapping or that the former GUI protocol remains available. The transparent proxy preserves the
SDK-generated end-to-end protocol headers and metadata; it does not invent negotiation
or successful replies. The concurrent upstream GUI migration is separate from H
headless contract compatibility and is documented in MCP.md. Tokens
exist only in memory and anonymous stdin pipes, never argv, reports or files.

## Run and review

After the approved shared revision is materialized, the normal native test command is:

```sh
python3 configs/macos_workflow.py test
```

It writes `build/h/h10/final/controller-regression-results.json` plus a separate raw
trace containing real owners, native packets, filters and fault observations. The
shared stdlib validator checks the fixture digest, exact30-row inventory, step order,
assertions and effect arithmetic. Native-plan revocation additionally requires the
supervisor to inspect the raw evidence; the validator labels that explicitly.

During precommit coordination, explicit `XTOUCH_H10_FIXTURE_PATH`,
`XTOUCH_H10_SCHEMA_ROOT` and `XTOUCH_H10_REPORT_ROOT` may select the approved uncommitted
**data/validator** candidate and a new report directory. The Swift runtime dependency
still comes from the managed locked checkout. The executor pins the approved fixture
SHA and refuses to silently learn a changed oracle. Those overrides are for development
coordination; they do not grant real-device access or change product policy.

T29 uses a discriminating fixture: p1 starts0 and p2 starts96. The existing product
`loadConfiguration(resetValues:false)` builds and sends the actual new-page plan. The
executor reads the real axis→p2 binding/value, requires a nonempty numeric axis plan,
and compares the actual Mock ring and real codec projection while retaining the observed
physical layer. An empty plan or a preview manually set to0 cannot prove correctness.

Final candidate results against fixture546f:24 pass,3 protocol NA,3 real failures:
T21 is a missing expression of the neutral global GUI/undo revocation objective: the
actual `mcpMotorWritesAllowed` is Agent-specific, while explicit local undo follows the
existing local permission path. It is not called a violation of the published separation
of permissions or a new H safety regression. T27 has no external
readback/authority-to-UI rejection path; T30 lacks explicit endpoint provenance and
qualification fields. These are observed differences/preparation gaps, not physical
acceptance or an invitation to change controller behavior within H-10. The old7a59 and9332 candidates and raw evidence remain preserved; the sole
fixture was refined only after supervisor review, not by changing product behavior.

## Concurrent upstream GUI integration

The final H-10 commit is based on remote1eddf24, which already contains12 separately
implemented GUI/configuration/packaging/capture commits. They are integrated and
regression-tested here, not claimed as H implementations. The incompatible retirement
of GUI2025-03-26 and GUI JSON-RPC batches was explicitly authorized by the user for
that GUI migration; it is separate from F's headless consumption contract.

The response-loss proxy now transparently forwards the SDK's existing end-to-end MCP
and Accept headers. The new real router rejects missing mirrored headers before any
dispatch (the preserved diagnostic shows HTTP400/-32020 and Agent still idle). With
actual SDK headers forwarded, upstream really dispatches once and returns HTTP200
before downstream loss produces SDK unknown. The proxy does not invent protocol
values or successful responses. Default tests use the remote-locked managed shared
revision83247ee and fixture546f, without candidate data/schema overrides.

For a full local HTTP run after these upstream additions, explicitly select all three
binaries from the same unified build path, including XTOUCH_GUI_BINARY. The newly added
GUI integration's default `.build` lookup can otherwise select an old local executable;
that first failed selection and both binary hashes remain in the H-10 evidence. The
existing macOS CI selects hardware modules, so its green status is not described as
executing this newly added GUI subprocess integration automatically.
