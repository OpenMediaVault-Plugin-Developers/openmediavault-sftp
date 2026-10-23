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
# Further checks: a shared folder named 'dev' is rejected, a deploy does not
# remount unchanged bind mounts, renaming the shared folder (to a name with
# a space) removes the stale mount point, logging of chrooted sessions to the
# journal and the log viewer, disabling rsyslog, the generated sshd config
# and service unit, revoked/group/denied privileges, and omv-removesftpmount
# never deleting data.
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
# WARNING: This script transiently modifies SFTP settings (port, auth options,
# rsyslog, extra options) and the privileges of the shared folder, renames
# the shared folder, creates/deletes test SFTP shares, temporary groups and a
# temporary shared folder named 'dev', and writes probe messages tagged
# 'internal-sftp' to the journal.  Everything except the journal messages is
# restored on exit.  Run on a test system or during a maintenance window.

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

# Set the SFTP settings to the original ones, modified by a jq filter,
# e.g. set_settings '.rsyslog = false'.  set_settings '.' restores them.
set_settings() {
    SETTINGS_CHANGED=true
    rpc "Sftp" "setSettings" \
        "$(echo "$ORIG_SETTINGS" | jq "del(.shares) | $1")" >/dev/null
}

# Replace the privileges of the test shared folder with a JSON array.
set_privileges() {
    PRIVS_CHANGED=true
    rpc "ShareMgmt" "setPrivileges" "$(jq -n \
        --arg uuid "$SF_REF" --argjson privs "$1" \
        '{uuid:$uuid,privileges:$privs}')" >/dev/null
}

restore_privileges() {
    set_privileges "$ORIG_PRIVS" && PRIVS_CHANGED=false
}

# Create a group with the given members (JSON array) and remember it for
# the cleanup.
create_group() {
    rpc "UserMgmt" "setGroup" "$(jq -n --arg name "$1" --argjson members "$2" \
        '{name:$name,comment:"test-rpc.sh",members:$members}')" >/dev/null \
        || return 1
    TEST_GROUPS+=("$1")
}

# UserMgmt.deleteGroup runs 'delgroup --only-if-empty' and silently keeps
# a group that still has members, so remove the members first.
delete_groups() {
    local g
    for g in "${TEST_GROUPS[@]}"; do
        rpc "UserMgmt" "setGroup" "$(jq -n --arg name "$g" \
            '{name:$name,comment:"test-rpc.sh",members:[]}')" &>/dev/null || true
        rpc "UserMgmt" "deleteGroup" "{\"name\":\"$g\"}" &>/dev/null || true
        if getent group "$g" &>/dev/null; then
            info "Could not delete temporary group '$g' — remove it manually"
        fi
    done
    TEST_GROUPS=()
}

# Run setShare (edit) for the test share; succeeds if the RPC succeeds.
edit_share() {
    omv-rpc -u admin "Sftp" "setShare" "$(jq -n \
        --arg uuid "$SHARE_UUID" --arg sfref "$SF_REF" --arg user "$TEST_USER" \
        '{uuid:$uuid,sharedfolderref:$sfref,username:$user}')" &>/dev/null
}

# Print the mount ID / options of a mount point, empty if not mounted.
mount_id()   { findmnt -n -o ID --mountpoint "$1" 2>/dev/null | tail -1; }
mount_opts() { findmnt -n -o OPTIONS --mountpoint "$1" 2>/dev/null | tail -1; }

assert_mounted() {
    if mountpoint -q "$2" 2>/dev/null; then
        _pass "$1"
    else
        _fail "$1" "not mounted: $2"
    fi
}

assert_not_mounted() {
    if mountpoint -q "$2" 2>/dev/null; then
        _fail "$1" "still mounted: $2"
    elif [ -e "$2" ]; then
        _fail "$1" "mount point directory still present: $2"
    else
        _pass "$1"
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
ORIG_PRIVS=""
PRIVS_CHANGED=false
SETTINGS_CHANGED=false
declare -a TEST_GROUPS=()
DEV_SF_UUID=""
DEV_SF_PATH=""
REMOVE_TEST_DIR=""

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

    if [ -n "$REMOVE_TEST_DIR" ]; then
        info "Removing test directory $REMOVE_TEST_DIR"
        rm -rf "$REMOVE_TEST_DIR" 2>/dev/null || true
        REMOVE_TEST_DIR=""
    fi

    if [ -n "$DEV_SF_UUID" ]; then
        info "Deleting temporary shared folder 'dev'"
        rpc "ShareMgmt" "delete" "{\"uuid\":\"$DEV_SF_UUID\",\"recursive\":false}" \
            &>/dev/null || true
        [ -n "$DEV_SF_PATH" ] && rmdir "$DEV_SF_PATH" 2>/dev/null || true
        DEV_SF_UUID=""
    fi

    local redeploy=false
    if $PRIVS_CHANGED; then
        info "Restoring original shared folder privileges"
        restore_privileges &>/dev/null || true
        redeploy=true
    fi

    if [ ${#TEST_GROUPS[@]} -gt 0 ]; then
        info "Deleting temporary groups: ${TEST_GROUPS[*]}"
        delete_groups
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
        $SETTINGS_CHANGED && redeploy=true
    fi

    if $redeploy; then
        info "Redeploying the restored configuration"
        deploy_dirty &>/dev/null || true
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

# Remember the original privileges, the privilege tests replace them and
# they are restored from this on exit.
ORIG_PRIVS=$(echo "$SF_JSON" | jq -c '
    .privileges.privilege // []
    | if type == "object" then [.] else . end
    | map({type, name, perms: (.perms | tonumber)})' 2>/dev/null || echo "")

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
    # Only touch the privileges if they could be read back completely.
    if ! echo "$ORIG_PRIVS" | jq -e --arg u "$TEST_USER" \
            'any(.[]; .type == "user" and .name == $u)' &>/dev/null; then
        info "Could not read the original privileges — privilege tests will be skipped"
        ORIG_PRIVS=""
    fi
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

# A shared folder named 'dev' would be mounted onto the directory holding
# the rsyslog socket of the chroot, so it must be rejected.  Use an existing
# 'dev' shared folder or create a temporary one next to the test folder.
DEV_REF=$(rpc "ShareMgmt" "getList" "$LIST_PARAMS" 2>/dev/null \
    | jq -r '.data[] | select(.name == "dev") | .uuid' | head -1)
if [ -z "$DEV_REF" ]; then
    DEV_RESULT=$(rpc "ShareMgmt" "set" "$(jq -n \
        --arg uuid "$OMV_NEW_UUID" --arg mntentref "$SF_MNTENTREF" \
        --arg reldirpath "sftprpctest_dev_$$/" \
        '{uuid:$uuid,name:"dev",mntentref:$mntentref,reldirpath:$reldirpath,
          comment:"test-rpc.sh",mode:"775"}')" 2>&1) || DEV_RESULT=""
    DEV_SF_UUID=$(echo "$DEV_RESULT" | jq -r '.uuid // ""' 2>/dev/null || echo "")
    if [ -n "$DEV_SF_UUID" ]; then
        DEV_SF_PATH=$(rpc "ShareMgmt" "getPath" "{\"uuid\":\"$DEV_SF_UUID\"}" \
            2>/dev/null | jq -r '.' 2>/dev/null || echo "")
        DEV_REF="$DEV_SF_UUID"
    fi
fi
if [ -n "$DEV_REF" ]; then
    DEV_OUT=$(omv-rpc -u admin "Sftp" "setShare" "$(jq -n \
        --arg uuid "$OMV_NEW_UUID" --arg sfref "$DEV_REF" --arg user "$TEST_USER" \
        '{uuid:$uuid,sharedfolderref:$sfref,username:$user}')" 2>&1) \
        && DEV_EC=0 || DEV_EC=$?
    if [ $DEV_EC -ne 0 ] && echo "$DEV_OUT" | grep -q "named 'dev'"; then
        _pass "setShare — shared folder named 'dev' rejected"
    else
        _fail "setShare — shared folder named 'dev' rejected" "${DEV_OUT:0:200}"
        # Remove the share that should not have been created.
        DEV_SHARE=$(echo "$DEV_OUT" | jq -r '.uuid // ""' 2>/dev/null || echo "")
        [ -n "$DEV_SHARE" ] && rpc "Sftp" "deleteShare" \
            "{\"uuid\":\"$DEV_SHARE\"}" &>/dev/null || true
    fi
    if [ -n "$DEV_SF_UUID" ]; then
        rpc "ShareMgmt" "delete" "{\"uuid\":\"$DEV_SF_UUID\",\"recursive\":false}" \
            &>/dev/null || true
        [ -n "$DEV_SF_PATH" ] && rmdir "$DEV_SF_PATH" 2>/dev/null || true
        DEV_SF_UUID=""
        DEV_SF_PATH=""
    fi
else
    _fail "setShare — shared folder named 'dev' rejected" \
        "could not create a temporary shared folder named 'dev'"
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
    section "Regression — deploy does not remount an unchanged bind mount"
    # =======================================================================
    #
    # A bind mount shows up as '<device>[<subdir>]' in findmnt, so comparing
    # its SOURCE with the shared folder path always differed and every deploy
    # unmounted and remounted it, breaking active sessions.

    if mountpoint -q "$BIND_MNT" 2>/dev/null; then
        ID_BEFORE=$(mount_id "$BIND_MNT")
        deploy_dirty
        ID_AFTER=$(mount_id "$BIND_MNT")
        if [ -n "$ID_BEFORE" ] && [ "$ID_BEFORE" = "$ID_AFTER" ]; then
            _pass "bind mount kept across deploy (mount ID $ID_BEFORE)"
        else
            _fail "bind mount was remounted by deploy" \
                "mount ID before='$ID_BEFORE' after='$ID_AFTER'"
        fi
    else
        info "Skipping remount regression — bind mount not active"
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
    section "Regression — shared folder rename removes stale bind mount"
    # =======================================================================
    #
    # Renaming the shared folder changes the mount point below /sftp. The
    # mount point with the old name must be unmounted and removed, otherwise
    # the user keeps access through it until the next reboot.  The new name
    # contains a space, which must be escaped as \040 in /etc/fstab only.

    if mountpoint -q "$BIND_MNT" 2>/dev/null; then
        NEW_SF_NAME="${SF_NAME} sftprpctest $$"
        NEW_BIND_MNT="/sftp/${TEST_USER}/${NEW_SF_NAME}"
        SF_RENAME=$(rpc "ShareMgmt" "set" "$(jq -n \
            --arg uuid       "$SF_REF"          \
            --arg name       "$NEW_SF_NAME"     \
            --arg mntentref  "$SF_MNTENTREF"    \
            --arg reldirpath "$SF_RELDIRPATH"   \
            --arg comment    "$SF_COMMENT"      \
            --arg mode       "$SF_MODE"         \
            '{uuid:$uuid,name:$name,mntentref:$mntentref,
              reldirpath:$reldirpath,comment:$comment,mode:$mode}')" \
            2>&1) && SF_REN_EC=0 || SF_REN_EC=$?

        if [ $SF_REN_EC -ne 0 ]; then
            info "Skipping rename regression — shared folder could not be renamed: ${SF_RENAME:0:200}"
        else
            # Let the cleanup handler restore the original name on failure.
            SF_PATH_CHANGED=true
            deploy_dirty

            if mountpoint -q "$NEW_BIND_MNT" 2>/dev/null; then
                _pass "rename regression — bind mount created: $NEW_BIND_MNT"
            else
                _fail "rename regression — bind mount not created at $NEW_BIND_MNT"
            fi
            if mountpoint -q "$BIND_MNT" 2>/dev/null || [ -e "$BIND_MNT" ]; then
                _fail "rename regression — stale mount point still present: $BIND_MNT"
            else
                _pass "rename regression — stale mount point removed"
            fi

            FSTAB_TARGET=$(printf '%s' "$NEW_BIND_MNT" | sed 's/ /\\040/g')
            # ENVIRON, unlike 'awk -v', does not process backslash escapes.
            FSTAB_COUNT=$(T="$FSTAB_TARGET" awk '$2 == ENVIRON["T"]' /etc/fstab | wc -l)
            if [ "$FSTAB_COUNT" -eq 1 ]; then
                _pass "space in name — exactly one fstab entry with \\040"
            else
                _fail "space in name — expected one fstab entry for '$FSTAB_TARGET'" \
                    "found $FSTAB_COUNT"
            fi
            if find "/sftp/${TEST_USER}" -mindepth 1 -maxdepth 1 \
                    -name '*\\040*' 2>/dev/null | grep -q .; then
                _fail "space in name — directory with a literal '\\040' created"
            else
                _pass "space in name — no directory with a literal '\\040'"
            fi

            info "Restoring original shared folder name ($SF_NAME) ..."
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

            if [ -e "$NEW_BIND_MNT" ]; then
                _fail "rename regression — renamed mount point not removed after restore: $NEW_BIND_MNT"
            else
                _pass "rename regression — renamed mount point removed after restore"
            fi
        fi
    else
        info "Skipping rename regression — bind mount not active"
    fi

    # =======================================================================
    section "Logging — chrooted sessions are logged to the journal"
    # =======================================================================
    #
    # rsyslog creates a socket inside every chroot and passes the messages
    # on to the journal; the 'sftp' log viewer reads them from there.

    LOG_SOCK="/sftp/${TEST_USER}/dev/log"
    RSYSLOG_CONF="/etc/rsyslog.d/openmediavault-sftp.conf"
    set_settings '.rsyslog = true'
    deploy_dirty

    if [ -S "$LOG_SOCK" ]; then
        _pass "rsyslog socket created: $LOG_SOCK"
    else
        _fail "rsyslog socket not created: $LOG_SOCK"
    fi
    if grep -q 'Ruleset="omv_sftp"' "$RSYSLOG_CONF" 2>/dev/null \
            && grep -q 'type="omjournal"' "$RSYSLOG_CONF" 2>/dev/null; then
        _pass "rsyslog config passes the messages on to the journal"
    else
        _fail "rsyslog config does not pass the messages on to the journal"
    fi

    if [ -S "$LOG_SOCK" ]; then
        # Log like internal-sftp does, with a known PID and a unique message.
        PROBE="test-rpc.sh probe $$-$RANDOM"
        logger -u "$LOG_SOCK" -t internal-sftp --id=$$ -p authpriv.info "$PROBE"
        PROBE_JSON=""
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            PROBE_JSON=$(journalctl --quiet --no-pager --output=json \
                --identifier=internal-sftp --since=-10min 2>/dev/null \
                | jq -c --arg m "$PROBE" 'select(.MESSAGE == $m)' | tail -1)
            [ -n "$PROBE_JSON" ] && break
            sleep 1
        done
        if [ -n "$PROBE_JSON" ]; then
            _pass "message from the chroot socket arrived in the journal"
            [ "$(echo "$PROBE_JSON" | jq -r '.SYSLOG_PID // ""')" = "$$" ] \
                && _pass "journal entry has the session PID ($$)" \
                || _fail "journal entry has the wrong PID" \
                    "$(echo "$PROBE_JSON" | jq -c '{SYSLOG_PID,_PID}')"
            [ "$(echo "$PROBE_JSON" | jq -r '.SYSLOG_FACILITY // ""')" = "10" ] \
                && _pass "journal entry has the authpriv facility" \
                || _fail "journal entry has the wrong facility" \
                    "$(echo "$PROBE_JSON" | jq -c '{SYSLOG_FACILITY}')"
        else
            _fail "message from the chroot socket not found in the journal"
        fi

        LOG_LIST=$(rpc "LogFile" "getList" \
            '{"start":0,"limit":null,"sortfield":null,"sortdir":null,"id":"sftp"}' \
            2>&1) || LOG_LIST=""
        if echo "$LOG_LIST" | jq -e --arg m "$PROBE" --arg p "[$$]:" \
                'any(.data[]; (.message | contains($m)) and (.message | contains($p)))' \
                &>/dev/null; then
            _pass "log viewer (LogFile getList sftp) shows the message with the session PID"
        else
            _fail "log viewer (LogFile getList sftp) does not show the message" \
                "${LOG_LIST:0:200}"
        fi
    fi

    # =======================================================================
    section "Logging — disabling rsyslog removes the sockets"
    # =======================================================================

    set_settings '.rsyslog = false'
    deploy_dirty

    if [ -e "$RSYSLOG_CONF" ]; then
        _fail "rsyslog config still present: $RSYSLOG_CONF"
    else
        _pass "rsyslog config removed"
    fi
    if [ -e "$LOG_SOCK" ] || [ -e "/sftp/${TEST_USER}/dev" ]; then
        _fail "rsyslog socket or dev directory still present below /sftp/${TEST_USER}"
    else
        _pass "rsyslog socket and dev directory removed"
    fi
    assert_mounted "bind mount kept when disabling rsyslog" "$BIND_MNT"

    # =======================================================================
    section "sshd configuration and service unit"
    # =======================================================================

    SSHD_CONF="/etc/ssh/omv_sftp_config"
    set_settings '.extraoptions = "MaxSessions 7" | .allowgroups = true'
    deploy_dirty

    if /usr/sbin/sshd -t -f "$SSHD_CONF" &>/dev/null; then
        _pass "sshd -t accepts $SSHD_CONF"
    else
        _fail "sshd -t rejects $SSHD_CONF" \
            "$(/usr/sbin/sshd -t -f "$SSHD_CONF" 2>&1 | head -3)"
    fi
    if grep -qE '^[[:space:]]*(Protocol|ChallengeResponseAuthentication)[[:space:]]' "$SSHD_CONF" \
            || grep -q 'ssh_host_dsa_key' "$SSHD_CONF"; then
        _fail "obsolete options (Protocol, ChallengeResponseAuthentication, DSA key) present"
    else
        _pass "no obsolete options (Protocol, ChallengeResponseAuthentication, DSA key)"
    fi
    grep -q '^KbdInteractiveAuthentication ' "$SSHD_CONF" \
        && _pass "KbdInteractiveAuthentication set" \
        || _fail "KbdInteractiveAuthentication missing"

    LINE_ALLOW=$(grep -n '^AllowGroups ' "$SSHD_CONF" | head -1 | cut -d: -f1)
    LINE_EXTRA=$(grep -n '^MaxSessions 7$' "$SSHD_CONF" | head -1 | cut -d: -f1)
    LINE_MATCH=$(grep -n '^Match Group ' "$SSHD_CONF" | head -1 | cut -d: -f1)
    if [ -n "$LINE_ALLOW" ] && [ -n "$LINE_EXTRA" ] && [ -n "$LINE_MATCH" ] \
            && [ "$LINE_ALLOW" -lt "$LINE_EXTRA" ] && [ "$LINE_EXTRA" -lt "$LINE_MATCH" ]; then
        _pass "order: AllowGroups, extra options, Match block"
    else
        _fail "wrong order of AllowGroups/extra options/Match" \
            "AllowGroups=$LINE_ALLOW extra=$LINE_EXTRA Match=$LINE_MATCH"
    fi

    systemctl show omv-sftp -p RuntimeDirectory --value 2>/dev/null | grep -qw sshd \
        && _pass "omv-sftp.service creates /run/sshd" \
        || _fail "omv-sftp.service does not set RuntimeDirectory=sshd"
    systemctl show omv-sftp -p ExecStartPre --value 2>/dev/null | grep -q 'sshd.* -t ' \
        && _pass "omv-sftp.service checks the config before starting" \
        || _fail "omv-sftp.service has no 'sshd -t' ExecStartPre"

    set_settings '.'
    deploy_dirty &>/dev/null || true

    # =======================================================================
    section "Privileges — revoked, group, denied"
    # =======================================================================
    #
    # The effective privileges follow the SMB rules: 'No access' for the
    # user or one of its groups wins, then read/write, then read only.
    # Entries are matched by type, a group named like the user does not
    # grant the user anything.

    if [ -z "$ORIG_PRIVS" ]; then
        info "Skipping privilege tests — original privileges unknown"
    elif ! mountpoint -q "$BIND_MNT" 2>/dev/null; then
        info "Skipping privilege tests — bind mount not active"
    else
        # Revoked: the mount point must go away, and come back on restore.
        set_privileges "$(jq -nc --arg u "$TEST_USER" \
            '[{type:"user",name:$u,perms:0}]')"
        deploy_dirty
        assert_not_mounted "revoked — bind mount and directory removed" "$BIND_MNT"
        edit_share \
            && _fail "revoked — setShare accepted a user without privileges" \
            || _pass "revoked — setShare rejects the user"

        restore_privileges
        deploy_dirty
        assert_mounted "revoked — bind mount restored with the privileges" "$BIND_MNT"

        TEST_GROUP="sftprpct$$"
        if create_group "$TEST_GROUP" "$(jq -nc --arg u "$TEST_USER" '[$u]')" \
                && id -nG "$TEST_USER" | tr ' ' '\n' | grep -qx "$TEST_GROUP"; then
            _pass "temporary group '$TEST_GROUP' with member '$TEST_USER' created"

            # Read/write through a group only.
            set_privileges "$(jq -nc --arg g "$TEST_GROUP" \
                '[{type:"group",name:$g,perms:7}]')"
            edit_share \
                && _pass "group rw — setShare accepts access through a group" \
                || _fail "group rw — setShare rejects access through a group"
            deploy_dirty
            assert_mounted "group rw — bind mount present" "$BIND_MNT"
            mount_opts "$BIND_MNT" | grep -q '^rw' \
                && _pass "group rw — mounted read/write" \
                || _fail "group rw — not mounted read/write" "$(mount_opts "$BIND_MNT")"

            # Read only through a group.
            set_privileges "$(jq -nc --arg g "$TEST_GROUP" \
                '[{type:"group",name:$g,perms:5}]')"
            deploy_dirty
            mount_opts "$BIND_MNT" | grep -q '^ro' \
                && _pass "group ro — mounted read only" \
                || _fail "group ro — not mounted read only" "$(mount_opts "$BIND_MNT")"

            # 'No access' for a group wins over read/write for the user.
            set_privileges "$(jq -nc --arg u "$TEST_USER" --arg g "$TEST_GROUP" \
                '[{type:"user",name:$u,perms:7},{type:"group",name:$g,perms:0}]')"
            edit_share \
                && _fail "deny wins — setShare accepted a user denied through a group" \
                || _pass "deny wins — setShare rejects a user denied through a group"
            deploy_dirty
            assert_not_mounted "deny wins — bind mount removed" "$BIND_MNT"
        else
            _fail "could not create temporary group '$TEST_GROUP' with member '$TEST_USER'"
        fi

        # A group with the same name as the user, which the user is not a
        # member of, must not be mistaken for the user's own entry.
        if getent group "$TEST_USER" &>/dev/null; then
            info "Skipping type-match test — a group named '$TEST_USER' already exists"
        elif create_group "$TEST_USER" '[]'; then
            set_privileges "$(jq -nc --arg u "$TEST_USER" \
                '[{type:"group",name:$u,perms:7}]')"
            edit_share \
                && _fail "type match — group named like the user granted access" \
                || _pass "type match — group named like the user grants no access"
            deploy_dirty
            assert_not_mounted "type match — no bind mount" "$BIND_MNT"
        else
            info "Skipping type-match test — could not create a group named '$TEST_USER'"
        fi

        restore_privileges
        delete_groups
        deploy_dirty
        assert_mounted "privileges restored — bind mount present" "$BIND_MNT"
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

    if [ ! -e "$BIND_MNT" ]; then
        _pass "mount point directory removed after deleteShare"
    else
        _fail "mount point directory still present after deleteShare: $BIND_MNT"
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
section "omv-removesftpmount never deletes data"
# ===========================================================================

if ! command -v omv-removesftpmount &>/dev/null; then
    info "omv-removesftpmount not installed — skipping"
else
    RM_DIR="/sftp/sftprpctest_$$"
    REMOVE_TEST_DIR="$RM_DIR"
    mkdir -p "$RM_DIR/full" "$RM_DIR/empty"
    echo "user data" > "$RM_DIR/full/file"

    if omv-removesftpmount "$RM_DIR/full" &>/dev/null; then
        _fail "non-empty directory — reported success"
    else
        _pass "non-empty directory — refused"
    fi
    [ -f "$RM_DIR/full/file" ] \
        && _pass "non-empty directory — content kept" \
        || _fail "non-empty directory — content deleted"

    omv-removesftpmount "$RM_DIR/empty" &>/dev/null \
        && [ ! -e "$RM_DIR/empty" ] \
        && _pass "empty directory — removed" \
        || _fail "empty directory — not removed"

    # Paths outside of /sftp are ignored.
    OUTSIDE_DIR=$(mktemp -d)
    omv-removesftpmount "$OUTSIDE_DIR" &>/dev/null || true
    [ -d "$OUTSIDE_DIR" ] \
        && _pass "path outside of /sftp — ignored" \
        || _fail "path outside of /sftp — removed"
    rmdir "$OUTSIDE_DIR" 2>/dev/null || true

    rm -rf "$RM_DIR"
    REMOVE_TEST_DIR=""
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
