#!/usr/bin/env bash

# Configuration profile discovery, validation, and execution.

PROFILE_DIR="${SCRIPT_DIR}/profiles"

list_profiles() {
  local profile_file
  local found=0

  if [[ ! -d "${PROFILE_DIR}" ]]; then
    log_warn "No profiles directory found."
    return 0
  fi

  while IFS= read -r profile_file; do
    found=1
    basename "${profile_file}" .conf
  done < <(
    find "${PROFILE_DIR}" \
      -maxdepth 1 \
      -type f \
      -name '*.conf' |
      sort
  )

  if [[ ${found} -eq 0 ]]; then
    log_warn "No profiles available."
  fi
}

# Splits a profile line into its module name and any trailing options, e.g.
# "scaffold --component .gitignore --component .claude" becomes
# module=scaffold, args=(--component .gitignore --component .claude).
_profile_split_line() {
  local line="${1:-}"
  local module_var="${2:-}"
  local args_var="${3:-}"
  local -n _profile_module_ref="${module_var}"
  local -n _profile_args_ref="${args_var}"
  local rest

  read -r _profile_module_ref rest <<< "${line}"

  _profile_args_ref=()
  if [[ -n "${rest:-}" ]]; then
    read -ra _profile_args_ref <<< "${rest}"
  fi
}

validate_profile() {
  local profile_file="${1:-}"
  local line module
  local -a line_args=()

  [[ -f "${profile_file}" ]] ||
    fatal "Profile not found: ${profile_file}"

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" == \#* ]] && continue

    line="$(trim_whitespace "${line}")"
    [[ -n "${line}" ]] || continue

    _profile_split_line "${line}" module line_args

    if ! validate_module "${module}"; then
      fatal "Unknown module '${module}' in profile ${profile_file}"
    fi
  done < "${profile_file}"
}

run_profile() {
  local ctid="${1:-}"
  local profile_file="${2:-}"
  local dry_run="${3:-false}"
  local module_options_name="${4:-}"
  local line module
  local module_status
  local -a line_args=()
  local -a module_options=()

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    [[ "${line}" == \#* ]] && continue

    line="$(trim_whitespace "${line}")"
    [[ -n "${line}" ]] || continue

    _profile_split_line "${line}" module line_args

    if [[ "${dry_run}" == "true" ]]; then
      log_info "Would run module '${module}'."
      continue
    fi

    log_info "Running module '${module}'..."

    # Options declared on the profile line itself come first so that any
    # CLI-forwarded override (via profile_module_options) still wins.
    module_options=("${line_args[@]}")
    if [[ -n "${module_options_name}" ]]; then
      profile_module_options "${module}" "${module_options_name}" module_options
    fi

    set +e
    run_module "${module}" "${ctid}" "${module_options[@]}"
    module_status=$?
    set -e

    case "${module_status}" in
      0)
        ;;

      10)
        log_info "Module '${module}' changed LXC configuration and requires a restart."

        if pct status "${ctid}" | grep -q "status: running"; then
          log_info "Restarting LXC ${ctid}..."

          if ! pct reboot "${ctid}"; then
            log_error "Failed to restart LXC ${ctid} after module '${module}'."
            return 1
          fi

          if ! wait_for_container_network "${ctid}"; then
            log_error "LXC ${ctid} network is not ready after restart."
            return 1
          fi

          log_success "LXC ${ctid} restarted."
        else
          log_info "LXC ${ctid} is stopped; restart will be handled before provisioning."
        fi
        ;;

      *)
        log_error "Module '${module}' failed with exit code ${module_status}."
        return "${module_status}"
        ;;
    esac
  done < "${profile_file}"

  return 0
}

profile_module_options() {
  local module="${1:-}"
  local options_name="${2:-}"
  local output_name="${3:-}"
  local -n options_ref="${options_name}"
  local -n output_ref="${output_name}"
  local option

  case "${module}" in
    user)
      for option in user shell groups; do
        if [[ -v "options_ref[${option}]" ]]; then
          output_ref+=("--${option}" "${options_ref[${option}]}" )
        fi
      done
      ;;

    locale)
      for option in locale timezone; do
        if [[ -v "options_ref[${option}]" ]]; then
          output_ref+=("--${option}" "${options_ref[${option}]}" )
        fi
      done
      ;;

    work-dir)
      for option in path user; do
        if [[ -v "options_ref[${option}]" ]]; then
          output_ref+=("--${option}" "${options_ref[${option}]}" )
        fi
      done
      ;;
  esac
}
