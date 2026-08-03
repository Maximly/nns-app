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
    cfg_set "$app" TRANSPORT_SSH_TARGET ""
    cfg_set "$app" TRANSPORT_SSH_IDENTITY ""
    cfg_set "$app" TRANSPORT_SSH_KNOWN_HOSTS ""
    cfg_set "$app" TRANSPORT_SSH_REMOTE_PORT ""
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
        ssh) command -v ssh 2>/dev/null ;;
        *) return 1 ;;
    esac
}

transport_client_exec() {
    local app=$1 profile=$2 type binary wrapper_pid vpn_pid rc=0
    load_cfg "$app"
    type=${TRANSPORT_TYPE:-direct}
    [[ "$type" == stunnel || "$type" == cloak || "$type" == ssh ]] ||
        die "Unsupported local transport '$type'."
    if [[ "$type" == stunnel || "$type" == cloak ]]; then
        [[ -n "$TRANSPORT_CONFIG" && -f "$TRANSPORT_CONFIG" ]] ||
            die "Transport config is missing for '$app'. Re-import its .nnslink bundle."
    fi
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
        ssh)
            validate_ssh_target "$TRANSPORT_SSH_TARGET"
            [[ -f "$TRANSPORT_SSH_IDENTITY" && ! -L "$TRANSPORT_SSH_IDENTITY" ]] ||
                die "Automatic-remote SSH identity is missing for '$app'. Re-run install --via-remote."
            [[ -f "$TRANSPORT_SSH_KNOWN_HOSTS" && ! -L "$TRANSPORT_SSH_KNOWN_HOSTS" ]] ||
                die "Automatic-remote SSH host-key pin is missing for '$app'. Re-run install --via-remote."
            [[ "$TRANSPORT_SSH_REMOTE_PORT" =~ ^[1-9][0-9]{0,4}$ &&
               "$TRANSPORT_SSH_REMOTE_PORT" -le 65535 ]] ||
                die "Automatic-remote OpenVPN port is invalid for '$app'. Re-add its profile."
            ip netns exec "$NS_NAME" "$binary" -F /dev/null -N -T \
                -o BatchMode=yes \
                -o ExitOnForwardFailure=yes \
                -o ServerAliveInterval=15 \
                -o ServerAliveCountMax=3 \
                -o TCPKeepAlive=yes \
                -o StrictHostKeyChecking=yes \
                -o "UserKnownHostsFile=$TRANSPORT_SSH_KNOWN_HOSTS" \
                -o PasswordAuthentication=no \
                -o KbdInteractiveAuthentication=no \
                -o LogLevel=ERROR \
                -i "$TRANSPORT_SSH_IDENTITY" \
                -p "$TRANSPORT_REMOTE_PORT" \
                -L "127.0.0.1:${TRANSPORT_LOCAL_PORT}:127.0.0.1:${TRANSPORT_SSH_REMOTE_PORT}" \
                "$TRANSPORT_SSH_TARGET" &
            wrapper_pid=$!
            ;;
    esac

    local deadline=$((SECONDS + 10))
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
if transport not in {"direct", "stunnel", "cloak", "ssh"}:
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
if transport == "ssh":
    value = manifest.get("ssh_remote_port")
    if not isinstance(value, int) or value < 1 or value > 65535:
        raise SystemExit("invalid manifest field: ssh_remote_port")
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
keys = ["gateway", "client", "backend", "transport", "public_host", "public_port", "local_port", "generation"]
if transport == "ssh":
    keys.append("ssh_remote_port")
for key in keys:
    print(f"{key.upper()}={json.dumps(manifest[key], separators=(',', ':'))}")
PY_NNSLINK_READ
}

nnslink_import() {
    require_root
    local app=$1 bundle=$2 expected_gateway=${3:-} expected_client=${4:-}
    local temp manifest_values
    local GATEWAY CLIENT BACKEND TRANSPORT PUBLIC_HOST PUBLIC_PORT LOCAL_PORT GENERATION SSH_REMOTE_PORT
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
            GATEWAY|CLIENT|BACKEND|TRANSPORT|PUBLIC_HOST|PUBLIC_PORT|LOCAL_PORT|GENERATION|SSH_REMOTE_PORT)
                printf -v "$key" '%s' "$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read()))' <<<"$value")"
                ;;
        esac
    done <<<"$manifest_values"

    [[ -z "$expected_gateway" || "$GATEWAY" == "$expected_gateway" ]] ||
        die ".nnslink gateway '$GATEWAY' does not match expected '$expected_gateway'."
    [[ -z "$expected_client" || "$CLIENT" == "$expected_client" ]] ||
        die ".nnslink client '$CLIENT' does not match expected '$expected_client'."
    [[ "$BACKEND" == openvpn ]] || die "Only OpenVPN .nnslink bundles are supported."
    if [[ "$TRANSPORT" == ssh ]]; then
        load_cfg "$app"
        [[ "${REMOTE_MODE:-}" == auto ]] ||
            die "SSH-forward .nnslink bundles are internal to install --via-remote; use direct, stunnel or Cloak for manual import."
    fi

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
        ssh)
            binary=$(transport_binary_for_type ssh || true)
            [[ -n "$binary" ]] || die "Install openssh-client before importing this bundle."
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
        ssh)
            config=""
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
    if [[ "$TRANSPORT" == ssh ]]; then
        cfg_set "$app" TRANSPORT_SSH_REMOTE_PORT "$SSH_REMOTE_PORT"
    else
        cfg_set "$app" TRANSPORT_SSH_TARGET ""
        cfg_set "$app" TRANSPORT_SSH_IDENTITY ""
        cfg_set "$app" TRANSPORT_SSH_KNOWN_HOSTS ""
        cfg_set "$app" TRANSPORT_SSH_REMOTE_PORT ""
    fi

    NNSLINK_GATEWAY=$GATEWAY
    NNSLINK_CLIENT=$CLIENT
    NNSLINK_GENERATION=$GENERATION
    NNSLINK_TRANSPORT=$TRANSPORT
    NNSLINK_SSH_REMOTE_PORT=${SSH_REMOTE_PORT:-}
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

shell_join_quoted() {
    local output="" arg quoted
    for arg in "$@"; do
        printf -v quoted '%q' "$arg"
        if [[ -n "$output" ]]; then
            output+=" "
        fi
        output+="$quoted"
    done
    printf '%s' "$output"
}

remote_command_payload() {
    local command
    command=$(shell_join_quoted nns-app "$@")
    printf 'if [ "$(id -u)" -eq 0 ]; then exec %s; else exec sudo -n %s; fi' \
        "$command" "$command"
}

remote_command() {
    local alias=$1 payload; shift
    remote_ssh_args "$alias"
    payload=$(remote_command_payload "$@")
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
    # Automatic SSH bundles intentionally omit the private management key.
    # Restore the local root-owned key and pinned host file before restarting
    # a live environment after synchronization.
    load_cfg "$app"
    if [[ "${REMOTE_MODE:-}" == auto && "${NNSLINK_TRANSPORT:-}" == ssh ]]; then
        cfg_set "$app" TRANSPORT_SSH_TARGET "$SSH_TARGET"
        cfg_set "$app" TRANSPORT_SSH_IDENTITY "$SSH_IDENTITY"
        cfg_set "$app" TRANSPORT_SSH_KNOWN_HOSTS "$(remote_known_hosts "$alias")"
    fi

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
    local app=$1 temp alias gateway client mode owner
    load_app_remote_metadata "$app"
    alias=$REMOTE_ALIAS gateway=$REMOTE_GATEWAY client=$REMOTE_CLIENT
    mode=${REMOTE_MODE:-}
    owner=${REMOTE_OWNER_ID:-}
    temp=$(mktemp --suffix=.nnslink)
    if [[ "$mode" == auto ]]; then
        remote_auto_command "$alias" export "$owner" >"$temp"
    else
        remote_command "$alias" gateway client export "$gateway" "$client" \
            --format nnslink --output - >"$temp"
    fi
    remote_import_bundle "$alias" "$gateway" "$client" "$app" "$temp"
    rm -f "$temp"
    if [[ "$mode" == auto ]]; then
        load_remote_cfg "$alias"
        cfg_set "$app" REMOTE_MODE auto
        cfg_set "$app" REMOTE_OWNER_ID "$owner"
        cfg_set "$app" REMOTE_EXIT_APP "$(remote_auto_exit_name "$owner")"
        cfg_set "$app" TRANSPORT_SSH_TARGET "$SSH_TARGET"
        cfg_set "$app" TRANSPORT_SSH_IDENTITY "$SSH_IDENTITY"
        cfg_set "$app" TRANSPORT_SSH_KNOWN_HOSTS "$(remote_known_hosts "$alias")"
    fi
    log "Synchronized '$app' from '$alias:$gateway'."
}

remote_rotate() {
    require_root
    local app=$1 alias gateway client mode owner
    load_app_remote_metadata "$app"
    alias=$REMOTE_ALIAS gateway=$REMOTE_GATEWAY client=$REMOTE_CLIENT
    mode=${REMOTE_MODE:-}
    owner=${REMOTE_OWNER_ID:-}
    if [[ "$mode" == auto ]]; then
        remote_auto_command "$alias" rotate "$owner"
    else
        remote_command "$alias" gateway client rotate "$gateway" "$client"
    fi
    remote_sync "$app"
    log "Rotated and synchronized credentials for '$app'."
}

remote_status() {
    require_root
    local target=$1 alias gateway client generation fingerprint mode owner
    if [[ -f "$(cfg_file "$target")" ]]; then
        load_app_remote_metadata "$target"
        alias=$REMOTE_ALIAS gateway=$REMOTE_GATEWAY client=$REMOTE_CLIENT
        mode=${REMOTE_MODE:-}
        owner=${REMOTE_OWNER_ID:-}
        generation=${REMOTE_PROFILE_GENERATION:-unknown}
        fingerprint=${REMOTE_SERVER_FINGERPRINT:-unknown}
        printf 'Local app:          %s\n' "$target"
        printf 'Remote:             %s\n' "$alias"
        printf 'Mode:               %s\n' "${mode:-manual}"
        printf 'Gateway/client:     %s/%s\n' "$gateway" "$client"
        printf 'Profile generation: %s\n' "$generation"
        printf 'Pinned SSH key:     %s\n' "$fingerprint"
        printf '\nRemote gateway status:\n'
        if [[ "$mode" == auto ]]; then
            remote_auto_command "$alias" status "$owner"
        else
            remote_command "$alias" gateway status "$gateway"
        fi
    else
        alias=$target
        load_remote_cfg "$alias"
        printf 'Remote:         %s\n' "$alias"
        printf 'SSH target:     %s:%s\n' "$SSH_TARGET" "$SSH_PORT"
        printf 'Pinned host key:%s\n' " $SSH_HOST_FINGERPRINT"
        printf 'Connectivity:   '
        if remote_command "$alias" --version >/dev/null 2>&1 ||
           remote_auto_command "$alias" version >/dev/null 2>&1; then
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
        direct|ssh) ;;
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
        direct|ssh) return 0 ;;
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
        ssh) ;;
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
        "$PUBLIC_HOST" "$PUBLIC_PORT" "$local_port" "${GENERATION:-1}" \
        "$OPENVPN_LISTEN_PORT" <<'PY_NNSLINK_MANIFEST'
import json,sys
path, gateway, client, transport, host, port, local_port, generation, remote_port = sys.argv[1:]
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
if transport == "ssh":
    data["ssh_remote_port"] = int(remote_port)
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

# Automatic remote mode ------------------------------------------------------
# The public three-command workflow uses SSH for both bootstrap and a
# supervised local port forward. The remote OpenVPN gateway is loopback-only,
# so no cloud firewall or additional public listener is required.

validate_remote_owner_id() {
    local owner=${1:-}
    [[ "$owner" =~ ^[a-f0-9]{16}$ ]] ||
        die "Invalid automatic-remote owner ID '$owner'."
}

remote_auto_exit_name() {
    validate_remote_owner_id "$1"
    printf 'ra-%s-exit\n' "${1:0:12}"
}

remote_auto_gateway_name() {
    validate_remote_owner_id "$1"
    printf 'ra-%s-gw\n' "${1:0:12}"
}

remote_auto_client_name() {
    validate_remote_owner_id "$1"
    printf 'ra-%s-client\n' "${1:0:12}"
}

remote_auto_state_file() {
    validate_remote_owner_id "$1"
    printf '%s/remote-auto/%s.cfg\n' "$STATE_DIR" "$1"
}

remote_auto_authorize() {
    require_root
    local user=$1 hash alias file tmp
    [[ "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
        die "Invalid remote account name '$user'."
    id "$user" >/dev/null 2>&1 || die "Remote account '$user' does not exist."
    hash=$(printf '%s' "$user" | cksum | awk '{print $1}')
    alias="NNS_APP_REMOTE_AUTO_${hash}"
    file="/etc/sudoers.d/nns-app-remote-auto-${user}"
    tmp=$(mktemp)
    cat >"$tmp" <<REMOTE_AUTO_SUDOERS
Cmnd_Alias $alias = $ENGINE_PATH _remote-auto *
$user ALL=(root) NOPASSWD: $alias
REMOTE_AUTO_SUDOERS
    visudo -cf "$tmp" >/dev/null || {
        rm -f "$tmp"
        die "Generated automatic-remote sudoers rule failed validation."
    }
    install -o root -g root -m 0440 "$tmp" "$file"
    rm -f "$tmp"
    log "Authorized '$user' for restricted nns-app automatic-remote operations."
}

remote_auto_write_state() {
    local owner=$1 exit_app=$2 gateway=$3 client=$4 file tmp
    file=$(remote_auto_state_file "$owner")
    install -d -o root -g root -m 0700 "$(dirname "$file")"
    tmp=$(mktemp)
    {
        printf 'OWNER_ID=%q\n' "$owner"
        printf 'EXIT_APP=%q\n' "$exit_app"
        printf 'GATEWAY=%q\n' "$gateway"
        printf 'CLIENT=%q\n' "$client"
    } >"$tmp"
    install -o root -g root -m 0600 "$tmp" "$file"
    rm -f "$tmp"
}

remote_auto_assert_state() {
    local owner=$1 expected_exit expected_gateway expected_client file
    expected_exit=$(remote_auto_exit_name "$owner")
    expected_gateway=$(remote_auto_gateway_name "$owner")
    expected_client=$(remote_auto_client_name "$owner")
    file=$(remote_auto_state_file "$owner")
    [[ -f "$file" ]] || die "Automatic remote '$owner' is not deployed."
    local OWNER_ID="" EXIT_APP="" GATEWAY="" CLIENT=""
    # shellcheck disable=SC1090
    source "$file"
    [[ "$OWNER_ID" == "$owner" && "$EXIT_APP" == "$expected_exit" &&
       "$GATEWAY" == "$expected_gateway" && "$CLIENT" == "$expected_client" ]] ||
        die "Automatic-remote state '$file' is inconsistent."
}

remote_auto_deploy_internal() {
    require_root
    local owner=$1 ssh_host=$2 ssh_port=$3 profile_name=$4
    local exit_app gateway client temp temp_dir port
    validate_remote_owner_id "$owner"
    [[ "$ssh_host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] ||
        die "Invalid automatic-remote SSH host '$ssh_host'."
    [[ "$ssh_port" =~ ^[1-9][0-9]{0,4}$ && "$ssh_port" -le 65535 ]] ||
        die "Invalid automatic-remote SSH port '$ssh_port'."
    [[ "$profile_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] ||
        die "Invalid remote profile name '$profile_name'."

    exit_app=$(remote_auto_exit_name "$owner")
    gateway=$(remote_auto_gateway_name "$owner")
    client=$(remote_auto_client_name "$owner")
    temp_dir=$(mktemp -d)
    temp="$temp_dir/$profile_name"
    trap 'rm -rf "${temp_dir:-}"' EXIT
    cat >"$temp"
    [[ -s "$temp" ]] || die "The uploaded VPN profile is empty."
    local uploaded_type
    uploaded_type=$(profile_type_from_file "$temp" 2>/dev/null || true)
    [[ -n "$uploaded_type" ]] || die "The uploaded file is not an OpenVPN or WireGuard profile."
    case "$uploaded_type" in
        openvpn) validate_ovpn "$temp" ;;
        wireguard) validate_wireguard "$temp" ;;
    esac

    if [[ ! -f "$(cfg_file "$exit_app")" ]]; then
        install_app "$exit_app" __default__
    fi
    load_cfg "$exit_app"
    [[ -z "${REMOTE_MANAGED_OWNER_ID:-}" ||
       "$REMOTE_MANAGED_OWNER_ID" == "$owner" ]] ||
        die "Automatic remote exit '$exit_app' belongs to another owner."
    cfg_set "$exit_app" REMOTE_MANAGED_OWNER_ID "$owner"

    if systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
        gateway_stop "$gateway"
    fi
    if app_is_started "$exit_app" ||
       systemctl is-active --quiet "nns-netns@${exit_app}.service"; then
        stop_app "$exit_app"
    fi

    add_profile "$exit_app" "$temp"
    cfg_set "$exit_app" READY_TIMEOUT 60
    cfg_set "$exit_app" AUTOSTART on
    start_app "$exit_app" off __default__

    if [[ ! -f "$(gateway_cfg_file "$gateway")" ]]; then
        port=$(gateway_allocate_backend_port "$gateway")
        gateway_create "$gateway" "$exit_app" "tcp:$port" \
            "$ssh_host:$ssh_port" "" "1.1.1.1 9.9.9.9" ssh ""
    else
        load_gateway_cfg "$gateway"
        [[ "$VIA_APP" == "$exit_app" && "${TRANSPORT:-}" == ssh &&
           "$PUBLIC_HOST" == "$ssh_host" && "$PUBLIC_PORT" == "$ssh_port" ]] ||
            die "Existing automatic gateway '$gateway' does not match this deployment."
        [[ -z "${REMOTE_MANAGED_OWNER_ID:-}" ||
           "$REMOTE_MANAGED_OWNER_ID" == "$owner" ]] ||
            die "Automatic gateway '$gateway' belongs to another owner."
    fi
    gateway_cfg_set "$gateway" REMOTE_MANAGED_OWNER_ID "$owner"

    if ! gateway_start "$gateway"; then
        die "Automatic gateway '$gateway' failed to start. The remote provider exit remains configured; rerun nns-app add after upgrading or correcting the gateway."
    fi
    systemctl enable "nns-gateway@${gateway}.service" >/dev/null

    if [[ ! -f "$(gateway_client_dir "$gateway" "$client")/client.cfg" ]]; then
        gateway_client_add "$gateway" "$client"
    else
        gateway_client_load "$gateway" "$client"
        if [[ "${STATUS:-}" != active ]]; then
            gateway_client_rotate "$gateway" "$client"
        fi
    fi
    remote_auto_write_state "$owner" "$exit_app" "$gateway" "$client"
    trap - EXIT
    rm -rf "$temp_dir"
    log "Automatic remote '$owner' is ready: $exit_app -> $gateway/$client."
}

remote_auto_export_internal() {
    require_root
    local owner=$1 gateway client
    remote_auto_assert_state "$owner"
    gateway=$(remote_auto_gateway_name "$owner")
    client=$(remote_auto_client_name "$owner")
    gateway_write_nnslink_bundle "$gateway" "$client" -
}

remote_auto_rotate_internal() {
    require_root
    local owner=$1 gateway client
    remote_auto_assert_state "$owner"
    gateway=$(remote_auto_gateway_name "$owner")
    client=$(remote_auto_client_name "$owner")
    gateway_client_rotate "$gateway" "$client"
}

remote_auto_status_internal() {
    require_root
    local owner=$1 exit_app gateway client
    remote_auto_assert_state "$owner"
    exit_app=$(remote_auto_exit_name "$owner")
    gateway=$(remote_auto_gateway_name "$owner")
    client=$(remote_auto_client_name "$owner")
    printf 'Automatic owner:    %s\n' "$owner"
    printf 'Remote exit app:    %s\n' "$exit_app"
    printf 'Remote gateway:     %s\n' "$gateway"
    printf 'Remote client:      %s\n\n' "$client"
    gateway_status "$gateway"
}

remote_auto_start_internal() {
    require_root
    local owner=$1 exit_app gateway
    remote_auto_assert_state "$owner"
    exit_app=$(remote_auto_exit_name "$owner")
    gateway=$(remote_auto_gateway_name "$owner")

    [[ -f "$(cfg_file "$exit_app")" ]] ||
        die "Automatic remote exit '$exit_app' is missing."
    [[ -f "$(gateway_cfg_file "$gateway")" ]] ||
        die "Automatic remote gateway '$gateway' is missing."

    load_cfg "$exit_app"
    [[ "${REMOTE_MANAGED_OWNER_ID:-}" == "$owner" ]] ||
        die "Refusing to start exit '$exit_app': owner marker mismatch."
    start_app "$exit_app" off __default__

    load_gateway_cfg "$gateway"
    [[ "$VIA_APP" == "$exit_app" ]] ||
        die "Refusing to start gateway '$gateway': it does not use '$exit_app'."
    [[ "${REMOTE_MANAGED_OWNER_ID:-}" == "$owner" ]] ||
        die "Refusing to start gateway '$gateway': owner marker mismatch."
    gateway_start "$gateway"

    # Keep boot recovery enabled even after an explicit stop/start cycle.
    systemctl enable \
        "nns-netns@${exit_app}.service" \
        "nns-openvpn@${exit_app}.service" \
        "nns-online@${exit_app}.service" \
        "nns-gateway@${gateway}.service" \
        >/dev/null
    log "Started automatic remote '$owner': $exit_app -> $gateway."
}

remote_auto_stop_internal() {
    require_root
    local owner=$1 exit_app gateway
    remote_auto_assert_state "$owner"
    exit_app=$(remote_auto_exit_name "$owner")
    gateway=$(remote_auto_gateway_name "$owner")

    if [[ -f "$(gateway_cfg_file "$gateway")" ]]; then
        load_gateway_cfg "$gateway"
        [[ "$VIA_APP" == "$exit_app" ]] ||
            die "Refusing to stop gateway '$gateway': it does not use '$exit_app'."
        [[ "${REMOTE_MANAGED_OWNER_ID:-}" == "$owner" ]] ||
            die "Refusing to stop gateway '$gateway': owner marker mismatch."
        gateway_stop "$gateway"
    fi

    if [[ -f "$(cfg_file "$exit_app")" ]]; then
        load_cfg "$exit_app"
        [[ "${REMOTE_MANAGED_OWNER_ID:-}" == "$owner" ]] ||
            die "Refusing to stop exit '$exit_app': owner marker mismatch."
        stop_app "$exit_app"
    fi

    # Deliberately do not disable the units: AUTOSTART remains the recovery
    # policy after either host reboots, while this command stops the current
    # runtime on both machines.
    log "Stopped automatic remote '$owner': $gateway and $exit_app."
}

remote_auto_deauthorize_owner() {
    require_root
    local owner=$1 user=${SUDO_USER:-} home authorized tmp group marker sudoers
    validate_remote_owner_id "$owner"

    # Automatic bootstrap keys are per owner. Remove only the key that created
    # this deployment; other clients using the same remote account remain.
    if [[ -z "$user" || "$user" == root ||
          ! "$user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
       ! id "$user" >/dev/null 2>&1; then
        warn "Could not identify the remote SSH account; its automatic key was not removed."
        return 0
    fi
    home=$(remote_auto_user_home "$user")
    [[ -n "$home" ]] || {
        warn "Could not determine the home directory for '$user'; its automatic key was not removed."
        return 0
    }
    authorized="$home/.ssh/authorized_keys"
    marker="nns-app-auto-$owner"
    if [[ -f "$authorized" ]]; then
        tmp=$(mktemp)
        awk -v marker="$marker" \
            'index($0, marker) == 0 { print }' \
            "$authorized" >"$tmp"
        group=$(id -gn "$user")
        install -o "$user" -g "$group" -m 0600 "$tmp" "$authorized"
        rm -f "$tmp"
    fi

    # The sudoers rule is shared by all automatic keys for this remote account.
    # Remove it only after the last such key has gone.
    sudoers="/etc/sudoers.d/nns-app-remote-auto-${user}"
    if [[ ! -f "$authorized" ]] ||
       ! grep -Fq 'nns-app-auto-' "$authorized"; then
        rm -f -- "$sudoers"
    fi
}

remote_auto_cleanup_internal() {
    require_root
    local owner=$1 exit_app gateway client state_file marker
    validate_remote_owner_id "$owner"
    exit_app=$(remote_auto_exit_name "$owner")
    gateway=$(remote_auto_gateway_name "$owner")
    client=$(remote_auto_client_name "$owner")
    state_file=$(remote_auto_state_file "$owner")

    # A completed deployment has a state file. Older failed deployments can
    # lack it, so deterministic names are still reconciled, but every existing
    # object must match the expected owner relationship before removal.
    if [[ -f "$state_file" ]]; then
        remote_auto_assert_state "$owner"
    else
        warn "Automatic-remote state '$state_file' is absent; cleaning deterministic partial objects."
    fi

    if [[ -f "$(gateway_cfg_file "$gateway")" ]]; then
        load_gateway_cfg "$gateway"
        [[ "$VIA_APP" == "$exit_app" ]] ||
            die "Refusing to remove gateway '$gateway': it does not use '$exit_app'."
        [[ -z "${REMOTE_MANAGED_OWNER_ID:-}" ||
           "$REMOTE_MANAGED_OWNER_ID" == "$owner" ]] ||
            die "Refusing to remove gateway '$gateway': owner marker mismatch."
        gateway_remove "$gateway"
    else
        systemctl disable --now \
            "nns-gateway@${gateway}.service" \
            "nns-gateway-crl-refresh@${gateway}.timer" \
            >/dev/null 2>&1 || true
        rm -rf -- \
            "$(gateway_dropin_dir "$gateway")" \
            "$(gateway_dir "$gateway")" \
            "$(gateway_runtime_dir "$gateway")"
    fi

    if [[ -f "$(cfg_file "$exit_app")" ]]; then
        load_cfg "$exit_app"
        marker=${REMOTE_MANAGED_OWNER_ID:-}
        [[ -z "$marker" || "$marker" == "$owner" ]] ||
            die "Refusing to remove exit '$exit_app': owner marker mismatch."
        remove_app "$exit_app" local-only
    else
        systemctl disable --now \
            "nns-watchdog@${exit_app}.timer" \
            "nns-online@${exit_app}.service" \
            "nns-openvpn@${exit_app}.service" \
            "nns-netns@${exit_app}.service" \
            >/dev/null 2>&1 || true
    fi

    rm -f -- "$state_file"
    remote_auto_deauthorize_owner "$owner"
    systemctl daemon-reload
    log "Removed automatic remote '$owner': $gateway/$client and $exit_app."
}

remote_auto_dispatch() {
    require_root
    local action=${1:-}
    shift || true
    case "$action" in
        version)
            [[ $# -eq 0 ]] || die "_remote-auto version takes no arguments."
            printf 'nns-app-remote-auto %s\n' "$VERSION"
            ;;
        deploy)
            [[ $# -eq 4 ]] ||
                die "_remote-auto deploy requires owner, SSH host, SSH port and profile name."
            remote_auto_deploy_internal "$@"
            ;;
        export)
            [[ $# -eq 1 ]] || die "_remote-auto export requires owner."
            remote_auto_export_internal "$1"
            ;;
        rotate)
            [[ $# -eq 1 ]] || die "_remote-auto rotate requires owner."
            remote_auto_rotate_internal "$1"
            ;;
        status)
            [[ $# -eq 1 ]] || die "_remote-auto status requires owner."
            remote_auto_status_internal "$1"
            ;;
        start)
            [[ $# -eq 1 ]] || die "_remote-auto start requires owner."
            remote_auto_start_internal "$1"
            ;;
        stop)
            [[ $# -eq 1 ]] || die "_remote-auto stop requires owner."
            remote_auto_stop_internal "$1"
            ;;
        cleanup)
            [[ $# -eq 1 ]] || die "_remote-auto cleanup requires owner."
            remote_auto_cleanup_internal "$1"
            ;;
        *) die "Unsupported automatic-remote operation '$action'." ;;
    esac
}

remote_auto_owner_id() {
    local app=$1 target=$2 machine_id
    machine_id=$(cat /etc/machine-id 2>/dev/null || hostname)
    printf '%s\0%s\0%s' "$machine_id" "$app" "$target" |
        sha256sum | cut -c1-16
}

remote_auto_alias() {
    local app=$1 owner=$2 stem
    stem=$(printf 'auto-%s' "$app" | cut -c1-23)
    printf '%s-%s\n' "$stem" "${owner:0:8}"
}

remote_auto_user_home() {
    getent passwd "$1" | awk -F: 'NR==1 {print $6}'
}

remote_auto_user_exec() {
    local user=$1; shift
    local home
    local -a user_env
    home=$(remote_auto_user_home "$user")
    [[ -n "$home" && -d "$home" ]] || die "Cannot determine home directory for '$user'."
    user_env=(HOME="$home" USER="$user" LOGNAME="$user")
    if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK:-}" ]]; then
        user_env+=(SSH_AUTH_SOCK="$SSH_AUTH_SOCK")
    fi
    runuser -u "$user" -- env "${user_env[@]}" "$@"
}

remote_auto_resolve_ssh() {
    local user=$1 target=$2 requested_port=${3:-22} cfg host ssh_user port
    validate_ssh_target "$target"
    [[ "$requested_port" =~ ^[1-9][0-9]{0,4}$ && "$requested_port" -le 65535 ]] ||
        die "Invalid SSH port '$requested_port'."
    cfg=$(remote_auto_user_exec "$user" ssh -G -p "$requested_port" "$target" 2>/dev/null) ||
        die "Cannot resolve SSH configuration for '$target'."
    host=$(awk '$1=="hostname" {print $2; exit}' <<<"$cfg")
    ssh_user=$(awk '$1=="user" {print $2; exit}' <<<"$cfg")
    port=$(awk '$1=="port" {print $2; exit}' <<<"$cfg")
    [[ -n "$host" && -n "$ssh_user" && "$port" =~ ^[1-9][0-9]{0,4}$ ]] ||
        die "SSH configuration for '$target' is incomplete."
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        host="[$host]"
    fi
    validate_ssh_target "$ssh_user@$host"
    printf '%s|%s|%s\n' "$ssh_user@$host" "$port" "${host#[}"
}

remote_auto_bootstrap() {
    local app=$1 target=$2 port=$3 alias=$4 owner=$5
    local user dir key pub pub_copy remote_tmp remote_pub control_dir control command
    load_cfg "$app"
    user=$APP_USER
    dir=$(remote_dir "$alias")
    key="$dir/id_ed25519"
    pub="$key.pub"
    install -d -o root -g root -m 0700 "$dir"
    if [[ ! -f "$key" ]]; then
        ssh-keygen -q -t ed25519 -N '' -C "nns-app-auto-$owner" -f "$key"
        chown root:root "$key" "$pub"
        chmod 0600 "$key"
        chmod 0644 "$pub"
    fi

    remote_tmp="/tmp/nns-app-auto-${owner}.sh"
    remote_pub="/tmp/nns-app-auto-${owner}.pub"
    pub_copy=$(mktemp)
    install -m 0644 "$pub" "$pub_copy"
    control_dir=$(mktemp -d "/tmp/nns-app-ssh-${owner}.XXXXXX")
    chown "$user":"$(id -gn "$user")" "$control_dir"
    chmod 0700 "$control_dir"
    control="$control_dir/control"

    remote_auto_bootstrap_cleanup() {
        remote_auto_user_exec "$user" ssh -O exit \
            -o "ControlPath=$control" -p "$port" "$target" \
            >/dev/null 2>&1 || true
        rm -f "$pub_copy"
        rm -rf "$control_dir"
    }

    log "Bootstrapping nns-app on '$target' (SSH and remote sudo may each prompt once)..."
    if ! remote_auto_user_exec "$user" ssh -N -f \
        -o ControlMaster=yes -o ControlPersist=120 \
        -o "ControlPath=$control" \
        -o StrictHostKeyChecking=accept-new \
        -p "$port" "$target"; then
        remote_auto_bootstrap_cleanup
        die "Cannot establish the bootstrap SSH connection to '$target'."
    fi

    if ! remote_auto_user_exec "$user" scp \
        -q -o "ControlPath=$control" -P "$port" \
        "$ENGINE_PATH" "$target:$remote_tmp"; then
        remote_auto_bootstrap_cleanup
        die "Cannot upload nns-app to '$target'."
    fi
    if ! remote_auto_user_exec "$user" scp \
        -q -o "ControlPath=$control" -P "$port" \
        "$pub_copy" "$target:$remote_pub"; then
        remote_auto_bootstrap_cleanup
        die "Cannot upload the automatic-remote public key to '$target'."
    fi

    printf -v command '%s' "set -e; umask 077; mkdir -p \"\$HOME/.ssh\"; touch \"\$HOME/.ssh/authorized_keys\"; chmod 700 \"\$HOME/.ssh\"; chmod 600 \"\$HOME/.ssh/authorized_keys\"; key=\$(awk '{print \$1\" \"\$2}' '$remote_pub'); grep -Fq \"\$key\" \"\$HOME/.ssh/authorized_keys\" || printf '\\nrestrict,port-forwarding %s nns-app-auto-$owner\\n' \"\$key\" >>\"\$HOME/.ssh/authorized_keys\"; sudo /bin/bash '$remote_tmp' install; sudo /bin/bash '$remote_tmp' _remote-auto-authorize \"\$(id -un)\"; rm -f '$remote_tmp' '$remote_pub'"
    if ! remote_auto_user_exec "$user" ssh -tt \
        -o "ControlPath=$control" -p "$port" "$target" "$command"; then
        remote_auto_user_exec "$user" ssh \
            -o "ControlPath=$control" -p "$port" "$target" \
            "rm -f '$remote_tmp' '$remote_pub'" >/dev/null 2>&1 || true
        remote_auto_bootstrap_cleanup
        die "Remote nns-app bootstrap failed on '$target'."
    fi
    remote_auto_bootstrap_cleanup
}

remote_auto_register() {
    local alias=$1 target=$2 port=$3 identity=$4 dir known cfg tmp fingerprint output
    validate_remote_alias "$alias"
    validate_ssh_target "$target"
    dir=$(remote_dir "$alias")
    known=$(remote_known_hosts "$alias")
    cfg=$(remote_cfg_file "$alias")
    install -d -o root -g root -m 0700 "$dir"
    touch "$known"
    chown root:root "$known"
    chmod 0600 "$known"
    output=$(ssh -F /dev/null -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$known" \
        -o IdentitiesOnly=yes -i "$identity" -p "$port" "$target" \
        "sudo -n $ENGINE_PATH _remote-auto version") ||
        die "The dedicated automatic-remote SSH key or restricted sudo helper is not usable on '$target'."
    grep -Fq "nns-app-remote-auto $VERSION" <<<"$output" ||
        die "Remote '$target' did not activate nns-app automatic-remote $VERSION."
    fingerprint=$(ssh-keygen -lf "$known" -E sha256 2>/dev/null | awk 'NR==1 {print $2}')
    [[ -n "$fingerprint" ]] || die "Could not pin the SSH host key for '$target'."
    tmp=$(mktemp)
    {
        printf 'SSH_TARGET=%q\n' "$target"
        printf 'SSH_PORT=%q\n' "$port"
        printf 'SSH_IDENTITY=%q\n' "$identity"
        printf 'SSH_HOST_FINGERPRINT=%q\n' "$fingerprint"
    } >"$tmp"
    install -o root -g root -m 0600 "$tmp" "$cfg"
    rm -f "$tmp"
}


remote_auto_is_current() {
    local alias=$1 target=$2 port=$3 output
    [[ -f "$(remote_cfg_file "$alias")" &&
       -f "$(remote_dir "$alias")/id_ed25519" &&
       -f "$(remote_known_hosts "$alias")" ]] || return 1
    load_remote_cfg "$alias" || return 1
    [[ "$SSH_TARGET" == "$target" && "$SSH_PORT" == "$port" ]] || return 1
    output=$(remote_auto_command "$alias" version 2>/dev/null) || return 1
    grep -Fq "nns-app-remote-auto $VERSION" <<<"$output"
}

remote_auto_install() {
    require_root
    local app=$1 requested_target=$2 requested_port=${3:-22}
    local target port host owner alias exit_app gateway client resolved
    validate_app_name "$app"
    load_cfg "$app"
    if [[ "${REMOTE_MODE:-}" != auto &&
          ( -n "${VPN_TYPE:-}" || -n "${DEFAULT_PROFILE:-}" ) ]]; then
        die "App '$app' already has a local VPN profile. Use a new app name for via --remote."
    fi
    resolved=$(remote_auto_resolve_ssh "$APP_USER" "$requested_target" "$requested_port")
    IFS='|' read -r target port host <<<"$resolved"
    host=${host%]}
    host=${host#[}
    [[ "$host" != *:* ]] ||
        die "Automatic remote mode currently requires an SSH host with an IPv4 address or DNS name."
    owner=$(remote_auto_owner_id "$app" "$target:$port")
    alias=$(remote_auto_alias "$app" "$owner")
    exit_app=$(remote_auto_exit_name "$owner")
    gateway=$(remote_auto_gateway_name "$owner")
    client=$(remote_auto_client_name "$owner")

    if [[ "${REMOTE_MODE:-}" == auto && -n "${TRANSPORT_SSH_TARGET:-}" &&
          "$TRANSPORT_SSH_TARGET" != "$target" ]]; then
        die "App '$app' is already bound to remote '$TRANSPORT_SSH_TARGET'. Use a new app name or remove it first."
    fi

    if remote_auto_is_current "$alias" "$target" "$port"; then
        log "Remote '$target' already runs automatic-remote $VERSION; bootstrap is current."
    else
        remote_auto_bootstrap "$app" "$requested_target" "$port" "$alias" "$owner"
        remote_auto_register "$alias" "$target" "$port" "$(remote_dir "$alias")/id_ed25519"
    fi

    cfg_set "$app" REMOTE_MODE auto
    cfg_set "$app" REMOTE_ALIAS "$alias"
    cfg_set "$app" REMOTE_OWNER_ID "$owner"
    cfg_set "$app" REMOTE_CLEANED off
    cfg_set "$app" REMOTE_EXIT_APP "$exit_app"
    cfg_set "$app" REMOTE_GATEWAY "$gateway"
    cfg_set "$app" REMOTE_CLIENT "$client"
    cfg_set "$app" TRANSPORT_SSH_TARGET "$target"
    cfg_set "$app" TRANSPORT_SSH_IDENTITY "$(remote_dir "$alias")/id_ed25519"
    cfg_set "$app" TRANSPORT_SSH_KNOWN_HOSTS "$(remote_known_hosts "$alias")"
    # Automatic remote environments are intended to reconnect after either
    # host reboots. The ordinary local/manual install default remains off.
    cfg_set "$app" AUTOSTART on

    log "Configured '$app' for automatic remote execution through '$target'."
    load_cfg "$app"
    if [[ -n "${VPN_TYPE:-}" && -n "${DEFAULT_PROFILE:-}" ]]; then
        start_app "$app" off __default__
        log "Automatic remote '$app' is started and enabled for boot."
    else
        log "State: pending provider profile; autostart will activate after deployment."
        log "Next: nns-app add $app /path/to/self-contained-profile.ovpn"
    fi
}

remote_auto_command_payload() {
    local command
    command=$(shell_join_quoted "$ENGINE_PATH" _remote-auto "$@")
    printf 'exec sudo -n %s' "$command"
}

remote_auto_command() {
    local alias=$1 payload; shift
    remote_ssh_args "$alias"
    payload=$(remote_auto_command_payload "$@")
    "${REMOTE_SSH_ARGS[@]}" "$payload"
}

remote_auto_lifecycle_app() {
    require_root
    local action=$1 app=$2 alias owner
    [[ "$action" == start || "$action" == stop ]] ||
        die "Unsupported automatic-remote lifecycle action '$action'."
    validate_app_name "$app"
    load_cfg "$app"
    [[ "${REMOTE_MODE:-}" == auto ]] || return 0

    alias=${REMOTE_ALIAS:-}
    owner=${REMOTE_OWNER_ID:-}
    [[ -n "$alias" && -n "$owner" ]] ||
        die "Automatic remote app '$app' has incomplete lifecycle metadata."
    [[ -f "$(remote_cfg_file "$alias")" ]] ||
        die "Automatic remote app '$app' has no SSH registration for '$alias'."

    case "$action" in
        start) log "Starting automatic remote resources for '$app'..." ;;
        stop)  log "Stopping automatic remote resources for '$app'..." ;;
    esac
    if ! remote_auto_command "$alias" "$action" "$owner"; then
        return 1
    fi
}

remote_auto_start_app() {
    local app=$1
    if ! remote_auto_lifecycle_app start "$app"; then
        die "Could not start the automatic remote resources for '$app'. Rerun 'nns-app install $app via --remote user@remote-host' to upgrade or repair the remote helper."
    fi
}

stop_app_cli() {
    require_root
    local app=$1 mode=${2:-remote} remote_mode alias owner deployed=0
    validate_app_name "$app"
    [[ "$mode" == remote || "$mode" == local-only ]] ||
        die "Unsupported stop mode '$mode'."
    assert_destructive_command_from_host "stop '$app'"
    load_cfg "$app"
    remote_mode=${REMOTE_MODE:-}
    alias=${REMOTE_ALIAS:-}
    owner=${REMOTE_OWNER_ID:-}
    if [[ "$remote_mode" == auto && -n "${DEFAULT_PROFILE:-}" &&
          -n "${VPN_TYPE:-}" && -n "$alias" && -n "$owner" ]]; then
        deployed=1
    fi

    # Stop the local client first so it cannot reconnect-loop while the remote
    # gateway and provider exit are being shut down.
    stop_app "$app"

    if (( deployed )) && [[ "$mode" != local-only ]]; then
        if ! remote_auto_lifecycle_app stop "$app"; then
            warn "Local app '$app' was stopped, but its automatic remote gateway/exit could not be stopped. Retry when the remote host is reachable, or use --local-only to acknowledge a local-only stop."
            return 1
        fi
        log "Stopped '$app' locally and on its automatic remote host."
    elif (( deployed )); then
        warn "Stopped '$app' locally only; its automatic remote gateway and provider exit remain running."
    fi
}

remote_auto_cleanup_app() {
    require_root
    local app=$1 alias owner target port
    validate_app_name "$app"
    load_cfg "$app"
    [[ "${REMOTE_MODE:-}" == auto ]] || return 0
    bool_on "${REMOTE_CLEANED:-off}" && return 0
    alias=${REMOTE_ALIAS:-}
    owner=${REMOTE_OWNER_ID:-}
    [[ -n "$alias" && -n "$owner" ]] ||
        die "Automatic remote app '$app' has incomplete cleanup metadata."
    [[ -f "$(remote_cfg_file "$alias")" ]] ||
        die "Automatic remote app '$app' has no SSH registration for '$alias'."

    load_remote_cfg "$alias"
    target=$SSH_TARGET
    port=$SSH_PORT
    if ! remote_auto_is_current "$alias" "$target" "$port"; then
        log "Upgrading automatic-remote support on '$target' before cleanup..."
        remote_auto_bootstrap "$app" "$target" "$port" "$alias" "$owner"
        remote_auto_register "$alias" "$target" "$port"             "$(remote_dir "$alias")/id_ed25519"
    fi

    log "Removing automatic remote resources owned by '$app'..."
    if ! remote_auto_command "$alias" cleanup "$owner"; then
        die "Could not clean the automatic remote resources for '$app'. Local configuration was preserved. Retry when the remote host is reachable, or use --local-only to intentionally leave the remote objects."
    fi
    cfg_set "$app" REMOTE_CLEANED on
    log "Automatic remote resources for '$app' were removed."
}

remote_auto_add_profile() {
    require_root
    local app=$1 src=$2 alias owner gateway client temp profile_name host
    validate_app_name "$app"
    load_cfg "$app"
    [[ "${REMOTE_MODE:-}" == auto && -n "$REMOTE_ALIAS" && -n "$REMOTE_OWNER_ID" ]] ||
        die "App '$app' is not configured for automatic remote mode."
    src=$(readlink -f "$src")
    local type
    type=$(profile_type_from_file "$src" 2>/dev/null || true)
    [[ -n "$type" ]] || die "Cannot identify '$src' as an OpenVPN or WireGuard profile."
    case "$type" in
        openvpn) validate_ovpn "$src" ;;
        wireguard) validate_wireguard "$src" ;;
    esac
    alias=$REMOTE_ALIAS
    owner=$REMOTE_OWNER_ID
    gateway=$(remote_auto_gateway_name "$owner")
    client=$(remote_auto_client_name "$owner")
    load_remote_cfg "$alias"
    host=${SSH_TARGET#*@}
    host=${host#[}; host=${host%]}
    profile_name=$(profile_name_from_path "$src" "$type")

    log "Deploying '$profile_name' to '$SSH_TARGET' and creating its private gateway..."
    remote_auto_command "$alias" deploy "$owner" "$host" "$SSH_PORT" "$profile_name" <"$src"
    temp=$(mktemp --suffix=.nnslink)
    remote_auto_command "$alias" export "$owner" >"$temp"
    [[ -s "$temp" ]] || die "Automatic remote returned an empty .nnslink bundle."
    remote_import_bundle "$alias" "$gateway" "$client" "$app" "$temp"
    rm -f "$temp"

    load_remote_cfg "$alias"
    cfg_set "$app" REMOTE_MODE auto
    cfg_set "$app" REMOTE_OWNER_ID "$owner"
    cfg_set "$app" REMOTE_CLEANED off
    cfg_set "$app" REMOTE_EXIT_APP "$(remote_auto_exit_name "$owner")"
    cfg_set "$app" READY_TIMEOUT 30
    cfg_set "$app" TRANSPORT_SSH_TARGET "$SSH_TARGET"
    cfg_set "$app" TRANSPORT_SSH_IDENTITY "$SSH_IDENTITY"
    cfg_set "$app" TRANSPORT_SSH_KNOWN_HOSTS "$(remote_known_hosts "$alias")"
    cfg_set "$app" AUTOSTART on

    # Complete the simple API by bringing the local side online immediately.
    # start_app enables the namespace, backend, online check, and watchdog
    # units because AUTOSTART is on; later boots recreate the full SSH/OpenVPN
    # path without requiring a prior run command.
    start_app "$app" off __default__
    log "Automatic remote '$app' is ready, started, and enabled for boot."
    log "Run commands with: nns-app run $app <command>"
}
