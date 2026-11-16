import importlib.util
import json
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest


sys.dont_write_bytecode = True
SCRIPTS = pathlib.Path(__file__).resolve().parent


def load(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SHARDS = load("ui-test-shards")
XCTESTRUN = load("ui-test-xctestrun")


class ShardTests(unittest.TestCase):
    def test_longest_first_and_stable_ties(self):
        assignments, loads = SHARDS.assign(["c", "b", "a", "d"], {"a": 60, "b": 30, "c": 30, "d": 20}, 2)
        self.assertEqual(assignments, {"a": 1, "b": 2, "c": 2, "d": 1})
        self.assertEqual(loads, [80, 60])
        self.assertEqual(SHARDS.assign(reversed(list(assignments)), {"a": 60, "b": 30, "c": 30, "d": 20}, 2),
                         (assignments, loads))

    def test_unknown_test_uses_table_median(self):
        assignments, loads = SHARDS.assign(["new"], {"old": 10, "other": 30}, 3)
        self.assertEqual(assignments, {"new": 1})
        self.assertEqual(loads, [20, 0, 0])

    def test_empty_table_and_tests(self):
        self.assertEqual(SHARDS.assign(["new"], {}, 1), ({"new": 1}, [30]))
        self.assertEqual(SHARDS.assign([], {}, 2), ({}, [0, 0]))

    def test_cli_rejects_invalid_or_empty_slice(self):
        for shard in ("0/3", "4/3", "1/0", "bad", "100/100"):
            result = subprocess.run([sys.executable, str(SCRIPTS / "ui-test-shards.py"), "--shard", shard],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run([sys.executable, str(SCRIPTS / "ui-test-shards.py"), "--tests", directory],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("has no tests", result.stderr)

    def test_real_three_slices_cover_each_case_once(self):
        tests = SHARDS.scan(SCRIPTS.parent / "LinksUITests")
        plans = []
        for shard in range(1, 4):
            result = subprocess.run([sys.executable, str(SCRIPTS / "ui-test-shards.py"), "--shard", f"{shard}/3"],
                                    capture_output=True, text=True, check=True)
            plan = {test: index for index, test in (line.split("\t") for line in result.stdout.splitlines())}
            plans.append(plan)
            self.assertIn(f"UI test slice {shard}/3: planned", result.stderr)
        self.assertEqual(plans[0], plans[1])
        self.assertEqual(plans[0], plans[2])
        selected = [[test for test, index in plans[0].items() if int(index) == shard] for shard in range(1, 4)]
        self.assertEqual(sorted(test for group in selected for test in group), tests)
        self.assertTrue(all(selected))

    def test_scanner_handles_paths_with_spaces_and_multiple_classes(self):
        with tempfile.TemporaryDirectory(prefix="ui tests ") as directory:
            path = pathlib.Path(directory)
            (path / "Tests.swift").write_text("class First: XCTestCase {\n func testA() {}\n}\n"
                                             "class Second: XCTestCase {\n @MainActor func testB() {}\n}\n")
            self.assertEqual(SHARDS.scan(path), ["LinksUITests/First/testA", "LinksUITests/Second/testB"])


class XctestrunTests(unittest.TestCase):
    def test_legacy_environment_and_relative_paths_are_preserved(self):
        target = {"TestBundlePath": "__TESTROOT__/Debug-iphonesimulator/LinksUITests.xctest",
                  "EnvironmentVariables": {"EXISTING": "yes"},
                  "TestingEnvironmentVariables": {"DYLD_LIBRARY_PATH": "__TESTROOT__/lib"}}
        specification = {"LinksUITests": target, "__xctestrun_metadata__": {"FormatVersion": 1}}
        configured = XCTESTRUN.configure(specification, {"LINKS_SERVER_URL": "http://localhost", "LINKS_DEV_TOKEN": "old"})
        target = configured["LinksUITests"]
        self.assertEqual(target["EnvironmentVariables"]["EXISTING"], "yes")
        self.assertEqual(target["TestingEnvironmentVariables"]["DYLD_LIBRARY_PATH"], "__TESTROOT__/lib")
        self.assertTrue(target["TestBundlePath"].startswith("__TESTROOT__/"))
        XCTESTRUN.configure(specification, {"LINKS_DEV_TOKEN": "fresh"})
        for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            self.assertEqual(target[key]["LINKS_DEV_TOKEN"], "fresh")
        self.assertEqual(configured["__xctestrun_metadata__"], {"FormatVersion": 1})

    def test_format_two_configures_every_target(self):
        specification = {"TestConfigurations": [{"TestTargets": [{}, {}]}, {"TestTargets": [{}]}]}
        result = XCTESTRUN.configure(specification, {"LINKS_SPARE_TOKEN": "fresh"})
        for configuration in result["TestConfigurations"]:
            for target in configuration["TestTargets"]:
                self.assertEqual(target["EnvironmentVariables"]["LINKS_SPARE_TOKEN"], "fresh")
                self.assertEqual(target["TestingEnvironmentVariables"]["LINKS_SPARE_TOKEN"], "fresh")

    def test_empty_specification_rejected(self):
        for specification in ({}, {"__xctestrun_metadata__": {}}, {"TestConfigurations": []}):
            with self.assertRaisesRegex(ValueError, "no test targets"):
                XCTESTRUN.configure(specification, {})

    def test_cli_injects_only_links_runner_variables(self):
        with tempfile.TemporaryDirectory() as directory:
            source = pathlib.Path(directory) / "original.xctestrun"
            destination = pathlib.Path(directory) / ".configured.xctestrun"
            source.write_bytes(plistlib.dumps({"LinksUITests": {}}))
            environment = dict(os.environ, TEST_RUNNER_LINKS_SERVER_URL="http://localhost",
                               TEST_RUNNER_LINKS_DEV_TOKEN="fixture", UNRELATED="not injected")
            subprocess.run([sys.executable, str(SCRIPTS / "ui-test-xctestrun.py"), str(source), str(destination)],
                           env=environment, check=True)
            target = plistlib.loads(destination.read_bytes())["LinksUITests"]
            self.assertEqual(target["TestingEnvironmentVariables"]["LINKS_DEV_TOKEN"], "fixture")
            self.assertNotIn("UNRELATED", target["EnvironmentVariables"])
            self.assertEqual(plistlib.loads(source.read_bytes()), {"LinksUITests": {}})


class ScriptTests(unittest.TestCase):
    def run_script(self, action, artifact=True, recovery=False, booted=True):
        with tempfile.TemporaryDirectory(prefix="links script ") as directory:
            root = pathlib.Path(directory)
            products = root / "build/Build/Products"
            (products / "Debug-iphonesimulator/Links.app").mkdir(parents=True)
            if artifact:
                (products / "Links.xctestrun").write_bytes(plistlib.dumps({"LinksUITests": {}}))
            commands = root / "bin"
            commands.mkdir()
            mock = commands / "mock"
            mock.write_text("#!/usr/bin/env python3\n" + r'''
import json, os, pathlib, plistlib, signal, sys
root = pathlib.Path(os.environ["MOCK_ROOT"])
command = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
if command == "bun":
    if "-e" in args:
        print("49123")
    elif "mint-session" in args:
        counter = root / "mint-count"
        value = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(value))
        print(f"fixture-{value}")
    else:
        signal.pause()
elif command == "xcrun":
    with (root / "simctl.jsonl").open("a") as log:
        log.write(json.dumps(args) + "\n")
    if args[:3] == ["simctl", "list", "devices"]:
        state = "Booted" if os.environ["MOCK_BOOTED"] == "1" else "Shutdown"
        print(f"    Links UI Tests (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) ({state})")
elif command == "xcodebuild":
    log = root / "xcodebuild.jsonl"
    attempt = len(log.read_text().splitlines()) if log.exists() else 0
    entry = {"args": args}
    if "-xctestrun" in args:
        entry["plist"] = plistlib.loads(pathlib.Path(args[args.index("-xctestrun") + 1]).read_bytes())
    with log.open("a") as output:
        output.write(json.dumps(entry) + "\n")
    case = "-[LinksUITests.LinksUITests testSignedInLaunchShowsTheInbox]"
    print(f"Test Case '{case}' started.")
    if os.environ["MOCK_RECOVERY"] == "1" and attempt == 0:
        print(f"file.swift:1: error: {case} : Failed to launch app: Timed out while launching")
        print(f"Test Case '{case}' failed (94 seconds).")
        sys.exit(65)
    print(f"Test Case '{case}' passed (1 seconds).")
''')
            mock.chmod(0o755)
            for name in ("bun", "curl", "xcrun", "xcodebuild"):
                (commands / name).symlink_to(mock)
            environment = dict(os.environ, HOME=str(root), PATH=str(commands) + os.pathsep + os.environ["PATH"],
                               MOCK_ROOT=str(root), MOCK_BOOTED=str(int(booted)), MOCK_RECOVERY=str(int(recovery)),
                               LINKS_UI_TEST_DERIVED_DATA=str(root / "build"), LINKS_UI_TEST_ACTION=action)
            environment.pop("LINKS_UI_TEST_SHARD", None)
            result = subprocess.run(["bash", str(SCRIPTS / "ui-tests.sh"),
                                     "-only-testing:LinksUITests/LinksUITests/testSignedInLaunchShowsTheInbox"],
                                    env=environment, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            invocations = [json.loads(line) for line in (root / "xcodebuild.jsonl").read_text().splitlines()]
            simctl = [json.loads(line) for line in (root / "simctl.jsonl").read_text().splitlines()]
            self.assertEqual(list(products.glob(".links-ui-tests-*.xctestrun")), [])
            return invocations, simctl, result

    def test_xctestrun_recovery_refreshes_environment_and_reuses_boot(self):
        invocations, simctl, result = self.run_script("test-without-building", recovery=True)
        self.assertEqual(len(invocations), 2)
        for invocation in invocations:
            args = invocation["args"]
            self.assertIn("-xctestrun", args)
            self.assertIn("-destination", args)
            self.assertNotIn("-project", args)
            self.assertNotIn("-scheme", args)
            self.assertNotIn("-configuration", args)
            self.assertIn("-only-testing:LinksUITests/LinksUITests/testSignedInLaunchShowsTheInbox", args)
            target = invocation["plist"]["LinksUITests"]
            self.assertEqual(target["EnvironmentVariables"]["LINKS_SERVER_URL"], "http://127.0.0.1:49123")
        old = invocations[0]["plist"]["LinksUITests"]["TestingEnvironmentVariables"]
        new = invocations[1]["plist"]["LinksUITests"]["TestingEnvironmentVariables"]
        self.assertNotEqual(old["LINKS_SPARE_TOKEN"], new["LINKS_SPARE_TOKEN"])
        self.assertNotEqual(old["LINKS_DELETABLE_TOKEN"], new["LINKS_DELETABLE_TOKEN"])
        self.assertFalse(any(args[:2] == ["simctl", "boot"] for args in simctl))
        self.assertIn("Simulator boot/bootstatus completed in", result.stdout)
        self.assertIn("Simulator app install completed in", result.stdout)
        self.assertIn("Simulator app launch completed in", result.stdout)

    def test_local_test_uses_project_even_when_xctestrun_exists(self):
        invocations, simctl, _ = self.run_script("test")
        self.assertIn("-project", invocations[0]["args"])
        self.assertNotIn("-xctestrun", invocations[0]["args"])
        self.assertFalse(any(args[:2] == ["simctl", "install"] for args in simctl))

    def test_without_xctestrun_falls_back_to_project_and_boots(self):
        invocations, simctl, _ = self.run_script("test-without-building", artifact=False, booted=False)
        self.assertIn("-project", invocations[0]["args"])
        self.assertNotIn("-xctestrun", invocations[0]["args"])
        self.assertTrue(any(args[:2] == ["simctl", "boot"] for args in simctl))
        self.assertTrue(any(args[:2] == ["simctl", "bootstatus"] for args in simctl))


if __name__ == "__main__":
    unittest.main()
