# Mock behaviour traces

`mockBehaviorTracesMatchCheckedInBytes` runs the real `CompactSession` / `CompactState`
with `MockXTouchCompact` as the output receiver. No CoreMIDI is constructed. Regenerate
intentionally with `UPDATE_BEHAVIOR_TRACES=1 swift test --jobs 2 --filter mockBehaviorTracesMatchCheckedInBytes`;
ordinary runs compare sorted-key JSON bytes, including the final newline.

Each `steps` row has:

- `input`: operation, MIDI 1 bytes, decoded hardware layer, injected monotonic time in
  seconds (row index / 10). Software operations have no raw message or hardware context.
- `result`: success / rejection reason, actual parameter differences, action count (all
  selected input gestures have no action binding).
- `output`: messages delivered to Mock, failed attempts, touch-deferred fader identities,
  delivery-filter suppression, and cancelled pending intents with their layer-mismatch reason. A rejected layer assertion describes all nine affected
  faders and its reason. The failure fixture calls the real transport-cache invalidation
  method before trying the same desired value again; it does not retry a hardware send.
- `observation`: host layer, input-observed layer, mismatch, last input F1 value, touch and
  pending sets. `fader_1_observed: null` means no input position has been received.
  `fader_1_observation_current` and `last_sent_motor` are always null because these private
  caches have no public read API. They are never inferred from sent messages. Missing
  freshness is a source limitation: a retained numeric observation may already be stale.

Scenario 07 exercises `CompactState.setRingStyle` on a state copy, records its style +
position reassertion, then requests the same ring value on that same copy. The latter is
empty because the style operation has already reasserted the value. No session style API
or product introspection was added to fill trace fields. Scenarios 01 and 02 deliberately
share their first two steps; 02 extends 01 with the release.

`source: mock` labels software-only evidence. Times are supplied by the harness; these
state-machine APIs themselves do not consume time. No result implies physical position,
firmware release-address behaviour, or an independently verified physical layer.

## Neutral declarations (L-C2)

The original keys, arrays and values are retained unchanged. Each `input` adds
`element`, `role` and `context`. Each `output.declarations` item identifies exactly
one original output by its JSON pointer `source_field` and declares `category`,
`target`, `affected`, and optional `side_effects`. This additive array preserves
original MIDI-byte arrays rather than replacing them with a different shape.
The old rejected-layer record's `category: mechanism_motion` is a legacy raw field;
its **neutral declaration** is `category: management`, `side_effects: [motion]`.
No alias conversion is required: consume only the explicit declaration for semantics.

Physical IDs are `fader.1`...`fader.9`, `encoder.1`...`encoder.16`, and
`button.1`...`button.39`, independent of layer. A fader's position and touch use
the same ID with roles `position` and `touch`; encoder rotation/push similarly
share an ID with `rotation`/`press`. The factory table also names the optional
`pedal.expression`/`pedal.switch` (not exercised by these eight fixtures).
The harness obtains input identities from `FactoryStandardMap.decode` and output
endpoints from `feedbackAddress`/`encoderRingStyleAddress`. Ring-style targets end
in `.ring.style`; other targets end in `.motor`, `.ring`, or `.light`.
Program Change targets `device.layer`, affects all nine `fader.*` IDs, and declares
the additional `motion` side effect. Deferred/cancelled intents retain their exact
original reason and declare the affected motor endpoint. No product API was added.

`observation.declarations` supplies `state` and a `source_field` for every original
observation value. Actual delivered Mock output also gets a `sent_only` observation
referencing its output pointer: it never invents a position observation. The F1
position state starts `unknown`, becomes `observed` on an actual position input,
and becomes `stale` on the state operations that invalidate it (motor plan or layer
assertion). A missing numeric F1 observation remains `unknown`, never inferred from
an output. The private `fader_1_observation_current`/`last_sent_motor` fields remain
null with null state. `host_layer`, `layer_mismatch` and `pending_motor` are host
intent/computed bookkeeping rather than hardware observations, so their added
state is also null. Touch and input-layer evidence are labelled independently.

Software commands have no single physical input gesture or observed hardware
layer: their input `element`, `role`, and `context.value` are null. Every context
still declares `kind: layer`; actual MIDI input declares `a`/`b` from the factory
address. These nulls represent unknown/not-applicable input, not guessed identity.

| Scenario | Steps | Null element / role / context.value (each) | Null observation state |
|---|---:|---:|---:|
| 01-touch-defers-write | 2 | 1 | 10 |
| 02-release-reconciles | 3 | 1 | 15 |
| 03-cross-layer-release | 4 | 1 | 20 |
| 04-touched-layer-refused | 2 | 1 | 10 |
| 05-layer-invalidates-observation | 2 | 1 | 10 |
| 06-send-failure-cache | 2 | 2 | 10 |
| 07-ring-style-redraw | 3 | 3 | 15 |
| 08-shared-parameter-touch | 2 | 1 | 10 |
| Total | 20 | 11 | 100 |

Output `category`, `target`, `affected` have zero nulls. Optional `side_effects`
is present only for layer assertions, always `[motion]`. A software operation's
null role is intentional rather than adding a fifth role to the agreed vocabulary.
