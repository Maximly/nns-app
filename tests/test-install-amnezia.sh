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
if ( main --install incorrect ) 2>"$TMP/error"; then
    fail 'unexpected dependency bundle accepted'
fi
grep -Fq 'Usage: nns-app --install amnezia' "$TMP/error" || fail 'invalid bundle error missing'

# Ensure the helper is only reachable through the explicit CLI option. App
# installation remains separate, including an app actually named "amnezia".
grep -Fq -- '--install)' "$ROOT/src/90-main.sh" || fail 'missing explicit dispatcher'
grep -Fq 'install_amnezia_userspace_tools' "$ROOT/src/90-main.sh" || fail 'installer not called'
! grep -Eq '^ *install_amnezia_userspace_tools' "$ROOT/src/20-install.sh" || fail 'install_engine invokes AWG setup'
grep -Fq 'sudo nns-app --install amnezia' "$ROOT/README.md" || fail 'missing usage in README'

echo 'Explicit AmneziaWG userspace installer tests passed.'
