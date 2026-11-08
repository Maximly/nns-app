#!/usr/bin/env bash
# Gateway egress switching with a transactional config snapshot.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1
BASE_DIR="$TEST_TMP/apps"
GATEWAY_BASE_DIR="$TEST_TMP/gateways"
mkdir -p "$BASE_DIR/hidemy-norway" "$BASE_DIR/mlhomeuz" "$GATEWAY_BASE_DIR/hidemy-cursor/clients/mlubuntu" "$GATEWAY_BASE_DIR/myawg"
cat > "$BASE_DIR/hidemy-norway/hidemy-norway.cfg" <<'CFG'
APP_NAME=hidemy-norway
UPSTREAM_APP=host
CFG
cat > "$BASE_DIR/mlhomeuz/mlhomeuz.cfg" <<'CFG'
APP_NAME=mlhomeuz
UPSTREAM_APP=host
CFG
cat > "$GATEWAY_BASE_DIR/hidemy-cursor/gateway.cfg" <<'CFG'
GATEWAY_NAME=hidemy-cursor
GATEWAY_BACKEND=openvpn
VIA_APP=hidemy-norway
PUBLIC_HOST=135.106.161.67
PUBLIC_PORT=1196
LISTEN_PROTO=udp
LISTEN_PORT=1196
CLIENT_POOL=10.253.3.0/24
CFG
cat > "$GATEWAY_BASE_DIR/myawg/gateway.cfg" <<'CFG'
GATEWAY_NAME=myawg
GATEWAY_BACKEND=amneziawg
VIA_APP=host
CFG
printf 'keep-credential\n' >"$GATEWAY_BASE_DIR/hidemy-cursor/clients/mlubuntu/client.key"
source "$ROOT/src/10-config.sh"
source "$ROOT/src/60-gateway.sh"
source "$ROOT/src/90-main.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_root() { :; }
log() { :; }
warn() { :; }
acquire_lock() { :; }
release_lock() { :; }
load_gateway_cfg() {
  VIA_APP= GATEWAY_BACKEND=
  source "$(gateway_cfg_file "$1")"
}
gateway_cfg_set() {
  [[ "$2" == VIA_APP ]] || fail 'unexpected config update'
  sed -i -E "s/^VIA_APP=.*/VIA_APP=$3/" "$(gateway_cfg_file "$1")"
}
TRACE="$TEST_TMP/trace"
: >"$TRACE"
STATE="$TEST_TMP/state"
printf "on\n" >"$STATE"
systemctl() {
  [[ "$1" == is-active ]] || fail "unexpected systemctl $1"
  [[ "$(cat "$STATE")" == on ]]
}
ensure_upstream_ready() {
  printf 'preflight:%s\n' "$2" >>"$TRACE"
  [[ "${FAIL_PREFLIGHT:-}" != "$2" ]]
}
gateway_stop() {
  printf 'stop:%s\n' "$(gateway_cfg_value "$1" VIA_APP)" >>"$TRACE"
  [[ "${FAIL_STOP:-off}" != on ]] || return 1
  printf "off\n" >"$STATE"
}
gateway_down() {
  printf 'cleanup:%s\n' "$(gateway_cfg_value "$1" VIA_APP)" >>"$TRACE"
}
gateway_start() {
  local via
  via=$(gateway_cfg_value "$1" VIA_APP)
  printf 'start:%s\n' "$via" >>"$TRACE"
  [[ "${FAIL_START_VIA:-}" != "$via" ]] || return 1
  printf "on\n" >"$STATE"
}
via() { gateway_cfg_value hidemy-cursor VIA_APP; }
assert_no_snapshot() {
  if compgen -G "$(gateway_cfg_file hidemy-cursor).set-via.*" >/dev/null; then
    fail 'stray transition snapshot'
  fi
}
# Running service: validate readiness, stop with old config, update, restart.
main set-via hidemy-cursor mlhomeuz
[[ "$(via)" == mlhomeuz && "$(cat "$STATE")" == on ]] || fail 'active gateway was not switched'
[[ "$(cat "$GATEWAY_BASE_DIR/hidemy-cursor/clients/mlubuntu/client.key")" == keep-credential ]] || fail 'client key changed'
[[ "$(grep -c 'stop:hidemy-norway' "$TRACE")" == 1 ]] || fail 'old egress was not stopped'
[[ "$(grep -c 'start:mlhomeuz' "$TRACE")" == 1 ]] || fail 'new egress was not started'
[[ "$(gateway_cfg_value hidemy-cursor PUBLIC_PORT)" == 1196 ]] || fail 'public port changed'
assert_no_snapshot

# Idempotent update is a no-op.
: >"$TRACE"
main set-via hidemy-cursor mlhomeuz
[[ ! -s "$TRACE" ]] || fail 'no-op changed service state'

# Invalid/missing or offline target fails before stopping an active gateway.
if (main set-via hidemy-cursor doesnt-exist) >/dev/null 2>&1; then fail 'missing upstream accepted'; fi
[[ "$(via)" == mlhomeuz && "$(cat "$STATE")" == on ]] || fail 'invalid target disrupted gateway'
FAIL_PREFLIGHT=hidemy-norway
if (main set-via hidemy-cursor hidemy-norway) >/dev/null 2>&1; then fail 'offline upstream accepted'; fi
unset FAIL_PREFLIGHT
[[ "$(via)" == mlhomeuz && "$(cat "$STATE")" == on ]] || fail 'failed preflight changed gateway'

# Failed new start restores old config and restarts old service.
: >"$TRACE"
FAIL_START_VIA=hidemy-norway
if main set-via hidemy-cursor hidemy-norway; then fail 'failed start counted as successful'; fi
unset FAIL_START_VIA
[[ "$(via)" == mlhomeuz && "$(cat "$STATE")" == on ]] || fail 'failed start did not rollback'
[[ "$(grep -c 'stop:hidemy-norway' "$TRACE")" == 1 ]] || fail 'failed new egress not torn down'
[[ "$(grep -c 'start:mlhomeuz' "$TRACE")" == 1 ]] || fail 'rollback did not restart previous service'
assert_no_snapshot

# A previously stopped gateway remains stopped and may target offline app.
printf "off\n" >"$STATE"
: >"$TRACE"
FAIL_PREFLIGHT=hidemy-norway
main set-via hidemy-cursor hidemy-norway
[[ "$(via)" == hidemy-norway && "$(cat "$STATE")" == off ]] || fail 'stopped gateway should stay stopped'
[[ "$(grep -c 'cleanup:mlhomeuz' "$TRACE")" == 1 ]] || fail 'stopped old network not cleaned'
! grep -q '^start:' "$TRACE" || fail 'stopped gateway was started'
unset FAIL_PREFLIGHT

# Host transition is supported and does not change client credentials.
printf "on\n" >"$STATE"
main set-via hidemy-cursor host
[[ "$(via)" == host && "$(cat "$STATE")" == on ]] || fail 'host egress switching failed'

# AWG 3.1 servers are currently host-only; reject changing their exit.
if (main set-via myawg mlhomeuz) >/dev/null 2>&1; then fail 'AWG accepted nonhost upstream'; fi
[[ "$(gateway_cfg_value myawg VIA_APP)" == host ]] || fail 'AWG config changed'

# A namespace app must not be treated as a public server.
if (main set-via mlhomeuz host) >/dev/null 2>&1; then fail 'namespace accepted as gateway'; fi
assert_no_snapshot
printf 'Gateway set-via and rollback tests passed.\n'
