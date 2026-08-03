# nns-app source module: dependency checks, installation, upgrades and removal.
check_openvpn_version() {
    local raw version
    raw=$(openvpn --version 2>/dev/null | head -n1 || true)
    version=$(sed -nE \
        's/^OpenVPN[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' <<<"$raw")
    [[ -n "$version" ]] ||
        die "Cannot determine the installed OpenVPN version."

    if [[ "$(printf '%s\n%s\n' '2.6.0' "$version" | sort -V | head -n1)" != 2.6.0 ]]; then
        die "OpenVPN 2.6.0 or newer is required; found $version."
    fi
}

ensure_dependencies() {
    local missing=()
    command -v ip >/dev/null 2>&1       || missing+=(iproute2)
    command -v openvpn >/dev/null 2>&1  || missing+=(openvpn)
    command -v wg >/dev/null 2>&1       || missing+=(wireguard-tools)
    command -v wg-quick >/dev/null 2>&1 || missing+=(wireguard-tools)
    command -v iptables >/dev/null 2>&1 || missing+=(iptables)
    command -v curl >/dev/null 2>&1     || missing+=(curl)
    command -v ping >/dev/null 2>&1     || missing+=(iputils-ping)
    command -v setpriv >/dev/null 2>&1  || missing+=(util-linux)
    command -v sudo >/dev/null 2>&1     || missing+=(sudo)
    command -v openssl >/dev/null 2>&1  || missing+=(openssl)
    command -v python3 >/dev/null 2>&1  || missing+=(python3)

    if (( ${#missing[@]} )); then
        log "Installing required packages: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    fi
    check_openvpn_version
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

    chmod 0644 "$NETNS_UNIT" "$VPN_UNIT" "$ONLINE_UNIT" "$GATEWAY_UNIT" \
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
        write_app_unit_dropin "$app"
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
Defaults!$ENGINE_PATH env_keep += "DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR LANG LC_ALL TERM COLORTERM SSH_AUTH_SOCK"
Cmnd_Alias $alias = \\
    $ENGINE_PATH list, \\
    $ENGINE_PATH status $app, \\
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
# Empty until a profile is added; `add` sets this to openvpn or wireguard.
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

# Optional local transport for .nnslink profiles. These values are managed by
# `nns-app link import` / `nns-app remote sync`.
TRANSPORT_TYPE="direct"
TRANSPORT_REMOTE_HOST=""
TRANSPORT_REMOTE_PORT=""
TRANSPORT_LOCAL_PORT=""
TRANSPORT_CONFIG=""

# SSH management-plane metadata. The VPN data path never depends on SSH.
REMOTE_ALIAS=""
REMOTE_GATEWAY=""
REMOTE_CLIENT=""
REMOTE_PROFILE_GENERATION=""
REMOTE_SERVER_FINGERPRINT=""

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

