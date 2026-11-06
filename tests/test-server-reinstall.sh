#!/usr/bin/env bash
# Deterministic, unprivileged tests for port arbitration and in-place upgrades.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
BASE_DIR="$TEST_TMP/apps"
GATEWAY_BASE_DIR="$TEST_TMP/gateways"
GATEWAY_RUN_BASE="$TEST_TMP/run"
mkdir -p "$BASE_DIR" "$GATEWAY_BASE_DIR" "$GATEWAY_RUN_BASE"
source "$ROOT/src/60-gateway.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { :; }
warn() { :; }
require_root() { :; }
validate_app_name() { :; }
cfg_file() { printf '%s/%s/app.cfg\n' "$BASE_DIR" "$1"; }
acquire_lock() { :; }
release_lock() { :; }
ensure_dependencies() { :; }
install_engine_files() { :; }
write_gateway_unit_dropin() { :; }
reset_gateway_cfg_vars() { :; }
load_gateway_cfg() { source "$(gateway_cfg_file "$1")"; }
# The tests must not require root ownership for gateway_cfg_set.
install() {
    local -a params=()
    while (( $# )); do
        case "$1" in
            -o|-g) shift 2 ;;
            *) params+=("$1"); shift ;;
        esac
    done
    command install "${params[@]}"
}
SERVER_ACTIVE=off
FAIL_NEW_PORT=''
EVENTS="$TEST_TMP/events"
systemctl() {
    if [[ "$1" == is-active ]]; then
        [[ "$SERVER_ACTIVE" == on ]]
        return
    fi
    return 0
}
ss() {
    [[ "$1" == -H ]] || fail 'wrong ss arguments'
    # A separate unmanaged host process has the optional 1197 port.
    [[ "$2" == -lun ]] && printf 'UNCONN 0 0 0.0.0.0:1197 0.0.0.0:*\n'
    return 0
}
gateway_stop() {
    load_gateway_cfg "$1"
    printf 'stop:%s\n' "$LISTEN_PORT" >>"$EVENTS"
}
gateway_start() {
    load_gateway_cfg "$1"
    printf 'start:%s\n' "$LISTEN_PORT" >>"$EVENTS"
    printf 'port %s\n' "$LISTEN_PORT" >"$(gateway_server_config "$1")"
    [[ "$LISTEN_PORT" != "$FAIL_NEW_PORT" ]]
}
server_public_host() { printf '198.51.100.40\n'; }
allocate_gateway_networks() { printf '%s|10.239.2.0/30|10.239.2.1/30|10.239.2.2/30\n' "$1"; }

mkdir -p "$GATEWAY_BASE_DIR/mlvpn" "$GATEWAY_BASE_DIR/myvpn/clients/ml" "$GATEWAY_BASE_DIR/myvpn/pki"
cat >"$GATEWAY_BASE_DIR/mlvpn/gateway.cfg" <<'CFG'
GATEWAY_NAME=mlvpn
VIA_APP=host
TRANSPORT=direct
LISTEN_PROTO=udp
LISTEN_PORT=1194
OPENVPN_LISTEN_PROTO=udp
OPENVPN_LISTEN_PORT=1194
CFG
cat >"$GATEWAY_BASE_DIR/myvpn/gateway.cfg" <<'CFG'
GATEWAY_NAME=myvpn
VIA_APP=host
TRANSPORT=direct
LISTEN_PROTO=udp
LISTEN_PORT=1194
OPENVPN_LISTEN_PROTO=udp
OPENVPN_LISTEN_PORT=1194
PUBLIC_HOST=198.51.100.40
PUBLIC_PORT=1194
CLIENT_POOL=10.253.1.0/24
DNS_SERVERS='1.1.1.1 9.9.9.9'
CLIENT_TO_CLIENT=on
CFG
printf 'test-client-private-key' >"$GATEWAY_BASE_DIR/myvpn/clients/ml/client.key"
printf 'test-ca' >"$GATEWAY_BASE_DIR/myvpn/pki/ca.crt"
printf 'original server config' >"$GATEWAY_BASE_DIR/myvpn/server.conf"

[[ "$(server_choose_listener newserver)" == udp:1195 ]] || fail 'second server did not auto-select 1195'
reason=$(server_listener_conflict udp 1194 myvpn) || fail 'missed other managed gateway reservation'
grep -Fq mlvpn <<<"$reason" || fail 'port conflict did not identify owning gateway'
reason=$(server_listener_conflict udp 1197 myvpn) || fail 'missed unmanaged host UDP listener'
grep -Fq 'host process' <<<"$reason" || fail 'wrong unmanaged-port explanation'
if ( install_openvpn_server myvpn udp:1194 ) >/dev/null 2>&1; then
    fail 'busy explicitly requested port was accepted'
fi

# The previously installed, STOPPED myvpn should be repaired in place,
# acquiring 1195 with the old CA and clients untouched.
install_openvpn_server myvpn >/dev/null
[[ "$(gateway_cfg_value myvpn LISTEN_PORT)" == 1195 ]] || fail 'reinstall did not repair busy listener'
[[ "$(gateway_cfg_value myvpn PUBLIC_PORT)" == 1195 ]] || fail 'reinstall did not update default public port'
[[ "$(gateway_cfg_value myvpn CLIENT_TO_CLIENT)" == on ]] || fail 'reinstall dropped client-to-client'
grep -Fq 'start:1195' "$EVENTS" || fail 'reinstall did not start on new port'
[[ "$(cat "$GATEWAY_BASE_DIR/myvpn/clients/ml/client.key")" == test-client-private-key ]] || fail 'reinstall deleted client private key'
[[ "$(cat "$GATEWAY_BASE_DIR/myvpn/pki/ca.crt")" == test-ca ]] || fail 'reinstall replaced CA'
[[ "$(gateway_cfg_value mlvpn LISTEN_PORT)" == 1194 ]] || fail 'reinstall modified other server'

# Explicit reconfiguration of listener, DNS, pool and c2c while preserving PKI.
install_openvpn_server myvpn udp:1196 '' 10.253.52.0/24 '9.9.9.9' off >/dev/null
[[ "$(gateway_cfg_value myvpn LISTEN_PORT)" == 1196 ]] || fail 'explicit listener change failed'
[[ "$(gateway_cfg_value myvpn CLIENT_POOL)" == 10.253.52.0/24 ]] || fail 'pool change failed'
[[ "$(gateway_cfg_value myvpn DNS_SERVERS)" == 9.9.9.9 ]] || fail 'DNS change failed'
[[ "$(gateway_cfg_value myvpn CLIENT_TO_CLIENT)" == off ]] || fail 'c2c change failed'

# Failed update must roll back all config keys, generated server.conf,
# preserve issued identities, and try to restart the old active instance.
SERVER_ACTIVE=on
FAIL_NEW_PORT=1198
if ( install_openvpn_server myvpn udp:1198 ) >/dev/null 2>&1; then
    fail 'simulated failed server start incorrectly succeeded'
fi
[[ "$(gateway_cfg_value myvpn LISTEN_PORT)" == 1196 ]] || fail 'failed install did not restore listener'
[[ "$(gateway_cfg_value myvpn PUBLIC_PORT)" == 1196 ]] || fail 'failed install did not restore public endpoint'
[[ "$(cat "$GATEWAY_BASE_DIR/myvpn/server.conf")" == 'port 1196' ]] || fail 'failed install did not restore config'
[[ "$(cat "$GATEWAY_BASE_DIR/myvpn/clients/ml/client.key")" == test-client-private-key ]] || fail 'failed install lost client cert'
grep -Fq 'start:1198' "$EVENTS" || fail 'failure path was not exercised'
[[ "$(grep -c '^start:1196$' "$EVENTS")" -ge 2 ]] || fail 'failed install did not restart previous listener'
printf 'OpenVPN server reinstall tests passed.\n'
