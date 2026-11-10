# Explicit installation of the AmneziaWG 3.1 userspace runtime on Ubuntu.
# The application lifecycle never calls this installer automatically.
readonly NNS_AWG_GO_TAG="v3.1.20260828"
readonly NNS_AWG_TOOLS_TAG="v3.1.20260812"
readonly NNS_AWG_GO_REPO="https://github.com/amnezia-vpn/amneziawg-go.git"
readonly NNS_AWG_TOOLS_REPO="https://github.com/amnezia-vpn/amneziawg-tools.git"

amnezia_go_version_usable() {
    local version major minor
    version=$(go version 2>/dev/null || true)
    [[ "$version" =~ go([0-9]+)\.([0-9]+)(\.|[[:space:]]) ]] || return 1
    major=${BASH_REMATCH[1]}
    minor=${BASH_REMATCH[2]}
    (( major > 1 || (major == 1 && minor >= 21) ))
}

# Older Ubuntu LTS releases ship Go versions without toolchain auto-selection.
# In that case download the current official stable Go archive into the private
# build directory, verifying its SHA256 against the official Go manifest.
# Nothing is added to /usr/local/go or to the host's existing Go installation.
amnezia_bootstrap_go() {
    local build_dir=$1 architecture archive_info version checksum archive
    architecture=$(dpkg --print-architecture)
    case "$architecture" in
        amd64|arm64) ;;
        *) die "Official Go bootstrap is supported for amd64/arm64; install Go >= 1.21 manually on $architecture." ;;
    esac
    log "The Ubuntu Go package is too old; downloading an official Go toolchain for this build."
    archive_info=$(curl --fail --silent --show-error --location --retry 2 \
        --connect-timeout 15 --max-time 60 'https://go.dev/dl/?mode=json' | \
        python3 -c 'import json,sys
arch=sys.argv[1]
items=json.load(sys.stdin)
for release in items:
    for item in release.get("files",[]):
        if item.get("os")=="linux" and item.get("arch")==arch and item.get("kind")=="archive" and item.get("sha256"):
            print(release["version"]+"\t"+item["sha256"])
            sys.exit(0)
sys.exit("No official Go Linux archive found")' "$architecture") || die "Cannot retrieve the official Go release manifest."
    read -r version checksum <<<"$archive_info"
    [[ "$version" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ && "$checksum" =~ ^[a-fA-F0-9]{64}$ ]] ||
        die "Unexpected official Go release metadata."
    archive="$build_dir/$version.linux-$architecture.tar.gz"
    curl --fail --show-error --location --retry 2 --connect-timeout 15 \
        --max-time 300 --output "$archive" "https://go.dev/dl/$version.linux-$architecture.tar.gz" ||
        die "Failed downloading Go $version."
    printf '%s  %s\n' "$checksum" "$archive" | sha256sum -c - >/dev/null ||
        die "Official Go archive checksum mismatch."
    mkdir -p "$build_dir/go-toolchain"
    tar -xzf "$archive" -C "$build_dir/go-toolchain" || die "Could not unpack official Go."
    export PATH="$build_dir/go-toolchain/go/bin:$PATH"
    log "Using $(go version) for the AmneziaWG build."
}

install_amnezia_userspace_tools() {
    require_root
    local os_id build_dir go_binary tools_binary
    os_id=$(os_release_value ID 2>/dev/null || true)
    [[ "$os_id" == ubuntu ]] ||
        die "nns-app --install amnezia currently supports Ubuntu only (detected: ${os_id:-unknown})."
    command -v apt-get >/dev/null 2>&1 || die "apt-get is required on Ubuntu."

    log "Installing AmneziaWG 3.1 userspace prerequisites from Ubuntu repositories."
    log "External sources: $NNS_AWG_TOOLS_REPO ($NNS_AWG_TOOLS_TAG), $NNS_AWG_GO_REPO ($NNS_AWG_GO_TAG)."
    log "No kernel module, DKMS, PPA, or VPN service will be installed."
    DEBIAN_FRONTEND=noninteractive apt-get update || die "apt-get update failed."
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ca-certificates git build-essential make golang-go curl python3 \
        iproute2 iptables || die "Could not install Ubuntu build prerequisites."

    build_dir=$(mktemp -d /tmp/nns-amnezia-build.XXXXXXXX) || die "Cannot create private build directory."
    chmod 0700 "$build_dir"
    (
        set -Eeuo pipefail
        trap 'rm -rf -- "$build_dir"' EXIT
        if ! amnezia_go_version_usable; then
            amnezia_bootstrap_go "$build_dir"
        fi
        # A supported Go 1.21+ downloads a newer compiler as directed by the
        # project's go.mod, instead of modifying the system Go installation.
        export GOTOOLCHAIN=auto
        log "Cloning the pinned AmneziaWG 3.1 sources."
        git -c advice.detachedHead=false clone --quiet --depth 1 \
            --branch "$NNS_AWG_TOOLS_TAG" "$NNS_AWG_TOOLS_REPO" "$build_dir/tools"
        git -c advice.detachedHead=false clone --quiet --depth 1 \
            --branch "$NNS_AWG_GO_TAG" "$NNS_AWG_GO_REPO" "$build_dir/go-src"
        [[ "$(git -C "$build_dir/tools" describe --tags --exact-match 2>/dev/null)" == "$NNS_AWG_TOOLS_TAG" ]] ||
            die "Unexpected AmneziaWG tools revision."
        [[ "$(git -C "$build_dir/go-src" describe --tags --exact-match 2>/dev/null)" == "$NNS_AWG_GO_TAG" ]] ||
            die "Unexpected AmneziaWG Go revision."

        log "Building awg and amneziawg-go (userspace)."
        make -C "$build_dir/tools/src" -j "$(nproc)" wg
        (cd "$build_dir/go-src" && make)
        go_binary="$build_dir/go-src/amneziawg-go"
        tools_binary="$build_dir/tools/src/wg"
        [[ -s "$go_binary" && -x "$go_binary" && -s "$tools_binary" && -x "$tools_binary" ]] ||
            die "AmneziaWG build did not produce executable binaries."
        [[ -s "$build_dir/tools/src/wg-quick/linux.bash" ]] ||
            die "Missing upstream awg-quick launcher."

        # Install only after both builds succeed. Never replace a system
        # package-managed /usr/bin binary, and never touch VPN configuration.
        install -d -m 0755 /usr/local/bin
        install -m 0755 "$tools_binary" /usr/local/bin/awg
        install -m 0755 "$build_dir/tools/src/wg-quick/linux.bash" /usr/local/bin/awg-quick
        install -m 0755 "$go_binary" /usr/local/bin/amneziawg-go
    ) || die "AmneziaWG userspace installation failed. Existing VPN profiles were not modified."

    [[ -x /usr/local/bin/awg && -x /usr/local/bin/awg-quick && -x /usr/local/bin/amneziawg-go ]] ||
        die "AmneziaWG binaries are missing after installation."
    /usr/local/bin/awg --version || die "Installed awg binary failed its version check."
    /usr/local/bin/amneziawg-go --version || die "Installed userspace backend failed its version check."
    log "Installed userspace AmneziaWG tools in /usr/local/bin."
    log "Start an existing AmneziaWG app with: nns-app start <app_name>"
}
