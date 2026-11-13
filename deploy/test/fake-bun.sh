#!/usr/bin/env bash
# A stand-in for bun that makes deploy.sh ship a build that can't start, to exercise its automatic
# rollback (see .github/workflows/deploy-e2e.yml):
#
#   BUN=$PWD/deploy/test/fake-bun.sh deploy/deploy.sh root@host
#
# `test` succeeds without running (the real suite already ran in that job), `build` writes an
# executable that exits 1 to --outfile, and anything else goes to the real bun.
set -euo pipefail

case "${1:-}" in
  test)
    echo "fake-bun: skipping the tests" >&2
    ;;
  build)
    out=
    while [ $# -gt 0 ]; do
      case $1 in
        --outfile) out=${2:?fake-bun: --outfile needs a path}; shift ;;
        --outfile=*) out=${1#--outfile=} ;;
      esac
      shift
    done
    [ -n "$out" ] || { echo "fake-bun: build without --outfile" >&2; exit 2; }
    mkdir -p "$(dirname "$out")"
    printf '#!/bin/sh\necho "links-server: deliberately broken build from deploy/test/fake-bun.sh" >&2\nexit 1\n' > "$out"
    chmod 755 "$out"
    echo "fake-bun: wrote a broken links-server to $out" >&2
    ;;
  *)
    real=$(command -v bun) || { echo "fake-bun: no real bun on PATH for: $*" >&2; exit 127; }
    exec "$real" "$@"
    ;;
esac
