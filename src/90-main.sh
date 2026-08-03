# nns-app source module: CLI parser and source-only guard.
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
            gateway_crl_refresh "$2"
            exit
            ;;
        _wait-online)
            require_root
            [[ $# -eq 3 ]] || die "_wait-online requires app_name and timeout."
            wait_online "$2" "$3" ||
                die "NNS app '$2' did not become online within $3 seconds."
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
        _watchdog)
            require_root
            [[ $# -eq 2 ]] || die "_watchdog requires app_name."
            watchdog_check "$2"
            exit
            ;;
    esac

    reexec_as_root_if_needed "$@"

    case "$cmd" in
        install)
            if (( $# == 1 )); then
                install_engine
            else
                local install_app_name=$2 install_via="__default__" install_backend="__default__"
                local install_remote="" install_remote_port=22
                shift 2
                while (( $# > 0 )); do
                    case "$1" in
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
                            shift 2
                            ;;
                        --remote-port=*)
                            install_remote_port=${1#--remote-port=}
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
                            die "Usage: nns-app install <app_name> via --remote <user@host>"
                            ;;
                    esac
                done
                if [[ -n "$install_remote" ]]; then
                    [[ "$install_via" == __default__ && "$install_backend" == __default__ ]] ||
                        die "--via-remote cannot be combined with --via or --backend."
                    install_app "$install_app_name" __default__
                    remote_auto_install "$install_app_name" "$install_remote" "$install_remote_port"
                else
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
        status)
            [[ $# -eq 2 ]] || die "Usage: nns-app status <app_name>"
            status_app "$2"
            ;;
        add)
            (( $# >= 3 )) ||
                die "Usage: nns-app add <app_name> <profile.ovpn|wireguard.conf>|any [country] [--refresh] [--via <upstream-app>|host]"
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
            start_app "$START_APP_NAME" "$START_IGNORE" "$START_VIA"
            ;;
        stop)
            [[ $# -eq 2 ]] || die "Usage: nns-app stop <app_name>"
            stop_app "$2"
            ;;
        gateway)
            (( $# >= 2 )) || die "Usage: nns-app gateway <create|start|stop|status|list|remove|client> ..."
            case "$2" in
                create)
                    (( $# >= 3 )) ||
                        die "Usage: nns-app gateway create <name> --via <app> --listen tcp|udp:<port> --public <host>:<port> [--pool CIDR] [--dns \"IP ...\"]"
                    local gw_name=$3 gw_via="" gw_listen="" gw_public="" gw_pool="" gw_dns="1.1.1.1 9.9.9.9" gw_transport="direct" gw_server_name=""
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
                            *)
                                die "Unknown gateway create option '$1'."
                                ;;
                        esac
                    done
                    [[ -n "$gw_via" && -n "$gw_listen" && -n "$gw_public" ]] ||
                        die "gateway create requires --via, --listen and --public."
                    [[ "$gw_transport" != ssh ]] ||
                        die "Transport 'ssh' is managed internally by install --via-remote."
                    gateway_create "$gw_name" "$gw_via" "$gw_listen" "$gw_public" "$gw_pool" "$gw_dns" "$gw_transport" "$gw_server_name"
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
                            [[ $# -eq 5 ]] ||
                                die "Usage: nns-app gateway client add <gateway_name> <client_name>"
                            gateway_client_add "$4" "$5"
                            ;;
                        list)
                            [[ $# -eq 4 ]] ||
                                die "Usage: nns-app gateway client list <gateway_name>"
                            gateway_client_list "$4"
                            ;;
                        export)
                            (( $# >= 6 )) ||
                                die "Usage: nns-app gateway client export <gateway_name> <client_name> --output <file.ovpn>"
                            local export_gateway=$4 export_client=$5 export_output="" export_format="ovpn"
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
                                    *)
                                        die "Unknown gateway client export option '$1'."
                                        ;;
                                esac
                            done
                            [[ -n "$export_output" ]] || die "--output is required."
                            gateway_client_export "$export_gateway" "$export_client" "$export_output" "$export_format"
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
            run_in_app "$app" "$@"
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
