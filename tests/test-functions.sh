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

# Distribution-specific dependency resolution must remain deterministic.
fedora_os_release="$TEST_TMP/fedora-os-release"
cat >"$fedora_os_release" <<'EOF_TEST_FEDORA_OS_RELEASE'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=44
EOF_TEST_FEDORA_OS_RELEASE
NNS_APP_OS_RELEASE_FILE="$fedora_os_release"
export NNS_APP_OS_RELEASE_FILE
[[ "$(detect_platform_family)" == fedora ]] || fail 'Fedora platform detection'
[[ "$(dependency_package_for fedora ip)" == iproute ]] || fail 'Fedora iproute package mapping'
[[ "$(dependency_package_for fedora iptables)" == iptables-nft ]] || fail 'Fedora iptables package mapping'
[[ "$(dependency_package_for fedora ping)" == iputils ]] || fail 'Fedora ping package mapping'
[[ "$(dependency_package_for fedora ssh)" == openssh-clients ]] || fail 'Fedora SSH package mapping'

ubuntu_os_release="$TEST_TMP/ubuntu-os-release"
cat >"$ubuntu_os_release" <<'EOF_TEST_UBUNTU_OS_RELEASE'
NAME="Ubuntu"
ID=ubuntu
ID_LIKE=debian
EOF_TEST_UBUNTU_OS_RELEASE
NNS_APP_OS_RELEASE_FILE="$ubuntu_os_release"
[[ "$(detect_platform_family)" == debian ]] || fail 'Ubuntu platform detection'
unset NNS_APP_OS_RELEASE_FILE

fake_openvpn_26="$TEST_TMP/openvpn-2.6"
cat >"$fake_openvpn_26" <<'EOF_TEST_OPENVPN_26'
#!/bin/sh
[ "$1" = --help ] && { echo 'OpenVPN options'; exit 0; }
EOF_TEST_OPENVPN_26
chmod 0755 "$fake_openvpn_26"
(
    openvpn_binary() { printf '%s\n' "$fake_openvpn_26"; }
    if openvpn_supports_dns_updown; then
        fail 'OpenVPN 2.6-style help incorrectly advertises dns-updown'
    fi
)
fake_openvpn_27="$TEST_TMP/openvpn-2.7"
cat >"$fake_openvpn_27" <<'EOF_TEST_OPENVPN_27'
#!/bin/sh
[ "$1" = --help ] && { echo '  --dns-updown mode'; exit 0; }
EOF_TEST_OPENVPN_27
chmod 0755 "$fake_openvpn_27"
(
    openvpn_binary() { printf '%s\n' "$fake_openvpn_27"; }
    openvpn_supports_dns_updown || fail 'OpenVPN 2.7 dns-updown capability detection'
)

unprivileged_group=$(nns_unprivileged_group)
getent group "$unprivileged_group" >/dev/null 2>&1 ||
    fail 'unprivileged group helper returned an unknown group'

# Active firewalld receives both persistent and runtime objects. The zone has a
# DROP target for host input; the policy only permits forwarding onward.
(
    firewalld_log="$TEST_TMP/firewalld.log"
    firewall-cmd() {
        local arg
        for arg in "$@"; do printf '%s ' "$arg" >>"$firewalld_log"; done
        printf '\n' >>"$firewalld_log"
        for arg in "$@"; do
            case "$arg" in
                --state) return 0 ;;
                --get-zones) printf 'public\n'; return 0 ;;
                --get-policies) printf '\n'; return 0 ;;
            esac
        done
        return 0
    }
    firewalld_interface_add nns-unit-host
    grep -Fq -- '--permanent --new-zone=nns-app' "$firewalld_log" ||
        fail 'firewalld permanent zone was not created'
    grep -Fq -- '--zone=nns-app --set-target=DROP' "$firewalld_log" ||
        fail 'firewalld zone target was not restricted'
    grep -Fq -- '--permanent --new-policy=nns-app-forward' "$firewalld_log" ||
        fail 'firewalld permanent policy was not created'
    grep -Fq -- '--policy=nns-app-forward --add-ingress-zone=nns-app' "$firewalld_log" ||
        fail 'firewalld ingress zone was not configured'
    grep -Fq -- '--policy=nns-app-forward --add-egress-zone=ANY' "$firewalld_log" ||
        fail 'firewalld egress zone was not configured'
    grep -Fq -- '--policy=nns-app-forward --set-target=ACCEPT' "$firewalld_log" ||
        fail 'firewalld forwarding target was not configured'
    grep -Fq -- '--permanent --zone=nns-app --add-interface=nns-unit-host' "$firewalld_log" ||
        fail 'firewalld persistent interface assignment was omitted'
)


# Public gateways own their host-firewall exceptions. UFW rules are tagged,
# removed on shutdown/removal, and pre-existing administrator rules are not
# claimed or deleted.
(
    fwtest="$TEST_TMP/public-fw-ufw"
    mkdir -p "$fwtest"
    rules="$fwtest/rules"
    logf="$fwtest/ufw.log"
    : >"$rules"
    : >"$logf"

    gateway_ufw_state_file() { printf '%s/state\n' "$fwtest"; }
    gateway_firewalld_state_file() { printf '%s/fwld-state\n' "$fwtest"; }
    firewalld_is_active() { return 1; }
    gateway_iptables_public_down() { :; }
    ufw() {
        printf '%s\n' "$*" >>"$logf"
        case "${1:-} ${2:-}" in
            'status '*) printf 'Status: active\n'; return 0 ;;
            'show added') cat "$rules"; return 0 ;;
            'allow 25108/tcp')
                printf "ufw allow 25108/tcp comment 'nns-app:gateway:test-public:public-input'\n" >"$rules"
                return 0
                ;;
            'delete allow')
                : >"$rules"
                return 0
                ;;
        esac
        return 0
    }

    TRANSPORT=direct
    LISTEN_PORT=25108
    LISTEN_PROTO=tcp
    gateway_public_firewall_up test-public || fail 'UFW public firewall open failed'
    [[ -e "$fwtest/state" ]] || fail 'UFW ownership marker was not created'
    grep -Fq "comment 'nns-app:gateway:test-public:public-input'" "$rules" ||
        fail 'UFW managed public rule was not created'
    gateway_public_firewall_down test-public || fail 'UFW public firewall close failed'
    [[ ! -e "$fwtest/state" ]] || fail 'UFW ownership marker survived successful close'
    [[ ! -s "$rules" ]] || fail 'UFW managed public rule survived gateway close'
)

(
    fwtest="$TEST_TMP/public-fw-ufw-preexisting"
    mkdir -p "$fwtest"
    rules="$fwtest/rules"
    logf="$fwtest/ufw.log"
    printf "ufw allow 25108/tcp comment 'administrator-owned'\n" >"$rules"
    : >"$logf"

    gateway_ufw_state_file() { printf '%s/state\n' "$fwtest"; }
    ufw() {
        printf '%s\n' "$*" >>"$logf"
        case "${1:-} ${2:-}" in
            'status '*) printf 'Status: active\n'; return 0 ;;
            'show added') cat "$rules"; return 0 ;;
            allow*|delete*) fail 'UFW pre-existing administrator rule was modified' ;;
        esac
        return 0
    }

    gateway_ufw_public_up test-public 25108 tcp ||
        fail 'pre-existing UFW allow was not accepted'
    [[ ! -e "$fwtest/state" ]] || fail 'pre-existing UFW rule was incorrectly claimed'
    gateway_ufw_public_down test-public 25108 tcp ||
        fail 'pre-existing UFW cleanup should be a no-op'
    grep -Fq "administrator-owned" "$rules" ||
        fail 'pre-existing UFW rule was removed'
)

# firewalld ownership is persisted only for ports nns-app itself created, and
# both runtime and permanent scopes are removed again on gateway shutdown.
(
    fwtest="$TEST_TMP/public-fw-firewalld"
    mkdir -p "$fwtest"
    runtime="$fwtest/runtime"
    permanent="$fwtest/permanent"
    : >"$runtime"
    : >"$permanent"

    gateway_firewalld_state_file() { printf '%s/state\n' "$fwtest"; }
    firewalld_is_active() { return 0; }
    firewalld_public_zone() { printf 'public\n'; }
    firewalld_port_query() {
        local scope=$1
        grep -Fxq '25108/tcp' "${scope/permanent/$permanent}" 2>/dev/null && return 0
        if [[ "$scope" == runtime ]]; then grep -Fxq '25108/tcp' "$runtime" 2>/dev/null; else grep -Fxq '25108/tcp' "$permanent" 2>/dev/null; fi
    }
    firewalld_port_add() {
        local scope=$1
        if [[ "$scope" == runtime ]]; then printf '25108/tcp\n' >"$runtime"; else printf '25108/tcp\n' >"$permanent"; fi
    }
    firewalld_port_remove() {
        local scope=$1
        if [[ "$scope" == runtime ]]; then : >"$runtime"; else : >"$permanent"; fi
    }

    gateway_firewalld_public_up test-public 25108 tcp ||
        fail 'firewalld public firewall open failed'
    [[ "$(cat "$fwtest/state")" == public ]] || fail 'firewalld ownership zone was not recorded'
    grep -Fxq '25108/tcp' "$runtime" || fail 'firewalld runtime port was not opened'
    grep -Fxq '25108/tcp' "$permanent" || fail 'firewalld permanent port was not opened'
    gateway_firewalld_public_down test-public 25108 tcp ||
        fail 'firewalld public firewall close failed'
    [[ ! -e "$fwtest/state" ]] || fail 'firewalld ownership marker survived close'
    [[ ! -s "$runtime" && ! -s "$permanent" ]] ||
        fail 'firewalld managed port survived gateway close'
)

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


# Destructive lifecycle operations must not tear down the namespace containing
# their own caller. This commonly happens after `nns-app run my-app bash`.
(
    current_nns_app() { printf 'inside-app\n'; }
    if output=$(assert_destructive_command_from_host "stop 'inside-app'" 2>&1); then
        fail 'destructive command was allowed from inside an nns-app namespace'
    fi
    grep -Fq "Cannot stop 'inside-app' from inside nns-app environment 'inside-app'" <<<"$output" ||
        fail 'inside-namespace stop diagnostic'
    grep -Fq "Exit the shell/application started by 'nns-app run inside-app ...'" <<<"$output" ||
        fail 'inside-namespace stop recovery guidance'
)
(
    current_nns_app() { return 1; }
    assert_destructive_command_from_host "stop 'host-app'"
)


# `myip` without an app follows the shell's current namespace and must not
# escalate. An explicit app selects that app regardless of the current shell.
(
    require_root() { fail 'context-only myip unexpectedly required root'; }
    current_nns_app() { printf 'inside-app\n'; }
    myip_report_app() { printf 'APP:%s:%s\n' "$1" "$2"; }
    myip_report_host() { printf 'HOST:%s\n' "$1"; }
    output=$(myip_command)
    [[ "$output" == 'APP:inside-app:current' ]] ||
        fail "myip did not select the current app context: $output"
)
(
    require_root() { fail 'context-hint myip unexpectedly required root'; }
    current_nns_app() { return 1; }
    myip_host_namespace() { return 1; }
    cfg_file() { printf '%s/context-app.cfg\n' "$TEST_TMP"; }
    : >"$TEST_TMP/context-app.cfg"
    NNS_APP_CONTEXT=context-app
    myip_report_app() { printf 'APP:%s:%s\n' "$1" "$2"; }
    myip_report_host() { printf 'HOST:%s\n' "$1"; }
    output=$(myip_command)
    [[ "$output" == 'APP:context-app:current' ]] ||
        fail "myip did not use the run-context hint: $output"
)
(
    require_root() { fail 'host-context myip unexpectedly required root'; }
    current_nns_app() { return 1; }
    myip_host_namespace() { return 0; }
    myip_report_app() { printf 'APP:%s:%s\n' "$1" "$2"; }
    myip_report_host() { printf 'HOST:%s\n' "$1"; }
    output=$(myip_command)
    [[ "$output" == 'HOST:host' ]] ||
        fail "myip did not select the host context: $output"
)
(
    require_root() { printf 'ROOT\n'; }
    myip_report_app() { printf 'APP:%s:%s\n' "$1" "$2"; }
    output=$(myip_command named-app)
    [[ "$output" == $'ROOT\nAPP:named-app:namespace' ]] ||
        fail "explicit myip app selection failed: $output"
)
[[ "$(myip_ssh_host 'user@remote-host')" == remote-host ]] ||
    fail 'myip SSH route report did not remove the account name'
(
    REMOTE_MODE=auto
    TRANSPORT_SSH_TARGET=user@remote-host
    TRANSPORT_REMOTE_HOST=remote-host
    TRANSPORT_REMOTE_PORT=2222
    REMOTE_GATEWAY=managed-gateway
    REMOTE_EXIT_APP=managed-exit
    path=$(myip_app_route_path named-app tun0 '' openvpn host)
    [[ "$path" == *'SSH:remote-host:2222'* ]] ||
        fail "automatic-remote myip path omitted the remote hop: $path"
    [[ "$path" != *'user@'* ]] ||
        fail "automatic-remote myip path exposed the SSH account: $path"
    [[ "$path" == *'gateway:managed-gateway -> exit:managed-exit'* ]] ||
        fail "automatic-remote myip path omitted gateway/exit details: $path"
)

caller_path='/home/test-user/.local/bin:/opt/test-tools/bin'
composed_path=$(compose_user_run_path "$caller_path")
[[ "$composed_path" == "$caller_path:"* ]] ||
    fail 'caller PATH order was not preserved'
for required_path in /usr/local/sbin /usr/sbin /sbin /usr/bin /bin /snap/bin; do
    case ":$composed_path:" in
        *":$required_path:"*) ;;
        *) fail "standard command directory missing from run PATH: $required_path" ;;
    esac
done
empty_composed_path=$(compose_user_run_path '')
[[ "$empty_composed_path" == /usr/local/sbin:* ]] ||
    fail 'empty caller PATH did not receive the standard system path'

# A locally selected free profile uses the local importer. Automatic-remote
# apps must divert before any local download or probe and ask the remote host
# to perform selection instead.
(
    add_profile() { printf 'LOCAL:%s:%s\n' "$1" "$2"; }
    output=$(add_selected_profile_for_app sample-app /tmp/free.ovpn)
    [[ "$output" == 'LOCAL:sample-app:/tmp/free.ovpn' ]] ||
        fail "free profile did not use the local importer: $output"
)
(
    require_root() { :; }
    validate_app_name() { :; }
    load_cfg() { REMOTE_MODE=auto; }
    remote_auto_add_any_profile() { printf 'REMOTE-ANY:%s:%s:%s\n' "$1" "$2" "$3"; }
    output=$(add_any_profile sample-app JP on __default__)
    [[ "$output" == 'REMOTE-ANY:sample-app:JP:on' ]] ||
        fail "automatic free-profile selection did not run remotely: $output"
)

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

snap_wrapper="$TEST_TMP/firefox-transition-wrapper"
cat >"$snap_wrapper" <<'EOF_TEST_SNAP_WRAPPER'
#!/bin/sh
exec /snap/bin/firefox "$@"
EOF_TEST_SNAP_WRAPPER
chmod 0755 "$snap_wrapper"
command_needs_namespaced_snap_mounts "$snap_wrapper" ||
    fail 'distro transition wrapper to /snap/bin was not detected'

snap_run_wrapper="$TEST_TMP/chromium-transition-wrapper"
cat >"$snap_run_wrapper" <<'EOF_TEST_SNAP_RUN_WRAPPER'
#!/bin/sh
exec /usr/bin/snap run chromium "$@"
EOF_TEST_SNAP_RUN_WRAPPER
chmod 0755 "$snap_run_wrapper"
command_needs_namespaced_snap_mounts "$snap_run_wrapper" ||
    fail 'distro transition wrapper using snap run was not detected'

native_script="$TEST_TMP/native-script"
cat >"$native_script" <<'EOF_TEST_NATIVE_SCRIPT'
#!/bin/sh
echo native
EOF_TEST_NATIVE_SCRIPT
chmod 0755 "$native_script"
if command_needs_namespaced_snap_mounts "$native_script"; then
    fail 'ordinary script incorrectly requires Snap mounts'
fi

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
PUBLIC_HOST=remote-host
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

# OpenVPN appends tun_dev, tun_mtu, a compatibility zero, local/remote
# addresses, and init/restart after the configured --up command arguments.
# The dispatcher must retain the configured gateway name and ignore the rest.
(
    require_root() { :; }
    gateway_tun_up() { [[ "$1" == unit-gateway ]]; }
    main _gateway-tun-up unit-gateway ngwdeadbeef 1500 0 \
        10.253.99.1 10.253.99.2 init
) || fail 'gateway up callback rejected OpenVPN-appended arguments'

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

validate_ssh_target 'user@example.net'
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
    output=$(main install my-app via --remote user@remote-host --remote-port 2222)
    grep -Fq 'install:my-app:__default__' <<<"$output" || fail 'via --remote did not install the local app'
    grep -Fq 'remote:my-app:user@remote-host:2222' <<<"$output" || fail 'via --remote parser'
    output=$(main install my-app --via-remote user@remote-host)
    grep -Fq 'remote:my-app:user@remote-host:22' <<<"$output" || fail '--via-remote alias parser'
)

# Automatic remote mode must opt the local app into boot recovery while the
# ordinary install default remains unchanged. A pending app records autostart
# but cannot start until its provider profile has been deployed.
(
    require_root() { :; }
    validate_app_name() { :; }
    remote_auto_resolve_ssh() { printf '%s\n' 'user@remote-host|22|remote-host'; }
    remote_auto_owner_id() { printf '%s\n' 0123456789abcdef; }
    remote_auto_alias() { printf '%s\n' auto-test; }
    remote_auto_is_current() { return 0; }
    remote_auto_bootstrap() { fail 'current automatic remote unexpectedly bootstrapped'; }
    remote_auto_register() { fail 'current automatic remote unexpectedly registered'; }
    remote_dir() { printf '%s\n' /tmp/nns-auto-test; }
    remote_known_hosts() { printf '%s\n' /tmp/nns-auto-test/known_hosts; }
    cfg_set() { printf 'set:%s:%s:%s\n' "$1" "$2" "$3"; }
    start_app() { printf 'start:%s:%s:%s\n' "$1" "$2" "$3"; }
    log() { printf 'log:%s\n' "$*"; }
    load_cfg() {
        APP_USER=test-user
        REMOTE_MODE=
        TRANSPORT_SSH_TARGET=
        VPN_TYPE=
        DEFAULT_PROFILE=
    }
    output=$(remote_auto_install my-app user@remote-host 22)
    grep -Fq 'set:my-app:AUTOSTART:on' <<<"$output" ||
        fail 'pending automatic remote did not enable autostart'
    if grep -Fq 'start:my-app:' <<<"$output"; then
        fail 'pending automatic remote attempted to start without a profile'
    fi
)

# Reconciliation of an already configured automatic-remote app must enable
# autostart and start it immediately.
(
    require_root() { :; }
    validate_app_name() { :; }
    remote_auto_resolve_ssh() { printf '%s\n' 'user@remote-host|22|remote-host'; }
    remote_auto_owner_id() { printf '%s\n' 0123456789abcdef; }
    remote_auto_alias() { printf '%s\n' auto-test; }
    remote_auto_is_current() { return 0; }
    remote_auto_bootstrap() { fail 'current automatic remote unexpectedly bootstrapped'; }
    remote_auto_register() { fail 'current automatic remote unexpectedly registered'; }
    remote_dir() { printf '%s\n' /tmp/nns-auto-test; }
    remote_known_hosts() { printf '%s\n' /tmp/nns-auto-test/known_hosts; }
    cfg_set() { printf 'set:%s:%s:%s\n' "$1" "$2" "$3"; }
    start_app() { printf 'start:%s:%s:%s\n' "$1" "$2" "$3"; }
    log() { printf 'log:%s\n' "$*"; }
    load_cfg() {
        APP_USER=test-user
        REMOTE_MODE=auto
        TRANSPORT_SSH_TARGET=user@remote-host
        VPN_TYPE=openvpn
        DEFAULT_PROFILE=client.ovpn
    }
    output=$(remote_auto_install my-app user@remote-host 22)
    grep -Fq 'set:my-app:AUTOSTART:on' <<<"$output" ||
        fail 'configured automatic remote did not enable autostart'
    grep -Fq 'start:my-app:off:__default__' <<<"$output" ||
        fail 'configured automatic remote was not started during reconciliation'
)

# A successful automatic profile deployment must bring the local side online
# immediately, making boot enablement effective even before the first run.
(
    require_root() { :; }
    validate_app_name() { :; }
    assert_destructive_command_from_host() { :; }
    load_cfg() {
        REMOTE_MODE=auto
        REMOTE_ALIAS=auto-test
        REMOTE_OWNER_ID=0123456789abcdef
    }
    profile_type_from_file() { printf '%s\n' openvpn; }
    validate_ovpn() { :; }
    profile_name_from_path() { printf '%s\n' my-provider-profile.ovpn; }
    load_remote_cfg() {
        SSH_TARGET=user@remote-host
        SSH_PORT=22
        SSH_IDENTITY=/tmp/nns-auto-test/id_ed25519
    }
    remote_auto_command() {
        local alias=$1 action=$2
        shift 2
        case "$action" in
            deploy) cat >/dev/null ;;
            locate) printf '%s\n' 'ra-0123456789ab-exit|ra-0123456789ab-gw|ra-0123456789ab-client|0123456789abcdef|10.120.0.2|1' ;;
            export) printf '%s\n' test-bundle ;;
            *) fail "unexpected automatic remote action: $action" ;;
        esac
    }
    remote_import_bundle() { :; }
    remote_known_hosts() { printf '%s\n' /tmp/nns-auto-test/known_hosts; }
    cfg_set() { printf 'set:%s:%s:%s\n' "$1" "$2" "$3"; }
    start_app() { printf 'start:%s:%s:%s\n' "$1" "$2" "$3"; }
    log() { printf 'log:%s\n' "$*"; }
    profile="$TEST_TMP/my-provider-profile.ovpn"
    printf '%s\n' client >"$profile"
    output=$(remote_auto_add_profile my-app "$profile")
    grep -Fq 'set:my-app:AUTOSTART:on' <<<"$output" ||
        fail 'automatic deployment did not persist autostart'
    grep -Fq 'start:my-app:off:__default__' <<<"$output" ||
        fail 'automatic deployment did not start the local environment'
)

# Automatic free-profile deployment must send only selection criteria to the
# remote helper; no local VPN Gate profile path is involved.
(
    require_root() { :; }
    validate_app_name() { :; }
    load_cfg() {
        REMOTE_MODE=auto
        REMOTE_ALIAS=auto-test
        REMOTE_OWNER_ID=0123456789abcdef
    }
    load_remote_cfg() {
        SSH_TARGET=user@remote-host
        SSH_PORT=2222
    }
    remote_auto_command() {
        [[ "$1" == auto-test ]] || fail 'remote alias changed'
        [[ "$2" == deploy-any ]] || fail "unexpected remote action: $2"
        [[ "$3" == 0123456789abcdef ]] || fail 'owner changed'
        [[ "$4" == remote-host && "$5" == 2222 ]] || fail 'remote endpoint changed'
        [[ "$6" == JP && "$7" == on ]] || fail 'remote selection criteria changed'
        printf 'deploy-any-ok\n'
    }
    remote_auto_finish_profile_deployment() {
        printf 'finish:%s:%s:%s\n' "$1" "$2" "$3"
    }
    log() { :; }
    output=$(remote_auto_add_any_profile my-app JP on)
    grep -Fq 'deploy-any-ok' <<<"$output" ||
        fail 'automatic free-profile deployment did not invoke deploy-any'
    grep -Fq 'finish:my-app:auto-test:0123456789abcdef' <<<"$output" ||
        fail 'automatic free-profile deployment did not finalize locally'
)

# The remote dispatcher must preserve all deploy-any arguments, including an
# empty country filter.
(
    require_root() { :; }
    remote_auto_deploy_any_internal() {
        printf 'deploy-any:%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" "$5"
    }
    output=$(remote_auto_dispatch deploy-any 0123456789abcdef remote-host 22 '' off)
    [[ "$output" == 'deploy-any:0123456789abcdef:remote-host:22::off' ]] ||
        fail "automatic remote deploy-any dispatch changed arguments: $output"
)

# Automatic remote cleanup is a first-class remote operation and must preserve
# the owner argument exactly.
(
    require_root() { :; }
    remote_auto_cleanup_internal() {
        [[ "$1" == 0123456789abcdef ]] || fail 'cleanup owner was changed'
        printf 'cleanup:%s\n' "$1"
    }
    output=$(remote_auto_dispatch cleanup 0123456789abcdef)
    grep -Fq 'cleanup:0123456789abcdef' <<<"$output" ||
        fail 'automatic remote cleanup dispatch'
)

# Local cleanup upgrades an older remote helper, removes the owned objects, and
# records completion so a multi-app purge can safely be retried.
cleanup_remote_cfg="$TEST_TMP/cleanup-remote.cfg"
printf '%s\n' test >"$cleanup_remote_cfg"
(
    require_root() { :; }
    validate_app_name() { :; }
    load_cfg() {
        REMOTE_MODE=auto
        REMOTE_CLEANED=off
        REMOTE_ALIAS=auto-cleanup
        REMOTE_OWNER_ID=0123456789abcdef
    }
    remote_cfg_file() { printf '%s\n' "$cleanup_remote_cfg"; }
    load_remote_cfg() {
        SSH_TARGET=user@remote-host
        SSH_PORT=22
    }
    remote_auto_is_current() { return 1; }
    remote_auto_bootstrap() { printf 'bootstrap:%s:%s:%s:%s:%s\n' "$@"; }
    remote_auto_register() { printf 'register:%s:%s:%s:%s\n' "$@"; }
    remote_dir() { printf '%s\n' /tmp/auto-cleanup; }
    remote_auto_command() {
        [[ "$1" == auto-cleanup && "$2" == cleanup &&
           "$3" == 0123456789abcdef ]] ||
            fail 'local automatic cleanup command arguments'
        printf 'remote-cleanup:%s\n' "$3"
    }
    cfg_set() { printf 'set:%s:%s:%s\n' "$1" "$2" "$3"; }
    log() { printf 'log:%s\n' "$*"; }
    output=$(remote_auto_cleanup_app my-app)
    grep -Fq 'bootstrap:my-app:user@remote-host:22:auto-cleanup:0123456789abcdef' <<<"$output" ||
        fail 'cleanup did not upgrade an older remote helper'
    grep -Fq 'remote-cleanup:0123456789abcdef' <<<"$output" ||
        fail 'cleanup command was not sent'
    grep -Fq 'set:my-app:REMOTE_CLEANED:on' <<<"$output" ||
        fail 'cleanup completion was not recorded'
)

# Final-pool cleanup works while the provider exit is stopped. It removes the
# whole gateway before its exit, skips unnecessary client revocation, and
# passes local-only to the nested remove operation so cleanup cannot recurse.
cleanup_state="$TEST_TMP/remote-auto-state.cfg"
cleanup_gateway_cfg="$TEST_TMP/remote-gateway.cfg"
cleanup_exit_cfg="$TEST_TMP/remote-exit.cfg"
cat >"$cleanup_state" <<'EOF_CLEANUP_STATE'
OWNER_ID=0123456789abcdef
POOL_ID=0123456789abcdef
EXIT_APP=ra-0123456789ab-exit
GATEWAY=ra-0123456789ab-gw
CLIENT=ra-0123456789ab-client
PROVIDER_VPN_IPV4=10.120.0.2
PROFILE_SHA256=
ACTIVE=off
EOF_CLEANUP_STATE
printf '%s\n' gateway >"$cleanup_gateway_cfg"
printf '%s\n' exit >"$cleanup_exit_cfg"
(
    require_root() { :; }
    remote_auto_state_file() { printf '%s\n' "$cleanup_state"; }
    remote_auto_assert_state() { :; }
    gateway_cfg_file() {
        if [[ "$1" == ra-0123456789ab-gw ]]; then
            printf '%s\n' "$cleanup_gateway_cfg"
        else
            printf '%s/missing-%s.cfg\n' "$TEST_TMP" "$1"
        fi
    }
    cfg_file() { printf '%s\n' "$cleanup_exit_cfg"; }
    load_gateway_cfg() {
        VIA_APP=ra-0123456789ab-exit
        REMOTE_MANAGED_OWNER_ID=0123456789abcdef
    }
    gateway_client_revoke() { fail 'final pool attempted unnecessary client revocation'; }
    gateway_remove() { printf 'gateway-remove:%s\n' "$1"; }
    load_cfg() { REMOTE_MANAGED_OWNER_ID=0123456789abcdef; }
    remove_app() { printf 'app-remove:%s:%s\n' "$1" "$2"; }
    remote_auto_deauthorize_owner() { printf 'deauthorize:%s\n' "$1"; }
    systemctl() { :; }
    log() { printf 'log:%s\n' "$*"; }
    output=$(remote_auto_cleanup_internal 0123456789abcdef)
    grep -Fq 'gateway-remove:ra-0123456789ab-gw' <<<"$output" ||
        fail 'remote gateway was not removed'
    grep -Fq 'app-remove:ra-0123456789ab-exit:local-only' <<<"$output" ||
        fail 'remote exit was not removed without recursion'
    grep -Fq 'deauthorize:0123456789abcdef' <<<"$output" ||
        fail 'per-owner SSH authorization was not removed'
    [[ ! -e "$cleanup_state" ]] || fail 'completed final-pool cleanup retained owner state'
)

# A failed final-pool deletion retains the owner state so purge can be retried.
cat >"$cleanup_state" <<'EOF_CLEANUP_RETRY_STATE'
OWNER_ID=0123456789abcdef
POOL_ID=0123456789abcdef
EXIT_APP=ra-0123456789ab-exit
GATEWAY=ra-0123456789ab-gw
CLIENT=ra-0123456789ab-client
PROVIDER_VPN_IPV4=10.120.0.2
PROFILE_SHA256=
ACTIVE=off
EOF_CLEANUP_RETRY_STATE
if (
    require_root() { :; }
    remote_auto_state_file() { printf '%s\n' "$cleanup_state"; }
    remote_auto_load_state() {
        RA_EXIT_APP=ra-0123456789ab-exit
        RA_GATEWAY=ra-0123456789ab-gw
        RA_CLIENT=ra-0123456789ab-client
        RA_POOL_ID=0123456789abcdef
        RA_PROVIDER_VPN_IPV4=10.120.0.2
        RA_PROFILE_SHA256=
        RA_ACTIVE=off
    }
    remote_auto_pool_member_count() { printf '%s\n' 0; }
    gateway_cfg_file() {
        if [[ "$1" == ra-0123456789ab-gw ]]; then
            printf '%s\n' "$cleanup_gateway_cfg"
        else
            printf '%s/missing-%s.cfg\n' "$TEST_TMP" "$1"
        fi
    }
    cfg_file() { printf '%s\n' "$cleanup_exit_cfg"; }
    load_gateway_cfg() {
        VIA_APP=ra-0123456789ab-exit
        REMOTE_MANAGED_OWNER_ID=0123456789abcdef
    }
    gateway_remove() { exit 1; }
    log() { :; }
    remote_auto_cleanup_internal 0123456789abcdef >/dev/null 2>&1
); then
    fail 'failed final gateway deletion was reported as success'
fi
[[ -f "$cleanup_state" ]] || fail 'failed final-pool cleanup deleted retry state'

# Dependency enumerators are list-producing helpers, not predicates. Their
# definitions must end in explicit success so a zero-match result remains safe
# in remove_app() pipelines under set -e -o pipefail.
gateway_enum_definition=$(declare -f gateways_using_app)
app_enum_definition=$(declare -f apps_using_upstream)
grep -Fq 'return 0' <<<"$gateway_enum_definition" ||
    fail 'gateway dependency enumerator has no explicit successful empty result'
grep -Fq 'return 0' <<<"$app_enum_definition" ||
    fail 'app dependency enumerator has no explicit successful empty result'

# Public CLI exposes explicit local-only escape hatches; normal remove/purge
# use ownership-scoped remote cleanup by default.
(
    reexec_as_root_if_needed() { :; }
    remove_app() { printf 'remove:%s:%s\n' "$1" "${2:-remote}"; }
    purge_engine() { printf 'purge:%s\n' "${1:-remote}"; }
    output=$(main remove my-app)
    grep -Fq 'remove:my-app:remote' <<<"$output" || fail 'default remove cleanup mode'
    output=$(main remove my-app --local-only)
    grep -Fq 'remove:my-app:local-only' <<<"$output" || fail 'local-only remove parser'
    output=$(main purge)
    grep -Fq 'purge:remote' <<<"$output" || fail 'default purge cleanup mode'
    output=$(main purge --local-only)
    grep -Fq 'purge:local-only' <<<"$output" || fail 'local-only purge parser'
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
  "public_host": "remote.example.net",
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
    deploy 0123456789abcdef remote-host 22 'my provider profile.ovpn')
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
    deploy 0123456789abcdef remote-host 22 'my provider profile.ovpn'
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


# Automatic remote start/stop are first-class restricted operations and must
# preserve the owner argument exactly.
(
    require_root() { :; }
    remote_auto_start_internal() {
        [[ "$1" == 0123456789abcdef ]] || fail 'start owner was changed'
        printf 'remote-start:%s\n' "$1"
    }
    remote_auto_stop_internal() {
        [[ "$1" == 0123456789abcdef ]] || fail 'stop owner was changed'
        printf 'remote-stop:%s\n' "$1"
    }
    output=$(remote_auto_dispatch start 0123456789abcdef)
    grep -Fq 'remote-start:0123456789abcdef' <<<"$output" ||
        fail 'automatic remote start dispatch'
    output=$(remote_auto_dispatch stop 0123456789abcdef)
    grep -Fq 'remote-stop:0123456789abcdef' <<<"$output" ||
        fail 'automatic remote stop dispatch'
)

# Public stop defaults to symmetric automatic-remote shutdown, but exposes an
# explicit local-only escape hatch. Local/manual apps never invoke SSH.
(
    require_root() { :; }
    validate_app_name() { :; }
    load_cfg() {
        if [[ "$1" == remote-app ]]; then
            REMOTE_MODE=auto
            REMOTE_ALIAS=auto-test
            REMOTE_OWNER_ID=0123456789abcdef
            DEFAULT_PROFILE=client.ovpn
            VPN_TYPE=openvpn
        else
            REMOTE_MODE=
            REMOTE_ALIAS=
            REMOTE_OWNER_ID=
            DEFAULT_PROFILE=local.ovpn
            VPN_TYPE=openvpn
        fi
    }
    stop_app() { printf 'local-stop:%s\n' "$1"; }
    remote_auto_lifecycle_app() {
        printf 'remote-%s:%s\n' "$1" "$2"
    }
    warn() { printf 'warn:%s\n' "$*"; }
    log() { printf 'log:%s\n' "$*"; }

    output=$(stop_app_cli remote-app remote)
    [[ "$(sed -n '1p' <<<"$output")" == 'local-stop:remote-app' ]] ||
        fail 'automatic stop did not stop local side first'
    grep -Fq 'remote-stop:remote-app' <<<"$output" ||
        fail 'automatic stop omitted remote lifecycle'

    output=$(stop_app_cli remote-app local-only)
    grep -Fq 'local-stop:remote-app' <<<"$output" ||
        fail 'local-only stop omitted local shutdown'
    if grep -Fq 'remote-stop:remote-app' <<<"$output"; then
        fail 'local-only stop touched remote lifecycle'
    fi

    output=$(stop_app_cli local-app remote)
    grep -Fq 'local-stop:local-app' <<<"$output" ||
        fail 'manual app stop omitted local shutdown'
    if grep -Fq 'remote-stop:local-app' <<<"$output"; then
        fail 'manual app stop attempted remote lifecycle'
    fi
)

# CLI stop parsing must select symmetric or local-only semantics explicitly.
(
    stop_app_cli() { printf 'stop-cli:%s:%s\n' "$1" "$2"; }
    output=$(main stop my-app)
    grep -Fq 'stop-cli:my-app:remote' <<<"$output" ||
        fail 'default stop parser did not select remote lifecycle'
    output=$(main stop my-app --local-only)
    grep -Fq 'stop-cli:my-app:local-only' <<<"$output" ||
        fail 'local-only stop parser'
)



# Legacy automatic-remote objects created before ownership markers existed are
# adopted only when their state record and deterministic relationship validate.
(
    require_root() { :; }
    remote_auto_load_state() {
        [[ "$1" == 0123456789abcdef ]]
        RA_POOL_ID=0123456789abcdef
        RA_EXIT_APP=ra-0123456789ab-exit
        RA_GATEWAY=ra-0123456789ab-gw
    }
    temp=$(mktemp -d)
    cfg_file() { printf '%s/%s.cfg\n' "$temp" "$1"; }
    gateway_cfg_file() { printf '%s/%s.cfg\n' "$temp" "$1"; }
    : >"$(cfg_file ra-0123456789ab-exit)"
    : >"$(gateway_cfg_file ra-0123456789ab-gw)"
    load_cfg() { REMOTE_MANAGED_OWNER_ID=; }
    load_gateway_cfg() {
        VIA_APP=ra-0123456789ab-exit
        REMOTE_MANAGED_OWNER_ID=
    }
    cfg_set() { printf 'cfg-set:%s:%s:%s\n' "$1" "$2" "$3"; }
    gateway_cfg_set() { printf 'gw-set:%s:%s:%s\n' "$1" "$2" "$3"; }
    log() { :; }
    die() { printf 'die:%s\n' "$*"; return 1; }
    output=$(remote_auto_reconcile_owner_markers 0123456789abcdef)
    grep -Fq 'cfg-set:ra-0123456789ab-exit:REMOTE_MANAGED_OWNER_ID:0123456789abcdef' <<<"$output" ||
        fail 'legacy exit owner marker was not adopted'
    grep -Fq 'gw-set:ra-0123456789ab-gw:REMOTE_MANAGED_OWNER_ID:0123456789abcdef' <<<"$output" ||
        fail 'legacy gateway owner marker was not adopted'
    rm -rf "$temp"
)

# A nonempty conflicting marker must never be silently rewritten.
(
    require_root() { :; }
    remote_auto_load_state() {
        RA_POOL_ID=0123456789abcdef
        RA_EXIT_APP=ra-0123456789ab-exit
        RA_GATEWAY=ra-0123456789ab-gw
    }
    temp=$(mktemp -d)
    cfg_file() { printf '%s/%s.cfg\n' "$temp" "$1"; }
    gateway_cfg_file() { printf '%s/%s.cfg\n' "$temp" "$1"; }
    : >"$(cfg_file ra-0123456789ab-exit)"
    load_cfg() { REMOTE_MANAGED_OWNER_ID=ffffffffffffffff; }
    cfg_set() { fail 'conflicting marker was overwritten'; }
    log() { :; }
    die() { printf '%s\n' "$*" >&2; exit 1; }
    output=$(remote_auto_reconcile_owner_markers 0123456789abcdef 2>&1) &&
        fail 'conflicting owner marker was accepted'
    grep -Fq 'pool marker mismatch' <<<"$output" ||
        fail 'conflicting marker did not report mismatch'
    rm -rf "$temp"
)


# A second automatic client with the same provider-side tunnel address must
# attach to the existing pool instead of leaving two competing provider exits.
(
    require_root() { :; }
    acquire_lock() { :; }
    remote_auto_state_file() { printf '%s/%s.cfg\n' "$TEST_TMP" "$1"; }
    cfg_file() { printf '%s/%s.app.cfg\n' "$TEST_TMP" "$1"; }
    gateway_cfg_file() { printf '%s/%s.gw.cfg\n' "$TEST_TMP" "$1"; }
    install_app() { : >"$(cfg_file "$1")"; printf 'install:%s\n' "$1"; }
    load_cfg() { REMOTE_MANAGED_OWNER_ID=; }
    cfg_set() { printf 'cfg-set:%s:%s:%s\n' "$1" "$2" "$3"; }
    systemctl() { return 1; }
    app_is_started() { return 1; }
    add_profile() { printf 'profile:%s:%s\n' "$1" "${2##*/}"; }
    start_app() { printf 'start:%s:%s\n' "$1" "${2:-}"; }
    stop_app() { printf 'stop:%s\n' "$1"; }
    remove_app() { printf 'remove:%s:%s\n' "$1" "$2"; }
    profile_type_from_file() { printf '%s\n' openvpn; }
    validate_ovpn() { :; }
    remote_auto_provider_ipv4() { printf '%s\n' 10.120.0.2; }
    remote_auto_find_shared_pool() {
        printf '%s\n' '1111111111111111|ra-111111111111-exit|ra-111111111111-gw|2222222222222222'
    }
    wait_online() { return 1; }
    gateway_stop() { printf 'gateway-stop:%s\n' "$1"; }
    gateway_start() { printf 'gateway-start:%s\n' "$1"; }
    gateway_client_dir() { printf '%s/client-%s-%s\n' "$TEST_TMP" "$1" "$2"; }
    gateway_client_add() { printf 'client-add:%s:%s\n' "$1" "$2"; }
    gateway_client_load() { STATUS=active; }
    gateway_client_rotate() { printf 'client-rotate:%s:%s\n' "$1" "$2"; }
    remote_auto_load_state() {
        RA_POOL_ID=1111111111111111
        RA_EXIT_APP=ra-111111111111-exit
        RA_GATEWAY=ra-111111111111-gw
        RA_CLIENT=ra-222222222222-client
        RA_PROVIDER_VPN_IPV4=
        RA_PROFILE_SHA256=
        RA_ACTIVE=on
    }
    remote_auto_write_state() { printf 'state:%s:%s:%s:%s:%s:%s:%s:%s\n' "$@"; }
    remote_auto_pool_member_count() { printf '%s\n' 2; }
    gateway_remove() { printf 'gateway-remove:%s\n' "$1"; }
    log() { printf 'log:%s\n' "$*"; }

    output=$(printf '%s\n' client | remote_auto_deploy_internal \
        3333333333333333 remote-host 22 provider.ovpn)
    grep -Fq 'start:ra-333333333333-exit:probe' <<<"$output" ||
        fail 'candidate exit was not started in address-probe mode before sharing'
    grep -Fq 'remove:ra-333333333333-exit:local-only' <<<"$output" ||
        fail 'duplicate provider exit was not removed during sharing'
    grep -Fq 'client-add:ra-111111111111-gw:ra-333333333333-client' <<<"$output" ||
        fail 'new owner did not receive a unique client on the shared gateway'
    grep -Fq 'state:3333333333333333:ra-111111111111-exit:ra-111111111111-gw:ra-333333333333-client:1111111111111111:10.120.0.2:' <<<"$output" ||
        fail 'new owner state did not reference the shared pool'
)

# Stopping one member must not stop a shared remote exit while another member
# is marked active.
(
    require_root() { :; }
    remote_auto_reconcile_owner_markers() { :; }
    remote_auto_load_state() {
        RA_EXIT_APP=ra-111111111111-exit
        RA_GATEWAY=ra-111111111111-gw
        RA_CLIENT=ra-333333333333-client
        RA_POOL_ID=1111111111111111
        RA_PROVIDER_VPN_IPV4=10.120.0.2
        RA_PROFILE_SHA256=
    }
    remote_auto_write_state() { printf 'state-active:%s\n' "$8"; }
    remote_auto_pool_has_active_member() { return 0; }
    gateway_stop() { fail 'shared gateway was stopped while another client was active'; }
    stop_app() { fail 'shared exit was stopped while another client was active'; }
    log() { printf 'log:%s\n' "$*"; }
    output=$(remote_auto_stop_internal 3333333333333333)
    grep -Fq 'state-active:off' <<<"$output" || fail 'stopped member was not marked inactive'
    grep -Fq 'remains online for other clients' <<<"$output" ||
        fail 'shared stop did not report retained pool'
)

# Removing a follower revokes only its gateway credential and preserves the
# shared gateway/exit while at least one pool member remains.
(
    require_root() { :; }
    state="$TEST_TMP/shared-cleanup.cfg"
    : >"$state"
    cdir="$TEST_TMP/shared-client"
    mkdir -p "$cdir"
    : >"$cdir/client.cfg"
    remote_auto_state_file() { printf '%s\n' "$state"; }
    remote_auto_load_state() {
        RA_EXIT_APP=ra-111111111111-exit
        RA_GATEWAY=ra-111111111111-gw
        RA_CLIENT=ra-333333333333-client
        RA_POOL_ID=1111111111111111
        RA_PROVIDER_VPN_IPV4=10.120.0.2
        RA_PROFILE_SHA256=
        RA_ACTIVE=on
    }
    gateway_client_dir() { printf '%s\n' "$cdir"; }
    gateway_client_load() { STATUS=active; }
    gateway_client_revoke() { printf 'revoke:%s:%s\n' "$1" "$2"; }
    remote_auto_pool_member_count() {
        [[ "$1" == 1111111111111111 && "$2" == 3333333333333333 ]] ||
            fail 'shared cleanup did not exclude the owner being removed'
        printf '%s\n' 1
    }
    remote_auto_deauthorize_owner() { printf 'deauthorize:%s\n' "$1"; }
    gateway_remove() { fail 'shared gateway was removed with members remaining'; }
    remove_app() { fail 'shared exit was removed with members remaining'; }
    systemctl() { :; }
    log() { printf 'log:%s\n' "$*"; }
    output=$(remote_auto_cleanup_internal 3333333333333333)
    grep -Fq 'revoke:ra-111111111111-gw:ra-333333333333-client' <<<"$output" ||
        fail 'shared follower credential was not revoked'
    grep -Fq 'shared pool' <<<"$output" || fail 'shared cleanup did not preserve the pool'
    [[ ! -e "$state" ]] || fail 'shared cleanup retained removed member state'
)

# Automatic-remote public OpenVPN export/revoke must use deterministic pool
# gateway names and preserve every CLI argument through dispatch.
[[ "$(remote_auto_public_gateway_name 0123456789abcdef)" == ra-0123456789ab-public ]] ||
    fail 'automatic public gateway naming'

(
    require_root() { :; }
    remote_auto_public_export_internal() {
        printf 'public-export:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4"
    }
    remote_auto_public_revoke_internal() {
        printf 'public-revoke:%s:%s\n' "$1" "$2"
    }
    output=$(remote_auto_dispatch public-export 0123456789abcdef my-phone vpn.example.net:443 tcp)
    [[ "$output" == 'public-export:0123456789abcdef:my-phone:vpn.example.net:443:tcp' ]] ||
        fail "automatic public export dispatch: $output"
    output=$(remote_auto_dispatch public-revoke 0123456789abcdef my-phone)
    [[ "$output" == 'public-revoke:0123456789abcdef:my-phone' ]] ||
        fail "automatic public revoke dispatch: $output"
)

# First public export may omit --public: infer the current automatic-remote
# host and allocate a distinct direct OpenVPN port instead of colliding with
# the SSH-only loopback listener.
(
    export_test="$TEST_TMP/public-export-default"
    mkdir -p "$export_test"
    : >"$export_test/exit.cfg"
    : >"$export_test/private-gateway.cfg"

    require_root() { :; }
    validate_remote_owner_id() { :; }
    validate_gateway_client_name() { :; }
    acquire_lock() { :; }
    release_lock() { :; }
    remote_auto_reconcile_owner_markers() { :; }
    remote_auto_load_state() {
        RA_POOL_ID=0123456789abcdef
        RA_EXIT_APP=ra-0123456789ab-exit
        RA_GATEWAY=ra-0123456789ab-gw
        RA_CLIENT=ra-fedcba987654-client
    }
    remote_auto_public_gateway_name() { printf '%s\n' ra-0123456789ab-public; }
    cfg_file() { printf '%s\n' "$export_test/exit.cfg"; }
    gateway_cfg_file() {
        case "$1" in
            ra-0123456789ab-gw) printf '%s\n' "$export_test/private-gateway.cfg" ;;
            ra-0123456789ab-public) printf '%s\n' "$export_test/public-gateway.cfg" ;;
            *) printf '%s/%s.cfg\n' "$export_test" "$1" ;;
        esac
    }
    load_cfg() { REMOTE_MANAGED_OWNER_ID=0123456789abcdef; }
    load_gateway_cfg() {
        case "$1" in
            ra-0123456789ab-gw)
                VIA_APP=ra-0123456789ab-exit
                TRANSPORT=ssh
                REMOTE_MANAGED_OWNER_ID=0123456789abcdef
                PUBLIC_HOST=remote.example.net
                PUBLIC_PORT=22
                OPENVPN_LISTEN_PROTO=tcp
                OPENVPN_LISTEN_PORT=23111
                ;;
            ra-0123456789ab-public)
                VIA_APP=ra-0123456789ab-exit
                TRANSPORT=direct
                REMOTE_MANAGED_OWNER_ID=0123456789abcdef
                PUBLIC_HOST=remote.example.net
                PUBLIC_PORT=24777
                LISTEN_PROTO=tcp
                LISTEN_PORT=24777
                ;;
        esac
    }
    gateway_allocate_backend_port() { printf '%s\n' 24777; }
    start_app() { :; }
    gateway_create() {
        printf '%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$7" >"$export_test/create.log"
        : >"$export_test/public-gateway.cfg"
    }
    gateway_cfg_set() { :; }
    gateway_start() { :; }
    systemctl() { :; }
    gateway_client_dir() { printf '%s/%s-%s\n' "$export_test" "$1" "$2"; }
    gateway_client_add() { :; }
    remote_auto_public_active_client_count() { printf '%s\n' 1; }
    warn() { :; }
    gateway_client_export() { printf 'PROFILE\n'; }
    log() { printf '%s\n' "$*" >&2; }

    remote_auto_public_export_internal 0123456789abcdef laptop - auto \
        >"$export_test/profile" 2>"$export_test/stderr"
    [[ "$(cat "$export_test/create.log")" == \
       'ra-0123456789ab-public|ra-0123456789ab-exit|tcp:24777|remote.example.net:24777|direct' ]] ||
        fail "automatic public endpoint inference: $(cat "$export_test/create.log")"
    grep -Fq "using current remote host 'remote.example.net' with automatically selected OpenVPN port '24777'" \
        "$export_test/stderr" || fail 'automatic public endpoint inference message'
    [[ "$(cat "$export_test/profile")" == PROFILE ]] ||
        fail 'automatic public export profile output'
)

(
    remote_auto_export_public_ovpn() {
        printf 'EXPORT:%s:%s:%s:%s:%s\n' "$1" "$2" "$3" "$4" "$5"
    }
    remote_auto_revoke_public_ovpn() {
        printf 'REVOKE:%s:%s\n' "$1" "$2"
    }
    output=$(main export ovpn my-app --client my-phone --public vpn.example.net:443 --proto udp --output /tmp/my-phone.ovpn)
    [[ "$output" == 'EXPORT:my-app:my-phone:vpn.example.net:443:udp:/tmp/my-phone.ovpn' ]] ||
        fail "public export CLI parsing: $output"
    output=$(main export ovpn my-app --client my-laptop)
    [[ "$output" == 'EXPORT:my-app:my-laptop:-:auto:-' ]] ||
        fail "public export reuse CLI parsing: $output"
    output=$(main revoke my-app my-phone)
    [[ "$output" == 'REVOKE:my-app:my-phone' ]] ||
        fail "public revoke CLI parsing: $output"
)


# High-level list record formatting keeps gateway/client inventories readable
# and retains the source association for automatic-remote objects.
(
    output=$(list_gateway_record_print 'GATEWAY|my-public-gw|public|active|my-exit|vpn.example.net:443/tcp|2|1|1|remote:my-private-app')
    grep -Fq 'my-public-gw' <<<"$output" || fail 'gateway overview omits gateway name'
    grep -Fq '2/1' <<<"$output" || fail 'gateway overview omits active/revoked counts'
    grep -Fq 'remote:my-private-app' <<<"$output" || fail 'gateway overview omits remote source association'
)
(
    output=$(list_client_record_print 'CLIENT|my-phone|active|my-public-gw|vpn.example.net:443/tcp|2026-08-08T00:00:00Z|yes|remote:my-private-app')
    grep -Fq 'my-phone' <<<"$output" || fail 'external client overview omits client name'
    grep -Fq 'yes' <<<"$output" || fail 'external client overview omits connection state'
    grep -Fq 'remote:my-private-app' <<<"$output" || fail 'external client overview omits remote source association'
)
(
    REMOTE_ALIAS=auto-test
    REMOTE_OWNER_ID=0123456789abcdef
    remote_auto_command() {
        [[ "$1" == auto-test && "$2" == topology && "$3" == 0123456789abcdef ]] ||
            fail 'status topology sent wrong remote request'
        printf 'Remote pool:        0123456789abcdef\nPublic gateway:     my-public-gw (active; vpn.example.net:443/tcp)\nExternal clients:   1 active/0 revoked; connected=1\n'
    }
    output=$(status_remote_topology my-private-app)
    grep -Fq 'Remote topology:' <<<"$output" || fail 'status remote topology heading missing'
    grep -Fq 'Public gateway:' <<<"$output" || fail 'status remote topology omits public gateway'
    grep -Fq 'External clients:' <<<"$output" || fail 'status remote topology omits external client summary'
)



# Engine-only install refreshes configured automatic-remote nodes by default,
# while --local-only suppresses propagation.  This also guarantees that the
# bootstrap path can install on a remote node without recursively walking that
# node's own remote graph.
(
    require_root() { :; }
    acquire_lock() { :; }
    release_lock() { :; }
    ensure_dependencies() { :; }
    install_engine_files() { :; }
    install() { :; }
    refresh_managed_unit_metadata() { :; }
    remote_auto_refresh_configured_nodes() { printf '%s\n' remote-refresh; }
    log() { printf 'log:%s\n' "$*"; }
    output=$(install_engine on)
    grep -Fq 'remote-refresh' <<<"$output" ||
        fail 'plain engine install did not refresh automatic remotes'
    output=$(install_engine off)
    if grep -Fq 'remote-refresh' <<<"$output"; then
        fail 'local-only engine install unexpectedly refreshed automatic remotes'
    fi
)

# The public command parser exposes the same local-only switch.
(
    reexec_as_root_if_needed() { :; }
    install_engine() { printf 'engine:%s\n' "${1:-unset}"; }
    output=$(main install)
    grep -Fq 'engine:on' <<<"$output" || fail 'plain install parser lost remote refresh'
    output=$(main install --local-only)
    grep -Fq 'engine:off' <<<"$output" || fail 'install --local-only parser'
)

# Refreshing one configured automatic-remote app must preserve its registered
# SSH endpoint/port and repair a stale remote with the normal bootstrap +
# registration sequence.  A current remote must not be bootstrapped again.
(
    validate_app_name() { :; }
    load_cfg() {
        REMOTE_MODE=auto
        REMOTE_ALIAS=auto-test
        REMOTE_OWNER_ID=0123456789abcdef
    }
    load_remote_cfg() {
        SSH_TARGET=user@remote-host
        SSH_PORT=2222
    }
    remote_dir() { printf '%s\n' /tmp/auto-test; }
    remote_auto_is_current() { return 1; }
    remote_auto_bootstrap() { printf 'bootstrap:%s:%s:%s:%s:%s\n' "$@"; }
    remote_auto_register() { printf 'register:%s:%s:%s:%s\n' "$@"; }
    log() { printf 'log:%s\n' "$*"; }
    output=$(remote_auto_refresh_configured_app my-app)
    grep -Fq 'bootstrap:my-app:user@remote-host:2222:auto-test:0123456789abcdef' <<<"$output" ||
        fail 'remote engine refresh lost configured SSH endpoint or owner'
    grep -Fq 'register:auto-test:user@remote-host:2222:/tmp/auto-test/id_ed25519' <<<"$output" ||
        fail 'remote engine refresh did not re-register the upgraded helper'
)
(
    validate_app_name() { :; }
    load_cfg() {
        REMOTE_MODE=auto
        REMOTE_ALIAS=auto-test
        REMOTE_OWNER_ID=0123456789abcdef
    }
    load_remote_cfg() { SSH_TARGET=user@remote-host; SSH_PORT=22; }
    remote_auto_is_current() { return 0; }
    remote_auto_bootstrap() { fail 'current remote was unnecessarily bootstrapped'; }
    remote_auto_register() { fail 'current remote was unnecessarily registered'; }
    log() { printf 'log:%s\n' "$*"; }
    output=$(remote_auto_refresh_configured_app my-app)
    grep -Fq 'already runs nns-app 1.3.30' <<<"$output" ||
        fail 'current remote refresh status missing'
)



# Repair parses remote-auto state without executing it and can reconstruct a
# missing state from exactly one deterministic private gateway/client.
(
    state_test="$TEST_TMP/repair-state"
    mkdir -p "$state_test"
    cat >"$state_test/state.cfg" <<'EOF_REPAIR_STATE'
OWNER_ID=0123456789abcdef
POOL_ID=0123456789abcdef
EXIT_APP=ra-0123456789ab-exit
GATEWAY=ra-0123456789ab-gw
CLIENT=ra-0123456789ab-client
PROVIDER_VPN_IPV4=10.10.10.10
PROFILE_SHA256=''
ACTIVE=on
EOF_REPAIR_STATE
    output=$(repair_remote_state_record "$state_test/state.cfg" 0123456789abcdef)
    [[ "$output" == '0123456789abcdef|0123456789abcdef|ra-0123456789ab-exit|ra-0123456789ab-gw|ra-0123456789ab-client|10.10.10.10||on' ]] ||
        fail "strict repair state parser: $output"
    printf 'OWNER_ID=0123456789abcdef\nPOOL_ID=$(touch /tmp/nns-repair-should-not-run)\n' >"$state_test/bad.cfg"
    if repair_remote_state_record "$state_test/bad.cfg" 0123456789abcdef >/dev/null 2>&1; then
        fail 'repair state parser accepted executable shell syntax'
    fi
    [[ ! -e /tmp/nns-repair-should-not-run ]] || fail 'repair state parser executed damaged state'
)

# Repair CLI exposes remote and local-only reconciliation modes.
(
    reexec_as_root_if_needed() { :; }
    repair_engine() { printf 'repair:%s\n' "$1"; }
    output=$(main repair)
    [[ "$output" == 'repair:remote' ]] || fail "repair CLI default mode: $output"
    output=$(main repair --local-only)
    [[ "$output" == 'repair:local-only' ]] || fail "repair CLI local-only mode: $output"
)

# A stopped public gateway with an nns-app-owned UFW rule closes that rule;
# an active gateway missing the rule opens it.
(
    REPAIR_FIXED=0 REPAIR_WARNINGS=0 REPAIR_UNRESOLVED=0
    validate_gateway_name() { :; }
    acquire_lock() { :; }
    release_lock() { :; }
    load_gateway_cfg() {
        TRANSPORT=direct LISTEN_PORT=25108 LISTEN_PROTO=tcp
        GATEWAY_TUN=ngwtest REMOTE_MANAGED_OWNER_ID=""
    }
    write_gateway_unit_dropin() { :; }
    gateway_write_openssl_config() { :; }
    gateway_write_server_config() { :; }
    gateway_write_transport_config() { :; }
    repair_gateway_abandoned_certs() { :; }
    systemctl() {
        if [[ "$1" == is-active ]]; then printf 'inactive\n'; return 3; fi
        return 1
    }
    ufw_is_active() { return 0; }
    ufw_managed_public_rule_exists() { return 0; }
    gateway_ufw_state_file() { printf '%s\n' "$TEST_TMP/repair-ufw-state"; }
    gateway_ufw_public_down() { printf 'closed\n' >"$TEST_TMP/repair-ufw"; rm -f "$TEST_TMP/repair-ufw-state"; }
    gateway_firewalld_public_down() { :; }
    gateway_iptables_public_down() { :; }
    repair_gateway_expected_running() { return 1; }
    repair_gateway_one gw >/dev/null
    [[ -f "$TEST_TMP/repair-ufw" ]] || fail 'repair did not close stale UFW gateway rule'
)

echo 'Function tests passed.'
