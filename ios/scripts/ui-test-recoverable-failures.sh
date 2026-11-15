#!/usr/bin/env bash
set -euo pipefail

# Emit only failures whose every recorded issue is infrastructure-related. A shell crash
# elsewhere in the log must never turn an assertion failure into a recoverable failure.
awk '
  /The system shell \(SpringBoard.*probably crashed|Failed to launch app with identifier: .*uitests.xctrunner|Simulator device failed to launch .*uitests.xctrunner/ { shell_crashed = 1 }
  /error: -\[LinksUITests\.[A-Za-z0-9_]+ [A-Za-z0-9_]+\] :/ {
    test = $0
    sub(/^.*error: -\[LinksUITests\./, "", test)
    sub(/\] :.*/, "", test)
    sub(/ /, "/", test)
    if (/Lost connection to the application/) crash[test] = 1
    else if (/Failed to launch .*Timed out while launching/) launch[test] = 1
    else if (/Failed to launch .*Simulator device failed to launch|Failed to launch .*system shell \(SpringBoard/) shell_launch[test] = 1
    else genuine[test] = 1
  }
  /^Test Case .*LinksUITests\.[A-Za-z0-9_]+ [A-Za-z0-9_]+.* failed / {
    test = $0
    sub(/^.*LinksUITests\./, "", test)
    sub(/\].*/, "", test)
    sub(/ /, "/", test)
    failed[test] = 1
  }
  END {
    for (test in failed) {
      if (genuine[test] || !(crash[test] || launch[test] || (shell_crashed && shell_launch[test]))) exit 1
    }
    for (test in failed) {
      kind = (crash[test] || (shell_crashed && shell_launch[test])) ? "crash" : "launch"
      print kind, test
    }
  }
' "$1" | sort
