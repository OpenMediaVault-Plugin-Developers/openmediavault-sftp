#!/usr/bin/env bash
# test-rpc.sh — Integration tests for openmediavault-sftp RPC methods.
#
# Usage: sudo ./tests/test-rpc.sh <sharedfolder> <username>
#
# Exercises all Sftp RPC methods: settings CRUD, share CRUD, validation, a
# deploy cycle that verifies the /sftp bind mount is created and cleaned up,
# a regression test for the shared-folder path-change bug (stale bind mount
# not updated when the shared folder's path changes in OMV), and a regression
# test that duplicate user/shared-folder share entries are rejected.
#
# Prerequisites:
#   <sharedfolder> — name or UUID of an existing OMV shared folder
#   <username>     — system user with read-only (5) or read-write (7)
#                    privileges on that shared folder
#
# Find values with:
#   omv-rpc -u admin ShareMgmt getList \
#     '{"start":0,"limit":25,"sortfield":null,"sortdir":null}'
#
# WARNING: This script transiently modifies SFTP settings (port, auth options)
# and creates/deletes test SFTP shares.  Run on a test system or during a
# maintenance window.

set -uo pipefail

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
if [ $# -lt 2 ]; then
    echo "Usage: $(basename "$0") <sharedfolder> <username>" >&2
    echo "" >&2
    echo "  <sharedfolder>  name or UUID of an OMV shared folder" >&2
    echo "  <username>      system user with read or write access to that folder" >&2
    echo "" >&2
    echo "  Find shared folders:" >&2
    echo "    omv-rpc -u admin ShareMgmt getList" \
         "'{\"start\":0,\"limit\":25,\"sortfield\":null,\"sortdir\":null}'" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "Must be run as root." >&2
    exit 1
fi

SF_REF="$1"
TEST_USER="$2"

# ---------------------------------------------------------------------------
# Colours / counters  (display → stderr; $() captures only JSON)
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

# ---------------------------------------------------------------------------
# RPC helpers
# ---------------------------------------------------------------------------
rpc() {
    local svc=$1 method=$2 params=${3:-'{}'}
    omv-rpc -u admin "$svc" "$method" "$params"
}

assert_rpc() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'} pattern=${5:-}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -ne 0 ]; then
        _fail "$desc" "$(echo "$out" | tail -3)"
        return 1
    fi
    if [ -n "$pattern" ] && ! echo "$out" | grep -q "$pattern"; then
        _fail "$desc" "Pattern '$pattern' not found in: ${out:0:200}"
        return 1
    fi
    _pass "$desc"
    echo "$out"
    return 0
}

assert_rpc_fails() {
    local desc=$1 svc=$2 method=$3 params=${4:-'{}'}
    local out ec=0
    out=$(omv-rpc -u admin "$svc" "$method" "$params" 2>&1) || ec=$?
    if [ $ec -eq 0 ] && ! echo "$out" | grep -qi "exception"; then
        _fail "$desc" "Expected failure but RPC succeeded: ${out:0:200}"
        return 1
    fi
    _pass "$desc"
    return 0
}

# Deploy fstab, sftp, systemd in one salt call.
# Returns 1 if the deploy failed.
deploy_dirty() {
    if omv-salt deploy run fstab sftp systemd &>/dev/null; then
        _pass "omv-salt deploy run fstab sftp systemd"
    else
        _fail "omv-salt deploy run fstab sftp systemd"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
SHARE_UUID=""
DELETED_UUID=""
ORIG_SETTINGS=""
SF_NAME=""
SF_RELDIRPATH=""
SF_MNTENTREF=""
SF_COMMENT=""
SF_MODE=""
SF_PATH_CHANGED=false
NEW_PATH_DIR=""

LIST_PARAMS='{"start":0,"limit":null,"sortfield":null,"sortdir":null}'
OMV_NEW_UUID=$(. /etc/default/openmediavault 2>/dev/null; \
    echo "${OMV_CONFIGOBJECT_NEW_UUID:-fa4b1c66-ef79-11e5-87a0-0002b3a176b4}")

# ---------------------------------------------------------------------------
# Cleanup — always runs on exit
# ---------------------------------------------------------------------------
cleanup() {
    section "Cleanup"

    if [ -n "$SHARE_UUID" ]; then
        info "Deleting test share $SHARE_UUID"
        rpc "Sftp" "deleteShare" "{\"uuid\":\"$SHARE_UUID\"}" &>/dev/null || true
        SHARE_UUID=""
    fi

    if [ -n "$NEW_PATH_DIR" ]; then
        info "Removing test path directory $NEW_PATH_DIR"
        rm -rf "$NEW_PATH_DIR" 2>/dev/null || true
        NEW_PATH_DIR=""
    fi

    if $SF_PATH_CHANGED; then
        info "Restoring original shared folder path ($SF_RELDIRPATH)"
        rpc "ShareMgmt" "set" "$(jq -n \
            --arg uuid      "$SF_REF"       \
            --arg name      "$SF_NAME"      \
            --arg mntentref "$SF_MNTENTREF" \
            --arg reldirpath "$SF_RELDIRPATH" \
            --arg comment   "$SF_COMMENT"   \
            --arg mode      "$SF_MODE"      \
            '{uuid:$uuid,name:$name,mntentref:$mntentref,
              reldirpath:$reldirpath,comment:$comment,mode:$mode}')" \
            &>/dev/null || true
        deploy_dirty &>/dev/null || true
        SF_PATH_CHANGED=false
    fi

    if [ -n "$ORIG_SETTINGS" ]; then
        info "Restoring original SFTP settings"
        local restore
        restore=$(echo "$ORIG_SETTINGS" | jq 'del(.shares)' 2>/dev/null || echo "")
        [ -n "$restore" ] && rpc "Sftp" "setSettings" "$restore" &>/dev/null || true
    fi

    info "Done."
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
section "Pre-flight"

for cmd in omv-rpc jq python3; do
    if command -v "$cmd" &>/dev/null; then
        _pass "command available: $cmd"
    else
        _fail "command available: $cmd" "$cmd not found"
    fi
done

if command -v omv-salt &>/dev/null; then
    _pass "command available: omv-salt"
else
    info "omv-salt not found — deploy and bind-mount tests will be skipped"
fi

if command -v findmnt &>/dev/null; then
    _pass "command available: findmnt"
else
    info "findmnt not found — bind-mount source checks will be skipped"
fi

if ! omv-rpc -u admin "Config" "isDirty" '{}' &>/dev/null; then
    echo -e "\n${RED}omv-rpc not functional — aborting.${NC}" >&2
    exit 1
fi
_pass "omv-rpc functional"

# Resolve shared folder — accept either a UUID or a name
if echo "$SF_REF" | grep -qE \
        '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
    SF_JSON=$(omv-rpc -u admin "ShareMgmt" "get" "{\"uuid\":\"$SF_REF\"}" 2>&1) \
        && SF_EC=0 || SF_EC=$?
    if [ $SF_EC -ne 0 ]; then
        echo -e "\n${RED}Shared folder UUID $SF_REF not found — aborting.${NC}" >&2
        echo "  omv-rpc -u admin ShareMgmt getList" \
             "'{\"start\":0,\"limit\":25,\"sortfield\":null,\"sortdir\":null}'" >&2
        exit 1
    fi
else
    SF_LIST=$(omv-rpc -u admin "ShareMgmt" "getList" \
        '{"start":0,"limit":null,"sortfield":null,"sortdir":null}' 2>/dev/null \
        || echo '{"data":[]}')
    SF_REF=$(echo "$SF_LIST" \
        | jq -r --arg n "$SF_REF" '.data[] | select(.name == $n) | .uuid' \
        | head -1)
    if [ -z "$SF_REF" ]; then
        echo -e "\n${RED}No shared folder named '$1' found — aborting.${NC}" >&2
        echo "  omv-rpc -u admin ShareMgmt getList" \
             "'{\"start\":0,\"limit\":25,\"sortfield\":null,\"sortdir\":null}'" >&2
        exit 1
    fi
    SF_JSON=$(omv-rpc -u admin "ShareMgmt" "get" "{\"uuid\":\"$SF_REF\"}" 2>&1)
fi

SF_NAME=$(echo "$SF_JSON"      | jq -r '.name       // ""')
SF_RELDIRPATH=$(echo "$SF_JSON" | jq -r '.reldirpath // ""')
SF_MNTENTREF=$(echo "$SF_JSON"  | jq -r '.mntentref  // ""')
SF_COMMENT=$(echo "$SF_JSON"   | jq -r '.comment    // ""')
SF_MODE=$(echo "$SF_JSON"      | jq -r '.mode       // "775"')
_pass "shared folder found: $SF_NAME ($SF_REF)"

# Verify user exists on this system
if id "$TEST_USER" &>/dev/null; then
    _pass "user exists: $TEST_USER"
else
    echo -e "\n${RED}User '$TEST_USER' not found on this system — aborting.${NC}" >&2
    exit 1
fi

# Verify user has read or read-write privileges on the shared folder
if echo "$SF_JSON" | jq -e \
        --arg u "$TEST_USER" \
        '.privileges.privilege
         | if type == "object" then [.] else . end
         | .[] | select(.name == $u and (.perms == 5 or .perms == 7))' \
        &>/dev/null; then
    _pass "user '$TEST_USER' has read/write privileges on '$SF_NAME'"
else
    echo -e "\n${RED}User '$TEST_USER' lacks read or read-write privileges on '$SF_NAME' — aborting.${NC}" >&2
    echo "  Grant via OMV → Access Rights Management → Shared Folders → Privileges." >&2
    exit 1
fi

section "Configuration"
info "Shared folder : $SF_NAME  ($SF_REF)"
info "Username      : $TEST_USER"

# ===========================================================================
section "Settings — read"
# ===========================================================================

ORIG_SETTINGS=$(assert_rpc "getSettings" "Sftp" "getSettings") || {
    echo -e "\n${RED}getSettings failed — aborting.${NC}" >&2
    exit 1
}

for field in enable port passwordauthentication pubkeyauthentication allowgroups extraoptions; do
    if echo "$ORIG_SETTINGS" | jq -e "has(\"$field\")" &>/dev/null; then
        _pass "getSettings — field '$field' present"
    else
        _fail "getSettings — field '$field' missing"
    fi
done

ORIG_PORT=$(echo "$ORIG_SETTINGS" | jq -r '.port // 222')
info "Current port: $ORIG_PORT"

# ===========================================================================
section "Settings — write"
# ===========================================================================

assert_rpc "setSettings — change port to 2222" "Sftp" "setSettings" \
    '{"enable":false,"port":2222,"passwordauthentication":true,"pubkeyauthentication":false,"allowgroups":false,"rsyslog":true,"extraoptions":""}' \
    '"port":2222' >/dev/null

assert_rpc "setSettings — pubkey auth + allowgroups" "Sftp" "setSettings" \
    '{"enable":false,"port":2222,"passwordauthentication":false,"pubkeyauthentication":true,"allowgroups":true,"rsyslog":false,"extraoptions":""}' \
    '"pubkeyauthentication":true' >/dev/null

assert_rpc "setSettings — extraoptions" "Sftp" "setSettings" \
    '{"enable":false,"port":2222,"passwordauthentication":true,"pubkeyauthentication":false,"allowgroups":false,"rsyslog":true,"extraoptions":"MaxSessions 5"}' \
    'MaxSessions' >/dev/null

# Restore before negative tests to avoid bad state persisting on failure
RESTORE=$(echo "$ORIG_SETTINGS" | jq 'del(.shares)' 2>/dev/null || echo "")
[ -n "$RESTORE" ] && rpc "Sftp" "setSettings" "$RESTORE" &>/dev/null || true

# ===========================================================================
section "Settings — negative tests"
# ===========================================================================

assert_rpc_fails "setSettings — port 0 rejected" "Sftp" "setSettings" \
    '{"enable":false,"port":0,"passwordauthentication":true,"pubkeyauthentication":false,"allowgroups":false,"rsyslog":true,"extraoptions":""}'

assert_rpc_fails "setSettings — port 65536 rejected" "Sftp" "setSettings" \
    '{"enable":false,"port":65536,"passwordauthentication":true,"pubkeyauthentication":false,"allowgroups":false,"rsyslog":true,"extraoptions":""}'

assert_rpc_fails "setSettings — missing port" "Sftp" "setSettings" \
    '{"enable":false,"passwordauthentication":true,"extraoptions":""}'

assert_rpc_fails "setSettings — missing enable" "Sftp" "setSettings" \
    '{"port":222,"passwordauthentication":true,"extraoptions":""}'

# ===========================================================================
section "Share — CRUD"
# ===========================================================================

assert_rpc "getShareList (initial)" "Sftp" "getShareList" "$LIST_PARAMS" >/dev/null

# Create test share — use rpc() directly to capture UUID cleanly
SHARE_RESULT=$(rpc "Sftp" "setShare" "$(jq -n \
    --arg uuid "$OMV_NEW_UUID" --arg sfref "$SF_REF" --arg user "$TEST_USER" \
    '{uuid:$uuid,sharedfolderref:$sfref,username:$user}')" 2>&1) \
    && CREAT_EC=0 || CREAT_EC=$?

SHARE_UUID=$(echo "$SHARE_RESULT" | jq -r '.uuid // ""' 2>/dev/null || echo "")

if [ $CREAT_EC -eq 0 ] && [ -n "$SHARE_UUID" ] && [ "$SHARE_UUID" != "$OMV_NEW_UUID" ]; then
    _pass "setShare (create) — UUID: $SHARE_UUID"
else
    _fail "setShare (create)" "${SHARE_RESULT:0:200}"
    SHARE_UUID=""
fi

if [ -n "$SHARE_UUID" ]; then
    # getShare — verify stored fields
    SHARE_DATA=$(assert_rpc "getShare" "Sftp" "getShare" \
        "{\"uuid\":\"$SHARE_UUID\"}" "\"uuid\":\"$SHARE_UUID\"")

    STORED_SFREF=$(echo "$SHARE_DATA" | jq -r '.sharedfolderref // ""')
    [ "$STORED_SFREF" = "$SF_REF" ] \
        && _pass "getShare — sharedfolderref correct" \
        || _fail "getShare — sharedfolderref mismatch: $STORED_SFREF"

    STORED_USER=$(echo "$SHARE_DATA" | jq -r '.username // ""')
    [ "$STORED_USER" = "$TEST_USER" ] \
        && _pass "getShare — username correct" \
        || _fail "getShare — username mismatch: $STORED_USER"

    # getShareList — share present; sharedfoldername populated by RPC
    LIST_RESULT=$(assert_rpc "getShareList — share present" "Sftp" "getShareList" \
        "$LIST_PARAMS" "\"uuid\":\"$SHARE_UUID\"")

    SF_NAME_IN_LIST=$(echo "$LIST_RESULT" \
        | jq -r --arg u "$SHARE_UUID" '.data[] | select(.uuid == $u) | .sharedfoldername // ""')
    [ "$SF_NAME_IN_LIST" = "$SF_NAME" ] \
        && _pass "getShareList — sharedfoldername='$SF_NAME' populated" \
        || _fail "getShareList — sharedfoldername: '$SF_NAME_IN_LIST' (expected '$SF_NAME')"

    # setShare edit (existing UUID → update, should be idempotent here)
    assert_rpc "setShare (edit — idempotent)" "Sftp" "setShare" \
        "$(jq -n \
            --arg uuid "$SHARE_UUID" --arg sfref "$SF_REF" --arg user "$TEST_USER" \
            '{uuid:$uuid,sharedfolderref:$sfref,username:$user}')" \
        "\"uuid\":\"$SHARE_UUID\"" >/dev/null
fi

# ===========================================================================
section "Share — negative tests"
# ===========================================================================

assert_rpc_fails "getShare — unknown UUID" "Sftp" "getShare" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

assert_rpc_fails "deleteShare — unknown UUID" "Sftp" "deleteShare" \
    '{"uuid":"00000000-0000-0000-0000-000000000000"}'

assert_rpc_fails "setShare — unknown sharedfolderref" "Sftp" "setShare" \
    "$(jq -n \
        --arg uuid "$OMV_NEW_UUID" --arg user "$TEST_USER" \
        '{uuid:$uuid,sharedfolderref:"00000000-0000-0000-0000-000000000000",username:$user}')"

assert_rpc_fails "setShare — user without privileges" "Sftp" "setShare" \
    "$(jq -n \
        --arg uuid "$OMV_NEW_UUID" --arg sfref "$SF_REF" \
        '{uuid:$uuid,sharedfolderref:$sfref,username:"noprivuser_sftprpctest"}')"

# Duplicate user/shared-folder pair — a share for (TEST_USER, SF_REF) was
# created in the CRUD section above, so creating a second one must be rejected.
if [ -n "$SHARE_UUID" ]; then
    assert_rpc_fails "setShare — duplicate user/shared folder pair rejected" \
        "Sftp" "setShare" "$(jq -n \
            --arg uuid "$OMV_NEW_UUID" --arg sfref "$SF_REF" --arg user "$TEST_USER" \
            '{uuid:$uuid,sharedfolderref:$sfref,username:$user}')"
else
    info "Skipping duplicate-pair test — no test share was created"
fi

# ===========================================================================
section "Integration — deploy and bind mount"
# ===========================================================================

BIND_MNT="/sftp/${TEST_USER}/${SF_NAME}"

if [ -z "$SHARE_UUID" ]; then
    info "No test share — skipping deploy and bind-mount tests"
elif ! command -v omv-salt &>/dev/null; then
    info "omv-salt not available — skipping deploy and bind-mount tests"
else
    info "Running deploy: fstab sftp systemd ..."
    deploy_dirty

    if mountpoint -q "$BIND_MNT" 2>/dev/null; then
        _pass "bind mount created: $BIND_MNT"
    else
        _fail "bind mount not created at $BIND_MNT"
    fi

    # =======================================================================
    section "Regression — shared folder path change updates bind mount"
    # =======================================================================
    #
    # Reproduces the reported bug: when a shared folder's path is changed via
    # OMV's Shared Folders UI, re-deploying must update the bind mount to the
    # new path.  We do this with a real ShareMgmt::set call, read the dirty
    # modules from dirtymodules.json, deploy, verify the bind mount source
    # changed, then restore the original path.

    if mountpoint -q "$BIND_MNT" 2>/dev/null && command -v findmnt &>/dev/null; then
        ORIG_SRC=$(findmnt --output SOURCE --noheadings "$BIND_MNT" 2>/dev/null || echo "")
        info "Original bind mount source: $ORIG_SRC"

        # /proc/self/mountinfo has the bind mount's root-within-filesystem as
        # a well-defined field.  Find the primary mount for the same source
        # device (the one whose fsroot is /) to get the real directory where
        # we can create a new subdirectory for the test.
        # python3 is used here because /proc/self/mountinfo is not JSON.
        OMV_MNT_DIR=$(python3 -c "
import sys
bind_mnt = '$BIND_MNT'
mounts = {}
with open('/proc/self/mountinfo') as f:
    for line in f:
        parts = line.split()
        try:
            sep = parts.index('-')
            mounts[parts[4]] = {'root': parts[3], 'source': parts[sep + 2]}
        except (ValueError, IndexError):
            continue
if bind_mnt not in mounts:
    sys.exit(1)
bind_source = mounts[bind_mnt]['source']
# Prefer the shortest-path primary mount (fsroot == /) for this source
candidates = [mp for mp, info in mounts.items()
              if info['source'] == bind_source and info['root'] == '/']
if candidates:
    print(min(candidates, key=len))
    sys.exit(0)
sys.exit(1)
" 2>/dev/null || echo "")
        info "Filesystem mount point: $OMV_MNT_DIR"

        if [ -z "$OMV_MNT_DIR" ]; then
            _fail "path-change regression — could not resolve filesystem mount directory"
        else

        NEW_RELDIRPATH="sftprpctest_pathchange_$$"
        NEW_PATH_DIR="$OMV_MNT_DIR/$NEW_RELDIRPATH"
        mkdir -p "$NEW_PATH_DIR"
        _pass "new path directory created: $NEW_PATH_DIR"

        # Change the shared folder's path via ShareMgmt::set — this triggers
        # onSharedFolder in sftp.inc which marks sftp and fstab dirty
        SF_UPDATE=$(rpc "ShareMgmt" "set" "$(jq -n \
            --arg uuid       "$SF_REF"          \
            --arg name       "$SF_NAME"         \
            --arg mntentref  "$SF_MNTENTREF"    \
            --arg reldirpath "$NEW_RELDIRPATH"  \
            --arg comment    "$SF_COMMENT"      \
            --arg mode       "$SF_MODE"         \
            '{uuid:$uuid,name:$name,mntentref:$mntentref,
              reldirpath:$reldirpath,comment:$comment,mode:$mode}')" \
            2>&1) && SF_UPD_EC=0 || SF_UPD_EC=$?

        if [ $SF_UPD_EC -eq 0 ]; then
            _pass "ShareMgmt::set — shared folder path changed to '$NEW_RELDIRPATH'"
            SF_PATH_CHANGED=true
        else
            _fail "ShareMgmt::set — could not change shared folder path" \
                "${SF_UPDATE:0:200}"
        fi

        if $SF_PATH_CHANGED; then
            deploy_dirty

            NEW_SRC=$(findmnt --output SOURCE --noheadings "$BIND_MNT" 2>/dev/null || echo "")
            if [ "$NEW_SRC" != "$ORIG_SRC" ] && echo "$NEW_SRC" | grep -qF "$NEW_RELDIRPATH"; then
                _pass "path-change regression — bind mount source updated to new path"
                info "Old source: $ORIG_SRC"
                info "New source: $NEW_SRC"
            else
                _fail "path-change regression — bind mount source not updated" \
                    "old='$ORIG_SRC' new='$NEW_SRC'"
            fi

            # Restore the original shared folder path
            info "Restoring original shared folder path ($SF_RELDIRPATH) ..."
            rpc "ShareMgmt" "set" "$(jq -n \
                --arg uuid       "$SF_REF"       \
                --arg name       "$SF_NAME"      \
                --arg mntentref  "$SF_MNTENTREF" \
                --arg reldirpath "$SF_RELDIRPATH" \
                --arg comment    "$SF_COMMENT"   \
                --arg mode       "$SF_MODE"      \
                '{uuid:$uuid,name:$name,mntentref:$mntentref,
                  reldirpath:$reldirpath,comment:$comment,mode:$mode}')" \
                &>/dev/null || true
            SF_PATH_CHANGED=false

            deploy_dirty &>/dev/null || true
        fi

        rm -rf "$NEW_PATH_DIR" 2>/dev/null || true
        NEW_PATH_DIR=""
        fi  # [ -z "$OMV_MNT_DIR" ]
    else
        info "Skipping path-change regression — bind mount not active or findmnt unavailable"
    fi

    # =======================================================================
    section "Share — delete and verify cleanup"
    # =======================================================================

    assert_rpc "deleteShare" "Sftp" "deleteShare" \
        "{\"uuid\":\"$SHARE_UUID\"}" >/dev/null
    DELETED_UUID="$SHARE_UUID"
    SHARE_UUID=""

    if ! mountpoint -q "$BIND_MNT" 2>/dev/null; then
        _pass "bind mount removed after deleteShare"
    else
        _fail "bind mount still present after deleteShare: $BIND_MNT"
    fi

    assert_rpc_fails "getShare after deleteShare" "Sftp" "getShare" \
        "{\"uuid\":\"$DELETED_UUID\"}"

    LIST_AFTER=$(rpc "Sftp" "getShareList" "$LIST_PARAMS" 2>/dev/null \
        || echo '{"data":[]}')
    if echo "$LIST_AFTER" \
            | jq -e --arg u "$DELETED_UUID" '.data[] | select(.uuid == $u)' \
            &>/dev/null; then
        _fail "getShareList — deleted share still present"
    else
        _pass "getShareList — deleted share absent"
    fi
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

[ $FAIL -eq 0 ] && exit 0 || exit 1
