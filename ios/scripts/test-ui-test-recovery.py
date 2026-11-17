import pathlib
import re
import subprocess
import sys
import tempfile
import unittest


PARSER = pathlib.Path(__file__).with_name("ui-test-recoverable-failures.sh")
SELECTION = pathlib.Path(__file__).with_name("ui-test-selection.sh")
REAL_LOG = pathlib.Path(sys.argv.pop(1)) if len(sys.argv) > 1 else None


class RecoveryTests(unittest.TestCase):
    def test_skip_guard(self):
        script = PARSER.with_name("ui-tests.sh").read_text()
        guard = script.split("# Without the TEST_RUNNER_", 1)[1].split('if [[ $status -ne 0 ]]', 1)[0]
        guard = guard.split("\n", 1)[1]
        allowed = "Messages on this Simulator can't open iMessage apps: the app drawer is disabled (no iMessage daemon); run on a device"
        missing_server = "Run ios/scripts/ui-tests.sh, which starts a server for these tests."
        summary = "Test Case '-[LinksUITests.MessagesUITests testExample]' skipped (1 seconds).\n"
        for reasons, expected in (([], 0), ([allowed], 0), ([missing_server], 1),
                                  ([allowed, missing_server], 1), (["Unknown skip"], 1),
                                  ([allowed, "Unknown skip"], 1)):
            with self.subTest(reasons=reasons), tempfile.TemporaryDirectory() as logs:
                log = "".join(f"file.swift:1: test : Test skipped - {reason}\n" for reason in reasons)
                pathlib.Path(logs, "xcodebuild.log").write_text(log + (summary if reasons else ""))
                result = subprocess.run(
                    ["bash", "-c", 'set -euo pipefail; status=0; logs="$1"; ' + guard + '\nexit "$status"', "test", logs],
                    capture_output=True, text=True,
                )
                self.assertEqual(result.returncode, expected, result.stderr)
                if reasons == [allowed]:
                    self.assertIn("warning: " + allowed, result.stderr)

    def parse(self, log, selection=""):
        with tempfile.NamedTemporaryFile(mode="w") as fixture, tempfile.NamedTemporaryFile(mode="w") as selected:
            fixture.write(log)
            fixture.flush()
            selected.write(selection)
            selected.flush()
            return subprocess.run(
                ["bash", str(PARSER), fixture.name, selected.name], capture_output=True, text=True
            )

    def test_incomplete_selection_stays_red(self):
        log = self.failure("Lost connection to the application") + "The system shell (SpringBoard:11909) probably crashed.\n"
        selection = "LinksUITests/LinksUITests/testExample\nLinksUITests/LinksUITests/testLater\n"
        result = self.parse(log, selection)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("selection incomplete", result.stderr)
        result = self.parse(log + "Test Case '-[LinksUITests.LinksUITests testLater]' passed (1 seconds).\n", selection)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "crash LinksUITests/testExample\n")

    def select(self, tests, *args):
        return subprocess.run(
            ["bash", str(SELECTION), *args], input=tests, capture_output=True, text=True, check=True
        ).stdout

    def test_selection_follows_extra_xcodebuild_args(self):
        tests = (
            "LinksUITests/LinksUITests/testExample\n"
            "LinksUITests/LinksUITests/testExampleTwo\n"
            "LinksUITests/OtherUITests/testOther\n"
        )
        self.assertEqual(self.select(tests), tests)
        self.assertEqual(self.select(tests, "-only-testing:LinksUITests/LinksUITests/testExample"),
                         "LinksUITests/LinksUITests/testExample\n")
        self.assertEqual(self.select(tests, "-only-testing:LinksUITests/OtherUITests"),
                         "LinksUITests/OtherUITests/testOther\n")
        self.assertEqual(self.select(tests, "-only-testing:LinksUITests"), tests)
        self.assertEqual(self.select(tests, "-skip-testing:LinksUITests/LinksUITests/testExample"),
                         "LinksUITests/LinksUITests/testExampleTwo\nLinksUITests/OtherUITests/testOther\n")
        self.assertEqual(self.select(tests, "-only-testing:LinksUITests/LinksUITests", "-skip-testing:LinksUITests/LinksUITests/testExampleTwo"),
                         "LinksUITests/LinksUITests/testExample\n")

    def test_launch_timeout_in_a_single_test_run_reruns(self):
        tests = "LinksUITests/LinksUITests/testExample\nLinksUITests/LinksUITests/testLater\n"
        selection = self.select(tests, "-only-testing:LinksUITests/LinksUITests/testExample")
        result = self.parse(self.failure("Failed to launch app with identifier: com.tpcomm.links. Error: Timed out while launching application via Xcode"), selection)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "launch LinksUITests/testExample\n")

    def failure(self, message, name="testExample"):
        return (
            f"file.swift:1: error: -[LinksUITests.LinksUITests {name}] : {message}\n"
            f"Test Case '-[LinksUITests.LinksUITests {name}]' failed (94 seconds).\n"
        )

    def test_launch_timeout(self):
        result = self.parse(self.failure("Failed to launch app: Timed out while launching"))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "launch LinksUITests/testExample\n")

    def test_empty_and_passing_logs(self):
        for log in ("", "Test Case '-[LinksUITests.LinksUITests testExample]' passed (1 seconds)."):
            result = self.parse(log)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_assertions_stay_red_even_with_crash(self):
        crash = self.failure("Lost connection to the application") + "The system shell (SpringBoard:11909) probably crashed.\n"
        for name in ("testExample", "testOther"):
            result = self.parse(crash + self.failure("XCTAssertTrue failed", name))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_lost_connection_requires_springboard_crash(self):
        log = self.failure("Lost connection to the application")
        for evidence in ("", "Simulator device failed to launch com.tpcomm.links.uitests.xctrunner\n"):
            result = self.parse(log + evidence)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_unknown_failure_stays_red(self):
        result = self.parse(self.failure("Timed out while evaluating UI query"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_shell_launch_requires_crash_evidence(self):
        log = self.failure("Failed to launch app: Simulator device failed to launch runner")
        self.assertNotEqual(self.parse(log).returncode, 0)
        result = self.parse(log + "The system shell (SpringBoard:11909) probably crashed.\n")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "crash LinksUITests/testExample\n")

    @unittest.skipUnless(REAL_LOG, "pass a downloaded GitHub run log to check the real signature")
    def test_real_run_one(self):
        log = "\n".join(
            re.sub(r"^\d{4}-\d\d-\d\dT\S+ ", "", line.split("\t", 2)[-1])
            for line in REAL_LOG.read_text().splitlines()
        )
        result = self.parse(log)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "crash LinksUITests/testReactingAndEditingTheNote\n")
        print("run1: crash-rerunnable LinksUITests/testReactingAndEditingTheNote")
        result = self.parse(log + self.failure("XCTAssertEqual failed"))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        print("run1 plus assertion: not rerunnable")


if __name__ == "__main__":
    unittest.main()
