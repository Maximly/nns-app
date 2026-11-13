#!/usr/bin/env bash
# Test runtime WireGuard config placement and private key mode without root.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TMP/locks"
source "$ROOT/install_linux"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Both wg-quick and wg AppArmor profiles permit /etc/wireguard/** by default.
[[ "$(wireguard_runtime_config_path demo-vpn)" == /etc/wireguard/nns-app/nwg9de5554d.conf ]] ||
    fail 'WireGuard runtime not placed under /etc/wireguard/nns-app'
[[ "$(wireguard_legacy_runtime_config_path demo-vpn)" == /run/nns-app/nwg9de5554d.conf ]] ||
    fail 'legacy runtime config path regression'
grep -Fq 'install -d -o root -g root -m 0700 /etc/wireguard/nns-app' "$ROOT/src/50-runtime.sh" ||
    fail 'generated runtime directory not secured'

cat > "$TMP/profile.conf" <<'PROFILE'
[Interface]
Address = 10.77.0.20/24
PrivateKey = test-private-key-not-secret
PostUp = resolvectl dns %i 10.77.0.53
PostUp = resolvectl domain %i '~corp.example'
PostDown = resolvectl revert %i
[Peer]
PublicKey = fake
AllowedIPs = 10.77.0.1/32, 10.77.0.53/32
Endpoint = 203.0.113.10:51820
PROFILE

# The generation helper itself is intentionally independent of path policy.
umask 0000
prepare_wireguard_runtime_config "$TMP/profile.conf" "$TMP/runtime.conf" on
[[ "$(stat -c %a "$TMP/runtime.conf")" == 600 ]] || fail 'private-key file created with insecure permissions'
! grep -Eq '^[[:space:]]*Post(Up|Down)[[:space:]]*=' "$TMP/runtime.conf" || fail 'shell hooks passed to wg-quick'
grep -Fq 'AllowedIPs = 10.77.0.1/32, 10.77.0.53/32' "$TMP/runtime.conf" || fail 'split routes rewritten'

# Secure replacement also stays 0600, even if the previous file was 0644.
chmod 0644 "$TMP/runtime.conf"
prepare_wireguard_runtime_config "$TMP/profile.conf" "$TMP/runtime.conf" on
[[ "$(stat -c %a "$TMP/runtime.conf")" == 600 ]] || fail 'replaced file retains insecure permissions'

# Atomic replacement may never follow an attacker-supplied symlink.
ln -s "$TMP/do-not-touch" "$TMP/link.conf"
prepare_wireguard_runtime_config "$TMP/profile.conf" "$TMP/link.conf" on
[[ ! -L "$TMP/link.conf" ]] || fail 'runtime symlink not atomically replaced'
[[ ! -e "$TMP/do-not-touch" ]] || fail 'runtime generator followed symlink'

echo 'WireGuard AppArmor runtime placement and secret-mode tests passed.'
