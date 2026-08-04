#!/usr/bin/env bash
# nns-app - manage per-application VPN network namespaces on Linux.
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
#   install [<app_name> [--backend inherit] [--via <upstream-app>|host]
#                         [--via-remote <user@host> [--remote-port <port>]]]
#   remove  <app_name>
#   purge
#   list
#   status  <app_name>
#   myip    [<app_name>]
#   add     <app_name> <profile.ovpn|wireguard.conf>
#   add     <app_name> any [country] [--refresh] [--via <upstream-app>|host]
#   start   [-i|--ignore-start-error] <app_name> [--via <upstream-app>|host]
#   stop    <app_name> [--local-only]
#   run     <app_name> <command> [args...]
#   gateway create <gateway> --via <app> --listen tcp|udp:<port>
#                  --public <host>:<port> [--transport direct|stunnel|cloak]
#                  [--server-name <cloak-decoy-host>]
#   remote add|connect|sync|rotate|status ...
#   link import <app> <bundle.nnslink>
#   gateway start|stop|status|list|remove ...
#   gateway client add|list|export|revoke ...
#
# The script installs itself as /usr/local/sbin/nns_app.sh and creates the
# convenience symlink /usr/local/bin/nns-app.

set -Eeuo pipefail
IFS=$'\n\t'

readonly VERSION="1.3.16"
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
readonly DNS_PROXY_UNIT="/etc/systemd/system/nns-dns@.service"
readonly WATCHDOG_SERVICE="/etc/systemd/system/nns-watchdog@.service"
readonly WATCHDOG_TIMER="/etc/systemd/system/nns-watchdog@.timer"
readonly GATEWAY_CRL_SERVICE="/etc/systemd/system/nns-gateway-crl-refresh@.service"
readonly GATEWAY_CRL_TIMER="/etc/systemd/system/nns-gateway-crl-refresh@.timer"
readonly FIREWALLD_ZONE="nns-app"
readonly FIREWALLD_POLICY="nns-app-forward"
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
readonly REMOTE_BASE_DIR="$BASE_DIR/remotes"
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
    READY_TIMEOUT="" EXTERNAL_IP_URL="" WATCHDOG_MODE=""
    WATCHDOG_FAILURES="" WATCHDOG_COOLDOWN="" NS_NAME="" NS_CIDR=""
    HOST_ADDR="" NS_ADDR="" VETH_HOST="" VETH_NS=""
    TRANSPORT_TYPE="" TRANSPORT_REMOTE_HOST="" TRANSPORT_REMOTE_PORT=""
    TRANSPORT_LOCAL_PORT="" TRANSPORT_CONFIG=""
    TRANSPORT_SSH_TARGET="" TRANSPORT_SSH_IDENTITY=""
    TRANSPORT_SSH_KNOWN_HOSTS="" TRANSPORT_SSH_REMOTE_PORT=""
    REMOTE_MODE="" REMOTE_ALIAS="" REMOTE_GATEWAY="" REMOTE_CLIENT=""
    REMOTE_OWNER_ID="" REMOTE_EXIT_APP="" REMOTE_PROFILE_GENERATION=""
    REMOTE_SERVER_FINGERPRINT="" REMOTE_CLEANED=""
    REMOTE_MANAGED_OWNER_ID=""
}

reset_gateway_cfg_vars() {
    GATEWAY_NAME="" GATEWAY_BACKEND="" VIA_APP=""
    LISTEN_PROTO="" LISTEN_PORT="" PUBLIC_HOST="" PUBLIC_PORT=""
    TRANSPORT="" OPENVPN_LISTEN_PROTO="" OPENVPN_LISTEN_PORT=""
    TRANSPORT_SERVER_NAME="" TRANSPORT_PUBLIC_KEY="" TRANSPORT_PRIVATE_KEY=""
    CLIENT_POOL="" DNS_SERVERS="" TRANSIT_CIDR=""
    TRANSIT_HOST_ADDR="" TRANSIT_NS_ADDR="" GATEWAY_TUN=""
    GATEWAY_VETH_HOST="" GATEWAY_VETH_NS="" ROUTE_TABLE=""
    RULE_PRIORITY="" SERVER_CN="" HOST_FWD_CHAIN=""
    HOST_MANGLE_CHAIN="" NS_FWD_CHAIN="" NS_NAT_CHAIN=""
    NS_MANGLE_CHAIN="" REMOTE_MANAGED_OWNER_ID=""
}

reset_gateway_client_vars() {
    CLIENT_NAME="" STATUS="" CERT_SERIAL="" CREATED_AT="" REVOKED_AT=""
    GENERATION="" CLOAK_UID=""
}

required_binary() {
    local name=$1 path
    path=$(command -v "$name" 2>/dev/null || true)
    [[ -n "$path" && -x "$path" ]] || die "Required executable '$name' is unavailable."
    readlink -f -- "$path"
}

openvpn_binary() {
    required_binary openvpn
}

ip_binary() {
    required_binary ip
}

openvpn_supports_dns_updown() {
    local binary
    binary=$(openvpn_binary)
    "$binary" --help 2>&1 | grep -Fq -- '--dns-updown'
}

nns_unprivileged_user() {
    id nobody >/dev/null 2>&1 || die "The system account 'nobody' is missing."
    printf 'nobody\n'
}

nns_unprivileged_group() {
    if getent group nogroup >/dev/null 2>&1; then
        printf 'nogroup\n'
    elif getent group nobody >/dev/null 2>&1; then
        printf 'nobody\n'
    else
        id -gn nobody 2>/dev/null ||
            die "Cannot determine the unprivileged group for 'nobody'."
    fi
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
  nns-app install [app_name [--backend inherit] [--via <upstream-app>|host]]
  nns-app install <app_name> via --remote <user@host> [--remote-port <port>]
  nns-app remove  <app_name> [--local-only]
  nns-app purge [--local-only]
  nns-app list
  nns-app status  <app_name>
  nns-app myip [<app_name>]
  nns-app add     <app_name> <profile.ovpn|wireguard.conf>
  nns-app add     <app_name> any [country-code-or-name] [--refresh] [--via <upstream-app>|host]
  nns-app start   [-i|--ignore-start-error] <app_name> [--via <upstream-app>|host]
  nns-app stop    <app_name> [--local-only]
  nns-app run     <app_name> <command> [arguments...]

  nns-app gateway create <gateway_name> --via <app_name>
                  --listen <tcp|udp>:<port>
                  --public <host>:<port>
                  [--pool <IPv4-CIDR>] [--dns "<IPv4> ..."]
                  [--transport direct|stunnel|cloak]
                  [--server-name <cloak-decoy-host>]
  nns-app gateway start  <gateway_name>
  nns-app gateway stop   <gateway_name>
  nns-app gateway status <gateway_name>
  nns-app gateway list
  nns-app gateway remove <gateway_name>
  nns-app gateway client add    <gateway_name> <client_name>
  nns-app gateway client list   <gateway_name>
  nns-app gateway client export <gateway_name> <client_name>
                  [--format ovpn|nnslink] --output <file|->
  nns-app gateway client rotate <gateway_name> <client_name>
  nns-app gateway client revoke <gateway_name> <client_name>

  nns-app link import <app_name> <bundle.nnslink>
  nns-app remote add <alias> --ssh <user@host> [--port <port>] [--identity <file>]
  nns-app remote connect <alias>:<gateway> --client <name> --name <local_app>
  nns-app remote sync   <local_app>
  nns-app remote rotate <local_app>
  nns-app remote status <local_app|alias>

Simple managed-remote mode:
  nns-app install <app_name> via --remote <user@host> [--remote-port <port>]
  nns-app add <app_name> <self-contained-profile.ovpn|wireguard.conf>
  nns-app run <app_name> <command> [arguments...]

Examples:
  sudo ./nns-app.sh install
  sudo nns-app install my-upstream-vpn
  nns-app install my-private-app via --remote user@remote-host
  nns-app add my-private-app ~/my-base-profile.ovpn
  nns-app run my-private-app ping 1.1.1.1
  sudo nns-app add my-upstream-vpn ~/my-base-profile.ovpn
  sudo nns-app install my-private-app --via my-upstream-vpn
  sudo nns-app install my-shared-app --backend inherit --via my-remote-exit
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
  nns-app myip
  nns-app myip my-private-app

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

