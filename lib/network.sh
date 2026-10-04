#!/usr/bin/env bash

# Network helpers.

_validate_ipv4() {
  local ip="${1:-}"
  local octet
  local octets

  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS='.' read -r -a octets <<< "${ip}"

  for octet in "${octets[@]}"; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

_validate_cidr() {
  local value="${1:-}"
  local ip="${value%/*}"
  local prefix="${value#*/}"

  [[ "${value}" == */* ]] || return 1
  _validate_ipv4 "${ip}" || return 1
  [[ "${prefix}" =~ ^[0-9]+$ ]] || return 1
  (( prefix >= 0 && prefix <= 32 ))
}

_network_ip_in_use() {
  local ip="${1:-}"

  if ip -4 addr show dev "${LXC_BRIDGE:-vmbr0}" |
    grep -qE "[[:space:]]${ip}/"; then
    return 0
  fi

  if ping -c 1 -W 1 "${ip}" >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

_resolve_create_ip() {
  local ctid="${1:-}"
  local requested_ip="${2:-}"

  case "${requested_ip}" in
    dhcp)
      printf '%s\n' "dhcp"
      ;;

    auto)
      # The homelab's addressing rule: a guest's last octet is its CTID, so an
      # address is never something to look up. That only holds while every CTID
      # stays inside the range the router's DHCP pool has been kept out of -
      # outside it, `auto` would either collide with a DHCP lease or roll past
      # the end of the subnet, so refuse rather than generate a bad address.
      local auto_ip="${LXC_LAN_PREFIX:-192.168.0}.${ctid}"

      if (( ctid < ${LXC_CTID_MIN:-100} || ctid > ${LXC_CTID_MAX:-149} )); then
        fatal "CTID ${ctid} is outside ${LXC_CTID_MIN:-100}-${LXC_CTID_MAX:-149}, which --ip auto requires (the last octet is the CTID). Pick a CTID in range, or pass an explicit --ip."
      fi

      _validate_ipv4 "${auto_ip}" ||
        fatal "CTID ${ctid} cannot be used to generate a valid IPv4 address."

      if _network_ip_in_use "${auto_ip}"; then
        fatal "Automatically selected IP ${auto_ip} is already in use."
      fi

      printf '%s\n' "${auto_ip}/${LXC_LAN_CIDR:-24}"
      ;;

    *)
      _validate_cidr "${requested_ip}" ||
        fatal "Invalid IP '${requested_ip}'. Expected dhcp, auto, or IPv4/CIDR."

      printf '%s\n' "${requested_ip}"
      ;;
  esac
}

_validate_network_gateway() {
  local gateway="${1:-}"

  _validate_ipv4 "${gateway}" ||
    fatal "Invalid gateway '${gateway}'."
}

_validate_network_ip_available() {
  local ip="${1:-}"

  if _network_ip_in_use "${ip}"; then
    fatal "IP address ${ip} is already in use."
  fi
}

_validate_bridge() {
  local bridge="${1:-}"

  ip link show "${bridge}" >/dev/null 2>&1 ||
    fatal "Bridge '${bridge}' does not exist."
}

build_lxc_network_config() {
  local bridge="${1:-vmbr0}"
  local ip="${2:-dhcp}"
  local gateway="${3:-}"
  local net="name=eth0,bridge=${bridge},ip=${ip}"

  if [[ -n "${gateway}" && "${ip}" != "dhcp" ]]; then
    net+=",gw=${gateway}"
  fi

  printf '%s\n' "${net}"
}

wait_for_container_network() {
  local ctid="${1:-}"
  local attempts=30

  log_info "Waiting for LXC ${ctid} network..."

  while (( attempts > 0 )); do
    if pct exec "${ctid}" -- ip route get 1.1.1.1 >/dev/null 2>&1 &&
       pct exec "${ctid}" -- getent hosts deb.debian.org >/dev/null 2>&1; then
      log_success "LXC ${ctid} network is ready."
      return 0
    fi

    sleep 1
    ((attempts--))
  done

  log_error "LXC ${ctid} network did not become ready."
  return 1
}
