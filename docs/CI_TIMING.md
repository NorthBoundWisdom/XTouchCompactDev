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
