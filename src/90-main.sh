# nns-app source module: CLI parser and source-only guard.
# A VPN namespace and a VPN server/gateway are both managed apps. Their
# persistent state remains in its respective backend directory; CLI lifecycle
# operations resolve by installed object, never by the gateway's VIA_APP.
managed_app_kind() {
    local app=${1:-} namespace=off gateway=off
    validate_app_name "$app"
    [[ ! -f "$(cfg_file "$app")" ]] || namespace=on
    if managed_gateway_exists "$app"; then gateway=on; fi
    if [[ "$namespace" == on && "$gateway" == on ]]; then
        die "Conflicting namespace and gateway configurations for app '$app'. Resolve the duplicate before proceeding."
    elif [[ "$gateway" == on ]]; then
        printf 'gateway\n'
    elif [[ "$namespace" == on ]]; then
        printf 'namespace\n'
    else
        die "NNS app '$app' is not installed."
    fi
}

managed_app_start() {
    local app=$1 ignore=${2:-off} via=${3:-__default__} kind
    kind=$(managed_app_kind "$app") || return 1
    if [[ "$kind" == gateway ]]; then
        [[ "$via" == __default__ ]] ||
            die "Gateway '$app' has a configured exit; change its configuration rather than overriding --via at start."
        [[ "$ignore" == off ]] ||
            die "--ignore-start-error is supported only for VPN namespace apps."
        gateway_start "$app"
    else
        start_app "$app" "$ignore" "$via"
    fi
}

managed_app_stop() {
    local app=$1 mode=${2:-remote} kind
    kind=$(managed_app_kind "$app") || return 1
    if [[ "$kind" == gateway ]]; then
        # --local-only is already the natural operation for a local server.
        gateway_stop "$app"
    else
        stop_app_cli "$app" "$mode"
    fi
}

managed_app_status() {
    local app=$1 kind
    kind=$(managed_app_kind "$app") || return 1
    if [[ "$kind" == gateway ]]; then
        gateway_status "$app"
    else
        status_app "$app"
    fi
}

managed_app_remove() {
    local app=$1 mode=${2:-remote} kind
    kind=$(managed_app_kind "$app") || return 1
    if [[ "$kind" == gateway ]]; then
        gateway_remove "$app"
    elif [[ "$mode" == local-only ]]; then
        remove_app "$app" local-only
    else
        remove_app "$app"
    fi
}

managed_app_run() {
    local app=$1 kind
    shift
    kind=$(managed_app_kind "$app") || return 1
    if [[ "$kind" == gateway ]]; then
        run_in_gateway "$app" "$@"
    else
        run_in_app "$app" "$@"
    fi
}

# A managed public gateway is an app, regardless of the backend or its exit.
# The public client CLI handles credentials for these apps independently from
# the namespace VPN profiles configured with `nns-app add`.
managed_client_export() {
    local app=$1 client=$2 output=$3 format=${4:-auto}
    local fixed_ip=${5:-off} route_mode=${6:-keep} backend transport cdir sidecar
    require_root
    validate_gateway_name "$app"
    validate_gateway_client_name "$client"
    managed_gateway_exists "$app" ||
        die "App '$app' is not a managed VPN server/gateway."
    load_gateway_cfg "$app"
    backend=${GATEWAY_BACKEND:-openvpn}
    transport=${TRANSPORT:-direct}
    case "$format" in auto|ovpn|awg|nnslink) ;; *) die "Unsupported client export format '$format'." ;; esac
    if [[ "$format" == auto ]]; then
        if [[ "$backend" == amneziawg ]]; then
            format=awg
        elif [[ "$transport" == direct || "$transport" == cloak ]]; then
            format=ovpn
        else
            format=nnslink
        fi
    fi
    case "$backend:$format" in
        amneziawg:awg)
            [[ "$fixed_ip" == off || "$fixed_ip" == on ]] || die "Invalid fixed IP option."
            ;;
        openvpn:ovpn)
            [[ "$transport" == direct || "$transport" == cloak ]] ||
                die "Transport '$transport' requires --format nnslink."
            ;;
        openvpn:nnslink) ;;
        *) die "Format '$format' is incompatible with server '$app' ($backend)." ;;
    esac
    [[ "$route_mode" == keep || "$route_mode" == full || "$route_mode" == split ]] ||
        die "Invalid tunnel route mode '$route_mode'."
    [[ -n "$output" ]] || die "--output is required."
    if [[ "$backend" == amneziawg ]]; then
        [[ "$output" != - ]] || die "AmneziaWG private profiles require a file output."
    fi
    if [[ "$transport" == cloak && "$format" == ovpn ]]; then
        [[ "$output" != - && "$output" == *.ovpn ]] ||
            die "Cloak export requires an .ovpn output path."
    fi
    # Fail on invalid/conflicting output BEFORE issuing a persistent credential.
    if [[ "$output" != - ]]; then
        output=$(readlink -m -- "$output")
        [[ -d "$(dirname -- "$output")" ]] || die "Output directory does not exist: $(dirname -- "$output")"
        [[ ! -e "$output" && ! -L "$output" ]] || die "Output already exists: $output"
        if [[ "$transport" == cloak && "$format" == ovpn ]]; then
            sidecar="${output%.ovpn}.cloak.json"
            [[ ! -e "$sidecar" && ! -L "$sidecar" ]] || die "Output already exists: $sidecar"
        fi
    fi
    cdir=$(gateway_client_dir "$app" "$client")
    if [[ "$backend" == amneziawg ]]; then
        awg_server_client_export "$app" "$client" "$output" "$route_mode"
    elif [[ "$format" == ovpn ]]; then
        server_export_ovpn "$app" "$client" "$output" - auto modern "$fixed_ip" "$route_mode"
    else
        if [[ ! -e "$cdir" ]]; then
            gateway_client_add "$app" "$client" >&2
        fi
        if [[ "$fixed_ip" == on ]]; then
            gateway_client_fixed_ip "$app" "$client" on >&2
        fi
        if [[ "$route_mode" != keep ]]; then
            gateway_client_route_mode "$app" "$client" "$route_mode" >&2
        fi
        gateway_client_export "$app" "$client" "$output" nnslink
    fi
}

# Revoke first, then destroy the local client identity. OpenVPN's CA database
# and CRL are deliberately retained: deleting them would reauthorize a removed
# certificate. For AWG, the peer is removed from the live server before its
# private/public keys and metadata are destroyed.
managed_client_remove() {
    local app=$1 client=$2 dir backend state
    require_root
    validate_gateway_name "$app"
    validate_gateway_client_name "$client"
    managed_gateway_exists "$app" || die "App '$app' is not a managed VPN server/gateway."
    dir=$(gateway_client_dir "$app" "$client")
    [[ -d "$dir" && ! -L "$dir" ]] || die "Client '$client' does not exist on '$app'."
    acquire_lock "gateway-$app" shared
    load_gateway_cfg "$app"
    backend=${GATEWAY_BACKEND:-openvpn}
    gateway_client_load "$app" "$client"
    state=${STATUS:-}
    release_lock "gateway-$app"
    [[ "$state" == active || "$state" == revoked ]] ||
        die "Cannot remove client '$client': unknown status '$state'."
    if [[ "$backend" == amneziawg ]]; then
        # Retry the live peer synchronization even for an already-revoked
        # record: the previous syncconf might have failed after updating its
        # metadata, leaving the old peer authorized in the running interface.
        awg_server_client_revoke "$app" "$client" || return 1
    elif [[ "$state" == active ]]; then
        gateway_client_revoke "$app" "$client" || return 1
    elif systemctl is-active --quiet "nns-gateway@${app}.service"; then
        # A previous revoke may have persisted the CRL but failed to restart
        # the daemon. Do not destroy the last client record until a running
        # OpenVPN process has reloaded its CRL and dropped the old session.
        systemctl restart "nns-gateway@${app}.service" || return 1
    fi
    acquire_lock "gateway-$app"
    load_gateway_cfg "$app"
    gateway_client_load "$app" "$client"
    if [[ "${STATUS:-}" != revoked || -L "$dir" ]]; then
        release_lock "gateway-$app"
        die "Client '$client' was not safely revoked; files preserved."
    fi
    # Only the validated, root-controlled client directory is removed. Never
    # remove gateway CA/CRL material or any other client record.
    rm -rf -- "$dir" || { release_lock "gateway-$app"; die "Failed deleting client '$client'."; }
    if [[ "$backend" == amneziawg ]]; then
        awg_server_write_config "$app" || { release_lock "gateway-$app"; die "Failed regenerating AmneziaWG peer configuration."; }
    else
        gateway_write_server_config "$app" || { release_lock "gateway-$app"; die "Failed rebuilding OpenVPN client configuration."; }
        if [[ "${TRANSPORT:-direct}" == cloak ]]; then
            gateway_write_transport_config "$app" || { release_lock "gateway-$app"; die "Failed rebuilding Cloak client authorization."; }
        fi
    fi
    release_lock "gateway-$app"
    log "Revoked and removed client '$client' from '$app'."
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
        _dns-proxy)
            require_root
            [[ $# -eq 2 ]] || die "_dns-proxy requires app_name."
            dns_proxy_exec "$2"
            exit
            ;;
        _amnezia-up)
            require_root
            [[ $# -eq 2 ]] || die "_amnezia-up requires server_name."
            awg_server_up "$2"
            exit
            ;;
        _amnezia-down)
            require_root
            [[ $# -eq 2 ]] || die "_amnezia-down requires server_name."
            awg_server_down "$2"
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
            # OpenVPN appends its generated TUN arguments after the command
            # and gateway name configured in --up.  The gateway callback uses
            # the device environment variable and intentionally ignores those
            # additional positional arguments.
            (( $# >= 2 )) || die "_gateway-tun-up requires gateway_name."
            gateway_tun_up "$2"
            exit
            ;;
        _gateway-crl-refresh)
            require_root
            [[ $# -eq 2 ]] || die "_gateway-crl-refresh requires gateway_name."
            [[ "$(gateway_cfg_value "$2" GATEWAY_BACKEND)" != amneziawg ]] || exit 0
            gateway_crl_refresh "$2"
            exit
            ;;
        _wait-online)
            require_root
            [[ $# -eq 3 ]] || die "_wait-online requires app_name and timeout."
            wait_online "$2" "$3" ||
                die "NNS app '$2' did not become online within $3 seconds."
            mtu_auto_repair "$2"
            exit
            ;;
        _remote-auto-authorize)
            require_root
            [[ $# -eq 2 ]] || die "_remote-auto-authorize requires a remote account name."
            remote_auto_authorize "$2"
            exit
            ;;
        _remote-auto)
            require_root
            (( $# >= 2 )) || die "_remote-auto requires an operation."
            shift
            remote_auto_dispatch "$@"
            exit
            ;;
        _mtu-up)
            require_root
            # OpenVPN appends: dev tun_mtu 0 local_ip remote_ip [init|restart].
            (( $# >= 3 )) || die "_mtu-up requires app_name and tunnel device."
            mtu_openvpn_up "$2" "$3"
            exit
            ;;
        _mtu-reconcile)
            require_root
            [[ $# -eq 2 ]] || die "_mtu-reconcile requires app_name."
            mtu_reconcile_local "$2"
            exit
            ;;
        _watchdog)
            require_root
            [[ $# -eq 2 ]] || die "_watchdog requires app_name."
            watchdog_check "$2"
            exit
            ;;
    esac

    reexec_as_root_if_needed "$@"

    case "$cmd" in
        backup)
            shift
            nns_backup "$@"
            ;;
        restore)
            shift
            nns_restore "$@"
            ;;
        install)
            if (( $# == 1 )); then
                install_engine on
            elif (( $# == 2 )) && [[ "$2" == --local-only ]]; then
                install_engine off
            else
                local install_app_name=$2 install_via="__default__" install_backend="__default__"
                [[ -n "$install_app_name" && "$install_app_name" != --* ]] ||
                    die "Usage: nns-app install <name> --server"
                local install_remote="" install_remote_port=22 install_remote_port_set=off
                local install_server=off install_amnezia=off install_listen="" install_public=""
                local install_pool="" install_dns="" install_c2c=""
                local install_transport="" install_server_name=""
                shift 2
                while (( $# > 0 )); do
                    case "$1" in
                        --server)
                            install_server=on
                            shift
                            ;;
                        --amnezia)
                            install_amnezia=on
                            shift
                            ;;
                        --client-to-client)
                            install_c2c=on
                            if (( $# >= 2 )) && [[ "$2" == on || "$2" == off ]]; then
                                install_c2c=$2; shift 2
                            else
                                shift
                            fi
                            ;;
                        --client-to-client=*)
                            install_c2c=${1#--client-to-client=}; shift ;;
                        --no-client-to-client)
                            install_c2c=off; shift ;;
                        --listen)
                            (( $# >= 2 )) || die "--listen requires tcp:<port> or udp:<port>."
                            install_listen=$2; shift 2 ;;
                        --listen=*)
                            install_listen=${1#--listen=}; shift ;;
                        --public)
                            (( $# >= 2 )) || die "--public requires host:port."
                            install_public=$2; shift 2 ;;
                        --public=*)
                            install_public=${1#--public=}; shift ;;
                        --transport)
                            (( $# >= 2 )) || die "--transport requires direct or cloak."
                            install_transport=$2; shift 2 ;;
                        --transport=*)
                            install_transport=${1#--transport=}; shift ;;
                        --server-name)
                            (( $# >= 2 )) || die "--server-name requires a Cloak decoy hostname."
                            install_server_name=$2; shift 2 ;;
                        --server-name=*)
                            install_server_name=${1#--server-name=}; shift ;;
                        --pool)
                            (( $# >= 2 )) || die "--pool requires an IPv4 CIDR."
                            install_pool=$2; shift 2 ;;
                        --pool=*)
                            install_pool=${1#--pool=}; shift ;;
                        --dns)
                            (( $# >= 2 )) || die "--dns requires quoted space-separated IPv4 addresses."
                            install_dns=$2; shift 2 ;;
                        --dns=*)
                            install_dns=${1#--dns=}; shift ;;
                        --via)
                            (( $# >= 2 )) || die "--via requires an upstream app name or 'host'."
                            install_via=$2
                            shift 2
                            ;;
                        --via=*)
                            install_via=${1#--via=}
                            shift
                            ;;
                        via)
                            (( $# >= 2 )) || die "via requires --remote <user@host>."
                            case "$2" in
                                --remote)
                                    (( $# >= 3 )) || die "via --remote requires [user@]host."
                                    install_remote=$3
                                    shift 3
                                    ;;
                                --remote=*)
                                    install_remote=${2#--remote=}
                                    shift 2
                                    ;;
                                *)
                                    die "Only 'via --remote <user@host>' is supported in the automatic remote form."
                                    ;;
                            esac
                            ;;
                        --via-remote|--remote)
                            (( $# >= 2 )) || die "$1 requires [user@]host."
                            install_remote=$2
                            shift 2
                            ;;
                        --via-remote=*|--remote=*)
                            install_remote=${1#*=}
                            shift
                            ;;
                        --remote-port)
                            (( $# >= 2 )) || die "--remote-port requires a number."
                            install_remote_port=$2
                            install_remote_port_set=on
                            shift 2
                            ;;
                        --remote-port=*)
                            install_remote_port=${1#--remote-port=}
                            install_remote_port_set=on
                            shift
                            ;;
                        --backend)
                            (( $# >= 2 )) || die "--backend requires 'inherit'."
                            install_backend=$2
                            shift 2
                            ;;
                        --backend=*)
                            install_backend=${1#--backend=}
                            shift
                            ;;
                        *)
                            die "Unknown install option '$1'. See nns-app --help."
                            ;;
                    esac
                done
                if [[ "$install_server" == on ]]; then
                    [[ -z "$install_remote" && "$install_remote_port_set" == off &&
                       "$install_via" == __default__ && "$install_backend" == __default__ ]] ||
                        die "--server cannot be combined with --via, --remote, or --backend."
                    if [[ "$install_amnezia" == on ]]; then
                        [[ -z "$install_transport$install_server_name" ]] ||
                            die "--amnezia cannot be combined with --transport or --server-name."
                        awg_server_install "$install_app_name" "$install_listen" "$install_public" \
                            "$install_pool" "$install_dns" "$install_c2c"
                    else
                        install_openvpn_server "$install_app_name" \
                            "$install_listen" "$install_public" "$install_pool" "$install_dns" "$install_c2c" \
                            "$install_transport" "$install_server_name"
                    fi
                else
                    [[ "$install_amnezia" != on ]] || die "--amnezia requires --server."
                    [[ -z "$install_listen$install_public$install_pool$install_dns$install_c2c$install_transport$install_server_name" ]] ||
                        die "--listen, --public, --pool, --dns, --transport, --server-name and --client-to-client require --server."
                    if [[ -n "$install_remote" ]]; then
                        [[ "$install_via" == __default__ && "$install_backend" == __default__ ]] ||
                            die "--via-remote cannot be combined with --via or --backend."
                        install_app "$install_app_name" __default__
                        remote_auto_install "$install_app_name" "$install_remote" "$install_remote_port"
                    else
                        [[ "$install_remote_port_set" == off ]] ||
                            die "--remote-port requires --remote."
                        case "$install_backend" in
                            __default__) install_app "$install_app_name" "$install_via" ;;
                            inherit)
                                install_app "$install_app_name" "$install_via"
                                set_inherit_backend "$install_app_name" "$install_via"
                                ;;
                            *) die "Unsupported app backend '$install_backend'; only 'inherit' is valid without a profile." ;;
                        esac
                    fi
                fi
            fi
            ;;
        remove)
            if [[ $# -eq 2 ]]; then
                managed_app_remove "$2"
            elif [[ $# -eq 3 && "$3" == --local-only ]]; then
                managed_app_remove "$2" local-only
            else
                die "Usage: nns-app remove <app_name> [--local-only]"
            fi
            ;;
        purge)
            if [[ $# -eq 1 ]]; then
                purge_engine
            elif [[ $# -eq 2 && "$2" == --local-only ]]; then
                purge_engine local-only
            else
                die "Usage: nns-app purge [--local-only]"
            fi
            ;;
        repair)
            if [[ $# -eq 1 ]]; then
                repair_engine remote
            elif [[ $# -eq 2 && "$2" == --local-only ]]; then
                repair_engine local-only
            else
                die "Usage: nns-app repair [--local-only]"
            fi
            ;;
        list)
            case "${2:-managed}" in
                managed)
                    [[ $# -eq 1 ]] || die "Usage: nns-app list [apps|namespaces|gateways|clients|all]"
                    list_managed_objects
                    ;;
                apps)
                    [[ $# -eq 2 ]] || die "Usage: nns-app list apps"
                    list_managed_objects
                    ;;
                namespaces|local-clients)
                    [[ $# -eq 2 ]] || die "Usage: nns-app list namespaces"
                    list_apps
                    ;;
                all)
                    [[ $# -eq 2 ]] || die "Usage: nns-app list all"
                    list_all_objects
                    ;;
                gateway|gateways)
                    [[ $# -eq 2 ]] || die "Usage: nns-app list gateway"
                    list_gateways_overview
                    ;;
                client|clients)
                    [[ $# -eq 2 ]] || die "Usage: nns-app list clients"
                    list_external_clients_overview
                    ;;
                *)
                    die "Usage: nns-app list [apps|namespaces|gateways|clients|all]"
                    ;;
            esac
            ;;
        status)
            [[ $# -eq 2 ]] || die "Usage: nns-app status <app_name>"
            managed_app_status "$2"
            ;;
        myip)
            (( $# <= 2 )) || die "Usage: nns-app myip [<app_or_gateway_name>]"
            myip_command "${2:-}"
            ;;
        export)
            (( $# >= 4 )) ||
                die "Usage: nns-app export ovpn <app_name> --client <client_name> [--embedded] [--public <host>:<port>] [--proto tcp|udp] [--output <file|->]"
            [[ "$2" == ovpn || "$2" == awg ]] ||
                die "Supported export formats: ovpn and awg."
            local export_kind=$2 export_app=$3 export_client="" export_public="-" export_proto="auto" export_output="-" export_compat="modern" export_fixed_ip="off" export_route_mode="keep"
            shift 3
            while (( $# > 0 )); do
                case "$1" in
                    --client)
                        (( $# >= 2 )) || die "--client requires a client name."
                        export_client=$2; shift 2 ;;
                    --client=*)
                        export_client=${1#--client=}; shift ;;
                    --embedded)
                        export_compat=embedded; shift ;;
                    --fixed-ip)
                        export_fixed_ip=on; shift ;;
                    --split-tunnel)
                        export_route_mode=split; shift ;;
                    --full-tunnel)
                        export_route_mode=full; shift ;;
                    --public)
                        (( $# >= 2 )) || die "--public requires host:port."
                        export_public=$2; shift 2 ;;
                    --public=*)
                        export_public=${1#--public=}; shift ;;
                    --proto)
                        (( $# >= 2 )) || die "--proto requires tcp or udp."
                        export_proto=$2; shift 2 ;;
                    --proto=*)
                        export_proto=${1#--proto=}; shift ;;
                    --output)
                        (( $# >= 2 )) || die "--output requires a file path or '-'."
                        export_output=$2; shift 2 ;;
                    --output=*)
                        export_output=${1#--output=}; shift ;;
                    *) die "Unknown export option '$1'." ;;
                esac
            done
            [[ -n "$export_client" ]] || die "export ovpn requires --client <client_name>."
            if [[ "$export_kind" == awg ]]; then
                managed_gateway_exists "$export_app" || die "AmneziaWG export requires a locally managed server."
                [[ "$export_public" == - && "$export_proto" == auto && "$export_compat" == modern ]] ||
                    die "--public, --proto and --embedded are not valid for AmneziaWG client export."
                awg_server_client_export "$export_app" "$export_client" "$export_output" "$export_route_mode"
            elif managed_gateway_exists "$export_app"; then
                server_export_ovpn "$export_app" "$export_client" \
                    "$export_output" "$export_public" "$export_proto" "$export_compat" "$export_fixed_ip" "$export_route_mode"
            else
                [[ "$export_fixed_ip" == off && "$export_route_mode" == keep ]] || die "--fixed-ip and tunnel routing controls are supported for locally managed OpenVPN servers only."
                remote_auto_export_public_ovpn "$export_app" "$export_client" \
                    "$export_public" "$export_proto" "$export_output" "$export_compat"
            fi
            ;;
        client)
            (( $# >= 3 )) || die "Usage: nns-app client <export|remove|add|list|revoke> <app> [client] ..."
            case "$2" in
                export)
                    (( $# >= 5 )) || die "Usage: nns-app client export <app> <client> --output <file> [--format ovpn|awg|nnslink] [--full-tunnel|--split-tunnel] [--fixed-ip]"
                    local app=$3 name=$4 output="" format=auto fixed=off route=keep
                    shift 4
                    while (( $# > 0 )); do
                        case "$1" in
                            --output)
                                (( $# >= 2 )) || die "--output requires a path."
                                output=$2; shift 2 ;;
                            --output=*) output=${1#--output=}; shift ;;
                            --format)
                                (( $# >= 2 )) || die "--format requires ovpn, awg or nnslink."
                                format=$2; shift 2 ;;
                            --format=*) format=${1#--format=}; shift ;;
                            --fixed-ip) fixed=on; shift ;;
                            --full-tunnel) route=full; shift ;;
                            --split-tunnel) route=split; shift ;;
                            *) die "Unknown client export option '$1'." ;;
                        esac
                    done
                    [[ -n "$output" ]] || die "--output is required."
                    managed_client_export "$app" "$name" "$output" "$format" "$fixed" "$route"
                    ;;
                remove)
                    [[ $# -eq 4 ]] || die "Usage: nns-app client remove <app> <client>"
                    managed_client_remove "$3" "$4"
                    ;;
                add)
                    [[ $# -eq 4 || ( $# -eq 5 && "$5" == --fixed-ip ) ]] ||
                        die "Usage: nns-app client add <app> <client> [--fixed-ip]"
                    gateway_client_add "$3" "$4"
                    [[ $# -ne 5 ]] || gateway_client_fixed_ip "$3" "$4" on
                    ;;
                revoke)
                    [[ $# -eq 4 ]] || die "Usage: nns-app client revoke <app> <client>"
                    if [[ "$(gateway_cfg_value "$3" GATEWAY_BACKEND)" == amneziawg ]]; then
                        awg_server_client_revoke "$3" "$4"
                    else
                        gateway_client_revoke "$3" "$4"
                    fi
                    ;;
                list)
                    [[ $# -eq 3 ]] || die "Usage: nns-app client list <app>"
                    gateway_client_list "$3"
                    ;;
                *) die "Unknown client command '$2'." ;;
            esac
            ;;
        revoke)
            (( $# >= 3 && $# <= 4 )) ||
                die "Usage: nns-app revoke <app_name> <client_name> [--modern|--embedded]"
            local revoke_scope=all
            if (( $# == 4 )); then
                case "$4" in
                    --modern) revoke_scope=modern ;;
                    --embedded) revoke_scope=embedded ;;
                    *) die "Usage: nns-app revoke <app_name> <client_name> [--modern|--embedded]" ;;
                esac
            fi
            if managed_gateway_exists "$2"; then
                [[ "$revoke_scope" != embedded ]] ||
                    die "--embedded is not supported for a modern OpenVPN server."
                if [[ "$(gateway_cfg_value "$2" GATEWAY_BACKEND)" == amneziawg ]]; then
                    awg_server_client_revoke "$2" "$3"
                else
                    gateway_client_revoke "$2" "$3"
                fi
            else
                remote_auto_revoke_public_ovpn "$2" "$3" "$revoke_scope"
            fi
            ;;
        add)
            (( $# >= 3 )) ||
                die "Usage: nns-app add <app_name> <profile.ovpn|wireguard.conf|amneziawg.conf>|any [country] [--refresh] [--via <upstream-app>|host]"
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
                load_cfg "$2"
                if [[ "${REMOTE_MODE:-}" == auto ]]; then
                    [[ "$3" != *.nnslink ]] ||
                        die "Automatic remote mode accepts the provider profile, not a generated .nnslink bundle."
                    remote_auto_add_profile "$2" "$3"
                elif [[ "$3" == *.nnslink ]]; then
                    nnslink_import "$2" "$3"
                else
                    add_profile "$2" "$3"
                fi
            fi
            ;;
        start)
            shift
            parse_start_cli "$@"
            managed_app_start "$START_APP_NAME" "$START_IGNORE" "$START_VIA"
            ;;
        stop)
            case $# in
                2) managed_app_stop "$2" ;;
                3)
                    [[ "$3" == --local-only ]] ||
                        die "Usage: nns-app stop <app_name> [--local-only]"
                    managed_app_stop "$2" local-only
                    ;;
                *) die "Usage: nns-app stop <app_name> [--local-only]" ;;
            esac
            ;;
        set-via)
            (( $# == 3 )) || die "Usage: nns-app set-via <gateway-app> <upstream-app|host>"
            gateway_set_via "$2" "$3"
            ;;
        route-mode)
            (( $# >= 3 && $# <= 4 )) ||
                die "Usage: nns-app route-mode <server_name> <client_name> [split|full]"
            gateway_client_route_mode "$2" "$3" "${4:-show}"
            ;;
        fixed-ip)
            (( $# >= 3 && $# <= 4 )) ||
                die "Usage: nns-app fixed-ip <server_name> <client_name> [on|off]"
            if (( $# == 3 )); then
                gateway_client_fixed_ip "$2" "$3" show
            else
                gateway_client_fixed_ip "$2" "$3" "$4"
            fi
            ;;
        client-to-client)
            (( $# == 2 || $# == 3 )) ||
                die "Usage: nns-app client-to-client <server_name> [on|off]"
            managed_gateway_exists "$2" ||
                die "'$2' is not an installed OpenVPN gateway."
            if (( $# == 2 )); then
                gateway_show_client_to_client "$2"
            else
                gateway_set_client_to_client "$2" "$3"
            fi
            ;;
        gateway)
            (( $# >= 2 )) || die "Usage: nns-app gateway <create|start|stop|status|list|remove|client|client-to-client> ..."
            case "$2" in
                create)
                    (( $# >= 3 )) ||
                        die "Usage: nns-app gateway create <name> --via <app> --listen tcp|udp:<port> --public <host>:<port> [--pool CIDR] [--dns \"IP ...\"]"
                    local gw_name=$3 gw_via="" gw_listen="" gw_public="" gw_pool="" gw_dns="1.1.1.1 9.9.9.9" gw_transport="direct" gw_server_name="" gw_c2c=off
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
                            --transport)
                                (( $# >= 2 )) || die "--transport requires direct, stunnel or cloak."
                                gw_transport=$2; shift 2 ;;
                            --transport=*)
                                gw_transport=${1#--transport=}; shift ;;
                            --server-name)
                                (( $# >= 2 )) || die "--server-name requires a Cloak decoy hostname."
                                gw_server_name=$2; shift 2 ;;
                            --server-name=*)
                                gw_server_name=${1#--server-name=}; shift ;;
                            --client-to-client)
                                gw_c2c=on
                                if (( $# >= 2 )) && [[ "$2" == on || "$2" == off ]]; then
                                    gw_c2c=$2; shift 2
                                else
                                    shift
                                fi
                                ;;
                            --client-to-client=*)
                                gw_c2c=${1#--client-to-client=}; shift ;;
                            --no-client-to-client)
                                gw_c2c=off; shift ;;
                            *)
                                die "Unknown gateway create option '$1'."
                                ;;
                        esac
                    done
                    [[ -n "$gw_via" ]] ||
                        die "gateway create requires --via <app|host>."
                    [[ "$gw_transport" != ssh ]] ||
                        die "Transport 'ssh' is managed internally by install --via-remote."
                    gateway_create "$gw_name" "$gw_via" "$gw_listen" "$gw_public" "$gw_pool" "$gw_dns" "$gw_transport" "$gw_server_name" modern "$gw_c2c"
                    ;;
                client-to-client)
                    (( $# == 3 || $# == 4 )) ||
                        die "Usage: nns-app gateway client-to-client <gateway_name> [on|off]"
                    if (( $# == 3 )); then
                        gateway_show_client_to_client "$3"
                    else
                        gateway_set_client_to_client "$3" "$4"
                    fi
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
                        die "Usage: nns-app gateway client <add|list|export|rotate|revoke> ..."
                    case "$3" in
                        add)
                            [[ $# -eq 5 || ( $# -eq 6 && "$6" == --fixed-ip ) ]] ||
                                die "Usage: nns-app gateway client add <gateway_name> <client_name> [--fixed-ip]"
                            gateway_client_add "$4" "$5"
                            [[ $# -ne 6 ]] || gateway_client_fixed_ip "$4" "$5" on
                            ;;
                        fixed-ip)
                            (( $# >= 5 && $# <= 6 )) ||
                                die "Usage: nns-app gateway client fixed-ip <gateway_name> <client_name> [on|off]"
                            gateway_client_fixed_ip "$4" "$5" "${6:-show}"
                            ;;
                        route-mode)
                            (( $# >= 5 && $# <= 6 )) ||
                                die "Usage: nns-app gateway client route-mode <gateway_name> <client_name> [split|full]"
                            gateway_client_route_mode "$4" "$5" "${6:-show}"
                            ;;
                        list)
                            [[ $# -eq 4 ]] ||
                                die "Usage: nns-app gateway client list <gateway_name>"
                            gateway_client_list "$4"
                            ;;
                        export)
                            (( $# >= 6 )) ||
                                die "Usage: nns-app gateway client export <gateway_name> <client_name> --output <file.ovpn>"
                            local export_gateway=$4 export_client=$5 export_output="" export_format="ovpn" export_static="off" export_route_mode="keep"
                            shift 5
                            while (( $# > 0 )); do
                                case "$1" in
                                    --output)
                                        (( $# >= 2 )) || die "--output requires a path."
                                        export_output=$2; shift 2 ;;
                                    --output=*)
                                        export_output=${1#--output=}; shift ;;
                                    --format)
                                        (( $# >= 2 )) || die "--format requires ovpn or nnslink."
                                        export_format=$2; shift 2 ;;
                                    --format=*)
                                        export_format=${1#--format=}; shift ;;
                                    --fixed-ip)
                                        export_static=on; shift ;;
                                    --split-tunnel)
                                        export_route_mode=split; shift ;;
                                    --full-tunnel)
                                        export_route_mode=full; shift ;;
                                    *)
                                        die "Unknown gateway client export option '$1'."
                                        ;;
                                esac
                            done
                            [[ -n "$export_output" ]] || die "--output is required."
                            managed_client_export "$export_gateway" "$export_client" "$export_output" "$export_format" "$export_static" "$export_route_mode"
                            ;;
                        rotate)
                            [[ $# -eq 5 ]] ||
                                die "Usage: nns-app gateway client rotate <gateway_name> <client_name>"
                            gateway_client_rotate "$4" "$5"
                            ;;
                        revoke)
                            [[ $# -eq 5 ]] ||
                                die "Usage: nns-app gateway client revoke <gateway_name> <client_name>"
                            gateway_client_revoke "$4" "$5"
                            ;;
                        remove)
                            [[ $# -eq 5 ]] ||
                                die "Usage: nns-app gateway client remove <gateway_name> <client_name>"
                            managed_client_remove "$4" "$5"
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
        link)
            [[ $# -eq 4 && "$2" == import ]] ||
                die "Usage: nns-app link import <app_name> <bundle.nnslink>"
            nnslink_import "$3" "$4"
            ;;
        remote)
            (( $# >= 3 )) || die "Usage: nns-app remote <add|connect|sync|rotate|status> ..."
            case "$2" in
                add)
                    local remote_alias=$3 remote_target="" remote_port=22 remote_identity=""
                    shift 3
                    while (( $# > 0 )); do
                        case "$1" in
                            --ssh)
                                (( $# >= 2 )) || die "--ssh requires [user@]host."
                                remote_target=$2; shift 2 ;;
                            --ssh=*) remote_target=${1#--ssh=}; shift ;;
                            --port)
                                (( $# >= 2 )) || die "--port requires a number."
                                remote_port=$2; shift 2 ;;
                            --port=*) remote_port=${1#--port=}; shift ;;
                            --identity)
                                (( $# >= 2 )) || die "--identity requires a private-key path."
                                remote_identity=$2; shift 2 ;;
                            --identity=*) remote_identity=${1#--identity=}; shift ;;
                            *) die "Unknown remote add option '$1'." ;;
                        esac
                    done
                    [[ -n "$remote_target" ]] || die "remote add requires --ssh <user@host>."
                    remote_add "$remote_alias" "$remote_target" "$remote_port" "$remote_identity"
                    ;;
                connect)
                    local remote_ref=$3 remote_client="" remote_name="" remote_backend="openvpn"
                    shift 3
                    while (( $# > 0 )); do
                        case "$1" in
                            --client)
                                (( $# >= 2 )) || die "--client requires a client name."
                                remote_client=$2; shift 2 ;;
                            --client=*) remote_client=${1#--client=}; shift ;;
                            --name)
                                (( $# >= 2 )) || die "--name requires a local app name."
                                remote_name=$2; shift 2 ;;
                            --name=*) remote_name=${1#--name=}; shift ;;
                            --backend)
                                (( $# >= 2 )) || die "--backend requires openvpn."
                                remote_backend=$2; shift 2 ;;
                            --backend=*) remote_backend=${1#--backend=}; shift ;;
                            *) die "Unknown remote connect option '$1'." ;;
                        esac
                    done
                    [[ -n "$remote_client" && -n "$remote_name" ]] ||
                        die "remote connect requires --client and --name."
                    remote_connect "$remote_ref" "$remote_client" "$remote_name" "$remote_backend"
                    ;;
                sync)
                    [[ $# -eq 3 ]] || die "Usage: nns-app remote sync <local_app>"
                    remote_sync "$3"
                    ;;
                rotate)
                    [[ $# -eq 3 ]] || die "Usage: nns-app remote rotate <local_app>"
                    remote_rotate "$3"
                    ;;
                status)
                    [[ $# -eq 3 ]] || die "Usage: nns-app remote status <local_app|alias>"
                    remote_status "$3"
                    ;;
                *) die "Unknown remote command '$2'." ;;
            esac
            ;;
        run)
            (( $# >= 3 )) || die "Usage: nns-app run <app_name> <command> [arguments...]"
            local app=$2
            shift 2
            managed_app_run "$app" "$@"
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
