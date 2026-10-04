#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="kvm"
MODULE_DESCRIPTION="Pass /dev/kvm through for hardware-accelerated nested virtualization"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

configure_kvm() {
    local ctid="${1:-}"
    local changed=false

    if [[ -z "${ctid}" ]]; then
        log_error "KVM configuration requires a CTID."
        return 2
    fi

    if [[ ! -e /dev/kvm ]]; then
        log_error "/dev/kvm does not exist on this host - the CPU/hypervisor doesn't expose virtualization support here."
        return 1
    fi

    log_info "Configuring /dev/kvm passthrough for LXC ${ctid}..."

    local major minor
    major="$((0x$(stat -c '%t' /dev/kvm)))"
    minor="$((0x$(stat -c '%T' /dev/kvm)))"
    local allow_line="lxc.cgroup2.devices.allow: c ${major}:${minor} rwm"
    local mount_line="lxc.mount.entry: /dev/kvm dev/kvm none bind,optional,create=file"

    if lxc_config_has_line "${ctid}" "${allow_line}"; then
        log_info "KVM device permission already configured."
    else
        lxc_config_add_line "${ctid}" "${allow_line}"
        log_success "Added KVM device permission (${major}:${minor})."
        changed=true
    fi

    if lxc_config_has_line "${ctid}" "${mount_line}"; then
        log_info "KVM device mount already configured."
    else
        lxc_config_add_line "${ctid}" "${mount_line}"
        log_success "Added KVM device mount."
        changed=true
    fi

    # Unprivileged containers map their root to a non-zero host UID, which
    # can't satisfy /dev/kvm's default "root:kvm 0660" host-side permissions
    # even once bind-mounted in - widen it so the mapped root can open it.
    # Persisted via udev so it survives host reboots (a plain chmod would
    # reset on the next one). Confirmed working this way on sandbox (LXC 301).
    local udev_rule="/etc/udev/rules.d/65-kvm-lxc.rules"
    local udev_line='KERNEL=="kvm", GROUP="kvm", MODE="0666"'

    if [[ -f "${udev_rule}" ]] && grep -Fqx -- "${udev_line}" "${udev_rule}"; then
        log_info "KVM udev permission rule already present."
    else
        if dry_run_enabled; then
            dry_run_command "write ${udev_rule} widening /dev/kvm to mode 0666"
        else
            printf '%s\n' "${udev_line}" >"${udev_rule}"
            udevadm control --reload-rules
            udevadm trigger --name-match=kvm
            log_success "Added KVM udev permission rule and widened /dev/kvm to 0666."
        fi
        changed=true
    fi

    if [[ "${changed}" == "true" ]]; then
        log_info "LXC ${ctid} needs a restart (pct reboot ${ctid}) for the device passthrough to take effect."
        return 10
    fi

    return 0
}
