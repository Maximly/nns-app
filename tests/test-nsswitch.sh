#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TMP/locks"
source "$ROOT/install_linux"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Ubuntu's nss-resolve plugin calls a host UNIX socket, bypassing netns DNS.
cat >"$TMP/nsswitch.host" <<'EOS'
passwd:         files systemd
group:          files systemd
shadow:         files
hosts:          files mdns4_minimal [NOTFOUND=return] resolve [!UNAVAIL=return] dns myhostname
networks:       files
EOS
cp "$TMP/nsswitch.host" "$TMP/saved-host"
namespace_dns_nsswitch_write "$TMP/nsswitch.host" "$TMP/nsswitch.ns"
grep -Fxq 'hosts: files dns' "$TMP/nsswitch.ns" || fail 'glibc hosts configuration not redirected to namespace DNS'
[[ "$(grep -c '^hosts:' "$TMP/nsswitch.ns")" == 1 ]] || fail 'duplicate hosts entry'
grep -Fxq 'passwd:         files systemd' "$TMP/nsswitch.ns" || fail 'passwd NSS configuration changed'
grep -Fxq 'group:          files systemd' "$TMP/nsswitch.ns" || fail 'group NSS configuration changed'
grep -Fxq 'networks:       files' "$TMP/nsswitch.ns" || fail 'non-host entries modified'
cmp -s "$TMP/nsswitch.host" "$TMP/saved-host" || fail 'host NSS configuration modified'
[[ "$(stat -c '%a' "$TMP/nsswitch.ns")" == 644 ]] || fail 'namespace NSS file does not have mode 0644'

# Append hosts if absent, avoiding a host systemd NSS bypass.
printf 'passwd: files\ngroup: files\n' >"$TMP/minimal"
namespace_dns_nsswitch_write "$TMP/minimal" "$TMP/minimal.ns"
grep -Fxq 'hosts: files dns' "$TMP/minimal.ns" || fail 'missing hosts entry not added'

# No temporary command injection and no symlink-based output file writes.
ln -s "$TMP/saved-host" "$TMP/unsafe"
if (namespace_dns_nsswitch_write "$TMP/nsswitch.host" "$TMP/unsafe") >/dev/null 2>&1; then
    fail 'symlink output accepted'
fi
cmp -s "$TMP/saved-host" "$TMP/nsswitch.host" || fail 'symlink target overwritten'

# Assert integration paths work for fresh, upgraded, and already-running apps.
grep -Fq 'ensure_namespace_dns_nsswitch "$app"' "$ROOT/src/40-network.sh" || fail 'missing nsswitch install in netns_up'
grep -Fq 'ensure_namespace_dns_nsswitch "$app"' "$ROOT/src/50-runtime.sh" || fail 'missing running-app reconciliation'
grep -Fq 'ensure_namespace_dns_nsswitch "$app"' "$ROOT/src/70-run-status.sh" || fail 'missing nns-app run reconciliation'
grep -Fq 'rm -rf "/etc/netns/$NS_NAME"' "$ROOT/src/40-network.sh" || fail 'namespace-specific NSS cleanup missing'

# Ensure duplicate or invalid host configurations cannot be accepted as-is.
printf 'hosts: files resolve\nhosts: files dns\n' >"$TMP/duplicate"
if (namespace_dns_nsswitch_write "$TMP/duplicate" "$TMP/duplicate.ns") >/dev/null 2>&1; then
    fail 'duplicate NSS hosts definitions accepted'
fi

echo 'Namespace NSS routing, host preservation, security and integration tests passed.'
