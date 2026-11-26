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

    def test_first_slice_overhead_reduces_its_test_work(self):
        assignments, loads = SHARDS.assign(["a", "b", "c", "d"],
                                           {"a": 60, "b": 40, "c": 30, "d": 20}, 2, 30)
        self.assertEqual(assignments, {"a": 2, "b": 1, "c": 2, "d": 1})
        self.assertEqual(loads, [90, 90])

    def test_cli_rejects_invalid_overhead(self):
        for overhead in ("-1", "nan", "inf"):
            result = subprocess.run([sys.executable, str(SCRIPTS / "ui-test-shards.py"),
                                     "--first-shard-overhead", overhead], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("overhead must be finite and nonnegative", result.stderr)

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

    def test_real_two_slices_with_overhead_cover_each_case_once(self):
        tests = SHARDS.scan(SCRIPTS.parent / "LinksUITests")
        plans = []
        for shard in range(1, 3):
            result = subprocess.run([sys.executable, str(SCRIPTS / "ui-test-shards.py"), "--shard", f"{shard}/2"],
                                    env=dict(os.environ, LINKS_UI_TEST_FIRST_SHARD_OVERHEAD="100"),
                                    capture_output=True, text=True, check=True)
            plan = {test: index for index, test in (line.split("\t") for line in result.stdout.splitlines())}
            plans.append(plan)
            self.assertIn(f"UI test slice {shard}/2: planned", result.stderr)
            self.assertIn("100.0s overhead", result.stderr)
        self.assertEqual(plans[0], plans[1])
        selected = [[test for test, index in plans[0].items() if int(index) == shard] for shard in range(1, 3)]
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
    def run_script(self, action, artifact=True, recovery=False, booted=True,
                   launch_failures=0, expected_status=0, shard=None, stall=False):
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
import json, os, pathlib, plistlib, signal, sys, time
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
    if args[:3] == ["xcresulttool", "get", "object"]:
        print((root / "failure.json").read_text())
    if args[:3] == ["simctl", "list", "devices"]:
        state = "Booted" if os.environ["MOCK_BOOTED"] == "1" else "Shutdown"
        if (root / "erased").exists() and not (root / "booted").exists():
            state = "Shutdown"
        print(f"    Links UI Tests (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) ({state})")
    if args[:2] == ["simctl", "erase"]:
        (root / "erased").touch()
    if args[:2] == ["simctl", "boot"]:
        (root / "booted").touch()
    if args[:2] == ["simctl", "launch"]:
        counter = root / "launch-count"
        value = int(counter.read_text()) + 1 if counter.exists() else 1
        counter.write_text(str(value))
        if value <= int(os.environ["MOCK_LAUNCH_FAILURES"]):
            sys.exit(1)
elif command == "xcodebuild":
    log = root / "xcodebuild.jsonl"
    attempt = len(log.read_text().splitlines()) if log.exists() else 0
    entry = {"args": args}
    if "-xctestrun" in args:
        entry["plist"] = plistlib.loads(pathlib.Path(args[args.index("-xctestrun") + 1]).read_bytes())
    with log.open("a") as output:
        output.write(json.dumps(entry) + "\n")
    case = "-[LinksUITests.LinksUITests testSignedInLaunchShowsTheInbox]"
    print(f"Test Case '{case}' started.", flush=True)
    if os.environ["MOCK_STALL"] == "1":
        time.sleep(10)
    if os.environ["MOCK_RECOVERY"] == "2" and attempt == 0:
        bundle = root / "Test-Links.xcresult"
        bundle.mkdir()
        (root / "failure.json").write_text(json.dumps({"issues": {"testFailureSummaries": {"_values": [{
            "testCaseName": {"_value": "LinksUITests.testSignedInLaunchShowsTheInbox()"},
            "message": {"_value": "Test crashed with signal term."}
        }]}}}))
        print("Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.")
        print("Test session results, code coverage, and logs:")
        print(f"    {bundle}")
        sys.exit(65)
    if os.environ["MOCK_RECOVERY"] == "1" and attempt == 0:
        print(f"file.swift:1: error: {case} : Failed to launch app: Timed out while launching")
        print(f"Test Case '{case}' failed (94 seconds).")
        sys.exit(65)
    print(f"Test Case '{case}' passed (1 seconds).")
elif command == "sleep" and os.environ["MOCK_STALL"] == "1" and args == ["1"]:
    time.sleep(1)
''')
            mock.chmod(0o755)
            for name in ("bun", "curl", "xcrun", "xcodebuild", "sleep"):
                (commands / name).symlink_to(mock)
            environment = dict(os.environ, HOME=str(root), PATH=str(commands) + os.pathsep + os.environ["PATH"],
                               MOCK_ROOT=str(root), MOCK_BOOTED=str(int(booted)),
                               MOCK_LAUNCH_FAILURES=str(launch_failures),
                               MOCK_RECOVERY="2" if recovery == "killed" else str(int(recovery)),
                               MOCK_STALL=str(int(stall)),
                               LINKS_UI_TEST_DERIVED_DATA=str(root / "build"), LINKS_UI_TEST_ACTION=action)
            if stall:
                environment.update(LINKS_UI_TEST_LOGS="relative logs", LINKS_UI_TEST_STALL_SECONDS="1")
            environment.pop("LINKS_UI_TEST_SHARD", None)
            args = ["bash", str(SCRIPTS / "ui-tests.sh")]
            if shard is None:
                args.append("-only-testing:LinksUITests/LinksUITests/testSignedInLaunchShowsTheInbox")
            else:
                environment.update(LINKS_UI_TEST_SHARD=shard, LINKS_UI_TEST_FIRST_SHARD_OVERHEAD="100")
            result = subprocess.run(args,
                                    cwd=root if stall else None, env=environment,
                                    capture_output=True, text=True, timeout=30)
            if expected_status is not None:
                self.assertEqual(result.returncode, expected_status, result.stdout + result.stderr)
            log = root / "xcodebuild.jsonl"
            invocations = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            simctl = [json.loads(line) for line in (root / "simctl.jsonl").read_text().splitlines()]
            self.assertEqual(list(products.glob(".links-ui-tests-*.xctestrun")), [])
            return invocations, simctl, result

    def test_watchdog_stops_silent_xcodebuild_with_relative_logs(self):
        _, _, result = self.run_script("test", stall=True, expected_status=None)
        self.assertRegex(result.stdout, r"error: no UI test output for \d+s; stopping xcodebuild")
        self.assertNotEqual(result.returncode, 0)

    def test_three_slices_select_each_case_once_and_leave_unscanned_cases_to_the_last(self):
        tests = set(SHARDS.scan(SCRIPTS.parent / "LinksUITests"))
        unscanned = "LinksUITests/OtherTests/testUnscanned"
        remaining = tests | {unscanned}
        for shard in range(1, 4):
            invocations, _, result = self.run_script("test-without-building", shard=f"{shard}/3")
            self.assertIn(f"UI test slice {shard}/3: planned", result.stderr)
            self.assertEqual(len(invocations), 1)
            args = invocations[0]["args"]
            only = {arg.removeprefix("-only-testing:") for arg in args if arg.startswith("-only-testing:")}
            skip = {arg.removeprefix("-skip-testing:") for arg in args if arg.startswith("-skip-testing:")}
            if shard < 3:
                self.assertFalse(skip)
                selected = only
            else:
                self.assertFalse(only)
                selected = (tests | {unscanned}) - skip
                self.assertIn(unscanned, selected)
            self.assertTrue(selected)
            self.assertLessEqual(selected, remaining)
            remaining -= selected
        self.assertFalse(remaining)

    def test_healthy_warm_up_does_not_reset(self):
        invocations, commands, result = self.run_script("test-without-building")
        self.assertEqual(len(invocations), 1)
        self.assertIn("Simulator warm-up reset=no", result.stdout)
        self.assertFalse(any(args[:2] == ["simctl", "erase"] for args in commands))
        self.assertEqual(sum(args[:2] == ["simctl", "launch"] for args in commands), 1)

    def test_warm_up_recovers_after_one_reset(self):
        invocations, commands, result = self.run_script("test-without-building", launch_failures=6)
        self.assertEqual(len(invocations), 1)
        operations = [args[1] for args in commands if args[0] == "simctl"]
        reset = operations.index("erase")
        self.assertEqual(operations[reset - 1:reset + 5],
                         ["shutdown", "erase", "list", "boot", "bootstatus", "install"])
        self.assertEqual(operations.count("erase"), 1)
        self.assertEqual(operations.count("install"), 2)
        self.assertEqual(operations.count("launch"), 7)
        self.assertIn("Simulator warm-up reset=yes", result.stdout)
        self.assertEqual(result.stdout.count("Simulator app launch completed in"), 1)
        self.assertIn("Simulator reset erase completed in", result.stdout)

    def test_warm_up_failure_after_reset_stops_before_xcode(self):
        invocations, commands, result = self.run_script(
            "test-without-building", launch_failures=12, expected_status=1)
        self.assertEqual(invocations, [])
        self.assertEqual(sum(args[:2] == ["simctl", "erase"] for args in commands), 1)
        self.assertEqual(sum(args[:2] == ["simctl", "launch"] for args in commands), 12)
        self.assertIn("Simulator warm-up reset=yes", result.stdout)
        self.assertIn("Simulator warm-up failed after reset", result.stderr)
        self.assertNotIn("Simulator app launch completed", result.stdout)
        self.assertNotIn("Simulator booted and Links launched once", result.stdout)

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

    def test_killed_runner_uses_xcresult_reboots_and_refreshes_tokens(self):
        invocations, commands, result = self.run_script("test-without-building", recovery="killed")
        self.assertEqual(len(invocations), 2)
        self.assertTrue(any(args[:4] == ["xcresulttool", "get", "object", "--legacy"] for args in commands))
        self.assertTrue(any(args[:2] == ["simctl", "shutdown"] for args in commands))
        self.assertTrue(any(args[:2] == ["simctl", "boot"] for args in commands))
        for invocation in invocations:
            self.assertIn("-only-testing:LinksUITests/LinksUITests/testSignedInLaunchShowsTheInbox", invocation["args"])
        old = invocations[0]["plist"]["LinksUITests"]["TestingEnvironmentVariables"]
        new = invocations[1]["plist"]["LinksUITests"]["TestingEnvironmentVariables"]
        for key in ("LINKS_SPARE_TOKEN", "LINKS_DELETABLE_TOKEN"):
            self.assertNotEqual(old[key], new[key])
        self.assertIn("simulator crash interrupted UI tests", result.stderr)

    def test_without_xctestrun_falls_back_to_project_and_boots(self):
        invocations, simctl, _ = self.run_script("test-without-building", artifact=False, booted=False)
        self.assertIn("-project", invocations[0]["args"])
        self.assertNotIn("-xctestrun", invocations[0]["args"])
        self.assertTrue(any(args[:2] == ["simctl", "boot"] for args in simctl))
        self.assertTrue(any(args[:2] == ["simctl", "bootstatus"] for args in simctl))


if __name__ == "__main__":
    unittest.main()
