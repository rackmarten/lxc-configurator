#!/usr/bin/env bash

# Existing-LXC migration orchestration and post-migration reporting.

migration_profile_modules() {
  local profile_file="${1:-}"
  local line module
  # shellcheck disable=SC2034  # line_args is an output parameter for _profile_split_line; this call site only needs the module name.
  local -a line_args=()

  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" || "${line}" == \#* ]] && continue

    line="$(trim_whitespace "${line}")"
    [[ -n "${line}" ]] || continue

    _profile_split_line "${line}" module line_args
    printf '%s\n' "${module}"
  done < "${profile_file}"
}

migration_print_plan() {
  local ctid="${1:-}"
  local current_hostname="${2:-unavailable}"
  local hostname_action="${3:-preserved}"
  local profile="${4:-default}"
  local profile_file="${PROFILE_DIR}/${profile}.conf"
  local module

  printf '%s\n' 'Migration Plan' '---------------'
  printf 'LXC:       %s\n' "${ctid}"
  printf 'Current:   %s\n' "${current_hostname}"
  printf 'Hostname:  %s\n' "${hostname_action}"
  printf 'Profile:   %s\n' "${profile}"
  printf '%s\n' '' 'Modules:'
  while IFS= read -r module; do
    printf '  %s\n' "${module}"
  done < <(migration_profile_modules "${profile_file}")
  printf '%s\n' '' 'Existing files and Git repositories will be preserved.'
}

_migration_is_virtual_ip() {
  local ip="${1:-}"
  local octet1 octet2

  IFS='.' read -r octet1 octet2 _ _ <<< "${ip}"
  [[ "${octet1}" =~ ^[0-9]+$ && "${octet2}" =~ ^[0-9]+$ ]] || return 1

  # Docker's default bridge network.
  [[ "${octet1}" == 172 && "${octet2}" == 17 ]] && return 0

  # Tailscale's CGNAT range (100.64.0.0/10).
  [[ "${octet1}" == 100 && "${octet2}" -ge 64 && "${octet2}" -le 127 ]] && return 0

  return 1
}

migration_read_hostname() {
  local ctid="${1:-}"
  local hostname

  if dry_run_enabled; then
    printf '%s' 'unavailable'
    return 0
  fi

  if hostname="$(guest_exec "${ctid}" hostname 2>&1)"; then
    printf '%s' "${hostname}"
  else
    log_warn "Could not read hostname from LXC ${ctid}: ${hostname}"
    printf '%s' 'unavailable'
  fi
}

migration_read_ip() {
  local ctid="${1:-}"
  local raw
  local candidate
  local ip=""
  local fallback=""

  if dry_run_enabled; then
    printf '%s' 'unavailable'
    return 0
  fi

  if ! raw="$(guest_exec "${ctid}" hostname -I 2>&1)"; then
    log_warn "Could not read IP address from LXC ${ctid}: ${raw}"
    printf '%s' 'unavailable'
    return 0
  fi

  for candidate in ${raw}; do
    [[ -n "${fallback}" ]] || fallback="${candidate}"
    if ! _migration_is_virtual_ip "${candidate}"; then
      ip="${candidate}"
      break
    fi
  done
  [[ -n "${ip}" ]] || ip="${fallback}"

  [[ -n "${ip}" ]] && printf '%s' "${ip}" || printf '%s' 'unavailable'
}

migration_print_public_key() {
  local ctid="${1:-}"
  local user_name="${2:-}"
  local passwd_entry
  local home=""
  local public_key=""
  local candidate
  local key_file

  [[ -n "${user_name}" ]] || return 1

  if dry_run_enabled; then
    printf '%s\n' '' 'GitHub SSH public key: unavailable in dry run.'
    return 1
  fi

  if passwd_entry="$(guest_exec "${ctid}" getent passwd "${user_name}" 2>&1)"; then
    home="$(cut -d: -f6 <<< "${passwd_entry}")"
  else
    log_warn "Could not resolve user '${user_name}' in LXC ${ctid}: ${passwd_entry}"
  fi

  if [[ -n "${home}" ]]; then
    for candidate in id_ed25519.pub id_rsa.pub; do
      key_file="${home}/.ssh/${candidate}"
      if guest_file_exists "${ctid}" "${key_file}" 2>/dev/null; then
        public_key="$(guest_file_read "${ctid}" "${key_file}" 2>/dev/null || true)"
        [[ -n "${public_key}" ]] && break
      fi
    done
  fi

  if [[ -n "${public_key}" ]]; then
    printf '%s\n' '' 'GitHub SSH public key' '---------------------' '' "${public_key}"
    return 0
  fi

  printf '%s\n' '' 'No SSH public key was found.'
  return 1
}

# Prints the connection/Git/verification/next-steps summary for an LXC:
# SSH command, VS Code Remote SSH project-manager entry, and the personal
# GitHub SSH public key. Pure read-only reporting - callers that already
# made changes (migrate) print their own status line first; callers that
# only want a read-only report (create, info) can call this directly.
lxc_print_summary() {
  local ctid="${1:-}"
  local profile="${2:-default}"
  local hostname="${3:-unavailable}"
  local resolved_user_name="${4:-}"
  local resolved_work_dir="${5:-}"
  local profile_file="${PROFILE_DIR}/${profile}.conf"
  local ip
  local module
  local has_user=false
  local has_work_dir=false
  local user_name=""
  local work_dir=""
  local key_found=false

  while IFS= read -r module; do
    case "${module}" in
      user) has_user=true; user_name="${resolved_user_name}" ;;
      work-dir) has_work_dir=true; work_dir="${resolved_work_dir}" ;;
    esac
  done < <(migration_profile_modules "${profile_file}")

  ip="$(migration_read_ip "${ctid}")"
  printf '%s\n' '' 'Connection' '----------'
  printf 'Hostname: %s\n' "${hostname}"
  printf 'IP:       %s\n' "${ip}"
  if [[ -n "${user_name}" && "${hostname}" != unavailable ]]; then
    printf '%s\n' 'SSH:' "  ssh ${user_name}@${hostname}"
  fi
  if [[ -n "${user_name}" && "${ip}" != unavailable ]]; then
    printf '%s\n' "  ssh ${user_name}@${ip}"
  fi

  if [[ "${has_work_dir}" == true && -n "${user_name}" && -n "${work_dir}" && "${ip}" != unavailable ]]; then
    printf '%s\n' '' 'VS Code Remote SSH' '------------------' 'Remote project manager entry:'
    printf '  {"name":"homelab - %s","rootPath":"vscode-remote://ssh-remote+%s@%s%s","paths":[],"tags":["homelab"],"enabled":true,"profile":""}\n' \
      "${hostname}" "${user_name}" "${ip}" "${work_dir}"
    printf '%s\n' '' 'Project' '-------' "Path:   ${work_dir}" "Review: ${work_dir}/README.md"
  fi

  if [[ "${has_user}" == true && ( -n "${GIT_USER_NAME:-}" || -n "${GIT_USER_EMAIL:-}" ) ]]; then
    printf '%s\n' '' 'Git' '---' "User:   ${GIT_USER_NAME:-unavailable}" "Email:  ${GIT_USER_EMAIL:-unavailable}" "Branch: ${GIT_DEFAULT_BRANCH:-unavailable}"
  fi

  while IFS= read -r module; do
    case "${module}" in
      docker) printf '%s\n' '' 'Docker' '------' 'Verify:' '  docker version' '  docker ps' ;;
      tailscale) printf '%s\n' '' 'Tailscale' '---------' 'Verify:' '  tailscale status' ;;
    esac
  done < <(migration_profile_modules "${profile_file}")

  if migration_print_public_key "${ctid}" "${user_name}"; then
    key_found=true
  fi
  printf '%s\n' '' 'Next steps' '----------'
  local step=1
  if [[ "${key_found}" == true ]]; then
    printf '[%d] Add the SSH public key to GitHub.\n' "${step}"; step=$((step + 1))
  fi
  if [[ "${hostname}" != unavailable && -n "${user_name}" ]]; then
    printf '[%d] Connect using: ssh %s@%s\n' "${step}" "${user_name}" "${hostname}"; step=$((step + 1))
  fi
  [[ -n "${work_dir}" ]] && printf '[%d] Review %s and restore application data as required.\n' "${step}" "${work_dir}"
}

migration_print_report() {
  local ctid="${1:-}"
  local profile="${2:-default}"
  local hostname="${3:-unavailable}"
  local resolved_user_name="${4:-}"
  local resolved_work_dir="${5:-}"

  if dry_run_enabled; then
    printf '%s\n' '' "[INFO] Dry run preview for LXC ${ctid}."
  else
    printf '%s\n' '' "[OK] LXC ${ctid} migrated successfully."
  fi

  lxc_print_summary "${ctid}" "${profile}" "${hostname}" "${resolved_user_name}" "${resolved_work_dir}"
}

run_migrate() {
  local ctid="${1:-}"
  shift || true
  local profile="default"
  local dry_run=false
  local hostname_requested=false
  local current_hostname
  local target_hostname
  declare -A options=()
  declare -A common_options=()
  local remaining=()

  [[ -n "${ctid}" ]] || fatal "Usage: ./configurator.sh migrate <ctid> [profile] [options]"
  [[ "${ctid}" =~ ^[0-9]+$ ]] || fatal "Invalid CTID '${ctid}'. Expected a numeric container ID."

  if [[ $# -gt 0 && "${1}" != --* ]]; then
    profile="$1"
    shift
  fi

  option_extract_common common_options remaining "$@"
  [[ -v "common_options[dry-run]" ]] && dry_run=true
  # shellcheck disable=SC2034  # DRY_RUN is a global read by dry_run_enabled() in lib/common.sh.
  DRY_RUN="${dry_run}"
  option_parse options "hostname,user,shell,groups,locale,timezone,path" "${remaining[@]}"
  [[ -v "options[hostname]" ]] && hostname_requested=true

  if ! lxc_exists "${ctid}"; then
    fatal "LXC ${ctid} does not exist."
  fi
  [[ -f "${PROFILE_DIR}/${profile}.conf" ]] || fatal "Profile '${profile}' does not exist."
  validate_profile "${PROFILE_DIR}/${profile}.conf"

  if ! dry_run_enabled && ! lxc_is_running "${ctid}"; then
    fatal "LXC ${ctid} is not running."
  fi

  local resolved_user_name
  local resolved_work_dir
  resolved_user_name="$(option_get options user USER_NAME '')"
  resolved_work_dir="$(option_get options path WORK_DIR /app)"

  current_hostname="$(migration_read_hostname "${ctid}")"
  target_hostname="${current_hostname}"
  if [[ "${hostname_requested}" == true ]]; then
    target_hostname="${options[hostname]}"
    [[ "${target_hostname}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || fatal "Invalid hostname '${target_hostname}'."
  fi
  local hostname_action='preserved'
  [[ "${hostname_requested}" == true ]] && hostname_action="change to ${target_hostname}"
  migration_print_plan "${ctid}" "${current_hostname}" "${hostname_action}" "${profile}"

  if [[ "${hostname_requested}" == true ]]; then
    lxc_set_hostname "${ctid}" "${target_hostname}" || return 1
  fi

  if [[ "${dry_run}" == true ]]; then
    run_profile "${ctid}" "${PROFILE_DIR}/${profile}.conf" false options
    migration_print_report "${ctid}" "${profile}" "${target_hostname}" "${resolved_user_name}" "${resolved_work_dir}"
    log_success "Dry run completed."
    return 0
  fi

  run_profile "${ctid}" "${PROFILE_DIR}/${profile}.conf" false options || return 1
  log_action_record "migrate" "${ctid}" "${target_hostname}" "${profile}"
  migration_print_report "${ctid}" "${profile}" "${target_hostname}" "${resolved_user_name}" "${resolved_work_dir}"
}

# Gathers the same connection/Git/SSH-key summary as migrate, but purely by
# reading an existing, already-configured LXC - it never runs a profile or
# touches guest state. Useful to regenerate a lost project-manager entry or
# SSH key listing for an LXC that was set up previously.
run_info() {
  local ctid="${1:-}"
  shift || true
  local profile="default"
  declare -A options=()
  declare -A common_options=()
  local remaining=()

  [[ -n "${ctid}" ]] || fatal "Usage: ./configurator.sh info <ctid> [profile] [options]"
  [[ "${ctid}" =~ ^[0-9]+$ ]] || fatal "Invalid CTID '${ctid}'. Expected a numeric container ID."

  if [[ $# -gt 0 && "${1}" != --* ]]; then
    profile="$1"
    shift
  fi

  option_extract_common common_options remaining "$@"
  option_parse options "user,path" "${remaining[@]}"

  if ! lxc_exists "${ctid}"; then
    fatal "LXC ${ctid} does not exist."
  fi
  [[ -f "${PROFILE_DIR}/${profile}.conf" ]] || fatal "Profile '${profile}' does not exist."
  validate_profile "${PROFILE_DIR}/${profile}.conf"

  if ! lxc_is_running "${ctid}"; then
    fatal "LXC ${ctid} is not running."
  fi

  local resolved_user_name
  local resolved_work_dir
  resolved_user_name="$(option_get options user USER_NAME '')"
  resolved_work_dir="$(option_get options path WORK_DIR /app)"

  local hostname
  hostname="$(migration_read_hostname "${ctid}")"

  printf '%s\n' '' "LXC ${ctid} summary" '--------------------'
  lxc_print_summary "${ctid}" "${profile}" "${hostname}" "${resolved_user_name}" "${resolved_work_dir}"
}
