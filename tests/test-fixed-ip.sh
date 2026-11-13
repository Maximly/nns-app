#!/usr/bin/env bash
# Unprivileged regression tests for server-only OpenVPN fixed client IPs.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TEST_TMP/locks"
# shellcheck source=/dev/null
source "$ROOT/install_linux"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
require_root() { :; }
acquire_lock() { :; }
release_lock() { :; }
nns_unprivileged_group() { printf 'nogroup\n'; }
nns_unprivileged_user() { printf 'nobody\n'; }
gateway_dir() { printf '%s/gateways/%s\n' "$TEST_TMP" "$1"; }
gateway_cfg_file() { printf '%s/gateways/%s/gateway.cfg\n' "$TEST_TMP" "$1"; }
gateway_clients_dir() { printf '%s/gateways/%s/clients\n' "$TEST_TMP" "$1"; }
gateway_client_dir() { printf '%s/gateways/%s/clients/%s\n' "$TEST_TMP" "$1" "$2"; }
gateway_server_config() { printf '%s/gateways/%s/server.conf\n' "$TEST_TMP" "$1"; }
gateway_pki_dir() { printf '%s/gateways/%s/pki\n' "$TEST_TMP" "$1"; }
load_gateway_cfg() { reset_gateway_cfg_vars; source "$(gateway_cfg_file "$1")"; }
gateway_client_load() {
    reset_gateway_client_vars
    # shellcheck disable=SC1090
    source "$(gateway_client_dir "$1" "$2")/client.cfg"
}
# Tests run as an unprivileged account. Omit only chown, group selection.
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
chown() { :; }
ACTIVE=off
RESTART_FAIL_ONCE=off
RESTARTS=0
systemctl() {
    case "$1" in
        is-active) [[ "$ACTIVE" == on ]] ;;
        restart)
            RESTARTS=$((RESTARTS+1))
            if [[ "$RESTART_FAIL_ONCE" == on ]]; then
                RESTART_FAIL_ONCE=off
                return 1
            fi
            return 0 ;;
        *) return 0 ;;
    esac
}
root=$(gateway_dir team)
mkdir -p "$root/pki" "$root/clients/ml" "$root/clients/laptop" "$root/clients/phone"
cat >"$root/gateway.cfg" <<'CFG'
GATEWAY_NAME=team
GATEWAY_BACKEND=openvpn
VIA_APP=host
TRANSPORT=direct
OPENVPN_COMPAT=modern
LISTEN_PROTO=udp
LISTEN_PORT=1194
OPENVPN_LISTEN_PROTO=udp
OPENVPN_LISTEN_PORT=1194
PUBLIC_HOST=example.org
PUBLIC_PORT=1194
CLIENT_POOL=10.253.50.0/24
GATEWAY_TUN=ngwteam
DNS_SERVERS='1.1.1.1'
SERVER_CN=nns-gateway-team
CLIENT_TO_CLIENT=on
CFG
for name in ml laptop phone; do
    cat >"$root/clients/$name/client.cfg" <<EOF_CLIENT
CLIENT_NAME="$name"
STATUS=active
FIXED_IP=""
EOF_CLIENT
    printf 'CLIENT CERT\n' > "$root/clients/$name/client.crt"
    printf 'CLIENT KEY\n' > "$root/clients/$name/client.key"
    printf 'TLS KEY\n' > "$root/clients/$name/tls-crypt-v2-client.key"
done
printf 'ROOT CERT\n' >"$root/pki/ca.crt"

# Legacy servers remain on full dynamic pool until explicitly opting in.
gateway_write_server_config team || fail 'write baseline server'
grep -Fxq 'server 10.253.50.0 255.255.255.0' "$root/server.conf" || fail 'baseline server pool'
! grep -Fq 'client-config-dir' "$root/server.conf" || fail 'CCD enabled without static clients'

[[ $(gateway_allocate_fixed_ip 10.253.50.0/24 '') == 10.253.50.128 ]] || fail 'first fixed IP'
[[ $(gateway_allocate_fixed_ip 10.253.50.0/24 'ml|10.253.50.128') == 10.253.50.129 ]] || fail 'second fixed IP'
[[ $(gateway_allocate_fixed_ip 10.253.50.0/29 '') == 10.253.50.4 ]] || fail '/29 first fixed IP'
if gateway_fixed_ip_plan 10.253.50.0/24 'ml|10.253.50.4' >/dev/null 2>&1; then
    fail 'dynamic-range fixed IP accepted'
fi
if gateway_fixed_ip_plan 10.253.50.0/24 $'ml|10.253.50.128\nlaptop|10.253.50.128' >/dev/null 2>&1; then
    fail 'duplicate fixed IP accepted'
fi
if gateway_fixed_ip_plan 10.253.50.0/24 'ml|10.253.51.128' >/dev/null 2>&1; then
    fail 'out-of-pool fixed IP accepted'
fi

# Modifying an existing client reuses its identity and never alters .ovpn.
gateway_client_fixed_ip team ml on >/dev/null || fail 'enable ml fixed IP'
[[ $(gateway_client_fixed_ip team ml show) == 'team/ml: fixed-ip=10.253.50.128' ]] || fail 'fixed IP status'
gateway_client_fixed_ip team laptop on >/dev/null || fail 'enable laptop fixed IP'
grep -Fxq 'ifconfig-push 10.253.50.128 255.255.255.0' "$root/ccd/ml" || fail 'CCD ml'
grep -Fxq 'ifconfig-push 10.253.50.129 255.255.255.0' "$root/ccd/laptop" || fail 'CCD laptop'
grep -Fxq 'server 10.253.50.0 255.255.255.0 nopool' "$root/server.conf" || fail 'fixed pool helper'
grep -Fxq 'ifconfig-pool 10.253.50.2 10.253.50.127 255.255.255.0' "$root/server.conf" || fail 'dynamic pool not separated from static IPs'
grep -Fxq "client-config-dir $root/ccd" "$root/server.conf" || fail 'CCD config missing'
grep -Fxq 'client-to-client' "$root/server.conf" || fail 'c2c lost'
[[ $(stat -c '%a' "$root/ccd/ml") == 640 ]] || fail 'CCD mode too permissive'
gateway_write_client_profile_file team ml "$TEST_TMP/ml.ovpn" public || fail 'profile generation'
! grep -Eq '(ifconfig-push|10\.253\.50\.128|FIXED_IP)' "$TEST_TMP/ml.ovpn" || fail 'client profile contains assigned IP'

gateway_client_fixed_ip team ml on >/dev/null || fail 'idempotence'
gateway_client_fixed_ip team ml off >/dev/null || fail 'turn off fixed IP'
[[ $(gateway_client_fixed_ip team ml show) == 'team/ml: fixed-ip=off' ]] || fail 'dynamic mode status'
[[ ! -e "$root/ccd/ml" ]] || fail 'removed fixed IP still in CCD'
[[ -e "$root/ccd/laptop" ]] || fail 'other client lost its fixed IP'
gateway_client_fixed_ip team laptop off >/dev/null || fail 'turn off last fixed IP'
! grep -Fq 'ifconfig-pool ' "$root/server.conf" || fail 'last fixed-IP disable left restricted pool'
! grep -Fq 'client-config-dir' "$root/server.conf" || fail 'last fixed-IP disable left CCD enabled'

# Restart failure rolls back the metadata and server configuration.
ACTIVE=on
RESTART_FAIL_ONCE=on
if gateway_client_fixed_ip team ml on >/dev/null 2>&1; then
    fail 'failed restart was accepted'
fi
[[ $(gateway_client_fixed_ip team ml show) == 'team/ml: fixed-ip=off' ]] || fail 'failure did not roll back client address'
! grep -Fq 'client-config-dir' "$root/server.conf" || fail 'failure did not restore pool'
(( RESTARTS == 2 )) || fail 'restart rollback did not retry service'

# Revoke/disable must never expose a stale CCD entry to OpenVPN.
ACTIVE=off
gateway_client_fixed_ip team ml on >/dev/null || fail 're-enable static address'
sed -i 's/^STATUS=active$/STATUS=revoked/' "$root/clients/ml/client.cfg"
gateway_write_server_config team || fail 'regenerate after revoke'
[[ ! -e "$root/ccd/ml" ]] || fail 'revoked client retained fixed assignment'

echo 'Fixed client IP tests passed.'
