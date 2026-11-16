# X-Touch display targets (simulation)

Generated from the default read-only discovery profile; no MIDI addresses are handwritten.
Profile: `xtouch.compact.standard.simulation` / `1.3`.
Faders are excluded from every panel catalogue. Hardware faders must declare no feedback kind.

Discovery gives stable IDs, feedback kinds and ranges. It does not report the current ring style
or physical qualification. The style/qualification notes below describe the existing host implementation;
they are not new contract fields or evidence of a physical device preset.

Encoder values are mapped to a position display in the existing simulator ring style.
The default visual renderer uses single-position when no style is present; discovery does not expose style.

| Stable ID | Kind | Allowed values | Current display style / knowledge | Default qualification |
|---|---|---|---|---|
| `a.encoder.1` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.2` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.3` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.4` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.5` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.6` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.7` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.8` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.9` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.10` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.11` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.12` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.13` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.14` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.15` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.encoder.16` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `a.button.1` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.2` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.3` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.4` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.5` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.6` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.7` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.8` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.9` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.10` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.11` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.12` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.13` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.14` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.15` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.16` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.17` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.18` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.19` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.20` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.21` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.22` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.23` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.24` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.25` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.26` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.27` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.28` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.29` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.30` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.31` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.32` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.33` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.34` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.35` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.36` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.37` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.38` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `a.button.39` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.encoder.1` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.2` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.3` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.4` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.5` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.6` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.7` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.8` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.9` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.10` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.11` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.12` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.13` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.14` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.15` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.encoder.16` | value | 0..127; step 1 | position in simulator style; default renderer single | simulation only |
| `b.button.1` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.2` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.3` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.4` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.5` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.6` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.7` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.8` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.9` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.10` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.11` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.12` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.13` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.14` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.15` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.16` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.17` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.18` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.19` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.20` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.21` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.22` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.23` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.24` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.25` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.26` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.27` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.28` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.29` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.30` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.31` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.32` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.33` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.34` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.35` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.36` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.37` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.38` | indicator | off / on / blink | off / steady / blinking | simulation only |
| `b.button.39` | indicator | off / on / blink | off / steady / blinking | simulation only |

Display controls: 110. This catalogue does not change profile eligibility or physical qualification.
