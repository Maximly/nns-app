#!/bin/bash
# Run on Linux CI as well as Darwin; no network interfaces are modified.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
bash -n "$ROOT/nns-app-darwin.sh"
bash -n "$ROOT/install.sh"
for forbidden in 'pfctl' 'networksetup' 'dseditgroup' 'scutil --set' 'iptables' 'ip netns' 'launchctl'; do
  if grep -Fq "$forbidden" "$ROOT/nns-app-darwin.sh"; then
    echo "Unexpected host-affecting macOS command: $forbidden" >&2; exit 1
  fi
done
grep -Fq -- '-ifscope "$UTUN"' "$ROOT/nns-app-darwin.sh"
grep -Fq 'DYLD_INTERPOSE(nns_connect, connect)' "$ROOT/src/libnnsbind.c"
grep -Fq 'DYLD_INTERPOSE(nns_getaddrinfo, getaddrinfo)' "$ROOT/src/libnnsbind.c"
if command -v clang >/dev/null 2>&1; then
  clang -D_DARWIN_C_SOURCE -Wall -Wextra -Werror -std=c11 -fsyntax-only "$ROOT/src/libnnsbind.c" "$ROOT/src/nns-run.c"
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

[[ "$(bash "$ROOT/nns-app-darwin.sh" list)" == 'No apps configured.' ]] || {
  echo 'list not empty after remove' >&2; exit 1
}
echo 'macOS static + mock CLI tests passed.'
