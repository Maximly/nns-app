#!/usr/bin/env bash
# Test runtime WireGuard config placement and private key mode without root.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TMP/locks"
source "$ROOT/nns-app-install.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

# Both wg-quick and wg AppArmor profiles permit /etc/wireguard/** by default.
[[ "$(wireguard_runtime_config_path bitblaze)" == /etc/wireguard/nns-app/nwg23fc0119.conf ]] ||
    fail 'WireGuard runtime not placed under /etc/wireguard/nns-app'
[[ "$(wireguard_legacy_runtime_config_path bitblaze)" == /run/nns-app/nwg23fc0119.conf ]] ||
    fail 'legacy runtime config path regression'
grep -Fq 'install -d -o root -g root -m 0700 /etc/wireguard/nns-app' "$ROOT/src/50-runtime.sh" ||
    fail 'generated runtime directory not secured'

cat > "$TMP/profile.conf" <<'PROFILE'
[Interface]
Address = 10.3.1.52/24
PrivateKey = test-private-key-not-secret
PostUp = resolvectl dns %i 192.168.83.10
PostUp = resolvectl domain %i '~promobit.loc'
PostDown = resolvectl revert %i
[Peer]
PublicKey = fake
AllowedIPs = 10.3.1.1/32, 192.168.83.10/32
Endpoint = 77.221.196.190:49018
PROFILE

# The generation helper itself is intentionally independent of path policy.
umask 0000
prepare_wireguard_runtime_config "$TMP/profile.conf" "$TMP/runtime.conf" on
[[ "$(stat -c %a "$TMP/runtime.conf")" == 600 ]] || fail 'private-key file created with insecure permissions'
! grep -Eq '^[[:space:]]*Post(Up|Down)[[:space:]]*=' "$TMP/runtime.conf" || fail 'shell hooks passed to wg-quick'
grep -Fq 'AllowedIPs = 10.3.1.1/32, 192.168.83.10/32' "$TMP/runtime.conf" || fail 'split routes rewritten'

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
