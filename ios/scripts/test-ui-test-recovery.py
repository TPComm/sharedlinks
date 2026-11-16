import pathlib
import json
import re
import subprocess
import sys
import tempfile
import unittest


PARSER = pathlib.Path(__file__).with_name("ui-test-recoverable-failures.sh")
SELECTION = pathlib.Path(__file__).with_name("ui-test-selection.sh")
REAL_LOG = pathlib.Path(sys.argv.pop(1)) if len(sys.argv) > 1 else None
KILLED_LOG = PARSER.with_name("ui-test-killed-runner.txt").read_text()
KILLED_RESULT = PARSER.with_name("ui-test-killed-runner-result.json")
NOTIFICATION = "LinksUITests/LinksUITests/testNotificationTogglesSaveEachSetting\n"


class RecoveryTests(unittest.TestCase):
    def result_failures(self, result):
        return subprocess.run(
            [sys.executable, str(PARSER.with_name("ui-test-result-failures.py"))],
            input=json.dumps(result), capture_output=True, text=True, check=True
        ).stdout

    def test_run_43858784250_requires_result_evidence(self):
        result = self.parse(KILLED_LOG, NOTIFICATION)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        evidence = self.result_failures(json.loads(KILLED_RESULT.read_text()))
        result = self.parse(KILLED_LOG + evidence, NOTIFICATION)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "crash LinksUITests/testNotificationTogglesSaveEachSetting\n")

    def test_killed_process_reruns_incomplete_and_unstarted_only(self):
        selection = NOTIFICATION + "LinksUITests/OtherUITests/testLater\n" + \
            "LinksUITests/LinksUITests/testRenamingAddingPeopleToAndLeavingAChat\n"
        for evidence in ("Lost connection to test process\n", "Test crashed with signal term.\n"):
            result = self.parse(KILLED_LOG + evidence, selection)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "crash LinksUITests/testNotificationTogglesSaveEachSetting\n"
                             "crash OtherUITests/testLater\n")

    def test_killed_marker_without_interrupted_selected_test_stays_red(self):
        for log in ("", KILLED_LOG):
            result = self.parse(log + "Lost connection to test process\n",
                                "LinksUITests/LinksUITests/testNeverStarted\n")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_killed_marker_does_not_hide_assertions_or_real_signals(self):
        for problem in ("XCTAssertTrue failed", "Timed out while evaluating UI query",
                        "Test crashed with signal segv.", "Test crashed with signal abrt."):
            for name in ("testNotificationTogglesSaveEachSetting", "testOther"):
                log = KILLED_LOG + "Lost connection to test process\n" + \
                    f"file.swift:1: error: -[LinksUITests.LinksUITests {name}] : {problem}\n"
                result = self.parse(log, NOTIFICATION)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
        for signal in ("SIGSEGV", "SIGABRT", "EXC_BAD_ACCESS"):
            result = self.parse(KILLED_LOG + f"Lost connection to test process\n{signal}\n", NOTIFICATION)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")

    def test_result_failures_preserve_assertions_and_unknown_issues(self):
        self.assertEqual(self.result_failures({}), "")
        result = json.loads(KILLED_RESULT.read_text())
        issues = result["issues"]["testFailureSummaries"]["_values"]
        issues.append({"testCaseName": {"_value": "OtherUITests.testOther()"},
                       "message": {"_value": "XCTAssertEqual failed"}})
        parsed = self.parse(KILLED_LOG + self.result_failures(result), NOTIFICATION)
        self.assertNotEqual(parsed.returncode, 0)
        self.assertEqual(parsed.stdout, "")
        issues[-1] = {"message": {"_value": "Unknown failure"}}
        parsed = self.parse(KILLED_LOG + self.result_failures(result), NOTIFICATION)
        self.assertNotEqual(parsed.returncode, 0)
        self.assertEqual(parsed.stdout, "")

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
