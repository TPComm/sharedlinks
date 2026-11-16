#!/usr/bin/env bash
set -euo pipefail

# Emit only failures whose every recorded issue is infrastructure-related. A shell crash
# elsewhere in the log must never turn an assertion failure into a recoverable failure.
awk -v selection="${2:-/dev/null}" '
  function test_id(line) {
    sub(/^.*LinksUITests\./, "", line)
    sub(/\].*/, "", line)
    sub(/ /, "/", line)
    return line
  }
  /The system shell \(SpringBoard.*probably crashed/ { shell_crashed = 1 }
  /Lost connection to test process|Test crashed with signal term\./ {
    if ($0 !~ /error: -\[/ && active != "" && !completed[active]) killed[active] = 1
  }
  /Test crashed with signal/ && !/Test crashed with signal term\./ { unsafe_signal = 1 }
  /SIG(SEGV|ABRT|BUS|ILL|FPE|TRAP)|EXC_BAD_ACCESS/ { unsafe_signal = 1 }
  /XCTAssert.*failed|Asynchronous wait failed/ { assertion_failure = 1 }
  /^UI test result contains unrecognized failure/ { unknown_result = 1 }
  /^Test Case .*LinksUITests\.[A-Za-z0-9_]+ [A-Za-z0-9_]+.* started/ {
    active = test_id($0)
    started[active] = 1
  }
  /error: -\[LinksUITests\.[A-Za-z0-9_]+ [A-Za-z0-9_]+\] :/ {
    test = $0
    sub(/^.*error: -\[LinksUITests\./, "", test)
    sub(/\] :.*/, "", test)
    sub(/ /, "/", test)
    if (/Lost connection to test process|Test crashed with signal term\./) killed[test] = 1
    else if (/Lost connection to the application/) crash[test] = 1
    else if (/Failed to launch .*Timed out while launching/) launch[test] = 1
    else if (/Failed to launch .*Simulator device failed to launch|Failed to launch .*system shell \(SpringBoard/) shell_launch[test] = 1
    else genuine[test] = 1
  }
  /^Test Case .*LinksUITests\.[A-Za-z0-9_]+ [A-Za-z0-9_]+.* (passed|failed|skipped) / {
    test = $0
    sub(/^.*LinksUITests\./, "", test)
    sub(/\].*/, "", test)
    sub(/ /, "/", test)
    completed[test] = 1
    if (active == test) active = ""
    if ($0 ~ / failed /) failed[test] = 1
  }
  END {
    for (test in genuine) exit 1
    if (unsafe_signal || unknown_result || assertion_failure) exit 1
    while ((getline expected < selection) > 0) {
      sub(/^LinksUITests\//, "", expected)
      if (!completed[expected]) {
        missing[expected] = 1
        if (started[expected] && killed[expected]) interrupted = 1
        else if (started[expected]) unknown_interruption = 1
      }
    }
    close(selection)
    if (!interrupted || unknown_interruption) {
      for (test in missing) {
        print "warning: UI test selection incomplete; refusing recovery: " test > "/dev/stderr"
        exit 1
      }
    }
    for (test in failed) {
      if (genuine[test] || (crash[test] && !shell_crashed) || !(launch[test] || (shell_crashed && (crash[test] || shell_launch[test])))) exit 1
    }
    for (test in failed) {
      kind = (shell_crashed && (crash[test] || shell_launch[test])) ? "crash" : "launch"
      print kind, test
    }
    for (test in missing) print "crash", test
  }
' "$1" | sort
