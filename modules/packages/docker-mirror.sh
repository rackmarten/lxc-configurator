#!/usr/bin/env bash

# Points the guest's Docker daemon at a registry mirror (pull-through cache)
# by merging it into /etc/docker/daemon.json, keeping every other key.

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="docker-mirror"
MODULE_DESCRIPTION="Point Docker at a registry mirror"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

DOCKER_MIRROR_DAEMON_JSON="/etc/docker/daemon.json"

# Appends $mirror to registry-mirrors and, when $insecure is set, appends it
# to insecure-registries, each only if missing. Every other key and any
# mirror already listed is kept, so applying it twice changes nothing.
# shellcheck disable=SC2016  # jq's own syntax; $mirror/$insecure are jq --arg bindings.
DOCKER_MIRROR_JQ_FILTER='
  def add($v): (. // []) | if any(.[]; . == $v) then . else . + [$v] end;
  .["registry-mirrors"] |= add($mirror)
  | if $insecure != "" then .["insecure-registries"] |= add($insecure) else . end
'

# A mirror is a bare scheme://host[:port]; dockerd rejects a path here.
_docker_mirror_validate() {
  local mirror="${1:-}"

  [[ "${mirror}" =~ ^https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]]
}

# host:port of an http:// mirror (dockerd only talks plain HTTP to registries
# listed in insecure-registries), empty for https://.
_docker_mirror_insecure_entry() {
  local mirror="${1:-}"

  if [[ "${mirror}" == http://* ]]; then
    printf '%s' "${mirror#http://}"
  fi
}

# Prints daemon.json with the mirror merged in. Fails on invalid JSON, so a
# broken file is reported rather than overwritten. Any further arguments are
# a command prefix for jq (e.g. `guest_exec <ctid>`); without one jq runs
# locally.
_docker_mirror_merge() {
  local current="${1:-}"
  local mirror="${2:-}"
  shift 2 || true
  local insecure

  [[ -n "${current//[[:space:]]/}" ]] || current="{}"
  insecure="$(_docker_mirror_insecure_entry "${mirror}")"

  "$@" jq -n \
    --argjson current "${current}" \
    --arg mirror "${mirror}" \
    --arg insecure "${insecure}" \
    "\$current | ${DOCKER_MIRROR_JQ_FILTER}"
}

# True when dockerd reports the mirror as active. `docker info` lists
# mirrors with a trailing slash, so compare without it.
_docker_mirror_active() {
  local ctid="${1:-}"
  local mirror="${2:-}"
  local listed line

  listed="$(guest_exec "${ctid}" docker info --format '{{range .RegistryConfig.Mirrors}}{{println .}}{{end}}' 2>/dev/null)" ||
    return 1

  while IFS= read -r line; do
    [[ "${line%/}" == "${mirror}" ]] && return 0
  done <<< "${listed}"

  return 1
}

configure_docker_mirror() {
  local ctid="${1:-}"
  shift || true

  if [[ "${1:-}" == "--help" ]]; then
    configure_docker_mirror_help
    return 1
  fi

  declare -A options=()
  option_parse options "mirror" "$@"

  if [[ -z "${ctid}" ]]; then
    log_error "Docker mirror configuration requires a CTID."
    return 2
  fi

  local mirror
  mirror="$(option_get options mirror DOCKER_REGISTRY_MIRROR '')"
  mirror="${mirror%/}"

  if [[ -z "${mirror}" ]]; then
    log_info "DOCKER_REGISTRY_MIRROR is not set; leaving Docker's registry mirrors alone."
    return 0
  fi

  _docker_mirror_validate "${mirror}" ||
    fatal "Invalid registry mirror '${mirror}' (expected http(s)://host[:port])."

  log_info "Configuring Docker registry mirror '${mirror}' for LXC ${ctid}..."

  if ! guest_command_exists "${ctid}" docker; then
    log_warn "Docker is not installed in LXC ${ctid}; skipping the registry mirror."
    return 0
  fi

  guest_install_packages "${ctid}" jq || return 1

  local file="${DOCKER_MIRROR_DAEMON_JSON}"
  local current="" normalized merged

  if guest_file_exists "${ctid}" "${file}"; then
    current="$(guest_file_read "${ctid}" "${file}")" || {
      log_error "Failed to read ${file} in LXC ${ctid}."
      return 1
    }
  fi

  # Under dry-run guest_exec runs nothing, so the file cannot be read; merge
  # locally into an empty file instead, which still shows the added keys.
  if dry_run_enabled; then
    if command_exists jq && merged="$(_docker_mirror_merge "{}" "${mirror}")"; then
      log_info "[DRY-RUN] Would merge into ${file} (existing keys are kept):"
      printf '%s\n' "${merged}"
    fi
    log_info "[DRY-RUN] Would reload Docker (no restart) and check 'docker info' for the mirror."
    return 0
  fi

  merged="$(_docker_mirror_merge "${current}" "${mirror}" guest_exec "${ctid}")" || {
    log_error "${file} in LXC ${ctid} is not valid JSON; fix it by hand, it was left unchanged."
    return 1
  }

  normalized="{}"
  if [[ -n "${current//[[:space:]]/}" ]]; then
    # shellcheck disable=SC2016  # $current is a jq --argjson binding.
    normalized="$(guest_exec "${ctid}" jq -n --argjson current "${current}" '$current')"
  fi

  if [[ "${merged}" == "${normalized}" ]]; then
    log_info "${file} already lists the mirror."
  else
    if ! guest_exec "${ctid}" mkdir -p "${file%/*}" ||
      ! guest_file_write "${ctid}" "${file}" "${merged}"; then
      log_error "Failed to write ${file} in LXC ${ctid}."
      return 1
    fi
    log_success "Merged the mirror into ${file}."
  fi

  if ! guest_exec "${ctid}" systemctl is-active --quiet docker >/dev/null 2>&1; then
    log_info "Docker is not running; the mirror applies when it starts."
    return 0
  fi

  if _docker_mirror_active "${ctid}" "${mirror}"; then
    log_success "Docker in LXC ${ctid} uses registry mirror '${mirror}'."
    return 0
  fi

  # A reload (SIGHUP) re-reads registry-mirrors and insecure-registries
  # without stopping running containers; a restart would bounce them.
  log_info "Reloading Docker to pick up the mirror..."
  if ! guest_exec "${ctid}" systemctl reload docker >/dev/null 2>&1; then
    log_error "Failed to reload Docker in LXC ${ctid}."
    return 1
  fi

  if ! _docker_mirror_active "${ctid}" "${mirror}"; then
    log_error "Docker in LXC ${ctid} does not list '${mirror}' after the reload; check 'journalctl -u docker'."
    return 1
  fi

  log_success "Docker in LXC ${ctid} uses registry mirror '${mirror}'."
}

configure_docker_mirror_help() {
  cat <<'EOF'
Usage: ./configurator.sh module docker-mirror <ctid> [options]

Merges a registry mirror into /etc/docker/daemon.json (every other key is
kept), adds an http:// mirror's host:port to insecure-registries, then
reloads Docker (SIGHUP, running containers keep running) and checks that
'docker info' lists the mirror. Does nothing when no mirror is configured
or Docker is not installed.

Options:
    --mirror <url>   Override DOCKER_REGISTRY_MIRROR (http(s)://host[:port]).
EOF
}
