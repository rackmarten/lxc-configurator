#!/usr/bin/env bash

# Helpers for managing raw LXC configuration directives
# in /etc/pve/lxc/<ctid>.conf.

lxc_config_file() {
    local ctid="${1:-}"

    _lxc_validate_ctid "$ctid" || return 2

    local config_file="/etc/pve/lxc/${ctid}.conf"

    if [[ ! -f "$config_file" ]]; then
        printf '%s\n' "lxc_config_file: configuration file does not exist: ${config_file}" >&2
        return 1
    fi

    printf '%s\n' "$config_file"
}

lxc_config_has_line() {
    local ctid="${1:-}"
    local line="${2:-}"
    local config_file

    if [[ -z "$line" ]]; then
        printf '%s\n' "lxc_config_has_line: configuration line is required." >&2
        return 2
    fi

    if dry_run_enabled; then
        log_info "[DRY-RUN] Unable to inspect LXC ${ctid} configuration without root."
        return 1
    fi

    config_file="$(lxc_config_file "$ctid")" || return

    grep -Fqx -- "$line" "$config_file"
}

lxc_config_add_line() {
    local ctid="${1:-}"
    local line="${2:-}"
    local config_file

    if [[ -z "$line" ]]; then
        printf '%s\n' "lxc_config_add_line: configuration line is required." >&2
        return 2
    fi

    if dry_run_enabled; then
        dry_run_command "add LXC ${ctid} configuration line: ${line}"
        return 0
    fi

    config_file="$(lxc_config_file "$ctid")" || return

    if grep -Fqx -- "$line" "$config_file"; then
        return 0
    fi

    printf '%s\n' "$line" >> "$config_file"
}
