# ControlSurfaceKit adoption

Current managed commit is `8c8b58e48b3c2a8239ce882821ee3edeefb99ec7`.
Production uses the Kit for J3 binding, context and connection and for J4
feedback planning, preflight and receipt-scope eligibility. The host still owns
scheduling and applies device safety policy before sending feedback.
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

## J4 production feedback planning

`SurfaceFeedbackPlanning` owns the production authorization stage, whole-plan
preflight and receipt-scope eligibility. The Console constructs immutable plans
from the captured route/authorization/mode and original endpoint facts. Its
canonical device filter still runs exactly once, in the original place after
touch, layer and motor-action checks. That actual result becomes the explicit
native safety proof; Core does not implement or bypass a device gate. Actual
transport pinning and synchronous callback ordering remain in the adapter.

A receipt's result describes the actual boundary call. A pin refusal after that
call is an admission attempt, not evidence of a physical write or observation.
Core scope eligibility controls the existing post-call bookkeeping and does not
refresh identity or replay output after a callback changes the owner.

Permanent Mock keeps its virtual-layer behavior and now dispatches the immutable
plans permitted by Core. Hardware-mode Console retains its explicit local
motor/layer policy. The GUI-only virtual service retains its separate atomic
journal and Mock display transaction. Ordinary and owned hardware services
remain typed display-only. Core evaluates the existing pin inside each sender.
Ordinary CoreMIDI refreshes the endpoints before pinning and validates the word
next. Owned virtual MIDI validates ownership and the word before pinning, and
retains its final ownership check before committing. The managed manifest
records feedback adoption. The accepted migration comparisons are retired.
Product regressions and the independent scheduling candidate remain.

Compact uses `FeedbackRequestState` with `.suppressAfterProposal` for button lights,
encoder ring values and ring styles. The host still owns redraw order, desired
values, indexed scope, and the decision to invalidate. A generated value carries
no transport or physical-acknowledgement meaning. The independent comparison for
these three caches was retired after the exact cut passed.

The historical scheduler candidate remains test support for fader, held-intent
and receipt causality. Its value state follows session copies. Unmatched or
ambiguous receipts remain unknown and do not update an accepted cache. This
historical lane is separate from the three production display stores.

Test trace schema 2 uses lossless exact-content catalog nodes. Every persisted
export is read through the repository's strict reader and cold-replayed by its
actual node/parent lineage. Header coverage, raw duplicate keys, closed fields,
canonical references, actual input bytes and nested DTO layouts are checked.
The scheduler collector is an opt-in Debug test hook. Virtual tests
and transport acceptance provide software evidence. Physical qualification
requires separate attended checks.
