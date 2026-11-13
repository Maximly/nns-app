#!/bin/bash
# Run on Linux CI as well as Darwin; no network interfaces are modified.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
REPO=$(cd "$ROOT/.." && pwd -P)
EXPECTED_VERSION=$(tr -d '[:space:]\r' < "$REPO/VERSION")
bash -n "$ROOT/nns-app-darwin.sh"
bash -n "$ROOT/install.sh"
# Source-tree CLI must resolve version from VERSION (placeholder still present).
grep -Fq '@@NNS_VERSION@@' "$ROOT/nns-app-darwin.sh"
got=$(bash "$ROOT/nns-app-darwin.sh" --version)
grep -Fq "nns-app $EXPECTED_VERSION" <<<"$got" || {
  echo "darwin --version mismatch: $got (expected $EXPECTED_VERSION)" >&2; exit 1
}
for forbidden in 'pfctl' 'networksetup' 'dseditgroup' 'scutil --set' 'iptables' 'ip netns' 'launchctl'; do
  if grep -Fq "$forbidden" "$ROOT/nns-app-darwin.sh"; then
    echo "Unexpected host-affecting macOS command: $forbidden" >&2; exit 1
  fi
done
grep -Fq -- '-ifscope "$UTUN"' "$ROOT/nns-app-darwin.sh"
grep -Fq 'DYLD_INTERPOSE(nns_connect, connect)' "$ROOT/src/libnnsbind.c"
grep -Fq 'DYLD_INTERPOSE(nns_getaddrinfo, getaddrinfo)' "$ROOT/src/libnnsbind.c"
grep -Fq 'nns_ipv4_is_host_local' "$ROOT/src/nns_net.h"
grep -Fq '#include "nns_net.h"' "$ROOT/src/libnnsbind.c"
grep -Fq '#include "nns_net.h"' "$ROOT/src/nns-run.c"
grep -Fq 'nns_add_bind_args' "$ROOT/src/nns-run.c"
grep -Fq 'BindAddress=' "$ROOT/src/nns-run.c"
grep -Fq '"--interface"' "$ROOT/src/nns-run.c"
# Shared IPv4 policy must live in the header, not be re-defined per TU.
if grep -En 'NNS_IPV4_LINKLOCAL_NET|enum nns_ipv4_class' \
     "$ROOT/src/libnnsbind.c" "$ROOT/src/nns-run.c" | grep -v 'nns_net.h'; then
  echo 'IPv4 class constants must come from nns_net.h only' >&2; exit 1
fi
if command -v clang >/dev/null 2>&1; then
  clang -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -std=c11 -fsyntax-only \
    "$ROOT/src/libnnsbind.c" "$ROOT/src/nns-run.c"
fi
# Mock Darwin only for configuration lifecycle; never start a VPN in CI.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/fake" "$T/home"
cat > "$T/fake/uname" <<'S'
#!/bin/sh
echo Darwin
S
cat > "$T/fake/id" <<'S'
#!/bin/sh
case "$1" in -un) echo testuser;; -u) echo 1077;; *) /usr/bin/id "$@";; esac
S
cat > "$T/fake/dscl" <<'S'
#!/bin/sh
printf 'NFSHomeDirectory: %s\n' "$NNS_MAC_TEST_HOME"
S
chmod +x "$T/fake/"*
cat > "$T/test.conf" <<'S'
[Interface]
PrivateKey = 0000000000000000000000000000000000000000000=
Address = 10.7.0.2/32
DNS = 10.7.0.1
[Peer]
PublicKey = 1111111111111111111111111111111111111111111=
AllowedIPs = 10.7.0.1/32
Endpoint = 203.0.113.7:51820
S
export NNS_MAC_TEST_HOME="$T/home"
export PATH="$T/fake:$PATH"
[[ "$(bash "$ROOT/nns-app-darwin.sh" list)" == 'No apps configured.' ]] || {
  echo 'empty list message mismatch' >&2; exit 1
}
bash "$ROOT/nns-app-darwin.sh" install testvpn
# install-only apps must list cleanly with no profile.conf yet
output=$(bash "$ROOT/nns-app-darwin.sh" list 2>"$T/list.err")
[ ! -s "$T/list.err" ] || { echo "list stderr: $(cat "$T/list.err")" >&2; exit 1; }
grep -Eq 'testvpn[[:space:]]+vpn-client/wg[[:space:]]+stopped[[:space:]]+host[[:space:]]+none \| -' <<<"$output" || {
  echo "install-only list mismatch: $output" >&2; exit 1
}
bash "$ROOT/nns-app-darwin.sh" add testvpn "$T/test.conf"
bash "$ROOT/nns-app-darwin.sh" status testvpn | grep -q stopped
bash "$ROOT/nns-app-darwin.sh" dns testvpn 10.7.0.3
output=$(bash "$ROOT/nns-app-darwin.sh" list)
grep -Fq 'Apps:' <<<"$output" || { echo 'list missing Apps header' >&2; exit 1; }
grep -Fq 'Name' <<<"$output" || { echo 'list missing column header' >&2; exit 1; }
grep -Eq 'testvpn[[:space:]]+vpn-client/wg[[:space:]]+stopped[[:space:]]+host' <<<"$output" || {
  echo "list row mismatch: $output" >&2; exit 1
}
grep -Fq 'dns 10.7.0.3' <<<"$output" || { echo 'list missing DNS override' >&2; exit 1; }
grep -Fq 'local' <<<"$output" || { echo 'list missing source' >&2; exit 1; }
bash "$ROOT/nns-app-darwin.sh" remove testvpn
[ ! -d "$T/home/Library/Application Support/nns-app/apps/testvpn" ]

# resolvectl DNS hooks: accept, strip, persist DNS (Linux-compatible policy).
cat > "$T/hooks.conf" <<'S'
[Interface]
PrivateKey = 0000000000000000000000000000000000000000000=
Address = 10.7.0.2/32
PostUp = resolvectl dns %i 192.168.83.10
PostUp = resolvectl domain %i '~promobit.loc'
PostDown = resolvectl revert %i
[Peer]
PublicKey = 1111111111111111111111111111111111111111111=
AllowedIPs = 10.7.0.1/32
Endpoint = 203.0.113.7:51820
S
bash "$ROOT/nns-app-darwin.sh" install hookvpn
bash "$ROOT/nns-app-darwin.sh" add hookvpn "$T/hooks.conf"
CONF="$T/home/Library/Application Support/nns-app/apps/hookvpn/profile.conf"
! grep -Eiq '^[[:space:]]*Post(Up|Down)[[:space:]]*=' "$CONF" || {
  echo 'hooks leaked into stored profile' >&2; exit 1
}
[[ "$(cat "$T/home/Library/Application Support/nns-app/apps/hookvpn/dns_ipv4")" == 192.168.83.10 ]] || {
  echo 'hook DNS was not imported' >&2; exit 1
}
cat > "$T/bad-hooks.conf" <<'S'
[Interface]
PrivateKey = 0000000000000000000000000000000000000000000=
Address = 10.7.0.2/32
PreUp = /bin/true
[Peer]
PublicKey = 1111111111111111111111111111111111111111111=
AllowedIPs = 10.7.0.1/32
Endpoint = 203.0.113.7:51820
S
if bash "$ROOT/nns-app-darwin.sh" add hookvpn "$T/bad-hooks.conf" 2>"$T/bad.err"; then
  echo 'PreUp hook was accepted' >&2; exit 1
fi
grep -Eiq 'PreUp|not supported' "$T/bad.err" || {
  echo "bad hook error missing: $(cat "$T/bad.err")" >&2; exit 1
}
bash "$ROOT/nns-app-darwin.sh" remove hookvpn

# OpenVPN .ovpn import: accept inline profile, extract dhcp-option DNS, reject scripts.
cat > "$T/good.ovpn" <<'S'
client
dev tun
proto udp
remote 203.0.113.50 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
dhcp-option DNS 10.9.0.1
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIIB
-----END PRIVATE KEY-----
</key>
S
# Prose notes that collide with OpenVPN options (e.g. "Remote host...") must
# be commented out during import, not treated as directives.
cat > "$T/prose.ovpn" <<'S'
# header
Remote host firewall access for 21895/tcp is managed by nns-app.
WARNING: External cloud security groups must still allow tcp port 21895.
client
dev tun
proto tcp-client
remote 203.0.113.50 21895
nobind
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIIB
-----END PRIVATE KEY-----
</key>
S
bash "$ROOT/nns-app-darwin.sh" install prosevpn
bash "$ROOT/nns-app-darwin.sh" add prosevpn "$T/prose.ovpn"
PROSE="$T/home/Library/Application Support/nns-app/apps/prosevpn/profile.ovpn"
grep -E '^# Remote host firewall' "$PROSE" || {
  echo 'prose Remote line was not commented' >&2; exit 1
}
grep -E '^# WARNING:' "$PROSE" || {
  echo 'prose WARNING line was not commented' >&2; exit 1
}
grep -Eq '^remote 203\.0\.113\.50 21895$' "$PROSE" || {
  echo 'real remote directive lost' >&2; exit 1
}
bash "$ROOT/nns-app-darwin.sh" remove prosevpn

bash "$ROOT/nns-app-darwin.sh" install ovpnvpn
bash "$ROOT/nns-app-darwin.sh" add ovpnvpn "$T/good.ovpn"
OVPN_PROF="$T/home/Library/Application Support/nns-app/apps/ovpnvpn/profile.ovpn"
grep -Eq '^# persist-key' "$OVPN_PROF" || {
  echo 'deprecated persist-key was not commented out' >&2; exit 1
}
[[ "$(cat "$T/home/Library/Application Support/nns-app/apps/ovpnvpn/type")" == openvpn ]] || {
  echo 'openvpn type not stored' >&2; exit 1
}
[[ -f "$T/home/Library/Application Support/nns-app/apps/ovpnvpn/profile.ovpn" ]] || {
  echo 'profile.ovpn missing' >&2; exit 1
}
[[ "$(cat "$T/home/Library/Application Support/nns-app/apps/ovpnvpn/dns_ipv4")" == 10.9.0.1 ]] || {
  echo 'ovpn dhcp-option DNS not imported' >&2; exit 1
}
output=$(bash "$ROOT/nns-app-darwin.sh" list)
grep -Eq 'ovpnvpn[[:space:]]+vpn-client/ovpn[[:space:]]+stopped[[:space:]]+host' <<<"$output" || {
  echo "ovpn list row mismatch: $output" >&2; exit 1
}
grep -Fq 'dns 10.9.0.1' <<<"$output" || { echo 'ovpn list missing DNS' >&2; exit 1; }
bash "$ROOT/nns-app-darwin.sh" status ovpnvpn | grep -q 'vpn-client/ovpn' || {
  echo 'ovpn status missing type' >&2; exit 1
}
cat > "$T/bad.ovpn" <<'S'
client
dev tun
remote 203.0.113.50 1194
up /bin/true
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIIB
-----END PRIVATE KEY-----
</key>
S
if bash "$ROOT/nns-app-darwin.sh" add ovpnvpn "$T/bad.ovpn" 2>"$T/bad-ovpn.err"; then
  echo 'OpenVPN up script was accepted' >&2; exit 1
fi
grep -Eiq 'unsafe|up' "$T/bad-ovpn.err" || {
  echo "bad ovpn error missing: $(cat "$T/bad-ovpn.err")" >&2; exit 1
}
bash "$ROOT/nns-app-darwin.sh" remove ovpnvpn

[[ "$(bash "$ROOT/nns-app-darwin.sh" list)" == 'No apps configured.' ]] || {
  echo 'list not empty after remove' >&2; exit 1
}
# The launcher supplies native bind options to SIP-protected tools that
# cannot receive the DYLD interposer. Fake commands make this deterministic.
if [ "$(uname -s)" = Darwin ] && [ -x "$ROOT/bin/nns-run" ] && [ -r "$ROOT/bin/libnnsbind.dylib" ]; then
  SHIM="$T/shim"
  mkdir -p "$SHIM"
  for name in ping nc ssh scp sftp curl dig traceroute wget rsync openssl git host; do
    cat > "$SHIM/$name" <<'SH'
#!/bin/sh
printf '%s\n' "$@"
SH
    chmod +x "$SHIM/$name"
  done

  run_shim() {
    "$ROOT/bin/nns-run" --vpn-ip 10.0.0.2 --vpn-if utun9 \
      --lib "$ROOT/bin/libnnsbind.dylib" -- "$@"
  }

  check_shim() {
    local label=$1 expected=$2 actual
    shift 2
    actual=$(run_shim "$@" 2>/dev/null) || {
      echo "launcher shim '$label' failed" >&2; exit 1
    }
    [ "$actual" = "$expected" ] || {
      printf 'launcher shim %s mismatch\nwant:\n%s\ngot:\n%s\n' \
        "$label" "$expected" "$actual" >&2
      exit 1
    }
  }

  check_shim ping $'-b\nutun9\n-c\n1\n10.0.0.1' "$SHIM/ping" -c 1 10.0.0.1
  check_shim ping-local $'-c\n1\n127.0.0.1' "$SHIM/ping" -c 1 127.0.0.1
  check_shim ping-user-bind $'-S\n192.0.2.1\n10.0.0.1' "$SHIM/ping" -S 192.0.2.1 10.0.0.1
  check_shim nc $'-b\nutun9\n-vz\n10.0.0.1\n22' "$SHIM/nc" -vz 10.0.0.1 22
  check_shim nc-listen $'-l\n8080' "$SHIM/nc" -l 8080
  check_shim nc-timeout $'-b\nutun9\n-w\n2\n10.0.0.1\n22' "$SHIM/nc" -w 2 10.0.0.1 22
  check_shim nc-unix $'-U\n/tmp/nns.sock' "$SHIM/nc" -U /tmp/nns.sock
  check_shim ssh $'-b\n10.0.0.2\nuser@10.0.0.1' "$SHIM/ssh" user@10.0.0.1
  check_shim ssh-local $'localhost' "$SHIM/ssh" localhost
  check_shim ssh-forward $'-b\n10.0.0.2\n-L\n8080:localhost:80\nuser@10.0.0.1' \
    "$SHIM/ssh" -L 8080:localhost:80 user@10.0.0.1
  check_shim ssh-remote-b $'-b\n10.0.0.2\nhost\necho\n-b' "$SHIM/ssh" host echo -b
  check_shim scp $'-o\nBindAddress=10.0.0.2\nfile\nuser@10.0.0.1:/tmp' \
    "$SHIM/scp" file user@10.0.0.1:/tmp
  check_shim scp-local $'file\nlocalhost:/tmp' "$SHIM/scp" file localhost:/tmp
  check_shim sftp $'-o\nBindAddress=10.0.0.2\nuser@10.0.0.1' "$SHIM/sftp" user@10.0.0.1
  check_shim curl $'--interface\nutun9\nhttps://example.com' "$SHIM/curl" https://example.com
  check_shim curl-local $'http://127.0.0.1:8080' "$SHIM/curl" http://127.0.0.1:8080
  check_shim curl-mixed $'--interface\nutun9\nhttps://example.com\n--referer\nhttp://localhost' \
    "$SHIM/curl" https://example.com --referer http://localhost
  check_shim curl-query $'--interface\nutun9\nhttps://example.com?next=@localhost' \
    "$SHIM/curl" 'https://example.com?next=@localhost'
  check_shim dig $'-b\n10.0.0.2\n@10.0.0.1\nexample.com' "$SHIM/dig" @10.0.0.1 example.com
  check_shim dig-local $'@127.0.0.1\nexample.com' "$SHIM/dig" @127.0.0.1 example.com
  check_shim traceroute $'-s\n10.0.0.2\n10.0.0.1' "$SHIM/traceroute" 10.0.0.1
  check_shim traceroute-local $'127.0.0.1' "$SHIM/traceroute" 127.0.0.1
  check_shim wget $'--bind-address=10.0.0.2\nhttps://example.com' \
    "$SHIM/wget" https://example.com
  check_shim wget-user $'--bind-address=192.0.2.9\nhttps://example.com' \
    "$SHIM/wget" --bind-address=192.0.2.9 https://example.com
  check_shim rsync $'--address=10.0.0.2\nhost:file\n.' \
    "$SHIM/rsync" host:file .
  check_shim openssl $'s_client\n-bind\n10.0.0.2:0\n-connect\n10.0.0.1:443' \
    "$SHIM/openssl" s_client -connect 10.0.0.1:443
  check_shim untouched $'hello' /bin/echo hello

  # git gets a warning and no bind argv rewrite.
  git_out=$(run_shim "$SHIM/git" pull 2>"$T/git-via.warn") || {
    echo 'git shim failed' >&2; exit 1
  }
  [ "$git_out" = pull ] || { echo "git shim argv mismatch: $git_out" >&2; exit 1; }
  grep -Eiq 'git-via' "$T/git-via.warn" || {
    echo "git warning missing: $(cat "$T/git-via.warn")" >&2; exit 1
  }

  # Apple platform tools without a recipe should warn (use real /usr/bin/host).
  if [ -x /usr/bin/host ]; then
    NNS_BIND_QUIET= /usr/bin/true  # keep shell happy
    if run_shim /usr/bin/host example.com >/dev/null 2>"$T/host.warn"; then
      :
    fi
    # host may fail DNS; warning must still appear on stderr from nns-run.
    "$ROOT/bin/nns-run" --vpn-ip 10.0.0.2 --vpn-if utun9 \
      --lib "$ROOT/bin/libnnsbind.dylib" -- /usr/bin/host example.com \
      >/dev/null 2>"$T/host.warn" || true
    grep -Eiq 'platform binary|SIP' "$T/host.warn" || {
      echo "host SIP warning missing: $(cat "$T/host.warn")" >&2; exit 1
    }
    NNS_BIND_QUIET=1 "$ROOT/bin/nns-run" --vpn-ip 10.0.0.2 --vpn-if utun9 \
      --lib "$ROOT/bin/libnnsbind.dylib" -- /usr/bin/host example.com \
      >/dev/null 2>"$T/host.quiet" || true
    if grep -Eiq 'platform binary|SIP' "$T/host.quiet"; then
      echo 'NNS_BIND_QUIET did not suppress warning' >&2; exit 1
    fi
  fi

  if run_shim "$SHIM/ping6" ::1 >/dev/null 2>&1; then
    echo 'IPv6 ping was allowed through the IPv4-only launcher' >&2; exit 1
  fi
fi

echo 'macOS static + mock CLI tests passed.'
