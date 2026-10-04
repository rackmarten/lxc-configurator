#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="ssh"
MODULE_DESCRIPTION="Configure SSH security"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

configure_ssh() {
    local ctid="${1:-}"

    if [[ -z "${ctid}" ]]; then
        log_error "SSH security configuration requires a CTID."
        return 2
    fi

    log_info "Configuring SSH security for LXC ${ctid}..."

    local sshd_config="/etc/ssh/sshd_config"

    guest_exec "${ctid}" test -f "${sshd_config}" || {
        log_error "SSH server configuration not found in LXC ${ctid}."
        return 1
    }

    if guest_exec "${ctid}" grep -Eq \
        '^[[:space:]]*PermitRootLogin[[:space:]]+no([[:space:]]|$)' \
        "${sshd_config}"; then

        log_info "Root SSH login is already disabled."

    else

        guest_exec "${ctid}" sed -i \
            -E 's/^[[:space:]]*#?[[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin no/' \
            "${sshd_config}"

        if ! guest_exec "${ctid}" grep -Eq \
            '^[[:space:]]*PermitRootLogin[[:space:]]+no([[:space:]]|$)' \
            "${sshd_config}"; then

            # shellcheck disable=SC2016  # '$1' is expanded by the guest's sh, not this shell.
            guest_exec "${ctid}" sh -c \
                'printf "%s\n" "PermitRootLogin no" >> "$1"' \
                sh "${sshd_config}"
        fi

        log_success "Disabled SSH root login."
    fi

    if ! guest_exec "${ctid}" sshd -t; then
        log_error "SSH configuration validation failed."
        return 1
    fi

    if guest_exec "${ctid}" systemctl is-active --quiet ssh; then
        if ! guest_exec "${ctid}" systemctl restart ssh; then
            log_error "Failed to restart SSH service."
            return 1
        fi
    else
        if ! guest_exec "${ctid}" systemctl start ssh; then
            log_error "Failed to start SSH service."
            return 1
        fi
    fi

    if ! guest_exec "${ctid}" systemctl is-active --quiet ssh; then
        log_error "SSH service is not running."
        return 1
    fi

    log_success "SSH security configured for LXC ${ctid}."
}
