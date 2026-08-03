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
            [[ $# -eq 2 ]] || die "_gateway-tun-up requires gateway_name."
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
    esac

    reexec_as_root_if_needed "$@"

    case "$cmd" in
        install)
            if (( $# == 1 )); then
                install_engine
            else
                local install_app_name=$2 install_via="__default__"
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
                        *)
                            die "Usage: nns-app install <app_name> [--via <upstream-app>|host]"
                            ;;
                    esac
                done
                install_app "$install_app_name" "$install_via"
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
                add_profile "$2" "$3"
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
                    local gw_name=$3 gw_via="" gw_listen="" gw_public="" gw_pool="" gw_dns="1.1.1.1 9.9.9.9"
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
                            *)
                                die "Unknown gateway create option '$1'."
                                ;;
                        esac
                    done
                    [[ -n "$gw_via" && -n "$gw_listen" && -n "$gw_public" ]] ||
                        die "gateway create requires --via, --listen and --public."
                    gateway_create "$gw_name" "$gw_via" "$gw_listen" "$gw_public" "$gw_pool" "$gw_dns"
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
                        die "Usage: nns-app gateway client <add|list|export|revoke> ..."
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
                            local export_gateway=$4 export_client=$5 export_output=""
                            shift 5
                            while (( $# > 0 )); do
                                case "$1" in
                                    --output)
                                        (( $# >= 2 )) || die "--output requires a path."
                                        export_output=$2; shift 2 ;;
                                    --output=*)
                                        export_output=${1#--output=}; shift ;;
                                    *)
                                        die "Unknown gateway client export option '$1'."
                                        ;;
                                esac
                            done
                            [[ -n "$export_output" ]] || die "--output is required."
                            gateway_client_export "$export_gateway" "$export_client" "$export_output"
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
