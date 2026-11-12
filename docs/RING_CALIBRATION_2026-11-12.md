# Ring appearance calibration — 2026-11-12

The operator arranged the physical encoders, described their lit LEDs, and left
them in position. Values below were read through macOS accessibility from the
running physical console's Layer A values workspace. These are UI parameter
readings paired with operator reports, not camera measurements or LED readback.
The console was connected with writeback enabled. No firmware, device profile,
MIDI style selection or feedback address was changed for this calibration.

| Encoder | UI value | Operator-reported physical appearance | Panel segments |
| --- | ---: | --- | --- |
| E1 | 6 | First and second LEDs lit together | 1, 2 |
| E2 | 10 | First and second LEDs still lit; one further turn extinguishes the first | 1, 2 |
| E9 | 18 | Left half fully lit, right half off | 1–7 |
| E10 | 22 | One left LED extinguished | 2–7 |
| E11 | 32 | Two left LEDs extinguished | 3–7 |
| E12 | 43 | Three left LEDs extinguished | 4–7 |
| E13 | 64 | Center LED only; turning left adds a neighboring left LED | 7 |
| E15 | 127 | Right half fully lit | 7–13 |

Segments are numbered from bottom left clockwise to bottom right, with 7 at the
top center. “Left/right half fully lit” is drawn including the center LED. The
operator explicitly corrected the earlier all-off midpoint assumption: E13 could
not be set fully off. E14 was left untouched and supplies no calibration sample.

Top rings use a downward-quantized 25-state single/pair progression. It fits 6
and 10 as LEDs 1+2, with 11 drawn as LED 2; the last boundary is inferred from the
reported next turn, not a separately captured transition measurement.

Side rings interpolate the sampled positions, keeping the center LED on. The
lower 0–18 plateau, intermediate transition thresholds and unsampled right-side
positions remain approximations. Do not describe this curve as a verified
factory mapping, infer an RX channel from it, or use it to rewrite MIDI feedback.
Layer B, reverse-direction hysteresis, firmware version, exact LED counts in the
fully lit halves and the protocol style ID remain uncharacterized. The 13-LED
layout currently interprets a lit half as six side LEDs plus the center.

The renderer uses `EncoderPresentation.localRingAppearance`; `style` stays nil
unless the backend has a host-selected protocol style. Passive input observation
still does not synthesize LED state. Tests cover these samples, adjacent top
pairs, center persistence, contiguous side bars and monotonic travel.
