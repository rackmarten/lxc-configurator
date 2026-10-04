#!/usr/bin/env bash

# LXC configuration orchestration.

run_configure() {
  local ctid="${1:-}"
  local profile="${2:-default}"
  local dry_run="${3:-}"
  local profile_file="${PROFILE_DIR}/${profile}.conf"

  if [[ -z "${ctid}" ]]; then
    fatal "Usage: ./configurator.sh configure <ctid> [profile] [--dry-run]"
  fi

  if [[ -n "${dry_run}" && "${dry_run}" != "--dry-run" ]]; then
    fatal "Unknown configure option: ${dry_run}"
  fi

  if [[ "${dry_run}" != "--dry-run" ]] && ! lxc_exists "${ctid}"; then
    fatal "LXC ${ctid} does not exist."
  fi

  if [[ ! -f "${profile_file}" ]]; then
    log_error "Profile '${profile}' does not exist."
    log_info "Available profiles:"
    list_profiles
    return 1
  fi

  validate_profile "${profile_file}"

  if [[ "${dry_run}" == "--dry-run" ]]; then
    log_info "Dry run: LXC ${ctid} using profile '${profile}'..."

    local previous_dry_run="${DRY_RUN:-false}"
    DRY_RUN=true

    if ! run_profile "${ctid}" "${profile_file}" false; then
      DRY_RUN="${previous_dry_run}"
      log_error "Dry run failed for profile '${profile}'."
      return 1
    fi

    DRY_RUN="${previous_dry_run}"
    log_success "Dry run completed."
    return 0
  fi

  log_info "Configuring LXC ${ctid} using profile '${profile}'..."

  if ! run_profile "${ctid}" "${profile_file}"; then
    log_error "Configuration failed for LXC ${ctid} using profile '${profile}'."
    return 1
  fi

  log_action_record "configure" "${ctid}" "$(migration_read_hostname "${ctid}")" "${profile}"
  log_success "LXC ${ctid} configured using profile '${profile}'."
}
