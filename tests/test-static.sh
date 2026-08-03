#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$ROOT/nns-app-install.sh"

bash -n "$INSTALLER"
python3 "$ROOT/tools/check_embedded_python.py" "$INSTALLER"

version=$("$INSTALLER" --version)
grep -Fq 'nns-app 1.2.5' <<<"$version"

help=$("$INSTALLER" --help)
grep -Fq 'nns-app status' <<<"$help"
grep -Fq 'nns-app gateway create' <<<"$help"
grep -Fq 'nns-app gateway client export' <<<"$help"
grep -Fq 'nns-app remote connect' <<<"$help"
grep -Fq 'nns-app link import' <<<"$help"
grep -Fq -- '--backend inherit' <<<"$help"
grep -Fq -- '--transport direct|stunnel|cloak' <<<"$help"
grep -Fq -- '--server-name <cloak-decoy-host>' <<<"$help"
grep -Fq 'cfg_set "$app" VPN_TYPE inherit' "$INSTALLER"
grep -Fq 'TRANSPORT_TYPE' "$INSTALLER"
grep -Fq 'nnslink_manifest_read' "$INSTALLER"
grep -Fq 'StrictHostKeyChecking=yes' "$INSTALLER"
grep -Fq -- '-s "$TRANSPORT_REMOTE_HOST"' "$INSTALLER"
grep -Fq -- '-p "$TRANSPORT_REMOTE_PORT"' "$INSTALLER"
grep -Fq 'namespace_ref_id /proc/self/ns/net' "$INSTALLER"
if grep -Fq 'readlink "/run/netns/$NS_NAME"' "$INSTALLER"; then
    echo 'named namespace identity incorrectly uses readlink' >&2
    exit 1
fi

if grep -Eq 'install[[:space:]]+-d[^[:cntrl:]]*(/sys/fs/cgroup|/sys/kernel/security)' "$INSTALLER"; then
    echo 'run helper attempts to chmod a kernel-managed mount point' >&2
    exit 1
fi
grep -Fq 'mkdir -p -- "$mountpoint"' "$INSTALLER"
grep -Fq 'command_needs_namespaced_snap_mounts "$1"' "$INSTALLER"
if grep -Fq 'prepare_namespaced_desktop_mounts' "$INSTALLER"; then
    echo 'obsolete unconditional desktop-mount helper found' >&2
    exit 1
fi

# Desktop applications must retain enough session identity for Chromium's
# oscrypt/safeStorage backend selection while the launcher still uses env -i.
for desktop_var in \
    DBUS_SESSION_BUS_ADDRESS \
    XDG_CURRENT_DESKTOP \
    XDG_SESSION_DESKTOP \
    XDG_SESSION_TYPE \
    DESKTOP_SESSION \
    GDMSESSION \
    GNOME_KEYRING_CONTROL \
    KDE_FULL_SESSION \
    KDE_SESSION_VERSION; do
    count=$(grep -o "$desktop_var" "$INSTALLER" | wc -l)
    (( count >= 2 )) || {
        echo "desktop session variable is not preserved through both launcher stages: $desktop_var" >&2
        exit 1
    }
done

grep -Fq 'write_sudoers_for_app "$app" "$APP_USER"' "$INSTALLER" || {
    echo 'engine upgrade does not refresh existing per-app sudoers rules' >&2
    exit 1
}

grep -Fq 'nns-online@.service' "$INSTALLER"
grep -Fq 'nns-watchdog@.service' "$INSTALLER"
grep -Fq 'nns-watchdog@.timer' "$INSTALLER"
grep -Fq '_watchdog %i' "$INSTALLER"
grep -Fq 'WATCHDOG_MODE="auto"' "$INSTALLER"
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

grep -Fq '**Release:** 1.2.5' "$ROOT/README.md"
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

if grep -Fq '/root/' \
    "$ROOT/README.md" \
    "$ROOT/src/00-preamble.sh" \
    "$INSTALLER"; then
    echo 'root-specific path found in public documentation or help' >&2
    exit 1
fi

if grep -Fq '~/Downloads/' \
    "$ROOT/README.md" \
    "$ROOT/src/00-preamble.sh" \
    "$INSTALLER"; then
    echo 'desktop-specific Downloads path found in public documentation or help' >&2
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
