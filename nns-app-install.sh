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
# nns-app source module: preamble, constants, logging and process helpers.
# Author: Maxim Lyadvinsky
#
# Public commands:
#   install [<app_name> [--via <upstream-app>|host]]
#   remove  <app_name>
#   purge
#   list
#   status  <app_name>
#   add     <app_name> <profile.ovpn|wireguard.conf>
#   add     <app_name> any [country] [--refresh] [--via <upstream-app>|host]
#   start   [-i|--ignore-start-error] <app_name> [--via <upstream-app>|host]
#   stop    <app_name>
#   run     <app_name> <command> [args...]
#   gateway create <gateway> --via <app> --listen tcp|udp:<port>
#                  --public <host>:<port> [--pool <IPv4-CIDR>]
#   gateway start|stop|status|list|remove ...
#   gateway client add|list|export|revoke ...
#
# The script installs itself as /usr/local/sbin/nns_app.sh and creates the
# convenience symlink /usr/local/bin/nns-app.

set -Eeuo pipefail
IFS=$'\n\t'

readonly VERSION="1.1.27"
readonly PROGRAM_NAME="nns-app"
readonly AUTHOR="Maxim Lyadvinsky"
readonly LICENSE_ID="GPL-3.0-or-later"
readonly ENGINE_PATH="/usr/local/sbin/nns_app.sh"
readonly USER_PATH="/usr/local/bin/nns-app"
readonly BASE_DIR="/etc/nns-app"
readonly RUN_DIR="/run/nns-app"
readonly NETNS_UNIT="/etc/systemd/system/nns-netns@.service"
readonly VPN_UNIT="/etc/systemd/system/nns-openvpn@.service"
readonly GATEWAY_UNIT="/etc/systemd/system/nns-gateway@.service"
readonly ONLINE_UNIT="/etc/systemd/system/nns-online@.service"
readonly GATEWAY_CRL_SERVICE="/etc/systemd/system/nns-gateway-crl-refresh@.service"
readonly GATEWAY_CRL_TIMER="/etc/systemd/system/nns-gateway-crl-refresh@.timer"
readonly SYSTEMD_UNIT_DIR="/etc/systemd/system"
readonly DEFAULT_LOCK_DIR="/run/lock/nns-app"
# Unit tests source the built script without root privileges. They may point
# locks at a private temporary directory; normal command execution always uses
# the fixed system path so an environment variable cannot redirect root-owned
# lock files.
if [[ "${NNS_APP_SOURCE_ONLY:-0}" == 1 && -n "${NNS_APP_LOCK_DIR:-}" ]]; then
    readonly LOCK_DIR="$NNS_APP_LOCK_DIR"
else
    readonly LOCK_DIR="$DEFAULT_LOCK_DIR"
fi
readonly GATEWAY_BASE_DIR="$BASE_DIR/gateways"
readonly GATEWAY_RUN_BASE="$RUN_DIR/gateways"
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


declare -Ag NNS_LOCK_FDS=()
declare -Ag NNS_LOCK_DEPTH=()

ensure_lock_dir() {
    local owner mode mode_octal

    [[ ! -L "$LOCK_DIR" ]] || die "Refusing symbolic-link lock directory: $LOCK_DIR"

    if (( EUID == 0 )); then
        install -d -o root -g root -m 0755 "$LOCK_DIR"
        owner=$(stat -c '%u' "$LOCK_DIR")
        mode=$(stat -c '%a' "$LOCK_DIR")
        mode_octal=$((8#$mode))
        [[ "$owner" == 0 ]] || die "Unsafe lock directory owner: $LOCK_DIR"
        (( (mode_octal & 0022) == 0 )) ||
            die "Unsafe writable lock directory: $LOCK_DIR"
        return 0
    fi

    # Non-root locking exists only for source-level unit tests. Requiring both
    # source-only mode and an explicit non-system path prevents production
    # commands from silently weakening lock ownership.
    [[ "${NNS_APP_SOURCE_ONLY:-0}" == 1 && "$LOCK_DIR" != "$DEFAULT_LOCK_DIR" ]] ||
        die "Creating $DEFAULT_LOCK_DIR requires root privileges."
    install -d -m 0700 "$LOCK_DIR"
    owner=$(stat -c '%u' "$LOCK_DIR")
    [[ "$owner" == "$EUID" ]] || die "Test lock directory is not owned by the current user: $LOCK_DIR"
}

acquire_lock() {
    local key=$1 mode=${2:-exclusive} safe fd
    safe=${key//[^A-Za-z0-9_.-]/_}
    ensure_lock_dir

    if [[ -n "${NNS_LOCK_FDS[$safe]-}" ]]; then
        NNS_LOCK_DEPTH[$safe]=$(( ${NNS_LOCK_DEPTH[$safe]:-1} + 1 ))
        return 0
    fi

    exec {fd}>"$LOCK_DIR/$safe.lock"
    if [[ "$mode" == shared ]]; then
        flock -s "$fd"
    else
        flock -x "$fd"
    fi
    NNS_LOCK_FDS[$safe]=$fd
    NNS_LOCK_DEPTH[$safe]=1
}

release_lock() {
    local key=$1 safe fd depth
    safe=${key//[^A-Za-z0-9_.-]/_}
    fd=${NNS_LOCK_FDS[$safe]-}
    [[ -n "$fd" ]] || return 0

    depth=${NNS_LOCK_DEPTH[$safe]:-1}
    if (( depth > 1 )); then
        NNS_LOCK_DEPTH[$safe]=$((depth - 1))
        return 0
    fi

    flock -u "$fd" || true
    eval "exec ${fd}>&-"
    unset "NNS_LOCK_FDS[$safe]" "NNS_LOCK_DEPTH[$safe]"
}

reset_app_cfg_vars() {
    APP_NAME="" APP_USER="" DEFAULT_PROFILE="" VPN_TYPE=""
    KILLSWITCH="" AUTOSTART="" UPSTREAM_APP="" WAN_IFACE=""
    DNS_SERVERS="" DISABLE_IPV6="" DISABLE_DCO="" PROFILE_FIXUPS=""
    READY_TIMEOUT="" EXTERNAL_IP_URL="" NS_NAME="" NS_CIDR=""
    HOST_ADDR="" NS_ADDR="" VETH_HOST="" VETH_NS=""
}

reset_gateway_cfg_vars() {
    GATEWAY_NAME="" GATEWAY_BACKEND="" VIA_APP=""
    LISTEN_PROTO="" LISTEN_PORT="" PUBLIC_HOST="" PUBLIC_PORT=""
    CLIENT_POOL="" DNS_SERVERS="" TRANSIT_CIDR=""
    TRANSIT_HOST_ADDR="" TRANSIT_NS_ADDR="" GATEWAY_TUN=""
    GATEWAY_VETH_HOST="" GATEWAY_VETH_NS="" ROUTE_TABLE=""
    RULE_PRIORITY="" SERVER_CN="" HOST_FWD_CHAIN=""
    HOST_MANGLE_CHAIN="" NS_FWD_CHAIN="" NS_NAT_CHAIN=""
    NS_MANGLE_CHAIN=""
}

reset_gateway_client_vars() {
    CLIENT_NAME="" STATUS="" CERT_SERIAL="" CREATED_AT="" REVOKED_AT=""
}

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
    elif (( seconds >= 60 )); then
        printf '%dm' "$((seconds / 60))"
    else
        printf '%ds' "$seconds"
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
  nns-app status  <app_name>
  nns-app add     <app_name> <profile.ovpn|wireguard.conf>
  nns-app add     <app_name> any [country-code-or-name] [--refresh] [--via <upstream-app>|host]
  nns-app start   [-i|--ignore-start-error] <app_name> [--via <upstream-app>|host]
  nns-app stop    <app_name>
  nns-app run     <app_name> <command> [arguments...]

  nns-app gateway create <gateway_name> --via <app_name>
                  --listen <tcp|udp>:<port>
                  --public <host>:<port>
                  [--pool <IPv4-CIDR>] [--dns "<IPv4> ..."]
  nns-app gateway start  <gateway_name>
  nns-app gateway stop   <gateway_name>
  nns-app gateway status <gateway_name>
  nns-app gateway list
  nns-app gateway remove <gateway_name>
  nns-app gateway client add    <gateway_name> <client_name>
  nns-app gateway client list   <gateway_name>
  nns-app gateway client export <gateway_name> <client_name> --output <file.ovpn>
  nns-app gateway client revoke <gateway_name> <client_name>

Examples:
  sudo ./nns-app.sh install
  sudo nns-app install my-upstream-vpn
  sudo nns-app add my-upstream-vpn ~/my-base-profile.ovpn
  sudo nns-app install my-private-app --via my-upstream-vpn
  sudo nns-app add my-private-app ~/my-app-profile.ovpn
  sudo nns-app add my-private-app ~/my-wireguard-profile.conf
  sudo nns-app add my-private-app any US --via my-upstream-vpn
  nns-app start my-private-app
  nns-app start -i my-private-app --via my-upstream-vpn
  nns-app run my-private-app curl -4 https://api.ipify.org
  nns-app run my-private-app firefox --no-remote
  sudo nns-app purge
  nns-app list
  nns-app status my-private-app

  # On a remote Linux box where `my-remote-exit` is already online:
  sudo nns-app gateway create my-relay \
      --via my-remote-exit \
      --listen tcp:443 \
      --public vpn.example.net:443
  sudo nns-app gateway client add my-relay my-linux-client
  sudo nns-app gateway client export my-relay my-linux-client \
      --output ~/my-remote-profile.ovpn
  sudo nns-app gateway start my-relay
USAGE
}


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

    local sudo_args=(/usr/bin/sudo)
    case "$cmd" in
        list|status|start|stop|run)
            sudo_args+=( -n )
            ;;
        install|remove|add|purge|gateway)
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
        systemctl enable --now "nns-gateway-crl-refresh@${gateway}.timer" \
            >/dev/null 2>&1 || true
        if systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
            warn "Gateway '$gateway' is running; restart it to activate the 1.1 data-plane rules."
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
        "$GATEWAY_BASE_DIR" "$GATEWAY_RUN_BASE" "$LOCK_DIR"
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
        "$GATEWAY_BASE_DIR" "$GATEWAY_RUN_BASE" "$LOCK_DIR"

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


# nns-app source module: profile import, validation and VPN Gate selection.
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
        BEGIN {
            inblock=0
            bad=0
            unsafe = "^(up|down|route-up|route-pre-down|ipchange|"
            unsafe = unsafe "learn-address|client-connect|client-disconnect|"
            unsafe = unsafe "auth-user-pass-verify|tls-verify|tls-crypt-v2-verify|"
            unsafe = unsafe "plugin|script-security|iproute|config|daemon|"
            unsafe = unsafe "writepid|chroot|cd|user|group|log|log-append|"
            unsafe = unsafe "status|status-version|pkcs11-providers|pkcs11-id|"
            unsafe = unsafe "cryptoapicert|engine)$"
        }
        /^[[:space:]]*<[^/][^>]*>[[:space:]]*$/ { inblock=1; next }
        /^[[:space:]]*<\/[A-Za-z0-9_-]+>[[:space:]]*$/ { inblock=0; next }
        inblock { next }
        /^[[:space:]]*[#;]/ { next }
        {
            key=tolower($1)
            if (key ~ unsafe || key ~ /^management/) {
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

    # Disable DCO only in the managed copy because some OpenVPN/Ubuntu
    # combinations bypass or retain data-path state across namespace restarts.
    # The provider's source profile is never modified.
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

    # Treat a two-letter filter as a country code and match CountryShort
    # exactly; substring matching would create false positives.
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

# Rotate through the strongest candidates. Persisting the last selected entry
# prevents repeated `add ... any` calls from returning the same profile. The
# top-20 cap avoids rotating into low-quality entries in large country pools.
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



# nns-app source module: managed remote gateway, PKI, routing and client lifecycle.
validate_gateway_name() {
    local name=${1:-}
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] ||
        die "Invalid gateway name '$name'. Use 1-32 letters, digits, '.', '_' or '-'."
}

validate_gateway_client_name() {
    local name=${1:-}
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$ ]] ||
        die "Invalid client name '$name'. Use 1-48 letters, digits, '.', '_' or '-'."
}

gateway_dir()          { printf '%s/%s\n' "$GATEWAY_BASE_DIR" "$1"; }
gateway_cfg_file()     { printf '%s/%s/gateway.cfg\n' "$GATEWAY_BASE_DIR" "$1"; }
gateway_pki_dir()      { printf '%s/%s/pki\n' "$GATEWAY_BASE_DIR" "$1"; }
gateway_clients_dir()  { printf '%s/%s/clients\n' "$GATEWAY_BASE_DIR" "$1"; }
gateway_client_dir()   { printf '%s/%s/clients/%s\n' "$GATEWAY_BASE_DIR" "$1" "$2"; }
gateway_server_config(){ printf '%s/%s/server.conf\n' "$GATEWAY_BASE_DIR" "$1"; }
gateway_runtime_dir()  { printf '%s/%s\n' "$GATEWAY_RUN_BASE" "$1"; }
gateway_runtime_file() { printf '%s/%s/runtime.env\n' "$GATEWAY_RUN_BASE" "$1"; }
gateway_status_file()  { printf '%s/%s/openvpn-status.log\n' "$GATEWAY_RUN_BASE" "$1"; }

load_gateway_cfg() {
    local gateway=$1 file owner mode mode_octal
    validate_gateway_name "$gateway"
    file=$(gateway_cfg_file "$gateway")
    [[ -f "$file" ]] || die "Gateway '$gateway' is not configured."

    owner=$(stat -c '%u' "$file")
    mode=$(stat -c '%a' "$file")
    [[ "$owner" == 0 ]] ||
        die "Unsafe gateway config owner for $file; expected root."
    mode_octal=$((8#$mode))
    (( (mode_octal & 0022) == 0 )) ||
        die "Unsafe gateway config permissions on $file."

    reset_gateway_cfg_vars
    # shellcheck disable=SC1090
    source "$file"

    [[ "${GATEWAY_NAME:-}" == "$gateway" ]] ||
        die "GATEWAY_NAME mismatch in $file."
    [[ "${GATEWAY_BACKEND:-}" == openvpn ]] ||
        die "Unsupported gateway backend '${GATEWAY_BACKEND:-}'."
    [[ -n "${VIA_APP:-}" ]] || die "VIA_APP is missing in $file."
    [[ "${ROUTE_TABLE:-}" =~ ^[0-9]+$ &&
       "${RULE_PRIORITY:-}" =~ ^[0-9]+$ ]] ||
        die "Gateway routing identifiers are invalid in $file."

    # Legacy gateway configs may omit dedicated firewall-chain names. Derive
    # stable names from the gateway ID so upgrades remain backward compatible.
    if [[ -z "${HOST_FWD_CHAIN:-}" || -z "${NS_NAT_CHAIN:-}" ]]; then
        local derived_tun derived_host derived_ns
        IFS='|' read -r \
            derived_tun derived_host derived_ns \
            HOST_FWD_CHAIN HOST_MANGLE_CHAIN \
            NS_FWD_CHAIN NS_NAT_CHAIN NS_MANGLE_CHAIN \
            <<<"$(make_gateway_names "$gateway")"
    fi
}

gateway_cfg_value() {
    local gateway=$1 key=$2 file
    file=$(gateway_cfg_file "$gateway")
    [[ -f "$file" ]] || return 1
    (
        set +u
        # shellcheck disable=SC1090
        source "$file"
        printf '%s\n' "${!key-}"
    )
}

make_gateway_names() {
    local gateway=$1 crc hex
    crc=$(printf 'gateway:%s' "$gateway" | cksum | awk '{print $1}')
    printf -v hex '%08x' "$crc"
    printf 'ngw%s|ngh%s|ngn%s|NGH%sF|NGH%sM|NGN%sF|NGN%sN|NGN%sM\n' \
        "$hex" "$hex" "$hex" "$hex" "$hex" "$hex" "$hex" "$hex"
}

gateway_used_networks() {
    all_known_ipv4_networks
}

allocate_gateway_networks() {
    local requested_pool=${1:-}
    python3 - "$requested_pool" 3< <(all_known_ipv4_networks) <<'PY_GATEWAY_NETWORKS'
import ipaddress
import os
import sys

requested = sys.argv[1].strip()
used = []
for raw in os.fdopen(3):
    raw = raw.strip()
    if not raw:
        continue
    try:
        used.append(ipaddress.ip_network(raw, strict=False))
    except ValueError:
        pass

def free(net):
    return all(not net.overlaps(other) for other in used)

if requested:
    pool = ipaddress.ip_network(requested, strict=True)
    if pool.version != 4 or not pool.is_private:
        raise SystemExit("client pool must be private IPv4")
    if pool.prefixlen < 24 or pool.prefixlen > 29:
        raise SystemExit("client pool prefix must be /24 through /29")
    for reserved in (
        ipaddress.ip_network("10.239.0.0/16"),
        ipaddress.ip_network("10.240.0.0/16"),
    ):
        if pool.overlaps(reserved):
            raise SystemExit(f"client pool overlaps reserved range {reserved}")
    if not free(pool):
        raise SystemExit(f"client pool {pool} overlaps an existing or live network")
else:
    pool = next(
        (
            net
            for net in ipaddress.ip_network("10.253.0.0/16").subnets(new_prefix=24)
            if free(net)
        ),
        None,
    )
    if pool is None:
        raise SystemExit("no free gateway client /24 remains in 10.253.0.0/16")

used.append(pool)
transit = next(
    (
        net
        for net in ipaddress.ip_network("10.239.0.0/16").subnets(new_prefix=30)
        if free(net)
    ),
    None,
)
if transit is None:
    raise SystemExit("no free gateway transit /30 remains in 10.239.0.0/16")

hosts = list(transit.hosts())
print(f"{pool}|{transit}|{hosts[0]}/{transit.prefixlen}|{hosts[1]}/{transit.prefixlen}")
PY_GATEWAY_NETWORKS
}

gateway_route_id_in_use() {
    local table=$1 priority=$2

    if grep -RhsE '^(ROUTE_TABLE|RULE_PRIORITY)=' \
        "$GATEWAY_BASE_DIR"/*/gateway.cfg 2>/dev/null |
        grep -Eq "=\"?(${table}|${priority})\"?$"; then
        return 0
    fi

    ip rule show 2>/dev/null |
        grep -Eq "(^|[[:space:]])${priority}:|lookup[[:space:]]+${table}([[:space:]]|$)" &&
        return 0
    ip route show table "$table" 2>/dev/null | grep -q . && return 0
    awk -v table="$table" '$1 == table {found=1} END {exit !found}' \
        /etc/iproute2/rt_tables 2>/dev/null && return 0
    return 1
}

allocate_gateway_table() {
    local table priority
    for ((table=22000; table<23000; table++)); do
        priority=$((table - 10000))
        if ! gateway_route_id_in_use "$table" "$priority"; then
            printf '%s|%s\n' "$table" "$priority"
            return 0
        fi
    done
    die "No free gateway policy-routing table remains."
}

parse_gateway_listen() {
    local value=$1 proto port
    [[ "$value" == *:* ]] || die "--listen must be tcp:<port> or udp:<port>."
    proto=${value%%:*}
    port=${value##*:}
    proto=${proto,,}
    case "$proto" in tcp|udp) ;; *) die "Gateway listen protocol must be tcp or udp." ;; esac
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) ||
        die "Gateway listen port must be from 1 through 65535."
    printf '%s|%s\n' "$proto" "$port"
}

parse_public_endpoint() {
    local value=$1 host port
    [[ "$value" == *:* ]] || die "--public must be host:port."
    host=${value%:*}
    port=${value##*:}
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] && [[ -n "$host" ]] ||
        die "Gateway public host must be an IPv4 address or DNS name."
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) ||
        die "Gateway public port must be from 1 through 65535."
    printf '%s|%s\n' "$host" "$port"
}

validate_gateway_dns() {
    local value=$1
    python3 - "$value" <<'PY_GATEWAY_DNS'
import ipaddress
import sys
items = sys.argv[1].split()
if not items:
    raise SystemExit("at least one DNS server is required")
for item in items:
    try:
        addr = ipaddress.ip_address(item)
    except ValueError as exc:
        raise SystemExit(f"invalid DNS server {item!r}: {exc}")
    if addr.version != 4:
        raise SystemExit("gateway v1 supports IPv4 DNS servers only")
print(" ".join(items))
PY_GATEWAY_DNS
}

gateway_write_openssl_config() {
    local gateway=$1 root=${2:-$(gateway_dir "$gateway")} pki output
    pki="$root/pki"
    output=$(mktemp "$pki/openssl.cnf.XXXXXX") || return 1

    if ! cat >"$output" <<OPENSSL_GATEWAY_EOF
[ ca ]
default_ca = CA_default

[ CA_default ]
dir               = $pki
database          = \$dir/index.txt
new_certs_dir     = \$dir/newcerts
certificate       = \$dir/ca.crt
serial            = \$dir/serial
crlnumber         = \$dir/crlnumber
private_key       = \$dir/private/ca.key
default_md        = sha256
default_days      = 825
default_crl_days  = 14
policy            = policy_loose
copy_extensions   = none
unique_subject    = no

[ policy_loose ]
countryName             = optional
stateOrProvinceName     = optional
localityName            = optional
organizationName        = optional
organizationalUnitName  = optional
commonName              = supplied
emailAddress            = optional

[ server_cert ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer

[ client_cert ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
OPENSSL_GATEWAY_EOF
    then
        rm -f "$output"
        return 1
    fi

    if ! install -o root -g root -m 0644 \
        "$output" "$pki/openssl.cnf"; then
        rm -f "$output"
        return 1
    fi
    rm -f "$output"
}

gateway_generate_crl_at() {
    local pki=$1 tmp
    tmp=$(mktemp "$pki/crl.pem.XXXXXX") || return 1
    if ! openssl ca -batch -config "$pki/openssl.cnf" \
        -gencrl -out "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        return 1
    fi
    if ! install -o root -g root -m 0644 \
        "$tmp" "$pki/crl.pem"; then
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
}

gateway_crl_refresh() {
    require_root
    local gateway=$1 pki
    validate_gateway_name "$gateway"
    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"
    pki=$(gateway_pki_dir "$gateway")
    sed -i -E \
        's/^default_crl_days[[:space:]]*=.*/default_crl_days  = 14/' \
        "$pki/openssl.cnf"
    if ! gateway_generate_crl_at "$pki"; then
        release_lock "gateway-$gateway"
        die "Failed to refresh CRL for gateway '$gateway'."
    fi
    release_lock "gateway-$gateway"
    log "Refreshed CRL for gateway '$gateway'."
}

gateway_generate_pki() {
    local gateway=$1 root=${2:-$(gateway_dir "$gateway")} pki server_cn
    pki="$root/pki"
    server_cn="nns-gateway-$gateway"

    install -d -o root -g root -m 0755 \
        "$pki" "$pki/newcerts" "$pki/issued" || return 1
    install -d -o root -g root -m 0700 "$pki/private" || return 1
    : >"$pki/index.txt" || return 1
    printf '1000\n' >"$pki/serial" || return 1
    printf '1000\n' >"$pki/crlnumber" || return 1
    gateway_write_openssl_config "$gateway" "$root" || return 1

    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
        -out "$pki/private/ca.key" >/dev/null 2>&1 || return 1
    chmod 0600 "$pki/private/ca.key" || return 1
    openssl req -x509 -new -sha256 -days 3650 \
        -key "$pki/private/ca.key" \
        -subj "/CN=nns-app $gateway gateway CA" \
        -out "$pki/ca.crt" >/dev/null 2>&1 || return 1

    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
        -out "$pki/server.key" >/dev/null 2>&1 || return 1
    openssl req -new -sha256 \
        -key "$pki/server.key" \
        -subj "/CN=$server_cn" \
        -out "$pki/server.csr" >/dev/null 2>&1 || return 1
    openssl ca -batch -notext \
        -config "$pki/openssl.cnf" \
        -extensions server_cert \
        -in "$pki/server.csr" \
        -out "$pki/server.crt" >/dev/null 2>&1 || return 1

    openvpn --genkey tls-crypt-v2-server \
        "$pki/tls-crypt-v2-server.key" || return 1
    gateway_generate_crl_at "$pki" || return 1
    rm -f "$pki/server.csr"

    chown root:root "$pki/ca.crt" "$pki/server.crt" "$pki/crl.pem" ||
        return 1
    chown root:nogroup "$pki/server.key" "$pki/tls-crypt-v2-server.key" ||
        return 1
    chmod 0644 "$pki/ca.crt" "$pki/server.crt" "$pki/crl.pem" ||
        return 1
    chmod 0640 "$pki/server.key" "$pki/tls-crypt-v2-server.key" ||
        return 1
}

gateway_write_server_config() {
    local gateway=$1 root=${2:-$(gateway_dir "$gateway")}
    local config output pki proto_option network netmask dns

    if [[ "$root" == "$(gateway_dir "$gateway")" ]]; then
        load_gateway_cfg "$gateway"
    else
        reset_gateway_cfg_vars
        # shellcheck disable=SC1090
        source "$root/gateway.cfg"
    fi

    config="$root/server.conf"
    output="$config"
    if [[ "$root" == "$(gateway_dir "$gateway")" ]]; then
        output=$(mktemp "$root/server.conf.XXXXXX")
    fi
    pki="$root/pki"
    [[ "$LISTEN_PROTO" == tcp ]] &&
        proto_option=tcp-server || proto_option=udp

    read -r network netmask < <(
        python3 - "$CLIENT_POOL" <<'PY_GATEWAY_POOL'
import ipaddress
import sys

net = ipaddress.ip_network(sys.argv[1], strict=True)
print(net.network_address, net.netmask)
PY_GATEWAY_POOL
    )

    {
        printf '# Generated by nns-app; recreate the gateway instead of editing this file.\n'
        printf 'mode server\n'
        printf 'tls-server\n'
        printf 'proto %s\n' "$proto_option"
        printf 'port %s\n' "$LISTEN_PORT"
        printf 'dev %s\n' "$GATEWAY_TUN"
        printf 'topology subnet\n'
        printf 'server %s %s\n' "$network" "$netmask"
        printf 'ca %s\n' "$pki/ca.crt"
        printf 'cert %s\n' "$pki/server.crt"
        printf 'key %s\n' "$pki/server.key"
        printf 'dh none\n'
        printf 'crl-verify %s\n' "$pki/crl.pem"
        printf 'tls-crypt-v2 %s force-cookie\n' \
            "$pki/tls-crypt-v2-server.key"
        printf 'verify-client-cert require\n'
        printf 'remote-cert-tls client\n'
        printf 'tls-version-min 1.2\n'
        printf 'data-ciphers AES-256-GCM:CHACHA20-POLY1305:AES-128-GCM\n'
        printf 'auth SHA256\n'
        printf 'allow-compression no\n'
        printf 'keepalive 10 60\n'
        printf 'persist-key\n'
        printf 'persist-tun\n'
        printf 'script-security 2\n'
        printf 'up "%s _gateway-tun-up %s"\n' "$ENGINE_PATH" "$gateway"
        printf 'user nobody\n'
        printf 'group nogroup\n'
        printf 'status %s 5\n' "$(gateway_status_file "$gateway")"
        printf 'status-version 3\n'
        printf 'push "redirect-gateway def1 bypass-dhcp"\n'
        for dns in $DNS_SERVERS; do
            printf 'push "dhcp-option DNS %s"\n' "$dns"
        done
        [[ "$LISTEN_PROTO" == udp ]] &&
            printf 'explicit-exit-notify 1\n'
        printf 'verb 3\n'
        printf 'mute 10\n'
    } >"$output" || {
        rm -f "$output"
        return 1
    }

    if [[ "$output" != "$config" ]]; then
        install -o root -g nogroup -m 0640 "$output" "$config" || {
            rm -f "$output"
            return 1
        }
        rm -f "$output"
    else
        chown root:nogroup "$config" || return 1
        chmod 0640 "$config" || return 1
    fi
}

gateway_validate_staging() {
    local gateway=$1 root=$2 pki="$2/pki"
    [[ -s "$root/gateway.cfg" && -s "$root/server.conf" ]] || return 1
    [[ -s "$pki/ca.crt" && -s "$pki/server.crt" &&
       -s "$pki/server.key" ]] || return 1
    [[ -s "$pki/tls-crypt-v2-server.key" &&
       -s "$pki/crl.pem" ]] || return 1
    openssl verify -CAfile "$pki/ca.crt" \
        "$pki/server.crt" >/dev/null 2>&1 || return 1
    openssl crl -in "$pki/crl.pem" \
        -noout -checkend 1 >/dev/null 2>&1 || return 1
    grep -Eq '^tls-crypt-v2[[:space:]]+' "$root/server.conf" || return 1
    grep -Eq '^up[[:space:]]+' "$root/server.conf" || return 1
}

gateway_create() {
    require_root
    local gateway=$1 via_app=$2 listen=$3 public=$4
    local requested_pool=${5:-}
    local dns_input=${6:-"1.1.1.1 9.9.9.9"}
    local staging=""

    validate_gateway_name "$gateway"
    validate_app_name "$via_app"
    [[ ! -f "$(cfg_file "$gateway")" ]] ||
        die "An NNS app named '$gateway' already exists."
    [[ -f "$(cfg_file "$via_app")" ]] ||
        die "Upstream NNS app '$via_app' is not installed."
    [[ ! -e "$(gateway_cfg_file "$gateway")" ]] ||
        die "Gateway '$gateway' already exists."

    acquire_lock global
    acquire_lock "gateway-$gateway"

    local listen_proto listen_port public_host public_port
    local client_pool transit_cidr transit_host_addr transit_ns_addr
    local route_table rule_priority gateway_tun veth_host veth_ns
    local host_fwd host_mangle ns_fwd ns_nat ns_mangle dns_servers

    IFS='|' read -r listen_proto listen_port \
        <<<"$(parse_gateway_listen "$listen")"
    IFS='|' read -r public_host public_port \
        <<<"$(parse_public_endpoint "$public")"
    IFS='|' read -r \
        client_pool transit_cidr transit_host_addr transit_ns_addr \
        <<<"$(allocate_gateway_networks "$requested_pool")"
    IFS='|' read -r route_table rule_priority \
        <<<"$(allocate_gateway_table)"
    IFS='|' read -r \
        gateway_tun veth_host veth_ns \
        host_fwd host_mangle ns_fwd ns_nat ns_mangle \
        <<<"$(make_gateway_names "$gateway")"
    dns_servers=$(validate_gateway_dns "$dns_input")

    ensure_dependencies
    install_engine_files
    install -d -o root -g root -m 0755 \
        "$GATEWAY_BASE_DIR" "$GATEWAY_RUN_BASE"

    staging=$(mktemp -d "$GATEWAY_BASE_DIR/.${gateway}.new.XXXXXX")
    install -d -o root -g root -m 0700 "$staging/clients"

    cat >"$staging/gateway.cfg" <<GATEWAY_CONFIG_EOF
# nns-app managed OpenVPN gateway. Generated file; use nns-app to change it.
GATEWAY_NAME="$gateway"
GATEWAY_BACKEND="openvpn"
VIA_APP="$via_app"

LISTEN_PROTO="$listen_proto"
LISTEN_PORT="$listen_port"
PUBLIC_HOST="$public_host"
PUBLIC_PORT="$public_port"
CLIENT_POOL="$client_pool"
DNS_SERVERS="$dns_servers"

TRANSIT_CIDR="$transit_cidr"
TRANSIT_HOST_ADDR="$transit_host_addr"
TRANSIT_NS_ADDR="$transit_ns_addr"
GATEWAY_TUN="$gateway_tun"
GATEWAY_VETH_HOST="$veth_host"
GATEWAY_VETH_NS="$veth_ns"
ROUTE_TABLE="$route_table"
RULE_PRIORITY="$rule_priority"
SERVER_CN="nns-gateway-$gateway"

HOST_FWD_CHAIN="$host_fwd"
HOST_MANGLE_CHAIN="$host_mangle"
NS_FWD_CHAIN="$ns_fwd"
NS_NAT_CHAIN="$ns_nat"
NS_MANGLE_CHAIN="$ns_mangle"
GATEWAY_CONFIG_EOF
    chown root:root "$staging/gateway.cfg"
    chmod 0644 "$staging/gateway.cfg"

    if ! gateway_generate_pki "$gateway" "$staging" ||
       ! gateway_write_server_config "$gateway" "$staging" ||
       ! gateway_validate_staging "$gateway" "$staging"; then
        rm -rf "$staging"
        release_lock "gateway-$gateway"
        release_lock global
        die "Failed to create gateway '$gateway'; staged files were removed."
    fi

    mv "$staging" "$(gateway_dir "$gateway")"
    if ! gateway_write_openssl_config "$gateway" "$(gateway_dir "$gateway")" ||
       ! gateway_write_server_config "$gateway" "$(gateway_dir "$gateway")"; then
        rm -rf "$(gateway_dir "$gateway")"
        release_lock "gateway-$gateway"
        release_lock global
        die "Failed to finalize gateway '$gateway'; installed files were removed."
    fi

    write_gateway_unit_dropin "$gateway"
    systemctl daemon-reload
    systemctl enable --now "nns-gateway-crl-refresh@${gateway}.timer" >/dev/null

    release_lock "gateway-$gateway"
    release_lock global

    log "Created managed OpenVPN gateway '$gateway'."
    log "Public endpoint: $public_host:$public_port/$listen_proto"
    log "Client pool:     $client_pool"
    log "Remote exit:     $via_app"
    warn "Ensure the host firewall and upstream NAT/router allow $listen_proto port $listen_port."
}

iptables_chain_ensure() {
    local table=$1 chain=$2
    iptables -w -t "$table" -N "$chain" 2>/dev/null || true
    iptables -w -t "$table" -F "$chain"
}

iptables_jump_add_once() {
    local table=$1 parent=$2 chain=$3 comment=$4
    iptables -w -t "$table" \
        -C "$parent" -m comment --comment "$comment" -j "$chain" 2>/dev/null ||
    iptables -w -t "$table" \
        -I "$parent" 1 -m comment --comment "$comment" -j "$chain"
}

iptables_jump_delete_all() {
    local table=$1 parent=$2 chain=$3 comment=$4
    while iptables -w -t "$table" \
        -C "$parent" -m comment --comment "$comment" -j "$chain" 2>/dev/null; do
        iptables -w -t "$table" \
            -D "$parent" -m comment --comment "$comment" -j "$chain" || break
    done
}

netns_chain_ensure() {
    local ns=$1 table=$2 chain=$3
    ip netns exec "$ns" iptables -w -t "$table" \
        -N "$chain" 2>/dev/null || true
    ip netns exec "$ns" iptables -w -t "$table" -F "$chain"
}

netns_jump_add_once() {
    local ns=$1 table=$2 parent=$3 chain=$4 comment=$5
    ip netns exec "$ns" iptables -w -t "$table" \
        -C "$parent" -m comment --comment "$comment" -j "$chain" 2>/dev/null ||
    ip netns exec "$ns" iptables -w -t "$table" \
        -I "$parent" 1 -m comment --comment "$comment" -j "$chain"
}

netns_jump_delete_all() {
    local ns=$1 table=$2 parent=$3 chain=$4 comment=$5
    while ip netns exec "$ns" iptables -w -t "$table" \
        -C "$parent" -m comment --comment "$comment" -j "$chain" 2>/dev/null; do
        ip netns exec "$ns" iptables -w -t "$table" \
            -D "$parent" -m comment --comment "$comment" -j "$chain" || break
    done
}

gateway_delete_veth_everywhere() {
    local name=$1 ns
    ip link del "$name" 2>/dev/null || true
    while read -r ns _; do
        [[ -n "$ns" ]] || continue
        ip -n "$ns" link del "$name" 2>/dev/null || true
    done < <(ip netns list 2>/dev/null || true)
}

gateway_host_rules_up() {
    local comment="nns-app:gateway:$GATEWAY_NAME"

    iptables_chain_ensure filter "$HOST_FWD_CHAIN"
    iptables -w -t filter -A "$HOST_FWD_CHAIN" \
        -i "$GATEWAY_TUN" -s "$CLIENT_POOL" \
        -o "$GATEWAY_VETH_HOST" -j ACCEPT
    iptables -w -t filter -A "$HOST_FWD_CHAIN" \
        -i "$GATEWAY_VETH_HOST" -d "$CLIENT_POOL" \
        -o "$GATEWAY_TUN" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -w -t filter -A "$HOST_FWD_CHAIN" \
        -i "$GATEWAY_TUN" -s "$CLIENT_POOL" -j DROP
    iptables -w -t filter -A "$HOST_FWD_CHAIN" -j RETURN
    iptables_jump_add_once \
        filter FORWARD "$HOST_FWD_CHAIN" "$comment:forward"

    iptables_chain_ensure mangle "$HOST_MANGLE_CHAIN"
    iptables -w -t mangle -A "$HOST_MANGLE_CHAIN" \
        -i "$GATEWAY_TUN" -s "$CLIENT_POOL" \
        -o "$GATEWAY_VETH_HOST" -p tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -w -t mangle -A "$HOST_MANGLE_CHAIN" -j RETURN
    iptables_jump_add_once \
        mangle FORWARD "$HOST_MANGLE_CHAIN" "$comment:mangle"
}

gateway_host_rules_down() {
    local comment="nns-app:gateway:$GATEWAY_NAME"

    iptables_jump_delete_all \
        filter FORWARD "$HOST_FWD_CHAIN" "$comment:forward"
    iptables_jump_delete_all \
        mangle FORWARD "$HOST_MANGLE_CHAIN" "$comment:mangle"

    iptables -w -t filter -F "$HOST_FWD_CHAIN" 2>/dev/null || true
    iptables -w -t filter -X "$HOST_FWD_CHAIN" 2>/dev/null || true
    iptables -w -t mangle -F "$HOST_MANGLE_CHAIN" 2>/dev/null || true
    iptables -w -t mangle -X "$HOST_MANGLE_CHAIN" 2>/dev/null || true
}

gateway_namespace_rules_up() {
    local ns=$1 tunnel=$2 comment="nns-app:gateway:$GATEWAY_NAME"
    ip netns exec "$ns" sysctl -q -w net.ipv4.ip_forward=1

    netns_chain_ensure "$ns" filter "$NS_FWD_CHAIN"
    ip netns exec "$ns" iptables -w -t filter -A "$NS_FWD_CHAIN" \
        -i "$GATEWAY_VETH_NS" -s "$CLIENT_POOL" \
        -o "$tunnel" -j ACCEPT
    ip netns exec "$ns" iptables -w -t filter -A "$NS_FWD_CHAIN" \
        -i "$tunnel" -d "$CLIENT_POOL" \
        -o "$GATEWAY_VETH_NS" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    ip netns exec "$ns" iptables -w -t filter -A "$NS_FWD_CHAIN" \
        -i "$GATEWAY_VETH_NS" -s "$CLIENT_POOL" -j DROP
    ip netns exec "$ns" iptables -w -t filter \
        -A "$NS_FWD_CHAIN" -j RETURN
    netns_jump_add_once \
        "$ns" filter FORWARD "$NS_FWD_CHAIN" "$comment:ns-forward"

    netns_chain_ensure "$ns" nat "$NS_NAT_CHAIN"
    ip netns exec "$ns" iptables -w -t nat -A "$NS_NAT_CHAIN" \
        -s "$CLIENT_POOL" -o "$tunnel" -j MASQUERADE
    ip netns exec "$ns" iptables -w -t nat \
        -A "$NS_NAT_CHAIN" -j RETURN
    netns_jump_add_once \
        "$ns" nat POSTROUTING "$NS_NAT_CHAIN" "$comment:ns-nat"

    netns_chain_ensure "$ns" mangle "$NS_MANGLE_CHAIN"
    ip netns exec "$ns" iptables -w -t mangle -A "$NS_MANGLE_CHAIN" \
        -i "$GATEWAY_VETH_NS" -s "$CLIENT_POOL" \
        -o "$tunnel" -p tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    ip netns exec "$ns" iptables -w -t mangle \
        -A "$NS_MANGLE_CHAIN" -j RETURN
    netns_jump_add_once \
        "$ns" mangle FORWARD "$NS_MANGLE_CHAIN" "$comment:ns-mangle"
}

gateway_namespace_rules_down() {
    local ns=$1 tunnel=$2 comment="nns-app:gateway:$GATEWAY_NAME"
    local table chain

    netns_jump_delete_all \
        "$ns" filter FORWARD "$NS_FWD_CHAIN" "$comment:ns-forward"
    netns_jump_delete_all \
        "$ns" nat POSTROUTING "$NS_NAT_CHAIN" "$comment:ns-nat"
    netns_jump_delete_all \
        "$ns" mangle FORWARD "$NS_MANGLE_CHAIN" "$comment:ns-mangle"

    for table in filter nat mangle; do
        case "$table" in
            filter) chain=$NS_FWD_CHAIN ;;
            nat) chain=$NS_NAT_CHAIN ;;
            mangle) chain=$NS_MANGLE_CHAIN ;;
        esac
        ip netns exec "$ns" iptables -w -t "$table" \
            -F "$chain" 2>/dev/null || true
        ip netns exec "$ns" iptables -w -t "$table" \
            -X "$chain" 2>/dev/null || true
    done
}

gateway_rule_delete_exact() {
    local line
    while true; do
        line=$(ip rule show |
            awk -v priority="${RULE_PRIORITY}:" '$1 == priority {print; exit}')
        [[ -n "$line" ]] || break

        if [[ "$line" == *"from $CLIENT_POOL"* &&
              "$line" == *"iif $GATEWAY_TUN"* &&
              "$line" == *"lookup $ROUTE_TABLE"* ]]; then
            ip rule del \
                priority "$RULE_PRIORITY" \
                iif "$GATEWAY_TUN" \
                from "$CLIENT_POOL" \
                lookup "$ROUTE_TABLE" || break
        else
            break
        fi
    done
}

gateway_remove_legacy_rule() {
    local line
    line=$(ip rule show |
        awk -v priority="${RULE_PRIORITY}:" '$1 == priority {print; exit}')
    [[ -n "$line" ]] || return 0

    # A legacy install may leave a source-only policy rule. Remove it only
    # when every owned attribute matches; never delete a rule by priority alone.
    if [[ "$line" == *"from $CLIENT_POOL"* &&
          "$line" != *"iif "* &&
          "$line" == *"lookup $ROUTE_TABLE"* ]]; then
        ip rule del \
            priority "$RULE_PRIORITY" \
            from "$CLIENT_POOL" \
            lookup "$ROUTE_TABLE"
    fi
}

gateway_routes_delete_exact() {
    local ns_ip=${1:-${TRANSIT_NS_ADDR%/*}}
    ip route del table "$ROUTE_TABLE" \
        default via "$ns_ip" dev "$GATEWAY_VETH_HOST" metric 10 \
        2>/dev/null || true
    ip route del table "$ROUTE_TABLE" \
        blackhole default metric 32767 \
        2>/dev/null || true
}

gateway_down_locked() {
    local gateway=$1 runtime upstream_ns="" upstream_tun="" ns_ip=""
    validate_gateway_name "$gateway"
    [[ -f "$(gateway_cfg_file "$gateway")" ]] || return 0
    load_gateway_cfg "$gateway"

    runtime=$(gateway_runtime_file "$gateway")
    if [[ -f "$runtime" ]]; then
        upstream_ns=$(runtime_read_value \
            "$runtime" UPSTREAM_NS_RUNTIME 2>/dev/null || true)
        upstream_tun=$(runtime_read_value \
            "$runtime" UPSTREAM_TUN_RUNTIME 2>/dev/null || true)
        ns_ip=$(runtime_read_value \
            "$runtime" TRANSIT_NS_IP_RUNTIME 2>/dev/null || true)
    fi

    [[ -n "$upstream_ns" ]] ||
        upstream_ns=$(cfg_read_value "$VIA_APP" NS_NAME 2>/dev/null || true)
    [[ -n "$upstream_tun" ]] ||
        upstream_tun=$(vpn_route_iface "$VIA_APP" 2>/dev/null || true)
    [[ -n "$ns_ip" ]] || ns_ip=${TRANSIT_NS_ADDR%/*}

    gateway_host_rules_down || true
    gateway_rule_delete_exact || true
    gateway_remove_legacy_rule || true
    gateway_routes_delete_exact "$ns_ip" || true

    if [[ -n "$upstream_ns" ]] &&
       ip netns list 2>/dev/null |
           awk '{print $1}' | grep -Fxq "$upstream_ns"; then
        [[ -z "$upstream_tun" ]] ||
            gateway_namespace_rules_down \
                "$upstream_ns" "$upstream_tun" || true
        ip -n "$upstream_ns" route del "$CLIENT_POOL" \
            2>/dev/null || true
        ip -n "$upstream_ns" link del "$GATEWAY_VETH_NS" \
            2>/dev/null || true
    fi

    gateway_delete_veth_everywhere "$GATEWAY_VETH_HOST"
    rm -rf "$(gateway_runtime_dir "$gateway")"
}

gateway_up() {
    require_root
    local gateway=$1 upstream_data upstream_ns upstream_tun
    local host_ip ns_ip runtime

    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"

    upstream_data=$(ensure_upstream_ready "$gateway" "$VIA_APP")
    IFS='|' read -r upstream_ns upstream_tun <<<"$upstream_data"
    [[ -n "$upstream_ns" && -n "$upstream_tun" ]] ||
        die "Gateway upstream '$VIA_APP' has no active tunnel."

    gateway_down_locked "$gateway" >/dev/null 2>&1 || true
    load_gateway_cfg "$gateway"
    gateway_delete_veth_everywhere "$GATEWAY_VETH_HOST"

    host_ip=${TRANSIT_HOST_ADDR%/*}
    ns_ip=${TRANSIT_NS_ADDR%/*}
    runtime=$(gateway_runtime_file "$gateway")
    install -d -o nobody -g nogroup -m 0750 \
        "$(gateway_runtime_dir "$gateway")"

    ip link add "$GATEWAY_VETH_HOST" \
        type veth peer name "$GATEWAY_VETH_NS"
    ip addr add "$TRANSIT_HOST_ADDR" dev "$GATEWAY_VETH_HOST"
    ip link set "$GATEWAY_VETH_HOST" up
    sysctl -q -w \
        "net.ipv4.conf.${GATEWAY_VETH_HOST}.rp_filter=2"

    ip link set "$GATEWAY_VETH_NS" netns "$upstream_ns"
    ip -n "$upstream_ns" addr add \
        "$TRANSIT_NS_ADDR" dev "$GATEWAY_VETH_NS"
    ip -n "$upstream_ns" link set "$GATEWAY_VETH_NS" up
    ip netns exec "$upstream_ns" sysctl -q -w \
        "net.ipv4.conf.${GATEWAY_VETH_NS}.rp_filter=2"
    ip -n "$upstream_ns" route replace "$CLIENT_POOL" \
        via "$host_ip" dev "$GATEWAY_VETH_NS"

    sysctl -q -w net.ipv4.ip_forward=1
    ip netns exec "$upstream_ns" sysctl -q -w net.ipv4.ip_forward=1

    gateway_rule_delete_exact || true
    gateway_remove_legacy_rule || true
    gateway_routes_delete_exact "$ns_ip" || true
    ip route add table "$ROUTE_TABLE" \
        default via "$ns_ip" dev "$GATEWAY_VETH_HOST" metric 10
    ip route add table "$ROUTE_TABLE" \
        blackhole default metric 32767

    gateway_namespace_rules_up "$upstream_ns" "$upstream_tun"

    {
        printf 'UPSTREAM_APP_RUNTIME=%q\n' "$VIA_APP"
        printf 'UPSTREAM_NS_RUNTIME=%q\n' "$upstream_ns"
        printf 'UPSTREAM_TUN_RUNTIME=%q\n' "$upstream_tun"
        printf 'TRANSIT_NS_IP_RUNTIME=%q\n' "$ns_ip"
    } >"$runtime"
    chown root:root "$runtime"
    chmod 0600 "$runtime"

    release_lock "gateway-$gateway"
    log "Gateway '$gateway' data plane is ready through '$VIA_APP/$upstream_tun'."
}

gateway_down() {
    require_root
    local gateway=$1
    acquire_lock "gateway-$gateway"
    gateway_down_locked "$gateway"
    release_lock "gateway-$gateway"
}

gateway_tun_up() {
    require_root
    local gateway=$1 tunnel_dev=${dev:-}
    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"

    [[ -n "$tunnel_dev" ]] || tunnel_dev=$GATEWAY_TUN
    if [[ "$tunnel_dev" != "$GATEWAY_TUN" ]]; then
        release_lock "gateway-$gateway"
        die "Gateway '$gateway' opened unexpected interface '$tunnel_dev'."
    fi

    sysctl -q -w \
        "net.ipv4.conf.${tunnel_dev}.rp_filter=2" || true

    # Match both the server TUN and client pool. Source-only matching could
    # capture unrelated host-generated packets that use an address from the pool.
    gateway_rule_delete_exact || true
    ip rule add priority "$RULE_PRIORITY" \
        iif "$tunnel_dev" \
        from "$CLIENT_POOL" \
        lookup "$ROUTE_TABLE"

    gateway_host_rules_up
    release_lock "gateway-$gateway"
}

gateway_server_exec() {
    require_root
    local gateway=$1 config
    load_gateway_cfg "$gateway"
    config=$(gateway_server_config "$gateway")
    [[ -f "$config" ]] || die "Gateway server config is missing: $config"
    exec /usr/sbin/openvpn --config "$config"
}

gateway_start() {
    require_root
    local gateway=$1 deadline pki
    validate_gateway_name "$gateway"
    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"
    ensure_upstream_ready "$gateway" "$VIA_APP" >/dev/null

    write_gateway_unit_dropin "$gateway"
    gateway_write_server_config "$gateway"
    systemctl daemon-reload
    systemctl enable --now "nns-gateway-crl-refresh@${gateway}.timer" \
        >/dev/null 2>&1 || true

    pki=$(gateway_pki_dir "$gateway")
    if ! openssl crl -in "$pki/crl.pem" \
        -noout -checkend 604800 >/dev/null 2>&1; then
        gateway_crl_refresh "$gateway"
    fi
    release_lock "gateway-$gateway"

    if systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
        log "Gateway '$gateway' is already running."
        return 0
    fi

    if ! systemctl start "nns-gateway@${gateway}.service"; then
        warn "Gateway '$gateway' failed to start."
        journalctl -u "nns-gateway@${gateway}.service" \
            -n 80 -o cat --no-pager >&2 2>/dev/null || true
        return 1
    fi

    deadline=$((SECONDS + 8))
    while (( SECONDS < deadline )); do
        if ip link show dev "$GATEWAY_TUN" up >/dev/null 2>&1 &&
           systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
            log "Started gateway '$gateway' on $PUBLIC_HOST:$PUBLIC_PORT/$LISTEN_PROTO via $VIA_APP."
            return 0
        fi
        systemctl is-failed --quiet "nns-gateway@${gateway}.service" &&
            break
        sleep 0.25
    done

    warn "Gateway service started but its OpenVPN interface '$GATEWAY_TUN' is not ready."
    journalctl -u "nns-gateway@${gateway}.service" \
        -n 80 -o cat --no-pager >&2 2>/dev/null || true
    return 1
}

gateway_stop() {
    require_root
    local gateway=$1
    load_gateway_cfg "$gateway"
    systemctl stop "nns-gateway@${gateway}.service" 2>/dev/null || true
    systemctl reset-failed "nns-gateway@${gateway}.service" 2>/dev/null || true
    gateway_down "$gateway" >/dev/null 2>&1 || true
    log "Stopped gateway '$gateway'."
}

gateways_using_app() {
    local app=$1 dir gateway via
    shopt -s nullglob
    for dir in "$GATEWAY_BASE_DIR"/*; do
        [[ -f "$dir/gateway.cfg" ]] || continue
        gateway=$(basename "$dir")
        via=$(gateway_cfg_value "$gateway" VIA_APP 2>/dev/null || true)
        [[ "$via" == "$app" ]] && printf '%s\n' "$gateway"
    done
}

stop_gateways_via_app() {
    local app=$1 gateway
    while IFS= read -r gateway; do
        [[ -n "$gateway" ]] || continue
        if systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
            warn "Stopping gateway '$gateway' before its upstream app '$app'."
            gateway_stop "$gateway"
        fi
    done < <(gateways_using_app "$app")
}

gateway_ca_snapshot() {
    local pki=$1 backup=$2 optional owner

    [[ ! -L "$backup" ]] || return 1
    if (( EUID == 0 )); then
        install -d -o root -g root -m 0700 "$backup" || return 1
    else
        # This path is used only by source-level function tests. Production
        # callers are root-only gateway lifecycle operations.
        [[ "${NNS_APP_SOURCE_ONLY:-0}" == 1 ]] || return 1
        install -d -m 0700 "$backup" || return 1
        owner=$(stat -c '%u' "$backup")
        [[ "$owner" == "$EUID" ]] || return 1
    fi

    cp -a \
        "$pki/index.txt" \
        "$pki/serial" \
        "$pki/crlnumber" \
        "$pki/newcerts" \
        "$backup/" || return 1

    for optional in \
        "$pki/index.txt.attr" \
        "$pki/index.txt.old" \
        "$pki/index.txt.attr.old" \
        "$pki/serial.old" \
        "$pki/crlnumber.old"; do
        [[ -e "$optional" ]] || continue
        cp -a "$optional" "$backup/" || return 1
    done
}

gateway_ca_restore() {
    local pki=$1 backup=$2 optional
    rm -f \
        "$pki/index.txt" \
        "$pki/index.txt.attr" \
        "$pki/index.txt.old" \
        "$pki/index.txt.attr.old" \
        "$pki/serial" \
        "$pki/serial.old" \
        "$pki/crlnumber" \
        "$pki/crlnumber.old"
    cp -a \
        "$backup/index.txt" \
        "$backup/serial" \
        "$backup/crlnumber" \
        "$pki/" || return 1

    for optional in \
        "$backup/index.txt.attr" \
        "$backup/index.txt.old" \
        "$backup/index.txt.attr.old" \
        "$backup/serial.old" \
        "$backup/crlnumber.old"; do
        [[ -e "$optional" ]] || continue
        cp -a "$optional" "$pki/" || return 1
    done

    rm -rf "$pki/newcerts"
    cp -a "$backup/newcerts" "$pki/newcerts"
}

gateway_client_add() {
    require_root
    local gateway=$1 client=$2 pki final staging backup
    local metadata cert_serial="" rc=0

    validate_gateway_name "$gateway"
    validate_gateway_client_name "$client"
    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"

    pki=$(gateway_pki_dir "$gateway")
    final=$(gateway_client_dir "$gateway" "$client")
    if [[ -e "$final" ]]; then
        release_lock "gateway-$gateway"
        die "Gateway client '$client' already exists."
    fi

    staging=$(mktemp -d \
        "$(gateway_clients_dir "$gateway")/.${client}.new.XXXXXX")
    backup=$(mktemp -d "$(gateway_dir "$gateway")/.ca-db.XXXXXX")
    if ! gateway_ca_snapshot "$pki" "$backup"; then
        rm -rf "$backup" "$staging"
        release_lock "gateway-$gateway"
        die "Failed to snapshot the gateway CA database."
    fi

    openssl genpkey -algorithm RSA \
        -pkeyopt rsa_keygen_bits:3072 \
        -out "$staging/client.key" >/dev/null 2>&1 || rc=1

    if (( rc == 0 )); then
        openssl req -new -sha256 \
            -key "$staging/client.key" \
            -subj "/CN=$client" \
            -out "$staging/client.csr" >/dev/null 2>&1 || rc=1
    fi

    if (( rc == 0 )); then
        openssl ca -batch -notext \
            -config "$pki/openssl.cnf" \
            -extensions client_cert \
            -in "$staging/client.csr" \
            -out "$staging/client.crt" >/dev/null 2>&1 || rc=1
    fi

    if (( rc == 0 )); then
        metadata=$(printf '%s' "$client" | base64 -w0) || rc=1
    fi
    if (( rc == 0 )); then
        openvpn \
            --tls-crypt-v2 "$pki/tls-crypt-v2-server.key" \
            --genkey tls-crypt-v2-client \
            "$staging/tls-crypt-v2-client.key" \
            "$metadata" >/dev/null 2>&1 || rc=1
    fi

    if (( rc == 0 )); then
        cert_serial=$(openssl x509 \
            -in "$staging/client.crt" \
            -noout -serial 2>/dev/null | cut -d= -f2) || rc=1
        [[ -n "$cert_serial" ]] || rc=1
    fi

    if (( rc == 0 )); then
        rm -f "$staging/client.csr" || rc=1
    fi
    if (( rc == 0 )); then
        cat >"$staging/client.cfg" <<CLIENT_CFG_EOF || rc=1
CLIENT_NAME="$client"
STATUS="active"
CERT_SERIAL="$cert_serial"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CLIENT_CFG_EOF
    fi

    if (( rc == 0 )); then
        chown -R root:root "$staging" || rc=1
        chmod 0700 "$staging" || rc=1
        chmod 0600 \
            "$staging/client.key" \
            "$staging/tls-crypt-v2-client.key" \
            "$staging/client.cfg" || rc=1
        chmod 0644 "$staging/client.crt" || rc=1
    fi

    if (( rc == 0 )); then
        mv "$staging" "$final" || rc=1
    fi

    if (( rc != 0 )); then
        gateway_ca_restore "$pki" "$backup" ||
            warn "Could not fully restore the CA database after client issuance failed."
        rm -rf "$backup" "$staging"
        release_lock "gateway-$gateway"
        die "Failed to issue client '$client'; no client was installed."
    fi

    rm -rf "$backup"
    release_lock "gateway-$gateway"

    log "Added client '$client' to gateway '$gateway'."
    log "Export it with:"
    log "  sudo nns-app gateway client export $gateway $client --output ~/$gateway-$client.ovpn"
}

gateway_client_load() {
    local gateway=$1 client=$2 cdir file owner mode mode_octal
    validate_gateway_client_name "$client"
    cdir=$(gateway_client_dir "$gateway" "$client")
    file="$cdir/client.cfg"
    [[ -f "$file" ]] ||
        die "Gateway client '$client' does not exist."

    owner=$(stat -c '%u' "$file")
    mode=$(stat -c '%a' "$file")
    [[ "$owner" == 0 ]] ||
        die "Unsafe client config owner for $file."
    mode_octal=$((8#$mode))
    (( (mode_octal & 0077) == 0 )) ||
        die "Unsafe client config permissions on $file."

    reset_gateway_client_vars
    # shellcheck disable=SC1090
    source "$file"
    [[ "${CLIENT_NAME:-}" == "$client" ]] ||
        die "CLIENT_NAME mismatch in $file."
}

gateway_client_export() {
    require_root
    local gateway=$1 client=$2 output=$3 cdir pki tmp proto owner
    validate_gateway_name "$gateway"
    validate_gateway_client_name "$client"
    acquire_lock "gateway-$gateway" shared
    load_gateway_cfg "$gateway"
    gateway_client_load "$gateway" "$client"
    [[ "${STATUS:-}" == active ]] ||
        die "Client '$client' is revoked and cannot be exported."

    [[ -n "$output" ]] || die "--output is required."
    output=$(readlink -m "$output")
    [[ ! -e "$output" ]] || die "Output already exists: $output"
    [[ -d "$(dirname "$output")" ]] || die "Output directory does not exist: $(dirname "$output")"

    cdir=$(gateway_client_dir "$gateway" "$client")
    pki=$(gateway_pki_dir "$gateway")
    tmp=$(mktemp)

    if [[ "$LISTEN_PROTO" == tcp ]]; then
        proto=tcp-client
    else
        proto=udp
    fi

    {
        printf '# nns-app managed gateway profile: %s / %s\n' "$gateway" "$client"
        printf 'client\n'
        printf 'dev tun\n'
        printf 'proto %s\n' "$proto"
        printf 'remote %s %s\n' "$PUBLIC_HOST" "$PUBLIC_PORT"
        printf 'nobind\n'
        printf 'persist-key\n'
        printf 'persist-tun\n'
        printf 'auth-nocache\n'
        printf 'remote-cert-tls server\n'
        printf 'verify-x509-name %s name\n' "$SERVER_CN"
        printf 'tls-version-min 1.2\n'
        printf 'data-ciphers AES-256-GCM:CHACHA20-POLY1305:AES-128-GCM\n'
        printf 'auth SHA256\n'
        printf 'allow-compression no\n'
        printf 'disable-dco\n'
        if [[ "$LISTEN_PROTO" == udp ]]; then
            printf 'explicit-exit-notify 2\n'
        fi
        printf 'verb 3\n'
        printf '\n<ca>\n'
        cat "$pki/ca.crt"
        printf '</ca>\n\n<cert>\n'
        cat "$cdir/client.crt"
        printf '</cert>\n\n<key>\n'
        cat "$cdir/client.key"
        printf '</key>\n\n<tls-crypt-v2>\n'
        cat "$cdir/tls-crypt-v2-client.key"
        printf '</tls-crypt-v2>\n'
    } >"$tmp"

    owner=${SUDO_USER:-root}
    if [[ "$owner" != root ]] && id "$owner" >/dev/null 2>&1; then
        install -o "$owner" -g "$(id -gn "$owner")" -m 0600 "$tmp" "$output"
    else
        install -o root -g root -m 0600 "$tmp" "$output"
    fi
    rm -f "$tmp"
    release_lock "gateway-$gateway"

    log "Exported client '$client' from gateway '$gateway'."
    log "Profile: $output"
    log "Import on the local box with:"
    log "  sudo nns-app install remote-$gateway"
    log "  sudo nns-app add remote-$gateway $output"
}

gateway_client_revoke() {
    require_root
    local gateway=$1 client=$2 cdir pki tmp="" restart=no backup
    local revoked_at rc=0

    validate_gateway_name "$gateway"
    validate_gateway_client_name "$client"
    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"
    gateway_client_load "$gateway" "$client"
    [[ "${STATUS:-}" == active ]] ||
        die "Client '$client' is already revoked."

    cdir=$(gateway_client_dir "$gateway" "$client")
    pki=$(gateway_pki_dir "$gateway")
    backup=$(mktemp -d "$(gateway_dir "$gateway")/.ca-db.XXXXXX")

    if ! gateway_ca_snapshot "$pki" "$backup"; then
        rm -rf "$backup"
        release_lock "gateway-$gateway"
        die "Failed to snapshot the gateway CA database."
    fi

    openssl ca -batch \
        -config "$pki/openssl.cnf" \
        -revoke "$cdir/client.crt" >/dev/null 2>&1 || rc=1
    if (( rc == 0 )); then
        gateway_generate_crl_at "$pki" || rc=1
    fi

    revoked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if (( rc == 0 )); then
        tmp=$(mktemp) || rc=1
    fi
    if (( rc == 0 )); then
        awk -v revoked_at="$revoked_at" '
            /^STATUS=/ {
                print "STATUS=\"revoked\""
                found_status=1
                next
            }
            /^REVOKED_AT=/ { next }
            { print }
            END {
                if (!found_status)
                    print "STATUS=\"revoked\""
                print "REVOKED_AT=\"" revoked_at "\""
            }
        ' "$cdir/client.cfg" >"$tmp" || rc=1
    fi
    if (( rc == 0 )); then
        install -o root -g root -m 0600 \
            "$tmp" "$cdir/client.cfg" || rc=1
    fi

    if (( rc != 0 )); then
        gateway_ca_restore "$pki" "$backup" ||
            warn "Could not fully restore the CA database after revocation failed."
        [[ -z "$tmp" ]] || rm -f "$tmp"
        rm -rf "$backup"
        release_lock "gateway-$gateway"
        die "Failed to revoke client '$client'; its active state was preserved."
    fi

    rm -f "$tmp"
    rm -rf "$backup"
    systemctl is-active --quiet "nns-gateway@${gateway}.service" &&
        restart=yes
    release_lock "gateway-$gateway"

    if [[ "$restart" == yes ]]; then
        if ! systemctl restart "nns-gateway@${gateway}.service"; then
            warn "Client '$client' is revoked, but gateway '$gateway' failed to restart."
            return 1
        fi
    fi
    log "Revoked client '$client' on gateway '$gateway'."
}

gateway_client_list() {
    require_root
    local gateway=$1 dir client status serial created
    validate_gateway_name "$gateway"
    acquire_lock "gateway-$gateway" shared
    load_gateway_cfg "$gateway"
    printf '%-24s %-10s %-20s %s\n' "Client" "Status" "Serial" "Created"
    printf '%-24s %-10s %-20s %s\n' "------------------------" "----------" "--------------------" "--------------------"
    local found=0
    shopt -s nullglob
    for dir in "$(gateway_clients_dir "$gateway")"/*; do
        [[ -f "$dir/client.cfg" ]] || continue
        client=$(basename "$dir")
        gateway_client_load "$gateway" "$client"
        status=${STATUS:-unknown}
        serial=${CERT_SERIAL:-unknown}
        created=${CREATED_AT:-unknown}
        printf '%-24s %-10s %-20s %s\n' "$client" "$status" "$serial" "$created"
        found=1
    done
    (( found )) || log "No clients configured for gateway '$gateway'."
    release_lock "gateway-$gateway"
}

gateway_connected_clients() {
    local gateway=$1 status_file
    status_file=$(gateway_status_file "$gateway")
    [[ -s "$status_file" ]] || return 0
    python3 - "$status_file" <<'PY_GATEWAY_STATUS'
import csv
import sys
from pathlib import Path

rows = list(
    csv.reader(
        Path(sys.argv[1]).read_text(
            encoding="utf-8",
            errors="replace",
        ).splitlines(),
        delimiter="\t",
    )
)
header = None
clients = []
for row in rows:
    if not row:
        continue
    if row[0] == "HEADER" and len(row) > 2 and row[1] == "CLIENT_LIST":
        header = row[2:]
    elif row[0] == "CLIENT_LIST":
        values = row[1:]
        if header:
            item = dict(zip(header, values))
            clients.append(item)
        else:
            clients.append({"Common Name": values[0] if values else "unknown"})

for item in clients:
    cn = item.get("Common Name", "unknown")
    real = item.get("Real Address", "-")
    virtual = item.get("Virtual Address", "-")
    rx = item.get("Bytes Received", "0")
    tx = item.get("Bytes Sent", "0")
    since = item.get("Connected Since", item.get("Connected Since (time_t)", "-"))
    print(f"{cn}|{real}|{virtual}|{rx}|{tx}|{since}")
PY_GATEWAY_STATUS
}

gateway_listener_ready() {
    local pid=$1 proto_flag
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$LISTEN_PROTO" == tcp ]] &&
        proto_flag=lntp || proto_flag=lnup

    ss -H -"$proto_flag" 2>/dev/null |
        grep -Eq "[:.]${LISTEN_PORT}[[:space:]].*pid=${pid},"
}

gateway_policy_ready() {
    local rule_pattern_a rule_pattern_b
    rule_pattern_a="^${RULE_PRIORITY}:[[:space:]]+from ${CLIENT_POOL}[[:space:]]+iif ${GATEWAY_TUN}[[:space:]]+lookup ${ROUTE_TABLE}([[:space:]]|$)"
    rule_pattern_b="^${RULE_PRIORITY}:[[:space:]]+from ${CLIENT_POOL}[[:space:]]+lookup ${ROUTE_TABLE}[[:space:]]+iif ${GATEWAY_TUN}([[:space:]]|$)"

    ip rule show | grep -Eq "$rule_pattern_a|$rule_pattern_b" || return 1
    ip route show table "$ROUTE_TABLE" |
        grep -q "default via ${TRANSIT_NS_ADDR%/*} dev $GATEWAY_VETH_HOST" ||
        return 1
    ip route show table "$ROUTE_TABLE" |
        grep -q '^blackhole default' || return 1
}

gateway_firewall_ready() {
    local gateway=$1 upstream_ns=$2 upstream_tun=$3
    local comment="nns-app:gateway:$gateway"
    [[ -n "$upstream_ns" && -n "$upstream_tun" ]] || return 1

    iptables -w -t filter -C FORWARD \
        -m comment --comment "$comment:forward" \
        -j "$HOST_FWD_CHAIN" 2>/dev/null || return 1
    iptables -w -t filter -C "$HOST_FWD_CHAIN" \
        -i "$GATEWAY_TUN" -s "$CLIENT_POOL" \
        -o "$GATEWAY_VETH_HOST" -j ACCEPT 2>/dev/null || return 1
    iptables -w -t filter -C "$HOST_FWD_CHAIN" \
        -i "$GATEWAY_TUN" -s "$CLIENT_POOL" \
        -j DROP 2>/dev/null || return 1

    iptables -w -t mangle -C FORWARD \
        -m comment --comment "$comment:mangle" \
        -j "$HOST_MANGLE_CHAIN" 2>/dev/null || return 1
    iptables -w -t mangle -C "$HOST_MANGLE_CHAIN" \
        -i "$GATEWAY_TUN" -s "$CLIENT_POOL" \
        -o "$GATEWAY_VETH_HOST" -p tcp \
        --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || return 1

    ip netns exec "$upstream_ns" iptables -w -t filter -C FORWARD \
        -m comment --comment "$comment:ns-forward" \
        -j "$NS_FWD_CHAIN" 2>/dev/null || return 1
    ip netns exec "$upstream_ns" iptables -w -t filter \
        -C "$NS_FWD_CHAIN" \
        -i "$GATEWAY_VETH_NS" -s "$CLIENT_POOL" \
        -o "$upstream_tun" \
        -j ACCEPT 2>/dev/null || return 1
    ip netns exec "$upstream_ns" iptables -w -t filter \
        -C "$NS_FWD_CHAIN" \
        -i "$GATEWAY_VETH_NS" -s "$CLIENT_POOL" \
        -j DROP 2>/dev/null || return 1

    ip netns exec "$upstream_ns" iptables -w -t nat -C POSTROUTING \
        -m comment --comment "$comment:ns-nat" \
        -j "$NS_NAT_CHAIN" 2>/dev/null || return 1
    ip netns exec "$upstream_ns" iptables -w -t nat \
        -C "$NS_NAT_CHAIN" \
        -s "$CLIENT_POOL" -o "$upstream_tun" \
        -j MASQUERADE 2>/dev/null || return 1

    ip netns exec "$upstream_ns" iptables -w -t mangle -C FORWARD \
        -m comment --comment "$comment:ns-mangle" \
        -j "$NS_MANGLE_CHAIN" 2>/dev/null || return 1
}

gateway_status() {
    require_root
    local gateway=$1 unit state sub result pid restarts health diagnosis
    local upstream_state=offline upstream_iface="" upstream_ns=""
    local listening=no tunnel=no connected=0 line
    local policy_ok=no veth_ok=no firewall_ok=no
    local crl_next=unknown crl_epoch=0 now
    now=$(date +%s)

    validate_gateway_name "$gateway"
    acquire_lock "gateway-$gateway" shared
    load_gateway_cfg "$gateway"
    unit="nns-gateway@${gateway}.service"
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    sub=$(systemctl show "$unit" -p SubState --value 2>/dev/null || true)
    result=$(systemctl show "$unit" -p Result --value 2>/dev/null || true)
    pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)
    restarts=$(systemctl show "$unit" -p NRestarts --value 2>/dev/null || true)

    if app_is_started "$VIA_APP" && vpn_route_ready "$VIA_APP"; then
        upstream_state=ready
        upstream_iface=$(vpn_route_iface "$VIA_APP" 2>/dev/null || true)
        upstream_ns=$(cfg_read_value "$VIA_APP" NS_NAME 2>/dev/null || true)
    elif app_is_started "$VIA_APP"; then
        upstream_state="started but tunnel offline"
    fi

    ip link show dev "$GATEWAY_TUN" up >/dev/null 2>&1 &&
        tunnel=yes
    gateway_listener_ready "${pid:-0}" && listening=yes

    if ip link show "$GATEWAY_VETH_HOST" up >/dev/null 2>&1 &&
       [[ -n "$upstream_ns" ]] &&
       ip -n "$upstream_ns" link show "$GATEWAY_VETH_NS" \
           up >/dev/null 2>&1; then
        veth_ok=yes
    fi

    gateway_policy_ready && policy_ok=yes
    gateway_firewall_ready "$gateway" "$upstream_ns" "$upstream_iface" &&
        firewall_ok=yes

    while IFS= read -r line; do
        [[ -n "$line" ]] && connected=$((connected + 1))
    done < <(gateway_connected_clients "$gateway")

    crl_next=$(openssl crl \
        -in "$(gateway_pki_dir "$gateway")/crl.pem" \
        -noout -nextupdate 2>/dev/null |
        sed 's/^nextUpdate=//' || true)
    if [[ -n "$crl_next" ]]; then
        crl_epoch=$(date -d "$crl_next" +%s 2>/dev/null || printf 0)
    fi

    if [[ "$state" == failed || "$result" == failed ]]; then
        health=FAILED
        diagnosis="The managed OpenVPN gateway service failed."
    elif [[ "$state" != active ]]; then
        health=STOPPED
        diagnosis="The gateway service is not running."
    elif [[ "$upstream_state" != ready ]]; then
        health=DEGRADED
        diagnosis="The selected remote NNS exit is unavailable."
    elif [[ "$tunnel" != yes || "$listening" != yes ]]; then
        health=STARTING
        diagnosis="The service is active, but its OpenVPN listener or TUN is not ready."
    elif [[ "$veth_ok" != yes ||
            "$policy_ok" != yes ||
            "$firewall_ok" != yes ]]; then
        health=DEGRADED
        diagnosis="The OpenVPN server is running, but the managed data plane is incomplete."
    elif (( crl_epoch > 0 && crl_epoch <= now )); then
        health=DEGRADED
        diagnosis="The gateway CRL has expired; refresh it before accepting clients."
    else
        health=READY
        diagnosis="The listener and managed data plane are ready; public reachability is not tested locally."
    fi

    printf 'Gateway:           %s\n' "$gateway"
    printf 'Health:            %s\n' "$health"
    printf 'Diagnosis:         %s\n' "$diagnosis"
    printf 'Backend:           OpenVPN server\n'
    printf 'Public endpoint:   %s:%s/%s\n' \
        "$PUBLIC_HOST" "$PUBLIC_PORT" "$LISTEN_PROTO"
    printf 'Local listener:    0.0.0.0:%s/%s (%s; pid=%s)\n' \
        "$LISTEN_PORT" "$LISTEN_PROTO" "$listening" "${pid:-0}"
    printf 'Client pool:       %s\n' "$CLIENT_POOL"
    printf 'Remote NNS exit:   %s (%s)\n' \
        "$VIA_APP" "$upstream_state"
    [[ -z "$upstream_iface" ]] ||
        printf 'Exit tunnel:       %s\n' "$upstream_iface"
    printf 'Server interface:  %s (%s)\n' \
        "$GATEWAY_TUN" "$tunnel"
    printf 'Transit veth:      %s\n' "$veth_ok"
    printf 'Policy routing:    %s\n' "$policy_ok"
    printf 'Firewall chains:  %s\n' "$firewall_ok"
    printf 'Service:           %s/%s; result=%s; restarts=%s\n' \
        "${state:-unknown}" "${sub:-unknown}" \
        "${result:-unknown}" "${restarts:-0}"
    printf 'Connected clients: %s\n' "$connected"
    printf 'CRL next update:   %s\n' "${crl_next:-unknown}"

    if (( connected > 0 )); then
        printf '\nActive clients:\n'
        printf '%-20s %-24s %-16s %-12s %-12s %s\n' \
            Name 'Real address' 'VPN address' RX TX Connected
        while IFS='|' read -r cn real virtual rx tx since; do
            printf '%-20s %-24s %-16s %-12s %-12s %s\n' \
                "$cn" "$real" "$virtual" \
                "$(human_bytes "$rx")" "$(human_bytes "$tx")" "$since"
        done < <(gateway_connected_clients "$gateway")
    fi

    if [[ "$health" != READY ]]; then
        local tmp
        tmp=$(mktemp)
        unit_current_log "$unit" 200 >"$tmp"
        print_status_log_cut \
            "Important gateway log cuts:" \
            "$tmp" \
            'error|warning|failed|fatal|TLS Error|VERIFY ERROR|AUTH_FAILED|Cannot|Options error|route|iptables|permission|address already in use|Initialization Sequence' \
            22
        rm -f "$tmp"
    fi
    release_lock "gateway-$gateway"
}

gateway_list() {
    require_root
    local dir gateway state via endpoint pool found=0
    printf '%-18s %-10s %-18s %-26s %s\n' \
        "Gateway" "Status" "Via" "Public endpoint" "Client pool"
    printf '%-18s %-10s %-18s %-26s %s\n' \
        "------------------" "----------" "------------------" "--------------------------" "------------------"
    shopt -s nullglob
    for dir in "$GATEWAY_BASE_DIR"/*; do
        [[ -f "$dir/gateway.cfg" ]] || continue
        gateway=$(basename "$dir")
        load_gateway_cfg "$gateway"
        state=$(systemctl is-active "nns-gateway@${gateway}.service" 2>/dev/null || true)
        [[ "$state" == active ]] || state=stopped
        endpoint="$PUBLIC_HOST:$PUBLIC_PORT/$LISTEN_PROTO"
        printf '%-18s %-10s %-18s %-26s %s\n' \
            "$gateway" "$state" "$VIA_APP" "$endpoint" "$CLIENT_POOL"
        found=1
    done
    (( found )) || log "No managed gateways configured."
}

gateway_remove() {
    require_root
    local gateway=$1
    validate_gateway_name "$gateway"
    acquire_lock global
    load_gateway_cfg "$gateway"

    # Stop future CRL refreshes before taking the gateway lock. A refresh that
    # already holds the lock is allowed to finish before removal continues.
    systemctl disable --now \
        "nns-gateway-crl-refresh@${gateway}.timer" \
        >/dev/null 2>&1 || true

    # Release the gateway lock before asking systemd to stop the service.
    # ExecStopPost runs _gateway-down in another process and must acquire it.
    gateway_stop "$gateway"
    acquire_lock "gateway-$gateway"

    systemctl disable "nns-gateway@${gateway}.service" \
        >/dev/null 2>&1 || true
    rm -rf \
        "$(gateway_dropin_dir "$gateway")" \
        "$(gateway_dir "$gateway")" \
        "$(gateway_runtime_dir "$gateway")"
    systemctl daemon-reload

    release_lock "gateway-$gateway"
    release_lock global
    log "Removed gateway '$gateway', including its CA and all client private keys."
}


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

prepare_namespaced_desktop_mounts() {
    # `ip netns exec` creates a private mount namespace for per-namespace
    # configuration binds. Snap launchers also require cgroup2 and securityfs
    # there. These mounts are command-local and disappear when it exits.
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

    # Refuse direct invocation: this helper is valid only after `ip netns exec`
    # has entered the application environment's network namespace.
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

    configured_via=$(effective_via_for_app "$app" __default__)
    runtime_via=$(runtime_via_for_app "$app" 2>/dev/null || printf '%s' "$configured_via")

    if [[ -n "$profile_name" ]]; then
        profile_file="$(profiles_dir "$app")/$profile_name"
        if [[ -f "$profile_file" ]]; then
            type=$(vpn_type_for_app "$app" 2>/dev/null || true)
            type_label=$(vpn_type_label "${type:-unknown}")
        fi
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

    if [[ "$ns_state" == failed || "$ns_result" == failed ]]; then
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
            *) diagnosis="The VPN service is active, but no usable tunnel route exists." ;;
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
    [[ -z "$ns_since" ]] || printf 'Namespace active:  %s\n' "$ns_since"
    [[ -z "$vpn_since" ]] || printf 'VPN active:        %s\n' "$vpn_since"
    printf 'Kill switch:       %s\n' "${KILLSWITCH:-unknown}"
    printf 'DNS servers:       %s\n' "${DNS_SERVERS:-not configured}"
    printf 'Tunnel interface:  %s\n' "${route_iface:-not ready}"
    printf 'Tunnel IPv4:       %s\n' "${local_ip:-not assigned}"
    printf 'External IPv4:     %s\n' "${external_ip:-unavailable}"
    printf 'Ping data path:    %s\n' "$ping_ok"

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



# nns-app source module: CLI parser and source-only guard.
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

    # Underscore-prefixed commands are implementation entry points for
    # root-owned systemd units.
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
        _gateway-up)
            require_root
            [[ $# -eq 2 ]] || die "_gateway-up requires gateway_name."
            gateway_up "$2"
            exit
            ;;
        _gateway-server)
            require_root
            [[ $# -eq 2 ]] || die "_gateway-server requires gateway_name."
            gateway_server_exec "$2"
            exit
            ;;
        _gateway-down)
            require_root
            [[ $# -eq 2 ]] || die "_gateway-down requires gateway_name."
            gateway_down "$2"
            exit
            ;;
        _gateway-tun-up)
            require_root
            [[ $# -eq 2 ]] || die "_gateway-tun-up requires gateway_name."
            gateway_tun_up "$2"
            exit
            ;;
        _gateway-crl-refresh)
            require_root
            [[ $# -eq 2 ]] || die "_gateway-crl-refresh requires gateway_name."
            gateway_crl_refresh "$2"
            exit
            ;;
        _wait-online)
            require_root
            [[ $# -eq 3 ]] || die "_wait-online requires app_name and timeout."
            wait_online "$2" "$3" ||
                die "NNS app '$2' did not become online within $3 seconds."
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
        status)
            [[ $# -eq 2 ]] || die "Usage: nns-app status <app_name>"
            status_app "$2"
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
        gateway)
            (( $# >= 2 )) || die "Usage: nns-app gateway <create|start|stop|status|list|remove|client> ..."
            case "$2" in
                create)
                    (( $# >= 3 )) ||
                        die "Usage: nns-app gateway create <name> --via <app> --listen tcp|udp:<port> --public <host>:<port> [--pool CIDR] [--dns \"IP ...\"]"
                    local gw_name=$3 gw_via="" gw_listen="" gw_public="" gw_pool="" gw_dns="1.1.1.1 9.9.9.9"
                    shift 3
                    while (( $# > 0 )); do
                        case "$1" in
                            --via)
                                (( $# >= 2 )) || die "--via requires an NNS app name."
                                gw_via=$2; shift 2 ;;
                            --via=*)
                                gw_via=${1#--via=}; shift ;;
                            --listen)
                                (( $# >= 2 )) || die "--listen requires tcp:<port> or udp:<port>."
                                gw_listen=$2; shift 2 ;;
                            --listen=*)
                                gw_listen=${1#--listen=}; shift ;;
                            --public)
                                (( $# >= 2 )) || die "--public requires host:port."
                                gw_public=$2; shift 2 ;;
                            --public=*)
                                gw_public=${1#--public=}; shift ;;
                            --pool)
                                (( $# >= 2 )) || die "--pool requires an IPv4 CIDR."
                                gw_pool=$2; shift 2 ;;
                            --pool=*)
                                gw_pool=${1#--pool=}; shift ;;
                            --dns)
                                (( $# >= 2 )) || die "--dns requires a quoted space-separated IPv4 list."
                                gw_dns=$2; shift 2 ;;
                            --dns=*)
                                gw_dns=${1#--dns=}; shift ;;
                            *)
                                die "Unknown gateway create option '$1'."
                                ;;
                        esac
                    done
                    [[ -n "$gw_via" && -n "$gw_listen" && -n "$gw_public" ]] ||
                        die "gateway create requires --via, --listen and --public."
                    gateway_create "$gw_name" "$gw_via" "$gw_listen" "$gw_public" "$gw_pool" "$gw_dns"
                    ;;
                start)
                    [[ $# -eq 3 ]] || die "Usage: nns-app gateway start <gateway_name>"
                    gateway_start "$3"
                    ;;
                stop)
                    [[ $# -eq 3 ]] || die "Usage: nns-app gateway stop <gateway_name>"
                    gateway_stop "$3"
                    ;;
                status)
                    [[ $# -eq 3 ]] || die "Usage: nns-app gateway status <gateway_name>"
                    gateway_status "$3"
                    ;;
                list)
                    [[ $# -eq 2 ]] || die "Usage: nns-app gateway list"
                    gateway_list
                    ;;
                remove)
                    [[ $# -eq 3 ]] || die "Usage: nns-app gateway remove <gateway_name>"
                    gateway_remove "$3"
                    ;;
                client)
                    (( $# >= 3 )) ||
                        die "Usage: nns-app gateway client <add|list|export|revoke> ..."
                    case "$3" in
                        add)
                            [[ $# -eq 5 ]] ||
                                die "Usage: nns-app gateway client add <gateway_name> <client_name>"
                            gateway_client_add "$4" "$5"
                            ;;
                        list)
                            [[ $# -eq 4 ]] ||
                                die "Usage: nns-app gateway client list <gateway_name>"
                            gateway_client_list "$4"
                            ;;
                        export)
                            (( $# >= 6 )) ||
                                die "Usage: nns-app gateway client export <gateway_name> <client_name> --output <file.ovpn>"
                            local export_gateway=$4 export_client=$5 export_output=""
                            shift 5
                            while (( $# > 0 )); do
                                case "$1" in
                                    --output)
                                        (( $# >= 2 )) || die "--output requires a path."
                                        export_output=$2; shift 2 ;;
                                    --output=*)
                                        export_output=${1#--output=}; shift ;;
                                    *)
                                        die "Unknown gateway client export option '$1'."
                                        ;;
                                esac
                            done
                            [[ -n "$export_output" ]] || die "--output is required."
                            gateway_client_export "$export_gateway" "$export_client" "$export_output"
                            ;;
                        revoke)
                            [[ $# -eq 5 ]] ||
                                die "Usage: nns-app gateway client revoke <gateway_name> <client_name>"
                            gateway_client_revoke "$4" "$5"
                            ;;
                        *)
                            die "Unknown gateway client command '$3'."
                            ;;
                    esac
                    ;;
                *)
                    die "Unknown gateway command '$2'."
                    ;;
            esac
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

if [[ "${NNS_APP_SOURCE_ONLY:-0}" != 1 ]]; then
    main "$@"
fi

