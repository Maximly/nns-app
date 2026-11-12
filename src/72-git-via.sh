# nns-app source module: repository-local SSH transport routing for Git.
# This module is intentionally unprivileged and never runs Git through sudo.
# `git-via <app>` affects this repository's Git SSH transport only. HTTPS
# remotes, other repositories, and the host's SSH configuration are unchanged.

git_via_command() {
    if (( $# != 1 )); then
        die "Usage: git-via <nns-app-name>|- (run inside a Git repository)"
    fi
    case "$1" in
        -h|--help)
            printf 'Usage: git-via <nns-app-name>|-\n  git-via app  Configure this repository SSH through nns-app\n  git-via -    Restore previous repository SSH command\n'
            return 0
            ;;
    esac

    command -v git >/dev/null 2>&1 || die "git is not installed."
    git rev-parse --git-dir >/dev/null 2>&1 ||
        die "git-via must be run inside a Git repository."

    # Read local config only, so inherited/global SSH settings are restored
    # automatically by clearing our local override. Preserve an explicit
    # local command precisely, including whitespace, if one already exists.
    local -a current_commands=()
    mapfile -d '' -t current_commands < <(git config --local --null --get-all core.sshCommand || true)
    (( ${#current_commands[@]} <= 1 )) ||
        die "Multiple local core.sshCommand values exist; resolve them before git-via."

    local active="" previous_set="" previous="" desired="" app=$1
    active=$(git config --local --get nnsGitVia.activeApp 2>/dev/null || true)

    if [[ "$app" == - ]]; then
        if [[ -z "$active" ]]; then
            # Support resetting older manually configured nns-app SSH overrides
            # without modifying an unrelated pre-existing SSH command.
            if (( ${#current_commands[@]} == 1 )) &&
               [[ "${current_commands[0]}" =~ ^(nns-app|/usr/local/bin/nns-app)[[:space:]]+run[[:space:]]+[A-Za-z0-9][A-Za-z0-9._-]{0,31}[[:space:]]+ssh$ ]]; then
                git config --local --unset-all core.sshCommand
                log "Removed the manual nns-app Git SSH override; Git now uses its ordinary SSH configuration."
            else
                log "No git-via Git SSH override is active in this repository."
            fi
            return 0
        fi

        desired="$USER_PATH run $active ssh"
        if (( ${#current_commands[@]} != 1 )) || [[ "${current_commands[0]}" != "$desired" ]]; then
            die "core.sshCommand was changed outside git-via; refusing to overwrite it. Inspect git config --local --get core.sshCommand."
        fi
        previous_set=$(git config --local --get nnsGitVia.previousSet 2>/dev/null || true)
        case "$previous_set" in
            yes)
                previous=$(git config --local --get nnsGitVia.previousSSHCommand) ||
                    die "Saved Git SSH command missing; refusing to discard it."
                git config --local --replace-all core.sshCommand "$previous"
                log "Restored the previous repository-local Git SSH command."
                ;;
            no)
                git config --local --unset-all core.sshCommand
                log "Removed the repository-local Git SSH override; Git uses its ordinary SSH configuration."
                ;;
            *) die "Saved git-via state is incomplete; refusing to alter Git SSH settings." ;;
        esac
        git config --local --unset-all nnsGitVia.activeApp
        git config --local --unset-all nnsGitVia.previousSet
        if [[ "$previous_set" == yes ]]; then
            git config --local --unset-all nnsGitVia.previousSSHCommand
        fi
        return 0
    fi

    validate_app_name "$app"
    [[ -f "$(cfg_file "$app")" ]] ||
        die "NNS app '$app' is not installed. Install it with nns-app before configuring Git."

    # Switching to another app must not replace the original SSH setting
    # saved before the first git-via invocation.
    if [[ -n "$active" ]]; then
        desired="$USER_PATH run $active ssh"
        if (( ${#current_commands[@]} != 1 )) || [[ "${current_commands[0]}" != "$desired" ]]; then
            die "core.sshCommand was changed outside git-via; refusing to overwrite it."
        fi
    else
        [[ -z "$(git config --local --get nnsGitVia.previousSet 2>/dev/null || true)" ]] ||
            die "Incomplete previous git-via state; refusing to replace saved settings."
        if (( ${#current_commands[@]} == 1 )); then
            git config --local --replace-all nnsGitVia.previousSSHCommand "${current_commands[0]}"
            git config --local --replace-all nnsGitVia.previousSet yes
        else
            git config --local --replace-all nnsGitVia.previousSet no
        fi
    fi

    git config --local --replace-all core.sshCommand "$USER_PATH run $app ssh"
    git config --local --replace-all nnsGitVia.activeApp "$app"
    log "This repository's Git SSH transport now uses nns-app '$app'."
    log "Use ordinary git pull/fetch/push; run 'git-via -' to restore Git SSH."
}
