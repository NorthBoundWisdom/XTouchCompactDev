# Development

Use Swift 6, Python 3.10+, Xcode command-line tools on macOS, SwiftFormat and Ruff.
No third-party runtime package is required. Run `python3 configs/setup_local_project.py`
then install the optional local hook with `git config core.hooksPath configs/githooks`.
Setup does not change Git configuration implicitly.

Before a commit:

```sh
python3 configs/format_repo.py --check
python3 configs/validate_repo_commands.py .
python3 -m unittest discover -s Tests/BuildWorkflowTests -v
swift test --jobs 2
swift build
```

`python3 configs/format_repo.py` applies formatting. Keep one backend TODO per
commit where possible. Commit messages use Conventional Commits and record tests
and remaining hardware/visual limitations. Never force-push or create release
tags unless explicitly requested. Use `--startup-smoke` or `--integration-test`
for isolated app checks: neither starts CoreMIDI nor loads user workspace files.
MCP and OSC are off at startup. Tests inject fake MIDI, temporary storage and
in-memory authentication tokens; they never use user Keychain credentials.

Hosted macOS CI requires native build/tests, ad-hoc ZIP/DMG packaging and isolated
startup smoke. Preview capture is a desktop diagnostic: the hosted runner timed
out despite passing startup smoke. Run `tools/capture_readme_screenshots.py`
locally on a Mac, or explicitly enable `capture_previews` in the manual GitHub
workflow. It is not silently ignored when selected: a capture error still fails
that diagnostic run. Push and pull-request CI do not run desktop preview capture.

CI actions must use a supported Node runtime. Checkout is on Node 24; Linux runs
inside the official `swift:6.2-noble` image with Python for workflow checks,
removing the Node 20 setup action while retaining Swift 6.2 / Ubuntu 24.04.
The macOS lane stays Apple Silicon. GitHub may attach an arm64 capacity notice;
that provider scheduling notice is not a build failure and cannot be fixed by
repository code. Do not hide it by silently replacing ARM coverage with Intel.
