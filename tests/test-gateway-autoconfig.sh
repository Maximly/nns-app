#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT
GATEWAY_BASE_DIR="$TEST_TMP/gateways"
mkdir -p "$GATEWAY_BASE_DIR"/{mlhome,other-exit,secured}
source "$ROOT/src/60-gateway.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ss() {
    case "$2" in
        -lun) printf 'UNCONN 0 0 0.0.0.0:1196 0.0.0.0:*\n' ;;
        -ltn) printf 'LISTEN 0 128 0.0.0.0:444 0.0.0.0:*\n' ;;
    esac
}
cat >"$GATEWAY_BASE_DIR/mlhome/gateway.cfg" <<'CFG'
VIA_APP=host
TRANSPORT=direct
LISTEN_PROTO=udp
LISTEN_PORT=1194
OPENVPN_LISTEN_PROTO=udp
OPENVPN_LISTEN_PORT=1194
CFG
cat >"$GATEWAY_BASE_DIR/other-exit/gateway.cfg" <<'CFG'
VIA_APP=hidemy
TRANSPORT=direct
LISTEN_PROTO=udp
LISTEN_PORT=1195
OPENVPN_LISTEN_PROTO=udp
OPENVPN_LISTEN_PORT=1195
CFG
cat >"$GATEWAY_BASE_DIR/secured/gateway.cfg" <<'CFG'
VIA_APP=host
TRANSPORT=cloak
LISTEN_PROTO=tcp
LISTEN_PORT=443
OPENVPN_LISTEN_PROTO=tcp
OPENVPN_LISTEN_PORT=12345
CFG
[[ $(gateway_choose_listener direct hidemy-phone) == udp:1197 ]] ||
    fail 'default UDP listener did not skip managed and unmanaged host ports'
[[ $(gateway_choose_listener cloak secure-phone-new) == tcp:445 ]] ||
    fail 'default TCP Cloak listener did not skip managed and unmanaged host ports'
[[ $(gateway_choose_listener stunnel secure-stunnel) == tcp:445 ]] ||
    fail 'default TCP stunnel listener did not skip managed and unmanaged host ports'
if (gateway_choose_listener ssh ssh-test) >/dev/null 2>&1; then
    fail 'SSH transport incorrectly auto-selected public listener'
fi
printf 'Gateway auto-endpoint tests passed.\n'
