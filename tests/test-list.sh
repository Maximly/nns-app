#!/usr/bin/env bash
# Inventory rendering tests use a private filesystem and mocked state sources.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
BASE_DIR="$TEST_TMP/apps"
RUN_DIR="$TEST_TMP/run"
GATEWAY_BASE_DIR="$TEST_TMP/gateways"
mkdir -p "$BASE_DIR" "$RUN_DIR" "$GATEWAY_BASE_DIR"

# Source functions, not the built program, to keep state in the private tree.
# shellcheck source=/dev/null
source "$ROOT/src/70-run-status.sh"
# shellcheck source=/dev/null
source "$ROOT/src/60-gateway.sh"
log() { printf '%s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
require_root() { :; }
install() { command install "$@"; }
cfg_file() { printf '%s/%s/config\n' "$BASE_DIR" "$1"; }
load_cfg() { DEFAULT_PROFILE="test.ovpn"; }
vpn_type_for_app() { printf 'openvpn\n'; }
vpn_type_label() { printf 'openvpn\n'; }
effective_via_for_app() { printf 'host\n'; }
app_is_started() { return 1; }
list_remote_auto_records() { :; }
gateway_inventory_record() {
    printf 'GATEWAY|%s|public|active|host|vpn.example.net:1194/udp|1|0|0|local\n' "$1"
}
gateway_external_client_records() { :; }

output=$(list_managed_objects)
[[ "$output" == 'No applications or local gateways configured.' ]] ||
    fail 'default empty inventory should show one short message and no headers'
output=$(list_all_objects)
[[ "$output" == 'No applications, gateways, or external clients configured.' ]] ||
    fail 'combined empty inventory should show one short message and no headers'
[[ "$(list_apps)" == 'No NNS apps installed.' ]] ||
    fail 'empty apps inventory should omit table headers'
[[ "$(list_gateways_overview)" == 'No managed gateways configured.' ]] ||
    fail 'empty gateways inventory should omit table headers'
[[ "$(list_external_clients_overview)" == 'No external gateway clients configured.' ]] ||
    fail 'empty clients inventory should omit table headers'
[[ "$(gateway_list)" == 'No managed gateways configured.' ]] ||
    fail 'empty direct gateway list should omit table headers'

mkdir "$BASE_DIR/editor"
touch "$BASE_DIR/editor/config"
output=$(list_managed_objects)
grep -Fq 'Applications:' <<<"$output" || fail 'default inventory missing installed app'
grep -Fq 'editor' <<<"$output" || fail 'default inventory missing app row'
! grep -Fq 'Gateways:' <<<"$output" || fail 'default inventory shows empty gateway section'
output=$(list_all_objects)
grep -Fq 'Applications:' <<<"$output" || fail 'present app section missing'
grep -Fq 'editor' <<<"$output" || fail 'present app row missing'
! grep -Fq 'Gateways:' <<<"$output" || fail 'empty gateway section shown'
! grep -Fq 'External clients:' <<<"$output" || fail 'empty client section shown'
[[ "$(grep -c '^Name ' <<<"$output")" == 1 ]] || fail 'app header repeated'

mkdir "$GATEWAY_BASE_DIR/vpn"
touch "$GATEWAY_BASE_DIR/vpn/gateway.cfg"
output=$(list_managed_objects)
grep -Fq 'Applications:' <<<"$output" || fail 'default mixed inventory missing app section'
grep -Fq 'Gateways:' <<<"$output" || fail 'default mixed inventory missing local gateway'
grep -Fq 'vpn' <<<"$output" || fail 'default mixed inventory missing gateway row'
! grep -Fq 'External clients:' <<<"$output" || fail 'default inventory should exclude clients'
output=$(list_all_objects)
grep -Fq 'Applications:' <<<"$output" || fail 'app section missing in mixed inventory'
grep -Fq 'Gateways:' <<<"$output" || fail 'gateway section missing in mixed inventory'
! grep -Fq 'External clients:' <<<"$output" || fail 'empty client section shown in mixed inventory'
[[ "$(grep -c '^Gateway ' <<<"$output")" == 1 ]] || fail 'gateway header repeated'

# A server-only host should show its gateway, but not an empty app table.
rm -rf "$BASE_DIR/editor"
output=$(list_managed_objects)
! grep -Fq 'Applications:' <<<"$output" || fail 'server-only inventory shows empty apps'
grep -Fq 'Gateways:' <<<"$output" || fail 'server-only inventory hides OpenVPN server'
grep -Fq 'vpn' <<<"$output" || fail 'server-only inventory missing OpenVPN server row'
[[ "$(list_apps)" == 'No NNS apps installed.' ]] || fail 'list apps should stay namespace-only'

# Only clients can be present (no local apps/gateways) when remote inventory
# supplies them; ensure those records still render without empty sections.
rm -rf "$GATEWAY_BASE_DIR/vpn"
list_remote_auto_records() {
    case "$1" in
        inventory-clients)
            printf 'CLIENT|laptop|active|remote-gw|vpn.example.net:1194/udp|2026-11-06|yes|remote:app\n'
            ;;
    esac
}
output=$(list_managed_objects)
[[ "$output" == 'No applications or local gateways configured.' ]] ||
    fail 'default local list must exclude remote-only client records'
output=$(list_all_objects)
! grep -Fq 'Applications:' <<<"$output" || fail 'empty apps section shown for remote client'
! grep -Fq 'Gateways:' <<<"$output" || fail 'empty gateways section shown for remote client'
grep -Fq 'External clients:' <<<"$output" || fail 'remote clients section missing'
grep -Fq 'laptop' <<<"$output" || fail 'remote client row missing'

# An offline remote is a material status row, not an empty table.
list_remote_auto_records() {
    case "$1" in
        inventory-gateways) printf 'WARN|app|inventory-gateways\n' ;;
    esac
}
output=$(list_managed_objects)
[[ "$output" == 'No applications or local gateways configured.' ]] ||
    fail 'default list must not display remote gateway failure as a local instance'
output=$(list_gateways_overview)
grep -Fq 'offline' <<<"$output" || fail 'list gateways should retain remote offline state'
output=$(list_all_objects)
grep -Fq 'Gateways:' <<<"$output" || fail 'offline remote gateway section hidden'
grep -Fq 'offline' <<<"$output" || fail 'offline remote status hidden'
! grep -Fq 'Applications:' <<<"$output" || fail 'empty apps section shown for offline remote'
! grep -Fq 'External clients:' <<<"$output" || fail 'empty clients section shown for offline remote'

# Exercise the user-facing CLI dispatch without touching the actual host.
NNS_APP_SOURCE_ONLY=1 source "$ROOT/src/90-main.sh"
reexec_as_root_if_needed() { :; }
# CLI 'list' must include a server. Explicit 'list apps' must not.
list_remote_auto_records() { :; }
mkdir "$GATEWAY_BASE_DIR/mlvpn"
touch "$GATEWAY_BASE_DIR/mlvpn/gateway.cfg"
output=$(main list)
grep -Fq 'mlvpn' <<<"$output" || fail 'CLI list does not show locally managed OpenVPN server'
! grep -Fq 'Applications:' <<<"$output" || fail 'CLI list shows empty apps table'
! grep -Fq 'External clients:' <<<"$output" || fail 'CLI list shows exported clients'
[[ "$(main list apps)" == 'No NNS apps installed.' ]] || fail 'CLI list apps includes gateway'
grep -Fq 'mlvpn' <<<"$(main list gateways)" || fail 'CLI list gateways omits server'
grep -Fq 'mlvpn' <<<"$(main list gateway)" || fail 'legacy gateway alias broken'
grep -Fq 'mlvpn' <<<"$(main list all)" || fail 'CLI list all omits server'

printf 'List rendering tests passed.\n' 
