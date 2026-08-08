# nns-app source module: conservative state and lifecycle reconciliation.
#
# `nns-app repair` fixes only resources whose nns-app ownership can be proven.
# Ambiguous shared-pool or PKI state is reported and left untouched.

REPAIR_FIXED=0
REPAIR_WARNINGS=0
REPAIR_UNRESOLVED=0

repair_fixed() {
    REPAIR_FIXED=$((REPAIR_FIXED + 1))
    printf 'REPAIRED: %s\n' "$*"
}

repair_warning() {
    REPAIR_WARNINGS=$((REPAIR_WARNINGS + 1))
    printf 'WARNING: %s\n' "$*" >&2
}

repair_unresolved() {
    REPAIR_UNRESOLVED=$((REPAIR_UNRESOLVED + 1))
    printf 'UNRESOLVED: %s\n' "$*" >&2
}

# Strict, non-executing reader for automatic-remote state.  All values written
# by remote_auto_write_state() are deliberately restricted to shell-safe
# tokens, so repair never needs to `source` a possibly damaged state file.
repair_remote_state_record() {
    local file=$1 expected_owner=${2:-}
    [[ -f "$file" && ! -L "$file" ]] || return 1
    python3 - "$file" "$expected_owner" <<'PY_REPAIR_REMOTE_STATE'
from __future__ import annotations
import ipaddress
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected = sys.argv[2]
allowed = {
    "OWNER_ID", "POOL_ID", "EXIT_APP", "GATEWAY", "CLIENT",
    "PROVIDER_VPN_IPV4", "PROFILE_SHA256", "ACTIVE",
}
values: dict[str, str] = {}
try:
    lines = path.read_text(encoding="utf-8").splitlines()
except OSError:
    raise SystemExit(1)
for line in lines:
    if not line:
        continue
    m = re.fullmatch(r"([A-Z0-9_]+)=(.*)", line)
    if not m or m.group(1) not in allowed or m.group(1) in values:
        raise SystemExit(1)
    raw = m.group(2)
    if raw == "''":
        value = ""
    elif re.fullmatch(r"[A-Za-z0-9._:/-]*", raw):
        value = raw
    elif len(raw) >= 2 and raw[0] == raw[-1] == "'" and "'" not in raw[1:-1]:
        value = raw[1:-1]
    elif len(raw) >= 2 and raw[0] == raw[-1] == '"' and '"' not in raw[1:-1]:
        value = raw[1:-1]
    else:
        raise SystemExit(1)
    values[m.group(1)] = value

required = {"OWNER_ID", "EXIT_APP", "GATEWAY", "CLIENT"}
if not required.issubset(values):
    raise SystemExit(1)
owner = values["OWNER_ID"]
pool = values.get("POOL_ID") or owner
active = values.get("ACTIVE") or "on"
provider = values.get("PROVIDER_VPN_IPV4", "")
fingerprint = values.get("PROFILE_SHA256", "")
if expected and owner != expected:
    raise SystemExit(1)
if not re.fullmatch(r"[a-f0-9]{16}", owner) or not re.fullmatch(r"[a-f0-9]{16}", pool):
    raise SystemExit(1)
if values["EXIT_APP"] != f"ra-{pool[:12]}-exit":
    raise SystemExit(1)
if values["GATEWAY"] != f"ra-{pool[:12]}-gw":
    raise SystemExit(1)
if values["CLIENT"] != f"ra-{owner[:12]}-client":
    raise SystemExit(1)
if active not in {"on", "off"}:
    raise SystemExit(1)
if provider:
    try:
        if ipaddress.ip_address(provider).version != 4:
            raise ValueError
    except ValueError:
        raise SystemExit(1)
if fingerprint and not re.fullmatch(r"[a-f0-9]{64}", fingerprint):
    raise SystemExit(1)
print("|".join((owner, pool, values["EXIT_APP"], values["GATEWAY"],
                values["CLIENT"], provider, fingerprint, active)))
PY_REPAIR_REMOTE_STATE
}

repair_state_pool_has_member() {
    local pool=$1 require_active=${2:-any} file record owner state_pool _exit _gw _client _ip _sha active
    shopt -s nullglob
    for file in "$STATE_DIR"/remote-auto/*.cfg; do
        record=$(repair_remote_state_record "$file" 2>/dev/null || true)
        [[ -n "$record" ]] || continue
        IFS='|' read -r owner state_pool _exit _gw _client _ip _sha active <<<"$record"
        [[ "$state_pool" == "$pool" ]] || continue
        [[ "$require_active" != active || "$active" == on ]] || continue
        shopt -u nullglob
        return 0
    done
    shopt -u nullglob
    return 1
}

repair_profile_fingerprint_for_exit() {
    local app=$1 record profile
    record=$(
        load_cfg "$app"
        [[ -n "${DEFAULT_PROFILE:-}" ]] || exit 1
        profile="$(profiles_dir "$app")/$DEFAULT_PROFILE"
        [[ -f "$profile" && ! -L "$profile" ]] || exit 1
        sha256sum "$profile" | awk '{print $1}'
    ) 2>/dev/null || return 1
    [[ "$record" =~ ^[a-f0-9]{64}$ ]] || return 1
    printf '%s\n' "$record"
}

# Reconstruct one missing automatic-remote state file only when its unique
# deterministic client is found in exactly one consistently owned private
# gateway.  No PKI or client credential is regenerated here.
repair_remote_reconstruct_state() {
    local owner=$1 expected_active=${2:-off} state_file record
    local expected_client dir gateway candidate="" candidates=0 data pool exit_app marker transport
    local provider="" fingerprint=""
    validate_remote_owner_id "$owner"
    [[ "$expected_active" == on || "$expected_active" == off ]] || return 1
    state_file=$(remote_auto_state_file "$owner")

    record=$(repair_remote_state_record "$state_file" "$owner" 2>/dev/null || true)
    if [[ -n "$record" ]]; then
        IFS='|' read -r RA_OWNER_ID RA_POOL_ID RA_EXIT_APP RA_GATEWAY RA_CLIENT \
            RA_PROVIDER_VPN_IPV4 RA_PROFILE_SHA256 RA_ACTIVE <<<"$record"
        # Rewrite through the canonical writer if an old file omitted fields.
        remote_auto_write_state "$RA_OWNER_ID" "$RA_EXIT_APP" "$RA_GATEWAY" "$RA_CLIENT" \
            "$RA_POOL_ID" "$RA_PROVIDER_VPN_IPV4" "$RA_PROFILE_SHA256" "$RA_ACTIVE"
        return 0
    fi

    expected_client=$(remote_auto_client_name "$owner")
    shopt -s nullglob
    for dir in "$GATEWAY_BASE_DIR"/*; do
        [[ -f "$dir/gateway.cfg" && -f "$dir/clients/$expected_client/client.cfg" ]] || continue
        gateway=$(basename "$dir")
        data=$(
            load_gateway_cfg "$gateway"
            gateway_client_load "$gateway" "$expected_client"
            [[ "${STATUS:-}" == active ]] || exit 1
            printf '%s|%s|%s\n' "${REMOTE_MANAGED_OWNER_ID:-}" "$VIA_APP" "${TRANSPORT:-direct}"
        ) 2>/dev/null || continue
        IFS='|' read -r marker exit_app transport <<<"$data"
        [[ "$transport" == ssh && -f "$(cfg_file "$exit_app")" ]] || continue
        data=$(
            load_cfg "$exit_app"
            printf '%s\n' "${REMOTE_MANAGED_OWNER_ID:-}"
        ) 2>/dev/null || continue
        if [[ "$marker" =~ ^[a-f0-9]{16}$ ]]; then
            pool=$marker
            [[ -z "$data" || "$data" == "$pool" ]] || continue
        elif [[ "$data" =~ ^[a-f0-9]{16}$ ]]; then
            pool=$data
        else
            continue
        fi
        [[ "$gateway" == "$(remote_auto_gateway_name "$pool")" &&
           "$exit_app" == "$(remote_auto_exit_name "$pool")" ]] || continue
        candidate="$pool|$exit_app|$gateway|$expected_client"
        candidates=$((candidates + 1))
    done
    shopt -u nullglob

    if (( candidates != 1 )); then
        if [[ -e "$state_file" ]]; then
            repair_unresolved "automatic-remote state for owner '$owner' is invalid and has $candidates unambiguous reconstruction candidate(s); left untouched"
        else
            repair_unresolved "automatic-remote state for owner '$owner' is missing and has $candidates unambiguous reconstruction candidate(s)"
        fi
        return 1
    fi

    IFS='|' read -r pool exit_app gateway expected_client <<<"$candidate"
    data=$( ( load_cfg "$exit_app"; printf '%s\n' "${REMOTE_MANAGED_OWNER_ID:-}" ) 2>/dev/null || true)
    if [[ -z "$data" ]]; then
        cfg_set "$exit_app" REMOTE_MANAGED_OWNER_ID "$pool"
        repair_fixed "adopted missing pool marker on provider exit '$exit_app'"
    fi
    data=$( ( load_gateway_cfg "$gateway"; printf '%s\n' "${REMOTE_MANAGED_OWNER_ID:-}" ) 2>/dev/null || true)
    if [[ -z "$data" ]]; then
        gateway_cfg_set "$gateway" REMOTE_MANAGED_OWNER_ID "$pool"
        repair_fixed "adopted missing pool marker on gateway '$gateway'"
    fi

    provider=$(remote_auto_provider_ipv4 "$exit_app" 2>/dev/null || true)
    # add_profile() may have applied managed compatibility edits to the stored
    # provider profile, so hashing it here would not reproduce the original
    # upload fingerprint. Leave the fingerprint unknown rather than recording
    # a misleading identity; a later normal deployment can backfill it.
    fingerprint=""
    remote_auto_write_state "$owner" "$exit_app" "$gateway" "$expected_client" \
        "$pool" "$provider" "$fingerprint" "$expected_active"
    RA_OWNER_ID=$owner RA_POOL_ID=$pool RA_EXIT_APP=$exit_app RA_GATEWAY=$gateway
    RA_CLIENT=$expected_client RA_PROVIDER_VPN_IPV4=$provider
    RA_PROFILE_SHA256=$fingerprint RA_ACTIVE=$expected_active
    repair_fixed "reconstructed automatic-remote state for owner '$owner' from '$gateway/$expected_client'"
    return 0
}

repair_gateway_abandoned_certs() {
    local gateway=$1 pki index server_cn row status serial cn cert backup rc=0 fixed_any=0
    local cdir
    load_gateway_cfg "$gateway"
    pki=$(gateway_pki_dir "$gateway")
    index="$pki/index.txt"
    [[ -f "$index" ]] || {
        repair_unresolved "gateway '$gateway' CA database is missing '$index'"
        return 1
    }
    server_cn=${SERVER_CN:-}

    # Staging directories are protected by the gateway lock. If repair owns the
    # lock, no issuance transaction can legitimately still be using them.
    shopt -s nullglob
    for cdir in "$(gateway_clients_dir "$gateway")"/.*.new.* "$(gateway_dir "$gateway")"/.ca-db.*; do
        [[ -e "$cdir" ]] || continue
        rm -rf -- "$cdir"
        repair_fixed "removed abandoned gateway transaction staging '$(basename "$cdir")' from '$gateway'"
    done
    shopt -u nullglob

    while IFS='|' read -r status serial cn; do
        [[ "$status" == V && -n "$serial" && -n "$cn" ]] || continue
        [[ "$cn" != "$server_cn" ]] || continue
        [[ "$cn" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$ ]] || continue
        [[ ! -f "$(gateway_client_dir "$gateway" "$cn")/client.cfg" ]] || continue
        cert="$pki/newcerts/${serial}.pem"
        if [[ ! -f "$cert" ]]; then
            # OpenSSL can also use lower-case serial filenames depending on CA
            # tooling; try that without guessing any unrelated certificate.
            cert="$pki/newcerts/${serial,,}.pem"
        fi
        if [[ ! -f "$cert" ]]; then
            repair_unresolved "gateway '$gateway' has valid CA entry '$cn' serial '$serial' without tracked client metadata or certificate file"
            continue
        fi
        backup=$(mktemp -d "$(gateway_dir "$gateway")/.repair-ca.XXXXXX")
        if ! gateway_ca_snapshot "$pki" "$backup"; then
            rm -rf "$backup"
            repair_unresolved "could not snapshot CA database before revoking abandoned client '$cn' on '$gateway'"
            continue
        fi
        if openssl ca -batch -config "$pki/openssl.cnf" -revoke "$cert" >/dev/null 2>&1 &&
           gateway_generate_crl_at "$pki"; then
            rm -rf "$backup"
            repair_fixed "revoked abandoned certificate '$cn' on gateway '$gateway'"
            fixed_any=1
        else
            gateway_ca_restore "$pki" "$backup" >/dev/null 2>&1 || true
            rm -rf "$backup"
            repair_unresolved "failed to revoke abandoned certificate '$cn' on gateway '$gateway'; CA database restored"
            rc=1
        fi
    done < <(awk -F '\t' '
        $1 == "V" {
            cn=$6
            sub(/^.*\/CN=/, "", cn)
            sub(/\/.*/, "", cn)
            print $1 "|" $4 "|" cn
        }
    ' "$index")

    # OpenVPN reads the CRL file during client verification; replacing the CRL
    # atomically is enough. Do not restart the service while the gateway lock is
    # held because ExecStopPost would need the same lock in another process.
    return "$rc"
}

repair_gateway_expected_running() {
    local gateway=$1 marker active_public
    systemctl is-enabled --quiet "nns-gateway@${gateway}.service" 2>/dev/null && return 0
    marker=${REMOTE_MANAGED_OWNER_ID:-}
    [[ "$marker" =~ ^[a-f0-9]{16}$ ]] || return 1
    if [[ "$gateway" == "$(remote_auto_gateway_name "$marker")" ]]; then
        repair_state_pool_has_member "$marker" active && return 0
    elif [[ "$gateway" == "$(remote_auto_public_gateway_name "$marker")" ]]; then
        active_public=$(remote_auto_public_active_client_count "$marker" 2>/dev/null || printf 0)
        [[ "$active_public" =~ ^[0-9]+$ ]] && (( active_public > 0 )) && return 0
    fi
    return 1
}

repair_gateway_one() {
    local gateway=$1 state pid restart_needed=no upstream_ns="" upstream_tun=""
    local before_ufw=no
    validate_gateway_name "$gateway"
    if ! ( load_gateway_cfg "$gateway" ) 2>/dev/null; then
        repair_unresolved "gateway '$gateway' has an invalid configuration"
        return 1
    fi
    acquire_lock "gateway-$gateway"
    load_gateway_cfg "$gateway"
    write_gateway_unit_dropin "$gateway"
    gateway_write_openssl_config "$gateway" "$(gateway_dir "$gateway")"
    gateway_write_server_config "$gateway"
    gateway_write_transport_config "$gateway"

    repair_gateway_abandoned_certs "$gateway" || true

    state=$(systemctl is-active "nns-gateway@${gateway}.service" 2>/dev/null || true)
    if [[ "$state" == active ]]; then
        if ufw_is_active && [[ "${TRANSPORT:-direct}" != ssh ]]; then
            if ufw_public_allow_exists "$LISTEN_PORT" "$LISTEN_PROTO" ||
               ufw_managed_public_rule_exists "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO"; then
                before_ufw=yes
            fi
        fi
        if ! gateway_public_firewall_up "$gateway"; then
            repair_unresolved "could not reconcile host firewall for active gateway '$gateway' ($LISTEN_PORT/$LISTEN_PROTO)"
        elif [[ "$before_ufw" == no ]] && ufw_is_active && [[ "${TRANSPORT:-direct}" != ssh ]]; then
            repair_fixed "opened missing UFW port $LISTEN_PORT/$LISTEN_PROTO for active gateway '$gateway'"
        fi

        pid=$(systemctl show "nns-gateway@${gateway}.service" -p MainPID --value 2>/dev/null || true)
        ip link show dev "$GATEWAY_TUN" up >/dev/null 2>&1 || restart_needed=yes
        gateway_listener_ready "${pid:-0}" || restart_needed=yes
        gateway_policy_ready || restart_needed=yes
        if [[ "$restart_needed" == yes ]]; then
            release_lock "gateway-$gateway"
            if ( gateway_stop "$gateway" >/dev/null 2>&1 ) &&
               ( gateway_start "$gateway" >/dev/null 2>&1 ); then
                repair_fixed "restarted stale gateway '$gateway' and rebuilt its data plane"
                return 0
            fi
            repair_unresolved "gateway '$gateway' is configured active but its listener/data plane could not be rebuilt"
            return 1
        fi
    else
        # A stopped gateway must never retain an nns-app-owned public INPUT
        # exception. Administrator-owned broad rules are intentionally retained.
        if ufw_is_active && [[ "${TRANSPORT:-direct}" != ssh ]] &&
           ufw_managed_public_rule_exists "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO"; then
            # Older/interrupted releases may have created the tagged UFW rule
            # before recording the ownership state file. Recreate only that
            # private marker so the normal exact-delete path can remove it.
            if [[ ! -e "$(gateway_ufw_state_file "$gateway")" ]]; then
                : >"$(gateway_ufw_state_file "$gateway")"
                chmod 0600 "$(gateway_ufw_state_file "$gateway")" 2>/dev/null || true
            fi
            if gateway_ufw_public_down "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO"; then
                repair_fixed "closed stale UFW port $LISTEN_PORT/$LISTEN_PROTO for stopped gateway '$gateway'"
            else
                repair_unresolved "could not close stale UFW port for stopped gateway '$gateway'"
            fi
        fi
        gateway_firewalld_public_down "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO" >/dev/null 2>&1 || true
        gateway_iptables_public_down "$gateway" "$LISTEN_PORT" "$LISTEN_PROTO" >/dev/null 2>&1 || true

        if repair_gateway_expected_running "$gateway"; then
            release_lock "gateway-$gateway"
            if ( gateway_start "$gateway" >/dev/null 2>&1 ); then
                repair_fixed "started gateway '$gateway' because its enabled/active ownership state requires it"
                return 0
            fi
            repair_unresolved "gateway '$gateway' should be running but could not be started"
            return 1
        fi
    fi
    release_lock "gateway-$gateway"
    return 0
}

repair_ufw_orphan_rules() {
    ufw_is_active || return 0
    local line spec gateway marker
    while IFS= read -r line; do
        [[ "$line" == *"nns-app:gateway:"*":public-input"* ]] || continue
        gateway=$(sed -n "s/.*nns-app:gateway:\([A-Za-z0-9._-]*\):public-input.*/\1/p" <<<"$line")
        [[ "$gateway" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || continue
        [[ ! -f "$(gateway_cfg_file "$gateway")" ]] || continue
        spec=$(awk '{ if ($3=="in") print $4; else print $3 }' <<<"$line")
        [[ "$spec" =~ ^[1-9][0-9]{0,4}/(tcp|udp)$ ]] || continue
        marker=$(gateway_public_firewall_comment "$gateway")
        if ufw delete allow "$spec" comment "$marker" >/dev/null 2>&1; then
            repair_fixed "removed orphan UFW rule '$spec' for deleted gateway '$gateway'"
        else
            repair_unresolved "could not remove orphan UFW rule '$spec' for deleted gateway '$gateway'"
        fi
    done < <(LC_ALL=C ufw show added 2>/dev/null || true)
}


repair_orphan_gateway_dirs() {
    local dir gateway state zone server port proto
    shopt -s nullglob
    for dir in "$GATEWAY_BASE_DIR"/*; do
        [[ -d "$dir" && ! -f "$dir/gateway.cfg" ]] || continue
        gateway=$(basename "$dir")
        [[ "$gateway" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || continue
        server="$dir/server.conf"
        port=""; proto=""
        if [[ -f "$server" ]]; then
            port=$(awk '$1=="port" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$server" 2>/dev/null || true)
            proto=$(awk '$1=="proto" {print $2; exit}' "$server" 2>/dev/null || true)
            [[ "$proto" == tcp-server || "$proto" == tcp-client ]] && proto=tcp
            [[ "$proto" == udp || "$proto" == tcp ]] || proto=""
            [[ "$port" =~ ^[1-9][0-9]{0,4}$ && "$port" -le 65535 ]] || port=""
        fi

        state="$dir/.host-firewall-firewalld"
        if [[ -s "$state" ]]; then
            zone=$(head -n 1 "$state" 2>/dev/null || true)
            zone=${zone%%|*}
            if [[ "$zone" =~ ^[A-Za-z0-9_-]+$ && -n "$port" && -n "$proto" ]]; then
                if firewalld_is_active; then
                    firewalld_port_remove runtime "$zone" "$port" "$proto" >/dev/null 2>&1 || true
                    firewalld_port_remove permanent "$zone" "$port" "$proto" >/dev/null 2>&1 || true
                    if ! firewalld_port_query runtime "$zone" "$port" "$proto" &&
                       ! firewalld_port_query permanent "$zone" "$port" "$proto"; then
                        rm -f "$state"
                        repair_fixed "removed orphan firewalld port $port/$proto for deleted gateway '$gateway'"
                    else
                        repair_unresolved "could not remove orphan firewalld port $port/$proto for deleted gateway '$gateway'"
                    fi
                elif command -v firewall-offline-cmd >/dev/null 2>&1; then
                    if firewall-offline-cmd --zone="$zone" --remove-port="$port/$proto" >/dev/null 2>&1; then
                        rm -f "$state"
                        repair_fixed "removed persistent orphan firewalld port $port/$proto for deleted gateway '$gateway'"
                    else
                        repair_unresolved "could not remove persistent orphan firewalld port $port/$proto for deleted gateway '$gateway'"
                    fi
                else
                    repair_unresolved "gateway '$gateway' is missing its config and owns a firewalld rule, but no firewalld tool is available to remove it"
                fi
            else
                repair_unresolved "gateway directory '$gateway' is missing gateway.cfg and its firewalld ownership state cannot be safely reconstructed"
            fi
        fi

        # Tagged fallback iptables access can be removed exactly when the old
        # server config still proves the listener port/protocol.
        if [[ -n "$port" && -n "$proto" ]] && command -v iptables >/dev/null 2>&1; then
            if iptables -w -t filter -C INPUT -p "$proto" --dport "$port" \
                -m comment --comment "$(gateway_public_firewall_comment "$gateway")" -j ACCEPT \
                >/dev/null 2>&1; then
                gateway_iptables_public_down "$gateway" "$port" "$proto" >/dev/null 2>&1 || true
                if ! iptables -w -t filter -C INPUT -p "$proto" --dport "$port" \
                    -m comment --comment "$(gateway_public_firewall_comment "$gateway")" -j ACCEPT \
                    >/dev/null 2>&1; then
                    repair_fixed "removed orphan iptables INPUT rule $port/$proto for deleted gateway '$gateway'"
                else
                    repair_unresolved "could not remove orphan iptables INPUT rule for deleted gateway '$gateway'"
                fi
            fi
        fi

        # Missing gateway.cfg means routing/PKI ownership cannot be proven
        # sufficiently to reconstruct or delete the remaining directory.
        if find "$dir" -mindepth 1 -maxdepth 1 ! -name '.host-firewall-ufw' ! -name '.host-firewall-firewalld' -print -quit 2>/dev/null | grep -q .; then
            repair_unresolved "gateway directory '$gateway' is missing gateway.cfg; firewall was reconciled where possible but PKI/runtime files were preserved"
        elif [[ -d "$dir" ]]; then
            rmdir "$dir" 2>/dev/null || true
        fi
    done
    shopt -u nullglob
}

repair_dangling_systemd_units() {
    local unit kind name key
    local -A seen=()
    while read -r unit _; do
        [[ -n "$unit" ]] || continue
        seen["$unit"]=1
    done < <(systemctl list-units --all --plain --no-legend \
        'nns-netns@*.service' 'nns-openvpn@*.service' 'nns-online@*.service' \
        'nns-dns@*.service' 'nns-watchdog@*.service' 'nns-watchdog@*.timer' \
        'nns-gateway@*.service' 'nns-gateway-crl-refresh@*.service' \
        'nns-gateway-crl-refresh@*.timer' 2>/dev/null || true)
    while read -r unit _; do
        [[ -n "$unit" ]] || continue
        seen["$unit"]=1
    done < <(systemctl list-unit-files --no-legend \
        'nns-netns@*.service' 'nns-openvpn@*.service' 'nns-online@*.service' \
        'nns-dns@*.service' 'nns-watchdog@*.service' 'nns-watchdog@*.timer' \
        'nns-gateway@*.service' 'nns-gateway-crl-refresh@*.service' \
        'nns-gateway-crl-refresh@*.timer' 2>/dev/null || true)

    for unit in "${!seen[@]}"; do
        case "$unit" in
            nns-netns@*.service|nns-openvpn@*.service|nns-online@*.service|nns-dns@*.service|nns-watchdog@*.service|nns-watchdog@*.timer)
                name=${unit#*@}; name=${name%.service}; name=${name%.timer}
                [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || continue
                [[ -f "$(cfg_file "$name")" ]] && continue
                systemctl disable --now "$unit" >/dev/null 2>&1 || true
                rm -rf -- "$(app_dropin_dir "$name")"
                rm -f -- "/etc/sudoers.d/nns-app-$name"
                repair_fixed "removed dangling systemd instance '$unit' with no application configuration"
                ;;
            nns-gateway@*.service|nns-gateway-crl-refresh@*.service|nns-gateway-crl-refresh@*.timer)
                name=${unit#*@}; name=${name%.service}; name=${name%.timer}
                [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || continue
                [[ -f "$(gateway_cfg_file "$name")" ]] && continue
                systemctl disable --now "$unit" >/dev/null 2>&1 || true
                rm -rf -- "$(gateway_dropin_dir "$name")"
                repair_fixed "removed dangling systemd instance '$unit' with no gateway configuration"
                ;;
        esac
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
}

repair_local_ssh_forward() {
    local app=$1 local_port ns active_ns=no listener=no
    load_cfg "$app"
    [[ "${TRANSPORT_TYPE:-direct}" == ssh ]] || return 0
    [[ "${TRANSPORT_LOCAL_PORT:-}" =~ ^[1-9][0-9]{0,4}$ ]] || {
        repair_unresolved "automatic-remote app '$app' has invalid local SSH-forward port metadata"
        return 1
    }
    local_port=$TRANSPORT_LOCAL_PORT
    ns=$NS_NAME
    systemctl is-active --quiet "nns-netns@${app}.service" && active_ns=yes
    [[ "$active_ns" == yes ]] || return 0
    if ip netns exec "$ns" ss -H -lnt 2>/dev/null |
       grep -Eq "127\\.0\\.0\\.1:${local_port}([[:space:]]|$)"; then
        listener=yes
    fi
    if [[ "$listener" == yes && $(systemctl is-active "nns-openvpn@${app}.service" 2>/dev/null || true) == active ]]; then
        return 0
    fi

    systemctl stop "nns-online@${app}.service" >/dev/null 2>&1 || true
    if systemctl restart "nns-openvpn@${app}.service" >/dev/null 2>&1; then
        local deadline=$((SECONDS + 10))
        while (( SECONDS < deadline )); do
            if ip netns exec "$ns" ss -H -lnt 2>/dev/null |
               grep -Eq "127\\.0\\.0\\.1:${local_port}([[:space:]]|$)"; then
                systemctl start "nns-online@${app}.service" >/dev/null 2>&1 || true
                repair_fixed "restarted dead SSH forward for app '$app' on 127.0.0.1:$local_port"
                return 0
            fi
            sleep 0.2
        done
    fi
    repair_unresolved "SSH forward for running app '$app' is still unavailable on 127.0.0.1:$local_port"
    return 1
}

repair_remote_owned_orphans() {
    # Remove only remote-managed provider exits that are referenced by neither
    # valid automatic-remote state nor any configured gateway. This safely
    # catches failed/duplicate candidate exits without guessing shared pools.
    local dir app marker referenced=no file record _owner _pool exit_ref _gw _client _ip _sha _active deps
    shopt -s nullglob
    for dir in "$BASE_DIR"/*; do
        [[ -d "$dir" ]] || continue
        app=$(basename "$dir")
        [[ "$app" =~ ^ra-[a-f0-9]{12}-exit$ && -f "$(cfg_file "$app")" ]] || continue
        marker=$( ( load_cfg "$app"; printf '%s\n' "${REMOTE_MANAGED_OWNER_ID:-}" ) 2>/dev/null || true)
        [[ "$marker" =~ ^[a-f0-9]{16}$ && "$app" == "$(remote_auto_exit_name "$marker")" ]] || continue
        referenced=no
        for file in "$STATE_DIR"/remote-auto/*.cfg; do
            record=$(repair_remote_state_record "$file" 2>/dev/null || true)
            [[ -n "$record" ]] || continue
            IFS='|' read -r _owner _pool exit_ref _gw _client _ip _sha _active <<<"$record"
            if [[ "$exit_ref" == "$app" ]]; then referenced=yes; break; fi
        done
        [[ "$referenced" == no ]] || continue
        deps=$(gateways_using_app "$app" | paste -sd ',' -)
        [[ -z "$deps" ]] || continue
        if ( remove_app "$app" local-only >/dev/null 2>&1 ); then
            repair_fixed "removed unreferenced remote-managed provider exit '$app' (failed/duplicate orphan)"
        else
            repair_unresolved "could not remove unreferenced remote-managed provider exit '$app'"
        fi
    done
    shopt -u nullglob
}

repair_detect_duplicate_exits() {
    local file record owner pool exit_app gw client ip sha active key previous
    local -A seen=()
    shopt -s nullglob
    for file in "$STATE_DIR"/remote-auto/*.cfg; do
        record=$(repair_remote_state_record "$file" 2>/dev/null || true)
        [[ -n "$record" ]] || continue
        IFS='|' read -r owner pool exit_app gw client ip sha active <<<"$record"
        [[ -n "$ip" ]] || continue
        key="$ip"
        previous=${seen[$key]-}
        if [[ -n "$previous" && "$previous" != "$exit_app" ]]; then
            repair_unresolved "duplicate managed provider exits '$previous' and '$exit_app' report provider-side VPN address '$ip'; both are referenced, so repair will not merge them automatically"
        else
            seen[$key]=$exit_app
        fi
    done
    shopt -u nullglob
}

remote_auto_repair_internal() {
    require_root
    local owner=$1 expected_active=${2:-off} public_gateway
    validate_remote_owner_id "$owner"
    [[ "$expected_active" == on || "$expected_active" == off ]] ||
        die "_remote-auto repair active state must be on or off."

    REPAIR_FIXED=0 REPAIR_WARNINGS=0 REPAIR_UNRESOLVED=0
    acquire_lock remote-auto-pools
    if repair_remote_reconstruct_state "$owner" "$expected_active"; then
        # The canonical file is now safe for the regular state loader.
        remote_auto_load_state "$owner"
        if [[ "$RA_ACTIVE" != "$expected_active" ]]; then
            remote_auto_write_state "$owner" "$RA_EXIT_APP" "$RA_GATEWAY" "$RA_CLIENT" \
                "$RA_POOL_ID" "$RA_PROVIDER_VPN_IPV4" "$RA_PROFILE_SHA256" "$expected_active"
            RA_ACTIVE=$expected_active
            repair_fixed "synchronized automatic-remote active state for owner '$owner' to '$expected_active'"
        fi
        if [[ -f "$(gateway_cfg_file "$RA_GATEWAY")" ]]; then
            repair_gateway_one "$RA_GATEWAY" || true
        else
            repair_unresolved "private gateway '$RA_GATEWAY' referenced by owner '$owner' is missing"
        fi
        public_gateway=$(remote_auto_public_gateway_name "$RA_POOL_ID")
        if [[ -f "$(gateway_cfg_file "$public_gateway")" ]]; then
            repair_gateway_one "$public_gateway" || true
        fi
    fi
    repair_remote_owned_orphans
    repair_detect_duplicate_exits
    repair_ufw_orphan_rules
    repair_orphan_gateway_dirs
    repair_dangling_systemd_units
    release_lock remote-auto-pools

    printf 'Repair summary: repaired=%s warnings=%s unresolved=%s\n' \
        "$REPAIR_FIXED" "$REPAIR_WARNINGS" "$REPAIR_UNRESOLVED"
    (( REPAIR_UNRESOLVED == 0 ))
}

repair_local_gateways() {
    local dir gateway
    shopt -s nullglob
    for dir in "$GATEWAY_BASE_DIR"/*; do
        [[ -f "$dir/gateway.cfg" ]] || continue
        gateway=$(basename "$dir")
        repair_gateway_one "$gateway" || true
    done
    shopt -u nullglob
}

repair_local_apps() {
    local dir app
    shopt -s nullglob
    for dir in "$BASE_DIR"/*; do
        [[ -d "$dir" ]] || continue
        app=$(basename "$dir")
        [[ -f "$(cfg_file "$app")" ]] || continue
        if ! ( load_cfg "$app" ) 2>/dev/null; then
            repair_unresolved "application '$app' has an invalid configuration"
            continue
        fi
        load_cfg "$app"
        write_app_unit_dropin "$app"
        write_sudoers_for_app "$app" "$APP_USER"
        sync_watchdog_timer "$app"
        repair_local_ssh_forward "$app" || true
    done
    shopt -u nullglob
}

repair_configured_remotes() {
    local dir app alias owner expected_active target port
    shopt -s nullglob
    for dir in "$BASE_DIR"/*; do
        [[ -d "$dir" ]] || continue
        app=$(basename "$dir")
        [[ -f "$(cfg_file "$app")" ]] || continue
        if ! ( load_cfg "$app" ) 2>/dev/null; then
            continue
        fi
        load_cfg "$app"
        [[ "${REMOTE_MODE:-}" == auto ]] || continue
        alias=${REMOTE_ALIAS:-}; owner=${REMOTE_OWNER_ID:-}
        if [[ -z "$alias" || -z "$owner" || ! -f "$(remote_cfg_file "$alias")" ]]; then
            repair_unresolved "automatic-remote metadata/SSH registration is incomplete for '$app'"
            continue
        fi
        expected_active=off
        if app_is_started "$app" ||
           systemctl is-active --quiet "nns-netns@${app}.service" 2>/dev/null ||
           systemctl is-active --quiet "nns-openvpn@${app}.service" 2>/dev/null ||
           [[ -f "$RUN_DIR/${app}.profile" ]]; then
            expected_active=on
        fi

        if ! ( remote_auto_refresh_configured_app "$app" >/dev/null 2>&1 ); then
            repair_unresolved "remote node for '$app' could not be upgraded/contacted; remote repair skipped"
            continue
        fi
        load_cfg "$app"
        alias=$REMOTE_ALIAS owner=$REMOTE_OWNER_ID
        printf 'Remote repair for %s:\n' "$app"
        if remote_auto_command "$alias" repair "$owner" "$expected_active"; then
            :
        else
            repair_unresolved "remote reconciliation for '$app' reported unresolved problems"
        fi
    done
    shopt -u nullglob
}

repair_engine() {
    require_root
    assert_destructive_command_from_host "repair nns-app"
    local mode=${1:-remote}
    [[ "$mode" == remote || "$mode" == local-only ]] || die "Unsupported repair mode '$mode'."
    REPAIR_FIXED=0 REPAIR_WARNINGS=0 REPAIR_UNRESOLVED=0

    log "Checking nns-app state and owned resources..."
    if [[ "$mode" == remote ]]; then
        repair_configured_remotes
    else
        log "Remote automatic nodes skipped (--local-only)."
    fi
    repair_local_apps
    repair_local_gateways
    repair_ufw_orphan_rules
    repair_orphan_gateway_dirs
    repair_dangling_systemd_units

    printf 'Repair summary: repaired=%s warnings=%s unresolved=%s\n' \
        "$REPAIR_FIXED" "$REPAIR_WARNINGS" "$REPAIR_UNRESOLVED"
    if (( REPAIR_UNRESOLVED > 0 )); then
        warn "Repair completed with unresolved items; ambiguous/destructive recovery was intentionally not attempted."
        return 1
    fi
    return 0
}
