# External IP geolocation for the current network or a managed app's egress.
# The primary probe is ip-api.com (free, HTTP-only, rate-limited,
# non-commercial); it is unreachable from some networks, so myloc falls back
# to ipwho.is (HTTPS, keyless) when the primary fails. One request is made
# per provider; a failed namespace lookup never falls back to host.
readonly MYLOC_URL='http://ip-api.com/json/?fields=status,message,query,country,countryCode,regionName,city,zip,lat,lon,timezone,isp,org,as'
readonly MYLOC_FALLBACK_URLS='https://ipwho.is/'

# Probe URLs can be overridden for custom or self-hosted endpoints:
# NNS_MYLOC_URL replaces the primary, NNS_MYLOC_FALLBACK_URLS (space-separated,
# empty disables fallback) replaces the fallbacks, and NNS_MYLOC_CURL replaces
# /usr/bin/curl (used by the test suite).
myloc_urls() {
    local -a extra
    if [[ -n "${NNS_MYLOC_URL:-}" ]]; then
        printf '%s\n' "$NNS_MYLOC_URL"
    else
        printf '%s\n' "$MYLOC_URL"
    fi
    if [[ -n "${NNS_MYLOC_FALLBACK_URLS+x}" ]]; then
        read -r -a extra <<<"${NNS_MYLOC_FALLBACK_URLS:-}"
    else
        read -r -a extra <<<"$MYLOC_FALLBACK_URLS"
    fi
    if (( ${#extra[@]} > 0 )); then
        printf '%s\n' "${extra[@]}"
    fi
}

# The provider that last worked is remembered per egress context and tried
# first on later runs, so an unreachable primary does not cost a connect
# timeout on every invocation. Different namespaces reach providers
# differently, so the cache is keyed per network namespace (or the current
# one for host mode). NNS_MYLOC_CACHE overrides the cache path (tests);
# source-only runs disable it unless a path is given explicitly.
myloc_cache_file() {
    if [[ -n "${NNS_MYLOC_CACHE:-}" ]]; then
        printf '%s\n' "$NNS_MYLOC_CACHE"
        return 0
    fi
    [[ "${NNS_APP_SOURCE_ONLY:-0}" != 1 ]] || return 1
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/nns-app/myloc-providers"
}

myloc_cache_key() {
    local ns="${1:-}" id
    if [[ -n "$ns" ]]; then
        printf 'ns:%s\n' "$ns"
        return 0
    fi
    id=$(namespace_ref_id /proc/self/ns/net 2>/dev/null || true)
    printf 'self:%s\n' "${id:-host}"
}

myloc_cache_read() {
    local file="$1" key="$2" k url
    [[ -f "$file" ]] || return 1
    while read -r k url _; do
        if [[ "$k" == "$key" && -n "$url" ]]; then
            printf '%s\n' "$url"
            return 0
        fi
    done < "$file"
    return 1
}

myloc_cache_write() {
    local file="$1" key="$2" url="$3" line tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/nns-myloc-cache.XXXXXX") || return 1
    if [[ -f "$file" ]]; then
        while IFS= read -r line; do
            [[ "${line%%$'\t'*}" != "$key" ]] || continue
            printf '%s\n' "$line"
        done < "$file" > "$tmp"
    fi
    # Tab-separated: the installer runs with IFS=$'\n\t', so plain `read`
    # splits records reliably.
    printf '%s\t%s\t%s\n' "$key" "$url" "$(date +%s)" >> "$tmp"
    mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# Emit the cached provider (if any) followed by the configured providers,
# without duplicates; myloc_query tries them in this order.
myloc_query_urls() {
    local key="$1" file="$2" cached=""
    if [[ -n "$file" ]]; then
        cached=$(myloc_cache_read "$file" "$key" 2>/dev/null || true)
    fi
    {
        if [[ -n "$cached" ]]; then
            printf '%s\n' "$cached"
        fi
        myloc_urls
    } | awk 'NF && !seen[$0]++'
}

# Normalize a provider response onto the ip-api.com field shape and record
# the originating provider. Exit 0 with normalized JSON on success, exit 1
# with the provider's failure message, exit 2 on an unparseable response.
myloc_normalize() {
    python3 - "$1" "$2" <<'PY_MYLOC_NORM'
import json
import sys
from urllib.parse import urlparse

host = (urlparse(sys.argv[1]).hostname or "").lower()
try:
    data = json.loads(sys.argv[2])
except (ValueError, UnicodeError):
    sys.exit(2)
if not isinstance(data, dict):
    sys.exit(2)

if host.endswith("ipwho.is"):
    ok = data.get("success") is True
    conn = data.get("connection")
    conn = conn if isinstance(conn, dict) else {}
    tz = data.get("timezone")
    tz = tz if isinstance(tz, dict) else {}
    asn = ""
    if conn.get("asn"):
        asn = "AS%d" % conn["asn"]
        if conn.get("org"):
            asn += " " + str(conn["org"])
    out = {
        "status": "success" if ok else "fail",
        "message": "" if ok else str(data.get("message") or "unknown"),
        "query": data.get("ip"),
        "country": data.get("country"),
        "countryCode": data.get("country_code"),
        "regionName": data.get("region"),
        "city": data.get("city"),
        "zip": data.get("postal"),
        "lat": data.get("latitude"),
        "lon": data.get("longitude"),
        "timezone": tz.get("id"),
        "isp": conn.get("isp"),
        "org": conn.get("org"),
        "as": asn or None,
        "provider": "ipwho.is",
    }
else:
    # ip-api.com and any user-supplied ip-api-compatible endpoint pass through.
    out = dict(data)
    out["provider"] = host or "custom"

if out.get("status") == "success" and isinstance(out.get("query"), str) and out["query"]:
    print(json.dumps(out, ensure_ascii=False))
    sys.exit(0)
print(str(out.get("message") or "unknown"))
sys.exit(1)
PY_MYLOC_NORM
}

myloc_query() {
    local ns="${1:-}" key file url json answer last_msg="" last_err="" errfile
    local -a cmd
    key=$(myloc_cache_key "$ns")
    file=$(myloc_cache_file 2>/dev/null || true)
    errfile=$(mktemp "${TMPDIR:-/tmp}/nns-myloc.XXXXXX") || return 1
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        cmd=("${NNS_MYLOC_CURL:-/usr/bin/curl}" -4fsS --noproxy '*' --connect-timeout 3 --max-time 10 "$url")
        if [[ -n "$ns" ]]; then
            json=$("$(ip_binary)" netns exec "$ns" "${cmd[@]}" 2>"$errfile") || {
                last_err=$(<"$errfile")
                continue
            }
        else
            json=$("${cmd[@]}" 2>"$errfile") || {
                last_err=$(<"$errfile")
                continue
            }
        fi
        [[ -n "$json" ]] || continue
        if answer=$(myloc_normalize "$url" "$json"); then
            rm -f "$errfile"
            if [[ -n "$file" ]]; then
                [[ "$file" != */* ]] || mkdir -p "${file%/*}" 2>/dev/null || true
                myloc_cache_write "$file" "$key" "$url" 2>/dev/null || true
            fi
            printf '%s\n' "$answer"
            return 0
        fi
        [[ -n "$answer" ]] && last_msg=$answer
    done < <(myloc_query_urls "$key" "$file")
    rm -f "$errfile"
    if [[ -n "$last_err" ]]; then
        printf '%s\n' "$last_err" >&2
    fi
    if [[ -n "$last_msg" ]]; then
        printf 'myloc: last provider error: %s\n' "$last_msg" >&2
    fi
    return 1
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
provider = data.get("provider")
if not isinstance(provider, str) or not provider:
    provider = "ip-api.com"
transport = "; HTTP" if provider == "ip-api.com" else ""
print("Provider:          " + provider + " (approximate location" + transport + ")")
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
