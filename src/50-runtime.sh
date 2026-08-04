# nns-app source module: OpenVPN/WireGuard runtime and app lifecycle.
openvpn_exec() {
    local app=$1 profile=$2 openvpn_bin ip_bin
    load_cfg "$app"
    openvpn_bin=$(openvpn_binary)
    ip_bin=$(ip_binary)

    local args=(
        "$openvpn_bin"
        --config "$profile"
    )
    # OpenVPN 2.7 gained --dns-updown. Fedora 43 still ships the supported
    # OpenVPN 2.6 branch, where the option does not exist. Namespace-local
    # resolv.conf handling does not require the hook, so disable it only when
    # the installed OpenVPN advertises the option.
    if openvpn_supports_dns_updown; then
        args+=(--dns-updown disable)
    fi
    if bool_on "$DISABLE_DCO"; then
        args+=(--disable-dco)
    fi

    exec "$ip_bin" netns exec "$NS_NAME" "${args[@]}"
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
    local app=$1 type profile marker
    validate_app_name "$app"
    load_cfg "$app"

    ip netns list | awk '{print $1}' | grep -Fxq "$NS_NAME" ||
        die "Namespace '$NS_NAME' is not running."
    type=$(vpn_type_for_app "$app" 2>/dev/null || true)
    [[ -n "$type" ]] || die "Cannot determine VPN backend for '$app'."

    if [[ "$type" == inherit ]]; then
        [[ -z "$DEFAULT_PROFILE" ]] || warn "Ignoring profile '$DEFAULT_PROFILE' for inherit backend '$app'."
        marker="inherit:${UPSTREAM_APP:-host}"
    else
        [[ -n "$DEFAULT_PROFILE" ]] || die "No default profile is configured for '$app'."
        profile="$(profiles_dir "$app")/$DEFAULT_PROFILE"
        [[ -f "$profile" ]] || die "Default profile does not exist: $profile"
        marker=$DEFAULT_PROFILE
    fi

    install -d -o root -g root -m 0755 "$RUN_DIR"
    printf '%s\n' "$marker" >"$RUN_DIR/${app}.profile"
    printf '%s\n' "$type" >"$RUN_DIR/${app}.type"
    chmod 0644 "$RUN_DIR/${app}.profile" "$RUN_DIR/${app}.type"

    case "$type" in
        openvpn)
            case "${TRANSPORT_TYPE:-direct}" in
                direct|"") openvpn_exec "$app" "$profile" ;;
                stunnel|cloak|ssh) transport_client_exec "$app" "$profile" ;;
                *) die "Unsupported local transport '${TRANSPORT_TYPE}'." ;;
            esac
            ;;
        wireguard) wireguard_exec "$app" "$profile" ;;
        inherit)
            trap 'exit 0' TERM INT HUP
            while :; do sleep 3600 & wait $! || true; done
            ;;
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

watchdog_state_file() {
    printf '%s/%s.watchdog\n' "$RUN_DIR" "$1"
}

watchdog_numeric_setting() {
    local value=$1 fallback=$2 minimum=$3 maximum=$4
    if [[ "$value" =~ ^[0-9]+$ ]] &&
       (( value >= minimum && value <= maximum )); then
        printf '%s\n' "$value"
    else
        printf '%s\n' "$fallback"
    fi
}

watchdog_enabled_for_type() {
    local type=$1 mode=${WATCHDOG_MODE:-auto}
    case "${mode,,}" in
        off|no|false|0|disabled) return 1 ;;
        auto|on|yes|true|1|enabled)
            [[ "$type" == openvpn || "$type" == wireguard ]]
            ;;
        *)
            warn "Invalid WATCHDOG_MODE='$mode'; treating it as auto."
            [[ "$type" == openvpn || "$type" == wireguard ]]
            ;;
    esac
}

watchdog_state_load() {
    local app=$1 file
    file=$(watchdog_state_file "$app")
    WD_ARMED=0
    WD_FAILURES=0
    WD_LAST_RESTART=0
    WD_TOTAL_RESTARTS=0
    WD_LAST_CHECK=0
    WD_LAST_RESULT=never
    [[ -f "$file" ]] || return 0

    local key value
    while IFS='=' read -r key value; do
        case "$key" in
            ARMED) [[ "$value" == 0 || "$value" == 1 ]] && WD_ARMED=$value ;;
            FAILURES) [[ "$value" =~ ^[0-9]+$ ]] && WD_FAILURES=$value ;;
            LAST_RESTART) [[ "$value" =~ ^[0-9]+$ ]] && WD_LAST_RESTART=$value ;;
            TOTAL_RESTARTS) [[ "$value" =~ ^[0-9]+$ ]] && WD_TOTAL_RESTARTS=$value ;;
            LAST_CHECK) [[ "$value" =~ ^[0-9]+$ ]] && WD_LAST_CHECK=$value ;;
            LAST_RESULT) [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] && WD_LAST_RESULT=$value ;;
        esac
    done <"$file"
}

watchdog_state_save() {
    local app=$1 file dir tmp
    file=$(watchdog_state_file "$app")
    dir=${file%/*}
    if (( EUID == 0 )); then
        install -d -o root -g root -m 0755 "$dir"
    else
        [[ "${NNS_APP_SOURCE_ONLY:-0}" == 1 ]] ||
            die "Writing watchdog state requires root privileges."
        install -d -m 0700 "$dir"
    fi
    tmp=$(mktemp "${file}.XXXXXX")
    cat >"$tmp" <<WATCHDOG_STATE_EOF
ARMED=$WD_ARMED
FAILURES=$WD_FAILURES
LAST_RESTART=$WD_LAST_RESTART
TOTAL_RESTARTS=$WD_TOTAL_RESTARTS
LAST_CHECK=$WD_LAST_CHECK
LAST_RESULT=$WD_LAST_RESULT
WATCHDOG_STATE_EOF
    if (( EUID == 0 )); then
        install -o root -g root -m 0600 "$tmp" "$file"
    else
        install -m 0600 "$tmp" "$file"
    fi
    rm -f "$tmp"
}

watchdog_mark_online() {
    local app=$1
    watchdog_state_load "$app"
    WD_ARMED=1
    WD_FAILURES=0
    WD_LAST_CHECK=$(date +%s)
    WD_LAST_RESULT=online
    watchdog_state_save "$app"
}

watchdog_namespace_exists() {
    [[ -e "/run/netns/$NS_NAME" ]]
}

sync_watchdog_timer() {
    local app=$1 type
    validate_app_name "$app"
    load_cfg "$app"
    type=$(vpn_type_for_app "$app" 2>/dev/null || true)

    if [[ -n "$type" ]] && watchdog_enabled_for_type "$type"; then
        if bool_on "${AUTOSTART:-off}"; then
            systemctl enable "nns-watchdog@${app}.timer" >/dev/null 2>&1 || true
        else
            systemctl disable "nns-watchdog@${app}.timer" >/dev/null 2>&1 || true
        fi

        if app_is_started "$app"; then
            systemctl start "nns-watchdog@${app}.timer" >/dev/null 2>&1 ||
                warn "Could not start the data-path watchdog timer for '$app'."
        else
            systemctl stop "nns-watchdog@${app}.timer" >/dev/null 2>&1 || true
            systemctl stop "nns-watchdog@${app}.service" >/dev/null 2>&1 || true
        fi
    else
        systemctl disable --now "nns-watchdog@${app}.timer" >/dev/null 2>&1 || true
        systemctl stop "nns-watchdog@${app}.service" >/dev/null 2>&1 || true
        rm -f "$(watchdog_state_file "$app")"
    fi
}

watchdog_check() {
    require_root
    local app=$1 type via failures_limit cooldown now elapsed
    validate_app_name "$app"
    acquire_lock "watchdog-$app"
    load_cfg "$app"
    type=$(vpn_type_for_app "$app" 2>/dev/null || true)

    if [[ -z "$type" ]] || ! watchdog_enabled_for_type "$type"; then
        rm -f "$(watchdog_state_file "$app")"
        release_lock "watchdog-$app"
        return 0
    fi

    if ! app_is_started "$app" || ! watchdog_namespace_exists; then
        rm -f "$(watchdog_state_file "$app")"
        release_lock "watchdog-$app"
        return 0
    fi

    watchdog_state_load "$app"
    if (( WD_ARMED == 0 )) &&
       systemctl is-active --quiet "nns-online@${app}.service"; then
        WD_ARMED=1
    fi
    now=$(date +%s)
    failures_limit=$(watchdog_numeric_setting "${WATCHDOG_FAILURES:-3}" 3 1 20)
    cooldown=$(watchdog_numeric_setting "${WATCHDOG_COOLDOWN:-300}" 300 30 86400)
    via=$(runtime_via_for_app "$app" 2>/dev/null || printf 'host')

    # Do not restart a child tunnel while its upstream is unavailable. The
    # upstream's own watchdog should recover first; the child is checked again
    # on the next timer tick.
    if [[ "$via" != host ]] &&
       { ! app_is_started "$via" || ! wait_online "$via" 2; }; then
        WD_FAILURES=0
        WD_LAST_CHECK=$now
        WD_LAST_RESULT=deferred-upstream
        watchdog_state_save "$app"
        release_lock "watchdog-$app"
        return 0
    fi

    if wait_online "$app" 4; then
        WD_ARMED=1
        WD_FAILURES=0
        WD_LAST_CHECK=$now
        WD_LAST_RESULT=online
        watchdog_state_save "$app"
        release_lock "watchdog-$app"
        return 0
    fi

    if (( WD_ARMED == 0 )); then
        WD_FAILURES=0
        WD_LAST_CHECK=$now
        WD_LAST_RESULT=waiting-initial-online
        watchdog_state_save "$app"
        release_lock "watchdog-$app"
        return 0
    fi

    WD_FAILURES=$((WD_FAILURES + 1))
    WD_LAST_CHECK=$now
    WD_LAST_RESULT=offline
    if (( WD_FAILURES < failures_limit )); then
        watchdog_state_save "$app"
        warn "Watchdog probe for '$app' failed ($WD_FAILURES/$failures_limit); waiting before recovery."
        release_lock "watchdog-$app"
        return 0
    fi

    elapsed=$((now - WD_LAST_RESTART))
    if (( WD_LAST_RESTART > 0 && elapsed < cooldown )); then
        WD_LAST_RESULT=cooldown
        watchdog_state_save "$app"
        warn "Watchdog for '$app' confirmed an offline data path, but restart cooldown is active for $((cooldown - elapsed))s."
        release_lock "watchdog-$app"
        return 0
    fi

    # Restart only the VPN backend. The application network namespace and all
    # processes already running inside it remain alive and should regain the
    # data path when the backend reconnects.
    warn "Watchdog confirmed '$app' offline after $WD_FAILURES consecutive probes; restarting its $type backend."
    systemctl stop "nns-online@${app}.service" >/dev/null 2>&1 || true
    WD_LAST_RESTART=$now
    WD_TOTAL_RESTARTS=$((WD_TOTAL_RESTARTS + 1))
    WD_FAILURES=0

    if systemctl restart "nns-openvpn@${app}.service"; then
        systemctl reset-failed "nns-online@${app}.service" >/dev/null 2>&1 || true
        if systemctl start "nns-online@${app}.service"; then
            WD_LAST_RESULT=recovered
            log "Watchdog restored the data path for '$app'."
        else
            WD_LAST_RESULT=restart-offline
            warn "Watchdog restarted '$app', but its data path did not become online yet."
        fi
    else
        WD_LAST_RESULT=restart-failed
        warn "Watchdog could not restart the VPN backend for '$app'."
    fi

    watchdog_state_save "$app"
    release_lock "watchdog-$app"
    return 0
}

start_app() {
    require_root
    local app=$1
    local ignore_start_error=${2:-off}
    local via_override=${3:-__default__}
    case "$ignore_start_error" in
        off|on|probe) ;;
        *) die "Invalid start readiness mode '$ignore_start_error'." ;;
    esac
    local vpn_type profile_marker
    validate_app_name "$app"
    load_cfg "$app"

    # `install <app> via --remote ...` intentionally creates a pending local
    # environment before `add` deploys the provider profile and imports the
    # generated client bundle. Report that state explicitly instead of falling
    # through to the generic backend-detection error.
    if [[ "${REMOTE_MODE:-}" == auto &&
          ( -z "${DEFAULT_PROFILE:-}" || -z "${VPN_TYPE:-}" ) ]]; then
        die "Automatic remote app '$app' is configured, but no provider profile has been deployed. Run: nns-app add $app /path/to/profile.ovpn"
    fi

    # An explicitly started automatic-remote app owns both ends of the path.
    # Bring the remote provider exit and private gateway online before starting
    # or reconciling the local SSH/OpenVPN client. The remote operation is
    # idempotent, so recovery after an earlier explicit stop is transparent.
    if [[ "${REMOTE_MODE:-}" == auto ]]; then
        remote_auto_start_app "$app"
        load_cfg "$app"
    fi

    vpn_type=$(vpn_type_for_app "$app" 2>/dev/null || true)
    [[ -n "$vpn_type" ]] || die "Cannot determine VPN backend for '$app'. Re-add its profile or configure --backend inherit."

    if [[ "$vpn_type" == inherit ]]; then
        profile_marker="inherit:${UPSTREAM_APP:-host}"
    else
        [[ -n "$DEFAULT_PROFILE" ]] || die "No profile configured. Use: nns-app add $app profile.ovpn|wireguard.conf"
        [[ -f "$(profiles_dir "$app")/$DEFAULT_PROFILE" ]] ||
            die "Configured profile '$DEFAULT_PROFILE' is missing."
        profile_marker=$DEFAULT_PROFILE
    fi

    local desired_via current_via="host"
    desired_via=$(effective_via_for_app "$app" "$via_override")
    if [[ "$vpn_type" == inherit && "$desired_via" == host ]]; then
        die "Inherit backend '$app' requires an upstream NNS app."
    fi
    if [[ "$desired_via" != host ]]; then
        ensure_upstream_ready "$app" "$desired_via" >/dev/null
    fi
    [[ "$vpn_type" != inherit ]] || profile_marker="inherit:${desired_via}"

    local current=""
    [[ -f "$RUN_DIR/${app}.profile" ]] && current=$(<"$RUN_DIR/${app}.profile")
    if app_is_started "$app"; then
        current_via=$(runtime_via_for_app "$app")
    fi
    if app_is_started "$app" && [[ "$current" == "$profile_marker" && "$current_via" == "$desired_via" ]]; then
        sync_watchdog_timer "$app"
        log "'$app' is already started with '$profile_marker' via $desired_via."
        return 0
    fi

    if app_is_started "$app" || systemctl is-active --quiet "nns-netns@${app}.service"; then
        stop_app "$app"
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
        warn "Failed to start the network backend for '$app'."
        warn "Recent backend-service log:"
        journalctl -u "nns-openvpn@${app}.service" -n 40 \
            -o cat --no-pager >&2 2>/dev/null || true
        stop_app "$app"
        return 1
    fi

    sync_watchdog_timer "$app"

    local timeout
    if [[ "$ignore_start_error" == probe ]] || bool_on "$ignore_start_error"; then
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
        if watchdog_enabled_for_type "$vpn_type"; then
            watchdog_mark_online "$app"
        fi
        log "Started '$app' with '$profile_marker' ($(vpn_type_label "$vpn_type")) via $desired_via.${ext:+ External IP: $ext}"
        return 0
    fi

    if [[ "$ignore_start_error" == probe ]]; then
        log "Started provider-address probe for '$app' via $desired_via; full data-path readiness is deferred."
        return 0
    fi

    if bool_on "$ignore_start_error"; then
        warn "'$app' is not online yet; -i ignored the readiness error."
        warn "The namespace and backend service were left running via $desired_via."
        warn "Check later with: nns-app list"
        return 0
    fi

    warn "'$app' failed: the data path was not online within ${timeout}s."
    warn "Stopping the failed instance instead of leaving it reconnecting."
    warn "Recent backend log:"
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
    systemctl stop "nns-watchdog@${app}.timer" 2>/dev/null || true
    systemctl stop "nns-watchdog@${app}.service" 2>/dev/null || true
    systemctl stop "nns-online@${app}.service" 2>/dev/null || true
    systemctl stop "nns-dns@${app}.service" 2>/dev/null || true
    systemctl stop "nns-openvpn@${app}.service" 2>/dev/null || true
    systemctl stop "nns-netns@${app}.service" 2>/dev/null || true
    systemctl reset-failed \
        "nns-watchdog@${app}.service" \
        "nns-online@${app}.service" \
        "nns-dns@${app}.service" \
        "nns-openvpn@${app}.service" \
        "nns-netns@${app}.service" 2>/dev/null || true

    rm -f \
        "$RUN_DIR/${app}.profile" \
        "$RUN_DIR/${app}.type" \
        "$RUN_DIR/${app}.via" \
        "$(watchdog_state_file "$app")" \
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

    # This is an enumerator, not a predicate. An empty result is successful.
    # Without the explicit return, the last non-matching [[ ... ]] becomes the
    # function status and `set -e -o pipefail` can abort remove/purge silently.
    return 0
}

remote_alias_used_by_other_app() {
    local alias=$1 excluded_app=$2 dir app configured_alias
    shopt -s nullglob
    for dir in "$BASE_DIR"/*; do
        [[ -d "$dir" ]] || continue
        app=$(basename "$dir")
        [[ "$app" != "$excluded_app" && -f "$(cfg_file "$app")" ]] || continue
        configured_alias=$(cfg_read_value "$app" REMOTE_ALIAS 2>/dev/null || true)
        [[ "$configured_alias" == "$alias" ]] && return 0
    done
    return 1
}

remove_app() {
    require_root
    local app=$1 cleanup_mode=${2:-remote}
    local gateway_dependencies app_dependencies auto_alias=""
    validate_app_name "$app"
    assert_destructive_command_from_host "remove '$app'"
    load_cfg "$app"

    auto_alias=${REMOTE_ALIAS:-}
    gateway_dependencies=$(gateways_using_app "$app" | paste -sd ', ' -)
    app_dependencies=$(apps_using_upstream "$app" | paste -sd ', ' -)
    [[ -z "$gateway_dependencies" ]] ||
        die "App '$app' is used by gateway(s): $gateway_dependencies. Reconfigure them first."
    [[ -z "$app_dependencies" ]] ||
        die "App '$app' is the configured upstream for: $app_dependencies. Reconfigure those apps first."

    if [[ "${REMOTE_MODE:-}" == auto ]]; then
        if [[ "$cleanup_mode" != local-only ]]; then
            remote_auto_cleanup_app "$app"
            load_cfg "$app"
        else
            warn "Leaving automatic remote resources for '$app' because --local-only was requested."
        fi
    fi

    stop_app "$app"
    load_cfg "$app"
    firewalld_interface_remove "$VETH_HOST"
    systemctl disable --now "nns-watchdog@${app}.timer" \
        >/dev/null 2>&1 || true
    systemctl disable \
        "nns-online@${app}.service" \
        "nns-openvpn@${app}.service" \
        "nns-netns@${app}.service" \
        >/dev/null 2>&1 || true

    rm -f "/etc/sudoers.d/nns-app-${app}"
    rm -rf \
        "$(app_dropin_dir "$app")" \
        "$(cfg_dir "$app")" \
        "/etc/netns/$NS_NAME"
    rm -f \
        "$RUN_DIR/${app}.env" \
        "$RUN_DIR/${app}.profile" \
        "$RUN_DIR/${app}.type" \
        "$RUN_DIR/${app}.via" \
        "$(watchdog_state_file "$app")" \
        "$(wireguard_runtime_config_path "$app")"

    if [[ -n "$auto_alias" ]] &&
       ! remote_alias_used_by_other_app "$auto_alias" "$app"; then
        rm -rf -- "$(remote_dir "$auto_alias")"
    fi
    systemctl daemon-reload
    log "Removed NNS app '$app'."
}

purge_engine() {
    require_root
    assert_destructive_command_from_host "purge nns-app"

    local cleanup_mode=${1:-remote}
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

    # Automatic-remote objects are owned by their local app. Clean them before
    # deleting local SSH keys and metadata. Failure is fail-closed: local state
    # remains available so the user can retry when the remote host returns.
    if [[ "$cleanup_mode" != local-only ]]; then
        for app in "${apps[@]}"; do
            remote_auto_cleanup_app "$app"
        done
    else
        warn "Purging local state only; automatic remote exits and gateways are intentionally left in place."
    fi

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
        systemctl stop "nns-watchdog@${app}.timer" 2>/dev/null || true
        systemctl stop "nns-watchdog@${app}.service" 2>/dev/null || true
        systemctl stop "nns-online@${app}.service" 2>/dev/null || true
        systemctl stop "nns-dns@${app}.service" 2>/dev/null || true
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
            "nns-watchdog@${app}.timer" \
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

    # Remove the global firewalld objects after all managed interfaces have
    # disappeared. They are owned exclusively by nns-app.
    firewalld_remove_integration

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
           -o -name 'nns-dns@*.service' \
           -o -name 'nns-watchdog@*.service' \
           -o -name 'nns-watchdog@*.timer' \
           -o -name 'nns-gateway@*.service' \
           -o -name 'nns-gateway-crl-refresh@*.service' \
           -o -name 'nns-gateway-crl-refresh@*.timer' \) \
        -delete 2>/dev/null || true

    find /etc/systemd/system -maxdepth 1 -type d \
        \( -name 'nns-netns@*.service.d' \
           -o -name 'nns-online@*.service.d' \
           -o -name 'nns-watchdog@*.service.d' \
           -o -name 'nns-watchdog@*.timer.d' \
           -o -name 'nns-gateway@*.service.d' \) \
        -exec rm -rf {} + 2>/dev/null || true

    rm -rf -- \
        /etc/systemd/system/nns-openvpn@.service.d \
        /etc/systemd/system/nns-netns@.service.d \
        /etc/systemd/system/nns-online@.service.d \
        /etc/systemd/system/nns-watchdog@.service.d \
        /etc/systemd/system/nns-watchdog@.timer.d \
        /etc/systemd/system/nns-gateway@.service.d
    rm -f -- \
        "$VPN_UNIT" "$NETNS_UNIT" "$ONLINE_UNIT" "$DNS_PROXY_UNIT" \
        "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER" "$GATEWAY_UNIT" \
        "$GATEWAY_CRL_SERVICE" "$GATEWAY_CRL_TIMER"

    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    rm -f -- "$USER_PATH"
    rm -f -- "$ENGINE_PATH"

    log "Purged NNS app engine and all installed NNS apps."
    if [[ "$cleanup_mode" != local-only ]]; then
        log "Removed automatic remote exits, gateways, clients, and per-owner SSH keys."
    fi
    log "Removed: $BASE_DIR, /etc/netns/nns-*, NNS systemd units, NNS sudoers rules, $USER_PATH and $ENGINE_PATH"
}


