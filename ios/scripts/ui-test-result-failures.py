#!/usr/bin/env python3
import json
import re
import sys


def failures(result):
    issues = result.get("issues", {}).get("testFailureSummaries", {}).get("_values", [])
    for issue in issues:
        name = issue.get("testCaseName", {}).get("_value", "")
        message = issue.get("message", {}).get("_value", "")
        match = re.fullmatch(r"(?:LinksUITests\.)?(\w+)\.(test\w+)\(\)", name)
        if not match or not message:
            yield "UI test result contains unrecognized failure"
            continue
        message = " ".join(message.splitlines())
        yield f"xcresult: error: -[LinksUITests.{match[1]} {match[2]}] : {message}"


if __name__ == "__main__":
    for failure in failures(json.load(sys.stdin)):
        print(failure)
