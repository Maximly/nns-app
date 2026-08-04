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
        openvpn|wireguard|inherit)
            printf '%s
' "$configured"
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
    printf '%s
' "$detected"
}

vpn_type_label() {
    case "$1" in
        openvpn) printf 'OpenVPN
' ;;
        wireguard) printf 'WireGuard
' ;;
        inherit) printf 'Inherit
' ;;
        *) printf 'unknown
' ;;
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
    clear_app_transport_metadata "$app"
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


add_selected_profile_for_app() {
    local app=$1 selected=$2
    # Selection has already occurred on this host. Automatic-remote apps are
    # diverted before selection so a relay that is inaccessible locally can
    # still be discovered and probed from the remote host.
    add_profile "$app" "$selected"
}


add_any_profile() {
    require_root
    local app=$1 country=${2:-} force_refresh=${3:-off} via_override=${4:-__default__}
    validate_app_name "$app"
    load_cfg "$app"

    if [[ "${REMOTE_MODE:-}" == auto ]]; then
        [[ "$via_override" == __default__ || "$via_override" == host ]] ||
            die "Automatic-remote free-profile selection runs on the remote host; --via accepts only 'host'."
        remote_auto_add_any_profile "$app" "$country" "$force_refresh"
        return 0
    fi

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
        path_prefix=("$(ip_binary)" netns exec "$probe_ns")
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
    openvpn = shutil.which("openvpn") or "/usr/bin/openvpn"
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
            shutil.which("ip") or "/usr/bin/ip", "netns", "exec", probe_namespace,
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

    add_selected_profile_for_app "$app" "$selected"
    if [[ "${REMOTE_MODE:-}" != auto && "$probe_via" != host ]]; then
        log "Start this profile through the same path with: nns-app start $app --via $probe_via"
    fi
    rm -rf "$tmpdir"
    trap - EXIT
}


