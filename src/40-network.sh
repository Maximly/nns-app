# nns-app source module: endpoint parsing, namespace networking and firewall rules.
profile_endpoints() {
    local profile=$1 type
    type=$(profile_type_from_file "$profile" 2>/dev/null || true)
    [[ -n "$type" ]] || die "Cannot determine VPN profile type: $profile"

    case "$type" in
        openvpn)
            # Output: host|port|protocol. Ignore inline certificate/key blocks.
            awk '
                BEGIN { inblock=0; proto="udp"; port="1194" }
                { gsub(/\r/, "", $0) }
                /^[[:space:]]*<[^/][^>]*>[[:space:]]*$/ { inblock=1; next }
                /^[[:space:]]*<\/[A-Za-z0-9_-]+>[[:space:]]*$/ { inblock=0; next }
                inblock { next }
                /^[[:space:]]*[#;]/ { next }
                {
                    key=tolower($1)
                    if (key == "proto" && NF >= 2) proto=tolower($2)
                    else if (key == "port" && NF >= 2) port=$2
                    else if (key == "remote" && NF >= 2) {
                        rport=(NF >= 3 && $3 != "") ? $3 : port
                        rproto=(NF >= 4 && $4 != "") ? tolower($4) : proto
                        if (rproto ~ /^tcp/) rproto="tcp"
                        else rproto="udp"
                        print $2 "|" rport "|" rproto
                    }
                }
            ' "$profile"
            ;;
        wireguard)
            python3 - "$profile" <<'PY_WG_ENDPOINTS'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
for raw in text.splitlines():
    line = raw.split("#", 1)[0].strip()
    if not line or "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key.strip().casefold() != "endpoint":
        continue
    endpoint = value.strip()
    if endpoint.startswith("["):
        raise SystemExit("IPv6 WireGuard endpoints are unsupported")
    host, port = endpoint.rsplit(":", 1)
    print(f"{host}|{port}|udp")
PY_WG_ENDPOINTS
            ;;
    esac
}


resolve_profile_endpoints() {
    local profile=$1 outfile=$2 resolver_ns=${3:-host}
    local host port proto ip
    local tmp
    tmp=$(mktemp)
    : >"$tmp"

    while IFS='|' read -r host port proto; do
        host=${host//$'\r'/}
        port=${port//$'\r'/}
        proto=${proto//$'\r'/}

        [[ -n "$host" && -n "$port" && -n "$proto" ]] || continue
        [[ "$port" =~ ^[0-9]+$ ]] ||
            die "Invalid VPN endpoint port '$port' in $profile"
        (( port >= 1 && port <= 65535 )) ||
            die "VPN endpoint port '$port' is outside 1..65535 in $profile"
        case "$proto" in
            tcp|udp) ;;
            *) die "Invalid VPN endpoint protocol '$proto' in $profile" ;;
        esac

        if [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            printf '%s|%s|%s\n' "$host" "$port" "$proto" >>"$tmp"
        else
            [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] ||
                die "Invalid VPN endpoint host '$host' in $profile"
            if [[ "$resolver_ns" == host ]]; then
                while read -r ip; do
                    [[ -n "$ip" ]] && printf '%s|%s|%s\n' "$ip" "$port" "$proto" >>"$tmp"
                done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
            else
                while read -r ip; do
                    [[ -n "$ip" ]] && printf '%s|%s|%s\n' "$ip" "$port" "$proto" >>"$tmp"
                done < <(ip netns exec "$resolver_ns" getent ahostsv4 "$host" 2>/dev/null |
                         awk '{print $1}' | sort -u)
            fi
        fi
    done < <(profile_endpoints "$profile")

    sort -u "$tmp" >"$outfile"
    rm -f "$tmp"
    [[ -s "$outfile" ]] || die "Could not resolve any IPv4 VPN endpoint from $profile"
}

detect_wan_iface() {
    local requested=$1
    if [[ "$requested" != auto && -n "$requested" ]]; then
        ip link show "$requested" >/dev/null 2>&1 || die "WAN interface '$requested' does not exist."
        printf '%s\n' "$requested"
        return
    fi

    local wan
    wan=$(ip -4 route get 1.1.1.1 2>/dev/null |
          awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    [[ -n "$wan" ]] || die "Cannot determine the host IPv4 uplink interface."
    printf '%s\n' "$wan"
}

iptables_add_once() {
    local table=$1
    shift
    if [[ "$table" == filter ]]; then
        iptables -w 5 -C "$@" 2>/dev/null || iptables -w 5 -I "$@"
    else
        iptables -w 5 -t "$table" -C "$@" 2>/dev/null ||
            iptables -w 5 -t "$table" -A "$@"
    fi
}

iptables_delete_all() {
    local table=$1
    shift
    if [[ "$table" == filter ]]; then
        while iptables -w 5 -C "$@" 2>/dev/null; do
            iptables -w 5 -D "$@" || break
        done
    else
        while iptables -w 5 -t "$table" -C "$@" 2>/dev/null; do
            iptables -w 5 -t "$table" -D "$@" || break
        done
    fi
}

host_rules_up() {
    local wan=$1
    iptables_add_once filter FORWARD -i "$VETH_HOST" -o "$wan" -j ACCEPT
    iptables_add_once filter FORWARD -i "$wan" -o "$VETH_HOST" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables_add_once nat POSTROUTING -s "$NS_CIDR" -o "$wan" -j MASQUERADE
}

host_rules_down() {
    local wan=$1
    iptables_delete_all filter FORWARD -i "$VETH_HOST" -o "$wan" -j ACCEPT
    iptables_delete_all filter FORWARD -i "$wan" -o "$VETH_HOST" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables_delete_all nat POSTROUTING -s "$NS_CIDR" -o "$wan" -j MASQUERADE
}

netns_iptables_add_once() {
    local ns=$1 table=$2
    shift 2
    if [[ "$table" == filter ]]; then
        ip netns exec "$ns" iptables -w 5 -C "$@" 2>/dev/null ||
            ip netns exec "$ns" iptables -w 5 -I "$@"
    else
        ip netns exec "$ns" iptables -w 5 -t "$table" -C "$@" 2>/dev/null ||
            ip netns exec "$ns" iptables -w 5 -t "$table" -A "$@"
    fi
}

netns_iptables_delete_all() {
    local ns=$1 table=$2
    shift 2
    if [[ "$table" == filter ]]; then
        while ip netns exec "$ns" iptables -w 5 -C "$@" 2>/dev/null; do
            ip netns exec "$ns" iptables -w 5 -D "$@" || break
        done
    else
        while ip netns exec "$ns" iptables -w 5 -t "$table" -C "$@" 2>/dev/null; do
            ip netns exec "$ns" iptables -w 5 -t "$table" -D "$@" || break
        done
    fi
}

upstream_rules_up() {
    local upstream_ns=$1 upstream_tun=$2
    ip netns exec "$upstream_ns" sysctl -q -w net.ipv4.ip_forward=1
    netns_iptables_add_once "$upstream_ns" filter FORWARD \
        -i "$VETH_HOST" -o "$upstream_tun" -j ACCEPT
    netns_iptables_add_once "$upstream_ns" filter FORWARD \
        -i "$upstream_tun" -o "$VETH_HOST" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    netns_iptables_add_once "$upstream_ns" nat POSTROUTING \
        -s "$NS_CIDR" -o "$upstream_tun" -j MASQUERADE
    netns_iptables_add_once "$upstream_ns" mangle FORWARD \
        -i "$VETH_HOST" -o "$upstream_tun" -p tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
}

upstream_rules_down() {
    local upstream_ns=$1 upstream_tun=$2
    netns_iptables_delete_all "$upstream_ns" filter FORWARD \
        -i "$VETH_HOST" -o "$upstream_tun" -j ACCEPT
    netns_iptables_delete_all "$upstream_ns" filter FORWARD \
        -i "$upstream_tun" -o "$VETH_HOST" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    netns_iptables_delete_all "$upstream_ns" nat POSTROUTING \
        -s "$NS_CIDR" -o "$upstream_tun" -j MASQUERADE
    netns_iptables_delete_all "$upstream_ns" mangle FORWARD \
        -i "$VETH_HOST" -o "$upstream_tun" -p tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
}

delete_veth_everywhere() {
    local name=$1 ns
    ip link del "$name" 2>/dev/null || true
    while read -r ns _; do
        [[ -n "$ns" ]] || continue
        ip -n "$ns" link del "$name" 2>/dev/null || true
    done < <(ip netns list 2>/dev/null || true)
}

netns_up() {
    require_root
    local app=$1
    validate_app_name "$app"
    load_cfg "$app"

    local runtime profile endpoints_file via_app host_ip vpn_type tunnel_iface
    local wan="" upstream_ns="" upstream_tun="" upstream_data=""
    runtime="$RUN_DIR/${app}.env"
    endpoints_file="$RUN_DIR/${app}.endpoints"
    via_app=$(effective_via_runtime "$app")

    # Preserve the requested upstream across stale-state cleanup. Cleanup
    # removes the one-start override file, but the current start still owns
    # the already-resolved value.
    if ip netns list | awk '{print $1}' | grep -Fxq "$NS_NAME"; then
        warn "Removing stale namespace '$NS_NAME'."
        netns_down "$app"
        load_cfg "$app"
    fi
    delete_veth_everywhere "$VETH_HOST"

    if [[ "$via_app" == host ]]; then
        wan=$(detect_wan_iface "$WAN_IFACE")
    else
        upstream_data=$(ensure_upstream_ready "$app" "$via_app")
        IFS='|' read -r upstream_ns upstream_tun <<<"$upstream_data"
    fi

    host_ip=${HOST_ADDR%/*}
    profile="$(profiles_dir "$app")/$DEFAULT_PROFILE"
    vpn_type=$(vpn_type_for_app "$app" 2>/dev/null || true)
    [[ -n "$vpn_type" ]] || die "Cannot determine VPN backend for '$app'. Re-add its profile or configure inherit."
    case "$vpn_type" in
        wireguard) tunnel_iface=$(wireguard_iface_name "$app") ;;
        inherit)
            [[ "$via_app" != host ]] || die "Inherit backend '$app' requires an upstream NNS app."
            tunnel_iface=$VETH_NS
            ;;
        openvpn) tunnel_iface='tun+' ;;
        *) die "Unsupported VPN backend '$vpn_type'." ;;
    esac
    if [[ "$vpn_type" != inherit ]]; then
        [[ -n "$DEFAULT_PROFILE" && -f "$profile" ]] ||
            die "No usable default profile is configured for '$app'."
    fi

    install -d -o root -g root -m 0755 "$RUN_DIR"
    case "$vpn_type:${TRANSPORT_TYPE:-direct}" in
        inherit:*) : >"$endpoints_file" ;;
        openvpn:stunnel|openvpn:cloak)
            resolve_transport_endpoint "$app" "$endpoints_file" "${upstream_ns:-host}"
            ;;
        *) resolve_profile_endpoints "$profile" "$endpoints_file" "${upstream_ns:-host}" ;;
    esac
    chmod 0600 "$endpoints_file"

    if [[ "$via_app" == host ]]; then
        {
            printf 'UPLINK_MODE_RUNTIME=%q\n' host
            printf 'WAN_IFACE_RUNTIME=%q\n' "$wan"
            printf 'UPSTREAM_APP_RUNTIME=%q\n' ""
            printf 'VPN_TYPE_RUNTIME=%q\n' "$vpn_type"
            printf 'TUNNEL_IFACE_RUNTIME=%q\n' "$tunnel_iface"
        } >"$runtime"
    else
        {
            printf 'UPLINK_MODE_RUNTIME=%q\n' app
            printf 'WAN_IFACE_RUNTIME=%q\n' ""
            printf 'UPSTREAM_APP_RUNTIME=%q\n' "$via_app"
            printf 'UPSTREAM_NS_RUNTIME=%q\n' "$upstream_ns"
            printf 'UPSTREAM_TUN_RUNTIME=%q\n' "$upstream_tun"
            printf 'VPN_TYPE_RUNTIME=%q\n' "$vpn_type"
            printf 'TUNNEL_IFACE_RUNTIME=%q\n' "$tunnel_iface"
        } >"$runtime"
    fi
    chmod 0600 "$runtime"

    ip netns add "$NS_NAME"
    ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
    ip link set "$VETH_NS" netns "$NS_NAME"

    if [[ "$via_app" == host ]]; then
        ip addr add "$HOST_ADDR" dev "$VETH_HOST"
        ip link set "$VETH_HOST" up
    else
        ip link set "$VETH_HOST" netns "$upstream_ns"
        ip -n "$upstream_ns" addr add "$HOST_ADDR" dev "$VETH_HOST"
        ip -n "$upstream_ns" link set "$VETH_HOST" up
    fi

    ip -n "$NS_NAME" link set lo up
    ip -n "$NS_NAME" addr add "$NS_ADDR" dev "$VETH_NS"
    ip -n "$NS_NAME" link set "$VETH_NS" up
    ip -n "$NS_NAME" route add default via "$host_ip" dev "$VETH_NS"

    # Pin the VPN control endpoint to the namespace uplink so it never follows
    # the inner tunnel it is creating. In chained mode, that uplink is the
    # verified upstream VPN.
    local endpoint_ip endpoint_port endpoint_proto
    while IFS='|' read -r endpoint_ip endpoint_port endpoint_proto; do
        ip -n "$NS_NAME" route replace "$endpoint_ip/32" \
            via "$host_ip" dev "$VETH_NS"
    done <"$endpoints_file"

    install -d -o root -g root -m 0755 "/etc/netns/$NS_NAME"
    : >"/etc/netns/$NS_NAME/resolv.conf"
    local dns dns_list=()
    IFS=' ' read -r -a dns_list <<<"$DNS_SERVERS"
    for dns in "${dns_list[@]}"; do
        [[ -n "$dns" ]] && printf 'nameserver %s\n' "$dns" >>"/etc/netns/$NS_NAME/resolv.conf"
    done
    printf 'options timeout:2 attempts:2 rotate\n' >>"/etc/netns/$NS_NAME/resolv.conf"
    chmod 0644 "/etc/netns/$NS_NAME/resolv.conf"

    if [[ "$via_app" == host ]]; then
        sysctl -q -w net.ipv4.ip_forward=1
        host_rules_up "$wan"
    else
        upstream_rules_up "$upstream_ns" "$upstream_tun"
    fi

    if bool_on "$DISABLE_IPV6"; then
        ip netns exec "$NS_NAME" sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 || true
        ip netns exec "$NS_NAME" sysctl -q -w net.ipv6.conf.default.disable_ipv6=1 || true
    fi

    # Before the inner tunnel is ready, permit only its exact control endpoint
    # and DNS requests issued by the root-owned VPN setup. Application traffic
    # remains blocked by the kill switch.
    ip netns exec "$NS_NAME" iptables -w 5 -F
    ip netns exec "$NS_NAME" iptables -w 5 -X
    ip netns exec "$NS_NAME" iptables -w 5 -P INPUT DROP
    ip netns exec "$NS_NAME" iptables -w 5 -P FORWARD DROP

    if bool_on "$KILLSWITCH"; then
        ip netns exec "$NS_NAME" iptables -w 5 -P OUTPUT DROP
    else
        ip netns exec "$NS_NAME" iptables -w 5 -P OUTPUT ACCEPT
    fi

    ip netns exec "$NS_NAME" iptables -w 5 -A INPUT -i lo -j ACCEPT
    ip netns exec "$NS_NAME" iptables -w 5 -A OUTPUT -o lo -j ACCEPT
    ip netns exec "$NS_NAME" iptables -w 5 -A INPUT \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip netns exec "$NS_NAME" iptables -w 5 -A OUTPUT \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    if bool_on "$KILLSWITCH"; then
        while IFS='|' read -r endpoint_ip endpoint_port endpoint_proto; do
            ip netns exec "$NS_NAME" iptables -w 5 -A OUTPUT \
                -o "$VETH_NS" -d "$endpoint_ip" \
                -p "$endpoint_proto" --dport "$endpoint_port" -j ACCEPT
        done <"$endpoints_file"

        local dns_server
        local -a dns_servers=()
        IFS=' ' read -r -a dns_servers <<<"$DNS_SERVERS"
        for dns_server in "${dns_servers[@]}"; do
            [[ -n "$dns_server" ]] || continue
            ip netns exec "$NS_NAME" iptables -w 5 -A OUTPUT \
                -o "$VETH_NS" -d "$dns_server" -p udp --dport 53 \
                -m owner --uid-owner 0 -j ACCEPT
            ip netns exec "$NS_NAME" iptables -w 5 -A OUTPUT \
                -o "$VETH_NS" -d "$dns_server" -p tcp --dport 53 \
                -m owner --uid-owner 0 -j ACCEPT
        done

        ip netns exec "$NS_NAME" iptables -w 5 -A OUTPUT -o "$tunnel_iface" -j ACCEPT
    fi

    if [[ "$via_app" == host ]]; then
        log "Namespace '$NS_NAME' is ready on $NS_CIDR via host/$wan."
    else
        log "Namespace '$NS_NAME' is ready on $NS_CIDR via $via_app/$upstream_tun."
    fi
    log "VPN backend: $(vpn_type_label "$vpn_type"); tunnel interface: $tunnel_iface"
    while IFS='|' read -r endpoint_ip endpoint_port endpoint_proto; do
        log "VPN endpoint: $endpoint_ip:$endpoint_port/$endpoint_proto via $VETH_NS"
    done <"$endpoints_file"
}

netns_down() {
    require_root
    local app=$1
    validate_app_name "$app"
    load_cfg "$app"

    local runtime mode="" wan="" upstream_app="" upstream_ns="" upstream_tun="" pids
    runtime="$RUN_DIR/${app}.env"
    if [[ -f "$runtime" ]]; then
        mode=$(runtime_read_value "$runtime" UPLINK_MODE_RUNTIME 2>/dev/null || true)
        wan=$(runtime_read_value "$runtime" WAN_IFACE_RUNTIME 2>/dev/null || true)
        upstream_app=$(runtime_read_value "$runtime" UPSTREAM_APP_RUNTIME 2>/dev/null || true)
        upstream_ns=$(runtime_read_value "$runtime" UPSTREAM_NS_RUNTIME 2>/dev/null || true)
        upstream_tun=$(runtime_read_value "$runtime" UPSTREAM_TUN_RUNTIME 2>/dev/null || true)
    fi

    if [[ -z "$mode" ]]; then
        upstream_app=$(effective_via_runtime "$app" 2>/dev/null || printf 'host')
        if [[ "$upstream_app" == host ]]; then
            mode=host
            wan=$(detect_wan_iface "$WAN_IFACE" 2>/dev/null || true)
        else
            mode=app
            upstream_ns=$(cfg_read_value "$upstream_app" NS_NAME 2>/dev/null || true)
            local data
            data=$(upstream_tunnel_iface "$upstream_app" 2>/dev/null || true)
            [[ -z "$data" ]] || IFS='|' read -r upstream_ns upstream_tun <<<"$data"
        fi
    fi

    pids=$(ip netns pids "$NS_NAME" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        sleep 1
        pids=$(ip netns pids "$NS_NAME" 2>/dev/null || true)
        [[ -z "$pids" ]] || kill -9 $pids 2>/dev/null || true
    fi

    if [[ "$mode" == app ]]; then
        if [[ -n "$upstream_ns" ]] && ip netns list | awk '{print $1}' | grep -Fxq "$upstream_ns"; then
            [[ -z "$upstream_tun" ]] || upstream_rules_down "$upstream_ns" "$upstream_tun"
            ip -n "$upstream_ns" link del "$VETH_HOST" 2>/dev/null || true
        fi
    else
        [[ -z "$wan" ]] || host_rules_down "$wan"
    fi

    ip netns del "$NS_NAME" 2>/dev/null || true
    delete_veth_everywhere "$VETH_HOST"
    rm -rf "/etc/netns/$NS_NAME"
    rm -f \
        "$runtime" \
        "$RUN_DIR/${app}.via" \
        "$RUN_DIR/${app}.profile" \
        "$RUN_DIR/${app}.type" \
        "$RUN_DIR/${app}.endpoints" \
        "$(wireguard_runtime_config_path "$app")"
    log "Namespace '$NS_NAME' stopped."
}

