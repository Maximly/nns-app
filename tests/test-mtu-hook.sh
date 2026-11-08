#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/src/52-mtu.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }
log() { :; }
warn() { :; }
validate_app_name() { [[ "$1" == test ]]; }
load_cfg() { NS_NAME=nns-test; TUN_MTU=${TEST_TUN_MTU-1400}; }
vpn_type_for_app() { echo openvpn; }
vpn_route_iface() { echo tun0; }
RUN_DIR=$(mktemp -d)
trap 'rm -rf "$RUN_DIR"' EXIT
MTU=1500
IP_WRITES=0
NETNS_MATCH=on
stat() {
    [[ "$1" == -Lc && "$2" == '%d:%i' ]] || fail "stat called with unexpected arguments: $*"
    case "$3" in
        /proc/self/ns/net) echo 4:10 ;;
        /run/netns/nns-test)
            if [[ "$NETNS_MATCH" == on ]]; then echo 4:10; else echo 4:11; fi ;;
        *) fail "unexpected stat path: $3" ;;
    esac
}
ip() {
    if [[ "$1" == -o && "$2" == link && "$3" == show ]]; then
        printf '2: tun0: <UP> mtu %d qdisc fq_codel\n' "$MTU"
    elif [[ "$1" == link && "$2" == set && "$3" == dev && "$4" == tun0 && "$5" == mtu ]]; then
        MTU=$6
        IP_WRITES=$((IP_WRITES + 1))
    elif [[ "$1" == -n && "$3" == -o && "$4" == link && "$5" == show ]]; then
        printf '2: tun0: <UP> mtu %d qdisc fq_codel\n' "$MTU"
    elif [[ "$1" == -n && "$3" == link && "$4" == set && "$5" == dev ]]; then
        MTU=$8
        IP_WRITES=$((IP_WRITES + 1))
    else
        fail "unexpected ip: $*"
    fi
}
mtu_openvpn_up test tun0
[[ "$MTU" == 1400 && "$IP_WRITES" == 1 ]] || fail 'OpenVPN --up did not enforce saved MTU'
mtu_openvpn_up test tun0
[[ "$IP_WRITES" == 1 ]] || fail 'OpenVPN --up wrote unchanged MTU'
NETNS_MATCH=off
MTU=1500
mtu_openvpn_up test tun0
[[ "$MTU" == 1500 ]] || fail 'callback modified interface outside named namespace'
NETNS_MATCH=on
TEST_TUN_MTU=''
mtu_openvpn_up test tun0
[[ "$MTU" == 1500 ]] || fail 'callback modified interface without saved MTU'
TEST_TUN_MTU=1400
# Independent local timer must work without a successful HTTPS probe.
mtu_https_probe() { fail 'local timer called remote HTTPS probe'; }
mtu_apply_saved() { MTU=1400; IP_WRITES=$((IP_WRITES + 1)); }
# The real timer uses a /run/netns path; replace only that environment guard
# in a disposable source copy so the rest of the fast service can be exercised.
script=$(mktemp)
sed 's@\[\[ -e "/run/netns/\$NS_NAME" \]\] || return 0@true@' "$ROOT/src/52-mtu.sh" >"$script"
source "$script"
rm -f "$script"
MTU=1500
mtu_reconcile_local test
[[ "$MTU" == 1400 ]] || fail 'independent fast service did not reconcile MTU'
# A tuning sweep already holding the lock should never be disturbed.
MTU=1500
exec {fd}>"$RUN_DIR/test.mtu-guard"
flock -x "$fd"
# flock is per-open-file-description; a separate subprocess must be unable to
# obtain the lock, but it should exit rather than wait.
(timeout 2 bash -c 'flock -n "$1" -c true' _ "$RUN_DIR/test.mtu-guard") >/dev/null 2>&1 && fail 'MTU guard unexpectedly unlocked'
flock -u "$fd"
eval "exec ${fd}>&-"
echo 'OpenVPN MTU up-hook and independent reconciliation tests passed.'
