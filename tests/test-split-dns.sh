#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TMP/locks"
source "$ROOT/install_linux"
fail() { echo "FAIL: $*" >&2; exit 1; }
KEY=$(python3 - <<'PY'
import base64
print(base64.b64encode(bytes(range(32))).decode())
PY
)
cat >"$TMP/demo-vpn.conf" <<EOF
[Interface]
Address = 10.77.0.20/24
PrivateKey = $KEY
PostUp = resolvectl dns %i 10.77.0.53
PostUp = resolvectl domain %i '~corp.example'
PostDown = resolvectl revert %i

[Peer]
PublicKey = $KEY
AllowedIPs = 10.77.0.1/32, 10.77.0.53/32, 10.77.1.130/32
PersistentKeepalive = 60
Endpoint = 203.0.113.10:51820
EOF
validate_wireguard "$TMP/demo-vpn.conf" || fail 'rejected legitimate wg-quick DNS hooks'
[[ "$(wireguard_profile_dns_policy "$TMP/demo-vpn.conf")" == $'10.77.0.53\ncorp.example' ]] || fail 'wrong DNS policy extraction'
[[ "$(wireguard_profile_route_mode "$TMP/demo-vpn.conf")" == split ]] || fail 'split routes changed'
prepare_wireguard_runtime_config "$TMP/demo-vpn.conf" "$TMP/runtime.conf" on
grep -Fq 'AllowedIPs = 10.77.0.1/32, 10.77.0.53/32, 10.77.1.130/32' "$TMP/runtime.conf" || fail 'AllowedIPs changed'
! grep -Eiq '^[[:space:]]*Post(Up|Down)[[:space:]]*=' "$TMP/runtime.conf" || fail 'hooks leaked to runtime wg-quick'
grep -Fq 'for field in "${private_servers[@]}"' "$ROOT/src/40-network.sh" || fail 'private DNS egress not pinned to tunnel'

# The import must reject dangerous changes even if they contain a known command.
cp "$TMP/demo-vpn.conf" "$TMP/unsafe.conf"
sed -i 's/resolvectl dns %i 10.77.0.53/resolvectl dns %i 10.77.0.53; touch \/tmp\/nns-bad/' "$TMP/unsafe.conf"
if (validate_wireguard "$TMP/unsafe.conf") >/dev/null 2>&1; then fail 'unsafe shell accepted'; fi
cp "$TMP/demo-vpn.conf" "$TMP/unsafe.conf"
sed -i 's/PostDown = resolvectl revert %i/PostDown = rm -rf \/tmp/' "$TMP/unsafe.conf"
if (validate_wireguard "$TMP/unsafe.conf") >/dev/null 2>&1; then fail 'arbitrary PostDown accepted'; fi
cp "$TMP/demo-vpn.conf" "$TMP/unsafe.conf"
sed -i 's/~corp.example/~corp.example;curl example.org/' "$TMP/unsafe.conf"
if (validate_wireguard "$TMP/unsafe.conf") >/dev/null 2>&1; then fail 'unsafe split DNS suffix accepted'; fi
cp "$TMP/demo-vpn.conf" "$TMP/unsafe.conf"
sed -i 's/10.77.0.53\/32/10.77.0.54\/32/' "$TMP/unsafe.conf"
if (validate_wireguard "$TMP/unsafe.conf") >/dev/null 2>&1; then fail 'DNS outside AllowedIPs accepted'; fi
cp "$TMP/demo-vpn.conf" "$TMP/unsafe.conf"
sed -i '/^PostDown =/d' "$TMP/unsafe.conf"
if (validate_wireguard "$TMP/unsafe.conf") >/dev/null 2>&1; then fail 'incomplete lifecycle accepted'; fi
cp "$TMP/demo-vpn.conf" "$TMP/unsafe.conf"
sed -i '/^PostUp = resolvectl domain/d' "$TMP/unsafe.conf"
if (validate_wireguard "$TMP/unsafe.conf") >/dev/null 2>&1; then fail 'DNS without domain accepted'; fi
# The exact supported hooks also work for AmneziaWG.
validate_amneziawg "$TMP/demo-vpn.conf" || fail 'legitimate AmneziaWG DNS policy rejected'

# Standard wg-quick DNS= must be effective, not accepted and silently ignored.
cat >"$TMP/demo-vpn-dns.conf" <<EOF
[Interface]
Address = 10.77.0.20/24
PrivateKey = $KEY
DNS = 10.77.0.53, corp.example

[Peer]
PublicKey = $KEY
AllowedIPs = 10.77.0.1/32, 10.77.0.0/24
Endpoint = 203.0.113.10:51820
EOF
validate_wireguard "$TMP/demo-vpn-dns.conf" || fail 'rejected standard WireGuard DNS setting'
validate_amneziawg "$TMP/demo-vpn-dns.conf" || fail 'rejected standard AmneziaWG DNS setting'
[[ "$(wireguard_profile_dns_policy "$TMP/demo-vpn-dns.conf")" == $'10.77.0.53\n.' ]] || fail 'standard DNS= did not select all DNS through VPN'
[[ "$(wireguard_profile_dns_policy "$TMP/demo-vpn-dns.conf" search)" == 'corp.example' ]] || fail 'missing DNS search domain'
[[ "$(wireguard_profile_route_mode "$TMP/demo-vpn-dns.conf")" == split ]] || fail 'standard DNS changed split routes'
prepare_wireguard_runtime_config "$TMP/demo-vpn-dns.conf" "$TMP/runtime-dns.conf" on
! grep -Eiq '^[[:space:]]*DNS[[:space:]]*=' "$TMP/runtime-dns.conf" || fail 'DNS leaked into wg-quick runtime'
grep -Fq 'search_domains=$(wireguard_profile_dns_policy "$profile" search)' "$ROOT/src/40-network.sh" || fail 'DNS search suffix not wired into resolver'
grep -Fq 'ensure_snap_dns_proxy "$app"' "$ROOT/src/40-network.sh" || fail 'DNS proxy not started during namespace initialization'

# Accept an explicit route-only DNS= suffix without adding it to search.
sed 's/, corp.example/, ~corp.example/' "$TMP/demo-vpn-dns.conf" >"$TMP/route-dns.conf"
validate_wireguard "$TMP/route-dns.conf" || fail 'rejected DNS= route-only suffix'
[[ "$(wireguard_profile_dns_policy "$TMP/route-dns.conf")" == $'10.77.0.53\ncorp.example' ]] || fail 'route-only DNS= classification wrong'
[[ -z "$(wireguard_profile_dns_policy "$TMP/route-dns.conf" search)" ]] || fail 'route-only domain unexpectedly became search suffix'

# DNS= must fail closed on commands, duplicate options, mixed hooks, and
# nameserver addresses not covered by AllowedIPs.
sed 's/DNS = 10.77.0.53, corp.example/DNS = 10.78.0.11, corp.example/' "$TMP/demo-vpn-dns.conf" >"$TMP/invalid-dns.conf"
if (validate_wireguard "$TMP/invalid-dns.conf") >/dev/null 2>&1; then fail 'DNS server outside AllowedIPs accepted'; fi
sed 's/DNS = 10.77.0.53, corp.example/DNS = 10.77.0.53; touch \/tmp\/nns-unsafe/' "$TMP/demo-vpn-dns.conf" >"$TMP/invalid-dns.conf"
if (validate_wireguard "$TMP/invalid-dns.conf") >/dev/null 2>&1; then fail 'DNS= command injection accepted'; fi
sed '/^DNS =/a DNS = 10.77.0.53' "$TMP/demo-vpn-dns.conf" >"$TMP/invalid-dns.conf"
if (validate_wireguard "$TMP/invalid-dns.conf") >/dev/null 2>&1; then fail 'duplicate DNS= accepted'; fi
sed '/^PostUp = resolvectl dns %i/a DNS = 10.77.0.53' "$TMP/demo-vpn.conf" >"$TMP/invalid-dns.conf"
if (validate_wireguard "$TMP/invalid-dns.conf") >/dev/null 2>&1; then fail 'mixed hook and DNS= accepted'; fi

# Test the packet-level suffix dispatcher without binding port 53 or needing root.
python3 - "$ROOT/src/70-run-status.sh" <<'PY'
import pathlib, struct, sys
src = pathlib.Path(sys.argv[1]).read_text()
preamble = src.split("<<'PY_NNS_DNS_PROXY'\n", 1)[1].split('\nPY_NNS_DNS_PROXY', 1)[0]
code = preamble.split('udp_server = ThreadingUDPServer(', 1)[0]
sys.argv = ['proxy', '1.1.1.1 9.9.9.9', '10.77.0.53', 'corp.example']
scope = {}
exec(code, scope)

def query(name):
    qname = b''.join(bytes([len(l)])+l.encode('ascii') for l in name.split('.'))+b'\0'
    return struct.pack('!HHHHHH', 123, 0x0100, 1, 0, 0, 0) + qname + struct.pack('!HH', 1, 1)

upstreams = scope['dns_upstreams']
for name in ('corp.example', 'host.corp.example', 'Host.CoRp.ExAmPlE'):
    assert upstreams(query(name)) == [('10.77.0.53', 53)], name
for name in ('other.loc', 'notcorp.example', 'corp.example.evil.com'):
    assert upstreams(query(name)) == [('1.1.1.1', 53), ('9.9.9.9', 53)], name
assert upstreams(struct.pack('!HHHHHH', 123, 0x0100, 1, 0, 0, 0) + b'\xc0\x0c' + struct.pack('!HH',1,1)) == []
assert upstreams(b'\0'*12) == []
# No fallback to public DNS for a matching suffix, even if its server fails.
sys.argv = ['proxy', '1.1.1.1', '', '']
scope = {}
exec(code, scope)
assert scope['dns_upstreams'](query('corp.example')) == [('1.1.1.1', 53)]
# Standard DNS= sends all names through the profile resolver.
sys.argv = ['proxy', '1.1.1.1 9.9.9.9', '10.77.0.53', '.']
scope = {}
exec(code, scope)
assert scope['dns_upstreams'](query('corp.example')) == [('10.77.0.53', 53)]
assert scope['dns_upstreams'](query('ya.ru')) == [('10.77.0.53', 53)]
assert scope['dns_upstreams'](query('notcorp.example')) == [('10.77.0.53', 53)]
PY

echo 'Split DNS tests passed.'
