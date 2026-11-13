#!/usr/bin/env bash
# Cloak host server install/reinstall, client export, rollback regression checks.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TEST_TMP/locks"
source "$ROOT/install_linux"
fail() { echo "FAIL: $*" >&2; exit 1; }
require_root() { :; }
acquire_lock() { :; }
release_lock() { :; }
ensure_dependencies() { :; }
install_engine_files() { :; }
write_gateway_unit_dropin() { :; }
log() { :; }
warn() { :; }
mkdir -p "$TEST_TMP/apps" "$TEST_TMP/gateways" "$TEST_TMP/run"
cfg_file() { printf '%s/apps/%s/app.cfg\n' "$TEST_TMP" "$1"; }
gateway_dir() { printf '%s/gateways/%s\n' "$TEST_TMP" "$1"; }
gateway_cfg_file() { printf '%s/gateways/%s/gateway.cfg\n' "$TEST_TMP" "$1"; }
gateway_client_dir() { printf '%s/gateways/%s/clients/%s\n' "$TEST_TMP" "$1" "$2"; }
gateway_clients_dir() { printf '%s/gateways/%s/clients\n' "$TEST_TMP" "$1"; }
gateway_pki_dir() { printf '%s/gateways/%s/pki\n' "$TEST_TMP" "$1"; }
gateway_server_config() { printf '%s/gateways/%s/server.conf\n' "$TEST_TMP" "$1"; }
gateway_transport_dir() { printf '%s/gateways/%s/transport\n' "$TEST_TMP" "$1"; }
load_gateway_cfg() { reset_gateway_cfg_vars; source "$(gateway_cfg_file "$1")"; }
# Avoid relying on systemd/real local sockets in a pure unit test.
server_listener_conflict() { return 1; }
server_public_host() { echo 198.51.100.40; }
gateway_allocate_backend_port() { echo 22550; }
gateway_transport_binary() { [[ "$1" == cloak ]] && echo /usr/bin/ck-server; }
gateway_cloak_new_uid() { echo 'MDEyMzQ1Njc4OWFiY2RlZg=='; }
gateway_prepare_transport() {
    local root=$2
    mkdir -p "$root/transport"
    echo 'ZmFrZV9wdWJsaWNfa2V5' >"$root/transport/public.key"
    echo 'ZmFrZV9wcml2YXRlX2tleQ==' >"$root/transport/private.key"
}
ACTIVE=off
FAIL_START=off
START_COUNT=0
systemctl() {
    if [[ "$1" == is-active ]]; then [[ "$ACTIVE" == on ]]; return; fi
    return 0
}
gateway_stop() { :; }
gateway_start() {
    local name=$1
    load_gateway_cfg "$name"
    START_COUNT=$((START_COUNT+1))
    [[ "$FAIL_START" == off ]] || return 1
    printf 'proto %s\nport %s\n' "$OPENVPN_LISTEN_PROTO" "$OPENVPN_LISTEN_PORT" > "$(gateway_server_config "$name")"
    if [[ "$TRANSPORT" == cloak ]]; then
        gateway_write_transport_config "$name"
    fi
}
# Don't create real PKI for this test. The existing upstream path is already
# tested in the install suites; assert argument propagation here.
gateway_create() {
    local name=$1 via=$2 listen=$3 public=$4 transport=$7 decoy=$8
    [[ "$via" == host && "$transport" == cloak && "$decoy" == www.bing.com ]] || fail 'wrong cloak create arguments'
    [[ "$listen" == tcp:443 && "$public" == 198.51.100.40:443 ]] || fail 'wrong cloak listen/public defaults'
    mkdir -p "$(gateway_dir "$name")/clients" "$(gateway_dir "$name")/pki"
    cat >"$(gateway_cfg_file "$name")" <<EOF
GATEWAY_NAME=$name
GATEWAY_BACKEND=openvpn
VIA_APP=host
TRANSPORT=cloak
TRANSPORT_SERVER_NAME=www.bing.com
LISTEN_PROTO=tcp
LISTEN_PORT=443
OPENVPN_LISTEN_PROTO=tcp
OPENVPN_LISTEN_PORT=22550
PUBLIC_HOST=198.51.100.40
PUBLIC_PORT=443
CLIENT_POOL=10.253.2.0/24
DNS_SERVERS='1.1.1.1 9.9.9.9'
CLIENT_TO_CLIENT=off
EOF
    gateway_prepare_transport "$name" "$(gateway_dir "$name")" cloak
}
install_openvpn_server newcloak '' '' '' '' '' cloak >/dev/null
[[ "$(gateway_cfg_value newcloak TRANSPORT)" == cloak ]] || fail 'new server did not select Cloak'
[[ "$(gateway_cfg_value newcloak LISTEN_PROTO)" == tcp ]] || fail 'new server not TCP'
[[ "$(gateway_cfg_value newcloak OPENVPN_LISTEN_PORT)" == 22550 ]] || fail 'OpenVPN backend not private TCP'

# Convert a real saved direct server without losing its client credentials.
root=$(gateway_dir legacy)
mkdir -p "$root/clients/ml" "$root/pki" "$root/transport"
cat >"$root/gateway.cfg" <<'EOF'
GATEWAY_NAME=legacy
GATEWAY_BACKEND=openvpn
VIA_APP=host
TRANSPORT=direct
TRANSPORT_SERVER_NAME=198.51.100.40
LISTEN_PROTO=udp
LISTEN_PORT=1194
OPENVPN_LISTEN_PROTO=udp
OPENVPN_LISTEN_PORT=1194
PUBLIC_HOST=198.51.100.40
PUBLIC_PORT=1194
CLIENT_POOL=10.253.0.0/24
DNS_SERVERS='1.1.1.1 9.9.9.9'
CLIENT_TO_CLIENT=on
EOF
cat >"$root/clients/ml/client.cfg" <<'EOF'
CLIENT_NAME=ml
STATUS=active
CLOAK_UID=""
FIXED_IP=10.253.0.128
ROUTE_MODE=split
EOF
echo keep-key >"$root/clients/ml/client.key"
echo keep-ca >"$root/pki/ca.crt"
echo original >"$root/server.conf"
install_openvpn_server legacy 'tcp:8443' '198.51.100.40:8443' '' '' '' cloak 'www.bing.com' >/dev/null
[[ "$(gateway_cfg_value legacy TRANSPORT)" == cloak ]] || fail 'conversion did not select Cloak'
[[ "$(gateway_cfg_value legacy CLIENT_TO_CLIENT)" == on ]] || fail 'conversion lost client-to-client'
[[ "$(gateway_cfg_value legacy PUBLIC_PORT)" == 8443 ]] || fail 'conversion lost public port'
[[ "$(gateway_cfg_value legacy OPENVPN_LISTEN_PORT)" == 22550 ]] || fail 'conversion did not set private OpenVPN port'
[[ "$(cat "$root/clients/ml/client.key")" == keep-key ]] || fail 'conversion replaced client key'
[[ "$(cat "$root/pki/ca.crt")" == keep-ca ]] || fail 'conversion replaced CA'
[[ "$(gateway_cfg_value legacy TRANSPORT_SERVER_NAME)" == www.bing.com ]] || fail 'decoy missing'
grep -Fq 'CLOAK_UID="MDEyMzQ1Njc4OWFiY2RlZg=="' "$root/clients/ml/client.cfg" || fail 'existing client not issued Cloak UID'
grep -Fq 'FIXED_IP=10.253.0.128' "$root/clients/ml/client.cfg" || fail 'fixed IP lost'
grep -Fq 'ROUTE_MODE=split' "$root/clients/ml/client.cfg" || fail 'route mode lost'
python3 - "$root/transport/server.json" <<'PY'
import json,sys
cfg=json.load(open(sys.argv[1]))
assert cfg['RedirAddr'] == 'www.bing.com:443', cfg
assert cfg['BindAddr'] == [':8443'], cfg
assert cfg['ProxyBook']['openvpn'] == ['tcp','127.0.0.1:22550'], cfg
assert cfg['BypassUID'] == ['MDEyMzQ1Njc4OWFiY2RlZg=='], cfg
PY

# Generating macOS standalone Cloak/Tunnelblick pair requires no live certs.
gateway_write_client_profile_file() {
    printf 'client\nproto tcp-client\nremote 127.0.0.1 11940\n' > "$3"
}
output="$TEST_TMP/mac.ovpn"
gateway_cloak_export_client_pair legacy ml "$output" >/dev/null
[[ -f "$output" && -f "$TEST_TMP/mac.cloak.json" ]] || fail 'export did not emit both files'
grep -q '^route 198.51.100.40 255.255.255.255 net_gateway$' "$output" || fail 'full-tunnel transport escape route missing'
python3 - "$TEST_TMP/mac.cloak.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
assert x['ServerName'] == 'www.bing.com'
assert x['UID'] == 'MDEyMzQ1Njc4OWFiY2RlZg=='
assert x['ProxyMethod'] == 'openvpn'
assert x['EncryptionMethod'] != 'plain'
PY
[[ "$(stat -c %a "$output")" == 600 ]] || fail 'client profile not private'
[[ "$(stat -c %a "$TEST_TMP/mac.cloak.json")" == 600 ]] || fail 'client Cloak JSON not private'
if ( gateway_cloak_export_client_pair legacy ml - ) >/dev/null 2>&1; then fail 'Cloak stdout export accepted'; fi
if ( gateway_cloak_export_client_pair legacy ml "$output" ) >/dev/null 2>&1; then fail 'Cloak export overwrote existing files'; fi

# Simulated failed reinstall must restore client UID, transport and config.
FAIL_START=on
if ( install_openvpn_server legacy 'tcp:8444' '' '' '' '' direct ) >/dev/null 2>&1; then
    fail 'simulated failed reconfiguration unexpectedly succeeded'
fi
[[ "$(gateway_cfg_value legacy TRANSPORT)" == cloak ]] || fail 'rollback lost prior Cloak transport'
[[ "$(gateway_cfg_value legacy PUBLIC_PORT)" == 8443 ]] || fail 'rollback lost endpoint'
[[ -f "$root/transport/private.key" ]] || fail 'rollback lost Cloak private key'
grep -Fq 'CLOAK_UID="MDEyMzQ1Njc4OWFiY2RlZg=="' "$root/clients/ml/client.cfg" || fail 'rollback lost client UID'
[[ "$(cat "$root/clients/ml/client.key")" == keep-key ]] || fail 'rollback lost client private key'

# Assert the public command dispatches the two new options intact.
install_openvpn_server() { printf '%s|%s|%s|%s\n' "$1" "$2" "$7" "$8" >"$TEST_TMP/parsed"; }
main install dispatch --server --listen tcp:8443 --transport cloak --server-name www.bing.com
[[ "$(cat "$TEST_TMP/parsed")" == 'dispatch|tcp:8443|cloak|www.bing.com' ]] || fail 'install CLI lost transport/server-name arguments'
if ( main install dispatch --transport cloak ) >/dev/null 2>&1; then fail 'transport accepted without --server'; fi
printf 'Cloak server lifecycle/export tests passed.\n' 
