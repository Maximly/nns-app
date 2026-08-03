#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

export NNS_APP_SOURCE_ONLY=1
export NNS_APP_LOCK_DIR="$TEST_TMP/locks"
# shellcheck source=/dev/null
source "$ROOT/nns-app-install.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ "$(format_duration 0)" == 0s ]] || fail 'format_duration 0'
[[ "$(format_duration 59)" == 59s ]] || fail 'format_duration seconds'
[[ "$(format_duration 60)" == 1m ]] || fail 'format_duration minute'
[[ "$(format_duration 3660)" == '1h 1m' ]] || fail 'format_duration hour'

current_ns_id=$(namespace_ref_id /proc/self/ns/net)
[[ -n "$current_ns_id" ]] || fail 'current namespace identity'
[[ "$current_ns_id" == "$(namespace_ref_id /proc/self/ns/net)" ]] ||
    fail 'stable namespace identity'
if namespace_ref_id "$TEST_TMP/missing-netns" >/dev/null 2>&1; then
    fail 'missing namespace reference was accepted'
fi

if command_needs_namespaced_snap_mounts ping; then
    fail 'ordinary command incorrectly requires Snap mounts'
fi
if command_needs_namespaced_snap_mounts /usr/share/cursor/cursor; then
    fail 'non-Snap desktop command incorrectly requires Snap mounts'
fi
command_needs_namespaced_snap_mounts /snap/bin/firefox ||
    fail 'Snap alias path was not detected'
command_needs_namespaced_snap_mounts /usr/bin/snap ||
    fail 'snap launcher was not detected'

IFS='|' read -r tun host ns host_fwd host_mangle ns_fwd ns_nat ns_mangle \
    <<<"$(make_gateway_names my-relay)"
[[ -n "$tun" && -n "$host" && -n "$ns" ]] || fail 'gateway interface names'
for chain in "$host_fwd" "$host_mangle" "$ns_fwd" "$ns_nat" "$ns_mangle"; do
    (( ${#chain} <= 28 )) || fail "iptables chain name too long: $chain"
done

# A custom gateway device name does not begin with tun/tap. OpenVPN therefore
# requires an explicit dev-type or it rejects the server directive.
gateway_cfg_root="$TEST_TMP/gateway-config"
mkdir -p "$gateway_cfg_root/pki"
cat >"$gateway_cfg_root/gateway.cfg" <<'EOF_TEST_GATEWAY_CFG'
GATEWAY_NAME=unit-gateway
GATEWAY_BACKEND=openvpn
VIA_APP=unit-exit
TRANSPORT=ssh
LISTEN_PROTO=tcp
LISTEN_PORT=24443
OPENVPN_LISTEN_PROTO=tcp
OPENVPN_LISTEN_PORT=24443
PUBLIC_HOST=mlcloud
PUBLIC_PORT=22
CLIENT_POOL=10.253.99.0/24
DNS_SERVERS='1.1.1.1 9.9.9.9'
GATEWAY_TUN=ngwdeadbeef
SERVER_CN=nns-gateway-unit-gateway
EOF_TEST_GATEWAY_CFG
gateway_write_server_config unit-gateway "$gateway_cfg_root"
grep -Fxq 'dev-type tun' "$gateway_cfg_root/server.conf" ||
    fail 'gateway config omitted dev-type tun'
grep -Fxq 'dev ngwdeadbeef' "$gateway_cfg_root/server.conf" ||
    fail 'gateway config omitted custom device name'
dev_type_line=$(grep -nFx 'dev-type tun' "$gateway_cfg_root/server.conf" | cut -d: -f1)
dev_line=$(grep -nFx 'dev ngwdeadbeef' "$gateway_cfg_root/server.conf" | cut -d: -f1)
(( dev_type_line < dev_line )) || fail 'dev-type must precede the custom dev line'

lock_key="test-functions-$$"
acquire_lock "$lock_key"
acquire_lock "$lock_key"
safe_key=${lock_key//[^A-Za-z0-9_.-]/_}
[[ "${NNS_LOCK_DEPTH[$safe_key]}" == 2 ]] || fail 'nested lock depth'
release_lock "$lock_key"
[[ "${NNS_LOCK_DEPTH[$safe_key]}" == 1 ]] || fail 'nested lock release'
release_lock "$lock_key"
[[ -z "${NNS_LOCK_FDS[$safe_key]-}" ]] || fail 'lock descriptor cleanup'

all_known_ipv4_networks() {
    printf '%s\n' \
        10.240.0.0/30 \
        10.240.0.4/30
}
IFS='|' read -r net host_addr ns_addr <<<"$(allocate_network)"
[[ "$net" == 10.240.0.8/30 ]] || fail "unexpected app network: $net"
[[ "$host_addr" == 10.240.0.9/30 ]] || fail "unexpected host address: $host_addr"
[[ "$ns_addr" == 10.240.0.10/30 ]] || fail "unexpected namespace address: $ns_addr"

all_known_ipv4_networks() {
    printf '%s\n' \
        10.253.0.0/24 \
        10.239.0.0/30 \
        192.168.50.0/24
}
IFS='|' read -r pool transit transit_host transit_ns \
    <<<"$(allocate_gateway_networks '')"
[[ "$pool" == 10.253.1.0/24 ]] || fail "unexpected gateway pool: $pool"
[[ "$transit" == 10.239.0.4/30 ]] || fail "unexpected transit: $transit"

if allocate_gateway_networks 10.240.1.0/24 >/dev/null 2>&1; then
    fail 'reserved app-network range accepted as a gateway pool'
fi

gateway_route_id_in_use() {
    (( $1 < 22002 ))
}
[[ "$(allocate_gateway_table)" == '22002|12002' ]] ||
    fail 'route-table allocator did not skip occupied IDs'

cfg_read_value() {
    case "$1:$2" in
        B:UPSTREAM_APP) printf 'C\n' ;;
        C:UPSTREAM_APP) printf 'A\n' ;;
        *) printf '\n' ;;
    esac
}
if ( assert_no_via_cycle A B ) >/dev/null 2>&1; then
    fail 'indirect upstream cycle was accepted'
fi

TEST_STATUS_FILE="$TEST_TMP/openvpn-status.log"
printf '%s\n' \
    $'TITLE\tOpenVPN 2.7.0 x86_64-pc-linux-gnu' \
    $'TIME\t2026-08-03 10:00:00\t1785740400' \
    $'HEADER\tCLIENT_LIST\tCommon Name\tReal Address\tVirtual Address\tBytes Received\tBytes Sent\tConnected Since' \
    $'CLIENT_LIST\tmy-linux-client\t203.0.113.10:41000\t10.253.1.2\t1234\t5678\t2026-08-03 09:59:00' \
    >"$TEST_STATUS_FILE"

gateway_status_file() {
    printf '%s\n' "$TEST_STATUS_FILE"
}

parsed=$(gateway_connected_clients my-relay)
expected='my-linux-client|203.0.113.10:41000|10.253.1.2|1234|5678|2026-08-03 09:59:00'
[[ "$parsed" == "$expected" ]] || fail "status-v3 parser: $parsed"

# CRL validity must be derived from nextUpdate. `openssl crl` has no
# certificate-style -checkend option.
(
    crl="$TEST_TMP/test.crl"
    printf 'placeholder
' >"$crl"
    future=$(date -u -d '+2 hours' '+%b %e %T %Y GMT')
    past=$(date -u -d '-2 hours' '+%b %e %T %Y GMT')
    openssl() {
        printf 'nextUpdate=%s
' "$future"
    }
    gateway_crl_valid_for "$crl" 60 || fail 'future CRL was rejected'
    if gateway_crl_valid_for "$crl" 10800; then
        fail 'CRL with insufficient remaining lifetime was accepted'
    fi
    openssl() {
        printf 'nextUpdate=%s
' "$past"
    }
    if gateway_crl_valid_for "$crl" 0; then
        fail 'expired CRL was accepted'
    fi
)

tmp_pki="$TEST_TMP/pki"
tmp_backup="$TEST_TMP/pki-backup"
mkdir -p "$tmp_pki/newcerts" "$tmp_backup"
printf 'V\n' >"$tmp_pki/index.txt"
printf '1000\n' >"$tmp_pki/serial"
printf '1000\n' >"$tmp_pki/crlnumber"
printf 'cert\n' >"$tmp_pki/newcerts/1000.pem"
gateway_ca_snapshot "$tmp_pki" "$tmp_backup"
printf 'BROKEN\n' >"$tmp_pki/index.txt"
rm -f "$tmp_pki/newcerts/1000.pem"
gateway_ca_restore "$tmp_pki" "$tmp_backup"
[[ "$(<"$tmp_pki/index.txt")" == V ]] || fail 'CA index restore'
[[ -f "$tmp_pki/newcerts/1000.pem" ]] || fail 'CA newcerts restore'


[[ "$(vpn_type_label inherit)" == Inherit ]] || fail 'inherit backend label'

[[ "$(watchdog_numeric_setting 3 9 1 20)" == 3 ]] || fail 'watchdog numeric setting valid'
[[ "$(watchdog_numeric_setting bad 9 1 20)" == 9 ]] || fail 'watchdog numeric setting fallback'
WATCHDOG_MODE=auto
watchdog_enabled_for_type openvpn || fail 'auto watchdog omitted OpenVPN'
watchdog_enabled_for_type wireguard || fail 'auto watchdog omitted WireGuard'
if watchdog_enabled_for_type inherit; then
    fail 'inherit backend incorrectly enables its own watchdog'
fi
WATCHDOG_MODE=off
if watchdog_enabled_for_type openvpn; then
    fail 'disabled watchdog accepted OpenVPN'
fi
WATCHDOG_MODE=auto
watchdog_state_file() {
    printf '%s/run/%s.watchdog\n' "$TEST_TMP" "$1"
}
mkdir -p "$TEST_TMP/run"
WD_ARMED=1
WD_FAILURES=2
WD_LAST_RESTART=123
WD_TOTAL_RESTARTS=4
WD_LAST_CHECK=456
WD_LAST_RESULT=offline
watchdog_state_save test-watchdog
WD_ARMED=0 WD_FAILURES=0 WD_LAST_RESTART=0 WD_TOTAL_RESTARTS=0 WD_LAST_CHECK=0 WD_LAST_RESULT=never
watchdog_state_load test-watchdog
[[ "$WD_ARMED:$WD_FAILURES:$WD_LAST_RESTART:$WD_TOTAL_RESTARTS:$WD_LAST_CHECK:$WD_LAST_RESULT" == '1:2:123:4:456:offline' ]] ||
    fail 'watchdog state round-trip'


# Recovery is not allowed until a data path has been verified online once.
(
    require_root() { :; }
    validate_app_name() { :; }
    acquire_lock() { :; }
    release_lock() { :; }
    load_cfg() {
        NS_NAME=test-watchdog
        WATCHDOG_MODE=auto
        WATCHDOG_FAILURES=2
        WATCHDOG_COOLDOWN=300
    }
    vpn_type_for_app() { printf 'openvpn\n'; }
    app_is_started() { return 0; }
    watchdog_namespace_exists() { return 0; }
    runtime_via_for_app() { printf 'host\n'; }
    wait_online() { return 1; }
    SYSTEMCTL_RESTARTED=0
    systemctl() {
        if [[ "$1" == restart && "${2:-}" == nns-openvpn@test-watchdog.service ]]; then
            SYSTEMCTL_RESTARTED=1
        fi
        case "$1 $2" in
            'is-active --quiet') return 1 ;;
        esac
        return 0
    }
    watchdog_state_file() { printf '%s/unarmed.watchdog\n' "$TEST_TMP"; }
    rm -f "$TEST_TMP/unarmed.watchdog"
    watchdog_check test-watchdog >/dev/null 2>&1
    watchdog_state_load test-watchdog
    [[ "$WD_ARMED:$WD_FAILURES:$WD_LAST_RESULT" == '0:0:waiting-initial-online' ]] ||
        fail 'unarmed watchdog attempted recovery'
    [[ "$SYSTEMCTL_RESTARTED" == 0 ]] || fail 'unarmed watchdog restarted the backend'
)

# Once armed, the threshold restarts only the backend and records the attempt.
(
    require_root() { :; }
    validate_app_name() { :; }
    acquire_lock() { :; }
    release_lock() { :; }
    load_cfg() {
        NS_NAME=test-watchdog
        WATCHDOG_MODE=auto
        WATCHDOG_FAILURES=2
        WATCHDOG_COOLDOWN=300
    }
    vpn_type_for_app() { printf 'openvpn\n'; }
    app_is_started() { return 0; }
    watchdog_namespace_exists() { return 0; }
    runtime_via_for_app() { printf 'host\n'; }
    wait_online() { return 1; }
    SYSTEMCTL_RESTARTED=0
    systemctl() {
        if [[ "$1" == restart && "${2:-}" == nns-openvpn@test-watchdog.service ]]; then
            SYSTEMCTL_RESTARTED=1
        fi
        case "$1 $2" in
            'is-active --quiet') return 1 ;;
        esac
        return 0
    }
    watchdog_state_file() { printf '%s/armed.watchdog\n' "$TEST_TMP"; }
    rm -f "$TEST_TMP/armed.watchdog"
    WD_ARMED=1
    WD_FAILURES=1
    WD_LAST_RESTART=0
    WD_TOTAL_RESTARTS=0
    WD_LAST_CHECK=0
    WD_LAST_RESULT=offline
    watchdog_state_save test-watchdog
    watchdog_check test-watchdog >/dev/null 2>&1
    watchdog_state_load test-watchdog
    [[ "$WD_ARMED:$WD_FAILURES:$WD_TOTAL_RESTARTS:$WD_LAST_RESULT" == '1:0:1:recovered' ]] ||
        fail 'armed watchdog recovery state'
    [[ "$SYSTEMCTL_RESTARTED" == 1 ]] || fail 'armed watchdog did not restart only the backend unit'
)

validate_ssh_target 'maxim@example.net'
validate_ssh_target '[2001:db8::1]'
if ( validate_ssh_target '-oProxyCommand=bad' ) >/dev/null 2>&1; then
    fail 'unsafe SSH target accepted'
fi

bundle_dir="$TEST_TMP/bundle"
mkdir -p "$bundle_dir"
printf '%s\n' 'client' 'dev tun' 'proto tcp-client' 'remote 127.0.0.1 11940' >"$bundle_dir/client.ovpn"
cat >"$bundle_dir/manifest.json" <<'EOF_MANIFEST'
{
  "format": "nnslink",
  "version": 1,
  "gateway": "my-relay",
  "client": "my-linux-client",
  "generation": 2,
  "backend": "openvpn",
  "transport": "direct",
  "public_host": "vpn.example.net",
  "public_port": 443,
  "local_port": 11940
}
EOF_MANIFEST
python3 - "$bundle_dir" "$TEST_TMP/valid.nnslink" <<'PY_TEST_BUNDLE'
import pathlib,sys,tarfile
root=pathlib.Path(sys.argv[1])
with tarfile.open(sys.argv[2], 'w:gz') as tf:
    tf.add(root/'manifest.json', arcname='manifest.json')
    tf.add(root/'client.ovpn', arcname='client.ovpn')
PY_TEST_BUNDLE
manifest_output=$(nnslink_manifest_read "$TEST_TMP/valid.nnslink" "$TEST_TMP/extracted")
grep -Fq 'TRANSPORT="direct"' <<<"$manifest_output" || fail 'nnslink transport parsing'
grep -Fq 'GENERATION=2' <<<"$manifest_output" || fail 'nnslink generation parsing'

python3 - "$TEST_TMP/unsafe.nnslink" <<'PY_TEST_UNSAFE'
import io,tarfile,sys
with tarfile.open(sys.argv[1], 'w:gz') as tf:
    data=b'bad'
    info=tarfile.TarInfo('../escape')
    info.size=len(data)
    tf.addfile(info, io.BytesIO(data))
PY_TEST_UNSAFE
if nnslink_manifest_read "$TEST_TMP/unsafe.nnslink" "$TEST_TMP/unsafe-out" >/dev/null 2>&1; then
    fail 'unsafe nnslink path accepted'
fi

validate_transport_server_name 'www.bing.com'
if ( validate_transport_server_name 'vpn..example.net' ) >/dev/null 2>&1; then
    fail 'invalid Cloak decoy hostname accepted'
fi

malicious_dir="$TEST_TMP/malicious-bundle"
mkdir -p "$malicious_dir"
cp "$bundle_dir/client.ovpn" "$malicious_dir/client.ovpn"
cat >"$malicious_dir/manifest.json" <<'EOF_MALICIOUS_MANIFEST'
{
  "format": "nnslink",
  "version": 1,
  "gateway": "bad\";touch /tmp/nns-injected;#",
  "client": "my-linux-client",
  "generation": 1,
  "backend": "openvpn",
  "transport": "direct",
  "public_host": "vpn.example.net",
  "public_port": 443,
  "local_port": 11940
}
EOF_MALICIOUS_MANIFEST
python3 - "$malicious_dir" "$TEST_TMP/malicious.nnslink" <<'PY_TEST_MALICIOUS'
import pathlib,sys,tarfile
root=pathlib.Path(sys.argv[1])
with tarfile.open(sys.argv[2], 'w:gz') as tf:
    tf.add(root/'manifest.json', arcname='manifest.json')
    tf.add(root/'client.ovpn', arcname='client.ovpn')
PY_TEST_MALICIOUS
if nnslink_manifest_read "$TEST_TMP/malicious.nnslink" "$TEST_TMP/malicious-out" >/dev/null 2>&1; then
    fail 'unsafe nnslink manifest metadata accepted'
fi


# Both the human-readable `via --remote` form and the compact legacy alias
# must route to the same automatic installer without invoking the live system.
(
    reexec_as_root_if_needed() { :; }
    install_app() { printf 'install:%s:%s\n' "$1" "$2"; }
    remote_auto_install() { printf 'remote:%s:%s:%s\n' "$1" "$2" "$3"; }
    output=$(main install my-app via --remote maxim@mlcloud --remote-port 2222)
    grep -Fq 'install:my-app:__default__' <<<"$output" || fail 'via --remote did not install the local app'
    grep -Fq 'remote:my-app:maxim@mlcloud:2222' <<<"$output" || fail 'via --remote parser'
    output=$(main install my-app --via-remote maxim@mlcloud)
    grep -Fq 'remote:my-app:maxim@mlcloud:22' <<<"$output" || fail '--via-remote alias parser'
)

owner=0123456789abcdef
[[ "$(remote_auto_exit_name "$owner")" == ra-0123456789ab-exit ]] || fail 'automatic remote exit name'
[[ "$(remote_auto_gateway_name "$owner")" == ra-0123456789ab-gw ]] || fail 'automatic remote gateway name'
[[ "$(remote_auto_client_name "$owner")" == ra-0123456789ab-client ]] || fail 'automatic remote client name'
if ( validate_remote_owner_id '../bad' ) >/dev/null 2>&1; then
    fail 'unsafe automatic-remote owner ID accepted'
fi

ssh_bundle_dir="$TEST_TMP/ssh-bundle"
mkdir -p "$ssh_bundle_dir"
printf '%s\n' 'client' 'dev tun' 'proto tcp-client' 'remote 127.0.0.1 11940' >"$ssh_bundle_dir/client.ovpn"
cat >"$ssh_bundle_dir/manifest.json" <<'EOF_SSH_MANIFEST'
{
  "format": "nnslink",
  "version": 1,
  "gateway": "my-relay",
  "client": "my-linux-client",
  "generation": 3,
  "backend": "openvpn",
  "transport": "ssh",
  "public_host": "mlcloud.example.net",
  "public_port": 22,
  "local_port": 11940,
  "ssh_remote_port": 24567
}
EOF_SSH_MANIFEST
python3 - "$ssh_bundle_dir" "$TEST_TMP/ssh-valid.nnslink" <<'PY_TEST_SSH_BUNDLE'
import pathlib,sys,tarfile
root=pathlib.Path(sys.argv[1])
with tarfile.open(sys.argv[2], 'w:gz') as tf:
    tf.add(root/'manifest.json', arcname='manifest.json')
    tf.add(root/'client.ovpn', arcname='client.ovpn')
PY_TEST_SSH_BUNDLE
ssh_manifest_output=$(nnslink_manifest_read "$TEST_TMP/ssh-valid.nnslink" "$TEST_TMP/ssh-extracted")
grep -Fq 'TRANSPORT="ssh"' <<<"$ssh_manifest_output" || fail 'SSH nnslink transport parsing'
grep -Fq 'SSH_REMOTE_PORT=24567' <<<"$ssh_manifest_output" || fail 'SSH nnslink private port parsing'

# Remote command payloads must use literal spaces even though nns-app globally
# sets IFS to newline/tab. Every argument must survive one remote-shell parse.
remote_payload=$(remote_auto_command_payload \
    deploy 0123456789abcdef mlcloud 22 'Norway Sandefjord S23.ovpn')
[[ "$remote_payload" != *$'\n'* ]] || fail 'automatic-remote payload contains argument-separating newlines'
mapfile -d '' -t remote_argv < <(
    PAYLOAD="$remote_payload" python3 - <<'PY_REMOTE_ARGV'
import os
import shlex
import sys
for arg in shlex.split(os.environ['PAYLOAD']):
    sys.stdout.buffer.write(arg.encode() + b'\0')
PY_REMOTE_ARGV
)
expected_remote_argv=(
    exec sudo -n /usr/local/sbin/nns_app.sh _remote-auto
    deploy 0123456789abcdef mlcloud 22 'Norway Sandefjord S23.ovpn'
)
[[ "${remote_argv[*]}" == "${expected_remote_argv[*]}" ]] ||
    fail "automatic-remote payload lost arguments: ${remote_argv[*]}"

manual_payload=$(remote_command_payload gateway client export \
    my-relay 'client with spaces' --output '-')
[[ "$manual_payload" != *$'\n'* ]] || fail 'manual remote payload contains argument-separating newlines'
[[ "$manual_payload" == *'client\ with\ spaces'* ]] ||
    fail 'manual remote payload did not shell-quote a spaced argument'


# Starting an automatic-remote app before `add` must report the intended
# pending state rather than a generic missing-backend error.
(
    require_root() { :; }
    validate_app_name() { :; }
    load_cfg() {
        REMOTE_MODE=auto
        DEFAULT_PROFILE=
        VPN_TYPE=
    }
    output=$(start_app pending-remote off __default__ 2>&1) &&
        fail 'pending automatic-remote app unexpectedly started'
    grep -Fq "no provider profile has been deployed" <<<"$output" ||
        fail "pending automatic-remote start message: $output"
    grep -Fq "nns-app add pending-remote /path/to/profile.ovpn" <<<"$output" ||
        fail 'pending automatic-remote start omitted recovery command'
)


echo 'Function tests passed.'
