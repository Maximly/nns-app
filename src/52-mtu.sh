# Conditional HTTPS/MTU validation for OpenVPN namespace clients.
# The small IP probe in wait_online() verifies basic routing, not TLS-sized
# packets. Only attempt an MTU reduction after both independent HTTPS probes
# establish TCP but fail to complete TLS.

mtu_https_probe() {
    local ns=$1 url=$2 metrics rc=0 connected tls_done
    if metrics=$(ip netns exec "$ns" curl -4 -sS -o /dev/null \
            --noproxy '*' --connect-timeout 3 --max-time 7 \
            --write-out '%{time_connect} %{time_appconnect}' \
            "$url" 2>/dev/null); then
        return 0
    else
        rc=$?
    fi
    # A completed TLS handshake also counts when the HTTP endpoint later
    # declines the request. Never mistake DNS/TCP/certificate failure for PMTU.
    local IFS=' '
    read -r connected tls_done <<<"$metrics"
    if [[ -n "$tls_done" ]] &&
       awk -v t="$tls_done" 'BEGIN { exit !(t > 0) }'; then
        return 0
    fi
    if [[ -n "$connected" ]] &&
       awk -v t="$connected" 'BEGIN { exit !(t > 0) }' &&
       [[ "$rc" == 28 || "$rc" == 35 || "$rc" == 56 ]]; then
        return 10
    fi
    return 20
}

mtu_auto_repair() {
    local app=$1 kind ns dev original candidate result url good suspect=0
    local deadline
    local -a urls=(
        'https://www.cloudflare.com/cdn-cgi/trace'
        'https://www.google.com/generate_204'
    )

    load_cfg "$app"
    [[ "${AUTO_MTU:-on}" != off ]] || return 0
    kind=$(vpn_type_for_app "$app" 2>/dev/null || true)
    [[ "$kind" == openvpn ]] || return 0
    app_split_tunnel "$app" && return 0
    ns=$NS_NAME
    dev=$(vpn_route_iface "$app" 2>/dev/null || true)
    [[ "$dev" == tun* ]] || return 0
    original=$(ip -n "$ns" -o link show dev "$dev" 2>/dev/null |
        awk '{for (i=1;i<=NF;i++) if ($i=="mtu") {print $(i+1); exit}}')
    [[ "$original" =~ ^[0-9]+$ ]] || return 0

    # Any working HTTPS target is sufficient proof that TLS-size traffic passes.
    # If a target fails DNS/TCP or certificate validation, do not touch MTU.
    for url in "${urls[@]}"; do
        if mtu_https_probe "$ns" "$url"; then
            return 0
        else
            result=$?
        fi
        [[ "$result" == 10 ]] || return 0
        suspect=$((suspect + 1))
    done
    (( suspect == ${#urls[@]} )) || return 0

    warn "'$app': IP connectivity works but HTTPS TLS is stalled; checking tunnel MTU."
    deadline=$((SECONDS + 35))
    # A known conservative starting point avoids expensive wide-range sweeps.
    # The probe is the authority: no MTU value is committed before TLS succeeds.
    for candidate in 1400 1360 1320 1280 1200; do
        (( SECONDS < deadline )) || break
        (( candidate < original )) || continue
        if ! ip -n "$ns" link set dev "$dev" mtu "$candidate"; then
            warn "'$app': could not set $dev MTU $candidate; restoring prior setting."
            break
        fi
        good=off
        for url in "${urls[@]}"; do
            (( SECONDS < deadline )) || break
            if mtu_https_probe "$ns" "$url" &&
               mtu_https_probe "$ns" "$url"; then
                good=on
                break
            fi
        done
        if [[ "$good" == on ]]; then
            if cfg_set "$app" TUN_MTU "$candidate"; then
                log "'$app': HTTPS recovered at $dev MTU $candidate (previous $original); saved for OpenVPN reconnects."
                return 0
            fi
            warn "'$app': could not persist the working MTU; restoring $original."
            break
        fi
    done
    ip -n "$ns" link set dev "$dev" mtu "$original" 2>/dev/null || true
    warn "'$app': HTTPS did not recover with reduced MTU; keeping $original."
    return 0
}
