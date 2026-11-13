#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TMP/locks"
source "$ROOT/install_linux"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
KEY=$(python3 - <<'PY'
import base64
print(base64.b64encode(bytes(range(32))).decode())
PY
)
cat > "$TMP/split-awg.conf" <<EOF_AWG
[Interface]
PrivateKey = $KEY
Address = 10.9.0.2/32
Jc = 3
Jmin = 40
Jmax = 60
S1 = 15
H1 = 12345678

[ Peer ]
PublicKey = $KEY
AllowedIPs = 10.30.0.0/16, 192.168.100.10/32
Endpoint = vpn.example.com:443
EOF_AWG
cat > "$TMP/split-wg.conf" <<EOF_WG
[Interface]
PrivateKey = $KEY
Address = 10.9.0.2/32

[Peer]
PublicKey = $KEY
AllowedIPs = 10.30.0.0/16
Endpoint = vpn.example.com:443
EOF_WG
cat > "$TMP/full-wg.conf" <<EOF_WG
[Interface]
PrivateKey = $KEY
Address = 10.9.0.2/32

[Peer]
PublicKey = $KEY
AllowedIPs = 0.0.0.0/2, 64.0.0.0/2, 128.0.0.0/2, 192.0.0.0/2
Endpoint = vpn.example.com:443
EOF_WG
cat > "$TMP/ipv6-only.conf" <<EOF_WG
[Interface]
PrivateKey = $KEY
Address = 10.9.0.2/32

[Peer]
PublicKey = $KEY
AllowedIPs = ::/0
Endpoint = vpn.example.com:443
EOF_WG
[[ $(profile_type_from_file "$TMP/split-awg.conf") == amneziawg ]] || fail 'AWG detection'
validate_amneziawg "$TMP/split-awg.conf" || fail 'AWG split validation'
validate_wireguard "$TMP/split-wg.conf" || fail 'WG split validation'
validate_wireguard "$TMP/full-wg.conf" || fail 'WG full validation'
if (validate_wireguard "$TMP/ipv6-only.conf") >/dev/null 2>&1; then fail 'IPv6 only accepted'; fi
[[ $(wireguard_profile_route_mode "$TMP/split-awg.conf") == split ]] || fail 'AWG split mode'
[[ $(wireguard_profile_route_mode "$TMP/split-wg.conf") == split ]] || fail 'WG split mode'
[[ $(wireguard_profile_route_mode "$TMP/full-wg.conf") == full ]] || fail 'four /2 cover /0'
[[ $(wireguard_profile_route_sample "$TMP/split-awg.conf") == 10.30.0.1 ]] || fail 'sample IP'
prepare_wireguard_runtime_config "$TMP/split-awg.conf" "$TMP/runtime-awg.conf" on
cmp <(grep -E '^AllowedIPs' "$TMP/split-awg.conf") <(grep -E '^AllowedIPs' "$TMP/runtime-awg.conf") || fail 'AllowedIPs mutated'

# Starting a split-tunnel must not ping 1.1.1.1 or use the public-IP service.
(
    load_cfg() { NS_NAME=mock-netns; DEFAULT_PROFILE=split-awg.conf; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    vpn_type_for_app() { printf 'amneziawg\n'; }
    cfg_read_value() { if [[ "$2" == DEFAULT_PROFILE ]]; then printf 'split-awg.conf\n'; fi; }
    wireguard_iface_name() { printf 'nwgtest\n'; }
    vpn_route_ready() { return 0; }
    ip() {
        if [[ "$1" == -n && "$2" == mock-netns && "$3" == -4 && "$4" == route && "$5" == get ]]; then
            [[ "$6" == 10.30.0.1 ]] || fail 'Wrong route probe IP'
            echo '10.30.0.1 dev nwgtest src 10.9.0.2'
            return 0
        fi
        fail "Unexpected ip call: $*"
    }
    wait_online edgewall 2 || fail 'Split route readiness fails'
)
(
    load_cfg() { NS_NAME=mock-netns; DEFAULT_PROFILE=split-awg.conf; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    vpn_type_for_app() { printf 'amneziawg\n'; }
    cfg_read_value() { if [[ "$2" == DEFAULT_PROFILE ]]; then printf 'split-awg.conf\n'; fi; }
    wireguard_iface_name() { printf 'nwgtest\n'; }
    vpn_route_ready() { return 0; }
    # Wrong route must not count as ready.
    ip() { echo '10.30.0.1 dev veth0 src 10.9.0.2'; }
    if wait_online edgewall 1; then fail 'Invalid split route accepted'; fi
)

grep -Fq 'iptables -w 5 -P OUTPUT DROP' "$ROOT/src/40-network.sh" || fail 'Kill switch unexpectedly removed'
grep -Fq 'iptables -w 5 -A OUTPUT -o "$tunnel_iface" -j ACCEPT' "$ROOT/src/40-network.sh" || fail 'Tunnel allow rule removed'
echo 'Split tunnel tests passed.'
