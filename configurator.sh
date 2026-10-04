#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURATOR_VERSION="0.1.0"
RECIPE_FORMAT_VERSION="1"
ENV_FILE="${SCRIPT_DIR}/.env"
PROFILE_DIR="${SCRIPT_DIR}/profiles"

source "${SCRIPT_DIR}/lib/common.sh"
source "${SCRIPT_DIR}/lib/options.sh"
source "${SCRIPT_DIR}/lib/lxc.sh"
source "${SCRIPT_DIR}/lib/lxc_config.sh"
source "${SCRIPT_DIR}/lib/guest.sh"
source "${SCRIPT_DIR}/lib/module.sh"
source "${SCRIPT_DIR}/lib/profile.sh"
source "${SCRIPT_DIR}/lib/configure.sh"
source "${SCRIPT_DIR}/lib/create.sh"
source "${SCRIPT_DIR}/lib/network.sh"
source "${SCRIPT_DIR}/lib/version.sh"
source "${SCRIPT_DIR}/lib/recipe.sh"
source "${SCRIPT_DIR}/lib/interactive.sh"
source "${SCRIPT_DIR}/lib/generated.sh"
source "${SCRIPT_DIR}/lib/template.sh"
source "${SCRIPT_DIR}/lib/migrate.sh"
source "${SCRIPT_DIR}/lib/status.sh"

show_help() {
  cat <<'EOF'
Usage: ./configurator.sh <command> [arguments]

Commands:
  help
      Show this help message.

  version
      Print the project version.

  profile list
      List available configuration profiles

  module <name> <ctid> [options]
      Run an individual provisioning module.

  module list
      List available provisioning modules.

  configure <ctid> [profile] [--dry-run]
      Configure an LXC using a profile.

    migrate <ctid> [profile] [options]
      Migrate an existing LXC using a profile.

  create <ctid> [profile] [options]
      Create and configure a new LXC.

  info <ctid> [profile] [options]
      Print the connection/SSH-key/project-manager summary for an existing,
      already-configured LXC. Read-only: never runs a profile or changes
      guest state.

      Options:
        --user <name>
        --path <path>

  status
      List currently running LXC containers (Proxmox VMs, e.g. a Home
      Assistant OS guest, are never included - they live in a separate
      qm/pct namespace) and show which ones this tool has already migrated,
      created, or configured, based on the local action ledger.

  interactive
      Start the interactive recipe generator.

      Options:
        --generate-cli-command
            Print the generated CLI commands.

  execute <script> [arguments]
      Execute a generated configuration script.

  generated list
      List generated configuration scripts.
  
  generated validate <script>
      Validate a generated configuration script.

  test
      Run the unprivileged test suite.

  run <recipe> [arguments]
      Run a generated configuration recipe.

      Options:
        --template <template>
        --storage <storage>
        --hostname <hostname>
        --ip <auto|dhcp|address/cidr>   (default: auto - last octet = CTID)
        --gw <gateway>
        --bridge <bridge>
        --cores <count>
        --memory <mb>
        --swap <mb>
        --disk <gb>
        --start
        --no-start
        --dry-run

Examples:
  ./configurator.sh help
  ./configurator.sh version
  ./configurator.sh module tun 200
  ./configurator.sh configure 200
  ./configurator.sh configure 200 default
  ./configurator.sh migrate 200 minimal --dry-run
EOF
}


load_env_if_present() {
  if [[ -f "${ENV_FILE}" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
    set +a

    log_info "Loaded environment file: ${ENV_FILE}"
  fi
}

main() {
  local command="${1:-help}"

  case "${command}" in
    help|--help|-h|version|-v|profile|generated|test)
      ;;
    configure)
      [[ "${4:-}" == "--dry-run" ]] || require_root
      ;;
    migrate)
      [[ "${*:2}" == *"--dry-run"* || "${2:-}" == "--help" || "${2:-}" == "-h" ]] || require_root
      ;;
    info)
      [[ "${2:-}" == "--help" || "${2:-}" == "-h" ]] || require_root
      ;;
    status)
      require_root
      ;;
    module)
      [[ "${*:4}" == *"--dry-run"* ]] || [[ "${2:-}" == "list" ]] || [[ "${3:-}" == "--help" || "${3:-}" == "-h" ]] || require_root
      ;;
    run)
      [[ "${*:2}" == *"--dry-run"* ]] || require_root
      ;;
    *)
      require_root
      ;;
  esac

  if [[ "${command}" != "test" ]]; then
    load_env_if_present
  fi

  case "${command}" in
    help|--help|-h)
      show_help
      ;;

    version|-v)
      print_version
      ;;

    profile)
      if [[ "${2:-}" != "list" ]]; then
        fatal "Usage: ./configurator.sh profile list"
      fi

      list_profiles
      ;;

    module)
      if [[ "${2:-}" == "list" ]]; then
        list_module_metadata
      else
        run_module "${2:-}" "${3:-}" "${@:4}"
      fi
      ;;

    configure)
      run_configure "${2:-}" "${3:-default}" "${4:-}"
      ;;

    migrate)
      if [[ "${2:-}" == "--help" || "${2:-}" == "-h" ]]; then
        printf '%s\n' 'Usage: ./configurator.sh migrate <ctid> [profile] [options]' '' 'Options:' '  --hostname <name>' '  --user <name>' '  --shell <path>' '  --groups <list>' '  --locale <value>' '  --timezone <value>' '  --path <path>' '  --dry-run'
      else
        run_migrate "${2:-}" "${@:3}"
      fi
      ;;

    create)
      create_lxc "${2:-}" "${@:3}"
      ;;

    info)
      if [[ "${2:-}" == "--help" || "${2:-}" == "-h" ]]; then
        printf '%s\n' 'Usage: ./configurator.sh info <ctid> [profile] [options]' '' 'Options:' '  --user <name>' '  --path <path>'
      else
        run_info "${2:-}" "${@:3}"
      fi
      ;;

    status)
      run_status
      ;;

    interactive)
      shift
      run_interactive "$@"
      ;;

    run)
      shift
      run_recipe "$@"
      ;;

    execute)
      shift
      run_generated_script "$@"
      ;;

    generated)
      case "${2:-}" in
        list)
          list_generated_scripts
          ;;

        validate)
          generated_validate "${3:-}"
          ;;

        *)
          fatal "Usage: ./configurator.sh generated {list|validate <script>}"
          ;;
      esac
      ;;

    test)
      "${SCRIPT_DIR}/tests/test.sh"
      ;;

    "")
      show_help
      ;;

    *)
      log_error "Unsupported command: ${command}"
      echo
      show_help
      exit 1
      ;;
  esac
}


main "$@"
