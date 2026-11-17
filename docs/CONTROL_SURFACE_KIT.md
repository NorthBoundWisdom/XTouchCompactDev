# ControlSurfaceKit adoption

Current managed commit is `49ad4a7b8aa1160b9369733f0c8681647a41cd51`.
J3 binding/context/connection is adopted in production; J4 feedback planning,
preflight and receipts remain a strict Debug shadow. Native code determines
product behavior in this stage; feedback and scheduling have not switched.
`configs/control_surface_kit.lock.json` and its stdlib/Git manager own acquisition;
Swift never compiles the development checkout. SurfacePlugins remains pinned to
`5ffbac79699505a76298172e8e6f28f7de3df88b` and remains the sole shared business-contract/quantization authority.

Production owners are now:

- `ParameterEngine.assignment` reads the Kit `BindingContext` first-match index.
  Its opaque target is a reference into the one native validated configuration;
  action payloads and parameter values stay there. Physical role IDs do not change
  across A/B. Native logical facets remain separate from physical identity.
- `CompactState` uses `ContextResourceIndex` as the only pending-ID and nonmotor
  cache-validity owner. Typed desired/sent payloads remain in their single native
  dictionaries. Lifecycle invalidation uses the shared index's exact removed IDs.
  Numeric-sorted pending presentation preserves the original unordered Set API;
  actual feedback arrays and release-driven send order are never sorted.
- `ConsoleModel` uses value `ConnectionState` transitions and exact shared route
  comparison. C's extra identity is empty: descriptor/name/provenance changes are
  retained facts, but were never part of C's semantic route-change predicate.
  The candidate value is computed before publication and committed only after
  the actual Published store. The trusted latest raw transport and the UI
  projection retain the native a532 publication/handover ownership policy.

Contact ownership, actual layer evidence, mismatch, stale-observation revisions,
manual motor recall, Program Change safety, endpoint selection and MIDI encoding
remain device/host responsibilities. This is not a J4 scheduling cut. The static
simulation-profile discovery builder still reads native configuration to produce
its frozen public descriptor; it is not the runtime control-binding lookup.

## Test reference boundary

All old Set/first-match/route leaf implementations are in
`Tests/*Tests/Legacy*Reference.swift`. Both Core/App resource-and-binding files
are identical; no production source imports them. Their resource, binding and
connection states are structs. Only their diagnostic sink is a class.

Same-package, nonpublic reference protocols are diagnostic test hooks. DEBUG
storage defaults to nil; Release stores no reference and neither configuration
allocates/retains a default recorder. A reference receives the same operation
input, independently computes the old answer and strictly checks the Kit result;
it cannot change the returned value, authorization or device safety. Copy/discard
cases cover candidate branches. The actual test-only failure sink is compiled
and exercised by `test_context_shadow_gate.py`; an intentional mismatch must
terminate the child, while its equal control must return normally.

## Requirements for another device adapter

Supply stable actuation-role IDs, opaque logical facets and references into the
existing configuration, stable lifecycle context, and actual trusted endpoint
identity/provenance. Keep unknown facts absent. Feed the shared connection value
at the real native publication boundary, not a future UI snapshot. Register and
consume actual deferred IDs and cache-validity IDs; retain payloads in one owner.
Apply the returned invalidation IDs to those payloads. Keep physical safety and
final pinned transport admission in the adapter. Supply time at receipt/planning;
do not derive neutral monotonic time from diagnostic wall time.

## J4 complete shadow stage

`SurfaceFeedbackPlanning` supplies immutable plans, explicit stage/full proofs and
actual boundary receipts beside the existing native decision. The same real
inputs are checked without changing native return values, touch/layer gates,
callback ownership, transport calls or post-record scope ordering. Device facts
and original UTF-8/number bits are retained. A pin refusal after invoking the
adapter is an admission attempt, not evidence of a physical write or observation.

All three compositions are distinct: permanent Mock keeps its original virtual
layer behavior; hardware-mode Console retains its explicit local motor/layer
policy; ordinary and owned hardware services remain typed display-only. The
managed manifest records `feedback-shadow`, not feedback adoption.

The shared scheduler candidate is test support only. Its mutable state is a value
that follows session copies; shared classes only collect diagnostic records.
Unmatched or ambiguous receipts remain unproven and do not update an accepted
cache. Generation-cache and style/projection policy differences are recorded;
no scheduler algorithm is adopted here.

Test trace schema 2 uses lossless exact-content catalog nodes. Every persisted
export is read through the repository's strict reader and cold-replayed by its
actual node/parent lineage. Header coverage, raw duplicate keys, closed fields,
canonical references, actual input bytes and nested DTO layouts are checked.
The test-only legacy resource/binding/connection references remain independent.
No reference/scheduler collector is installed by default; Release retains the
native runtime path. Neither virtual tests nor transport acceptance grant
hardware qualification. A later feedback cut requires a separate review and
the other host's exact successful CI in the approved order.
