#!/usr/bin/env bash
# Regression coverage for current client IPs and read-only detailed status.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
BASE_DIR="$T/apps"
GATEWAY_BASE_DIR="$T/gateways"
GATEWAY_RUN_BASE="$T/run"
mkdir -p "$BASE_DIR" "$GATEWAY_BASE_DIR" "$GATEWAY_RUN_BASE/team" "$GATEWAY_RUN_BASE/awg"
export NNS_APP_SOURCE_ONLY=1
source "$ROOT/src/10-config.sh"
source "$ROOT/src/60-gateway.sh"
source "$ROOT/src/63-amnezia-server.sh"
source "$ROOT/src/70-run-status.sh"
source "$ROOT/src/90-main.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
die() { echo "ERROR: $*" >&2; exit 1; }
require_root() { :; }
acquire_lock() { :; }
release_lock() { :; }
log() { printf '%s\n' "$*"; }
reset_gateway_client_vars() { CLIENT_NAME='' STATUS='' CERT_SERIAL='' CREATED_AT='' REVOKED_AT='' GENERATION='' CLOAK_UID='' FIXED_IP='' ROUTE_MODE=full; }
reset_gateway_cfg_vars() { GATEWAY_BACKEND='' TRANSPORT='' PUBLIC_HOST='' PUBLIC_PORT='' LISTEN_PROTO='' CLIENT_POOL='' GATEWAY_TUN='' CLIENT_TO_CLIENT='' VIA_APP=''; }
load_gateway_cfg() { reset_gateway_cfg_vars; source "$(gateway_cfg_file "$1")"; }
gateway_client_load() { reset_gateway_client_vars; source "$(gateway_client_dir "$1" "$2")/client.cfg"; }
systemctl() { if [[ "$1" == is-active ]]; then echo active; return 0; else return 1; fi; }
mkdir -p "$GATEWAY_BASE_DIR/team/clients" "$GATEWAY_BASE_DIR/awg/clients"
cat >"$GATEWAY_BASE_DIR/team/gateway.cfg" <<'CFG'
GATEWAY_NAME=team
GATEWAY_BACKEND=openvpn
TRANSPORT=direct
PUBLIC_HOST=vpn.example.org
PUBLIC_PORT=1194
LISTEN_PROTO=udp
CLIENT_POOL=10.99.1.0/24
GATEWAY_TUN=tunteam
CLIENT_TO_CLIENT=off
VIA_APP=host
CFG
cat >"$GATEWAY_BASE_DIR/awg/gateway.cfg" <<'CFG'
GATEWAY_NAME=awg
GATEWAY_BACKEND=amneziawg
TRANSPORT=direct
PUBLIC_HOST=vpn2.example.org
PUBLIC_PORT=51820
LISTEN_PROTO=udp
CLIENT_POOL=10.99.2.0/24
GATEWAY_TUN=tunawg
CLIENT_TO_CLIENT=on
VIA_APP=host
CFG
for spec in 'team dynamic active ""' 'team fixed active 10.99.1.150' 'team retired revoked ""' 'awg peer active 10.99.2.10'; do
    IFS=' ' read -r gateway client state fixed <<<"$spec"
    [[ "$fixed" != '""' ]] || fixed=''
    mkdir -p "$GATEWAY_BASE_DIR/$gateway/clients/$client"
    cat >"$GATEWAY_BASE_DIR/$gateway/clients/$client/client.cfg" <<EOF
CLIENT_NAME="$client"
STATUS="$state"
FIXED_IP="$fixed"
ROUTE_MODE=split
CERT_SERIAL="012345"
CREATED_AT="2026-11-01T10:00:00Z"
GENERATION=2
EOF
done
printf 'peerpublickey' >"$GATEWAY_BASE_DIR/awg/clients/peer/public.key"
# OpenVPN status format: live current IP must be used instead of static record.
printf 'HEADER\tCLIENT_LIST\tCommon Name\tReal Address\tVirtual IPv4 Address\tBytes Received\tBytes Sent\tConnected Since\nCLIENT_LIST\tdynamic\t203.0.113.99:4020\t10.99.1.17\t123\t456\t2026-11-13 12:00\nCLIENT_LIST\tfixed\t203.0.113.88:4021\t10.99.1.150\t200\t400\t2026-11-13 12:30\n' >"$GATEWAY_RUN_BASE/team/openvpn-status.log"
awg() {
    [[ "$1" == show ]] || return 1
    case "$3" in
        latest-handshakes) printf 'peerpublickey\t%s\n' "$(date +%s)" ;;
        transfer) printf 'peerpublickey\t111\t222\n' ;;
        endpoints) printf 'peerpublickey\t198.51.100.15:62000\n' ;;
    esac
}

output=$(list_external_clients_overview)
grep -Eq '(^|[[:space:]])IP([[:space:]]|$)' <<<"$output" || fail 'missing IP column'
! grep -Fq 'Created' <<<"$output" || fail 'old Created column still present'
grep -Fq '10.99.1.17' <<<"$output" || fail 'dynamic live IPv4 missing'
grep -Fq '10.99.1.150' <<<"$output" || fail 'fixed IP missing'
grep -Fq '10.99.2.10' <<<"$output" || fail 'AWG IP missing'
output=$(gateway_client_list team)
grep -Fq 'Fixed IP' <<<"$output" || fail 'fixed column lost'
grep -Fq 'IP' <<<"$output" || fail 'live column lost'
! grep -Fq 'Created' <<<"$output" || fail 'Created still shown on gateway view'
grep -Fq '10.99.1.17' <<<"$output" || fail 'dynamic IP missing gateway view'
output=$(gateway_client_status team dynamic)
grep -Fq 'Current VPN IP:    10.99.1.17' <<<"$output" || fail 'current IP missing in status'
grep -Fq 'Assigned VPN IP:   -' <<<"$output" || fail 'incorrect static IP'
grep -Fq 'Remote address:    203.0.113.99:4020' <<<"$output" || fail 'real address missing'
grep -Fq 'Bytes received:    123' <<<"$output" || fail 'RX missing'
grep -Fq 'Created:           2026-11-01T10:00:00Z' <<<"$output" || fail 'created missing from detail'
output=$(gateway_client_status team retired)
grep -Fq 'Connected:         no' <<<"$output" || fail 'revoked client marked connected'
grep -Fq 'Current VPN IP:    -' <<<"$output" || fail 'revoked has current IP'
output=$(gateway_client_status awg peer)
grep -Fq 'Current VPN IP:    10.99.2.10' <<<"$output" || fail 'AWG current IP missing'
grep -Fq 'Peer endpoint:     198.51.100.15:62000' <<<"$output" || fail 'AWG endpoint missing'
grep -Fq 'Peer public key:   peerpublickey' <<<"$output" || fail 'AWG public key missing'
! grep -Fq 'PRIVATE KEY' <<<"$output" || fail 'secret leaked'
[[ "$(main status dynamic | grep 'Current VPN IP:')" == 'Current VPN IP:    10.99.1.17' ]] || fail 'short client status dispatch'
[[ "$(main status team/dynamic | grep 'Current VPN IP:')" == 'Current VPN IP:    10.99.1.17' ]] || fail 'qualified client status dispatch'
[[ "$(main client status team dynamic | grep 'Current VPN IP:')" == 'Current VPN IP:    10.99.1.17' ]] || fail 'client status dispatch'
[[ "$(main gateway client status team dynamic | grep 'Current VPN IP:')" == 'Current VPN IP:    10.99.1.17' ]] || fail 'gateway client status dispatch'
mkdir -p "$GATEWAY_BASE_DIR/awg/clients/dynamic"
printf 'CLIENT_NAME=dynamic\nSTATUS=active\nFIXED_IP=10.99.2.20\n' >"$GATEWAY_BASE_DIR/awg/clients/dynamic/client.cfg"
if ( main status dynamic ) >/dev/null 2>&1; then fail 'ambiguous client name accepted'; fi
if ( main status missing ) >/dev/null 2>&1; then fail 'unknown client accepted'; fi
# A remote-managed client appears in list and may be inspected through the
# owning SSH remote without accessing unrelated gateways.
list_remote_auto_records() { printf 'CLIENT|remotepeer|active|remote-gw|vpn.example.org:1194/udp|10.123.0.8|yes|remote:hub\n'; }
cfg_read_value() { case "$2" in REMOTE_ALIAS) printf 'myremote\n';; REMOTE_OWNER_ID) printf 'myowner\n';; esac; }
remote_auto_command() {
    [[ "$1" == myremote && "$2" == client-status && "$3" == myowner && "$4" == remote-gw && "$5" == remotepeer ]] || fail 'wrong remote details request'
    echo 'Client: remotepeer'; echo 'Current VPN IP:    10.123.0.8'
}
output=$(main status remotepeer)
grep -Fq 'Source:            remote:hub' <<<"$output" || fail 'remote source not shown'
grep -Fq 'Current VPN IP:    10.123.0.8' <<<"$output" || fail 'remote detail not retrieved'
[[ "$(main status remote-gw/remotepeer | grep -c 'Current VPN IP')" == 1 ]] || fail 'qualified remote lookup'
echo 'Client IP and status regression tests passed.'
