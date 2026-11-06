#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
BASE_DIR="$TEST_TMP/apps"
RUN_DIR="$TEST_TMP/run"
GATEWAY_BASE_DIR="$TEST_TMP/gateways"
mkdir -p "$BASE_DIR" "$RUN_DIR" "$GATEWAY_BASE_DIR"
source "$ROOT/src/70-run-status.sh"
source "$ROOT/src/60-gateway.sh"
log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
require_root() { :; }
install() { command install "$@"; }
cfg_file() { printf '%s/%s/config\n' "$BASE_DIR" "$1"; }
load_cfg() { DEFAULT_PROFILE="test.ovpn"; }
vpn_type_for_app() { printf 'openvpn\n'; }
effective_via_for_app() { printf 'host\n'; }
app_is_started() { return 1; }
list_remote_auto_records() { :; }
gateway_inventory_record() {
    printf 'GATEWAY|%s|public|active|host|vpn.example.net:1194/udp|1|0|0|local\n' "$1"
}
gateway_external_client_records() { :; }

[[ "$(list_managed_objects)" == 'No apps configured.' ]] || fail 'empty local inventory'
[[ "$(list_all_objects)" == 'No apps or exported clients configured.' ]] || fail 'empty full inventory'
[[ "$(list_apps)" == 'No NNS apps installed.' ]] || fail 'empty namespaces inventory'
[[ "$(list_gateways_overview)" == 'No managed gateways configured.' ]] || fail 'empty gateways inventory'
[[ "$(list_external_clients_overview)" == 'No external gateway clients configured.' ]] || fail 'empty client identities inventory'

mkdir "$BASE_DIR/editor"
touch "$BASE_DIR/editor/config"
output=$(list_managed_objects)
grep -Fq 'Apps:' <<<"$output" || fail 'app section missing'
grep -Fq 'vpn-client/ovpn' <<<"$output" || fail 'namespace type missing'
grep -Fq 'editor' <<<"$output" || fail 'local app missing'
[[ "$(grep -c '^Name ' <<<"$output")" == 1 ]] || fail 'app header duplicated'
! grep -Fq 'Exported clients:' <<<"$output" || fail 'unexpected exported clients'

mkdir "$GATEWAY_BASE_DIR/vpn"
touch "$GATEWAY_BASE_DIR/vpn/gateway.cfg"
output=$(list_managed_objects)
grep -Fq 'vpn-client/ovpn' <<<"$output" || fail 'mixed local namespace missing'
grep -Fq 'openvpn-server' <<<"$output" || fail 'server type missing'
grep -Fq 'vpn' <<<"$output" || fail 'server name missing'
[[ "$(grep -c '^Name ' <<<"$output")" == 1 ]] || fail 'mixed inventory duplicates header'
! grep -Fq 'Gateways:' <<<"$output" || fail 'duplicated gateway inventory in Apps'
output=$(list_all_objects)
grep -Fq 'Apps:' <<<"$output" || fail 'full inventory missing apps'
! grep -Fq 'Exported clients:' <<<"$output" || fail 'full inventory renders empty client table'

rm -rf "$BASE_DIR/editor"
output=$(list_managed_objects)
grep -Fq 'openvpn-server' <<<"$output" || fail 'server-only inventory missing server'
! grep -Fq 'vpn-client/' <<<"$output" || fail 'server-only inventory has namespace'
[[ "$(list_apps)" == 'No NNS apps installed.' ]] || fail 'namespace-only command includes server'

rm -rf "$GATEWAY_BASE_DIR/vpn"
list_remote_auto_records() {
    case "$1" in
        inventory-clients) printf 'CLIENT|laptop|active|remote-gw|vpn.example.net:1194/udp|2026-11-06|yes|remote:app\n' ;;
    esac
}
[[ "$(list_managed_objects)" == 'No apps configured.' ]] || fail 'remote-only credentials leak into local apps'
output=$(list_all_objects)
! grep -Fq 'Apps:' <<<"$output" || fail 'remote-only exported credentials create apps table'
grep -Fq 'Exported clients:' <<<"$output" || fail 'remote credentials missing'
grep -Fq 'laptop' <<<"$output" || fail 'remote credential missing name'

list_remote_auto_records() {
    case "$1" in
        inventory-gateways) printf 'WARN|app|inventory-gateways\n' ;;
    esac
}
[[ "$(list_managed_objects)" == 'No apps configured.' ]] || fail 'remote connection failure affects local inventory'
output=$(list_all_objects)
grep -Fq 'Apps:' <<<"$output" || fail 'remote gateway should appear as typed app'
grep -Fq 'remote-gateway' <<<"$output" || fail 'remote gateway type missing'
grep -Fq 'offline' <<<"$output" || fail 'offline gateway lost'
! grep -Fq 'Exported clients:' <<<"$output" || fail 'empty exported credentials table shown'

# Command dispatch: list/apps same unified table, namespaces filtered.
NNS_APP_SOURCE_ONLY=1 source "$ROOT/src/90-main.sh"
reexec_as_root_if_needed() { :; }
list_remote_auto_records() { :; }
mkdir "$GATEWAY_BASE_DIR/mlvpn"
touch "$GATEWAY_BASE_DIR/mlvpn/gateway.cfg"
output=$(main list)
grep -Fq 'mlvpn' <<<"$output" || fail 'CLI list omits managed server'
grep -Fq 'openvpn-server' <<<"$output" || fail 'CLI list lacks server type'
[[ "$(main list apps)" == "$output" ]] || fail 'list apps differs from default'
[[ "$(main list namespaces)" == 'No NNS apps installed.' ]] || fail 'list namespaces includes server'
[[ "$(main list local-clients)" == 'No NNS apps installed.' ]] || fail 'list local-clients alias broken'
grep -Fq 'mlvpn' <<<"$(main list gateways)" || fail 'list gateways missing server'
grep -Fq 'mlvpn' <<<"$(main list gateway)" || fail 'legacy gateway alias broken'
grep -Fq 'mlvpn' <<<"$(main list all)" || fail 'list all missing server'
printf 'Unified inventory tests passed.\n'
