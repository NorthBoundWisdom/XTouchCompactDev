# Surface Control Python client

This repository no longer keeps its own copy of the Python SDK. The single source is the
shared SurfacePlugins package at the revision pinned in
[`configs/surface_plugins.lock.json`](../../configs/surface_plugins.lock.json):

- SDK 1.1.0: `clients/python/surface_control/__init__.py` (standard library only, contracts
  1.0 and 1.1, no profile names or business roles built in);
- its unit tests: `clients/python/tests/`;
- the Pipe taskless-trial integration example: `integrations/pipe/` (never part of a generic
  delivery).

In a checkout, the managed dependency is materialized at `build/dependencies/SurfacePlugins`
(`python3 configs/surface_plugins_dependency.py ensure`). Use it with
`PYTHONPATH=build/dependencies/SurfacePlugins/clients/python` and
`PYTHONDONTWRITEBYTECODE=1`, as `Tests/SimulatorIntegration` does: the dependency manager
treats any extra file in the managed cache (including `__pycache__`) as a dirty cache. A simulator delivery contains the same SDK as
`surface-control-sdk-1.1.0.zip`, with every file hash in `manifest.json`.

[`examples/surface_roundtrip.py`](examples/surface_roundtrip.py) is a generic consumer that
imports the SDK only from a pinned delivery zip after checking the manifest pin and file hashes.
Writes are explicit and never retried; a lost response is an unknown outcome.
A production operator bridge must continue to reject simulation input.
