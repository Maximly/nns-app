# Verify substantial HTTPS transfers through a full-tunnel OpenVPN namespace.
# Only change the interface MTU if a previously failing transfer recovers at
# the new size. IP reachability alone is not proof that TCP/TLS works.

mtu_probe_state() {
    local app=$1 state=$2
    [[ -n "${RUN_DIR:-}" ]] || return 0
    install -d -o root -g root -m 0755 "$RUN_DIR" 2>/dev/null || return 0
    printf '%s\n' "$state" >"$RUN_DIR/${app}.mtu-check" 2>/dev/null || true
}

# Returns: 0 = transfer completed, 10 = stalled after TLS was sent,
#          20 = target unavailable / DNS / TCP connect / certificate error.
# Always check the full response. A successful TCP connect or 204 response
# cannot establish that the path carries packets of normal application size.
mtu_https_probe() {
    local ns=$1 url=$2 capture rc=0 metrics tcp tls bytes http_code
    local min_bytes=7
    [[ "$url" == *'/__down?bytes=32768' ]] && min_bytes=32768
    if capture=$(ip netns exec "$ns" curl -4 -v -f -sS \
            --noproxy '*' --connect-timeout 4 --max-time 6 \
            -o /dev/null \
            --write-out $'\nNNS_MTU_METRICS:%{time_connect}|%{time_appconnect}|%{size_download}|%{http_code}\n' \
            "$url" 2>&1); then
        rc=0
    else
        rc=$?
    fi

    if (( rc == 0 )); then
        [[ "$capture" == *'NNS_MTU_METRICS:'* ]] || return 20
        metrics=${capture##*NNS_MTU_METRICS:}
        metrics=${metrics%%$'\n'*}
        local IFS='|'
        read -r tcp tls bytes http_code <<< "$metrics"
        # Require the expected response length, not merely a successful TLS
        # handshake. The diagnostic download is a fixed 32-KiB payload.
        [[ "$bytes" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 20
        awk -v got="$bytes" -v minimum="$min_bytes" \
            'BEGIN { exit !(got >= minimum) }' || return 20
        return 0
    fi

    # Recent curl versions can reset time_connect to zero when a TLS
    # handshake times out. Its verbose ClientHello log still proves TCP
    # connected and that TLS traffic was sent. DNS/TCP/certificate errors
    # must not be misclassified as path-MTU failures.
    if (( rc == 28 || rc == 18 )) &&
       [[ "$capture" == *'TLS handshake, Client hello'* ]]; then
        return 10
    fi
    return 20
}

# An MTU selected by a successful earlier probe is a runtime requirement,
# even if OpenVPN was already active when the value was saved. OpenVPN may
# also recreate its TUN interface after an internal reconnect; the watchdog
# reconciles that interface without restarting the user's processes.
mtu_apply_saved() {
    local app=$1 type dev actual previous
    [[ "${TUN_MTU:-}" =~ ^[0-9]+$ ]] || return 0
    (( TUN_MTU >= 576 && TUN_MTU <= 1500 )) || {
        warn "'$app': ignoring invalid saved TUN_MTU '$TUN_MTU'."
        return 1
    }
    type=$(vpn_type_for_app "$app" 2>/dev/null || true)
    [[ "$type" == openvpn ]] || return 0
    dev=$(vpn_route_iface "$app" 2>/dev/null || true)
    [[ "$dev" == tun* ]] || return 0
    actual=$(ip -n "$NS_NAME" -o link show dev "$dev" 2>/dev/null |
        awk '{for (i=1;i<=NF;i++) if ($i=="mtu") {print $(i+1); exit}}')
    [[ "$actual" =~ ^[0-9]+$ ]] || return 0
    [[ "$actual" != "$TUN_MTU" ]] || return 0
    previous=$actual
    if ! ip -n "$NS_NAME" link set dev "$dev" mtu "$TUN_MTU"; then
        warn "'$app': failed to apply saved MTU $TUN_MTU to $dev."
        return 1
    fi
    actual=$(ip -n "$NS_NAME" -o link show dev "$dev" 2>/dev/null |
        awk '{for (i=1;i<=NF;i++) if ($i=="mtu") {print $(i+1); exit}}')
    if [[ "$actual" != "$TUN_MTU" ]]; then
        warn "'$app': saved MTU $TUN_MTU did not take effect on $dev (actual ${actual:-unknown})."
        return 1
    fi
    mtu_probe_state "$app" "restored:MTU=$TUN_MTU:previous=$previous"
    log "'$app': applied saved MTU $TUN_MTU to $dev."
}

mtu_auto_repair() {
    local app=$1 kind ns dev original candidate result url
    local deadline suspect=0 unavailable=0 good
    local -a urls=(
        'https://speed.cloudflare.com/__down?bytes=32768'
        'https://api.ipify.org/'
    )
    local -a failed_urls=() healthy_urls=()

    load_cfg "$app"
    mtu_apply_saved "$app" || true
    [[ "${AUTO_MTU:-on}" != off ]] || { mtu_probe_state "$app" disabled; return 0; }
    kind=$(vpn_type_for_app "$app" 2>/dev/null || true)
    [[ "$kind" == openvpn ]] || return 0
    app_split_tunnel "$app" && { mtu_probe_state "$app" split-tunnel-skipped; return 0; }
    ns=$NS_NAME
    dev=$(vpn_route_iface "$app" 2>/dev/null || true)
    [[ "$dev" == tun* ]] || return 0
    original=$(ip -n "$ns" -o link show dev "$dev" 2>/dev/null |
        awk '{for (i=1;i<=NF;i++) if ($i=="mtu") {print $(i+1); exit}}')
    [[ "$original" =~ ^[0-9]+$ ]] || return 0

    # End-to-end budget includes baseline probes. Avoid holding the startup
    # service indefinitely when the connection is broken.
    deadline=$((SECONDS + 38))
    for url in "${urls[@]}"; do
        if mtu_https_probe "$ns" "$url"; then
            healthy_urls+=("$url")
            continue
        else
            result=$?
        fi
        if (( result == 10 )); then
            failed_urls+=("$url")
            suspect=$((suspect + 1))
        else
            unavailable=$((unavailable + 1))
        fi
    done

    if (( suspect == 0 )); then
        if (( unavailable == 0 )); then
            mtu_probe_state "$app" "healthy:MTU=$original"
        else
            mtu_probe_state "$app" "inconclusive:unavailable=$unavailable:MTU=$original"
            warn "'$app': an HTTPS probe was unavailable; MTU remains $original (no size-related stall detected)."
        fi
        return 0
    fi
    # A DNS/TCP failure at one optional target must not mask a genuine TLS
    # stall at another. Only the stalled target can authorize a saved MTU,
    # after it recovers at the new setting on two independent connections.
    if (( unavailable != 0 )); then
        warn "'$app': $unavailable HTTPS target(s) unavailable; checking MTU only against the $suspect confirmed TLS stall(s)."
    fi
    warn "'$app': $suspect HTTPS transfer(s) stalled after TCP/TLS; testing smaller $dev MTUs."
    for candidate in 1400 1360 1320 1280 1200; do
        (( SECONDS < deadline )) || break
        (( candidate < original )) || continue
        if ! ip -n "$ns" link set dev "$dev" mtu "$candidate"; then
            warn "'$app': could not set $dev MTU $candidate."
            break
        fi
        good=on
        # Every previously failed target must recover. A different working
        # URL is not evidence that the original failure is fixed.
        for url in "${failed_urls[@]}"; do
            (( SECONDS < deadline )) || { good=off; break; }
            if ! mtu_https_probe "$ns" "$url"; then good=off; break; fi
        done
        if [[ "$good" == on ]]; then
            # Retest all targets known to have worked or stalled. Ignore
            # independent DNS/TCP failures unrelated to packet size.
            for url in "${healthy_urls[@]}" "${failed_urls[@]}"; do
                (( SECONDS < deadline )) || { good=off; break; }
                if ! mtu_https_probe "$ns" "$url"; then good=off; break; fi
            done
        fi
        if [[ "$good" == on ]]; then
            if cfg_set "$app" TUN_MTU "$candidate"; then
                mtu_probe_state "$app" "recovered:MTU=$candidate:previous=$original"
                log "'$app': HTTPS recovered at $dev MTU $candidate (previous $original); saved for OpenVPN reconnects."
                return 0
            fi
            warn "'$app': could not persist the working MTU; restoring $original."
            break
        fi
    done
    ip -n "$ns" link set dev "$dev" mtu "$original" 2>/dev/null || true
    mtu_probe_state "$app" "unresolved:MTU=$original"
    warn "'$app': HTTPS did not reliably recover with reduced MTU; keeping $original."
    return 0
}
