# FreeCM development workflow

Open this repository root in VS Code with the recommended `ethan-kang.freecm`
extension. Open **FreeCM: Show Workflow Panel**, then select **Config → Local
macOS Swift** once before Build, Run, Test or Package. Linux selects **Linux
Swift Core** and exposes core builds and tests only.

`configs/freecm.commands.jsonc` is the version 2 plugin manifest. A changed
configuration input shows **Needs Config**; run Config again. FreeCM records
command submission, not successful completion: check the terminal for errors.
The setup script writes `build/configured.json` only after validation succeeds.

| Action | Command | Result |
| --- | --- | --- |
| Config | `python3 configs/setup_local_project.py` | Validate manifest and Swift package; create local settings if missing |
| Build | `python3 configs/macos_workflow.py build` | `build/app/debug/XTouchCompactApp.app`, ad-hoc signed |
| Run | `python3 configs/macos_workflow.py run` | Build and execute the debug bundle in the terminal |
| Test | `python3 configs/macos_workflow.py test` | Hardware-independent Swift tests, two jobs |
| Workflow tests | `python3 -m unittest discover -s Tests/BuildWorkflowTests -v` | Python workflow checks |
| Package | `python3 configs/macos_workflow.py package` | Native Release `.app` in a ZIP and `.zip.sha256` under `build/package/` |

The Run process belongs to the FreeCM terminal: logs remain visible and Ctrl+C
stops it. Stop Run before submitting another command. The app starts in Mock
mode. Hardware output and motor recall still require the existing UI actions;
the workflow does not select MIDI ports, change channels or send MIDI commands.

Build variants include Debug App and Release App (`build --configuration
release`). SwiftPM artifacts live under `build/swiftpm/`. The original `swift
test --jobs 2`, `swift build` and `swift run XTouchCompactApp` commands also work
and use SwiftPM's separate `.build/` directory.

## Local settings and packaging limits

Setup copies `configs/build.local.example.json` to ignored `build.local.json`
only when missing; existing settings are preserved. Its `environment` object
contains string overrides, and `path` contains directories prepended to PATH.
Values can reference `$REPO_ROOT`, inherited variables or `~`; no shell code is
executed. Set local Swift/Xcode paths there as needed. Version defaults live in
`configs/app_build.json`; `MARKETING_VERSION` and `ARCHIVE_ID` can be overridden
through the local environment.

Python 3.10+ is required for these workflows. macOS actions require macOS 14+, Swift 6
and Xcode command-line tools providing `codesign` and `ditto`. No Python packages,
Node, FreeCM checkout, submodule or external runtime dependency is needed.

Packages are native-architecture, locally ad-hoc signed developer artifacts.
They have no custom icon, Developer ID signing or notarization. They are not
production distribution builds. No release, upload or tag is created.

## Initialization and cleanup

`configs/source_root_workflow.py` supplies FreeCM's Init repo and Update
entry points (`--initrepo`, `--update`), both running local setup. `--init` is
accepted for older plugins. `--initlock` reports that there are no external
source roots; it creates no artificial dependency lock or download.

The adapter's explicit cleanup supports previews:

```sh
python3 configs/source_root_workflow.py --cleanbuild --dry-run
python3 configs/source_root_workflow.py --cleanbuild
```

It removes only `build/configured.json`, `build/swiftpm`, `build/app` and
`build/package`. Other files and local settings survive; symlinked build roots
are rejected. FreeCM's own **Clean Build** implementation may remove all build
children except its dependency seed/source directories. Neither cleanup removes
the separate `.build/` cache. Run Config again after cleanup.

## Headless validation

```sh
python3 configs/validate_repo_commands.py .
python3 -m unittest discover -s Tests/BuildWorkflowTests -v
swift test --jobs 2
swift build
git diff --check
```

The private MIT-licensed validator snapshot under `configs/_vendor/` is copied
from BCR2000Dev with provenance. It is used for configuration checks, never by
the app. Linux CI exercises the portable scripts and Swift core; macOS CI also
builds the native ad-hoc app bundle.
