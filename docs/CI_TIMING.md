# Job wall time and warm-cache budget

This host follows BCR2000Dev's committed `configs/ci_job_budget.py` policy from
`73a50eb6dc9d7745f397fecaa46198442cbae7ac`: same step name, summary heading,
step/result/seconds table and warm/cold decision. It is a standard-library-only
reporter, not a new runtime dependency. The one host adaptation is CI_JOB_NAME
for the package workflow's matrix names, which differ from GITHUB_JOB.

Every job ends with **Report wall time and enforce warm-cache 300s budget** under
`if: always()`. The reporter reads the current attempt's GitHub job timestamps,
measures started_at through the live report, writes GITHUB_STEP_SUMMARY and fails
that clearly named step only when a restored build key is nonempty and elapsed
job time exceeds 300 seconds. Run-creation/queue time is reported separately.
Cold bootstrap is measured and labelled, not hidden or killed by a five-minute
bootstrap timeout. Post-job cleanup is outside the live check, so completed job
and created→updated timings must still be checked independently afterward.

Warm means `actions/cache/restore` returned `cache-matched-key`, including a
usable prefix restore, not only an exact cache hit. Manual `cold_build=true`
skips restoring project compilation caches; dependency acquisition remains pinned.
Artifact-only package-smoke jobs have no compilation cache and report an empty
key rather than pretending a downloaded artifact was a warm build cache.

Linux/native CI builds all tests first, immediately saves a successful compilation
cache even if later tests fail, and runs stock SwiftPM tests with --skip-build.
Universal packaging restores a separate compiler cache, explicitly compiles the
two existing slice paths, saves after successful compilation, and invokes the
unchanged package command to assemble/sign/check the final assets. No packaging
or delivery implementation is changed. New UI acceptance scripts remain local and
are not CI steps. Time reports never contain the GitHub credential.
