# External IP geolocation for the current network or a managed app's egress.
# ip-api.com's free API is HTTP-only, rate-limited, non-commercial. Only a
# single request is made; a failed namespace lookup never falls back to host.
readonly MYLOC_URL='http://ip-api.com/json/?fields=status,message,query,country,countryCode,regionName,city,zip,lat,lon,timezone,isp,org,as'

myloc_query() {
    local ns=${1:-} json
    local -a cmd=(/usr/bin/curl -4fsS --noproxy '*' --connect-timeout 3 --max-time 10 "$MYLOC_URL")
    if [[ -n "$ns" ]]; then
        json=$("$(ip_binary)" netns exec "$ns" "${cmd[@]}") || return 1
    else
        json=$("${cmd[@]}") || return 1
    fi
    [[ -n "$json" ]] || return 1
    printf '%s\n' "$json"
}

myloc_namespace_ready() {
    [[ -e "/run/netns/$1" ]]
}

# A private-only split tunnel with the kill switch enabled drops every packet
# outside AllowedIPs, so its namespace has no public Internet exit to query.
myloc_private_only() {
    local app=$1 killswitch
    app_split_tunnel "$app" || return 1
    killswitch=$(cfg_read_value "$app" KILLSWITCH 2>/dev/null || true)
    bool_on "${killswitch:-off}"
}

myloc_format() {
    local format=$1 context=$2
    python3 -c '
import json
import sys
try:
    data = json.load(sys.stdin)
except (ValueError, UnicodeError):
    sys.exit("ERROR: Invalid geolocation response.")
if not isinstance(data, dict):
    sys.exit("ERROR: Invalid geolocation response type.")
if data.get("status") != "success":
    sys.exit("ERROR: IP geolocation query failed: " + str(data.get("message", "unknown")))
if not isinstance(data.get("query"), str) or not data["query"]:
    sys.exit("ERROR: Geolocation response lacks public IP.")
if sys.argv[1] == "json":
    print(json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2))
    sys.exit(0)
print("Context:           " + sys.argv[2])
fields = [
    ("query", "Public IPv4"), ("country", "Country"),
    ("countryCode", "Country code"), ("regionName", "Region"),
    ("city", "City"), ("zip", "Postal code"),
    ("timezone", "Timezone"), ("isp", "ISP"),
    ("org", "Organization"), ("as", "ASN"),
]
for key, label in fields:
    value = data.get(key)
    if value is not None and value != "":
        print(f"{label + chr(58):<19}{value}")
if data.get("lat") is not None and data.get("lon") is not None:
    print("Coordinates:       {}, {}".format(data["lat"], data["lon"]))
print("Provider:          ip-api.com (approximate location; HTTP)")
' "$format" "$context"
}

myloc_command() {
    local requested="" format=pretty context="host" ns="" via="" json="" egress=""
    while (( $# > 0 )); do
        case "$1" in
            --json) format=json ;;
            --*) die "Unknown myloc option '$1'." ;;
            *)
                [[ -z "$requested" ]] || die 'Usage: nns-app myloc [<app_or_gateway_name>] [--json]'
                requested=$1 ;;
        esac
        shift
    done

    if [[ -n "$requested" ]]; then
        validate_app_name "$requested"
        if managed_gateway_exists "$requested"; then
            load_gateway_cfg "$requested"
            via=$VIA_APP
            systemctl is-active --quiet "nns-gateway@${requested}.service" ||
                die "Gateway '$requested' is stopped."
            if [[ "$via" == host ]]; then
                myip_host_namespace || die "Cannot inspect host-exit gateway '$requested' from another network namespace."
                context="gateway:$requested via host"
            else
                require_root
                load_cfg "$via"
                myloc_namespace_ready "$NS_NAME" || die "Gateway upstream '$via' has no active namespace."
                ns=$NS_NAME
                context="gateway:$requested via $via"
                egress=$via
                if [[ -n "${UPSTREAM_APP:-}" && "$UPSTREAM_APP" != host ]]; then
                    egress=$UPSTREAM_APP
                fi
            fi
        else
            require_root
            load_cfg "$requested"
            myloc_namespace_ready "$NS_NAME" || die "App '$requested' has no active namespace."
            ns=$NS_NAME
            context="app:$requested"
            egress=$requested
            if [[ -n "${UPSTREAM_APP:-}" && "$UPSTREAM_APP" != host ]]; then
                egress=$UPSTREAM_APP
            fi
        fi
    else
        local detected
        detected=$(current_nns_app 2>/dev/null || true)
        if [[ -z "$detected" && -n "${NNS_APP_CONTEXT:-}" ]] && ! myip_host_namespace; then
            detected=$NNS_APP_CONTEXT
        fi
        if [[ -n "$detected" ]]; then
            context="app:$detected (current namespace)"
        elif ! myip_host_namespace; then
            context='current network namespace'
        fi
    fi

    if [[ -n "$egress" ]] && myloc_private_only "$egress"; then
        die "IP geolocation is impossible from '$context': app '$egress' is a private-only split tunnel with the kill switch enabled (no public Internet exit)."
    fi

    json=$(myloc_query "$ns") || die "IP geolocation unavailable from '$context' (DNS, network, API, or rate limit)."
    printf '%s\n' "$json" | myloc_format "$format" "$context"
}
