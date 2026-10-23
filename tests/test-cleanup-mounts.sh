#!/usr/bin/env bash
# test-cleanup-mounts.sh — Unit tests for usr/sbin/omv-sftp-cleanup-mounts.
#
# Usage: ./tests/test-cleanup-mounts.sh
#
# Runs against a temporary directory (SFTP_ROOT) and does not need
# openmediavault. Run as root to also test unmounting a stale bind mount.

set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/usr/sbin/omv-sftp-cleanup-mounts"

# ---------------------------------------------------------------------------
# Colours / counters
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
declare -a FAILED_TESTS=()

section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}" >&2; }
info()    { echo -e "  ${YELLOW}»${NC} $*" >&2; }

_pass() {
    echo -e "  ${GREEN}PASS${NC}  $1" >&2
    ((PASS++)) || true
}
_fail() {
    echo -e "  ${RED}FAIL${NC}  $1" >&2
    [ -n "${2:-}" ] && echo -e "         ${RED}→${NC} $2" >&2
    ((FAIL++)) || true
    FAILED_TESTS+=("$1")
}

assert_exists() {
    if [ -e "$2" ]; then _pass "$1"; else _fail "$1" "missing: $2"; fi
}
assert_absent() {
    if [ ! -e "$2" ]; then _pass "$1"; else _fail "$1" "still present: $2"; fi
}

# Run the script with SFTP_ROOT set. Usage: run [--check] [expected...]
run() {
    SFTP_ROOT="$ROOT" "$SCRIPT" "$@"
}

# ---------------------------------------------------------------------------
# Setup / cleanup
# ---------------------------------------------------------------------------
ROOT=""
BIND_SRC=""

cleanup() {
    if [ -n "$ROOT" ]; then
        # Never leave a test bind mount behind before removing the tree.
        for d in "$ROOT"/*/*/; do
            mountpoint -q "$d" 2>/dev/null && umount --lazy "$d"
        done
        rm -rf "$ROOT"
    fi
    [ -n "$BIND_SRC" ] && rm -rf "$BIND_SRC"
}
trap cleanup EXIT

section "Pre-flight"

if [ -x "$SCRIPT" ]; then
    _pass "script found: $SCRIPT"
else
    echo -e "\n${RED}$SCRIPT not found or not executable — aborting.${NC}" >&2
    exit 1
fi

ROOT=$(mktemp -d)
info "SFTP_ROOT: $ROOT"

# ===========================================================================
section "Nothing to clean up"
# ===========================================================================

if run --check; then
    _fail "--check on empty root reports nothing to do" "exit 0"
else
    _pass "--check on empty root reports nothing to do"
fi
if run; then
    _pass "run on empty root succeeds"
else
    _fail "run on empty root succeeds"
fi

# An expected (configured) mount point, a non-empty directory, the rsyslog
# 'dev' directory and an empty user directory are never stale.
mkdir -p "$ROOT/alice/Media" "$ROOT/alice/data" "$ROOT/alice/dev" "$ROOT/carol"
echo "keep" > "$ROOT/alice/data/file"
touch "$ROOT/alice/dev/log"
mkdir -p "$ROOT/bob/dev"

if run --check "$ROOT/alice/Media"; then
    _fail "--check ignores expected, non-empty and dev directories" "exit 0"
else
    _pass "--check ignores expected, non-empty and dev directories"
fi

# ===========================================================================
section "Stale empty directories"
# ===========================================================================

mkdir -p "$ROOT/alice/Old" "$ROOT/alice/With Space" "$ROOT/alice/It's" \
    "$ROOT/bob/Gone" "$ROOT/alice/Keep Me"

if run --check "$ROOT/alice/Media" "$ROOT/alice/Keep Me/"; then
    _pass "--check reports stale directories"
else
    _fail "--check reports stale directories" "exit 1"
fi

if run "$ROOT/alice/Media" "$ROOT/alice/Keep Me/"; then
    _pass "run succeeds"
else
    _fail "run succeeds"
fi

assert_absent "stale empty directory removed" "$ROOT/alice/Old"
assert_absent "stale directory with a space removed" "$ROOT/alice/With Space"
assert_absent "stale directory with a quote removed" "$ROOT/alice/It's"
assert_absent "stale directory of another user removed" "$ROOT/bob/Gone"
assert_exists "expected empty directory kept" "$ROOT/alice/Media"
assert_exists "expected directory given with trailing slash kept" "$ROOT/alice/Keep Me"
assert_exists "non-empty directory kept" "$ROOT/alice/data/file"
assert_exists "dev directory with content kept" "$ROOT/alice/dev/log"
assert_exists "empty dev directory kept" "$ROOT/bob/dev"
assert_exists "user directory kept" "$ROOT/carol"

if run --check "$ROOT/alice/Media" "$ROOT/alice/Keep Me"; then
    _fail "--check reports nothing to do after cleanup" "exit 0"
else
    _pass "--check reports nothing to do after cleanup"
fi

# ===========================================================================
section "Stale bind mount"
# ===========================================================================

if [ "$(id -u)" -ne 0 ]; then
    info "Not running as root — skipping bind mount tests"
else
    BIND_SRC=$(mktemp -d)
    echo "user data" > "$BIND_SRC/file"
    mkdir -p "$ROOT/alice/Mounted" "$ROOT/alice/Stale Mount"
    mount --bind "$BIND_SRC" "$ROOT/alice/Mounted"
    mount --bind "$BIND_SRC" "$ROOT/alice/Stale Mount"

    if run --check "$ROOT/alice/Media" "$ROOT/alice/Mounted"; then
        _pass "--check reports a stale bind mount"
    else
        _fail "--check reports a stale bind mount" "exit 1"
    fi

    run "$ROOT/alice/Media" "$ROOT/alice/Mounted"

    if mountpoint -q "$ROOT/alice/Stale Mount" 2>/dev/null; then
        _fail "stale bind mount unmounted"
    else
        _pass "stale bind mount unmounted"
    fi
    assert_absent "stale mount point directory removed" "$ROOT/alice/Stale Mount"
    if mountpoint -q "$ROOT/alice/Mounted"; then
        _pass "expected bind mount kept"
    else
        _fail "expected bind mount kept"
    fi
    assert_exists "data of the unmounted source untouched" "$BIND_SRC/file"
fi

# ===========================================================================
section "Summary"
# ===========================================================================
TOTAL=$((PASS + FAIL))
echo >&2
echo -e "  Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC} (${TOTAL} total)" >&2
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    echo -e "\n  ${RED}Failed tests:${NC}" >&2
    for t in "${FAILED_TESTS[@]}"; do
        echo -e "    ${RED}✗${NC} $t" >&2
    done
fi
echo >&2
[ $FAIL -eq 0 ]
