#!/usr/bin/env bash
# Server-side per-client split/full tunnel and fixed-IP interactions.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TEST_TMP/locks"
# shellcheck source=/dev/null
source "$ROOT/nns-app-install.sh"
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
gateway_pki_dir() { printf '%s/gateways/%s/pki\n' "$TEST_TMP" "$1"; }
load_gateway_cfg() { reset_gateway_cfg_vars; source "$(gateway_cfg_file "$1")"; }
gateway_client_load() { reset_gateway_client_vars; source "$(gateway_client_dir "$1" "$2")/client.cfg"; }
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
mkdir -p "$root/pki" "$root/clients/ml" "$root/clients/laptop" "$root/clients/old"
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
DNS_SERVERS='1.1.1.1 9.9.9.9'
SERVER_CN=nns-gateway-team
CLIENT_TO_CLIENT=on
CFG
for name in ml laptop old; do
    cat >"$root/clients/$name/client.cfg" <<EOF_CLIENT
CLIENT_NAME="$name"
STATUS=active
FIXED_IP=""
EOF_CLIENT
    chmod 0600 "$root/clients/$name/client.cfg"
    printf 'CLIENT CERT\n' >"$root/clients/$name/client.crt"
    printf 'CLIENT KEY\n' >"$root/clients/$name/client.key"
    printf 'TLS KEY\n' >"$root/clients/$name/tls-crypt-v2-client.key"
done
printf 'ROOT CERT\n' >"$root/pki/ca.crt"
# Original clients, even those without a ROUTE_MODE entry, remain full tunnel.
gateway_write_server_config team || fail 'write baseline server'
[[ $(gateway_client_route_mode team old show) == 'team/old: route-mode=full' ]] || fail 'legacy default full'
grep -Fxq 'push "redirect-gateway def1 bypass-dhcp"' "$root/server.conf" || fail 'global route lost'
! grep -Fq 'client-config-dir' "$root/server.conf" || fail 'unexpected baseline CCD'

# Existing client can enable split mode without a fixed address.
gateway_client_route_mode team ml split >/dev/null || fail 'route mode split'
[[ $(gateway_client_route_mode team ml show) == 'team/ml: route-mode=split' ]] || fail 'route mode status'
grep -Fxq 'push-remove redirect-gateway' "$root/ccd/ml" || fail 'split redirect push missing'
grep -Fxq 'push-remove "dhcp-option DNS"' "$root/ccd/ml" || fail 'split DNS push missing'
grep -Fxq "client-config-dir $root/ccd" "$root/server.conf" || fail 'split-only CCD config missing'
! grep -Fq 'ifconfig-pool ' "$root/server.conf" || fail 'split accidentally restricted pool'
[[ ! -e "$root/ccd/laptop" ]] || fail 'other client got route override'

# Static and split can coexist and have no client-profile side effects.
gateway_client_fixed_ip team ml on >/dev/null || fail 'fixed IP after split'
grep -Fxq 'ifconfig-push 10.253.50.128 255.255.255.0' "$root/ccd/ml" || fail 'fixed IP dropped by split policy'
grep -Fxq 'push-remove redirect-gateway' "$root/ccd/ml" || fail 'split route policy dropped by fixed IP'
[[ $(gateway_client_route_mode team laptop show) == 'team/laptop: route-mode=full' ]] || fail 'second client default changed'

gateway_write_client_profile_file team ml "$TEST_TMP/ml.ovpn" public || fail 'export profile'
! grep -Eq 'redirect-gateway|push-remove|ifconfig-push|10\.253\.50\.128' "$TEST_TMP/ml.ovpn" || fail 'server-side settings leaked into ovpn'

# Change back to full while keeping the fixed IP.
gateway_client_route_mode team ml full >/dev/null || fail 'revert to full'
[[ $(gateway_client_route_mode team ml show) == 'team/ml: route-mode=full' ]] || fail 'revert status'
grep -Fxq 'ifconfig-push 10.253.50.128 255.255.255.0' "$root/ccd/ml" || fail 'fixed IP lost on return to full'
! grep -Fq 'push-remove' "$root/ccd/ml" || fail 'stale route policy after return to full'
gateway_client_fixed_ip team ml off >/dev/null || fail 'disable fixed IP'
[[ ! -e "$root/ccd/ml" ]] || fail 'CCD retained after restoring defaults'
! grep -Fq 'client-config-dir ' "$root/server.conf" || fail 'CCD still enabled with no overrides'

# A failed service restart restores route policy and CCD state.
ACTIVE=on
RESTART_FAIL_ONCE=on
if gateway_client_route_mode team ml split >/dev/null 2>&1; then
    fail 'failed restart falsely succeeded'
fi
[[ $(gateway_client_route_mode team ml show) == 'team/ml: route-mode=full' ]] || fail 'restart failure did not restore policy'
[[ ! -e "$root/ccd/ml" ]] || fail 'restart failure left split CCD'
(( RESTARTS == 2 )) || fail 'restart rollback did not restart twice'

# Revoke must remove per-client policy from the active CCD.
ACTIVE=off
gateway_client_route_mode team ml split >/dev/null || fail 're-enable split'
sed -i 's/^STATUS=active$/STATUS=revoked/' "$root/clients/ml/client.cfg"
gateway_write_server_config team || fail 'regenerate after revocation'
[[ ! -e "$root/ccd/ml" ]] || fail 'revoked split client retained CCD'
! grep -Fq 'client-config-dir' "$root/server.conf" || fail 'revoked split client left CCD enabled'

echo 'Server-side client routing tests passed.'
