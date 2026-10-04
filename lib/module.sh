#!/usr/bin/env bash

# Module discovery, validation, and execution.

MODULE_DIR="${SCRIPT_DIR}/modules"

list_modules() {
  local module_file

  find "${MODULE_DIR}" \
    -type f \
    -name '*.sh' \
    -print |
    while IFS= read -r module_file; do
      basename "${module_file}" .sh
    done |
    sort
}

load_module_metadata() {
  local module="${1:-}"
  local module_file
  local function

  module_file="$(find_module "${module}")" || return 1
  function="$(module_function_name "${module}")"

  unset MODULE_NAME MODULE_DESCRIPTION MODULE_SUPPORTS_DRY_RUN MODULE_REQUIRES_ROOT MODULE_DEPENDS

  # shellcheck disable=SC1090
  source "${module_file}"

  [[ "${MODULE_NAME:-}" == "${module}" ]] || {
    log_error "Module '${module}' has invalid or mismatched MODULE_NAME."
    return 1
  }
  [[ "${MODULE_NAME}" =~ ^[a-z][a-z0-9-]*$ ]] || {
    log_error "Module '${module}' has an unsafe MODULE_NAME."
    return 1
  }
  [[ -n "${MODULE_DESCRIPTION:-}" && "${MODULE_DESCRIPTION}" != *$'\n'* ]] || {
    log_error "Module '${module}' requires a single-line MODULE_DESCRIPTION."
    return 1
  }
  [[ "${MODULE_SUPPORTS_DRY_RUN:-}" == true || "${MODULE_SUPPORTS_DRY_RUN:-}" == false ]] || {
    log_error "Module '${module}' requires MODULE_SUPPORTS_DRY_RUN=true or false."
    return 1
  }
  [[ "${MODULE_REQUIRES_ROOT:-}" == true || "${MODULE_REQUIRES_ROOT:-}" == false ]] || {
    log_error "Module '${module}' requires MODULE_REQUIRES_ROOT=true or false."
    return 1
  }
  declare -F "${function}" >/dev/null 2>&1 || {
    log_error "Module '${module}' does not define ${function}()."
    return 1
  }
}

list_module_metadata() {
  local module

  while IFS= read -r module; do
    load_module_metadata "${module}" || fatal "Invalid metadata for module '${module}'."
    printf '%-22s %s\n' "${MODULE_NAME}" "${MODULE_DESCRIPTION}"
  done < <(list_modules)
}

find_module() {
  local module="${1:-}"
  local module_file

  [[ -n "${module}" ]] || return 1

  while IFS= read -r module_file; do
    if [[ "$(basename "${module_file}" .sh)" == "${module}" ]]; then
      printf '%s\n' "${module_file}"
      return 0
    fi
  done < <(
    find "${MODULE_DIR}" \
      -type f \
      -name '*.sh' \
      -print |
      sort
  )

  return 1
}

module_function_name() {
  local module="${1:-}"

  printf 'configure_%s\n' "${module//-/_}"
}

validate_module() {
  local module="${1:-}"

  load_module_metadata "${module}"
}

run_module() {
  local module="${1:-}"
  local ctid="${2:-}"

  if [[ -z "${module}" || -z "${ctid}" ]]; then
    fatal "Usage: ./configurator.sh module <name> <ctid> [options]"
  fi

  shift 2

  local previous_dry_run="${DRY_RUN:-false}"
  local module_options=()
  declare -A common_options=()
  option_extract_common common_options module_options "$@"
  local module_dry_run=false
  if [[ -v "common_options[dry-run]" ]]; then
    DRY_RUN=true
    module_dry_run=true
  fi

  local function

  find_module "${module}" >/dev/null || {
    fatal "Unknown module: ${module}"
  }

  function="$(module_function_name "${module}")"

  load_module_metadata "${module}" || fatal "Invalid metadata for module '${module}'."

  if [[ "${ctid}" == "--help" || "${ctid}" == "-h" ]]; then
    if declare -F "${function}_help" >/dev/null 2>&1; then
      "${function}_help"
    else
      fatal "Module '${module}' does not provide help."
    fi
    return 0
  fi

  if ! lxc_exists "${ctid}"; then
    fatal "LXC ${ctid} does not exist."
  fi

  local module_status=0
  "${function}" "${ctid}" "${module_options[@]}" || module_status=$?
  DRY_RUN="${previous_dry_run}"

  if [[ "${module_dry_run}" == "true" || "${previous_dry_run}" == "true" ]] &&
     [[ ${module_status} -eq 10 ]]; then
    return 0
  fi

  return "${module_status}"
}
