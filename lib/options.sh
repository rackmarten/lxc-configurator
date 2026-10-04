#!/usr/bin/env bash

# Shared parsing and configuration resolution for module options.

option_extract_common() {
    local common_name="${1:-}"
    local remaining_name="${2:-}"
    shift 2 || true
    local argument

    [[ -n "${common_name}" && -n "${remaining_name}" ]] ||
        fatal "option_extract_common requires output array names."
    local -n common_ref="${common_name}"
    local -n remaining_ref="${remaining_name}"

    common_ref=()
    remaining_ref=()
    for argument in "$@"; do
        if [[ "${argument}" == "--dry-run" ]]; then
            # shellcheck disable=SC2034,SC2154  # common_ref is an associative-array nameref from the caller; "dry-run" is a literal key, not arithmetic.
            common_ref["dry-run"]=true
        else
            remaining_ref+=("${argument}")
        fi
    done
}

option_parse() {
    local options_name="${1:-}"
    local allowed="${2:-}"
    shift 2 || true
    local argument option value

    [[ -n "${options_name}" ]] || fatal "option_parse requires an options array name."
    local -n options_ref="${options_name}"

    while (($# > 0)); do
        argument="$1"
        shift
        [[ "${argument}" == --* ]] || fatal "Unexpected module argument: ${argument}"
        option="${argument#--}"
        [[ -n "${option}" ]] || fatal "Invalid empty module option."
        if [[ "${option}" == *=* ]]; then
            value="${option#*=}"
            option="${option%%=*}"
        else
            (($# > 0)) || fatal "Missing value for --${option}."
            value="$1"
            shift
            [[ "${value}" != --* ]] || fatal "Missing value for --${option}."
        fi
        [[ ",${allowed}," == *",${option},"* ]] || fatal "Unknown module option: --${option}"
        [[ -n "${value}" ]] || fatal "Empty value for --${option}."
        options_ref["${option}"]="${value}"
    done
}

option_has() {
    local options_name="${1:-}"
    local option="${2:-}"
    # shellcheck disable=SC2178  # This nameref targets an associative array; shellcheck can't see that across the option_parse() reuse of the same local name.
    local -n options_ref="${options_name}"
    [[ -v "options_ref[${option}]" ]]
}

option_get() {
    local options_name="${1:-}"
    local option="${2:-}"
    local environment_name="${3:-}"
    local default_value="${4:-}"
    local -n options_ref="${options_name}"

    if option_has "${options_name}" "${option}"; then
        printf '%s' "${options_ref[${option}]}"
    elif [[ -n "${environment_name}" && -v "${environment_name}" ]]; then
        printf '%s' "${!environment_name}"
    else
        printf '%s' "${default_value}"
    fi
}

option_require() {
    local value
    value="$(option_get "$@")"
    [[ -n "${value}" ]] || fatal "Required configuration value is missing."
    printf '%s' "${value}"
}

option_list() {
    local options_name="${1:-}"
    local option="${2:-}"
    local environment_name="${3:-}"
    local default_value="${4:-}"
    local output_name="${5:-}"
    local value item
    local -n output_ref="${output_name}"

    value="$(option_get "${options_name}" "${option}" "${environment_name}" "${default_value}")"
    output_ref=()
    IFS=',' read -r -a output_ref <<< "${value}"
    for index in "${!output_ref[@]}"; do
        item="$(trim_whitespace "${output_ref[${index}]}")"
        output_ref["${index}"]="${item}"
        [[ -n "${item}" ]] || fatal "Invalid empty item in --${option}."
        [[ "${item}" =~ ^[A-Za-z_][A-Za-z0-9_.-]*$ ]] || fatal "Invalid value '${item}' in --${option}."
    done
}
