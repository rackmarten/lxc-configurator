#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="tun"
MODULE_DESCRIPTION="Configure TUN access"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

configure_tun() {
    local ctid="${1:-}"
    local changed=false

    if [[ -z "${ctid}" ]]; then
        log_error "TUN configuration requires a CTID."
        return 2
    fi

    log_info "Configuring TUN access for LXC ${ctid}..."

    if lxc_config_has_line \
        "${ctid}" \
        "lxc.cgroup2.devices.allow: c 10:200 rwm"; then
        log_info "TUN device permission already configured."
    else
        lxc_config_add_line \
            "${ctid}" \
            "lxc.cgroup2.devices.allow: c 10:200 rwm"

        log_success "Added TUN device permission."
        changed=true
    fi

    if lxc_config_has_line \
        "${ctid}" \
        "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"; then
        log_info "TUN device mount already configured."
    else
        lxc_config_add_line \
            "${ctid}" \
            "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"

        log_success "Added TUN device mount."
        changed=true
    fi

    if [[ "${changed}" == "true" ]]; then
        return 10
    fi

    return 0
}
