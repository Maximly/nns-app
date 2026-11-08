#!/usr/bin/env bash
# Unified managed-client CLI: automatic identity creation and revoke-first removal.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1
source "$ROOT/nns-app-install.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { :; }
warn() { :; }
require_root() { :; }
reexec_as_root_if_needed() { :; }
acquire_lock() { :; }
release_lock() { :; }
gateway_dir() { printf '%s/gateways/%s\n' "$TEST_TMP" "$1"; }
gateway_cfg_file() { printf '%s/gateways/%s/gateway.cfg\n' "$TEST_TMP" "$1"; }
gateway_clients_dir() { printf '%s/gateways/%s/clients\n' "$TEST_TMP" "$1"; }
gateway_client_dir() { printf '%s/gateways/%s/clients/%s\n' "$TEST_TMP" "$1" "$2"; }
load_gateway_cfg() {
    reset_gateway_cfg_vars
    # shellcheck disable=SC1090
    source "$(gateway_cfg_file "$1")"
}
gateway_client_load() {
    local path
    path="$(gateway_client_dir "$1" "$2")/client.cfg"
    [[ -f "$path" ]] || die "Missing client '$2'."
    reset_gateway_client_vars
    # shellcheck disable=SC1090
    source "$path"
}
mkdir -p "$TEST_TMP/gateways/ovpn/clients" "$TEST_TMP/gateways/awg/clients" \
         "$TEST_TMP/gateways/cloak/clients"
cat >"$TEST_TMP/gateways/ovpn/gateway.cfg" <<'EOF'
GATEWAY_BACKEND=openvpn
TRANSPORT=direct
OPENVPN_COMPAT=modern
PUBLIC_HOST=198.51.100.40
PUBLIC_PORT=1194
LISTEN_PROTO=udp
EOF
cat >"$TEST_TMP/gateways/awg/gateway.cfg" <<'EOF'
GATEWAY_BACKEND=amneziawg
TRANSPORT=direct
EOF
cat >"$TEST_TMP/gateways/cloak/gateway.cfg" <<'EOF'
GATEWAY_BACKEND=openvpn
TRANSPORT=cloak
OPENVPN_COMPAT=modern
PUBLIC_HOST=198.51.100.40
PUBLIC_PORT=443
LISTEN_PROTO=tcp
EOF
TRACE="$TEST_TMP/trace"
: >"$TRACE"
new_client() {
    local app=$1 client=$2 dir
    dir=$(gateway_client_dir "$app" "$client")
    mkdir -p "$dir"
    printf 'CLIENT_NAME="%s"\nSTATUS="active"\n' "$client" >"$dir/client.cfg"
    printf 'private-%s-%s\n' "$app" "$client" >"$dir/client.key"
    printf 'create:%s:%s\n' "$app" "$client" >>"$TRACE"
}
gateway_client_add() { new_client "$1" "$2"; }
gateway_client_export() {
    local app=$1 client=$2 output=$3 format=$4
    [[ -e "$(gateway_client_dir "$app" "$client")/client.cfg" ]] || fail 'export without client'
    [[ "$format" == ovpn || "$format" == nnslink ]] || fail 'bad format'
    if [[ "$output" != - ]]; then
        printf 'profile:%s:%s:%s\n' "$app" "$client" "$format" >"$output"
    fi
}
gateway_cloak_export_client_pair() {
    local app=$1 client=$2 output=$3
    [[ -f "$(gateway_client_dir "$app" "$client")/client.cfg" ]] || fail 'cloak client missing'
    printf 'ovpn' >"$output"
    printf 'json' >"${output%.ovpn}.cloak.json"
}
gateway_client_fixed_ip() { printf 'fixed:%s:%s\n' "$1" "$2" >>"$TRACE"; }
gateway_client_route_mode() { printf 'route:%s:%s:%s\n' "$1" "$2" "$3" >>"$TRACE"; }
awg_server_client_export() {
    local app=$1 client=$2 output=$3 mode=$4
    [[ -f "$(gateway_client_dir "$app" "$client")/client.cfg" ]] || new_client "$app" "$client"
    printf 'awg:%s:%s:%s\n' "$app" "$client" "$mode" >"$output"
}
systemctl() {
    if [[ "$1" == is-active ]]; then
        [[ "${TEST_SERVICE_ACTIVE:-off}" == on ]]
    else
        [[ "${FAIL_RESTART:-off}" != on ]]
    fi
}
gateway_client_revoke() {
    local app=$1 client=$2 path
    path="$(gateway_client_dir "$app" "$client")/client.cfg"
    [[ -f "$path" ]] || die 'Missing client for revocation'
    printf 'revoke:%s:%s\n' "$app" "$client" >>"$TRACE"
    [[ "${FAIL_REVOKE:-off}" != on ]] || return 1
    sed -i 's/STATUS="active"/STATUS="revoked"/' "$path"
    printf '%s\n' "$client" >>"$(gateway_dir "$app")/crl"
}
awg_server_client_revoke() {
    gateway_client_revoke "$@" || return 1
    printf 'awg-sync:%s:%s\n' "$1" "$2" >>"$TRACE"
}
gateway_write_server_config() { printf 'regenerate:%s\n' "$1" >>"$TRACE"; }
awg_server_write_config() { printf 'awg-regenerate:%s\n' "$1" >>"$TRACE"; }
gateway_write_transport_config() { printf 'cloak-regenerate:%s\n' "$1" >>"$TRACE"; }

# New OpenVPN clients are created exactly once; exports reuse identities.
main client export ovpn first --full-tunnel --output "$TEST_TMP/first.ovpn" >/dev/null
[[ -f "$TEST_TMP/first.ovpn" ]] || fail 'ovpn profile not exported'
[[ "$(grep -c '^create:ovpn:first$' "$TRACE")" == 1 ]] || fail 'no first client enrollment'
main client export ovpn first --output "$TEST_TMP/second.ovpn" >/dev/null
[[ "$(grep -c '^create:ovpn:first$' "$TRACE")" == 1 ]] || fail 'existing identity recreated'
[[ "$(cat "$(gateway_client_dir ovpn first)/client.key")" == private-ovpn-first ]] || fail 'identity changed'

# An occupied target must not issue client credentials.
if ( main client export ovpn blocked --output "$TEST_TMP/first.ovpn" ) > /dev/null 2>&1; then
    fail 'existing output overwritten'
fi
[[ ! -e "$(gateway_client_dir ovpn blocked)" ]] || fail 'identity created before output validation'

# Legacy gateway export must share the same auto-enrollment behavior.
main gateway client export ovpn oldclient --full-tunnel --output "$TEST_TMP/old.ovpn" >/dev/null
[[ -e "$(gateway_client_dir ovpn oldclient)/client.cfg" ]] || fail 'legacy export did not enroll'

# AWG automatically uses its native profile format and supports routing options.
main client export awg peer --full-tunnel --output "$TEST_TMP/peer.conf" >/dev/null
grep -Fxq 'awg:awg:peer:full' "$TEST_TMP/peer.conf" || fail 'AWG dispatch / route mode wrong'

# Cloak default export writes both files; reject occupied sidecars before client creation.
main client export cloak first --output "$TEST_TMP/cloak.ovpn" >/dev/null
[[ -f "$TEST_TMP/cloak.ovpn" && -f "$TEST_TMP/cloak.cloak.json" ]] || fail 'missing Cloak sidecar'
: >"$TEST_TMP/taken.cloak.json"
if ( main client export cloak mustnotexist --output "$TEST_TMP/taken.ovpn" ) >/dev/null 2>&1; then
    fail 'existing Cloak sidecar overwritten'
fi
[[ ! -e "$(gateway_client_dir cloak mustnotexist)" ]] || fail 'Cloak identity created before sidecar check'

# Revocation failure never removes a still-live client identity.
FAIL_REVOKE=on
if ( main client remove ovpn first ) >/dev/null 2>&1; then fail 'failed revoke permitted delete'; fi
[[ -f "$(gateway_client_dir ovpn first)/client.cfg" ]] || fail 'identity deleted after failed revoke'
FAIL_REVOKE=off
main client remove ovpn first >/dev/null
[[ ! -e "$(gateway_client_dir ovpn first)" ]] || fail 'OpenVPN client files not deleted'
grep -Fxq first "$(gateway_dir ovpn)/crl" || fail 'OpenVPN revocation record lost'
[[ "$(grep -c '^revoke:ovpn:first$' "$TRACE")" == 2 ]] || fail 'missing revoke-before-delete attempt'
[[ -f "$(gateway_client_dir ovpn oldclient)/client.cfg" ]] || fail 'unrelated client deleted'

main client remove awg peer >/dev/null
[[ ! -e "$(gateway_client_dir awg peer)" ]] || fail 'AWG client not deleted'
grep -Fxq 'awg-sync:awg:peer' "$TRACE" || fail 'AWG peer not revoked/synced before delete'
grep -Fxq 'awg-regenerate:awg' "$TRACE" || fail 'AWG server peer config not rebuilt'
# A prior failed AWG sync must not let removal bypass peer revocation.
new_client awg blocked
sed -i 's/STATUS="active"/STATUS="revoked"/' "$(gateway_client_dir awg blocked)/client.cfg"
FAIL_REVOKE=on
if ( main client remove awg blocked ) >/dev/null 2>&1; then fail 'failed AWG re-sync permitted delete'; fi
[[ -d "$(gateway_client_dir awg blocked)" ]] || fail 'AWG identity lost before re-sync'
FAIL_REVOKE=off
main client remove awg blocked >/dev/null
[[ ! -e "$(gateway_client_dir awg blocked)" ]] || fail 'previously revoked AWG client not deleted'

# A previously revoked OpenVPN client is removable, but a failed live
# restart must prevent deletion (the old session could still be active).
new_client ovpn revoked
sed -i 's/STATUS="active"/STATUS="revoked"/' "$(gateway_client_dir ovpn revoked)/client.cfg"
TEST_SERVICE_ACTIVE=on FAIL_RESTART=on
if ( main client remove ovpn revoked ) >/dev/null 2>&1; then fail 'removed revoked client without restarting OpenVPN'; fi
[[ -d "$(gateway_client_dir ovpn revoked)" ]] || fail 'previously revoked client removed before restart'
FAIL_RESTART=off
main client remove ovpn revoked >/dev/null
[[ ! -e "$(gateway_client_dir ovpn revoked)" ]] || fail 'revoked client not cleaned'
TEST_SERVICE_ACTIVE=off
if ( main client remove ovpn revoked ) >/dev/null 2>&1; then fail 'missing client removed again'; fi
if ( main client export ovpn first --format awg --output "$TEST_TMP/invalid.conf" ) >/dev/null 2>&1; then
    fail 'incompatible format accepted'
fi

printf 'Managed client export/create/revoke/remove tests passed.\n'
