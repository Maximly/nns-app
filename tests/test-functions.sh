#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

export NNS_APP_SOURCE_ONLY=1
export NNS_APP_LOCK_DIR="$TEST_TMP/locks"
# shellcheck source=/dev/null
source "$ROOT/nns-app-install.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ "$(format_duration 0)" == 0s ]] || fail 'format_duration 0'
[[ "$(format_duration 59)" == 59s ]] || fail 'format_duration seconds'
[[ "$(format_duration 60)" == 1m ]] || fail 'format_duration minute'
[[ "$(format_duration 3660)" == '1h 1m' ]] || fail 'format_duration hour'

IFS='|' read -r tun host ns host_fwd host_mangle ns_fwd ns_nat ns_mangle \
    <<<"$(make_gateway_names my-relay)"
[[ -n "$tun" && -n "$host" && -n "$ns" ]] || fail 'gateway interface names'
for chain in "$host_fwd" "$host_mangle" "$ns_fwd" "$ns_nat" "$ns_mangle"; do
    (( ${#chain} <= 28 )) || fail "iptables chain name too long: $chain"
done

lock_key="test-functions-$$"
acquire_lock "$lock_key"
acquire_lock "$lock_key"
safe_key=${lock_key//[^A-Za-z0-9_.-]/_}
[[ "${NNS_LOCK_DEPTH[$safe_key]}" == 2 ]] || fail 'nested lock depth'
release_lock "$lock_key"
[[ "${NNS_LOCK_DEPTH[$safe_key]}" == 1 ]] || fail 'nested lock release'
release_lock "$lock_key"
[[ -z "${NNS_LOCK_FDS[$safe_key]-}" ]] || fail 'lock descriptor cleanup'

all_known_ipv4_networks() {
    printf '%s\n' \
        10.240.0.0/30 \
        10.240.0.4/30
}
IFS='|' read -r net host_addr ns_addr <<<"$(allocate_network)"
[[ "$net" == 10.240.0.8/30 ]] || fail "unexpected app network: $net"
[[ "$host_addr" == 10.240.0.9/30 ]] || fail "unexpected host address: $host_addr"
[[ "$ns_addr" == 10.240.0.10/30 ]] || fail "unexpected namespace address: $ns_addr"

all_known_ipv4_networks() {
    printf '%s\n' \
        10.253.0.0/24 \
        10.239.0.0/30 \
        192.168.50.0/24
}
IFS='|' read -r pool transit transit_host transit_ns \
    <<<"$(allocate_gateway_networks '')"
[[ "$pool" == 10.253.1.0/24 ]] || fail "unexpected gateway pool: $pool"
[[ "$transit" == 10.239.0.4/30 ]] || fail "unexpected transit: $transit"

if allocate_gateway_networks 10.240.1.0/24 >/dev/null 2>&1; then
    fail 'reserved app-network range accepted as a gateway pool'
fi

gateway_route_id_in_use() {
    (( $1 < 22002 ))
}
[[ "$(allocate_gateway_table)" == '22002|12002' ]] ||
    fail 'route-table allocator did not skip occupied IDs'

cfg_read_value() {
    case "$1:$2" in
        B:UPSTREAM_APP) printf 'C\n' ;;
        C:UPSTREAM_APP) printf 'A\n' ;;
        *) printf '\n' ;;
    esac
}
if ( assert_no_via_cycle A B ) >/dev/null 2>&1; then
    fail 'indirect upstream cycle was accepted'
fi

TEST_STATUS_FILE="$TEST_TMP/openvpn-status.log"
printf '%s\n' \
    $'TITLE\tOpenVPN 2.7.0 x86_64-pc-linux-gnu' \
    $'TIME\t2026-08-03 10:00:00\t1785740400' \
    $'HEADER\tCLIENT_LIST\tCommon Name\tReal Address\tVirtual Address\tBytes Received\tBytes Sent\tConnected Since' \
    $'CLIENT_LIST\tmy-linux-client\t203.0.113.10:41000\t10.253.1.2\t1234\t5678\t2026-08-03 09:59:00' \
    >"$TEST_STATUS_FILE"

gateway_status_file() {
    printf '%s\n' "$TEST_STATUS_FILE"
}

parsed=$(gateway_connected_clients my-relay)
expected='my-linux-client|203.0.113.10:41000|10.253.1.2|1234|5678|2026-08-03 09:59:00'
[[ "$parsed" == "$expected" ]] || fail "status-v3 parser: $parsed"

tmp_pki="$TEST_TMP/pki"
tmp_backup="$TEST_TMP/pki-backup"
mkdir -p "$tmp_pki/newcerts" "$tmp_backup"
printf 'V\n' >"$tmp_pki/index.txt"
printf '1000\n' >"$tmp_pki/serial"
printf '1000\n' >"$tmp_pki/crlnumber"
printf 'cert\n' >"$tmp_pki/newcerts/1000.pem"
gateway_ca_snapshot "$tmp_pki" "$tmp_backup"
printf 'BROKEN\n' >"$tmp_pki/index.txt"
rm -f "$tmp_pki/newcerts/1000.pem"
gateway_ca_restore "$tmp_pki" "$tmp_backup"
[[ "$(<"$tmp_pki/index.txt")" == V ]] || fail 'CA index restore'
[[ -f "$tmp_pki/newcerts/1000.pem" ]] || fail 'CA newcerts restore'

echo 'Function tests passed.'
