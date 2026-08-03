#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$ROOT/nns-app-install.sh"

bash -n "$INSTALLER"
python3 "$ROOT/tools/check_embedded_python.py" "$INSTALLER"

version=$("$INSTALLER" --version)
grep -Fq 'nns-app 1.1.26' <<<"$version"

help=$("$INSTALLER" --help)
grep -Fq 'nns-app status' <<<"$help"
grep -Fq 'nns-app gateway create' <<<"$help"
grep -Fq 'nns-app gateway client export' <<<"$help"

grep -Fq 'nns-online@.service' "$INSTALLER"
grep -Fq 'nns-gateway-crl-refresh@.timer' "$INSTALLER"
grep -Fq 'systemctl enable --now "nns-gateway-crl-refresh@${gateway}.timer"' "$INSTALLER"
grep -Fq 'delimiter="\t"' "$INSTALLER"
grep -Fq 'iif "$tunnel_dev"' "$INSTALLER"
grep -Fq 'NNS_APP_SOURCE_ONLY' "$INSTALLER"
grep -Fq 'NNS_APP_LOCK_DIR' "$INSTALLER"
grep -Fq 'iif "$GATEWAY_TUN"' "$INSTALLER"
grep -Fq 'CONTRIBUTING.md' "$ROOT/README.md"
test -s "$ROOT/CONTRIBUTING.md"
test ! -e "$ROOT/ARCHITECTURE.md"

if grep -Fq 'ip route flush table "$ROUTE_TABLE"' "$INSTALLER"; then
    echo 'unsafe route-table flush found' >&2
    exit 1
fi

if grep -Fq 'while ip rule del priority "$RULE_PRIORITY"' "$INSTALLER"; then
    echo 'unsafe priority-only rule deletion loop found' >&2
    exit 1
fi

if grep -Fq 'rm -f "$tmp" "$backup"' "$INSTALLER"; then
    echo 'directory cleanup uses rm -f instead of rm -rf' >&2
    exit 1
fi

grep -Fq '**Release:** 1.1.26' "$ROOT/README.md"
grep -Fq 'OpenVPN 2.6+' "$ROOT/README.md"

# Public documentation and help use one descriptive example-name set.
for expected_name in \
    my-private-app \
    my-upstream-vpn \
    my-remote-exit \
    my-relay \
    my-linux-client \
    my-remote-profile.ovpn; do
    grep -Fq "$expected_name" "$ROOT/README.md"
done

if grep -Eqi 'experimental release|status:[[:space:]]*experimental' "$ROOT/README.md"; then
    echo 'stale experimental notice found in README' >&2
    exit 1
fi

before=$(sha256sum "$INSTALLER" | awk '{print $1}')
"$ROOT/build.sh" >/dev/null
after=$(sha256sum "$INSTALLER" | awk '{print $1}')
[[ "$before" == "$after" ]] || {
    echo 'build is not deterministic' >&2
    exit 1
}

echo 'Static tests passed.'
