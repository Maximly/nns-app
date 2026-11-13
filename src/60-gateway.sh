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

validate_transport_server_name() {
    local name=${1:-}
    (( ${#name} <= 253 )) &&
        [[ "$name" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]] ||
        die "Invalid transport server name '$name'. Use a valid DNS hostname."
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
    GATEWAY_BACKEND=${GATEWAY_BACKEND:-openvpn}
    case "$GATEWAY_BACKEND" in
        openvpn|amneziawg) ;;
        *) die "Unsupported gateway backend '${GATEWAY_BACKEND:-}'." ;;
    esac
    TRANSPORT=${TRANSPORT:-direct}
    OPENVPN_COMPAT=${OPENVPN_COMPAT:-modern}
    case "$OPENVPN_COMPAT" in
        modern|embedded) ;;
        *) die "Unsupported OpenVPN compatibility mode '$OPENVPN_COMPAT'." ;;
    esac
    if [[ "${GATEWAY_BACKEND:-openvpn}" == amneziawg ]]; then
        [[ "$LISTEN_PROTO" == udp ]] || die "AmneziaWG servers require UDP."
        AWG_JC=${AWG_JC:-5}
        AWG_JMIN=${AWG_JMIN:-50}
        AWG_JMAX=${AWG_JMAX:-200}
        AWG_S1=${AWG_S1:-88}
        AWG_S2=${AWG_S2:-47}
        AWG_S3=${AWG_S3:-29}
        AWG_S4=${AWG_S4:-17}
    fi
    OPENVPN_LISTEN_PROTO=${OPENVPN_LISTEN_PROTO:-$LISTEN_PROTO}
    OPENVPN_LISTEN_PORT=${OPENVPN_LISTEN_PORT:-$LISTEN_PORT}
    CLIENT_TO_CLIENT=${CLIENT_TO_CLIENT:-off}
    validate_client_to_client "$CLIENT_TO_CLIENT"
    TRANSPORT_SERVER_NAME=${TRANSPORT_SERVER_NAME:-$PUBLIC_HOST}
    case "$TRANSPORT" in
        direct|stunnel|cloak|ssh) ;;
        *) die "Unsupported gateway transport '$TRANSPORT'." ;;
    esac
    validate_transport_server_name "$TRANSPORT_SERVER_NAME"
    if [[ "$TRANSPORT" == cloak && "$TRANSPORT_SERVER_NAME" == "$PUBLIC_HOST" ]]; then
        die "Cloak's --server-name must differ from the gateway public host to avoid a redirection loop."
    fi
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

validate_client_to_client() {
    case "${1:-}" in
        on|off) ;;
        *) die "Invalid client-to-client setting '${1:-}'; expected on or off." ;;
    esac
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

gateway_cfg_set() {
    local gateway=$1 key=$2 value=$3 file tmp quoted line found=0
    file=$(gateway_cfg_file "$gateway")
    [[ -f "$file" ]] || die "Gateway '$gateway' is not configured."
    tmp=$(mktemp "${file}.XXXXXX")
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


gateway_ufw_state_file() {
    printf '%s/.host-firewall-ufw\n' "$(gateway_dir "$1")"
}

gateway_firewalld_state_file() {
    printf '%s/.host-firewall-firewalld\n' "$(gateway_dir "$1")"
}

gateway_public_firewall_comment() {
    printf 'nns-app:gateway:%s:public-input\n' "$1"
}

ufw_is_active() {
    command -v ufw >/dev/null 2>&1 || return 1
    LC_ALL=C ufw status 2>/dev/null | grep -Fxq 'Status: active'
}

# Avoid claiming/removing a broad UFW rule that the administrator already
# owned before nns-app started the gateway.  This catches the canonical short
# form and the equivalent unrestricted long form.  More specific source or
# interface rules do not count because they may not make the public endpoint
# reachable from an arbitrary exported client.
ufw_public_allow_exists() {
    local port=$1 proto=$2 spec="${1}/${2}"
    command -v ufw >/dev/null 2>&1 || return 1
    LC_ALL=C ufw show added 2>/dev/null | awk \
        -v spec="$spec" -v port="$port" -v proto="$proto" '
        $1 != "ufw" || $2 != "allow" { next }
        {
            end=NF
            for (i=3; i<=NF; i++) {
                if ($i == "comment") { end=i-1; break }
            }
            start=3
            if ($start == "in") start++
            if (start <= end && $start == spec) { found=1; next }

            saw_on=0; p=""; src=""; dst=""; dport=""
            for (i=start; i<=end; i++) {
                if ($i == "on") saw_on=1
                else if ($i == "proto" && i < end) p=$(i+1)
                else if ($i == "from" && i < end) src=$(i+1)
                else if ($i == "to" && i < end) dst=$(i+1)
                else if ($i == "port" && i < end) dport=$(i+1)
            }
            if (!saw_on && p == proto && src == "any" && dst == "any" && dport == port)
                found=1
        }
        END { exit(found ? 0 : 1) }
    '
}

ufw_managed_public_rule_exists() {
    local gateway=$1 port=$2 proto=$3 marker line
    marker=$(gateway_public_firewall_comment "$gateway")
    command -v ufw >/dev/null 2>&1 || return 1
    while IFS= read -r line; do
        [[ "$line" == *"comment '$marker'"* ]] || continue
        [[ "$line" == "ufw allow $port/$proto "* ||
           "$line" == "ufw allow in $port/$proto "* ||
           "$line" == "ufw allow $port/$proto" ||
           "$line" == "ufw allow in $port/$proto" ]] && return 0
    done < <(LC_ALL=C ufw show added 2>/dev/null || true)
    return 1
}

gateway_ufw_public_up() {
    local gateway=$1 port=$2 proto=$3 state marker
    ufw_is_active || return 0
    state=$(gateway_ufw_state_file "$gateway")
    marker=$(gateway_public_firewall_comment "$gateway")

    if [[ ! -e "$state" ]] && ufw_public_allow_exists "$port" "$proto"; then
        # Administrator-owned broad access already exists.  Do not alter its
        # comment and, crucially, do not delete it when the gateway goes away.
        return 0
    fi

    if ! ufw_managed_public_rule_exists "$gateway" "$port" "$proto"; then
        ufw allow "$port/$proto" comment "$marker" >/dev/null 2>&1 || return 1
    fi
    if [[ ! -e "$state" ]]; then
        : >"$state" || {
            ufw delete allow "$port/$proto" comment "$marker" >/dev/null 2>&1 || true
            return 1
        }
        chmod 0600 "$state" 2>/dev/null || true
    fi
    return 0
}

gateway_ufw_public_down() {
    local gateway=$1 port=$2 proto=$3 state marker
    state=$(gateway_ufw_state_file "$gateway")
    [[ -e "$state" ]] || return 0
    marker=$(gateway_public_firewall_comment "$gateway")
    command -v ufw >/dev/null 2>&1 || return 1

    if ufw_managed_public_rule_exists "$gateway" "$port" "$proto"; then
        # UFW explicitly supports deleting the original rule including its
        # comment, so this cannot consume an unrelated administrator rule.
        ufw delete allow "$port/$proto" comment "$marker" >/dev/null 2>&1 || return 1
    fi
    ! ufw_managed_public_rule_exists "$gateway" "$port" "$proto" || return 1
    rm -f "$state"
    return 0
}

firewalld_public_zone() {
    local wan zone
    wan=$(detect_wan_iface auto) || return 1
    zone=$(firewall-cmd --get-zone-of-interface="$wan" 2>/dev/null || true)
    if [[ -z "$zone" || "$zone" == 'no zone' ]]; then
        zone=$(firewall-cmd --get-default-zone 2>/dev/null || true)
    fi
    [[ -n "$zone" && "$zone" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    printf '%s\n' "$zone"
}

firewalld_port_query() {
    local scope=$1 zone=$2 port=$3 proto=$4
    local -a cmd=(firewall-cmd)
    [[ "$scope" == permanent ]] && cmd+=(--permanent)
    "${cmd[@]}" --zone="$zone" --query-port="$port/$proto" >/dev/null 2>&1
}

firewalld_port_add() {
    local scope=$1 zone=$2 port=$3 proto=$4
    local -a cmd=(firewall-cmd)
    [[ "$scope" == permanent ]] && cmd+=(--permanent)
    "${cmd[@]}" --zone="$zone" --add-port="$port/$proto" >/dev/null 2>&1
}

firewalld_port_remove() {
    local scope=$1 zone=$2 port=$3 proto=$4
    local -a cmd=(firewall-cmd)
    [[ "$scope" == permanent ]] && cmd+=(--permanent)
    if firewalld_port_query "$scope" "$zone" "$port" "$proto"; then
        "${cmd[@]}" --zone="$zone" --remove-port="$port/$proto" >/dev/null 2>&1
    fi
}

gateway_firewalld_public_up() {
    local gateway=$1 port=$2 proto=$3 state zone old_zone runtime_has=no permanent_has=no
    firewalld_is_active || return 0
    state=$(gateway_firewalld_state_file "$gateway")
    zone=$(firewalld_public_zone) || return 1

    if [[ -s "$state" ]]; then
        old_zone=$(head -n 1 "$state" 2>/dev/null || true)
        [[ "$old_zone" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
        if [[ "$old_zone" != "$zone" ]]; then
            firewalld_port_remove runtime "$old_zone" "$port" "$proto" || return 1
            firewalld_port_remove permanent "$old_zone" "$port" "$proto" || return 1
            printf '%s\n' "$zone" >"$state" || return 1
            chmod 0600 "$state" 2>/dev/null || true
        fi
        firewalld_port_query runtime "$zone" "$port" "$proto" ||
            firewalld_port_add runtime "$zone" "$port" "$proto" || return 1
        firewalld_port_query permanent "$zone" "$port" "$proto" ||
            firewalld_port_add permanent "$zone" "$port" "$proto" || return 1
        return 0
    fi

    firewalld_port_query runtime "$zone" "$port" "$proto" && runtime_has=yes
    firewalld_port_query permanent "$zone" "$port" "$proto" && permanent_has=yes

    # If the administrator already owns either scope, do not claim it.  A
    # permanent rule is mirrored into runtime so the current gateway works;
    # it remains administrator-owned and is intentionally retained later.
    if [[ "$runtime_has" == yes || "$permanent_has" == yes ]]; then
        if [[ "$runtime_has" != yes && "$permanent_has" == yes ]]; then
            firewalld_port_add runtime "$zone" "$port" "$proto" || return 1
        fi
        return 0
    fi

    firewalld_port_add permanent "$zone" "$port" "$proto" || return 1
    if ! firewalld_port_add runtime "$zone" "$port" "$proto"; then
        firewalld_port_remove permanent "$zone" "$port" "$proto" || true
        return 1
    fi
    printf '%s\n' "$zone" >"$state" || {
        firewalld_port_remove runtime "$zone" "$port" "$proto" || true
        firewalld_port_remove permanent "$zone" "$port" "$proto" || true
        return 1
    }
    chmod 0600 "$state" 2>/dev/null || true
    return 0
}

gateway_firewalld_public_down() {
    local gateway=$1 port=$2 proto=$3 state zone
    state=$(gateway_firewalld_state_file "$gateway")
    [[ -s "$state" ]] || return 0
    zone=$(head -n 1 "$state" 2>/dev/null || true)
    [[ "$zone" =~ ^[A-Za-z0-9_-]+$ ]] || return 1

    if firewalld_is_active; then
        firewalld_port_remove runtime "$zone" "$port" "$proto" || return 1
        firewalld_port_remove permanent "$zone" "$port" "$proto" || return 1
        ! firewalld_port_query runtime "$zone" "$port" "$proto" || return 1
        ! firewalld_port_query permanent "$zone" "$port" "$proto" || return 1
    elif command -v firewall-offline-cmd >/dev/null 2>&1; then
        firewall-offline-cmd --zone="$zone" --remove-port="$port/$proto" \
            >/dev/null 2>&1 || return 1
    else
        return 1
    fi
    rm -f "$state"
    return 0
}

gateway_iptables_public_up() {
    local gateway=$1 port=$2 proto=$3 comment
    comment=$(gateway_public_firewall_comment "$gateway")
    iptables_add_once filter INPUT -p "$proto" --dport "$port" \
        -m comment --comment "$comment" -j ACCEPT
}

gateway_iptables_public_down() {
    local gateway=$1 port=$2 proto=$3 comment
    comment=$(gateway_public_firewall_comment "$gateway")
    command -v iptables >/dev/null 2>&1 || return 0
    iptables_delete_all filter INPUT -p "$proto" --dport "$port" \
        -m comment --comment "$comment" -j ACCEPT
}

gateway_public_firewall_up() {
    local gateway=$1 managed=no
    [[ "${TRANSPORT:-direct}" != ssh ]] || return 0

    if ufw_is_active; then
        gateway_ufw_public_up "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO" || return 1
        managed=yes
    fi
    if firewalld_is_active; then
        gateway_firewalld_public_up "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO" || {
            gateway_ufw_public_down "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO" || true
            return 1
        }
        managed=yes
    fi
    if [[ "$managed" == no ]]; then
        gateway_iptables_public_up "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO" || return 1
    fi
    return 0
}

gateway_public_firewall_down() {
    local gateway=$1 rc=0
    [[ "${TRANSPORT:-direct}" != ssh ]] || return 0

    gateway_ufw_public_down "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO" || rc=1
    gateway_firewalld_public_down "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO" || rc=1
    gateway_iptables_public_down "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO" || rc=1
    return "$rc"
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


# Host OpenVPN servers bind on wildcard IPv4. Reject both reserved managed
# listeners (including stopped units) and active, unmanaged host sockets.
# Prints a diagnostic and returns success if occupied.
server_listener_conflict() {
    local proto=$1 port=$2 self=${3:-} self_active=${4:-off}
    local dir other transport cfg_proto cfg_port backend_proto backend_port
    local matched_socket=off
    shopt -s nullglob
    for dir in "$GATEWAY_BASE_DIR"/*; do
        [[ -f "$dir/gateway.cfg" ]] || continue
        other=${dir##*/}
        [[ "$other" != "$self" ]] || continue
        transport=$(gateway_cfg_value "$other" TRANSPORT 2>/dev/null || true)
        cfg_proto=$(gateway_cfg_value "$other" LISTEN_PROTO 2>/dev/null || true)
        cfg_port=$(gateway_cfg_value "$other" LISTEN_PORT 2>/dev/null || true)
        backend_proto=$(gateway_cfg_value "$other" OPENVPN_LISTEN_PROTO 2>/dev/null || true)
        backend_port=$(gateway_cfg_value "$other" OPENVPN_LISTEN_PORT 2>/dev/null || true)
        # The public listener is on this host except for SSH tunneling.
        if [[ "$transport" != ssh && "$cfg_proto" == "$proto" && "$cfg_port" == "$port" ]]; then
            printf 'managed gateway %s reserves %s:%s' "$other" "$proto" "$port"
            return 0
        fi
        if [[ "${backend_proto:-$cfg_proto}" == "$proto" &&
              "${backend_port:-$cfg_port}" == "$port" ]]; then
            printf 'managed gateway %s reserves OpenVPN backend %s:%s' "$other" "$proto" "$port"
            return 0
        fi
    done
    # ss is shipped by iproute2. A missing/broken ss must not silently
    # let the installer accept an unknown listener state.
    command -v ss >/dev/null 2>&1 || die "Cannot verify OpenVPN listener availability: 'ss' is missing."
    local ss_out
    if [[ "$proto" == udp ]]; then
        ss_out=$(ss -H -lun) || die "Cannot inspect UDP listeners with ss."
    else
        ss_out=$(ss -H -ltn) || die "Cannot inspect TCP listeners with ss."
    fi
    if awk -v port="$port" '$4 ~ (":" port "$") {found=1} END {exit !found}' <<<"$ss_out"; then
        matched_socket=on
    fi
    # A running instance is expected to own its existing port; reinstallation
    # of the same listener does not constitute a collision.
    if [[ "$matched_socket" == on && "$self_active" != on ]]; then
        printf 'a host process already listens on %s:%s' "$proto" "$port"
        return 0
    fi
    return 1
}

# Use 1194 by default, but allow additional servers without manual conflicts.
server_choose_listener() {
    local self=${1:-} port conflict
    for ((port=1194; port<=1294; port++)); do
        if ! conflict=$(server_listener_conflict udp "$port" "$self"); then
            printf 'udp:%s\n' "$port"
            return 0
        fi
    done
    die 'No available UDP OpenVPN server port in 1194-1294; specify --listen.'
}

# Pick an unused public listener in the host network namespace. Both
# host-exit servers and gateways exiting through another namespace bind on
# the host, so they must share one collision domain.
gateway_choose_listener() {
    local transport=$1 self=${2:-} proto first last port conflict
    case "$transport" in
        direct) proto=udp; first=1194; last=1294 ;;
        cloak|stunnel) proto=tcp; first=443; last=543 ;;
        ssh) die 'SSH transport requires an explicit private listener.' ;;
        *) die "Unsupported gateway transport '$transport'." ;;
    esac
    for ((port=first; port<=last; port++)); do
        if ! conflict=$(server_listener_conflict "$proto" "$port" "$self"); then
            printf '%s:%s\n' "$proto" "$port"
            return 0
        fi
    done
    die "No free $proto listener in $first-$last; specify --listen."
}

gateway_write_openssl_config() {
    local gateway=$1
    local root=${2:-$(gateway_dir "$gateway")} pki output
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

# `openssl crl` has no `-checkend` option (that option belongs to
# `openssl x509`). Parse the CRL's nextUpdate value instead so fresh CRLs are
# accepted and startup refreshes only when the remaining lifetime is short.
gateway_crl_valid_for() {
    local crl=$1 minimum_seconds=${2:-0}
    local next_update next_epoch now_epoch

    [[ "$minimum_seconds" =~ ^[0-9]+$ ]] || return 1
    [[ -s "$crl" ]] || return 1
    next_update=$(openssl crl -in "$crl" -noout -nextupdate 2>/dev/null) ||
        return 1
    [[ "$next_update" == nextUpdate=* ]] || return 1
    next_update=${next_update#nextUpdate=}
    next_epoch=$(LC_ALL=C date -u -d "$next_update" +%s 2>/dev/null) ||
        return 1
    now_epoch=$(date -u +%s) || return 1
    (( next_epoch - now_epoch > minimum_seconds ))
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
    local gateway=$1
    local root=${2:-$(gateway_dir "$gateway")} compat=${3:-modern} pki server_cn
    pki="$root/pki"
    server_cn="nns-gateway-$gateway"
    case "$compat" in modern|embedded) ;; *) return 1 ;; esac

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

    if [[ "$compat" == embedded ]]; then
        # Some embedded OpenVPN clients require tls-auth instead of
        # tls-crypt-v2. Retain the compatible static-key filename.
        openvpn --genkey secret "$pki/tls-crypt.key" || return 1
    else
        openvpn --genkey tls-crypt-v2-server \
            "$pki/tls-crypt-v2-server.key" || return 1
    fi
    gateway_generate_crl_at "$pki" || return 1
    rm -f "$pki/server.csr"

    chown root:root "$pki/ca.crt" "$pki/server.crt" "$pki/crl.pem" ||
        return 1
    chown root:root "$pki/server.key" || return 1
    if [[ "$compat" == embedded ]]; then
        chown root:root "$pki/tls-crypt.key" || return 1
    else
        chown root:root "$pki/tls-crypt-v2-server.key" || return 1
    fi
    chmod 0644 "$pki/ca.crt" "$pki/server.crt" "$pki/crl.pem" ||
        return 1
    chmod 0600 "$pki/server.key" || return 1
    if [[ "$compat" == embedded ]]; then
        chmod 0600 "$pki/tls-crypt.key" || return 1
    else
        chmod 0600 "$pki/tls-crypt-v2-server.key" || return 1
    fi
}

# OpenVPN fixed addresses live on the server, indexed by client certificate CN.
# Dynamic clients use the lower half of the pool and fixed clients the upper
# half. Never put ifconfig-push or the assigned address in exported profiles.
gateway_active_fixed_assignments() {
    local root=$1 file
    for file in "$root"/clients/*/client.cfg; do
        [[ -f "$file" ]] || continue
        (
            CLIENT_NAME='' STATUS='' FIXED_IP=''
            # client.cfg is root-owned and validated by the normal client loader.
            # shellcheck disable=SC1090
            source "$file"
            if [[ "$STATUS" == active && -n "$FIXED_IP" ]]; then
                validate_gateway_client_name "$CLIENT_NAME"
                printf '%s|%s\n' "$CLIENT_NAME" "$FIXED_IP"
            fi
        ) || return 1
    done
}

gateway_fixed_ip_plan() {
    local pool=$1 assignments=${2:-}
    python3 - "$pool" "$assignments" <<'PY_NNS_FIXED_POOL'
import ipaddress
import sys

try:
    net = ipaddress.ip_network(sys.argv[1], strict=True)
    if net.version != 4 or not 24 <= net.prefixlen <= 29:
        raise ValueError('client pool must be IPv4 /24 through /29')
    base = int(net.network_address)
    size = net.num_addresses
    dynamic_first = ipaddress.IPv4Address(base + 2)
    dynamic_last = ipaddress.IPv4Address(base + size // 2 - 1)
    static_first = base + size // 2
    static_last = base + size - 2
    used = set()
    for entry in sys.argv[2].splitlines():
        cn, address = entry.split('|', 1)
        addr = ipaddress.IPv4Address(address)
        if not static_first <= int(addr) <= static_last:
            raise ValueError(f"fixed IP {addr} for '{cn}' is outside the reserved static range")
        if addr in used:
            raise ValueError(f'fixed IP {addr} is assigned to multiple clients')
        used.add(addr)
    print(f'{dynamic_first}|{dynamic_last}|{net.netmask}')
except (ValueError, IndexError) as exc:
    print(f'Invalid OpenVPN fixed address configuration: {exc}', file=sys.stderr)
    sys.exit(1)
PY_NNS_FIXED_POOL
}

gateway_allocate_fixed_ip() {
    local pool=$1 assignments=${2:-}
    python3 - "$pool" "$assignments" <<'PY_NNS_FIXED_ALLOC'
import ipaddress
import sys

net = ipaddress.ip_network(sys.argv[1], strict=True)
base = int(net.network_address)
start = base + net.num_addresses // 2
end = base + net.num_addresses - 2
used = {int(ipaddress.IPv4Address(line.split('|', 1)[1]))
        for line in sys.argv[2].splitlines() if line}
for ip in range(start, end + 1):
    if ip not in used:
        print(ipaddress.IPv4Address(ip))
        break
else:
    print(f'No fixed IP addresses available in {net}', file=sys.stderr)
    sys.exit(1)
PY_NNS_FIXED_ALLOC
}

# A split-tunnel policy is a server-side CCD push override. It does not
# change the exported client profile or the static IP allocation.
gateway_active_split_clients() {
    local root=$1 file
    for file in "$root"/clients/*/client.cfg; do
        [[ -f "$file" ]] || continue
        (
            CLIENT_NAME='' STATUS='' ROUTE_MODE='full'
            # Only read trusted, root-owned managed client metadata.
            local owner mode
            owner=$(stat -c '%u' "$file") || exit 1
            mode=$(stat -c '%a' "$file") || exit 1
            [[ "$owner" == 0 ]] || exit 1
            (( (8#$mode & 0022) == 0 )) || exit 1
            # shellcheck disable=SC1090
            source "$file"
            case "${ROUTE_MODE:-full}" in
                full) ;;
                split)
                    [[ "${STATUS:-}" == active ]] || exit 0
                    validate_gateway_client_name "$CLIENT_NAME"
                    [[ "$(basename "$(dirname "$file")")" == "$CLIENT_NAME" ]] || exit 1
                    printf '%s\n' "$CLIENT_NAME"
                    ;;
                *) exit 1 ;;
            esac
        ) || return 1
    done
}

gateway_sync_fixed_ip_ccd() {
    local root=$1 assignments=${2:-} netmask=$3 split_clients=${4:-}
    local group ccd client addr tmp file
    local -A fixed_ips=() split=() keep=()
    group=$(nns_unprivileged_group)
    ccd="$root/ccd"
    [[ ! -L "$ccd" ]] || { warn "Refusing symlinked CCD directory: $ccd"; return 1; }
    install -d -o root -g "$group" -m 0750 "$ccd" || return 1
    while IFS='|' read -r client addr; do
        [[ -n "$client" ]] || continue
        validate_gateway_client_name "$client"
        fixed_ips[$client]=$addr
        keep[$client]=1
    done <<<"$assignments"
    while IFS= read -r client; do
        [[ -n "$client" ]] || continue
        validate_gateway_client_name "$client"
        split[$client]=1
        keep[$client]=1
    done <<<"$split_clients"
    # Replace complete CCD entries atomically, never leave partial directives.
    for client in "${!keep[@]}"; do
        tmp=$(mktemp "$ccd/.new.XXXXXX") || return 1
        {
            if [[ -n "${fixed_ips[$client]:-}" ]]; then
                printf 'ifconfig-push %s %s\n' "${fixed_ips[$client]}" "$netmask"
            fi
            if [[ -n "${split[$client]:-}" ]]; then
                printf 'push-remove redirect-gateway\n'
                printf 'push-remove "dhcp-option DNS"\n'
            fi
        } >"$tmp" || return 1
        chown "root:$group" "$tmp" || return 1
        chmod 0640 "$tmp" || return 1
        mv -f -- "$tmp" "$ccd/$client" || return 1
    done
    for file in "$ccd"/*; do
        [[ -f "$file" && ! -L "$file" ]] || continue
        client=${file##*/}
        [[ -n "${keep[$client]:-}" ]] || rm -f -- "$file" || return 1
    done
}

gateway_write_server_config() {
    local gateway=$1
    local root=${2:-$(gateway_dir "$gateway")}
    local config output pki proto_option network netmask dns
    local unpriv_user unpriv_group fixed_assignments fixed_pool dynamic_first dynamic_last fixed_netmask split_clients

    if [[ "$root" == "$(gateway_dir "$gateway")" ]]; then
        load_gateway_cfg "$gateway"
    else
        reset_gateway_cfg_vars
        # shellcheck disable=SC1090
        source "$root/gateway.cfg"
    fi

    if [[ "${GATEWAY_BACKEND:-}" == amneziawg ]]; then
        awg_server_write_config "$gateway"
        return $?
    fi
    config="$root/server.conf"
    output="$config"
    if [[ "$root" == "$(gateway_dir "$gateway")" ]]; then
        output=$(mktemp "$root/server.conf.XXXXXX")
    fi
    pki="$root/pki"
    unpriv_user=$(nns_unprivileged_user)
    unpriv_group=$(nns_unprivileged_group)
    [[ "$OPENVPN_LISTEN_PROTO" == tcp ]] &&
        proto_option=tcp-server || proto_option=udp

    IFS='|' read -r network netmask < <(
        python3 - "$CLIENT_POOL" <<'PY_GATEWAY_POOL'
import ipaddress
import sys

net = ipaddress.ip_network(sys.argv[1], strict=True)
print(f'{net.network_address}|{net.netmask}')
PY_GATEWAY_POOL
    )
    fixed_assignments=$(gateway_active_fixed_assignments "$root") || return 1
    split_clients=$(gateway_active_split_clients "$root") || return 1
    fixed_pool=off
    if [[ -n "$fixed_assignments" ]]; then
        local plan
        plan=$(gateway_fixed_ip_plan "$CLIENT_POOL" "$fixed_assignments") || return 1
        IFS='|' read -r dynamic_first dynamic_last fixed_netmask <<<"$plan"
        fixed_pool=on
    fi
    gateway_sync_fixed_ip_ccd "$root" "$fixed_assignments" "$netmask" "$split_clients" || return 1

    {
        printf '# Generated by nns-app; recreate the gateway instead of editing this file.\n'
        printf 'mode server\n'
        printf 'tls-server\n'
        printf 'proto %s\n' "$proto_option"
        printf 'port %s\n' "$OPENVPN_LISTEN_PORT"
        [[ "${TRANSPORT:-direct}" == direct ]] || printf 'local 127.0.0.1\n'
        # The managed interface uses an nns-app-specific name (ngw...), so
        # OpenVPN cannot infer TUN vs TAP from the device prefix.
        printf 'dev-type tun\n'
        printf 'dev %s\n' "$GATEWAY_TUN"
        printf 'topology subnet\n'
        if [[ "$fixed_pool" == on ]]; then
            printf 'server %s %s nopool\n' "$network" "$netmask"
            printf 'ifconfig-pool %s %s %s\n' "$dynamic_first" "$dynamic_last" "$fixed_netmask"
        else
            printf 'server %s %s\n' "$network" "$netmask"
        fi
        if [[ "$fixed_pool" == on || -n "$split_clients" ]]; then
            printf 'client-config-dir %s\n' "$root/ccd"
        fi
        # Force userspace routing for this setting: with OpenVPN DCO enabled,
        # client-to-client is ignored and Linux would need separate tun->tun
        # forwarding rules. Never widen the host firewall for other traffic.
        if [[ "${CLIENT_TO_CLIENT:-off}" == on ]]; then
            printf 'disable-dco\n'
            printf 'client-to-client\n'
        fi
        printf 'ca %s\n' "$pki/ca.crt"
        printf 'cert %s\n' "$pki/server.crt"
        printf 'key %s\n' "$pki/server.key"
        printf 'dh none\n'
        printf 'crl-verify %s\n' "$pki/crl.pem"
        if [[ "$OPENVPN_COMPAT" == embedded ]]; then
            printf 'tls-auth %s 0\n' "$pki/tls-crypt.key"
        else
            printf 'tls-crypt-v2 %s force-cookie\n' \
                "$pki/tls-crypt-v2-server.key"
        fi
        printf 'verify-client-cert require\n'
        printf 'remote-cert-tls client\n'
        printf 'tls-version-min 1.2\n'
        if [[ "$OPENVPN_COMPAT" == embedded ]]; then
            # Keep the public router-facing profile conservative while
            # retaining an explicit server-side fallback for modern daemons.
            printf 'cipher AES-256-GCM\n'
            printf 'data-ciphers AES-256-GCM:AES-128-GCM\n'
            printf 'data-ciphers-fallback AES-256-GCM\n'
        else
            printf 'data-ciphers AES-256-GCM:CHACHA20-POLY1305:AES-128-GCM\n'
            printf 'allow-compression no\n'
        fi
        printf 'auth SHA256\n'
        printf 'keepalive 10 60\n'
        printf 'persist-tun\n'
        printf 'script-security 2\n'
        printf 'up "%s _gateway-tun-up %s"\n' "$ENGINE_PATH" "$gateway"
        printf 'user %s\n' "$unpriv_user"
        printf 'group %s\n' "$unpriv_group"
        printf 'status %s 5\n' "$(gateway_status_file "$gateway")"
        printf 'status-version 3\n'
        printf 'push "redirect-gateway def1 bypass-dhcp"\n'
        for dns in $DNS_SERVERS; do
            printf 'push "dhcp-option DNS %s"\n' "$dns"
        done
        [[ "$LISTEN_PROTO" == udp ]] &&
            printf 'explicit-exit-notify 1\n'
        printf 'verb 3\n'
        # Do not hide handshake diagnostics for constrained/vendor clients.
        # Their UIs frequently expose only a generic "Connecting" state.
        [[ "$OPENVPN_COMPAT" == embedded ]] || printf 'mute 10\n'
    } >"$output" || {
        rm -f "$output"
        return 1
    }

    if [[ "$output" != "$config" ]]; then
        install -o root -g "$unpriv_group" -m 0640 "$output" "$config" || {
            rm -f "$output"
            return 1
        }
        rm -f "$output"
    else
        chown "root:$unpriv_group" "$config" || return 1
        chmod 0640 "$config" || return 1
    fi
}

gateway_validate_staging() {
    local gateway=$1 root=$2 pki="$2/pki" transport compat
    [[ -s "$root/gateway.cfg" && -s "$root/server.conf" ]] || return 1
    [[ -s "$pki/ca.crt" && -s "$pki/server.crt" &&
       -s "$pki/server.key" ]] || return 1
    [[ -s "$pki/crl.pem" ]] || return 1
    compat=$(awk -F= '/^OPENVPN_COMPAT=/{gsub(/^"|"$/, "", $2); print $2; exit}' "$root/gateway.cfg")
    compat=${compat:-modern}
    case "$compat" in modern|embedded) ;; *) return 1 ;; esac
    if [[ "$compat" == embedded ]]; then
        [[ -s "$pki/tls-crypt.key" ]] || return 1
    else
        [[ -s "$pki/tls-crypt-v2-server.key" ]] || return 1
    fi
    openssl verify -CAfile "$pki/ca.crt" \
        "$pki/server.crt" >/dev/null 2>&1 || return 1
    gateway_crl_valid_for "$pki/crl.pem" 1 || return 1
    if [[ "$compat" == embedded ]]; then
        grep -Eq '^tls-auth[[:space:]]+.+[[:space:]]+0$' "$root/server.conf" || return 1
        grep -Eq '^tls-crypt(-v2)?[[:space:]]+' "$root/server.conf" && return 1
    else
        grep -Eq '^tls-crypt-v2[[:space:]]+' "$root/server.conf" || return 1
    fi
    grep -Eq '^up[[:space:]]+' "$root/server.conf" || return 1
    transport=$(awk -F= '/^TRANSPORT=/{gsub(/^"|"$/, "", $2); print $2; exit}' "$root/gateway.cfg")
    case "${transport:-direct}" in
        direct) ;;
        stunnel)
            [[ -s "$root/transport/server.conf" &&
               -s "$root/transport/ca.crt" &&
               -s "$root/transport/server-chain.crt" &&
               -s "$root/transport/server.key" ]] || return 1
            ;;
        cloak)
            [[ -s "$root/transport/server.json" &&
               -s "$root/transport/public.key" &&
               -s "$root/transport/private.key" ]] || return 1
            ;;
        ssh) ;;
        *) return 1 ;;
    esac
}

gateway_ensure_runtime_access() {
    local gateway=$1 root
    root=$(gateway_dir "$gateway")
    [[ -d "$root" ]] || return 1

    # OpenVPN reads private key material while privileged, then drops to the
    # configured unprivileged account. It must still be able to traverse the
    # gateway root to stat/reload the world-readable CRL. mktemp -d creates
    # 0700, so normalize the installed managed gateway root to execute-only
    # traversal for non-root users without allowing directory listings.
    chmod 0711 "$root" || return 1
    [[ ! -d "$root/pki" ]] || chmod 0755 "$root/pki" || return 1
    [[ ! -f "$root/pki/crl.pem" ]] || chmod 0644 "$root/pki/crl.pem" || return 1
}

gateway_create() {
    require_root
    local gateway=$1 via_app=$2 listen=$3 public=$4
    local requested_pool=${5:-}
    local dns_input=${6:-"1.1.1.1 9.9.9.9"}
    local transport=${7:-direct}
    local transport_server_name=${8:-}
    local openvpn_compat=${9:-modern}
    local client_to_client=${10:-off}
    local staging=""

    validate_gateway_name "$gateway"
    validate_app_name "$via_app"
    case "$transport" in direct|stunnel|cloak|ssh) ;; *) die "Unsupported transport '$transport'." ;; esac
    case "$openvpn_compat" in modern|embedded) ;; *) die "Unsupported OpenVPN compatibility mode '$openvpn_compat'." ;; esac
    validate_client_to_client "$client_to_client"
    [[ "$openvpn_compat" == modern || "$transport" == direct ]] ||
        die "Embedded OpenVPN compatibility is supported only with direct transport."
    if [[ "$transport" == cloak ]]; then
        transport_server_name=${transport_server_name:-www.bing.com}
        validate_transport_server_name "$transport_server_name"
    elif [[ -n "$transport_server_name" ]]; then
        die "--server-name is valid only with --transport cloak."
    fi
    [[ ! -f "$(cfg_file "$gateway")" ]] ||
        die "An NNS app named '$gateway' already exists."
    if [[ "$via_app" != host ]]; then
        [[ -f "$(cfg_file "$via_app")" ]] ||
            die "Upstream NNS app '$via_app' is not installed."
    fi
    [[ ! -e "$(gateway_cfg_file "$gateway")" ]] ||
        die "Gateway '$gateway' already exists."

    acquire_lock global
    acquire_lock "gateway-$gateway"

    local listen_proto listen_port public_host public_port
    local openvpn_listen_proto openvpn_listen_port
    local client_pool transit_cidr transit_host_addr transit_ns_addr
    local route_table rule_priority gateway_tun veth_host veth_ns
    local host_fwd host_mangle ns_fwd ns_nat ns_mangle dns_servers

    # Resolve defaults under the creation lock: a concurrent install must
    # not reserve the same listener between selection and configuration.
    if [[ -z "$listen" ]]; then
        listen=$(gateway_choose_listener "$transport" "$gateway")
        log "Selected available gateway listener: $listen"
    fi
    IFS='|' read -r listen_proto listen_port \
        <<<"$(parse_gateway_listen "$listen")"
    if [[ -z "$public" ]]; then
        public_host=$(server_public_host) ||
            die "Cannot detect the server's public IPv4 address; specify --public <host>:<port>."
        public="$public_host:$listen_port"
        log "Detected gateway public endpoint: $public"
    fi
    IFS='|' read -r public_host public_port \
        <<<"$(parse_public_endpoint "$public")"
    # Public listeners bind in the host namespace regardless of which
    # upstream VPN namespace carries the clients' egress traffic.
    # Check under the global creation lock to avoid port reservation races.
    if [[ "$transport" != ssh ]]; then
        local conflict_reason
        if conflict_reason=$(server_listener_conflict "$listen_proto" "$listen_port" "$gateway"); then
            release_lock "gateway-$gateway"
            release_lock global
            die "Cannot create server '$gateway': $conflict_reason. Use --listen $listen_proto:<free-port>."
        fi
    fi
    if [[ "$transport" == cloak ]]; then
        [[ "$transport_server_name" != "$public_host" ]] ||
            die "Cloak --server-name must differ from the gateway public host."
    else
        transport_server_name=$public_host
    fi
    if [[ "$transport" == direct ]]; then
        openvpn_listen_proto=$listen_proto
        openvpn_listen_port=$listen_port
    elif [[ "$transport" == ssh ]]; then
        [[ "$listen_proto" == tcp ]] ||
            die "Transport 'ssh' requires a TCP loopback listener."
        openvpn_listen_proto=tcp
        openvpn_listen_port=$listen_port
    else
        [[ "$listen_proto" == tcp ]] ||
            die "Transport '$transport' requires a TCP public listener."
        openvpn_listen_proto=tcp
        openvpn_listen_port=$(gateway_allocate_backend_port "$gateway")
    fi
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

TRANSPORT="$transport"
LISTEN_PROTO="$listen_proto"
LISTEN_PORT="$listen_port"
PUBLIC_HOST="$public_host"
PUBLIC_PORT="$public_port"
OPENVPN_LISTEN_PROTO="$openvpn_listen_proto"
OPENVPN_LISTEN_PORT="$openvpn_listen_port"
OPENVPN_COMPAT="$openvpn_compat"
TRANSPORT_SERVER_NAME="$transport_server_name"
CLIENT_POOL="$client_pool"
DNS_SERVERS="$dns_servers"
CLIENT_TO_CLIENT="$client_to_client"

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

    local failed_stage=""
    if ! gateway_prepare_transport "$gateway" "$staging" "$transport"; then
        failed_stage="transport preparation"
    elif ! gateway_generate_pki "$gateway" "$staging" "$openvpn_compat"; then
        failed_stage="PKI generation"
    elif ! gateway_write_server_config "$gateway" "$staging"; then
        failed_stage="OpenVPN server configuration"
    elif ! gateway_write_transport_config "$gateway" "$staging"; then
        failed_stage="transport configuration"
    elif ! gateway_validate_staging "$gateway" "$staging"; then
        failed_stage="staging validation"
    fi
    if [[ -n "$failed_stage" ]]; then
        rm -rf "$staging"
        release_lock "gateway-$gateway"
        release_lock global
        die "Failed to create gateway '$gateway' during $failed_stage; staged files were removed."
    fi

    # mktemp -d creates staging with 0700. The final gateway root needs 0711
    # so the privilege-dropped OpenVPN process can traverse to pki/crl.pem.
    chmod 0711 "$staging" || {
        rm -rf "$staging"
        release_lock "gateway-$gateway"
        release_lock global
        die "Failed to set runtime access on gateway '$gateway' staging directory."
    }
    mv "$staging" "$(gateway_dir "$gateway")"
    if ! gateway_ensure_runtime_access "$gateway" ||
       ! gateway_write_openssl_config "$gateway" "$(gateway_dir "$gateway")" ||
       ! gateway_write_server_config "$gateway" "$(gateway_dir "$gateway")" ||
       ! gateway_write_transport_config "$gateway" "$(gateway_dir "$gateway")"; then
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

    log "Created managed OpenVPN gateway '$gateway' with '$transport' transport."
    if [[ "$transport" == ssh ]]; then
        log "SSH endpoint:    $public_host:$public_port/tcp"
        log "Private OpenVPN listener: 127.0.0.1:$openvpn_listen_port/tcp"
    else
        log "Public endpoint: $public_host:$public_port/$listen_proto"
        [[ "$transport" == direct ]] || log "Private OpenVPN listener: 127.0.0.1:$openvpn_listen_port/tcp"
    fi
    log "Client pool:     $client_pool"
    log "Exit:            $via_app"
    if [[ "$transport" != ssh ]]; then
        log "Host firewall:    nns-app opens $listen_port/$listen_proto while the gateway is running and removes its owned rule when stopped/removed."
        warn "External cloud security groups and upstream NAT/router forwarding are not managed by nns-app."
    fi
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

# Stand-alone OpenVPN server: VPN clients exit through the host's IPv4
# default uplink, not a provider VPN namespace. Rules are scoped to the
# managed tunnel, pool and detected egress device. No existing rules flushed.
gateway_host_exit_rules_down() {
    local comment="nns-app:gateway:$GATEWAY_NAME"
    iptables_jump_delete_all filter FORWARD "$HOST_FWD_CHAIN" "$comment:forward"
    iptables_jump_delete_all mangle FORWARD "$HOST_MANGLE_CHAIN" "$comment:mangle"
    iptables_jump_delete_all nat POSTROUTING "$NS_NAT_CHAIN" "$comment:host-nat"
    iptables -w -t filter -F "$HOST_FWD_CHAIN" 2>/dev/null || true
    iptables -w -t filter -X "$HOST_FWD_CHAIN" 2>/dev/null || true
    iptables -w -t mangle -F "$HOST_MANGLE_CHAIN" 2>/dev/null || true
    iptables -w -t mangle -X "$HOST_MANGLE_CHAIN" 2>/dev/null || true
    iptables -w -t nat -F "$NS_NAT_CHAIN" 2>/dev/null || true
    iptables -w -t nat -X "$NS_NAT_CHAIN" 2>/dev/null || true
}

gateway_host_exit_rules_up() {
    local wan=$1 comment="nns-app:gateway:$GATEWAY_NAME"
    [[ "$wan" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]] ||
        die "Invalid host WAN interface '$wan'."
    gateway_host_exit_rules_down

    iptables_chain_ensure filter "$HOST_FWD_CHAIN"
    if [[ "${GATEWAY_BACKEND:-openvpn}" == amneziawg ]]; then
        iptables -w -t filter -A "$HOST_FWD_CHAIN" \
            -i "$GATEWAY_TUN" -o "$GATEWAY_TUN" -s "$CLIENT_POOL" -d "$CLIENT_POOL" \
            -j "$([[ "$CLIENT_TO_CLIENT" == on ]] && echo ACCEPT || echo DROP)"
    fi
    iptables -w -t filter -A "$HOST_FWD_CHAIN" \
        -i "$GATEWAY_TUN" -s "$CLIENT_POOL" -o "$wan" -j ACCEPT
    iptables -w -t filter -A "$HOST_FWD_CHAIN" \
        -i "$wan" -o "$GATEWAY_TUN" -m conntrack \
        --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -w -t filter -A "$HOST_FWD_CHAIN" \
        -i "$GATEWAY_TUN" -s "$CLIENT_POOL" -j DROP
    iptables -w -t filter -A "$HOST_FWD_CHAIN" -j RETURN
    iptables_jump_add_once filter FORWARD "$HOST_FWD_CHAIN" "$comment:forward"

    iptables_chain_ensure mangle "$HOST_MANGLE_CHAIN"
    iptables -w -t mangle -A "$HOST_MANGLE_CHAIN" \
        -i "$GATEWAY_TUN" -s "$CLIENT_POOL" -o "$wan" -p tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    iptables -w -t mangle -A "$HOST_MANGLE_CHAIN" -j RETURN
    iptables_jump_add_once mangle FORWARD "$HOST_MANGLE_CHAIN" "$comment:mangle"

    iptables_chain_ensure nat "$NS_NAT_CHAIN"
    iptables -w -t nat -A "$NS_NAT_CHAIN" \
        -s "$CLIENT_POOL" -o "$wan" -j MASQUERADE
    iptables -w -t nat -A "$NS_NAT_CHAIN" -j RETURN
    iptables_jump_add_once nat POSTROUTING "$NS_NAT_CHAIN" "$comment:host-nat"
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

    # Host exit does not own a transit veth, NNS route or policy table.
    # Remove only its own INPUT, forward and NAT rules.
    if [[ "$VIA_APP" == host ]]; then
        gateway_public_firewall_down "$gateway" || true
        gateway_host_exit_rules_down || true
        ip link del "$GATEWAY_TUN" 2>/dev/null || true
        rm -rf "$(gateway_runtime_dir "$gateway")"
        return 0
    fi

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

    # Public INPUT access is lifecycle-owned by the gateway.  Remove the
    # nns-app-owned host-firewall rule before tearing down the data plane so a
    # stopped/removed public gateway does not leave an exposed listening port.
    gateway_public_firewall_down "$gateway" || true
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
    # A failed OpenVPN startup can leave the uniquely named managed TUN
    # interface behind.  Remove it before a reconciled retry so the next
    # process never inherits stale interface state.
    ip link del "$GATEWAY_TUN" 2>/dev/null || true
    rm -rf "$(gateway_runtime_dir "$gateway")"
}

gateway_up() {
    require_root
    local gateway=$1 upstream_data upstream_ns upstream_tun
    local host_ip ns_ip runtime

    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"

    if [[ "$VIA_APP" == host ]]; then
        # OpenVPN's --up callback installs host NAT only after the TUN exists.
        gateway_down_locked "$gateway" >/dev/null 2>&1 || true
        load_gateway_cfg "$gateway"
        local unpriv_user unpriv_group
        unpriv_user=$(nns_unprivileged_user)
        unpriv_group=$(nns_unprivileged_group)
        install -d -o "$unpriv_user" -g "$unpriv_group" -m 0750 \
            "$(gateway_runtime_dir "$gateway")"
        sysctl -q -w net.ipv4.ip_forward=1
        if ! gateway_public_firewall_up "$gateway"; then
            release_lock "gateway-$gateway"
            die "Could not open host firewall for OpenVPN server '$gateway'."
        fi
        release_lock "gateway-$gateway"
        log "OpenVPN server '$gateway' is ready to start on the host uplink."
        return 0
    fi

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
    local unpriv_user unpriv_group
    unpriv_user=$(nns_unprivileged_user)
    unpriv_group=$(nns_unprivileged_group)
    install -d -o "$unpriv_user" -g "$unpriv_group" -m 0750 \
        "$(gateway_runtime_dir "$gateway")"

    ip link add "$GATEWAY_VETH_HOST" \
        type veth peer name "$GATEWAY_VETH_NS"
    ip addr add "$TRANSIT_HOST_ADDR" dev "$GATEWAY_VETH_HOST"
    ip link set "$GATEWAY_VETH_HOST" up
    firewalld_interface_add "$GATEWAY_VETH_HOST"
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

    if ! gateway_public_firewall_up "$gateway"; then
        gateway_down_locked "$gateway" >/dev/null 2>&1 || true
        release_lock "gateway-$gateway"
        die "Could not open host firewall for gateway '$gateway' on $LISTEN_PORT/$LISTEN_PROTO."
    fi

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
    firewalld_interface_add "$tunnel_dev"

    if [[ "$VIA_APP" == host ]]; then
        local wan
        wan=$(detect_wan_iface auto) || {
            release_lock "gateway-$gateway"
            die "Cannot detect the host IPv4 default WAN interface."
        }
        sysctl -q -w net.ipv4.ip_forward=1
        gateway_host_exit_rules_up "$wan"
        release_lock "gateway-$gateway"
        return 0
    fi

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
    case "${TRANSPORT:-direct}" in
        direct|ssh) exec "$(openvpn_binary)" --config "$config" ;;
        stunnel|cloak) gateway_transport_server_exec "$gateway" ;;
        *) die "Unsupported gateway transport '$TRANSPORT'." ;;
    esac
}

gateway_start() {
    require_root
    local gateway=$1 deadline pki config_before="" config_after=""
    validate_gateway_name "$gateway"
    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"
    if [[ "${GATEWAY_BACKEND:-openvpn}" == amneziawg ]]; then
        awg_server_start "$gateway"
        return $?
    fi
    gateway_ensure_runtime_access "$gateway" || {
        release_lock "gateway-$gateway"
        die "Could not normalize runtime access for gateway '$gateway'."
    }
    if [[ "$VIA_APP" != host ]]; then
        ensure_upstream_ready "$gateway" "$VIA_APP" >/dev/null
    fi

    [[ ! -f "$(gateway_dir "$gateway")/server.conf" ]] ||
        config_before=$(sha256sum "$(gateway_dir "$gateway")/server.conf" 2>/dev/null | awk '{print $1}')
    write_gateway_unit_dropin "$gateway"
    gateway_write_server_config "$gateway"
    [[ ! -f "$(gateway_dir "$gateway")/server.conf" ]] ||
        config_after=$(sha256sum "$(gateway_dir "$gateway")/server.conf" 2>/dev/null | awk '{print $1}')
    gateway_write_transport_config "$gateway"
    systemctl daemon-reload
    systemctl enable --now "nns-gateway-crl-refresh@${gateway}.timer" \
        >/dev/null 2>&1 || true

    pki=$(gateway_pki_dir "$gateway")
    if ! gateway_crl_valid_for "$pki/crl.pem" 604800; then
        gateway_crl_refresh "$gateway"
    fi
    if ! gateway_public_firewall_up "$gateway"; then
        gateway_public_firewall_down "$gateway" >/dev/null 2>&1 || true
        release_lock "gateway-$gateway"
        die "Could not open host firewall for gateway '$gateway' on $LISTEN_PORT/$LISTEN_PROTO."
    fi
    release_lock "gateway-$gateway"

    if systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
        if [[ -n "$config_before" && "$config_before" != "$config_after" ]]; then
            log "Gateway '$gateway' configuration changed; restarting it."
            if ! systemctl restart "nns-gateway@${gateway}.service"; then
                warn "Gateway '$gateway' failed to restart after configuration update."
                journalctl -u "nns-gateway@${gateway}.service" \
                    -n 80 -o cat --no-pager >&2 2>/dev/null || true
                return 1
            fi
        else
            log "Gateway '$gateway' is already running."
            return 0
        fi
    elif ! systemctl start "nns-gateway@${gateway}.service"; then
        warn "Gateway '$gateway' failed to start."
        journalctl -u "nns-gateway@${gateway}.service" \
            -n 80 -o cat --no-pager >&2 2>/dev/null || true
        return 1
    fi

    deadline=$((SECONDS + 8))
    while (( SECONDS < deadline )); do
        if ip link show dev "$GATEWAY_TUN" up >/dev/null 2>&1 &&
           systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
            if [[ "${TRANSPORT:-direct}" == ssh ]]; then
                log "Started loopback gateway '$gateway' on 127.0.0.1:$OPENVPN_LISTEN_PORT/tcp via $VIA_APP (SSH endpoint $PUBLIC_HOST:$PUBLIC_PORT)."
            else
                log "Started gateway '$gateway' on $PUBLIC_HOST:$PUBLIC_PORT/$LISTEN_PROTO via $VIA_APP."
            fi
            return 0
        fi
        if systemctl is-failed --quiet "nns-gateway@${gateway}.service" ||
           [[ "$(systemctl show -p SubState --value "nns-gateway@${gateway}.service" 2>/dev/null || true)" == auto-restart ]]; then
            break
        fi
        sleep 0.25
    done

    warn "Gateway service did not create its OpenVPN interface '$GATEWAY_TUN'."
    journalctl -u "nns-gateway@${gateway}.service" \
        -n 80 -o cat --no-pager >&2 2>/dev/null || true

    # Do not leave an invalid configuration in systemd's restart loop. The
    # caller can repair/reconcile the gateway and start it again explicitly.
    systemctl stop "nns-gateway@${gateway}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "nns-gateway@${gateway}.service" >/dev/null 2>&1 || true
    gateway_down "$gateway" >/dev/null 2>&1 || true
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

# Change a public gateway's egress without changing its listener, tunnel,
# client pool or issued credentials. Stop while the old configuration is still
# installed: ExecStopPost must tear down the OLD namespace's routes and NAT.
gateway_set_via() {
    require_root
    local gateway=$1 requested=$2 previous backend cfg snapshot was_active=off
    validate_gateway_name "$gateway"
    managed_gateway_exists "$gateway" || die "App '$gateway' is not a managed VPN server/gateway."

    # Serialize changes against gateway creation/reinstallation and reserve
    # this gateway's configuration for the entire transition. Never hold its
    # gateway lock while stopping/starting systemd: ExecStopPost/ExecStartPre
    # acquire that lock themselves.
    acquire_lock global
    load_gateway_cfg "$gateway"
    previous=$VIA_APP
    backend=${GATEWAY_BACKEND:-openvpn}
    if [[ "$requested" != host ]]; then
        # Reject missing upstreams, dependency cycles and gateway-as-upstream.
        # Validation is read-only and must happen BEFORE disrupting clients.
        if ! ( normalize_via "$gateway" "$requested" >/dev/null ); then
            release_lock global
            return 1
        fi
        if [[ "$backend" != openvpn ]]; then
            release_lock global
            die "Changing the exit of an AmneziaWG server is not supported; only OpenVPN gateways can use --via."
        fi
    fi
    if [[ "$previous" == "$requested" ]]; then
        release_lock global
        log "App '$gateway' already uses '$requested'."
        return 0
    fi
    if systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
        was_active=on
        if [[ "$requested" != host ]]; then
            # Validate actual tunnel readiness, not merely a configured name.
            if ! ( ensure_upstream_ready "$gateway" "$requested" >/dev/null ); then
                release_lock global
                warn "Upstream '$requested' is not ready; '$gateway' remains on '$previous'."
                return 1
            fi
        fi
    fi

    cfg=$(gateway_cfg_file "$gateway")
    snapshot=$(mktemp "${cfg}.set-via.XXXXXX") || {
        release_lock global
        die "Cannot create a rollback snapshot for '$gateway'."
    }
    if ! cp -p -- "$cfg" "$snapshot"; then
        rm -f -- "$snapshot"
        release_lock global
        die "Cannot snapshot '$gateway' before changing its exit."
    fi

    if [[ "$was_active" == on ]]; then
        if ! ( gateway_stop "$gateway" ) ||
           systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
            rm -f -- "$snapshot"
            release_lock global
            warn "Could not stop '$gateway' using '$previous'; exit was not changed."
            return 1
        fi
    else
        # A stopped service should not have a live data plane, but clean up
        # any stale runtime under the OLD upstream before updating VIA_APP.
        if ! ( gateway_down "$gateway" ); then
            rm -f -- "$snapshot"
            release_lock global
            warn "Could not clean up '$gateway' before changing its exit."
            return 1
        fi
    fi

    acquire_lock "gateway-$gateway"
    if ! ( gateway_cfg_set "$gateway" VIA_APP "$requested" ); then
        release_lock "gateway-$gateway"
        if cp -p -- "$snapshot" "$cfg"; then
            rm -f -- "$snapshot"
            warn "Failed to update '$gateway' exit; previous configuration restored."
        else
            warn "Failed to restore '$gateway' configuration; recovery snapshot kept: $snapshot"
        fi
        release_lock global
        return 1
    fi
    release_lock "gateway-$gateway"

    if [[ "$was_active" == on ]] && ! ( gateway_start "$gateway" ); then
        warn "Failed to start '$gateway' via '$requested'; rolling back to '$previous'."
        # The new upstream's partially provisioned rules must be torn down
        # while VIA_APP still refers to the new upstream.
        if ! ( gateway_stop "$gateway" ) ||
           systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
            release_lock global
            warn "Rollback cannot stop the failed new service. Configuration snapshot kept: $snapshot"
            return 1
        fi
        acquire_lock "gateway-$gateway"
        if ! cp -p -- "$snapshot" "$cfg"; then
            release_lock "gateway-$gateway"
            release_lock global
            warn "Rollback could not restore configuration. Snapshot kept: $snapshot"
            return 1
        fi
        release_lock "gateway-$gateway"
        rm -f -- "$snapshot"
        if ! ( gateway_start "$gateway" ); then
            release_lock global
            warn "Configuration was restored to '$previous', but gateway '$gateway' did not restart."
            return 1
        fi
        release_lock global
        warn "Gateway '$gateway' restored to '$previous' after failed switch."
        return 1
    fi

    rm -f -- "$snapshot"
    release_lock global
    log "Gateway '$gateway' exit changed: $previous -> $requested (previously $was_active)."
}

gateways_using_app() {
    local app=$1 dir gateway via
    shopt -s nullglob
    for dir in "$GATEWAY_BASE_DIR"/*; do
        [[ -f "$dir/gateway.cfg" ]] || continue
        gateway=$(basename "$dir")
        via=$(gateway_cfg_value "$gateway" VIA_APP 2>/dev/null || true)
        # 'host' denotes a direct host exit, not an app dependency.
        [[ "$via" == "$app" && "$via" != host ]] && printf '%s\n' "$gateway"
    done

    # This is an enumerator, not a predicate. A different gateway—or no
    # gateway at all—must produce empty output with success. remove_app() uses
    # it in a pipe while errexit/pipefail are enabled.
    return 0
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
    local metadata cert_serial="" cloak_uid="" generation=1 rc=0 restart=no

    validate_gateway_name "$gateway"
    validate_gateway_client_name "$client"
    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"

    if [[ "${GATEWAY_BACKEND:-openvpn}" == amneziawg ]]; then
        release_lock "gateway-$gateway"
        awg_server_client_add "$gateway" "$client"
        return $?
    fi
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

    if (( rc == 0 )) && [[ "${OPENVPN_COMPAT:-modern}" != embedded ]]; then
        metadata=$(printf '%s' "$client" | base64 -w0) || rc=1
    fi
    if (( rc == 0 )) && [[ "${OPENVPN_COMPAT:-modern}" != embedded ]]; then
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
    if (( rc == 0 )) && [[ "${TRANSPORT:-direct}" == cloak ]]; then
        cloak_uid=$(gateway_cloak_new_uid) || rc=1
    fi
    if (( rc == 0 )); then
        cat >"$staging/client.cfg" <<CLIENT_CFG_EOF || rc=1
CLIENT_NAME="$client"
STATUS="active"
CERT_SERIAL="$cert_serial"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GENERATION="$generation"
CLOAK_UID="$cloak_uid"
FIXED_IP=""
ROUTE_MODE="full"
CLIENT_CFG_EOF
    fi

    if (( rc == 0 )); then
        chown -R root:root "$staging" || rc=1
        chmod 0700 "$staging" || rc=1
        chmod 0600 "$staging/client.key" "$staging/client.cfg" || rc=1
        if [[ "${OPENVPN_COMPAT:-modern}" != embedded ]]; then
            chmod 0600 "$staging/tls-crypt-v2-client.key" || rc=1
        fi
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
    if [[ "${TRANSPORT:-direct}" == cloak ]]; then
        gateway_write_transport_config "$gateway"
        if [[ "${NNS_SUPPRESS_GATEWAY_RESTART:-0}" != 1 ]] &&
           systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
            restart=yes
        fi
    fi
    release_lock "gateway-$gateway"

    if [[ "$restart" == yes ]]; then
        systemctl restart "nns-gateway@${gateway}.service" ||
            warn "Client '$client' was added, but gateway '$gateway' failed to restart."
    fi
    log "Added client '$client' to gateway '$gateway'."
    log "Export it with:"
    if [[ "${TRANSPORT:-direct}" == direct ]]; then
        log "  sudo nns-app gateway client export $gateway $client --output ~/$gateway-$client.ovpn"
    else
        log "  sudo nns-app gateway client export $gateway $client --format nnslink --output ~/$gateway-$client.nnslink"
    fi
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
    GENERATION=${GENERATION:-1}
    CLOAK_UID=${CLOAK_UID:-}
    FIXED_IP=${FIXED_IP:-}
    ROUTE_MODE=${ROUTE_MODE:-full}
    case "$ROUTE_MODE" in full|split) ;; *) die "Invalid route mode in $file." ;; esac
    [[ "${CLIENT_NAME:-}" == "$client" ]] ||
        die "CLIENT_NAME mismatch in $file."
}

gateway_client_fixed_ip() {
    require_root
    local gateway=$1 client=$2 requested=${3:-show} previous assignments candidate
    local cfg tmp backup was_active=off
    validate_gateway_name "$gateway"
    validate_gateway_client_name "$client"
    if [[ "$(gateway_cfg_value "$gateway" GATEWAY_BACKEND)" == amneziawg ]]; then
        gateway_client_load "$gateway" "$client"
        case "$requested" in
            show|on) printf '%s/%s: fixed-ip=%s (required by AmneziaWG)\n' "$gateway" "$client" "$FIXED_IP" ;;
            off) die "AmneziaWG peers require server-assigned stable IPs; cannot disable." ;;
            *) die "Expected fixed-ip on or off." ;;
        esac
        return 0
    fi
    case "$requested" in show|on|off) ;; *) die "Expected fixed-ip on or off." ;; esac
    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"
    gateway_client_load "$gateway" "$client"
    previous=${FIXED_IP:-}
    [[ "${STATUS:-}" == active ]] || die "Cannot change revoked client '$client'."
    if [[ "$requested" == show ]]; then
        release_lock "gateway-$gateway"
        printf '%s/%s: fixed-ip=%s\n' "$gateway" "$client" "${previous:-off}"
        return 0
    fi
    if [[ "$requested" == on && -n "$previous" ]]; then
        release_lock "gateway-$gateway"
        log "Client '$client' on '$gateway' already has fixed IP $previous."
        return 0
    fi
    if [[ "$requested" == off && -z "$previous" ]]; then
        release_lock "gateway-$gateway"
        log "Client '$client' on '$gateway' already uses dynamic addressing."
        return 0
    fi
    candidate=''
    if [[ "$requested" == on ]]; then
        assignments=$(gateway_active_fixed_assignments "$(gateway_dir "$gateway")") ||
            die "Could not read existing fixed assignments."
        gateway_fixed_ip_plan "$CLIENT_POOL" "$assignments" >/dev/null ||
            die "Existing fixed assignments are invalid."
        candidate=$(gateway_allocate_fixed_ip "$CLIENT_POOL" "$assignments") ||
            die "No fixed VPN IP remains for '$gateway'."
    fi
    cfg="$(gateway_client_dir "$gateway" "$client")/client.cfg"
    backup=$(mktemp) || return 1
    cp -p "$cfg" "$backup" || { rm -f "$backup"; return 1; }
    tmp=$(mktemp "${cfg}.XXXXXX") || { rm -f "$backup"; return 1; }
    awk -v assigned="$candidate" '
        /^FIXED_IP=/ { print "FIXED_IP=\"" assigned "\""; seen=1; next }
        { print }
        END { if (!seen) print "FIXED_IP=\"" assigned "\"" }
    ' "$cfg" >"$tmp"
    install -o root -g root -m 0600 "$tmp" "$cfg" || {
        rm -f -- "$tmp" "$backup"; return 1;
    }
    rm -f "$tmp"
    if ! gateway_write_server_config "$gateway"; then
        cp -p "$backup" "$cfg"
        gateway_write_server_config "$gateway" || true
        rm -f "$backup"
        release_lock "gateway-$gateway"
        die "Failed updating fixed IP for '$client'."
    fi
    if systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
        was_active=on
    fi
    release_lock "gateway-$gateway"
    # A restart updates the dynamic pool and forces already connected clients
    # to obtain their address afresh. Certificates and profiles do not change.
    if [[ "$was_active" == on ]]; then
        if ! systemctl restart "nns-gateway@${gateway}.service"; then
            warn "Fixed IP update failed to restart gateway '$gateway'; rolling back."
            acquire_lock "gateway-$gateway"
            cp -p "$backup" "$cfg" || warn "Cannot restore previous client assignment."
            gateway_write_server_config "$gateway" ||
                warn "Could not rebuild previous OpenVPN configuration."
            release_lock "gateway-$gateway"
            systemctl restart "nns-gateway@${gateway}.service" ||
                warn "Gateway '$gateway' could not restart after rollback."
            rm -f "$backup"
            return 1
        fi
    fi
    rm -f "$backup"
    if [[ "$requested" == on ]]; then
        log "Client '$client' on '$gateway': fixed IP $candidate (server-assigned; reconnect to use)."
    else
        log "Client '$client' on '$gateway': fixed IP disabled (dynamic on reconnect)."
    fi
}

# Only the server stores this setting. Existing profile and key stay intact.
# A running OpenVPN server is restarted because changing pushed options does
# not immediately reconfigure an already-connected client.
gateway_client_route_mode() {
    require_root
    local gateway=$1 client=$2 requested=${3:-show} previous cfg tmp backup was_active=off
    validate_gateway_name "$gateway"
    validate_gateway_client_name "$client"
    case "$requested" in show|split|full) ;; *) die "Expected route-mode split or full." ;; esac
    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"
    gateway_client_load "$gateway" "$client"
    if [[ "${GATEWAY_BACKEND:-openvpn}" == amneziawg ]]; then
        previous=${ROUTE_MODE:-split}
        if [[ "$requested" == show ]]; then
            release_lock "gateway-$gateway"
            printf '%s/%s: route-mode=%s (re-export needed after change)\n' "$gateway" "$client" "$previous"
            return 0
        fi
        sed -i -E "s/^ROUTE_MODE=.*/ROUTE_MODE=\"$requested\"/" "$(gateway_client_dir "$gateway" "$client")/client.cfg"
        release_lock "gateway-$gateway"
        log "Updated AmneziaWG client route mode; re-export its .conf profile to apply."
        return 0
    fi
    previous=${ROUTE_MODE:-full}
    [[ "${STATUS:-}" == active ]] || die "Cannot change revoked client '$client'."
    if [[ "$requested" == show ]]; then
        release_lock "gateway-$gateway"
        printf '%s/%s: route-mode=%s\n' "$gateway" "$client" "$previous"
        return 0
    fi
    if [[ "$requested" == "$previous" ]]; then
        release_lock "gateway-$gateway"
        log "Client '$client' on '$gateway' already uses $requested routing."
        return 0
    fi
    cfg="$(gateway_client_dir "$gateway" "$client")/client.cfg"
    backup=$(mktemp) || return 1
    cp -p "$cfg" "$backup" || { rm -f "$backup"; return 1; }
    tmp=$(mktemp "${cfg}.XXXXXX") || { rm -f "$backup"; return 1; }
    awk -v mode="$requested" '
        /^ROUTE_MODE=/ { print "ROUTE_MODE=\"" mode "\""; seen=1; next }
        { print }
        END { if (!seen) print "ROUTE_MODE=\"" mode "\"" }
    ' "$cfg" >"$tmp"
    install -o root -g root -m 0600 "$tmp" "$cfg" || {
        rm -f -- "$tmp" "$backup"; return 1;
    }
    rm -f "$tmp"
    if ! gateway_write_server_config "$gateway"; then
        cp -p "$backup" "$cfg" || true
        gateway_write_server_config "$gateway" || true
        rm -f "$backup"
        release_lock "gateway-$gateway"
        die "Failed updating route mode for '$client'."
    fi
    if systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
        was_active=on
    fi
    release_lock "gateway-$gateway"
    if [[ "$was_active" == on ]]; then
        if ! systemctl restart "nns-gateway@${gateway}.service"; then
            warn "Route mode update failed to restart '$gateway'; rolling back."
            acquire_lock "gateway-$gateway"
            cp -p "$backup" "$cfg" || warn "Cannot restore client route mode."
            gateway_write_server_config "$gateway" || warn "Cannot rebuild previous server configuration."
            release_lock "gateway-$gateway"
            systemctl restart "nns-gateway@${gateway}.service" ||
                warn "Could not restart previous configuration for '$gateway'."
            rm -f "$backup"
            return 1
        fi
    fi
    rm -f "$backup"
    log "Client '$client' on '$gateway': $requested tunnel routing (effective on reconnect)."
}

gateway_client_export() {
    require_root
    local gateway=$1 client=$2 output=$3 format=${4:-ovpn}
    local tmp owner group
    validate_gateway_name "$gateway"
    validate_gateway_client_name "$client"
    case "$format" in ovpn|nnslink) ;; *) die "Unsupported export format '$format'." ;; esac
    acquire_lock "gateway-$gateway" shared
    load_gateway_cfg "$gateway"
    [[ "${GATEWAY_BACKEND:-openvpn}" != amneziawg ]] || die "Use: nns-app export awg $gateway --client $client --output client.conf"
    gateway_client_load "$gateway" "$client"
    [[ "${STATUS:-}" == active ]] ||
        die "Client '$client' is revoked and cannot be exported."
    [[ -n "$output" ]] || die "--output is required."

    if [[ "$output" != - ]]; then
        output=$(readlink -m "$output")
        [[ ! -e "$output" ]] || die "Output already exists: $output"
        [[ -d "$(dirname "$output")" ]] || die "Output directory does not exist: $(dirname "$output")"
    fi

    if [[ "$format" == ovpn ]]; then
        [[ "${TRANSPORT:-direct}" == direct ]] ||
            die "Gateway transport '$TRANSPORT' requires --format nnslink."
        tmp=$(mktemp)
        gateway_write_client_profile_file "$gateway" "$client" "$tmp" public
        if [[ "$output" == - ]]; then
            cat "$tmp"
        else
            owner=${SUDO_USER:-root}
            if [[ "$owner" != root ]] && id "$owner" >/dev/null 2>&1; then
                group=$(id -gn "$owner")
                install -o "$owner" -g "$group" -m 0600 "$tmp" "$output"
            else
                install -o root -g root -m 0600 "$tmp" "$output"
            fi
        fi
        rm -f "$tmp"
    else
        if [[ "$output" == - ]]; then
            gateway_write_nnslink_bundle "$gateway" "$client" -
        else
            tmp=$(mktemp)
            gateway_write_nnslink_bundle "$gateway" "$client" "$tmp"
            owner=${SUDO_USER:-root}
            if [[ "$owner" != root ]] && id "$owner" >/dev/null 2>&1; then
                group=$(id -gn "$owner")
                install -o "$owner" -g "$group" -m 0600 "$tmp" "$output"
            else
                install -o root -g root -m 0600 "$tmp" "$output"
            fi
            rm -f "$tmp"
        fi
    fi
    release_lock "gateway-$gateway"

    if [[ "$output" != - ]]; then
        log "Exported client '$client' from gateway '$gateway' as $format."
        log "Output: $output"
    fi
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

    if [[ "${GATEWAY_BACKEND:-openvpn}" == amneziawg ]]; then
        release_lock "gateway-$gateway"
        awg_server_client_revoke "$gateway" "$client"
        return $?
    fi
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
    [[ "${TRANSPORT:-direct}" != cloak ]] || gateway_write_transport_config "$gateway"
    gateway_write_server_config "$gateway" || warn "Unable to refresh CCD after revoking '$client'."
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

# Current VPN address and connection metadata come from the server's live
# OpenVPN status file / AmneziaWG handshake.  A disconnected dynamic client
# has no current address, while an assigned fixed IP is retained separately.
gateway_client_live_records() {
    local gateway=$1
    # OpenVPN status files may survive service shutdown. Never label cached
    # sessions as currently connected when the gateway service is offline.
    systemctl is-active --quiet "nns-gateway@${gateway}.service" >/dev/null 2>&1 || return 0
    gateway_connected_clients "$gateway"
}

gateway_client_connection_record() {
    local gateway=$1 client=$2 record name
    while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        IFS='|' read -r name _ <<<"$record"
        if [[ "$name" == "$client" ]]; then
            printf '%s\n' "$record"
            return 0
        fi
    done < <(gateway_client_live_records "$gateway")
    return 1
}

gateway_client_current_ip() {
    local gateway=$1 client=$2 record cn real ip rx tx since
    record=$(gateway_client_connection_record "$gateway" "$client") || return 1
    IFS='|' read -r cn real ip rx tx since <<<"$record"
    [[ -n "$ip" && "$ip" != '-' ]] || return 1
    # OpenVPN status v3 can return an IPv4 + IPv6 pair. Prefer IPv4.
    printf '%s\n' "${ip%%,*}"
}

gateway_client_list() {
    require_root
    local gateway=$1 dir client status serial fixed route_mode current cn real ip rx tx since
    declare -A live_ips=()
    validate_gateway_name "$gateway"
    acquire_lock "gateway-$gateway" shared
    load_gateway_cfg "$gateway"
    while IFS='|' read -r cn real ip rx tx since; do
        [[ -n "$cn" && -n "$ip" && "$ip" != - ]] || continue
        live_ips["$cn"]=${ip%%,*}
    done < <(gateway_client_live_records "$gateway")
    printf '%-24s %-10s %-16s %-10s %-20s %s\n' "Client" "Status" "Fixed IP" "Route" "Serial" "IP"
    printf '%-24s %-10s %-16s %-10s %-20s %s\n' "------------------------" "----------" "----------------" "----------" "--------------------" "----------------"
    local found=0
    shopt -s nullglob
    for dir in "$(gateway_clients_dir "$gateway")"/*; do
        [[ -f "$dir/client.cfg" ]] || continue
        client=$(basename "$dir")
        gateway_client_load "$gateway" "$client"
        status=${STATUS:-unknown}
        serial=${CERT_SERIAL:--}
        fixed=${FIXED_IP:--}
        route_mode=${ROUTE_MODE:-full}
        current=${live_ips[$client]-}
        [[ "$status" == active ]] || { fixed=-; route_mode=-; current=''; }
        printf '%-24s %-10s %-16s %-10s %-20s %s\n' \
            "$client" "$status" "$fixed" "$route_mode" "$serial" "${current:--}"
        found=1
    done
    shopt -u nullglob
    (( found )) || log "No clients configured for gateway '$gateway'."
    release_lock "gateway-$gateway"
}

# Detailed metadata deliberately excludes credential material (client.key,
# private keys, TLS secrets).  No network/host configuration is modified.
gateway_client_status() {
    require_root
    local gateway=$1 client=$2 record cn real current rx tx since connected=no
    local assigned status backend publickey='' endpoint='' handshake=0 latest='-'
    local created revoked serial generation cloak route_mode service
    validate_gateway_name "$gateway"
    validate_gateway_client_name "$client"
    acquire_lock "gateway-$gateway" shared
    load_gateway_cfg "$gateway"
    gateway_client_load "$gateway" "$client"
    backend=${GATEWAY_BACKEND:-openvpn}
    status=${STATUS:-unknown}
    assigned=${FIXED_IP:-}
    route_mode=${ROUTE_MODE:-full}
    created=${CREATED_AT:--}
    revoked=${REVOKED_AT:--}
    serial=${CERT_SERIAL:--}
    generation=${GENERATION:-1}
    cloak=${CLOAK_UID:-}
    record=$(gateway_client_connection_record "$gateway" "$client" 2>/dev/null || true)
    current=''; real=''; rx=''; tx=''; since=''
    if [[ -n "$record" && "$status" == active ]]; then
        IFS='|' read -r cn real current rx tx since <<<"$record"
        current=${current%%,*}
        connected=yes
    fi
    service=$(systemctl is-active "nns-gateway@${gateway}.service" 2>/dev/null || true)
    [[ -n "$service" ]] || service=unknown
    printf 'Client:            %s\nGateway:           %s\nBackend:           %s\n' \
        "$client" "$gateway" "$backend"
    printf 'Status:            %s\nConnected:         %s\nGateway service:   %s\n' \
        "$status" "$connected" "$service"
    printf 'Current VPN IP:    %s\nAssigned VPN IP:   %s\n' \
        "${current:--}" "${assigned:--}"
    printf 'Remote address:    %s\nPublic endpoint:   %s:%s/%s\n' \
        "${real:--}" "${PUBLIC_HOST:-unknown}" "${PUBLIC_PORT:-unknown}" "${LISTEN_PROTO:-unknown}"
    printf 'Client pool:       %s\nTunnel:            %s\nRoute mode:        %s\n' \
        "${CLIENT_POOL:--}" "${GATEWAY_TUN:--}" "$route_mode"
    printf 'Transport:         %s\nUpstream:          %s\nClient-to-client:  %s\n' \
        "${TRANSPORT:-direct}" "${VIA_APP:-host}" "${CLIENT_TO_CLIENT:-off}"
    printf 'Created:           %s\nRevoked:           %s\nGeneration:        %s\n' \
        "$created" "$revoked" "$generation"
    if [[ "$backend" == amneziawg ]]; then
        publickey=$(cat "$(gateway_client_dir "$gateway" "$client")/public.key" 2>/dev/null || true)
        if [[ -n "$publickey" ]]; then
            printf 'Peer public key:   %s\n' "$publickey"
            endpoint=$(awg show "$GATEWAY_TUN" endpoints 2>/dev/null | awk -v k="$publickey" '$1==k {print $2; exit}')
            handshake=$(awg show "$GATEWAY_TUN" latest-handshakes 2>/dev/null | awk -v k="$publickey" '$1==k {print $2; exit}')
            if [[ "$handshake" =~ ^[0-9]+$ ]] && (( handshake > 0 )); then
                latest=$(date -u -d "@$handshake" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null || echo "$handshake")
            fi
            printf 'Peer endpoint:     %s\nLast handshake:    %s\n' "${endpoint:--}" "$latest"
            if [[ -z "$rx" || -z "$tx" ]]; then
                IFS=$'\t' read -r rx tx < <(awg show "$GATEWAY_TUN" transfer 2>/dev/null | awk -v k="$publickey" '$1==k {printf "%s\t%s\n", $2, $3; exit}') || true
            fi
        fi
    else
        printf 'Certificate serial: %s\n' "$serial"
        [[ -z "$cloak" ]] || printf 'Cloak UID:         %s\n' "$cloak"
    fi
    printf 'Connected since:   %s\n' "${since:--}"
    printf 'Bytes received:    %s\nBytes sent:        %s\n' "${rx:--}" "${tx:--}"
    release_lock "gateway-$gateway"
}

gateway_client_counts() {
    local gateway=$1 dir client active=0 revoked=0 total=0
    validate_gateway_name "$gateway"
    shopt -s nullglob
    for dir in "$(gateway_clients_dir "$gateway")"/*; do
        [[ -f "$dir/client.cfg" ]] || continue
        client=$(basename "$dir")
        if ! gateway_client_load "$gateway" "$client" 2>/dev/null; then
            continue
        fi
        total=$((total + 1))
        case "${STATUS:-unknown}" in
            active) active=$((active + 1)) ;;
            revoked) revoked=$((revoked + 1)) ;;
        esac
    done
    shopt -u nullglob
    printf '%s|%s|%s\n' "$total" "$active" "$revoked"
}

gateway_connected_client_count() {
    local gateway=$1 count=0 line
    while IFS= read -r line; do
        [[ -n "$line" ]] && count=$((count + 1))
    done < <(gateway_connected_clients "$gateway")
    printf '%s\n' "$count"
}

gateway_client_is_connected() {
    local gateway=$1 client=$2 line cn
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        IFS='|' read -r cn _ <<<"$line"
        [[ "$cn" == "$client" ]] && return 0
    done < <(gateway_connected_clients "$gateway")
    return 1
}

gateway_inventory_record() {
    # Machine-readable record used by the high-level `nns-app list` views and
    # automatic-remote inventory. Fields never contain literal '|'.
    local gateway=$1 source=${2:-local}
    local state endpoint kind counts total active revoked connected
    validate_gateway_name "$gateway"
    load_gateway_cfg "$gateway"
    state=$(systemctl is-active "nns-gateway@${gateway}.service" 2>/dev/null || true)
    [[ "$state" == active ]] || state=stopped
    if [[ "${TRANSPORT:-direct}" == ssh ]]; then
        kind=private
        endpoint="${PUBLIC_HOST}:${PUBLIC_PORT}/ssh"
    else
        kind=public
        endpoint="${PUBLIC_HOST}:${PUBLIC_PORT}/${LISTEN_PROTO}"
    fi
    counts=$(gateway_client_counts "$gateway")
    IFS='|' read -r total active revoked <<<"$counts"
    connected=$(gateway_connected_client_count "$gateway")
    printf 'GATEWAY|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$gateway" "$kind" "$state" "$VIA_APP" "$endpoint" \
        "$active" "$revoked" "$connected" "$source"
}

gateway_external_client_records() {
    # CLIENT|name|status|gateway|endpoint|IP|connected|source
    # IP means live VPN IP when connected, otherwise configured fixed IP, or '-'.
    local gateway=$1 source=${2:-local} dir client endpoint connected current display_ip cn real ip rx tx since
    declare -A live_ips=()
    validate_gateway_name "$gateway"
    load_gateway_cfg "$gateway"
    [[ "${TRANSPORT:-direct}" != ssh ]] || return 0
    endpoint="${PUBLIC_HOST}:${PUBLIC_PORT}/${LISTEN_PROTO}"
    while IFS='|' read -r cn real ip rx tx since; do
        [[ -n "$cn" && -n "$ip" && "$ip" != - ]] || continue
        live_ips["$cn"]=${ip%%,*}
    done < <(gateway_client_live_records "$gateway")
    shopt -s nullglob
    for dir in "$(gateway_clients_dir "$gateway")"/*; do
        [[ -f "$dir/client.cfg" ]] || continue
        client=$(basename "$dir")
        gateway_client_load "$gateway" "$client" 2>/dev/null || continue
        current=''
        if [[ "${STATUS:-unknown}" == active ]]; then
            current=${live_ips[$client]-}
            display_ip=${current:-${FIXED_IP:--}}
        else
            display_ip=-
        fi
        connected=no
        [[ -z "$current" ]] || connected=yes
        printf 'CLIENT|%s|%s|%s|%s|%s|%s|%s\n' \
            "$client" "${STATUS:-unknown}" "$gateway" "$endpoint" \
            "$display_ip" "$connected" "$source"
    done
    shopt -u nullglob
}

gateway_connected_clients() {
    local gateway=$1 status_file
    if [[ "$(gateway_cfg_value "$gateway" GATEWAY_BACKEND)" == amneziawg ]]; then
        awg_server_connected_clients "$gateway"
        return $?
    fi
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
    virtual = item.get("Virtual IPv4 Address") or item.get("Virtual Address", "-")
    rx = item.get("Bytes Received", "0")
    tx = item.get("Bytes Sent", "0")
    since = item.get("Connected Since", item.get("Connected Since (time_t)", "-"))
    print(f"{cn}|{real}|{virtual}|{rx}|{tx}|{since}")
PY_GATEWAY_STATUS
}

gateway_listener_ready() {
    local pid=$1 proto_flag
    [[ "$LISTEN_PROTO" == tcp ]] && proto_flag=lnt || proto_flag=lnu
    ss -H -"$proto_flag" 2>/dev/null |
        grep -Eq "[:.]${LISTEN_PORT}[[:space:]]"
}

gateway_policy_ready() {
    [[ "$VIA_APP" != host ]] || return 0
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
    if [[ "$VIA_APP" == host ]]; then
        [[ -n "$upstream_tun" ]] || return 1
        iptables -w -t filter -C FORWARD \
            -m comment --comment "$comment:forward" \
            -j "$HOST_FWD_CHAIN" 2>/dev/null || return 1
        iptables -w -t filter -C "$HOST_FWD_CHAIN" \
            -i "$GATEWAY_TUN" -s "$CLIENT_POOL" \
            -o "$upstream_tun" -j ACCEPT 2>/dev/null || return 1
        iptables -w -t mangle -C FORWARD \
            -m comment --comment "$comment:mangle" \
            -j "$HOST_MANGLE_CHAIN" 2>/dev/null || return 1
        iptables -w -t nat -C POSTROUTING \
            -m comment --comment "$comment:host-nat" \
            -j "$NS_NAT_CHAIN" 2>/dev/null || return 1
        iptables -w -t nat -C "$NS_NAT_CHAIN" \
            -s "$CLIENT_POOL" -o "$upstream_tun" \
            -j MASQUERADE 2>/dev/null || return 1
        return 0
    fi
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
    if [[ "${GATEWAY_BACKEND:-openvpn}" == amneziawg ]]; then
        awg_server_status "$gateway"
        return $?
    fi
    unit="nns-gateway@${gateway}.service"
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    sub=$(systemctl show "$unit" -p SubState --value 2>/dev/null || true)
    result=$(systemctl show "$unit" -p Result --value 2>/dev/null || true)
    pid=$(systemctl show "$unit" -p MainPID --value 2>/dev/null || true)
    restarts=$(systemctl show "$unit" -p NRestarts --value 2>/dev/null || true)

    if [[ "$VIA_APP" == host ]]; then
        upstream_iface=$(detect_wan_iface auto 2>/dev/null || true)
        if [[ -n "$upstream_iface" ]]; then
            upstream_state=ready
        else
            upstream_state="host uplink unavailable"
        fi
    elif app_is_started "$VIA_APP" && vpn_route_ready "$VIA_APP"; then
        upstream_state=ready
        upstream_iface=$(vpn_route_iface "$VIA_APP" 2>/dev/null || true)
        upstream_ns=$(cfg_read_value "$VIA_APP" NS_NAME 2>/dev/null || true)
    elif app_is_started "$VIA_APP"; then
        upstream_state="started but tunnel offline"
    fi

    ip link show dev "$GATEWAY_TUN" up >/dev/null 2>&1 &&
        tunnel=yes
    gateway_listener_ready "${pid:-0}" && listening=yes

    if [[ "$VIA_APP" == host ]]; then
        veth_ok=yes  # No transit veth required for the host exit.
    elif ip link show "$GATEWAY_VETH_HOST" up >/dev/null 2>&1 &&
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
    printf 'Transport:         %s\n' "${TRANSPORT:-direct}"
    if [[ "${TRANSPORT:-direct}" == ssh ]]; then
        printf 'SSH endpoint:      %s:%s/tcp\n' "$PUBLIC_HOST" "$PUBLIC_PORT"
        printf 'Local listener:    127.0.0.1:%s/%s (%s; pid=%s)\n' \
            "$OPENVPN_LISTEN_PORT" "$OPENVPN_LISTEN_PROTO" "$listening" "${pid:-0}"
    else
        printf 'Public endpoint:   %s:%s/%s\n' \
            "$PUBLIC_HOST" "$PUBLIC_PORT" "$LISTEN_PROTO"
        printf 'Local listener:    %s:%s/%s (%s; pid=%s)\n' \
            "$([[ "${TRANSPORT:-direct}" == direct ]] && printf '0.0.0.0' || printf '127.0.0.1')" \
            "$LISTEN_PORT" "$LISTEN_PROTO" "$listening" "${pid:-0}"
    fi
    printf 'Client pool:       %s\n' "$CLIENT_POOL"
    printf 'Client-to-client:  %s\n' "$CLIENT_TO_CLIENT"
    printf 'Exit:              %s (%s)\n' \
        "$VIA_APP" "$upstream_state"
    [[ -z "$upstream_iface" ]] ||
        printf 'Exit tunnel:       %s\n' "$upstream_iface"
    printf 'Server interface:  %s (%s)\n' \
        "$GATEWAY_TUN" "$tunnel"
    if [[ "$VIA_APP" == host ]]; then
        printf 'Host uplink:       %s\n' "${upstream_iface:-unavailable}"
    else
        printf 'Transit veth:      %s\n' "$veth_ok"
        printf 'Policy routing:    %s\n' "$policy_ok"
    fi
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
    shopt -s nullglob
    for dir in "$GATEWAY_BASE_DIR"/*; do
        [[ -f "$dir/gateway.cfg" ]] || continue
        if (( ! found )); then
            printf '%-18s %-10s %-18s %-26s %s\n' \
                "Gateway" "Status" "Via" "Public endpoint" "Client pool"
            printf '%-18s %-10s %-18s %-26s %s\n' \
                "------------------" "----------" "------------------" "--------------------------" "------------------"
            found=1
        fi
        gateway=$(basename "$dir")
        load_gateway_cfg "$gateway"
        state=$(systemctl is-active "nns-gateway@${gateway}.service" 2>/dev/null || true)
        [[ "$state" == active ]] || state=stopped
        endpoint="$PUBLIC_HOST:$PUBLIC_PORT/$LISTEN_PROTO"
        printf '%-18s %-10s %-18s %-26s %s\n' \
            "$gateway" "$state" "$VIA_APP" "$endpoint" "$CLIENT_POOL"
    done
    (( found )) || log "No managed gateways configured."
}


# The --server convenience form creates a direct public gateway with the
# host's normal uplink as its exit. Credentials and service state remain under
# the existing gateway subsystem; no second PKI/service implementation.
server_public_host() {
    local value
    value=$(curl -4fsS --connect-timeout 3 --max-time 7 \
        https://api.ipify.org 2>/dev/null || true)
    if python3 - "$value" <<'PY_SERVER_PUBLIC_IP'
import ipaddress, sys
try:
    ipaddress.IPv4Address(sys.argv[1])
except ipaddress.AddressValueError:
    raise SystemExit(1)
PY_SERVER_PUBLIC_IP
    then
        printf '%s\n' "$value"
        return 0
    fi

    # Offline/captive hosts can still create a server, but must eventually
    # override a private address with their public port-forwarding endpoint.
    value=$(ip -4 route get 1.1.1.1 2>/dev/null | \
        sed -nE 's/.*[[:space:]]src[[:space:]]([0-9.]+).*/\1/p' | head -n1)
    [[ -n "$value" ]] || return 1
    warn "Public IPv4 discovery failed. Using local $value; specify --public for NAT or a cloud ingress."
    printf '%s\n' "$value"
}

# Every configured gateway is a managed app, whether its exit is the host
# or another VPN namespace. Keep the host-only predicate for the legacy
# --server *installation/reconciliation* path, not for lifecycle dispatch.
managed_gateway_exists() {
    local name=${1:-}
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || return 1
    [[ -f "$(gateway_cfg_file "$name")" ]]
}

server_gateway_exists() {
    local name=${1:-}
    managed_gateway_exists "$name" || return 1
    [[ "$(gateway_cfg_value "$name" VIA_APP 2>/dev/null || true)" == host ]]
}

# Idempotent install also reconciles an existing OpenVPN server. In-place
# updates retain its CA, all client keys/certificates, and its tunnel identity.
# A failed update restores the previous settings and (if running) service.
# Restore all mutable state affected by a server transport conversion. The
# private CA, issued certificates and client keys are never modified.
server_restore_reinstall_snapshot() {
    local name=$1 snapshot=$2 root cfg client_file client
    root=$(gateway_dir "$name")
    cp -p "$snapshot/gateway.cfg" "$root/gateway.cfg" || return 1
    if [[ -f "$snapshot/server.conf" ]]; then
        cp -p "$snapshot/server.conf" "$root/server.conf" || return 1
    else
        rm -f "$root/server.conf"
    fi
    if [[ -e "$snapshot/transport" ]]; then
        rm -rf "$root/transport"
        cp -a "$snapshot/transport" "$root/transport" || return 1
    else
        rm -rf "$root/transport"
    fi
    shopt -s nullglob
    for cfg in "$snapshot/client-configs"/*.cfg; do
        client_file=${cfg##*/}
        client=${client_file%.cfg}
        cp -p "$cfg" "$root/clients/$client/client.cfg" || return 1
    done
}

# Idempotent installation/reconciliation of direct and Cloak host OpenVPN
# servers. Preserve PKI, issued identities, fixed IP and per-client routing.
install_openvpn_server() {
    require_root
    local name=$1 listen=${2:-} public=${3:-} pool=${4:-} dns=${5:-}
    local client_to_client=${6:-} requested_transport=${7:-} requested_decoy=${8:-}
    local protocol port public_host current_proto current_port current_public_port old_public_host
    local backup_dir="" changed=off was_active=off conflict_reason=""
    local new_proto new_port new_host new_public_port new_pool new_dns new_c2c
    local old_transport new_transport new_decoy new_backend_port public_proto
    local old_endpoint="" old_listener="" root cfg client client_dir
    validate_gateway_name "$name"
    [[ -z "$client_to_client" ]] || validate_client_to_client "$client_to_client"
    case "$requested_transport" in ''|direct|cloak) ;; *) die "--transport must be direct or cloak." ;; esac
    if [[ -n "$requested_decoy" ]]; then
        validate_transport_server_name "$requested_decoy"
        [[ "$requested_transport" == cloak || -z "$requested_transport" ]] ||
            die "--server-name requires --transport cloak."
    fi
    [[ ! -f "$(cfg_file "$name")" ]] ||
        die "'$name' is an existing namespace app (type vpn-client); remove it before replacing its type."

    acquire_lock global
    ensure_dependencies
    install_engine_files

    if [[ -f "$(gateway_cfg_file "$name")" ]]; then
        server_gateway_exists "$name" ||
            die "'$name' is an existing gateway with a non-host exit; use 'gateway' commands."
        [[ "$(gateway_cfg_value "$name" GATEWAY_BACKEND)" != amneziawg ]] ||
            die "'$name' is an existing AmneziaWG server; reinstall with --server --amnezia."
        load_gateway_cfg "$name"
        case "$TRANSPORT" in direct|cloak) ;;
          *) die "'$name' uses $TRANSPORT, which cannot be reinstalled with --server." ;;
        esac
        old_transport=$TRANSPORT
        new_transport=${requested_transport:-$TRANSPORT}
        new_decoy=${TRANSPORT_SERVER_NAME:-$PUBLIC_HOST}
        if [[ "$new_transport" == cloak ]]; then
            new_decoy=${requested_decoy:-$([[ "$old_transport" == cloak ]] && printf %s "$TRANSPORT_SERVER_NAME" || printf %s www.bing.com)}
            validate_transport_server_name "$new_decoy"
            [[ -n "$(gateway_transport_binary cloak || true)" ]] ||
                die "Cloak requires ck-server on the server (install the trusted Cloak binary before --transport cloak)."
        else
            [[ -z "$requested_decoy" ]] || die "--server-name requires --transport cloak."
        fi
        current_proto=$LISTEN_PROTO
        current_port=$LISTEN_PORT
        current_public_port=$PUBLIC_PORT
        old_public_host=$PUBLIC_HOST
        old_endpoint="$PUBLIC_HOST:$PUBLIC_PORT"
        old_listener="$LISTEN_PROTO:$LISTEN_PORT"
        new_proto=$LISTEN_PROTO
        new_port=$LISTEN_PORT
        new_host=$PUBLIC_HOST
        new_public_port=$PUBLIC_PORT
        new_pool=$CLIENT_POOL
        new_dns=$DNS_SERVERS
        new_c2c=$CLIENT_TO_CLIENT
        new_backend_port=${OPENVPN_LISTEN_PORT:-$LISTEN_PORT}
        if systemctl is-active --quiet "nns-gateway@${name}.service"; then
            was_active=on
        fi

        if [[ -n "$listen" ]]; then
            IFS='|' read -r new_proto new_port <<<"$(parse_gateway_listen "$listen")"
        elif [[ "$old_transport" == direct && "$new_transport" == cloak &&
                "$current_proto" == udp ]]; then
            # Cloak exposes a public TCP listener, and its OpenVPN backend is
            # always private TCP regardless of the original UDP server.
            new_proto=tcp
            new_port=443
        fi
        [[ "$new_transport" != cloak || "$new_proto" == tcp ]] ||
            die "Cloak requires a TCP listener. Use --listen tcp:443 (or another TCP port)."

        if conflict_reason=$(server_listener_conflict "$new_proto" "$new_port" "$name" \
            "$([[ "$was_active" == on && "$new_proto:$new_port" == "$old_listener" ]] && echo on || echo off)"); then
            if [[ -n "$listen" || "$new_transport" == cloak ]]; then
                die "Cannot reinstall '$name': $conflict_reason. Select a free --listen tcp:<port>."
            fi
            listen=$(server_choose_listener "$name")
            IFS='|' read -r new_proto new_port <<<"$(parse_gateway_listen "$listen")"
            warn "Server '$name' cannot use $old_listener ($conflict_reason); switching to $listen."
        fi
        if [[ -z "$public" && "$new_port" != "$current_port" &&
              "$current_public_port" == "$current_port" ]]; then
            new_public_port=$new_port
        fi
        if [[ -n "$public" ]]; then
            IFS='|' read -r new_host new_public_port <<<"$(parse_public_endpoint "$public")"
        fi
        if [[ "$new_transport" == cloak ]]; then
            [[ "$new_decoy" != "$new_host" ]] ||
                die "Cloak --server-name must differ from --public to avoid a redirect loop."
            if [[ "$old_transport" != cloak ]]; then
                new_backend_port=$(gateway_allocate_backend_port "$name")
            fi
        else
            new_decoy=$new_host
            new_backend_port=$new_port
        fi
        if [[ -n "$pool" && "$pool" != "$CLIENT_POOL" ]]; then
            local allocated unused_transit unused_a unused_b
            IFS='|' read -r allocated unused_transit unused_a unused_b \
                <<<"$(allocate_gateway_networks "$pool")"
            [[ "$allocated" == "$pool" ]] || die "Invalid requested client pool '$pool'."
            new_pool=$pool
        fi
        if [[ "$new_pool" != "$CLIENT_POOL" ]]; then
            local old_fixed
            old_fixed=$(gateway_active_fixed_assignments "$(gateway_dir "$name")") ||
                die "Unable to read fixed client assignments for '$name'."
            if [[ -n "$old_fixed" ]]; then
                gateway_fixed_ip_plan "$new_pool" "$old_fixed" >/dev/null ||
                    die "Cannot change client pool of '$name' while fixed IPs are outside the new reserved range."
            fi
        fi
        [[ -z "$dns" ]] || new_dns=$(validate_gateway_dns "$dns")
        [[ -z "$client_to_client" ]] || new_c2c=$client_to_client
        if [[ "$new_proto" != "$LISTEN_PROTO" || "$new_port" != "$LISTEN_PORT" ||
              "$new_host" != "$PUBLIC_HOST" || "$new_public_port" != "$PUBLIC_PORT" ||
              "$new_pool" != "$CLIENT_POOL" || "$new_dns" != "$DNS_SERVERS" ||
              "$new_c2c" != "$CLIENT_TO_CLIENT" || "$new_transport" != "$old_transport" ||
              "$new_decoy" != "${TRANSPORT_SERVER_NAME:-$PUBLIC_HOST}" ]]; then
            changed=on
        fi
        if [[ "$changed" == on ]]; then
            gateway_stop "$name"
            acquire_lock "gateway-$name"
            root=$(gateway_dir "$name")
            backup_dir=$(mktemp -d "$root/.reinstall.XXXXXX")
            cp -p "$root/gateway.cfg" "$backup_dir/gateway.cfg"
            [[ ! -f "$root/server.conf" ]] || cp -p "$root/server.conf" "$backup_dir/server.conf"
            [[ ! -d "$root/transport" ]] || cp -a "$root/transport" "$backup_dir/transport"
            mkdir -p "$backup_dir/client-configs"
            shopt -s nullglob
            for client_dir in "$root/clients"/*; do
                cfg="$client_dir/client.cfg"
                [[ ! -f "$cfg" ]] || cp -p "$cfg" "$backup_dir/client-configs/${client_dir##*/}.cfg"
            done
            gateway_cfg_set "$name" TRANSPORT "$new_transport"
            gateway_cfg_set "$name" LISTEN_PROTO "$new_proto"
            gateway_cfg_set "$name" LISTEN_PORT "$new_port"
            gateway_cfg_set "$name" OPENVPN_LISTEN_PROTO "$([[ "$new_transport" == cloak ]] && echo tcp || echo "$new_proto")"
            gateway_cfg_set "$name" OPENVPN_LISTEN_PORT "$new_backend_port"
            gateway_cfg_set "$name" PUBLIC_HOST "$new_host"
            gateway_cfg_set "$name" PUBLIC_PORT "$new_public_port"
            gateway_cfg_set "$name" TRANSPORT_SERVER_NAME "$new_decoy"
            gateway_cfg_set "$name" CLIENT_POOL "$new_pool"
            gateway_cfg_set "$name" DNS_SERVERS "$new_dns"
            gateway_cfg_set "$name" CLIENT_TO_CLIENT "$new_c2c"
            local prep_ok=on
            if [[ "$new_transport" == cloak ]]; then
                if [[ ! -s "$root/transport/private.key" || ! -s "$root/transport/public.key" ]]; then
                    ( gateway_prepare_transport "$name" "$root" cloak ) || prep_ok=off
                fi
                if [[ "$prep_ok" == on ]]; then
                    ( gateway_cloak_ensure_client_uids "$name" "$root" ) || prep_ok=off
                fi
            fi
            release_lock "gateway-$name"
            if [[ "$prep_ok" != on ]]; then
                acquire_lock "gateway-$name"
                server_restore_reinstall_snapshot "$name" "$backup_dir" ||
                    warn "Could not fully restore '$name' after transport preparation failure."
                release_lock "gateway-$name"
                rm -rf "$backup_dir"
                [[ "$was_active" != on ]] || gateway_start "$name" || true
                release_lock global
                die "Failed to prepare '$name' Cloak configuration; previous settings restored."
            fi
        fi
        write_gateway_unit_dropin "$name"
        systemctl daemon-reload
        systemctl enable "nns-gateway@${name}.service" >/dev/null
        if ! gateway_start "$name"; then
            if [[ "$changed" == on ]]; then
                gateway_stop "$name" >/dev/null 2>&1 || true
                acquire_lock "gateway-$name"
                server_restore_reinstall_snapshot "$name" "$backup_dir" ||
                    warn "Could not fully restore '$name' after failed start."
                release_lock "gateway-$name"
                if [[ "$was_active" == on ]]; then
                    gateway_start "$name" ||
                        warn "Rollback restored '$name' but the previous service failed to restart."
                fi
            fi
            [[ -z "$backup_dir" ]] || rm -rf "$backup_dir"
            release_lock global
            die "Server '$name' could not start. Previous settings were restored if reconfigured."
        fi
        [[ -z "$backup_dir" ]] || rm -rf "$backup_dir"
        log "Reinstalled OpenVPN server '$name' with '$new_transport' transport (CA and client certificates preserved)."
        if [[ "$new_host:$new_public_port" != "$old_endpoint" ||
              "$new_proto:$new_port" != "$old_listener" || "$new_transport" != "$old_transport" ]]; then
            warn "Re-export client profiles: public endpoint or transport changed."
        fi
    else
        new_transport=${requested_transport:-direct}
        if [[ "$new_transport" == cloak ]]; then
            [[ -n "$(gateway_transport_binary cloak || true)" ]] ||
                die "Cloak requires ck-server on the server (install Cloak first)."
            listen=${listen:-tcp:443}
            new_decoy=${requested_decoy:-www.bing.com}
            validate_transport_server_name "$new_decoy"
        else
            [[ -z "$requested_decoy" ]] || die "--server-name requires --transport cloak."
            listen=${listen:-$(server_choose_listener "$name")}
            new_decoy=""
        fi
        IFS='|' read -r protocol port <<<"$(parse_gateway_listen "$listen")"
        [[ "$new_transport" != cloak || "$protocol" == tcp ]] ||
            die "Cloak requires --listen tcp:<port>, for example tcp:443."
        if conflict_reason=$(server_listener_conflict "$protocol" "$port" "$name"); then
            die "Cannot install '$name': $conflict_reason. Use a different --listen port."
        fi
        if [[ -z "$public" ]]; then
            public_host=$(server_public_host) ||
                die "Cannot discover host IPv4. Pass --public <host>:<port>."
            public="$public_host:$port"
        fi
        if [[ "$new_transport" == cloak ]]; then
            IFS='|' read -r public_host public_proto <<<"$(parse_public_endpoint "$public")"
            [[ "$new_decoy" != "$public_host" ]] ||
                die "Cloak --server-name must differ from --public to avoid a redirect loop."
        fi
        gateway_create "$name" host "$listen" "$public" "$pool" \
            "${dns:-1.1.1.1 9.9.9.9}" "$new_transport" "$new_decoy" modern "${client_to_client:-off}"
        load_gateway_cfg "$name"
        new_host=$PUBLIC_HOST
        new_public_port=$PUBLIC_PORT
        systemctl enable "nns-gateway@${name}.service" >/dev/null
        if ! gateway_start "$name"; then
            release_lock global
            die "OpenVPN server '$name' was installed but failed to start; inspect: nns-app status $name"
        fi
    fi
    release_lock global
    log "OpenVPN server '$name' is enabled at boot."
    if [[ "$new_transport" == cloak ]]; then
        log "Cloak listener: $new_host:$new_public_port/tcp (private OpenVPN backend)."
        log "Create client: nns-app export ovpn $name --client laptop --split-tunnel --output laptop.ovpn"
        log "Cloak client requires ck-client on macOS in addition to Tunnelblick."
    else
        log "Create client: nns-app export ovpn $name --client laptop --output laptop.ovpn"
    fi
    log "Check status:   nns-app status $name"
}

gateway_set_client_to_client() {
    require_root
    local gateway=$1 requested=$2 previous was_active=off
    validate_gateway_name "$gateway"
    validate_client_to_client "$requested"
    load_gateway_cfg "$gateway"
    previous=$CLIENT_TO_CLIENT
    if [[ "$requested" == "$previous" ]]; then
        log "Gateway '$gateway': client-to-client is already $requested."
        return 0
    fi

    if systemctl is-active --quiet "nns-gateway@${gateway}.service"; then
        was_active=on
    fi
    acquire_lock "gateway-$gateway"
    gateway_cfg_set "$gateway" CLIENT_TO_CLIENT "$requested"
    release_lock "gateway-$gateway"

    # Regeneration is also necessary for a stopped gateway so a later start
    # cannot accidentally reuse the previous policy from server.conf.
    if [[ "$was_active" == on ]]; then
        if ! gateway_start "$gateway"; then
            warn "Failed to apply client-to-client=$requested to '$gateway'; restoring $previous."
            gateway_cfg_set "$gateway" CLIENT_TO_CLIENT "$previous"
            gateway_write_server_config "$gateway" || true
            gateway_start "$gateway" ||
                warn "Gateway '$gateway' could not be restarted after rollback."
            return 1
        fi
    elif ! gateway_write_server_config "$gateway"; then
        gateway_cfg_set "$gateway" CLIENT_TO_CLIENT "$previous"
        gateway_write_server_config "$gateway" || true
        die "Could not regenerate OpenVPN configuration for '$gateway'."
    fi
    log "Gateway '$gateway': client-to-client is now $requested."
}

gateway_show_client_to_client() {
    local gateway=$1
    load_gateway_cfg "$gateway"
    printf '%s: client-to-client=%s\n' "$gateway" "$CLIENT_TO_CLIENT"
}

server_export_ovpn() {
    require_root
    local gateway=$1 client=$2 output=$3 public=$4 proto=$5 compat=$6 fixed_ip=${7:-off} route_mode=${8:-keep}
    managed_gateway_exists "$gateway" || die "VPN server/gateway '$gateway' does not exist."
    load_gateway_cfg "$gateway"
    [[ "$GATEWAY_BACKEND" == openvpn ]] ||
        die "App '$gateway' is an AmneziaWG server; export an AWG profile using 'nns-app export awg'."
    [[ "$compat" == modern && "$OPENVPN_COMPAT" == modern ]] ||
        die "This server uses modern OpenVPN profiles; --embedded is not supported."
    [[ "$public" == - || "$public" == "$PUBLIC_HOST:$PUBLIC_PORT" ]] ||
        die "Server public endpoint is $PUBLIC_HOST:$PUBLIC_PORT; export override is not supported."
    [[ "$proto" == auto || "$proto" == "$LISTEN_PROTO" ]] ||
        die "Server listener uses $LISTEN_PROTO, not $proto."
    if [[ "$TRANSPORT" == cloak && "$output" == - ]]; then
        die "Cloak needs a .ovpn and a .cloak.json file; pass --output <name>.ovpn."
    fi
    if [[ ! -e "$(gateway_client_dir "$gateway" "$client")" ]]; then
        # Keep stdout pure so --output - can safely be redirected to an .ovpn.
        gateway_client_add "$gateway" "$client" >&2
    fi
    if [[ "$fixed_ip" == on ]]; then
        gateway_client_fixed_ip "$gateway" "$client" on >&2
    fi
    if [[ "$route_mode" != keep ]]; then
        gateway_client_route_mode "$gateway" "$client" "$route_mode" >&2
    fi
    if [[ "$TRANSPORT" == cloak ]]; then
        gateway_cloak_export_client_pair "$gateway" "$client" "$output"
    else
        gateway_client_export "$gateway" "$client" "$output" ovpn
    fi
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
    load_gateway_cfg "$gateway"

    # gateway_stop/ExecStopPost normally performs this cleanup already.  Do it
    # again under the removal lock and require success before deleting the
    # gateway configuration; otherwise a stale persistent firewall exception
    # could become impossible for nns-app to identify and retry later.
    if ! gateway_public_firewall_down "$gateway"; then
        release_lock "gateway-$gateway"
        release_lock global
        die "Could not remove the host-firewall rule for gateway '$gateway'; configuration was preserved for a safe retry."
    fi

    systemctl disable "nns-gateway@${gateway}.service" \
        >/dev/null 2>&1 || true
    firewalld_interface_remove "$GATEWAY_TUN"
    firewalld_interface_remove "$GATEWAY_VETH_HOST"
    rm -rf \
        "$(gateway_dropin_dir "$gateway")" \
        "$(gateway_dir "$gateway")" \
        "$(gateway_runtime_dir "$gateway")"
    systemctl daemon-reload

    release_lock "gateway-$gateway"
    release_lock global
    log "Removed managed server '$gateway', including all managed client private keys."
}

