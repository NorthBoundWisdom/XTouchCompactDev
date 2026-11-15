# Stock test-runner assessment (G-8)

Keep the current SwiftPM runner for XTouch. This is an assessment, not a migration to the BCR batch runner.

## Current execution paths

- `configs/macos_workflow.py test` directly invokes one `swift test --build-path build/swiftpm` command.
- Linux CI directly invokes `swift test`; macOS CI uses the workflow adapter above. The build paths differ by platform, but the runner is SwiftPM in both cases.
- No local script loops over individual test-case names to launch a fresh native test process per case. The BCR-specific motivation for replacing such a launcher therefore does not exist here.
- XCTest and Swift Testing both contribute results. Swift Testing's bundle total includes its explicitly disabled attended test; do not count that skipped test as a pass or count repeated XCTest suite summaries twice.
- Python's real-process tests deliberately start isolated host processes to verify restart, instance/epoch boundaries, quota and credential separation. Reusing one host across those tests would lose their isolation coverage; a faster native test dispatcher would not replace that work.

## Measured evidence

Same local checkout, build path, `--jobs 2`, and hardware tests disabled. Complete commands, exit statuses and monotonic wall durations are recorded in `build/g/{baseline,g0-after,g5-after,g4-fixed}/commands.json`.

| Group | Before G changes | After G-4 | Scope |
|---|---:|---:|---|
| Swift command wall time | 8.294263165968005 s | 7.302611207996961 s | Includes incremental build; not an isolated runner-overhead benchmark |
| Real-process integration command | 29.494465916999616 s | 28.380013458023313 s | 55 passed / 0 failed / 1 attended skip in both runs |
| Three test commands combined | 42.78004320792388 s | 40.22158149903407 s | Python workflow + Swift + integration; workflow tests grew 82 to 85 and Swift passes grew 346 to 347 |

The total test-command durations are sums of measured command intervals, not estimates. One before/after full run cannot establish a universal speedup. G-4 separately compares the six modified process tests with the same simulator binary and SDK, alternating three old/new test implementations; its raw measurements are in `build/g/waits-comparison/summary.json`.

The last supervisor-observed all-green CI before G-4 was G-5 run `43738451847` (134 seconds including checkout/setup/build), below the five-minute limit. G-0's complete successful run `43737998906` took 212 seconds. The F starting run failed early on formatting, so its 107 seconds cannot be used as an equal-work performance baseline. CI cache/network/compile work differs from a local warm test command.

## Decision

Do not introduce a second native runner or a new per-case dispatcher. Keep SwiftPM's discovery, XCTest/Swift Testing execution and existing failure/skip accounting. If future evidence identifies native launch overhead as a material cost, first capture process-level evidence and a complete case inventory, then evaluate a common runner with exact discovery/start/end accounting. No tests, assertions, CI lanes or timeout thresholds are removed by this assessment.
