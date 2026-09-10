#!/usr/bin/env bash
#
# Run install.sh across a matrix of Linux distros in Docker.
#
#   tests/docker-matrix.sh                 # default image list, fast component set
#   tests/docker-matrix.sh ubuntu:24.04    # one image
#   DK_ALL=1 tests/docker-matrix.sh        # full --all (slow: JDK + Rust per image)
#   DK_WITH=go,rust tests/docker-matrix.sh # custom component set
#
# Each image: install -> source env.sh + print versions -> re-run + assert
# env.sh is byte-identical. The heavier SDKMAN/Rust paths are validated on
# ubuntu-latest natively in CI (.github/workflows/ci.yml); this matrix focuses
# on the per-distro package-manager and download/extract paths.

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)

IMAGES=("$@")
if [ ${#IMAGES[@]} -eq 0 ]; then
  IMAGES=(ubuntu:24.04 debian:12 fedora:42 archlinux:latest alpine:3.21 opensuse/leap:15.6)
fi

if [ "${DK_ALL:-0}" = 1 ]; then
  SEL="--all"
else
  SEL="--with ${DK_WITH:-go,node,bun,pnpm,git}"
fi

pass=0
fail=0
failed=""

for img in "${IMAGES[@]}"; do
  echo "=================================================================="
  echo "  $img    ($SEL)"
  echo "=================================================================="
  # busybox/alpine has no bash until we add it; everything else has bash.
  if docker run --rm -v "$REPO:/src:ro" "$img" sh -c '
      if command -v apk >/dev/null 2>&1 && ! command -v bash >/dev/null 2>&1; then apk add --no-cache bash >/dev/null; fi
      exec bash /src/tests/incontainer.sh "'"$SEL"'"
    '; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed="$failed $img"
  fi
  echo
done

echo "=================================================================="
echo "  matrix result — PASS: $pass  FAIL: $fail${failed:+  (failed:$failed)}"
echo "=================================================================="
[ "$fail" -eq 0 ]
