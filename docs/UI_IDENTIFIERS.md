# Native accessibility identifiers

The BCR host is adopting this same naming convention and adding its own checker
in this alignment step. The convention is shared; each host keeps its own
physical-control catalog and MIDI mapping. BCR controls do not inherit XTouch IDs.

Identifiers are an interaction contract, following BCR's dot-separated names and
stable entity suffixes. They are literal source constants, independent of translated
labels. Keep an existing ID when moving a control or renaming its label; add a new
ID for a new control. Do not regenerate IDs from source order. Entity rows append
the saved parameter/link/scene/macro/library ID, never a display name or a MIDI
address. Confirmation buttons have their own IDs, separate from opening actions.

| Surface | Identifier contract |
| --- | --- |
| Fader motion | `surface.fader.1` … `.9` |
| Fader touch region | `surface.touch.1` … `.9` |
| Encoder rotation | `surface.encoder.1` … `.16` |
| Encoder push | `surface.push.1` … `.16` |
| Illuminated buttons | `surface.button.1` … `.39` |
| Optional pedals | `surface.expression`, `surface.footswitch` (outside the 89) |
| Workspace selection/tabs | `workspace.selection`, `workspace.tab.<case>` |
| Mode choices | `mode.mock`, `mode.hardware`, `mode.manualSend`, `mode.liveSend` |
| Connection | `connection.input`, `connection.output`, `connection.tx`, `connection.rx`, `connection.ledEncoding`, `connection.ports.apply`, `connection.profile.apply` |
| MCP | `mcp.enabled`, `mcp.permission.parameterWrite`, `.motorWrites`, `.agentControl`, `.simulationControl` |
| Configuration library | `configuration.library.<action>.<entry UUID>`; the pending action uses `configuration.library.confirm` |
| Other controls | `settings.*`, `inspector.*`, `parameters.*`, `macros.*`, `agents.primary.<slot>`, and view-specific semantic prefixes. Exact literals remain in the view source. |

Panel motion/touch and rotation/push remain separate accessibility elements so the
89 identities can be discovered independently. The touch identity is attached to
the existing draggable slot, including unknown-position presentation. This changes
accessibility grouping only; no new input operation, shortcut, remote API, motor
permission or desktop automation is added. IDs persist across layers, assignments,
source selection and language changes; current data/labels can still change.

Run `python3 configs/check_accessibility.py` for static primitive coverage, unique
literal templates and the five panel binding families. BuildWorkflowTests also
exercise its lexical handling of nested controls and comments/strings. The Swift
`allEightyNinePhysicalControlsHaveUniqueLayerIndependentAccessibilityIdentities`
test verifies all 89 distinct physical IDs and pedal exclusion. Dynamic rows use
stable entity suffixes; shared helpers receive explicit call-site identities or a
physical-control ID, rather than repeating one ID across visible rows.

These are source/model checks. Native accessibility-tree lookup, focus traversal,
system menu/dialog interaction and mouse acceptance remain unverified; this task
does not run a desktop driver or claim native UI acceptance.
