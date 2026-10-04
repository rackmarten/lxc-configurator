#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="shell"
MODULE_DESCRIPTION="Configure shell environment"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

configure_shell() {
    local ctid="${1:-}"

    if [[ -z "${ctid}" ]]; then
        log_error "Shell configuration requires a CTID."
        return 2
    fi

    : "${USER_NAME:?USER_NAME is required}"

    log_info "Configuring shell environment for '${USER_NAME}' in LXC ${ctid}..."

    local home
    home="$(guest_user_home "${ctid}" "${USER_NAME}")"

    if [[ -z "${home}" ]]; then
        log_error "Could not determine home directory for '${USER_NAME}'."
        return 1
    fi

    if guest_file_exists "${ctid}" "${home}/.oh-my-zsh/oh-my-zsh.sh"; then
        log_info "Oh My Zsh is already installed."
    else
        log_info "Installing Oh My Zsh..."

        # shellcheck disable=SC2016  # This is a literal remote command string for the guest's sh, not local expansion.
        if ! guest_exec "${ctid}" runuser -u "${USER_NAME}" -- \
            env HOME="${home}" \
            RUNZSH=no \
            CHSH=no \
            KEEP_ZSHRC=yes \
            sh -c \
            'sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"' \
            >/dev/null 2>&1; then
            log_error "Failed to install Oh My Zsh."
            return 1
        fi

        log_success "Oh My Zsh installed."
    fi

    guest_exec "${ctid}" sed -i \
        's/^ZSH_THEME=.*/ZSH_THEME="af-magic"/' \
        "${home}/.zshrc"

    # shellcheck disable=SC2016  # '$1' below is expanded by the guest's sh, not this shell.
    guest_exec "${ctid}" sh -c \
        'grep -qxF "alias dc='\''docker compose'\''" "$1" ||
         printf "%s\n" "alias dc='\''docker compose'\''" >> "$1"' \
        sh "${home}/.zshrc"

    # shellcheck disable=SC2016  # '$1' below is expanded by the guest's sh, not this shell.
    guest_exec "${ctid}" sh -c \
        'grep -qxF "export EDITOR=micro" "$1" ||
         printf "%s\n" "export EDITOR=micro" >> "$1"' \
        sh "${home}/.zshrc"

    # shellcheck disable=SC2016  # '$1' below is expanded by the guest's sh, not this shell.
    guest_exec "${ctid}" sh -c \
        'grep -qxF "export VISUAL=micro" "$1" ||
         printf "%s\n" "export VISUAL=micro" >> "$1"' \
        sh "${home}/.zshrc"

    guest_exec "${ctid}" chown \
        "${USER_NAME}:${USER_NAME}" \
        "${home}/.zshrc"

    log_success "Shell environment configured for '${USER_NAME}'."
}
