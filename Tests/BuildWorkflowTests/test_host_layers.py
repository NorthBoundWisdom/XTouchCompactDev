"""Exercise illegal real Swift declaration/import directions in isolated source fixtures."""

import json
import subprocess
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path

from configs.check_host_layers import check_tree, swift_code

ROOT = Path(__file__).resolve().parents[2]


@contextmanager
def fixture(files, constructors=None):
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        roles = {}
        targets = {path.split("/")[1] for path in files}
        for path, (role, code) in files.items():
            destination = root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(code)
            roles[path] = role
        manifest = {
            "schema_version": 1,
            "files": roles,
            "targets": {target: {"dependencies": sorted(targets - {target})} for target in targets},
            "validated_runtime_constructors": constructors or {},
        }
        yield root, manifest


class HostLayerTests(unittest.TestCase):
    def test_actual_tree_classifies_every_production_file_and_has_no_reverse_edges(self):
        manifest = json.loads((ROOT / "configs/host_layers.json").read_text())
        package = json.loads(subprocess.check_output(["swift", "package", "dump-package"], cwd=ROOT))
        report = check_tree(ROOT, manifest, package)
        self.assertEqual(report["errors"], [])
        self.assertTrue(all(report["roles"][role] > 0 for role in ("runtime", "bridge", "device", "transport")))

    def test_runtime_cannot_reference_transport_declarations_across_nested_files(self):
        with fixture(
            {
                "Sources/Host/Runtime.swift": ("runtime", "struct Runtime { var bad: TransportThing? }"),
                "Sources/Host/nested/Transport.swift": ("transport", "struct TransportThing {}"),
            }
        ) as (root, manifest):
            self.assertTrue(any("TransportThing" in error for error in check_tree(root, manifest)["errors"]))

    def test_mock_device_cannot_call_a_bridge_static_helper(self):
        with fixture(
            {
                "Sources/Host/Mock.swift": ("device", "struct Mock { func f() { Bridge.segment() } }"),
                "Sources/Host/Bridge.swift": ("bridge", "struct Bridge { static func segment() {} }"),
            }
        ) as (root, manifest):
            self.assertTrue(any("Bridge" in error for error in check_tree(root, manifest)["errors"]))

    def test_qualified_cross_module_reference_is_checked_in_its_actual_file_role(self):
        with fixture(
            {
                "Sources/Runtime/Runtime.swift": (
                    "runtime",
                    "import Transport\nstruct Runtime { var bad: Transport.Wire? }",
                ),
                "Sources/Transport/Wire.swift": ("transport", "struct Wire {}"),
            }
        ) as (root, manifest):
            self.assertTrue(any("[Wire]" in error for error in check_tree(root, manifest)["errors"]))

    def test_extension_body_cannot_reach_a_forbidden_transport_type(self):
        with fixture(
            {
                "Sources/Host/Runtime.swift": ("runtime", "struct Runtime {}"),
                "Sources/Host/Extension.swift": ("runtime", "extension Runtime { var bad: Wire? { nil } }"),
                "Sources/Host/Wire.swift": ("transport", "struct Wire {}"),
            }
        ) as (root, manifest):
            self.assertTrue(
                any("Extension.swift" in error and "Wire" in error for error in check_tree(root, manifest)["errors"])
            )

    def test_instance_extension_member_edges_do_not_hide_behind_a_value_type(self):
        with fixture(
            {
                "Sources/Host/Values.swift": ("values", "struct Config {}"),
                "Sources/Host/Device.swift": ("device", "extension Config { func validate() {} }"),
                "Sources/Host/Runtime.swift": (
                    "runtime",
                    "struct Runtime { var config: Config; func f() { config.validate() } }",
                ),
            }
        ) as (root, manifest):
            self.assertTrue(any("Config.validate" in error for error in check_tree(root, manifest)["errors"]))

    def test_static_extension_member_edges_do_not_hide_behind_a_value_type(self):
        with fixture(
            {
                "Sources/Host/Values.swift": ("values", "struct Config {}"),
                "Sources/Host/Device.swift": (
                    "device",
                    "extension Config { static func configured() -> Config { Config() } }",
                ),
                "Sources/Host/Runtime.swift": ("runtime", "struct Runtime { var config = Config.configured() }"),
            }
        ) as (root, manifest):
            self.assertTrue(any("Config.configured" in error for error in check_tree(root, manifest)["errors"]))

    def test_attribute_access_and_qualified_imports_cannot_hide_platform_dependencies(self):
        for spelling in (
            "    import CoreMIDI",
            "@preconcurrency import CoreMIDI",
            "public import struct CoreMIDI.MIDIEventList",
        ):
            with (
                self.subTest(spelling=spelling),
                fixture({"Sources/Host/Runtime.swift": ("runtime", spelling)}) as (root, manifest),
            ):
                self.assertTrue(any("CoreMIDI" in error for error in check_tree(root, manifest)["errors"]))

    def test_comment_and_raw_literal_text_are_ignored_but_interpolation_is_code(self):
        harmless = 'struct Runtime { let label = #"Wire()"# }\n/* nested /* Wire */ Wire */ // Wire'
        with fixture(
            {
                "Sources/Host/Runtime.swift": ("runtime", harmless),
                "Sources/Host/Wire.swift": ("transport", "struct Wire {}"),
            }
        ) as (root, manifest):
            self.assertEqual(check_tree(root, manifest)["errors"], [])
            (root / "Sources/Host/Runtime.swift").write_text('struct Runtime { let label = "value \\(Wire())" }')
            self.assertTrue(any("Wire" in error for error in check_tree(root, manifest)["errors"]))
        self.assertNotIn("Wire", swift_code('let value = """Wire"""'))

    def test_unimported_same_name_nested_types_are_not_fabricated_dependencies(self):
        with fixture(
            {
                "Sources/Runtime/Runtime.swift": ("runtime", "struct Runtime { enum Invalid {} ; var item: Invalid? }"),
                "Sources/Transport/Wire.swift": ("transport", "struct Wire { enum Invalid {} }"),
            }
        ) as (root, manifest):
            self.assertEqual(check_tree(root, manifest)["errors"], [])

    def test_transport_may_use_localized_data_but_not_resource_rendering(self):
        files = {
            "Sources/Transport/Wire.swift": ("transport", "import Localization\nstruct Wire { var message: Message? }"),
            "Sources/Localization/Values.swift": ("values", "struct Message {}"),
            "Sources/Localization/Rendering.swift": ("composition", "struct Localizer { func render() {} }"),
        }
        with fixture(files) as (root, manifest):
            self.assertEqual(check_tree(root, manifest)["errors"], [])
            (root / "Sources/Transport/Wire.swift").write_text(
                "import Localization\nstruct Wire { var renderer: Localizer? }"
            )
            self.assertTrue(any("Localizer" in error for error in check_tree(root, manifest)["errors"]))

    def test_unclassified_sources_targets_and_unapproved_module_dependencies_fail(self):
        with fixture({"Sources/Host/Runtime.swift": ("runtime", "struct Runtime {}")}) as (root, manifest):
            (root / "Sources/Host/Added.swift").write_text("struct Added {}")
            package = {
                "targets": [
                    {"name": "Host", "type": "regular", "dependencies": [{"byName": ["Outer", None]}]},
                    {"name": "Unclassified", "type": "regular", "dependencies": []},
                ]
            }
            errors = check_tree(root, manifest, package)["errors"]
            self.assertTrue(any("Unclassified production file" in error for error in errors))
            self.assertTrue(any("Unclassified production module" in error for error in errors))
            self.assertTrue(any("Forbidden module dependencies" in error for error in errors))

    def test_runtime_must_use_the_validated_value_constructor_not_bridge_convenience(self):
        files = {
            "Sources/Host/Values.swift": ("values", "struct Config {}"),
            "Sources/Host/Engine.swift": ("runtime", "struct Engine { init(validatedConfiguration: Config) {} }"),
            "Sources/Host/Adapter.swift": (
                "bridge",
                "extension Engine { init(configuration: Config) { self.init(validatedConfiguration: configuration) } }",
            ),
            "Sources/Host/Runtime.swift": ("runtime", "let engine = Engine(configuration: Config())"),
        }
        with fixture(files, constructors={"Engine": "validatedConfiguration"}) as (root, manifest):
            self.assertTrue(any("bypasses validated" in error for error in check_tree(root, manifest)["errors"]))
            (root / "Sources/Host/Runtime.swift").write_text("let engine = Engine(validatedConfiguration: Config())")
            self.assertEqual(check_tree(root, manifest)["errors"], [])
