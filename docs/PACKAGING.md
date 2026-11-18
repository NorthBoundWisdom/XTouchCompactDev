# Local macOS packaging

Packaging remains local ad-hoc signing only: no Developer ID, notarization,
credentials, tag creation or GitHub Release. Do not describe these artifacts as
notarized distribution. Minimum deployment target is macOS 14.

```sh
python3 configs/setup_local_project.py
python3 configs/macos_workflow.py package --architecture universal
```

`--architecture native|arm64|x86_64|universal` is supported by build/package.
The CLI defaults to native; the FreeCM Release ZIP + DMG variant selects universal.
Explicit slices use independent build paths and macOS 14 target triples. Universal
assembly uses lipo and copies the architecture-independent localization bundle.
The `.app` structure and ZIP/DMG root payload remain unchanged. Packages stay in
`build/package/`, named with the actual architecture or `universal`.

Each ZIP and DMG has its existing `.sha256` plus a `.build.json` containing source
commit, dirty flag, marketing/build versions, Swift toolchain, selected/actual
architectures, minimum macOS, SurfacePlugins locked revision, SHA-256 and explicit
ad-hoc/non-notarized status. Local dirty builds are labelled as such; source
provenance cannot be silently omitted. These records provide traceability and
integrity checking, not a cryptographic publisher identity.

```sh
python3 configs/macos_workflow.py check-package --archive build/package/<artifact>.zip
python3 configs/macos_workflow.py check-package --archive build/package/<artifact>.dmg
```

Package creation verifies the final ZIP and DMG payloads. ZIP is extracted into an
owned temporary build directory; DMG is mounted read-only with no browsing, copied
into that directory and always detached. Checks compare sidecar checksums,
record/bundle versions, source metadata, signatures, localization and actual Mach-O
architectures. A matching native architecture runs both `--startup-smoke=headless` and `--startup-smoke`; a cross-only
artifact receives structural verification and explicitly reports that launch needs
a matching host. Universal launches the host's native slice. The headless entry runs before AppKit scenes: no window, workspace, Keychain,
CoreMIDI client or runtime scheduler. The GUI entry launches the actual SwiftUI
scene and ContentView, then exits only after its first draw/window-update cycle;
there is no fixed sleep. Both use isolated Mock models and keep external services
and permissions off. GUI markers require mode=gui, windowCreated=true and
firstFramePresented=true; headless markers require mode=headless and both flags
false. Both require hardwareAccessed=false and cannot substitute for each other.
The normal CI “Isolated native startup” keeps the GUI entry. Hosted macOS runners
have window sessions, so final packages exercise both entries on ARM and Intel.
This is an isolated process startup check, not visual or physical acceptance.

The manual/tag package workflow builds universal ad-hoc assets and uploads their
records/checksums. Separate ARM (`macos-26`) and Intel (`macos-26-intel`) jobs fetch
the final assets and launch both extracted payloads, requiring a clean exact
GITHUB_SHA and the checkout's exact dependency lock. There is no publish job.
The pinned compiler lane remains unchanged. This round does not push or create a
tag, so hosted availability, remote execution and Intel native startup await a
later authorized workflow run. Local cross-compilation alone is not Intel launch
evidence.
