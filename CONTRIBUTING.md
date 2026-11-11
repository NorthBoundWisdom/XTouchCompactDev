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
