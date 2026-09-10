#!/usr/bin/env bash
#
# Runs inside a distro container (invoked by docker-matrix.sh):
#   1. install the selected components
#   2. source env.sh and print each tool's version
#   3. re-run and assert env.sh is byte-identical (idempotency)
#
# $1 = selection args, e.g. "--with go,node,bun,pnpm,git" or "--all"

set -euo pipefail

SEL=${1:-"--with go,node,bun,pnpm,git"}
ENV_SH="${XDG_CONFIG_HOME:-$HOME/.config}/dev-kit/env.sh"

dk_ver() {
  local t=$1
  command -v "$t" >/dev/null 2>&1 || { printf '  %-8s (not installed)\n' "$t"; return; }
  local out=""
  case "$t" in
    java)   out=$(java -version 2>&1 | head -1);;
    go)     out=$(go version 2>&1 | head -1);;
    mvn)    out=$(mvn -v 2>&1 | head -1);;
    gradle) out=$(gradle -v 2>&1 | grep -i '^Gradle' | head -1);;
    *)      out=$("$t" --version 2>&1 | head -1);;
  esac
  printf '  %-8s %s\n' "$t" "$out"
}

echo "### install ($SEL)"
# shellcheck disable=SC2086
bash /src/install.sh $SEL --yes --mirror off

[ -f "$ENV_SH" ] || { echo "FAIL: env.sh not generated"; exit 1; }
h1=$(sha256sum "$ENV_SH" | cut -d' ' -f1)

# shellcheck disable=SC1090
. "$ENV_SH"
echo "### versions"
for t in git java mvn gradle go cargo node pnpm bun; do dk_ver "$t"; done

echo "### re-run (idempotency)"
# shellcheck disable=SC2086
bash /src/install.sh $SEL --yes --mirror off >/dev/null 2>&1
h2=$(sha256sum "$ENV_SH" | cut -d' ' -f1)
if [ "$h1" != "$h2" ]; then
  echo "FAIL: env.sh changed on re-run"; exit 1
fi

echo "PASS"
