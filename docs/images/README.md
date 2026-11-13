# App-owned README screenshots

Updated 2026-11-13. These are actual SwiftUI views rendered by the application in
`--integration-test` mode, with synthetic Mock data. The capture process opens no
CoreMIDI ports, reads no saved workspace or Keychain token, and captures neither
the desktop nor other applications. The offline example intentionally contains a
recorded violation to demonstrate the audit; it is not a real hardware recording.
All README screenshots use English. The pixels come from the app's own rendering.

| Image | App scene | Language | PNG pixels |
| --- | --- | --- | --- |
| `console-en.png` | `readme-console` | `en` | 3840 × 2080 |
| `settings.png` | `settings` | `en` | 1300 × 1880 |
| `organization.png` | `organize-page` | `en` | 1520 × 1120 |
| `offline-capture.png` | `offline-capture` | `en` | 1920 × 2560 |

Reproduce from the repository root:

```sh
python3 tools/capture_readme_screenshots.py
```

The helper builds the native Debug app and writes fresh images and per-scene logs
under ignored `build/screenshots/`. Inspect them before copying the selected files
above into this directory. `--skip-build` is available only when the current app
has already been built. No hardware or ordinary app launch is needed.

Rendering inspection does not sign off mouse/clipboard acceptance, physical LEDs,
motor behavior or hardware coverage. Those tasks remain in `TODO.md`.
