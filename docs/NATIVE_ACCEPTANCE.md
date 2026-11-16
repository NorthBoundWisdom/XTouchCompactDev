# Native mouse acceptance (N5)

Status on 2026-11-13: **the seven N5 cases below remain incomplete** (two added for
Agent motor permission and value persistence). Code-level
tests pass, but they do not substitute for these mouse/visual acceptance cases.
The separate hardware-observation workspace has since been accepted by the
operator on a physical unit; see [the session record](HARDWARE_SESSION_2026-11-11.md).
That confirmation covers visible input feedback, not the seven console actions below.

The earlier native window automation surface returned `cgWindowNotFound` for both the
isolated release instance and an independently identified acceptance bundle.
A separate installed-app access attempt timed out and reset the UI tool session.
The isolated processes were stopped; the pre-existing user app was left running.
Sampling the isolated process showed an idle AppKit run loop, not a main-thread
rendering deadlock. This is evidence of a window-access/startup issue, not proof
that the interactions below pass or fail.

## Operator quick run (about 10 minutes)

Do the rows in order in Mock mode. Fill in **Actual result** with what you saw and
`pass` / `fail`; a screenshot filename is enough evidence. The persistence row needs
a normal (non-`--integration-test`) launch because isolated mode disables storage.
For the MCP rows, any local client works; for example:

```sh
TOKEN=<paste token>
curl -s -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"get_state","arguments":{}}}' \
  http://127.0.0.1:8765/mcp
```

Do not paste the token into this file or any committed evidence.

### Reference renders

Four rows have an app-rendered reference of the expected state, built with the same model
calls the UI uses. They show what to look for; they are **not** acceptance results.

```sh
python3 configs/macos_workflow.py build
APP=build/app/debug/XTouchCompactApp.app/Contents/MacOS/XTouchCompactApp
for scene in n5-touch n5-layer n5-osc n5-mcp; do
  "$APP" --integration-test --snapshot-scene "$scene" --snapshot-output "build/n5/$scene.png"
done
```

| Scene | Row | What it shows |
| --- | --- | --- |
| `n5-touch` | Touch arbitration | F1 held at 40 with a 110 software target: gold outline, 触摸中 badge, “motor command deferred” note |
| `n5-layer` | Layer mismatch | Mock physical layer B while host is A: warning banner, Connection tab with Realign current layer |
| `n5-osc` | OSC stop | Enable refused without trusted actual/heartbeat: visible OSC notice, output still off |
| `n5-mcp` | MCP switch / Agent motor permission | Settings with Agent writes on and Agent motor moves off |

Preset replacement and value persistence have no reference: the confirmation dialog is a
separate window that offscreen rendering cannot capture, and persistence needs a real relaunch.

## Reproduce in an isolated instance

Run setup, then `python3 configs/macos_workflow.py build`. Launch
`build/app/debug/XTouchCompactApp.app/Contents/MacOS/XTouchCompactApp --integration-test`.
This disables CoreMIDI and workspace/Keychain access. MCP/OSC remain off until
explicitly enabled. A UDP listener alone cannot arm OSC: trusted actual-state feedback and an independent heartbeat are required, and no production receiver configuration exists yet. Test the visible refusal without telemetry; use an explicit trusted fixture for armed-output expiry.

| Case | Mouse procedure | Expected result | Operator visual result | Offscreen automated acceptance |
| --- | --- | --- | --- | --- |
| Touch arbitration | Hold and drag F1; while held, write F1 through MCP or a second input device using the inspector; release | Cap stays with the hand, pending badge appears; release aligns to latest software target | Pending desktop access | C-12: passed Mock touch/release + zero touched-motor sends; pointer gesture remains operator-only |
| Layer mismatch | Inject a Layer B input while host is A using a fake MIDI service/test fixture; inspect warning and click Realign current layer in Connection | Mock: warning clears and Program Change is modeled without bank-target recall. Hardware-send: touched state refuses; after release and explicit retry, the assertion can cycle all nine motors | Pending desktop access | C-12: passed Mock B-input mismatch/explicit realignment; real controller still unverified |
| Preset replacement | Write a non-default parameter, choose Audio example, cancel; repeat and confirm | Cancel preserves configuration/value; confirm uses pending preset defaults once, no motor recall | Pending desktop access | Manual: native menu/confirmation not opened or substituted |
| OSC stop | Try enabling without trusted telemetry; separately use a trusted actual/heartbeat fixture and let the heartbeat age reach 0.3 s or invalidate the destination | Output disables, visible stop notification; re-enable is explicit | Pending desktop access | Partial: real enable refusal/notification/off verified; trusted live receiver expiry remains manual |
| MCP switch/token | Enable MCP in Settings, copy token, use local read-only integration client, disable | Loopback listener answers authenticated reads; disabling closes it; token is not logged | Pending desktop access | Passed isolated enable/stop + token action/feedback; system clipboard is not read or written |
| Agent motor permission | With Agent writes on and motor moves off, `set_parameter` a fader parameter; then turn motor moves on and repeat | Off: value and panel target change, mock fader cap stays; on: cap moves. Motor toggle is disabled while Agent writes is off | Pending desktop access | Passed real switches + guarded Agent requests; ungranted/touched motor ledger stays empty |
| Value persistence | Change a fader and an encoder, quit normally, relaunch | Values and ring restored; fader caps do not move on launch; panel shows the restored target | Pending desktop access | Passed owned temporary workspace save/relaunch; restored target sends no startup motor commands |

Deterministic coverage: PanelPresentationTests (mock gestures and held fader),
ServiceTests (layer realignment and touch), ConfigurationImportTests (preset
cancel/confirm), OSCOutputTests (stop notifications/scheduler), MCPTests and
HTTPTests (toggle/authentication/loopback). Clipboard copying still requires the
native acceptance above; never place an access token in committed evidence.

Record OS, compiler, commit, each actual outcome and app-owned evidence filenames
here after desktop access is available. Keep this task open until all rows have
actual visual results.

## Attended hardware follow-up for U2/U3

N5 remains incomplete; the limited HW-6 sign-off does not cover these changes.
In the 2026-11-12/13 session, Program Change and physical A/B selection cycled all
nine motors silently. “No motor CC” and “no bank recall” do not mean no movement.
U2 software behavior: while any fader is touched, A/B selection, Realign and Sync
lights refuse visibly without sending or queueing; release alone does nothing.
Mock selection stays unchanged. U3 hardware reconnect sends no MIDI, invalidates
old layer evidence and marks lights unsynchronized; the user must sync explicitly.
A failed/refused sync stays pending. **未在实机复核**.

With an operator present, start with TODO H1 (A/B highlight follows host selection)
and H6 (U2 refusal and U3 reconnect). H5 must distinguish USB power-up motion from
host output using listening-only mode. H4 (touch held during physical layer
change) needs an agreed safe procedure first. Keep all actual-result cells pending
until observed; isolated/fake-transport tests do not count as mouse acceptance.

## C-12 offscreen automated acceptance (separate from operator sign-off)

Run locally in a graphical macOS session with Accessibility permission:

```sh
python3 tools/run_offscreen_acceptance.py
# Optional: --suite n5|organize|offline|panels --output build/ui-acceptance/<run>
```

The command builds once, creates uniquely identified ad-hoc test copies with
LSUIElement=true before launch, then starts only `--integration-test --offscreen`
owned instances. Ordinary `--offscreen` startup is rejected before app/device
initialization. The Debug command additionally requires a session UUID, owned
directory marker and an in-memory credential. It uses `.prohibited` activation
policy, process-local activation interception, transparent/click-through non-key
NSPanels, no CoreMIDI and no user workspace/Keychain. Any active/key/opaque/non-Mock
state kills that owned instance and fails isolation. No global AX traversal,
keyboard/mouse events, AppleScript or desktop pixels are used. Screenshots come
from the owned hosting view's cacheDisplay, triggered through AX.

The helper validates target parent PID, UID and integration/session arguments on
every call. Queries/actions only traverse that PID's AX tree. Read-only loopback
inspection cross-checks UI values and the dedicated Mock motor-send ledger.
Mutations happen through AX production controls or labelled Mock input fixtures
(touch, incoming layer evidence, guarded Agent request, injected clock/flush).
Menus/confirmation actions are not replaced by alternate success buttons.

| Script | Offscreen coverage | Boundary retained for manual acceptance |
| --- | --- | --- |
| tools/verify_n5_ui.py | Touch/release, no motor commands while touched/ungranted, explicit Mock layer realignment, OSC refusal banner, MCP toggle/isolated copy feedback, actual temporary storage/relaunch | Native preset menu/confirmation; trusted actual/heartbeat receiver; system clipboard contents; real pointer gesture |
| tools/verify_organize_ui.py | Color, group highlight, fixture link follow/touch defer, fixture scene recall without motor sends, undo/redo | Non-key AX text edits/AXConfirm do not commit rename/group-name bindings; native link selection menus; pointer acceptance |
| tools/verify_offline_ui.py | Frozen XTouch/BCR common evidence, complete/incomplete/N-A display, step/run/pause/reset, isolated replay distinct from live console | Native file picker is not opened; file bytes are loaded at isolated startup; pause uses an injected batch-yield gate, not elapsed sleeps |
| tools/verify_new_panels_ui.py | Seeded library request-button availability, macro run outcomes, arm content visibility/pose/empty state, new MCP permissions and actual call rows | Native library load/delete confirmations; non-key name/save commit; native macro parameter picker/creation; full Parameters AX page transition; actual Panels menu-bar routing |

A long Mock replay fixture is derived from the frozen XTouch sample, with valid
new sequences/counts, to exercise pause deterministically between 128-event
batches. The production default remains Task.yield. Source files are hashed
before/after import. Seeded links/scenes/macros/library entries are setup data;
their creation routes are never described as passed when those routes cannot be
driven offscreen. Missing permission returns status `missing-permission`/exit77
before launching any UI (also checked during actions), not pass or a test failure.

This is **not in CI**. Permission-free parser/launch-policy/ownership checks are in
BuildWorkflowTests; Core flag/one-unit adjustment and App token/yield regressions
also run normally. Results are structured passed/manual-required/failed rows in
summary.json; a manual row is never an operator sign-off. Canonical local evidence
for this round: build/align3/acceptance-final/ (summary, actions, read-only state,
app logs and owned-view PNGs). Earlier probes/failures are retained separately.

The seven N5 operator cells above and TODO manual checkboxes remain pending.
Offscreen observations add evidence; they do not verify native system dialogs,
keyboard focus editing, mouse ergonomics, another running app or physical hardware.
