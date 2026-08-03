#!/usr/bin/env bash
# Build the single-file nns-app installer from ordered source modules.
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
OUTPUT="$ROOT/nns-app-install.sh"
TMP=$(mktemp "$ROOT/.nns-app-install.XXXXXX")
trap 'rm -f "$TMP"' EXIT

mapfile -t MODULES < <(find "$ROOT/src" -maxdepth 1 -type f -name '[0-9][0-9]-*.sh' | sort)
(( ${#MODULES[@]} > 0 )) || {
    printf 'ERROR: no source modules found under %s/src\n' "$ROOT" >&2
    exit 1
}

for module in "${MODULES[@]}"; do
    bash -n "$module"
    cat "$module" >>"$TMP"
    printf '\n' >>"$TMP"
done

bash -n "$TMP"
python3 "$ROOT/tools/check_embedded_python.py" "$TMP"
install -m 0755 "$TMP" "$OUTPUT"

printf 'Built %s\n' "$OUTPUT"
sha256sum "$OUTPUT"
