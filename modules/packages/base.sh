#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="base"
MODULE_DESCRIPTION="Install base system packages"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

configure_base() {
    local ctid="${1:-}"

    if [[ -z "${ctid}" ]]; then
        log_error "Base package configuration requires a CTID."
        return 2
    fi

    log_info "Configuring base packages for LXC ${ctid}..."

    guest_install_packages "${ctid}" \
        ca-certificates \
        curl \
        git \
        sudo \
        zsh \
        micro \
        btop \
        jq \
        ripgrep \
        shellcheck

    log_success "Base packages configured for LXC ${ctid}."
}
