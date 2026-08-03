# nns-app source module: inherit-only application environments, transport
# bundles and SSH-based remote gateway management.

app_transport_dir() { printf '%s/%s/transport\n' "$BASE_DIR" "$1"; }
remote_dir()         { printf '%s/%s\n' "$REMOTE_BASE_DIR" "$1"; }
remote_cfg_file()    { printf '%s/%s/remote.cfg\n' "$REMOTE_BASE_DIR" "$1"; }
remote_known_hosts() { printf '%s/%s/known_hosts\n' "$REMOTE_BASE_DIR" "$1"; }

validate_remote_alias() {
    local alias=${1:-}
    [[ "$alias" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] ||
        die "Invalid remote alias '$alias'. Use 1-32 letters, digits, '.', '_' or '-'."
}

validate_ssh_target() {
    local target=${1:-}
    [[ "$target" =~ ^([A-Za-z0-9._-]+@)?([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])$ ]] ||
        die "Invalid SSH target '$target'. Use [user@]host without shell options."
}

clear_app_transport_metadata() {
    local app=$1 dir
    [[ -f "$(cfg_file "$app")" ]] || return 0
    dir=$(app_transport_dir "$app")
    rm -rf "$dir"
    cfg_set "$app" TRANSPORT_TYPE direct
    cfg_set "$app" TRANSPORT_REMOTE_HOST ""
    cfg_set "$app" TRANSPORT_REMOTE_PORT ""
    cfg_set "$app" TRANSPORT_LOCAL_PORT ""
    cfg_set "$app" TRANSPORT_CONFIG ""
}

set_inherit_backend() {
    require_root
    local app=$1 via=${2:-__default__} selected was_started=no
    validate_app_name "$app"
    load_cfg "$app"
    selected=$(effective_via_for_app "$app" "$via")
    [[ "$selected" != host ]] ||
        die "The inherit backend requires --via <upstream-app>; it cannot inherit the host uplink."

    if app_is_started "$app" || systemctl is-active --quiet "nns-netns@${app}.service"; then
        was_started=yes
        stop_app "$app"
        load_cfg "$app"
    fi

    cfg_set "$app" VPN_TYPE inherit
    cfg_set "$app" DEFAULT_PROFILE ""
    cfg_set "$app" UPSTREAM_APP "$selected"
    clear_app_transport_metadata "$app"
    write_app_unit_dropin "$app"
    systemctl daemon-reload
    log "Configured '$app' as an inherit-only environment via '$selected'."
    if [[ "$was_started" == yes ]]; then
        start_app "$app" off "$selected"
    fi
}

transport_binary_for_type() {
    case "$1" in
        direct|"") return 1 ;;
        stunnel) command -v stunnel4 2>/dev/null || command -v stunnel 2>/dev/null ;;
        cloak) command -v ck-client 2>/dev/null ;;
        *) return 1 ;;
    esac
}

transport_client_exec() {
    local app=$1 profile=$2 type binary wrapper_pid vpn_pid rc=0
    load_cfg "$app"
    type=${TRANSPORT_TYPE:-direct}
    [[ "$type" == stunnel || "$type" == cloak ]] ||
        die "Unsupported local transport '$type'."
    [[ -n "$TRANSPORT_CONFIG" && -f "$TRANSPORT_CONFIG" ]] ||
        die "Transport config is missing for '$app'. Re-import its .nnslink bundle."
    binary=$(transport_binary_for_type "$type" || true)
    [[ -n "$binary" ]] ||
        die "Transport '$type' is not installed (required client binary is missing)."

    transport_cleanup() {
        [[ -z "${vpn_pid:-}" ]] || kill "$vpn_pid" 2>/dev/null || true
        [[ -z "${wrapper_pid:-}" ]] || kill "$wrapper_pid" 2>/dev/null || true
        wait "${vpn_pid:-0}" "${wrapper_pid:-0}" 2>/dev/null || true
    }
    trap 'exit 0' TERM INT HUP
    trap transport_cleanup EXIT

    case "$type" in
        stunnel)
            ip netns exec "$NS_NAME" "$binary" "$TRANSPORT_CONFIG" &
            wrapper_pid=$!
            ;;
        cloak)
            ip netns exec "$NS_NAME" "$binary" \
                -c "$TRANSPORT_CONFIG" \
                -s "$TRANSPORT_REMOTE_HOST" \
                -p "$TRANSPORT_REMOTE_PORT" \
                -i 127.0.0.1 \
                -l "$TRANSPORT_LOCAL_PORT" &
            wrapper_pid=$!
            ;;
    esac

    local deadline=$((SECONDS + 5))
    while (( SECONDS < deadline )); do
        kill -0 "$wrapper_pid" 2>/dev/null ||
            die "The $type client exited before opening its local listener."
        if ip netns exec "$NS_NAME" ss -H -lnt 2>/dev/null |
           grep -Eq "127\\.0\\.0\\.1:${TRANSPORT_LOCAL_PORT}([[:space:]]|$)"; then
            break
        fi
        sleep 0.1
    done
    ip netns exec "$NS_NAME" ss -H -lnt 2>/dev/null |
        grep -Eq "127\\.0\\.0\\.1:${TRANSPORT_LOCAL_PORT}([[:space:]]|$)" ||
        die "The $type client did not open 127.0.0.1:${TRANSPORT_LOCAL_PORT}."

    ip netns exec "$NS_NAME" /usr/sbin/openvpn \
        --config "$profile" --dns-updown disable --disable-dco &
    vpn_pid=$!

    wait -n "$wrapper_pid" "$vpn_pid" || rc=$?
    kill "$wrapper_pid" "$vpn_pid" 2>/dev/null || true
    wait "$wrapper_pid" "$vpn_pid" 2>/dev/null || true
    (( rc == 0 )) || return "$rc"
    die "The transported OpenVPN service exited unexpectedly."
}

resolve_transport_endpoint() {
    local app=$1 output=$2 namespace=${3:-host}
    load_cfg "$app"
    [[ -n "${TRANSPORT_REMOTE_HOST:-}" &&
       "${TRANSPORT_REMOTE_PORT:-}" =~ ^[1-9][0-9]{0,4}$ ]] ||
        die "Transport endpoint metadata is incomplete for '$app'."

    python3 - "$TRANSPORT_REMOTE_HOST" "$TRANSPORT_REMOTE_PORT" "$output" \
        3< <(if [[ "$namespace" == host ]]; then
                getent ahostsv4 "$TRANSPORT_REMOTE_HOST" 2>/dev/null || true
             else
                ip netns exec "$namespace" getent ahostsv4 "$TRANSPORT_REMOTE_HOST" 2>/dev/null || true
             fi) <<'PY_TRANSPORT_ENDPOINT'
import ipaddress
import os
import sys

host, port, output = sys.argv[1:]
addresses = []
try:
    addresses.append(str(ipaddress.IPv4Address(host)))
except ipaddress.AddressValueError:
    for line in os.fdopen(3):
        fields = line.split()
        if not fields:
            continue
        try:
            ip = str(ipaddress.IPv4Address(fields[0]))
        except ipaddress.AddressValueError:
            continue
        if ip not in addresses:
            addresses.append(ip)
if not addresses:
    raise SystemExit(f"cannot resolve transport host {host!r} to IPv4")
with open(output, "w", encoding="ascii") as fh:
    for ip in addresses:
        fh.write(f"{ip}|{port}|tcp\n")
PY_TRANSPORT_ENDPOINT
}

nnslink_manifest_read() {
    local bundle=$1 extract_dir=$2
    python3 - "$bundle" "$extract_dir" <<'PY_NNSLINK_READ'
import json
import os
import pathlib
import sys
import tarfile

bundle = pathlib.Path(sys.argv[1])
out = pathlib.Path(sys.argv[2])
allowed = {"manifest.json", "client.ovpn", "stunnel-ca.pem", "cloak-client.json"}
if not bundle.is_file() or bundle.stat().st_size > 8 * 1024 * 1024:
    raise SystemExit("invalid or unexpectedly large .nnslink bundle")
out.mkdir(mode=0o700, parents=True, exist_ok=True)
with tarfile.open(bundle, "r:gz") as tf:
    members = tf.getmembers()
    total = 0
    for member in members:
        p = pathlib.PurePosixPath(member.name)
        if member.name not in allowed or p.is_absolute() or ".." in p.parts:
            raise SystemExit(f"unsafe or unexpected bundle member: {member.name}")
        if not member.isfile() or member.issym() or member.islnk():
            raise SystemExit(f"unsupported bundle member type: {member.name}")
        total += member.size
    if total > 4 * 1024 * 1024:
        raise SystemExit("expanded .nnslink bundle is unexpectedly large")
    for member in members:
        source = tf.extractfile(member)
        if source is None:
            raise SystemExit(f"cannot read bundle member: {member.name}")
        target = out / member.name
        target.write_bytes(source.read())
        os.chmod(target, 0o600)
manifest_path = out / "manifest.json"
profile_path = out / "client.ovpn"
if not manifest_path.is_file() or not profile_path.is_file():
    raise SystemExit("bundle must contain manifest.json and client.ovpn")
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
required = {
    "format": "nnslink",
    "version": 1,
    "backend": "openvpn",
}
for key, value in required.items():
    if manifest.get(key) != value:
        raise SystemExit(f"unsupported manifest {key}: {manifest.get(key)!r}")
transport = manifest.get("transport")
if transport not in {"direct", "stunnel", "cloak"}:
    raise SystemExit(f"unsupported transport: {transport!r}")
import re

name_rules = {
    "gateway": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$"),
    "client": re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$"),
}
for key, rule in name_rules.items():
    value = manifest.get(key)
    if not isinstance(value, str) or not rule.fullmatch(value):
        raise SystemExit(f"invalid manifest field: {key}")
host = manifest.get("public_host")
if (not isinstance(host, str) or len(host) > 253 or
        not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", host) or
        host.endswith((".", "-")) or ".." in host):
    raise SystemExit("invalid manifest field: public_host")
for key in ("public_port", "local_port", "generation"):
    value = manifest.get(key)
    if not isinstance(value, int) or value < 1 or value > (65535 if key != "generation" else 2**31-1):
        raise SystemExit(f"invalid manifest field: {key}")
if transport == "stunnel" and not (out / "stunnel-ca.pem").is_file():
    raise SystemExit("stunnel bundle is missing stunnel-ca.pem")
if transport == "cloak":
    cloak_path = out / "cloak-client.json"
    if not cloak_path.is_file():
        raise SystemExit("cloak bundle is missing cloak-client.json")
    try:
        cloak = json.loads(cloak_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise SystemExit(f"invalid Cloak client configuration: {exc}")
    expected_keys = {
        "Transport", "ProxyMethod", "EncryptionMethod", "UID", "PublicKey",
        "ServerName", "NumConn", "BrowserSig", "StreamTimeout",
    }
    if not isinstance(cloak, dict) or set(cloak) != expected_keys:
        raise SystemExit("unsupported Cloak client configuration fields")
    if cloak.get("Transport") != "direct" or cloak.get("ProxyMethod") != "openvpn":
        raise SystemExit("Cloak bundle is not configured for direct OpenVPN transport")
    if cloak.get("EncryptionMethod") not in {
        "chacha20-poly1305", "aes-256-gcm", "aes-128-gcm"
    }:
        raise SystemExit("unsupported Cloak encryption method")
    if cloak.get("BrowserSig") not in {"chrome", "firefox", "safari"}:
        raise SystemExit("unsupported Cloak browser signature")
    if not isinstance(cloak.get("NumConn"), int) or not 1 <= cloak["NumConn"] <= 16:
        raise SystemExit("invalid Cloak connection count")
    if not isinstance(cloak.get("StreamTimeout"), int) or not 1 <= cloak["StreamTimeout"] <= 86400:
        raise SystemExit("invalid Cloak stream timeout")
    server_name = cloak.get("ServerName")
    if (not isinstance(server_name, str) or len(server_name) > 253 or
            not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*", server_name) or
            server_name.endswith((".", "-")) or ".." in server_name):
        raise SystemExit("invalid Cloak server name")
    import base64
    import binascii
    for key, decoded_size in (("UID", 16), ("PublicKey", 32)):
        value = cloak.get(key)
        if not isinstance(value, str):
            raise SystemExit(f"invalid Cloak {key}")
        try:
            decoded = base64.b64decode(value, validate=True)
        except (ValueError, binascii.Error):
            raise SystemExit(f"invalid Cloak {key}")
        if len(decoded) != decoded_size:
            raise SystemExit(f"invalid Cloak {key} length")
for key in ("gateway", "client", "backend", "transport", "public_host", "public_port", "local_port", "generation"):
    print(f"{key.upper()}={json.dumps(manifest[key], separators=(',', ':'))}")
PY_NNSLINK_READ
}

nnslink_import() {
    require_root
    local app=$1 bundle=$2 expected_gateway=${3:-} expected_client=${4:-}
    local temp manifest_values
    local GATEWAY CLIENT BACKEND TRANSPORT PUBLIC_HOST PUBLIC_PORT LOCAL_PORT GENERATION
    validate_app_name "$app"
    [[ -f "$(cfg_file "$app")" ]] ||
        die "NNS app '$app' is not installed. Run: sudo nns-app install $app"
    bundle=$(readlink -f "$bundle")
    [[ "$bundle" == *.nnslink ]] || warn "Importing a bundle without the .nnslink suffix."

    temp=$(mktemp -d)
    manifest_values=$(nnslink_manifest_read "$bundle" "$temp/extracted") ||
        die "Cannot validate .nnslink bundle '$bundle'."
    while IFS='=' read -r key value; do
        case "$key" in
            GATEWAY|CLIENT|BACKEND|TRANSPORT|PUBLIC_HOST|PUBLIC_PORT|LOCAL_PORT|GENERATION)
                printf -v "$key" '%s' "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()))' <<<"$value")"
                ;;
        esac
    done <<<"$manifest_values"

    [[ -z "$expected_gateway" || "$GATEWAY" == "$expected_gateway" ]] ||
        die ".nnslink gateway '$GATEWAY' does not match expected '$expected_gateway'."
    [[ -z "$expected_client" || "$CLIENT" == "$expected_client" ]] ||
        die ".nnslink client '$CLIENT' does not match expected '$expected_client'."
    [[ "$BACKEND" == openvpn ]] || die "Only OpenVPN .nnslink bundles are supported."

    # Validate optional runtime dependencies and pinned material before
    # replacing the app's currently working profile.
    local tdir config binary
    case "$TRANSPORT" in
        direct) ;;
        stunnel)
            binary=$(transport_binary_for_type stunnel || true)
            [[ -n "$binary" ]] || die "Install stunnel before importing this bundle."
            openssl x509 -in "$temp/extracted/stunnel-ca.pem" -noout >/dev/null 2>&1 ||
                die "The .nnslink stunnel CA is not a valid X.509 certificate."
            ;;
        cloak)
            binary=$(transport_binary_for_type cloak || true)
            [[ -n "$binary" ]] || die "Install ck-client before importing this bundle."
            ;;
    esac

    add_profile "$app" "$temp/extracted/client.ovpn"
    tdir=$(app_transport_dir "$app")
    install -d -o root -g root -m 0700 "$tdir"
    case "$TRANSPORT" in
        direct)
            config=""
            ;;
        stunnel)
            install -o root -g root -m 0644 \
                "$temp/extracted/stunnel-ca.pem" "$tdir/server-ca.pem"
            config="$tdir/client.conf"
            cat >"$config" <<STUNNEL_CLIENT_EOF
foreground = yes
client = yes
verifyChain = yes
CAfile = $tdir/server-ca.pem
sslVersionMin = TLSv1.2

[nnslink]
accept = 127.0.0.1:$LOCAL_PORT
connect = $PUBLIC_HOST:$PUBLIC_PORT
checkHost = $PUBLIC_HOST
sni = $PUBLIC_HOST
STUNNEL_CLIENT_EOF
            if [[ "$PUBLIC_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                sed -i "s/^checkHost = /checkIP = /; /^sni = /d" "$config"
            fi
            chmod 0600 "$config"
            ;;
        cloak)
            config="$tdir/client.json"
            install -o root -g root -m 0600 \
                "$temp/extracted/cloak-client.json" "$config"
            ;;
    esac

    cfg_set "$app" TRANSPORT_TYPE "$TRANSPORT"
    if [[ "$TRANSPORT" == direct ]]; then
        cfg_set "$app" TRANSPORT_REMOTE_HOST ""
        cfg_set "$app" TRANSPORT_REMOTE_PORT ""
        cfg_set "$app" TRANSPORT_LOCAL_PORT ""
        cfg_set "$app" TRANSPORT_CONFIG ""
    else
        cfg_set "$app" TRANSPORT_REMOTE_HOST "$PUBLIC_HOST"
        cfg_set "$app" TRANSPORT_REMOTE_PORT "$PUBLIC_PORT"
        cfg_set "$app" TRANSPORT_LOCAL_PORT "$LOCAL_PORT"
        cfg_set "$app" TRANSPORT_CONFIG "$config"
    fi

    NNSLINK_GATEWAY=$GATEWAY
    NNSLINK_CLIENT=$CLIENT
    NNSLINK_GENERATION=$GENERATION
    NNSLINK_TRANSPORT=$TRANSPORT
    rm -rf "$temp"
    log "Imported $TRANSPORT .nnslink profile for '$app' ($GATEWAY/$CLIENT generation $GENERATION)."
}

load_remote_cfg() {
    local alias=$1 file owner mode mode_octal
    validate_remote_alias "$alias"
    file=$(remote_cfg_file "$alias")
    [[ -f "$file" ]] || die "Remote '$alias' is not registered."
    owner=$(stat -c '%u' "$file")
    mode=$(stat -c '%a' "$file")
    mode_octal=$((8#$mode))
    [[ "$owner" == 0 && $((mode_octal & 0077)) == 0 ]] ||
        die "Unsafe remote config permissions on $file."
    SSH_TARGET="" SSH_PORT="" SSH_IDENTITY="" SSH_HOST_FINGERPRINT=""
    # shellcheck disable=SC1090
    source "$file"
    [[ -n "$SSH_TARGET" && "$SSH_PORT" =~ ^[1-9][0-9]{0,4}$ ]] ||
        die "Remote config '$file' is incomplete."
}

remote_ssh_args() {
    local alias=$1
    load_remote_cfg "$alias"
    REMOTE_SSH_ARGS=(
        ssh -o BatchMode=yes -o ConnectTimeout=10
        -o StrictHostKeyChecking=yes
        -o "UserKnownHostsFile=$(remote_known_hosts "$alias")"
        -p "$SSH_PORT"
    )
    [[ -z "$SSH_IDENTITY" ]] || REMOTE_SSH_ARGS+=( -i "$SSH_IDENTITY" -o IdentitiesOnly=yes )
    REMOTE_SSH_ARGS+=( "$SSH_TARGET" )
}

remote_command() {
    local alias=$1; shift
    remote_ssh_args "$alias"
    local quoted=() arg
    for arg in "$@"; do
        printf -v arg '%q' "$arg"
        quoted+=("$arg")
    done
    local payload
    printf -v payload 'if [ "$(id -u)" -eq 0 ]; then exec nns-app %s; else exec sudo -n nns-app %s; fi' \
        "${quoted[*]}" "${quoted[*]}"
    "${REMOTE_SSH_ARGS[@]}" "$payload"
}

remote_add() {
    require_root
    local alias=$1 target=$2 port=${3:-22} identity=${4:-}
    validate_remote_alias "$alias"
    validate_ssh_target "$target"
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ && "$port" -le 65535 ]] || die "Invalid SSH port '$port'."
    if [[ -n "$identity" ]]; then
        identity=$(readlink -f "$identity")
        [[ -f "$identity" ]] || die "SSH identity file not found: $identity"
    fi
    [[ ! -e "$(remote_cfg_file "$alias")" ]] || die "Remote '$alias' already exists."

    local dir known cfg tmp fingerprint version_output
    dir=$(remote_dir "$alias")
    known=$(remote_known_hosts "$alias")
    cfg=$(remote_cfg_file "$alias")
    install -d -o root -g root -m 0700 "$dir"
    touch "$known"; chown root:root "$known"; chmod 0600 "$known"

    local -a args=(ssh -o BatchMode=yes -o ConnectTimeout=10
        -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known" -p "$port")
    [[ -z "$identity" ]] || args+=( -i "$identity" -o IdentitiesOnly=yes )
    args+=( "$target" 'if [ "$(id -u)" -eq 0 ]; then exec nns-app --version; else exec sudo -n nns-app --version; fi' )
    version_output=$("${args[@]}") || {
        rm -rf "$dir"
        die "Cannot verify nns-app on remote '$target' using non-interactive SSH/sudo."
    }
    python3 - "$version_output" <<'PY_REMOTE_VERSION' || {
import re
import sys

match = re.search(r"(?m)^nns-app[ \t]+([0-9]+)\.([0-9]+)\.([0-9]+)[ \t]*$", sys.argv[1])
if match is None or tuple(map(int, match.groups())) < (1, 2, 0):
    raise SystemExit(1)
PY_REMOTE_VERSION
        rm -rf "$dir"
        die "Remote '$target' must run nns-app 1.2.0 or newer."
    }
    fingerprint=$(ssh-keygen -lf "$known" -E sha256 2>/dev/null | awk 'NR==1 {print $2}')
    [[ -n "$fingerprint" ]] || { rm -rf "$dir"; die "Could not record the SSH host-key fingerprint."; }

    tmp=$(mktemp)
    {
        printf 'SSH_TARGET=%q\n' "$target"
        printf 'SSH_PORT=%q\n' "$port"
        printf 'SSH_IDENTITY=%q\n' "$identity"
        printf 'SSH_HOST_FINGERPRINT=%q\n' "$fingerprint"
    } >"$tmp"
    install -o root -g root -m 0600 "$tmp" "$cfg"
    rm -f "$tmp"
    log "Registered remote '$alias' ($target, host key $fingerprint)."
}

parse_remote_ref() {
    local ref=$1
    [[ "$ref" == *:* ]] || die "Remote gateway must be written as <remote>:<gateway>."
    REMOTE_REF_ALIAS=${ref%%:*}
    REMOTE_REF_GATEWAY=${ref#*:}
    validate_remote_alias "$REMOTE_REF_ALIAS"
    validate_gateway_name "$REMOTE_REF_GATEWAY"
}

remote_import_bundle() {
    local alias=$1 gateway=$2 client=$3 app=$4 bundle=$5
    local was_started=no restart_via=__default__
    if app_is_started "$app" || systemctl is-active --quiet "nns-netns@${app}.service"; then
        was_started=yes
        restart_via=$(runtime_via_for_app "$app" 2>/dev/null || printf '__default__')
    fi

    nnslink_import "$app" "$bundle" "$gateway" "$client"
    cfg_set "$app" REMOTE_ALIAS "$alias"
    cfg_set "$app" REMOTE_GATEWAY "$gateway"
    cfg_set "$app" REMOTE_CLIENT "$client"
    cfg_set "$app" REMOTE_PROFILE_GENERATION "$NNSLINK_GENERATION"
    load_remote_cfg "$alias"
    cfg_set "$app" REMOTE_SERVER_FINGERPRINT "$SSH_HOST_FINGERPRINT"

    # Endpoint routes and kill-switch rules are created with the namespace, so
    # replacing a live bundle requires a full namespace restart rather than
    # only restarting OpenVPN.
    if [[ "$was_started" == yes ]]; then
        stop_app "$app"
        start_app "$app" off "$restart_via"
        log "Restarted '$app' to apply synchronized endpoint and transport state."
    fi
}

remote_connect() {
    require_root
    local ref=$1 client=$2 app=$3 backend=${4:-openvpn} temp
    parse_remote_ref "$ref"
    [[ "$backend" == openvpn ]] || die "Only the OpenVPN gateway backend is currently supported."
    validate_gateway_client_name "$client"
    validate_app_name "$app"
    load_remote_cfg "$REMOTE_REF_ALIAS"

    remote_command "$REMOTE_REF_ALIAS" gateway client add "$REMOTE_REF_GATEWAY" "$client"
    temp=$(mktemp --suffix=.nnslink)
    remote_command "$REMOTE_REF_ALIAS" gateway client export \
        "$REMOTE_REF_GATEWAY" "$client" --format nnslink --output - >"$temp"
    [[ -s "$temp" ]] || die "Remote gateway returned an empty .nnslink bundle."
    if [[ ! -f "$(cfg_file "$app")" ]]; then
        install_app "$app" __default__
    fi
    remote_import_bundle "$REMOTE_REF_ALIAS" "$REMOTE_REF_GATEWAY" "$client" "$app" "$temp"
    rm -f "$temp"
    log "Connected local app '$app' to $REMOTE_REF_ALIAS:$REMOTE_REF_GATEWAY as '$client'."
}

load_app_remote_metadata() {
    local app=$1
    load_cfg "$app"
    [[ -n "${REMOTE_ALIAS:-}" && -n "${REMOTE_GATEWAY:-}" && -n "${REMOTE_CLIENT:-}" ]] ||
        die "App '$app' is not managed by an nns-app remote."
}

remote_sync() {
    require_root
    local app=$1 temp alias gateway client
    load_app_remote_metadata "$app"
    alias=$REMOTE_ALIAS gateway=$REMOTE_GATEWAY client=$REMOTE_CLIENT
    temp=$(mktemp --suffix=.nnslink)
    remote_command "$alias" gateway client export "$gateway" "$client" \
        --format nnslink --output - >"$temp"
    remote_import_bundle "$alias" "$gateway" "$client" "$app" "$temp"
    rm -f "$temp"
    log "Synchronized '$app' from '$alias:$gateway'."
}

remote_rotate() {
    require_root
    local app=$1 alias gateway client
    load_app_remote_metadata "$app"
    alias=$REMOTE_ALIAS gateway=$REMOTE_GATEWAY client=$REMOTE_CLIENT
    remote_command "$alias" gateway client rotate "$gateway" "$client"
    remote_sync "$app"
    log "Rotated and synchronized credentials for '$app'."
}

remote_status() {
    require_root
    local target=$1 alias gateway client generation fingerprint
    if [[ -f "$(cfg_file "$target")" ]]; then
        load_app_remote_metadata "$target"
        alias=$REMOTE_ALIAS gateway=$REMOTE_GATEWAY client=$REMOTE_CLIENT
        generation=${REMOTE_PROFILE_GENERATION:-unknown}
        fingerprint=${REMOTE_SERVER_FINGERPRINT:-unknown}
        printf 'Local app:          %s\n' "$target"
        printf 'Remote:             %s\n' "$alias"
        printf 'Gateway/client:     %s/%s\n' "$gateway" "$client"
        printf 'Profile generation: %s\n' "$generation"
        printf 'Pinned SSH key:     %s\n' "$fingerprint"
        printf '\nRemote gateway status:\n'
        remote_command "$alias" gateway status "$gateway"
    else
        alias=$target
        load_remote_cfg "$alias"
        printf 'Remote:         %s\n' "$alias"
        printf 'SSH target:     %s:%s\n' "$SSH_TARGET" "$SSH_PORT"
        printf 'Pinned host key:%s\n' " $SSH_HOST_FINGERPRINT"
        printf 'Connectivity:   '
        if remote_command "$alias" --version >/dev/null 2>&1; then
            printf 'online\n'
        else
            printf 'offline\n'
            return 1
        fi
    fi
}

gateway_transport_dir() {
    local gateway=$1 root=${2:-$(gateway_dir "$gateway")}
    printf '%s/transport\n' "$root"
}

gateway_allocate_backend_port() {
    local gateway=$1 crc start port dir used
    crc=$(printf 'transport:%s' "$gateway" | cksum | awk '{print $1}')
    start=$((20000 + crc % 8000))
    for ((used=0; used<8000; used++)); do
        port=$((20000 + (start - 20000 + used) % 8000))
        if ! grep -RhsE '^OPENVPN_LISTEN_PORT=' "$GATEWAY_BASE_DIR"/*/gateway.cfg 2>/dev/null |
             grep -Eq "=\"?${port}\"?$" &&
           ! ss -H -lntun 2>/dev/null | grep -Eq "[:.]${port}[[:space:]]"; then
            printf '%s\n' "$port"
            return 0
        fi
    done
    die "No free private OpenVPN transport port remains."
}

gateway_transport_binary() {
    case "$1" in
        stunnel) command -v stunnel4 2>/dev/null || command -v stunnel 2>/dev/null ;;
        cloak) command -v ck-server 2>/dev/null ;;
        direct) return 1 ;;
        *) return 1 ;;
    esac
}

gateway_prepare_transport() {
    local gateway=$1 root=$2 transport=$3 tdir binary keys public_key private_key san
    reset_gateway_cfg_vars
    # shellcheck disable=SC1090
    source "$root/gateway.cfg"
    tdir=$(gateway_transport_dir "$gateway" "$root")
    install -d -o root -g root -m 0700 "$tdir"
    case "$transport" in
        direct) ;;
        stunnel)
            binary=$(gateway_transport_binary stunnel || true)
            [[ -n "$binary" ]] || die "stunnel transport requires stunnel4 (or stunnel) to be installed."
            openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
                -out "$tdir/ca.key" >/dev/null 2>&1
            openssl req -x509 -new -sha256 -days 3650 \
                -key "$tdir/ca.key" -subj "/CN=nns-app $gateway transport CA" \
                -out "$tdir/ca.crt" >/dev/null 2>&1
            openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
                -out "$tdir/server.key" >/dev/null 2>&1
            if [[ "$PUBLIC_HOST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                san="IP:$PUBLIC_HOST"
            else
                san="DNS:$PUBLIC_HOST"
            fi
            cat >"$tdir/server-ext.cnf" <<STUNNEL_EXT_EOF
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$san
STUNNEL_EXT_EOF
            openssl req -new -sha256 -key "$tdir/server.key" \
                -subj "/CN=$PUBLIC_HOST" -out "$tdir/server.csr" >/dev/null 2>&1
            openssl x509 -req -sha256 -days 825 \
                -in "$tdir/server.csr" -CA "$tdir/ca.crt" -CAkey "$tdir/ca.key" \
                -CAcreateserial -extfile "$tdir/server-ext.cnf" \
                -out "$tdir/server.crt" >/dev/null 2>&1
            cat "$tdir/server.crt" "$tdir/ca.crt" >"$tdir/server-chain.crt"
            rm -f "$tdir/server.csr" "$tdir/server-ext.cnf" "$tdir/ca.srl"
            chown -R root:root "$tdir"
            chmod 0600 "$tdir/ca.key" "$tdir/server.key"
            chmod 0644 "$tdir/ca.crt" "$tdir/server.crt" "$tdir/server-chain.crt"
            ;;
        cloak)
            binary=$(gateway_transport_binary cloak || true)
            [[ -n "$binary" ]] || die "cloak transport requires ck-server to be installed."
            keys=$("$binary" -key 2>/dev/null || "$binary" -k 2>/dev/null || true)
            local -a cloak_keys=()
            mapfile -t cloak_keys < <(python3 - "$keys" <<'PY_CLOAK_KEYS'
import base64
import binascii
import sys

parts = [part.strip() for part in sys.argv[1].strip().split(",")]
if len(parts) != 2:
    raise SystemExit(1)
for value in parts:
    try:
        raw = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error):
        raise SystemExit(1)
    if len(raw) != 32:
        raise SystemExit(1)
    print(value)
PY_CLOAK_KEYS
            )
            (( ${#cloak_keys[@]} == 2 )) ||
                die "ck-server did not return a valid public/private key pair."
            public_key=${cloak_keys[0]}
            private_key=${cloak_keys[1]}
            printf '%s\n' "$public_key" >"$tdir/public.key"
            printf '%s\n' "$private_key" >"$tdir/private.key"
            chown -R root:root "$tdir"
            chmod 0600 "$tdir/private.key"
            chmod 0644 "$tdir/public.key"
            ;;
        *) die "Unsupported gateway transport '$transport'." ;;
    esac
}

gateway_cloak_active_uids_json() {
    local gateway=$1 root=${2:-$(gateway_dir "$gateway")} dir cfg uid status first=1
    printf '['
    shopt -s nullglob
    for dir in "$root/clients"/*; do
        cfg="$dir/client.cfg"
        [[ -f "$cfg" ]] || continue
        status=$(awk -F= '/^STATUS=/{gsub(/^"|"$/, "", $2); print $2; exit}' "$cfg")
        uid=$(awk -F= '/^CLOAK_UID=/{sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit}' "$cfg")
        [[ "$status" == active && -n "$uid" ]] || continue
        (( first )) || printf ','
        python3 -c 'import json,sys; print(json.dumps(sys.argv[1]), end="")' "$uid"
        first=0
    done
    printf ']'
}

gateway_write_transport_config() {
    local gateway=$1 root=${2:-$(gateway_dir "$gateway")} tdir output private_key public_key uids
    if [[ "$root" == "$(gateway_dir "$gateway")" ]]; then
        load_gateway_cfg "$gateway"
    else
        reset_gateway_cfg_vars
        # shellcheck disable=SC1090
        source "$root/gateway.cfg"
        TRANSPORT=${TRANSPORT:-direct}
        OPENVPN_LISTEN_PROTO=${OPENVPN_LISTEN_PROTO:-$LISTEN_PROTO}
        OPENVPN_LISTEN_PORT=${OPENVPN_LISTEN_PORT:-$LISTEN_PORT}
    fi
    tdir=$(gateway_transport_dir "$gateway" "$root")
    case "${TRANSPORT:-direct}" in
        direct) return 0 ;;
        stunnel)
            output="$tdir/server.conf"
            cat >"$output" <<STUNNEL_SERVER_EOF
foreground = yes
client = no
cert = $tdir/server-chain.crt
key = $tdir/server.key
sslVersionMin = TLSv1.2

[nnslink]
accept = 0.0.0.0:$LISTEN_PORT
connect = 127.0.0.1:$OPENVPN_LISTEN_PORT
STUNNEL_SERVER_EOF
            chmod 0600 "$output"
            ;;
        cloak)
            private_key=$(<"$tdir/private.key")
            public_key=$(<"$tdir/public.key")
            uids=$(gateway_cloak_active_uids_json "$gateway" "$root")
            python3 - "$tdir/server.json" "$LISTEN_PORT" "$OPENVPN_LISTEN_PORT" \
                "$PUBLIC_HOST" "$private_key" "$uids" <<'PY_CLOAK_SERVER'
import json,sys
path, public_port, backend_port, server_name, private_key, uids = sys.argv[1:]
config = {
    "ProxyBook": {"openvpn": ["tcp", f"127.0.0.1:{backend_port}"]},
    "BindAddr": [f":{public_port}"],
    "BypassUID": json.loads(uids),
    "RedirAddr": f"{server_name}:443",
    "PrivateKey": private_key,
    "AdminUID": "",
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(config, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY_CLOAK_SERVER
            chmod 0600 "$tdir/server.json"
            ;;
    esac
}

gateway_transport_server_exec() {
    local gateway=$1 type binary config openvpn_pid wrapper_pid rc=0
    load_gateway_cfg "$gateway"
    type=${TRANSPORT:-direct}
    [[ "$type" == stunnel || "$type" == cloak ]] || die "No wrapper transport configured."
    binary=$(gateway_transport_binary "$type" || true)
    [[ -n "$binary" ]] || die "Gateway transport binary for '$type' is missing."
    gateway_write_transport_config "$gateway"
    config=$(gateway_server_config "$gateway")

    gateway_transport_cleanup() {
        [[ -z "${openvpn_pid:-}" ]] || kill "$openvpn_pid" 2>/dev/null || true
        [[ -z "${wrapper_pid:-}" ]] || kill "$wrapper_pid" 2>/dev/null || true
        wait "${openvpn_pid:-0}" "${wrapper_pid:-0}" 2>/dev/null || true
    }
    trap 'exit 0' TERM INT HUP
    trap gateway_transport_cleanup EXIT

    /usr/sbin/openvpn --config "$config" &
    openvpn_pid=$!
    case "$type" in
        stunnel) "$binary" "$(gateway_transport_dir "$gateway")/server.conf" & ;;
        cloak) "$binary" -c "$(gateway_transport_dir "$gateway")/server.json" & ;;
    esac
    wrapper_pid=$!
    wait -n "$openvpn_pid" "$wrapper_pid" || rc=$?
    kill "$openvpn_pid" "$wrapper_pid" 2>/dev/null || true
    wait "$openvpn_pid" "$wrapper_pid" 2>/dev/null || true
    (( rc == 0 )) || return "$rc"
    die "A gateway transport process exited unexpectedly."
}

gateway_cloak_new_uid() {
    local binary uid
    binary=$(gateway_transport_binary cloak || true)
    [[ -n "$binary" ]] || return 1
    uid=$("$binary" -uid 2>/dev/null || "$binary" -u 2>/dev/null || true)
    uid=${uid##*$'\n'}
    python3 - "$uid" <<'PY_CLOAK_UID'
import base64
import binascii
import sys

value = sys.argv[1].strip()
try:
    raw = base64.b64decode(value, validate=True)
except (ValueError, binascii.Error):
    raise SystemExit(1)
if len(raw) != 16:
    raise SystemExit(1)
print(value)
PY_CLOAK_UID
}

gateway_write_client_profile_file() {
    local gateway=$1 client=$2 output=$3 target_mode=${4:-public}
    local cdir pki proto remote_host remote_port
    load_gateway_cfg "$gateway"
    gateway_client_load "$gateway" "$client"
    cdir=$(gateway_client_dir "$gateway" "$client")
    pki=$(gateway_pki_dir "$gateway")

    if [[ "$target_mode" == local ]]; then
        proto=tcp-client
        remote_host=127.0.0.1
        remote_port=11940
    else
        [[ "$LISTEN_PROTO" == tcp ]] && proto=tcp-client || proto=udp
        remote_host=$PUBLIC_HOST
        remote_port=$PUBLIC_PORT
    fi

    {
        printf '# nns-app managed gateway profile: %s / %s\n' "$gateway" "$client"
        printf 'client\n'
        printf 'dev tun\n'
        printf 'proto %s\n' "$proto"
        printf 'remote %s %s\n' "$remote_host" "$remote_port"
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
        if [[ "$target_mode" == public && "$LISTEN_PROTO" == udp ]]; then
            printf 'explicit-exit-notify 2\n'
        fi
        printf 'verb 3\n'
        printf '\n<ca>\n'; cat "$pki/ca.crt"; printf '</ca>\n'
        printf '\n<cert>\n'; cat "$cdir/client.crt"; printf '</cert>\n'
        printf '\n<key>\n'; cat "$cdir/client.key"; printf '</key>\n'
        printf '\n<tls-crypt-v2>\n'; cat "$cdir/tls-crypt-v2-client.key"; printf '</tls-crypt-v2>\n'
    } >"$output"
    chmod 0600 "$output"
}

gateway_write_nnslink_bundle() {
    local gateway=$1 client=$2 output=$3 temp transport local_port=11940 tdir public_key
    load_gateway_cfg "$gateway"
    gateway_client_load "$gateway" "$client"
    transport=${TRANSPORT:-direct}
    temp=$(mktemp -d)

    if [[ "$transport" == direct ]]; then
        gateway_write_client_profile_file "$gateway" "$client" "$temp/client.ovpn" public
    else
        gateway_write_client_profile_file "$gateway" "$client" "$temp/client.ovpn" local
    fi
    tdir=$(gateway_transport_dir "$gateway")
    case "$transport" in
        direct) ;;
        stunnel)
            install -m 0644 "$tdir/ca.crt" "$temp/stunnel-ca.pem"
            ;;
        cloak)
            [[ -n "$CLOAK_UID" ]] || die "Cloak client '$client' has no UID; rotate it before export."
            public_key=$(<"$tdir/public.key")
            python3 - "$temp/cloak-client.json" "$CLOAK_UID" "$public_key" \
                "$TRANSPORT_SERVER_NAME" <<'PY_CLOAK_CLIENT'
import json,sys
path, uid, public_key, server_name = sys.argv[1:]
config = {
    "Transport": "direct",
    "ProxyMethod": "openvpn",
    "EncryptionMethod": "chacha20-poly1305",
    "UID": uid,
    "PublicKey": public_key,
    "ServerName": server_name,
    "NumConn": 4,
    "BrowserSig": "chrome",
    "StreamTimeout": 300,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(config, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY_CLOAK_CLIENT
            chmod 0600 "$temp/cloak-client.json"
            ;;
    esac

    python3 - "$temp/manifest.json" "$gateway" "$client" "$transport" \
        "$PUBLIC_HOST" "$PUBLIC_PORT" "$local_port" "${GENERATION:-1}" <<'PY_NNSLINK_MANIFEST'
import json,sys
path, gateway, client, transport, host, port, local_port, generation = sys.argv[1:]
data = {
    "format": "nnslink",
    "version": 1,
    "gateway": gateway,
    "client": client,
    "generation": int(generation),
    "backend": "openvpn",
    "transport": transport,
    "public_host": host,
    "public_port": int(port),
    "local_port": int(local_port),
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY_NNSLINK_MANIFEST
    chmod 0600 "$temp/manifest.json"

    python3 - "$temp" "$output" <<'PY_NNSLINK_WRITE'
import gzip
import io
import os
import pathlib
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
target = sys.argv[2]
names = ["manifest.json", "client.ovpn", "stunnel-ca.pem", "cloak-client.json"]
buffer = io.BytesIO()
with tarfile.open(fileobj=buffer, mode="w") as tf:
    for name in names:
        path = root / name
        if not path.exists():
            continue
        data = path.read_bytes()
        info = tarfile.TarInfo(name)
        info.size = len(data)
        info.mode = 0o600
        info.uid = info.gid = 0
        info.uname = info.gname = "root"
        info.mtime = 0
        tf.addfile(info, io.BytesIO(data))
payload = gzip.compress(buffer.getvalue(), compresslevel=9, mtime=0)
if target == "-":
    sys.stdout.buffer.write(payload)
else:
    pathlib.Path(target).write_bytes(payload)
    os.chmod(target, 0o600)
PY_NNSLINK_WRITE
    rm -rf "$temp"
}

gateway_client_rotate() {
    require_root
    local gateway=$1 client=$2 pki final old backup generation rc=0 tmp
    validate_gateway_name "$gateway"
    validate_gateway_client_name "$client"
    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"
    gateway_client_load "$gateway" "$client"
    [[ "${STATUS:-}" == active ]] || die "Client '$client' is revoked and cannot be rotated."
    generation=$(( ${GENERATION:-1} + 1 ))
    pki=$(gateway_pki_dir "$gateway")
    final=$(gateway_client_dir "$gateway" "$client")
    old=$(mktemp -d "$(gateway_clients_dir "$gateway")/.${client}.old.XXXXXX")
    rmdir "$old"
    backup=$(mktemp -d "$(gateway_dir "$gateway")/.ca-db.XXXXXX")
    gateway_ca_snapshot "$pki" "$backup" || {
        rm -rf "$backup"
        release_lock "gateway-$gateway"
        die "Failed to snapshot the gateway CA database."
    }
    mv "$final" "$old"

    if ! ( NNS_SUPPRESS_GATEWAY_RESTART=1 gateway_client_add "$gateway" "$client" ) >/dev/null 2>&1; then
        gateway_ca_restore "$pki" "$backup" || true
        rm -rf "$final"
        mv "$old" "$final"
        rm -rf "$backup"
        release_lock "gateway-$gateway"
        die "Failed to issue replacement credentials for '$client'."
    fi

    openssl ca -batch -config "$pki/openssl.cnf" \
        -revoke "$old/client.crt" >/dev/null 2>&1 || rc=1
    (( rc != 0 )) || gateway_generate_crl_at "$pki" || rc=1
    if (( rc != 0 )); then
        rm -rf "$final"
        gateway_ca_restore "$pki" "$backup" || true
        mv "$old" "$final"
        rm -rf "$backup"
        release_lock "gateway-$gateway"
        die "Failed to revoke the previous certificate; rotation was rolled back."
    fi

    tmp=$(mktemp)
    awk -v generation="$generation" '
        /^GENERATION=/ { print "GENERATION=\"" generation "\""; done=1; next }
        { print }
        END { if (!done) print "GENERATION=\"" generation "\""" }
    ' "$final/client.cfg" >"$tmp"
    install -o root -g root -m 0600 "$tmp" "$final/client.cfg"
    rm -f "$tmp"
    rm -rf "$old" "$backup"

    gateway_write_transport_config "$gateway"
    local restart=no
    systemctl is-active --quiet "nns-gateway@${gateway}.service" && restart=yes
    release_lock "gateway-$gateway"
    if [[ "$restart" == yes ]]; then
        systemctl restart "nns-gateway@${gateway}.service" ||
            warn "Client '$client' was rotated, but gateway '$gateway' failed to restart."
    fi
    log "Rotated client '$client' on gateway '$gateway' to generation $generation."
}
