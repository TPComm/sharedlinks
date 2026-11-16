#!/usr/bin/env python3
"""Mock the CI runtime preparation without requiring macOS."""

import contextlib
import importlib.util
import io
import json
import pathlib
import subprocess
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location("host", pathlib.Path(__file__).with_name("ui-test-host.py"))
host = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(host)
IOS_ID = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
OTHER_ID = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"


def image(identifier, runtime, platform):
    return {"identifier": identifier, "runtimeIdentifier": runtime, "platformIdentifier": platform, "state": "Ready"}


class HostTests(unittest.TestCase):
    def prepare(self, images, delete_status=0):
        current = dict(images)

        def run(args, timeout=10):
            if args == ["xcrun", "simctl", "runtime", "list", "-j"]:
                return subprocess.CompletedProcess(args, 0, json.dumps(current), "")
            if args == ["xcrun", "--find", "simctl"]:
                return subprocess.CompletedProcess(args, 0, "/Applications/Xcode_27.2.app/usr/bin/simctl\n", "")
            self.assertEqual(args[:5], ["sudo", "-n", "/Applications/Xcode_27.2.app/usr/bin/simctl", "runtime", "delete"])
            if not delete_status:
                del current[args[5]]
            return subprocess.CompletedProcess(args, delete_status, "", "permission denied" if delete_status else "")

        output = io.StringIO()
        with mock.patch.object(host, "run", side_effect=run) as command, contextlib.redirect_stdout(output):
            host.cleanup()
        return command.call_args_list, output.getvalue()

    def test_removes_other_platforms_and_old_ios_but_preserves_target_variants(self):
        for platform, runtime in [(p, "unused") for p in host.OTHER_PLATFORMS] + [(host.IOS, "com.apple.CoreSimulator.SimRuntime.iOS-27-0")]:
            with self.subTest(platform=platform):
                calls, output = self.prepare({IOS_ID: image(IOS_ID, host.TARGET, host.IOS),
                                              OTHER_ID: image(OTHER_ID, runtime, platform)})
                deletes = [call.args[0] for call in calls if "delete" in call.args[0]]
                self.assertEqual(len(deletes), 1)
                self.assertEqual(deletes[0][-1], OTHER_ID)
                self.assertIn("Runtime cleanup removed:", output)
                self.assertIn("removed=1", output)
        calls, _ = self.prepare({IOS_ID: image(IOS_ID, host.TARGET, host.IOS),
                                 OTHER_ID: image(OTHER_ID, host.TARGET + "-iPhone19-4", host.IOS)})
        self.assertEqual(len(calls), 1)

    def test_empty_or_missing_target_never_deletes(self):
        for images in ({}, {OTHER_ID: image(OTHER_ID, "unused", "com.apple.platform.watchsimulator")}):
            calls, output = self.prepare(images)
            self.assertEqual(len(calls), 1)
            self.assertIn("leaving all runtime images untouched", output)

    def test_unknown_platform_and_invalid_identifier_never_deleted(self):
        calls, _ = self.prepare({IOS_ID: image(IOS_ID, host.TARGET, host.IOS),
                                 OTHER_ID: image(OTHER_ID, "unknown", "unknown"),
                                 "all": image("all", "unused", "com.apple.platform.watchsimulator")})
        self.assertEqual(len(calls), 1)

    def test_delete_failure_is_best_effort(self):
        _, output = self.prepare({IOS_ID: image(IOS_ID, host.TARGET, host.IOS),
                                 OTHER_ID: image(OTHER_ID, "unused", "com.apple.platform.watchsimulator")}, 1)
        self.assertIn("runtime delete failed", output)
        self.assertIn("removed=0", output)

    def test_waits_for_async_deletion_before_reporting_removed(self):
        images = {IOS_ID: image(IOS_ID, host.TARGET, host.IOS),
                  OTHER_ID: image(OTHER_ID, "unused", "com.apple.platform.watchsimulator")}
        results = [subprocess.CompletedProcess([], 0, "/selected/simctl", ""),
                   subprocess.CompletedProcess([], 0, "", "")]
        with mock.patch.object(host, "runtime_list", side_effect=[images, images, {IOS_ID: images[IOS_ID]}]), \
                mock.patch.object(host, "run", side_effect=results), \
                mock.patch.object(host.time, "sleep") as sleep, contextlib.redirect_stdout(io.StringIO()) as output:
            host.cleanup()
        sleep.assert_called_once()
        self.assertIn("removed=1", output.getvalue())

    def test_list_errors_and_timeout_are_best_effort(self):
        for error in (OSError("not installed"), ValueError("invalid JSON"), subprocess.TimeoutExpired("simctl", 15)):
            with self.subTest(error=error), mock.patch.object(host, "runtime_list", side_effect=error), contextlib.redirect_stdout(io.StringIO()) as output:
                host.cleanup()
                self.assertIn("cleanup incomplete", output.getvalue())

    def test_resource_commands_are_read_only_and_best_effort(self):
        with mock.patch.object(host, "run", side_effect=OSError("not installed")) as command, contextlib.redirect_stdout(io.StringIO()) as output:
            host.resources("after-boot")
        self.assertIn("cpu_count=", output.getvalue())
        self.assertIn("load_average=", output.getvalue())
        self.assertEqual([call.args[0] for call in command.call_args_list], [["sysctl", "hw.memsize"], ["vm_stat"]])


if __name__ == "__main__":
    unittest.main()
