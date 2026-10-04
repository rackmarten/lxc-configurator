#!/usr/bin/env bash

# Small Proxmox/LXC helper layer for host-side operations.
#
# This file provides the basic interface used by provisioning modules
# to inspect and execute commands against LXC containers.

_lxc_require_pct() {
  if ! command -v pct >/dev/null 2>&1; then
    printf '%s\n' "lxc: 'pct' is not available on this host." >&2
    return 1
  fi
}

_lxc_validate_ctid() {
  local ctid="${1:-}"

  if [[ -z "${ctid}" ]]; then
    printf '%s\n' "lxc: CTID is required." >&2
    return 2
  fi

  if [[ ! "${ctid}" =~ ^[0-9]+$ ]]; then
    printf '%s\n' \
      "lxc: invalid CTID '${ctid}'. Expected a numeric container ID." >&2
    return 2
  fi
}

lxc_exists() {
  local ctid="${1:-}"

  _lxc_validate_ctid "${ctid}" >/dev/null || return 2

  if dry_run_enabled; then
    log_info "[DRY-RUN] Unable to inspect whether LXC ${ctid} exists without root."
    return 0
  fi

  _lxc_require_pct || return 1

  pct status "${ctid}" >/dev/null 2>&1
}

lxc_is_running() {
  local ctid="${1:-}"
  local status

  _lxc_validate_ctid "${ctid}" >/dev/null || return 2
  _lxc_require_pct || return 1

  if ! lxc_exists "${ctid}"; then
    printf '%s\n' "lxc: container ${ctid} does not exist." >&2
    return 1
  fi

  status="$(pct status "${ctid}" 2>/dev/null || true)"

  [[ "${status}" == "status: running" ]]
}

lxc_exec() {
  local ctid="${1:-}"

  if [[ -z "${ctid}" ]]; then
    printf '%s\n' "lxc_exec: CTID is required." >&2
    return 2
  fi

  shift

  _lxc_validate_ctid "${ctid}" >/dev/null || return 2
  _lxc_require_pct || return 1

  if ! lxc_exists "${ctid}"; then
    printf '%s\n' "lxc_exec: LXC ${ctid} does not exist." >&2
    return 1
  fi

  if ! lxc_is_running "${ctid}"; then
    printf '%s\n' "lxc_exec: LXC ${ctid} is not running." >&2
    return 1
  fi

  if [[ $# -eq 0 ]]; then
    printf '%s\n' "lxc_exec: no command specified for CTID ${ctid}." >&2
    return 2
  fi

  pct exec "${ctid}" -- "$@"
}

lxc_config_get() {
  local ctid="${1:-}"

  _lxc_validate_ctid "${ctid}" >/dev/null || return 2
  _lxc_require_pct || return 1

  if ! lxc_exists "${ctid}"; then
    printf '%s\n' "lxc_config_get: LXC ${ctid} does not exist." >&2
    return 1
  fi

  pct config "${ctid}"
}

lxc_set_hostname() {
  local ctid="${1:-}"
  local hostname="${2:-}"

  _lxc_validate_ctid "${ctid}" >/dev/null || return 2
  [[ "${hostname}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || {
    log_error "Invalid hostname '${hostname}'."
    return 2
  }

  if dry_run_enabled; then
    dry_run_command "set LXC ${ctid} hostname to ${hostname}"
    return 0
  fi

  _lxc_require_pct || return 1
  pct set "${ctid}" --hostname "${hostname}"
}
