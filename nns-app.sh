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
#   install <app_name>
#   remove  <app_name>
#   purge
#   list
#   add     <app_name> <profile.ovpn>
#   add     <app_name> any [country] [--refresh]
#   start   [-i|--ignore-start-error] <app_name>
#   stop    <app_name>
#   run     <app_name> <command> [args...]
#
# The script installs itself as /usr/local/sbin/nns_app.sh and creates the
# convenience symlink /usr/local/bin/nns-app.

set -Eeuo pipefail
IFS=$'\n\t'

readonly VERSION="1.0.14"
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
readonly VPNGATE_CACHE_FILE="$CACHE_DIR/vpngate.csv"
readonly VPNGATE_CACHE_TTL=1800

log()  { printf '%s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

show_version() {
    printf '%s %s\n' "$PROGRAM_NAME" "$VERSION"
    printf 'Author:  %s\n' "$AUTHOR"
    printf 'License: %s\n' "$LICENSE_ID"
}

usage() {
    cat <<'USAGE'
Usage:
  nns-app install <app_name>
  nns-app remove  <app_name>
  nns-app purge
  nns-app list
  nns-app add     <app_name> <profile.ovpn>
  nns-app add     <app_name> any [country-code-or-name] [--refresh]
  nns-app start   [-i|--ignore-start-error] <app_name>
  nns-app stop    <app_name>
  nns-app run     <app_name> <command> [arguments...]

Examples:
  sudo ./nns-app.sh install browser
  sudo nns-app add browser ~/Downloads/NorwayS23.ovpn
  sudo nns-app add browser any
  sudo nns-app add browser any JP
  sudo nns-app add browser any DE --refresh
  nns-app start browser
  nns-app start -i browser   # leave a slow connection running in background
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

ensure_dependencies() {
    local missing=()
    command -v ip >/dev/null 2>&1       || missing+=(iproute2)
    command -v openvpn >/dev/null 2>&1  || missing+=(openvpn)
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
Description=OpenVPN for NNS app %i
Requires=nns-netns@%i.service
After=nns-netns@%i.service
BindsTo=nns-netns@%i.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/nns_app.sh _openvpn %i
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
Cmnd_Alias $alias = $ENGINE_PATH list, $ENGINE_PATH start $app, $ENGINE_PATH start -i $app, $ENGINE_PATH start --ignore-start-error $app, $ENGINE_PATH start $app -i, $ENGINE_PATH start $app --ignore-start-error, $ENGINE_PATH stop $app, $ENGINE_PATH run $app *
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
    local app=$1
    validate_app_name "$app"

    ensure_dependencies
    install_engine_files
    install -d -o root -g root -m 0755 "$BASE_DIR" "$RUN_DIR"

    local dir file user net_data cidr host_addr ns_addr veth_data veth_host veth_ns
    dir=$(cfg_dir "$app")
    file=$(cfg_file "$app")

    if [[ -f "$file" ]]; then
        load_cfg "$app"
        write_sudoers_for_app "$app" "$APP_USER"
        log "NNS app '$app' is already installed; engine files were refreshed."
        log "Config: $file"
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

# on: application traffic cannot fall back to the host uplink.
# off: direct fallback through the host uplink is allowed.
KILLSWITCH="on"

# Enable/disable automatic startup at boot.
AUTOSTART="off"

# auto uses the host's current IPv4 default-route interface.
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
    log "Next:     sudo $USER_PATH add $app /path/to/profile.ovpn"
    log "          or: sudo $USER_PATH add $app any [country]"
}

profile_name_from_path() {
    local base name
    base=$(basename "$1")
    name=${base%.*}
    name=$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9._-]+/_/g; s/^_+//; s/_+$//')
    [[ -n "$name" ]] || name="profile"
    printf '%.64s.ovpn\n' "$name"
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
    validate_ovpn "$src"

    local name dest tmp
    local -a applied=()
    name=$(profile_name_from_path "$src")
    dest="$(profiles_dir "$app")/$name"
    tmp=$(mktemp)

    # Never alter the user's downloaded profile. Normalize line endings and
    # apply compatibility adjustments only to the protected managed copy under
    # /etc/nns-app. CRLF is common in VPN Gate profiles; leaving the trailing
    # carriage return would corrupt parsed protocol/port values passed to
    # iptables during namespace creation.
    cat "$src" >"$tmp"
    sed -i 's/\r$//' "$tmp"
    validate_ovpn "$tmp"
    if bool_on "${PROFILE_FIXUPS:-on}"; then
        apply_profile_fixups "$tmp" applied
    fi

    install -o root -g root -m 0600 "$tmp" "$dest"
    rm -f "$tmp"
    cfg_set "$app" DEFAULT_PROFILE "$name"

    log "Added profile '$name' to '$app'."
    if (( ${#applied[@]} )); then
        log "Applied managed-profile compatibility fixes:"
        local fix
        for fix in "${applied[@]}"; do
            log "  - $fix"
        done
    elif bool_on "${PROFILE_FIXUPS:-on}"; then
        log "No compatibility fixes were needed."
    else
        log "Profile fixups are disabled in $(cfg_file "$app")."
    fi
    log "Default profile is now '$name'."
    if systemctl is-active --quiet "nns-openvpn@${app}.service"; then
        warn "'$app' is currently running. Stop and start it to switch profiles."
    fi
}


add_any_profile() {
    require_root
    local app=$1 country=${2:-} force_refresh=${3:-off}
    validate_app_name "$app"
    load_cfg "$app"

    command -v curl >/dev/null 2>&1 || die "curl is required. Refresh the installation with: nns-app install $app"
    command -v python3 >/dev/null 2>&1 || die "python3 is required. Refresh the installation with: nns-app install $app"

    local tmpdir csv_file selected metadata
    local now mtime age cache_tmp use_cache="off"
    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir:-}" "${cache_tmp:-}"' EXIT

    install -d -o root -g root -m 0755 "$CACHE_DIR"
    csv_file="$VPNGATE_CACHE_FILE"
    now=$(date +%s)

    if [[ -s "$VPNGATE_CACHE_FILE" ]] && ! bool_on "$force_refresh"; then
        mtime=$(stat -c %Y "$VPNGATE_CACHE_FILE" 2>/dev/null || printf '0')
        [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
        age=$((now - mtime))
        if (( age >= 0 && age <= VPNGATE_CACHE_TTL )); then
            use_cache="on"
            log "Using cached VPN Gate relay list (age $((age / 60)) min; TTL $((VPNGATE_CACHE_TTL / 60)) min)."
        fi
    fi

    if ! bool_on "$use_cache"; then
        log "Downloading the VPN Gate public relay list${country:+ for '$country'}..."
        cache_tmp=$(mktemp "$CACHE_DIR/.vpngate.csv.XXXXXX")

        if curl --fail --silent --show-error --location --compressed \
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
            warn "Could not refresh the VPN Gate list; using stale cache (age $((age / 60)) min)."
        else
            rm -f "$cache_tmp"
            cache_tmp=""
            die "Could not download the VPN Gate server list and no cached copy is available."
        fi
    fi

    [[ -s "$csv_file" ]] || die "VPN Gate cache is empty: $csv_file"
    log "Searching VPN Gate candidates${country:+ for '$country'}..."

    metadata=$(python3 - "$csv_file" "$tmpdir" "$country" <<'PY_SELECT'
import base64
import csv
import io
import os
import random
import re
import sys
from pathlib import Path

csv_path = Path(sys.argv[1])
out_dir = Path(sys.argv[2])
country_filter = sys.argv[3].strip().casefold()

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
    # ping values rank below measured ones. A small random tie-break avoids
    # every nns-app user selecting exactly the same volunteer relay.
    rank = (
        score,
        speed,
        uptime,
        -sessions,
        -(ping if ping > 0 else 999999),
        random.random(),
    )
    candidates.append((rank, row, config))

if not candidates:
    label = sys.argv[3] or "any country"
    raise SystemExit(f"No usable VPN Gate OpenVPN profile found for {label}")

# Randomly choose among the strongest few rather than concentrating all users
# on one relay. They are already ordered by VPN Gate's quality measurements.
candidates.sort(key=lambda item: item[0], reverse=True)
pool = candidates[: min(5, len(candidates))]
_, row, config = random.choice(pool)

host = get(row, "HostName")
ip = get(row, "IP")
short_name = get(row, "CountryShort").upper() or "XX"
long_name = get(row, "CountryLong") or "Unknown"
score = number(get(row, "Score"))
ping = number(get(row, "Ping"))
speed = number(get(row, "Speed"))
uptime = number(get(row, "Uptime"))
sessions = number(get(row, "NumVpnSessions"))

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
            str(sessions),
        ]
    )
)
PY_SELECT
    ) || die "Could not select a usable free VPN profile."

    IFS=$'\t' read -r selected country_short country_long host ip score ping speed_mbps uptime_minutes sessions <<<"$metadata"
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
    log "  Uptime:   ${uptime_minutes} min; active sessions: $sessions"
    warn "VPN Gate relays are operated by volunteers and may log traffic."
    warn "Use end-to-end encryption and do not treat this as a trusted privacy VPN."

    add_profile "$app" "$selected"
    rm -rf "$tmpdir"
    trap - EXIT
}


profile_endpoints() {
    local profile=$1

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
}

resolve_profile_endpoints() {
    local profile=$1 outfile=$2
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
            while read -r ip; do
                [[ -n "$ip" ]] && printf '%s|%s|%s\n' "$ip" "$port" "$proto" >>"$tmp"
            done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u)
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

netns_up() {
    require_root
    local app=$1
    validate_app_name "$app"
    load_cfg "$app"

    local wan host_ip runtime profile endpoints_file
    runtime="$RUN_DIR/${app}.env"
    endpoints_file="$RUN_DIR/${app}.endpoints"

    # Clean an incomplete previous instance before creating any new runtime
    # files. netns_down() removes <app>.env and <app>.endpoints, so resolving
    # endpoints before this cleanup made a second start fail with:
    #   /run/nns-app/<app>.endpoints: No such file or directory
    if ip netns list | awk '{print $1}' | grep -Fxq "$NS_NAME"; then
        warn "Removing stale namespace '$NS_NAME'."
        netns_down "$app"
        load_cfg "$app"
    fi
    ip link del "$VETH_HOST" 2>/dev/null || true

    wan=$(detect_wan_iface "$WAN_IFACE")
    host_ip=${HOST_ADDR%/*}
    profile="$(profiles_dir "$app")/$DEFAULT_PROFILE"
    [[ -n "$DEFAULT_PROFILE" && -f "$profile" ]] ||
        die "No usable default profile is configured for '$app'."

    install -d -o root -g root -m 0755 "$RUN_DIR"
    resolve_profile_endpoints "$profile" "$endpoints_file"
    chmod 0600 "$endpoints_file"

    printf 'WAN_IFACE_RUNTIME=%q\n' "$wan" >"$runtime"
    chmod 0600 "$runtime"

    ip netns add "$NS_NAME"
    ip link add "$VETH_HOST" type veth peer name "$VETH_NS"
    ip link set "$VETH_NS" netns "$NS_NAME"

    ip addr add "$HOST_ADDR" dev "$VETH_HOST"
    ip link set "$VETH_HOST" up

    ip -n "$NS_NAME" link set lo up
    ip -n "$NS_NAME" addr add "$NS_ADDR" dev "$VETH_NS"
    ip -n "$NS_NAME" link set "$VETH_NS" up
    ip -n "$NS_NAME" route add default via "$host_ip" dev "$VETH_NS"

    # The original known-good implementation pinned the OpenVPN endpoint to
    # the veth gateway before OpenVPN installed redirect-gateway routes. This
    # prevents reconnects and persisted routes from accidentally sending the
    # control channel back into the VPN tunnel.
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

    sysctl -q -w net.ipv4.ip_forward=1
    if bool_on "$DISABLE_IPV6"; then
        ip netns exec "$NS_NAME" sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 || true
        ip netns exec "$NS_NAME" sysctl -q -w net.ipv6.conf.default.disable_ipv6=1 || true
    fi

    host_rules_up "$wan"

    # Namespace-local firewall. OpenVPN remains root; launched applications are
    # dropped to APP_USER. With KILLSWITCH=on only root may use the veth uplink,
    # while application traffic is accepted only through tun+.
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
        # Match the original known-good firewall model: permit only the exact
        # OpenVPN endpoint(s) over the physical veth before the tunnel exists.
        # Do not depend on xt_owner/UID matching for the control channel.
        while IFS='|' read -r endpoint_ip endpoint_port endpoint_proto; do
            ip netns exec "$NS_NAME" iptables -w 5 -A OUTPUT \
                -o "$VETH_NS" -d "$endpoint_ip" \
                -p "$endpoint_proto" --dport "$endpoint_port" -j ACCEPT
        done <"$endpoints_file"

        # Permit root-owned DNS only while it follows the pre-tunnel default
        # route over veth. After redirect-gateway, DNS follows tun+ instead.
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

        ip netns exec "$NS_NAME" iptables -w 5 -A OUTPUT -o 'tun+' -j ACCEPT
    fi

    log "Namespace '$NS_NAME' is ready on $NS_CIDR via $wan."
    while IFS='|' read -r endpoint_ip endpoint_port endpoint_proto; do
        log "VPN endpoint: $endpoint_ip:$endpoint_port/$endpoint_proto via $VETH_NS"
    done <"$endpoints_file"
}

netns_down() {
    require_root
    local app=$1
    validate_app_name "$app"
    load_cfg "$app"

    local runtime wan pids
    runtime="$RUN_DIR/${app}.env"
    wan=""
    if [[ -f "$runtime" ]]; then
        # shellcheck disable=SC1090
        source "$runtime"
        wan=${WAN_IFACE_RUNTIME:-}
    fi
    if [[ -z "$wan" ]]; then
        wan=$(detect_wan_iface "$WAN_IFACE" 2>/dev/null || true)
    fi

    pids=$(ip netns pids "$NS_NAME" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        kill $pids 2>/dev/null || true
        sleep 1
        pids=$(ip netns pids "$NS_NAME" 2>/dev/null || true)
        [[ -z "$pids" ]] || kill -9 $pids 2>/dev/null || true
    fi

    [[ -z "$wan" ]] || host_rules_down "$wan"
    ip netns del "$NS_NAME" 2>/dev/null || true
    ip link del "$VETH_HOST" 2>/dev/null || true
    rm -rf "/etc/netns/$NS_NAME"
    rm -f "$runtime" "$RUN_DIR/${app}.profile" "$RUN_DIR/${app}.endpoints"
    log "Namespace '$NS_NAME' stopped."
}

openvpn_exec() {
    require_root
    local app=$1
    validate_app_name "$app"
    load_cfg "$app"

    [[ -n "$DEFAULT_PROFILE" ]] || die "No default profile is configured for '$app'."
    local profile
    profile="$(profiles_dir "$app")/$DEFAULT_PROFILE"
    [[ -f "$profile" ]] || die "Default profile does not exist: $profile"
    ip netns list | awk '{print $1}' | grep -Fxq "$NS_NAME" ||
        die "Namespace '$NS_NAME' is not running."

    install -d -o root -g root -m 0755 "$RUN_DIR"
    printf '%s\n' "$DEFAULT_PROFILE" >"$RUN_DIR/${app}.profile"
    chmod 0644 "$RUN_DIR/${app}.profile"

    # Match the known-good original namespace method as closely as possible.
    # Only disable OpenVPN's systemd-resolved integration so namespace DNS can
    # never modify the host resolver. The profile itself controls all other
    # OpenVPN behavior.
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

app_is_started() {
    systemctl is-active --quiet "nns-openvpn@${1}.service" &&
    systemctl is-active --quiet "nns-netns@${1}.service"
}

wait_online() {
    local app=$1 timeout=$2 deadline
    load_cfg "$app"

    deadline=$((SECONDS + timeout))
    while (( SECONDS < deadline )); do
        if ip -n "$NS_NAME" route get 1.1.1.1 2>/dev/null |
           grep -qE ' dev (tun|tap)[^ ]* '; then
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
    validate_app_name "$app"
    load_cfg "$app"
    [[ -n "$DEFAULT_PROFILE" ]] || die "No profile configured. Use: nns-app add $app profile.ovpn"
    [[ -f "$(profiles_dir "$app")/$DEFAULT_PROFILE" ]] ||
        die "Configured profile '$DEFAULT_PROFILE' is missing."

    local current=""
    [[ -f "$RUN_DIR/${app}.profile" ]] && current=$(<"$RUN_DIR/${app}.profile")
    if app_is_started "$app" && [[ "$current" == "$DEFAULT_PROFILE" ]]; then
        log "'$app' is already started with '$DEFAULT_PROFILE'."
        return 0
    fi

    if app_is_started "$app" || systemctl is-active --quiet "nns-netns@${app}.service"; then
        stop_app "$app"
    fi

    if bool_on "$AUTOSTART"; then
        systemctl enable "nns-netns@${app}.service" "nns-openvpn@${app}.service" >/dev/null
    else
        systemctl disable "nns-netns@${app}.service" "nns-openvpn@${app}.service" >/dev/null 2>&1 || true
    fi

    if ! systemctl start "nns-netns@${app}.service"; then
        warn "Failed to create the network namespace for '$app'."
        warn "Recent namespace-service log:"
        journalctl -u "nns-netns@${app}.service" -n 40 \
            -o cat --no-pager >&2 2>/dev/null || true
        netns_down "$app" >/dev/null 2>&1 || true
        systemctl reset-failed "nns-netns@${app}.service" 2>/dev/null || true
        return 1
    fi

    if ! systemctl start "nns-openvpn@${app}.service"; then
        warn "Failed to start OpenVPN for '$app'."
        warn "Recent OpenVPN-service log:"
        journalctl -u "nns-openvpn@${app}.service" -n 40 \
            -o cat --no-pager >&2 2>/dev/null || true
        stop_app "$app"
        return 1
    fi

    local timeout
    if bool_on "$ignore_start_error"; then
        # -i is an asynchronous/ignore-readiness mode. Use a one-second
        # readiness budget; the ping plus HTTP fallback may make wall time
        # approximately one to two seconds. A failed probe leaves the services
        # running and still returns success to the caller.
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
        log "Started '$app' with '$DEFAULT_PROFILE'.${ext:+ External IP: $ext}"
        return 0
    fi

    if bool_on "$ignore_start_error"; then
        warn "'$app' is not online yet; -i ignored the readiness error."
        warn "The namespace and VPN service were left running in the background."
        warn "Check later with: nns-app list"
        return 0
    fi

    warn "'$app' failed: the VPN data path was not online within ${timeout}s."
    warn "Stopping the failed VPN instance instead of leaving it reconnecting."
    warn "Recent OpenVPN log:"
    journalctl -u "nns-openvpn@${app}.service" -n 20 \
        -o cat --no-pager >&2 2>/dev/null || true
    stop_app "$app"
    return 1
}

stop_app() {
    require_root
    local app=$1
    validate_app_name "$app"
    load_cfg "$app"

    systemctl stop "nns-openvpn@${app}.service" 2>/dev/null || true
    systemctl stop "nns-netns@${app}.service" 2>/dev/null || true
    systemctl reset-failed "nns-openvpn@${app}.service" "nns-netns@${app}.service" 2>/dev/null || true
    rm -f "$RUN_DIR/${app}.profile"
    log "Stopped '$app'."
}

remove_app() {
    require_root
    local app=$1
    validate_app_name "$app"
    load_cfg "$app"

    stop_app "$app"
    systemctl disable "nns-openvpn@${app}.service" "nns-netns@${app}.service" >/dev/null 2>&1 || true
    rm -f "/etc/sudoers.d/nns-app-${app}"
    rm -rf "$(cfg_dir "$app")" "/etc/netns/$NS_NAME"
    rm -f "$RUN_DIR/${app}.env" "$RUN_DIR/${app}.profile"
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
    # packages (openvpn, iproute2, iptables, curl, sudo, etc.).
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
        ip -n "$NS_NAME" route get 1.1.1.1 2>/dev/null | grep -qE ' dev (tun|tap)[^ ]* ' ||
            die "VPN tunnel route for '$app' is not ready."
        wait_online "$app" 2 ||
            die "VPN data path for '$app' is not online yet."
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
    for name in DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS \
                LANG LC_ALL TERM COLORTERM SSH_AUTH_SOCK; do
        value=${!name-}
        [[ -z "$value" ]] || env_args+=("$name=$value")
    done

    # No eval, no shell re-parsing. Enter the network namespace as root, then
    # permanently drop to APP_USER before executing the requested program.
    exec /usr/sbin/ip netns exec "$NS_NAME" \
        /usr/bin/setpriv \
            --reuid="$uid" \
            --regid="$gid" \
            --init-groups \
            -- \
        /usr/bin/env -i "${env_args[@]}" "$@"
}

list_apps() {
    require_root
    install -d -o root -g root -m 0755 "$BASE_DIR" "$RUN_DIR"

    printf '%-18s %-9s %s\n' "Name" "Status" "Online"
    printf '%-18s %-9s %s\n' "------------------" "---------" "-----------------------------------------------"

    local found=0 dir app status profile local_ip external online
    shopt -s nullglob
    for dir in "$BASE_DIR"/*; do
        [[ -d "$dir" ]] || continue
        app=$(basename "$dir")
        [[ -f "$(cfg_file "$app")" ]] || continue
        found=1

        load_cfg "$app"
        profile=${DEFAULT_PROFILE:-none}
        profile=${profile%.ovpn}
        status=stopped
        online="$profile | -"

        if app_is_started "$app"; then
            status=started
            local_ip=$(ip -n "$NS_NAME" -o -4 addr show 2>/dev/null |
                       awk '$2 ~ /^(tun|tap)/ {split($4,a,"/"); print a[1]; exit}' || true)
            [[ -n "$local_ip" ]] || local_ip="-"
            external=""
            if ip -n "$NS_NAME" route get 1.1.1.1 2>/dev/null | grep -qE ' dev (tun|tap)[^ ]* '; then
                external=$(ip netns exec "$NS_NAME" curl -4fsS \
                           --connect-timeout 2 --max-time 4 "$EXTERNAL_IP_URL" 2>/dev/null || true)
            fi
            [[ -n "$external" ]] || external="offline"
            online="$profile | $local_ip -> $external"
        fi

        printf '%-18s %-9s %s\n' "$app" "$status" "$online"
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
        _openvpn)
            require_root
            [[ $# -eq 2 ]] || die "_openvpn requires app_name."
            openvpn_exec "$2"
            exit
            ;;
    esac

    reexec_as_root_if_needed "$@"

    case "$cmd" in
        install)
            [[ $# -eq 2 ]] || die "Usage: nns-app install <app_name>"
            install_app "$2"
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
            (( $# >= 3 && $# <= 5 )) ||
                die "Usage: nns-app add <app_name> <profile.ovpn>|any [country] [--refresh]"
            if [[ "$3" == any ]]; then
                local add_country="" add_refresh="off" add_arg
                for add_arg in "${@:4}"; do
                    case "$add_arg" in
                        --refresh)
                            add_refresh="on"
                            ;;
                        -*)
                            die "Unknown add option '$add_arg'."
                            ;;
                        *)
                            [[ -z "$add_country" ]] ||
                                die "Only one country filter may be supplied."
                            add_country=$add_arg
                            ;;
                    esac
                done
                add_any_profile "$2" "$add_country" "$add_refresh"
            else
                [[ $# -eq 3 ]] ||
                    die "Options are valid only with: nns-app add <app_name> any [country] [--refresh]"
                add_profile "$2" "$3"
            fi
            ;;
        start)
            local start_app_name="" ignore_start_error="off" arg
            shift
            for arg in "$@"; do
                case "$arg" in
                    -i|--ignore-start-error)
                        ignore_start_error="on"
                        ;;
                    -*)
                        die "Unknown start option '$arg'. Usage: nns-app start [-i] <app_name>"
                        ;;
                    *)
                        [[ -z "$start_app_name" ]] ||
                            die "Usage: nns-app start [-i] <app_name>"
                        start_app_name=$arg
                        ;;
                esac
            done
            [[ -n "$start_app_name" ]] || die "Usage: nns-app start [-i] <app_name>"
            start_app "$start_app_name" "$ignore_start_error"
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
