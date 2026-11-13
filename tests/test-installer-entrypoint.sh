#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Source the generated Bash without running main or modifying the system.
export NNS_APP_SOURCE_ONLY=1
source "$ROOT/install_linux"

main() { (( $# > 0 )) || return 0; printf '<%s>\n' "$@"; }
expect() {
    local expected=$1 actual
    shift
    actual=$(linux_installer_entrypoint "$@")
    [[ "$actual" == "$expected" ]] || {
        printf 'FAIL: expected %q, got %q\n' "$expected" "$actual" >&2
        exit 1
    }
}
expect '<install>' install_linux
expect $'<install>\n<--local-only>' /any/path/install_linux --local-only
expect $'<install>\n<--local-only>' install_linux install --local-only
expect '<restore>' install_linux restore
expect $'<install>\n<work-vpn>' nns-app install work-vpn
expect '' nns-app
expect '<--version>' nns-app --version
expect $'<--local-only>\n<extra>' install_linux --local-only extra
printf 'Installer entrypoint tests passed.\n'
