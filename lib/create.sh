#!/usr/bin/env bash

# LXC creation helpers.

_create_validate_positive_integer() {
  local name="${1:-}"
  local value="${2:-}"

  [[ "${value}" =~ ^[0-9]+$ ]] ||
    fatal "${name} must be a positive integer."

  (( value > 0 )) ||
    fatal "${name} must be greater than 0."
}

_create_validate_storage() {
  local storage="${1:-}"

  pvesm status --storage "${storage}" >/dev/null 2>&1 ||
    fatal "Storage '${storage}' does not exist or is unavailable."
}

_create_validate_template() {
  local template="${1:-}"

  pvesm list "${template%%:*}" 2>/dev/null |
    awk '{print $1}' |
    grep -Fxq "${template}" ||
    fatal "Template '${template}' is not available."
}

create_lxc() {
  local ctid="${1:-}"
  shift || true

  if [[ -z "${ctid}" ]]; then
    fatal "Usage: ./configurator.sh create <ctid> [profile] [options]"
  fi

  if [[ ! "${ctid}" =~ ^[0-9]+$ ]]; then
    fatal "Invalid CTID '${ctid}'. Expected a numeric container ID."
  fi

  if lxc_exists "${ctid}"; then
    fatal "LXC ${ctid} already exists."
  fi

  local profile="${CREATE_PROFILE:-default}"
  local template="${LXC_TEMPLATE:-local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst}"
  local storage="${LXC_STORAGE:-lxc-storage}"
  local bridge="${LXC_BRIDGE:-vmbr0}"
  local hostname=""
  local requested_ip="${LXC_IP:-auto}"
  local gateway="${LXC_GATEWAY:-}"
  local cores="${LXC_CORES:-2}"
  local memory="${LXC_MEMORY:-2048}"
  local swap="${LXC_SWAP:-512}"
  local disk="${LXC_DISK:-8}"
  local start="${LXC_START:-1}"
  local unprivileged="${LXC_UNPRIVILEGED:-1}"
  local nesting="${LXC_NESTING:-1}"
  local dry_run=false

  if [[ $# -gt 0 && "${1}" != --* ]]; then
    profile="$1"
    shift
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --template)
        [[ $# -ge 2 ]] || fatal "--template requires a value."
        template="$2"
        shift 2
        ;;

      --storage)
        [[ $# -ge 2 ]] || fatal "--storage requires a value."
        storage="$2"
        shift 2
        ;;

      --hostname)
        [[ $# -ge 2 ]] || fatal "--hostname requires a value."
        hostname="$2"
        shift 2
        ;;

      --ip)
        [[ $# -ge 2 ]] || fatal "--ip requires a value."
        requested_ip="$2"
        shift 2
        ;;

      --gw|--gateway)
        [[ $# -ge 2 ]] || fatal "--gateway requires a value."
        gateway="$2"
        shift 2
        ;;

      --bridge)
        [[ $# -ge 2 ]] || fatal "--bridge requires a value."
        bridge="$2"
        shift 2
        ;;

      --cores)
        [[ $# -ge 2 ]] || fatal "--cores requires a value."
        cores="$2"
        shift 2
        ;;

      --memory)
        [[ $# -ge 2 ]] || fatal "--memory requires a value."
        memory="$2"
        shift 2
        ;;

      --swap)
        [[ $# -ge 2 ]] || fatal "--swap requires a value."
        swap="$2"
        shift 2
        ;;

      --disk)
        [[ $# -ge 2 ]] || fatal "--disk requires a value."
        disk="$2"
        shift 2
        ;;

      --start)
        start=1
        shift
        ;;

      --no-start)
        start=0
        shift
        ;;

      --dry-run)
        dry_run=true
        shift
        ;;

      *)
        fatal "Unknown create option: $1"
        ;;
    esac
  done

  [[ -n "${template}" ]] ||
    fatal "No LXC template specified."

  [[ -n "${storage}" ]] ||
    fatal "No LXC storage specified."

  [[ -n "${hostname}" ]] || hostname="lxc-${ctid}"

  _create_validate_positive_integer "CPU cores" "${cores}"
  _create_validate_positive_integer "Memory" "${memory}"
  _create_validate_positive_integer "Swap" "${swap}"
  _create_validate_positive_integer "Disk" "${disk}"

  local ip
  ip="$(_resolve_create_ip "${ctid}" "${requested_ip}")"

  if [[ "${ip}" != "dhcp" ]]; then
    local ip_address="${ip%/*}"

    if [[ -z "${gateway}" ]]; then
      gateway="${LXC_GATEWAY:-192.168.0.1}"
    fi

    _validate_network_gateway "${gateway}"

    if [[ "${dry_run}" != "true" ]]; then
      _validate_network_ip_available "${ip_address}"
    fi
  fi

  local net
  net="$(build_lxc_network_config "${bridge}" "${ip}" "${gateway}")"

  if [[ "${dry_run}" != "true" ]]; then
    _create_validate_storage "${storage}"
    _create_validate_template "${template}"
    _validate_bridge "${bridge}"
  fi

  log_info "LXC ${ctid} creation parameters:"
  log_info "  Template: ${template}"
  log_info "  Storage:  ${storage}"
  log_info "  Hostname: ${hostname}"
  log_info "  Network:  ${net}"
  log_info "  CPU:      ${cores}"
  log_info "  Memory:   ${memory} MB"
  log_info "  Disk:     ${disk} GB"
  log_info "  Swap:     ${swap} MB"
  log_info "  Start:    ${start}"
  log_info "  Profile:  ${profile}"
  log_info "  Unprivileged: ${unprivileged}"
  log_info "  Nesting:      ${nesting}"

  local profile_file="${PROFILE_DIR}/${profile}.conf"

  if [[ ! -f "${profile_file}" ]]; then
    fatal "Profile '${profile}' does not exist."
  fi

  validate_profile "${profile_file}"

  if [[ "${dry_run}" == "true" ]]; then
    log_success "Dry run completed."
    return 0
  fi

  if ! pct create "${ctid}" "${template}" \
    --storage "${storage}" \
    --rootfs "${storage}:${disk}" \
    --hostname "${hostname}" \
    --cores "${cores}" \
    --memory "${memory}" \
    --swap "${swap}" \
    --net0 "${net}" \
    --unprivileged "${unprivileged}" \
    --features "nesting=${nesting}" \
    --onboot 1 \
    --start "${start}"; then
    log_error "Failed to create LXC ${ctid}."
    return 1
  fi

  log_success "LXC ${ctid} created."

  local was_started=false

  if [[ "${start}" == "1" ]]; then
    was_started=true
  else
    log_info "Temporarily starting LXC ${ctid} for provisioning..."

    if ! pct start "${ctid}"; then
      log_error "Failed to start LXC ${ctid} for provisioning."
      return 1
    fi
  fi

  if ! wait_for_container_network "${ctid}"; then
    log_error "LXC ${ctid} network is not ready."

    if [[ "${was_started}" == "false" ]]; then
      pct stop "${ctid}" >/dev/null 2>&1 || true
    fi

    return 1
  fi

  if ! run_configure "${ctid}" "${profile}"; then
    log_error "LXC ${ctid} configuration failed."

    if [[ "${was_started}" == "false" ]]; then
      log_info "Stopping LXC ${ctid} after failed provisioning..."
      pct stop "${ctid}" >/dev/null 2>&1 || true
    fi

    return 1
  fi

  local created_hostname
  created_hostname="$(migration_read_hostname "${ctid}")"
  log_action_record "create" "${ctid}" "${created_hostname}" "${profile}"

  local summary
  summary="$(lxc_print_summary "${ctid}" "${profile}" "${created_hostname}" "${USER_NAME:-}" "${WORK_DIR:-/app}")"

  if [[ "${was_started}" == "false" ]]; then
    log_info "Stopping LXC ${ctid} as requested by --no-start..."

    if ! pct shutdown "${ctid}" --timeout 30; then
      log_error "Graceful shutdown failed, forcing LXC ${ctid} to stop."
      pct stop "${ctid}" || {
        log_error "Failed to stop LXC ${ctid}."
        return 1
      }
    fi
  fi

  log_success "LXC ${ctid} created and configured."
  printf '%s\n' "${summary}"
}
