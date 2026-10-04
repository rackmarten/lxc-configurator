#!/usr/bin/env bash

# Project scaffold provisioning module.

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="scaffold"
MODULE_DESCRIPTION="Create the project scaffold and optionally initialize Git"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

SCAFFOLD_TEMPLATE_DIR="${SCRIPT_DIR}/templates/work-dir"

_scaffold_list_components() {
  [[ -d "${SCAFFOLD_TEMPLATE_DIR}" ]] || return 0

  find "${SCAFFOLD_TEMPLATE_DIR}" \
    -mindepth 1 \
    -maxdepth 1 \
    ! -name '.git' \
    -printf '%P\n' |
    sort
}

_scaffold_template_exists() {
  local component="${1:-}"

  [[ -n "${component}" ]] ||
    return 1

  [[ "${component}" != ".git" ]] ||
    return 1

  [[ "${component}" != .git/* ]] ||
    return 1

  [[ -e "${SCAFFOLD_TEMPLATE_DIR}/${component}" ]]
}

_scaffold_parse_default_components() {
  local component

  SCAFFOLD_SELECTED_COMPONENTS=()

  while IFS= read -r component; do
    [[ -n "${component}" ]] ||
      continue

    SCAFFOLD_SELECTED_COMPONENTS+=("${component}")
  done < <(_scaffold_list_components)
}

_scaffold_parse_args() {
  SCAFFOLD_SELECTED_COMPONENTS=()
  SCAFFOLD_EXPLICIT_SELECTION=false
  SCAFFOLD_INIT_GIT="${WORK_DIR_SCAFFOLD_INIT_GIT:-false}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --component)
        [[ $# -ge 2 ]] ||
          fatal "--component requires a value."

        SCAFFOLD_SELECTED_COMPONENTS+=("$2")
        SCAFFOLD_EXPLICIT_SELECTION=true

        shift 2
        ;;

      --git)
        SCAFFOLD_INIT_GIT=true
        shift
        ;;

      --no-git)
        SCAFFOLD_INIT_GIT=false
        shift
        ;;

      --help)
        cat <<'EOF'
Usage:
  ./configurator.sh module scaffold <ctid> [options]

Options:
  --component <path>
      Add a scaffold template component.

  --git
      Initialize a Git repository.

  --no-git
      Do not initialize a Git repository.

Selecting the AGENTS.md component also creates CLAUDE.md as a symlink to
AGENTS.md in the guest (Claude Code auto-loads CLAUDE.md, not AGENTS.md).
An existing CLAUDE.md is preserved, same as any other scaffold target.

Examples:
  ./configurator.sh module scaffold 250

  ./configurator.sh module scaffold 250 \
    --component .env.example \
    --component .gitignore \
    --component .vscode \
    --component .claude \
    --component .github \
    --component docker-compose.yml \
    --component scripts \
    --git
EOF
        return 1
        ;;

      *)
        fatal "Unknown scaffold option: $1"
        ;;
    esac
  done

  if [[ "${SCAFFOLD_EXPLICIT_SELECTION}" == "false" ]]; then
    _scaffold_parse_default_components
  fi
}

_scaffold_copy_file() {
  local ctid="${1:-}"
  local source_file="${2:-}"
  local target_file="${3:-}"
  local hostname="${4:-}"

  if guest_file_exists "${ctid}" "${target_file}"; then
    log_info "File '${target_file}' already exists, preserving it."
    return 0
  fi

  local content

  content="$(
    template_render_file \
      "${source_file}" \
      CTID "${ctid}" \
      HOSTNAME "${hostname}" \
      WORK_DIR "${WORK_DIR}" \
      USER_NAME "${USER_NAME}" \
      WORK_DIR_PROJECT_NAME "${WORK_DIR_PROJECT_NAME:-${hostname}}"
  )"

  guest_file_write \
    "${ctid}" \
    "${target_file}" \
    "${content}"

  guest_exec \
    "${ctid}" \
    chmod 664 \
    "${target_file}"

  guest_exec \
    "${ctid}" \
    chown \
    "${USER_NAME}:${USER_NAME}" \
    "${target_file}"

  log_success "Created '${target_file}'."
}

_scaffold_symlink_claude_md() {
  local ctid="${1:-}"

  local target="${WORK_DIR}/CLAUDE.md"

  if guest_file_exists "${ctid}" "${target}"; then
    log_info "File '${target}' already exists, preserving it."
    return 0
  fi

  # shellcheck disable=SC2016  # '$1' is expanded by the guest's sh, not this shell.
  guest_exec \
    "${ctid}" \
    sh -c 'cd "$1" && ln -sf AGENTS.md CLAUDE.md' \
    sh "${WORK_DIR}"

  guest_exec \
    "${ctid}" \
    chown \
    -h \
    "${USER_NAME}:${USER_NAME}" \
    "${target}"

  log_success "Created '${target}' as a symlink to 'AGENTS.md'."
}

_scaffold_copy_directory() {
  local ctid="${1:-}"
  local source_dir="${2:-}"
  local target_dir="${3:-}"
  local hostname="${4:-}"

  if guest_file_exists "${ctid}" "${target_dir}"; then
    log_info "Directory '${target_dir}' already exists, preserving it."
  else
    log_info "Creating directory '${target_dir}'..."

    guest_exec \
      "${ctid}" \
      mkdir -p \
      "${target_dir}"

    guest_exec \
      "${ctid}" \
      chown \
      "${USER_NAME}:${USER_NAME}" \
      "${target_dir}"

    log_success "Created directory '${target_dir}'."
  fi

  while IFS= read -r -d '' source_path; do
    local relative_path="${source_path#"${source_dir}"/}"
    local target_path="${target_dir}/${relative_path}"

    if [[ -d "${source_path}" ]]; then
      if guest_file_exists "${ctid}" "${target_path}"; then
        log_info "Directory '${target_path}' already exists, preserving it."
      else
        guest_exec \
          "${ctid}" \
          mkdir -p \
          "${target_path}"

        guest_exec \
          "${ctid}" \
          chown \
          "${USER_NAME}:${USER_NAME}" \
          "${target_path}"

        log_success "Created directory '${target_path}'."
      fi
    else
      _scaffold_copy_file \
        "${ctid}" \
        "${source_path}" \
        "${target_path}" \
        "${hostname}"
    fi
  done < <(
    find "${source_dir}" \
      -mindepth 1 \
      -print0
  )
}

_scaffold_copy_component() {
  local ctid="${1:-}"
  local component="${2:-}"
  local hostname="${3:-}"

  local source="${SCAFFOLD_TEMPLATE_DIR}/${component}"
  local target="${WORK_DIR}/${component}"

  if [[ -d "${source}" ]]; then
    _scaffold_copy_directory \
      "${ctid}" \
      "${source}" \
      "${target}" \
      "${hostname}"
    return 0
  fi

  _scaffold_copy_file \
    "${ctid}" \
    "${source}" \
    "${target}" \
    "${hostname}"

  if [[ "${component}" == "AGENTS.md" ]]; then
    _scaffold_symlink_claude_md "${ctid}"
  fi
}

_scaffold_init_git() {
  local ctid="${1:-}"

  if guest_file_exists "${ctid}" "${WORK_DIR}/.git"; then
    log_info "Git repository already exists."
    return 0
  fi

  log_info "Initializing Git repository..."

  guest_exec \
    "${ctid}" \
    sudo -u "${USER_NAME}" \
    git -C "${WORK_DIR}" init -q

  log_success "Initialized Git repository."
}

configure_scaffold() {
  local ctid="${1:-}"

  shift || true

  if [[ -z "${ctid}" ]]; then
    fatal "Usage: ./configurator.sh module scaffold <ctid> [options]"
  fi

  [[ -n "${WORK_DIR:-}" ]] ||
    fatal "WORK_DIR is not configured."

  [[ -n "${USER_NAME:-}" ]] ||
    fatal "USER_NAME is not configured."

  if ! guest_file_exists "${ctid}" "${WORK_DIR}"; then
    fatal "Working directory '${WORK_DIR}' does not exist."
  fi

  _scaffold_parse_args "$@"

  local hostname
  hostname="$(guest_exec "${ctid}" hostname)"

  if [[ ${#SCAFFOLD_SELECTED_COMPONENTS[@]} -eq 0 &&
        "${SCAFFOLD_INIT_GIT}" != "true" ]]; then
    log_warn "No scaffold components or actions selected."
    return 0
  fi

  log_info \
    "Configuring project scaffold in '${WORK_DIR}' for user '${USER_NAME}' in LXC ${ctid}..."

  local component

  for component in "${SCAFFOLD_SELECTED_COMPONENTS[@]}"; do
    [[ -n "${component}" ]] ||
      continue

    if ! _scaffold_template_exists "${component}"; then
      log_error "Scaffold template not found: ${component}"
      return 1
    fi

    _scaffold_copy_component \
      "${ctid}" \
      "${component}" \
      "${hostname}"
  done

  if [[ "${SCAFFOLD_INIT_GIT}" == "true" ]]; then
    _scaffold_init_git "${ctid}"
  fi

  log_success \
    "Project scaffold configured in '${WORK_DIR}'."
}
