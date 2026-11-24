#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export NNS_APP_SOURCE_ONLY=1
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export NNS_APP_LOCK_DIR="$TEST_TMP/locks"
source "$ROOT/install_linux"
fail() { echo "FAIL: $*" >&2; exit 1; }
fixture='{"status":"success","query":"203.0.113.41","country":"Example Land","countryCode":"EX","regionName":"Example Region","city":"Example City","isp":"Example ISP","org":"Example Network","as":"AS64501 Example","lat":0,"lon":3.1}'

# Host operation requires neither root nor a second network namespace.
(
    require_root() { fail 'host myloc required root'; }
    current_nns_app() { return 1; }
    myip_host_namespace() { return 0; }
    myloc_query() { [[ -z "$1" ]] || fail 'host lookup attempted namespace'; printf '%s\n' "$fixture"; }
    output=$(myloc_command)
    grep -Fq 'Public IPv4:       203.0.113.41' <<<"$output" || fail 'host public IPv4'
    grep -Fq 'Country:           Example Land' <<<"$output" || fail 'country output'
    grep -Fq 'ASN:               AS64501 Example' <<<"$output" || fail 'AS output'
    grep -Fq 'Coordinates:       0, 3.1' <<<"$output" || fail 'coordinates including zero'
)
(
    current_nns_app() { printf 'local-vpn\n'; }
    myloc_query() { [[ -z "$1" ]] || fail 'current context queried wrong namespace'; printf '%s\n' "$fixture"; }
    output=$(myloc_command --json)
    python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["query"] == "203.0.113.41"' <<<"$output" || fail 'JSON output'
)
(
    require_root() { :; }
    validate_app_name() { [[ "$1" == testvpn ]] || fail 'wrong named app'; }
    managed_gateway_exists() { return 1; }
    load_cfg() { NS_NAME='nns-testvpn'; }
    myloc_namespace_ready() { [[ "$1" == nns-testvpn ]]; }
    myloc_query() { [[ "$1" == nns-testvpn ]] || fail 'named VPN did not use its namespace'; printf '%s\n' "$fixture"; }
    output=$(myloc_command testvpn)
    grep -Fq 'Context:           app:testvpn' <<<"$output" || fail 'named app context'
)
(
    require_root() { :; }
    validate_app_name() { :; }
    managed_gateway_exists() { [[ "$1" == relay ]]; }
    load_gateway_cfg() { VIA_APP=upstream; }
    systemctl() { [[ "$1" == is-active ]] || fail 'wrong service check'; }
    load_cfg() { [[ "$1" == upstream ]] || fail 'wrong upstream'; NS_NAME=nns-upstream; }
    myloc_namespace_ready() { [[ "$1" == nns-upstream ]]; }
    myloc_query() { [[ "$1" == nns-upstream ]] || fail 'gateway leaked through host'; printf '%s\n' "$fixture"; }
    output=$(myloc_command relay)
    grep -Fq 'Context:           gateway:relay via upstream' <<<"$output" || fail 'gateway context'
)
(
    require_root() { :; }
    validate_app_name() { :; }
    managed_gateway_exists() { return 1; }
    load_cfg() { NS_NAME=nns-missing; }
    myloc_namespace_ready() { return 1; }
    myloc_query() { fail 'queried the host after a missing namespace'; }
    die() { echo "$*" >&2; return 1; }
    if (myloc_command missing) >"$TEST_TMP/missing.out" 2>&1; then fail 'missing namespace accepted'; fi
    grep -Fq 'no active namespace' "$TEST_TMP/missing.out" || fail 'missing namespace diagnostic'
)
(
    myloc_query() { printf '%s\n' '{"status":"fail","message":"private range","query":"0.0.0.0"}'; }
    current_nns_app() { return 1; }
    myip_host_namespace() { return 0; }
    if (myloc_command --json) >"$TEST_TMP/error.out" 2>&1; then fail 'failed API response accepted'; fi
    grep -Fq 'private range' "$TEST_TMP/error.out" || fail 'API failure did not show error'
)
(
    require_root() { :; }
    validate_app_name() { :; }
    managed_gateway_exists() { return 1; }
    load_cfg() { NS_NAME=nns-private; }
    app_split_tunnel() { [[ "$1" == private-app ]]; }
    cfg_read_value() { [[ "$1" == private-app && "$2" == KILLSWITCH ]] || fail 'wrong split guard lookup'; printf 'on\n'; }
    myloc_namespace_ready() { return 0; }
    myloc_query() { fail 'queried a kill-switched split tunnel'; }
    die() { echo "$*" >&2; return 1; }
    if (myloc_command private-app) >"$TEST_TMP/split.out" 2>&1; then fail 'split tunnel with kill switch accepted'; fi
    grep -Fq 'no public Internet exit' "$TEST_TMP/split.out" || fail 'split-tunnel diagnostic'
)
(
    require_root() { :; }
    validate_app_name() { :; }
    managed_gateway_exists() { return 1; }
    load_cfg() { NS_NAME=nns-soft; }
    app_split_tunnel() { [[ "$1" == soft-app ]]; }
    cfg_read_value() { [[ "$1" == soft-app && "$2" == KILLSWITCH ]] || fail 'wrong split guard lookup'; printf 'off\n'; }
    myloc_namespace_ready() { return 0; }
    myloc_query() { [[ "$1" == nns-soft ]] || fail 'split app with kill switch off did not use namespace'; printf '%s\n' "$fixture"; }
    output=$(myloc_command soft-app)
    grep -Fq 'Context:           app:soft-app' <<<"$output" || fail 'soft split app context'
)
(
    require_root() { :; }
    validate_app_name() { :; }
    managed_gateway_exists() { [[ "$1" == relay ]]; }
    load_gateway_cfg() { VIA_APP=upstream; }
    systemctl() { [[ "$1" == is-active ]] || fail 'wrong service check'; }
    load_cfg() { NS_NAME=nns-upstream; }
    app_split_tunnel() { [[ "$1" == upstream ]]; }
    cfg_read_value() { [[ "$1" == upstream && "$2" == KILLSWITCH ]] || fail 'wrong gateway guard lookup'; printf 'on\n'; }
    myloc_namespace_ready() { [[ "$1" == nns-upstream ]]; }
    myloc_query() { fail 'gateway via split tunnel queried'; }
    die() { echo "$*" >&2; return 1; }
    if (myloc_command relay) >"$TEST_TMP/gw-split.out" 2>&1; then fail 'gateway via split tunnel accepted'; fi
    grep -Fq 'gateway:relay via upstream' "$TEST_TMP/gw-split.out" || fail 'gateway split diagnostic context'
)
(
    printf '%s\n' 'bad JSON' | myloc_format json host >"$TEST_TMP/bad.out" 2>&1 && fail 'invalid JSON accepted'
    grep -Fq 'Invalid geolocation response' "$TEST_TMP/bad.out" || fail 'invalid JSON diagnostic'
)
# Provider normalization: ipwho.is responses map onto the ip-api.com shape and
# record the provider; failures keep the provider message; garbage is rejected.
(
    whois_fixture='{"ip":"203.0.113.55","success":true,"type":"IPv4","country":"Example Land","country_code":"EX","region":"Example Region","city":"Example City","postal":"12345","latitude":4.2,"longitude":5.3,"connection":{"asn":64500,"org":"Example Org","isp":"Example ISP"},"timezone":{"id":"Example/Zone"}}'
    out=$(myloc_normalize 'https://ipwho.is/' "$whois_fixture") || fail 'ipwho.is normalization rejected'
    python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["status"]=="success" and d["query"]=="203.0.113.55" and d["countryCode"]=="EX" and d["lat"]==4.2 and d["lon"]==5.3 and d["as"]=="AS64500 Example Org" and d["provider"]=="ipwho.is", d' <<<"$out" || fail 'ipwho.is normalization fields'
    if myloc_normalize 'https://ipwho.is/' '{"success":false,"message":"reserved range"}' >"$TEST_TMP/norm-fail.out" 2>&1; then
        fail 'failed ipwho.is response accepted'
    fi
    grep -Fq 'reserved range' "$TEST_TMP/norm-fail.out" || fail 'ipwho.is failure message lost'
    if myloc_normalize 'https://ipwho.is/' 'not json' >/dev/null 2>&1; then fail 'invalid provider JSON accepted'; fi
    passthrough=$(myloc_normalize 'http://ip-api.com/json/' '{"status":"success","query":"203.0.113.9","country":"X"}') ||
        fail 'ip-api passthrough rejected'
    grep -Fq '"provider": "ip-api.com"' <<<"$passthrough" || fail 'passthrough provider missing'
)
# Real myloc_query tries the next provider when the primary is unreachable,
# honors the URL overrides, and surfaces the last provider error.
(
    cat >"$TEST_TMP/fake-myloc-curl" <<'S'
#!/bin/bash
case "$*" in
    *ip-api.com*) exit 7 ;;
    *ipwho.is*) printf '%s\n' '{"ip":"203.0.113.55","success":true,"country":"Example Land","country_code":"EX","city":"Example City","connection":{"asn":64500,"org":"Example Org","isp":"Example ISP"},"timezone":{"id":"Example/Zone"}}'; exit 0 ;;
    *) exit 7 ;;
esac
S
    chmod +x "$TEST_TMP/fake-myloc-curl"
    out=$(NNS_MYLOC_CURL="$TEST_TMP/fake-myloc-curl" myloc_query '') || fail 'fallback provider did not answer'
    grep -Fq '203.0.113.55' <<<"$out" || fail 'fallback provider result missing'
    grep -Fq '"provider": "ipwho.is"' <<<"$out" || fail 'fallback provider not recorded'
    out=$(NNS_MYLOC_CURL="$TEST_TMP/fake-myloc-curl" NNS_MYLOC_URL='https://ipwho.is/' myloc_query '') ||
        fail 'primary URL override rejected'
    grep -Fq '203.0.113.55' <<<"$out" || fail 'primary URL override did not answer'
    if NNS_MYLOC_CURL="$TEST_TMP/fake-myloc-curl" NNS_MYLOC_FALLBACK_URLS='' myloc_query '' >"$TEST_TMP/nofb.out" 2>&1; then
        fail 'disabled fallback accepted'
    fi
    cat >"$TEST_TMP/fake-api-fail-curl" <<'S'
#!/bin/bash
case "$*" in
    *ip-api.com*) printf '%s\n' '{"status":"fail","message":"private range","query":"0.0.0.0"}'; exit 0 ;;
    *) printf '%s\n' '{"ip":"203.0.113.55","success":true,"country":"Example Land","country_code":"EX","city":"Example City","connection":{"asn":64500,"org":"Example Org","isp":"Example ISP"},"timezone":{"id":"Example/Zone"}}'; exit 0 ;;
esac
S
    chmod +x "$TEST_TMP/fake-api-fail-curl"
    out=$(NNS_MYLOC_CURL="$TEST_TMP/fake-api-fail-curl" myloc_query '') ||
        fail 'fallback after API-level failure did not answer'
    grep -Fq '203.0.113.55' <<<"$out" || fail 'fallback after API-level failure missing'
    if NNS_MYLOC_CURL="$TEST_TMP/fake-api-fail-curl" NNS_MYLOC_FALLBACK_URLS='' myloc_query '' >"$TEST_TMP/apifail.out" 2>"$TEST_TMP/apifail.err"; then
        fail 'API-level failure accepted as success'
    fi
    grep -Fq 'private range' "$TEST_TMP/apifail.err" || fail 'provider failure detail lost'
)
# The provider that last worked is remembered per egress and tried first on
# later runs, so a blocked primary is not re-probed every time.
(
    cat >"$TEST_TMP/rec-curl" <<'S'
#!/bin/bash
printf '%s\n' "$*" >>"${NNS_REC_FILE:?}"
case "$*" in
    *ipwho.is*) printf '%s\n' '{"ip":"203.0.113.55","success":true,"country":"Example Land","country_code":"EX","city":"Example City","connection":{"asn":64500,"org":"Example Org","isp":"Example ISP"},"timezone":{"id":"Example/Zone"}}'; exit 0 ;;
    *) exit 7 ;;
esac
S
    chmod +x "$TEST_TMP/rec-curl"
    rm -f "$TEST_TMP/myloc-cache" "$TEST_TMP/order1" "$TEST_TMP/order2" "$TEST_TMP/order3"
    out=$(NNS_MYLOC_CURL="$TEST_TMP/rec-curl" NNS_MYLOC_CACHE="$TEST_TMP/myloc-cache" NNS_REC_FILE="$TEST_TMP/order1" myloc_query '') ||
        fail 'first provider-cache run failed'
    grep -Fq '203.0.113.55' <<<"$out" || fail 'first provider-cache run missing result'
    grep -Fq 'ip-api.com' "$TEST_TMP/order1" || fail 'primary not attempted on first run'
    out=$(NNS_MYLOC_CURL="$TEST_TMP/rec-curl" NNS_MYLOC_CACHE="$TEST_TMP/myloc-cache" NNS_REC_FILE="$TEST_TMP/order2" myloc_query '') ||
        fail 'second provider-cache run failed'
    head -n1 "$TEST_TMP/order2" | grep -Fq 'ipwho.is' || fail 'cached provider not tried first'
    # A stale cached provider is re-evaluated and the cache rewritten.
    self_key=$(myloc_cache_key '')
    printf '%s\t%s\t%s\n' "$self_key" 'https://gone.example/' 1 > "$TEST_TMP/myloc-cache"
    out=$(NNS_MYLOC_CURL="$TEST_TMP/rec-curl" NNS_MYLOC_CACHE="$TEST_TMP/myloc-cache" NNS_REC_FILE="$TEST_TMP/order3" myloc_query '') ||
        fail 'stale provider-cache run failed'
    grep -Fq '203.0.113.55' <<<"$out" || fail 'stale provider-cache run missing result'
    grep -Fq "$self_key"$'\t'"https://ipwho.is/" "$TEST_TMP/myloc-cache" || fail 'cache not rewritten to working provider'
    # The cache is keyed per network namespace, not globally.
    cat >"$TEST_TMP/fake-ip" <<'S'
#!/bin/bash
shift 3
exec "$@"
S
    chmod +x "$TEST_TMP/fake-ip"
    ip_binary() { printf '%s\n' "$TEST_TMP/fake-ip"; }
    rm -f "$TEST_TMP/myloc-cache2" "$TEST_TMP/order4"
    out=$(NNS_MYLOC_CURL="$TEST_TMP/rec-curl" NNS_MYLOC_CACHE="$TEST_TMP/myloc-cache2" NNS_REC_FILE="$TEST_TMP/order4" myloc_query nns-one) ||
        fail 'namespaced provider-cache run failed'
    grep -Fq '203.0.113.55' <<<"$out" || fail 'namespaced provider-cache run missing result'
    grep -Fq 'ns:nns-one'$'\t''https://ipwho.is/' "$TEST_TMP/myloc-cache2" || fail 'namespace cache key missing'
    # A namespace path (PID 1) is probed through nsenter, not `ip netns exec`.
    cat >"$TEST_TMP/fake-nsenter" <<'S'
#!/bin/bash
shift 1
exec "$@"
S
    chmod +x "$TEST_TMP/fake-nsenter"
    myloc_nsenter() { printf '%s\n' "$TEST_TMP/fake-nsenter"; }
    rm -f "$TEST_TMP/myloc-cache3" "$TEST_TMP/order5"
    out=$(NNS_MYLOC_CURL="$TEST_TMP/rec-curl" NNS_MYLOC_CACHE="$TEST_TMP/myloc-cache3" NNS_REC_FILE="$TEST_TMP/order5" myloc_query /proc/1/ns/net) ||
        fail 'host-namespace path probe failed'
    grep -Fq '203.0.113.55' <<<"$out" || fail 'host-namespace path probe missing result'
    grep -Fq 'ns:/proc/1/ns/net'$'\t''https://ipwho.is/' "$TEST_TMP/myloc-cache3" || fail 'host-namespace path cache key missing'
)
# A host-exit gateway geolocates the host's egress. Inside the host namespace
# the current shell is probed; elsewhere the probe targets PID 1's namespace
# through nsenter, and a missing nsenter is a clear diagnostic.
(
    require_root() { :; }
    validate_app_name() { :; }
    managed_gateway_exists() { [[ "$1" == mlhome ]]; }
    load_gateway_cfg() { VIA_APP=host; }
    systemctl() { [[ "$1" == is-active ]] || fail 'wrong service check'; }
    myip_host_namespace() { return 1; }
    myloc_nsenter() { printf '%s\n' "$TEST_TMP/fake-nsenter-ok"; }
    myloc_query() {
        [[ "$1" == /proc/1/ns/net ]] || fail 'host-exit probe did not target PID 1 namespace'
        printf '%s\n' "$fixture"
    }
    output=$(myloc_command mlhome)
    grep -Fq 'Context:           gateway:mlhome via host' <<<"$output" || fail 'host-exit gateway context'
)
(
    require_root() { :; }
    validate_app_name() { :; }
    managed_gateway_exists() { [[ "$1" == mlhome ]]; }
    load_gateway_cfg() { VIA_APP=host; }
    systemctl() { :; }
    myip_host_namespace() { return 1; }
    myloc_nsenter() { return 1; }
    myloc_query() { fail 'queried without nsenter'; }
    die() { echo "$*" >&2; return 1; }
    if (myloc_command mlhome) >"$TEST_TMP/nsenter.out" 2>&1; then fail 'host-exit probe accepted without nsenter'; fi
    grep -Fq 'nsenter (util-linux) is required' "$TEST_TMP/nsenter.out" || fail 'missing nsenter diagnostic'
)
(
    require_root() { fail 'host-ns gateway myloc required root'; }
    validate_app_name() { :; }
    managed_gateway_exists() { [[ "$1" == mlhome ]]; }
    load_gateway_cfg() { VIA_APP=host; }
    systemctl() { :; }
    myip_host_namespace() { return 0; }
    myloc_query() { [[ -z "$1" ]] || fail 'host-ns gateway probe used a namespace'; printf '%s\n' "$fixture"; }
    output=$(myloc_command mlhome)
    grep -Fq 'Context:           gateway:mlhome via host' <<<"$output" || fail 'host-ns gateway context'
)
echo 'myloc context, formatting, and failure tests passed.'
