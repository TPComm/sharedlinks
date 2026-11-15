import pathlib
import re
import subprocess
import sys
import tempfile
import unittest


PARSER = pathlib.Path(__file__).with_name("ui-test-recoverable-failures.sh")
REAL_LOG = pathlib.Path(sys.argv.pop(1)) if len(sys.argv) > 1 else None


class RecoveryTests(unittest.TestCase):
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
