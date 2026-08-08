# nns-app source module: validation, configuration loading and dependency graphs.
validate_app_name() {
    local app=${1:-}
    [[ "$app" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] ||
        die "Invalid app name '$app'. Use 1-32 letters, digits, '.', '_' or '-'."
}

cfg_dir()      { printf '%s/%s\n' "$BASE_DIR" "$1"; }
cfg_file()     { printf '%s/%s/%s.cfg\n' "$BASE_DIR" "$1" "$1"; }
profiles_dir() { printf '%s/%s/profiles\n' "$BASE_DIR" "$1"; }

require_root() {
    (( EUID == 0 )) || die "This internal operation requires root."
}

# Re-run a public command with sudo. Routine operations use -n after install;
# administrative operations are allowed to prompt for a password.
reexec_as_root_if_needed() {
    local cmd=${1:-}
    (( EUID != 0 )) || return 0

    # Elevate the exact script the user invoked. This prevents an upgrade
    # command from being dispatched to an older installed engine.
    local target
    target=$(readlink -f "$0")
    [[ -x "$target" ]] || die "Cannot execute script: $target"

    # Context-only `myip` reads the namespace it is already running in and
    # does not need privilege escalation.  An explicit app name still needs
    # root to enter that app's network namespace from the host or another app.
    if [[ "$cmd" == myip && $# -eq 1 ]]; then
        return 0
    fi

    local sudo_args=(/usr/bin/sudo)
    case "$cmd" in
        list|status|myip|start|stop|run)
            sudo_args+=( -n )
            ;;
        install|remove|add|purge|repair|gateway|remote|link|export|revoke)
            ;;
        *)
            die "Unknown command '$cmd'."
            ;;
    esac

    # Canonicalize flexible start-option ordering before sudo. This lets the
    # per-app sudoers entry remain narrow while accepting --via in any position.
    if [[ "$cmd" == start ]]; then
        shift
        parse_start_cli "$@"
        local -a canonical=(start)
        bool_on "$START_IGNORE" && canonical+=(-i)
        canonical+=("$START_APP_NAME")
        if [[ "$START_VIA" != __default__ ]]; then
            canonical+=(--via "$START_VIA")
        fi
        "${sudo_args[@]}" "$target" "${canonical[@]}"
        exit $?
    fi

    # Preserve the invoking user's command-search path under a dedicated
    # variable before sudo applies secure_path. The root engine never executes
    # through this value; it is passed back only after setpriv has permanently
    # dropped to APP_USER.
    if [[ "$cmd" == run ]]; then
        export NNS_APP_RUN_PATH=${PATH-}
    fi

    # Do not exec sudo here. Keeping this wrapper process separate avoids
    # replacing an interactive caller and gives normal shells clean SIGINT flow.
    "${sudo_args[@]}" "$target" "$@"
    exit $?
}

load_cfg() {
    local app=$1 file owner mode mode_octal
    validate_app_name "$app"
    file=$(cfg_file "$app")
    [[ -f "$file" ]] || die "NNS app '$app' is not installed."

    owner=$(stat -c '%u' "$file")
    mode=$(stat -c '%a' "$file")
    [[ "$owner" == 0 ]] || die "Unsafe config owner for $file; expected root."
    mode_octal=$((8#$mode))
    (( (mode_octal & 0022) == 0 )) ||
        die "Unsafe config permissions on $file; it must not be group/world writable."

    reset_app_cfg_vars
    # Generated configuration files are sourced only after owner and mode
    # validation. Resetting every field prevents state leaking between loads.
    # shellcheck disable=SC1090
    source "$file"

    [[ "${APP_NAME:-}" == "$app" ]] || die "APP_NAME mismatch in $file."
    [[ -n "${APP_USER:-}" ]] || die "APP_USER is missing in $file."
    id "$APP_USER" >/dev/null 2>&1 ||
        die "Configured user '$APP_USER' does not exist."
    [[ "${NS_CIDR:-}" =~ ^[0-9.]+/[0-9]+$ ]] ||
        die "NS_CIDR is invalid in $file."
    [[ -n "${NS_NAME:-}" && -n "${VETH_HOST:-}" && -n "${VETH_NS:-}" ]] ||
        die "Namespace identity fields are missing in $file."
}

cfg_set() {
    local app=$1 key=$2 value=$3
    local file tmp quoted line found=0
    file=$(cfg_file "$app")
    tmp=$(mktemp "${file}.XXXXXX")

    # Config files are sourced by Bash after strict owner/mode checks. Store
    # values using Bash's reversible shell quoting and avoid passing that
    # quoting through sed/awk escape processing.
    printf -v quoted '%q' "$value"
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "$key="* ]]; then
            printf '%s=%s\n' "$key" "$quoted"
            found=1
        else
            printf '%s\n' "$line"
        fi
    done <"$file" >"$tmp"
    (( found )) || printf '%s=%s\n' "$key" "$quoted" >>"$tmp"

    install -o root -g root -m 0644 "$tmp" "$file"
    rm -f "$tmp"
}

bool_on() {
    case "${1,,}" in
        1|yes|true|on|enabled) return 0 ;;
        *) return 1 ;;
    esac
}

cfg_read_value() {
    local app=$1 key=$2 file
    validate_app_name "$app"
    file=$(cfg_file "$app")
    [[ -f "$file" ]] || return 1

    (
        set +u
        # shellcheck disable=SC1090
        source "$file"
        printf '%s\n' "${!key-}"
    )
}

runtime_read_value() {
    local file=$1 key=$2
    [[ -f "$file" ]] || return 1
    (
        set +u
        # shellcheck disable=SC1090
        source "$file"
        printf '%s\n' "${!key-}"
    )
}

assert_no_via_cycle() {
    local child=$1 parent=$2 current=$2 next
    declare -A seen=()
    seen[$child]=1

    while [[ "$current" != host && -n "$current" ]]; do
        [[ -z "${seen[$current]-}" ]] ||
            die "Upstream cycle detected while linking '$child' via '$parent'."
        seen[$current]=1
        next=$(cfg_read_value "$current" UPSTREAM_APP 2>/dev/null || true)
        current=${next:-host}
    done
}

normalize_via() {
    local child=$1 via=${2:-host}
    [[ -n "$via" ]] || via=host
    if [[ "$via" == host ]]; then
        printf 'host\n'
        return 0
    fi

    validate_app_name "$via"
    [[ "$via" != "$child" ]] || die "An app cannot use itself as its upstream."
    [[ -f "$(cfg_file "$via")" ]] ||
        die "Upstream app '$via' is not installed."
    assert_no_via_cycle "$child" "$via"
    printf '%s\n' "$via"
}

namespace_ref_id() {
    local path=$1
    stat -Lc '%d:%i' -- "$path" 2>/dev/null
}

current_nns_app() {
    local current dir app ns target
    current=$(namespace_ref_id /proc/self/ns/net 2>/dev/null || true)
    [[ -n "$current" ]] || return 1

    shopt -s nullglob
    for dir in "$BASE_DIR"/*; do
        [[ -d "$dir" ]] || continue
        app=$(basename "$dir")
        [[ -f "$(cfg_file "$app")" ]] || continue
        ns=$(cfg_read_value "$app" NS_NAME 2>/dev/null || true)
        [[ -n "$ns" && -e "/run/netns/$ns" ]] || continue
        target=$(namespace_ref_id "/run/netns/$ns" 2>/dev/null || true)
        if [[ -n "$target" && "$current" == "$target" ]]; then
            printf '%s\n' "$app"
            return 0
        fi
    done
    return 1
}

assert_destructive_command_from_host() {
    local operation=$1 current_app
    current_app=$(current_nns_app 2>/dev/null || true)
    [[ -z "$current_app" ]] ||
        die "Cannot $operation from inside nns-app environment '$current_app'. Exit the shell/application started by 'nns-app run $current_app ...', or use another host terminal, and retry."
}

effective_via_for_app() {
    local app=$1 override=${2:-__default__} configured
    if [[ "$override" != __default__ ]]; then
        normalize_via "$app" "$override"
        return
    fi

    configured=$(cfg_read_value "$app" UPSTREAM_APP 2>/dev/null || true)
    normalize_via "$app" "${configured:-host}"
}

effective_via_runtime() {
    local app=$1 override_file="$RUN_DIR/${app}.via" selected
    if [[ -s "$override_file" ]]; then
        selected=$(<"$override_file")
        normalize_via "$app" "$selected"
    else
        effective_via_for_app "$app" __default__
    fi
}

runtime_via_for_app() {
    local app=$1 runtime="$RUN_DIR/${app}.env" mode upstream
    mode=$(runtime_read_value "$runtime" UPLINK_MODE_RUNTIME 2>/dev/null || true)
    upstream=$(runtime_read_value "$runtime" UPSTREAM_APP_RUNTIME 2>/dev/null || true)
    if [[ "$mode" == app && -n "$upstream" ]]; then
        printf '%s\n' "$upstream"
    else
        printf 'host\n'
    fi
}

vpn_route_iface() {
    local app=$1 ns type dev expected upstream
    ns=$(cfg_read_value "$app" NS_NAME 2>/dev/null || true)
    [[ -n "$ns" ]] || return 1
    type=$(vpn_type_for_app "$app" 2>/dev/null || true)
    [[ -n "$type" ]] || return 1

    case "$type" in
        openvpn)
            dev=$(ip -n "$ns" -4 route get 1.1.1.1 2>/dev/null |
                  awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
            [[ "$dev" =~ ^(tun|tap) ]] || return 1
            ;;
        wireguard)
            expected=$(wireguard_iface_name "$app")
            ip -n "$ns" link show dev "$expected" up >/dev/null 2>&1 || return 1
            ip netns exec "$ns" wg show "$expected" >/dev/null 2>&1 || return 1
            dev=$expected
            ;;
        inherit)
            dev=$(cfg_read_value "$app" VETH_NS 2>/dev/null || true)
            upstream=$(runtime_via_for_app "$app" 2>/dev/null || true)
            [[ -n "$dev" && "$upstream" != host ]] || return 1
            ip -n "$ns" link show dev "$dev" up >/dev/null 2>&1 || return 1
            vpn_route_ready "$upstream" || return 1
            ;;
        *) return 1 ;;
    esac

    printf '%s
' "$dev"
}

vpn_route_ready() {
    vpn_route_iface "$1" >/dev/null 2>&1
}

vpn_local_ipv4() {
    local app=$1 ns dev
    ns=$(cfg_read_value "$app" NS_NAME 2>/dev/null || true)
    dev=$(vpn_route_iface "$app" 2>/dev/null || true)
    [[ -n "$ns" && -n "$dev" ]] || return 1
    ip -n "$ns" -o -4 addr show dev "$dev" 2>/dev/null |
        awk '{split($4,a,"/"); print a[1]; exit}'
}

upstream_tunnel_iface() {
    local upstream=$1 ns dev
    ns=$(cfg_read_value "$upstream" NS_NAME 2>/dev/null || true)
    [[ -n "$ns" ]] || return 1
    dev=$(vpn_route_iface "$upstream" 2>/dev/null || true)
    [[ -n "$dev" ]] || return 1
    printf '%s|%s\n' "$ns" "$dev"
}


ensure_upstream_ready() {
    local child=$1 upstream=$2 data
    [[ "$upstream" != host ]] || return 0
    normalize_via "$child" "$upstream" >/dev/null

    systemctl is-active --quiet "nns-netns@${upstream}.service" ||
        die "Upstream app '$upstream' is not started."
    systemctl is-active --quiet "nns-openvpn@${upstream}.service" ||
        die "Upstream VPN service for '$upstream' is not running."

    data=$(upstream_tunnel_iface "$upstream" 2>/dev/null || true)
    [[ -n "$data" ]] || die "Upstream app '$upstream' has no active tunnel route."

    if ! ( wait_online "$upstream" 3 ); then
        die "Upstream VPN data path for '$upstream' is offline."
    fi
    printf '%s\n' "$data"
}

parse_start_cli() {
    START_APP_NAME=""
    START_IGNORE="off"
    START_VIA="__default__"

    while (( $# > 0 )); do
        case "$1" in
            -i|--ignore-start-error)
                START_IGNORE="on"
                shift
                ;;
            --via)
                (( $# >= 2 )) || die "--via requires an upstream app name or 'host'."
                START_VIA=$2
                shift 2
                ;;
            --via=*)
                START_VIA=${1#--via=}
                shift
                ;;
            -*)
                die "Unknown start option '$1'."
                ;;
            *)
                [[ -z "$START_APP_NAME" ]] ||
                    die "Usage: nns-app start [-i] <app_name> [--via <upstream-app>|host]"
                START_APP_NAME=$1
                shift
                ;;
        esac
    done

    [[ -n "$START_APP_NAME" ]] ||
        die "Usage: nns-app start [-i] <app_name> [--via <upstream-app>|host]"
}

