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
grep -Fq 'normalize_oc_profile' "$ROOT/nns-app-darwin.sh"
grep -Fq 'write_oc_hook' "$ROOT/nns-app-darwin.sh"
grep -Fq -- '--passwd-on-stdin' "$ROOT/nns-app-darwin.sh"
grep -Fq -- '--cookie-on-stdin' "$ROOT/nns-app-darwin.sh"
grep -Fq 'vpn-client/oc' "$ROOT/nns-app-darwin.sh"
grep -Fq 'openconnect_bin' "$ROOT/nns-app-darwin.sh"
grep -Fq 'oc-login' "$ROOT/nns-app-darwin.sh"
grep -Fq 'oc_obtain_cookie' "$ROOT/nns-app-darwin.sh" || {
  echo 'macOS start does not auto-obtain the session cookie' >&2; exit 1
}
grep -Fq 'engine_alive' "$ROOT/nns-app-darwin.sh" || {
  echo 'macOS backend lacks the engine-aliveness guard' >&2; exit 1
}
grep -Fq 'STALE (the VPN engine exited' "$ROOT/nns-app-darwin.sh" || {
  echo 'macOS status does not report stale engine state' >&2; exit 1
}
grep -Fq 'ensure_engine_running' "$ROOT/nns-app-darwin.sh" || {
  echo 'macOS run/git does not self-heal stale apps' >&2; exit 1
}
grep -Fq 'Clearing stale runtime state' "$ROOT/nns-app-darwin.sh" || {
  echo 'macOS start does not clear its own stale runtime state' >&2; exit 1
}
grep -Fq 'lstart' "$ROOT/nns-app-darwin.sh" || {
  echo 'engine identity check does not record/compare start times' >&2; exit 1
}
grep -Fq 'app_runtime_stale' "$ROOT/nns-app-darwin.sh" || {
  echo 'macOS backend lacks the comprehensive staleness predicate' >&2; exit 1
}
grep -Fq 'resolve_conflicting_address' "$ROOT/nns-app-darwin.sh" || {
  echo 'macOS start lacks the duplicate-address resolver' >&2; exit 1
}
grep -Fq 'engine_alive_in' "$ROOT/nns-app-darwin.sh" || {
  echo 'start sweep is not identity-aware' >&2; exit 1
}
grep -Fq 'ps -o pid=' "$ROOT/nns-app-darwin.sh" || {
  echo 'engine liveness depends on signalling rights' >&2; exit 1
}
grep -Fq 'chmod 644 "$RUNSTATE/ovpn_lstart"' "$ROOT/nns-app-darwin.sh" || {
  echo 'engine identity file is not owner-readable' >&2; exit 1
}
grep -Fq 'chmod 644 "$RUNSTATE/ovpn.log"' "$ROOT/nns-app-darwin.sh" || {
  echo 'engine log is not owner-readable' >&2; exit 1
}
grep -Fq 'sudo -n tail -20' "$ROOT/nns-app-darwin.sh" || {
  echo 'log dump lacks the root fallback' >&2; exit 1
}
grep -Fq 'ps -o command= -p "$pid"' "$ROOT/nns-app-darwin.sh" || {
  echo 'engine identity fallback no longer checks the command line' >&2; exit 1
}
if grep -Fq -- '--setenv NNS_APP_MARK' "$ROOT/nns-app-darwin.sh"; then
  grep -Fq -- 'openvpn' "$ROOT/nns-app-darwin.sh" || :
fi
grep -Fq -- '--no-dtls' "$ROOT/nns-app-darwin.sh" || {
  echo 'macOS start does not support dtls=off' >&2; exit 1
}
grep -Fq -- '--disable-ipv6' "$ROOT/nns-app-darwin.sh" || {
  echo 'macOS start does not enforce the IPv4-only tunnel' >&2; exit 1
}
grep -Fq -- '--queue-len 8' "$ROOT/nns-app-darwin.sh" || {
  echo 'macOS start does not disable vhost-net' >&2; exit 1
}
# The start loop must abort only on terminal failures, never on the benign
# multi-attempt form noise ("Login failed.") or the trust-check fallback.
if grep -Fq 'Login failed|Failed to obtain WebVPN' "$ROOT/nns-app-darwin.sh"; then
  echo 'macOS start still aborts on benign form noise' >&2; exit 1
fi
grep -Fq 'Failed to complete authentication' "$ROOT/nns-app-darwin.sh" || {
  echo 'macOS start lost its terminal auth-failure detection' >&2; exit 1
}
if grep -Fq 'has_command openconnect || packages' "$ROOT/install.sh"; then
  echo 'install_macos still auto-installs openconnect' >&2; exit 1
fi
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
[ ! -f "$T/home/Library/Application Support/nns-app/apps/ovpnvpn/dns_domains" ] || {
  echo 'plain ovpn import must not create a split-domain scope' >&2; exit 1
}
grep -Eq '^# dhcp-option' "$OVPN_PROF" || {
  echo 'dhcp-option was not neutralized in the stored profile' >&2; exit 1
}
if grep -Eq '^dhcp-option' "$OVPN_PROF"; then
  echo 'active dhcp-option leaked into stored profile (would hijack system DNS)' >&2; exit 1
fi
output=$(bash "$ROOT/nns-app-darwin.sh" list)
grep -Eq 'ovpnvpn[[:space:]]+vpn-client/ovpn[[:space:]]+stopped[[:space:]]+host' <<<"$output" || {
  echo "ovpn list row mismatch: $output" >&2; exit 1
}
grep -Fq 'dns 10.9.0.1' <<<"$output" || { echo 'ovpn list missing DNS' >&2; exit 1; }
bash "$ROOT/nns-app-darwin.sh" status ovpnvpn | grep -q 'vpn-client/ovpn' || {
  echo 'ovpn status missing type' >&2; exit 1
}
# Private-only gateway export: dhcp-option DOMAIN becomes the split-DNS scope,
# so only matching domains use the per-app VPN resolver and public names keep
# the system resolver.
cat > "$T/private.ovpn" <<'S'
# nns-app private-only: client-side routes below, no redirect-gateway
client
dev tun
proto udp
remote 135.106.161.67 1197
nobind
remote-cert-tls server
route 192.168.83.0 255.255.255.0
dhcp-option DNS 192.168.83.10
dhcp-option DOMAIN promobit.loc
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
bash "$ROOT/nns-app-darwin.sh" install privatevpn
bash "$ROOT/nns-app-darwin.sh" add privatevpn "$T/private.ovpn"
PRIV_CFG="$T/home/Library/Application Support/nns-app/apps/privatevpn"
[[ "$(cat "$PRIV_CFG/dns_ipv4")" == 192.168.83.10 ]] || {
  echo 'private profile DNS not imported' >&2; exit 1
}
[[ "$(cat "$PRIV_CFG/dns_domains")" == promobit.loc ]] || {
  echo 'private profile split domains not imported' >&2; exit 1
}
grep -Fq 'NNS_DNS_DOMAINS' "$ROOT/nns-app-darwin.sh" || {
  echo 'interposer domain scope not exported' >&2; exit 1
}
grep -Fq -- '--pull-filter ignore dhcp-option' "$ROOT/nns-app-darwin.sh" || {
  echo 'pushed dhcp-option not filtered from OpenVPN' >&2; exit 1
}
if grep -Eq '^dhcp-option' "$PRIV_CFG/profile.ovpn"; then
  echo 'private profile kept an active dhcp-option (would hijack system DNS)' >&2; exit 1
fi
bash "$ROOT/nns-app-darwin.sh" remove privatevpn
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

# AnyConnect .oc import: nns-app key=value profiles; allow-list enforced,
# inline credentials accepted, type stored, stale backend files removed.
cat > "$T/corp.oc" <<'S'
# Corporate AnyConnect gateway
protocol=anyconnect
server=https://vpn.example.com
user=employee
passwd=correct horse battery staple
authgroup=Employees
route-mode=split
S
cat > "$T/certs.oc" <<'S'
server=https://vpn.example.com:8443
user=employee
password=secret
fingerprint=SHA1:AA:BB:CC:DD:EE:FF:11:22:33:44:55:66:77:88:99:00:AB:CD:EF:12
<cert>
-----BEGIN CERTIFICATE-----
MIIBszCCAVmgAwIBAgIUTx+0aGVzdC1jZXJ0IHRlc3QwDQYJKoZIhvcNAQELBQAw
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQCrb3Rlc3Qta2V5
-----END PRIVATE KEY-----
</key>
S
bash "$ROOT/nns-app-darwin.sh" install occorp
bash "$ROOT/nns-app-darwin.sh" add occorp "$T/corp.oc" 2>"$T/add-oc-warn.err"
if ! command -v openconnect >/dev/null 2>&1 &&
   [ ! -x /opt/homebrew/sbin/openconnect ] && [ ! -x /usr/local/sbin/openconnect ] &&
   [ ! -x /opt/homebrew/bin/openconnect ] && [ ! -x /usr/local/bin/openconnect ]; then
  grep -Fq 'brew install openconnect' "$T/add-oc-warn.err" || {
    echo "anyconnect add missing the brew install hint: $(cat "$T/add-oc-warn.err")" >&2; exit 1
  }
fi
OCCFG="$T/home/Library/Application Support/nns-app/apps/occorp"
[[ "$(cat "$OCCFG/type")" == anyconnect ]] || {
  echo 'anyconnect type not stored' >&2; exit 1
}
[[ -f "$OCCFG/profile.oc" ]] || { echo 'profile.oc missing' >&2; exit 1; }
[ ! -e "$OCCFG/profile.conf" ] && [ ! -e "$OCCFG/profile.ovpn" ] || {
  echo 'stale backend profile not removed by anyconnect import' >&2; exit 1
}
[ ! -e "$OCCFG/dns_ipv4" ] || {
  echo 'anyconnect import must not inherit a DNS override from another backend' >&2; exit 1
}
output=$(bash "$ROOT/nns-app-darwin.sh" list)
grep -Eq 'occorp[[:space:]]+vpn-client/oc[[:space:]]+stopped[[:space:]]+host' <<<"$output" || {
  echo "anyconnect list row mismatch: $output" >&2; exit 1
}
bash "$ROOT/nns-app-darwin.sh" status occorp | grep -q 'vpn-client/oc' || {
  echo 'anyconnect status missing type' >&2; exit 1
}
# Replacing the profile with a certificate-based one drops the stale cookie.
printf 'stale-cookie' > "$OCCFG/cookie"
bash "$ROOT/nns-app-darwin.sh" add occorp "$T/certs.oc"
[ ! -e "$OCCFG/cookie" ] || { echo 'stale cookie survived profile replacement' >&2; exit 1; }
grep -Fq 'Employees' "$OCCFG/profile.oc" && {
  echo 'old profile content leaked into the replaced profile' >&2; exit 1
}
# oc-login with a mock openconnect stores the session cookie. The mock is
# only authoritative when the host has no real openconnect (openconnect_bin
# probes the Homebrew absolute paths before $PATH).
if ! command -v openconnect >/dev/null 2>&1 &&
   [ ! -x /opt/homebrew/sbin/openconnect ] && [ ! -x /usr/local/sbin/openconnect ] &&
   [ ! -x /opt/homebrew/bin/openconnect ] && [ ! -x /usr/local/bin/openconnect ]; then
  cat > "$T/fake/openconnect" <<'S'
#!/bin/sh
# Modern openconnect quotes the cookie: COOKIE='<value>'.
printf "COOKIE='AbCdEf0123456789+/=_-xyz'\n"
S
  chmod +x "$T/fake/openconnect"
  oclogin_output=$(bash "$ROOT/nns-app-darwin.sh" oc-login occorp)
  grep -Fq 'cookie saved' <<<"$oclogin_output" || {
    echo 'oc-login did not report success' >&2; exit 1
  }
  [[ "$(cat "$OCCFG/cookie")" == AbCdEf0123456789+/=_-xyz ]] || {
    echo 'oc-login did not persist the session cookie' >&2; exit 1
  }
fi
cat > "$T/bad.oc" <<'S'
server=https://vpn.example.com
script=/etc/vpnc/vpnc-script
S
if bash "$ROOT/nns-app-darwin.sh" add occorp "$T/bad.oc" 2>"$T/bad-oc.err"; then
  echo 'AnyConnect script directive was accepted' >&2; exit 1
fi
grep -Eiq 'unsupported directive' "$T/bad-oc.err" || {
  echo "bad oc error missing: $(cat "$T/bad-oc.err")" >&2; exit 1
}
cat > "$T/noserver.oc" <<'S'
user=employee
S
if bash "$ROOT/nns-app-darwin.sh" add occorp "$T/noserver.oc" 2>"$T/noserver-oc.err"; then
  echo 'AnyConnect profile without server was accepted' >&2; exit 1
fi
grep -Eiq "no 'server=' entry" "$T/noserver-oc.err" || {
  echo "missing-server error missing: $(cat "$T/noserver-oc.err")" >&2; exit 1
}
# pin-sha256 is the fingerprint format openconnect prints in its own
# certificate error; the importer must accept it verbatim.
cat > "$T/pin.oc" <<'S'
server=https://rnd.megafon.ru:441
user=employee
password=secret
fingerprint=pin-sha256:+W/ZQRawrDxndKfi1OBPsdJYl53aYmoe1gdx3QPuwg8=
dns=10.99.0.53
S
bash "$ROOT/nns-app-darwin.sh" add occorp "$T/pin.oc" | grep -q 'Imported AnyConnect profile' || {
  echo 'pin-sha256 profile import failed' >&2; exit 1
}
[[ "$(cat "$OCCFG/dns_ipv4")" == 10.99.0.53 ]] || {
  echo 'profile dns= was not imported as the per-app resolver' >&2; exit 1
}
bash "$ROOT/nns-app-darwin.sh" remove occorp

[[ "$(bash "$ROOT/nns-app-darwin.sh" list)" == 'No apps configured.' ]] || {
  echo 'list not empty after remove' >&2; exit 1
}
# Darwin-only: the generated openconnect hook must configure only the utun,
# never host DNS, PF or the host default route; and the placeholder must be
# substituted with the runtime state path.
if [ "$(uname -s)" = Darwin ]; then
  mkdir -p "$T/oc-hook-state"
  hook_out=$(bash -c '
    set -e
    hook_script=$1
    hook_state=$2
    # The sourced CLI runs main() at the end; with no arguments it prints
    # usage and returns, which is harmless here.
    set --
    source "$hook_script" >/dev/null
    RUNSTATE="$hook_state"
    write_oc_hook utun9
    list_utuns() { printf "utun0\nutun3\n"; }
    [ "$(next_utun)" = utun4 ] || { echo "next_utun mismatch: $(next_utun)" >&2; exit 1; }
    printf "hook written"
  ' bash "$ROOT/nns-app-darwin.sh" "$T/oc-hook-state")
  HOOK="$T/oc-hook-state/oc-hook"
  [ -x "$HOOK" ] || { echo 'oc-hook missing or not executable' >&2; exit 1; }
  grep -Fq "$T/oc-hook-state" "$HOOK" || { echo '@RUNSTATE@ not substituted' >&2; exit 1; }
  grep -Fq 'ifconfig "$dev" inet "$ip" "$ip" netmask 255.255.255.255 up' "$HOOK" || {
    echo 'oc-hook does not narrow the utun address to /32' >&2; exit 1
  }
  grep -Fq -- '-ifscope "$dev"' "$HOOK" || {
    echo 'oc-hook does not use interface-scoped routes' >&2; exit 1
  }
  grep -Fq 'route -q -n add -ifscope "$dev" -net' "$HOOK" || {
    echo 'oc-hook does not scope pushed split routes' >&2; exit 1
  }
  # The reason arrives via the `reason` environment variable in modern
  # openconnect; the requested utun name is baked in as the TUNDEV fallback.
  grep -Fq 'hook_reason=${reason:-}' "$HOOK" || {
    echo 'oc-hook does not read the reason environment variable' >&2; exit 1
  }
  grep -Fq 'utun9' "$HOOK" || {
    echo 'oc-hook does not embed the requested utun fallback' >&2; exit 1
  }
  grep -Fq 'VPNGATEWAY' "$HOOK" || {
    echo 'oc-hook lacks the VPN-gateway DNS fallback' >&2; exit 1
  }
  grep -Fq 'attempt-reconnect' "$HOOK" || {
    echo 'oc-hook does not handle attempt-reconnect' >&2; exit 1
  }
  # A dead engine must never leave a "started" claim: engine_alive gates on
  # the recorded engine pid, which is gone once the tunnel process exits.
  rm -rf "$T/engine-state"; mkdir -p "$T/engine-state"
  engine_check=$(bash -c '
    set -e
    cli_script=$1
    cli_state=$2
    set --
    source "$cli_script" >/dev/null
    RUNSTATE="$cli_state"
    ( exec -a openconnect sleep 300 ) &
    oc_pid=$!
    printf "%s\n" "$oc_pid" >"$RUNSTATE/oc_pid"
    engine_alive || { echo "alive-miss" >&2; kill "$oc_pid" 2>/dev/null || true; exit 1; }
    kill "$oc_pid" 2>/dev/null || true
    printf "99999999\n" >"$RUNSTATE/oc_pid"
    if engine_alive; then echo "dead-miss" >&2; exit 1; fi
    # Pid reuse: a live but unrelated process must count as dead. Only
    # verifiable where ps can inspect processes (not in sandboxes).
    if ps -o command= -p "$$" >/dev/null 2>&1; then
      sleep 300 &
      reuse_pid=$!
      printf "%s\n" "$reuse_pid" >"$RUNSTATE/oc_pid"
      if engine_alive; then echo "reuse-miss" >&2; kill "$reuse_pid" 2>/dev/null || true; exit 1; fi
      kill "$reuse_pid" 2>/dev/null || true
    fi
    # EPERM on kill -0 (engine owned by another uid) must count as alive
    # when ps proves the pid exists; liveness cannot depend on signalling.
    printf "424242\n" >"$RUNSTATE/oc_pid"
    kill() { return 1; }
    ps() {
      case "$*" in
        *"pid="*) printf "424242\n" ;;
      esac
      return 0
    }
    engine_alive || { echo "eperm-miss" >&2; exit 1; }
    rm -f "$RUNSTATE/oc_pid"
    if engine_alive; then echo "absent-miss" >&2; exit 1; fi
    echo "engine-alive-ok"
  ' bash "$ROOT/nns-app-darwin.sh" "$T/engine-state")
  grep -Fq 'engine-alive-ok' <<<"$engine_check" || {
    echo "engine aliveness checks failed: $engine_check" >&2; exit 1
  }
  # run/git must auto-restart a stale app (dead engine) via sudo -n.
  rm -rf "$T/engine-run"; mkdir -p "$T/engine-run"
  run_check=$(bash -c '
    set -e
    cli_script=$1
    cli_state=$2
    cli_log=$3
    set --
    source "$cli_script" >/dev/null
    RUNSTATE="$cli_state"
    APP=unitapp
    mkdir -p "$RUNSTATE"
    : >"$RUNSTATE/ready"
    printf "99999999\n" >"$RUNSTATE/oc_pid"
    printf "engine-dies-everywhere\n" >"$RUNSTATE/ovpn.log"
    SUDO_LOG="$cli_log"
    : >"$SUDO_LOG"
    engine_alive() { return 1; }
    sleep() { return 0; }
    start_via_sudo() { printf "restart\n" >>"$SUDO_LOG"; return 0; }
    # A persistently dying engine: bounded restarts, then a failure that
    # dumps the engine log tail; stdout stays clean for the git channel.
    msg=$( ( ensure_engine_running ) 2>&1 || true )
    [ "$(grep -c restart "$SUDO_LOG")" -eq 3 ] || {
      echo "expected 3 restart attempts: $(cat "$SUDO_LOG")" >&2; exit 1
    }
    grep -Fq "keeps exiting after restart" <<<"$msg" || {
      echo "missing keeps-exiting message: $msg" >&2; exit 1
    }
    grep -Fq engine-dies-everywhere <<<"$msg" || {
      echo "engine log tail not shown: $msg" >&2; exit 1
    }
    echo "auto-restart-ok"
  ' bash "$ROOT/nns-app-darwin.sh" "$T/engine-run" "$T/run-sudo.log")
  grep -Fq 'auto-restart-ok' <<<"$run_check" || {
    echo "auto-restart checks failed: $run_check" >&2; exit 1
  }
  # start_via_sudo: passwordless attempt first, interactive fallback second.
  sudo_check=$(bash -c '
    set -e
    cli_script=$1
    cli_log=$2
    set --
    source "$cli_script" >/dev/null
    APP=unitapp
    SUDO_LOG="$cli_log"
    : >"$SUDO_LOG"
    sudo() { printf "%s\n" "$*" >>"$SUDO_LOG"; [ "${1:-}" = -n ] && return 1; return 0; }
    start_via_sudo
    [ "$(grep -c restart "$SUDO_LOG")" -eq 2 ] || {
      echo "sudo fallback broken: $(cat "$SUDO_LOG")" >&2; exit 1
    }
    grep -Fq -- "-n" "$SUDO_LOG" || { echo "missing sudo -n attempt" >&2; exit 1; }
    echo "sudo-fallback-ok"
  ' bash "$ROOT/nns-app-darwin.sh" "$T/sudo-fallback.log")
  grep -Fq 'sudo-fallback-ok' <<<"$sudo_check" || {
    echo "sudo fallback checks failed: $sudo_check" >&2; exit 1
  }
  # The comprehensive staleness predicate: a live engine whose claimed utun
  # no longer carries the claimed address (pid reused by another engine) is
  # stale and must be recovered, not protected.
  rm -rf "$T/engine-stale"; mkdir -p "$T/engine-stale"
  stale_check=$(bash -c '
    set -e
    cli_script=$1
    cli_state=$2
    set --
    source "$cli_script" >/dev/null
    RUNSTATE="$cli_state"
    APP=unitapp
    : >"$RUNSTATE/ready"
    printf "utun9\n" >"$RUNSTATE/utun"
    printf "10.9.9.9\n" >"$RUNSTATE/vpn_ip"
    engine_alive() { return 0; }
    ifconfig() { printf "inet %s --> %s netmask 0xffffffff\n" "$FAKE_IF_IP" "$FAKE_IF_IP"; }
    FAKE_IF_IP=10.0.0.1
    app_runtime_stale || { echo "claim-mismatch-not-stale" >&2; exit 1; }
    FAKE_IF_IP=10.9.9.9
    if app_runtime_stale; then echo "valid-claim-stale" >&2; exit 1; fi
    engine_alive() { return 1; }
    if ! app_runtime_stale; then echo "dead-not-stale" >&2; exit 1; fi
    echo "stale-predicate-ok"
  ' bash "$ROOT/nns-app-darwin.sh" "$T/engine-stale")
  grep -Fq 'stale-predicate-ok' <<<"$stale_check" || {
    echo "staleness predicate checks failed: $stale_check" >&2; exit 1
  }
  # Duplicate-address resolution: correct interface attribution, managed-app
  # refusal by name, and destruction of orphaned carriers.
  rm -rf "$T/engine-conflict"; mkdir -p "$T/engine-conflict"
  conflict_check=$(bash -c '
    set -e
    cli_script=$1
    cli_state=$2
    set --
    source "$cli_script" >/dev/null
    USER_RUNTIME="$cli_state"
    warn() { :; }
    # Non-utun carriers must be attributed to their own header, not the
    # previous utun seen in the listing.
    ifconfig() { printf "vmenet0: flags=...\n\tinet 10.5.5.5 --> 10.5.5.5 netmask 0xffffffff\nutun7: flags=...\n\tinet 10.6.6.6 --> 10.6.6.6 netmask 0xffffffff\n"; }
    out=$(iface_for_address 10.5.5.5 "")
    [ "$out" = "vmenet0" ] || { echo "bad-attribution:$out" >&2; exit 1; }
    # A carrier owned by another managed app must be refused by name.
    managed="$cli_state/app1"; mkdir -p "$managed"
    : >"$managed/ready"
    printf "utun7\n" >"$managed/utun"
    # The nested subshell contains the fail() exit so the || true applies
    # to the substitution instead of the captured command.
    msg=$( ( resolve_conflicting_address 10.6.6.6 utun9 ) 2>&1 || true )
    grep -Fq "stop it first: sudo nns-app stop app1" <<<"$msg" || {
      echo "no-owner-refusal: $msg" >&2; exit 1
    }
    # A busy orphaned utun cannot be destroyed; the engine holding it (its
    # command line carries the app mark) must be killed instead.
    rm -rf "$cli_state/app1"
    APP=unitapp
    : >"$cli_state/utun8-alive"
    : >"$cli_state/kills"
    ifconfig() {
      [ "${2:-}" != destroy ] || return 0
      case "$1" in
        -a) [ -e "$cli_state/utun8-alive" ] &&
            printf "utun8: flags=...\n\tinet 10.7.7.7 --> 10.7.7.7 netmask 0xffffffff\n" ;;
      esac
    }
    pgrep() { printf "4242\n"; }
    kill() { printf "%s\n" "$1" >>"$cli_state/kills"; rm -f "$cli_state/utun8-alive"; return 0; }
    sleep() { return 0; }
    out=$(resolve_conflicting_address 10.7.7.7 utun9)
    [ -z "$out" ] || { echo "orphan-survivor:$out" >&2; exit 1; }
    grep -Fxq 4242 "$cli_state/kills" || { echo "orphan-holder-not-killed" >&2; exit 1; }
    [ ! -e "$cli_state/utun8-alive" ] || { echo "orphan-not-freed" >&2; exit 1; }
    echo "conflict-resolver-ok"
  ' bash "$ROOT/nns-app-darwin.sh" "$T/engine-conflict")
  grep -Fq 'conflict-resolver-ok' <<<"$conflict_check" || {
    echo "conflict resolver checks failed: $conflict_check" >&2; exit 1
  }
  for forbidden in 'networksetup' 'scutil' 'pfctl' 'route -n add -inet default'; do
    if grep -Fq "$forbidden" "$HOOK"; then
      echo "oc-hook contains a host-affecting command: $forbidden" >&2; exit 1
    fi
  done
fi
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


# Regression: git-via must work when the repository has no core.sshCommand.
# `set -o pipefail` previously aborted the "count existing values" pipeline
# before git-via could write the new setting.
if [ "$(uname -s)" = Darwin ]; then
  test_ssh=''
  for candidate in /opt/homebrew/bin/ssh /usr/local/bin/ssh \
    /opt/homebrew/opt/openssh/bin/ssh /usr/local/opt/openssh/bin/ssh; do
    if [ -x "$candidate" ]; then test_ssh=$candidate; break; fi
  done
  if [ -n "$test_ssh" ]; then
    mkdir "$T/gitvia-repo"
    (
      cd "$T/gitvia-repo"
      git init -q
      git config user.email test@example.invalid
      git config user.name test
    )
    bash "$ROOT/nns-app-darwin.sh" install gitviavpn >/dev/null
    bash "$ROOT/nns-app-darwin.sh" add gitviavpn "$T/test.conf" >/dev/null
    (
      cd "$T/gitvia-repo"
      bash "$ROOT/nns-app-darwin.sh" git-via gitviavpn >/dev/null
    )
    desired=$(cd "$T/gitvia-repo" && git config --local --get core.sshCommand)
    [ "$desired" = "/usr/local/bin/nns-app run gitviavpn $test_ssh" ] || {
      echo "git-via did not set core.sshCommand: '$desired'" >&2; exit 1
    }
    (
      cd "$T/gitvia-repo"
      bash "$ROOT/nns-app-darwin.sh" git-via - >/dev/null
    )
    [ -z "$(cd "$T/gitvia-repo" && git config --local --get core.sshCommand 2>/dev/null || true)" ] || {
      echo 'git-via - did not remove core.sshCommand' >&2; exit 1
    }
    bash "$ROOT/nns-app-darwin.sh" remove gitviavpn >/dev/null
  fi
fi


# Host-mode myip/myloc work without an app name. Use a fake curl so the
# test stays offline and deterministic.
if [ "$(uname -s)" = Darwin ]; then
  cat > "$T/fake-myip-curl" <<'S'
#!/bin/sh
printf '%s\n' '203.0.113.7'
S
  cat > "$T/fake-myloc-curl" <<'S'
#!/bin/sh
printf '%s\n' '{"status":"success","message":"","query":"203.0.113.9","country":"Testland","countryCode":"TL","regionName":"Test Region","city":"Test City","zip":"00000","lat":1.5,"lon":2.5,"timezone":"Etc/UTC","isp":"Test ISP","org":"Test Org","as":"AS64500 Test"}'
S
  chmod +x "$T/fake-myip-curl" "$T/fake-myloc-curl"
  [[ "$(NNS_MAC_TEST_CURL="$T/fake-myip-curl" bash "$ROOT/nns-app-darwin.sh" myip)" == '203.0.113.7' ]] || {
    echo 'host-mode myip mismatch' >&2; exit 1
  }
  loc_json=$(NNS_MAC_TEST_CURL="$T/fake-myloc-curl" NNS_MYLOC_CACHE="$T/myloc-cache" bash "$ROOT/nns-app-darwin.sh" myloc --json)
  grep -Fq '"query": "203.0.113.9"' <<<"$loc_json" || {
    echo "host-mode myloc --json mismatch: $loc_json" >&2; exit 1
  }
  loc_pretty=$(NNS_MAC_TEST_CURL="$T/fake-myloc-curl" NNS_MYLOC_CACHE="$T/myloc-cache" bash "$ROOT/nns-app-darwin.sh" myloc)
  grep -Fq '203.0.113.9' <<<"$loc_pretty" && grep -Fq 'Context:           host' <<<"$loc_pretty" || {
    echo "host-mode myloc mismatch: $loc_pretty" >&2; exit 1
  }

  # When the primary ip-api.com probe fails, host-mode myloc falls back to
  # ipwho.is and reports the provider that actually answered.
  cat > "$T/fake-myloc-fb-curl" <<'S'
#!/bin/sh
case "$*" in
  *ip-api.com*) exit 7 ;;
  *) printf '%s\n' '{"ip":"203.0.113.11","success":true,"country":"Testland","country_code":"TL","region":"Test Region","city":"Test City","postal":"00000","latitude":3.4,"longitude":4.5,"connection":{"asn":64501,"org":"Test Org","isp":"Test ISP"},"timezone":{"id":"Etc/UTC"}}' ;;
esac
S
  chmod +x "$T/fake-myloc-fb-curl"
  rm -f "$T/myloc-cache"
  loc_fb=$(NNS_MAC_TEST_CURL="$T/fake-myloc-fb-curl" NNS_MYLOC_CACHE="$T/myloc-cache" bash "$ROOT/nns-app-darwin.sh" myloc)
  grep -Fq '203.0.113.11' <<<"$loc_fb" && grep -Fq 'Provider:          ipwho.is' <<<"$loc_fb" || {
    echo "host-mode myloc fallback mismatch: $loc_fb" >&2; exit 1
  }

  # The provider that last worked is remembered per context and tried first
  # on the next run, so the blocked primary is not re-probed every time.
  cat > "$T/fake-myloc-rec-curl" <<'S'
#!/bin/sh
printf '%s\n' "$*" >>"${NNS_REC_FILE:-/dev/null}"
case "$*" in
  *ipwho.is*) printf '%s\n' '{"ip":"203.0.113.12","success":true,"country":"Testland","country_code":"TL","city":"Test City","connection":{"asn":64502,"org":"Test Org","isp":"Test ISP"},"timezone":{"id":"Etc/UTC"}}'; exit 0 ;;
  *) exit 7 ;;
esac
S
  chmod +x "$T/fake-myloc-rec-curl"
  rm -f "$T/myloc-cache" "$T/myloc-order1" "$T/myloc-order2"
  loc_r1=$(NNS_MAC_TEST_CURL="$T/fake-myloc-rec-curl" NNS_MYLOC_CACHE="$T/myloc-cache" NNS_REC_FILE="$T/myloc-order1" bash "$ROOT/nns-app-darwin.sh" myloc)
  grep -Fq '203.0.113.12' <<<"$loc_r1" || { echo "cached myloc first run mismatch: $loc_r1" >&2; exit 1; }
  grep -Fq 'ip-api.com' "$T/myloc-order1" || { echo 'primary not attempted on first cached run' >&2; exit 1; }
  loc_r2=$(NNS_MAC_TEST_CURL="$T/fake-myloc-rec-curl" NNS_MYLOC_CACHE="$T/myloc-cache" NNS_REC_FILE="$T/myloc-order2" bash "$ROOT/nns-app-darwin.sh" myloc)
  grep -Fq '203.0.113.12' <<<"$loc_r2" || { echo "cached myloc second run mismatch: $loc_r2" >&2; exit 1; }
  head -n1 "$T/myloc-order2" | grep -Fq 'ipwho.is' || { echo 'cached provider not tried first on second run' >&2; exit 1; }
fi

# SIP-protected tools get scoped VPN DNS via the exported resolver symbol:
# the launcher resolves in-scope hostnames and substitutes numeric argv.
nm -gU "$ROOT/bin/libnnsbind.dylib" 2>/dev/null | grep -Fq '_nns_dns_resolve_host' || {
  echo 'libnnsbind lacks the exported VPN DNS resolver' >&2; exit 1
}
nm -gU "$ROOT/bin/libnnsbind.dylib" 2>/dev/null | grep -Fq '_nns_dns_host_is_local' || {
  echo 'libnnsbind lacks the exported /etc/hosts classifier' >&2; exit 1
}
strings "$ROOT/bin/nns-run" | grep -Fq 'nns_dns_resolve_host' || {
  echo 'nns-run lacks the VPN DNS resolution hook' >&2; exit 1
}
strings "$ROOT/bin/nns-run" | grep -Fq 'nns_dns_host_is_local' || {
  echo 'nns-run lacks the local-hosts passthrough hook' >&2; exit 1
}

# restart: stop (if running) then start, with auto-sudo like start/stop.
grep -Fq 'restart)' "$ROOT/nns-app-darwin.sh" || { echo 'restart command missing' >&2; exit 1; }
grep -Fq 'nns-app restart' "$ROOT/nns-app-darwin.sh" || { echo 'restart usage missing' >&2; exit 1; }
grep -Fq 'start|stop|restart|recover)' "$ROOT/nns-app-darwin.sh" || { echo 'restart missing from auto-sudo set' >&2; exit 1; }
grep -Fq 'restart_all()' "$ROOT/nns-app-darwin.sh" || { echo 'bare restart (all apps) missing' >&2; exit 1; }

echo 'macOS static + mock CLI tests passed.'
