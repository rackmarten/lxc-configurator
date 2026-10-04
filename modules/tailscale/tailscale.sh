#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="tailscale"
MODULE_DESCRIPTION="Configure Tailscale"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

configure_tailscale() {
    local ctid="${1:-}"

    if [[ -z "${ctid}" ]]; then
        log_error "Tailscale configuration requires a CTID."
        return 2
    fi

    : "${TAILSCALE_LOGIN_SERVER:?TAILSCALE_LOGIN_SERVER is required}"

    log_info "Configuring Tailscale for LXC ${ctid}..."

    # Pin the login server to its LAN address so the control and DERP
    # connections skip the ISP router's hairpin NAT, which drops them after
    # ~30-60s idle. Lines outside Proxmox's "BEGIN PVE" block survive restarts.
    # An existing pin to a different address is replaced, not kept: a stale pin
    # (e.g. to headscale itself instead of the TLS-terminating proxy) makes
    # every connection attempt fail while looking like a hang.
    if [[ -n "${TAILSCALE_LOGIN_SERVER_LAN_IP:-}" ]]; then
        local login_host="${TAILSCALE_LOGIN_SERVER#*://}"
        login_host="${login_host%%[/:]*}"
        local host_re="${login_host//./\\.}"
        local pin_line="${TAILSCALE_LOGIN_SERVER_LAN_IP} ${login_host}  # skip ISP router hairpin NAT"

        if ! guest_exec "${ctid}" sh -c \
            "grep -qxF '${pin_line}' /etc/hosts || { sed -i -E '/[[:space:]]${host_re}([[:space:]]|\$)/d' /etc/hosts && echo '${pin_line}' >> /etc/hosts; }"; then
            log_error "Failed to pin ${login_host} in /etc/hosts of LXC ${ctid}."
            return 1
        fi
    fi

    if guest_command_exists "${ctid}" tailscale; then
        log_info "Tailscale is already installed."
    else
        log_info "Installing Tailscale..."

        if ! guest_exec "${ctid}" sh -c \
            'curl -fsSL https://tailscale.com/install.sh | sh' >/dev/null 2>&1; then
            log_error "Failed to install Tailscale in LXC ${ctid}."
            return 1
        fi

        log_success "Tailscale installed."
    fi

    if guest_exec "${ctid}" systemctl is-active --quiet tailscaled; then
        if guest_exec "${ctid}" tailscale status >/dev/null 2>&1; then
            log_info "Tailscale is already configured."
            return 0
        fi
    else
        log_info "Starting Tailscale daemon..."

        if ! guest_exec "${ctid}" systemctl start tailscaled >/dev/null 2>&1; then
            log_error "Failed to start tailscaled in LXC ${ctid}."
            return 1
        fi
    fi

    if guest_exec "${ctid}" tailscale status >/dev/null 2>&1; then
        log_info "Tailscale is already configured."
        return 0
    fi

    : "${TAILSCALE_AUTH_KEY:?TAILSCALE_AUTH_KEY is required when connecting a new LXC}"

    log_info "Connecting LXC ${ctid} to Tailscale..."

    # Without --timeout, `tailscale up` blocks forever when it cannot reach the
    # login server or the key is rejected, and with its output discarded that
    # looks like a silent hang. The output is shown only on failure, since the
    # dry-run log of this command would include the auth key.
    local up_output
    if ! up_output="$(guest_exec "${ctid}" tailscale up \
        --login-server="${TAILSCALE_LOGIN_SERVER}" \
        --auth-key="${TAILSCALE_AUTH_KEY}" \
        --timeout="${TAILSCALE_UP_TIMEOUT:-60s}" 2>&1)"; then
        log_error "Failed to connect LXC ${ctid} to Tailscale: ${up_output}"
        log_error "Check that ${TAILSCALE_LOGIN_SERVER} is reachable from the LXC and that TAILSCALE_AUTH_KEY is valid."
        return 1
    fi

    log_success "Tailscale configured for LXC ${ctid}."
}
