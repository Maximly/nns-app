#!/usr/bin/env bash
# Prevent remote-auto from replacing a newer remote engine managing servers.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
source "$ROOT/src/20-install.sh"
source "$ROOT/src/65-link-remote.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { :; }
warn() { :; }
require_root() { :; }
acquire_lock() { printf 'lock\n' >>"$TEST_TMP/actions"; }
release_lock() { :; }
ensure_dependencies() { printf 'dependencies\n' >>"$TEST_TMP/actions"; }
install_engine_files() { printf 'overwrite\n' >>"$TEST_TMP/actions"; }
refresh_managed_unit_metadata() { printf 'regenerate\n' >>"$TEST_TMP/actions"; }
remote_auto_refresh_configured_nodes() { :; }
ENGINE_PATH="$TEST_TMP/nns_app.sh"
USER_PATH="$TEST_TMP/nns-app"
BASE_DIR="$TEST_TMP/apps"
RUN_DIR="$TEST_TMP/run"
CACHE_DIR="$TEST_TMP/cache"
STATE_DIR="$TEST_TMP/state"
GATEWAY_BASE_DIR="$TEST_TMP/gateways"
GATEWAY_RUN_BASE="$TEST_TMP/gateways-run"
REMOTE_BASE_DIR="$TEST_TMP/remotes"
LOCK_DIR="$TEST_TMP/locks"
install() {
    local -a kept=()
    while (( $# )); do
        case "$1" in -o|-g) shift 2 ;; *) kept+=("$1"); shift ;; esac
    done
    command install "${kept[@]}"
}
VERSION=2.0.8
cat >"$ENGINE_PATH" <<'SH'
#!/bin/sh
printf 'nns-app %s\n' "${TEST_INSTALLED_VERSION:-2.0.9}"
printf 'Author: test\n'
SH
chmod +x "$ENGINE_PATH"
: >"$TEST_TMP/actions"
export TEST_INSTALLED_VERSION=2.0.9
[[ "$(nns_engine_version_from_output $'nns-app 2.0\nAuthor: Test')" == 2.0 ]] || fail 'two-component release version not parsed'
[[ "$(nns_engine_version_from_output $'nns-app 1.3.48\nAuthor: Test')" == 1.3.48 ]] || fail 'legacy three-component version not parsed'
nns_version_is_newer 2.0 1.3.48 || fail 'major upgrade comparison failed'
nns_version_is_newer 2.0.1 2.0 || fail 'patch upgrade comparison failed'
nns_version_is_newer 2.0.9 2.0.8 || fail 'next patch comparison failed'
if nns_version_is_newer 1.3.48 2.0.2; then fail 'legacy version considered newer than 2.0.1'; fi
if ( install_engine off ) >"$TEST_TMP/downgrade-log" 2>&1; then
    fail 'downgrade was accepted'
fi
grep -Fq 'Refusing nns-app downgrade 2.0.9 -> 2.0.8' "$TEST_TMP/downgrade-log" || fail 'missing downgrade explanation'
! grep -Eq '^(dependencies|overwrite|regenerate)$' "$TEST_TMP/actions" || fail 'downgrade ran side-effecting operations'

# Equal and older engines may be installed and refreshed.
for previous in 2.0.8 2.0.7 2.0.6 2.0.5 2.0.4 2.0.3 2.0.2 2.0.1 2.0 1.3.48; do
    export TEST_INSTALLED_VERSION="$previous"
    : >"$TEST_TMP/actions"
    ( install_engine off ) >"$TEST_TMP/upgrade-log" 2>&1 || { cat "$TEST_TMP/upgrade-log" >&2; fail "upgrade from $previous rejected"; }
    grep -Fq 'overwrite' "$TEST_TMP/actions" || fail 'upgrade did not update engine'
done

# Reject unparseable preexisting engine instead of overwriting it.
cat >"$ENGINE_PATH" <<'SH2'
#!/bin/sh
printf 'unknown version\n'
SH2
chmod +x "$ENGINE_PATH"
: >"$TEST_TMP/actions"
if ( install_engine off ) >"$TEST_TMP/unknown-log" 2>&1; then
    fail 'unparseable preexisting engine accepted'
fi
! grep -Eq '^(dependencies|overwrite|regenerate)$' "$TEST_TMP/actions" || fail 'unparseable engine ran side effects'

# Remote auto preflight is read-only, rejects newer destination versions,
# allows an absent/equal/older engine and never copies anything itself.
remote_auto_user_exec() {
    [[ "$2" == ssh ]] || fail 'remote guard did not use ssh'
    case "$TEST_REMOTE_VERSION" in
        absent) printf 'nns-app-absent\n' ;;
        unknown) printf 'bad-version\n' ;;
        *) printf 'nns-app %s\nAuthor: Test\n' "$TEST_REMOTE_VERSION" ;;
    esac
}
for previous in absent 1.3.48 2.0 2.0.1 2.0.2 2.0.3 2.0.4 2.0.5 2.0.6 2.0.7 2.0.8; do
    TEST_REMOTE_VERSION="$previous"
    ( remote_auto_guard_remote_engine alice alice@example.org 2222 /tmp/ctl ) >/dev/null 2>&1 ||
        fail "remote preflight rejected $previous"
done
TEST_REMOTE_VERSION=2.0.9
if ( remote_auto_guard_remote_engine alice alice@example.org 2222 /tmp/ctl ) >"$TEST_TMP/remote-log" 2>&1; then
    fail 'remote preflight accepted newer engine'
fi
grep -Fq 'Upgrade nns-app on this initiating host' "$TEST_TMP/remote-log" ||
    fail 'remote preflight did not explain next step'
TEST_REMOTE_VERSION=unknown
if ( remote_auto_guard_remote_engine alice alice@example.org 2222 /tmp/ctl ) >/dev/null 2>&1; then
    fail 'remote preflight accepted unknown version'
fi
printf 'Remote-bootstrap downgrade regression tests passed.\n'

