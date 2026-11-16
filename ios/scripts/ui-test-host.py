#!/usr/bin/env python3
"""Best-effort CI runtime cleanup and host resource snapshots; never edit device sets."""

import argparse
import json
import os
import re
import subprocess
import time


IOS = "com.apple.platform.iphonesimulator"
OTHER_PLATFORMS = {
    "com.apple.platform.appletvsimulator",
    "com.apple.platform.watchsimulator",
    "com.apple.platform.xrsimulator",
}
TARGET = "com.apple.CoreSimulator.SimRuntime.iOS-27-2"


def run(args, timeout=10):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)


def runtime_list(timeout):
    result = run(["xcrun", "simctl", "runtime", "list", "-j"], timeout)
    if result.returncode:
        raise ValueError(f"runtime list failed: {result.stderr.strip()}")
    images = json.loads(result.stdout)
    if not isinstance(images, dict) or not all(isinstance(v, dict) for v in images.values()):
        raise ValueError("unrecognized runtime list schema")
    return images


def is_target(image):
    identifier = image.get("runtimeIdentifier", "")
    return identifier == TARGET or identifier.startswith(TARGET + "-")


def cleanup(timeout=120):
    started = time.monotonic()
    deadline = started + timeout
    removed = 0

    def budget():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("runtime cleanup deadline reached")
        return min(15, remaining)

    try:
        images = runtime_list(budget())
        if not any(is_target(image) for image in images.values()):
            print("warning: iOS 27.2 runtime not found; leaving all runtime images untouched", flush=True)
            return
        candidates = {}
        for key, image in sorted(images.items()):
            identifier = image.get("identifier", key)
            runtime = image.get("runtimeIdentifier", "unknown")
            print(f"Runtime image: {identifier} {runtime} state={image.get('state', 'unknown')}", flush=True)
            if is_target(image):
                print(f"Runtime cleanup preserved: {identifier} {runtime}", flush=True)
                continue
            if image.get("platformIdentifier") not in OTHER_PLATFORMS | {IOS}:
                print(f"warning: leaving unrecognized runtime platform untouched: {identifier}", flush=True)
                continue
            if not re.fullmatch(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}", identifier):
                print(f"warning: leaving unrecognized runtime identifier untouched: {identifier}", flush=True)
                continue
            candidates[identifier] = runtime
        if not candidates:
            return
        result = run(["xcrun", "--find", "simctl"], budget())
        if result.returncode or not result.stdout.strip().startswith("/"):
            raise ValueError("cannot locate the selected Xcode's simctl")
        simctl = result.stdout.strip()
        requested = set()
        for identifier, runtime in candidates.items():
            phase = time.monotonic()
            result = run(["sudo", "-n", simctl, "runtime", "delete", identifier], budget())
            elapsed = time.monotonic() - phase
            if result.returncode:
                print(f"warning: runtime delete failed: {identifier} {runtime} after {elapsed:.1f}s: "
                      f"{result.stderr.strip()}", flush=True)
            else:
                requested.add(identifier)
                print(f"Runtime deletion requested: {identifier} {runtime} in {elapsed:.1f}s", flush=True)
        # Deletion is asynchronous; keep its unmount work out of the build and boot phases.
        remaining = requested.copy()
        while remaining:
            current = runtime_list(budget())
            present = {image.get("identifier", key) for key, image in current.items()}
            for identifier in sorted(remaining - present):
                removed += 1
                print(f"Runtime cleanup removed: {identifier} {candidates[identifier]}", flush=True)
            remaining &= present
            if remaining:
                time.sleep(min(2, budget()))
    except (OSError, ValueError, TypeError, TimeoutError, subprocess.TimeoutExpired) as error:
        print(f"warning: best-effort runtime cleanup incomplete: {error}", flush=True)
    finally:
        print(f"Runtime cleanup completed in {time.monotonic() - started:.1f}s; removed={removed}", flush=True)


def resources(phase):
    print(f"Host resources ({phase}): cpu_count={os.cpu_count()} load_average={os.getloadavg()}", flush=True)
    for args in (["sysctl", "hw.memsize"], ["vm_stat"]):
        try:
            result = run(args)
            if result.returncode:
                print(f"warning: {' '.join(args)} failed: {result.stderr.strip()}", flush=True)
            else:
                print(result.stdout.strip(), flush=True)
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"warning: resource snapshot incomplete: {error}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("job-start", "after-boot"))
    phase = parser.parse_args().phase
    try:
        resources(phase)
        if phase == "job-start":
            cleanup()
    except Exception as error:
        print(f"warning: best-effort host preparation incomplete: {error}", flush=True)


if __name__ == "__main__":
    main()
