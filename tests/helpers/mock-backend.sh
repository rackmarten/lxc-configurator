#!/usr/bin/env bash

MOCK_ROOT="${MOCK_ROOT:-$(mktemp -d)}"
MOCK_OPERATIONS_FILE="${MOCK_ROOT}/operations"
: > "${MOCK_OPERATIONS_FILE}"

mock_operations() {
  cat "${MOCK_OPERATIONS_FILE}"
}

mock_record() {
  printf '%s\n' "$*" >> "${MOCK_OPERATIONS_FILE}"
}

MOCK_SSH_KEY_FILE="${MOCK_SSH_KEY_FILE:-}"
MOCK_SSH_KEY_CONTENT="${MOCK_SSH_KEY_CONTENT:-ssh-ed25519 AAAAmockkey user@lxc}"

# A tiny fake guest filesystem, rooted here, backing guest_file_write/read/exists
# for paths that aren't one of the special-cased fixtures above. Lets tests
# (e.g. secrets-guard) exercise a real write-then-read-back round trip.
MOCK_GUEST_FS="${MOCK_ROOT}/guest_fs"
mkdir -p "${MOCK_GUEST_FS}"

lxc_exists() {
  mock_record "inspect_lxc ${1:-}"
  [[ "${1:-}" == "250" ]]
}

lxc_is_running() {
  mock_record "check_running ${1:-}"
  [[ "${1:-}" == "250" ]]
}

guest_exec() {
  shift
  mock_record "${*}"

  if dry_run_enabled; then
    return 0
  fi

  case "${1:-}" in
    test)
      if [[ "${2:-}" == "-e" ]]; then
        [[ "${3:-}" == "/app" || ( -n "${MOCK_SSH_KEY_FILE}" && "${3:-}" == "${MOCK_SSH_KEY_FILE}" ) ]]
      else
        return 1
      fi
      ;;
    hostname)
      if [[ "${2:-}" == "-I" ]]; then
        printf '172.17.0.2 10.0.0.42\n'
      else
        printf 'mock-host\n'
      fi
      ;;
    getent)
      if [[ "${2:-}" == "passwd" ]]; then
        printf '%s:x:1000:1000::/home/%s:/bin/zsh\n' "${3:-}" "${3:-}"
      else
        return 1
      fi
      ;;
    cat)
      if [[ "${2:-}" == "--" && -n "${MOCK_SSH_KEY_FILE}" && "${3:-}" == "${MOCK_SSH_KEY_FILE}" ]]; then
        printf '%s\n' "${MOCK_SSH_KEY_CONTENT}"
      elif [[ "${2:-}" == "--" && -f "${MOCK_GUEST_FS}${3:-}" ]]; then
        cat -- "${MOCK_GUEST_FS}${3:-}"
      else
        return 1
      fi
      ;;
    sh)
      # Matches guest_file_write's `sh -c 'cat > "$1"' sh <file>` invocation,
      # and scaffold's `sh -c 'cd "$1" && ln -sf AGENTS.md CLAUDE.md' sh <dir>`.
      # shellcheck disable=SC2016  # '$1' is the guest script's literal argument, not shell expansion here.
      if [[ "${2:-}" == "-c" && "${3:-}" == 'cat > "$1"' && "${4:-}" == "sh" && -n "${5:-}" ]]; then
        mkdir -p "$(dirname "${MOCK_GUEST_FS}${5}")"
        cat > "${MOCK_GUEST_FS}${5}"
      elif [[ "${2:-}" == "-c" && "${3:-}" == 'cd "$1" && ln -sf AGENTS.md CLAUDE.md' && "${4:-}" == "sh" && -n "${5:-}" ]]; then
        mkdir -p "${MOCK_GUEST_FS}${5}"
        ln -sf AGENTS.md "${MOCK_GUEST_FS}${5}/CLAUDE.md"
      else
        return 1
      fi
      ;;
    jq)
      shift
      command jq "$@"
      ;;
    *)
      return 0
      ;;
  esac
}

guest_file_exists() {
  local path="${2:-}"
  mock_record "inspect_file ${path}"
  [[ "${path}" == "/app" ||
     ( -n "${MOCK_SSH_KEY_FILE}" && "${path}" == "${MOCK_SSH_KEY_FILE}" ) ||
     -e "${MOCK_GUEST_FS}${path}" ]]
}
