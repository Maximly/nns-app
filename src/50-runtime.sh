# nns-app source module: OpenVPN/WireGuard runtime and app lifecycle.
openvpn_exec() {
    local app=$1 profile=$2
    load_cfg "$app"

    local args=(
        /usr/sbin/openvpn
        --config "$profile"
        --dns-updown disable
    )
    if bool_on "$DISABLE_DCO"; then
        args+=(--disable-dco)
    fi

    exec /usr/sbin/ip netns exec "$NS_NAME" "${args[@]}"
}

wireguard_exec() {
    local app=$1 profile=$2 runtime_config iface wg_quick
    load_cfg "$app"

    iface=$(wireguard_iface_name "$app")
    runtime_config=$(wireguard_runtime_config_path "$app")
    wg_quick=$(command -v wg-quick)
    [[ -x "$wg_quick" ]] || die "wg-quick is not installed."

    prepare_wireguard_runtime_config \
        "$profile" "$runtime_config" "${DISABLE_IPV6:-on}"

    wireguard_cleanup() {
        if ip netns list 2>/dev/null | awk '{print $1}' | grep -Fxq "$NS_NAME"; then
            ip netns exec "$NS_NAME" "$wg_quick" down "$runtime_config" \
                >/dev/null 2>&1 || ip -n "$NS_NAME" link del "$iface" 2>/dev/null || true
        fi
        rm -f "$runtime_config"
    }

    trap 'exit 0' TERM INT HUP
    trap wireguard_cleanup EXIT

    ip netns exec "$NS_NAME" "$wg_quick" up "$runtime_config"
    log "WireGuard interface '$iface' is active in '$NS_NAME'."

    # Keep the service process alive after wg-quick configures the interface.
    # This lets the backend-neutral compatibility unit own WireGuard teardown
    # in the same way it owns a long-running OpenVPN process.
    while :; do
        sleep 3600 &
        wait $! || true
    done
}

vpn_exec() {
    require_root
    local app=$1 type profile
    validate_app_name "$app"
    load_cfg "$app"

    [[ -n "$DEFAULT_PROFILE" ]] || die "No default profile is configured for '$app'."
    profile="$(profiles_dir "$app")/$DEFAULT_PROFILE"
    [[ -f "$profile" ]] || die "Default profile does not exist: $profile"
    ip netns list | awk '{print $1}' | grep -Fxq "$NS_NAME" ||
        die "Namespace '$NS_NAME' is not running."

    type=$(vpn_type_for_app "$app" 2>/dev/null || true)
    [[ -n "$type" ]] || die "Cannot determine VPN backend for '$app'."

    install -d -o root -g root -m 0755 "$RUN_DIR"
    printf '%s\n' "$DEFAULT_PROFILE" >"$RUN_DIR/${app}.profile"
    printf '%s\n' "$type" >"$RUN_DIR/${app}.type"
    chmod 0644 "$RUN_DIR/${app}.profile" "$RUN_DIR/${app}.type"

    case "$type" in
        openvpn) openvpn_exec "$app" "$profile" ;;
        wireguard) wireguard_exec "$app" "$profile" ;;
        *) die "Unsupported VPN backend '$type'." ;;
    esac
}


app_is_started() {
    systemctl is-active --quiet "nns-openvpn@${1}.service" &&
    systemctl is-active --quiet "nns-netns@${1}.service"
}

wait_online() {
    local app=$1 timeout=$2 deadline
    load_cfg "$app"

    deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if vpn_route_ready "$app"; then
            # A tunnel interface and route are not enough: verify that packets
            # actually traverse the VPN. Keep each probe short so a five-second
            # readiness deadline remains a real five-second deadline.
            if ip netns exec "$NS_NAME" ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1 ||
               ip netns exec "$NS_NAME" curl -4fsS \
                   --connect-timeout 1 --max-time 1 \
                   http://1.1.1.1/cdn-cgi/trace >/dev/null 2>&1; then
                return 0
            fi
        fi
        sleep 0.2
    done
    return 1
}

start_app() {
    require_root
    local app=$1
    local ignore_start_error=${2:-off}
    local via_override=${3:-__default__}
    validate_app_name "$app"
    load_cfg "$app"
    [[ -n "$DEFAULT_PROFILE" ]] || die "No profile configured. Use: nns-app add $app profile.ovpn|wireguard.conf"
    [[ -f "$(profiles_dir "$app")/$DEFAULT_PROFILE" ]] ||
        die "Configured profile '$DEFAULT_PROFILE' is missing."
    local vpn_type
    vpn_type=$(vpn_type_for_app "$app" 2>/dev/null || true)
    [[ -n "$vpn_type" ]] || die "Cannot determine VPN backend for '$app'. Re-add its profile."

    local desired_via current_via="host"
    desired_via=$(effective_via_for_app "$app" "$via_override")
    if [[ "$desired_via" != host ]]; then
        ensure_upstream_ready "$app" "$desired_via" >/dev/null
    fi

    local current=""
    [[ -f "$RUN_DIR/${app}.profile" ]] && current=$(<"$RUN_DIR/${app}.profile")
    if app_is_started "$app"; then
        current_via=$(runtime_via_for_app "$app")
    fi
    if app_is_started "$app" && [[ "$current" == "$DEFAULT_PROFILE" && "$current_via" == "$desired_via" ]]; then
        log "'$app' is already started with '$DEFAULT_PROFILE' via $desired_via."
        return 0
    fi

    if app_is_started "$app" || systemctl is-active --quiet "nns-netns@${app}.service"; then
        stop_app "$app"
        # Recursive dependent shutdown loads other app configs into this shell.
        # Reload the original app before continuing its restart sequence.
        load_cfg "$app"
    fi

    install -d -o root -g root -m 0755 "$RUN_DIR"
    printf '%s\n' "$desired_via" >"$RUN_DIR/${app}.via"
    chmod 0600 "$RUN_DIR/${app}.via"

    if bool_on "$AUTOSTART"; then
        if [[ "$via_override" != __default__ ]]; then
            warn "A one-start --via override is not persistent across boot; set UPSTREAM_APP in $(cfg_file "$app")."
        fi
        systemctl enable \
            "nns-netns@${app}.service" \
            "nns-openvpn@${app}.service" \
            "nns-online@${app}.service" >/dev/null
    else
        systemctl disable \
            "nns-netns@${app}.service" \
            "nns-openvpn@${app}.service" \
            "nns-online@${app}.service" \
            >/dev/null 2>&1 || true
    fi

    if ! systemctl start "nns-netns@${app}.service"; then
        warn "Failed to create the network namespace for '$app'."
        warn "Recent namespace-service log:"
        journalctl -u "nns-netns@${app}.service" -n 60 \
            -o cat --no-pager >&2 2>/dev/null || true
        netns_down "$app" >/dev/null 2>&1 || true
        systemctl reset-failed "nns-netns@${app}.service" 2>/dev/null || true
        return 1
    fi

    if ! systemctl start "nns-openvpn@${app}.service"; then
        warn "Failed to start the VPN backend for '$app'."
        warn "Recent VPN-service log:"
        journalctl -u "nns-openvpn@${app}.service" -n 40 \
            -o cat --no-pager >&2 2>/dev/null || true
        stop_app "$app"
        return 1
    fi

    local timeout
    if bool_on "$ignore_start_error"; then
        timeout=1
    else
        timeout=${READY_TIMEOUT:-5}
        [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || timeout=5
    fi

    if wait_online "$app" "$timeout"; then
        local ext
        ext=$(ip netns exec "$NS_NAME" curl -4fsS \
              --connect-timeout 1 --max-time 1 \
              "$EXTERNAL_IP_URL" 2>/dev/null || true)
        log "Started '$app' with '$DEFAULT_PROFILE' ($(vpn_type_label "$vpn_type")) via $desired_via.${ext:+ External IP: $ext}"
        return 0
    fi

    if bool_on "$ignore_start_error"; then
        warn "'$app' is not online yet; -i ignored the readiness error."
        warn "The namespace and VPN service were left running via $desired_via."
        warn "Check later with: nns-app list"
        return 0
    fi

    warn "'$app' failed: the VPN data path was not online within ${timeout}s."
    warn "Stopping the failed VPN instance instead of leaving it reconnecting."
    warn "Recent VPN backend log:"
    journalctl -u "nns-openvpn@${app}.service" -n 20 \
        -o cat --no-pager >&2 2>/dev/null || true
    stop_app "$app"
    return 1
}

stop_dependents() {
    local upstream=$1 env child parent
    shopt -s nullglob
    for env in "$RUN_DIR"/*.env; do
        child=$(basename "$env" .env)
        [[ "$child" != "$upstream" ]] || continue
        parent=$(runtime_read_value "$env" UPSTREAM_APP_RUNTIME 2>/dev/null || true)
        [[ "$parent" == "$upstream" ]] || continue

        if systemctl is-active --quiet "nns-netns@${child}.service" ||
           systemctl is-active --quiet "nns-openvpn@${child}.service"; then
            warn "Stopping dependent app '$child' before upstream '$upstream'."
            stop_app_internal "$child"
        fi
    done
}

stop_app_internal() {
    local app=$1
    validate_app_name "$app"
    [[ -z "${STOP_VISITED[$app]-}" ]] || return 0
    STOP_VISITED[$app]=1
    load_cfg "$app"

    stop_gateways_via_app "$app"
    stop_dependents "$app"
    systemctl stop "nns-online@${app}.service" 2>/dev/null || true
    systemctl stop "nns-openvpn@${app}.service" 2>/dev/null || true
    systemctl stop "nns-netns@${app}.service" 2>/dev/null || true
    systemctl reset-failed \
        "nns-online@${app}.service" \
        "nns-openvpn@${app}.service" \
        "nns-netns@${app}.service" 2>/dev/null || true

    rm -f \
        "$RUN_DIR/${app}.profile" \
        "$RUN_DIR/${app}.type" \
        "$RUN_DIR/${app}.via" \
        "$(wireguard_runtime_config_path "$app")"
    log "Stopped '$app'."
}

stop_app() {
    require_root
    declare -gA STOP_VISITED=()
    stop_app_internal "$1"
    unset STOP_VISITED
}

apps_using_upstream() {
    local upstream=$1 dir app parent
    shopt -s nullglob
    for dir in "$BASE_DIR"/*; do
        [[ -d "$dir" ]] || continue
        app=$(basename "$dir")
        [[ -f "$(cfg_file "$app")" ]] || continue
        parent=$(cfg_read_value "$app" UPSTREAM_APP 2>/dev/null || true)
        [[ "$parent" == "$upstream" ]] && printf '%s\n' "$app"
    done
}

remove_app() {
    require_root
    local app=$1 gateway_dependencies app_dependencies
    validate_app_name "$app"
    load_cfg "$app"

    gateway_dependencies=$(gateways_using_app "$app" | paste -sd ', ' -)
    app_dependencies=$(apps_using_upstream "$app" | paste -sd ', ' -)
    [[ -z "$gateway_dependencies" ]] ||
        die "App '$app' is used by gateway(s): $gateway_dependencies. Reconfigure them first."
    [[ -z "$app_dependencies" ]] ||
        die "App '$app' is the configured upstream for: $app_dependencies. Reconfigure those apps first."

    stop_app "$app"
    load_cfg "$app"
    systemctl disable \
        "nns-online@${app}.service" \
        "nns-openvpn@${app}.service" \
        "nns-netns@${app}.service" >/dev/null 2>&1 || true

    rm -f "/etc/sudoers.d/nns-app-${app}"
    rm -rf "$(app_dropin_dir "$app")" "$(cfg_dir "$app")" "/etc/netns/$NS_NAME"
    rm -f \
        "$RUN_DIR/${app}.env" \
        "$RUN_DIR/${app}.profile" \
        "$RUN_DIR/${app}.type" \
        "$RUN_DIR/${app}.via" \
        "$(wireguard_runtime_config_path "$app")"
    systemctl daemon-reload
    log "Removed NNS app '$app'."
}

purge_engine() {
    require_root

    local dir app ns pids
    local -a apps=()
    shopt -s nullglob

    # Record installed apps before deleting any configuration. Their unit
    # ExecStop handlers and netns_down() need the per-app config to remove
    # namespace interfaces, NAT and forwarding rules safely.
    for dir in "$BASE_DIR"/*; do
        [[ -d "$dir" ]] || continue
        app=$(basename "$dir")
        [[ -f "$(cfg_file "$app")" ]] || continue
        apps+=("$app")
    done

    # Stop gateways before removing the NNS exits that carry their data path.
    local gateway_dir gateway
    shopt -s nullglob
    for gateway_dir in "$GATEWAY_BASE_DIR"/*; do
        [[ -f "$gateway_dir/gateway.cfg" ]] || continue
        gateway=$(basename "$gateway_dir")
        systemctl stop "nns-gateway@${gateway}.service" 2>/dev/null || true
        ( gateway_down "$gateway" ) >/dev/null 2>&1 || true
        systemctl disable --now \
            "nns-gateway@${gateway}.service" \
            "nns-gateway-crl-refresh@${gateway}.timer" \
            >/dev/null 2>&1 || true
    done

    # Stop VPN processes first, then namespaces. Do this app by app so that
    # systemd invokes the normal cleanup path while the engine and configs
    # still exist.
    for app in "${apps[@]}"; do
        systemctl stop "nns-online@${app}.service" 2>/dev/null || true
        systemctl stop "nns-openvpn@${app}.service" 2>/dev/null || true
    done
    for app in "${apps[@]}"; do
        systemctl stop "nns-netns@${app}.service" 2>/dev/null || true

        # Clean a namespace left behind by a failed/inactive unit. Run in a
        # subshell because a damaged app config must not prevent global purge.
        if ip netns list 2>/dev/null | awk '{print $1}' | grep -Fxq "nns-$app"; then
            ( netns_down "$app" ) || warn "Could not fully clean namespace for '$app'; continuing purge."
        fi

        systemctl disable \
            "nns-openvpn@${app}.service" \
            "nns-netns@${app}.service" \
            >/dev/null 2>&1 || true
    done

    # Remove any orphan NNS namespaces that no longer have a readable config.
    while IFS= read -r ns; do
        [[ "$ns" == nns-* ]] || continue
        pids=$(ip netns pids "$ns" 2>/dev/null || true)
        if [[ -n "$pids" ]]; then
            kill $pids 2>/dev/null || true
            sleep 1
            pids=$(ip netns pids "$ns" 2>/dev/null || true)
            [[ -z "$pids" ]] || kill -9 $pids 2>/dev/null || true
        fi
        ip netns del "$ns" 2>/dev/null || true
    done < <(ip netns list 2>/dev/null | awk '{print $1}')

    # Remove all files installed by this engine. Do not remove dependency
    # packages (openvpn, wireguard-tools, iproute2, iptables, curl, sudo, etc.).
    rm -rf -- "$BASE_DIR" "$RUN_DIR"

    if [[ -d /etc/netns ]]; then
        find /etc/netns -mindepth 1 -maxdepth 1 \
            -type d -name 'nns-*' -exec rm -rf -- {} +
    fi

    find /etc/sudoers.d -maxdepth 1 -type f -name 'nns-app-*' -delete 2>/dev/null || true

    # Remove enabled-instance symlinks before deleting the templates.
    find /etc/systemd/system -type l \
        \( -name 'nns-openvpn@*.service' \
           -o -name 'nns-netns@*.service' \
           -o -name 'nns-online@*.service' \
           -o -name 'nns-gateway@*.service' \
           -o -name 'nns-gateway-crl-refresh@*.service' \
           -o -name 'nns-gateway-crl-refresh@*.timer' \) \
        -delete 2>/dev/null || true

    find /etc/systemd/system -maxdepth 1 -type d \
        \( -name 'nns-netns@*.service.d' \
           -o -name 'nns-online@*.service.d' \
           -o -name 'nns-gateway@*.service.d' \) \
        -exec rm -rf {} + 2>/dev/null || true

    rm -rf -- \
        /etc/systemd/system/nns-openvpn@.service.d \
        /etc/systemd/system/nns-netns@.service.d \
        /etc/systemd/system/nns-online@.service.d \
        /etc/systemd/system/nns-gateway@.service.d
    rm -f -- \
        "$VPN_UNIT" "$NETNS_UNIT" "$ONLINE_UNIT" "$GATEWAY_UNIT" \
        "$GATEWAY_CRL_SERVICE" "$GATEWAY_CRL_TIMER"

    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    rm -f -- "$USER_PATH"
    rm -f -- "$ENGINE_PATH"

    log "Purged NNS app engine and all installed NNS apps."
    log "Removed: $BASE_DIR, /etc/netns/nns-*, NNS systemd units, NNS sudoers rules, $USER_PATH and $ENGINE_PATH"
}


