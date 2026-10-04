#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="work-dir"
MODULE_DESCRIPTION="Configure the working directory"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

configure_work_dir() {
    local ctid="${1:-}"
    shift || true
    declare -A options=()
    option_parse options "path,user" "$@"

    if [[ -z "${ctid}" ]]; then
        log_error "Working directory configuration requires a CTID."
        return 2
    fi

    local user_name
    user_name="$(option_require options user USER_NAME '')"

    local work_dir
    work_dir="$(option_get options path WORK_DIR /app)"
    [[ "${work_dir}" == /* && "${work_dir}" != *$'\n'* && "${work_dir}" != *$'\r'* ]] || fatal "Invalid working directory path '${work_dir}'."

    log_info "Configuring working directory '${work_dir}' for LXC ${ctid}..."

    if guest_exec "${ctid}" test -e "${work_dir}"; then
        local current_owner
        current_owner="$(guest_exec "${ctid}" stat -c '%U:%G' "${work_dir}")"

        if [[ "${current_owner}" == "${user_name}:${user_name}" ]]; then
            log_info "Working directory is already owned by '${user_name}'."
        else
            if ! guest_exec "${ctid}" chown \
                "${user_name}:${user_name}" \
                "${work_dir}"; then
                log_error "Failed to update ownership of '${work_dir}'."
                return 1
            fi

            log_success "Working directory ownership updated."
        fi
    else
        if ! guest_exec "${ctid}" install -d \
            -m 755 \
            -o "${user_name}" \
            -g "${user_name}" \
            "${work_dir}"; then
            log_error "Failed to create working directory '${work_dir}'."
            return 1
        fi

        log_success "Created working directory '${work_dir}'."
    fi

    if ! guest_exec "${ctid}" test -d "${work_dir}"; then
        log_error "Working directory '${work_dir}' does not exist."
        return 1
    fi

    if ! guest_exec "${ctid}" sudo -u "${user_name}" test -w "${work_dir}"; then
        log_error "User '${user_name}' cannot write to '${work_dir}'."
        return 1
    fi

    log_success "Working directory '${work_dir}' configured for LXC ${ctid}."
}

configure_work_dir_help() {
        cat <<'EOF'
Usage: ./configurator.sh module work-dir <ctid> [options]

Options:
    --path <path>        Override WORK_DIR (default: /app).
    --user <name>        Override USER_NAME (owner of the working directory).
EOF
}
