# Frozen Mock capture interchange

`xtouch-sample.jsonl` is the actual XTouch recorder output frozen in commit
`edcc120f74cb597dd4b6dcad3f3a524974a3ed40`; the current recorder test compares exact bytes.

`bcr-sample.jsonl` is copied byte-for-byte from BCR2000Dev commit
`2fdd1ca5fee8cdd239833a06e39554e61e901bfb`, path `Tests/Fixtures/Capture/bcr-sample.jsonl`.
SHA-256: `23f9a2ae214e1c6ba95bf5651efa1ebc0770d9a684409db3097a9ac712a07910`. The original BCR recorder test covers its own writer.
This replaces the explicitly labelled handwritten placeholder; no format field or
meaning is changed on the XTouch side. `provenance.json` pins the copied bytes/count.
Both are synthetic Mock data, not physical-device captures or hardware qualification.
No host source/runtime dependency is introduced.
