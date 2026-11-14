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
echo 'myloc context, formatting, and failure tests passed.'
