# Neutral chassis simulation parameter set

Start the standalone simulator with `--simulation-configuration examples/chassis.json`.
Use `--describe` with the same option to inspect its exact profile and mapping revision.
The default demonstration configuration remains unchanged when the option is omitted.
This file uses the host's version 1 SurfaceConfiguration JSON; version 2 unprotected
parameters are also supported. Unknown fields, invalid or duplicate bindings, actions,
read-only parameters and externally protected parameters are refused before startup.

| Role | Control | Parameter | Input / display |
| --- | --- | --- | --- |
| Enable | a.touch.1 | simulation.enable | boolean, momentary; hold rest=false, max 10s |
| Linear axis | a.fader.1 | simulation.linear | scalar 0..127, value display |
| Steering axis | a.encoder.9 | simulation.steer | scalar 0..127, value display |
| Stop | a.button.3 | simulation.stop | boolean, toggle on press |
| Speed display | a.encoder.10 | simulation.speed_feedback | scalar 0..127, value display |
| Steering display | a.encoder.11 | simulation.steer_feedback | scalar 0..127, value display |
| Stopped display | a.button.4 | simulation.stopped_feedback | boolean, indicator display |

All seven controls have parameter mappings and accept input. Displays remain independent
feedback intent and never write parameter values or create an input. The consumer assigns
business meaning and must verify that the device actually stops; these are simulated inputs.

In this standalone simulation only, a parameter-bound fader touch writes the parameter's
maximum while touched and its minimum on release or lease expiry. Expiry restores the
original layer's binding even after a layer switch. This adapter preserves the Mock/session
motor-touch safety state. Hardware parameter buttons retain their existing toggle behavior.
Other parameter-bound buttons in this configuration also toggle and declare no hold.
An unbound touch only controls simulated motor-touch protection, as in the default profile.
