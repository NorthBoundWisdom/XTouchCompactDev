# ControlSurfaceKit adoption

J3 uses managed commit `545ba46c3cb5298663c3dd12e53604a5a68da7a0`.
`configs/control_surface_kit.lock.json` and its stdlib/Git manager own acquisition;
Swift never compiles the development checkout. SurfacePlugins remains pinned to
12ba0ed and remains the sole shared business-contract/quantization authority.

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
