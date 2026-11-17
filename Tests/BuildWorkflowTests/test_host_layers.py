"""Exercise illegal real Swift declaration/import directions in isolated source fixtures."""

import json
import subprocess
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

from configs.check_host_layers import PURE_IMPORTS, check_tree, swift_code

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

    def test_shared_test_support_cannot_become_runtime_or_an_app_cycle(self):
        with fixture({"Sources/Host/Runtime.swift": ("composition", "struct Runtime {}")}) as (root, manifest):
            support = {
                "name": "XTouchFeedbackTestSupport",
                "type": "regular",
                "path": "Tests/XTouchFeedbackTestSupport",
                "dependencies": [
                    {"byName": [name, None]}
                    for name in (
                        "XTouchCompactCore",
                        "SurfaceFeedbackPlanning",
                        "SurfaceDeviceContracts",
                        "SurfaceDeviceConformance",
                    )
                ],
            }
            support["settings"] = [
                {
                    "condition": {"config": "debug", "platformNames": []},
                    "kind": {"unsafeFlags": {"_0": ["-O", "-assert-config", "Debug"]}},
                    "tool": "swift",
                }
            ]
            package = {"targets": [support, {"name": "Host", "type": "regular", "dependencies": []}], "products": []}
            self.assertEqual(check_tree(root, manifest, package)["errors"], [])
            for flags, config in [
                (["-Ounchecked"], "debug"),
                (["-O"], "debug"),
                (["-O", "-assert-config", "Release"], "debug"),
                (["-O", "-assert-config", "Debug"], "release"),
            ]:
                original = support["settings"]
                support["settings"] = [
                    {
                        "condition": {"config": config, "platformNames": []},
                        "kind": {"unsafeFlags": {"_0": flags}},
                        "tool": "swift",
                    }
                ]
                self.assertTrue(any("assertion-preserving" in e for e in check_tree(root, manifest, package)["errors"]))
                support["settings"] = original
            package["targets"][1]["settings"] = support["settings"]
            self.assertTrue(any("optimization escaped" in e for e in check_tree(root, manifest, package)["errors"]))
            package["targets"][1].pop("settings")
            package["targets"][1]["dependencies"] = [{"byName": ["XTouchFeedbackTestSupport", None]}]
            self.assertTrue(
                any(
                    "Test-support module in production target" in e
                    for e in check_tree(root, manifest, package)["errors"]
                )
            )
            package["targets"][1]["dependencies"] = []
            package["products"] = [{"name": "RuntimeLeak", "targets": ["XTouchFeedbackTestSupport"]}]
            self.assertTrue(any("exposed as product" in e for e in check_tree(root, manifest, package)["errors"]))
            package["products"] = []
            support["dependencies"].append({"byName": ["XTouchCompactApp", None]})
            self.assertTrue(
                any("Invalid test-support target boundary" in e for e in check_tree(root, manifest, package)["errors"])
            )
            support["dependencies"].pop()
            support["path"] = "Sources/XTouchFeedbackTestSupport"
            self.assertTrue(
                any("Invalid test-support target boundary" in e for e in check_tree(root, manifest, package)["errors"])
            )
            support["path"] = "Tests/XTouchFeedbackTestSupport"
            package["targets"].append(
                {
                    "name": "OtherTests",
                    "type": "test",
                    "dependencies": [{"byName": ["XTouchFeedbackTestSupport", None]}],
                }
            )
            self.assertTrue(
                any("Unexpected test-support consumer" in e for e in check_tree(root, manifest, package)["errors"])
            )
            (root / "Sources/Host/Runtime.swift").write_text("import XTouchFeedbackTestSupport\nstruct Runtime {}")
            self.assertTrue(
                any(
                    "Test-support module in production source" in e
                    for e in check_tree(root, manifest, package)["errors"]
                )
            )

    def test_kernel_conformance_is_test_only_even_if_a_manifest_tries_to_allow_it(self):
        with fixture(
            {"Sources/Host/Runtime.swift": ("composition", "import SurfaceDeviceConformance\nstruct Runtime {}")}
        ) as (root, manifest):
            manifest["targets"]["Host"]["dependencies"] = ["SurfaceDeviceConformance"]
            package = {
                "targets": [
                    {
                        "name": "Host",
                        "type": "regular",
                        "dependencies": [{"product": ["SurfaceDeviceConformance", "ControlSurfaceKit", None, None]}],
                    }
                ]
            }
            errors = check_tree(root, manifest, package)["errors"]
            self.assertTrue(any("Test-only module in production source" in error for error in errors))
            self.assertTrue(any("Test-only module in production target" in error for error in errors))
        with fixture(
            {"Sources/Host/Runtime.swift": ("device", "import SurfaceDeviceContracts\nstruct Runtime {}")}
        ) as (root, manifest):
            self.assertEqual(check_tree(root, manifest)["errors"], [])

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

    def construction_fixture(self, consumer):
        return fixture(
            {
                "Sources/Host/Values.swift": ("values", "struct Configuration {}"),
                "Sources/Host/Engine.swift": (
                    "runtime",
                    "struct ParameterEngine { init(validatedConfiguration: Configuration, actionBindings: [Int: Int]) {} }",
                ),
                "Sources/Host/Adapter.swift": (
                    "bridge",
                    "extension ParameterEngine { init(configuration: Configuration = Configuration(), actionBindings: [Int: Int] = [:]) { self.init(validatedConfiguration: configuration, actionBindings: actionBindings) } }",
                ),
                "Sources/Host/Consumer.swift": ("runtime", consumer),
            },
            constructors={"ParameterEngine": "validatedConfiguration"},
        )

    def test_typed_inferred_initializers_cannot_call_bridge_convenience(self):
        for expression in [
            "let engine: ParameterEngine = .init()",
            "let engine: ParameterEngine = .init(configuration: Configuration())",
        ]:
            with self.subTest(expression=expression), self.construction_fixture(expression) as (root, manifest):
                self.assertTrue(any("validated" in error for error in check_tree(root, manifest)["errors"]))

    def test_explicit_function_return_context_cannot_infer_bridge_convenience(self):
        for expression in [
            "func make() -> ParameterEngine { .init() }",
            "func make() -> ParameterEngine { return .init(configuration: Configuration()) }",
            "func make(_ ready: Bool) -> ParameterEngine { if ready { return .init() }; return .init() }",
        ]:
            with self.subTest(expression=expression), self.construction_fixture(expression) as (root, manifest):
                self.assertTrue(any("validated" in error for error in check_tree(root, manifest)["errors"]))

    def test_plain_alias_calls_and_inferred_alias_initializers_are_guarded(self):
        for expression in [
            "typealias Engine = ParameterEngine; let engine = Engine()",
            "typealias Engine = ParameterEngine; let engine: Engine = .init(configuration: Configuration())",
            "typealias Engine = ParameterEngine; func make() -> Engine { .init() }",
        ]:
            with self.subTest(expression=expression), self.construction_fixture(expression) as (root, manifest):
                self.assertTrue(any("validated" in error for error in check_tree(root, manifest)["errors"]))

    def test_explicit_metatype_initializers_use_the_same_validated_boundary(self):
        with self.construction_fixture("let engine = ParameterEngine.self.init(configuration: Configuration())") as (
            root,
            manifest,
        ):
            self.assertTrue(any("validated" in error for error in check_tree(root, manifest)["errors"]))
        with self.construction_fixture(
            "let engine = ParameterEngine.self.init(validatedConfiguration: Configuration(), actionBindings: [:])"
        ) as (root, manifest):
            self.assertEqual(check_tree(root, manifest)["errors"], [])

    def test_legal_contextual_and_aliased_validated_initializers_remain_allowed(self):
        for expression in [
            "let engine: ParameterEngine = .init(validatedConfiguration: Configuration(), actionBindings: [:])",
            "func make() -> ParameterEngine { .init(validatedConfiguration: Configuration(), actionBindings: [:]) }",
            "typealias Engine = ParameterEngine; let engine = Engine(validatedConfiguration: Configuration(), actionBindings: [:])",
            "typealias Engine = ParameterEngine; let engine: Engine = .init(validatedConfiguration: Configuration(), actionBindings: [:])",
        ]:
            with self.subTest(expression=expression), self.construction_fixture(expression) as (root, manifest):
                self.assertEqual(check_tree(root, manifest)["errors"], [])

    def test_external_qualified_members_do_not_resolve_to_host_extensions(self):
        files = {
            "Sources/Host/Values.swift": ("values", "struct SurfaceConfiguration {}"),
            "Sources/Host/Adapter.swift": (
                "bridge",
                "extension SurfaceConfiguration { static var neutral: Self { .init() } }",
            ),
            "Sources/Host/Consumer.swift": (
                "runtime",
                "import External\nlet value = External.SurfaceConfiguration.neutral",
            ),
        }
        with patch.dict(PURE_IMPORTS, {"runtime": PURE_IMPORTS["runtime"] | {"External"}}):
            with fixture(files) as (root, manifest):
                self.assertEqual(check_tree(root, manifest)["errors"], [])

    def test_external_annotated_receivers_do_not_bind_host_extension_members(self):
        files = {
            "Sources/Host/Values.swift": ("values", "struct SurfaceConfiguration {}"),
            "Sources/Host/Adapter.swift": ("bridge", "extension SurfaceConfiguration { func validate() {} }"),
            "Sources/Host/Consumer.swift": (
                "runtime",
                "import External\nstruct Consumer { var config: External.SurfaceConfiguration; func f() { config.validate() } }",
            ),
        }
        with patch.dict(PURE_IMPORTS, {"runtime": PURE_IMPORTS["runtime"] | {"External"}}):
            with fixture(files) as (root, manifest):
                self.assertEqual(check_tree(root, manifest)["errors"], [])

    def test_internal_qualified_annotated_receivers_still_check_extension_roles(self):
        files = {
            "Sources/Host/Values.swift": ("values", "struct Config {}"),
            "Sources/Host/Device.swift": ("device", "extension Config { func validate() {} }"),
            "Sources/Host/Consumer.swift": (
                "runtime",
                "struct Consumer { var config: Host.Config; func f() { config.validate() } }",
            ),
        }
        with fixture(files) as (root, manifest):
            self.assertTrue(any("Config.validate" in error for error in check_tree(root, manifest)["errors"]))

    def throwing_construction_fixture(self, consumer):
        return fixture(
            {
                "Sources/Host/Values.swift": ("values", "struct Configuration {}"),
                "Sources/Host/Engine.swift": (
                    "runtime",
                    "struct ParameterEngine { init(validatedConfiguration: Configuration, actionBindings: [Int: Int]) throws {} }",
                ),
                "Sources/Host/Adapter.swift": (
                    "bridge",
                    "extension ParameterEngine { init(configuration: Configuration = Configuration(), actionBindings: [Int: Int] = [:]) throws { try self.init(validatedConfiguration: configuration, actionBindings: actionBindings) } }",
                ),
                "Sources/Host/Consumer.swift": ("runtime", consumer),
            },
            constructors={"ParameterEngine": "validatedConfiguration"},
        )

    def test_throwing_inferred_initializers_cannot_call_bridge_convenience(self):
        for expression in [
            "func consume() throws { let e: ParameterEngine = try .init() }",
            "func consume() throws { let e: ParameterEngine = try .init(configuration: Configuration()) }",
            "func make() throws -> ParameterEngine { return try .init() }",
            "func make() throws -> ParameterEngine { try .init() }",
        ]:
            with (
                self.subTest(expression=expression),
                self.throwing_construction_fixture(expression) as (root, manifest),
            ):
                self.assertTrue(any("validated" in error for error in check_tree(root, manifest)["errors"]))

    def test_forced_and_optional_try_inferred_initializers_cannot_bypass_the_boundary(self):
        for expression in [
            "func make() -> ParameterEngine { try! .init() }",
            "func make() -> ParameterEngine? { try? .init() }",
        ]:
            with (
                self.subTest(expression=expression),
                self.throwing_construction_fixture(expression) as (root, manifest),
            ):
                self.assertTrue(any("validated" in error for error in check_tree(root, manifest)["errors"]))

    def test_throwing_validated_initializers_remain_legal_in_all_static_forms(self):
        for expression in [
            "func consume() throws { let e: ParameterEngine = try .init(validatedConfiguration: Configuration(), actionBindings: [:]) }",
            "func make() throws -> ParameterEngine { return try .init(validatedConfiguration: Configuration(), actionBindings: [:]) }",
            "func make() -> ParameterEngine { try! .init(validatedConfiguration: Configuration(), actionBindings: [:]) }",
            "func make() -> ParameterEngine? { try? .init(validatedConfiguration: Configuration(), actionBindings: [:]) }",
            "typealias Engine = ParameterEngine; func make() throws -> Engine { try .init(validatedConfiguration: Configuration(), actionBindings: [:]) }",
            "func make() throws -> ParameterEngine { try ParameterEngine.self.init(validatedConfiguration: Configuration(), actionBindings: [:]) }",
        ]:
            with (
                self.subTest(expression=expression),
                self.throwing_construction_fixture(expression) as (root, manifest),
            ):
                self.assertEqual(check_tree(root, manifest)["errors"], [])

    def test_parenthesized_throwing_constructor_prefixes_are_normalized(self):
        for expression in [
            "func consume() throws { let e: ParameterEngine = (try .init()) }",
            "func make() throws -> ParameterEngine { return (try .init()) }",
            "func make() throws -> ParameterEngine { (try .init()) }",
            "func make() -> ParameterEngine { ((try! .init())) }",
            "func make() -> ParameterEngine? { return (try? .init()) }",
        ]:
            with (
                self.subTest(expression=expression),
                self.throwing_construction_fixture(expression) as (root, manifest),
            ):
                self.assertTrue(any("validated" in error for error in check_tree(root, manifest)["errors"]))
                legal = expression.replace(
                    ".init()", ".init(validatedConfiguration: Configuration(), actionBindings: [:])"
                )
                (root / "Sources/Host/Consumer.swift").write_text(legal)
                self.assertEqual(check_tree(root, manifest)["errors"], [])

    def test_let_imports_identify_the_real_module_without_expanding_allowed_imports(self):
        with fixture(
            {"Sources/Host/Runtime.swift": ("runtime", "import let Foundation.NSFoundationVersionNumber")}
        ) as (root, manifest):
            self.assertEqual(check_tree(root, manifest)["errors"], [])
        with fixture({"Sources/Host/Runtime.swift": ("runtime", "import let CoreMIDI.kMIDIInvalidUniqueID")}) as (
            root,
            manifest,
        ):
            self.assertTrue(any("CoreMIDI" in error for error in check_tree(root, manifest)["errors"]))

    def test_lexical_self_constructors_and_delegation_cannot_call_the_bridge(self):
        for expression in [
            "extension ParameterEngine { static func make() throws -> Self { try Self(configuration: Configuration()) } }",
            "extension ParameterEngine { func copy() throws -> Self { try .init(configuration: Configuration()) } }",
            "extension ParameterEngine { init(copy: Bool) throws { try self.init(configuration: Configuration()) } }",
        ]:
            with (
                self.subTest(expression=expression),
                self.throwing_construction_fixture(expression) as (root, manifest),
            ):
                self.assertTrue(any("validated" in error for error in check_tree(root, manifest)["errors"]))

    def test_lexical_self_validated_construction_and_delegation_remain_legal(self):
        for expression in [
            "extension ParameterEngine { static func make() throws -> Self { try Self(validatedConfiguration: Configuration(), actionBindings: [:]) } }",
            "extension ParameterEngine { func copy() throws -> Self { try .init(validatedConfiguration: Configuration(), actionBindings: [:]) } }",
            "extension ParameterEngine { init(copy: Bool) throws { try self.init(validatedConfiguration: Configuration(), actionBindings: [:]) } }",
        ]:
            with (
                self.subTest(expression=expression),
                self.throwing_construction_fixture(expression) as (root, manifest),
            ):
                self.assertEqual(check_tree(root, manifest)["errors"], [])

    def test_nested_other_nominal_self_does_not_inherit_the_engine_policy(self):
        expression = "extension ParameterEngine { struct Other { init(configuration: Configuration) throws {} ; func copy() throws -> Self { try .init(configuration: Configuration()) } } }"
        with self.throwing_construction_fixture(expression) as (root, manifest):
            self.assertEqual(check_tree(root, manifest)["errors"], [])
