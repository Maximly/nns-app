#!/usr/bin/env bash
# nns-app - manage per-application VPN network namespaces on Ubuntu.
#
# Copyright (C) 2026 Maxim Lyadvinsky
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along with
# this program. If not, see <https://www.gnu.org/licenses/>.
#
# SPDX-License-Identifier: GPL-3.0-or-later
# Author: Maxim Lyadvinsky
#
# Public commands:
#   install [<app_name> [--via <upstream-app>|host]]
#   remove  <app_name>
#   purge
#   list
#   add     <app_name> <profile.ovpn|wireguard.conf>
#   add     <app_name> any [country] [--refresh] [--via <upstream-app>|host]
#   start   [-i|--ignore-start-error] <app_name> [--via <upstream-app>|host]
#   stop    <app_name>
#   run     <app_name> <command> [args...]
#
# The script installs itself as /usr/local/sbin/nns_app.sh and creates the
# convenience symlink /usr/local/bin/nns-app.

set -Eeuo pipefail
IFS=$'\n\t'

readonly VERSION="1.0.21"
readonly PROGRAM_NAME="nns-app"
readonly AUTHOR="Maxim Lyadvinsky"
readonly LICENSE_ID="GPL-3.0-or-later"
readonly ENGINE_PATH="/usr/local/sbin/nns_app.sh"
readonly USER_PATH="/usr/local/bin/nns-app"
readonly BASE_DIR="/etc/nns-app"
readonly RUN_DIR="/run/nns-app"
readonly NETNS_UNIT="/etc/systemd/system/nns-netns@.service"
readonly VPN_UNIT="/etc/systemd/system/nns-openvpn@.service"
readonly VPNGATE_API_URL="https://www.vpngate.net/api/iphone/"
readonly CACHE_DIR="/var/cache/nns-app"
readonly STATE_DIR="/var/lib/nns-app"
readonly VPNGATE_CACHE_FILE="$CACHE_DIR/vpngate.csv"
# Candidate profiles are live-tested before import, so the large VPN Gate
# CSV does not need to be downloaded every few minutes.
readonly VPNGATE_CACHE_TTL=172800
readonly VPNGATE_PROBE_TIMEOUT=6
readonly VPNGATE_PROBE_ATTEMPTS=10

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

format_duration() {
    local seconds=${1:-0}
    [[ "$seconds" =~ ^[0-9]+$ ]] || seconds=0

    if (( seconds >= 86400 )); then
        local days=$((seconds / 86400))
        local hours=$(((seconds % 86400) / 3600))
        if (( hours > 0 )); then
            printf '%dd %dh' "$days" "$hours"
        else
            printf '%dd' "$days"
        fi
    elif (( seconds >= 3600 )); then
        local hours=$((seconds / 3600))
        local minutes=$(((seconds % 3600) / 60))
        if (( minutes > 0 )); then
            printf '%dh %dm' "$hours" "$minutes"
        else
            printf '%dh' "$hours"
        fi
    else
        printf '%dm' "$((seconds / 60))"
    fi
}

show_version() {
    printf '%s %s\n' "$PROGRAM_NAME" "$VERSION"
    printf 'Author:  %s\n' "$AUTHOR"
    printf 'License: %s\n' "$LICENSE_ID"
}

usage() {
    cat <<'USAGE'
Usage:
  nns-app install [app_name [--via <upstream-app>|host]]
  nns-app remove  <app_name>
  nns-app purge
  nns-app list
  nns-app add     <app_name> <profile.ovpn|wireguard.conf>
  nns-app add     <app_name> any [country-code-or-name] [--refresh] [--via <upstream-app>|host]
  nns-app start   [-i|--ignore-start-error] <app_name> [--via <upstream-app>|host]
  nns-app stop    <app_name>
  nns-app run     <app_name> <command> [arguments...]

Examples:
  sudo ./nns-app.sh install
  sudo nns-app install hidemy
  sudo nns-app install browser --via hidemy   # persistent upstream
  sudo nns-app add browser ~/Downloads/NorwayS23.ovpn
  sudo nns-app add browser ~/Downloads/wg-provider.conf
  sudo nns-app add browser any US --via hidemy
  nns-app start browser
  nns-app start -i browser --via hidemy       # one-start override
  nns-app run browser curl -4 https://api.ipify.org
  nns-app run browser firefox --no-remote
  sudo nns-app purge
  nns-app list
USAGE
}

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

    # Always elevate the exact script the user invoked.  Using ENGINE_PATH
    # first made a newly downloaded script dispatch commands (notably purge)
    # to an older installed engine that did not yet know those commands.
    local target
    target=$(readlink -f "$0")
    [[ -x "$target" ]] || die "Cannot execute script: $target"

    local sudo_args=(/usr/bin/sudo)
    case "$cmd" in
        list|start|stop|run)
            sudo_args+=( -n )
            ;;
        install|remove|add|purge)
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

    # Do not exec sudo here. Keeping this wrapper process separate avoids
    # replacing an interactive caller and gives normal shells clean SIGINT flow.
    "${sudo_args[@]}" "$target" "$@"
    exit $?
}

load_cfg() {
    local app=$1
    local file
    file=$(cfg_file "$app")
    [[ -f "$file" ]] || die "NNS app '$app' is not installed."

    local owner mode mode_octal
    owner=$(stat -c '%u' "$file")
    mode=$(stat -c '%a' "$file")
    [[ "$owner" == 0 ]] || die "Unsafe config owner for $file; expected root."
    mode_octal=$((8#$mode))
    (( (mode_octal & 0022) == 0 )) ||
        die "Unsafe config permissions on $file; it must not be group/world writable."

    # Newer optional fields must be reset before sourcing an older config;
    # otherwise a value from a previously loaded app could leak into this one.
    UPSTREAM_APP=""
    VPN_TYPE=""

    # shellcheck disable=SC1090
    source "$file"

    [[ "${APP_NAME:-}" == "$app" ]] || die "APP_NAME mismatch in $file."
    [[ -n "${APP_USER:-}" ]] || die "APP_USER is missing in $file."
    id "$APP_USER" >/dev/null 2>&1 || die "Configured user '$APP_USER' does not exist."
}

cfg_set() {
    local app=$1 key=$2 value=$3
    local file tmp
    file=$(cfg_file "$app")
    tmp=$(mktemp "${file}.XXXXXX")

    awk -v key="$key" -v value="$value" '
        BEGIN { done=0 }
        $0 ~ ("^" key "=") {
            printf "%s=\"%s\"\n", key, value
            done=1
            next
        }
        { print }
        END {
            if (!done)
                printf "%s=\"%s\"\n", key, value
        }
    ' "$file" >"$tmp"

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

normalize_via() {
    local child=$1 via=${2:-host}
    [[ -n "$via" ]] || via=host
    if [[ "$via" == host ]]; then
        printf 'host\n'
        return 0
    fi

    validate_app_name "$via"
    [[ "$via" != "$child" ]] || die "An app cannot use itself as its upstream."
    [[ -f "$(cfg_file "$via")" ]] || die "Upstream app '$via' is not installed."
    printf '%s\n' "$via"
}

current_nns_app() {
    local current dir app ns target
    current=$(readlink /proc/self/ns/net 2>/dev/null || true)
    [[ -n "$current" ]] || return 1

    shopt -s nullglob
    for dir in "$BASE_DIR"/*; do
        [[ -d "$dir" ]] || continue
        app=$(basename "$dir")
        [[ -f "$(cfg_file "$app")" ]] || continue
        ns=$(cfg_read_value "$app" NS_NAME 2>/dev/null || true)
        [[ -n "$ns" && -e "/run/netns/$ns" ]] || continue
        target=$(readlink "/run/netns/$ns" 2>/dev/null || true)
        if [[ "$current" == "$target" ]]; then
            printf '%s\n' "$app"
            return 0
        fi
    done
    return 1
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
    local app=$1 ns type dev expected
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
        *) return 1 ;;
    esac

    printf '%s\n' "$dev"
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

    chmod 0644 "$NETNS_UNIT" "$VPN_UNIT"
    systemctl daemon-reload
}

install_engine() {
    require_root

    ensure_dependencies
    install_engine_files
    install -d -o root -g root -m 0755         "$BASE_DIR" "$RUN_DIR" "$CACHE_DIR" "$STATE_DIR"

    log "Installed nns-app $VERSION."
    log "Command: $USER_PATH"
    log "Engine:  $ENGINE_PATH"
}


allocate_network() {
    local used idx offset o3 o4 net host ns cidr
    used=""
    if [[ -d "$BASE_DIR" ]]; then
        used=$(grep -Rhs '^NS_CIDR=' "$BASE_DIR"/*/*.cfg 2>/dev/null |
               sed -E 's/^NS_CIDR="?([^" ]+)"?.*/\1/' || true)
    fi

    for ((idx=1; idx<16384; idx++)); do
        offset=$((idx * 4))
        o3=$((offset / 256))
        o4=$((offset % 256))
        net="10.240.${o3}.${o4}"
        cidr="${net}/30"
        if ! grep -Fxq "$cidr" <<<"$used"; then
            host="10.240.${o3}.$((o4 + 1))/30"
            ns="10.240.${o3}.$((o4 + 2))/30"
            printf '%s|%s|%s\n' "$cidr" "$host" "$ns"
            return 0
        fi
    done
    die "No free /30 subnet remains in 10.240.0.0/16."
}

make_veth_names() {
    local app=$1 crc hex
    crc=$(printf '%s' "$app" | cksum | awk '{print $1}')
    printf -v hex '%08x' "$crc"
    printf 'nh%s|nn%s\n' "$hex" "$hex"
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
Cmnd_Alias $alias = $ENGINE_PATH list, $ENGINE_PATH start $app, $ENGINE_PATH start -i $app, $ENGINE_PATH start --ignore-start-error $app, $ENGINE_PATH start $app --via *, $ENGINE_PATH start -i $app --via *, $ENGINE_PATH start --ignore-start-error $app --via *, $ENGINE_PATH stop $app, $ENGINE_PATH run $app *
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
    if [[ "$via_setting" != __default__ ]]; then
        normalized_via=$(normalize_via "$app" "$via_setting")
    fi

    ensure_dependencies
    install_engine_files
    install -d -o root -g root -m 0755         "$BASE_DIR" "$RUN_DIR" "$CACHE_DIR" "$STATE_DIR"

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
# NNS application settings. Edit with: sudoedit $file
APP_NAME="$app"
APP_USER="$user"
DEFAULT_PROFILE=""
# Empty for a new app; set automatically to openvpn or wireguard by `add`.
VPN_TYPE=""

# on: application traffic cannot fall back to the host uplink.
# off: direct fallback through the host uplink is allowed.
KILLSWITCH="on"

# Enable/disable automatic startup at boot.
AUTOSTART="off"

# Empty/host: connect this namespace directly through the host uplink.
# An app name: connect through that app's active VPN namespace.
UPSTREAM_APP="${normalized_via#host}"

# Used only when UPSTREAM_APP is empty. auto follows the host IPv4 default route.
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

# Allocated internal namespace network. Do not copy these values to another app.
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

    log "Installed NNS app '$app'."
    log "Config:   $file"
    log "Profiles: $(profiles_dir "$app")"
    log "Upstream: ${normalized_via:-host}"
    log "Next:     sudo $USER_PATH add $app /path/to/profile.ovpn"
    log "          or: sudo $USER_PATH add $app /path/to/wireguard.conf"
    log "          or: sudo $USER_PATH add $app any [country]${normalized_via:+ --via $normalized_via}"
}

profile_type_from_file() {
    local file=$1
    [[ -f "$file" && -s "$file" ]] || return 1

    if grep -Eiq '^[[:space:]]*\[Interface\][[:space:]]*(#.*)?$' "$file" &&
       grep -Eiq '^[[:space:]]*\[Peer\][[:space:]]*(#.*)?$' "$file"; then
        printf 'wireguard\n'
    elif grep -Eiq '^[[:space:]]*remote[[:space:]]+' "$file"; then
        printf 'openvpn\n'
    else
        return 1
    fi
}

vpn_type_for_app() {
    local app=$1 configured profile file detected
    configured=$(cfg_read_value "$app" VPN_TYPE 2>/dev/null || true)
    case "$configured" in
        openvpn|wireguard)
            printf '%s\n' "$configured"
            return 0
            ;;
        "") ;;
        *) die "Unsupported VPN_TYPE '$configured' in $(cfg_file "$app")." ;;
    esac

    profile=$(cfg_read_value "$app" DEFAULT_PROFILE 2>/dev/null || true)
    [[ -n "$profile" ]] || return 1
    file="$(profiles_dir "$app")/$profile"
    detected=$(profile_type_from_file "$file" 2>/dev/null || true)
    [[ -n "$detected" ]] || return 1
    printf '%s\n' "$detected"
}

vpn_type_label() {
    case "$1" in
        openvpn) printf 'OpenVPN\n' ;;
        wireguard) printf 'WireGuard\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

wireguard_iface_name() {
    local app=$1 crc hex
    crc=$(printf '%s' "$app" | cksum | awk '{print $1}')
    printf -v hex '%08x' "$crc"
    printf 'nwg%s\n' "$hex"
}

wireguard_runtime_config_path() {
    local app=$1 iface
    iface=$(wireguard_iface_name "$app")
    printf '%s/%s.conf\n' "$RUN_DIR" "$iface"
}

profile_name_from_path() {
    local source=$1 type=$2 base name suffix
    base=$(basename "$source")
    name=${base%.*}
    name=$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+//; s/_+$//')
    [[ -n "$name" ]] || name="profile"
    case "$type" in
        openvpn) suffix=ovpn ;;
        wireguard) suffix=conf ;;
        *) die "Unsupported VPN profile type '$type'." ;;
    esac
    printf '%.64s.%s\n' "$name" "$suffix"
}

validate_wireguard() {
    local file=$1
    [[ -f "$file" ]] || die "Profile not found: $file"
    [[ -s "$file" ]] || die "Profile is empty: $file"
    (( $(stat -c '%s' "$file") <= 1048576 )) ||
        die "WireGuard profile is unexpectedly large (>1 MiB)."

    if ! python3 - "$file" <<'PY_WG_VALIDATE'
import base64
import binascii
import ipaddress
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n").decode("utf-8")

allowed_interface = {
    "privatekey", "address", "dns", "mtu", "table", "listenport", "fwmark"
}
allowed_peer = {
    "publickey", "presharedkey", "allowedips", "endpoint", "persistentkeepalive"
}
forbidden = {"preup", "postup", "predown", "postdown", "saveconfig"}

section = None
interface_count = 0
peer_count = 0
private_keys = []
ipv4_addresses = []
allowed_networks = []
endpoint_count = 0
peer_public = False
peer_allowed = False


def fail(line_no, message):
    raise SystemExit(f"line {line_no}: {message}")


def validate_key(value, line_no, field):
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        fail(line_no, f"{field} is not valid base64")
    if len(decoded) != 32:
        fail(line_no, f"{field} must decode to exactly 32 bytes")


def finish_peer(line_no):
    global peer_public, peer_allowed
    if section == "peer":
        if not peer_public:
            fail(line_no, "[Peer] is missing PublicKey")
        if not peer_allowed:
            fail(line_no, "[Peer] is missing AllowedIPs")
    peer_public = False
    peer_allowed = False


lines = text.splitlines()
for line_no, raw in enumerate(lines, 1):
    stripped = raw.strip()
    if not stripped or stripped.startswith("#"):
        continue

    section_match = re.fullmatch(r"\[\s*([^\]]+)\s*\](?:\s*#.*)?", stripped)
    if section_match:
        finish_peer(line_no)
        name = section_match.group(1).strip().casefold()
        if name == "interface":
            interface_count += 1
            if interface_count != 1 or peer_count:
                fail(line_no, "exactly one [Interface] must appear before all [Peer] sections")
            section = "interface"
        elif name == "peer":
            if interface_count != 1:
                fail(line_no, "[Peer] appears before [Interface]")
            peer_count += 1
            section = "peer"
        else:
            fail(line_no, f"unsupported section [{section_match.group(1)}]")
        continue

    if section is None:
        fail(line_no, "setting appears outside a section")
    if "=" not in raw:
        fail(line_no, "expected Key = Value")

    key_raw, value_raw = raw.split("=", 1)
    key = key_raw.strip().casefold()
    value = value_raw.split("#", 1)[0].strip()
    if not key or not value:
        fail(line_no, "empty key or value")
    if key in forbidden:
        fail(line_no, f"unsafe or state-changing option '{key_raw.strip()}' is not supported")

    allowed = allowed_interface if section == "interface" else allowed_peer
    if key not in allowed:
        fail(line_no, f"unsupported {section} option '{key_raw.strip()}'")

    if section == "interface":
        if key == "privatekey":
            validate_key(value, line_no, "PrivateKey")
            private_keys.append(value)
        elif key == "address":
            for item in value.split(","):
                try:
                    interface = ipaddress.ip_interface(item.strip())
                except ValueError as exc:
                    fail(line_no, f"invalid Address: {exc}")
                if interface.version == 4:
                    ipv4_addresses.append(interface)
        elif key == "dns":
            # Accepted at import, but ignored at runtime; nns-app owns resolv.conf.
            pass
        elif key == "mtu":
            if not value.isdigit() or not 576 <= int(value) <= 9000:
                fail(line_no, "MTU must be an integer from 576 through 9000")
        elif key == "table":
            if value.casefold() != "auto":
                fail(line_no, "only Table = auto (or no Table setting) is supported")
        elif key == "listenport":
            if not value.isdigit() or not 1 <= int(value) <= 65535:
                fail(line_no, "ListenPort must be from 1 through 65535")
    else:
        if key == "publickey":
            validate_key(value, line_no, "PublicKey")
            peer_public = True
        elif key == "presharedkey":
            validate_key(value, line_no, "PresharedKey")
        elif key == "allowedips":
            networks = []
            for item in value.split(","):
                try:
                    network = ipaddress.ip_network(item.strip(), strict=False)
                except ValueError as exc:
                    fail(line_no, f"invalid AllowedIPs: {exc}")
                networks.append(network)
                if network.version == 4:
                    allowed_networks.append(network)
            if not networks:
                fail(line_no, "AllowedIPs is empty")
            peer_allowed = True
        elif key == "endpoint":
            endpoint_count += 1
            if value.startswith("["):
                fail(line_no, "IPv6 WireGuard endpoints are not supported by this IPv4 NNS release")
            if ":" not in value:
                fail(line_no, "Endpoint must be host:port")
            host, port = value.rsplit(":", 1)
            if not re.fullmatch(r"[A-Za-z0-9.-]+", host) or not host:
                fail(line_no, "Endpoint host is invalid")
            if not port.isdigit() or not 1 <= int(port) <= 65535:
                fail(line_no, "Endpoint port must be from 1 through 65535")
        elif key == "persistentkeepalive":
            if not value.isdigit() or not 0 <= int(value) <= 65535:
                fail(line_no, "PersistentKeepalive must be from 0 through 65535")

finish_peer(len(lines) + 1)

if interface_count != 1:
    raise SystemExit("profile must contain exactly one [Interface]")
if len(private_keys) != 1:
    raise SystemExit("[Interface] must contain exactly one PrivateKey")
if not ipv4_addresses:
    raise SystemExit("[Interface] must contain at least one IPv4 Address")
if peer_count < 1:
    raise SystemExit("profile must contain at least one [Peer]")
if endpoint_count < 1:
    raise SystemExit("profile must contain at least one IPv4/hostname Endpoint")

full_default = ipaddress.ip_network("0.0.0.0/0") in allowed_networks
split_default = (
    ipaddress.ip_network("0.0.0.0/1") in allowed_networks
    and ipaddress.ip_network("128.0.0.0/1") in allowed_networks
)
if not (full_default or split_default):
    raise SystemExit(
        "nns-app currently requires a full-tunnel IPv4 WireGuard profile "
        "(0.0.0.0/0 or both /1 halves in AllowedIPs)"
    )
PY_WG_VALIDATE
    then
        die "WireGuard profile validation failed."
    fi
}

prepare_wireguard_runtime_config() {
    local source=$1 target=$2 disable_ipv6=${3:-on}
    python3 - "$source" "$target" "$disable_ipv6" <<'PY_WG_RUNTIME'
import ipaddress
import re
import sys
from pathlib import Path

source = Path(sys.argv[1])
target = Path(sys.argv[2])
disable_ipv6 = sys.argv[3].casefold() in {"1", "yes", "true", "on", "enabled"}
text = source.read_bytes().replace(b"\r\n", b"\n").replace(b"\r", b"\n").decode("utf-8")

out = [
    "# Runtime WireGuard profile generated by nns-app.",
    "# DNS is managed by /etc/netns/<namespace>/resolv.conf.",
]

for raw in text.splitlines():
    stripped = raw.strip()
    if not stripped or stripped.startswith("#") or stripped.startswith("["):
        out.append(raw)
        continue
    if "=" not in raw:
        out.append(raw)
        continue

    key_raw, value_raw = raw.split("=", 1)
    key = key_raw.strip().casefold()
    value = value_raw.split("#", 1)[0].strip()

    if key in {"preup", "postup", "predown", "postdown", "saveconfig"}:
        raise SystemExit(f"unsafe WireGuard option reached runtime: {key_raw.strip()}")
    if key == "dns":
        continue
    if key == "table" and value.casefold() == "auto":
        # auto is wg-quick's default.
        continue

    if disable_ipv6 and key in {"address", "allowedips"}:
        kept = []
        for item in value.split(","):
            token = item.strip()
            if not token:
                continue
            try:
                parsed = ipaddress.ip_interface(token) if key == "address" else ipaddress.ip_network(token, strict=False)
            except ValueError:
                kept.append(token)
                continue
            if parsed.version == 4:
                kept.append(token)
        if not kept:
            continue
        out.append(f"{key_raw.strip()} = {', '.join(kept)}")
        continue

    out.append(raw)

target.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
target.chmod(0o600)
PY_WG_RUNTIME
}

validate_ovpn() {
    local file=$1
    [[ -f "$file" ]] || die "Profile not found: $file"
    [[ -s "$file" ]] || die "Profile is empty: $file"
    (( $(stat -c '%s' "$file") <= 5242880 )) || die "Profile is unexpectedly large (>5 MiB)."

    grep -Eiq '^[[:space:]]*remote[[:space:]]+' "$file" ||
        die "Profile has no 'remote' directive."
    ! grep -Eiq '^[[:space:]]*<connection>[[:space:]]*$' "$file" ||
        die "Profiles with <connection> blocks are not supported."

    if ! awk '
        BEGIN { inblock=0; bad=0 }
        /^[[:space:]]*<[^/][^>]*>[[:space:]]*$/ { inblock=1; next }
        /^[[:space:]]*<\/[A-Za-z0-9_-]+>[[:space:]]*$/ { inblock=0; next }
        inblock { next }
        /^[[:space:]]*[#;]/ { next }
        {
            key=tolower($1)
            if (key ~ /^(up|down|route-up|route-pre-down|ipchange|learn-address|client-connect|client-disconnect|auth-user-pass-verify|tls-verify|tls-crypt-v2-verify|plugin|script-security|iproute|config|daemon|writepid|chroot|cd|user|group|log|log-append|status|status-version|pkcs11-providers|pkcs11-id|cryptoapicert|engine)$/ || key ~ /^management/) {
                print "unsafe directive: " $0 > "/dev/stderr"
                bad=1
            }
            if (key == "dev" && tolower($2) ~ /^tap/) {
                print "TAP profiles are unsupported: " $0 > "/dev/stderr"
                bad=1
            }
            if (key == "dev-type" && tolower($2) == "tap") {
                print "TAP profiles are unsupported: " $0 > "/dev/stderr"
                bad=1
            }
        }
        END { exit bad }
    ' "$file"; then
        die "Profile contains unsupported or unsafe directives."
    fi

    # Require key/certificate material to be embedded. This avoids missing sidecar
    # files and prevents a profile from making root read arbitrary host files.
    if ! awk '
        BEGIN { inblock=0; bad=0 }
        /^[[:space:]]*<[^/][^>]*>[[:space:]]*$/ { inblock=1; next }
        /^[[:space:]]*<\/[A-Za-z0-9_-]+>[[:space:]]*$/ { inblock=0; next }
        inblock { next }
        /^[[:space:]]*[#;]/ { next }
        {
            key=tolower($1)
            if (key ~ /^(ca|cert|key|pkcs12|tls-auth|tls-crypt|tls-crypt-v2|crl-verify|askpass|auth-user-pass)$/) {
                if (NF == 1 || $2 != "[inline]") {
                    print "external or interactive credential directive: " $0 > "/dev/stderr"
                    bad=1
                }
            }
        }
        END { exit bad }
    ' "$file"; then
        die "Use a self-contained .ovpn profile with inline keys/certificates and no interactive password prompt."
    fi
}

ovpn_has_directive() {
    local file=$1 key=${2,,}
    awk -v wanted="$key" '
        BEGIN { inblock=0; found=0 }
        /^[[:space:]]*<[^/][^>]*>[[:space:]]*$/ { inblock=1; next }
        /^[[:space:]]*<\/[A-Za-z0-9_-]+>[[:space:]]*$/ { inblock=0; next }
        inblock { next }
        /^[[:space:]]*[#;]/ { next }
        tolower($1) == wanted { found=1; exit }
        END { exit !found }
    ' "$file"
}

ovpn_first_directive_value() {
    local file=$1 key=${2,,}
    awk -v wanted="$key" '
        BEGIN { inblock=0 }
        /^[[:space:]]*<[^/][^>]*>[[:space:]]*$/ { inblock=1; next }
        /^[[:space:]]*<\/[A-Za-z0-9_-]+>[[:space:]]*$/ { inblock=0; next }
        inblock { next }
        /^[[:space:]]*[#;]/ { next }
        tolower($1) == wanted {
            value=$2
            gsub(/^"|"$/, "", value)
            print value
            exit
        }
    ' "$file"
}

ovpn_replace_or_append_directive() {
    local file=$1 key=$2 rendered=$3 tmp
    tmp=$(mktemp)

    awk -v wanted="${key,,}" -v replacement="$rendered" '
        BEGIN { inblock=0; done=0 }
        /^[[:space:]]*<[^/][^>]*>[[:space:]]*$/ {
            inblock=1
            print
            next
        }
        /^[[:space:]]*<\/[A-Za-z0-9_-]+>[[:space:]]*$/ {
            inblock=0
            print
            next
        }
        !inblock && $0 !~ /^[[:space:]]*[#;]/ && tolower($1) == wanted {
            if (!done) {
                print replacement
                done=1
            }
            next
        }
        { print }
        END {
            if (!done) {
                print ""
                print replacement
            }
        }
    ' "$file" >"$tmp"

    cat "$tmp" >"$file"
    rm -f "$tmp"
}

ovpn_contains_weak_certificate() {
    local file=$1 certdir cert found=1
    certdir=$(mktemp -d)

    awk -v dir="$certdir" '
        /-----BEGIN CERTIFICATE-----/ {
            n++
            out=sprintf("%s/cert-%03d.pem", dir, n)
            incert=1
        }
        incert { print >out }
        /-----END CERTIFICATE-----/ {
            if (incert) close(out)
            incert=0
        }
    ' "$file"

    shopt -s nullglob
    for cert in "$certdir"/*.pem; do
        if openssl x509 -in "$cert" -noout -text 2>/dev/null |
           grep -Eiq 'Signature Algorithm:[[:space:]]*(md5|sha1)'; then
            found=0
            break
        fi
    done
    shopt -u nullglob
    rm -rf "$certdir"
    return "$found"
}

apply_profile_fixups() {
    local file=$1
    local -n applied_ref=$2
    local cipher

    # DCO has shown unreliable restart/data-path behavior with this namespace
    # engine on Ubuntu 26.04. Keep the provider's original file untouched and
    # disable DCO only in the managed copy.
    if ! ovpn_has_directive "$file" disable-dco; then
        ovpn_replace_or_append_directive "$file" disable-dco "disable-dco"
        applied_ref+=("disable-dco")
    fi

    # OpenSSL 3 rejects SHA-1/MD5-signed legacy client or CA certificates at
    # the default security level. Add the narrow OpenVPN compatibility switch
    # only when the embedded certificate chain actually needs it.
    if ovpn_contains_weak_certificate "$file"; then
        ovpn_replace_or_append_directive \
            "$file" tls-cert-profile "tls-cert-profile insecure"
        applied_ref+=("tls-cert-profile insecure (legacy certificate chain)")
    fi

    # OpenVPN 2.7 ignores a legacy --cipher value for negotiation unless it is
    # also present in --data-ciphers. Preserve modern defaults and add only the
    # detected CBC cipher as a fallback.
    if ! ovpn_has_directive "$file" data-ciphers; then
        cipher=$(ovpn_first_directive_value "$file" cipher || true)
        case "${cipher^^}" in
            AES-128-CBC|AES-192-CBC|AES-256-CBC)
                ovpn_replace_or_append_directive \
                    "$file" data-ciphers "data-ciphers DEFAULT:${cipher^^}"
                applied_ref+=("data-ciphers DEFAULT:${cipher^^}")
                ;;
        esac
    fi
}

add_profile() {
    require_root
    local app=$1 src=$2
    validate_app_name "$app"
    load_cfg "$app"

    src=$(readlink -f "$src")
    local type
    type=$(profile_type_from_file "$src" 2>/dev/null || true)
    [[ -n "$type" ]] ||
        die "Cannot identify '$src' as an OpenVPN or WireGuard profile."

    case "$type" in
        openvpn) validate_ovpn "$src" ;;
        wireguard) validate_wireguard "$src" ;;
        *) die "Unsupported VPN profile type '$type'." ;;
    esac

    local name dest tmp
    local -a applied=()
    name=$(profile_name_from_path "$src" "$type")
    dest="$(profiles_dir "$app")/$name"
    tmp=$(mktemp)

    # Never alter the user's source profile. Normalize line endings and apply
    # backend-specific processing only to the root-owned managed copy.
    cat "$src" >"$tmp"
    sed -i 's/\r$//' "$tmp"

    case "$type" in
        openvpn)
            validate_ovpn "$tmp"
            if bool_on "${PROFILE_FIXUPS:-on}"; then
                apply_profile_fixups "$tmp" applied
            fi
            ;;
        wireguard)
            validate_wireguard "$tmp"
            ;;
    esac

    install -o root -g root -m 0600 "$tmp" "$dest"
    rm -f "$tmp"
    cfg_set "$app" DEFAULT_PROFILE "$name"
    cfg_set "$app" VPN_TYPE "$type"

    log "Added $(vpn_type_label "$type") profile '$name' to '$app'."
    if [[ "$type" == openvpn ]]; then
        if (( ${#applied[@]} )); then
            log "Applied managed-profile compatibility fixes:"
            local fix
            for fix in "${applied[@]}"; do
                log "  - $fix"
            done
        elif bool_on "${PROFILE_FIXUPS:-on}"; then
            log "No compatibility fixes were needed."
        else
            log "OpenVPN profile fixups are disabled in $(cfg_file "$app")."
        fi
    elif grep -Eiq '^[[:space:]]*DNS[[:space:]]*=' "$dest"; then
        log "WireGuard DNS setting will be ignored at runtime; namespace DNS_SERVERS remains authoritative."
    fi

    log "Default profile is now '$name' ($(vpn_type_label "$type"))."
    if systemctl is-active --quiet "nns-openvpn@${app}.service"; then
        warn "'$app' is currently running. Stop and start it to switch profiles/backends."
    fi
}


add_any_profile() {
    require_root
    local app=$1 country=${2:-} force_refresh=${3:-off} via_override=${4:-__default__}
    validate_app_name "$app"
    load_cfg "$app"

    command -v curl >/dev/null 2>&1 || die "curl is required. Refresh the installation with: nns-app install $app"
    command -v python3 >/dev/null 2>&1 || die "python3 is required. Refresh the installation with: nns-app install $app"

    local tmpdir csv_file selected metadata
    local now mtime age cache_tmp use_cache="off"
    local state_key state_file probe_via probe_ns="host" current_app=""
    local -a path_prefix=()
    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir:-}" "${cache_tmp:-}"' EXIT

    install -d -o root -g root -m 0755 "$CACHE_DIR" "$STATE_DIR"

    if [[ "$via_override" != __default__ ]]; then
        probe_via=$(normalize_via "$app" "$via_override")
    else
        probe_via=$(effective_via_for_app "$app" __default__)
        if [[ "$probe_via" == host ]]; then
            current_app=$(current_nns_app 2>/dev/null || true)
            if [[ -n "$current_app" && "$current_app" != "$app" ]]; then
                probe_via=$current_app
            fi
        fi
    fi

    if [[ "$probe_via" != host ]]; then
        local upstream_data
        upstream_data=$(ensure_upstream_ready "$app" "$probe_via")
        probe_ns=${upstream_data%%|*}
        path_prefix=(/usr/sbin/ip netns exec "$probe_ns")
    fi

    state_key=$(printf '%s' "${country:-ANY}" |
        tr '[:lower:]' '[:upper:]' |
        tr -c 'A-Z0-9._-' '_')
    state_file="$STATE_DIR/vpngate-${app}-${state_key}.last"
    csv_file="$VPNGATE_CACHE_FILE"
    now=$(date +%s)

    if [[ -s "$VPNGATE_CACHE_FILE" ]] && ! bool_on "$force_refresh"; then
        mtime=$(stat -c %Y "$VPNGATE_CACHE_FILE" 2>/dev/null || printf '0')
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        age=$((now - mtime))
        if (( age >= 0 && age <= VPNGATE_CACHE_TTL )); then
            use_cache="on"
            log "Using cached VPN Gate relay list (age $(format_duration "$age"); TTL $(format_duration "$VPNGATE_CACHE_TTL"))."
        fi
    fi

    if ! bool_on "$use_cache"; then
        log "Downloading the VPN Gate public relay list${country:+ for '$country'}..."
        cache_tmp=$(mktemp "$CACHE_DIR/.vpngate.csv.XXXXXX")

        if "${path_prefix[@]}" curl --fail --silent --show-error --location --compressed \
            --connect-timeout 5 --max-time 45 \
            --retry 2 --retry-delay 1 --retry-all-errors \
            --user-agent "nns-app/${VERSION}" \
            "$VPNGATE_API_URL" -o "$cache_tmp" &&
           grep -q '^#HostName,' "$cache_tmp"; then
            chmod 0644 "$cache_tmp"
            chown root:root "$cache_tmp"
            mv -f "$cache_tmp" "$VPNGATE_CACHE_FILE"
            cache_tmp=""
            log "Updated VPN Gate cache: $VPNGATE_CACHE_FILE"
        elif [[ -s "$VPNGATE_CACHE_FILE" ]]; then
            rm -f "$cache_tmp"
            cache_tmp=""
            mtime=$(stat -c %Y "$VPNGATE_CACHE_FILE" 2>/dev/null || printf '0')
            [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
            age=$((now - mtime))
            warn "Could not refresh the VPN Gate list; using stale cache (age $(format_duration "$age"))."
        else
            rm -f "$cache_tmp"
            cache_tmp=""
            die "Could not download the VPN Gate server list and no cached copy is available."
        fi
    fi

    [[ -s "$csv_file" ]] || die "VPN Gate cache is empty: $csv_file"
    log "Searching VPN Gate candidates${country:+ for '$country'}..."

    metadata=$(python3 - \
        "$csv_file" "$tmpdir" "$country" "$state_file" \
        "$VPNGATE_PROBE_TIMEOUT" "$VPNGATE_PROBE_ATTEMPTS" \
        "$probe_ns" "$probe_via" <<'PY_SELECT'
import base64
import csv
import io
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

csv_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
country_filter = sys.argv[3].strip().casefold()
state_path = Path(sys.argv[4])
probe_timeout = max(1.0, float(sys.argv[5]))
probe_attempts = max(1, int(sys.argv[6]))
probe_namespace = sys.argv[7]
probe_label = sys.argv[8]

raw = csv_path.read_text(encoding="utf-8-sig", errors="replace")
lines = [line for line in raw.splitlines() if line and not line.startswith("*")]
if not lines:
    raise SystemExit("VPN Gate returned no CSV records")

reader = csv.reader(io.StringIO("\n".join(lines)))
try:
    header = next(reader)
except StopIteration:
    raise SystemExit("VPN Gate returned an empty CSV document")

header = [field.strip() for field in header]
header[0] = header[0].lstrip("#")
index = {name: i for i, name in enumerate(header)}
required = {
    "HostName", "IP", "Score", "Ping", "Speed", "CountryLong",
    "CountryShort", "NumVpnSessions", "Uptime",
    "OpenVPN_ConfigData_Base64",
}
missing = sorted(required - index.keys())
if missing:
    raise SystemExit("VPN Gate CSV lacks fields: " + ", ".join(missing))

def get(row, name, default=""):
    pos = index[name]
    return row[pos].strip() if pos < len(row) else default

def number(value, default=0):
    try:
        return int(value)
    except (TypeError, ValueError):
        return default

def country_matches(short_name, long_name):
    if not country_filter:
        return True

    short_cf = short_name.casefold()
    long_cf = long_name.casefold()

    # A two-letter value is a country code and must match CountryShort exactly.
    # The old substring rule made "US" match "Russian Federation" because
    # "russian" contains the letters "us".
    if re.fullmatch(r"[a-z]{2}", country_filter):
        return country_filter == short_cf

    # Longer values are treated as country-name filters.
    return (
        country_filter == short_cf
        or country_filter == long_cf
        or country_filter in long_cf
    )

def looks_usable(config):
    text = config.decode("utf-8", errors="replace")
    if not re.search(r"(?im)^\s*remote\s+\S+", text):
        return False
    if re.search(r"(?im)^\s*(dev\s+tap|dev-type\s+tap)\b", text):
        return False
    if re.search(r"(?im)^\s*(?:up|down|route-up|route-pre-down|plugin|script-security|management\S*)\b", text):
        return False
    if re.search(r"(?im)^\s*auth-user-pass(?:\s+(?!\[inline\])\S+)?\s*$", text):
        return False
    return True

def normalize_proto(value):
    value = value.strip().casefold()
    if value.startswith("tcp"):
        return "tcp"
    if value.startswith("udp"):
        return "udp"
    return value

def first_endpoint(config):
    text = config.decode("utf-8", errors="replace")
    proto = "udp"
    default_port = 1194

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue

        parts = line.split()
        key = parts[0].casefold()

        if key == "proto" and len(parts) >= 2:
            proto = normalize_proto(parts[1])
            continue

        if key == "port" and len(parts) >= 2:
            try:
                default_port = int(parts[1])
            except ValueError:
                pass
            continue

        if key == "remote" and len(parts) >= 2:
            host = parts[1].strip('"')
            port = default_port
            remote_proto = proto

            if len(parts) >= 3:
                try:
                    port = int(parts[2])
                except ValueError:
                    return None

            if len(parts) >= 4:
                remote_proto = normalize_proto(parts[3])

            if not (1 <= port <= 65535):
                return None
            if remote_proto not in {"tcp", "udp"}:
                return None

            return host, port, remote_proto

    return None

def probe_compatible_config(config):
    text = config.decode("utf-8", errors="replace")
    additions = []

    if not re.search(r"(?im)^\s*disable-dco(?:\s|$)", text):
        additions.append("disable-dco")

    # The public VPN Gate pool still contains SHA-1-era certificate chains.
    # This mirrors the managed-profile compatibility fix used after import.
    if not re.search(r"(?im)^\s*tls-cert-profile(?:\s|$)", text):
        additions.append("tls-cert-profile insecure")

    if not re.search(r"(?im)^\s*data-ciphers(?:\s|$)", text):
        match = re.search(
            r"(?im)^\s*cipher\s+(AES-(?:128|192|256)-CBC)\s*$",
            text,
        )
        if match:
            additions.append(f"data-ciphers DEFAULT:{match.group(1).upper()}")

    if additions:
        text = text.rstrip() + "\n\n" + "\n".join(additions) + "\n"

    return text.encode("utf-8")

def classify_probe_log(log_text, endpoint):
    lower = log_text.casefold()
    _, _, proto = endpoint

    if "auth_failed" in lower:
        return "authentication rejected"
    if "certificate verification failed" in lower:
        return "certificate verification failed"
    if "connection refused" in lower:
        return "connection refused"
    if "network is unreachable" in lower or "no route to host" in lower:
        return "network unreachable"
    if "tls error" in lower or "tls key negotiation failed" in lower:
        return "TLS negotiation failed"
    if "options error" in lower:
        return "OpenVPN configuration rejected"
    if "tcp connection established" in lower:
        return "TCP connected, but OpenVPN handshake timed out"
    if proto == "tcp":
        return "TCP connection timed out"
    return "UDP/OpenVPN handshake timed out"

def terminate_process(proc):
    if proc.poll() is not None:
        return
    proc.terminate()
    try:
        proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=1)

def quick_openvpn_probe(config, endpoint, candidate_number):
    openvpn = shutil.which("openvpn") or "/usr/sbin/openvpn"
    if not Path(openvpn).is_file():
        return False, "OpenVPN executable is unavailable", 0.0

    probe_config = out_dir / f".probe-{os.getpid()}-{candidate_number}.ovpn"
    probe_log = out_dir / f".probe-{os.getpid()}-{candidate_number}.log"
    device = f"np{os.getpid():x}{candidate_number:x}"[:15]

    probe_config.write_bytes(probe_compatible_config(config))
    os.chmod(probe_config, 0o600)

    command = [
        openvpn,
        "--config", str(probe_config),
        "--dev", device,
        "--dev-type", "tun",
        "--route-nopull",
        "--route-noexec",
        "--ifconfig-noexec",
        "--connect-retry-max", "1",
        "--server-poll-timeout", str(max(1, int(probe_timeout))),
        "--resolv-retry", "0",
        "--nobind",
        "--auth-nocache",
        "--disable-dco",
        "--verb", "3",
        "--log", str(probe_log),
    ]

    if probe_namespace != "host":
        command = [
            "/usr/sbin/ip", "netns", "exec", probe_namespace,
        ] + command

    started = time.monotonic()
    proc = None
    success = False

    try:
        proc = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            close_fds=True,
        )

        deadline = started + probe_timeout
        while time.monotonic() < deadline:
            if probe_log.exists():
                log_text = probe_log.read_text(
                    encoding="utf-8",
                    errors="replace",
                )
                if (
                    "Peer Connection Initiated" in log_text
                    or "Initialization Sequence Completed" in log_text
                ):
                    success = True
                    break

            if proc.poll() is not None:
                break

            time.sleep(0.1)
    except OSError as exc:
        return False, f"could not start OpenVPN probe: {exc}", 0.0
    finally:
        if proc is not None:
            terminate_process(proc)

    elapsed = time.monotonic() - started
    try:
        log_text = probe_log.read_text(encoding="utf-8", errors="replace")
    except OSError:
        log_text = ""

    for path in (probe_config, probe_log):
        try:
            path.unlink()
        except OSError:
            pass

    if success:
        return True, "OpenVPN peer connection established", elapsed

    return False, classify_probe_log(log_text, endpoint), elapsed

candidates = []
for row in reader:
    if not row or len(row) < len(header):
        continue

    short_name = get(row, "CountryShort").upper()
    long_name = get(row, "CountryLong")
    if not country_matches(short_name, long_name):
        continue

    encoded = "".join(get(row, "OpenVPN_ConfigData_Base64").split())
    if not encoded:
        continue
    try:
        config = base64.b64decode(encoded, validate=True)
    except Exception:
        continue

    # VPN Gate commonly embeds Windows-style CRLF profiles. Store a canonical
    # LF-only profile so shell/awk/iptables consumers never receive values such
    # as "tcp\\r" or "1598\\r".
    config = config.replace(b"\r\n", b"\n").replace(b"\r", b"\n")

    if not config or len(config) > 5 * 1024 * 1024 or not looks_usable(config):
        continue

    score = number(get(row, "Score"))
    ping = number(get(row, "Ping"), 999999)
    speed = number(get(row, "Speed"))
    uptime = number(get(row, "Uptime"))
    sessions = number(get(row, "NumVpnSessions"))

    # Prefer the service's own score, then measured speed and uptime. Unknown
    # ping values rank below measured ones. Host/IP are stable tie-breakers so
    # the round-robin order remains deterministic for a cached server list.
    rank = (
        score,
        speed,
        uptime,
        -sessions,
        -(ping if ping > 0 else 999999),
        get(row, "HostName"),
        get(row, "IP"),
    )
    candidates.append((rank, row, config))

if not candidates:
    label = sys.argv[3] or "any country"
    raise SystemExit(f"No usable VPN Gate OpenVPN profile found for {label}")

# Rotate through the strongest candidates. A persistent last-relay marker makes
# repeated `add ... any` calls select the next relay instead of repeatedly
# returning the same highest-scoring profile. The top 20 cap avoids rotating
# into very low-quality entries when a country has a large server list.
candidates.sort(key=lambda item: item[0], reverse=True)
pool = candidates[: min(20, len(candidates))]

try:
    last_relay = state_path.read_text(encoding="utf-8").strip()
except OSError:
    last_relay = ""

start_index = 0
if last_relay:
    for i, (_, candidate_row, _) in enumerate(pool):
        relay_id = f"{get(candidate_row, 'HostName')}|{get(candidate_row, 'IP')}"
        if relay_id == last_relay:
            start_index = (i + 1) % len(pool)
            break

ordered_indexes = [
    (start_index + offset) % len(pool)
    for offset in range(len(pool))
]

selected_index = None
row = None
config = None
tested = 0
probe_note = ""

print(
    f"Candidate pool: {len(pool)} usable matching relay(s).",
    file=sys.stderr,
    flush=True,
)
print(
    f"Quick-checking up to {min(probe_attempts, len(pool))} candidate(s); "
    f"{probe_timeout:g}s each, via {probe_label}.",
    file=sys.stderr,
    flush=True,
)

last_tested_row = None

for pool_index in ordered_indexes[:probe_attempts]:
    _, candidate_row, candidate_config = pool[pool_index]
    last_tested_row = candidate_row
    endpoint = first_endpoint(candidate_config)
    candidate_host = get(candidate_row, "HostName")
    candidate_ip = get(candidate_row, "IP")

    if endpoint is None:
        print(
            f"  reject {candidate_host} ({candidate_ip}): invalid endpoint",
            file=sys.stderr,
            flush=True,
        )
        continue

    endpoint_host, endpoint_port, endpoint_proto = endpoint
    tested += 1
    print(
        f"  check {tested}: {candidate_host} ({candidate_ip}), "
        f"{endpoint_proto.upper()} {endpoint_host}:{endpoint_port} ...",
        file=sys.stderr,
        flush=True,
    )

    ok, reason, elapsed = quick_openvpn_probe(
        candidate_config,
        endpoint,
        tested,
    )

    if ok:
        print(
            f"    accepted: {reason} in {elapsed:.1f}s",
            file=sys.stderr,
            flush=True,
        )
        selected_index = pool_index
        row = candidate_row
        config = candidate_config
        probe_note = f"{reason} in {elapsed:.1f}s"
        break

    print(
        f"    rejected: {reason} ({elapsed:.1f}s)",
        file=sys.stderr,
        flush=True,
    )

if selected_index is None or row is None or config is None:
    # Advance round-robin state even after a failed batch, so a later call
    # continues with candidates that were not tested in this invocation.
    if last_tested_row is not None:
        failed_host = get(last_tested_row, "HostName")
        failed_ip = get(last_tested_row, "IP")
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_tmp = state_path.with_name(
            state_path.name + f".tmp.{os.getpid()}"
        )
        state_tmp.write_text(
            f"{failed_host}|{failed_ip}\n",
            encoding="utf-8",
        )
        os.chmod(state_tmp, 0o600)
        os.replace(state_tmp, state_path)

    raise SystemExit(
        "No candidate completed a quick OpenVPN handshake "
        f"(tested {tested} of {len(pool)}; "
        f"timeout {probe_timeout:g}s each)"
    )

host = get(row, "HostName")
ip = get(row, "IP")
short_name = get(row, "CountryShort").upper() or "XX"
long_name = get(row, "CountryLong") or "Unknown"
score = number(get(row, "Score"))
ping = number(get(row, "Ping"))
speed = number(get(row, "Speed"))
uptime = number(get(row, "Uptime"))
sessions = number(get(row, "NumVpnSessions"))

state_path.parent.mkdir(parents=True, exist_ok=True)
state_tmp = state_path.with_name(state_path.name + f".tmp.{os.getpid()}")
state_tmp.write_text(f"{host}|{ip}\n", encoding="utf-8")
os.chmod(state_tmp, 0o600)
os.replace(state_tmp, state_path)

safe_host = re.sub(r"[^A-Za-z0-9._-]+", "_", host).strip("_") or ip.replace(".", "_")
filename = f"vpngate_{short_name}_{safe_host}.ovpn"[:64]
if not filename.endswith(".ovpn"):
    filename = filename[:59] + ".ovpn"
path = out_dir / filename

comment = (
    "# Downloaded automatically by nns-app from the VPN Gate Academic "
    "Experiment public relay list.\n"
    f"# Relay: {host} ({ip}); country: {long_name} ({short_name}); "
    f"score: {score}; ping: {ping} ms; sessions: {sessions}.\n"
    "# This is a volunteer-operated public VPN relay. Do not assume privacy "
    "or no logging.\n\n"
).encode("utf-8")
path.write_bytes(comment + config)
os.chmod(path, 0o600)

speed_mbps = speed / 1_000_000 if speed > 0 else 0.0
uptime_minutes = uptime / 60_000 if uptime > 0 else 0.0
print(
    "\t".join(
        [
            str(path), short_name, long_name, host, ip, str(score),
            str(ping), f"{speed_mbps:.1f}", f"{uptime_minutes:.0f}",
            str(sessions), str(selected_index + 1), str(len(pool)),
            str(tested), probe_note,
        ]
    )
)
PY_SELECT
    ) || die "Could not select a usable free VPN profile."

    local rotation_index rotation_count probe_tested probe_note
    IFS=$'\t' read -r selected country_short country_long host ip score ping speed_mbps uptime_minutes sessions rotation_index rotation_count probe_tested probe_note <<<"$metadata"
    [[ -f "$selected" ]] || die "The VPN Gate selector did not produce a profile."

    local selected_endpoint selected_host selected_port selected_proto
    selected_endpoint=$(profile_endpoints "$selected" | head -n 1 || true)
    IFS='|' read -r selected_host selected_port selected_proto <<<"$selected_endpoint"

    log "Selected VPN Gate relay:"
    log "  Country:   $country_long ($country_short)"
    log "  Server:    $host ($ip)"
    if [[ -n "$selected_host" && -n "$selected_port" && -n "$selected_proto" ]]; then
        log "  Transport: ${selected_proto^^} $selected_host:$selected_port"
    fi
    log "  Quality:   score $score, ping ${ping:-unknown} ms, ${speed_mbps} Mbps"
    log "  Uptime:    ${uptime_minutes} min; active sessions: $sessions"
    log "  Rotation:  candidate ${rotation_index}/${rotation_count}"
    log "  Probe:     ${probe_note}; tested ${probe_tested} candidate(s) via $probe_via"
    warn "VPN Gate relays are operated by volunteers and may log traffic."
    warn "Use end-to-end encryption and do not treat this as a trusted privacy VPN."

    add_profile "$app" "$selected"
    if [[ "$probe_via" != host ]]; then
        log "Start this profile through the same path with: nns-app start $app --via $probe_via"
    fi
    rm -rf "$tmpdir"
    trap - EXIT
}


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

    # Capture the requested upstream before cleanup. A stale cleanup removes
    # the one-start override file, but this invocation must keep using it.
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
    [[ -n "$vpn_type" ]] || die "Cannot determine VPN backend for '$app'. Re-add its profile."
    if [[ "$vpn_type" == wireguard ]]; then
        tunnel_iface=$(wireguard_iface_name "$app")
    else
        tunnel_iface='tun+'
    fi
    [[ -n "$DEFAULT_PROFILE" && -f "$profile" ]] ||
        die "No usable default profile is configured for '$app'."

    install -d -o root -g root -m 0755 "$RUN_DIR"
    resolve_profile_endpoints "$profile" "$endpoints_file"         "${upstream_ns:-host}"
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

    # Keep the VPN control endpoint outside the inner tunnel. For a chained
    # app this route reaches the endpoint through the upstream VPN.
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

    # Namespace-local firewall. Before the inner tunnel exists only the VPN's
    # exact endpoint and root-owned DNS may leave over the veth uplink.
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
    rm -f "$runtime" "$RUN_DIR/${app}.via" "$RUN_DIR/${app}.profile"         "$RUN_DIR/${app}.type" "$RUN_DIR/${app}.endpoints"         "$(wireguard_runtime_config_path "$app")"
    log "Namespace '$NS_NAME' stopped."
}

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

    # Keep this process alive so the existing nns-openvpn@ service template
    # can manage both long-running OpenVPN and stateful wg-quick lifecycles.
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
        # stop_app may recursively stop downstream apps and load their configs.
        # Restore this app's settings before continuing the restart.
        load_cfg "$app"
    fi

    install -d -o root -g root -m 0755 "$RUN_DIR"
    printf '%s\n' "$desired_via" >"$RUN_DIR/${app}.via"
    chmod 0600 "$RUN_DIR/${app}.via"

    if bool_on "$AUTOSTART"; then
        if [[ "$via_override" != __default__ ]]; then
            warn "A one-start --via override is not persistent across boot; set UPSTREAM_APP in $(cfg_file "$app")."
        fi
        systemctl enable "nns-netns@${app}.service" "nns-openvpn@${app}.service" >/dev/null
    else
        systemctl disable "nns-netns@${app}.service" "nns-openvpn@${app}.service" >/dev/null 2>&1 || true
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
            stop_app "$child"
        fi
    done
}

stop_app() {
    require_root
    local app=$1
    validate_app_name "$app"
    load_cfg "$app"

    stop_dependents "$app"
    systemctl stop "nns-openvpn@${app}.service" 2>/dev/null || true
    systemctl stop "nns-netns@${app}.service" 2>/dev/null || true
    systemctl reset-failed "nns-openvpn@${app}.service" "nns-netns@${app}.service" 2>/dev/null || true
    rm -f "$RUN_DIR/${app}.profile" "$RUN_DIR/${app}.type" "$RUN_DIR/${app}.via"         "$(wireguard_runtime_config_path "$app")"
    log "Stopped '$app'."
}

remove_app() {
    require_root
    local app=$1
    validate_app_name "$app"
    load_cfg "$app"

    stop_app "$app"
    # stop_app may load a dependent app config while unwinding a chain.
    load_cfg "$app"
    systemctl disable "nns-openvpn@${app}.service" "nns-netns@${app}.service" >/dev/null 2>&1 || true
    rm -f "/etc/sudoers.d/nns-app-${app}"
    rm -rf "$(cfg_dir "$app")" "/etc/netns/$NS_NAME"
    rm -f "$RUN_DIR/${app}.env" "$RUN_DIR/${app}.profile" "$RUN_DIR/${app}.type"         "$RUN_DIR/${app}.via" "$(wireguard_runtime_config_path "$app")"
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

    # Stop VPN processes first, then namespaces. Do this app by app so that
    # systemd invokes the normal cleanup path while the engine and configs
    # still exist.
    for app in "${apps[@]}"; do
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
        \( -name 'nns-openvpn@*.service' -o -name 'nns-netns@*.service' \) \
        -delete 2>/dev/null || true

    rm -rf -- \
        /etc/systemd/system/nns-openvpn@.service.d \
        /etc/systemd/system/nns-netns@.service.d
    rm -f -- "$VPN_UNIT" "$NETNS_UNIT"

    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    rm -f -- "$USER_PATH"
    rm -f -- "$ENGINE_PATH"

    log "Purged NNS app engine and all installed NNS apps."
    log "Removed: $BASE_DIR, /etc/netns/nns-*, NNS systemd units, NNS sudoers rules, $USER_PATH and $ENGINE_PATH"
}

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

prepare_namespaced_desktop_mounts() {
    # `ip netns exec` creates a private mount namespace so it can bind
    # /etc/netns/<name>/* over the normal configuration paths. Snap's launcher
    # also needs cgroup2 and securityfs visible in that same mount namespace.
    # These mounts are private to this command and disappear when it exits.
    local current_type

    install -d -m 0755 /sys/fs/cgroup /sys/kernel/security

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

run_user_exec() {
    require_root
    local app=$1
    shift
    (( $# > 0 )) || die "_run-user requires an app and command."
    validate_app_name "$app"
    load_cfg "$app"

    # Prevent this internal helper from being used in the host namespace.
    local current_netns expected_netns
    current_netns=$(readlink /proc/self/ns/net)
    expected_netns=$(readlink "/run/netns/$NS_NAME")
    [[ -n "$current_netns" && "$current_netns" == "$expected_netns" ]] ||
        die "_run-user is not inside the expected namespace '$NS_NAME'."

    prepare_namespaced_desktop_mounts

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
    for name in DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS \
                LANG LC_ALL TERM COLORTERM SSH_AUTH_SOCK; do
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

    systemctl is-active --quiet "nns-netns@${app}.service" ||
        die "'$app' is stopped. Start it first."
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

    # ip-netns supplies the namespace-specific /etc/resolv.conf bind mount.
    # The internal helper then prepares cgroup2/securityfs for Snap and drops
    # permanently to APP_USER without shell re-parsing or eval.
    exec /usr/sbin/ip netns exec "$NS_NAME" \
        "$ENGINE_PATH" _run-user "$app" "$@"
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
        profile=${profile%.ovpn}
        profile=${profile%.conf}
        type=$(vpn_type_for_app "$app" 2>/dev/null || true)
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


main() {
    local cmd=${1:-}
    if [[ -z "$cmd" ]]; then
        show_version
        printf '\n'
        usage
        exit 0
    fi

    case "$cmd" in
        -h|--help|help)
            show_version
            printf '\n'
            usage
            exit 0
            ;;
        -V|--version|version)
            show_version
            exit 0
            ;;
    esac

    # Internal commands are called only by root-owned systemd units.
    case "$cmd" in
        _netns-up)
            require_root
            [[ $# -eq 2 ]] || die "_netns-up requires app_name."
            netns_up "$2"
            exit
            ;;
        _netns-down)
            require_root
            [[ $# -eq 2 ]] || die "_netns-down requires app_name."
            netns_down "$2"
            exit
            ;;
        _vpn)
            require_root
            [[ $# -eq 2 ]] || die "_vpn requires app_name."
            vpn_exec "$2"
            exit
            ;;
        _openvpn)
            require_root
            [[ $# -eq 2 ]] || die "_openvpn requires app_name."
            vpn_exec "$2"
            exit
            ;;
        _run-user)
            require_root
            (( $# >= 3 )) || die "_run-user requires app_name and command."
            local internal_app=$2
            shift 2
            run_user_exec "$internal_app" "$@"
            exit
            ;;
    esac

    reexec_as_root_if_needed "$@"

    case "$cmd" in
        install)
            if (( $# == 1 )); then
                install_engine
            else
                local install_app_name=$2 install_via="__default__"
                shift 2
                while (( $# > 0 )); do
                    case "$1" in
                        --via)
                            (( $# >= 2 )) || die "--via requires an upstream app name or 'host'."
                            install_via=$2
                            shift 2
                            ;;
                        --via=*)
                            install_via=${1#--via=}
                            shift
                            ;;
                        *)
                            die "Usage: nns-app install <app_name> [--via <upstream-app>|host]"
                            ;;
                    esac
                done
                install_app "$install_app_name" "$install_via"
            fi
            ;;
        remove)
            [[ $# -eq 2 ]] || die "Usage: nns-app remove <app_name>"
            remove_app "$2"
            ;;
        purge)
            [[ $# -eq 1 ]] || die "Usage: nns-app purge"
            purge_engine
            ;;
        list)
            [[ $# -eq 1 ]] || die "Usage: nns-app list"
            list_apps
            ;;
        add)
            (( $# >= 3 )) ||
                die "Usage: nns-app add <app_name> <profile.ovpn|wireguard.conf>|any [country] [--refresh] [--via <upstream-app>|host]"
            if [[ "$3" == any ]]; then
                local add_app=$2 add_country="" add_refresh="off" add_via="__default__"
                shift 3
                while (( $# > 0 )); do
                    case "$1" in
                        --refresh)
                            add_refresh="on"
                            shift
                            ;;
                        --via)
                            (( $# >= 2 )) || die "--via requires an upstream app name or 'host'."
                            add_via=$2
                            shift 2
                            ;;
                        --via=*)
                            add_via=${1#--via=}
                            shift
                            ;;
                        -*)
                            die "Unknown add option '$1'."
                            ;;
                        *)
                            [[ -z "$add_country" ]] ||
                                die "Only one country filter may be supplied."
                            add_country=$1
                            shift
                            ;;
                    esac
                done
                add_any_profile "$add_app" "$add_country" "$add_refresh" "$add_via"
            else
                [[ $# -eq 3 ]] ||
                    die "Options are valid only with: nns-app add <app_name> any [country] [--refresh] [--via <upstream-app>|host]"
                add_profile "$2" "$3"
            fi
            ;;
        start)
            shift
            parse_start_cli "$@"
            start_app "$START_APP_NAME" "$START_IGNORE" "$START_VIA"
            ;;
        stop)
            [[ $# -eq 2 ]] || die "Usage: nns-app stop <app_name>"
            stop_app "$2"
            ;;
        run)
            (( $# >= 3 )) || die "Usage: nns-app run <app_name> <command> [arguments...]"
            local app=$2
            shift 2
            run_in_app "$app" "$@"
            ;;
        *)
            usage
            die "Unknown command '$cmd'."
            ;;
    esac
}

main "$@"
