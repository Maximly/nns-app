#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/src/52-mtu.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
log() { :; }
warn() { :; }
load_cfg() { NS_NAME=nns-test; AUTO_MTU=${TEST_AUTO_MTU:-on}; TUN_MTU=${TEST_TUN_MTU:-}; }
vpn_type_for_app() { printf '%s\n' "${TEST_TYPE:-openvpn}"; }
app_split_tunnel() { [[ "${TEST_SPLIT:-off}" == on ]]; }
vpn_route_iface() { echo tun0; }
RUN_DIR=$(mktemp -d)
trap 'rm -rf "$RUN_DIR"' EXIT
SAVED_MTU=''
MTU=1500
TRIES=''
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
    if [[ "$1" == netns && "$2" == exec && "$4" == curl ]]; then
        local url=${!#} mode=${TEST_MODE:-healthy} fail_probe=0
        case "$mode" in
            healthy) ;;
            dnsfailed) echo 'curl: (6) Could not resolve host' >&2; return 6 ;;
            tcpfailed) echo 'curl: (28) Connection timed out' >&2; return 28 ;;
            stuck) fail_probe=1 ;;
            rescued1400) (( MTU <= 1400 )) || fail_probe=1 ;;
            rescued1280) (( MTU <= 1280 )) || fail_probe=1 ;;
            mixed)
                if [[ "$url" == *speed.cloudflare.com* ]]; then
                    echo 'curl: (6) Could not resolve host' >&2
                    return 6
                fi
                (( MTU <= 1400 )) || fail_probe=1
                ;;
            onehealthy)
                if [[ "$url" == *api.ipify.org* ]] && (( MTU > 1400 )); then
                    fail_probe=1
                fi
                ;;
            servererror) echo 'curl: (22) The requested URL returned error: 503' >&2; return 22 ;;
            shortreply)
                printf 'NNS_MTU_METRICS:0.032|0.150|1|200\n'
                return 0
                ;;
        esac
        if (( fail_probe )); then
            # Curl 8.11+ may return zero time_connect on TLS timeout.
            echo '* TLSv1.3 (OUT), TLS handshake, Client hello (1):' >&2
            printf 'NNS_MTU_METRICS:0.000000|0.000000|0|000\n'
            return 28
        fi
        local bytes=14
        [[ "$url" == *'/__down?bytes=32768' ]] && bytes=32768
        printf 'NNS_MTU_METRICS:0.032|0.150|%d|200\n' "$bytes"
        return 0
    fi
    echo "unexpected mock ip args: $*" >&2
    return 1
}
cfg_set() {
    [[ "$2" == TUN_MTU ]] || fail 'wrong cfg variable'
    SAVED_MTU=$3
    SAVE_COUNT=$((SAVE_COUNT + 1))
}

# Real classifier (not stubbed): avoids curl's time_connect=0 TLS regression.
TEST_MODE=stuck
if mtu_https_probe test https://api.ipify.org/; then fail 'TLS stall classified as healthy';
else [[ $? == 10 ]] || fail 'TLS stall not classified by ClientHello'; fi
TEST_MODE=dnsfailed
if mtu_https_probe test https://api.ipify.org/; then fail 'DNS failure classified as healthy';
else [[ $? == 20 ]] || fail 'DNS failure incorrectly triggers tuning'; fi
TEST_MODE=tcpfailed
if mtu_https_probe test https://api.ipify.org/; then fail 'TCP timeout classified as healthy';
else [[ $? == 20 ]] || fail 'TCP timeout incorrectly triggers tuning'; fi
TEST_MODE=shortreply
if mtu_https_probe test 'https://speed.cloudflare.com/__down?bytes=32768'; then
    fail '1-byte download classified as healthy'
else [[ $? == 20 ]] || fail 'short download classified as MTU stall'; fi

TEST_MODE=healthy
mtu_auto_repair test
[[ $MTU == 1500 && $SAVE_COUNT == 0 ]] || fail 'healthy tunnel modified'
grep -Fq 'healthy:MTU=1500' "$RUN_DIR/test.mtu-check" || fail 'healthy probe status not saved'
TEST_MODE=dnsfailed
mtu_auto_repair test
[[ $MTU == 1500 && $SAVE_COUNT == 0 ]] || fail 'DNS failure triggered tuning'
TEST_MODE=onehealthy
mtu_auto_repair test
[[ $MTU == 1400 && $SAVED_MTU == 1400 && $SAVE_COUNT == 1 ]] ||
    fail 'healthy first target hid a stalled second target'
grep -Fq 'recovered:MTU=1400' "$RUN_DIR/test.mtu-check" || fail 'MTU recovery not reflected in state'
TRIES='' MTU=1500 SAVED_MTU='' SAVE_COUNT=0
TEST_MODE=mixed
mtu_auto_repair test
[[ $MTU == 1400 && $SAVED_MTU == 1400 && $SAVE_COUNT == 1 ]] ||
    fail 'unavailable optional target suppressed recoverable TLS stall'
TRIES='' MTU=1500 SAVED_MTU='' SAVE_COUNT=0
TEST_MODE=rescued1280
mtu_auto_repair test
[[ $MTU == 1280 && $SAVED_MTU == 1280 && $SAVE_COUNT == 1 ]] || fail 'fallback candidate not saved'
[[ "$TRIES" == '1400 1360 1320 1280 ' ]] || fail "incorrect sweep: $TRIES"
TRIES='' MTU=1500 SAVED_MTU='' SAVE_COUNT=0
TEST_MODE=stuck
mtu_auto_repair test
[[ $MTU == 1500 && $SAVE_COUNT == 0 ]] || fail 'failed tuning not rolled back'
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
# An MTU saved during an earlier repair must be enforced even when the VPN
# backend is already running (no new OpenVPN process was launched).
MTU=1500 TEST_TUN_MTU=1400 TEST_MODE=healthy
mtu_auto_repair test
[[ "$MTU" == 1400 ]] || fail 'saved MTU was not applied to an already-running tunnel'
grep -Fq 'healthy:MTU=1400' "$RUN_DIR/test.mtu-check" || fail 'healthy probe did not use the saved MTU'
# Simulate OpenVPN recreating tun0 after a silent in-process reconnect.
MTU=1500 TEST_MODE=stuck
load_cfg test
mtu_apply_saved test
[[ "$MTU" == 1400 ]] || fail 'saved MTU was not restored after a reconnect'
grep -Fq 'restored:MTU=1400:previous=1500' "$RUN_DIR/test.mtu-check" || fail 'MTU restoration not reported'
# Watchdog must reconcile OpenVPN reconnects without running the HTTP probes.
grep -Fq 'mtu_apply_saved "$app" || true' "$ROOT/src/50-runtime.sh" || fail 'watchdog does not reapply saved MTU'
# Both startup paths must call the repair hook, saved values must be reused.
grep -Fq 'mtu_auto_repair "$app"' "$ROOT/src/50-runtime.sh" || fail 'interactive start missing repair'
grep -Fq 'mtu_auto_repair "$2"' "$ROOT/src/90-main.sh" || fail 'boot-time online unit missing repair'
grep -Fq 'args+=(--tun-mtu "$TUN_MTU")' "$ROOT/src/50-runtime.sh" || fail 'OpenVPN reconnect missing saved MTU'
echo 'Conditional startup MTU regression tests passed.'
