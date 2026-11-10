# nns-app AmneziaWG 3.1 host server. Persistent state lives in the managed
# gateway tree so existing backups include both server and client private keys.

awg_server_config() { printf '%s/%s.conf\n' "$(gateway_dir "$1")" "$(gateway_cfg_value "$1" GATEWAY_TUN)"; }

awg_server_require_runtime() {
    command -v awg >/dev/null 2>&1 || die "AmneziaWG 3.1 tools missing. On Ubuntu run: sudo nns-app --install amnezia"
    command -v awg-quick >/dev/null 2>&1 || die "AmneziaWG awg-quick missing. On Ubuntu run: sudo nns-app --install amnezia"
    # Prefer the userspace backend and do not request an AWG kernel module
    # when amneziawg-go is installed.
    if ! command -v amneziawg-go >/dev/null 2>&1 &&
       ! modprobe -q amneziawg 2>/dev/null; then
        die "AmneziaWG userspace backend missing. On Ubuntu run: sudo nns-app --install amnezia"
    fi
    [[ -c /dev/net/tun ]] || modprobe tun 2>/dev/null || true
}

awg_server_key() {
    local key=$1 value
    value=$(awg genkey) || return 1
    [[ "$value" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
    printf '%s\n' "$value" >"$key"
    chmod 0600 "$key"
}

awg_server_client_ip() {
    local root=$1 client=$2 pool=$3
    python3 - "$root" "$client" "$pool" <<'PY_AWG_ALLOC'
from pathlib import Path
import ipaddress, sys
root, client, network = Path(sys.argv[1]), sys.argv[2], ipaddress.ip_network(sys.argv[3], strict=True)
used = {network.network_address + 1}
for cfg in (root/'clients').glob('*/client.cfg'):
    if cfg.parent.name == client: continue
    for line in cfg.read_text().splitlines():
        if line.startswith('FIXED_IP='):
            try: used.add(ipaddress.ip_address(line.split('=',1)[1].strip('"\'')))
            except ValueError: raise SystemExit('Invalid existing AmneziaWG fixed IP')
for candidate in network.hosts():
    if candidate not in used:
        print(candidate)
        break
else:
    raise SystemExit('No free AmneziaWG client IPs')
PY_AWG_ALLOC
}

awg_server_write_config() {
    local gateway=$1 root="$(gateway_dir "$1")" config tmp server_ip client_dir cfg status key ip
    load_gateway_cfg "$gateway"
    [[ "$GATEWAY_BACKEND" == amneziawg ]] || die "Not an AmneziaWG server: $gateway"
    server_ip=$(python3 - "$CLIENT_POOL" <<'PY_AWG_HOST'
import ipaddress,sys
net=ipaddress.ip_network(sys.argv[1], strict=True)
print(next(net.hosts()))
PY_AWG_HOST
    ) || return 1
    config="$root/$GATEWAY_TUN.conf"
    tmp=$(mktemp "$root/.amnezia-conf.XXXXXX") || return 1
    {
        printf '[Interface]\n'
        printf 'PrivateKey = %s\n' "$(cat "$root/server.key")"
        printf 'Address = %s/%s\n' "$server_ip" "${CLIENT_POOL#*/}"
        printf 'ListenPort = %s\nMTU = 1280\n' "$LISTEN_PORT"
        printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "$AWG_JC" "$AWG_JMIN" "$AWG_JMAX"
        printf 'S1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n' "$AWG_S1" "$AWG_S2" "$AWG_S3" "$AWG_S4"
        printf 'H1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
        printf 'HeaderProtectionKey = %s\n' "$(cat "$root/header.key")"
        printf 'ContentPaddingAddition = 32-128\n'
        printf 'PostUp = /usr/local/sbin/nns_app.sh _gateway-tun-up %s\n' "$gateway"
        shopt -s nullglob
        for client_dir in "$root/clients"/*; do
            cfg="$client_dir/client.cfg"
            [[ -f "$cfg" ]] || continue
            status=$(sed -n 's/^STATUS=//p' "$cfg" | head -n 1 | tr -d '"')
            [[ "$status" == active ]] || continue
            key=$(cat "$client_dir/public.key") || return 1
            ip=$(sed -n 's/^FIXED_IP=//p' "$cfg" | head -n 1 | tr -d '"')
            [[ -n "$ip" ]] || die "Missing fixed IP for AmneziaWG peer '${client_dir##*/}'."
            printf '\n[Peer]\n# Client: %s\nPublicKey = %s\nAllowedIPs = %s/32\n' \
                "${client_dir##*/}" "$key" "$ip"
        done
        shopt -u nullglob
    } >"$tmp" || { rm -f "$tmp"; return 1; }
    chmod 0600 "$tmp"
    mv -f "$tmp" "$config"
}

awg_server_enable_dropin() {
    local gateway=$1 dir
    dir=$(gateway_dropin_dir "$gateway")
    install -d -o root -g root -m 0755 "$dir"
    cat >"$dir/20-amnezia.conf" <<'UNIT'
[Unit]
Description=NNS managed AmneziaWG server %i
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=
ExecStart=/usr/local/sbin/nns_app.sh _amnezia-up %i
ExecStop=/usr/local/sbin/nns_app.sh _amnezia-down %i
Restart=no
UNIT
    chmod 0644 "$dir/20-amnezia.conf"
}

awg_server_up() {
    require_root
    local gateway=$1
    load_gateway_cfg "$gateway"
    [[ "$GATEWAY_BACKEND" == amneziawg ]] || die "Not an AmneziaWG server."
    awg_server_require_runtime
    awg-quick up "$(awg_server_config "$gateway")"
}

awg_server_down() {
    require_root
    local gateway=$1
    load_gateway_cfg "$gateway"
    [[ "$GATEWAY_BACKEND" == amneziawg ]] || die "Not an AmneziaWG server."
    awg-quick down "$(awg_server_config "$gateway")" || true
}

awg_server_start() {
    require_root
    local gateway=$1
    load_gateway_cfg "$gateway"
    awg_server_require_runtime
    write_gateway_unit_dropin "$gateway"
    awg_server_write_config "$gateway"
    systemctl daemon-reload
    if systemctl is-active --quiet "nns-gateway@$gateway.service"; then
        systemctl restart "nns-gateway@$gateway.service" || return 1
    else
        systemctl start "nns-gateway@$gateway.service" || return 1
    fi
    ip link show "$GATEWAY_TUN" up >/dev/null 2>&1 || die "AmneziaWG interface '$GATEWAY_TUN' not created. Check journalctl -u nns-gateway@$gateway."
    log "AmneziaWG server '$gateway' active at $PUBLIC_HOST:$PUBLIC_PORT/udp."
}

awg_server_install() {
    require_root
    local name=$1 listen=${2:-} public=${3:-} pool=${4:-} dns=${5:-} c2c=${6:-}
    local proto port host public_port root staging tun host_fwd host_mangle ns_fwd ns_nat ns_mangle
    local veth_host veth_ns conflict existing=no backup_cfg="" previously_active=off
    validate_gateway_name "$name"
    [[ ! -f "$(cfg_file "$name")" ]] || die "'$name' is an existing namespace app."
    if [[ -f "$(gateway_cfg_file "$name")" ]]; then
        [[ "$(gateway_cfg_value "$name" GATEWAY_BACKEND)" == amneziawg ]] ||
            die "'$name' already exists as an OpenVPN server; use a different name."
        existing=yes
    fi
    [[ -z "$c2c" || "$c2c" == off || "$c2c" == on ]] || die "Expected --client-to-client=on|off."
    awg_server_require_runtime
    [[ -z "$dns" ]] || dns=$(validate_gateway_dns "$dns")
    acquire_lock global
    if [[ "$existing" == yes ]]; then
        load_gateway_cfg "$name"
        root=$(gateway_dir "$name")
        backup_cfg=$(mktemp "$root/.reinstall-cfg.XXXXXX") || die "Cannot snapshot AmneziaWG server."
        cp -p "$(gateway_cfg_file "$name")" "$backup_cfg" || die "Cannot snapshot AmneziaWG configuration."
        systemctl is-active --quiet "nns-gateway@$name.service" && previously_active=on || true
        [[ -z "$listen" ]] || [[ "$listen" == "$LISTEN_PROTO:$LISTEN_PORT" ]] ||
            die "Changing an existing AmneziaWG listener requires migration; keys and peers preserved, use the same --listen."
        [[ -z "$pool" || "$pool" == "$CLIENT_POOL" ]] || die "Cannot change a pool with existing peers."
        [[ -z "$public" ]] || {
            IFS='|' read -r host public_port <<<"$(parse_public_endpoint "$public")"
            gateway_cfg_set "$name" PUBLIC_HOST "$host"
            gateway_cfg_set "$name" PUBLIC_PORT "$public_port"
        }
        [[ -z "$dns" ]] || gateway_cfg_set "$name" DNS_SERVERS "$(validate_gateway_dns "$dns")"
        [[ -z "$c2c" ]] || gateway_cfg_set "$name" CLIENT_TO_CLIENT "$c2c"
        # Reconfiguration never regenerates server or client private keys.
    else
        listen=${listen:-$(server_choose_listener "$name")}
        IFS='|' read -r proto port <<<"$(parse_gateway_listen "$listen")"
        [[ "$proto" == udp ]] || die "AmneziaWG uses UDP; use --listen udp:<port>."
        if conflict=$(server_listener_conflict udp "$port" "$name"); then die "$conflict"; fi
        if [[ -z "$public" ]]; then
            host=$(server_public_host) || die "Cannot discover public host; pass --public host:port."
            public="$host:$port"
        fi
        IFS='|' read -r host public_port <<<"$(parse_public_endpoint "$public")"
        IFS='|' read -r pool _ _ _ <<<"$(allocate_gateway_networks "$pool")"
        IFS='|' read -r tun veth_host veth_ns host_fwd host_mangle ns_fwd ns_nat ns_mangle <<<"$(make_gateway_names "$name")"
        root=$(gateway_dir "$name")
        install -d -m 0755 "$(dirname "$root")"
        staging=$(mktemp -d "$(dirname "$root")/.${name}.awg.XXXXXX") || die "Cannot stage AmneziaWG server."
        mkdir -m 0700 "$staging/clients"
        awg_server_key "$staging/server.key" || die "Cannot generate AmneziaWG server key."
        awg pubkey <"$staging/server.key" >"$staging/server.pub" || die "Cannot derive AmneziaWG public key."
        awg_server_key "$staging/header.key" || die "Cannot generate header-protection key."
        local params awg_jc awg_jmin awg_jmax awg_s1 awg_s2 awg_s3 awg_s4
        params=$(python3 - <<'PY_AWG_PARAMS'
import secrets
rng = secrets.SystemRandom()
print('|'.join(map(str, (
    rng.randint(3, 6), rng.randint(45, 75), rng.randint(190, 250),
    rng.randint(40, 100), rng.randint(16, 39),
    rng.randint(16, 70), rng.randint(16, 70)
))))
PY_AWG_PARAMS
        ) || die "Cannot generate AmneziaWG obfuscation parameters."
        IFS='|' read -r awg_jc awg_jmin awg_jmax awg_s1 awg_s2 awg_s3 awg_s4 <<<"$params"
        cat >"$staging/gateway.cfg" <<EOF_CFG
GATEWAY_NAME="$name"
GATEWAY_BACKEND="amneziawg"
VIA_APP="host"
TRANSPORT="direct"
LISTEN_PROTO="udp"
LISTEN_PORT="$port"
PUBLIC_HOST="$host"
PUBLIC_PORT="$public_port"
TRANSPORT_SERVER_NAME="$host"
CLIENT_POOL="$pool"
DNS_SERVERS="${dns:-1.1.1.1 9.9.9.9}"
CLIENT_TO_CLIENT="${c2c:-off}"
AWG_JC="$awg_jc"
AWG_JMIN="$awg_jmin"
AWG_JMAX="$awg_jmax"
AWG_S1="$awg_s1"
AWG_S2="$awg_s2"
AWG_S3="$awg_s3"
AWG_S4="$awg_s4"
GATEWAY_TUN="$tun"
GATEWAY_VETH_HOST="$veth_host"
GATEWAY_VETH_NS="$veth_ns"
HOST_FWD_CHAIN="$host_fwd"
HOST_MANGLE_CHAIN="$host_mangle"
NS_FWD_CHAIN="$ns_fwd"
NS_NAT_CHAIN="$ns_nat"
NS_MANGLE_CHAIN="$ns_mangle"
ROUTE_TABLE="0"
RULE_PRIORITY="0"
EOF_CFG
        chmod 0644 "$staging/gateway.cfg"
        chmod 0711 "$staging"
        mv "$staging" "$root"
    fi
    write_gateway_unit_dropin "$name"
    systemctl daemon-reload
    systemctl enable "nns-gateway@$name.service" >/dev/null || true
    release_lock global
    if ! awg_server_start "$name"; then
        if [[ "$existing" == yes && -s "$backup_cfg" ]]; then
            cp -p "$backup_cfg" "$(gateway_cfg_file "$name")"
            awg_server_write_config "$name" || true
            if [[ "$previously_active" == on ]]; then
                systemctl restart "nns-gateway@$name.service" ||
                    warn "Could not restart '$name' after restoring its previous configuration."
            fi
        fi
        [[ -z "$backup_cfg" ]] || rm -f "$backup_cfg"
        die "AmneziaWG server '$name' failed to start; existing config restored if this was a reinstall."
    fi
    [[ -z "$backup_cfg" ]] || rm -f "$backup_cfg"
    log "Export client: nns-app export awg $name --client mac --split-tunnel --output mac.conf"
}

awg_server_client_add() {
    require_root
    local gateway=$1 client=$2 route_mode=${3:-split} root dir staging ip created
    validate_gateway_client_name "$client"
    [[ "$route_mode" == split || "$route_mode" == full ]] || die "Expected split or full routing."
    load_gateway_cfg "$gateway"
    [[ "$GATEWAY_BACKEND" == amneziawg ]] || die "Not an AmneziaWG server."
    root=$(gateway_dir "$gateway")
    dir=$(gateway_client_dir "$gateway" "$client")
    [[ ! -e "$dir" ]] || die "Client '$client' already exists."
    acquire_lock "gateway-$gateway"
    staging=$(mktemp -d "$root/clients/.${client}.XXXXXX") || die "Cannot stage client."
    awg_server_key "$staging/private.key" || die "Cannot generate peer key."
    awg pubkey <"$staging/private.key" >"$staging/public.key" || die "Cannot derive peer public key."
    ip=$(awg_server_client_ip "$root" "$client" "$CLIENT_POOL") || die "No free peer IP."
    created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf 'CLIENT_NAME="%s"\nSTATUS="active"\nFIXED_IP="%s"\nROUTE_MODE="%s"\nCREATED_AT="%s"\n' \
        "$client" "$ip" "$route_mode" "$created" >"$staging/client.cfg"
    chmod 0600 "$staging/client.cfg" "$staging/private.key" "$staging/public.key"
    mv "$staging" "$dir"
    awg_server_write_config "$gateway"
    release_lock "gateway-$gateway"
    if systemctl is-active --quiet "nns-gateway@$gateway.service"; then
        # Apply peer without bouncing established peers; `syncconf` handles
        # config changes and preserves existing handshakes.
        awg syncconf "$GATEWAY_TUN" <(awg-quick strip "$(awg_server_config "$gateway")") ||
            die "Peer created but could not be applied; restart server manually."
    fi
    log "Created AmneziaWG peer '$client': $ip"
}

awg_server_client_export() {
    require_root
    local gateway=$1 client=$2 output=$3 route=${4:-keep} root dir ip mode dns item tmp owner group
    validate_gateway_name "$gateway"
    validate_gateway_client_name "$client"
    [[ -n "$output" && "$output" != - ]] || die "AmneziaWG export requires --output <client.conf> (cannot print private keys to stdout)."
    load_gateway_cfg "$gateway"
    [[ "$GATEWAY_BACKEND" == amneziawg ]] || die "Not an AmneziaWG server."
    root=$(gateway_dir "$gateway")
    dir=$(gateway_client_dir "$gateway" "$client")
    [[ -f "$dir/client.cfg" ]] || awg_server_client_add "$gateway" "$client" "${route/keep/split}"
    [[ -f "$dir/client.cfg" ]] || die "Could not create AmneziaWG peer."
    [[ "$(sed -n 's/^STATUS=//p' "$dir/client.cfg" | tr -d '"')" == active ]] || die "Peer revoked."
    if [[ "$route" == split || "$route" == full ]]; then
        sed -i -E "s/^ROUTE_MODE=.*/ROUTE_MODE=\"$route\"/" "$dir/client.cfg"
    fi
    mode=$(sed -n 's/^ROUTE_MODE=//p' "$dir/client.cfg" | tr -d '"')
    ip=$(sed -n 's/^FIXED_IP=//p' "$dir/client.cfg" | tr -d '"')
    output=$(readlink -m "$output")
    [[ ! -e "$output" ]] || die "Export file exists: $output"
    [[ -d "$(dirname "$output")" ]] || die "Output directory missing: $output"
    tmp=$(mktemp) || return 1
    {
        printf '[Interface]\nPrivateKey = %s\nAddress = %s/32\nMTU = 1280\n' "$(cat "$dir/private.key")" "$ip"
        if [[ "$mode" == full ]]; then
            printf 'DNS = %s\n' "${DNS_SERVERS// /, }"
        fi
        printf 'Jc = %s\nJmin = %s\nJmax = %s\n' "$AWG_JC" "$AWG_JMIN" "$AWG_JMAX"
        printf 'S1 = %s\nS2 = %s\nS3 = %s\nS4 = %s\n' "$AWG_S1" "$AWG_S2" "$AWG_S3" "$AWG_S4"
        printf 'H1 = 1\nH2 = 2\nH3 = 3\nH4 = 4\n'
        printf 'HeaderProtectionKey = %s\n' "$(cat "$root/header.key")"
        printf 'ContentPaddingAddition = 32-128\n'
        printf '\n[Peer]\nPublicKey = %s\nEndpoint = %s:%s\n' "$(cat "$root/server.pub")" "$PUBLIC_HOST" "$PUBLIC_PORT"
        if [[ "$mode" == full ]]; then
            printf 'AllowedIPs = 0.0.0.0/0\n'
        else
            printf 'AllowedIPs = %s\n' "$CLIENT_POOL"
        fi
        printf 'PersistentKeepalive = 25\n'
    } >"$tmp" || { rm -f "$tmp"; return 1; }
    owner=${SUDO_USER:-root}
    if [[ "$owner" != root ]] && id "$owner" >/dev/null 2>&1; then
        group=$(id -gn "$owner")
    else
        owner=root; group=root
    fi
    install -m 0600 -o "$owner" -g "$group" "$tmp" "$output" || return 1
    rm -f "$tmp"
    log "Exported AmneziaWG client '$client' to $output ($mode, fixed $ip)."
}

awg_server_client_revoke() {
    require_root
    local gateway=$1 client=$2 dir
    load_gateway_cfg "$gateway"
    [[ "$GATEWAY_BACKEND" == amneziawg ]] || die "Not an AmneziaWG server."
    dir=$(gateway_client_dir "$gateway" "$client")
    [[ -f "$dir/client.cfg" ]] || die "Client '$client' does not exist."
    sed -i -E 's/^STATUS=.*/STATUS="revoked"/' "$dir/client.cfg"
    awg_server_write_config "$gateway"
    if systemctl is-active --quiet "nns-gateway@$gateway.service"; then
        awg syncconf "$GATEWAY_TUN" <(awg-quick strip "$(awg_server_config "$gateway")") ||
            die "Client marked revoked but server sync failed; restart server."
    fi
    log "Revoked AmneziaWG peer '$client'."
}

awg_server_connected_clients() {
    local gateway=$1 root dir key handshake now ip rx tx
    load_gateway_cfg "$gateway"
    root=$(gateway_dir "$gateway")
    now=$(date +%s)
    shopt -s nullglob
    for dir in "$root/clients"/*; do
        [[ -f "$dir/client.cfg" ]] || continue
        [[ "$(sed -n 's/^STATUS=//p' "$dir/client.cfg" | tr -d '"')" == active ]] || continue
        key=$(cat "$dir/public.key")
        handshake=$(awg show "$GATEWAY_TUN" latest-handshakes 2>/dev/null | awk -v k="$key" '$1==k {print $2}')
        [[ "$handshake" =~ ^[0-9]+$ ]] || continue
        (( handshake > 0 && now - handshake < 180 )) || continue
        ip=$(sed -n 's/^FIXED_IP=//p' "$dir/client.cfg" | tr -d '"')
        IFS=$'\t' read -r rx tx < <(awg show "$GATEWAY_TUN" transfer 2>/dev/null | awk -v k="$key" '$1==k {printf "%s\t%s\n",$2,$3}') || true
        printf '%s|%s|%s|%s|%s|%s\n' "${dir##*/}" "handshake" "$ip" "${rx:-0}" "${tx:-0}" "$(date -u -d "@$handshake" +%F\ %T)"
    done
    shopt -u nullglob
}

awg_server_status() {
    local gateway=$1 unit state iface=no fw=no listen=no connected
    load_gateway_cfg "$gateway"
    unit="nns-gateway@$gateway.service"
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    ip link show "$GATEWAY_TUN" up >/dev/null 2>&1 && iface=yes
    [[ "$(awg show "$GATEWAY_TUN" listen-port 2>/dev/null || true)" == "$LISTEN_PORT" ]] && listen=yes
    local wan
    wan=$(detect_wan_iface auto 2>/dev/null || true)
    if [[ -n "$wan" ]]; then
        gateway_firewall_ready "$gateway" '' "$wan" && fw=yes || true
    fi
    connected=$(awg_server_connected_clients "$gateway" | grep -c . || true)
    local health=STOPPED
    if [[ "$state" == active ]]; then
        health=DEGRADED
        [[ "$iface" == yes && "$listen" == yes && "$fw" == yes ]] && health=READY
    elif [[ "$state" == failed ]]; then
        health=FAILED
    fi
    printf 'App:               %s\nType:              amneziawg-server\nHealth:            %s\n' \
        "$gateway" "$health"
    printf 'Service:           %s\nPublic endpoint:   %s:%s/udp\nClient pool:       %s\n' \
        "${state:-stopped}" "$PUBLIC_HOST" "$PUBLIC_PORT" "$CLIENT_POOL"
    printf 'Tunnel:            %s (%s)\nListener:          %s\nFirewall:          %s\n' \
        "$GATEWAY_TUN" "$iface" "$listen" "$fw"
    printf 'Client-to-client:  %s\nConnected peers:   %s (handshake within 180s)\n' "$CLIENT_TO_CLIENT" "$connected"
}
