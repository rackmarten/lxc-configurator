#!/usr/bin/env bash

# Scans the working directory for secrets and keeps .gitignore and the
# project's .claude/settings.json deny rules in step with what's actually
# there, instead of relying on a static template.

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="secrets-guard"
MODULE_DESCRIPTION="Scan the project for secrets and extend .gitignore/.claude/settings.json"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

# Always denied, regardless of what the scan finds. Deliberately scoped to
# the literal `.env` file rather than a `.env.*` wildcard: Claude Code's
# permission model lets deny rules always win over allow rules, so a
# wildcard deny here would also block `.env.example` (see
# SECRETS_GUARD_BASELINE_ALLOW below) with no way for an allow rule to win
# it back. The Bash rules are a best-effort mitigation for the exact
# `cat`/`rg`/`shellcheck` invocations shown below only — they cannot catch
# every way to read a file via Bash (other readers, absolute paths,
# `python -c ...`, `rg` with a variable search pattern before the
# filename, etc).
SECRETS_GUARD_BASELINE_DENY=(
  "Read(**/.env)"
  "Edit(**/.env)"
  "Bash(cat .env)"
  "Bash(cat *.env)"
  "Bash(rg .env)"
  "Bash(rg *.env)"
  "Bash(shellcheck .env)"
  "Bash(shellcheck *.env)"
)

# Always allowed. `.env.example` is the checked-in reference config - it
# carries no real secrets by definition - so it must stay readable/editable
# even though it matches the "looks like an env file" pattern the deny
# rules above are guarding against.
SECRETS_GUARD_BASELINE_ALLOW=(
  "Read(**/.env.example)"
  "Edit(**/.env.example)"
  "Bash(cat .env.example)"
  "Bash(cat *.env.example)"
)

# Well-known secret-bearing filenames that aren't already covered by the
# static .gitignore template's *.pem/*.key/*.p12/*.pfx rules.
SECRETS_GUARD_EXTRA_FILE_NAMES=(
  "id_rsa"
  "id_ed25519"
  "id_ecdsa"
  "id_dsa"
  ".npmrc"
  ".netrc"
  ".pgpass"
  "credentials.json"
  "secrets.json"
  "secrets.yaml"
  "secrets.yml"
)

_secrets_guard_json_escape() {
  local value="${1:-}"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "${value}"
}

_secrets_guard_json_array() {
  local first=true
  local item

  printf '['
  for item in "$@"; do
    [[ "${first}" == true ]] || printf ','
    first=false
    printf '"%s"' "$(_secrets_guard_json_escape "${item}")"
  done
  printf ']'
}

_secrets_guard_ensure_claude_dir() {
  local ctid="${1:-}"
  local claude_dir="${WORK_DIR}/.claude"

  if guest_file_exists "${ctid}" "${claude_dir}"; then
    return 0
  fi

  guest_exec "${ctid}" mkdir -p "${claude_dir}"
  guest_exec "${ctid}" chown "${USER_NAME}:${USER_NAME}" "${claude_dir}"
  log_success "Created '${claude_dir}'."
}

# Merges a JSON array of rule strings into permissions.<key> (key is
# "deny" or "allow"), preserving every other key already in the file.
_secrets_guard_merge_permission_rules() {
  local ctid="${1:-}"
  local key="${2:-}"
  local rules_json="${3:-}"
  local settings_file="${WORK_DIR}/.claude/settings.json"

  [[ -n "${rules_json}" && "${rules_json}" != "[]" ]] || return 0

  _secrets_guard_ensure_claude_dir "${ctid}"

  local current="{}"
  if guest_file_exists "${ctid}" "${settings_file}"; then
    current="$(guest_file_read "${ctid}" "${settings_file}")"
    [[ -n "${current}" ]] || current="{}"
  fi

  local merged
  # shellcheck disable=SC2016  # This is jq's own filter syntax; $current/$add/$key are jq --arg/--argjson bindings, not shell variables.
  merged="$(
    guest_exec "${ctid}" jq -n \
      --argjson current "${current}" \
      --argjson add "${rules_json}" \
      --arg key "${key}" \
      '$current | .permissions[$key] = ((.permissions[$key] // []) + $add | unique)'
  )" || { log_error "Failed to update '${settings_file}'."; return 1; }

  # Empty output here means guest_exec short-circuited for dry-run, not a
  # real failure (a real jq error already returned non-zero above).
  [[ -n "${merged}" ]] || return 0

  guest_file_write "${ctid}" "${settings_file}" "${merged}"
  guest_exec "${ctid}" chmod 664 "${settings_file}"
  guest_exec "${ctid}" chown "${USER_NAME}:${USER_NAME}" "${settings_file}"

  log_success "Updated ${key} rules in '${settings_file}'."
}

_secrets_guard_add_deny_rules() {
  _secrets_guard_merge_permission_rules "${1:-}" deny "${2:-}"
}

_secrets_guard_add_allow_rules() {
  _secrets_guard_merge_permission_rules "${1:-}" allow "${2:-}"
}

# Appends a single line to .gitignore if it isn't already covered, without
# touching ownership of a .gitignore this module didn't create.
_secrets_guard_gitignore_add() {
  local ctid="${1:-}"
  local rule="${2:-}"
  local gitignore_file="${WORK_DIR}/.gitignore"

  [[ -n "${rule}" ]] || return 0

  if guest_file_exists "${ctid}" "${gitignore_file}"; then
    if guest_exec "${ctid}" grep -qxF "${rule}" "${gitignore_file}"; then
      return 0
    fi

    local existing
    existing="$(guest_file_read "${ctid}" "${gitignore_file}")"
    guest_file_write "${ctid}" "${gitignore_file}" "${existing}"$'\n'"${rule}"
  else
    guest_file_write "${ctid}" "${gitignore_file}" "${rule}"
    guest_exec "${ctid}" chown "${USER_NAME}:${USER_NAME}" "${gitignore_file}"
  fi

  guest_exec "${ctid}" chmod 664 "${gitignore_file}"

  log_success "Added '${rule}' to .gitignore."
}

_secrets_guard_find_compose_file() {
  local ctid="${1:-}"
  local candidate

  for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if guest_file_exists "${ctid}" "${WORK_DIR}/${candidate}"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done

  return 1
}

# Extends .gitignore with the relative bind-mount paths a compose file
# actually declares, but only for ones that exist on disk right now -
# never a generic guess at what a service "usually" needs.
_secrets_guard_extend_gitignore_from_compose() {
  local ctid="${1:-}"
  local compose_rel="${2:-}"
  local content line rel_path

  content="$(guest_file_read "${ctid}" "${WORK_DIR}/${compose_rel}")"

  while IFS= read -r line; do
    line="$(trim_whitespace "${line}")"
    line="${line#-}"
    line="$(trim_whitespace "${line}")"
    [[ -n "${line}" ]] || continue

    rel_path="${line%%:*}"
    rel_path="${rel_path#./}"
    [[ -n "${rel_path}" ]] || continue

    if guest_exec "${ctid}" test -d "${WORK_DIR}/${rel_path}"; then
      _secrets_guard_gitignore_add "${ctid}" "${rel_path}/"
    fi
  done < <(printf '%s\n' "${content}" | grep -E '^[[:space:]]*-[[:space:]]*\./')
}

# Flags literal-looking secret values (not ${VAR} references) sitting in a
# compose file that's actually tracked by Git, so a human moves them to
# .env before the repo is pushed anywhere. Scoped to compose files only -
# not a general tracked-file secret scan.
_secrets_guard_scan_compose_secrets() {
  local ctid="${1:-}"
  local compose_rel="${2:-}"
  local compose_path="${WORK_DIR}/${compose_rel}"
  local pattern='(PASSWORD|SECRET|TOKEN|API_?KEY|CREDENTIAL)[A-Za-z0-9_]*[[:space:]]*[:=][[:space:]]*[^$[:space:]#]'
  local matches line

  if ! guest_exec "${ctid}" git -C "${WORK_DIR}" ls-files --error-unmatch "${compose_rel}" >/dev/null 2>&1; then
    return 0
  fi

  matches="$(guest_exec "${ctid}" grep -nEi "${pattern}" "${compose_path}")" || true
  [[ -n "${matches}" ]] || return 0

  log_warn "Possible hardcoded credential(s) committed in tracked file '${compose_rel}':"
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    log_warn "  ${line}"
  done <<< "${matches}"
  log_warn "Move these values into '.env' and reference them as \${VAR} before pushing this repo anywhere."
}

# Looks for well-known secret-bearing filenames that actually exist in the
# work dir and denies Claude Code access to each one by its real path.
_secrets_guard_scan_secret_files() {
  local ctid="${1:-}"
  local find_args=(find "${WORK_DIR}" -mindepth 1 -not -path '*/.git/*' -not -path '*/.git' '(')
  local first=true
  local name path rel
  local deny_rules=()

  for name in "${SECRETS_GUARD_EXTRA_FILE_NAMES[@]}"; do
    if [[ "${first}" == true ]]; then
      find_args+=(-name "${name}")
      first=false
    else
      find_args+=(-o -name "${name}")
    fi
  done
  find_args+=(')')

  local found
  found="$(guest_exec "${ctid}" "${find_args[@]}")" || true
  [[ -n "${found}" ]] || return 0

  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    rel="${path#"${WORK_DIR}"/}"

    log_warn "Found potential secret file '${rel}'; denying Claude Code access to it."

    deny_rules+=(
      "Read(**/${rel})"
      "Edit(**/${rel})"
      "Bash(cat ${rel})"
      "Bash(cat ${rel}:*)"
      "Bash(rg ${rel})"
      "Bash(rg ${rel}:*)"
      "Bash(shellcheck ${rel})"
      "Bash(shellcheck ${rel}:*)"
    )

    _secrets_guard_gitignore_add "${ctid}" "${rel}"
  done <<< "${found}"

  if [[ ${#deny_rules[@]} -gt 0 ]]; then
    _secrets_guard_add_deny_rules "${ctid}" "$(_secrets_guard_json_array "${deny_rules[@]}")"
  fi
}

configure_secrets_guard() {
  local ctid="${1:-}"
  shift || true

  if [[ "${1:-}" == "--help" ]]; then
    configure_secrets_guard_help
    return 1
  fi

  if [[ -z "${ctid}" ]]; then
    fatal "Usage: ./configurator.sh module secrets-guard <ctid>"
  fi

  [[ -n "${WORK_DIR:-}" ]] || fatal "WORK_DIR is not configured."
  [[ -n "${USER_NAME:-}" ]] || fatal "USER_NAME is not configured."

  if ! guest_file_exists "${ctid}" "${WORK_DIR}"; then
    fatal "Working directory '${WORK_DIR}' does not exist."
  fi

  log_info "Scanning '${WORK_DIR}' for secrets in LXC ${ctid}..."

  guest_install_packages "${ctid}" jq

  _secrets_guard_add_deny_rules \
    "${ctid}" \
    "$(_secrets_guard_json_array "${SECRETS_GUARD_BASELINE_DENY[@]}")"

  _secrets_guard_add_allow_rules \
    "${ctid}" \
    "$(_secrets_guard_json_array "${SECRETS_GUARD_BASELINE_ALLOW[@]}")"

  local compose_rel
  if compose_rel="$(_secrets_guard_find_compose_file "${ctid}")"; then
    log_info "Found compose file '${compose_rel}'; extending .gitignore for its bind-mounted data directories..."
    _secrets_guard_extend_gitignore_from_compose "${ctid}" "${compose_rel}"
    _secrets_guard_scan_compose_secrets "${ctid}" "${compose_rel}"
  else
    log_info "No docker-compose file found in '${WORK_DIR}'; skipping compose-based scan."
  fi

  _secrets_guard_scan_secret_files "${ctid}"

  log_success "Secrets guard completed for '${WORK_DIR}' in LXC ${ctid}."
}

configure_secrets_guard_help() {
  cat <<'EOF'
Usage: ./configurator.sh module secrets-guard <ctid>

Scans WORK_DIR for secrets and keeps generated project files in step with
what's actually there:
  - Extends .gitignore with bind-mounted data directories a compose file
    declares, but only ones that actually exist on disk.
  - Extends the committed .claude/settings.json with deny rules for .env
    files and any other well-known secret-bearing files it finds, plus an
    allow rule keeping .env.example itself readable/editable.
  - Warns about literal (non-${VAR}) secret-looking values already
    committed in a tracked compose file.

Requires WORK_DIR and USER_NAME to already be configured (see the work-dir
module). Installs jq in the guest if missing.
EOF
}
