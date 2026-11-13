#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export NNS_APP_SOURCE_ONLY=1
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT
export NNS_APP_LOCK_DIR="$TEST_TMP/locks"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
source "$ROOT/install_linux"
fail() { echo "FAIL: $*" >&2; exit 1; }

# The helper requires only a real app name and an installed app directory.
# Mock only that filesystem location; Git config operations are all real.
cfg_file() { printf '%s/apps/%s/%s.cfg\n' "$TEST_TMP" "$1" "$1"; }
mkdir -p "$TEST_TMP/apps/demo-vpn" "$TEST_TMP/apps/office"
touch "$TEST_TMP/apps/demo-vpn/demo-vpn.cfg" "$TEST_TMP/apps/office/office.cfg"
mkdir "$TEST_TMP/repo"
cd "$TEST_TMP/repo"
git init -q

# The ordinary flow should create only a local core.sshCommand override.
git_via_command demo-vpn >/dev/null
[[ $(git config --local --get core.sshCommand) == '/usr/local/bin/nns-app run demo-vpn ssh' ]] || fail 'initial SSH command'
[[ $(git config --local --get nnsGitVia.activeApp) == demo-vpn ]] || fail 'active marker'
[[ $(git config --local --get nnsGitVia.previousSet) == no ]] || fail 'saved absent state'

# Switching profiles preserves the original SSH command before the first use.
git_via_command office >/dev/null
[[ $(git config --local --get core.sshCommand) == '/usr/local/bin/nns-app run office ssh' ]] || fail 'app switching'
[[ $(git config --local --get nnsGitVia.previousSet) == no ]] || fail 'app switching lost original'
git_via_command - >/dev/null
if git config --local --get core.sshCommand >/dev/null; then fail 'SSH command should be absent'; fi
if git config --local --get nnsGitVia.activeApp >/dev/null; then fail 'active marker not removed'; fi
if git config --local --get nnsGitVia.previousSet >/dev/null; then fail 'saved marker not removed'; fi

# Reset must restore the *exact* custom local command, including whitespace.
original='ssh -F "/home/test user/.ssh/config" -o ProxyJump=jump-host'
git config --local core.sshCommand "$original"
git_via_command demo-vpn >/dev/null
git_via_command office >/dev/null
git_via_command - >/dev/null
[[ $(git config --local --get core.sshCommand) == "$original" ]] || fail 'custom local SSH command not restored'
if git config --local --get nnsGitVia.previousSSHCommand >/dev/null; then fail 'saved command not removed'; fi

# Do not overwrite a SSH command modified outside git-via, on activate or reset.
git_via_command demo-vpn >/dev/null
git config --local core.sshCommand 'ssh -p 2222'
if (git_via_command -) >"$TEST_TMP/external.err" 2>&1; then fail 'external reset overwrite'; fi
[[ $(git config --local --get core.sshCommand) == 'ssh -p 2222' ]] || fail 'external command modified'
if (git_via_command office) >"$TEST_TMP/external.err" 2>&1; then fail 'external switch overwrite'; fi
git config --local core.sshCommand '/usr/local/bin/nns-app run demo-vpn ssh'
git_via_command - >/dev/null
[[ $(git config --local --get core.sshCommand) == "$original" ]] || fail 'external-change recovery'

# Existing manual nns-app overrides can be cleared without markers.
git config --local core.sshCommand 'nns-app run demo-vpn ssh'
git_via_command - >/dev/null
if git config --local --get core.sshCommand >/dev/null; then fail 'manual legacy override not removed'; fi

git config --local core.sshCommand 'ssh -p 2202'
git_via_command - >/dev/null
[[ $(git config --local --get core.sshCommand) == 'ssh -p 2202' ]] || fail 'non-nns override lost'

# A second Git repository must not be modified by the helper.
mkdir "$TEST_TMP/other"
git -C "$TEST_TMP/other" init -q
if git -C "$TEST_TMP/other" config --local --get core.sshCommand >/dev/null; then fail 'other repo affected'; fi

# Invalid application name must not be shell-interpreted.
if (git_via_command 'demo-vpn;touch /tmp/git-via-injection') >"$TEST_TMP/unsafe.out" 2>&1; then fail 'invalid app accepted'; fi
if (git_via_command notinstalled) >"$TEST_TMP/unsafe.out" 2>&1; then fail 'uninstalled app accepted'; fi
[[ $(git config --local --get core.sshCommand) == 'ssh -p 2202' ]] || fail 'invalid app altered SSH command'

# Reject invocation outside a repository, including Git's --local operation.
cd "$TEST_TMP"
if (git_via_command demo-vpn) >"$TEST_TMP/outside.err" 2>&1; then fail 'non-repository invocation accepted'; fi

# The installed helper symlink dispatches without sudo and exposes help.
ln -s "$ROOT/install_linux" "$TEST_TMP/git-via"
NNS_APP_SOURCE_ONLY=0 "$TEST_TMP/git-via" --help | grep -q 'Usage: git-via' || fail 'symlink entrypoint'

# The ordinary nns-app command also dispatches without requiring root.
(
  git_via_command() { [[ "$1" == - ]] || fail 'incorrect nns-app git-via arguments'; }
  main git-via -
)

echo 'git-via repository-local config, restore, switching, security, and symlink tests passed.'
