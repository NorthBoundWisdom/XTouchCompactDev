# Native mouse acceptance (N5)

Status on 2026-11-11: **the five N5 cases below remain incomplete**. Code-level
tests pass, but they do not substitute for these mouse/visual acceptance cases.
The separate hardware-observation workspace has since been accepted by the
operator on a physical unit; see [the session record](HARDWARE_SESSION_2026-11-11.md).
That confirmation covers visible input feedback, not the five console actions below.

The earlier native window automation surface returned `cgWindowNotFound` for both the
isolated release instance and an independently identified acceptance bundle.
A separate installed-app access attempt timed out and reset the UI tool session.
The isolated processes were stopped; the pre-existing user app was left running.
Sampling the isolated process showed an idle AppKit run loop, not a main-thread
rendering deadlock. This is evidence of a window-access/startup issue, not proof
that the interactions below pass or fail.

## Reproduce in an isolated instance

Run setup, then `python3 configs/macos_workflow.py build`. Launch
`build/app/debug/XTouchCompactApp.app/Contents/MacOS/XTouchCompactApp --integration-test`.
This disables CoreMIDI and workspace/Keychain access. MCP/OSC remain off until
explicitly enabled. Use a local UDP receiver if exercising OSC.

| Case | Mouse procedure | Expected result | Actual result |
| --- | --- | --- | --- |
| Touch arbitration | Hold and drag F1; while held, write F1 through MCP or a second input device using the inspector; release | Cap stays with the hand, pending badge appears; release aligns to latest software target | Pending desktop access |
| Layer mismatch | Inject a Layer B input while host is A using a fake MIDI service/test fixture; inspect warning and click Realign current layer in Connection | Warning clears, Program Change asserted, no motor recall; touch retained | Pending desktop access |
| Preset replacement | Write a non-default parameter, choose Audio example, cancel; repeat and confirm | Cancel preserves configuration/value; confirm uses pending preset defaults once, no motor recall | Pending desktop access |
| OSC stop | Enable output to local receiver, then apply an invalid destination or induce scheduler gap >1 s in fixture | Output disables, visible stop notification; re-enable is explicit | Pending desktop access |
| MCP switch/token | Enable MCP in Settings, copy token, use local read-only integration client, disable | Loopback listener answers authenticated reads; disabling closes it; token is not logged | Pending desktop access |

Deterministic coverage: PanelPresentationTests (mock gestures and held fader),
ServiceTests (layer realignment and touch), ConfigurationImportTests (preset
cancel/confirm), OSCOutputTests (stop notifications/scheduler), MCPTests and
HTTPTests (toggle/authentication/loopback). Clipboard copying still requires the
native acceptance above; never place an access token in committed evidence.

Record OS, compiler, commit, each actual outcome and app-owned evidence filenames
here after desktop access is available. Keep this task open until all rows have
actual visual results.
