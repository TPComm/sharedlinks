#!/usr/bin/env bash
set -euo pipefail

# Narrow the test list on stdin (LinksUITests/<Class>/<test>) to what extra xcodebuild arguments
# select, so the recovery check waits only for tests that run. -only-testing and -skip-testing
# take a target, a class or a single test.
awk -v args="$*" '
  BEGIN {
    n = split(args, list, " ")
    for (i = 1; i <= n; i++) {
      if (list[i] ~ /^-only-testing:/) { only[sub_id(list[i])] = 1; any_only = 1 }
      else if (list[i] ~ /^-skip-testing:/) skip[sub_id(list[i])] = 1
    }
  }
  function sub_id(arg) { sub(/^-(only|skip)-testing:/, "", arg); return arg }
  function picked(set, test,    id) {
    for (id in set) if (test == id || index(test, id "/") == 1) return 1
    return 0
  }
  (!any_only || picked(only, $0)) && !picked(skip, $0)
'
