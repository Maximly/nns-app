#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$ROOT/nns-app-install.sh"

bash -n "$INSTALLER"
python3 "$ROOT/tools/check_embedded_python.py" "$INSTALLER"

version=$("$INSTALLER" --version)
grep -Fq 'nns-app 1.3.11' <<<"$version"

help=$("$INSTALLER" --help)
grep -Fq 'nns-app status' <<<"$help"
grep -Fq 'nns-app gateway create' <<<"$help"
grep -Fq 'nns-app gateway client export' <<<"$help"
grep -Fq 'nns-app remote connect' <<<"$help"
grep -Fq 'nns-app link import' <<<"$help"
grep -Fq -- '--backend inherit' <<<"$help"
grep -Fq -- '--transport direct|stunnel|cloak' <<<"$help"
grep -Fq -- '--server-name <cloak-decoy-host>' <<<"$help"
grep -Fq -- 'via --remote <user@host>' <<<"$help"
grep -Fq 'nns-app purge [--local-only]' <<<"$help"
grep -Fq 'nns-app remove  <app_name> [--local-only]' <<<"$help"
grep -Fq 'remote_auto_cleanup_internal' "$INSTALLER"
grep -Fq 'remote_auto_cleanup_app' "$INSTALLER"
grep -Fq 'remote_auto_command "$alias" cleanup "$owner"' "$INSTALLER"
grep -Fq 'cfg_set "$app" REMOTE_CLEANED on' "$INSTALLER"
grep -Fq 'remove_app "$exit_app" local-only' "$INSTALLER"
grep -Fq 'REMOTE_MANAGED_OWNER_ID' "$INSTALLER"
grep -Fq 'remote_auto_install' "$INSTALLER"
grep -Fq 'remote_auto_deploy_internal' "$INSTALLER"
autostart_sets=$(grep -Fc 'cfg_set "$app" AUTOSTART on' "$INSTALLER")
(( autostart_sets >= 2 )) || {
    echo 'automatic-remote install/deploy does not enable boot startup' >&2
    exit 1
}
grep -Fq 'log "Automatic remote '"'"'$app'"'"' is ready, started, and enabled for boot."' "$INSTALLER" || {
    echo 'automatic-remote deployment does not start the local environment' >&2
    exit 1
}
grep -Fq 'TRANSPORT_SSH_REMOTE_PORT' "$INSTALLER"
grep -Fq 'ServerAliveInterval=15' "$INSTALLER"
grep -Fq 'ControlMaster=yes' "$INSTALLER"
grep -Fq 'openvpn:ssh' "$INSTALLER"
grep -Fq "Transport 'ssh' is managed internally by install --via-remote." "$INSTALLER"
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

# The caller's command-search path must survive sudo secure_path under a
# dedicated variable, and it must be applied only in the final user process.
grep -Fq 'export NNS_APP_RUN_PATH=${PATH-}' "$INSTALLER" || {
    echo 'run wrapper does not capture the invoking user PATH' >&2
    exit 1
}
grep -Fq 'env_keep += "NNS_APP_RUN_PATH ' "$INSTALLER" || {
    echo 'sudoers does not preserve the dedicated run PATH variable' >&2
    exit 1
}
grep -Fq 'run_path=$(compose_user_run_path "${NNS_APP_RUN_PATH:-}")' "$INSTALLER" || {
    echo 'run helper does not restore the caller PATH after privilege dropping' >&2
    exit 1
}
if grep -Fq '"PATH=/usr/local/bin:/usr/bin:/bin:/snap/bin"' "$INSTALLER"; then
    echo 'run helper still replaces the user PATH with the old minimal path' >&2
    exit 1
fi

grep -Fq 'nns-online@.service' "$INSTALLER"
grep -Fq 'nns-dns@.service' "$INSTALLER"
grep -Fq '_dns-proxy %i' "$INSTALLER"
grep -Fq 'ensure_snap_dns_proxy "$app"' "$INSTALLER"
grep -Fq '127.0.0.53' "$INSTALLER"
grep -Fq 'os.setuid(nobody.pw_uid)' "$INSTALLER"
grep -Fq 'Snap DNS proxy:    active on 127.0.0.53:53' "$INSTALLER"
grep -Fq 'nns-watchdog@.service' "$INSTALLER"
grep -Fq 'nns-watchdog@.timer' "$INSTALLER"
grep -Fq '_watchdog %i' "$INSTALLER"
grep -Fq 'WATCHDOG_MODE="auto"' "$INSTALLER"
grep -Fq 'nns-gateway-crl-refresh@.timer' "$INSTALLER"
grep -Fq '"$DNS_PROXY_UNIT"' "$INSTALLER"
grep -Fq 'systemctl enable --now "nns-gateway-crl-refresh@${gateway}.timer"' "$INSTALLER"
grep -Fq 'gateway_crl_valid_for "$pki/crl.pem" 1' "$INSTALLER"
grep -Fq 'gateway_crl_valid_for "$pki/crl.pem" 604800' "$INSTALLER"
if grep -Fq -- '-noout -checkend' "$INSTALLER"; then
    echo 'openssl crl incorrectly uses the x509-only -checkend option' >&2
    exit 1
fi
grep -Fq 'during $failed_stage; staged files were removed' "$INSTALLER"
grep -Fq 'delimiter="\t"' "$INSTALLER"
grep -Fq 'iif "$tunnel_dev"' "$INSTALLER"
grep -Fq 'NNS_APP_SOURCE_ONLY' "$INSTALLER"
grep -Fq 'NNS_APP_LOCK_DIR' "$INSTALLER"
grep -Fq 'iif "$GATEWAY_TUN"' "$INSTALLER"
grep -Fq "printf 'dev-type tun\\n'" "$INSTALLER" || {
    echo 'managed gateway server config does not declare custom device as TUN' >&2
    exit 1
}
grep -Fq 'systemctl stop "nns-gateway@${gateway}.service"' "$INSTALLER" || {
    echo 'failed gateway startup can leave a systemd restart loop running' >&2
    exit 1
}
grep -Fq '(( $# >= 2 )) || die "_gateway-tun-up requires gateway_name."' "$INSTALLER" || {
    echo 'OpenVPN up callback still rejects appended tunnel arguments' >&2
    exit 1
}
grep -Fq 'ip link del "$GATEWAY_TUN"' "$INSTALLER" || {
    echo 'gateway teardown does not remove a stale managed TUN interface' >&2
    exit 1
}
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

grep -Fq '**Release:** 1.3.10' "$ROOT/README.md"
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

private_pattern='ma''xim@|ml''cloud|ml''host|Sande''fjord|92c3''7155|193[.]200[.]221'
if grep -Eqi "$private_pattern" \
    "$ROOT/README.md" \
    "$ROOT/tests/test-functions.sh" \
    "$ROOT/src/00-preamble.sh"; then
    echo 'deployment-specific example data found in public material or tests' >&2
    exit 1
fi

before=$(sha256sum "$INSTALLER" | awk '{print $1}')
"$ROOT/build.sh" >/dev/null
after=$(sha256sum "$INSTALLER" | awk '{print $1}')
[[ "$before" == "$after" ]] || {
    echo 'build is not deterministic' >&2
    exit 1
}

# An expanded config heredoc must never contain shell command substitutions.
config_block=$(sed -n '/cat >"$file" <<CONFIG_EOF/,/^CONFIG_EOF$/p' "$ROOT/src/20-install.sh")
if grep -Fq '`' <<<"$config_block" || grep -Fq '$(' <<<"$config_block"; then
    echo 'generated app config heredoc contains shell command substitution' >&2
    exit 1
fi
if grep -Fq '"${quoted[*]}"' "$INSTALLER"; then
    echo 'remote command arguments are joined through global IFS' >&2
    exit 1
fi
grep -Fq 'temp="$temp_dir/$profile_name"' "$INSTALLER" || {
    echo 'automatic remote upload does not preserve the sanitized profile name' >&2
    exit 1
}


echo 'Static tests passed.'
