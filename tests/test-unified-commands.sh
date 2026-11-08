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
    [[ "$(main status "$gw")" == "gateway-status:$gw" ]] || fail "status gateway $gw"
    [[ "$(main remove "$gw")" == "gateway-remove:$gw" ]] || fail "remove gateway $gw"
    [[ "$(main remove "$gw" --local-only)" == "gateway-remove:$gw" ]] || fail "local-only remove $gw"
    if ( main start "$gw" --via host ) >/dev/null 2>&1; then fail 'gateway via override accepted'; fi
    if ( main start -i "$gw" ) >/dev/null 2>&1; then fail 'gateway ignore failure accepted'; fi
done
[[ "$(main start upstream-vpn)" == 'namespace-start:upstream-vpn|off|__default__' ]] || fail 'namespace start regressed'
[[ "$(main stop upstream-vpn)" == 'namespace-stop:upstream-vpn|remote' ]] || fail 'namespace stop regressed'
[[ "$(main stop upstream-vpn --local-only)" == 'namespace-stop:upstream-vpn|local-only' ]] || fail 'namespace stop local-only regressed'
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
printf 'Unified app lifecycle, gateway execution and export tests passed.\n'
