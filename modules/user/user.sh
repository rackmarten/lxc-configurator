#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="user"
MODULE_DESCRIPTION="Configure the primary user, groups, shell, SSH key and Git identity"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

configure_user() {
    local ctid="${1:-}"
    shift || true
    declare -A options=()
    option_parse options "user,shell,groups" "$@"

    if [[ -z "${ctid}" ]]; then
        log_error "User configuration requires a CTID."
        return 2
    fi

    local user_name
    local user_shell
    local groups=()
    user_name="$(option_require options user USER_NAME '')"
    user_shell="$(option_get options shell USER_SHELL /bin/zsh)"
    option_list options groups USER_GROUPS sudo,docker groups

    [[ "${user_name}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || fatal "Invalid username '${user_name}'."
    [[ "${user_shell}" =~ ^/[A-Za-z0-9_@%+=:,./-]+$ ]] || fatal "Invalid shell path '${user_shell}'."

    : "${USER_PASSWORD:?USER_PASSWORD is required}"
    : "${GIT_USER_NAME:?GIT_USER_NAME is required}"
    : "${GIT_USER_EMAIL:?GIT_USER_EMAIL is required}"
    : "${GIT_DEFAULT_BRANCH:?GIT_DEFAULT_BRANCH is required}"
    : "${SSH_PUBLIC_KEY:?SSH_PUBLIC_KEY is required}"

    log_info "Configuring user '${user_name}' in LXC ${ctid}..."

    if guest_exec "${ctid}" id "${user_name}" >/dev/null 2>&1; then
        log_info "User '${user_name}' already exists."
    else
        guest_exec "${ctid}" useradd --create-home --shell "${user_shell}" "${user_name}"
        log_success "Created user '${user_name}'."
    fi

    local group
    for group in "${groups[@]}"; do
        if [[ "${group}" == docker ]] && ! guest_command_exists "${ctid}" docker; then
            continue
        fi
        if ! guest_exec "${ctid}" getent group "${group}" >/dev/null 2>&1; then
            continue
        fi
        if guest_exec "${ctid}" id -nG "${user_name}" | tr ' ' '\n' | grep -qx "${group}"; then
            log_info "User '${user_name}' is already in ${group} group."
        else
            guest_exec "${ctid}" usermod -aG "${group}" "${user_name}"
            log_success "Added '${user_name}' to ${group} group."
        fi
    done

    printf '%s:%s\n' "${user_name}" "${USER_PASSWORD}" | guest_exec "${ctid}" chpasswd

    local current_shell
    current_shell="$(guest_exec "${ctid}" getent passwd "${user_name}" | cut -d: -f7)"
    if [[ "${current_shell}" == "${user_shell}" ]]; then
        log_info "User shell is already ${user_shell}."
    else
        guest_exec "${ctid}" usermod --shell "${user_shell}" "${user_name}"
        log_success "Set ${user_name}'s shell to ${user_shell}."
    fi

    local home
    home="$(guest_user_home "${ctid}" "${user_name}")"
    guest_exec "${ctid}" install -d -m 700 -o "${user_name}" -g "${user_name}" "${home}/.ssh"
    guest_file_write "${ctid}" "${home}/.ssh/authorized_keys" "${SSH_PUBLIC_KEY}"
    guest_exec "${ctid}" chmod 600 "${home}/.ssh/authorized_keys"
    guest_exec "${ctid}" chown "${user_name}:${user_name}" "${home}/.ssh/authorized_keys"

    local personal_key_file="${home}/.ssh/id_ed25519"
    if guest_file_exists "${ctid}" "${personal_key_file}.pub"; then
        log_info "User '${user_name}' already has a personal SSH key."
    else
        local key_hostname
        key_hostname="$(guest_exec "${ctid}" hostname 2>/dev/null)"
        [[ -n "${key_hostname}" ]] || key_hostname="lxc-${ctid}"

        guest_exec_user "${ctid}" "${user_name}" \
            ssh-keygen -t ed25519 -N '' -f "${personal_key_file}" -C "${user_name}@${key_hostname}"
        log_success "Generated a personal SSH key for '${user_name}'."
    fi

    guest_exec "${ctid}" runuser -u "${user_name}" -- git config --global user.name "${GIT_USER_NAME}"
    guest_exec "${ctid}" runuser -u "${user_name}" -- git config --global user.email "${GIT_USER_EMAIL}"
    guest_exec "${ctid}" runuser -u "${user_name}" -- git config --global init.defaultBranch "${GIT_DEFAULT_BRANCH}"

    log_success "User '${user_name}' configured."
}

configure_user_help() {
    cat <<'EOF'
Usage: ./configurator.sh module user <ctid> [options]

Options:
  --user <name>       Override USER_NAME.
  --shell <path>      Override USER_SHELL (default: /bin/zsh).
  --groups <list>     Comma-separated groups (default: sudo,docker).
EOF
}
