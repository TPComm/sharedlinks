#!/usr/bin/env python3
import os
import plistlib
import sys


def configure(specification, environment):
    if "TestConfigurations" in specification:
        targets = [target for configuration in specification["TestConfigurations"]
                   for target in configuration.get("TestTargets", [])]
    else:
        targets = [value for key, value in specification.items()
                   if not key.startswith("__") and isinstance(value, dict)]
    if not targets:
        raise ValueError("xctestrun contains no test targets")
    for target in targets:
        for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
            target.setdefault(key, {}).update(environment)
    return specification


if __name__ == "__main__":
    environment = {key.removeprefix("TEST_RUNNER_"): value for key, value in os.environ.items()
                   if key.startswith("TEST_RUNNER_LINKS_")}
    with open(sys.argv[1], "rb") as source:
        specification = configure(plistlib.load(source), environment)
    with open(sys.argv[2], "wb") as destination:
        plistlib.dump(specification, destination)
