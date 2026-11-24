#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1
BASE_DIR="$TEST_TMP/apps"
GATEWAY_BASE_DIR="$TEST_TMP/gateways"
mkdir -p "$BASE_DIR/upstream-vpn" "$GATEWAY_BASE_DIR/office-server" "$GATEWAY_BASE_DIR/relay-gateway" "$GATEWAY_BASE_DIR/myawg"
touch "$BASE_DIR/upstream-vpn/upstream-vpn.cfg"
cat >"$GATEWAY_BASE_DIR/office-server/gateway.cfg" <<'CFG'
GATEWAY_NAME=office-server
VIA_APP=host
CFG
cat >"$GATEWAY_BASE_DIR/relay-gateway/gateway.cfg" <<'CFG'
GATEWAY_NAME=relay-gateway
VIA_APP=upstream-vpn
CFG
cat >"$GATEWAY_BASE_DIR/myawg/gateway.cfg" <<'CFG'
GATEWAY_NAME=myawg
VIA_APP=host
GATEWAY_BACKEND=amneziawg
CFG
source "$ROOT/src/10-config.sh"
source "$ROOT/src/60-gateway.sh"
source "$ROOT/src/70-run-status.sh"
source "$ROOT/src/90-main.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { :; }
reexec_as_root_if_needed() { :; }
start_app() { printf 'namespace-start:%s|%s|%s\n' "$@"; }
stop_app_cli() { printf 'namespace-stop:%s|%s\n' "$@"; }
status_app() { printf 'namespace-status:%s\n' "$1"; }
remove_app() { printf 'namespace-remove:%s:%s\n' "$1" "${2:-remote}"; }
gateway_start() { printf 'gateway-start:%s\n' "$1"; }
gateway_stop() { printf 'gateway-stop:%s\n' "$1"; }
gateway_status() { printf 'gateway-status:%s\n' "$1"; }
gateway_remove() { printf 'gateway-remove:%s\n' "$1"; }
server_export_ovpn() { printf 'gateway-export:%s|%s\n' "$1" "$2"; }
gateway_client_revoke() { printf 'gateway-revoke:%s|%s\n' "$1" "$2"; }
awg_server_client_revoke() { printf 'awg-revoke:%s|%s\n' "$1" "$2"; }
awg_server_client_export() { printf 'awg-export:%s|%s\n' "$1" "$2"; }

[[ "$(managed_app_kind upstream-vpn)" == namespace ]] || fail 'namespace classification'
[[ "$(managed_app_kind office-server)" == gateway ]] || fail 'host server classification'
[[ "$(managed_app_kind relay-gateway)" == gateway ]] || fail 'VPN-exit gateway classification'
[[ "$(managed_app_kind myawg)" == gateway ]] || fail 'AmneziaWG server classification'
if managed_gateway_exists '../etc'; then fail 'unsafe gateway lookup'; fi
for gw in office-server relay-gateway myawg; do
    [[ "$(main start "$gw")" == "gateway-start:$gw" ]] || fail "start gateway $gw"
    [[ "$(main stop "$gw")" == "gateway-stop:$gw" ]] || fail "stop gateway $gw"
    [[ "$(main stop "$gw" --local-only)" == "gateway-stop:$gw" ]] || fail "local-only stop $gw"
    [[ "$(main restart "$gw")" == $'gateway-stop:'"$gw"$'\ngateway-start:'"$gw" ]] || fail "restart gateway $gw"
    [[ "$(main status "$gw")" == "gateway-status:$gw" ]] || fail "status gateway $gw"
    [[ "$(main remove "$gw")" == "gateway-remove:$gw" ]] || fail "remove gateway $gw"
    [[ "$(main remove "$gw" --local-only)" == "gateway-remove:$gw" ]] || fail "local-only remove $gw"
    if ( main start "$gw" --via host ) >/dev/null 2>&1; then fail 'gateway via override accepted'; fi
    if ( main start -i "$gw" ) >/dev/null 2>&1; then fail 'gateway ignore failure accepted'; fi
done
[[ "$(main start upstream-vpn)" == 'namespace-start:upstream-vpn|off|__default__' ]] || fail 'namespace start regressed'
[[ "$(main stop upstream-vpn)" == 'namespace-stop:upstream-vpn|remote' ]] || fail 'namespace stop regressed'
[[ "$(main stop upstream-vpn --local-only)" == 'namespace-stop:upstream-vpn|local-only' ]] || fail 'namespace stop local-only regressed'
[[ "$(main restart upstream-vpn)" == $'namespace-stop:upstream-vpn|remote\nnamespace-start:upstream-vpn|off|__default__' ]] || fail 'namespace restart sequence regressed'
[[ "$(main restart -i upstream-vpn)" == $'namespace-stop:upstream-vpn|remote\nnamespace-start:upstream-vpn|on|__default__' ]] || fail 'namespace restart -i sequence regressed'
restart_all() { printf 'restart-all\n'; }
[[ "$(main restart)" == 'restart-all' ]] || fail 'bare restart did not dispatch to restart_all'
[[ "$(main status upstream-vpn)" == 'namespace-status:upstream-vpn' ]] || fail 'namespace status regressed'
[[ "$(main remove upstream-vpn)" == 'namespace-remove:upstream-vpn:remote' ]] || fail 'namespace remove regressed'
[[ "$(main export ovpn relay-gateway --client phone --full-tunnel)" == 'gateway-export:relay-gateway|phone' ]] || fail 'VPN-exit OpenVPN profile dispatch'
[[ "$(main revoke relay-gateway phone)" == 'gateway-revoke:relay-gateway|phone' ]] || fail 'VPN-exit revoke dispatch'
[[ "$(main export awg myawg --client phone)" == 'awg-export:myawg|phone' ]] || fail 'AWG export dispatch'
[[ "$(main revoke myawg phone)" == 'awg-revoke:myawg|phone' ]] || fail 'AWG revoke dispatch'
if ( main status missing-app ) >/dev/null 2>&1; then fail 'missing app accepted'; fi
if ( main run '../bad' ping 1.1.1.1 ) >/dev/null 2>&1; then fail 'unsafe app name'; fi

# Exercise real gateway run selection, with only the underlying execution
# swapped for markers (no host commands need run during this test).
load_gateway_cfg() { case "$1" in office-server|myawg) VIA_APP=host;; relay-gateway) VIA_APP=upstream-vpn;; *) return 1;; esac; }
systemctl() { [[ "${TEST_GATEWAY_STOPPED:-off}" != on ]] && [[ "$1" == is-active ]]; }
run_in_app() { printf 'namespace-run:%s:%s\n' "$1" "$2"; }
exec_run_as_user() { printf 'unprivileged-host:%s:%s:%s\n' "$1" "$2" "$3"; }
export SUDO_USER=alice
[[ "$(main run office-server ping ya.ru)" == 'unprivileged-host:office-server:alice:ping' ]] || fail 'host server run context'
[[ "$(main run myawg ping ya.ru)" == 'unprivileged-host:myawg:alice:ping' ]] || fail 'AWG server run context'
[[ "$(main run relay-gateway ping ya.ru)" == 'namespace-run:upstream-vpn:ping' ]] || fail 'upstream VPN exit context'
TEST_GATEWAY_STOPPED=on
if ( main run relay-gateway ping ya.ru ) >/dev/null 2>&1; then fail 'stopped gateway allowed run'; fi
if ( main run office-server ping ya.ru ) >/dev/null 2>&1; then fail 'stopped host server allowed run'; fi

# The real non-root helper must refuse root as the command identity.
(
    source "$ROOT/src/70-run-status.sh"
    if ( exec_run_as_user office-server root true ) >/dev/null 2>&1; then fail 'gateway command ran as root'; fi
)

# An impossible duplicate object should not silently pick one backend.
touch "$BASE_DIR/office-server/office-server.cfg" 2>/dev/null || { mkdir -p "$BASE_DIR/office-server"; touch "$BASE_DIR/office-server/office-server.cfg"; }
if ( managed_app_kind office-server ) >/dev/null 2>&1; then fail 'ambiguous duplicated managed app accepted'; fi

# The real non-root re-exec must canonicalize start/restart before sudo.
# A bare `restart` (no app name) must pass through unchanged to restart_all;
# the command name itself still counts in $# at this point, so it must not be
# handed to the start-option parser.
(
    source "$ROOT/src/10-config.sh"
    require_root() { :; }
    managed_gateway_exists() { return 1; }
    parse_start_cli() { echo called >"$TEST_TMP/parse-called"; }
    function /usr/bin/sudo { local IFS=' '; printf 'sudo:%s\n' "$*" >>"$TEST_TMP/sudo-calls"; return 0; }
    reexec_as_root_if_needed restart
)
[ ! -e "$TEST_TMP/parse-called" ] || fail 'bare restart re-parsed empty arguments'
grep -Fq -- "sudo:-n $ROOT/tests/test-unified-commands.sh restart" "$TEST_TMP/sudo-calls" ||
    fail "bare restart canonicalization wrong: $(cat "$TEST_TMP/sudo-calls")"
(
    source "$ROOT/src/10-config.sh"
    require_root() { :; }
    managed_gateway_exists() { return 1; }
    function /usr/bin/sudo { local IFS=' '; printf 'sudo:%s\n' "$*" >>"$TEST_TMP/sudo-calls"; return 0; }
    reexec_as_root_if_needed restart --via host -i upstream-vpn
)
grep -Fq -- "sudo:-n $ROOT/tests/test-unified-commands.sh restart -i upstream-vpn --via host" "$TEST_TMP/sudo-calls" ||
    fail "named restart canonicalization wrong: $(cat "$TEST_TMP/sudo-calls")"

# `restart` without a name must never double-restart gateways: a gateway whose
# upstream app recovers is brought back exactly once by the app's own start
# path, and the trailing explicit pass may only start gateways still inactive
# (host-exit gateways). The is-active guard is what prevents the second start.
(
    # Re-source the real restart_all: the file-level stub above is only for
    # the bare-restart dispatch check.
    source "$ROOT/src/90-main.sh"
    log() { :; }
    warn() { :; }
    : >"$TEST_TMP/ra.log"
    relay_active=1
    office_active=1
    app_is_started() { [[ "$1" == upstream-vpn ]]; }
    gateway_stop() {
        printf 'gateway-stop:%s\n' "$1" >>"$TEST_TMP/ra.log"
        case "$1" in
            office-server) office_active=0 ;;
            relay-gateway) relay_active=0 ;;
        esac
    }
    systemctl() {
        local IFS=' '
        case "$*" in
            "is-active --quiet nns-gateway@relay-gateway.service")
                [[ "$relay_active" == 1 ]] ;;
            "is-active --quiet nns-gateway@office-server.service")
                [[ "$office_active" == 1 ]] ;;
            "is-active --quiet nns-gateway@myawg.service")
                return 1 ;;
            "restart nns-gateway@relay-gateway.service")
                printf 'restart:%s\n' "$*" >>"$TEST_TMP/ra.log"
                relay_active=1
                return 0 ;;
            *)
                printf 'systemctl:%s\n' "$*" >>"$TEST_TMP/ra.log"
                return 0 ;;
        esac
    }
    start_app() {
        printf 'namespace-start:%s\n' "$1" >>"$TEST_TMP/ra.log"
        # Mirrors the real start_app success path: recover gateways via $1.
        restart_gateways_via_app "$1"
        return 0
    }
    gateway_start() { printf 'gateway-explicit:%s\n' "$1" >>"$TEST_TMP/ra.log"; }
    restart_all
)
[[ "$(grep -c '^restart:restart nns-gateway@relay-gateway.service$' "$TEST_TMP/ra.log")" == 1 ]] ||
    fail "app-dependent gateway restarted more than once: $(cat "$TEST_TMP/ra.log")"
grep -Fq 'gateway-explicit:office-server' "$TEST_TMP/ra.log" ||
    fail 'host-exit gateway was not started by the explicit pass'
grep -Fq 'gateway-explicit:relay-gateway' "$TEST_TMP/ra.log" &&
    fail 'app-dependent gateway was double-started by the explicit pass'
grep -Fq 'namespace-start:upstream-vpn' "$TEST_TMP/ra.log" ||
    fail 'active app was not restarted'

printf 'Unified app lifecycle, gateway execution and export tests passed.\n'
