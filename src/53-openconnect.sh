# nns-app source module: OpenConnect/AnyConnect profile handling and runtime.
# OpenConnect is a generic backend: the AnyConnect protocol is the first
# validated one, and the same plumbing serves nc/pulse/gp/fortinet/f5/array.
# The profile format is nns-app's own key=value convention (`.oc`), not a
# Cisco or OpenConnect native format. Imported profiles are untrusted input:
# only a fixed allow-list of directives is accepted, helper scripts named by
# the profile are rejected, and the gateway URL is the only endpoint.

# Deterministic per-app TUN name. The `tun` prefix keeps the existing `tun+`
# firewall wildcard valid, and the suffix makes the interface unique and
# predictable inside the app's own network namespace.
openconnect_iface_name() {
    local app=$1 crc hex
    crc=$(printf '%s' "$app" | cksum | awk '{print $1}')
    printf -v hex '%08x' "$crc"
    printf 'tun%s\n' "$hex"
}

# The session cookie saved by `nns-app oc-login` lives next to the managed
# profile, root-owned and 0600 like every other credential material.
anyconnect_cookie_path() {
    local app=$1 profile
    profile=$(cfg_read_value "$app" DEFAULT_PROFILE 2>/dev/null || true)
    [[ -n "$profile" ]] || return 1
    printf '%s/%s.cookie\n' "$(profiles_dir "$app")" "$profile"
}

anyconnect_profile_value() {
    local file=$1 key=${2,,}
    awk -F= -v wanted="$key" '
        BEGIN { inblock=0 }
        { gsub(/\r/, "") }
        /^[[:space:]]*<(cert|key)>[[:space:]]*$/ { inblock=1; next }
        /^[[:space:]]*<\/(cert|key)>[[:space:]]*$/ { inblock=0; next }
        inblock { next }
        /^[[:space:]]*#/ { next }
        {
            k=$1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k)
            k=tolower(k)
            # `password=` is an accepted alias for `passwd=`.
            if (k == "password") k = "passwd"
            if (k == wanted) {
                v=substr($0, index($0, "=") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                # Inline comments: `key=value  # note` is allowed. A value
                # containing " #" is therefore not representable; passwords
                # with that substring must be avoided (use oc-login).
                sub(/[[:space:]]+#.*$/, "", v)
                gsub(/[[:space:]]+$/, "", v)
                print v
                exit
            }
        }
    ' "$file"
}

# Extract the body of an inline <cert>/<key> PEM block without the markers.
anyconnect_pem_block() {
    local file=$1 tag=$2 body
    body=$(sed -n "/^[[:space:]]*<$tag>[[:space:]]*$/,\
/^[[:space:]]*<\/$tag>[[:space:]]*$/p" "$file" | tr -d '\r' | sed '1d;$d')
    printf '%s\n' "$body"
}

anyconnect_pem_block_valid() {
    local file=$1 tag=$2 body first last middle
    body=$(anyconnect_pem_block "$file" "$tag")
    [[ -n "$body" ]] || return 1
    first=$(printf '%s\n' "$body" | sed -n '1p')
    last=$(printf '%s\n' "$body" | sed -n '$p')
    [[ "$first" =~ ^-----BEGIN[[:space:]]+(CERTIFICATE|RSA PRIVATE KEY|EC PRIVATE KEY|ENCRYPTED PRIVATE KEY|PRIVATE KEY)-----$ ]] || return 1
    [[ "$last" =~ ^-----END[[:space:]]+(CERTIFICATE|RSA PRIVATE KEY|EC PRIVATE KEY|ENCRYPTED PRIVATE KEY|PRIVATE KEY)-----$ ]] || return 1
    middle=$(printf '%s\n' "$body" | sed '1d;$d')
    [[ -n "$middle" ]] || return 1
    ! printf '%s\n' "$middle" | grep -Eqv '^[A-Za-z0-9+/=[:space:]]*$' || return 1
    return 0
}

validate_anyconnect() {
    local file=$1 size
    [[ -f "$file" ]] || die "Profile not found: $file"
    [[ -s "$file" ]] || die "Profile is empty: $file"
    size=$(stat -c '%s' "$file" 2>/dev/null || true)
    if [[ "$size" =~ ^[0-9]+$ ]] && (( size <= 65536 )); then
        :
    else
        die "AnyConnect profile is unexpectedly large (>64 KiB) or its size cannot be determined."
    fi

    # Only the documented allow-list is accepted. OpenConnect itself can load
    # options that name helper scripts or external files; an imported profile
    # is untrusted input, so anything else is rejected outright. Duplicate
    # directives are rejected too: the first-match-wins parser must never
    # silently drop a second value. Error lines name the key only, never the
    # value (credentials must not leak into stderr or the service journal).
    if ! awk '
        BEGIN { inblock=0; bad=0
            allowed = "^(protocol|server|user|passwd|authgroup|fingerprint|"
            allowed = allowed "token-mode|token-secret|route-mode|mtu|useragent)$"
        }
        { gsub(/\r/, "") }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*<(cert|key)>[[:space:]]*$/ {
            if (inblock) { print "nested inline block: " $0 > "/dev/stderr"; bad=1; next }
            inblock=1; next
        }
        /^[[:space:]]*<\/(cert|key)>[[:space:]]*$/ {
            if (!inblock) { print "unmatched inline block end: " $0 > "/dev/stderr"; bad=1; next }
            inblock=0; next
        }
        inblock { next }
        {
            key=$1; sub(/=.*/, "", key); key=tolower(key)
            # `password=` is an accepted alias for `passwd=`; declaring both
            # is ambiguous and rejected as a duplicate.
            if (key == "password") key = "passwd"
            if (key !~ allowed) {
                print "unsupported directive: " key > "/dev/stderr"
                bad=1
            } else if (seen[key]++) {
                print "duplicate directive: " key > "/dev/stderr"
                bad=1
            }
        }
        END { exit bad }
    ' "$file"; then
        die "AnyConnect profile contains unsupported directives; only protocol, server, user, passwd (or password), authgroup, fingerprint, token-mode, token-secret, route-mode, mtu, useragent and inline <cert>/<key> blocks are allowed."
    fi

    local server proto user passwd authgroup fingerprint tmode tsec rmode mtu ua
    local host port

    server=$(anyconnect_profile_value "$file" server)
    [[ -n "$server" ]] || die "AnyConnect profile has no 'server=' entry."
    if [[ "$server" =~ ^https://([A-Za-z0-9.-]+)(:([0-9]{1,5}))?(/)?$ ]] ||
       [[ "$server" =~ ^https://([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})(:([0-9]{1,5}))?(/)?$ ]]; then
        host=${BASH_REMATCH[1]}
        port=${BASH_REMATCH[3]:-443}
    else
        die "Invalid AnyConnect server URL '$server'; use https://host[:port]."
    fi
    (( port >= 1 && port <= 65535 )) ||
        die "AnyConnect server port must be within 1..65535 in '$server'."

    proto=$(anyconnect_profile_value "$file" protocol)
    [[ -n "$proto" ]] || proto=anyconnect
    case "$proto" in
        anyconnect|nc|pulse|gp|fortinet|f5|array) ;;
        *) die "Unsupported OpenConnect protocol '$proto'; expected one of anyconnect, nc, pulse, gp, fortinet, f5, array." ;;
    esac

    user=$(anyconnect_profile_value "$file" user)
    if [[ -n "$user" ]]; then
        [[ "$user" =~ ^[A-Za-z0-9@._-]{1,128}$ ]] ||
            die "Invalid AnyConnect username in profile."
    fi

    passwd=$(anyconnect_profile_value "$file" passwd)
    if [[ -n "$passwd" ]]; then
        # Printable ASCII only; the length is checked separately because
        # some regex engines cap repetition bounds at 255.
        if [[ ! "$passwd" =~ ^[[:print:]]+$ || "$passwd" =~ [[:cntrl:]] ]] ||
           (( ${#passwd} > 256 )); then
            die "Invalid AnyConnect password in profile (printable characters only, no tabs, max 256)."
        fi
    fi

    authgroup=$(anyconnect_profile_value "$file" authgroup)
    if [[ -n "$authgroup" ]]; then
        grep -Eq '^[A-Za-z0-9][A-Za-z0-9 ._@/()-]{0,126}$' <<<"$authgroup" ||
            die "Invalid AnyConnect auth group in profile."
    fi

    fingerprint=$(anyconnect_profile_value "$file" fingerprint)
    if [[ -n "$fingerprint" ]]; then
        local fp_kind=${fingerprint%%:*} fp_body=${fingerprint#*:}
        case "${fp_kind^^}" in
            SHA1)   [[ "$fp_body" =~ ^([0-9A-Fa-f]{2}:){19}[0-9A-Fa-f]{2}$ ]] ||
                        die "Invalid SHA1 fingerprint in profile; use SHA1:<hex pairs separated by colons>." ;;
            SHA256) [[ "$fp_body" =~ ^([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2}$ ]] ||
                        die "Invalid SHA256 fingerprint in profile; use SHA256:<hex pairs separated by colons>." ;;
            PIN-SHA256)
                # The format openconnect itself prints in its certificate
                # error message: a base64-encoded SHA-256 digest.
                [[ "$fp_body" =~ ^[A-Za-z0-9+/]{40,48}={0,2}$ ]] ||
                    die "Invalid pin-sha256 fingerprint in profile; use the value shown in openconnect's certificate error." ;;
            *) die "Invalid fingerprint kind '${fp_kind}'; use SHA1:, SHA256: or pin-sha256:." ;;
        esac
    fi

    tmode=$(anyconnect_profile_value "$file" token-mode)
    if [[ -n "$tmode" ]]; then
        case "$tmode" in
            rsa|totp|hotp|oidc|yubioath) ;;
            *) die "Unsupported token-mode '$tmode'; expected one of rsa, totp, hotp, oidc, yubioath." ;;
        esac
    fi

    tsec=$(anyconnect_profile_value "$file" token-secret)
    if [[ -n "$tsec" ]]; then
        [[ "$tsec" =~ ^(base32|hotp):[A-Za-z2-7]{16,128}$ ]] ||
            die "Invalid token-secret in profile; use base32:<secret> (TOTP) or hotp:<secret>."
    fi

    rmode=$(anyconnect_profile_value "$file" route-mode)
    if [[ -n "$rmode" ]]; then
        case "$rmode" in
            split|full) ;;
            *) die "Invalid route-mode '$rmode'; use split or full." ;;
        esac
    fi

    mtu=$(anyconnect_profile_value "$file" mtu)
    if [[ -n "$mtu" ]]; then
        [[ "$mtu" =~ ^[0-9]{3,4}$ ]] && (( mtu >= 576 && mtu <= 9000 )) ||
            die "Invalid AnyConnect mtu '$mtu'; use 576..9000."
    fi

    ua=$(anyconnect_profile_value "$file" useragent)
    if [[ -n "$ua" ]]; then
        grep -Eq '^[A-Za-z0-9][A-Za-z0-9 .()/_-]{7,127}$' <<<"$ua" ||
            die "Invalid AnyConnect useragent in profile."
    fi

    # Client certificates must be fully embedded. Both blocks are required
    # together, each exactly once, so an imported profile can never make root
    # read an arbitrary host file through a sidecar path reference.
    local has_cert has_key
    # grep -c exits 1 on zero matches, which must not abort the validator.
    has_cert=$(grep -Eic '^[[:space:]]*<cert>[[:space:]]*$' "$file" || true)
    has_key=$(grep -Eic '^[[:space:]]*<key>[[:space:]]*$' "$file" || true)
    if (( has_cert != has_key )) || (( has_cert > 1 )); then
        die "AnyConnect client certificates must embed exactly one <cert> and one <key> block."
    fi
    if (( has_cert == 1 )); then
        anyconnect_pem_block_valid "$file" cert ||
            die "AnyConnect <cert> block does not contain a valid PEM certificate."
        anyconnect_pem_block_valid "$file" key ||
            die "AnyConnect <key> block does not contain a valid PEM private key."
    fi
}

# Routing for AnyConnect is pushed by the gateway at connect time, so the
# profile itself carries no client-side networks. The functions below keep
# the generic dispatchers uniform.
anyconnect_profile_networks() {
    return 0
}

anyconnect_profile_route_sample() {
    return 1
}

anyconnect_profile_dns_policy() {
    return 0
}

anyconnect_profile_route_mode() {
    local profile=$1 mode
    mode=$(anyconnect_profile_value "$profile" route-mode)
    if [[ "$mode" == split ]]; then
        printf 'split\n'
    else
        printf 'full\n'
    fi
}

# Endpoint lines for the kill switch and inventory: the gateway host with
# TLS (TCP) and DTLS (UDP) on the configured port. Output: host|port|proto.
anyconnect_endpoint_lines() {
    local file=$1 server host port
    server=$(anyconnect_profile_value "$file" server)
    [[ -n "$server" ]] || return 1
    host=${server#https://}
    host=${host%/}
    port=443
    if [[ "$host" == *:* ]]; then
        port=${host##*:}
        host=${host%:*}
    fi
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || return 1
    printf '%s|%s|tcp\n' "$host" "$port"
    printf '%s|%s|udp\n' "$host" "$port"
}

ipv4_address_valid() {
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    awk -F. 'BEGIN{ok=1} {for(i=1;i<=4;i++) if ($i<0||$i>255) ok=0} END{exit !ok}' <<<"$1"
}

# Convert a dotted-quad netmask to a prefix length by counting set bits.
# Non-contiguous masks (invalid as netmasks) print "invalid" so callers can
# refuse them instead of installing a bogus route.
ipv4_netmask_prefix() {
    awk -F. '{
        p=0; seen=0; bad=0
        for(i=1;i<=4;i++){
            v=$i+0
            for(b=7;b>=0;b--){
                bit=(v >= 2^b) ? 1 : 0
                if (bit) v -= 2^b
                if (bit && seen) bad=1
                if (!bit) seen=1
                if (bit) p++
            }
        }
        print (bad ? "invalid" : p)
    }' <<<"$1"
}

# OpenConnect runs the hook inside the app's network namespace; refuse to
# configure anything if that invariant is broken (never touch the host).
openconnect_hook_ns_ok() {
    local current_ns named_ns
    current_ns=$(stat -Lc '%d:%i' /proc/self/ns/net 2>/dev/null || true)
    named_ns=$(stat -Lc '%d:%i' "/run/netns/$NS_NAME" 2>/dev/null || true)
    [[ -n "$current_ns" && "$current_ns" == "$named_ns" ]]
}

# vpnc-script replacement. openconnect runs the script via `/bin/sh -c` and
# passes the reason in the `reason` environment variable (not as an argv
# argument); the dispatcher forwards it, and older argv-based callers remain
# supported via the $2 fallback. TUNDEV / INTERNAL_IP4_* / CISCO_* arrive in
# the environment.
openconnect_hook() {
    local app=$1 dev=${TUNDEV:-} env_reason=${reason:-}
    local reason=${2:-}
    [[ -n "$reason" ]] || reason=$env_reason
    [[ -n "$dev" ]] || dev=$(openconnect_iface_name "$app")
    validate_app_name "$app"
    load_cfg "$app"
    case "$reason" in
        pre-init)
            # openconnect calls this BEFORE the TUN device exists; the real
            # configuration happens on connect/reconnect.
            return 0
            ;;
        connect|reconnect) openconnect_hook_up "$app" "$dev" ;;
        disconnect) openconnect_hook_down "$app" "$dev" ;;
        *)
            warn "OpenConnect hook for '$app' received unknown reason '$reason'."
            return 0
            ;;
    esac
}

# Write the pushed DNS resolvers into the namespace's resolv.conf file.
# Values come from the gateway and are untrusted: only validated IPv4
# addresses and a well-formed search domain survive.
openconnect_hook_write_resolv() {
    local app=$1
    shift
    local target search dns tmp
    target=$(namespace_resolv_conf_path)
    install -d -o root -g root -m 0755 "$(dirname -- "$target")" 2>/dev/null || return 1
    search=${CISCO_DEF_DOMAIN:-}
    [[ "$search" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || search=
    tmp=$(mktemp "${target}.XXXXXX")
    {
        for dns in "$@"; do
            [[ -n "$dns" ]] && printf 'nameserver %s\n' "$dns"
        done
        [[ -z "$search" ]] || printf 'search %s\n' "$search"
        printf 'options timeout:2 attempts:2 rotate\n'
    } >"$tmp"
    chmod 0644 "$tmp"
    mv -f "$tmp" "$target"
}

openconnect_hook_up() {
    local app=$1 dev=$2 prefix mtu ip mask
    local -a dns_servers=()
    local split=0

    [[ "$dev" =~ ^[A-Za-z0-9._-]{1,15}$ ]] || {
        warn "AnyConnect hook received an invalid interface name."
        return 1
    }
    if ! openconnect_hook_ns_ok; then
        warn "'$app': AnyConnect hook is not in the expected network namespace; refusing to configure '$dev'."
        return 0
    fi

    ip=${INTERNAL_IP4_ADDRESS:-}
    ipv4_address_valid "$ip" || {
        warn "'$app': AnyConnect hook received no usable IPv4 address."
        return 1
    }

    # openconnect supplies the netmask either as a prefix length or as a
    # dotted quad depending on version and protocol family.
    mask=${INTERNAL_IP4_NETMASK:-}
    if [[ "$mask" =~ ^[0-9]{1,2}$ ]] && (( mask <= 32 )); then
        prefix=$mask
    elif [[ "$mask" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        prefix=$(ipv4_netmask_prefix "$mask")
        [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || prefix=32
    else
        prefix=32
    fi

    # The server-negotiated MTU applies unless a validated TUN_MTU was
    # measured and saved by the MTU auto-repair machinery.
    mtu=${INTERNAL_IP4_MTU:-}
    if [[ "$mtu" =~ ^[0-9]{3,4}$ ]] && (( mtu >= 576 && mtu <= 9000 )); then
        :
    else
        mtu=
    fi
    if [[ "${TUN_MTU:-}" =~ ^[0-9]+$ ]] &&
       (( TUN_MTU >= 576 && TUN_MTU <= 1500 )); then
        mtu=$TUN_MTU
    fi

    ip addr flush dev "$dev" 2>/dev/null || true
    ip -4 addr add "$ip/$prefix" dev "$dev" ||
        { warn "'$app': could not assign $ip/$prefix to '$dev'."; return 1; }
    if [[ -n "$mtu" ]]; then
        ip link set dev "$dev" mtu "$mtu" 2>/dev/null || true
    fi
    ip link set dev "$dev" up ||
        { warn "'$app': could not bring up '$dev'."; return 1; }

    # Split-tunnel includes are CISCO_SPLIT_INC_<n>_ADDR with an optional
    # _MASK (dotted) or _MASKLEN (prefix). With none pushed, the gateway
    # expects a full tunnel and the default route belongs to the TUN.
    local split_vars
    split_vars=$(compgen -A variable | grep -E '^CISCO_SPLIT_INC_[0-9]+_ADDR$' || true)
    if [[ -n "$split_vars" ]]; then
        split=1
        local key n addr mlen msk p
        while IFS= read -r key; do
            n=${key#CISCO_SPLIT_INC_}
            n=${n%_ADDR}
            addr=${!key:-}
            mlen="CISCO_SPLIT_INC_${n}_MASKLEN"
            msk="CISCO_SPLIT_INC_${n}_MASK"
            if [[ "${!mlen:-}" =~ ^[0-9]{1,2}$ ]] && (( ${!mlen} <= 32 )); then
                p=${!mlen}
            elif [[ "${!msk:-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
                p=$(ipv4_netmask_prefix "${!msk}")
            else
                p=32
            fi
            if ipv4_address_valid "$addr"; then
                ip -4 route replace "$addr/$p" dev "$dev" 2>/dev/null ||
                    warn "'$app': could not install pushed split route $addr/$p via '$dev'."
            fi
        done <<<"$split_vars"
    else
        ip -4 route replace default dev "$dev" 2>/dev/null ||
            warn "'$app': could not install the default route via '$dev'."
    fi

    # The engine keeps IFS=$'\n\t' globally, so split the space-separated
    # DNS list explicitly (openconnect's INTERNAL_IP4_DNS convention).
    local -a dns_tokens=()
    IFS=' ' read -r -a dns_tokens <<<"${INTERNAL_IP4_DNS:-}"
    for dns in "${dns_tokens[@]}"; do
        ipv4_address_valid "$dns" && dns_servers+=("$dns")
    done
    if (( ${#dns_servers[@]} )); then
        openconnect_hook_write_resolv "$app" "${dns_servers[@]}" ||
            warn "'$app': could not write the pushed DNS resolvers."
    fi

    install -d -o root -g root -m 0755 "$(openconnect_state_dir)"
    printf '%s\n' "$dev" >"$(openconnect_state_dir)/${app}.oc-ready"
    chmod 0644 "$(openconnect_state_dir)/${app}.oc-ready"
    if (( split )); then
        : >"$(openconnect_state_dir)/${app}.oc-split"
        chmod 0644 "$(openconnect_state_dir)/${app}.oc-split"
    else
        rm -f "$(openconnect_state_dir)/${app}.oc-split"
    fi
    log "'$app': AnyConnect tunnel '$dev' is up ($ip/$prefix)."
    return 0
}

openconnect_hook_down() {
    local app=$1 dev=$2
    [[ "$dev" =~ ^[A-Za-z0-9._-]{1,15}$ ]] || return 0
    rm -f "$(openconnect_state_dir)/${app}.oc-ready" \
          "$(openconnect_state_dir)/${app}.oc-split"
    if openconnect_hook_ns_ok; then
        ip link set dev "$dev" down 2>/dev/null || true
        ip link del dev "$dev" 2>/dev/null || true
    fi
    # Restore bootstrap DNS so a fresh connection can resolve the gateway
    # from the namespace's original resolvers before the tunnel is up.
    reset_namespace_bootstrap_dns "$app" 2>/dev/null || true
    return 0
}

openconnect_exec() {
    local app=$1 profile=$2 oc_bin ip_bin
    local -a args=()
    local server proto user passwd authgroup fingerprint tmode tsec ua cookie creds certdir
    # The app name is interpolated into the --script command string; validate
    # it here too instead of relying on the caller (defense in depth).
    validate_app_name "$app"
    load_cfg "$app"
    validate_anyconnect "$profile"
    oc_bin=$(openconnect_binary)
    ip_bin=$(ip_binary)

    server=$(anyconnect_profile_value "$profile" server)
    proto=$(anyconnect_profile_value "$profile" protocol)
    [[ -n "$proto" ]] || proto=anyconnect
    user=$(anyconnect_profile_value "$profile" user)
    passwd=$(anyconnect_profile_value "$profile" passwd)
    authgroup=$(anyconnect_profile_value "$profile" authgroup)
    fingerprint=$(anyconnect_profile_value "$profile" fingerprint)
    tmode=$(anyconnect_profile_value "$profile" token-mode)
    tsec=$(anyconnect_profile_value "$profile" token-secret)
    ua=$(anyconnect_profile_value "$profile" useragent)

    args+=("$oc_bin" --non-inter --protocol "$proto")
    # OpenConnect requires a vpnc-script. The engine supplies its own hook:
    # addresses, routes, MTU and namespace DNS are applied only inside the
    # app's network namespace; host networking is never modified.
    args+=(--script "$ENGINE_PATH _oc-hook $app")
    args+=(--interface "$(openconnect_iface_name "$app")")
    [[ -n "$authgroup" ]] && args+=(--authgroup "$authgroup")
    [[ -n "$fingerprint" ]] && args+=(--servercert "$fingerprint")
    [[ -n "$tmode" ]] && args+=(--token-mode "$tmode")
    [[ -n "$tsec" ]] && args+=(--token-secret "$tsec")
    [[ -n "$ua" ]] && args+=(--useragent "$ua")
    if [[ "${TUN_MTU:-}" =~ ^[0-9]+$ ]] &&
       (( TUN_MTU >= 576 && TUN_MTU <= 1500 )); then
        args+=(--mtu "$TUN_MTU")
    fi

    if grep -Eiq '^[[:space:]]*<(cert|key)>[[:space:]]*$' "$profile"; then
        # Embedded PEM blocks are materialized into a root-only runtime
        # directory; a stale copy from a crashed session is replaced here.
        certdir="$RUN_DIR/${app}.oc-certs"
        rm -rf "$certdir"
        install -d -o root -g root -m 0700 "$certdir"
        anyconnect_pem_block "$profile" cert >"$certdir/cert.pem"
        anyconnect_pem_block "$profile" key >"$certdir/key.pem"
        chown root:root "$certdir/cert.pem" "$certdir/key.pem"
        chmod 0600 "$certdir/cert.pem" "$certdir/key.pem"
        args+=(--certificate "$certdir/cert.pem" --sslkey "$certdir/key.pem")
    fi

    # A saved session cookie (from `nns-app oc-login`) survives unattended
    # restarts until the gateway expires it. Otherwise inline credentials
    # are used; without either, the managed service cannot authenticate.
    cookie=$(anyconnect_cookie_path "$app" 2>/dev/null || true)
    if [[ -n "$cookie" && -s "$cookie" ]]; then
        log "Using the saved AnyConnect session cookie for '$app'."
        args+=(--cookie-on-stdin)
        creds=$(<"$cookie")
    elif [[ -n "$user" && -n "$passwd" ]]; then
        args+=(--user "$user" --passwd-on-stdin)
        creds=$(printf '%s\n%s\n' "$user" "$passwd")
    else
        die "No AnyConnect credentials are available for '$app'. Run: nns-app oc-login $app (interactive), or set user=/passwd= in the profile."
    fi

    # Resolve the gateway from bootstrap DNS before the tunnel replaces it.
    reset_namespace_bootstrap_dns "$app" 2>/dev/null || true
    install -d -o root -g root -m 0755 "$RUN_DIR"
    # exec keeps openconnect as the service main process, so SIGTERM
    # teardown and Restart=on-failure behave exactly like the OpenVPN
    # backend. The here-string carries credentials/cookie on stdin only.
    exec "$ip_bin" netns exec "$NS_NAME" "${args[@]}" "$server" <<<"$creds"
}

# Where the hook records per-session state. A tiny indirection so unit tests
# can redirect the root-owned runtime directory without touching production
# paths; normal execution always uses the fixed $RUN_DIR.
openconnect_state_dir() {
    printf '%s\n' "$RUN_DIR"
}

# Write a validated session cookie next to the managed profile, root 0600.
anyconnect_save_cookie() {
    local app=$1 cookie=$2 cookiefile tmp
    cookiefile=$(anyconnect_cookie_path "$app") ||
        die "Cannot determine the AnyConnect cookie path for '$app'."
    install -d -o root -g root -m 0755 "$(dirname -- "$cookiefile")"
    tmp=$(mktemp "${cookiefile}.XXXXXX")
    # Never leave a half-written cookie or a stray temp file behind.
    if ! printf '%s' "$cookie" >"$tmp" ||
       ! chown root:root "$tmp" ||
       ! chmod 0600 "$tmp" ||
       ! mv -f "$tmp" "$cookiefile"; then
        rm -f "$tmp"
        die "Could not store the AnyConnect session cookie for '$app'."
    fi
}

# Detect a failed or expired authentication in the current service log so
# the watchdog can stop restarting a backend that needs user interaction.
anyconnect_auth_failure_detected() {
    local app=$1
    journalctl -u "nns-openvpn@${app}.service" -n 60 -o cat --no-pager 2>/dev/null |
        grep -Eqi 'Login failed|Failed to obtain WebVPN cookie|authentication failed|not authorized|is no longer valid|401 Unauthorized'
}

# Certificate verification failures are equally deterministic: no restart can
# fix an untrusted or rotated gateway certificate. Classify them separately so
# the watchdog reports the right remedy instead of restarting the backend.
anyconnect_cert_failure_detected() {
    local app=$1
    journalctl -u "nns-openvpn@${app}.service" -n 60 -o cat --no-pager 2>/dev/null |
        grep -Eqi 'certificate.*failed verification|signer not found|self.signed|certificate verify failed'
}

# `nns-app oc-login <app>`: interactive or scripted authentication that
# stores the resulting session cookie without ever touching the tunnel.
openconnect_login() {
    require_root
    local app=$1 profile type oc_bin
    local -a args=()
    local server proto user passwd authgroup fingerprint tmode tsec ua
    local output cookie certdir
    validate_app_name "$app"
    load_cfg "$app"
    type=$(vpn_type_for_app "$app" 2>/dev/null || true)
    [[ "$type" == anyconnect ]] ||
        die "App '$app' does not use an AnyConnect profile."
    [[ -n "${DEFAULT_PROFILE:-}" ]] ||
        die "No AnyConnect profile is configured for '$app'."
    profile="$(profiles_dir "$app")/$DEFAULT_PROFILE"
    [[ -f "$profile" ]] || die "AnyConnect profile is missing: $profile"
    validate_anyconnect "$profile"
    oc_bin=$(openconnect_binary)

    server=$(anyconnect_profile_value "$profile" server)
    proto=$(anyconnect_profile_value "$profile" protocol)
    [[ -n "$proto" ]] || proto=anyconnect
    user=$(anyconnect_profile_value "$profile" user)
    passwd=$(anyconnect_profile_value "$profile" passwd)
    authgroup=$(anyconnect_profile_value "$profile" authgroup)
    fingerprint=$(anyconnect_profile_value "$profile" fingerprint)
    tmode=$(anyconnect_profile_value "$profile" token-mode)
    tsec=$(anyconnect_profile_value "$profile" token-secret)
    ua=$(anyconnect_profile_value "$profile" useragent)

    [[ -n "$user" ]] ||
        die "AnyConnect profile for '$app' has no 'user=' entry; add one before oc-login."

    args+=("$oc_bin" --authenticate --quiet --protocol "$proto" --user "$user")
    [[ -n "$authgroup" ]] && args+=(--authgroup "$authgroup")
    [[ -n "$fingerprint" ]] && args+=(--servercert "$fingerprint")
    [[ -n "$tmode" ]] && args+=(--token-mode "$tmode")
    [[ -n "$tsec" ]] && args+=(--token-secret "$tsec")
    [[ -n "$ua" ]] && args+=(--useragent "$ua")

    certdir=""
    if grep -Eiq '^[[:space:]]*<(cert|key)>[[:space:]]*$' "$profile"; then
        certdir=$(mktemp -d)
        chmod 0700 "$certdir"
        anyconnect_pem_block "$profile" cert >"$certdir/cert.pem"
        anyconnect_pem_block "$profile" key >"$certdir/key.pem"
        chmod 0600 "$certdir/cert.pem" "$certdir/key.pem"
        args+=(--certificate "$certdir/cert.pem" --sslkey "$certdir/key.pem")
    fi

    # Fully scriptable credentials (inline password and no interactive OTP)
    # authenticate non-interactively; otherwise keep the terminal attached
    # so the user can answer password, push or one-time-code prompts.
    if [[ -n "$passwd" && ( -z "$tmode" || -n "$tsec" ) ]]; then
        output=$(printf '%s\n%s\n' "$user" "$passwd" |
                 "${args[@]}" "$server" 2>/dev/null) || {
            rm -rf "${certdir:-}"
            die "openconnect --authenticate failed for '$app'; check the credentials in the profile."
        }
    else
        log "Authenticating to ${server} for '$app'; answer the prompts shown by openconnect."
        # stderr stays attached to the terminal: openconnect prints password
        # and one-time-code prompts there.
        output=$("${args[@]}" "$server") || {
            rm -rf "${certdir:-}"
            die "openconnect --authenticate failed for '$app'."
        }
    fi
    rm -rf "${certdir:-}"

    cookie=$(grep -E '^COOKIE=' <<<"$output" | tail -n1 | cut -d= -f2-)
    # openconnect prints `COOKIE='<value>'` (single-quoted); accept both the
    # quoted and the legacy unquoted form.
    cookie=${cookie#\'}
    cookie=${cookie%\'}
    if [[ ! "$cookie" =~ ^[A-Za-z0-9+/=_-]+$ ]] ||
       (( ${#cookie} < 8 || ${#cookie} > 4096 )); then
        die "openconnect did not return a valid session cookie for '$app'."
    fi

    anyconnect_save_cookie "$app" "$cookie"
    log "AnyConnect session cookie saved for '$app'."
    log "The backend uses it until the gateway expires the session; re-authenticate with: nns-app oc-login $app"
}
