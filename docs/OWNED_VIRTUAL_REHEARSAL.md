# Owned virtual rehearsal

This explicit Release hardware-service mode connects only to the source and display
destination created by this process. It does not enumerate or select physical endpoints.
Discovery uses `xtouch.compact.owned-virtual-rehearsal` / 1.5 and
`session.owned_virtual_rehearsal`; ready and audit records say
`owned_virtual_rehearsal=true`, `physical_evidence=false`. It is never hardware qualification.

A trusted launcher passes a separate anonymous FIFO using `--owned-virtual-steps-fd FD`
and sends the credential on the existing stdin pipe. Start with:

```
XTouchSurfaceHardware --owned-virtual-rehearsal --owned-virtual-steps-fd FD \
  --receive-channel 1 --light-protocol observed114 --token-stdin \
  --allow-surface-feedback --surface-instance-id owned.example
```

`FD` denotes an actual inherited FIFO descriptor, not a file or an RPC method. The mode
rejects explicit `--device`, `--device-access`, and all Debug test-injection environment
variables. Retention is independent: add `--surface-input-event-capacity N` explicitly
when required. Without this mode, ordinary and disabled behavior is unchanged.

Wait for ready before sending a strict JSON line on the private pipe. Allowed operations
are `input`, `disconnect`, `reconnect`, `finish`; there is no endpoint ref, raw output,
preset or permission field. For an input, provide `control_id`, its scalar/boolean `value`,
and canonical decimal `connection_generation` from the owned origin record. Addresses
are derived from the factory map, never supplied by the launcher. New connection origin
records appear in stderr after reconnect. Do not infer generation by counting commands.

Each line is bounded at 4096 bytes, buffering at 65536 bytes and each drain at 64 commands.
Input publication reserves a bounded ticket before CoreMIDI; callback and owner handoff
keep the ticket charged until canonical consumption/rejection. Display receipts have a
separate bound and never become input. Malformed/overflow/stale-generation/IO failures
are visible and terminate after owned cleanup; never retry an uncertain command.

Start, reconnect and cleanup send no display messages. Reconnect clears observations;
feedback requires fresh input evidence for the layer and the original display permission.
The hardware output type still cannot express motors or Program Change. Signal handlers
retain the async-safe ready-inode cleanup; CoreMIDI disposes clients on process exit.
A signal result reports the last visible counters and the zero-send cleanup path, not a
fabricated final Swift counter or a claim that deinit ran.

For the SDK display demo, keep the shared bundled mapping unchanged. Generate a local
mapping from this mode's describe output and the verified delivery SDK:

```
python3 generate_owned_virtual_mapping.py --delivery DELIVERY \
  --contract OWNED-DESCRIBE.json --output OWNED-MAPPING.json
```

Pass that explicit mapping path to `python3 -m surface_panel_demo --mapping PATH`, with
`--source hardware` and a private token FD. It changes display intent only. The synthetic
actual data and this rehearsal are software evidence; no physical device is qualified.
