#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/src/52-mtu.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
log() { :; }
warn() { :; }
load_cfg() { NS_NAME=nns-test; AUTO_MTU=${TEST_AUTO_MTU:-on}; }
vpn_type_for_app() { printf '%s\n' "${TEST_TYPE:-openvpn}"; }
app_split_tunnel() { [[ "${TEST_SPLIT:-off}" == on ]]; }
vpn_route_iface() { echo tun0; }
SAVED_MTU=""
MTU=1500
TRIES=""
SAVE_COUNT=0
ip() {
    if [[ "$1" == -n && "$3" == -o ]]; then
        echo "2: tun0: <UP> mtu $MTU qdisc fq_codel"
        return 0
    fi
    if [[ "$1" == -n && "$3" == link && "$4" == set ]]; then
        MTU=$8
        TRIES+="$MTU "
        return 0
    fi
    echo "unexpected mock ip args: $*" >&2
    return 1
}
cfg_set() { [[ "$2" == TUN_MTU ]] || fail 'wrong cfg var'; SAVED_MTU=$3; SAVE_COUNT=$((SAVE_COUNT + 1)); }
# Confirm the real curl-metrics classifier works with the project's IFS.
(
    ip() { printf '0.032 0.000\n'; return 28; }
    if mtu_https_probe test https://example.org/; then fail 'TLS timeout was healthy';
    else [[ $? == 10 ]] || fail 'TLS timeout classification'; fi
)
(
    ip() { printf '0.000 0.000\n'; return 6; }
    if mtu_https_probe test https://example.org/; then fail 'DNS error was healthy';
    else [[ $? == 20 ]] || fail 'DNS error classification'; fi
)
(
    ip() { printf '0.034 0.212\n'; return 22; }
    mtu_https_probe test https://example.org/ || fail 'completed TLS incorrectly treated as MTU issue'
)
# Use a simpler response for the tuner itself, with two independent targets.
mtu_https_probe() {
    local ns=$1 url=$2
    case "${TEST_MODE:-healthy}" in
        healthy) return 0;;
        dnsfailed) return 20;;
        stuck) return 10;;
        rescued1400) if (( MTU <= 1400 )); then return 0; else return 10; fi;;
        rescued1280) if (( MTU <= 1280 )); then return 0; else return 10; fi;;
        intermittent) if (( MTU <= 1400 )); then
             if [[ "$url" == *cloudflare* ]]; then return 0; else return 10; fi
          fi
          return 10;;
    esac
}
TEST_MODE=healthy
mtu_auto_repair test
[[ $MTU == 1500 && $SAVE_COUNT == 0 ]] || fail 'healthy tunnel modified'
TEST_MODE=dnsfailed
mtu_auto_repair test
[[ $MTU == 1500 && $SAVE_COUNT == 0 ]] || fail 'non-TLS outage triggered tuning'
TEST_MODE=rescued1400
mtu_auto_repair test
[[ $MTU == 1400 && $SAVED_MTU == 1400 && $SAVE_COUNT == 1 ]] || fail 'MTU recovery not saved'
TRIES='' MTU=1500 SAVED_MTU='' SAVE_COUNT=0
TEST_MODE=rescued1280
mtu_auto_repair test
[[ $MTU == 1280 && $SAVED_MTU == 1280 && $SAVE_COUNT == 1 ]] || fail 'fallback candidate not saved'
[[ "$TRIES" == '1400 1360 1320 1280 ' ]] || fail "incorrect sweep: $TRIES"
TRIES='' MTU=1500 SAVED_MTU='' SAVE_COUNT=0
TEST_MODE=stuck
mtu_auto_repair test
[[ $MTU == 1500 && $SAVE_COUNT == 0 ]] || fail 'failed tuning not rolled back'
TRIES='' MTU=1500 SAVED_MTU='' SAVE_COUNT=0
TEST_MODE=rescued1400 TEST_AUTO_MTU=off
mtu_auto_repair test
[[ $MTU == 1500 && $SAVE_COUNT == 0 ]] || fail 'disabled tuning changed MTU'
TEST_AUTO_MTU=on TEST_SPLIT=on
mtu_auto_repair test
[[ $MTU == 1500 && $SAVE_COUNT == 0 ]] || fail 'split routing triggered full-tunnel HTTPS checks'
TEST_SPLIT=off TEST_TYPE=wireguard
mtu_auto_repair test
[[ $MTU == 1500 && $SAVE_COUNT == 0 ]] || fail 'wireguard unexpectedly tuned'
TEST_TYPE=openvpn
# Ensure the startup paths call the repair hook and the OpenVPN exec path
# persists learned values across backend reconnections.
grep -Fq 'mtu_auto_repair "$app"' "$ROOT/src/50-runtime.sh" || fail 'interactive start missing repair'
grep -Fq 'mtu_auto_repair "$2"' "$ROOT/src/90-main.sh" || fail 'boot-time online unit missing repair'
grep -Fq 'args+=(--tun-mtu "$TUN_MTU")' "$ROOT/src/50-runtime.sh" || fail 'OpenVPN reconnect missing saved MTU'
echo 'Conditional startup MTU regression tests passed.'
