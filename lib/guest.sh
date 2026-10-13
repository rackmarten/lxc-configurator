#!/usr/bin/env bash

# Helpers for executing commands and managing packages/files inside LXC guests.

guest_exec() {
  local ctid="${1:-}"

  if [[ -z "${ctid}" ]]; then
    printf '%s\n' "guest_exec: CTID is required." >&2
    return 2
  fi

  shift

  if [[ $# -eq 0 ]]; then
    printf '%s\n' "guest_exec: no command specified." >&2
    return 2
  fi

  if dry_run_enabled; then
    local command_line
    printf -v command_line '%q ' "$@"
    log_info "[DRY-RUN] Would execute in LXC ${ctid}: ${command_line% }"
    return 0
  fi

  lxc_exec "${ctid}" "$@"
}

guest_exec_user() {
  local ctid="${1:-}"
  local user="${2:-}"

  if [[ -z "${ctid}" ]]; then
    printf '%s\n' "guest_exec_user: CTID is required." >&2
    return 2
  fi

  if [[ -z "${user}" ]]; then
    printf '%s\n' "guest_exec_user: user is required." >&2
    return 2
  fi

  shift 2

  if [[ $# -eq 0 ]]; then
    printf '%s\n' "guest_exec_user: no command specified." >&2
    return 2
  fi

  guest_exec "${ctid}" runuser -u "${user}" -- "$@"
}

guest_command_exists() {
  local ctid="${1:-}"
  local command="${2:-}"

  if [[ -z "${command}" ]]; then
    printf '%s\n' "guest_command_exists: command is required." >&2
    return 2
  fi

  # shellcheck disable=SC2016  # '$1' is expanded by the guest's sh, not this shell.
  guest_exec "${ctid}" sh -c 'command -v "$1" >/dev/null 2>&1' \
    sh "${command}"
}

guest_user_home() {
  local ctid="${1:-}"
  local user="${2:-}"
  local home

  if [[ -z "${user}" ]]; then
    printf '%s\n' "guest_user_home: user is required." >&2
    return 2
  fi

  home="$(guest_exec "${ctid}" getent passwd "${user}" | cut -d: -f6)"

  # guest_exec never actually runs anything under dry-run, so getent always
  # comes back empty - fall back to the conventional path so callers can
  # still preview what they'd do instead of failing on an empty value.
  if [[ -z "${home}" ]] && dry_run_enabled; then
    home="/home/${user}"
  fi

  printf '%s\n' "${home}"
}

guest_file_exists() {
  local ctid="${1:-}"
  local file="${2:-}"

  if [[ -z "${file}" ]]; then
    printf '%s\n' "guest_file_exists: file path is required." >&2
    return 2
  fi

  guest_exec "${ctid}" test -e "${file}"
}

guest_package_installed() {
  local ctid="${1:-}"
  local package="${2:-}"

  if [[ -z "${package}" ]]; then
    printf '%s\n' "guest_package_installed: package name is required." >&2
    return 2
  fi

  # shellcheck disable=SC2016  # '${Status}' is dpkg-query's own format placeholder, not shell expansion.
  guest_exec "${ctid}" dpkg-query \
    -W \
    -f='${Status}' \
    "${package}" 2>/dev/null |
    grep -q '^install ok installed$'
}

guest_install_packages() {
  local ctid="${1:-}"
  shift

  if [[ $# -eq 0 ]]; then
    printf '%s\n' "guest_install_packages: at least one package is required." >&2
    return 2
  fi

  local missing=()
  local package

  for package in "$@"; do
    if ! guest_package_installed "${ctid}" "${package}"; then
      missing+=("${package}")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    log_info "All requested packages are already installed."
    return 0
  fi

  log_info "Installing packages in LXC ${ctid}: ${missing[*]}"

  if ! guest_exec "${ctid}" apt-get update -qq >/dev/null 2>&1; then
    log_error "Failed to update package lists in LXC ${ctid}."
    return 1
  fi

  if ! guest_exec "${ctid}" env DEBIAN_FRONTEND=noninteractive \
    apt-get install -y -qq \
    "${missing[@]}" >/dev/null 2>&1; then
    log_error "Failed to install packages in LXC ${ctid}: ${missing[*]}"
    return 1
  fi

  log_success "Installed ${#missing[@]} package(s) in LXC ${ctid}."
}

guest_file_read() {
  local ctid="${1:-}"
  local file="${2:-}"

  if [[ -z "${file}" ]]; then
    printf '%s\n' "guest_file_read: file path is required." >&2
    return 2
  fi

  guest_exec "${ctid}" cat -- "${file}"
}

guest_file_write() {
  local ctid="${1:-}"
  local file="${2:-}"
  local content="${3:-}"

  if [[ -z "${file}" ]]; then
    printf '%s\n' "guest_file_write: file path is required." >&2
    return 2
  fi

  # shellcheck disable=SC2016  # '$1' is expanded by the guest's sh, not this shell.
  guest_exec "${ctid}" sh -c 'cat > "$1"' sh "${file}" <<< "${content}"
}

# Docker copies the guest's /etc/resolv.conf into its containers when they
# start. On boot docker.service can win the race against tailscaled, so the
# containers keep the pre-tailscale upstreams and cannot resolve MagicDNS
# names until restarted. This drop-in makes Docker wait (bounded) for
# tailscale's resolver; it starts Docker either way, so a tailscale outage
# never keeps the containers down. Only installed when both are present;
# called from the docker and tailscale modules so the order they run in
# does not matter.
GUEST_DOCKER_TAILSCALE_DNS_DROPIN="/etc/systemd/system/docker.service.d/10-wait-tailscale-dns.conf"
GUEST_DOCKER_TAILSCALE_DNS_TIMEOUT=90

guest_docker_tailscale_dns_dropin_content() {
  local timeout="${GUEST_DOCKER_TAILSCALE_DNS_TIMEOUT}"

  # `$$` is systemd's escape for a literal `$` passed through to sh.
  cat <<UNIT
# Managed by lxc-configurator: start Docker only once tailscale has taken
# over DNS (or after ${timeout}s), so containers copy tailscale's resolver.
[Unit]
After=tailscaled.service
Wants=tailscaled.service

[Service]
ExecStartPre=/bin/sh -c 'i=0; while [ "\$\$i" -lt ${timeout} ]; do if grep -qF "nameserver 100.100.100.100" /etc/resolv.conf; then echo "Tailscale DNS active after \$\${i}s, starting Docker."; exit 0; fi; i=\$\$((i + 1)); sleep 1; done; echo "Tailscale DNS not active after ${timeout}s, starting Docker anyway."; exit 0'
UNIT
}

guest_docker_wait_for_tailscale_dns() {
  local ctid="${1:-}"
  local dropin="${GUEST_DOCKER_TAILSCALE_DNS_DROPIN}"
  local content current

  if [[ -z "${ctid}" ]]; then
    printf '%s\n' "guest_docker_wait_for_tailscale_dns: CTID is required." >&2
    return 2
  fi

  if ! guest_command_exists "${ctid}" docker || ! guest_command_exists "${ctid}" tailscale; then
    return 0
  fi

  content="$(guest_docker_tailscale_dns_dropin_content)"
  current="$(guest_file_read "${ctid}" "${dropin}" 2>/dev/null)" || current=""

  if [[ "${current}" == "${content}" ]]; then
    log_info "Docker already waits for Tailscale DNS on boot."
    return 0
  fi

  log_info "Making Docker wait for Tailscale DNS on boot..."

  if ! guest_exec "${ctid}" mkdir -p "${dropin%/*}" ||
    ! guest_file_write "${ctid}" "${dropin}" "${content}" ||
    ! guest_exec "${ctid}" systemctl daemon-reload; then
    log_error "Failed to install ${dropin} in LXC ${ctid}."
    return 1
  fi

  # No restart: running containers keep working, the drop-in matters on the
  # next boot.
  log_success "Docker waits for Tailscale DNS on boot (takes effect on next restart)."
}
