# nns-app source module: dependency checks, installation, upgrades and removal.
os_release_value() {
    local key=$1 file=${NNS_APP_OS_RELEASE_FILE:-/etc/os-release}
    local line value
    [[ -r "$file" ]] || return 1
    line=$(grep -m1 -E "^${key}=" "$file" 2>/dev/null || true)
    [[ -n "$line" ]] || return 1
    value=${line#*=}
    if [[ "$value" == \"*\" && ${#value} -ge 2 ]]; then
        value=${value:1:${#value}-2}
    elif [[ "$value" == \'*\' && ${#value} -ge 2 ]]; then
        value=${value:1:${#value}-2}
    fi
    printf '%s\n' "$value"
}

detect_platform_family() {
    local id id_like
    id=$(os_release_value ID 2>/dev/null || true)
    id_like=$(os_release_value ID_LIKE 2>/dev/null || true)
    case "$id" in
        ubuntu|debian) printf 'debian\n' ;;
        fedora) printf 'fedora\n' ;;
        *)
            case " $id_like " in
                *' debian '*) printf 'debian\n' ;;
                *) return 1 ;;
            esac
            ;;
    esac
}

dependency_package_for() {
    local family=$1 command_name=$2
    case "$family:$command_name" in
        debian:ip) printf 'iproute2\n' ;;
        fedora:ip) printf 'iproute\n' ;;
        debian:iptables) printf 'iptables\n' ;;
        fedora:iptables) printf 'iptables-nft\n' ;;
        debian:ping) printf 'iputils-ping\n' ;;
        fedora:ping) printf 'iputils\n' ;;
        debian:ssh|debian:scp) printf 'openssh-client\n' ;;
        fedora:ssh|fedora:scp) printf 'openssh-clients\n' ;;
        *:openvpn) printf 'openvpn\n' ;;
        *:wg|*:wg-quick) printf 'wireguard-tools\n' ;;
        *:curl) printf 'curl\n' ;;
        *:setpriv) printf 'util-linux\n' ;;
        *:sudo) printf 'sudo\n' ;;
        *:openssl) printf 'openssl\n' ;;
        *:python3) printf 'python3\n' ;;
        *) return 1 ;;
    esac
}

install_dependency_packages() {
    local family=$1
    shift
    (( $# > 0 )) || return 0
    case "$family" in
        debian)
            command -v apt-get >/dev/null 2>&1 ||
                die "apt-get is unavailable on this Debian-family host."
            DEBIAN_FRONTEND=noninteractive apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
            ;;
        fedora)
            local dnf_binary
            dnf_binary=$(command -v dnf5 2>/dev/null || command -v dnf 2>/dev/null || true)
            [[ -n "$dnf_binary" ]] || die "dnf is unavailable on this Fedora host."
            "$dnf_binary" -y install "$@"
            ;;
        *) die "Unsupported package-manager family '$family'." ;;
    esac
}

check_openvpn_version() {
    local raw version binary
    binary=$(openvpn_binary)
    raw=$("$binary" --version 2>/dev/null | head -n1 || true)
    version=$(sed -nE \
        's/^OpenVPN[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"$raw")
    [[ -n "$version" ]] ||
        die "Cannot determine the installed OpenVPN version."

    if [[ "$(printf '%s\n%s\n' '2.6.0' "$version" | sort -V | head -n1)" != 2.6.0 ]]; then
        die "OpenVPN 2.6.0 or newer is required; found $version."
    fi
}

ensure_dependencies() {
    local family command_name package
    local -a commands=(
        ip openvpn wg wg-quick iptables curl ping setpriv sudo openssl
        python3 ssh scp
    )
    local -a missing=()
    local -A selected=()

    for command_name in "${commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 && continue
        if [[ -z "${family:-}" ]]; then
            family=$(detect_platform_family 2>/dev/null || true)
            [[ -n "$family" ]] ||
                die "Unsupported Linux distribution. Install the required commands manually; supported automatic installers are Ubuntu/Debian and Fedora."
        fi
        package=$(dependency_package_for "$family" "$command_name" 2>/dev/null || true)
        [[ -n "$package" ]] ||
            die "No package mapping for missing command '$command_name' on '$family'."
        if [[ -z "${selected[$package]:-}" ]]; then
            selected[$package]=1
            missing+=("$package")
        fi
    done

    if (( ${#missing[@]} )); then
        log "Installing required packages: ${missing[*]}"
        install_dependency_packages "$family" "${missing[@]}"
    fi

    for command_name in "${commands[@]}"; do
        command -v "$command_name" >/dev/null 2>&1 ||
            die "Required command '$command_name' is still unavailable after dependency installation."
    done
    check_openvpn_version
}

restore_selinux_contexts() {
    [[ -e /sys/fs/selinux/enforce ]] || return 0
    command -v restorecon >/dev/null 2>&1 || {
        warn "SELinux is enabled but restorecon is unavailable; install policycoreutils and reinstall nns-app."
        return 0
    }
    restorecon -F "$@" >/dev/null 2>&1 ||
        warn "Could not restore one or more SELinux file contexts."
}

install_engine_files() {
    require_root

    local self
    self=$(readlink -f "$0")
    install -d -o root -g root -m 0755 /usr/local/sbin /usr/local/bin

    if [[ "$self" != "$ENGINE_PATH" ]]; then
        install -o root -g root -m 0755 "$self" "$ENGINE_PATH"
    else
        chown root:root "$ENGINE_PATH"
        chmod 0755 "$ENGINE_PATH"
    fi
    ln -sfn "$ENGINE_PATH" "$USER_PATH"

    cat >"$NETNS_UNIT" <<'NETNS_UNIT_EOF'
[Unit]
Description=NNS network namespace for %i
Wants=network-online.target
After=network-online.target
Before=nns-openvpn@%i.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/nns_app.sh _netns-up %i
ExecStop=/usr/local/sbin/nns_app.sh _netns-down %i
TimeoutStartSec=30s
TimeoutStopSec=15s

[Install]
WantedBy=multi-user.target
NETNS_UNIT_EOF

    cat >"$VPN_UNIT" <<'VPN_UNIT_EOF'
[Unit]
Description=VPN transport for NNS app %i
Requires=nns-netns@%i.service
After=nns-netns@%i.service
BindsTo=nns-netns@%i.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/nns_app.sh _vpn %i
Restart=on-failure
RestartSec=5s
KillSignal=SIGTERM
TimeoutStopSec=25s

[Install]
WantedBy=multi-user.target
VPN_UNIT_EOF

    cat >"$ONLINE_UNIT" <<'ONLINE_UNIT_EOF'
[Unit]
Description=Online data path for NNS app %i
Requires=nns-openvpn@%i.service
After=nns-openvpn@%i.service
BindsTo=nns-openvpn@%i.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/nns_app.sh _wait-online %i 60
TimeoutStartSec=70s

[Install]
WantedBy=multi-user.target
ONLINE_UNIT_EOF

    cat >"$DNS_PROXY_UNIT" <<'DNS_PROXY_UNIT_EOF'
[Unit]
Description=Namespace DNS compatibility proxy for NNS app %i
Requires=nns-netns@%i.service
After=nns-netns@%i.service nns-openvpn@%i.service
BindsTo=nns-netns@%i.service
PartOf=nns-netns@%i.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/nns_app.sh _dns-proxy %i
Restart=on-failure
RestartSec=2s
TimeoutStopSec=5s
DNS_PROXY_UNIT_EOF

    cat >"$WATCHDOG_SERVICE" <<'WATCHDOG_SERVICE_EOF'
[Unit]
Description=Data-path watchdog for NNS app %i
ConditionPathExists=/etc/nns-app/%i/%i.cfg
After=nns-openvpn@%i.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nns_app.sh _watchdog %i
TimeoutStartSec=150s
WATCHDOG_SERVICE_EOF

    cat >"$WATCHDOG_TIMER" <<'WATCHDOG_TIMER_EOF'
[Unit]
Description=Periodic data-path watchdog for NNS app %i

[Timer]
OnActiveSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
RandomizedDelaySec=5s
Unit=nns-watchdog@%i.service

[Install]
WantedBy=timers.target
WATCHDOG_TIMER_EOF

    cat >"$GATEWAY_UNIT" <<'GATEWAY_UNIT_EOF'
[Unit]
Description=NNS managed OpenVPN gateway %i
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStartPre=/usr/local/sbin/nns_app.sh _gateway-up %i
ExecStart=/usr/local/sbin/nns_app.sh _gateway-server %i
ExecStopPost=/usr/local/sbin/nns_app.sh _gateway-down %i
Restart=on-failure
RestartSec=5s
KillSignal=SIGTERM
TimeoutStartSec=30s
TimeoutStopSec=30s

[Install]
WantedBy=multi-user.target
GATEWAY_UNIT_EOF

    cat >"$GATEWAY_CRL_SERVICE" <<'CRL_SERVICE_EOF'
[Unit]
Description=Refresh CRL for NNS gateway %i
ConditionPathExists=/etc/nns-app/gateways/%i/gateway.cfg

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nns_app.sh _gateway-crl-refresh %i
CRL_SERVICE_EOF

    cat >"$GATEWAY_CRL_TIMER" <<'CRL_TIMER_EOF'
[Unit]
Description=Weekly CRL refresh for NNS gateway %i

[Timer]
OnCalendar=weekly
Persistent=true
RandomizedDelaySec=1h
Unit=nns-gateway-crl-refresh@%i.service

[Install]
WantedBy=timers.target
CRL_TIMER_EOF

    chmod 0644 "$NETNS_UNIT" "$VPN_UNIT" "$ONLINE_UNIT" "$DNS_PROXY_UNIT" \
        "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$GATEWAY_UNIT" \
        "$GATEWAY_CRL_SERVICE" "$GATEWAY_CRL_TIMER"
    restore_selinux_contexts \
        "$ENGINE_PATH" "$USER_PATH" \
        "$NETNS_UNIT" "$VPN_UNIT" "$ONLINE_UNIT" "$DNS_PROXY_UNIT" \
        "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$GATEWAY_UNIT" \
        "$GATEWAY_CRL_SERVICE" "$GATEWAY_CRL_TIMER"
    systemctl daemon-reload
}

refresh_managed_unit_metadata() {
    local dir app gateway
    shopt -s nullglob

    for dir in "$BASE_DIR"/*; do
        [[ -d "$dir" ]] || continue
        app=$(basename "$dir")
        [[ -f "$(cfg_file "$app")" ]] || continue
        load_cfg "$app"
        write_app_unit_dropin "$app"
        # Sudo filters the caller environment before the root engine starts.
        # Rebuild existing per-app rules on every engine upgrade so additions
        # to the run-time environment allow-list take effect immediately.
        write_sudoers_for_app "$app" "$APP_USER"
        sync_watchdog_timer "$app"
    done

    for dir in "$GATEWAY_BASE_DIR"/*; do
        [[ -f "$dir/gateway.cfg" ]] || continue
        gateway=$(basename "$dir")
        acquire_lock "gateway-$gateway"
        write_gateway_unit_dropin "$gateway"
        gateway_write_openssl_config "$gateway" "$(gateway_dir "$gateway")"
        gateway_write_server_config "$gateway"
        gateway_write_transport_config "$gateway"
        systemctl enable --now "nns-gateway-crl-refresh@${gateway}.timer" \
            >/dev/null 2>&1 || true
        if systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
            warn "Gateway '$gateway' is running; restart it to activate refreshed gateway and transport settings."
        fi
        release_lock "gateway-$gateway"
    done
    systemctl daemon-reload
}

install_engine() {
    require_root
    local refresh_remotes=${1:-on}
    [[ "$refresh_remotes" == on || "$refresh_remotes" == off ]] ||
        die "Internal install mode must be 'on' or 'off'."

    acquire_lock global
    ensure_dependencies
    install_engine_files
    install -d -o root -g root -m 0755 \
        "$BASE_DIR" "$RUN_DIR" "$CACHE_DIR" "$STATE_DIR" \
        "$GATEWAY_BASE_DIR" "$GATEWAY_RUN_BASE" "$REMOTE_BASE_DIR" "$LOCK_DIR"
    refresh_managed_unit_metadata
    release_lock global

    log "Installed nns-app $VERSION."
    log "Command: $USER_PATH"
    log "Engine:  $ENGINE_PATH"

    # Keep direct automatic-remote nodes at the same engine version as the
    # client that owns them.  Inventory/status RPCs evolve with the engine,
    # so silently leaving an older helper behind makes a healthy remote look
    # offline to a newly upgraded client.  Remote bootstrap itself installs
    # with refresh_remotes=off to avoid recursive propagation.
    if [[ "$refresh_remotes" == on ]]; then
        remote_auto_refresh_configured_nodes
    fi
}

collect_live_ipv4_networks() {
    local ns
    ip -o -4 addr show 2>/dev/null | awk '{print $4}'
    ip -4 route show table all 2>/dev/null |
        awk '$1 ~ /^[0-9]+\./ && $1 ~ /\// {print $1}'

    while read -r ns _; do
        [[ -n "$ns" ]] || continue
        ip -n "$ns" -o -4 addr show 2>/dev/null | awk '{print $4}'
        ip -n "$ns" -4 route show table all 2>/dev/null |
            awk '$1 ~ /^[0-9]+\./ && $1 ~ /\// {print $1}'
    done < <(ip netns list 2>/dev/null || true)
}

collect_configured_ipv4_networks() {
    grep -RhsE '^(NS_CIDR|CLIENT_POOL|TRANSIT_CIDR)=' \
        "$BASE_DIR"/*/*.cfg "$GATEWAY_BASE_DIR"/*/gateway.cfg 2>/dev/null |
        sed -E 's/^[A-Z_]+="?([^" ]+)"?.*/\1/' || true
}

all_known_ipv4_networks() {
    {
        collect_configured_ipv4_networks
        collect_live_ipv4_networks
    } | awk 'NF && !seen[$0]++'
}

allocate_network() {
    python3 - 3< <(all_known_ipv4_networks) <<'PY_ALLOCATE_APP'
import ipaddress
import os

used = []
for raw in os.fdopen(3):
    raw = raw.strip()
    if not raw:
        continue
    try:
        used.append(ipaddress.ip_network(raw, strict=False))
    except ValueError:
        pass

for net in ipaddress.ip_network("10.240.0.0/16").subnets(new_prefix=30):
    if all(not net.overlaps(other) for other in used):
        hosts = list(net.hosts())
        print(f"{net}|{hosts[0]}/{net.prefixlen}|{hosts[1]}/{net.prefixlen}")
        raise SystemExit(0)

raise SystemExit("No free /30 subnet remains in 10.240.0.0/16")
PY_ALLOCATE_APP
}

make_veth_names() {
    local app=$1 crc hex
    crc=$(printf '%s' "$app" | cksum | awk '{print $1}')
    printf -v hex '%08x' "$crc"
    printf 'nh%s|nn%s\n' "$hex" "$hex"
}

app_dropin_dir() {
    printf '%s/nns-netns@%s.service.d\n' "$SYSTEMD_UNIT_DIR" "$1"
}

gateway_dropin_dir() {
    printf '%s/nns-gateway@%s.service.d\n' "$SYSTEMD_UNIT_DIR" "$1"
}

write_app_unit_dropin() {
    local app=$1 via dir
    via=$(effective_via_for_app "$app" __default__)
    dir=$(app_dropin_dir "$app")
    rm -rf "$dir"

    if [[ "$via" != host ]]; then
        install -d -o root -g root -m 0755 "$dir"
        cat >"$dir/10-upstream.conf" <<APP_DROPIN_EOF
[Unit]
Requires=nns-online@$via.service
After=nns-online@$via.service
BindsTo=nns-online@$via.service
APP_DROPIN_EOF
        chmod 0644 "$dir/10-upstream.conf"
    fi
}

write_gateway_unit_dropin() {
    local gateway=$1 via dir
    load_gateway_cfg "$gateway"
    via=$VIA_APP
    dir=$(gateway_dropin_dir "$gateway")
    rm -rf "$dir"
    install -d -o root -g root -m 0755 "$dir"
    cat >"$dir/10-upstream.conf" <<GATEWAY_DROPIN_EOF
[Unit]
Requires=nns-online@$via.service
After=nns-online@$via.service
BindsTo=nns-online@$via.service
GATEWAY_DROPIN_EOF
    chmod 0644 "$dir/10-upstream.conf"
}

write_sudoers_for_app() {
    local app=$1 user=$2 hash alias file tmp
    hash=$(printf '%s' "$app" | cksum | awk '{print $1}')
    alias="NNS_APP_${hash}"
    file="/etc/sudoers.d/nns-app-${app}"
    tmp=$(mktemp)

    cat >"$tmp" <<SUDOERS_EOF
Defaults!$ENGINE_PATH !use_pty
Defaults!$ENGINE_PATH env_keep += "NNS_APP_RUN_PATH DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE DESKTOP_SESSION GDMSESSION GNOME_DESKTOP_SESSION_ID GNOME_KEYRING_CONTROL KDE_FULL_SESSION KDE_SESSION_VERSION XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME XDG_CONFIG_DIRS XDG_DATA_DIRS LANG LANGUAGE LC_ALL TERM COLORTERM SSH_AUTH_SOCK"
Cmnd_Alias $alias = \\
    $ENGINE_PATH list, \\
    $ENGINE_PATH list apps, \\
    $ENGINE_PATH list all, \\
    $ENGINE_PATH list gateway, \\
    $ENGINE_PATH list gateways, \\
    $ENGINE_PATH list client, \\
    $ENGINE_PATH list clients, \\
    $ENGINE_PATH status $app, \\
    $ENGINE_PATH myip $app, \\
    $ENGINE_PATH start $app, \\
    $ENGINE_PATH start -i $app, \\
    $ENGINE_PATH start --ignore-start-error $app, \\
    $ENGINE_PATH start $app --via *, \\
    $ENGINE_PATH start -i $app --via *, \\
    $ENGINE_PATH start --ignore-start-error $app --via *, \\
    $ENGINE_PATH stop $app, \\
    $ENGINE_PATH run $app *
$user ALL=(root) NOPASSWD: $alias
SUDOERS_EOF

    visudo -cf "$tmp" >/dev/null || {
        rm -f "$tmp"
        die "Generated sudoers rule failed validation."
    }
    install -o root -g root -m 0440 "$tmp" "$file"
    restore_selinux_contexts "$file"
    rm -f "$tmp"
}

install_app() {
    require_root
    local app=$1 via_setting=${2:-__default__} normalized_via=""
    validate_app_name "$app"
    [[ ! -f "$(gateway_cfg_file "$app")" ]] ||
        die "A managed gateway named '$app' already exists; choose another app name."
    acquire_lock global

    if [[ "$via_setting" != __default__ ]]; then
        normalized_via=$(normalize_via "$app" "$via_setting")
    fi

    ensure_dependencies
    install_engine_files
    install -d -o root -g root -m 0755 \
        "$BASE_DIR" "$RUN_DIR" "$CACHE_DIR" "$STATE_DIR" \
        "$GATEWAY_BASE_DIR" "$GATEWAY_RUN_BASE" "$REMOTE_BASE_DIR" "$LOCK_DIR"

    local dir file user net_data cidr host_addr ns_addr veth_data veth_host veth_ns
    dir=$(cfg_dir "$app")
    file=$(cfg_file "$app")

    if [[ -f "$file" ]]; then
        load_cfg "$app"
        if [[ "$via_setting" != __default__ ]]; then
            if [[ "$normalized_via" == host ]]; then
                cfg_set "$app" UPSTREAM_APP ""
            else
                cfg_set "$app" UPSTREAM_APP "$normalized_via"
            fi
            load_cfg "$app"
        fi
        write_sudoers_for_app "$app" "$APP_USER"
        write_app_unit_dropin "$app"
        systemctl daemon-reload
        release_lock global
        log "NNS app '$app' is already installed; engine files were refreshed."
        log "Config: $file"
        log "Upstream: ${UPSTREAM_APP:-host}"
        return 0
    fi

    user=${NNS_APP_USER:-${SUDO_USER:-}}
    if [[ -z "$user" || "$user" == root ]]; then
        user=$(logname 2>/dev/null || true)
    fi
    [[ -n "$user" && "$user" != root ]] ||
        die "Cannot determine the application user. Run with sudo from that user, or set NNS_APP_USER."
    id "$user" >/dev/null 2>&1 || die "User '$user' does not exist."

    net_data=$(allocate_network)
    IFS='|' read -r cidr host_addr ns_addr <<<"$net_data"
    veth_data=$(make_veth_names "$app")
    IFS='|' read -r veth_host veth_ns <<<"$veth_data"

    install -d -o root -g root -m 0755 "$dir"
    install -d -o root -g root -m 0700 "$(profiles_dir "$app")"

    cat >"$file" <<CONFIG_EOF
# nns-app application-environment settings. Edit with: sudoedit $file
APP_NAME="$app"
APP_USER="$user"
DEFAULT_PROFILE=""
# Empty until a profile is added; the add command sets this to openvpn or wireguard.
VPN_TYPE=""

# on: application traffic cannot fall back to the host uplink.
# off: direct fallback through the host uplink is allowed.
KILLSWITCH="on"

# on starts this application environment during boot; off leaves it stopped.
AUTOSTART="off"

# Empty/host uses the host uplink. An app name routes this environment
# through that application environment's verified VPN tunnel.
UPSTREAM_APP="${normalized_via#host}"

# Used only with a direct host uplink. auto follows the host IPv4 default route.
WAN_IFACE="auto"
DNS_SERVERS="1.1.1.1 9.9.9.9"
DISABLE_IPV6="on"
DISABLE_DCO="off"

# on: normalize the managed copy of every added profile for this NNS engine:
#     disable DCO, permit detected legacy SHA-1/MD5 certificate chains, and
#     add a data-ciphers fallback for legacy CBC-only profiles.
# off: store the profile byte-for-byte without compatibility changes.
PROFILE_FIXUPS="on"
READY_TIMEOUT="5"
EXTERNAL_IP_URL="https://api.ipify.org"

# auto: monitor OpenVPN/WireGuard only while this environment is running.
# on:   same monitoring policy, explicitly enabled.
# off:  never start the data-path watchdog for this environment.
WATCHDOG_MODE="auto"
# Restart the VPN backend after this many consecutive failed probes.
WATCHDOG_FAILURES="3"
# Minimum seconds between watchdog-triggered backend restarts.
WATCHDOG_COOLDOWN="300"

# Optional local transport for .nnslink profiles. These values are managed by
# nns-app link import / nns-app remote sync.
TRANSPORT_TYPE="direct"
TRANSPORT_REMOTE_HOST=""
TRANSPORT_REMOTE_PORT=""
TRANSPORT_LOCAL_PORT=""
TRANSPORT_CONFIG=""
# Used only by the automatic SSH-forward transport. The dedicated private key
# and pinned host-key file remain root-owned on the local machine.
TRANSPORT_SSH_TARGET=""
TRANSPORT_SSH_IDENTITY=""
TRANSPORT_SSH_KNOWN_HOSTS=""
TRANSPORT_SSH_REMOTE_PORT=""

# SSH management-plane metadata. In manual remote mode the VPN data path does
# not depend on SSH; automatic remote mode intentionally uses a supervised SSH
# local forward so no additional inbound cloud port is required.
REMOTE_MODE=""
REMOTE_ALIAS=""
REMOTE_GATEWAY=""
REMOTE_CLIENT=""
REMOTE_OWNER_ID=""
REMOTE_EXIT_APP=""
REMOTE_PROFILE_GENERATION=""
REMOTE_SERVER_FINGERPRINT=""
# Set after remote cleanup succeeds so a multi-app purge can be retried safely.
REMOTE_CLEANED="off"
# Ownership marker used only on hidden remote exits created by automatic mode.
REMOTE_MANAGED_OWNER_ID=""

# Engine-owned namespace network. Never copy these values to another environment.
NS_NAME="nns-$app"
NS_CIDR="$cidr"
HOST_ADDR="$host_addr"
NS_ADDR="$ns_addr"
VETH_HOST="$veth_host"
VETH_NS="$veth_ns"
CONFIG_EOF

    chown root:root "$file"
    chmod 0644 "$file"
    write_sudoers_for_app "$app" "$user"
    write_app_unit_dropin "$app"
    systemctl daemon-reload
    release_lock global

    log "Installed NNS app '$app'."
    log "Config:   $file"
    log "Profiles: $(profiles_dir "$app")"
    log "Upstream: ${normalized_via:-host}"
    log "Next:     sudo $USER_PATH add $app /path/to/profile.ovpn"
    log "          or: sudo $USER_PATH add $app /path/to/wireguard.conf"
    log "          or: sudo $USER_PATH add $app any [country]${normalized_via:+ --via $normalized_via}"
}

