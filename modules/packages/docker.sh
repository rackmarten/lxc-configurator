#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="docker"
MODULE_DESCRIPTION="Install Docker"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

configure_docker() {
    local ctid="${1:-}"

    if [[ -z "${ctid}" ]]; then
        log_error "Docker configuration requires a CTID."
        return 2
    fi

    log_info "Configuring Docker for LXC ${ctid}..."

    if guest_command_exists "${ctid}" docker; then
        log_info "Docker is already installed."
    else
        guest_install_packages "${ctid}" ca-certificates curl

        log_info "Installing Docker repository..."

        # shellcheck disable=SC2016  # This is a literal remote script for the guest's sh, not local expansion.
        if ! guest_exec "${ctid}" sh -c '
            install -m 0755 -d /etc/apt/keyrings &&
            curl -fsSL https://download.docker.com/linux/debian/gpg \
                -o /etc/apt/keyrings/docker.asc &&
            chmod a+r /etc/apt/keyrings/docker.asc &&
            . /etc/os-release &&
            cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
        ' >/dev/null; then
            log_error "Failed to configure Docker repository."
            return 1
        fi

        if ! guest_exec "${ctid}" apt-get update -qq >/dev/null 2>&1; then
            log_error "Failed to update package lists after adding Docker repository."
            return 1
        fi

        if ! guest_exec "${ctid}" env DEBIAN_FRONTEND=noninteractive \
            apt-get install -y -qq \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin >/dev/null 2>&1; then
            log_error "Failed to install Docker."
            return 1
        fi

        log_success "Docker installed."
    fi

    guest_exec "${ctid}" systemctl enable docker >/dev/null 2>&1 || true

    if ! guest_exec "${ctid}" systemctl is-active --quiet docker >/dev/null 2>&1; then
        log_info "Starting Docker..."
        guest_exec "${ctid}" systemctl start docker >/dev/null 2>&1
    fi

    log_success "Docker configured for LXC ${ctid}."
}
