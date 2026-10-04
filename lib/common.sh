#!/usr/bin/env bash

log_info() {
  printf '[INFO] %s\n' "$*"
}

log_success() {
  printf '[OK] %s\n' "$*"
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

fatal() {
  log_error "$*"
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fatal "This script must be run as root."
  fi
}

dry_run_enabled() {
  [[ "${DRY_RUN:-false}" == "true" ]]
}

dry_run_command() {
  local description="${1:-}"

  dry_run_enabled || return 1
  log_info "[DRY-RUN] Would ${description}"
}

require_command() {
  local command="${1:-}"

  if [[ -z "${command}" ]]; then
    fatal "require_command requires a command name."
  fi

  if ! command_exists "${command}"; then
    fatal "Required command not found: ${command}"
  fi
}

trim_whitespace() {
    local value="${1:-}"

  printf '%s' "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}
