#!/usr/bin/env bash

# Template rendering helpers.
#
# Configurator templates may reference explicitly supplied variables:
#
#   ${hostname}
#   ${ctid}
#   ${WORK_DIR_PROJECT_NAME}
#
# Shell/Docker expressions containing ':' are intentionally left untouched:
#
#   ${PORT:-8080}
#   ${1:-default}

template_render() {
  local template="${1:-}"
  shift || true

  if [[ -z "${template}" ]]; then
    printf '%s\n' "template_render: template content is required." >&2
    return 2
  fi

  if (( $# % 2 != 0 )); then
    printf '%s\n' \
      "template_render: variables must be supplied as name/value pairs." >&2
    return 2
  fi

  local result="${template}"
  local variable
  local value

  while [[ $# -gt 0 ]]; do
    variable="$1"
    value="$2"

    shift 2

    [[ "${variable}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] ||
      printf '%s\n' \
        "template_render: invalid variable name '${variable}'." >&2

    result="${result//\$\{${variable}\}/${value}}"
  done

  printf '%s' "${result}"
}

template_render_file() {
  local file="${1:-}"
  shift || true

  if [[ -z "${file}" ]]; then
    printf '%s\n' "template_render_file: template file is required." >&2
    return 2
  fi

  if [[ ! -f "${file}" ]]; then
    printf '%s\n' \
      "template_render_file: template not found: ${file}" >&2
    return 1
  fi

  template_render "$(<"${file}")" "$@"
}
