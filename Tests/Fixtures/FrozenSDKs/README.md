# Frozen historical SDK fixtures

These exact historical SurfacePlugins SDK ZIPs are **test inputs only**. They are
not imported by the application, runtime package or current SDK delivery. They
retain the original single-module layout, version allowlists, ZIP timestamps and
permissions. `provenance.json` records each original host revision, shared source
revision and independently pinned archive SHA-256. The shared MIT license is here.

A normal Git checkout supplies both small archives without network access, cached
builds or old Git history. Integration tests verify the original hashes before a
fresh child interpreter imports exclusively from the archive; each genuine old
SDK must reject contract 1.3. Missing or altered fixtures fail instead of skipping.
No old SDK allowlist, current host version or test response is patched.

To independently reproduce a ZIP, read `clients/python/surface_control/__init__.py`
from the recorded SurfacePlugins commit and use the corresponding historical
host's `configs/package_surface_simulator.py` ZIP metadata (1980-01-01, deflate,
0644). Compare the original pinned SHA-256 before accepting any reconstructed file.
