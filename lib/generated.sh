#!/usr/bin/env bash

# Generated configuration script handling.

GENERATED_DIR="${SCRIPT_DIR}/generated"

generated_script_exists() {
  local script="${1:-}"

  [[ -f "${script}" && -x "${script}" ]]
}

generated_script_version() {
  local script="${1:-}"
  local version

  [[ -f "${script}" ]] || return 1

  version="$(
    sed -n \
      -nE 's/^# Configurator version: ([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' \
      "${script}" |
      head -n 1
  )"

  [[ -n "${version}" ]] || return 1

  printf '%s\n' "${version}"
}

generated_script_recipe_format() {
  local script="${1:-}"
  local format

  [[ -f "${script}" ]] || return 1

  format="$(
    sed -n \
      -nE 's/^# Recipe format: ([0-9]+).*$/\1/p' \
      "${script}" |
      head -n 1
  )"

  [[ -n "${format}" ]] || return 1

  printf '%s\n' "${format}"
}

generated_validate_script() {
  local script="${1:-}"
  local version
  local recipe_format

  [[ -n "${script}" ]] ||
    fatal "Generated script path is required."

  if [[ ! -f "${script}" ]]; then
    fatal "Generated script not found: ${script}"
  fi

  if [[ ! -x "${script}" ]]; then
    fatal "Generated script is not executable: ${script}"
  fi

  if [[ ! "${script}" = "${GENERATED_DIR}"/* ]]; then
    fatal "Generated script must be located inside ${GENERATED_DIR}."
  fi

  if ! head -n 1 "${script}" | grep -Fxq '#!/usr/bin/env bash'; then
    fatal "Invalid generated script: missing Bash shebang."
  fi

  version="$(generated_script_version "${script}")" || {
    fatal "Generated script does not contain a valid configurator version."
  }

  recipe_format="$(generated_script_recipe_format "${script}")" || {
    fatal "Generated script does not contain a valid recipe format."
  }

  printf '%s\n' "${version}"
}

generated_compare_version() {
  local generated_version="${1:-}"
  local current_version="${CONFIGURATOR_VERSION}"

  if [[ "${generated_version}" == "${current_version}" ]]; then
    return 0
  fi

  log_warn \
    "Generated script was created with lxc-configurator ${generated_version}, " \
    "current version is ${current_version}."

  return 1
}

generated_compare_recipe_format() {
  local generated_format="${1:-}"
  local current_format="${RECIPE_FORMAT_VERSION}"

  if [[ "${generated_format}" == "${current_format}" ]]; then
    return 0
  fi

  log_warn \
    "Generated script uses recipe format ${generated_format}, " \
    "current format is ${current_format}."

  return 1
}

generated_validate() {
  local script="${1:-}"
  local version
  local recipe_format

  [[ -n "${script}" ]] ||
    fatal "Usage: ./configurator.sh generated validate <script>"

  if [[ "${script}" != /* ]]; then
    script="${SCRIPT_DIR}/${script}"
  fi

  log_info "Validating generated script: ${script}"

  version="$(generated_validate_script "${script}")"

  if ! bash -n "${script}"; then
    fatal "Generated script contains invalid Bash syntax."
  fi

  log_success "Bash syntax is valid."
  log_success "Configurator version: ${version}"

  recipe_format="$(generated_script_recipe_format "${script}")"

  if [[ "${recipe_format}" != "${RECIPE_FORMAT_VERSION}" ]]; then
    log_error \
      "Unsupported recipe format: ${recipe_format} " \
      "(current: ${RECIPE_FORMAT_VERSION})."
    return 1
  fi

  log_success "Recipe format: ${recipe_format}"
  log_success "Generated script is valid."

  return 0
}

list_generated_scripts() {
  local script

  [[ -d "${GENERATED_DIR}" ]] || return 0

  while IFS= read -r script; do
    basename "${script}"
  done < <(
    find "${GENERATED_DIR}" \
      -maxdepth 1 \
      -type f \
      -name '*.sh' \
      -perm /111 \
      -print |
      sort
  )
}

run_generated_script() {
  local script="${1:-}"
  shift || true

  local generated_version
  local recipe_format

  if [[ -z "${script}" ]]; then
    fatal "Usage: ./configurator.sh execute <script> [options]"
  fi

  if [[ "${script}" != /* ]]; then
    script="${SCRIPT_DIR}/${script}"
  fi

  generated_validate_script "${script}" >/dev/null

  generated_version="$(generated_script_version "${script}")"
  recipe_format="$(generated_script_recipe_format "${script}")"

  if ! generated_compare_version "${generated_version}"; then
    log_warn "Continuing with generated script."
  fi

  if ! generated_compare_recipe_format "${recipe_format}"; then
    fatal "Cannot execute generated script with unsupported recipe format."
  fi

  if ! bash -n "${script}"; then
    fatal "Generated script contains invalid Bash syntax."
  fi

  log_info "Executing generated script: ${script}"

  if [[ $# -gt 0 ]]; then
    log_info "Script arguments: $*"
  fi

  "${script}" "$@"

  log_success "Generated script completed successfully."
}
