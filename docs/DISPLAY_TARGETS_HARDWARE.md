# X-Touch display targets (hardware)

Generated from the default read-only discovery profile; no MIDI addresses are handwritten.
Profile: `xtouch.compact.standard.hardware` / `1.4`.
Faders are excluded from every panel catalogue. Hardware faders must declare no feedback kind.

Discovery gives stable IDs, feedback kinds and ranges. It does not report the current ring style
or physical qualification. The style/qualification notes below describe the existing host implementation;
they are not new contract fields or evidence of a physical device preset.

Each encoder value request already sends a single-style declaration before its ring value.
This predates H; the physical preset is unread and has not been checked in attended acceptance.
This is an implementation gap against preserving an unknown current preset, not permission to change it.
Values: 0 off; 1–13 position; 14–26 blinking position; 27 all on; 28 all blinking.
A/B targets share physical output addresses: matching layer input evidence is required; remote cannot select a layer.

| Stable ID | Kind | Allowed values | Current display style / knowledge | Default qualification |
|---|---|---|---|---|
| `a.encoder.1` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.2` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.3` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.4` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.5` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.6` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.7` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.8` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.9` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.10` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.11` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.12` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.13` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.14` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.15` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.encoder.16` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `a.button.1` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.2` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.3` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.4` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.5` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.6` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.7` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.8` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.9` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.10` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.11` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.12` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.13` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.14` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.15` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.16` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.17` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.18` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.19` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.20` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.21` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.22` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.23` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.24` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.25` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.26` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.27` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.28` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.29` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.30` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.31` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.32` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.33` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.34` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.35` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.36` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.37` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.38` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `a.button.39` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.encoder.1` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.2` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.3` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.4` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.5` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.6` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.7` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.8` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.9` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.10` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.11` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.12` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.13` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.14` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.15` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.encoder.16` | value | 0..28; step 1 | single declared by service; physical preset unknown | software only; attended physical acceptance pending |
| `b.button.1` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.2` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.3` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.4` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.5` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.6` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.7` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.8` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.9` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.10` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.11` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.12` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.13` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.14` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.15` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.16` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.17` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.18` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.19` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.20` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.21` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.22` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.23` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.24` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.25` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.26` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.27` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.28` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.29` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.30` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.31` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.32` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.33` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.34` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.35` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.36` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.37` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.38` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |
| `b.button.39` | indicator | off / on / blink | off / steady / blinking | software only; attended physical acceptance pending |

Display controls: 110. This catalogue does not change profile eligibility or physical qualification.
