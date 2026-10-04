#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="incinerator"
MODULE_DESCRIPTION="Install incinerator, the local disk cleanup, with its daily and pressure timers"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

# Installs modules/system/incinerator/* into the guest. Each file is only
# rewritten when its content differs, and systemd is only reloaded when a unit
# changed, so re-running is a no-op on an up-to-date guest.
configure_incinerator() {
    local ctid="${1:-}"
    shift || true
    declare -A options=()
    option_parse options "" "$@"

    if [[ -z "${ctid}" ]]; then
        log_error "Incinerator configuration requires a CTID."
        return 2
    fi

    local source_dir="${SCRIPT_DIR}/modules/system/incinerator"
    local units=(incinerator-daily.service incinerator-daily.timer incinerator-pressure.service incinerator-pressure.timer)

    log_info "Configuring incinerator for LXC ${ctid}..."

    guest_install_packages "${ctid}" jq || return 1

    local changed_units=false
    incinerator_install_file "${ctid}" "${source_dir}/incinerator" /usr/local/sbin/incinerator 755 || [[ $? -eq 10 ]] || return 1

    local unit
    for unit in "${units[@]}"; do
        if incinerator_install_file "${ctid}" "${source_dir}/${unit}" "/etc/systemd/system/${unit}" 644; then
            :
        else
            local status=$?
            [[ ${status} -eq 10 ]] || return 1
            changed_units=true
        fi
    done

    if [[ "${changed_units}" == true ]]; then
        guest_exec "${ctid}" systemctl daemon-reload || {
            log_error "systemctl daemon-reload failed in LXC ${ctid}."
            return 1
        }
    fi

    local timer
    for timer in incinerator-daily.timer incinerator-pressure.timer; do
        if guest_exec "${ctid}" systemctl is-enabled --quiet "${timer}" &&
            guest_exec "${ctid}" systemctl is-active --quiet "${timer}"; then
            log_info "Timer '${timer}' is already enabled."
        else
            guest_exec "${ctid}" systemctl enable --now "${timer}" || {
                log_error "Failed to enable '${timer}' in LXC ${ctid}."
                return 1
            }
            log_success "Enabled '${timer}'."
        fi
    done

    log_success "Incinerator configured for LXC ${ctid}."
}

# Returns 0 when the guest file already matches, 10 when it was (re)written,
# 1 on failure.
incinerator_install_file() {
    local ctid="${1:-}" source="${2:-}" target="${3:-}" mode="${4:-}"
    local content current=""

    content="$(<"${source}")" || fatal "Missing incinerator source file '${source}'."

    if guest_file_exists "${ctid}" "${target}"; then
        current="$(guest_file_read "${ctid}" "${target}")" || current=""
    fi

    if [[ "${current}" == "${content}" ]] && ! dry_run_enabled; then
        log_info "'${target}' is already up to date."
        return 0
    fi

    if ! guest_file_write "${ctid}" "${target}" "${content}" ||
        ! guest_exec "${ctid}" chmod "${mode}" "${target}"; then
        log_error "Failed to install '${target}' in LXC ${ctid}."
        return 1
    fi

    log_success "Installed '${target}'."
    return 10
}

configure_incinerator_help() {
        cat <<'EOF'
Usage: ./configurator.sh module incinerator <ctid>

Installs /usr/local/sbin/incinerator (bash + jq) and the systemd units
incinerator-daily.timer (03:30 + up to 45m) and incinerator-pressure.timer
(every 15 minutes). Per-host policy lives in the guest at
/app/.homelab/incinerator.json; without it, built-in defaults apply.
EOF
}
