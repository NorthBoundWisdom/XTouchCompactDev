# Agent instructions — XTouchCompactDev

## Scope

Native macOS 14+ app for Behringer X-TOUCH COMPACT, with a pure Swift 6 core and a CoreMIDI/SwiftUI host. Reuse of BCR2000Dev's architecture is permitted, but hardware semantics differ significantly: **input messages and feedback addresses must never be presumed identical**.

## Rules

- Device support is **factory Standard MIDI mode** only; Mackie Control / modified editor presets are out of scope until characterized. Do not flash or patch firmware.
- 9 motor faders, 9 touch events, 16 encoders, 16 pushes and 39 illuminated buttons. Always keep physical control identities separate from MIDI address and layer identities.
- **Never command a motor while touched.** Do not automatically recall motor positions on startup, layer switch or reconnect. Intentional recall requires an explicit user action.
- Do not infer Global RX channel from TX messages. Expose both channels as configuration. Hardware profile is never silently rewritten.
- Preserve different button LED velocity encodings (manual vs observed firmware 1.14), and note exactly what has not been physically tested.
- No feedback loop or implicit state acknowledgement: last transmitted MIDI command is not a physical-position observation. Use stale-observation and reassertion policy.
- Keep protocol/core tests runnable on Linux without a physical controller; app and CoreMIDI live in an `#if os(macOS)` executable target. Every new message/event shape gets deterministic tests.
- For GitHub changes, verify the current main before pushing. Never force push; no release tag unless requested.
- Avoid adding an external runtime dependency until there is a demonstrated need. The explicitly authorized SurfacePlugins package is the sole exception: both hosts consume the same pinned commit for controller-neutral business logic. Do not copy PolyForm Noncommercial code from third parties.

- Views render `PanelSnapshot` and emit `PanelIntents` only; `ConsoleModel+Panel.swift` is the single adapter. Leave contract fields nil when the backend cannot report them — never fill them with guesses. Work split and task order are in `TODO.md`. Backend changes propose contract additions in commit descriptions; frontend authors change the contract and views.

## Local checks

```sh
swift test --jobs 2
swift build
```

FreeCM integration uses `configs/freecm.commands.jsonc` (version 2) and the thin
`configs/source_root_workflow.py` setup/cleanup adapter. No FreeCM checkout,
dependency lock or runtime dependency is required. Use `python3
configs/setup_local_project.py` before plugin Build/Run/Test/Package actions.
Keep local paths in ignored `build.local.json`; generated artifacts belong in
`build/`. Packaging is local ad-hoc ZIP/DMG only; do not claim notarized distribution.
See `docs/FREECM.md`. When changing workflows, also run:

```sh
python3 configs/validate_repo_commands.py .
python3 -m unittest discover -s Tests/BuildWorkflowTests -v
```

On macOS, additionally verify the native app on a Mac with at least Xcode command-line tools, then perform the documented physical bring-up checklist once hardware is available.
