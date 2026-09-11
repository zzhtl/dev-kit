#!/usr/bin/env bash
#
# dev-kit — one-shot developer environment installer for macOS and Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/zzhtl/dev-kit/main/install.sh | bash
#   ./install.sh                      # arrow-key menu: install / uninstall, options and all
#   ./install.sh --with go,node --yes # ... or drive the whole thing from flags
#
# Re-running updates every selected tool to the latest release and removes the
# versions it supersedes. Language toolchains live under $HOME; sudo is used only
# to install system packages (git, curl, unzip, ...).
#
# Written to run on the bash that ships with a stock machine, including macOS
# bash 3.2 — so: no associative arrays, no mapfile, no ${var^^}.

set -Eeuo pipefail

DEVKIT_VERSION="0.1.0"
DK_COMPONENTS_ALL="git jdk maven gradle go rust node pnpm bun"
DK_ORDER="git jdk maven gradle go rust node pnpm bun"

# ---- argument / selection state (initialised for set -u) --------------------
DK_ALL=0
DK_WITH=""
DK_YES=0
DK_SELECTED=""
DK_JDK_VERSION=""
DK_GO_VERSION=""
DK_RUST_VERSION=""
DK_NODE_VERSION=""
DK_MIRROR_ARG="auto"
DK_NO_SHELL_INIT=0
DK_MODE="install"
DK_MODE_FORCED=0
DK_KEEP_CACHE=0
DK_CONFIRMED=0
DK_LANG_ARG=""
DK_NO_TUI=0

# ---- interactive UI state --------------------------------------------------
DK_LANG="en"
DK_UTF8=0
DK_UI_ON=0
DK_UI_STTY=""
DK_UI_LINES=0
DK_UI_COLS=80
DK_UI_NOTES=""
DK_UI_RESULT=""
DK_UI_CUR=">"
DK_UI_GO="> "
DK_UI_BACK="< "
DK_UI_DOT="*"

# ---- resolved runtime state ------------------------------------------------
DK_OS=""
DK_ARCH=""
DK_GOARCH=""
DK_LIBC="glibc"
DK_PKG=""
DK_SDKMAN_PLATFORM=""
DK_MIRROR="off"
SUDO=""
DK_NO_SUDO=0
DK_TMP=""
DK_FAILED=""
DK_SDKMAN_OK=0
DK_BASH=""            # a bash >= 4 to drive SDKMAN with (see dk_find_bash4)
DK_JDK_MAJORS=""
DK_JDK_DEFAULT=""

# ---------------------------------------------------------------------------
# logging (stderr, so stdout stays parseable)
# ---------------------------------------------------------------------------
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_RST=""
fi
dk_info()  { printf '%s%s%s\n'   "$C_DIM" "$*" "$C_RST" >&2; }
dk_step()  { printf '\n%s==>%s %s\n' "$C_BLU" "$C_RST" "$*" >&2; }
dk_ok()    { printf '%s  ok%s %s\n'  "$C_GRN" "$C_RST" "$*" >&2; }
dk_warn()  { printf '%swarn%s %s\n'  "$C_YEL" "$C_RST" "$*" >&2; }
dk_err()   { printf '%serr %s %s\n'  "$C_RED" "$C_RST" "$*" >&2; }
dk_die()   { dk_err "$*"; exit 1; }

usage() {
  cat >&2 <<EOF
dev-kit $DEVKIT_VERSION — install/update a developer toolchain

Usage: install.sh [options]

With no selection and a terminal attached you get an interactive menu: pick
install or uninstall, tick the components with the arrow keys and space, and
review every option (versions, mirrors, shell init) before it runs. Every one
of those choices also has a flag, so scripts never need the menu.

Selection:
  --all                     install every component
  --with a,b,c              install these (of: $DK_COMPONENTS_ALL)
  --yes                     no prompts; with no selection, update what is installed
  (no selection + a TTY)    interactive menu

Versions:
  --jdk-version 21[,25]     JDK major(s); default: newest LTS (>= 21)
  --go-version 1.27.1       pin Go; default: latest
  --rust-version 1.90.0     pin Rust (or stable/beta/nightly); default: stable
  --node-version lts|24     Node line; default: latest LTS

Uninstall:
  --uninstall               remove components instead of installing them
                            (select with --all / --with / the menu). Removes the
                            toolchain, its caches, and dev-kit's own config.
  --keep-cache              with --uninstall, keep download/build caches
  --yes                     with --uninstall, skip the confirmation prompt

Other:
  --mirror auto|cn|off      package mirrors; auto probes network (default auto)
  --no-shell-init           do not touch shell rc files
  --lang zh|en              menu language (default: from \$LANG; \$DEVKIT_LANG works too)
  --no-tui                  plain numbered menu instead of the arrow-key one
  --version                 print version
  --help                    this help

Components: git, jdk (Temurin via SDKMAN), maven, gradle, go, rust (rustup),
node (via fnm), pnpm, bun.

User-authored files are never deleted (e.g. ~/.gitconfig, ~/.m2/settings.xml,
~/.gradle/gradle.properties, your own ~/.npmrc lines); they are reported instead.
EOF
}

dk_comp_desc() {
  if [ "$DK_LANG" = zh ]; then
    case "$1" in
      git)    echo "Git";;
      jdk)    echo "JDK（Temurin，经 SDKMAN）";;
      maven)  echo "Apache Maven";;
      gradle) echo "Gradle";;
      go)     echo "Go";;
      rust)   echo "Rust（rustup）";;
      node)   echo "Node.js（经 fnm）";;
      pnpm)   echo "pnpm";;
      bun)    echo "Bun";;
      *)      echo "";;
    esac
    return 0
  fi
  case "$1" in
    git)    echo "Git";;
    jdk)    echo "JDK (Temurin, via SDKMAN)";;
    maven)  echo "Apache Maven";;
    gradle) echo "Gradle";;
    go)     echo "Go";;
    rust)   echo "Rust (rustup)";;
    node)   echo "Node.js (via fnm)";;
    pnpm)   echo "pnpm";;
    bun)    echo "Bun";;
    *)      echo "";;
  esac
}

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------
dk_selected() { case " $DK_SELECTED " in *" $1 "*) return 0;; *) return 1;; esac; }
dk_selected_any() { local x; for x in "$@"; do dk_selected "$x" && return 0; done; return 1; }
dk_is_valid_comp() { case " $DK_COMPONENTS_ALL " in *" $1 "*) return 0;; *) return 1;; esac; }
dk_is_semver() { printf '%s' "$1" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; }

dk_require_cmds() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || dk_warn "required command not found: $c"
  done
}

dk_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# dk_fetch URL DEST [SHA256]
dk_fetch() {
  local url=$1 dest=$2 sha=${3:-} tmp
  tmp="$dest.part"
  local flags="-fL --proto =https --tlsv1.2 --connect-timeout 15 --retry 3 --retry-delay 2"
  if [ -t 2 ]; then flags="$flags -#"; else flags="$flags -sS"; fi
  rm -f "$tmp"
  # shellcheck disable=SC2086
  if ! curl $flags -o "$tmp" "$url"; then
    rm -f "$tmp"; dk_err "download failed: $url"; return 1
  fi
  if [ -n "$sha" ]; then
    local got; got=$(dk_sha256 "$tmp")
    if [ "$got" != "$sha" ]; then
      rm -f "$tmp"; dk_err "checksum mismatch for $url"; return 1
    fi
  fi
  mv -f "$tmp" "$dest"
}

# first "key":"value" out of JSON on stdin
#
# `sed -n 1p`, not `head -1`, on purpose (same below): head closes the pipe after
# the first line, the producer dies on SIGPIPE, and under `set -o pipefail` the
# pipeline then reports failure even though the value was read fine. sed drains.
dk_json_str() {
  grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" | sed -n '1p' | sed -E 's/.*:[[:space:]]*"//; s/"$//'
}

# compare version-like strings by their numeric groups; true if $1 > $2
dk_ver_gt() {
  local a b
  a=$(printf '%s' "$1" | grep -oE '[0-9]+' | tr '\n' ' ')
  b=$(printf '%s' "$2" | grep -oE '[0-9]+' | tr '\n' ' ')
  awk -v a="$a" -v b="$b" 'BEGIN{
    na=split(a,A," "); nb=split(b,B," "); n=(na>nb?na:nb);
    for(i=1;i<=n;i++){x=(i<=na?A[i]:0)+0; y=(i<=nb?B[i]:0)+0;
      if(x>y){print "gt"; exit} if(x<y){print "lt"; exit}}
    print "eq"
  }' | grep -q gt
}

# newest line from stdin, compared numerically
dk_ver_max() {
  local best="" v
  while IFS= read -r v; do
    [ -z "$v" ] && continue
    if [ -z "$best" ] || dk_ver_gt "$v" "$best"; then best="$v"; fi
  done
  printf '%s' "$best"
}

# extract single top-level dir of an archive into DEST (replacing DEST)
# dk_extract_to ARCHIVE DEST [KNOWN_TOP]
dk_extract_to() {
  local archive=$1 dest=$2 top=${3:-} tmp only cnt
  tmp="$DK_TMP/ex.$$.$RANDOM"; rm -rf "$tmp"; mkdir -p "$tmp"
  case "$archive" in
    *.zip) unzip -q "$archive" -d "$tmp";;
    *)     tar -xzf "$archive" -C "$tmp";;
  esac
  rm -rf "$dest"; mkdir -p "$(dirname "$dest")"
  if [ -n "$top" ] && [ -d "$tmp/$top" ]; then
    mv "$tmp/$top" "$dest"
  else
    cnt=$(ls -1 "$tmp" | wc -l | tr -d ' ')
    only=$(ls -1 "$tmp" | sed -n '1p')
    if [ "$cnt" = 1 ] && [ -d "$tmp/$only" ]; then
      mv "$tmp/$only" "$dest"
    else
      mkdir -p "$dest"; mv "$tmp"/* "$dest"/
    fi
  fi
  rm -rf "$tmp"
}

# ---- state file (key=value) ------------------------------------------------
dk_state_file() { printf '%s/state' "$DK_CONFIG_DIR"; }
dk_state_get() {
  local f line; f=$(dk_state_file)
  [ -f "$f" ] || return 0
  # a missing key must yield empty output, not a pipeline failure (pipefail + set -e)
  line=$(grep -E "^$1=" "$f" 2>/dev/null | tail -1) || true
  printf '%s' "${line#*=}"
}
dk_state_set() {
  local f; f=$(dk_state_file)
  mkdir -p "$DK_CONFIG_DIR"; touch "$f"
  if grep -qE "^$1=" "$f"; then
    sed -i.bak -E "s|^$1=.*|$1=$2|" "$f" && rm -f "$f.bak"
  else
    printf '%s=%s\n' "$1" "$2" >> "$f"
  fi
}

# ---- marker-block editing --------------------------------------------------
dk_upsert_block() {
  local file=$1 block=$2 begin="# >>> dev-kit >>>" end="# <<< dev-kit <<<"
  touch "$file"
  if grep -qF "$begin" "$file"; then
    awk -v b="$begin" -v e="$end" -v repl="$block" '
      $0==b {print repl; skip=1; next}
      $0==e {skip=0; next}
      skip!=1 {print}
    ' "$file" > "$file.dk.tmp" && mv "$file.dk.tmp" "$file"
  else
    printf '\n%s\n' "$block" >> "$file"
  fi
}
dk_remove_block() {
  local file=$1 begin=$2 end=$3
  [ -f "$file" ] || return 0
  awk -v b="$begin" -v e="$end" '
    $0==b {skip=1; next}
    $0==e {skip=0; next}
    skip!=1 {print}
  ' "$file" > "$file.dk.tmp" && mv "$file.dk.tmp" "$file"
}

# ---------------------------------------------------------------------------
# platform / dirs / privileges / mirror
# ---------------------------------------------------------------------------
dk_detect_platform() {
  local u; u=$(uname -s)
  case "$u" in
    Linux)  DK_OS=linux;;
    Darwin) DK_OS=darwin;;
    *) dk_die "unsupported OS: $u (this script covers macOS and Linux; use install.ps1 on Windows)";;
  esac

  local m; m=$(uname -m)
  case "$m" in
    x86_64|amd64) DK_ARCH=amd64;;
    aarch64|arm64) DK_ARCH=arm64;;
    *) dk_die "unsupported architecture: $m";;
  esac
  # a Rosetta shell reports x86_64 on Apple silicon
  if [ "$DK_OS" = darwin ] && [ "$DK_ARCH" = amd64 ]; then
    if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then DK_ARCH=arm64; fi
  fi
  DK_GOARCH=$DK_ARCH

  if [ "$DK_OS" = linux ]; then
    if [ -f /etc/alpine-release ] || (ldd --version 2>&1 | grep -qi musl); then DK_LIBC=musl; fi
  fi

  case "$DK_OS-$DK_ARCH" in
    linux-amd64)  DK_SDKMAN_PLATFORM=linuxx64;;
    linux-arm64)  DK_SDKMAN_PLATFORM=linuxarm64;;
    darwin-amd64) DK_SDKMAN_PLATFORM=darwinx64;;
    darwin-arm64) DK_SDKMAN_PLATFORM=darwinarm64;;
  esac

  if [ "$DK_OS" = darwin ]; then
    DK_PKG=xcode
  elif command -v apt-get >/dev/null 2>&1; then DK_PKG=apt
  elif command -v dnf     >/dev/null 2>&1; then DK_PKG=dnf
  elif command -v yum     >/dev/null 2>&1; then DK_PKG=yum
  elif command -v pacman  >/dev/null 2>&1; then DK_PKG=pacman
  elif command -v zypper  >/dev/null 2>&1; then DK_PKG=zypper
  elif command -v apk     >/dev/null 2>&1; then DK_PKG=apk
  else DK_PKG=unknown
  fi
}

dk_setup_dirs() {
  DK_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/dev-kit"
  DK_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dev-kit"
  SDKMAN_DIR="${SDKMAN_DIR:-$HOME/.sdkman}"
  CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
  RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
  FNM_DIR="${FNM_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/fnm}"
  BUN_INSTALL="${BUN_INSTALL:-$HOME/.bun}"
  PNPM_HOME="${PNPM_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/pnpm}"
  mkdir -p "$DK_CONFIG_DIR" "$DK_DATA_DIR/bin"
  DK_TMP=$(mktemp -d 2>/dev/null || mktemp -d -t devkit)
  trap 'dk_cleanup' EXIT
  trap 'dk_cleanup; exit 130' INT
  trap 'dk_cleanup; exit 143' TERM
}

# idempotent: runs from the EXIT trap and possibly from a signal before it
dk_cleanup() {
  dk_ui_close 2>/dev/null || true
  [ -n "$DK_TMP" ] && rm -rf "$DK_TMP"
  return 0
}

dk_setup_sudo() {
  if [ "$(id -u)" = 0 ]; then
    SUDO=""
  elif command -v sudo >/dev/null 2>&1; then
    if [ -e /dev/tty ]; then
      SUDO="sudo"
    elif sudo -n true 2>/dev/null; then
      SUDO="sudo"
    else
      DK_NO_SUDO=1
    fi
  else
    DK_NO_SUDO=1
  fi
}

dk_probe() { curl -sS -I -o /dev/null --connect-timeout 3 -m 4 "$1" >/dev/null 2>&1; }

dk_detect_mirror() {
  case "${DEVKIT_MIRROR:-$DK_MIRROR_ARG}" in
    cn)  DK_MIRROR=cn;  return;;
    off) DK_MIRROR=off; return;;
  esac
  # auto
  if dk_probe https://github.com && dk_probe https://go.dev; then
    DK_MIRROR=off
  elif dk_probe https://mirrors.tuna.tsinghua.edu.cn; then
    DK_MIRROR=cn
    dk_info "network probe failed for github.com/go.dev; using China mirrors (override with --mirror off)"
  else
    DK_MIRROR=off
  fi
}

# ---------------------------------------------------------------------------
# argument parsing
# ---------------------------------------------------------------------------
dk_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) DK_ALL=1;;
      --with) shift; [ $# -gt 0 ] || dk_die "--with needs an argument"; DK_WITH="$1";;
      --with=*) DK_WITH="${1#*=}";;
      --yes|-y) DK_YES=1;;
      --jdk-version) shift; DK_JDK_VERSION="$1";;
      --jdk-version=*) DK_JDK_VERSION="${1#*=}";;
      --go-version) shift; DK_GO_VERSION="$1";;
      --go-version=*) DK_GO_VERSION="${1#*=}";;
      --rust-version) shift; DK_RUST_VERSION="$1";;
      --rust-version=*) DK_RUST_VERSION="${1#*=}";;
      --node-version) shift; DK_NODE_VERSION="$1";;
      --node-version=*) DK_NODE_VERSION="${1#*=}";;
      --mirror) shift; DK_MIRROR_ARG="$1";;
      --mirror=*) DK_MIRROR_ARG="${1#*=}";;
      --no-shell-init) DK_NO_SHELL_INIT=1;;
      --lang) shift; DK_LANG_ARG="$1";;
      --lang=*) DK_LANG_ARG="${1#*=}";;
      --no-tui) DK_NO_TUI=1;;
      --uninstall|--remove) DK_MODE=uninstall; DK_MODE_FORCED=1;;
      --keep-cache) DK_KEEP_CACHE=1;;
      --version) echo "dev-kit $DEVKIT_VERSION"; exit 0;;
      --help|-h) usage; exit 0;;
      *) dk_die "unknown option: $1 (see --help)";;
    esac
    shift
  done
  case "$DK_MIRROR_ARG" in auto|cn|off) ;; *) dk_die "--mirror must be auto, cn, or off";; esac
}

# ---------------------------------------------------------------------------
# selection resolution (menu / flags)
# ---------------------------------------------------------------------------
dk_detect_installed() {
  case "$1" in
    git)    command -v git >/dev/null 2>&1;;
    jdk)    for _d in "$SDKMAN_DIR/candidates/java"/*-tem; do [ -d "$_d" ] && return 0; done; return 1;;
    maven)  [ -d "$SDKMAN_DIR/candidates/maven/current" ];;
    gradle) [ -d "$SDKMAN_DIR/candidates/gradle/current" ];;
    go)     [ -x "$DK_DATA_DIR/go/bin/go" ];;
    rust)   [ -x "$CARGO_HOME/bin/rustc" ];;
    node)   [ -x "$DK_DATA_DIR/bin/fnm" ];;
    pnpm)   [ -x "$PNPM_HOME/pnpm" ];;
    bun)    [ -x "$BUN_INSTALL/bin/bun" ];;
    *) return 1;;
  esac
}

dk_nth_comp() {
  local i=1 c
  for c in $DK_COMPONENTS_ALL; do
    [ "$i" = "$1" ] && { printf '%s' "$c"; return 0; }
    i=$((i+1))
  done
  return 1
}

dk_menu() {
  { exec 3<>/dev/tty; } 2>/dev/null || dk_die "no TTY for the menu; use --all or --with a,b,c"
  local sel=" " c title
  if [ "$DK_MODE" = uninstall ]; then
    # start with nothing selected; removal must be an explicit choice
    title="select components to UNINSTALL (installed ones marked *), then press enter"
  else
    title="toggle components to install/update, then press enter"
    for c in $DK_COMPONENTS_ALL; do dk_detect_installed "$c" && sel="$sel$c "; done
  fi
  while :; do
    printf '\n  dev-kit — %s\n\n' "$title" >&3
    local i=1 mark inst
    for c in $DK_COMPONENTS_ALL; do
      mark=" "; case "$sel" in *" $c "*) mark="x";; esac
      inst=""; [ "$DK_MODE" = uninstall ] && dk_detect_installed "$c" && inst="*"
      printf '   [%s] %2d) %-7s%1s %s\n' "$mark" "$i" "$c" "$inst" "$(dk_comp_desc "$c")" >&3
      i=$((i+1))
    done
    printf '\n   a) all   n) none   q) quit   enter) confirm\n   > ' >&3
    local line tok comp
    IFS= read -r line <&3 || line=""
    case "$line" in
      "") break;;
      a|A) sel=" $DK_COMPONENTS_ALL ";;
      n|N) sel=" ";;
      q|Q) exec 3>&-; dk_die "cancelled";;
      *)
        for tok in $line; do
          comp=$(dk_nth_comp "$tok" 2>/dev/null || true)
          [ -n "$comp" ] || continue
          if case "$sel" in *" $comp "*) true;; *) false;; esac; then
            sel=$(printf '%s' "$sel" | sed "s/ $comp / /")
          else
            sel="$sel$comp "
          fi
        done;;
    esac
  done
  exec 3>&-
  DK_SELECTED=$(printf '%s' "$sel" | tr -s ' ' | sed 's/^ //; s/ $//')
}

dk_menu_jdk_majors() {
  local avail def line
  avail=$(dk_available_jdk_majors)
  def=$(dk_default_jdk_majors)
  { exec 3<>/dev/tty; } 2>/dev/null || { DK_JDK_MAJORS="$def"; return; }
  printf '\n  JDK majors to install (space separated, of: %s)\n  > [%s] ' "$avail" "$def" >&3
  IFS= read -r line <&3 || line=""
  exec 3>&-
  [ -n "$line" ] && DK_JDK_MAJORS="$line" || DK_JDK_MAJORS="$def"
}

dk_resolve_selection() {
  if [ "$DK_MODE" = uninstall ]; then
    dk_resolve_uninstall_selection
    return
  fi
  if [ "$DK_ALL" = 1 ]; then
    DK_SELECTED="$DK_COMPONENTS_ALL"
  elif [ -n "$DK_WITH" ]; then
    local c cleaned=""
    for c in $(printf '%s' "$DK_WITH" | tr ',' ' '); do
      dk_is_valid_comp "$c" || dk_die "unknown component: $c (valid: $DK_COMPONENTS_ALL)"
      cleaned="$cleaned $c"
    done
    DK_SELECTED=$(printf '%s' "$cleaned" | sed 's/^ //')
  elif [ "$DK_YES" = 1 ]; then
    local c installed=""
    for c in $DK_COMPONENTS_ALL; do dk_detect_installed "$c" && installed="$installed $c"; done
    [ -n "$installed" ] || dk_die "nothing installed to update; pass --all or --with a,b,c"
    DK_SELECTED=$(printf '%s' "$installed" | sed 's/^ //')
    dk_info "updating installed components:$installed"
  else
    [ -e /dev/tty ] || dk_die "no selection and no TTY; pass --all or --with a,b,c"
    dk_menu
  fi
  [ -n "$DK_SELECTED" ] || dk_die "no components selected"

  # maven/gradle need a JDK
  if dk_selected_any maven gradle && ! dk_selected jdk; then
    if ! command -v java >/dev/null 2>&1 && [ ! -d "$SDKMAN_DIR/candidates/java/current" ]; then
      dk_info "maven/gradle need a JDK; adding jdk to the selection"
      DK_SELECTED="$DK_SELECTED jdk"
    fi
  fi

  # JDK majors
  if dk_selected jdk; then
    if [ -n "$DK_JDK_VERSION" ]; then
      DK_JDK_MAJORS=$(printf '%s' "$DK_JDK_VERSION" | tr ',' ' ')
    elif [ "$DK_YES" = 1 ] || [ "$DK_ALL" = 1 ] || [ -n "$DK_WITH" ]; then
      DK_JDK_MAJORS=$(dk_default_jdk_majors)
    else
      dk_menu_jdk_majors
    fi
    DK_JDK_DEFAULT=$(printf '%s' "$DK_JDK_MAJORS" | awk '{print $1}')
  fi
}

dk_resolve_uninstall_selection() {
  local c installed=""
  for c in $DK_COMPONENTS_ALL; do dk_detect_installed "$c" && installed="$installed $c"; done

  if [ "$DK_ALL" = 1 ]; then
    [ -n "$installed" ] || dk_die "nothing installed by dev-kit to uninstall"
    DK_SELECTED=$(printf '%s' "$installed" | sed 's/^ //')
  elif [ -n "$DK_WITH" ]; then
    local cleaned=""
    for c in $(printf '%s' "$DK_WITH" | tr ',' ' '); do
      dk_is_valid_comp "$c" || dk_die "unknown component: $c (valid: $DK_COMPONENTS_ALL)"
      cleaned="$cleaned $c"
    done
    DK_SELECTED=$(printf '%s' "$cleaned" | sed 's/^ //')
  elif [ -e /dev/tty ] && [ "$DK_YES" != 1 ]; then
    dk_menu
  else
    dk_die "uninstall needs an explicit selection: pass --all or --with a,b,c"
  fi
  [ -n "$DK_SELECTED" ] || dk_die "no components selected to uninstall"
}

dk_available_jdk_majors() {
  local m
  m=$(curl -fsSL -m 8 "https://api.adoptium.net/v3/info/available_releases" 2>/dev/null \
        | grep -oE '"available_releases"[^]]*]' | grep -oE '[0-9]+' | awk '$1>=21' | sort -n | tr '\n' ' ') || m=""
  [ -n "$m" ] && printf '%s' "$(echo "$m" | sed 's/ $//')" || printf '21 25 26'
}
dk_default_jdk_majors() {
  local lts
  lts=$(curl -fsSL -m 8 "https://api.adoptium.net/v3/info/available_releases" 2>/dev/null \
        | grep -oE '"available_lts_releases"[^]]*]' | grep -oE '[0-9]+' | awk '$1>=21' | sort -n | tail -1) || lts=""
  [ -n "$lts" ] && printf '%s' "$lts" || printf '25'
}

# ---------------------------------------------------------------------------
# system prerequisites (the only place sudo is used)
# ---------------------------------------------------------------------------
dk_prereqs_mac() {
  if xcode-select -p >/dev/null 2>&1; then return 0; fi
  if [ -e /dev/tty ]; then
    dk_info "installing Xcode Command Line Tools (click Install in the dialog that appears)"
    xcode-select --install >/dev/null 2>&1 || true
    local n=0
    while ! xcode-select -p >/dev/null 2>&1; do
      sleep 5; n=$((n+1)); [ $n -ge 240 ] && break
    done
    xcode-select -p >/dev/null 2>&1 || dk_warn "Command Line Tools not detected; git and compilers may be missing"
  else
    dk_warn "Xcode Command Line Tools missing; run: xcode-select --install"
  fi
}

dk_install_prereqs() {
  if [ "$DK_OS" = darwin ]; then dk_prereqs_mac; return 0; fi

  local want_git="" want_cc=""
  dk_selected git && want_git=1
  dk_selected rust && want_cc=1

  if [ "$DK_NO_SUDO" = 1 ]; then
    dk_warn "no sudo available; skipping system packages"
    dk_require_cmds curl tar gzip unzip zip xz
    return 0
  fi

  dk_step "installing system packages"
  case "$DK_PKG" in
    apt)
      $SUDO apt-get update -qq || dk_warn "apt-get update failed (continuing)"
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        curl ca-certificates zip unzip tar gzip xz-utils \
        ${want_git:+git} ${want_cc:+build-essential} \
        || dk_warn "apt-get install had errors (continuing)"
      ;;
    dnf|yum)
      $SUDO "$DK_PKG" -y install \
        curl ca-certificates zip unzip tar gzip xz \
        ${want_git:+git} ${want_cc:+gcc gcc-c++ make} \
        || dk_warn "$DK_PKG install had errors (continuing)"
      ;;
    pacman)
      $SUDO pacman -Sy --needed --noconfirm \
        curl ca-certificates zip unzip tar gzip xz \
        ${want_git:+git} ${want_cc:+base-devel} \
        || dk_warn "pacman install had errors (continuing)"
      ;;
    zypper)
      $SUDO zypper -n install \
        curl ca-certificates zip unzip tar gzip xz \
        ${want_git:+git} ${want_cc:+gcc gcc-c++ make} \
        || dk_warn "zypper install had errors (continuing)"
      ;;
    apk)
      # libstdc++/libgcc are runtime deps of the bun (and node) musl builds
      $SUDO apk add --no-cache bash \
        curl ca-certificates zip unzip tar gzip xz libstdc++ libgcc \
        ${want_git:+git} ${want_cc:+build-base} \
        || dk_warn "apk install had errors (continuing)"
      ;;
    *)
      dk_warn "unknown package manager; ensure curl, tar, gzip, unzip, zip are installed"
      dk_require_cmds curl tar gzip unzip zip
      ;;
  esac
}

# ---------------------------------------------------------------------------
# SDKMAN (shared by jdk / maven / gradle)
# ---------------------------------------------------------------------------
dk_set_kv() {
  local f=$1 k=$2 v=$3
  [ -f "$f" ] || return 0
  if grep -qE "^$k=" "$f"; then
    sed -i.bak -E "s|^$k=.*|$k=$v|" "$f" && rm -f "$f.bak"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

dk_sdkman_config() {
  local cfg="$SDKMAN_DIR/etc/config"
  dk_set_kv "$cfg" sdkman_auto_answer true
  dk_set_kv "$cfg" sdkman_selfupdate_feature false
  dk_set_kv "$cfg" sdkman_colour_enable false
  dk_set_kv "$cfg" sdkman_curl_connect_timeout 15
}

# SDKMAN 5.23 refuses to install on bash 3, and its runtime uses ${var^^}
# (src/sdkman-path-helpers.sh) -- so the bash 3.2 that macOS ships cannot drive
# it at all. Find a bash >= 4 and run everything SDKMAN through that, instead of
# sourcing sdkman-init.sh into this shell.
dk_find_bash4() {
  local c v
  for c in "${BASH:-}" bash /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash /bin/bash; do
    [ -n "$c" ] || continue
    v=$("$c" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null) || continue
    case "$v" in ''|*[!0-9]*) continue;; esac
    if [ "$v" -ge 4 ]; then printf '%s' "$c"; return 0; fi
  done
  return 1
}

dk_sdkman_load() {
  [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] || return 1
  [ -n "$DK_BASH" ] || return 1
  SDKMAN_DIR="$SDKMAN_DIR" "$DK_BASH" -c \
    '. "$SDKMAN_DIR/bin/sdkman-init.sh"; command -v sdk >/dev/null' >/dev/null 2>&1
}

# run an sdk command tolerantly (sdk internals are not set -e/-u clean)
dk_sdk() {
  local rc
  set +e
  SDKMAN_DIR="$SDKMAN_DIR" PAGER=cat "$DK_BASH" -c \
    'set +u; . "$SDKMAN_DIR/bin/sdkman-init.sh"; sdk "$@"' dk-sdk "$@" </dev/null
  rc=$?
  set -e
  return "$rc"
}

dk_ensure_sdkman() {
  DK_BASH=$(dk_find_bash4) || {
    dk_err "SDKMAN needs bash >= 4 and none was found (this shell: ${BASH_VERSION:-unknown})"
    dk_info "install one and re-run -- on macOS: brew install bash"
    return 1
  }
  dk_info "driving SDKMAN with $DK_BASH"
  if [ ! -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
    dk_step "installing SDKMAN"
    dk_fetch "https://get.sdkman.io?rcupdate=false&ci=true" "$DK_TMP/sdkman-install.sh" || return 1
    if ! SDKMAN_DIR="$SDKMAN_DIR" "$DK_BASH" "$DK_TMP/sdkman-install.sh" \
         > "$DK_TMP/sdkman-install.log" 2>&1; then
      dk_err "SDKMAN install failed:"
      sed -n '1,15p' "$DK_TMP/sdkman-install.log" >&2
      return 1
    fi
  fi
  dk_sdkman_config
  dk_sdkman_load || { dk_err "cannot source sdkman-init.sh"; return 1; }
  dk_sdk selfupdate force >/dev/null 2>&1 || true
  dk_sdkman_config
  return 0
}

# ---------------------------------------------------------------------------
# component: JDK
# ---------------------------------------------------------------------------
dk_jdk_installed_ids() {
  local major=$1 d b
  [ -d "$SDKMAN_DIR/candidates/java" ] || return 0
  for d in "$SDKMAN_DIR/candidates/java"/*; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    case "$b" in
      current) continue;;
      "$major".*-tem) echo "$b";;
    esac
  done
}

# resolve the target for a major; sets globals DK_JDK_ID/URL/SHA/LOCAL.
# Must be called directly (not via $(...)) so the globals reach the caller.
dk_jdk_resolve() {
  local major=$1 id="" url="" sha="" local=0 os arch file base ver
  DK_JDK_ID=""; DK_JDK_URL=""; DK_JDK_SHA=""; DK_JDK_LOCAL=0

  case "$DK_ARCH" in amd64) arch=x64;; arm64) arch=aarch64;; esac
  case "$DK_OS" in linux) os=linux;; darwin) os=mac;; esac
  [ "$DK_LIBC" = musl ] && os=alpine-linux

  if [ "$DK_MIRROR" = cn ]; then
    base="https://mirrors.tuna.tsinghua.edu.cn/Adoptium/$major/jdk/$arch/$os/"
    file=$(curl -fsSL -m 15 "$base" 2>/dev/null | grep -oE 'OpenJDK[^"]*\.tar\.gz' | head -1 || true)
    if [ -n "$file" ]; then
      ver=$(printf '%s' "$file" | sed -E 's/.*hotspot_//; s/\.tar\.gz$//; s/_([0-9]+)$/+\1/')
      id="$ver-tem"; url="$base$file"; local=1
      sha=$(curl -fsSL -m 15 "$base$file.sha256.txt" 2>/dev/null | awk '{print $1}' || true)
    fi
  fi

  if [ -z "$id" ] && { [ "$DK_MIRROR" = cn ] || [ "$DK_LIBC" = musl ]; }; then
    local api json
    api="https://api.adoptium.net/v3/assets/latest/$major/hotspot?os=$os&architecture=$arch&image_type=jdk"
    json=$(curl -fsSL -m 20 "$api" 2>/dev/null || true)
    url=$(printf '%s' "$json" | dk_json_str link) || url=""
    sha=$(printf '%s' "$json" | dk_json_str checksum) || sha=""
    ver=$(printf '%s' "$json" | dk_json_str release_name | sed -E 's/^jdk-//') || ver=""
    if [ -n "$url" ] && [ -n "$ver" ]; then id="$ver-tem"; local=1; fi
  fi

  if [ -z "$id" ]; then
    id=$(curl -fsSL -m 20 "https://api.sdkman.io/2/candidates/java/$DK_SDKMAN_PLATFORM/versions/all" 2>/dev/null \
          | tr ',' '\n' | grep -E -- '-tem$' | grep -E "^$major\." | dk_ver_max)
    local=0
  fi

  DK_JDK_ID="$id"; DK_JDK_URL="$url"; DK_JDK_SHA="$sha"; DK_JDK_LOCAL="$local"
}

dk_jdk_install() {
  local major=$1 id=$2
  if [ "$DK_JDK_LOCAL" = 1 ]; then
    [ -n "$DK_JDK_URL" ] || { dk_err "no download URL for JDK $major"; return 1; }
    dk_fetch "$DK_JDK_URL" "$DK_TMP/jdk-$major.tar.gz" "$DK_JDK_SHA"
    dk_extract_to "$DK_TMP/jdk-$major.tar.gz" "$DK_DATA_DIR/jdk/$id"
    local home="$DK_DATA_DIR/jdk/$id"
    [ -d "$home/Contents/Home" ] && home="$home/Contents/Home"
    dk_sdk install java "$id" "$home" || { dk_err "sdk local install failed for $id"; return 1; }
  else
    dk_sdk install java "$id" || { dk_err "sdk install failed for $id"; return 1; }
  fi
}

dk_jdk_one() {
  local major=$1 id installed keep old
  dk_info "resolving JDK $major"
  dk_jdk_resolve "$major"
  id="$DK_JDK_ID"
  [ -n "$id" ] || { dk_err "cannot resolve a Temurin JDK for major $major"; return 1; }

  installed=$(dk_jdk_installed_ids "$major")
  if [ -z "$installed" ] || ! printf '%s\n' "$installed" | grep -qxF "$id"; then
    dk_step "installing JDK $id"
    dk_jdk_install "$major" "$id"
  else
    dk_info "JDK $id already installed"
  fi

  installed=$(dk_jdk_installed_ids "$major")
  keep=$(printf '%s\n' "$installed" | dk_ver_max)

  if [ "$major" = "$DK_JDK_DEFAULT" ] && [ -n "$keep" ]; then
    dk_sdk default java "$keep" || true
  fi

  printf '%s\n' "$installed" | while IFS= read -r old; do
    [ -z "$old" ] && continue
    [ "$old" = "$keep" ] && continue
    dk_info "removing superseded JDK $old"
    dk_sdk uninstall java "$old" || true
    rm -rf "$DK_DATA_DIR/jdk/$old"
  done
}

# major numbers of the Temurin JDKs already installed (so a re-run bumps them too)
dk_jdk_existing_majors() {
  local d b
  [ -d "$SDKMAN_DIR/candidates/java" ] || return 0
  for d in "$SDKMAN_DIR/candidates/java"/*-tem; do
    [ -d "$d" ] || continue
    b=$(basename "$d")
    printf '%s\n' "$b" | sed -E 's/^([0-9]+)\..*/\1/'
  done | sort -u
}

dk_c_jdk() {
  [ "$DK_SDKMAN_OK" = 1 ] || { dk_err "SDKMAN unavailable"; return 1; }
  local m em majors="$DK_JDK_MAJORS"
  # never drop a major: also refresh every major already installed
  for em in $(dk_jdk_existing_majors); do
    case " $majors " in *" $em "*) ;; *) majors="$majors $em";; esac
  done
  for m in $majors; do
    dk_jdk_one "$m"
  done
}

# ---------------------------------------------------------------------------
# component: Maven
# ---------------------------------------------------------------------------
dk_maven_latest() {
  local base="https://dlcdn.apache.org/maven/maven-3/"
  [ "$DK_MIRROR" = cn ] && base="https://mirrors.tuna.tsinghua.edu.cn/apache/maven/maven-3/"
  curl -fsSL -m 20 "$base" 2>/dev/null | grep -oE '3\.[0-9]+\.[0-9]+/' | tr -d '/' | sort -u | dk_ver_max
}

dk_c_maven() {
  [ "$DK_SDKMAN_OK" = 1 ] || { dk_err "SDKMAN unavailable"; return 1; }
  local ver prev
  ver=$(dk_maven_latest) || ver=""
  [ -n "$ver" ] || { dk_err "cannot resolve Maven version"; return 1; }
  if [ ! -d "$SDKMAN_DIR/candidates/maven/$ver" ]; then
    dk_step "installing Maven $ver"
    if [ "$DK_MIRROR" = cn ]; then
      dk_fetch "https://mirrors.tuna.tsinghua.edu.cn/apache/maven/maven-3/$ver/binaries/apache-maven-$ver-bin.tar.gz" "$DK_TMP/mvn.tgz"
      dk_extract_to "$DK_TMP/mvn.tgz" "$DK_DATA_DIR/maven/$ver" "apache-maven-$ver"
      dk_sdk install maven "$ver" "$DK_DATA_DIR/maven/$ver" || { dk_err "maven local install failed"; return 1; }
    else
      dk_sdk install maven "$ver" || { dk_err "maven install failed"; return 1; }
    fi
  else
    dk_info "Maven $ver already installed"
  fi
  dk_sdk default maven "$ver" || true
  prev=$(dk_state_get maven_ver)
  if [ -n "$prev" ] && [ "$prev" != "$ver" ]; then
    dk_info "removing superseded Maven $prev"
    dk_sdk uninstall maven "$prev" || true
    rm -rf "$DK_DATA_DIR/maven/$prev"
  fi
  dk_state_set maven_ver "$ver"
}

# ---------------------------------------------------------------------------
# component: Gradle
# ---------------------------------------------------------------------------
dk_c_gradle() {
  [ "$DK_SDKMAN_OK" = 1 ] || { dk_err "SDKMAN unavailable"; return 1; }
  local json ver url sha prev
  json=$(curl -fsSL -m 20 "https://services.gradle.org/versions/current" 2>/dev/null || true)
  ver=$(printf '%s' "$json" | dk_json_str version) || ver=""
  [ -n "$ver" ] || { dk_err "cannot resolve Gradle version"; return 1; }
  if [ ! -d "$SDKMAN_DIR/candidates/gradle/$ver" ]; then
    dk_step "installing Gradle $ver"
    if [ "$DK_MIRROR" = cn ]; then
      sha=$(printf '%s' "$json" | dk_json_str checksum) || sha=""
      dk_fetch "https://mirrors.cloud.tencent.com/gradle/gradle-$ver-bin.zip" "$DK_TMP/gradle.zip" "$sha"
      dk_extract_to "$DK_TMP/gradle.zip" "$DK_DATA_DIR/gradle/$ver" "gradle-$ver"
      dk_sdk install gradle "$ver" "$DK_DATA_DIR/gradle/$ver" || { dk_err "gradle local install failed"; return 1; }
    else
      dk_sdk install gradle "$ver" || { dk_err "gradle install failed"; return 1; }
    fi
  else
    dk_info "Gradle $ver already installed"
  fi
  dk_sdk default gradle "$ver" || true
  prev=$(dk_state_get gradle_ver)
  if [ -n "$prev" ] && [ "$prev" != "$ver" ]; then
    dk_info "removing superseded Gradle $prev"
    dk_sdk uninstall gradle "$prev" || true
    rm -rf "$DK_DATA_DIR/gradle/$prev"
  fi
  dk_state_set gradle_ver "$ver"
}

# ---------------------------------------------------------------------------
# component: Go
# ---------------------------------------------------------------------------
dk_c_go() {
  local base jsonf ver file sha cur gobin
  base="https://go.dev/dl"
  [ "$DK_MIRROR" = cn ] && base="https://golang.google.cn/dl"
  jsonf="$DK_TMP/go.json"
  curl -fsSL -m 25 "$base/?mode=json" > "$jsonf" || { dk_err "cannot fetch Go release list"; return 1; }

  if [ -n "$DK_GO_VERSION" ]; then
    ver="go$DK_GO_VERSION"
  else
    ver=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"go[0-9.]+"' "$jsonf" | sed -n '1p' | sed -E 's/.*"(go[0-9.]+)".*/\1/') || ver=""
  fi
  [ -n "$ver" ] || { dk_err "cannot resolve Go version"; return 1; }
  file="$ver.$DK_OS-$DK_GOARCH.tar.gz"

  gobin="$DK_DATA_DIR/go/bin/go"
  cur=""
  [ -x "$gobin" ] && cur=$("$gobin" env GOVERSION 2>/dev/null || true)
  if [ "$cur" = "$ver" ]; then
    dk_info "Go $ver already current"
  else
    dk_step "installing Go $ver"
    sha=$(awk -v f="$file" '
      /"filename"/ {c=$0; sub(/.*"filename"[[:space:]]*:[[:space:]]*"/,"",c); sub(/".*/,"",c)}
      /"sha256"/ && c==f {v=$0; sub(/.*"sha256"[[:space:]]*:[[:space:]]*"/,"",v); sub(/".*/,"",v); print v; exit}
    ' "$jsonf")
    [ -n "$sha" ] || { dk_err "no Go build for $DK_OS-$DK_GOARCH ($file)"; return 1; }
    dk_fetch "$base/$file" "$DK_TMP/go.tgz" "$sha"
    dk_extract_to "$DK_TMP/go.tgz" "$DK_DATA_DIR/go" "go"
  fi

  if [ "$DK_MIRROR" = cn ]; then
    "$gobin" env -w GOPROXY=https://goproxy.cn,direct 2>/dev/null || true
  else
    local gp; gp=$("$gobin" env GOPROXY 2>/dev/null || true)
    case "$gp" in *goproxy.cn*) "$gobin" env -u GOPROXY 2>/dev/null || true;; esac
  fi
  dk_state_set go_ver "$ver"
}

# ---------------------------------------------------------------------------
# component: Rust
# ---------------------------------------------------------------------------
dk_cargo_cn_on() {
  local f="$CARGO_HOME/config.toml"
  mkdir -p "$CARGO_HOME"
  grep -q 'dev-kit cargo mirror' "$f" 2>/dev/null && return 0
  if [ -f "$f" ] && grep -qE '^\[source\.crates-io\]' "$f"; then
    dk_warn "cargo: existing [source.crates-io]; not adding a mirror"; return 0
  fi
  {
    echo "# >>> dev-kit cargo mirror >>>"
    cat <<'EOF'
[source.crates-io]
replace-with = "rsproxy-sparse"
[source.rsproxy-sparse]
registry = "sparse+https://rsproxy.cn/index/"
[registries.rsproxy-sparse]
index = "sparse+https://rsproxy.cn/index/"
[net]
git-fetch-with-cli = true
EOF
    echo "# <<< dev-kit cargo mirror <<<"
  } >> "$f"
}
dk_cargo_cn_off() {
  dk_remove_block "$CARGO_HOME/config.toml" "# >>> dev-kit cargo mirror >>>" "# <<< dev-kit cargo mirror <<<"
}

dk_c_rust() {
  local channel="stable" rustup prev initurl
  [ -n "$DK_RUST_VERSION" ] && channel="$DK_RUST_VERSION"
  export RUSTUP_HOME CARGO_HOME
  if [ "$DK_MIRROR" = cn ]; then
    export RUSTUP_DIST_SERVER=https://rsproxy.cn
    export RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup
  fi
  rustup="$CARGO_HOME/bin/rustup"

  if [ ! -x "$rustup" ]; then
    dk_step "installing rustup ($channel)"
    initurl="https://sh.rustup.rs"
    [ "$DK_MIRROR" = cn ] && initurl="https://rsproxy.cn/rustup-init.sh"
    curl --proto '=https' --tlsv1.2 -sSf -m 60 "$initurl" \
      | sh -s -- -y --no-modify-path --default-toolchain "$channel" --profile default >/dev/null \
      || { dk_err "rustup install failed"; return 1; }
  else
    dk_step "updating Rust"
    "$rustup" self update >/dev/null 2>&1 || true
    "$rustup" update >/dev/null 2>&1 || true
  fi

  if dk_is_semver "$channel"; then
    "$rustup" toolchain install "$channel" >/dev/null 2>&1 || true
    "$rustup" default "$channel" >/dev/null 2>&1 || true
    prev=$(dk_state_get rust_pin)
    if [ -n "$prev" ] && [ "$prev" != "$channel" ]; then
      dk_info "removing superseded Rust toolchain $prev"
      "$rustup" toolchain uninstall "$prev" >/dev/null 2>&1 || true
    fi
    dk_state_set rust_pin "$channel"
  else
    "$rustup" default "$channel" >/dev/null 2>&1 || true
  fi

  if [ "$DK_MIRROR" = cn ]; then dk_cargo_cn_on; else dk_cargo_cn_off; fi
}

# ---------------------------------------------------------------------------
# component: Node (fnm)
# ---------------------------------------------------------------------------
dk_install_fnm() {
  local asset url tmp bin
  case "$DK_OS-$DK_ARCH" in
    linux-amd64) asset="fnm-linux";;
    linux-arm64) asset="fnm-arm64";;
    darwin-*)    asset="fnm-macos";;
    *) dk_err "no fnm build for $DK_OS-$DK_ARCH"; return 1;;
  esac
  dk_step "installing fnm"
  url="https://github.com/Schniz/fnm/releases/latest/download/$asset.zip"
  dk_fetch "$url" "$DK_TMP/fnm.zip"
  tmp="$DK_TMP/fnmx"; rm -rf "$tmp"; mkdir -p "$tmp"
  unzip -q "$DK_TMP/fnm.zip" -d "$tmp"
  bin=$(find "$tmp" -type f -name fnm | sed -n '1p')
  [ -n "$bin" ] || bin=$(find "$tmp" -type f | sed -n '1p')
  [ -n "$bin" ] || { dk_err "fnm binary not found"; return 1; }
  mkdir -p "$DK_DATA_DIR/bin"
  mv -f "$bin" "$DK_DATA_DIR/bin/fnm"
  chmod +x "$DK_DATA_DIR/bin/fnm"
  rm -rf "$tmp"
}

dk_c_node() {
  local fnm target tmajor req v vm
  fnm="$DK_DATA_DIR/bin/fnm"
  [ -x "$fnm" ] || dk_install_fnm
  export FNM_DIR
  if [ "$DK_MIRROR" = cn ]; then export FNM_NODE_DIST_MIRROR="https://npmmirror.com/mirrors/node"; fi
  if [ "$DK_LIBC" = musl ]; then
    export FNM_NODE_DIST_MIRROR="https://unofficial-builds.nodejs.org/download/release"
    case "$DK_ARCH" in amd64) export FNM_ARCH=x64-musl;; arm64) export FNM_ARCH=arm64-musl;; esac
    dk_warn "musl: installing Node from unofficial-builds (best effort)"
  fi

  req="$DK_NODE_VERSION"
  if [ -z "$req" ] || [ "$req" = lts ]; then
    target=$("$fnm" ls-remote --lts --latest 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | tail -1) || target=""
  else
    target=$("$fnm" ls-remote --filter "$req" --latest 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | tail -1) || target=""
  fi
  [ -n "$target" ] || { dk_err "cannot resolve a Node version for '${req:-lts}'"; return 1; }
  tmajor=$(printf '%s' "$target" | sed -E 's/^v([0-9]+).*/\1/')

  if ! "$fnm" ls 2>/dev/null | grep -qF "$target"; then
    dk_step "installing Node $target"
    "$fnm" install "$target" || { dk_err "fnm install $target failed"; return 1; }
  else
    dk_info "Node $target already installed"
  fi
  "$fnm" default "$target" || true

  "$fnm" ls 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | while IFS= read -r v; do
    vm=$(printf '%s' "$v" | sed -E 's/^v([0-9]+).*/\1/')
    if [ "$vm" = "$tmajor" ] && [ "$v" != "$target" ]; then
      dk_info "removing superseded Node $v"
      "$fnm" uninstall "$v" >/dev/null 2>&1 || true
    fi
  done
}

# ---------------------------------------------------------------------------
# component: pnpm
# ---------------------------------------------------------------------------
dk_npmrc_cn_on() {
  local f="$HOME/.npmrc"
  grep -q 'dev-kit npm mirror' "$f" 2>/dev/null && return 0
  if [ -f "$f" ] && grep -qE '^registry=' "$f"; then
    dk_warn "npmrc: existing registry=; not adding a mirror"; return 0
  fi
  {
    echo "# >>> dev-kit npm mirror >>>"
    echo "registry=https://registry.npmmirror.com"
    echo "# <<< dev-kit npm mirror <<<"
  } >> "$f"
}
dk_npmrc_cn_off() {
  dk_remove_block "$HOME/.npmrc" "# >>> dev-kit npm mirror >>>" "# <<< dev-kit npm mirror <<<"
}

dk_c_pnpm() {
  local reg ver cur plat arch pkg tmp
  reg="https://registry.npmjs.org"
  [ "$DK_MIRROR" = cn ] && reg="https://registry.npmmirror.com"
  ver=$(curl -fsSL -m 20 "$reg/pnpm/latest" 2>/dev/null | grep -oE '"version"[[:space:]]*:[[:space:]]*"[0-9.]+"' | sed -n '1p' | sed -E 's/.*"([0-9.]+)".*/\1/') || ver=""
  [ -n "$ver" ] || { dk_err "cannot resolve pnpm version"; return 1; }

  cur=""
  [ -x "$PNPM_HOME/pnpm" ] && cur=$("$PNPM_HOME/pnpm" --version 2>/dev/null || true)
  if [ "$cur" != "$ver" ]; then
    dk_step "installing pnpm $ver"
    case "$DK_OS" in linux) plat=linux;; darwin) plat=darwin;; esac
    case "$DK_ARCH" in amd64) arch=x64;; arm64) arch=arm64;; esac
    pkg="exe.$plat-$arch"
    [ "$DK_LIBC" = musl ] && [ "$plat" = linux ] && pkg="exe.$plat-$arch-musl"
    dk_fetch "$reg/@pnpm/$pkg/-/$pkg-$ver.tgz" "$DK_TMP/pnpm.tgz"
    tmp="$DK_TMP/pnpmx"; rm -rf "$tmp"; mkdir -p "$tmp"
    tar -xzf "$DK_TMP/pnpm.tgz" -C "$tmp"
    [ -f "$tmp/package/pnpm" ] || { dk_err "pnpm binary not found in package"; return 1; }
    mkdir -p "$PNPM_HOME"
    mv -f "$tmp/package/pnpm" "$PNPM_HOME/pnpm"
    chmod +x "$PNPM_HOME/pnpm"
    rm -rf "$tmp"
  else
    dk_info "pnpm $ver already current"
  fi

  if [ "$DK_MIRROR" = cn ]; then dk_npmrc_cn_on; else dk_npmrc_cn_off; fi
  dk_state_set pnpm_ver "$ver"
}

# ---------------------------------------------------------------------------
# component: bun
# ---------------------------------------------------------------------------
dk_has_avx2() {
  if [ "$DK_OS" = linux ]; then
    grep -qi avx2 /proc/cpuinfo 2>/dev/null
  else
    sysctl -a 2>/dev/null | grep -qi avx2
  fi
}

dk_bun_target() {
  local os arch t
  case "$DK_OS" in linux) os=linux;; darwin) os=darwin;; esac
  case "$DK_ARCH" in amd64) arch=x64;; arm64) arch=aarch64;; esac
  t="bun-$os-$arch"
  [ "$DK_LIBC" = musl ] && [ "$os" = linux ] && t="$t-musl"
  if [ "$arch" = x64 ] && ! dk_has_avx2; then t="$t-baseline"; fi
  printf '%s' "$t"
}

dk_bun_tag() {
  if [ "$DK_MIRROR" = cn ]; then
    curl -fsSL -m 20 "https://registry.npmmirror.com/-/binary/bun/" 2>/dev/null \
      | grep -oE 'bun-v[0-9]+\.[0-9]+\.[0-9]+' | sort -u | dk_ver_max
  else
    curl -fsSL -m 20 "https://api.github.com/repos/oven-sh/bun/releases/latest" 2>/dev/null \
      | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -n '1p' | sed -E 's/.*"([^"]*)"$/\1/'
  fi
}

dk_c_bun() {
  local tag target cur url tmp bin
  tag=$(dk_bun_tag) || tag=""
  [ -n "$tag" ] || { dk_err "cannot resolve bun release"; return 1; }
  target=$(dk_bun_target)

  cur=""
  if [ -x "$BUN_INSTALL/bin/bun" ]; then cur="bun-v$("$BUN_INSTALL/bin/bun" --version 2>/dev/null || echo 0)"; fi
  if [ "$cur" = "$tag" ]; then
    dk_info "bun $tag already current"; dk_state_set bun_ver "$tag"; return 0
  fi

  dk_step "installing bun $tag"
  if [ "$DK_MIRROR" = cn ]; then
    url="https://registry.npmmirror.com/-/binary/bun/$tag/$target.zip"
  else
    url="https://github.com/oven-sh/bun/releases/download/$tag/$target.zip"
  fi
  dk_fetch "$url" "$DK_TMP/bun.zip"
  tmp="$DK_TMP/bunx"; rm -rf "$tmp"; mkdir -p "$tmp"
  unzip -q "$DK_TMP/bun.zip" -d "$tmp"
  bin=$(find "$tmp" -type f -name bun | sed -n '1p')
  [ -n "$bin" ] || { dk_err "bun binary not found in archive"; return 1; }
  mkdir -p "$BUN_INSTALL/bin"
  mv -f "$bin" "$BUN_INSTALL/bin/bun"
  chmod +x "$BUN_INSTALL/bin/bun"
  rm -rf "$tmp"
  dk_state_set bun_ver "$tag"
}

# ---------------------------------------------------------------------------
# component: git
# ---------------------------------------------------------------------------
dk_c_git() {
  if command -v git >/dev/null 2>&1; then
    dk_info "git present: $(git --version 2>/dev/null)"
    return 0
  fi
  # prereqs should have installed it; if not, it needs a package manager
  dk_err "git is not installed (needs a system package manager / sudo)"
  return 1
}

# ---------------------------------------------------------------------------
# shell integration
# ---------------------------------------------------------------------------
dk_write_env_sh() {
  local f="$DK_CONFIG_DIR/env.sh"
  mkdir -p "$DK_CONFIG_DIR"
  {
    echo "# generated by dev-kit — do not edit (regenerated on each run)"
    echo "export DEVKIT_HOME=\"$DK_DATA_DIR\""
    echo "export DEVKIT_MIRROR=\"$DK_MIRROR\""
    echo "export PATH=\"\$DEVKIT_HOME/bin:\$PATH\""

    if [ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ]; then
      echo "export SDKMAN_DIR=\"$SDKMAN_DIR\""
      echo "if [ -n \"\${BASH_VERSION:-}\${ZSH_VERSION:-}\" ] && [ -s \"\$SDKMAN_DIR/bin/sdkman-init.sh\" ]; then . \"\$SDKMAN_DIR/bin/sdkman-init.sh\"; fi"
    fi

    if [ -x "$DK_DATA_DIR/go/bin/go" ]; then
      echo "export GOROOT=\"\$DEVKIT_HOME/go\""
      echo "export PATH=\"\$GOROOT/bin:\$HOME/go/bin:\$PATH\""
    fi

    if [ -x "$CARGO_HOME/bin/rustc" ]; then
      echo "export CARGO_HOME=\"$CARGO_HOME\""
      echo "export RUSTUP_HOME=\"$RUSTUP_HOME\""
      if [ "$DK_MIRROR" = cn ]; then
        echo "export RUSTUP_DIST_SERVER=https://rsproxy.cn"
        echo "export RUSTUP_UPDATE_ROOT=https://rsproxy.cn/rustup"
      fi
      echo "[ -f \"\$CARGO_HOME/env\" ] && . \"\$CARGO_HOME/env\""
    fi

    if [ -x "$DK_DATA_DIR/bin/fnm" ]; then
      echo "export FNM_DIR=\"$FNM_DIR\""
      [ "$DK_MIRROR" = cn ] && echo "export FNM_NODE_DIST_MIRROR=https://npmmirror.com/mirrors/node"
      cat <<'EOS'
if command -v fnm >/dev/null 2>&1; then
  if [ -n "${ZSH_VERSION:-}" ]; then eval "$(fnm env --use-on-cd --shell zsh)"
  elif [ -n "${BASH_VERSION:-}" ]; then eval "$(fnm env --use-on-cd --shell bash)"; fi
fi
EOS
    fi

    if [ -x "$BUN_INSTALL/bin/bun" ]; then
      echo "export BUN_INSTALL=\"$BUN_INSTALL\""
      echo "export PATH=\"\$BUN_INSTALL/bin:\$PATH\""
    fi

    if [ -x "$PNPM_HOME/pnpm" ]; then
      echo "export PNPM_HOME=\"$PNPM_HOME\""
      echo "export PATH=\"\$PNPM_HOME:\$PATH\""
    fi
  } > "$f"
}

dk_integrate_rc() {
  if [ "$DK_NO_SHELL_INIT" = 1 ]; then return 0; fi
  local block file files
  block=$(printf '# >>> dev-kit >>>\n[ -r "%s/env.sh" ] && . "%s/env.sh"\n# <<< dev-kit <<<' "$DK_CONFIG_DIR" "$DK_CONFIG_DIR")
  files="$HOME/.bashrc $HOME/.zshrc"
  [ "$DK_OS" = darwin ] && files="$files $HOME/.bash_profile $HOME/.zprofile"
  [ -f "$HOME/.profile" ] && files="$files $HOME/.profile"
  for file in $files; do dk_upsert_block "$file" "$block"; done

  if [ "${GITHUB_ACTIONS:-}" = true ] && [ -n "${GITHUB_PATH:-}" ]; then
    {
      echo "$DK_DATA_DIR/bin"
      [ -x "$DK_DATA_DIR/go/bin/go" ] && echo "$DK_DATA_DIR/go/bin"
      [ -x "$DK_DATA_DIR/go/bin/go" ] && echo "$HOME/go/bin"
      [ -x "$CARGO_HOME/bin/rustc" ] && echo "$CARGO_HOME/bin"
      [ -x "$BUN_INSTALL/bin/bun" ] && echo "$BUN_INSTALL/bin"
      [ -x "$PNPM_HOME/pnpm" ] && echo "$PNPM_HOME"
      [ -d "$SDKMAN_DIR/candidates/java/current/bin" ] && echo "$SDKMAN_DIR/candidates/java/current/bin"
      [ -d "$SDKMAN_DIR/candidates/maven/current/bin" ] && echo "$SDKMAN_DIR/candidates/maven/current/bin"
      [ -d "$SDKMAN_DIR/candidates/gradle/current/bin" ] && echo "$SDKMAN_DIR/candidates/gradle/current/bin"
    } >> "$GITHUB_PATH" || true
    if [ -n "${GITHUB_ENV:-}" ]; then
      {
        [ -x "$DK_DATA_DIR/go/bin/go" ] && echo "GOROOT=$DK_DATA_DIR/go"
        [ -d "$SDKMAN_DIR/candidates/java/current" ] && echo "JAVA_HOME=$SDKMAN_DIR/candidates/java/current"
      } >> "$GITHUB_ENV" || true
    fi
  fi
}

# ---------------------------------------------------------------------------
# doctor
# ---------------------------------------------------------------------------
dk_doctor_row() {
  local label=$1 path=$2; shift 2
  local ver=""
  if [ -x "$path" ] || command -v "$path" >/dev/null 2>&1; then
    ver=$("$@" 2>&1 | sed -n '1p') || ver=""
    printf '  %s%-8s%s %s\n' "$C_GRN" "$label" "$C_RST" "$ver" >&2
  fi
}

dk_doctor() {
  dk_step "summary"
  command -v git >/dev/null 2>&1 && printf '  %s%-8s%s %s\n' "$C_GRN" "git" "$C_RST" "$(git --version 2>&1 | head -1)" >&2
  local jc="$SDKMAN_DIR/candidates/java/current/bin/java"
  [ -x "$jc" ] && printf '  %s%-8s%s %s\n' "$C_GRN" "java" "$C_RST" "$("$jc" -version 2>&1 | head -1)" >&2
  local mc="$SDKMAN_DIR/candidates/maven/current/bin/mvn"
  [ -x "$mc" ] && printf '  %s%-8s%s %s\n' "$C_GRN" "maven" "$C_RST" "$("$mc" -v 2>&1 | head -1)" >&2
  local gc="$SDKMAN_DIR/candidates/gradle/current/bin/gradle"
  [ -x "$gc" ] && printf '  %s%-8s%s %s\n' "$C_GRN" "gradle" "$C_RST" "$("$gc" -v 2>&1 | grep -i '^Gradle' | head -1)" >&2
  [ -x "$DK_DATA_DIR/go/bin/go" ] && printf '  %s%-8s%s %s\n' "$C_GRN" "go" "$C_RST" "$("$DK_DATA_DIR/go/bin/go" version 2>&1 | head -1)" >&2
  [ -x "$CARGO_HOME/bin/rustc" ] && printf '  %s%-8s%s %s\n' "$C_GRN" "rust" "$C_RST" "$("$CARGO_HOME/bin/rustc" --version 2>&1 | head -1)" >&2
  local ndef="$FNM_DIR/aliases/default/bin/node"
  [ -x "$ndef" ] && printf '  %s%-8s%s %s\n' "$C_GRN" "node" "$C_RST" "$("$ndef" --version 2>&1 | head -1)" >&2
  [ -x "$PNPM_HOME/pnpm" ] && printf '  %s%-8s%s %s\n' "$C_GRN" "pnpm" "$C_RST" "$("$PNPM_HOME/pnpm" --version 2>&1 | head -1)" >&2
  [ -x "$BUN_INSTALL/bin/bun" ] && printf '  %s%-8s%s %s\n' "$C_GRN" "bun" "$C_RST" "$("$BUN_INSTALL/bin/bun" --version 2>&1 | head -1)" >&2

  # shadow warnings: something else on PATH ahead of ours
  dk_doctor_shadow go "$DK_DATA_DIR/go/bin/go"
  dk_doctor_shadow node "$ndef"

  if [ -n "$DK_FAILED" ]; then
    dk_warn "failed:$DK_FAILED"
  fi
  echo >&2
  if [ "$DK_NO_SHELL_INIT" = 1 ]; then
    dk_info "shell rc not modified; source it yourself: . \"$DK_CONFIG_DIR/env.sh\""
  else
    dk_info "open a new shell, or run:  . \"$DK_CONFIG_DIR/env.sh\""
  fi
}

dk_doctor_shadow() {
  local name=$1 ours=$2 onpath
  [ -x "$ours" ] || return 0
  onpath=$(command -v "$name" 2>/dev/null || true)
  if [ -n "$onpath" ] && [ "$onpath" != "$ours" ]; then
    dk_warn "$name on PATH is $onpath (dev-kit installed $ours; new shells prefer dev-kit)"
  fi
}

# ---------------------------------------------------------------------------
# uninstall
# ---------------------------------------------------------------------------
DK_KEPT=""   # user-authored paths we deliberately did not delete

dk_rm() {
  local p
  for p in "$@"; do
    { [ -e "$p" ] || [ -L "$p" ]; } || continue
    dk_info "removing $p"
    rm -rf "$p"
  done
}

# remove a cache path unless --keep-cache
dk_rm_cache() {
  [ "$DK_KEEP_CACHE" = 1 ] && return 0
  dk_rm "$@"
}

dk_note_kept() {
  [ -e "$1" ] || return 0
  DK_KEPT="$DK_KEPT
    $1  ($2)"
}

dk_state_unset() {
  local f; f=$(dk_state_file)
  [ -f "$f" ] || return 0
  sed -i.bak "/^$1=/d" "$f" 2>/dev/null && rm -f "$f.bak" || true
}

dk_remove_rc_blocks() {
  local f
  for f in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile" "$HOME/.zprofile" "$HOME/.profile"; do
    [ -f "$f" ] && dk_remove_block "$f" "# >>> dev-kit >>>" "# <<< dev-kit <<<"
  done
}

dk_jdk_all_tem_ids() {
  local d b
  [ -d "$SDKMAN_DIR/candidates/java" ] || return 0
  for d in "$SDKMAN_DIR/candidates/java"/*-tem; do
    [ -d "$d" ] || continue
    b=$(basename "$d"); printf '%s\n' "$b"
  done
}

dk_u_git() {
  command -v git >/dev/null 2>&1 || { dk_info "git not present"; return 0; }
  dk_warn "git is a system package; dev-kit will not remove it automatically"
  case "$DK_PKG" in
    apt)    dk_info "  remove manually: sudo apt-get remove --purge git";;
    dnf|yum) dk_info "  remove manually: sudo $DK_PKG remove git";;
    pacman) dk_info "  remove manually: sudo pacman -Rns git";;
    zypper) dk_info "  remove manually: sudo zypper remove git";;
    apk)    dk_info "  remove manually: sudo apk del git";;
    xcode)  dk_info "  git ships with the Xcode Command Line Tools";;
  esac
  dk_note_kept "$HOME/.gitconfig" "your git config"
}

dk_u_jdk() {
  if dk_sdkman_load 2>/dev/null; then
    local id
    for id in $(dk_jdk_all_tem_ids); do
      dk_info "sdk uninstall java $id"
      dk_sdk uninstall java "$id" || true
    done
  fi
  local d
  for d in "$SDKMAN_DIR/candidates/java"/*-tem; do [ -d "$d" ] && dk_rm "$d"; done
  dk_rm "$DK_DATA_DIR/jdk"
}

dk_u_maven() {
  # remove every SDKMAN-managed maven (dev-kit installs one); rm is reliable, sdk is best-effort
  local d
  if [ -d "$SDKMAN_DIR/candidates/maven" ]; then
    dk_sdkman_load 2>/dev/null || true
    for d in "$SDKMAN_DIR/candidates/maven"/*; do
      { [ -e "$d" ] || [ -L "$d" ]; } || continue
      command -v sdk >/dev/null 2>&1 && [ "$(basename "$d")" != current ] && dk_sdk uninstall maven "$(basename "$d")" >/dev/null 2>&1 || true
      dk_rm "$d"
    done
  fi
  dk_rm "$DK_DATA_DIR/maven"
  dk_rm_cache "$HOME/.m2/repository"
  [ -d "$HOME/.m2" ] && rmdir "$HOME/.m2" 2>/dev/null || true
  dk_note_kept "$HOME/.m2/settings.xml" "your Maven settings"
  dk_state_unset maven_ver
}

dk_u_gradle() {
  local d
  if [ -d "$SDKMAN_DIR/candidates/gradle" ]; then
    dk_sdkman_load 2>/dev/null || true
    for d in "$SDKMAN_DIR/candidates/gradle"/*; do
      { [ -e "$d" ] || [ -L "$d" ]; } || continue
      command -v sdk >/dev/null 2>&1 && [ "$(basename "$d")" != current ] && dk_sdk uninstall gradle "$(basename "$d")" >/dev/null 2>&1 || true
      dk_rm "$d"
    done
  fi
  dk_rm "$DK_DATA_DIR/gradle"
  dk_rm_cache "$HOME/.gradle/caches" "$HOME/.gradle/wrapper" "$HOME/.gradle/daemon" "$HOME/.gradle/notifications"
  dk_note_kept "$HOME/.gradle/gradle.properties" "your Gradle properties"
  dk_state_unset gradle_ver
}

dk_u_go() {
  dk_rm "$DK_DATA_DIR/go"
  dk_rm_cache "${GOCACHE:-$HOME/.cache/go-build}" "${GOPATH:-$HOME/go}/pkg"
  # drop the GOPROXY line we may have written
  local gof="$HOME/.config/go/env"
  if [ -f "$gof" ] && grep -q 'goproxy\.cn' "$gof"; then
    sed -i.bak '/goproxy\.cn/d' "$gof" 2>/dev/null && rm -f "$gof.bak" || true
  fi
  dk_note_kept "${GOPATH:-$HOME/go}/bin" "tools you installed with 'go install'"
  dk_state_unset go_ver
}

dk_u_rust() {
  if [ -x "$CARGO_HOME/bin/rustup" ]; then
    dk_info "rustup self uninstall"
    "$CARGO_HOME/bin/rustup" self uninstall -y >/dev/null 2>&1 || true
  fi
  dk_rm "$CARGO_HOME" "$RUSTUP_HOME"
  dk_state_unset rust_pin
}

dk_u_node() {
  dk_rm "$DK_DATA_DIR/bin/fnm" "$FNM_DIR"
  dk_rm_cache "$HOME/.npm"
  dk_npmrc_cn_off
  dk_note_kept "$HOME/.npmrc" "your npm config"
}

dk_u_pnpm() {
  dk_rm "$PNPM_HOME"
  dk_rm_cache "$HOME/.cache/pnpm" "$HOME/.pnpm-store" "$HOME/.local/state/pnpm"
  dk_npmrc_cn_off
  dk_state_unset pnpm_ver
}

dk_u_bun() {
  # $BUN_INSTALL (~/.bun) holds the binary and bun's install cache
  dk_rm "$BUN_INSTALL"
  dk_rm_cache "$HOME/.cache/bun"
  dk_state_unset bun_ver
}

# after sdk-managed tools are gone, drop SDKMAN if nothing else uses it
dk_uninstall_sdkman_maybe() {
  [ -d "$SDKMAN_DIR" ] || return 0
  # all SDKMAN-managed tools removed -> drop SDKMAN wholesale
  if dk_selected jdk && dk_selected maven && dk_selected gradle; then
    dk_rm "$SDKMAN_DIR"; return 0
  fi
  # otherwise keep it only if some candidate version still remains (e.g. a JDK we kept)
  local left
  left=$(find "$SDKMAN_DIR/candidates" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | head -1 || true)
  if [ -z "$left" ]; then
    dk_rm "$SDKMAN_DIR"
  else
    dk_info "keeping SDKMAN (other candidates remain); clearing its cache"
    dk_rm_cache "$SDKMAN_DIR/tmp" "$SDKMAN_DIR/archives"
  fi
}

dk_uninstall_confirm() {
  [ "$DK_YES" = 1 ] && return 0
  [ "$DK_CONFIRMED" = 1 ] && return 0
  local ans
  { exec 3<>/dev/tty; } 2>/dev/null || dk_die "uninstall needs confirmation; re-run with --yes"
  printf '\n  About to UNINSTALL: %s\n' "$DK_SELECTED" >&3
  if [ "$DK_KEEP_CACHE" = 1 ]; then
    printf '  Removes the toolchains and dev-kit config (caches kept).\n' >&3
  else
    printf '  Removes the toolchains, their caches, and dev-kit config.\n' >&3
  fi
  printf '  User files (git/maven/gradle/npm config) are kept.\n\n  Proceed? [y/N] ' >&3
  IFS= read -r ans <&3 || ans=""
  exec 3>&-
  case "$ans" in y|Y|yes|YES) return 0;; *) dk_die "cancelled";; esac
}

dk_uninstall_finalize() {
  local c remaining=""
  # git is a system package we never remove, so it does not keep dev-kit "alive"
  for c in $DK_COMPONENTS_ALL; do
    [ "$c" = git ] && continue
    dk_detect_installed "$c" && remaining="$remaining $c"
  done
  remaining=$(printf '%s' "$remaining" | sed 's/^ *//; s/ *$//')
  if [ -z "$remaining" ]; then
    dk_remove_rc_blocks
    dk_rm "$DK_CONFIG_DIR" "$DK_DATA_DIR"
    dk_ok "dev-kit fully removed"
  else
    dk_write_env_sh
    dk_info "still installed:$remaining"
  fi
}

dk_uninstall_flow() {
  dk_uninstall_confirm
  local c
  for c in $DK_ORDER; do
    dk_selected "$c" || continue
    dk_step "uninstalling $c"
    dk_run_component "$c" dk_u_
  done
  if dk_selected_any jdk maven gradle; then
    dk_uninstall_sdkman_maybe
  fi
  dk_uninstall_finalize

  dk_step "uninstall summary"
  [ -n "$DK_FAILED" ] && dk_warn "issues with:$DK_FAILED"
  if [ -n "$DK_KEPT" ]; then
    dk_info "kept (delete these yourself if you want them gone):$DK_KEPT"
  fi
  dk_info "open a new shell so removed tools leave your PATH"
  [ -z "$DK_FAILED" ] || exit 2
}

# ---------------------------------------------------------------------------
# i18n — interactive UI strings only (progress/log output stays English)
# ---------------------------------------------------------------------------
dk_detect_lang() {
  local l
  case "${DK_LANG_ARG:-${DEVKIT_LANG:-}}" in
    zh|zh_CN|zh-CN|cn) DK_LANG=zh;;
    en|en_US|C|POSIX)  DK_LANG=en;;
    "")
      l="${LC_ALL:-}"; [ -n "$l" ] || l="${LC_MESSAGES:-}"; [ -n "$l" ] || l="${LANG:-}"
      case "$l" in zh*|*.zh*|*_zh*) DK_LANG=zh;; *) DK_LANG=en;; esac;;
    *) DK_LANG=en;;
  esac
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8*|*utf-8*|*UTF8*|*utf8*) DK_UTF8=1;;
    *) DK_UTF8=0;;
  esac
  # explicitly asking for Chinese implies a UTF-8 capable terminal
  [ "$DK_LANG" = zh ] && [ -n "${DK_LANG_ARG:-${DEVKIT_LANG:-}}" ] && DK_UTF8=1
  if [ "$DK_UTF8" = 1 ]; then
    DK_UI_CUR="▸"; DK_UI_GO="▶ "; DK_UI_BACK="← "; DK_UI_DOT="●"
  else
    DK_UI_CUR=">"; DK_UI_GO="> "; DK_UI_BACK="< "; DK_UI_DOT="*"
    # a non-UTF-8 terminal cannot render the Chinese menu at all
    [ "$DK_LANG" = zh ] && DK_LANG=en
  fi
  return 0
}

dk_t() {
  local zh="" en=""
  case "$1" in
    mode.title)    zh='选择要执行的操作';                        en='what would you like to do?';;
    mode.install)  zh='安装 / 更新组件';                          en='install / update components';;
    mode.uninst)   zh='卸载组件';                                 en='uninstall components';;
    mode.quit)     zh='退出';                                     en='quit';;
    pick.install)  zh='勾选要安装 / 更新的组件';                  en='select components to install / update';;
    pick.uninst)   zh='勾选要卸载的组件（* = 已安装）';           en='select components to uninstall (* = installed)';;
    opts.title)    zh='安装选项';                                 en='install options';;
    opts.titleu)   zh='卸载选项';                                 en='uninstall options';;
    hint.chk1)     zh='↑/↓ 移动   空格 勾选   回车 确认';         en='up/down move   space toggle   enter confirm';;
    hint.chk2)     zh='a 全选   n 全不选   i 反选   q 退出';      en='a all   n none   i invert   q quit';;
    hint.menu1)    zh='↑/↓ 移动   回车 选择   q 退出';            en='up/down move   enter select   q quit';;
    hint.input)    zh='输入后回车；留空用默认值';                 en='type and press enter; empty keeps the default';;
    lbl.jdk)       zh='JDK 主版本';                               en='JDK majors';;
    lbl.go)        zh='Go 版本';                                  en='Go version';;
    lbl.rust)      zh='Rust 工具链';                              en='Rust toolchain';;
    lbl.node)      zh='Node 版本';                                en='Node version';;
    lbl.mirror)    zh='镜像源';                                   en='mirrors';;
    lbl.shell)     zh='写入 shell 启动文件';                      en='write shell rc files';;
    lbl.cache)     zh='保留缓存';                                 en='keep caches';;
    act.start)     zh='开始安装';                                 en='start install';;
    act.startu)    zh='开始卸载';                                 en='start uninstall';;
    act.back)      zh='返回上一步';                               en='back';;
    val.latest)    zh='最新版';                                   en='latest';;
    val.lts)       zh='最新 LTS';                                 en='latest LTS';;
    val.custom)    zh='手动输入…';                                en='enter manually...';;
    val.default)   zh='默认';                                     en='default';;
    val.yes)       zh='是';                                       en='yes';;
    val.no)        zh='否';                                       en='no';;
    val.auto)      zh='auto — 探测网络后自动选择';                en='auto - probe the network';;
    val.cn)        zh='cn — 使用国内镜像';                        en='cn - China mirrors';;
    val.off)       zh='off — 只用官方源';                         en='off - upstream only';;
    in.go)         zh='Go 版本号，例如 1.27.1';                   en='Go version, e.g. 1.27.1';;
    in.rust)       zh='Rust 版本号，例如 1.90.0';                 en='Rust version, e.g. 1.90.0';;
    in.node)       zh='Node 主版本号，例如 24';                   en='Node major, e.g. 24';;
    sum.install)   zh='即将安装 / 更新：';                        en='about to install / update: ';;
    sum.uninst)    zh='即将卸载：';                               en='about to uninstall: ';;
    sum.u1)        zh='将删除工具链、缓存和 dev-kit 自身的配置';   en='removes the toolchains, their caches and dev-kit config';;
    sum.u1k)       zh='将删除工具链和 dev-kit 自身的配置（保留缓存）'; en='removes the toolchains and dev-kit config (caches kept)';;
    sum.u2)        zh='你自己写的配置文件不会被删除';             en='your own config files are kept';;
    sum.ask)       zh='确认执行？';                               en='proceed?';;
    msg.cancel)    zh='已取消';                                   en='cancelled';;
    msg.none)      zh='没有勾选任何组件';                         en='nothing selected';;
    msg.noinst)    zh='当前没有由 dev-kit 安装的组件';            en='nothing installed by dev-kit';;
    msg.loading)   zh='正在获取可用版本…';                        en='fetching available versions...';;
    msg.badver)    zh='格式不对，请重新输入';                     en='invalid version, try again';;
    *)             zh=''; en="$1";;
  esac
  if [ "$DK_LANG" = zh ] && [ -n "$zh" ]; then printf '%s' "$zh"; else printf '%s' "$en"; fi
}

# ---------------------------------------------------------------------------
# terminal UI primitives (arrow keys + checkboxes), bash 3.2 compatible
#
# Everything is drawn on fd 3 (/dev/tty) so it still works under
# `curl ... | bash`, where stdin is the script itself.
# ---------------------------------------------------------------------------
dk_ui_supported() {
  [ "${DEVKIT_NO_TUI:-0}" = 1 ] && return 1
  [ "$DK_NO_TUI" = 1 ] && return 1
  case "${TERM:-}" in dumb|"") return 1;; esac
  [ -e /dev/tty ] || return 1
  command -v stty >/dev/null 2>&1 || return 1
  ( exec 9<>/dev/tty ) 2>/dev/null || return 1
  return 0
}

dk_ui_open() {
  [ "$DK_UI_ON" = 1 ] && return 0
  { exec 3<>/dev/tty; } 2>/dev/null || return 1
  DK_UI_STTY=$(stty -g <&3 2>/dev/null) || { exec 3>&-; return 1; }
  if ! stty -icanon -echo min 1 time 0 <&3 2>/dev/null; then
    exec 3>&-; return 1
  fi
  DK_UI_ON=1
  DK_UI_LINES=0
  DK_UI_COLS=$(stty size <&3 2>/dev/null | awk '{print $2}') || DK_UI_COLS=""
  # 0 means "the terminal did not say"; only a genuinely narrow one is a problem
  case "$DK_UI_COLS" in ''|0|*[!0-9]*) DK_UI_COLS=80;; esac
  if [ "$DK_UI_COLS" -lt 44 ]; then dk_ui_close; return 1; fi
  printf '\033[?25l' >&3
  return 0
}

dk_ui_close() {
  [ "$DK_UI_ON" = 1 ] || return 0
  DK_UI_ON=0
  printf '\033[?25h' >&3 2>/dev/null || true
  if [ -n "$DK_UI_STTY" ]; then stty "$DK_UI_STTY" <&3 2>/dev/null || true; fi
  exec 3>&- || true
  return 0
}

# draw one line of the current frame (clearing whatever was there before)
dk_ui_line() {
  printf '%s\033[K\n' "$1" >&3
  DK_UI_LINES=$((DK_UI_LINES + 1))
}

# put the cursor back at the top of the frame so the next one overdraws it
dk_ui_rewind() {
  if [ "$DK_UI_LINES" -gt 0 ]; then printf '\033[%dA' "$DK_UI_LINES" >&3; fi
  DK_UI_LINES=0
}

# leave the widget: wipe its frame so the next one starts on a clean screen
dk_ui_wipe() {
  dk_ui_rewind
  printf '\033[J' >&3
}

dk_ui_header() {
  local l
  dk_ui_line ""
  dk_ui_line "  ${C_BLU}dev-kit${C_RST} ${C_DIM}$DEVKIT_VERSION${C_RST}  $1"
  dk_ui_line ""
  if [ -n "$DK_UI_NOTES" ]; then
    while IFS= read -r l; do dk_ui_line "$l"; done <<EOF
$DK_UI_NOTES
EOF
    dk_ui_line ""
  fi
}

dk_ui_footer() {
  dk_ui_line ""
  dk_ui_line "  ${C_DIM}$1${C_RST}"
  [ -n "${2:-}" ] && dk_ui_line "  ${C_DIM}$2${C_RST}"
  return 0
}

# read one keypress, print a symbolic name for it
dk_ui_key() {
  local k rest
  IFS= read -rsn1 k <&3 2>/dev/null || { printf 'quit'; return 0; }
  case "$k" in
    '')       printf 'enter'; return 0;;
    ' ')      printf 'space'; return 0;;
    $'\033')
      rest=''
      IFS= read -rsn2 -t 1 rest <&3 2>/dev/null || rest=''
      case "$rest" in
        '[A') printf 'up';;
        '[B') printf 'down';;
        '[C'|'[D') printf 'other';;
        '')   printf 'quit';;
        *)    printf 'other';;
      esac
      return 0;;
    $'\r'|$'\n') printf 'enter';;
    $'\003')  printf 'quit';;
    [0-9])    printf 'digit:%s' "$k";;
    k|K)      printf 'up';;
    j|J)      printf 'down';;
    a|A)      printf 'all';;
    n|N)      printf 'none';;
    i|I)      printf 'invert';;
    q|Q)      printf 'quit';;
    *)        printf 'other';;
  esac
}

dk_ui_nth() {
  local i=1 x
  for x in $2; do
    [ "$i" = "$1" ] && { printf '%s' "$x"; return 0; }
    i=$((i + 1))
  done
  return 1
}

# dk_ui_checklist TITLE ITEMS PRESELECTED LABEL_FN [MARK_FN]
#   result in DK_UI_RESULT; returns 1 when the user backs out
dk_ui_checklist() {
  local title=$1 items=$2 label_fn=$4 mark_fn=${5:-}
  local sel=" $3 " n=0 cur=0 first=1 i c key mark im ptr row
  for c in $items; do n=$((n + 1)); done
  if [ "$n" = 0 ]; then DK_UI_RESULT=""; return 0; fi
  while :; do
    if [ "$first" = 1 ]; then first=0; else dk_ui_rewind; fi
    dk_ui_header "$title"
    i=0
    for c in $items; do
      mark=" "; case "$sel" in *" $c "*) mark="x";; esac
      im="  "
      if [ -n "$mark_fn" ]; then im="$("$mark_fn" "$c")"; fi
      if [ "$i" = "$cur" ]; then ptr="$DK_UI_CUR"; else ptr=" "; fi
      row=$(printf '  %s [%s] %-7s %s%s' "$ptr" "$mark" "$c" "$im" "$("$label_fn" "$c")")
      if [ "$i" = "$cur" ]; then
        dk_ui_line "${C_GRN}${row}${C_RST}"
      else
        dk_ui_line "$row"
      fi
      i=$((i + 1))
    done
    dk_ui_footer "$(dk_t hint.chk1)" "$(dk_t hint.chk2)"
    key=$(dk_ui_key)
    case "$key" in
      up)    cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((n - 1));;
      down)  cur=$((cur + 1)); [ "$cur" -ge "$n" ] && cur=0;;
      space) c=$(dk_ui_nth $((cur + 1)) "$items"); sel=$(dk_ui_toggle "$sel" "$c");;
      digit:*)
        c=$(dk_ui_nth "${key#digit:}" "$items" 2>/dev/null || true)
        if [ -n "$c" ]; then sel=$(dk_ui_toggle "$sel" "$c"); fi;;
      all)   sel=" $items ";;
      none)  sel=" ";;
      invert)
        local inv=" "
        for c in $items; do
          case "$sel" in *" $c "*) ;; *) inv="$inv$c ";; esac
        done
        sel="$inv";;
      enter) break;;
      quit)  dk_ui_wipe; return 1;;
      *)     ;;
    esac
  done
  dk_ui_wipe
  DK_UI_RESULT=""
  for c in $items; do
    case "$sel" in *" $c "*) DK_UI_RESULT="$DK_UI_RESULT $c";; esac
  done
  DK_UI_RESULT=$(printf '%s' "$DK_UI_RESULT" | sed 's/^ *//')
  return 0
}

dk_ui_toggle() {
  case "$1" in
    *" $2 "*) printf '%s' "$1" | sed "s/ $2 / /";;
    *)        printf '%s%s ' "$1" "$2";;
  esac
}

# dk_ui_menu TITLE ITEMS MARKED CURSOR LABEL_FN
#   single choice; MARKED gets a dot, CURSOR is where the pointer starts.
#   result in DK_UI_RESULT; returns 1 when the user backs out
dk_ui_menu() {
  local title=$1 items=$2 marked=$3 want=$4 label_fn=$5
  local n=0 cur=0 first=1 i c key ptr dot row
  for c in $items; do
    [ "$c" = "$want" ] && cur=$n
    n=$((n + 1))
  done
  if [ "$n" = 0 ]; then DK_UI_RESULT=""; return 1; fi
  while :; do
    if [ "$first" = 1 ]; then first=0; else dk_ui_rewind; fi
    dk_ui_header "$title"
    i=0
    for c in $items; do
      if [ "$i" = "$cur" ]; then ptr="$DK_UI_CUR"; else ptr=" "; fi
      if [ -n "$marked" ] && [ "$c" = "$marked" ]; then dot="$DK_UI_DOT"; else dot=" "; fi
      row=$(printf '  %s %s %s' "$ptr" "$dot" "$("$label_fn" "$c")")
      if [ "$i" = "$cur" ]; then
        dk_ui_line "${C_GRN}${row}${C_RST}"
      else
        dk_ui_line "$row"
      fi
      i=$((i + 1))
    done
    dk_ui_footer "$(dk_t hint.menu1)"
    key=$(dk_ui_key)
    case "$key" in
      up)    cur=$((cur - 1)); [ "$cur" -lt 0 ] && cur=$((n - 1));;
      down)  cur=$((cur + 1)); [ "$cur" -ge "$n" ] && cur=0;;
      digit:*)
        c=$(dk_ui_nth "${key#digit:}" "$items" 2>/dev/null || true)
        if [ -n "$c" ]; then cur=$(( ${key#digit:} - 1 )); fi;;
      enter|space) break;;
      quit)  dk_ui_wipe; return 1;;
      *)     ;;
    esac
  done
  dk_ui_wipe
  DK_UI_RESULT=$(dk_ui_nth $((cur + 1)) "$items")
  return 0
}

# dk_ui_input TITLE DEFAULT -> DK_UI_RESULT (empty means "keep the default")
dk_ui_input() {
  local line=""
  dk_ui_header "$1"
  if [ -n "$2" ]; then
    dk_ui_line "  ${C_DIM}$(dk_t val.default): $2${C_RST}"
  fi
  dk_ui_footer "$(dk_t hint.input)"
  dk_ui_line ""
  # hand the terminal back to cooked mode for the duration of the read
  if [ -n "$DK_UI_STTY" ]; then stty "$DK_UI_STTY" <&3 2>/dev/null || true; fi
  printf '\033[?25h  > ' >&3
  IFS= read -r line <&3 2>/dev/null || line=""
  printf '\033[?25l' >&3
  stty -icanon -echo min 1 time 0 <&3 2>/dev/null || true
  DK_UI_LINES=$((DK_UI_LINES + 1))
  dk_ui_wipe
  DK_UI_RESULT=$(printf '%s' "$line" | tr -d '\r' | sed 's/^ *//; s/ *$//')
  return 0
}

# dk_ui_yesno TITLE CURRENT(0|1) -> 0 = yes, 1 = no, 2 = backed out
dk_ui_yesno() {
  local want=no
  [ "$2" = 1 ] && want=yes
  dk_ui_menu "$1" "yes no" "$want" "$want" dk_ui_yesno_label || return 2
  [ "$DK_UI_RESULT" = yes ] && return 0
  return 1
}
dk_ui_yesno_label() {
  case "$1" in
    yes) dk_t val.yes;;
    *)   dk_t val.no;;
  esac
}

# ---------------------------------------------------------------------------
# interactive wizard: mode -> components -> options -> run
# ---------------------------------------------------------------------------
dk_wizard_wanted() {
  [ "$DK_ALL" = 1 ] && return 1
  [ -n "$DK_WITH" ] && return 1
  [ "$DK_YES" = 1 ] && return 1
  dk_ui_supported || return 1
  return 0
}

dk_wiz_mode_label() {
  case "$1" in
    install)   dk_t mode.install;;
    uninstall) dk_t mode.uninst;;
    *)         dk_t mode.quit;;
  esac
}

dk_wiz_inst_mark() {
  if dk_detect_installed "$1"; then printf '%s' "* "; else printf '%s' "  "; fi
}

dk_wiz_pick() {
  local c installed="" title
  installed=""
  for c in $DK_COMPONENTS_ALL; do dk_detect_installed "$c" && installed="$installed$c "; done
  # coming back from a later step: keep what was ticked, do not reset it
  if [ "$DK_MODE" = uninstall ]; then
    [ -n "$installed" ] || { dk_ui_close; dk_die "$(dk_t msg.noinst)"; }
    title=$(dk_t pick.uninst)
    while :; do
      dk_ui_checklist "$title" "$DK_COMPONENTS_ALL" "$DK_SELECTED" dk_comp_desc dk_wiz_inst_mark || return 1
      [ -n "$DK_UI_RESULT" ] && break
      title="$(dk_t pick.uninst)   ${C_YEL}$(dk_t msg.none)${C_RST}"
    done
  else
    [ -n "$DK_SELECTED" ] && installed="$DK_SELECTED"
    title=$(dk_t pick.install)
    while :; do
      dk_ui_checklist "$title" "$DK_COMPONENTS_ALL" "$installed" dk_comp_desc || return 1
      [ -n "$DK_UI_RESULT" ] && break
      title="$(dk_t pick.install)   ${C_YEL}$(dk_t msg.none)${C_RST}"
    done
  fi
  DK_SELECTED="$DK_UI_RESULT"

  # maven/gradle need a JDK
  if [ "$DK_MODE" = install ] && dk_selected_any maven gradle && ! dk_selected jdk; then
    if ! command -v java >/dev/null 2>&1 && [ ! -d "$SDKMAN_DIR/candidates/java/current" ]; then
      dk_info "maven/gradle need a JDK; adding jdk to the selection"
      DK_SELECTED="$DK_SELECTED jdk"
    fi
  fi
  if [ "$DK_MODE" = install ] && dk_selected jdk && [ -z "$DK_JDK_MAJORS" ]; then
    if [ -n "$DK_JDK_VERSION" ]; then
      DK_JDK_MAJORS=$(printf '%s' "$DK_JDK_VERSION" | tr ',' ' ')
    else
      dk_ui_line "  ${C_DIM}$(dk_t msg.loading)${C_RST}"
      DK_JDK_MAJORS=$(dk_default_jdk_majors)
      dk_ui_wipe
    fi
  fi
  return 0
}

dk_wiz_option_items() {
  local items=""
  if [ "$DK_MODE" = uninstall ]; then
    printf 'cache startu back'
    return 0
  fi
  dk_selected jdk  && items="$items jdk"
  dk_selected go   && items="$items go"
  dk_selected rust && items="$items rust"
  dk_selected node && items="$items node"
  items="$items mirror shell start back"
  printf '%s' "$items" | sed 's/^ *//'
}

dk_wiz_yesno_text() {
  if [ "$1" = 1 ]; then dk_t val.yes; else dk_t val.no; fi
}

dk_wiz_opt_label() {
  case "$1" in
    jdk)    printf '%s: %s' "$(dk_t lbl.jdk)"    "$DK_JDK_MAJORS";;
    go)     printf '%s: %s' "$(dk_t lbl.go)"     "${DK_GO_VERSION:-$(dk_t val.latest)}";;
    rust)   printf '%s: %s' "$(dk_t lbl.rust)"   "${DK_RUST_VERSION:-stable}";;
    node)   printf '%s: %s' "$(dk_t lbl.node)"   "${DK_NODE_VERSION:-$(dk_t val.lts)}";;
    mirror) printf '%s: %s' "$(dk_t lbl.mirror)" "$DK_MIRROR_ARG";;
    shell)  printf '%s: %s' "$(dk_t lbl.shell)"  "$(dk_wiz_yesno_text $((1 - DK_NO_SHELL_INIT)))";;
    cache)  printf '%s: %s' "$(dk_t lbl.cache)"  "$(dk_wiz_yesno_text "$DK_KEEP_CACHE")";;
    start)  printf '%s%s' "$DK_UI_GO"   "$(dk_t act.start)";;
    startu) printf '%s%s' "$DK_UI_GO"   "$(dk_t act.startu)";;
    back)   printf '%s%s' "$DK_UI_BACK" "$(dk_t act.back)";;
    *)      printf '%s' "$1";;
  esac
}

dk_wiz_choice_label() {
  case "$1" in
    latest) dk_t val.latest;;
    lts)    dk_t val.lts;;
    custom) dk_t val.custom;;
    auto)   dk_t val.auto;;
    cn)     dk_t val.cn;;
    off)    dk_t val.off;;
    *)      printf '%s' "$1";;
  esac
}
dk_wiz_jdk_label() { printf ''; }

# dk_wiz_ask_version PROMPT_KEY CURRENT VALIDATOR -> DK_UI_RESULT ('' = unchanged)
dk_wiz_ask_version() {
  local title cur=$2 v
  title=$(dk_t "$1")
  while :; do
    dk_ui_input "$title" "$cur"
    v=$DK_UI_RESULT
    [ -z "$v" ] && { DK_UI_RESULT=""; return 0; }
    if "$3" "$v"; then DK_UI_RESULT="$v"; return 0; fi
    title="$(dk_t "$1")   ${C_YEL}$(dk_t msg.badver)${C_RST}"
  done
}
dk_is_major() { printf '%s' "$1" | grep -qE '^[0-9]+$'; }

dk_wiz_edit_go() {
  local marked=latest
  [ -n "$DK_GO_VERSION" ] && marked=custom
  dk_ui_menu "$(dk_t lbl.go)" "latest custom" "$marked" "$marked" dk_wiz_choice_label || return 0
  case "$DK_UI_RESULT" in
    latest) DK_GO_VERSION="";;
    custom) dk_wiz_ask_version in.go "$DK_GO_VERSION" dk_is_semver
            [ -n "$DK_UI_RESULT" ] && DK_GO_VERSION="$DK_UI_RESULT";;
  esac
  return 0
}

dk_wiz_edit_rust() {
  local marked=stable
  case "${DK_RUST_VERSION:-stable}" in
    stable|beta|nightly) marked="${DK_RUST_VERSION:-stable}";;
    *) marked=custom;;
  esac
  dk_ui_menu "$(dk_t lbl.rust)" "stable beta nightly custom" "$marked" "$marked" dk_wiz_choice_label || return 0
  case "$DK_UI_RESULT" in
    custom) dk_wiz_ask_version in.rust "$DK_RUST_VERSION" dk_is_semver
            [ -n "$DK_UI_RESULT" ] && DK_RUST_VERSION="$DK_UI_RESULT";;
    stable) DK_RUST_VERSION="";;
    *)      DK_RUST_VERSION="$DK_UI_RESULT";;
  esac
  return 0
}

dk_wiz_edit_node() {
  local marked=lts
  case "${DK_NODE_VERSION:-lts}" in lts) marked=lts;; *) marked=custom;; esac
  dk_ui_menu "$(dk_t lbl.node)" "lts custom" "$marked" "$marked" dk_wiz_choice_label || return 0
  case "$DK_UI_RESULT" in
    lts)    DK_NODE_VERSION="";;
    custom) dk_wiz_ask_version in.node "$DK_NODE_VERSION" dk_is_major
            [ -n "$DK_UI_RESULT" ] && DK_NODE_VERSION="$DK_UI_RESULT";;
  esac
  return 0
}

dk_wiz_edit_mirror() {
  dk_ui_menu "$(dk_t lbl.mirror)" "auto cn off" "$DK_MIRROR_ARG" "$DK_MIRROR_ARG" dk_wiz_choice_label || return 0
  DK_MIRROR_ARG="$DK_UI_RESULT"
  return 0
}

dk_wiz_edit_jdk() {
  local avail
  dk_ui_line "  ${C_DIM}$(dk_t msg.loading)${C_RST}"
  avail=$(dk_available_jdk_majors)
  dk_ui_wipe
  dk_ui_checklist "$(dk_t lbl.jdk)" "$avail" "$DK_JDK_MAJORS" dk_wiz_jdk_label || return 0
  [ -n "$DK_UI_RESULT" ] && DK_JDK_MAJORS="$DK_UI_RESULT"
  return 0
}

dk_wiz_summary_note() {
  if [ "$DK_MODE" = uninstall ]; then
    printf '  %s%s' "$(dk_t sum.uninst)" "$DK_SELECTED"
  else
    printf '  %s%s' "$(dk_t sum.install)" "$DK_SELECTED"
  fi
}

# 0 = start, 2 = back to the component picker
dk_wiz_options() {
  local items cur=start rc
  [ "$DK_MODE" = uninstall ] && cur=startu
  while :; do
    items=$(dk_wiz_option_items)
    DK_UI_NOTES=$(dk_wiz_summary_note)
    rc=0
    if [ "$DK_MODE" = uninstall ]; then
      dk_ui_menu "$(dk_t opts.titleu)" "$items" "" "$cur" dk_wiz_opt_label || rc=$?
    else
      dk_ui_menu "$(dk_t opts.title)" "$items" "" "$cur" dk_wiz_opt_label || rc=$?
    fi
    DK_UI_NOTES=""
    [ "$rc" = 0 ] || return 2
    cur=$DK_UI_RESULT
    case "$DK_UI_RESULT" in
      start|startu) return 0;;
      back)   return 2;;
      jdk)    dk_wiz_edit_jdk;;
      go)     dk_wiz_edit_go;;
      rust)   dk_wiz_edit_rust;;
      node)   dk_wiz_edit_node;;
      mirror) dk_wiz_edit_mirror;;
      shell)  rc=0; dk_ui_yesno "$(dk_t lbl.shell)" $((1 - DK_NO_SHELL_INIT)) || rc=$?
              if   [ "$rc" = 0 ]; then DK_NO_SHELL_INIT=0
              elif [ "$rc" = 1 ]; then DK_NO_SHELL_INIT=1; fi;;
      cache)  rc=0; dk_ui_yesno "$(dk_t lbl.cache)" "$DK_KEEP_CACHE" || rc=$?
              if   [ "$rc" = 0 ]; then DK_KEEP_CACHE=1
              elif [ "$rc" = 1 ]; then DK_KEEP_CACHE=0; fi;;
    esac
  done
}

# last stop before deleting things; 0 = go ahead, 1 = back to the options
dk_wiz_confirm_uninstall() {
  local rc=0 note
  if [ "$DK_KEEP_CACHE" = 1 ]; then note=$(dk_t sum.u1k); else note=$(dk_t sum.u1); fi
  DK_UI_NOTES=$(printf '  %s%s\n  %s%s%s\n  %s' \
    "$(dk_t sum.uninst)" "$DK_SELECTED" "$C_YEL" "$note" "$C_RST" "$(dk_t sum.u2)")
  dk_ui_yesno "$(dk_t sum.ask)" 0 || rc=$?
  DK_UI_NOTES=""
  [ "$rc" = 0 ] && return 0
  return 1
}

dk_wizard() {
  local step=1 rc
  dk_ui_open || return 1
  [ "$DK_MODE_FORCED" = 1 ] && step=2
  while :; do
    case "$step" in
      1)
        rc=0
        dk_ui_menu "$(dk_t mode.title)" "install uninstall quit" "" install dk_wiz_mode_label || rc=$?
        if [ "$rc" != 0 ]; then dk_ui_close; dk_info "$(dk_t msg.cancel)"; exit 0; fi
        case "$DK_UI_RESULT" in
          install)   DK_MODE=install;   step=2;;
          uninstall) DK_MODE=uninstall; step=2;;
          *)         dk_ui_close; exit 0;;
        esac;;
      2)
        rc=0; dk_wiz_pick || rc=$?
        if [ "$rc" != 0 ]; then
          if [ "$DK_MODE_FORCED" = 1 ]; then dk_ui_close; dk_info "$(dk_t msg.cancel)"; exit 0; fi
          step=1; continue
        fi
        step=3;;
      3)
        rc=0; dk_wiz_options || rc=$?
        if [ "$rc" != 0 ]; then step=2; continue; fi
        if [ "$DK_MODE" = uninstall ]; then step=4; else break; fi;;
      4)
        rc=0; dk_wiz_confirm_uninstall || rc=$?
        if [ "$rc" != 0 ]; then step=3; continue; fi
        break;;
    esac
  done
  dk_ui_close
  DK_CONFIRMED=1
  if dk_selected jdk && [ -n "$DK_JDK_MAJORS" ]; then
    DK_JDK_DEFAULT=$(printf '%s' "$DK_JDK_MAJORS" | awk '{print $1}')
  fi
  return 0
}

# ---------------------------------------------------------------------------
# orchestration
# ---------------------------------------------------------------------------
dk_run_component() {
  local name=$1 fn=${2:-dk_c_} rc=0
  set +e
  ( set -Eeuo pipefail
    trap 'dk_err "[$name] failed at line $LINENO: $BASH_COMMAND"' ERR
    "$fn$name" )
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    dk_ok "$name"
  else
    DK_FAILED="$DK_FAILED $name"
  fi
}

main() {
  dk_parse_args "$@"
  dk_detect_lang
  dk_detect_platform
  dk_setup_dirs
  dk_setup_sudo
  if dk_wizard_wanted && dk_wizard; then :; else dk_resolve_selection; fi

  if [ "$DK_MODE" = uninstall ]; then
    DK_MIRROR=$(dk_state_get mirror); [ -n "$DK_MIRROR" ] || DK_MIRROR=off
    dk_info "mode: uninstall"
    dk_info "components: $DK_SELECTED"
    dk_uninstall_flow
    return
  fi

  dk_detect_mirror
  dk_state_set mirror "$DK_MIRROR"
  dk_info "platform: $DK_OS/$DK_ARCH ($DK_LIBC), pkg: $DK_PKG, mirror: $DK_MIRROR"
  dk_info "components: $DK_SELECTED"
  dk_selected jdk && dk_info "jdk majors: $DK_JDK_MAJORS (default $DK_JDK_DEFAULT)"

  dk_install_prereqs

  if dk_selected_any jdk maven gradle; then
    if dk_ensure_sdkman; then DK_SDKMAN_OK=1; else dk_err "SDKMAN setup failed; skipping jdk/maven/gradle"; fi
  fi

  local c
  for c in $DK_ORDER; do
    dk_selected "$c" || continue
    dk_run_component "$c"
  done

  dk_write_env_sh
  dk_integrate_rc
  dk_doctor

  [ -z "$DK_FAILED" ] || exit 2
}

main "$@"
