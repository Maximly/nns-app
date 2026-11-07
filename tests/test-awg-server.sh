#!/usr/bin/env bash
# User-space AWG server creation/export, key preservation, peer lifecycle.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1
source "$ROOT/nns-app-install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
require_root() { :; }
log() { :; }
warn() { :; }
acquire_lock() { :; }
release_lock() { :; }
modprobe() { :; }
server_listener_conflict() { return 1; }
server_public_host() { echo 198.51.100.40; }
server_choose_listener() { echo udp:51821; }
validate_gateway_dns() { printf '%s\n' "${1:-1.1.1.1}"; }
allocate_gateway_networks() { echo '10.253.79.0/24|10.239.0.0/30|10.239.0.1/30|10.239.0.2/30'; }
write_gateway_unit_dropin() { :; }
awg_server_require_runtime() { :; }
awg() {
    case "$1" in
        genkey) printf '%043d=\n' 0 | tr '0' A ;;
        pubkey) printf '%043d=\n' 0 | tr '0' B ;;
        syncconf) : ;;
        show)
            case "$3" in
                latest-handshakes) : ;;
                listen-port) printf '51821\n' ;;
            esac
            ;;
        *) : ;;
    esac
}
awg-quick() { [[ "$1" == strip ]] && cat "$2" || :; }
systemctl() {
    [[ "$1" == is-active ]] && return 1
    return 0
}
awg_server_start() { awg_server_write_config "$1"; }
cfg_file() { echo "$TMP/apps/$1.cfg"; }
gateway_dir() { echo "$TMP/gateways/$1"; }
gateway_cfg_file() { echo "$TMP/gateways/$1/gateway.cfg"; }
gateway_client_dir() { echo "$TMP/gateways/$1/clients/$2"; }
gateway_clients_dir() { echo "$TMP/gateways/$1/clients"; }
mkdir -p "$TMP/apps" "$TMP/gateways"

awg_server_install localawg udp:51821 198.51.100.40:51821 10.253.79.0/24 '' off
G=$(gateway_dir localawg)
[[ -f "$G/gateway.cfg" && -s "$G/server.key" && -s "$G/header.key" && -f "$G/ngw$(printf %08x "$(printf localawg | cksum | awk '{print $1}')").conf" ]] || \
    [[ -n "$(find "$G" -maxdepth 1 -name 'ngw*.conf' -print)" ]] || fail 'missing server config'
conf=$(find "$G" -maxdepth 1 -name 'ngw*.conf' | head -1)
grep -q '^HeaderProtectionKey = ' "$conf" || fail '3.1 header protection missing'
grep -q '^ContentPaddingAddition = ' "$conf" || fail '3.1 padding missing'
grep -Eq '^S3 = ([1-9][0-9]|[1-9][0-9][0-9])$' "$conf" || fail 'invalid 3.1 nonce padding'
serverkey=$(cat "$G/server.key")
headerkey=$(cat "$G/header.key")
awg_server_install localawg udp:51821 '' '' '' on
[[ "$(cat "$G/server.key")" == "$serverkey" && "$(cat "$G/header.key")" == "$headerkey" ]] || fail 'reinstall rotated secrets'
[[ "$(gateway_cfg_value localawg CLIENT_TO_CLIENT)" == on ]] || fail 'reinstall lost c2c setting'
awg_server_client_add localawg mac split
[[ "$(grep -c '^\[Peer\]$' "$conf")" == 1 ]] || fail 'peer missing in server conf'
[[ "$(grep '^AllowedIPs = ' "$conf")" == 'AllowedIPs = 10.253.79.2/32' ]] || fail 'wrong peer IP'
awg_server_client_export localawg mac "$TMP/mac.conf" keep
[[ -f "$TMP/mac.conf" ]] || fail 'missing client export'
grep -q '^AllowedIPs = 10.253.79.0/24$' "$TMP/mac.conf" || fail 'split route should include VPN pool only'
grep -q '^HeaderProtectionKey = ' "$TMP/mac.conf" || fail 'client missing header key'
[[ "$(cat "$G/header.key")" == "$headerkey" ]] || fail 'client export rotated shared key'
awg_server_client_export localawg mac "$TMP/mac-full.conf" full
grep -q '^AllowedIPs = 0.0.0.0/0$' "$TMP/mac-full.conf" || fail 'full route missing'
awg_server_client_revoke localawg mac
[[ "$(grep -c '^\[Peer\]$' "$conf" || true)" == 0 ]] || fail 'revoked peer still in server conf'
echo 'AmneziaWG server create/reinstall/peer/export/revoke tests passed.'

(
    reexec_as_root_if_needed() { :; }
    awg_server_install() { printf 'awg-install:%s|%s|%s|%s|%s|%s\n' "$@"; }
    got=$(main install demo --server --amnezia --listen udp:51821 --public vpn.example.net:51821)
    [[ "$got" == 'awg-install:demo|udp:51821|vpn.example.net:51821|||' ]] || fail "--amnezia CLI dispatch: $got"
    if ( main install demo --amnezia ) >/dev/null 2>&1; then fail '--amnezia accepted without --server'; fi
    if ( main install demo --server --amnezia --transport cloak ) >/dev/null 2>&1; then fail 'Cloak unexpectedly combined with AmneziaWG'; fi
    server_gateway_exists() { :; }
    awg_server_client_export() { printf 'awg-export:%s|%s|%s|%s\n' "$@"; }
    got=$(main export awg demo --client mac --split-tunnel --output mac.conf)
    [[ "$got" == 'awg-export:demo|mac|mac.conf|split' ]] || fail "AWG client CLI export dispatch: $got"
)
echo 'AmneziaWG CLI dispatch tests passed.'
