# Shared business plugins

SurfacePlugins is the sole authorized shared business-logic dependency. The two
controller hosts have no source dependency on each other. The committed
`configs/surface_plugins.lock.json` fixes the remote URL and exact Git commit.
SwiftPM only consumes the clean detached checkout at
`build/dependencies/SurfacePlugins`; it never selects a sibling working tree.

Prepare the dependency before direct Swift commands:

```sh
python3 configs/surface_plugins_dependency.py ensure
swift test --build-path build/swiftpm --jobs 2
```

The normal setup/build/test/package workflow calls the same manager after loading
ignored `build.local.json`. It uses Python's standard library and Git, with no
FreeCM runtime or checkout dependency. A direct Swift invocation performs a
read-only cache verification and refuses dirty or incorrectly pinned sources.

Until the locked commit has been published, use an existing local Git repository
as the acquisition source:

```sh
SURFACE_PLUGINS_SOURCE=../SurfacePlugins python3 configs/surface_plugins_dependency.py ensure
```

This fetches the **committed locked SHA**, including when that repository's HEAD
has moved or its working files are dirty. It never compiles those working files.
`SURFACE_PLUGINS_PATH` is a legacy acquisition alias; conflicting aliases fail.
A missing commit, unavailable remote, unmanaged cache, dirty cache, or incorrect
revision fails visibly. An intentional lock upgrade uses `update` explicitly;
it replaces only a clean checkout previously owned by this manager.

Saved X-TOUCH COMPACT version-1 parameter files retain `isSwitch`, numeric `step`
(including zero), and explicit `defaultValue`. The configuration adapter translates
these to shared parameter metadata. Clamping uses a zero-anchored grid including
both endpoints and chooses the lower candidate on ties. Seven-bit projection and
13-segment ring rendering stay device-specific.


The Agent composition uses shared `AgentPlugin` and `AgentRemoteBinding` behind
one value registry. Local hardware and interface origins retain approval rights;
remote input cannot approve itself. Seven-phase presentation and button-light
rendering remain host adapters: active is on, attention blinks, every other
semantic is off. Only the default Agent instance is bound to the saved device
assignments. Additional instances retain independent state without overriding
those lights. Registration validates the complete candidate batch before start.

Plugin updates, startup, reconfiguration, layer selection and reconnection never
recall faders. Touch protection remains at the final motor-send boundary. None of
the software checks qualifies physical firmware behavior or completes a hardware
bring-up checklist.


Optional robot/chassis/output bindings share the same registry and epoch as Agent.
The simulations each receive a fresh host lifetime ID. Explicit launch flags and
the reference-arm example are described in [software workflows](SOFTWARE_WORKFLOWS.md).
The output module's stricter fresh-actual/independent-heartbeat requirement applies
to the existing OSC settings too; no private scalar safety implementation remains.
The compatibility scalar API forwards every decision to the shared gate.

Protected examples use configuration version 2. Old version-1 files keep their
original fields; ordinary exports do not add the optional protection field.
Version 1 with a protection field is rejected. This version fence prevents older
applications from ignoring a new protection flag and weakening write policy.
