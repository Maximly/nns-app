#!/bin/bash
# Install the precompiled macOS backend. The release's install_macos embeds these files.
set -euo pipefail
[ "$(uname -s)" = Darwin ] || { echo 'ERROR: macOS only' >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo 'Run sudo ./install_macos' >&2; exit 1; }

ROOT=$(cd "$(dirname "$0")" && pwd -P)
[ -x "$ROOT/bin/nns-run" ] && [ -f "$ROOT/bin/libnnsbind.dylib" ] || {
  echo 'ERROR: missing prebuilt macOS binaries; build.sh must run on a Mac first.' >&2
  exit 1
}

# The installer includes nns-app's own executable, launcher and dylib.
# Like install_linux using apt/dnf, runtime tools are installed through the
# platform package manager only when absent. Homebrew itself is a prerequisite.
has_command() {
  local command_name=$1 location
  for location in \
    "/opt/homebrew/bin/$command_name" "/usr/local/bin/$command_name" \
    "/opt/homebrew/opt/curl/bin/$command_name" "/usr/local/opt/curl/bin/$command_name" \
    "/opt/homebrew/opt/openssh/bin/$command_name" "/usr/local/opt/openssh/bin/$command_name"; do
    [ ! -x "$location" ] || return 0
  done
  return 1
}

packages=()
has_command wireguard-go || packages+=(wireguard-go)
if ! has_command wg || ! has_command wg-quick; then packages+=(wireguard-tools); fi
has_command curl || packages+=(curl)
# macOS /usr/bin/ssh is SIP-protected; Git needs a Homebrew-compatible SSH.
has_command ssh || packages+=(openssh)

if [ "${#packages[@]}" -ne 0 ]; then
  BREW=''
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then BREW=$candidate; break; fi
  done
  [ -n "$BREW" ] || {
    echo 'ERROR: Homebrew is required to install WireGuard/SSH runtime dependencies.' >&2
    echo 'Install Homebrew first, then rerun sudo ./install_macos.' >&2
    exit 1
  }
  [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] || {
    echo 'ERROR: run sudo ./install_macos from your macOS account; brew must not run as root.' >&2
    exit 1
  }
  printf 'Installing missing Homebrew dependencies: %s\n' "${packages[*]}"
  /usr/bin/sudo -H -u "$SUDO_USER" "$BREW" install "${packages[@]}"
fi

install -d -m 755 /usr/local/bin /usr/local/libexec/nns-app
install -m 755 "$ROOT/nns-app-darwin.sh" /usr/local/bin/nns-app
install -m 755 "$ROOT/bin/nns-run" /usr/local/libexec/nns-app/nns-run
install -m 755 "$ROOT/bin/libnnsbind.dylib" /usr/local/libexec/nns-app/libnnsbind.dylib
ln -sf /usr/local/bin/nns-app /usr/local/bin/git-via
printf 'Installed nns-app 2.1.0 (macOS) at /usr/local/bin/nns-app\n'
