#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TMP/locks"
# shellcheck source=/dev/null
source "$ROOT/install_linux"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# The engine uses GNU `stat -c`; provide a BSD-compatible shim so the test can
# also run on macOS development machines without coreutils.
if [[ "$(uname -s)" == Darwin ]]; then
    stat() {
        if [[ "$1" == -c && "$2" == %s ]]; then
            /usr/bin/stat -f '%z' "${3:--}"
        else
            /usr/bin/stat "$@"
        fi
    }
fi

cat > "$TMP/corp.oc" <<'EOF_CORP'
# Corporate AnyConnect gateway (nns-app .oc convention)
protocol=anyconnect
server=https://vpn.example.com
user=employee
passwd=correct horse battery staple
authgroup=Employees
route-mode=split
EOF_CORP

cat > "$TMP/full.oc" <<'EOF_FULL'
server=https://10.1.2.3:444
user=alice
passwd=secret
EOF_FULL

cat > "$TMP/nocreds.oc" <<'EOF_NOCREDS'
server=https://vpn.example.com
user=employee
EOF_NOCREDS

cat > "$TMP/nouser.oc" <<'EOF_NOUSER'
server=https://vpn.example.com
EOF_NOUSER

cat > "$TMP/certs.oc" <<'EOF_CERTS'
server=https://vpn.example.com
user=employee
passwd=secret
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
EOF_CERTS

# --- type detection ---------------------------------------------------------
[[ $(profile_type_from_file "$TMP/corp.oc") == anyconnect ]] || fail '.oc detection'
cat > "$TMP/renamed.txt" <<'EOF_RENAMED'
protocol=gp
server=https://vpn.example.com
EOF_RENAMED
[[ $(profile_type_from_file "$TMP/renamed.txt") == anyconnect ]] || fail 'protocol= content detection'
cat > "$TMP/weird.oc" <<'EOF_WEIRD'
remote vpn.example.com 443
EOF_WEIRD
[[ $(profile_type_from_file "$TMP/weird.oc") == anyconnect ]] ||
    fail '.oc extension must win over openvpn remote lines'
cat > "$TMP/plain.ovpn" <<'EOF_OVPN'
remote vpn.example.com 1194
EOF_OVPN
[[ $(profile_type_from_file "$TMP/plain.ovpn") == openvpn ]] || fail 'openvpn detection regressed'
cat > "$TMP/wg.conf" <<EOF_WG
[Interface]
PrivateKey = $(printf 'a%.0s' {1..44})=
Address = 10.9.0.2/32

[Peer]
PublicKey = $(printf 'b%.0s' {1..44})=
AllowedIPs = 10.30.0.0/16
Endpoint = vpn.example.com:443
EOF_WG
[[ $(profile_type_from_file "$TMP/wg.conf") == wireguard ]] || fail 'wireguard detection regressed'

# --- profile naming / labels ------------------------------------------------
[[ $(profile_name_from_path "$TMP/corp.oc" anyconnect) == corp.oc ]] || fail 'oc suffix'
[[ $(vpn_type_label anyconnect) == AnyConnect ]] || fail 'anyconnect label'

# --- validation -------------------------------------------------------------
validate_anyconnect "$TMP/corp.oc" || fail 'corp.oc validation'
validate_anyconnect "$TMP/full.oc" || fail 'full.oc validation'
validate_anyconnect "$TMP/certs.oc" || fail 'certs.oc validation'
[[ $(anyconnect_profile_route_mode "$TMP/corp.oc") == split ]] || fail 'split route mode'
[[ $(anyconnect_profile_route_mode "$TMP/full.oc") == full ]] || fail 'full route mode'
[[ $(anyconnect_profile_value "$TMP/corp.oc" passwd) == 'correct horse battery staple' ]] ||
    fail 'passwd value parsing'

expect_anyconnect_reject() {
    local file=$1 desc=$2
    if (validate_anyconnect "$file") >/dev/null 2>&1; then
        fail "accepted invalid profile: $desc"
    fi
}
cat > "$TMP/bad1.oc" <<'EOF_B1'
user=employee
EOF_B1
expect_anyconnect_reject "$TMP/bad1.oc" 'missing server'
cat > "$TMP/bad2.oc" <<'EOF_B2'
server=https://vpn.example.com/path?query=1
EOF_B2
expect_anyconnect_reject "$TMP/bad2.oc" 'URL with path/query'
cat > "$TMP/bad3.oc" <<'EOF_B3'
server=ftp://vpn.example.com
EOF_B3
expect_anyconnect_reject "$TMP/bad3.oc" 'non-https URL'
cat > "$TMP/bad4.oc" <<'EOF_B4'
server=https://vpn.example.com:99999
EOF_B4
expect_anyconnect_reject "$TMP/bad4.oc" 'out-of-range port'
cat > "$TMP/bad5.oc" <<'EOF_B5'
server=https://vpn.example.com
protocol=openvpn
EOF_B5
expect_anyconnect_reject "$TMP/bad5.oc" 'unsupported protocol'
cat > "$TMP/bad6.oc" <<'EOF_B6'
server=https://vpn.example.com
script=/etc/vpnc/vpnc-script
EOF_B6
expect_anyconnect_reject "$TMP/bad6.oc" 'helper script directive'
cat > "$TMP/bad7.oc" <<'EOF_B7'
server=https://vpn.example.com
user=bad name!
EOF_B7
expect_anyconnect_reject "$TMP/bad7.oc" 'invalid username'
cat > "$TMP/bad8.oc" <<'EOF_B8'
server=https://vpn.example.com
fingerprint=SHA256:abcd
EOF_B8
expect_anyconnect_reject "$TMP/bad8.oc" 'short fingerprint'
cat > "$TMP/bad9.oc" <<'EOF_B9'
server=https://vpn.example.com
token-mode=weird
EOF_B9
expect_anyconnect_reject "$TMP/bad9.oc" 'invalid token mode'
cat > "$TMP/bad10.oc" <<'EOF_B10'
server=https://vpn.example.com
token-secret=xyz:123
EOF_B10
expect_anyconnect_reject "$TMP/bad10.oc" 'invalid token secret'
cat > "$TMP/bad11.oc" <<'EOF_B11'
server=https://vpn.example.com
route-mode=banana
EOF_B11
expect_anyconnect_reject "$TMP/bad11.oc" 'invalid route mode'
cat > "$TMP/bad12.oc" <<'EOF_B12'
server=https://vpn.example.com
mtu=100
EOF_B12
expect_anyconnect_reject "$TMP/bad12.oc" 'out-of-range mtu'
cat > "$TMP/bad13.oc" <<'EOF_B13'
server=https://vpn.example.com
<cert>
-----BEGIN CERTIFICATE-----
xyz
-----END CERTIFICATE-----
</cert>
EOF_B13
expect_anyconnect_reject "$TMP/bad13.oc" 'cert without key'
cat > "$TMP/bad14.oc" <<'EOF_B14'
server=https://vpn.example.com
<cert>
-----BEGIN CERTIFICATE-----
not base64!
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
not base64!
-----END PRIVATE KEY-----
</key>
EOF_B14
expect_anyconnect_reject "$TMP/bad14.oc" 'non-base64 PEM body'
cat > "$TMP/bad15.oc" <<'EOF_B15'
server=https://vpn.example.com
authgroup=Employees;touch /tmp/x
EOF_B15
expect_anyconnect_reject "$TMP/bad15.oc" 'authgroup metacharacters'
printf 'server=https://vpn.example.com\npasswd=line1\nline2\n' > "$TMP/bad16.oc"
expect_anyconnect_reject "$TMP/bad16.oc" 'password value spanning lines'
cat > "$TMP/bad17.oc" <<'EOF_B17'
server=https://vpn.example.com
server=https://other.example.com
EOF_B17
expect_anyconnect_reject "$TMP/bad17.oc" 'duplicate server directive'
cat > "$TMP/bad18.oc" <<'EOF_B18'
server=https://vpn.example.com
passwd=one
passwd=two
EOF_B18
expect_anyconnect_reject "$TMP/bad18.oc" 'duplicate passwd directive'

# `password=` is an accepted alias for `passwd=`; declaring both is ambiguous.
cat > "$TMP/alias.oc" <<'EOF_ALIAS'
server=https://vpn.example.com
user=employee
password=secret
EOF_ALIAS
validate_anyconnect "$TMP/alias.oc" || fail 'password alias rejected'
[[ $(anyconnect_profile_value "$TMP/alias.oc" passwd) == secret ]] ||
    fail 'password alias not mapped to passwd'
cat > "$TMP/bad-alias.oc" <<'EOF_BAD_ALIAS'
server=https://vpn.example.com
passwd=one
password=two
EOF_BAD_ALIAS
expect_anyconnect_reject "$TMP/bad-alias.oc" 'both passwd and password'

# Validation errors must never echo secret values into stderr.
cat > "$TMP/bad-secret.oc" <<'EOF_BAD_SECRET'
server=https://vpn.example.com
secret=super-secret-value-xyz
EOF_BAD_SECRET
if (validate_anyconnect "$TMP/bad-secret.oc") 2>"$TMP/bad-secret.err"; then
    fail 'unknown directive accepted'
fi
if grep -Fq 'super-secret-value-xyz' "$TMP/bad-secret.err"; then
    fail 'validation error leaked the directive value'
fi
grep -Fq 'unsupported directive: secret' "$TMP/bad-secret.err" ||
    fail 'validation error does not name the offending key'

# Inline `# ...` comments after a value are stripped (README-documented form).
cat > "$TMP/commented.oc" <<'EOF_COMMENTED'
server=https://vpn.example.com   # required; https://host[:port]
user=employee            # optional; required for oc-login or inline credentials
passwd=secret            # optional; stored root-only (0600) like every profile
EOF_COMMENTED
validate_anyconnect "$TMP/commented.oc" || fail 'inline comments break parsing'
[[ $(anyconnect_profile_value "$TMP/commented.oc" server) == https://vpn.example.com ]] ||
    fail 'inline comment leaked into the server value'
[[ $(anyconnect_profile_value "$TMP/commented.oc" passwd) == secret ]] ||
    fail 'inline comment leaked into the passwd value'

# The README-documented example profile must validate verbatim: parser and
# public documentation must never drift.
README_EXAMPLE="$TMP/readme-example.oc"
python3 - "$ROOT/README.md" "$README_EXAMPLE" <<'PY_README_EXTRACT'
import re
import sys

text = open(sys.argv[1]).read()
match = re.search(r"```ini\n# Corporate AnyConnect gateway.*?\n```", text, re.S)
if not match:
    raise SystemExit("README AnyConnect example block not found")
profile = match.group(0)[len("```ini\n"):-len("\n```")]
with open(sys.argv[2], "w") as out:
    out.write(profile + "\n")
PY_README_EXTRACT
validate_anyconnect "$README_EXAMPLE" || fail 'README example profile was rejected'

# Valid fingerprint forms are accepted.
cat > "$TMP/fp.oc" <<'EOF_FP'
server=https://vpn.example.com
fingerprint=SHA1:AA:BB:CC:DD:EE:FF:11:22:33:44:55:66:77:88:99:00:AB:CD:EF:12
EOF_FP
validate_anyconnect "$TMP/fp.oc" || fail 'valid SHA1 fingerprint rejected'
# pin-sha256 is the format openconnect itself prints in its certificate
# error; profiles must accept that value verbatim.
cat > "$TMP/fp-pin.oc" <<'EOF_FP_PIN'
server=https://rnd.megafon.ru:441
user=employee
password=secret
fingerprint=pin-sha256:+W/ZQRawrDxndKfi1OBPsdJYl53aYmoe1gdx3QPuwg8=
EOF_FP_PIN
validate_anyconnect "$TMP/fp-pin.oc" || fail 'valid pin-sha256 fingerprint rejected'
cat > "$TMP/bad-pin.oc" <<'EOF_BAD_PIN'
server=https://vpn.example.com
fingerprint=pin-sha256:not!base64!
EOF_BAD_PIN
expect_anyconnect_reject "$TMP/bad-pin.oc" 'invalid pin-sha256 body'
cat > "$TMP/bad-dtls.oc" <<'EOF_BAD_DTLS'
server=https://vpn.example.com
dtls=maybe
EOF_BAD_DTLS
expect_anyconnect_reject "$TMP/bad-dtls.oc" 'invalid dtls value'
cat > "$TMP/dtlsoff.oc" <<'EOF_DTLS_OFF'
server=https://vpn.example.com
user=employee
passwd=secret
dtls=off
EOF_DTLS_OFF
validate_anyconnect "$TMP/dtlsoff.oc" || fail 'dtls=off rejected'
cat > "$TMP/dnskey.oc" <<'EOF_DNSKEY'
server=https://vpn.example.com
dns=10.99.0.53 10.99.0.54
EOF_DNSKEY
validate_anyconnect "$TMP/dnskey.oc" || fail 'valid dns= list rejected'
cat > "$TMP/bad-dns1.oc" <<'EOF_BAD_DNS1'
server=https://vpn.example.com
dns=10.99.0.53,10.99.0.54
EOF_BAD_DNS1
expect_anyconnect_reject "$TMP/bad-dns1.oc" 'comma-separated dns list'
cat > "$TMP/bad-dns2.oc" <<'EOF_BAD_DNS2'
server=https://vpn.example.com
dns=999.1.1.1
EOF_BAD_DNS2
expect_anyconnect_reject "$TMP/bad-dns2.oc" 'out-of-range dns octet'


cat > "$TMP/bad-pin2.oc" <<'EOF_BAD_PIN2'
server=https://vpn.example.com
fingerprint=pin-sha1:AA==
EOF_BAD_PIN2
expect_anyconnect_reject "$TMP/bad-pin2.oc" 'unknown fingerprint kind'
cat > "$TMP/totp.oc" <<'EOF_TOTP'
server=https://vpn.example.com
user=employee
token-mode=totp
token-secret=base32:JBSWY3DPEHPK3PXP
EOF_TOTP
validate_anyconnect "$TMP/totp.oc" || fail 'valid TOTP profile rejected'

# --- endpoints --------------------------------------------------------------
endpoints=$(anyconnect_endpoint_lines "$TMP/corp.oc")
[[ "$endpoints" == $'vpn.example.com|443|tcp\nvpn.example.com|0|udp' ]] ||
    fail "corp endpoints wrong: $endpoints"
endpoints=$(anyconnect_endpoint_lines "$TMP/full.oc")
[[ "$endpoints" == $'10.1.2.3|444|tcp\n10.1.2.3|0|udp' ]] ||
    fail "full endpoints wrong: $endpoints"
[[ $(profile_endpoints "$TMP/full.oc") == $'10.1.2.3|444|tcp\n10.1.2.3|0|udp' ]] ||
    fail 'profile_endpoints dispatcher'

# The DTLS port is server-advertised, so the kill switch uses the any-port
# UDP form (port 0). resolve_profile_endpoints must accept it for udp and
# reject it for any other protocol.
(
    resolve_profile_endpoints "$TMP/full.oc" "$TMP/endpoints-resolved" host
)
grep -Fq '10.1.2.3|444|tcp' "$TMP/endpoints-resolved" ||
    fail 'resolved endpoints lost the TLS line'
grep -Fq '10.1.2.3|0|udp' "$TMP/endpoints-resolved" ||
    fail 'resolved endpoints lost the any-port UDP line'
(
    profile_endpoints() { printf '10.1.2.3|0|tcp\n'; }
    if (resolve_profile_endpoints "$TMP/full.oc" "$TMP/endpoints-bad" host) >/dev/null 2>&1; then
        fail 'any-port marker accepted for tcp'
    fi
)

# --- openconnect_exec argument construction ----------------------------------
cat > "$TMP/fake-ip" <<'FAKE_IP'
#!/bin/bash
printf 'ip-args: %s\n' "$*" >>"$NNS_FAKE_LOG"
shift 3
exec "$@"
FAKE_IP
cat > "$TMP/fake-oc" <<'FAKE_OC'
#!/bin/bash
{
    printf 'oc-args:'
    printf ' <%s>' "$@"
    printf '\nstdin: '
    cat
    printf '\n'
} >>"$NNS_FAKE_LOG"
exit 0
FAKE_OC
chmod 755 "$TMP/fake-ip" "$TMP/fake-oc"
NNS_FAKE_LOG="$TMP/exec1.log"
(
    export NNS_FAKE_LOG
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=corp.oc; TUN_MTU=''; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-oc"; }
    ip_binary() { printf '%s\n' "$TMP/fake-ip"; }
    reset_namespace_bootstrap_dns() { return 0; }
    install() { return 0; }
    openconnect_exec edgewall "$TMP/corp.oc"
)
grep -Fq 'ip-args: netns exec mock-ns' "$TMP/exec1.log" ||
    fail 'openconnect not executed inside the namespace'
grep -Fq ' --non-inter ' "$TMP/exec1.log" || fail 'missing --non-inter'
grep -Fq ' --protocol anyconnect ' "$TMP/exec1.log" || fail 'missing --protocol anyconnect'
grep -Fq " --script $ENGINE_PATH _oc-hook edgewall " "$TMP/exec1.log" ||
    fail 'missing engine hook script'
grep -Fq " --interface $(openconnect_iface_name edgewall) " "$TMP/exec1.log" ||
    fail 'missing deterministic interface name'
grep -Fq ' --authgroup Employees ' "$TMP/exec1.log" || fail 'missing authgroup'
grep -Fq ' --user employee ' "$TMP/exec1.log" || fail 'missing user'
grep -Fq ' --passwd-on-stdin ' "$TMP/exec1.log" || fail 'missing passwd-on-stdin'
grep -Fq ' https://vpn.example.com' "$TMP/exec1.log" || fail 'missing server URL'
grep -Fq $'stdin: employee\ncorrect horse battery staple' "$TMP/exec1.log" ||
    fail 'credentials not piped on stdin'
grep -Fq -- ' --disable-ipv6 ' "$TMP/exec1.log" ||
    fail 'IPv4-only engine did not pass --disable-ipv6'
grep -Fq -- ' --queue-len 8 ' "$TMP/exec1.log" ||
    fail 'vhost-net was not disabled via a sub-16 queue length'
if grep -Fq -- '--cookie-on-stdin' "$TMP/exec1.log"; then fail 'unexpected cookie mode'; fi
if grep -Fq -- '--servercert' "$TMP/exec1.log"; then fail 'unexpected servercert'; fi

# DISABLE_IPV6=off opts back into openconnect's native dual-stack negotiation.
NNS_FAKE_LOG="$TMP/exec-ipv6.log"
(
    export NNS_FAKE_LOG
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=corp.oc; TUN_MTU=''; DISABLE_IPV6=off; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    cfg_read_value() { if [[ "$2" == DEFAULT_PROFILE ]]; then printf 'corp.oc\n'; fi; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-oc"; }
    ip_binary() { printf '%s\n' "$TMP/fake-ip"; }
    reset_namespace_bootstrap_dns() { return 0; }
    install() { return 0; }
    openconnect_exec edgewall "$TMP/corp.oc"
)
if grep -Fq -- '--disable-ipv6' "$TMP/exec-ipv6.log"; then fail 'DISABLE_IPV6=off still passed --disable-ipv6'; fi

# Saved session cookie wins over inline credentials.
cookie_file="$TMP/corp.oc.cookie"
printf '%s' 'AbCdEf0123456789+/=_-xyz' >"$cookie_file"
chmod 600 "$cookie_file"
NNS_FAKE_LOG="$TMP/exec2.log"
(
    export NNS_FAKE_LOG
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=corp.oc; TUN_MTU=''; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    cfg_read_value() { if [[ "$2" == DEFAULT_PROFILE ]]; then printf 'corp.oc\n'; fi; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-oc"; }
    ip_binary() { printf '%s\n' "$TMP/fake-ip"; }
    reset_namespace_bootstrap_dns() { return 0; }
    install() { return 0; }
    openconnect_exec edgewall "$TMP/corp.oc"
)
grep -Fq ' --cookie-on-stdin ' "$TMP/exec2.log" || fail 'cookie mode not selected'
grep -Fq $'stdin: AbCdEf0123456789+/=_-xyz' "$TMP/exec2.log" ||
    fail 'cookie not piped on stdin'
rm -f "$cookie_file"

# Without a cookie and without inline credentials the service must fail with
# an actionable hint instead of hanging on an interactive prompt.
(
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=nocreds.oc; TUN_MTU=''; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    cfg_read_value() { if [[ "$2" == DEFAULT_PROFILE ]]; then printf 'nocreds.oc\n'; fi; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-oc"; }
    ip_binary() { printf '%s\n' "$TMP/fake-ip"; }
    reset_namespace_bootstrap_dns() { return 0; }
    install() { return 0; }
    if (openconnect_exec edgewall "$TMP/nocreds.oc") >/dev/null 2>"$TMP/nocreds.err"; then
        fail 'credential-less profile was accepted'
    fi
)
grep -Fq 'oc-login edgewall' "$TMP/nocreds.err" || fail 'missing oc-login hint'

# With scriptable inline credentials, start obtains and persists a session
# cookie automatically so later restarts skip the gateway's login forms.
cat > "$TMP/fake-auth-oc" <<'FAKE_AUTH_OC'
#!/bin/bash
if [[ " $* " == *" --authenticate "* ]]; then
    printf "COOKIE='AutoCookie123456789+/=_-xyz'\n"
    exit 0
fi
{
    printf 'connect-args:'
    printf ' <%s>' "$@"
    printf '\nstdin: '
    cat
    printf '\n'
} >>"$NNS_FAKE_LOG"
exit 0
FAKE_AUTH_OC
chmod 755 "$TMP/fake-auth-oc"
rm -f "$TMP/corp.oc.cookie" "$TMP/corp.oc.cookie.no-auth" "$TMP/auto-saved-cookie"
NNS_FAKE_LOG="$TMP/exec3.log"
(
    export NNS_FAKE_LOG
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=corp.oc; TUN_MTU=''; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    cfg_read_value() { if [[ "$2" == DEFAULT_PROFILE ]]; then printf 'corp.oc\n'; fi; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-auth-oc"; }
    ip_binary() { printf '%s\n' "$TMP/fake-ip"; }
    reset_namespace_bootstrap_dns() { return 0; }
    install() { return 0; }
    anyconnect_save_cookie() { printf '%s' "$2" >"$TMP/auto-saved-cookie"; }
    openconnect_exec edgewall "$TMP/corp.oc"
)
[[ "$(cat "$TMP/auto-saved-cookie" 2>/dev/null)" == 'AutoCookie123456789+/=_-xyz' ]] ||
    fail 'start did not persist the automatically obtained cookie'
grep -Fq -- '--cookie-on-stdin' "$TMP/exec3.log" || fail 'fresh cookie not used for the connection'
grep -Fq $'stdin: AutoCookie123456789+/=_-xyz' "$TMP/exec3.log" ||
    fail 'fresh cookie not piped on stdin'

# A cookie the previous invocation logged as rejected is refreshed from the
# inline credentials instead of being reused.
printf 'OldCookie0123456789+/=_-xyz' >"$TMP/corp.oc.cookie"
chmod 600 "$TMP/corp.oc.cookie"
rm -f "$TMP/auto-saved-cookie"
NNS_FAKE_LOG="$TMP/exec4.log"
(
    export NNS_FAKE_LOG
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=corp.oc; TUN_MTU=''; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    cfg_read_value() { if [[ "$2" == DEFAULT_PROFILE ]]; then printf 'corp.oc\n'; fi; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-auth-oc"; }
    ip_binary() { printf '%s\n' "$TMP/fake-ip"; }
    reset_namespace_bootstrap_dns() { return 0; }
    install() { return 0; }
    anyconnect_auth_failure_detected() { return 0; }
    anyconnect_save_cookie() { printf '%s' "$2" >"$TMP/auto-saved-cookie"; }
    openconnect_exec edgewall "$TMP/corp.oc"
)
[[ "$(cat "$TMP/auto-saved-cookie" 2>/dev/null)" == 'AutoCookie123456789+/=_-xyz' ]] ||
    fail 'rejected cookie was reused instead of being refreshed'
rm -f "$TMP/corp.oc.cookie"

# A profile whose OTP must be entered interactively cannot auto-obtain a
# cookie; the direct credential path is used instead.
cat > "$TMP/totp-int.oc" <<'EOF_TOTP_INT'
server=https://vpn.example.com
user=employee
passwd=secret
token-mode=totp
EOF_TOTP_INT
rm -f "$TMP/auto-saved-cookie"
NNS_FAKE_LOG="$TMP/exec5.log"
(
    export NNS_FAKE_LOG
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=totp-int.oc; TUN_MTU=''; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    cfg_read_value() { if [[ "$2" == DEFAULT_PROFILE ]]; then printf 'totp-int.oc\n'; fi; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-auth-oc"; }
    ip_binary() { printf '%s\n' "$TMP/fake-ip"; }
    reset_namespace_bootstrap_dns() { return 0; }
    install() { return 0; }
    anyconnect_save_cookie() { printf '%s' "$2" >>"$TMP/auto-saved-cookie"; }
    openconnect_exec edgewall "$TMP/totp-int.oc"
)
[[ ! -e "$TMP/auto-saved-cookie" ]] ||
    fail 'interactive-OTP profile tried to auto-obtain a cookie'
# dtls=off must reach openconnect as --no-dtls.
NNS_FAKE_LOG="$TMP/exec-dtls.log"
(
    export NNS_FAKE_LOG
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=dtlsoff.oc; TUN_MTU=''; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    cfg_read_value() { if [[ "$2" == DEFAULT_PROFILE ]]; then printf 'dtlsoff.oc\n'; fi; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-oc"; }
    ip_binary() { printf '%s\n' "$TMP/fake-ip"; }
    reset_namespace_bootstrap_dns() { return 0; }
    install() { return 0; }
    openconnect_exec edgewall "$TMP/dtlsoff.oc"
)
grep -Fq -- ' --no-dtls ' "$TMP/exec-dtls.log" || fail 'dtls=off did not pass --no-dtls'

# Once a gateway is known not to expose a cookie to --authenticate, later
# starts must skip the doomed round trip and use inline credentials directly.
rm -f "$TMP/corp.oc.cookie" "$TMP/auto-saved-cookie"
: >"$TMP/corp.oc.cookie.no-auth"
NNS_FAKE_LOG="$TMP/exec6.log"
(
    export NNS_FAKE_LOG
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=corp.oc; TUN_MTU=''; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    cfg_read_value() { if [[ "$2" == DEFAULT_PROFILE ]]; then printf 'corp.oc\n'; fi; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-auth-oc"; }
    ip_binary() { printf '%s\n' "$TMP/fake-ip"; }
    reset_namespace_bootstrap_dns() { return 0; }
    install() { return 0; }
    anyconnect_save_cookie() { printf '%s' "$2" >"$TMP/auto-saved-cookie"; }
    openconnect_exec edgewall "$TMP/corp.oc"
)
if grep -Fq -- '--authenticate' "$TMP/exec6.log"; then fail 'no-auth marker did not skip cookie acquisition'; fi
[[ ! -e "$TMP/auto-saved-cookie" ]] || fail 'no-auth marker still saved a cookie'
grep -Fq -- '--passwd-on-stdin' "$TMP/exec6.log" || fail 'no-auth marker path did not use inline credentials'
rm -f "$TMP/corp.oc.cookie.no-auth"

grep -Fq -- '--passwd-on-stdin' "$TMP/exec5.log" ||
    fail 'interactive-OTP profile did not fall back to direct credentials'

# --- vpn_exec dispatch --------------------------------------------------------
# vpn_exec writes runtime markers under the root-owned $RUN_DIR, so the full
# dispatch path is exercised only where /run exists (Linux CI).
if [[ "$(uname -s)" == Linux ]]; then
(
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=corp.oc; TRANSPORT_TYPE=direct; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    openconnect_exec() { echo "dispatched $1 $2"; }
    require_root() { return 0; }
    ip() { printf 'mock-ns\n'; return 0; }
    install() { return 0; }
    vpn_exec edgewall >"$TMP/vpnexec.out"
)
grep -Fq 'dispatched edgewall' "$TMP/vpnexec.out" || fail 'vpn_exec dispatch'
(
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=corp.oc; TRANSPORT_TYPE=stunnel; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    require_root() { return 0; }
    ip() { printf 'mock-ns\n'; return 0; }
    install() { return 0; }
    if (vpn_exec edgewall) >/dev/null 2>&1; then fail 'transport wrapper accepted for anyconnect'; fi
)
fi

# --- hook: full tunnel --------------------------------------------------------
(
    state="$TMP/hook-full"; mkdir -p "$state"
    load_cfg() { NS_NAME=mock-ns; TUN_MTU=''; }
    openconnect_state_dir() { printf '%s\n' "$state"; }
    openconnect_hook_ns_ok() { return 0; }
    namespace_resolv_conf_path() { printf '%s/resolv.conf\n' "$TMP"; }
    install() { local last=${!#}; mkdir -p "$last"; }
    ip() { local IFS=' '; printf '%s\n' "$*" >>"$TMP/ip-full.log"; return 0; }
    INTERNAL_IP4_ADDRESS=10.9.8.7
    INTERNAL_IP4_NETMASK=255.255.255.0
    INTERNAL_IP4_MTU=1400
    INTERNAL_IP4_DNS='10.9.8.1 8.8.8.8'
    CISCO_DEF_DOMAIN=corp.example
    openconnect_hook_up edgewall tun1a2b3c4d
)
grep -Fq 'addr flush dev tun1a2b3c4d' "$TMP/ip-full.log" || fail 'no addr flush'
grep -Fq -- '-4 addr add 10.9.8.7/24 dev tun1a2b3c4d' "$TMP/ip-full.log" || fail 'wrong address/prefix'
grep -Fq 'link set dev tun1a2b3c4d mtu 1400' "$TMP/ip-full.log" || fail 'mtu not applied'
grep -Fq 'link set dev tun1a2b3c4d up' "$TMP/ip-full.log" || fail 'interface not brought up'
grep -Fq -- '-4 route replace default dev tun1a2b3c4d' "$TMP/ip-full.log" || fail 'no default route'
grep -Fq 'nameserver 10.9.8.1' "$TMP/resolv.conf" || fail 'pushed DNS missing'
grep -Fq 'nameserver 8.8.8.8' "$TMP/resolv.conf" || fail 'second DNS missing'
grep -Fq 'search corp.example' "$TMP/resolv.conf" || fail 'search domain missing'
[[ -f "$TMP/hook-full/edgewall.oc-ready" ]] || fail 'readiness marker missing'
[[ ! -e "$TMP/hook-full/edgewall.oc-split" ]] || fail 'split marker in full tunnel'

# --- hook: split tunnel + invalid DNS filtering ------------------------------
(
    state="$TMP/hook-split"; mkdir -p "$state"
    load_cfg() { NS_NAME=mock-ns; TUN_MTU=''; }
    openconnect_state_dir() { printf '%s\n' "$state"; }
    openconnect_hook_ns_ok() { return 0; }
    namespace_resolv_conf_path() { printf '%s/resolv-split.conf\n' "$TMP"; }
    install() { local last=${!#}; mkdir -p "$last"; }
    ip() { local IFS=' '; printf '%s\n' "$*" >>"$TMP/ip-split.log"; return 0; }
    INTERNAL_IP4_ADDRESS=10.7.7.7
    INTERNAL_IP4_NETMASK=24
    INTERNAL_IP4_DNS='10.7.7.1 999.1.1.1'
    export CISCO_SPLIT_INC_0_ADDR=10.0.0.0
    export CISCO_SPLIT_INC_0_MASKLEN=8
    export CISCO_SPLIT_INC_1_ADDR=192.168.50.0
    export CISCO_SPLIT_INC_1_MASK=255.255.255.0
    openconnect_hook_up edgewall tun2b3c4d5e
)
grep -Fq -- '-4 route replace 10.0.0.0/8 dev tun2b3c4d5e' "$TMP/ip-split.log" || fail 'missing MASKLEN split route'
grep -Fq -- '-4 route replace 192.168.50.0/24 dev tun2b3c4d5e' "$TMP/ip-split.log" || fail 'missing MASK split route'
if grep -Fq -- 'route replace default' "$TMP/ip-split.log"; then fail 'default route in split tunnel'; fi
# Pushed resolvers must always be reachable through the tunnel, even when the
# gateway omits them from its split includes; invalid addresses stay dropped.
grep -Fq -- '-4 route replace 10.7.7.1/32 dev tun2b3c4d5e' "$TMP/ip-split.log" ||
    fail 'pushed DNS server not routed through the split tunnel'
if grep -Fq -- '999.1.1.1' "$TMP/ip-split.log"; then fail 'invalid DNS server routed'; fi
# A full tunnel covers DNS via the default route; no /32 pinning expected.
if grep -Fq -- '10.9.8.1/32' "$TMP/ip-full.log"; then fail 'full tunnel pinned a DNS /32 route'; fi
[[ -f "$TMP/hook-split/edgewall.oc-split" ]] || fail 'split marker missing'
grep -Fq 'nameserver 10.7.7.1' "$TMP/resolv-split.conf" || fail 'valid DNS missing'
if grep -Fq '999.1.1.1' "$TMP/resolv-split.conf"; then fail 'invalid DNS written'; fi

# A gateway that pushes no resolvers must fall back to the profile dns= key;
# the fallback resolver gets a pinned tunnel route in split mode.
cat > "$TMP/dnsfallback.oc" <<'EOF_DNSFALLBACK'
server=https://vpn.example.com
dns=10.99.0.53
EOF_DNSFALLBACK
(
    state="$TMP/hook-dnsfb"; mkdir -p "$state"
    load_cfg() { NS_NAME=mock-ns; TUN_MTU=''; DEFAULT_PROFILE=dnsfallback.oc; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    openconnect_state_dir() { printf '%s\n' "$state"; }
    openconnect_hook_ns_ok() { return 0; }
    namespace_resolv_conf_path() { printf '%s/resolv-dnsfb.conf\n' "$TMP"; }
    install() { local last=${!#}; mkdir -p "$last"; }
    ip() { local IFS=' '; printf '%s\n' "$*" >>"$TMP/ip-dnsfb.log"; return 0; }
    INTERNAL_IP4_ADDRESS=10.7.7.7
    INTERNAL_IP4_NETMASK=24
    unset INTERNAL_IP4_DNS
    export CISCO_SPLIT_INC_0_ADDR=10.0.0.0
    export CISCO_SPLIT_INC_0_MASKLEN=8
    openconnect_hook_up edgewall tun6a7b8c9d
)
grep -Fq -- '-4 route replace 10.99.0.53/32 dev tun6a7b8c9d' "$TMP/ip-dnsfb.log" ||
    fail 'profile dns fallback not routed through the split tunnel'
grep -Fq 'nameserver 10.99.0.53' "$TMP/resolv-dnsfb.conf" ||
    fail 'profile dns fallback not written to the namespace resolver'

# With no pushed resolvers and no profile dns=, the VPN gateway address is
# used as the fallback resolver, and the configured bootstrap resolvers are
# appended (unpinned) so kill-switch-off setups can resolve public names
# directly. The gateway fallback itself IS pinned through the tunnel.
cat > "$TMP/plain.oc2" <<'EOF_PLAIN2'
server=https://vpn.example.com
EOF_PLAIN2
(
    state="$TMP/hook-gw"; mkdir -p "$state"
    load_cfg() { NS_NAME=mock-ns; TUN_MTU=''; DEFAULT_PROFILE=plain.oc2; DNS_SERVERS='1.1.1.1 9.9.9.9'; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    openconnect_state_dir() { printf '%s\n' "$state"; }
    openconnect_hook_ns_ok() { return 0; }
    namespace_resolv_conf_path() { printf '%s/resolv-gw.conf\n' "$TMP"; }
    install() { local last=${!#}; mkdir -p "$last"; }
    ip() { local IFS=' '; printf '%s\n' "$*" >>"$TMP/ip-gw.log"; return 0; }
    INTERNAL_IP4_ADDRESS=10.7.7.7
    INTERNAL_IP4_NETMASK=24
    unset INTERNAL_IP4_DNS
    VPNGATEWAY=10.98.0.1
    export CISCO_SPLIT_INC_0_ADDR=10.0.0.0
    export CISCO_SPLIT_INC_0_MASKLEN=8
    openconnect_hook_up edgewall tun7a8b9c0d
)
grep -Fq -- '-4 route replace 10.98.0.1/32 dev tun7a8b9c0d' "$TMP/ip-gw.log" ||
    fail 'VPN gateway fallback resolver not routed through the tunnel'
if grep -Fq -- '1.1.1.1/32' "$TMP/ip-gw.log"; then fail 'bootstrap DNS pinned through the tunnel'; fi
grep -Fq 'nameserver 10.98.0.1' "$TMP/resolv-gw.conf" ||
    fail 'VPN gateway fallback resolver not written'
grep -Fq 'nameserver 1.1.1.1' "$TMP/resolv-gw.conf" ||
    fail 'bootstrap fallback resolver not appended'
grep -Fq 'nameserver 9.9.9.9' "$TMP/resolv-gw.conf" ||
    fail 'second bootstrap fallback resolver not appended'

# attempt-reconnect must drop the readiness markers without touching the TUN
# (openconnect reuses it for the retry).
(
    state="$TMP/hook-attempt"; mkdir -p "$state"
    touch "$state/edgewall.oc-ready" "$state/edgewall.oc-split"
    load_cfg() { NS_NAME=mock-ns; }
    openconnect_state_dir() { printf '%s\n' "$state"; }
    ip() { printf '%s\n' "$*" >>"$TMP/ip-attempt.log"; return 0; }
    openconnect_hook edgewall attempt-reconnect
)
[[ ! -e "$TMP/hook-attempt/edgewall.oc-ready" ]] ||
    fail 'attempt-reconnect kept the ready marker'
[[ ! -e "$TMP/hook-attempt/edgewall.oc-split" ]] ||
    fail 'attempt-reconnect kept the split marker'
[[ ! -s "$TMP/ip-attempt.log" ]] || fail 'attempt-reconnect touched the network'

# --- hook: namespace guard and disconnect cleanup ----------------------------
(
    state="$TMP/hook-guard"; mkdir -p "$state"
    load_cfg() { NS_NAME=mock-ns; }
    openconnect_state_dir() { printf '%s\n' "$state"; }
    openconnect_hook_ns_ok() { return 1; }
    ip() { local IFS=' '; printf '%s\n' "$*" >>"$TMP/ip-guard.log"; return 0; }
    INTERNAL_IP4_ADDRESS=10.5.5.5
    openconnect_hook_up edgewall tun3c4d5e6f
)
[[ ! -s "$TMP/ip-guard.log" ]] || fail 'hook touched the network outside its namespace'
(
    state="$TMP/hook-down"; mkdir -p "$state"
    touch "$state/edgewall.oc-ready" "$state/edgewall.oc-split"
    load_cfg() { NS_NAME=mock-ns; }
    openconnect_state_dir() { printf '%s\n' "$state"; }
    openconnect_hook_ns_ok() { return 0; }
    reset_namespace_bootstrap_dns() { echo called >"$TMP/bootstrap.called"; }
    ip() { local IFS=' '; printf '%s\n' "$*" >>"$TMP/ip-down.log"; return 0; }
    openconnect_hook_down edgewall tun1a2b3c4d
)
[[ ! -e "$TMP/hook-down/edgewall.oc-ready" ]] || fail 'ready marker not removed on disconnect'
[[ ! -e "$TMP/hook-down/edgewall.oc-split" ]] || fail 'split marker not removed on disconnect'
grep -Fq 'link set dev tun1a2b3c4d down' "$TMP/ip-down.log" || fail 'tun not brought down'
grep -Fq 'link del dev tun1a2b3c4d' "$TMP/ip-down.log" || fail 'tun not deleted'
[[ -f "$TMP/bootstrap.called" ]] || fail 'bootstrap DNS not restored'

# --- oc-login ----------------------------------------------------------------
cat > "$TMP/fake-auth" <<'FAKE_AUTH'
#!/bin/bash
# Modern openconnect quotes the cookie: COOKIE='<value>'.
printf "COOKIE='AbCdEf0123456789+/=_-xyz'\n"
exit 0
FAKE_AUTH
chmod 755 "$TMP/fake-auth"
(
    load_cfg() { DEFAULT_PROFILE=corp.oc; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-auth"; }
    anyconnect_save_cookie() { printf '%s' "$2" >"$TMP/saved-cookie"; }
    require_root() { return 0; }
    openconnect_login edgewall >/dev/null
)
[[ $(cat "$TMP/saved-cookie") == 'AbCdEf0123456789+/=_-xyz' ]] || fail 'cookie not saved'
(
    load_cfg() { DEFAULT_PROFILE=nouser.oc; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-auth"; }
    require_root() { return 0; }
    if (openconnect_login edgewall) >/dev/null 2>&1; then
        fail 'oc-login accepted a profile without user='
    fi
)
(
    load_cfg() { DEFAULT_PROFILE=corp.oc; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    vpn_type_for_app() { printf 'wireguard\n'; }
    openconnect_binary() { printf '%s\n' "$TMP/fake-auth"; }
    require_root() { return 0; }
    if (openconnect_login edgewall) >/dev/null 2>&1; then
        fail 'oc-login accepted a non-AnyConnect app'
    fi
)

# openconnect runs the script via `/bin/sh -c` and passes the reason in the
# `reason` environment variable, not as an argv argument. The hook must honor
# the environment (with $2 remaining as a legacy argv fallback).
(
    load_cfg() { NS_NAME=mock-ns; }
    openconnect_hook_up() { printf 'UP-CALLED\n'; return 0; }
    openconnect_hook_down() { printf 'DOWN-CALLED\n'; return 0; }
    reason=connect
    [[ "$(openconnect_hook edgewall '')" == UP-CALLED ]] || fail 'env reason=connect ignored'
    reason=disconnect
    [[ "$(openconnect_hook edgewall '')" == DOWN-CALLED ]] || fail 'env reason=disconnect ignored'
    # Explicit argv reason still wins over the environment.
    reason=connect
    [[ "$(openconnect_hook edgewall disconnect)" == DOWN-CALLED ]] || fail 'argv reason overridden by env'
)
grep -Fq 'openconnect_hook "$2" "${3:-${reason:-}}"' "$ROOT/src/90-main.sh" ||
    fail 'hook dispatcher does not forward the reason environment variable'

# Full-contract simulation: openconnect invokes the vpnc-script as
# `/bin/sh -c "<script>"` and communicates reason/TUNDEV/pushed config only
# through the environment. The complete dispatcher+hook chain must configure
# the tunnel and record readiness.
STATE="$TMP/contract-state"; mkdir -p "$STATE"
(
    export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TMP/locks"
    export NNS_TEST_STATE="$STATE" NNS_TEST_IPLOG="$TMP/contract-ip.log"
    env \
        reason=connect \
        TUNDEV=tun5a6b7c8d \
        INTERNAL_IP4_ADDRESS=10.9.8.7 \
        INTERNAL_IP4_NETMASK=255.255.255.0 \
        INTERNAL_IP4_MTU=1400 \
        INTERNAL_IP4_DNS='10.9.8.1' \
        CISCO_DEF_DOMAIN=corp.example \
        bash -c '
            source "'"$ROOT"'/install_linux"
            require_root() { return 0; }
            load_cfg() { NS_NAME=mock-ns; TUN_MTU=""; }
            openconnect_state_dir() { printf "%s\n" "$NNS_TEST_STATE"; }
            openconnect_hook_ns_ok() { return 0; }
            namespace_resolv_conf_path() { printf "%s/resolv.conf\n" "$NNS_TEST_STATE"; }
            install() { return 0; }
            ip() { local IFS=" "; printf "%s\n" "$*" >>"$NNS_TEST_IPLOG"; return 0; }
            main _oc-hook edgewall
        '
)
grep -Fq -- '-4 addr add 10.9.8.7/24 dev tun5a6b7c8d' "$TMP/contract-ip.log" ||
    fail 'full-contract simulation did not configure the tunnel'
grep -Fq -- '-4 route replace default dev tun5a6b7c8d' "$TMP/contract-ip.log" ||
    fail 'full-contract simulation did not install the default route'
[[ -f "$STATE/edgewall.oc-ready" ]] || fail 'full-contract simulation did not record readiness'
grep -Fq 'nameserver 10.9.8.1' "$STATE/resolv.conf" ||
    fail 'full-contract simulation did not write pushed DNS'

# --- auth/cert failure detection --------------------------------------------
# Form error fields like "Login failed." and the trust-check "signer not
# found" line are printed on every healthy connection to multi-attempt
# gateways; only terminal markers may classify as fatal failures.
(
    journalctl() { printf 'Login failed.\n'; }
    if anyconnect_auth_failure_detected edgewall; then fail 'benign form error classified as auth failure'; fi
)
(
    journalctl() { printf 'Server certificate verify failed: signer not found\n'; }
    if anyconnect_cert_failure_detected edgewall; then fail 'benign trust-check line classified as cert failure'; fi
)
(
    journalctl() { printf 'Failed to complete authentication\n'; }
    anyconnect_auth_failure_detected edgewall || fail 'terminal auth failure not detected'
)
(
    journalctl() { printf 'Cookie was rejected by server; exiting.\n'; }
    anyconnect_auth_failure_detected edgewall || fail 'rejected cookie not detected'
)
(
    journalctl() { printf 'SSL connection failure: Error in the certificate.\n'; }
    anyconnect_cert_failure_detected edgewall || fail 'terminal cert failure not detected'
)
(
    journalctl() { printf 'None of the 1 fingerprint(s) specified via --servercert match the certificate\n'; }
    anyconnect_cert_failure_detected edgewall || fail 'pin mismatch not detected'
)

# Status diagnosis must ignore the same benign noise.
cat >"$TMP/diag-benign.log" <<'EOF_DIAG_BENIGN'
Server certificate verify failed: signer not found
Login failed.
Established DTLS connection (using GnuTLS). Ciphersuite (DTLS1.2)-(ECDHE-RSA)-(AES-256-GCM).
EOF_DIAG_BENIGN
diagnosis=$(openconnect_status_diagnosis "$TMP/diag-benign.log")
grep -Fqi 'authentication failed' <<<"$diagnosis" && fail 'benign log misdiagnosed as auth failure'
grep -Fqi 'certificate verification failed' <<<"$diagnosis" && fail 'benign log misdiagnosed as cert failure'
cat >"$TMP/diag-auth.log" <<'EOF_DIAG_AUTH'
Failed to complete authentication
EOF_DIAG_AUTH
openconnect_status_diagnosis "$TMP/diag-auth.log" | grep -Fqi 'authentication failed' ||
    fail 'terminal auth failure not diagnosed'
cat >"$TMP/diag-cert.log" <<'EOF_DIAG_CERT'
SSL connection failure: Error in the certificate.
EOF_DIAG_CERT
openconnect_status_diagnosis "$TMP/diag-cert.log" | grep -Fqi 'certificate verification failed' ||
    fail 'terminal cert failure not diagnosed'


# --- on-demand backend add-on installers -------------------------------------
# openconnect/wireguard tools must never be auto-installed by the engine; the
# explicit installers resolve only the missing commands to their packages.
rm -f "$TMP/backend-pkgs"
(
    oc_present=missing
    # Virtualize the binary: absent until the (mocked) package manager runs,
    # then present regardless of what this host actually has installed.
    command() {
        case "${2:-}" in
            openconnect) [[ "$oc_present" == installed ]] && return 0 || return 1 ;;
        esac
        builtin command "$@"
    }
    require_root() { return 0; }
    detect_platform_family() { printf 'debian\n'; }
    install_dependency_packages() {
        shift
        printf '%s\n' "$*" >>"$TMP/backend-pkgs"
        oc_present=installed
        return 0
    }
    log() { :; }
    install_openconnect_tools
)
grep -Fq 'openconnect' "$TMP/backend-pkgs" || fail 'openconnect add-on did not request its package'
(
    wg_present=missing
    command() {
        case "${2:-}" in
            wg|wg-quick) [[ "$wg_present" == installed ]] && return 0 || return 1 ;;
        esac
        builtin command "$@"
    }
    require_root() { return 0; }
    detect_platform_family() { printf 'fedora\n'; }
    install_dependency_packages() {
        shift
        printf '%s\n' "$*" >>"$TMP/backend-pkgs"
        wg_present=installed
        return 0
    }
    log() { :; }
    install_wireguard_tools
)
grep -Fq 'wireguard-tools' "$TMP/backend-pkgs" || fail 'wireguard add-on did not request its package'
# A missing binary must produce an actionable hint, not a generic error.
(
    PATH="$TMP/nonexistent-bin"
    if (openconnect_binary) >/dev/null 2>"$TMP/oc-missing.err"; then
        fail 'openconnect_binary succeeded without the binary'
    fi
)
grep -Fq 'nns-app --install openconnect' "$TMP/oc-missing.err" ||
    fail 'missing-binary error lacks the add-on installer hint'
# add must point at the matching installer when the backend binaries are gone.
grep -Fq 'nns-app --install openconnect' "$ROOT/src/30-profiles.sh" ||
    fail 'add does not suggest the openconnect add-on'
grep -Fq 'nns-app --install wireguard' "$ROOT/src/30-profiles.sh" ||
    fail 'add does not suggest the wireguard add-on'
grep -Fq 'nns-app --install amnezia' "$ROOT/src/30-profiles.sh" ||
    fail 'add does not suggest the amnezia add-on'

# --- route readiness and wait_online ------------------------------------------
# AnyConnect's multi-stage authentication needs a longer start window: at
# least 30s, while other backends keep the 5s default and -i/probe stays 1s.
[[ "$(start_readiness_timeout anyconnect off '')" == 30 ]] ||
    fail 'anyconnect does not get a 30s minimum readiness window'
[[ "$(start_readiness_timeout anyconnect off 5)" == 30 ]] ||
    fail 'configured 5s overrides the anyconnect minimum'
[[ "$(start_readiness_timeout anyconnect off 60)" == 60 ]] ||
    fail 'larger configured READY_TIMEOUT is not honored for anyconnect'
[[ "$(start_readiness_timeout openvpn off '')" == 5 ]] ||
    fail 'non-anyconnect backends lost the 5s default'
[[ "$(start_readiness_timeout anyconnect probe '')" == 1 ]] ||
    fail 'probe mode lost the 1s window'
[[ "$(start_readiness_timeout anyconnect on '')" == 1 ]] ||
    fail 'ignore-start-error did not keep the fast window'
(
    state="$TMP/route"; mkdir -p "$state"
    echo tun1234abcd >"$state/edgewall.oc-ready"
    cfg_read_value() { if [[ "$2" == NS_NAME ]]; then printf 'mock-ns\n'; fi; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    openconnect_iface_name() { printf 'tun1234abcd\n'; }
    openconnect_state_dir() { printf '%s\n' "$state"; }
    ip() {
        local IFS=' '
        case "$*" in
            "-n mock-ns link show dev tun1234abcd up") return 0 ;;
            "-n mock-ns -4 addr show dev tun1234abcd")
                printf '    inet 10.9.8.7/24 scope global tun1234abcd\n'; return 0 ;;
            "-n mock-ns -4 route show dev tun1234abcd")
                printf 'default dev tun1234abcd scope link\n'; return 0 ;;
            *) return 1 ;;
        esac
    }
    [[ $(vpn_route_iface edgewall) == tun1234abcd ]] || fail 'anyconnect vpn_route_iface'
    rm -f "$state/edgewall.oc-ready"
    if vpn_route_iface edgewall >/dev/null 2>&1; then fail 'marker missing but route ready'; fi
)
(
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=corp.oc; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    vpn_route_ready() { return 0; }
    wait_online edgewall 2 || fail 'anyconnect wait_online fails when route ready'
)
(
    load_cfg() { NS_NAME=mock-ns; DEFAULT_PROFILE=corp.oc; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    vpn_route_ready() { return 1; }
    if wait_online edgewall 1; then fail 'unready anyconnect accepted'; fi
)

# --- app_split_tunnel honors the runtime hook marker --------------------------
(
    cfg_read_value() { if [[ "$2" == DEFAULT_PROFILE ]]; then printf 'full.oc\n'; fi; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    profiles_dir() { printf '%s\n' "$TMP"; }
    openconnect_state_dir() { printf '%s\n' "$TMP/state-split"; }
    mkdir -p "$TMP/state-split"
    rm -f "$TMP/state-split/edgewall.oc-split"
    if app_split_tunnel edgewall; then fail 'full anyconnect classified split'; fi
    touch "$TMP/state-split/edgewall.oc-split"
    app_split_tunnel edgewall || fail 'runtime split marker ignored'
)

# --- watchdog: auth failures must not loop restarts --------------------------
grep -Fq 'anyconnect_auth_failure_detected "$app"' "$ROOT/src/50-runtime.sh" ||
    fail 'watchdog does not gate AnyConnect auth failures'
grep -Fq 'oc_stop_result=auth-required' "$ROOT/src/50-runtime.sh" ||
    fail 'watchdog does not record auth-required state'
# Behavioral check: an armed, offline AnyConnect app with an auth failure in
# the service log must be classified auth-required WITHOUT a backend restart.
(
    rm -f "$TMP/wd-restart"
    load_cfg() { NS_NAME=mock-ns; WATCHDOG_MODE=auto; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    watchdog_enabled_for_type() { return 0; }
    app_is_started() { return 0; }
    watchdog_namespace_exists() { return 0; }
    runtime_via_for_app() { printf 'host\n'; }
    wait_online() { return 1; }
    watchdog_state_load() {
        WD_ARMED=1; WD_FAILURES=3; WD_LAST_RESTART=0
        WD_TOTAL_RESTARTS=0; WD_LAST_CHECK=0; WD_LAST_RESULT=offline
    }
    watchdog_state_save() { :; }
    journalctl() { printf 'Failed to complete authentication\n'; }
    systemctl() { printf '%s\n' "$2" >>"$TMP/wd-restart"; return 0; }
    acquire_lock() { return 0; }
    release_lock() { return 0; }
    require_root() { return 0; }
    warn() { :; }
    watchdog_check edgewall
)
if [[ -s "$TMP/wd-restart" ]]; then fail 'watchdog restarted the backend on an auth failure'; fi
# A certificate verification failure is equally un-fixable by restarting.
(
    rm -f "$TMP/wd-restart"
    load_cfg() { NS_NAME=mock-ns; WATCHDOG_MODE=auto; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    watchdog_enabled_for_type() { return 0; }
    app_is_started() { return 0; }
    watchdog_namespace_exists() { return 0; }
    runtime_via_for_app() { printf 'host\n'; }
    wait_online() { return 1; }
    watchdog_state_load() {
        WD_ARMED=1; WD_FAILURES=3; WD_LAST_RESTART=0
        WD_TOTAL_RESTARTS=0; WD_LAST_CHECK=0; WD_LAST_RESULT=offline
    }
    watchdog_state_save() { :; }
    journalctl() { printf 'SSL connection failure: Error in the certificate.\n'; }
    systemctl() { printf '%s\n' "$2" >>"$TMP/wd-restart"; return 0; }
    acquire_lock() { return 0; }
    release_lock() { return 0; }
    require_root() { return 0; }
    warn() { :; }
    watchdog_check edgewall
)
if [[ -s "$TMP/wd-restart" ]]; then fail 'watchdog restarted the backend on a certificate failure'; fi
grep -Fq 'WD_LAST_RESULT=$oc_stop_result' "$ROOT/src/50-runtime.sh" ||
    fail 'watchdog does not record a distinct result for certificate failures'
grep -Fq 'oc_stop_result=config-required' "$ROOT/src/50-runtime.sh" ||
    fail 'watchdog does not classify certificate failures as config-required'
# Benign multi-attempt noise ("Login failed." + trust-check line) must NOT
# suppress the watchdog restart of an otherwise offline tunnel.
(
    rm -f "$TMP/wd-restart"
    load_cfg() { NS_NAME=mock-ns; WATCHDOG_MODE=auto; WATCHDOG_FAILURES=1; WATCHDOG_COOLDOWN=30; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    watchdog_enabled_for_type() { return 0; }
    app_is_started() { return 0; }
    watchdog_namespace_exists() { return 0; }
    runtime_via_for_app() { printf 'host\n'; }
    wait_online() { return 1; }
    watchdog_state_load() {
        WD_ARMED=1; WD_FAILURES=1; WD_LAST_RESTART=0
        WD_TOTAL_RESTARTS=0; WD_LAST_CHECK=0; WD_LAST_RESULT=offline
    }
    watchdog_state_save() { :; }
    journalctl() { printf 'Login failed.\nServer certificate verify failed: signer not found\n'; }
    systemctl() {
        printf '%s\n' "$2" >>"$TMP/wd-restart"
        if [[ "$2" == is-active ]]; then return 1; fi
        return 0
    }
    acquire_lock() { return 0; }
    release_lock() { return 0; }
    require_root() { return 0; }
    warn() { :; }
    log() { :; }
    restart_gateways_via_app() { :; }
    watchdog_check edgewall
)
grep -Fq 'nns-openvpn@edgewall.service' "$TMP/wd-restart" ||
    fail 'benign auth noise suppressed the watchdog restart'

# The same scenario WITHOUT an auth failure must reach the restart path.
(
    rm -f "$TMP/wd-restart"
    load_cfg() { NS_NAME=mock-ns; WATCHDOG_MODE=auto; WATCHDOG_FAILURES=1; WATCHDOG_COOLDOWN=30; }
    vpn_type_for_app() { printf 'anyconnect\n'; }
    watchdog_enabled_for_type() { return 0; }
    app_is_started() { return 0; }
    watchdog_namespace_exists() { return 0; }
    runtime_via_for_app() { printf 'host\n'; }
    wait_online() { return 1; }
    watchdog_state_load() {
        WD_ARMED=1; WD_FAILURES=1; WD_LAST_RESTART=0
        WD_TOTAL_RESTARTS=0; WD_LAST_CHECK=0; WD_LAST_RESULT=offline
    }
    watchdog_state_save() { :; }
    journalctl() { printf 'Established DTLS (CSTP)\n'; }
    systemctl() {
        printf '%s\n' "$2" >>"$TMP/wd-restart"
        if [[ "$2" == is-active ]]; then return 1; fi
        return 0
    }
    acquire_lock() { return 0; }
    release_lock() { return 0; }
    require_root() { return 0; }
    warn() { :; }
    log() { :; }
    restart_gateways_via_app() { :; }
    watchdog_check edgewall
)
grep -Fq 'nns-openvpn@edgewall.service' "$TMP/wd-restart" ||
    fail 'watchdog did not restart the backend on a network failure'

echo 'AnyConnect tests passed.'
