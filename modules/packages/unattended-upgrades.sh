#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="unattended-upgrades"
MODULE_DESCRIPTION="Configure unattended upgrades"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

configure_unattended_upgrades() {
    local ctid="${1:-}"

    if [[ -z "${ctid}" ]]; then
        log_error "Unattended upgrades configuration requires a CTID."
        return 2
    fi

    log_info "Configuring unattended upgrades for LXC ${ctid}..."

    guest_install_packages "${ctid}" \
        unattended-upgrades \
        apt-listchanges

    if guest_exec "${ctid}" test -f /etc/apt/apt.conf.d/20auto-upgrades; then
        log_info "Automatic upgrades are already configured."
    else
        guest_exec "${ctid}" sh -c \
            'printf "%s\n" \
                "APT::Periodic::Update-Package-Lists \"1\";" \
                "APT::Periodic::Unattended-Upgrade \"1\";" \
                > /etc/apt/apt.conf.d/20auto-upgrades'

        log_success "Enabled automatic security updates."
    fi

    log_success "Unattended upgrades configured for LXC ${ctid}."
}
