# X-Touch display budget (H-2)

These are software measurements of Debug real HTTP processes with local scripted MIDI only.
The reliable USB MIDI delivery ceiling of a real X-Touch is **unknown; needs attended hardware measurement**.
No physical device, preset, mapping or qualification was changed.

## Existing explicit configuration

Default remains one process-wide aggregate budget of 60 successful mutation requests per one-second window.
For a panel use the existing explicit option (no new flag or default change):

```sh
--write-limits input=60,feedback=300,renew=60,admin=10
```

Each category accepts 1..10000 requests/window; all four must be supplied. It is mutually exclusive with
`--write-limit`. The explicit mode advertises existing `writes.independent_limits`; ordinary default
simulation discovery remains unchanged. In the original three-role credential mode each category is
shared across clients; this is category isolation, not independent writer quotas.

Use 5Hz initially; up to 24 targets at 10Hz (240 feedback requests/s) was accepted with feedback=300.
Physical delivery and visible smoothness remain unqualified. One ring value requires two display MIDI
messages (existing single-style declaration then display); one button indicator requires one.
This test used up to 16 rings, then 8 buttons, therefore 24 targets at 10Hz means 400 MIDI messages/s.

## Six sustained conditions, each 60 seconds

Each phase ran six independent host processes concurrently, one display credential per host.
The companion input producer supplied 10Hz local physical-input script events; a separate operator
reader polled the unified journal every 50ms with limit=1024. No remote input RPC was used.
All 12 conditions read 600/600 generated inputs, in order, with no continuous-reader event gap.

| Mode | Targets | Hz | Accepted | Rate limited | Coalesced | Fake MIDI messages | Request→fake receipt p50/p95/p99/max ms | Input generation→read p99/max ms |
|---|---:|---:|---:|---:|---:|---:|---|---|
| default60 | 8 | 5 | 2400 | 0 | 0 | 4800 | 1.402/2.435/20.954/46.381 | 83.140/120.195 |
| default60 | 8 | 10 | 3553 | 1247 | 0 | 7106 | 1.227/2.203/15.563/57.264 | 78.982/122.873 |
| default60 | 16 | 5 | 3540 | 1260 | 0 | 7080 | 1.265/2.169/6.831/68.660 | 84.794/92.455 |
| default60 | 16 | 10 | 3600 | 6000 | 0 | 7200 | 1.127/2.078/6.675/57.517 | 86.367/120.782 |
| default60 | 24 | 5 | 3540 | 3660 | 0 | 6064 | 1.108/2.073/3.731/48.280 | 85.466/147.491 |
| default60 | 24 | 10 | 3600 | 10800 | 0 | 6196 | 1.032/1.953/5.106/55.984 | 79.159/123.104 |
| feedback300 | 8 | 5 | 2400 | 0 | 0 | 4800 | 1.520/2.706/26.187/61.922 | 80.416/130.846 |
| feedback300 | 8 | 10 | 4800 | 0 | 0 | 9600 | 1.342/2.426/21.842/75.750 | 82.659/131.574 |
| feedback300 | 16 | 5 | 4800 | 0 | 0 | 9600 | 1.357/2.304/8.787/63.102 | 80.204/127.619 |
| feedback300 | 16 | 10 | 9600 | 0 | 0 | 19200 | 1.214/2.179/7.715/75.416 | 89.693/131.219 |
| feedback300 | 24 | 5 | 7200 | 0 | 0 | 12000 | 1.228/2.163/4.880/76.001 | 83.999/128.124 |
| feedback300 | 24 | 10 | 14400 | 0 | 0 | 24000 | 1.132/2.067/4.126/72.628 | 93.055/128.214 |

Input-only companion baseline: p50/p95/p99/max 26.983/52.863/63.739/80.441ms (600/600 inputs).
With configured display load the largest input p99 was 93.055ms: 29.315ms above the 63.739ms baseline.
Input was measurably slower, although no input was lost and no reader gap occurred. These concurrent
same-machine runs include OS scheduling, Python HTTP and JSON input-script I/O; they are not isolated
device or hard real-time guarantees.

Coalesced=0: this hardware service synchronously validates and sends each accepted request, with no
asynchronous display queue to accumulate stale pending values. The feedback snapshot retains only
the latest value per target; old feedback events remain historical journal entries. Offline verification
checked every accepted typed plan, payload value, kind, target index and consecutive send_index against
the receipt stream, and checked final snapshot values against each target’s last accepted request.
No packet loss or reordering was observed in the fake transport. That is not real USB delivery evidence.

## Journal and observation overhead

The existing unified FIFO journal has capacity 1024. Every accepted feedback is an event; ignored
feedback is also an event under the shared contract. Display traffic can evict an unread old input.
The measured long-running reader kept up for all 60s windows despite multiple full buffer rotations.
A deliberately stale cursor=0 returned existing `event_gap` in every condition. The semantics were not changed.
At 240 feedback plus 10 input events/s the nominal retention is about 4.096s. Poll at least every 100ms,
drain all available pages, and fail closed/reprepare on any gap; do not resume from a guessed cursor.
There is no startup event-capacity option today. No filtering, event dropping or special feedback journal was added.

Timing uses an optional Debug-only local JSONL receipt sink. The original full-array fake report was
disabled during measurement to avoid its growing rewrite cost. Python and Swift monotonic clock domains
were checked against a bounded request/response sample for each host. The capture itself serializes/writes
one JSON line per fake message and can affect latency. A separate 10s, 24-target/10Hz single-host timing
control is recorded below; these sequential samples include scheduling noise and do not establish causal overhead.

| Recorder control | Feedback RPC p50/p95/p99/max ms | Inputs read |
|---|---|---:|
| timing-control | 1.010/1.543/2.780/36.475 | 100 |
| no-timing-control | 1.153/1.690/3.963/28.513 | 100 |

## Reproduce and prepare attended measurement

From a development checkout with a Debug hardware binary:

```sh
python3 configs/measure_display_budget.py --binary build/swiftpm/debug/XTouchSurfaceHardware --output build/h/h2/default60 --configuration default
python3 configs/measure_display_budget.py --binary build/swiftpm/debug/XTouchSurfaceHardware --output build/h/h2/feedback300-60 --configuration feedback300
```

Use new output paths: the timing sink refuses to overwrite evidence. Raw request, input-generation,
event-page and fake-receipt JSONL files plus summaries remain under `build/h/h2/`.
No credentials are recorded. The measurement tool forces a local scripted Debug adapter and refuses
a host that is not explicitly marked test_only; it cannot measure an actual device.

`python3 configs/hardware_attended.py prepare` preserves the original nine-step checklist and also
writes `build/e/xtouch-panel-attended.json` and `.md`; its H-C-BUDGET phase requires a user at the
device, fresh confirmation for each bounded send stage, and independent receipt/visible evidence.
It is prepared only, has no automatic real-device command, and has not been executed.
