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
