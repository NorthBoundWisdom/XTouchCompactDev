# Whole-run wall time and 300s budget

The direct user decision supersedes the earlier warm-only job budget. This host
matches BCR2000Dev origin/main at the start of C-15,
`9fc56ae57fe4883af3e0d883d71271cfea9ea0f3`: the **whole workflow run** must
finish within 300 seconds from creation, including queues, setup and post-job
cleanup. Cold and warm caches have the same limit, with no exemption.

Every job ends with **Report whole-run wall time and enforce 300s budget** under
`if: always()`. The standard-library reporter reads GitHub timestamps and writes
**Whole-run wall time and 300s budget**, policy, run/job/cache diagnostics and a
step/result/seconds table to GITHUB_STEP_SUMMARY. A live created-to-now duration
above 300 seconds fails that named step. CI_JOB_NAME selects matrix display names.
Final completed created-to-updated wall time must also be checked independently:
a job cannot observe its own post-job cleanup or other jobs' future completion.
The 20-minute hard timeout only guards hung jobs; it does not relax the budget.

A nonempty cache-matched-key (including prefix restores) means warm. Manual
`cold_build=true` skips project compilation cache restoration only; locked
SurfacePlugins acquisition is unchanged. Artifact-only smoke jobs report no
build cache. Timing output never contains GitHub credentials.

Compile all tests before running them; save the compiler cache immediately after
successful compilation even when subsequent tests fail. Packaging does the same
for release slices before assembling, signing and validating ZIP and DMG. Keep
all GUI/headless startup checks on both runner architectures. Offscreen native
acceptance remains local, outside CI. Record every cold/warm measurement and
three consecutive CI runs, including unsuccessful measurements, in ALIGN_C.md.

Release packaging has two parallel matrix producers (ARM and Intel slices).
Both save successfully compiled caches before checks. Each slice carries the
clean source SHA, locked dependency SHA, architecture and every payload hash;
Intel also stages the generated icon in that hashed payload. ARM merges the two
verified artifacts and packages on its already-prepared runner, without another
compile or dependency acquisition. Both final assets still receive all existing
GUI/headless checks, followed by the ARM and Intel smoke matrix.

Artifacts are selected only by exact names scoped to this run and attempt. The
ARM producer's late wait fails on producer failure or the original run's 300s
deadline. Consumers never reserve runners ahead of compile producers. Final
release binaries are also checked for Debug acceptance identifiers before bundle
assembly and again inside each extracted ZIP/DMG payload.

The earlier 336s serial cold measurement, 306s split-plus-assembly measurement,
and cancelled early-consumer experiment are retained in the handoff. Cancellation
followed observed runner starvation, not a replacement of an unsuccessful result.

## Python case evidence

`configs/run_python_workflow_tests.py --suite workflow|simulator [--pattern test_hardware_service.py]`
uses the BCR TimedResult shape: every case includes setUp/tearDown wall time in
`build/ci-verification/tests/python-*-case-times.json`, sorted descending;
`Slowest workflow cases:` prints the first twenty. Test failures retain a nonzero
exit and still write timing evidence. Both CI lanes upload the JSON even on
failure. Discovery and assertions remain unittest's own. Only three read/rejected
request cases share a daemon, guarded by a zero-sequence assertion after each.
Mutation, restart, generation, quotas and credentials retain isolated processes.

Audit: the sole Python HTTPServer bind in Tests/tools/Clients is
`Tests/H10Support/response_drop.py:64`. A read-only extracted-bind probe confirmed
it calls getfqdn. That file is explicitly reserved to the ongoing H round and is
unchanged here; H must apply BCR 9fc56ae's TCPServer.server_bind override and add
the DNS-denial test. No in-scope HTTP fixture had that defect. Real slow-reader
and lease deadlines remain measured against real sockets and process clocks;
their waits and safety bounds were preserved.

