#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export NNS_APP_SOURCE_ONLY=1 NNS_APP_LOCK_DIR="$TMP/locks"
source "$ROOT/install_linux"
fail() { echo "FAIL: $*" >&2; exit 1; }

# No tools, network access, service changes or package operations during these
# tests: validate the explicit command and its restrictions independently.
[[ "$NNS_AWG_GO_TAG" == v3.1.* ]] || fail 'missing pinned userspace Go version'
[[ "$NNS_AWG_TOOLS_TAG" == v3.1.* ]] || fail 'missing pinned AmneziaWG tool version'
! grep -Eq 'modprobe[[:space:]]+amneziawg|dkms[[:space:]]+install|add-apt-repository' "$ROOT/src/22-amnezia-tools.sh" ||
    fail 'userspace installer unexpectedly provisions kernel modules or PPAs'
if ( require_root() { :; }; os_release_value() { echo fedora; }; install_amnezia_userspace_tools ) 2>"$TMP/error"; then
    fail 'Fedora incorrectly accepted for Ubuntu-only installation'
fi
grep -Fq 'supports Ubuntu only' "$TMP/error" || fail 'unsupported-OS error missing'
# The explicit installers require root; stub the re-exec so the dispatcher
# itself is exercised identically on hosts without interactive sudo.
if ( reexec_as_root_if_needed() { return 0; }; main --install incorrect ) 2>"$TMP/error"; then
    fail 'unexpected dependency bundle accepted'
fi
grep -Fq 'Usage: nns-app --install openconnect|wireguard|amnezia' "$TMP/error" ||
    fail 'invalid bundle error missing'

# The wireguard and openconnect add-on installers exist next to the amnezia
# one and are only reachable through the same explicit CLI option.
grep -Fq 'openconnect) install_openconnect_tools' "$ROOT/src/90-main.sh" ||
    fail 'missing openconnect add-on dispatcher'
grep -Fq 'wireguard) install_wireguard_tools' "$ROOT/src/90-main.sh" ||
    fail 'missing wireguard add-on dispatcher'
grep -Fq 'install_openconnect_tools' "$ROOT/src/20-install.sh" ||
    fail 'openconnect add-on installer not defined'
grep -Fq 'install_wireguard_tools' "$ROOT/src/20-install.sh" ||
    fail 'wireguard add-on installer not defined'

# Ensure the helper is only reachable through the explicit CLI option. App
# installation remains separate, including an app actually named "amnezia".
grep -Fq -- '--install)' "$ROOT/src/90-main.sh" || fail 'missing explicit dispatcher'
grep -Fq 'install_amnezia_userspace_tools' "$ROOT/src/90-main.sh" || fail 'installer not called'
! grep -Eq '^ *install_amnezia_userspace_tools' "$ROOT/src/20-install.sh" || fail 'install_engine invokes AWG setup'
grep -Fq 'nns-app --install amnezia' "$ROOT/README.md" || fail 'missing usage in README'

echo 'Explicit AmneziaWG userspace installer tests passed.'
