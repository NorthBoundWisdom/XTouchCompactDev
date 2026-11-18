# CI layers


The current push workflow runs the original product regressions with the
independent scheduler-only proof in `full-proof.yml`. The historical J-FINISH
baseline below records the earlier migration configuration.

Baseline: `f8dc367675829f093f6ae92766b86e7dd7cc8acf`, [run 44121318088](https://github.com/NorthBoundWisdom/XTouchCompactDev/actions/runs/44121318088), 2026-11-17 UTC. The complete run took **662 seconds** (created 16:03:12 → updated 16:14:14). Only the app budget step failed. Durations below come from the Actions run and its original log, not estimates.

## Classification and destination

| Existing check / test group | Baseline actual duration | Class | Destination after classification approval |
| --- | ---: | --- | --- |
| `independentNativeAndTypedOwnersMatchEveryApplicableControllerStep` | 294.863 s (Swift Testing) | Complete proof: all scenarios, two independent owners, J3 leaves, J4 current + persisted cold replay | `full-proof.yml` on macOS; unchanged method, helpers, inputs and assertions |
| `controllerRegressionExecutorProducesThirtyValidatedResultsWithoutChangingProductPolicy` | 121.384 s (Swift Testing) | Product regression: all 30 scenarios, all applicable steps | Every-push macOS CI, unchanged |
| `mockBehaviorTracesMatchCheckedInBytes` | 44.434 s macOS; 14.947 s Linux | Fixed representative comparison: all eight checked-in native goldens | Every-push CI on both platforms |
| `independentNeutralGoldenOwnersRetainAllEightNativeByteTraces` | 34.532 s macOS; 9.491 s Linux | Fixed representative J2/J3/J4 comparison (eight goldens, 20 steps) | Every-push CI on both platforms |
| Remaining Swift tests (Core, App, MCP transport; context/feedback negative controls, copy isolation, catalog codec, permission and safety tests included) | Aggregate step: 423 s macOS / 17 s Linux; per-case original values in evidence ledger | Regression; uncertain cases retained | Every-push CI on the original platforms |
| Python workflow suite, including actual Debug shadow-failure probes and schema/packaging/compatibility checks | 62 s macOS / 16 s Linux; unittest elapsed 61.352 s macOS | Regression | Every-push CI, all original tests |
| Python simulator suite (all Linux cases) | 34 s | Regression | Every-push Linux CI |
| Fake MIDI HTTP hardware service | 3 s | Regression | Every-push macOS CI |
| Immutable offline HTTP diagnostics | 2 s | Regression | Every-push macOS CI |
| Owned virtual transport (Debug) | 3 s | Regression | Every-push macOS CI |
| Full lint/setup, layer boundaries, native build and isolated startup | See exact step inventory below | Regression/build gates | Every-push CI, original platforms |

Swift Testing case durations overlap because tests are concurrent and MainActor jobs queue. They are reported timings, not additive CPU or exclusive case cost. The 30-scenario product harness remains in normal CI, including its existing feedback auditing. Only the independent all-scenario twin-owner migration proof moves. No original Python tests move; no product source, original test body, assertion, count, threshold, fixture or dependency lock changes are made. Four new configuration tests check the explicit layer entry point. Compact has eight native goldens; the BCR-specific three G-6 samples remain in the BCR workflow.

## Complete proof workflow and acceptance

`full-proof.yml` runs the unchanged complete proof on manual dispatch, nightly schedule and path-triggered pushes (both locks/manifests/dependency setup, core and app adapter sources, feedback/context/scenario tests and test support, workflow/entry-point changes). Job timeout: 30 minutes. It must succeed at the exact same SHA as the normal CI before cutover or delivery. The every-push workflow retains the 300-second created-to-updated budget with queue/cold-cache time included; implementation targets 240 seconds. No retry or old-run rerun is planned. Final actual run IDs and times will be added after verification.

## Exact baseline workflow step inventory

All run API steps are retained below, including infrastructure/post-job steps. `0` means API timestamp resolution, not an estimate. Skipped preview capture remains an opt-in desktop diagnostic. No new skip is proposed.

### workflow-unit-macos

| Step | Actual seconds | Result | Destination |
| --- | ---: | --- | --- |
| Set up job | 1 | success | Every-push CI (unchanged) |
| Run actions/checkout@v7.0.1 | 4 | success | Every-push CI (unchanged) |
| Run xcodebuild -version | 0 | success | Every-push CI (unchanged) |
| Run python3 configs/check_swift_toolchain.py | 9 | success | Every-push CI (unchanged) |
| Run python3 configs/restore_git_mtimes.py | 0 | success | Every-push CI (unchanged) |
| Restore both locked unit-test dependencies without adding a writer | 1 | success | Every-push CI (unchanged) |
| Run python3 configs/setup_local_project.py --scratch-path build/swiftpm --phase-report build/ci-verification/setup/phase.json | 37 | success | Every-push CI (unchanged) |
| Run python3 -B configs/run_python_workflow_tests.py --suite workflow | 62 | success | Every-push CI (unchanged) |
| Preserve Python per-case wall times | 1 | success | Every-push CI (unchanged) |
| Report whole-run wall time and enforce 300s budget | 2 | success | Every-push CI (unchanged) |
| Post Run actions/checkout@v7.0.1 | 1 | success | Every-push CI (unchanged) |
| Complete job | 1 | success | Every-push CI (unchanged) |

### app-macos

| Step | Actual seconds | Result | Destination |
| --- | ---: | --- | --- |
| Set up job | 3 | success | Every-push CI (unchanged) |
| Run actions/checkout@v7.0.1 | 2 | success | Every-push CI (unchanged) |
| Run xcodebuild -version | 1 | success | Every-push CI (unchanged) |
| Run python3 configs/check_swift_toolchain.py | 7 | success | Every-push CI (unchanged) |
| Run python3 configs/restore_git_mtimes.py | 0 | success | Every-push CI (unchanged) |
| Identify the Swift toolchain for the build cache | 1 | success | Every-push CI (unchanged) |
| Cache the locked SurfacePlugins checkout | 1 | success | Every-push CI (unchanged) |
| Restore the latest SwiftPM build | 12 | success | Every-push CI (unchanged) |
| Run python3 configs/setup_local_project.py --scratch-path build/swiftpm --phase-report build/ci-verification/setup/phase.json | 28 | success | Every-push CI (unchanged) |
| Compile native targets and tests | 132 | success | Every-push CI (unchanged) |
| Link every executable in the test build path | 4 | success | Every-push CI (unchanged) |
| Save compiled native cache even if later tests fail | 5 | success | Every-push CI (unchanged) |
| Require exact validation success before native execution | 1 | success | Every-push CI (unchanged) |
| Run swift test --build-path build/swiftpm --skip-build --manifest-cache local | 423 | success | Every-push CI minus the single complete proof method listed above |
| Exercise hardware service with isolated fake MIDI only | 3 | success | Every-push CI (unchanged) |
| Exercise immutable no-device diagnostics over real HTTP | 2 | success | Every-push CI (unchanged) |
| Exercise owned virtual transport (Debug; no physical endpoint discovery) | 3 | success | Every-push CI (unchanged) |
| Run python3 configs/macos_workflow.py build --manifest-cache local | 17 | success | Every-push CI (unchanged) |
| Isolated native startup | 4 | success | Every-push CI (unchanged) |
| Capture previews (manual desktop diagnostic) | 0 | skipped | Every-push CI (unchanged) |
| Preserve preview diagnostics | 0 | skipped | Every-push CI (unchanged) |
| Preserve Python per-case wall times | 2 | success | Every-push CI (unchanged) |
| Report whole-run wall time and enforce 300s budget | 1 | failure | Every-push CI (unchanged) |
| Post Cache the locked SurfacePlugins checkout | 0 | skipped | Every-push CI (unchanged) |
| Post Run actions/checkout@v7.0.1 | 1 | success | Every-push CI (unchanged) |
| Complete job | 0 | success | Every-push CI (unchanged) |

### preflight-macos

| Step | Actual seconds | Result | Destination |
| --- | ---: | --- | --- |
| Set up job | 4 | success | Every-push CI (unchanged) |
| Run actions/checkout@v7.0.1 | 9 | success | Every-push CI (unchanged) |
| Run xcodebuild -version | 1 | success | Every-push CI (unchanged) |
| Run python3 configs/check_swift_toolchain.py | 12 | success | Every-push CI (unchanged) |
| Run python3 configs/restore_git_mtimes.py | 0 | success | Every-push CI (unchanged) |
| Cache both locked validation dependencies | 1 | success | Every-push CI (unchanged) |
| Join complete lint and setup with fixed tool identity | 56 | success | Every-push CI (unchanged) |
| Run python3 configs/check_host_layers.py --scratch-path build/swiftpm | 17 | success | Every-push CI (unchanged) |
| Preserve complete preflight diagnostics | 3 | success | Every-push CI (unchanged) |
| Report whole-run wall time and enforce 300s budget | 1 | success | Every-push CI (unchanged) |
| Post Cache both locked validation dependencies | 2 | success | Every-push CI (unchanged) |
| Post Run actions/checkout@v7.0.1 | 1 | success | Every-push CI (unchanged) |
| Complete job | 0 | success | Every-push CI (unchanged) |

### core-linux

| Step | Actual seconds | Result | Destination |
| --- | ---: | --- | --- |
| Set up job | 1 | success | Every-push CI (unchanged) |
| Initialize containers | 28 | success | Every-push CI (unchanged) |
| Run actions/checkout@v7.0.1 | 3 | success | Every-push CI (unchanged) |
| Trust the checked-out workspace in the container | 0 | success | Every-push CI (unchanged) |
| Install workflow Python | 1 | success | Every-push CI (unchanged) |
| Run python3 --version | 0 | success | Every-push CI (unchanged) |
| Run swift --version | 0 | success | Every-push CI (unchanged) |
| Run python3 configs/restore_git_mtimes.py | 0 | success | Every-push CI (unchanged) |
| Identify the Swift toolchain for the build cache | 0 | success | Every-push CI (unchanged) |
| Cache the locked SurfacePlugins checkout | 1 | success | Every-push CI (unchanged) |
| Restore the latest SwiftPM build | 4 | success | Every-push CI (unchanged) |
| Run python3 configs/setup_local_project.py | 3 | success | Every-push CI (unchanged) |
| Run python3 configs/check_host_layers.py | 3 | success | Every-push CI (unchanged) |
| Run python3 -B configs/run_python_workflow_tests.py --suite workflow | 16 | success | Every-push CI (unchanged) |
| Compile portable targets and tests | 55 | success | Every-push CI (unchanged) |
| Save compiled portable cache even if later tests fail | 12 | success | Every-push CI (unchanged) |
| Run swift test --skip-build | 17 | success | Every-push CI (unchanged) |
| Build the standalone software simulator | 1 | success | Every-push CI (unchanged) |
| Exercise real loopback simulator processes | 34 | success | Every-push CI (unchanged) |
| Preserve Python per-case wall times | 2 | success | Every-push CI (unchanged) |
| Report whole-run wall time and enforce 300s budget | 1 | success | Every-push CI (unchanged) |
| Post Cache the locked SurfacePlugins checkout | 2 | success | Every-push CI (unchanged) |
| Post Install workflow Python | 0 | success | Every-push CI (unchanged) |
| Post Run actions/checkout@v7.0.1 | 0 | success | Every-push CI (unchanged) |
| Stop containers | 1 | success | Every-push CI (unchanged) |
| Complete job | 0 | success | Every-push CI (unchanged) |

## Audit evidence

Workspace evidence: `build/j-finish/c/baseline-run.json`, `baseline-run.log`, `baseline-swift-test-times.json`. The JSON ledger enumerates every Swift test timing printed by the original run; the original log also includes Python per-case output. Baseline tests ran 493 Swift Testing tests on macOS and 281 on Linux; XCTest bridge counts and existing platform/hardware skips retain their original scope.

| Evidence file | SHA-256 |
| --- | --- |
| `baseline-run.json` | `56e1e620c0a1b235dfa72c9626ee6cf201b40687f22be64cddee31d3d8538a12` |
| `baseline-run.log` | `9ced6be34bcd00cbc3aea5ef2e34ad69dae4649f0d63d110d0ba6785812cfa14` |
| `baseline-swift-test-times.json` | `de62616c68e861a7c899baafe0d03d863801878707073652d5848cffd042166e` |

## Explicit regression entry point

The normal native step is named “Run product regressions with the explicit regression-layer entry point” and sets `XTOUCH_CI_TEST_LAYER=regression`. Its custom Actions shell is `python3 configs/ci_swift_test_layer.py {0}`. The entry point accepts only the original complete `swift test --build-path build/swiftpm --skip-build --manifest-cache local` argv, prints the effective argv, appends the single approved `--skip` expression, and returns Swift's exit code. It cannot run arbitrary shell commands or silently accept a different layer. The original manifest-cache configuration assertion remains unchanged and still verifies that cache policy. The first direct-filter draft correctly failed that original exact-command assertion (239/240 passed); the approved explicit entry point preserves the original policy and passes its focused recheck.

Both workflows list the real compiled test inventory before executing tests and check that regression plus full proof has no intersection and equals the complete list. Local inventory has 509 declarations: 508 regression plus exactly one complete proof. This is an inventory count, not the Swift Testing-only count of 493 (the additional 16 are XCTest declarations).

The effective selection uses the unique complete-proof method name rather than a module-qualified expression: the latter matched the list representation but did not exclude the runtime method on local Swift 6.4.2. The real runtime probe exposed that mismatch; that first draft is not counted as a valid split. The inventory verifier requires exactly the one approved fully qualified method and fails if any future test contains the same selected name. The actual entry-point run verifies the final exclusion in real Swift output. Two pin acceptance/rejection recorded-session comparisons remain in the normal suite alongside all eight goldens and all applicable scenarios.

## Observed F-1 result before the GUI group

- `0b37ec6`: normal run `44136327783` failed in 198 seconds because the new configuration test file used default Ruff formatting instead of `configs/ruff.toml`; native execution was rejected by the unchanged preflight gate. Automatic complete proof `44136327776` succeeded in 708 seconds.
- The isolated formatting correction is `05dbee1`. Its normal run `44137169205` failed in **503 seconds**, including queue time. Preflight/workflow-unit budget gates failed; the native app validation gate refused subsequent native execution. This is not evidence that every native regression ran successfully.
- At the same `05dbee1`, automatic complete proof `44137169185` succeeded in 613 seconds; the required manual complete proof `44139723434` succeeded in 785 seconds. Both are inside the separate 30-minute limit.
- F-1 therefore remains blocked on the every-push 300-second requirement. No additional performance optimization cycle, retry of an old failed run, feedback cutover or delivery follows from these results. Final GUI-commit run evidence is recorded in the append-only workspace handoff, rather than creating a documentation-only CI loop.

## Native push critical path

Run `44145566868` spent 76.11 of 78 seconds in the app lane's extra `swift package dump-package`. The preflight lane continues to run full setup, manifest validation, lint, and the production layer check. The app lane verifies local inputs, evaluates the manifest through its own native build, and still requires the exact preflight run and attempt before executing tests or launching the app. Input preparation emits phase diagnostics and leaves the full setup marker absent.

The native smoke step signs and verifies the usual app bundle using the Debug executable linked in that same job. Cache upload follows native execution, so network transfer no longer delays reaching the validation gate. Cache upload still counts toward the whole-run budget. Linux, workflow-unit, the full proof, and release packaging keep their existing entry points.

Run `44216110509` completed the native checks and spent 14 seconds on a second Swift build invocation and 28 seconds saving a second cache for identical build inputs. A fresh test build was verified to link all four executables. The app lane now checks those exact executable paths, resolves the Swift cache identity from the same validated version output, and saves a new cache when no build cache was restored or when the restored commit's compile inputs differ. The original test inventory check and native regression command still run for every push.

The complete proof uses the standard arm64 macOS 26 runner pool with Xcode 26.6. At the `e1c76f7` baseline, all push checks kept their existing platform and architecture; the O-0 workflow-unit exception is recorded below. The proof cache remains separated by runner architecture. This gives the 30-minute proof and the 300-second push checks separate runner pools while preserving all original proof inputs, assertions, and triggers.

## O-0 runner allocation

Normal run `44219638795` at `e1c76f7c07b23e1d5f30ad2e44f2f5aeb5df076d` failed its unchanged 300-second budget after 379 seconds. The native app waited 105 seconds before starting and then ran for 273 seconds; preflight and the complete workflow-unit job occupied the same Intel pool. The workflow-unit job now uses the macOS 26 arm64 pool, with the same Xcode 26.6 and every original setup, test, artifact and budget command. Native application checks and preflight remain on Intel; the independent proof remains on arm64. All dependency cache keys distinguish architecture. This reduces normal-workflow Intel demand from three jobs to two without changing product sources, product or safety assertions, fixtures, or the deadline. The runner-configuration assertion is updated to require each job’s exact assigned runner. A fresh exact-SHA run determines acceptance; the measured queue and local checks do not predict success.

First-attempt normal run `44221249767` at `b68514fb1fd21c5dc93bc199c8a0b7f7c39d195e` failed after 358 seconds (02:10:09Z to 02:16:07Z). All functional checks succeeded; only the app budget failed. The app queue fell to four seconds, while its native regressions took 170 seconds, compile 50 seconds, validation wait 18 seconds, inventory 19 seconds, bundle 17 seconds, and startup five seconds. Same-SHA complete proof `44221249745` succeeded in 331 seconds. Neither run was cancelled or rerun.

O-0's second and final structural attempt places native push regressions on macOS 26 arm64 and the independent full proof on macOS 26 Intel. Workflow-unit stays on arm64 and preflight stays on Intel, so a simultaneous push plus proof requests two macOS jobs per architecture instead of three in one pool. All four lanes retain Xcode 26.6, all original commands, product and safety assertions, and their original 300-second or 30-minute deadlines. Native cache keys already distinguish architecture; no Intel build is reused as arm64. The configuration test requires the exact assigned runner for every normal job and the independent proof. The first attempt's final result and the new exact-SHA acceptance are recorded in the O-round workspace report.

## O-2 retirement and retained coverage

The retired comparisons were signed off through `c01e61f` with normal CI in
238 seconds and the complete proof in 452 seconds. The product workflow keeps
all applicable platforms and the existing 300-second budget. It continues to
run all 30 scenario declarations, 70 applicable operations and 78 fixture
assertions, all eight frozen X-Touch golden traces, and the direct ordinary and
owned hardware pin, order, no-early-commit and reentrant completion regressions.
The three explicitly inapplicable scenarios remain T05, T19 and T20. The full
scheduler proof uses the typed driver, 30 owners and original 8,965 scheduling
rows. It applies a separate value candidate to real input, then cold-replays
persisted inputs with the existing strict reader and lineage checks. The byte
comparison against the signed typed-owner artifacts retained every scheduler
record, catalog node, generation, and causal receipt, with 4,179 old
feedback-plan comparison rows removed from those 30 artifacts.

The exact Swift inventory changes from 532 to 524 methods. It retains the
scheduler proof and 523 product regressions. Eight methods served only the
retired J2/J3/J4 comparisons. The Python workflow inventory changes from 245 to
239 methods after removing six old Debug comparison probes.

| Path | Lines removed | Change and retained coverage |
| --- | ---: | --- |
| `.github/workflows/ci.yml` | 1 | Describe the scheduler-only split. Product runner assignments and budget remain. |
| `.github/workflows/full-proof.yml` | 4 | Run the independent scheduler proof over the full typed scenario set. Keep the dedicated runner, triggers and timeout. |
| `Sources/XTouchCompactApp/ConnectionContextReference.swift` | 8 | Delete old route-reference interface. The live neutral route identity remains. |
| `Sources/XTouchCompactApp/ConsoleModel.swift` | 80 | Remove old connection, copied-filter and receipt comparison hooks. Actual send ordering and scheduler ingress remain. |
| `Sources/XTouchCompactCore/CompactContextRuntime.swift` | 56 | Remove comparison rows and legacy resource/binding interfaces. The live scoped resource and binding key definitions remain. |
| `Sources/XTouchCompactCore/CompactFeedbackRuntime.swift` | 59 | Remove temporary stage/preflight/receipt comparison machinery. Live feedback proofs and scheduling inputs remain. |
| `Sources/XTouchCompactCore/CompactHardwareSurface.swift` | 30 | Remove Debug decode/re-encode comparison. Typed display plans and sender safety regressions remain. |
| `Sources/XTouchCompactCore/CompactSession.swift` | 16 | Remove retired reference storage and propagation. Keep scheduler dispatch, receipt and generation inputs. |
| `Sources/XTouchCompactCore/CompactState.swift` | 133 | Remove old shadow resource samples. Live resources, authorization and touch/layer safety remain. |
| `Sources/XTouchCompactCore/CompactSurfaceSimulator.swift` | 37 | Remove old comparison emissions and test-only context reference propagation. Keep ordered mock feedback and scheduler ingress. |
| `Sources/XTouchCompactCore/ParameterEngine.swift` | 21 | Remove lookup/generation comparison. Production binding resolution and direct generation/metadata tests remain. |
| `Tests/BuildWorkflowTests/test_ci_test_layers.py` | 1 | Update the near-matching test name with the new exact selector. The four partition/configuration checks remain. |
| `Tests/BuildWorkflowTests/test_context_shadow_gate.py` | 121 | Delete four tests of retired resource/route comparison and cached Debug mismatch trap. |
| `Tests/BuildWorkflowTests/test_feedback_shadow_gate.py` | 104 | Delete two tests of the retired feedback-plan comparison and its Debug mismatch trap. |
| `Tests/XTouchCompactAppTests/ContextReducerShadowTests.swift` | 74 | Remove old reference fixtures and recordings. Retain direct binding/resource/route/touch/reentrant publication and stale-authority checks. |
| `Tests/XTouchCompactAppTests/ControllerRegressionExecutorTests.swift` | 380 | Retire twin-owner replay and native assertion parser. Assert all 70 operations, 78 fixture expectations, 27 pass and exact 3 N/A directly in the retained product test. Retain one deterministic driver for complete independent scheduling replay. |
| `Tests/XTouchCompactAppTests/FeedbackRuntimeShadowTests.swift` | 11 | Remove retired trace-only assertions. Direct proof, receipt, causal, direction and pin/reentry checks remain. |
| `Tests/XTouchCompactAppTests/LegacyConnectionReference.swift` | 34 | Delete retired old route oracle and its history. |
| `Tests/XTouchCompactAppTests/LegacyContextReference.swift` | 252 | Delete retired old scoped resource and binding oracles and their history. |
| `Tests/XTouchCompactCoreTests/BehaviorTraceTests.swift` | 149 | Delete duplicate golden migration comparison and old snapshots. Keep all eight actual golden byte/typed-value comparisons and real scheduler ingress. |
| `Tests/XTouchCompactCoreTests/ContextReducerShadowTests.swift` | 46 | Remove old reference fixtures and recordings. Retain direct binding/resource/route/touch/reentrant publication and stale-authority checks. |
| `Tests/XTouchCompactCoreTests/FeedbackFirstStructureTests.swift` | 96 | Delete retired whole-artifact and older AST migration. Keep strict scalar/codec fixtures, bounded caches and scheduler trap. |
| `Tests/XTouchCompactCoreTests/FeedbackRuntimeShadowTests.swift` | 3 | Remove retired trace-only assertions. Direct proof, receipt, causal, direction and pin/reentry checks remain. |
| `Tests/XTouchCompactCoreTests/FeedbackTraceCatalogTests.swift` | 70 | Delete optional legacy persisted-artifact only comparison. Keep strict persisted input, duplicate, order, lineage and replay tests. |
| `Tests/XTouchCompactCoreTests/LegacyContextReference.swift` | 252 | Delete retired old scoped resource and binding oracles and their history. |
| `Tests/XTouchCompactCoreTests/LegacyPresentationTests.swift` | 105 | Delete four tests of retired old shadow renderer order, key fields, cached comparison, and bounds. Live exact payload tests remain. |
| `Tests/XTouchFeedbackTestSupport/FeedbackShadowReference.swift` | 17 | Remove retired strict-plan collector. Keep all scheduling input/receipt provenance, live computation and actual persisted cold replay. |
| `Tests/XTouchFeedbackTestSupport/FeedbackTraceStrictReader.swift` | 9 | Remove retired strict-plan record case. Keep definition, scheduler and actual native/candidate receipt rows. |
| `configs/ci_swift_test_layer.py` | 2 | Select the independent scheduler proof as the only excluded method, with exact inventory partition validation. |
| `docs/CONTROL_SURFACE_KIT.md` | 5 | Document actual retained scope and adopted feedback. |
