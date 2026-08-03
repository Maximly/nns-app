# nns-app source module: command execution and detailed status reporting.
mount_type_at() {
    local path=$1
    awk -v path="$path" '
        $5 == path {
            for (i = 1; i <= NF; i++) {
                if ($i == "-") {
                    print $(i + 1)
                    exit
                }
            }
        }
    ' /proc/self/mountinfo
}

prepare_namespaced_snap_mounts() {
    # `ip netns exec` creates a private mount namespace for per-namespace
    # configuration binds. Snap launchers also require cgroup2 and securityfs
    # there. These mounts are command-local and disappear when it exits.
    local current_type

    # These are kernel-managed virtual-filesystem paths.  `install -d -m`
    # chmods directories even when they already exist, which fails on sysfs
    # and aborts `nns-app run` under `set -e`.  `mkdir -p` is intentionally
    # used without a mode so existing mount points are left untouched.
    local mountpoint
    for mountpoint in /sys/fs/cgroup /sys/kernel/security; do
        if ! mkdir -p -- "$mountpoint"; then
            warn "Could not prepare $mountpoint inside the command mount namespace; Snap applications may fail."
        fi
    done

    current_type=$(mount_type_at /sys/fs/cgroup)
    if [[ "$current_type" != cgroup2 ]]; then
        if ! mount -t cgroup2 cgroup2 /sys/fs/cgroup; then
            warn "Could not mount cgroup2 inside the command mount namespace; Snap applications may fail."
        fi
    fi

    current_type=$(mount_type_at /sys/kernel/security)
    if [[ "$current_type" != securityfs ]]; then
        if ! mount -t securityfs securityfs /sys/kernel/security; then
            warn "Could not mount securityfs inside the command mount namespace; Snap applications may fail."
        fi
    fi
}


run_command_path() {
    local command_name=$1 candidate

    if [[ "$command_name" == */* ]]; then
        printf '%s\n' "$command_name"
        return 0
    fi

    candidate=$(PATH=/usr/local/bin:/usr/bin:/bin:/snap/bin type -P -- "$command_name" 2>/dev/null || true)
    [[ -n "$candidate" ]] || return 1
    printf '%s\n' "$candidate"
}

command_needs_namespaced_snap_mounts() {
    local command_name=$1 candidate canonical

    candidate=$(run_command_path "$command_name" 2>/dev/null || true)
    [[ -n "$candidate" ]] || return 1

    # Preserve the pre-canonical path because /snap/bin/<app> usually resolves
    # to /usr/bin/snap and the alias path itself is useful evidence.
    case "$candidate" in
        /snap/bin/*|/var/lib/snapd/snap/bin/*)
            return 0
            ;;
    esac

    canonical=$(readlink -f -- "$candidate" 2>/dev/null || true)
    case "$canonical" in
        /usr/bin/snap|/usr/lib/snapd/snap|/usr/lib/snapd/snap-confine|/snap/*)
            return 0
            ;;
    esac

    return 1
}

namespace_ref_id() {
    local path=$1
    stat -Lc '%d:%i' -- "$path" 2>/dev/null
}

run_user_exec() {
    require_root
    local app=$1
    shift
    (( $# > 0 )) || die "_run-user requires an app and command."
    validate_app_name "$app"
    load_cfg "$app"

    # Refuse direct invocation: this helper is valid only after `ip netns exec`
    # has entered the application environment's network namespace.
    local current_netns expected_netns
    if ! current_netns=$(namespace_ref_id /proc/self/ns/net); then
        die "Cannot identify the current network namespace."
    fi
    if ! expected_netns=$(namespace_ref_id "/run/netns/$NS_NAME"); then
        die "Cannot identify the configured namespace '$NS_NAME'."
    fi
    [[ "$current_netns" == "$expected_netns" ]] ||
        die "_run-user is not inside the expected namespace '$NS_NAME'."

    # Most commands need only the network namespace and namespace-specific
    # resolver bind. Preparing cgroup2/securityfs for every process is both
    # unnecessary and can fail on kernel-managed mount points. Do it only for
    # commands that actually resolve to Snap/snap-confine.
    if command_needs_namespaced_snap_mounts "$1"; then
        prepare_namespaced_snap_mounts
    fi

    local uid gid home shell
    uid=$(id -u "$APP_USER")
    gid=$(id -g "$APP_USER")
    home=$(getent passwd "$APP_USER" | cut -d: -f6)
    shell=$(getent passwd "$APP_USER" | cut -d: -f7)
    [[ -n "$shell" ]] || shell=/bin/bash

    local env_args=(
        "HOME=$home"
        "USER=$APP_USER"
        "LOGNAME=$APP_USER"
        "SHELL=$shell"
        "PATH=/usr/local/bin:/usr/bin:/bin:/snap/bin"
        "XDG_RUNTIME_DIR=/run/user/$uid"
    )
    local name value
    # Preserve the desktop-session identity and D-Bus environment needed by
    # Electron/Chromium safeStorage to select GNOME Keyring or KWallet.  The
    # command still receives a clean allow-listed environment; no loader or
    # shell-startup variables are carried across the root boundary.
    for name in DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS \
                XDG_CURRENT_DESKTOP XDG_SESSION_DESKTOP XDG_SESSION_TYPE \
                DESKTOP_SESSION GDMSESSION GNOME_DESKTOP_SESSION_ID \
                GNOME_KEYRING_CONTROL KDE_FULL_SESSION KDE_SESSION_VERSION \
                XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME \
                XDG_CONFIG_DIRS XDG_DATA_DIRS \
                LANG LANGUAGE LC_ALL TERM COLORTERM SSH_AUTH_SOCK; do
        value=${!name-}
        [[ -z "$value" ]] || env_args+=("$name=$value")
    done

    exec /usr/bin/setpriv \
        --reuid="$uid" \
        --regid="$gid" \
        --init-groups \
        -- \
        /usr/bin/env -i "${env_args[@]}" "$@"
}

run_in_app() {
    require_root
    local app=$1
    shift
    (( $# > 0 )) || die "run requires a command line."
    validate_app_name "$app"
    load_cfg "$app"

    if ! systemctl is-active --quiet "nns-netns@${app}.service"; then
        if [[ "${REMOTE_MODE:-}" == auto ]]; then
            log "Starting automatic remote environment '$app'..."
            start_app "$app" off __default__ ||
                die "Automatic remote environment '$app' could not be started."
            load_cfg "$app"
        else
            die "'$app' is stopped. Start it first."
        fi
    fi
    ip netns list | awk '{print $1}' | grep -Fxq "$NS_NAME" ||
        die "Namespace '$NS_NAME' does not exist."

    if bool_on "$KILLSWITCH"; then
        systemctl is-active --quiet "nns-openvpn@${app}.service" ||
            die "VPN service for '$app' is not running."
        vpn_route_ready "$app" ||
            die "VPN tunnel for '$app' is not ready."
        wait_online "$app" 2 ||
            die "VPN data path for '$app' is not online yet."
    fi

    # `ip netns exec` supplies the namespace-specific resolver bind. The
    # internal helper prepares Snap-required mounts, then drops permanently to
    # APP_USER without shell re-parsing or eval.
    exec /usr/sbin/ip netns exec "$NS_NAME" \
        "$ENGINE_PATH" _run-user "$app" "$@"
}


human_bytes() {
    local value=${1:-0}
    [[ "$value" =~ ^[0-9]+$ ]] || value=0
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$value" 2>/dev/null || printf '%sB' "$value"
    else
        printf '%sB' "$value"
    fi
}

unit_current_log() {
    local unit=$1 lines=${2:-200} invocation
    invocation=$(systemctl show "$unit" -p InvocationID --value 2>/dev/null || true)

    if [[ "$invocation" =~ ^[0-9a-fA-F]{32}$ ]] && [[ "$invocation" != 00000000000000000000000000000000 ]]; then
        journalctl -b -n "$lines" -o cat --no-pager \
            "_SYSTEMD_INVOCATION_ID=$invocation" 2>/dev/null || true
    else
        journalctl -b -u "$unit" -n "$lines" -o cat --no-pager 2>/dev/null || true
    fi
}

print_status_log_cut() {
    local title=$1 file=$2 pattern=$3 fallback=${4:-12}
    local matched

    [[ -s "$file" ]] || return 0
    matched=$(grep -Ei "$pattern" "$file" 2>/dev/null | tail -n 24 || true)

    printf '\n%s\n' "$title"
    if [[ -n "$matched" ]]; then
        printf '%s\n' "$matched"
    else
        tail -n "$fallback" "$file"
    fi
}

openvpn_status_diagnosis() {
    local log_file=$1
    if grep -Eqi 'AUTH_FAILED|authentication failed' "$log_file"; then
        printf 'OpenVPN authentication was rejected.'
    elif grep -Eqi 'VERIFY ERROR|certificate verification failed|Cannot load certificate|private key password' "$log_file"; then
        printf 'OpenVPN certificate or private-key validation failed.'
    elif grep -Eqi 'Options error|Unrecognized option|Exiting due to fatal error' "$log_file"; then
        printf 'OpenVPN rejected the profile or runtime options.'
    elif grep -Eqi 'Connection refused|Network is unreachable|No route to host|connect.*failed: Connection timed out|TCP connection.*failed' "$log_file"; then
        printf 'The VPN endpoint transport connection failed.'
    elif grep -Eq 'TCP connection established' "$log_file" &&
         ! grep -Eq 'TLS: Initial packet|Peer Connection Initiated' "$log_file"; then
        printf 'TCP connected, but no OpenVPN/TLS response arrived; the path may be filtering OpenVPN or the port is not serving OpenVPN.'
    elif grep -Eq 'Peer Connection Initiated' "$log_file" &&
         ! grep -Eq 'Initialization Sequence Completed' "$log_file"; then
        printf 'OpenVPN TLS is established, but initialization or pushed configuration has not completed.'
    elif grep -Eq 'Initialization Sequence Completed' "$log_file"; then
        printf 'OpenVPN initialized, but the namespace data path is not currently usable.'
    elif grep -Eq 'Attempting to establish' "$log_file"; then
        printf 'OpenVPN is still trying to establish the endpoint transport connection.'
    else
        printf 'OpenVPN is running, but no completed handshake was found in the current service invocation.'
    fi
}

status_app() {
    require_root
    local app=$1
    validate_app_name "$app"
    load_cfg "$app"

    local ns_unit="nns-netns@${app}.service"
    local vpn_unit="nns-openvpn@${app}.service"
    local profile_name=${DEFAULT_PROFILE:-}
    local profile_file=""
    local type="" type_label="unknown"
    local configured_via runtime_via
    local ns_state vpn_state ns_sub vpn_sub ns_result vpn_result
    local ns_pid vpn_pid ns_since vpn_since restarts
    local namespace_exists="no"
    local route_iface="" local_ip="" external_ip="" ping_ok="no"
    local health="STOPPED" diagnosis=""
    local tmpdir ns_log vpn_log
    local endpoint_line endpoint_count=0
    local upstream_health="not applicable"
    local watchdog_timer_state watchdog_armed watchdog_failures watchdog_limit watchdog_result
    local watchdog_last_restart watchdog_total_restarts watchdog_last_restart_text="never"

    configured_via=$(effective_via_for_app "$app" __default__)
    runtime_via=$(runtime_via_for_app "$app" 2>/dev/null || printf '%s' "$configured_via")

    type=$(vpn_type_for_app "$app" 2>/dev/null || true)
    if [[ "${REMOTE_MODE:-}" == auto &&
          ( -z "${DEFAULT_PROFILE:-}" || -z "${VPN_TYPE:-}" ) ]]; then
        type_label="pending remote deployment"
    else
        type_label=$(vpn_type_label "${type:-unknown}")
    fi
    if [[ "$type" == inherit ]]; then
        profile_name="inherited:${configured_via}"
    elif [[ -n "$profile_name" ]]; then
        profile_file="$(profiles_dir "$app")/$profile_name"
    fi

    ns_state=$(systemctl is-active "$ns_unit" 2>/dev/null || true)
    vpn_state=$(systemctl is-active "$vpn_unit" 2>/dev/null || true)
    ns_sub=$(systemctl show "$ns_unit" -p SubState --value 2>/dev/null || true)
    vpn_sub=$(systemctl show "$vpn_unit" -p SubState --value 2>/dev/null || true)
    ns_result=$(systemctl show "$ns_unit" -p Result --value 2>/dev/null || true)
    vpn_result=$(systemctl show "$vpn_unit" -p Result --value 2>/dev/null || true)
    ns_pid=$(systemctl show "$ns_unit" -p MainPID --value 2>/dev/null || true)
    vpn_pid=$(systemctl show "$vpn_unit" -p MainPID --value 2>/dev/null || true)
    ns_since=$(systemctl show "$ns_unit" -p ActiveEnterTimestamp --value 2>/dev/null || true)
    vpn_since=$(systemctl show "$vpn_unit" -p ActiveEnterTimestamp --value 2>/dev/null || true)
    restarts=$(systemctl show "$vpn_unit" -p NRestarts --value 2>/dev/null || true)
    watchdog_timer_state=$(systemctl is-active "nns-watchdog@${app}.timer" 2>/dev/null || true)
    watchdog_state_load "$app"
    watchdog_armed=$WD_ARMED
    watchdog_failures=$WD_FAILURES
    watchdog_result=$WD_LAST_RESULT
    watchdog_last_restart=$WD_LAST_RESTART
    watchdog_total_restarts=$WD_TOTAL_RESTARTS
    watchdog_limit=$(watchdog_numeric_setting "${WATCHDOG_FAILURES:-3}" 3 1 20)
    if (( watchdog_last_restart > 0 )); then
        local watchdog_age=$(( $(date +%s) - watchdog_last_restart ))
        (( watchdog_age < 0 )) && watchdog_age=0
        watchdog_last_restart_text="$(format_duration "$watchdog_age") ago"
    fi

    [[ -e "/run/netns/$NS_NAME" ]] && namespace_exists="yes"

    tmpdir=$(mktemp -d)
    ns_log="$tmpdir/netns.log"
    vpn_log="$tmpdir/vpn.log"
    unit_current_log "$ns_unit" 160 >"$ns_log"
    unit_current_log "$vpn_unit" 240 >"$vpn_log"

    if [[ "$ns_state" == active && "$namespace_exists" == yes ]]; then
        route_iface=$(vpn_route_iface "$app" 2>/dev/null || true)
        local_ip=$(vpn_local_ipv4 "$app" 2>/dev/null || true)

        if [[ -n "$route_iface" ]]; then
            external_ip=$(ip netns exec "$NS_NAME" curl -4fsS \
                --connect-timeout 2 --max-time 4 \
                "$EXTERNAL_IP_URL" 2>/dev/null || true)
            if ip netns exec "$NS_NAME" ping -c 1 -W 1 1.1.1.1 >/dev/null 2>&1; then
                ping_ok="yes"
            fi
        fi
    fi

    if [[ "${REMOTE_MODE:-}" == auto &&
          ( -z "${DEFAULT_PROFILE:-}" || -z "${VPN_TYPE:-}" ) ]]; then
        health="PENDING"
        diagnosis="Remote access is configured, but no provider profile has been deployed. Run: nns-app add $app /path/to/profile.ovpn"
    elif [[ "$ns_state" == failed || "$ns_result" == failed ]]; then
        health="FAILED"
        diagnosis="Network namespace setup failed."
    elif [[ "$ns_state" != active || "$namespace_exists" != yes ]]; then
        if [[ "$ns_state" == activating ]]; then
            health="STARTING"
            diagnosis="The network namespace service is still starting."
        else
            health="STOPPED"
            diagnosis="The application namespace is not running."
        fi
    elif [[ "$vpn_state" == failed || "$vpn_result" == failed ]]; then
        health="FAILED"
        diagnosis="The VPN backend service failed."
    elif [[ "$vpn_state" != active ]]; then
        if [[ "$vpn_state" == activating ]]; then
            health="STARTING"
            diagnosis="The VPN backend service is still starting."
        else
            health="OFFLINE"
            diagnosis="The namespace is active, but the VPN backend is not running."
        fi
    elif [[ -z "$route_iface" ]]; then
        health="STARTING"
        case "$type" in
            openvpn) diagnosis=$(openvpn_status_diagnosis "$vpn_log") ;;
            wireguard) diagnosis="WireGuard is running, but its interface or full-tunnel route is not ready." ;;
            inherit) diagnosis="The inherited upstream data path is not ready." ;;
            *) diagnosis="The network backend is active, but no usable route exists." ;;
        esac
    elif [[ -n "$external_ip" || "$ping_ok" == yes ]]; then
        health="ONLINE"
        if [[ -n "$external_ip" ]]; then
            diagnosis="The tunnel route and external data path are working."
        else
            diagnosis="The tunnel passes IP traffic, but the external-IP service did not answer."
        fi
    else
        health="OFFLINE"
        case "$type" in
            openvpn) diagnosis=$(openvpn_status_diagnosis "$vpn_log") ;;
            wireguard) diagnosis="The WireGuard interface exists, but the Internet data-path probe failed." ;;
            inherit) diagnosis="The upstream route exists, but the inherited Internet data-path probe failed." ;;
            *) diagnosis="The tunnel exists, but the Internet data-path probe failed." ;;
        esac
    fi

    if [[ "$runtime_via" != host ]]; then
        if app_is_started "$runtime_via" && vpn_route_ready "$runtime_via"; then
            upstream_health="ready"
        elif app_is_started "$runtime_via"; then
            upstream_health="started but tunnel not ready"
        else
            upstream_health="stopped or failed"
        fi
    fi

    printf 'Application:       %s\n' "$app"
    printf 'Health:            %s\n' "$health"
    printf 'Diagnosis:         %s\n' "$diagnosis"
    printf 'Profile:           %s\n' "${profile_name:-not configured}"
    printf 'Backend:           %s\n' "$type_label"
    if [[ "$type" == openvpn ]]; then
        printf 'Transport:         %s\n' "${TRANSPORT_TYPE:-direct}"
    fi
    if [[ "${REMOTE_MODE:-}" == auto ]]; then
        printf 'Remote mode:       automatic\n'
        printf 'Remote target:     %s\n' "${TRANSPORT_SSH_TARGET:-unknown}"
        printf 'Remote exit:       %s\n' "${REMOTE_EXIT_APP:-unknown}"
        printf 'Remote gateway:    %s/%s\n' "${REMOTE_GATEWAY:-unknown}" "${REMOTE_CLIENT:-unknown}"
    fi
    printf 'Configured via:    %s\n' "$configured_via"
    printf 'Runtime via:       %s\n' "$runtime_via"
    if [[ "$runtime_via" != host ]]; then
        printf 'Upstream health:   %s\n' "$upstream_health"
    fi
    printf 'Namespace:         %s (%s)\n' "$NS_NAME" "$namespace_exists"
    printf 'Namespace service: %s/%s; result=%s; pid=%s\n' \
        "${ns_state:-unknown}" "${ns_sub:-unknown}" "${ns_result:-unknown}" "${ns_pid:-0}"
    printf 'VPN service:       %s/%s; result=%s; pid=%s; restarts=%s\n' \
        "${vpn_state:-unknown}" "${vpn_sub:-unknown}" "${vpn_result:-unknown}" \
        "${vpn_pid:-0}" "${restarts:-0}"
    if watchdog_enabled_for_type "$type"; then
        printf 'Watchdog:          %s; timer=%s; armed=%s; failures=%s/%s; restart attempts=%s\n' \
            "${WATCHDOG_MODE:-auto}" "${watchdog_timer_state:-inactive}" "$watchdog_armed" \
            "$watchdog_failures" "$watchdog_limit" "$watchdog_total_restarts"
        printf 'Watchdog result:   %s; last restart=%s\n' \
            "$watchdog_result" "$watchdog_last_restart_text"
    else
        printf 'Watchdog:          disabled\n'
    fi
    [[ -z "$ns_since" ]] || printf 'Namespace active:  %s\n' "$ns_since"
    [[ -z "$vpn_since" ]] || printf 'VPN active:        %s\n' "$vpn_since"
    printf 'Kill switch:       %s\n' "${KILLSWITCH:-unknown}"
    printf 'DNS servers:       %s\n' "${DNS_SERVERS:-not configured}"
    printf 'Tunnel interface:  %s\n' "${route_iface:-not ready}"
    printf 'Tunnel IPv4:       %s\n' "${local_ip:-not assigned}"
    printf 'External IPv4:     %s\n' "${external_ip:-unavailable}"
    printf 'Ping data path:    %s\n' "$ping_ok"

    if [[ "$type" == openvpn && "${TRANSPORT_TYPE:-direct}" != direct ]]; then
        printf 'Transport endpoint:%s:%s/tcp\n' "$TRANSPORT_REMOTE_HOST" "$TRANSPORT_REMOTE_PORT"
        printf 'Local wrapper:     127.0.0.1:%s\n' "$TRANSPORT_LOCAL_PORT"
    fi

    if [[ -n "$profile_file" && -f "$profile_file" ]]; then
        printf 'Profile file:      %s\n' "$profile_file"
        local endpoint_host endpoint_port endpoint_proto
        while IFS='|' read -r endpoint_host endpoint_port endpoint_proto; do
            [[ -n "$endpoint_host" && -n "$endpoint_port" && -n "$endpoint_proto" ]] || continue
            endpoint_count=$((endpoint_count + 1))
            endpoint_line="${endpoint_proto^^} ${endpoint_host}:${endpoint_port}"
            if (( endpoint_count == 1 )); then
                printf 'Endpoint:          %s\n' "$endpoint_line"
            elif (( endpoint_count <= 4 )); then
                printf '                   %s\n' "$endpoint_line"
            fi
        done < <(profile_endpoints "$profile_file" 2>/dev/null || true)
        if (( endpoint_count > 4 )); then
            printf '                   ... %d more\n' "$((endpoint_count - 4))"
        fi
    fi

    if [[ "$type" == openvpn ]]; then
        local actual_remote
        actual_remote=$(grep -E 'TCPv[46]_CLIENT link remote|UDPv[46]_CLIENT link remote|Peer Connection Initiated' \
            "$vpn_log" | tail -n 1 || true)
        [[ -z "$actual_remote" ]] || printf 'Current OpenVPN:   %s\n' "$actual_remote"

        if grep -Eq 'Initialization Sequence Completed' "$vpn_log"; then
            printf 'OpenVPN handshake: completed\n'
        elif grep -Eq 'Peer Connection Initiated' "$vpn_log"; then
            printf 'OpenVPN handshake: TLS peer connected; initialization incomplete\n'
        elif grep -Eq 'TLS: Initial packet' "$vpn_log"; then
            printf 'OpenVPN handshake: TLS started\n'
        elif grep -Eq 'TCP connection established' "$vpn_log"; then
            printf 'OpenVPN handshake: transport connected; no TLS response\n'
        else
            printf 'OpenVPN handshake: not established\n'
        fi
    elif [[ "$type" == wireguard && -n "$route_iface" ]]; then
        local latest now age peer_count wg_endpoint rx_bytes tx_bytes
        latest=$(ip netns exec "$NS_NAME" wg show "$route_iface" latest-handshakes 2>/dev/null |
            awk '$2 > latest { latest=$2 } END { print latest+0 }')
        peer_count=$(ip netns exec "$NS_NAME" wg show "$route_iface" peers 2>/dev/null |
            awk 'NF { count++ } END { print count+0 }')
        wg_endpoint=$(ip netns exec "$NS_NAME" wg show "$route_iface" endpoints 2>/dev/null |
            awk '{$1=""; sub(/^ /, ""); if ($0 != "(none)") print}' |
            paste -sd ', ' -)
        IFS=' ' read -r rx_bytes tx_bytes < <(
            ip netns exec "$NS_NAME" wg show "$route_iface" transfer 2>/dev/null |
            awk '{rx+=$2; tx+=$3} END {print rx+0, tx+0}'
        )

        printf 'WireGuard peers:   %s\n' "${peer_count:-0}"
        printf 'WireGuard endpoint:%s%s\n' "${wg_endpoint:+ }" "${wg_endpoint:- unavailable}"
        if [[ "${latest:-0}" -gt 0 ]]; then
            now=$(date +%s)
            age=$((now - latest))
            (( age < 0 )) && age=0
            printf 'Latest handshake:  %s ago\n' "$(format_duration "$age")"
        else
            printf 'Latest handshake:  never\n'
        fi
        printf 'Transfer:          RX %s; TX %s\n' \
            "$(human_bytes "${rx_bytes:-0}")" "$(human_bytes "${tx_bytes:-0}")"
    fi

    if [[ "$health" == ONLINE ]]; then
        print_status_log_cut \
            "Recent successful backend markers:" "$vpn_log" \
            'Initialization Sequence Completed|Peer Connection Initiated|WireGuard interface .* active|latest handshake' 8
    else
        print_status_log_cut \
            "Important namespace log cuts:" "$ns_log" \
            'error|warning|failed|invalid|no such|stale|endpoint|upstream|ready|iptables|nft|route' 14
        print_status_log_cut \
            "Important VPN log cuts:" "$vpn_log" \
            'error|warning|failed|fatal|AUTH_FAILED|VERIFY ERROR|TLS:|TLS Error|TCP connection|Attempting to establish|Peer Connection|Initialization Sequence|WireGuard|wg-quick|RTNETLINK|handshake|endpoint|timed out|refused|unreachable' 18
    fi

    rm -rf "$tmpdir"
}

list_apps() {
    require_root
    install -d -o root -g root -m 0755 "$BASE_DIR" "$RUN_DIR"

    printf '%-18s %-9s %-11s %-12s %s\n' "Name" "Status" "Backend" "Via" "Online"
    printf '%-18s %-9s %-11s %-12s %s\n' "------------------" "---------" "-----------" "------------" "-----------------------------------------------"

    local found=0 dir app status profile local_ip external online via type type_label
    shopt -s nullglob
    for dir in "$BASE_DIR"/*; do
        [[ -d "$dir" ]] || continue
        app=$(basename "$dir")
        [[ -f "$(cfg_file "$app")" ]] || continue
        found=1

        load_cfg "$app"
        profile=${DEFAULT_PROFILE:-none}
        type=$(vpn_type_for_app "$app" 2>/dev/null || true)
        if [[ "$type" == inherit ]]; then
            profile="inherited"
        else
            profile=${profile%.ovpn}
            profile=${profile%.conf}
        fi
        type_label=$(vpn_type_label "${type:-unknown}")
        status=stopped
        via=$(effective_via_for_app "$app" __default__)
        online="$profile | -"

        if app_is_started "$app"; then
            status=started
            via=$(runtime_via_for_app "$app")
            if [[ "$via" != host ]] && ! app_is_started "$via"; then
                via="${via}!"
            fi
            local_ip=$(vpn_local_ipv4 "$app" 2>/dev/null || true)
            [[ -n "$local_ip" ]] || local_ip="-"
            external=""
            if vpn_route_ready "$app"; then
                local ns
                ns=$(cfg_read_value "$app" NS_NAME 2>/dev/null || true)
                external=$(ip netns exec "$ns" curl -4fsS \
                           --connect-timeout 2 --max-time 4 "$EXTERNAL_IP_URL" 2>/dev/null || true)
            fi
            [[ -n "$external" ]] || external="offline"
            online="$profile | $local_ip -> $external"
        fi

        printf '%-18s %-9s %-11s %-12s %s\n' \
            "$app" "$status" "$type_label" "$via" "$online"
    done

    (( found )) || log "No NNS apps installed."
}


