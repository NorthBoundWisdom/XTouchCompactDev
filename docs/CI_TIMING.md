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

Release packaging has two parallel explicit producers (ARM and Intel slices).
Both save successfully compiled caches before checks. Each slice carries the
clean source SHA, locked dependency SHA, architecture and every payload hash;
Intel also stages the generated icon in that hashed payload. ARM merges the two
verified artifacts and packages on its already-prepared runner, without another
compile or dependency acquisition. Both final assets still receive all existing
GUI/headless checks. The smoke matrix depends on the completed Intel producer,
prepares its ARM/Intel runners while ARM finishes packaging, and waits for this
attempt's final artifact. Independent ZIP and DMG checks run concurrently,
preserving every GUI/headless assertion and failure outcome.

Artifacts are selected only by exact names scoped to this run and attempt. The
ARM producer's late wait fails on producer failure or the original run's 300s
deadline. Consumers are gated by the completed Intel producer. Final
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

## Completed measurements

Completed run measurements (package code commit `43f36a8fb42442e1cd734dd18337b19165a2a2e7`):

| Workflow | Run | Created-to-completed seconds | Conclusion |
| --- | --- | ---: | --- |
| ci.yml | 43832670088 | 138 | success |
| ci.yml | 43834106784 | 128 | success |
| ci.yml | 43835346070 | 155 | success |
| package.yml cold | 43836094476 | 295 | success |
| package.yml warm | 43837079632 | 137 | success |

The three CI runs are consecutive and use the current CI workflow; their code
commits are ec64102, c84c7a3 and 43f36a8 respectively. Both package runs bind the
same final code commit 43f36a8. Cold restored no build key; warm restored both
slice keys. Every package run above executed all twelve extracted-payload
headless/GUI launches across assembly and the ARM/Intel smoke runners.
Cold has five seconds of measured headroom; queue and cleanup overruns still
fail the same budget. Earlier unsuccessful/cancelled measurements, per-job
and step durations, and raw API/log paths are retained in ALIGN_C.md. This
measurement note is a documentation-only follow-up to the tested code commit.
