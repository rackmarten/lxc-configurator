#!/usr/bin/env bash

# Helpers for executing commands and managing packages/files inside LXC guests.

guest_exec() {
  local ctid="${1:-}"

  if [[ -z "${ctid}" ]]; then
    printf '%s\n' "guest_exec: CTID is required." >&2
    return 2
  fi

  shift

  if [[ $# -eq 0 ]]; then
    printf '%s\n' "guest_exec: no command specified." >&2
    return 2
  fi

  if dry_run_enabled; then
    local command_line
    printf -v command_line '%q ' "$@"
    log_info "[DRY-RUN] Would execute in LXC ${ctid}: ${command_line% }"
    return 0
  fi

  lxc_exec "${ctid}" "$@"
}

guest_exec_user() {
  local ctid="${1:-}"
  local user="${2:-}"

  if [[ -z "${ctid}" ]]; then
    printf '%s\n' "guest_exec_user: CTID is required." >&2
    return 2
  fi

  if [[ -z "${user}" ]]; then
    printf '%s\n' "guest_exec_user: user is required." >&2
    return 2
  fi

  shift 2

  if [[ $# -eq 0 ]]; then
    printf '%s\n' "guest_exec_user: no command specified." >&2
    return 2
  fi

  guest_exec "${ctid}" runuser -u "${user}" -- "$@"
}

guest_command_exists() {
  local ctid="${1:-}"
  local command="${2:-}"

  if [[ -z "${command}" ]]; then
    printf '%s\n' "guest_command_exists: command is required." >&2
    return 2
  fi

  # shellcheck disable=SC2016  # '$1' is expanded by the guest's sh, not this shell.
  guest_exec "${ctid}" sh -c 'command -v "$1" >/dev/null 2>&1' \
    sh "${command}"
}

guest_user_home() {
  local ctid="${1:-}"
  local user="${2:-}"
  local home

  if [[ -z "${user}" ]]; then
    printf '%s\n' "guest_user_home: user is required." >&2
    return 2
  fi

  home="$(guest_exec "${ctid}" getent passwd "${user}" | cut -d: -f6)"

  # guest_exec never actually runs anything under dry-run, so getent always
  # comes back empty - fall back to the conventional path so callers can
  # still preview what they'd do instead of failing on an empty value.
  if [[ -z "${home}" ]] && dry_run_enabled; then
    home="/home/${user}"
  fi

  printf '%s\n' "${home}"
}

guest_file_exists() {
  local ctid="${1:-}"
  local file="${2:-}"

  if [[ -z "${file}" ]]; then
    printf '%s\n' "guest_file_exists: file path is required." >&2
    return 2
  fi

  guest_exec "${ctid}" test -e "${file}"
}

guest_package_installed() {
  local ctid="${1:-}"
  local package="${2:-}"

  if [[ -z "${package}" ]]; then
    printf '%s\n' "guest_package_installed: package name is required." >&2
    return 2
  fi

  # shellcheck disable=SC2016  # '${Status}' is dpkg-query's own format placeholder, not shell expansion.
  guest_exec "${ctid}" dpkg-query \
    -W \
    -f='${Status}' \
    "${package}" 2>/dev/null |
    grep -q '^install ok installed$'
}

guest_install_packages() {
  local ctid="${1:-}"
  shift

  if [[ $# -eq 0 ]]; then
    printf '%s\n' "guest_install_packages: at least one package is required." >&2
    return 2
  fi

  local missing=()
  local package

  for package in "$@"; do
    if ! guest_package_installed "${ctid}" "${package}"; then
      missing+=("${package}")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log_info "All requested packages are already installed."
    return 0
  fi

  log_info "Installing packages in LXC ${ctid}: ${missing[*]}"

  if ! guest_exec "${ctid}" apt-get update -qq >/dev/null 2>&1; then
    log_error "Failed to update package lists in LXC ${ctid}."
    return 1
  fi

  if ! guest_exec "${ctid}" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq \
    "${missing[@]}" >/dev/null 2>&1; then
    log_error "Failed to install packages in LXC ${ctid}: ${missing[*]}"
    return 1
  fi

  log_success "Installed ${#missing[@]} package(s) in LXC ${ctid}."
}

guest_file_read() {
  local ctid="${1:-}"
  local file="${2:-}"

  if [[ -z "${file}" ]]; then
    printf '%s\n' "guest_file_read: file path is required." >&2
    return 2
  fi

  guest_exec "${ctid}" cat -- "${file}"
}

guest_file_write() {
  local ctid="${1:-}"
  local file="${2:-}"
  local content="${3:-}"

  if [[ -z "${file}" ]]; then
    printf '%s\n' "guest_file_write: file path is required." >&2
    return 2
  fi

  # shellcheck disable=SC2016  # '$1' is expanded by the guest's sh, not this shell.
  guest_exec "${ctid}" sh -c 'cat > "$1"' sh "${file}" <<< "${content}"
}
