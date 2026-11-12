# Surface Control Python client

This stdlib-only `surface_control` package is the same public client as the BCR
software Surface delivery. It does not import Provider 1.0 or host source. Use it
with either explicitly pinned simulation endpoint, profile version 1.0, and MCP
2025-11-25 (default) or 2026-07-28. Neither protocol retries mutations.

```python
from surface_control import Client, CommandCursor

client = Client(url, token, instance_id="car.a")
cursor = CommandCursor(client, {name: "simulation." + name
    for name in ("arm", "start", "pause", "cancel")})
initial_values = cursor.bootstrap()  # state only; never an operation
samples = cursor.poll()             # only subsequent accepted fresh edges
for sample in samples:
    cursor.verify(sample)           # immediately before choosing a business operation
```

Set `PYTHONPATH=Clients/Python` in a source checkout, or import the packaged module
alongside the delivery's example. Discovery validates source, instance/profile,
identity, and exact control shape. CAS is never silently refreshed to replay an
uncertain operation. Context changes, unknown responses, gaps, and stale input
invalidate the cursor; recovery requires explicit preparation by the consumer.
A production operator bridge must continue to reject simulation input.

Run unit tests with `PYTHONPATH=Clients/Python python3 -m unittest discover -s Clients/Python/tests -v`.
Real HTTP/process checks live in `Tests/SimulatorIntegration`.
