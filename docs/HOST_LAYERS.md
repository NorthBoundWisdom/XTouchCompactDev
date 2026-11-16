# Host module and file boundaries

The existing eight production targets remain unchanged. `configs/host_layers.json` lists
all production Swift files explicitly, including files in subdirectories. A new file or
module needs classification; a new target dependency needs an explicit manifest change.
CI runs `python3 configs/check_host_layers.py` before the normal tests on Linux and macOS.

| Role | Existing responsibilities |
|---|---|
| values | Protocol/control identities, configuration data, connection data, localized message data |
| runtime | Parameter values/actions, generic plugin registry, mutation budgets |
| device | Factory Standard MIDI mapping, device state/Mock, observations, display profiles, device configuration validation |
| bridge | Session composition, generic contract-to-device adapters, business binding factories, simulated capture replay |
| transport | HTTP/MIDI/socket/file transport, transport authentication, protected store, remote endpoint interpretation |
| composition | Executable wiring, UI, resource rendering and application orchestration |

Allowed direction is `values ← runtime ← device ← bridge ← transport ← composition`,
with each role allowed to use itself and the roles to its left. This describes dependency
direction, not chronological input or feedback flow. Device values are not device I/O;
transport acceptance is not a physical observation. The Core target is explicitly mixed,
and is never classified wholesale as runtime. Localization is also mixed: message data
is values, while resource lookup remains composition.

The H-6 mechanical separation removed actual reverse dependencies:

- The parameter engine no longer performs factory validation or supplies concrete Agent
  binding defaults. Its existing public construction signature lives in the construction
  bridge, validates in the original order and forwards an internal validated value into
  the unchanged value engine. Configuration data and persisted fields remain unchanged.
- The generic plugin registry no longer contains the Agent factory. Binding factories
  and indicator adapters live in their own bridge file. Its feedback-instance array stays
  private; an internal configuration operation preserves the factory's original order.
- The independent device Mock no longer calls a bridge helper. Position quantization is
  a device helper; the existing public session helper delegates to the same formula.
- Native MIDI transport no longer imports UI-owned connection declarations. Connection
  data moved within the same target, and endpoint interpretation remains transport code.
  `LocalizedMessage` moved as pure data; `Localizer` still owns resource lookup.

The checker removes nested comments and normal/raw/multiline string literal text while
retaining executable interpolation. It indexes host-owned type declarations and members,
then checks references in the actual file role, including module qualification, extensions
and annotated instance-member calls. Imported external SDK types are not confused with
same-named host types. A mixed target does not make its resource-rendering types values:
a transport reference to `Localizer` is rejected even though message data shares its module.
The parameter runtime's validated constructor label is also explicitly guarded, preventing
an accidental call back into its bridge convenience initializer.

This is a conservative source guard, not a Swift compiler or a general-purpose semantic
index. It resolves declared host types and annotated receivers; reflection, arbitrary
inferred generic receiver dispatch and dynamic lookup are outside its static model.
The real compiler and complete existing behavior tests remain mandatory. There is no
reverse-edge allowlist and no ignored production subdirectory. Purpose-built fixtures
exercise illegal imports, nested files, qualified references, extension bodies and members,
resource lookup, invalid constructor use, comment/literal false positives and interpolation.

No remote tool, schema, error contract, archived fixture or delivery layout changed.
