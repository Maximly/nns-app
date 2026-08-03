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
    local pki=$1 backup=$2 optional
    install -d -o root -g root -m 0700 "$backup"
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
    log "  sudo nns-app gateway client export $gateway $client --output /path/to/$gateway-$client.ovpn"
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

