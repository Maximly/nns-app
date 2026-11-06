#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TMP/locks"
# shellcheck source=/dev/null
source "$ROOT/nns-app-install.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
key=$(python3 - <<'PY'
import base64
print(base64.b64encode(bytes(range(32))).decode())
PY
)
cat >"$TMP/plain.conf" <<EOF
[Interface]
PrivateKey = $key
Address = 10.9.0.2/32, fd00:10::2/128
DNS = 8.8.8.8

[Peer]
PublicKey = $key
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = vpn.example.com:443
PersistentKeepalive = 25
EOF
cat >"$TMP/a1.conf" <<EOF
[Interface]
PrivateKey = $key
Address = 10.9.0.3/32
Jc = 5
Jmin = 64
Jmax = 128
S1 = 30
S2 = 40
H1 = 100001
H2 = 100002
H3 = 100003
H4 = 100004

[Peer]
PublicKey = $key
AllowedIPs = 0.0.0.0/0
Endpoint = 203.0.113.8:51820
EOF
cat >"$TMP/a3.conf" <<EOF
[Interface]
PrivateKey = $key
Address = 10.9.0.4/32, fd00:10::4/128
DNS = 8.8.8.8
Jc = 3
Jmin = 40
Jmax = 250
S1 = 40
S2 = 50
S3 = 20
S4 = 15
H1 = 100000-101000
H2 = 102000-103000
H3 = 104000-105000
H4 = 106000-107000
I1 = <r 148><b 0xdeadbeef>
HeaderProtectionKey = $key
ContentPaddingAddition = 20-64
RekeyAfterTime = 100-120
RekeyTimeout = 4-7
RejectAfterTime = 170-200
KeepaliveTimeout = 9-14
MaxHandshakeAttempts = 19-36
RandomTrailers = on
DisableCookies = on

[Peer]
PublicKey = $key
AllowedIPs = 0.0.0.0/1, 128.0.0.0/1, ::/0
Endpoint = awg.example.com:443
PersistentKeepalive = 25
EOF

[[ "$(profile_type_from_file "$TMP/plain.conf")" == wireguard ]] || fail 'plain WG detected incorrectly'
[[ "$(profile_type_from_file "$TMP/a1.conf")" == amneziawg ]] || fail 'AWG 1.x not detected'
[[ "$(profile_type_from_file "$TMP/a3.conf")" == amneziawg ]] || fail 'AWG 3.1 not detected'
validate_wireguard "$TMP/plain.conf" || fail 'plain WG validation'
validate_amneziawg "$TMP/a1.conf" || fail 'AWG 1.x validation'
validate_amneziawg "$TMP/a3.conf" || fail 'AWG 3.1 validation'
if (validate_wireguard "$TMP/a3.conf") >/dev/null 2>&1; then
    fail 'AWG profile accepted as standard WireGuard'
fi
[[ "$(profile_name_from_path "$TMP/a3.conf" amneziawg)" == 'a3.conf' ]] || fail 'AWG profile name'
[[ "$(vpn_type_label amneziawg)" == AmneziaWG ]] || fail 'AWG type label'
[[ "$(profile_endpoints "$TMP/a3.conf")" == 'awg.example.com|443|udp' ]] || fail 'AWG endpoint extraction'
prepare_wireguard_runtime_config "$TMP/a3.conf" "$TMP/runtime.conf" on
for parameter in 'Jc = 3' 'I1 = <r 148><b 0xdeadbeef>' 'HeaderProtectionKey = ' \
                 'ContentPaddingAddition = 20-64' 'RandomTrailers = on' 'H1 = 100000-101000'; do
    grep -Fq "$parameter" "$TMP/runtime.conf" || fail "runtime lost $parameter"
done
! grep -Eiq '^DNS[[:space:]]*=' "$TMP/runtime.conf" || fail 'DNS unexpectedly passed to AWG'
! grep -Fq '::/0' "$TMP/runtime.conf" || fail 'IPv6 route unexpectedly passed to AWG'
! grep -Fq 'fd00:10::4' "$TMP/runtime.conf" || fail 'IPv6 address unexpectedly passed to AWG'
[[ "$(stat -c %a "$TMP/runtime.conf")" == 600 ]] || fail 'runtime file mode'

# User-managed profiles are data, never a source of shell hooks or arbitrary
# AWG device settings that would run with root privileges.
reject_change() {
    local variant=$1 before=$2 after=$3
    sed "s#${before}#${after}#" "$TMP/a3.conf" >"$TMP/$variant.conf"
    if (validate_amneziawg "$TMP/$variant.conf") >/dev/null 2>&1; then
        fail "invalid AWG $variant was accepted"
    fi
}
reject_change junk_min 'Jmin = 40' 'Jmin = 251'
reject_change overlapping_headers 'H2 = 102000-103000' 'H2 = 100500-103000'
reject_change injected_header 'H4 = 106000-107000' 'H4 = 4;touch /tmp/injection'
reject_change invalid_i1 'I1 = <r 148><b 0xdeadbeef>' 'I1 = $(id)'
reject_change invalid_hpk 'HeaderProtectionKey = ' 'INVALID = '
reject_change invalid_rekey 'RekeyAfterTime = 100-120' 'RekeyAfterTime = 200-250'
reject_change invalid_cookie 'DisableCookies = on' 'DisableCookies = nonsense'
reject_change injected_hook 'RandomTrailers = on' 'PostUp = touch /tmp/exploit'

# AWG 2.0/3.1 H1-H4 use unsigned 32-bit values; values above 2^31-1
# must pass validation, including the high H3/H4 ranges seen in the wild.
sed -e 's/H3 = 104000-105000/H3 = 2894541602-2894587236/' \
    -e 's/H4 = 106000-107000/H4 = 3771044036-3771056315/' \
    "$TMP/a3.conf" >"$TMP/unsigned-high.conf"
validate_amneziawg "$TMP/unsigned-high.conf" || fail 'valid uint32 AWG header ranges rejected'
prepare_wireguard_runtime_config "$TMP/unsigned-high.conf" "$TMP/unsigned-runtime.conf" on
grep -Fxq 'H3 = 2894541602-2894587236' "$TMP/unsigned-runtime.conf" || fail 'uint32 H3 changed at runtime'
grep -Fxq 'H4 = 3771044036-3771056315' "$TMP/unsigned-runtime.conf" || fail 'uint32 H4 changed at runtime'

sed 's/H4 = 3771044036-3771056315/H4 = 4294967295/' \
    "$TMP/unsigned-high.conf" >"$TMP/unsigned-max.conf"
validate_amneziawg "$TMP/unsigned-max.conf" || fail 'uint32 maximum not accepted'

reject_unsigned() {
    local variant=$1 before=$2 after=$3
    sed "s#${before}#${after}#" "$TMP/unsigned-high.conf" >"$TMP/$variant.conf"
    if (validate_amneziawg "$TMP/$variant.conf") >/dev/null 2>&1; then
        fail "invalid unsigned AWG $variant was accepted"
    fi
}
reject_unsigned overflow 'H3 = 2894541602-2894587236' 'H3 = 2894541602-4294967296'
reject_unsigned reversed 'H3 = 2894541602-2894587236' 'H3 = 2894587236-2894541602'
reject_unsigned overlap 'H3 = 2894541602-2894587236' 'H3 = 3771044036-3771050000'
reject_unsigned zero 'H3 = 2894541602-2894587236' 'H3 = 0-5'
reject_change timer_overflow 'RekeyTimeout = 4-7' 'RekeyTimeout = 4-65536'

# Verify that status/readiness query AWG rather than standard WireGuard.
(
    cfg_read_value() { printf 'netns-test\n'; }
    vpn_type_for_app() { printf 'amneziawg\n'; }
    wireguard_iface_name() { printf 'nwgtest\n'; }
    ip() {
        if [[ "${1:-}" == netns && "${2:-}" == exec && "${4:-}" == awg && "${5:-}" == show ]]; then
            printf 'awg show\n' >>"$TMP/ip.log"
            return 0
        fi
        if [[ "${1:-}" == netns && "${2:-}" == exec && "${4:-}" == wg && "${5:-}" == show ]]; then
            return 77
        fi
        return 0
    }
    [[ "$(vpn_route_iface testapp)" == nwgtest ]] || fail 'AWG namespace route not recognized'
)
grep -Fq 'awg show' "$TMP/ip.log" || fail 'AWG route was checked with wg instead of awg'

# The server-side code must select awg-quick, not invoke wg-quick on AWG config.
grep -Fq 'amneziawg) wg_cmd=awg; wg_quick=$(command -v awg-quick || true)' "$ROOT/src/50-runtime.sh" ||
    fail 'AWG quick backend unavailable'
grep -Fq 'wireguard|amneziawg) tunnel_iface=' "$ROOT/src/40-network.sh" || fail 'network path rejects AWG'
grep -Fq 'amneziawg) app_type=vpn-client/awg' "$ROOT/src/70-run-status.sh" || fail 'inventory type missing'

# Simulate the unit's foreground runtime against a fake awg-quick. A failed
# `up` must invoke awg-quick (never wg-quick) and clean its generated file.
mkdir -p "$TMP/bin"
for binary in awg-quick awg; do
    printf '#!/bin/sh\nexit 0\n' >"$TMP/bin/$binary"
    chmod 0755 "$TMP/bin/$binary"
done
export AWG_TEST_TMP="$TMP" AWG_TEST_PROFILE="$TMP/a3.conf"
if PATH="$TMP/bin:$PATH" bash -c '
    set -Eeuo pipefail
    export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$AWG_TEST_TMP/locks"
    source "'"$ROOT"'/nns-app-install.sh"
    load_cfg() { NS_NAME=mock-netns; }
    wireguard_runtime_config_path() { printf "%s/runawg.conf\n" "$AWG_TEST_TMP"; }
    ip() {
        if [[ "${1:-}" == netns && "${2:-}" == list ]]; then
            printf "mock-netns\n"
            return 0
        fi
        if [[ "${1:-}" == netns && "${2:-}" == exec ]]; then
            printf "%s %s\n" "${4##*/}" "${5:-}" >>"$AWG_TEST_TMP/executed"
            if [[ "${5:-}" == up ]]; then return 85; fi
        fi
        return 0
    }
    wireguard_exec testapp "$AWG_TEST_PROFILE" amneziawg
' >"$TMP/runtime-debug.log" 2>&1; then
    fail 'simulated failed AWG startup did not return a failure'
fi
grep -Fxq 'awg-quick up' "$TMP/executed" || fail 'AWG runtime did not select awg-quick'
! grep -Fxq 'wg-quick up' "$TMP/executed" || fail 'AWG runtime accidentally used wg-quick'
grep -Fxq 'awg-quick down' "$TMP/executed" || { cat "$TMP/runtime-debug.log" >&2; cat "$TMP/executed" >&2; fail 'AWG failure did not clean up with awg-quick'; }
[[ ! -e "$TMP/runawg.conf" ]] || fail 'AWG runtime profile was not removed after failure'

echo 'AmneziaWG tests passed.'
