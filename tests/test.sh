#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TEST_DIR}/.." && pwd)"
SCRIPT_DIR="${ROOT_DIR}"
CONFIGURATOR_VERSION="0.1.0"
RECIPE_FORMAT_VERSION="1"
PROFILE_DIR="${ROOT_DIR}/profiles"
GENERATED_DIR="${ROOT_DIR}/generated"

# shellcheck source=helpers/test-framework.sh disable=SC1091
source "${TEST_DIR}/helpers/test-framework.sh"
source "${ROOT_DIR}/lib/common.sh"
source "${ROOT_DIR}/lib/options.sh"
source "${ROOT_DIR}/lib/template.sh"
source "${ROOT_DIR}/lib/generated.sh"
source "${ROOT_DIR}/lib/module.sh"
source "${ROOT_DIR}/lib/profile.sh"
source "${ROOT_DIR}/lib/configure.sh"
source "${ROOT_DIR}/lib/guest.sh"
source "${ROOT_DIR}/lib/lxc_config.sh"
source "${ROOT_DIR}/lib/lxc.sh"
source "${ROOT_DIR}/lib/migrate.sh"
source "${ROOT_DIR}/lib/status.sh"
# shellcheck source=helpers/mock-backend.sh disable=SC1091
source "${TEST_DIR}/helpers/mock-backend.sh"

assert_equal "trim_whitespace removes surrounding spaces" "value" "$(trim_whitespace '  value  ')"
# shellcheck disable=SC2034  # test_options is populated via option_parse's nameref, read only through it.
declare -A test_options=()
option_parse test_options user --user custom-user
assert_equal "option_get returns CLI override" "custom-user" "$(option_get test_options user USER_NAME default-user)"
declare -A common_options=()
common_module_options=()
option_extract_common common_options common_module_options --shell /bin/bash --dry-run --groups sudo,docker
assert_equal "common dry-run option is extracted" "true" "${common_options[dry-run]}"
assert_equal "module options remain ordered" "/bin/bash" "${common_module_options[1]}"
assert_equal "module options preserve later values" "sudo,docker" "${common_module_options[3]}"
# shellcheck disable=SC2034  # environment_options is read only via option_get's nameref.
declare -A environment_options=()
assert_equal "option_get falls back to environment" "env-user" "$(USER_NAME=env-user option_get environment_options user USER_NAME default-user)"
# shellcheck disable=SC2016  # These single-quoted ${...} templates are the input under test; template_render, not the shell, must expand them.
assert_equal "template rendering preserves spaces" 'Hello Ada Lovelace' "$(template_render 'Hello ${name}' name 'Ada Lovelace')"
# shellcheck disable=SC2016  # Same as above: input under test, not shell expansion.
assert_equal "template rendering substitutes multiple variables" '250 /app' "$(template_render '${ctid} ${path}' ctid 250 path /app)"
assert_success "valid profile is accepted" validate_profile "${PROFILE_DIR}/minimal.conf"
assert_failure "missing profile is rejected" validate_profile "${PROFILE_DIR}/missing.conf"
assert_success "existing-project example profile is valid" validate_profile "${PROFILE_DIR}/existing-project.conf"

profile_split_line_module=""
profile_split_line_args=()
_profile_split_line "scaffold --component .gitignore --component .claude" profile_split_line_module profile_split_line_args
assert_equal "profile line splitting extracts the module name" "scaffold" "${profile_split_line_module}"
assert_equal "profile line splitting extracts trailing options" "--component .gitignore --component .claude" "${profile_split_line_args[*]}"
profile_split_line_module=""
profile_split_line_args=()
_profile_split_line "tun" profile_split_line_module profile_split_line_args
assert_equal "profile line splitting handles a bare module name" "tun" "${profile_split_line_module}"
assert_equal "profile line splitting leaves no options for a bare module name" "" "${profile_split_line_args[*]}"

# --ip auto derives the address from the CTID (last octet == CTID), which is
# only valid while the CTID stays inside the range the router's DHCP pool is
# kept out of. Stub the in-use probe so these never touch the network.
# shellcheck source=../lib/network.sh disable=SC1091
source "${ROOT_DIR}/lib/network.sh"
_network_ip_in_use() { return 1; }

assert_equal "auto derives the IP from the CTID" "192.168.0.117/24" "$(_resolve_create_ip 117 auto)"
assert_equal "auto honors a custom LAN prefix" "10.0.5.117/24" "$(LXC_LAN_PREFIX=10.0.5 _resolve_create_ip 117 auto)"
assert_equal "auto keeps the lowest in-range CTID" "192.168.0.100/24" "$(_resolve_create_ip 100 auto)"
assert_equal "auto keeps the highest in-range CTID" "192.168.0.149/24" "$(_resolve_create_ip 149 auto)"
assert_failure "auto rejects a CTID below the reserved range" _resolve_create_ip 99 auto
assert_failure "auto rejects the first CTID inside the DHCP pool" _resolve_create_ip 150 auto
assert_failure "auto rejects a CTID far above the reserved range" _resolve_create_ip 250 auto
assert_equal "the ceiling follows LXC_CTID_MAX" "192.168.0.180/24" "$(LXC_CTID_MAX=199 _resolve_create_ip 180 auto)"
assert_failure "auto rejects a legacy 30x CTID" _resolve_create_ip 304 auto
assert_equal "dhcp is still passed through untouched" "dhcp" "$(_resolve_create_ip 117 dhcp)"
assert_equal "an explicit address overrides the CTID rule" "192.168.0.240/24" "$(_resolve_create_ip 304 192.168.0.240/24)"
assert_failure "a malformed address is still rejected" _resolve_create_ip 117 not-an-ip

# shellcheck disable=SC2034  # profile_forwarding_options is read only via profile_module_options's nameref.
declare -A profile_forwarding_options=([user]=bob [path]=/srv)
profile_forwarding_output=()
profile_module_options work-dir profile_forwarding_options profile_forwarding_output
assert_equal "profile_module_options forwards --user to work-dir" "--path /srv --user bob" "${profile_forwarding_output[*]}"
# A fixture in a temporary GENERATED_DIR, since generated/*.sh is gitignored
# and a fresh checkout has none.
generated_fixture_dir="$(mktemp -d)"
printf '%s\n' '#!/usr/bin/env bash' "# Configurator version: ${CONFIGURATOR_VERSION}" \
  "# Recipe format: ${RECIPE_FORMAT_VERSION}" 'set -Eeuo pipefail' > "${generated_fixture_dir}/minimal.sh"
chmod +x "${generated_fixture_dir}/minimal.sh"
validate_generated_fixture() {
  # shellcheck disable=SC2034  # read by generated_validate via dynamic scope.
  local GENERATED_DIR="${generated_fixture_dir}"
  generated_validate "${generated_fixture_dir}/minimal.sh" >/dev/null 2>&1
}
assert_success "generated script validates" validate_generated_fixture
rm -rf "${generated_fixture_dir}"

expected_modules=$'alloy\nbase\ndocker\nincinerator\nkopia-client\nkvm\nlocale\nscaffold\nsecrets-guard\nshell\nssh\ntailscale\ntun\nunattended-upgrades\nuser\nwork-dir'
assert_equal "module discovery is sorted by name" "${expected_modules}" "$(list_modules)"
module_metadata_output="$(list_module_metadata)"
assert_contains "module metadata includes user description" "${module_metadata_output}" "$(printf '%-22s %s' user 'Configure the primary user, groups, shell, SSH key and Git identity')"
assert_contains "module metadata includes locale description" "${module_metadata_output}" "$(printf '%-22s %s' locale 'Configure locale and timezone')"
assert_contains "module metadata includes scaffold description" "${module_metadata_output}" "$(printf '%-22s %s' scaffold 'Create the project scaffold and optionally initialize Git')"
assert_contains "module metadata includes secrets-guard description" "${module_metadata_output}" "$(printf '%-22s %s' secrets-guard 'Scan the project for secrets and extend .gitignore/.claude/settings.json')"
assert_success "all modules have valid metadata" validate_module alloy
assert_success "all modules have valid metadata" validate_module base
assert_success "all modules have valid metadata" validate_module docker
assert_success "all modules have valid metadata" validate_module locale
assert_success "all modules have valid metadata" validate_module scaffold
assert_success "all modules have valid metadata" validate_module secrets-guard
assert_success "all modules have valid metadata" validate_module shell
assert_success "all modules have valid metadata" validate_module ssh
assert_success "all modules have valid metadata" validate_module tailscale
assert_success "all modules have valid metadata" validate_module tun
assert_success "all modules have valid metadata" validate_module unattended-upgrades
assert_success "all modules have valid metadata" validate_module user
assert_success "all modules have valid metadata" validate_module work-dir

malformed_module_dir="$(mktemp -d)"
printf '%s\n' \
  'MODULE_NAME="broken"' \
  'MODULE_SUPPORTS_DRY_RUN=true' \
  'MODULE_REQUIRES_ROOT=true' \
  'configure_broken() { :; }' \
  > "${malformed_module_dir}/broken.sh"
module_dir_before_test="${MODULE_DIR}"
MODULE_DIR="${malformed_module_dir}"
assert_failure "malformed module metadata is rejected" validate_module broken
MODULE_DIR="${module_dir_before_test}"
rm -rf "${malformed_module_dir}"

MOCK_ROOT="$(mktemp -d)"
trap 'rm -rf "${MOCK_ROOT}"' EXIT
MOCK_OPERATIONS_FILE="${MOCK_ROOT}/operations"
: > "${MOCK_OPERATIONS_FILE}"

lxc_exec() {
  printf 'unexpected lxc_exec call\n' >> "${MOCK_ROOT}/unexpected"
  return 1
}

DRY_RUN=true
guest_exec 250 mkdir -p /app/project >/dev/null
assert_file_not_exists "dry-run does not call the real LXC backend" "${MOCK_ROOT}/unexpected"
assert_equal "dry-run records no host state" "" "$(find "${MOCK_ROOT}" -mindepth 1 -not -name operations -not -name unexpected -print)"
DRY_RUN=false

mock_record "mkdir /app/scripts"
assert_contains "mock backend records requested operations" "$(mock_operations)" "mkdir /app/scripts"

export USER_NAME=marek USER_PASSWORD=test-password GIT_USER_NAME=Marek GIT_USER_EMAIL=marek@example.com
export GIT_DEFAULT_BRANCH=main SSH_PUBLIC_KEY=test-key LOCALE=en_US.UTF-8 TIMEZONE=UTC WORK_DIR=/app LOKI_URL=http://loki:3100 TAILSCALE_LOGIN_SERVER=https://login.tailscale.com TAILSCALE_AUTH_KEY=test-auth-key

inline_profile_dir="$(mktemp -d)"
printf '%s\n' "scaffold --component .gitignore --component .claude" > "${inline_profile_dir}/inline.conf"
run_profile 250 "${inline_profile_dir}/inline.conf" false >/dev/null
assert_contains "profile line options reach scaffold: named component" "$(mock_operations)" "/app/.gitignore"
assert_contains "profile line options reach scaffold: named directory component" "$(mock_operations)" "/app/.claude"
if [[ "$(mock_operations)" != *"/app/README.md"* ]]; then
  pass "profile line options restrict scaffold: unnamed component is skipped"
else
  fail "profile line options restrict scaffold: unnamed component is skipped"
fi
rm -rf "${inline_profile_dir}"

# Scaffolding AGENTS.md must also create CLAUDE.md as a symlink to it (Claude
# Code only auto-loads CLAUDE.md), and re-running scaffold must preserve the
# existing symlink rather than recreating it.
agents_profile_dir="$(mktemp -d)"
printf '%s\n' "scaffold --component AGENTS.md" > "${agents_profile_dir}/inline.conf"
run_profile 250 "${agents_profile_dir}/inline.conf" false >/dev/null
assert_contains "scaffolding AGENTS.md symlinks CLAUDE.md to it" "$(mock_operations)" "ln -sf AGENTS.md CLAUDE.md"
assert_equal "CLAUDE.md resolves to AGENTS.md in the guest" "AGENTS.md" "$(readlink "${MOCK_GUEST_FS}/app/CLAUDE.md")"
: > "${MOCK_OPERATIONS_FILE}"
agents_rescaffold_output="$(run_profile 250 "${agents_profile_dir}/inline.conf" false)"
assert_contains "re-scaffolding AGENTS.md preserves an existing CLAUDE.md" "${agents_rescaffold_output}" "File '/app/CLAUDE.md' already exists, preserving it."
if [[ "$(mock_operations)" != *"ln -sf AGENTS.md CLAUDE.md"* ]]; then
  pass "re-scaffolding AGENTS.md does not recreate an existing CLAUDE.md symlink"
else
  fail "re-scaffolding AGENTS.md does not recreate an existing CLAUDE.md symlink"
fi
rm -rf "${agents_profile_dir}"

assert_failure "migration rejects a missing LXC" run_migrate 251 minimal --dry-run
assert_contains "missing migration only inspects the requested LXC" "$(mock_operations)" "inspect_lxc 251"
assert_failure "migration rejects an invalid profile" run_migrate 250 missing --dry-run

mock_lxc_set_hostname() {
  mock_record "set_hostname ${1:-} ${2:-}"
}
lxc_set_hostname() { mock_lxc_set_hostname "$@"; }

assert_success "migration dry-run accepts the default profile" run_migrate 250 --dry-run
assert_contains "migration dry-run lists profile modules" "$(mock_operations)" "inspect_lxc 250"
assert_success "migration dry-run accepts an explicit hostname" run_migrate 250 minimal --hostname new-server --dry-run
assert_contains "migration dry-run records hostname changes" "$(mock_operations)" "set_hostname 250 new-server"

migration_dry_run_output="$(run_migrate 250 minimal --dry-run)"
if [[ "${migration_dry_run_output}" != *"test-key"* ]]; then
  pass "migration dry-run does not leak SSH_PUBLIC_KEY from .env"
else
  fail "migration dry-run does not leak SSH_PUBLIC_KEY from .env"
fi
assert_contains "migration dry-run reports the key as unavailable" "${migration_dry_run_output}" "GitHub SSH public key: unavailable in dry run."
if [[ "${migration_dry_run_output}" != *"Add the SSH public key to GitHub"* ]]; then
  pass "migration dry-run does not suggest adding a key that wasn't found"
else
  fail "migration dry-run does not suggest adding a key that wasn't found"
fi
assert_contains "migration report uses the --user override, not the stale USER_NAME env value" \
  "$(run_migrate 250 minimal --user alice --hostname test-host --dry-run)" \
  "ssh alice@test-host"

DRY_RUN=false
assert_equal "migration prefers a non-Docker/Tailscale IP" "10.0.0.42" "$(migration_read_ip 250)"

MOCK_SSH_KEY_FILE=/home/marek/.ssh/id_ed25519.pub
assert_contains "VS Code Remote SSH entry connects via IP, not hostname" \
  "$(migration_print_report 250 minimal mock-host marek /app)" \
  'vscode-remote://ssh-remote+marek@10.0.0.42/app'

MOCK_SSH_KEY_FILE=/home/marek/.ssh/id_ed25519.pub
MOCK_SSH_KEY_CONTENT="ssh-ed25519 AAAAtestkey marek@lxc"
if migration_key_output="$(migration_print_public_key 250 marek)"; then
  migration_key_status=0
else
  migration_key_status=$?
fi
assert_contains "migration reads the guest's own id_ed25519.pub key" "${migration_key_output}" "ssh-ed25519 AAAAtestkey marek@lxc"
assert_equal "migration_print_public_key reports success when a key is found" "0" "${migration_key_status}"

MOCK_SSH_KEY_FILE=/home/marek/.ssh/id_rsa.pub
# shellcheck disable=SC2034  # MOCK_SSH_KEY_CONTENT is a global read by mock-backend.sh's guest_exec.
MOCK_SSH_KEY_CONTENT="ssh-rsa AAAAtestrsakey marek@lxc"
assert_contains "migration falls back to id_rsa.pub when id_ed25519.pub is absent" \
  "$(migration_print_public_key 250 marek)" "ssh-rsa AAAAtestrsakey marek@lxc"

MOCK_SSH_KEY_FILE=""
if migration_key_output="$(migration_print_public_key 250 marek)"; then
  migration_key_status=0
else
  migration_key_status=$?
fi
assert_contains "migration reports no key when none exists on the guest" "${migration_key_output}" "No SSH public key was found."
assert_equal "migration_print_public_key reports failure when no key is found" "1" "${migration_key_status}"
if [[ "${migration_key_output}" != *"authorized_keys"* && "${migration_key_output}" != *"test-key"* ]]; then
  pass "migration never reports the inbound authorized_keys/.env value as the personal key"
else
  fail "migration never reports the inbound authorized_keys/.env value as the personal key"
fi

# shellcheck disable=SC2317,SC2329  # This overrides the mock; it's invoked indirectly by run_migrate below (SC2317/SC2329 depending on shellcheck version).
lxc_is_running() { mock_record "check_running ${1:-}"; return 1; }
assert_failure "migration refuses to touch a stopped LXC" run_migrate 250 minimal
lxc_is_running() { mock_record "check_running ${1:-}"; [[ "${1:-}" == "250" ]]; }

DRY_RUN=false
assert_success "user module accepts dry-run after options" run_module user 250 --shell /bin/bash --dry-run
assert_contains "user dry-run records shell override" "$(mock_operations)" "usermod --shell /bin/bash marek"

MOCK_SSH_KEY_FILE=/home/marek/.ssh/id_ed25519.pub
: > "${MOCK_OPERATIONS_FILE}"
assert_success "user module runs with an existing personal SSH key" run_module user 250 --shell /bin/zsh
if [[ "$(mock_operations)" != *"ssh-keygen"* ]]; then
  pass "user module does not regenerate an existing personal SSH key"
else
  fail "user module does not regenerate an existing personal SSH key"
fi

# shellcheck disable=SC2034  # MOCK_SSH_KEY_FILE is a global read by mock-backend.sh's guest_exec/guest_file_exists.
MOCK_SSH_KEY_FILE=""
: > "${MOCK_OPERATIONS_FILE}"
assert_success "user module generates a personal SSH key when missing" run_module user 250 --shell /bin/zsh
assert_contains "user module runs ssh-keygen for the configured user" "$(mock_operations)" "-u marek -- ssh-keygen -t ed25519"
assert_contains "user module writes the key into the user's home directory" "$(mock_operations)" "-f /home/marek/.ssh/id_ed25519"
assert_success "locale module accepts dry-run after options" run_module locale 250 --timezone UTC --dry-run
assert_contains "locale dry-run records timezone" "$(mock_operations)" "ln -sf /usr/share/zoneinfo/UTC /etc/localtime"
assert_success "work-dir module accepts dry-run after options" run_module work-dir 250 --path /workspace --dry-run
assert_contains "work-dir dry-run records path override" "$(mock_operations)" "chown marek:marek /workspace"
assert_success "work-dir module accepts a --user override" run_module work-dir 250 --path /workspace --user alice --dry-run
assert_contains "work-dir dry-run honors --user, not the stale USER_NAME env value" "$(mock_operations)" "chown alice:alice /workspace"
assert_success "dry-run works before module options" run_module work-dir 250 --dry-run --path /workspace
: > "${MOCK_OPERATIONS_FILE}"
TAILSCALE_LOGIN_SERVER_LAN_IP=192.168.0.103 TAILSCALE_LOGIN_SERVER=https://hs.example.com:443/ \
  run_module tailscale 250 --dry-run >/dev/null
assert_contains "tailscale pins the login server host to its LAN IP" "$(mock_operations)" "192.168.0.103 hs.example.com  # skip ISP router hairpin NAT"
assert_contains "tailscale replaces a stale pin for the login server host" "$(mock_operations)" "sed -i -E '/[[:space:]]hs\.example\.com([[:space:]]|\$)/d' /etc/hosts"
# A logged-out guest whose `tailscale up` times out: the module must pass
# --timeout and report tailscale's error instead of hanging silently.
tailscale_up_output="$(
  # shellcheck disable=SC2317,SC2329  # Stubs invoked indirectly by configure_tailscale.
  guest_command_exists() { return 0; }
  # shellcheck disable=SC2317,SC2329
  guest_exec() {
    shift
    case "$*" in
      "systemctl is-active --quiet tailscaled") return 0 ;;
      "tailscale status") echo "Logged out."; return 1 ;;
      "tailscale up "*) echo "args: $*"; echo "timeout waiting for Tailscale service to enter a Running state" >&2; return 1 ;;
    esac
  }
  TAILSCALE_LOGIN_SERVER=https://hs.example.com configure_tailscale 250 2>&1
)" || true
assert_contains "tailscale up has a timeout instead of blocking forever" "${tailscale_up_output}" "--timeout=60s"
assert_contains "tailscale up failures relay tailscale's error" "${tailscale_up_output}" "timeout waiting for Tailscale service"
: > "${MOCK_OPERATIONS_FILE}"
run_module tailscale 250 --dry-run >/dev/null
if [[ "$(mock_operations)" != *"/etc/hosts"* ]]; then
  pass "tailscale leaves /etc/hosts alone without a LAN IP"
else
  fail "tailscale leaves /etc/hosts alone without a LAN IP"
fi
assert_failure "missing module option value fails" run_module work-dir 250 --path
assert_failure "unknown module option fails" run_module user 250 --does-not-exist

status_test_dir="$(mktemp -d)"
ACTION_LOG_FILE="${status_test_dir}/migrations.log"

DRY_RUN=true
log_action_record "migrate" 250 my-host minimal
assert_file_not_exists "log_action_record is a no-op during a dry run" "${ACTION_LOG_FILE}"
DRY_RUN=false

log_action_record "migrate" 250 my-host minimal
assert_file_exists "log_action_record creates the ledger file on first use" "${ACTION_LOG_FILE}"
assert_contains "log_action_record records the action, ctid, hostname and profile" \
  "$(cat "${ACTION_LOG_FILE}")" "$(printf 'migrate\t250\tmy-host\tminimal')"

log_action_record "configure" 250 renamed-host default
assert_equal "status tracks only the most recent action per ctid" \
  "250	configure	renamed-host	default" \
  "$(_status_last_action_per_ctid | cut -f1,3,4,5)"

pct() {
  if [[ "${1:-}" == "list" ]]; then
    printf '%s\n' \
      'VMID       Status     Lock         Name' \
      '250        running                 renamed-host' \
      '260        running                 fresh-host' \
      '270        stopped                 offline-host'
  fi
}

status_output="$(run_status)"
assert_contains "status lists a previously-migrated running LXC as migrated" "${status_output}" "$(printf '%-6s %-24s migrated' 250 renamed-host)"
assert_contains "status shows the last action, timestamp and profile for a migrated LXC" "${status_output}" "configure"
assert_contains "status flags a running LXC with no ledger entry as not migrated" "${status_output}" "$(printf '%-6s %-24s not migrated' 260 fresh-host)"
if [[ "${status_output}" != *"offline-host"* ]]; then
  pass "status omits stopped LXCs"
else
  fail "status omits stopped LXCs"
fi
unset -f pct

# Regression coverage for a shadowing bug: configurator.sh used to define its
# own run_configure() after sourcing lib/configure.sh, silently overriding it
# with a hand-rolled module loop that never split trailing profile-line
# options (e.g. `scaffold --component ...`) the way run_profile() does. Now
# that lib/configure.sh's run_configure() is the only definition and it
# delegates to run_profile(), exercise the option-forwarding fix directly
# against a minimal profile (a full real profile pulls in modules, like
# docker, that this mock backend doesn't model end-to-end).
configure_test_profile_dir="$(mktemp -d)"
printf '%s\n' 'scaffold --component .gitignore --component .claude' \
  > "${configure_test_profile_dir}/scaffold-only.conf"
profile_dir_before_test="${PROFILE_DIR}"
PROFILE_DIR="${configure_test_profile_dir}"

: > "${MOCK_OPERATIONS_FILE}"
ledger_lines_before_dry_run="$(wc -l < "${ACTION_LOG_FILE}")"
assert_success "configure dry-run succeeds for a profile with line options" \
  run_configure 250 scaffold-only --dry-run
assert_equal "configure dry-run does not touch the migration ledger" \
  "${ledger_lines_before_dry_run}" "$(wc -l < "${ACTION_LOG_FILE}")"

: > "${MOCK_OPERATIONS_FILE}"
DRY_RUN=false
assert_success "configure runs a profile with trailing module-line options" run_configure 250 scaffold-only
assert_contains "configure forwards trailing profile-line options to the module" \
  "$(mock_operations)" "/app/.gitignore"
if [[ "$(mock_operations)" != *"/app/README.md"* ]]; then
  pass "configure honors scaffold --component restrictions from the profile line"
else
  fail "configure honors scaffold --component restrictions from the profile line"
fi
assert_equal "configure records a ledger entry on success" \
  "250	configure" \
  "$(_status_last_action_per_ctid | cut -f1,3)"

PROFILE_DIR="${profile_dir_before_test}"
rm -rf "${configure_test_profile_dir}"
unset -f pct 2>/dev/null || true
rm -rf "${status_test_dir}"

# Regression coverage for the .env.example / secrets-guard deny-vs-allow bug:
# Claude Code's permission model lets a deny rule win over any allow rule, so
# a `.env.*`-style wildcard deny (matching `.env.example`, the one env file
# that must stay readable/editable) can never be un-blocked by adding an
# allow rule alongside it - the wildcard has to not be there in the first
# place. Both the static scaffold template and the secrets-guard module hit
# this; cover both.
_string_lacks() {
  [[ "$1" != *"$2"* ]]
}

static_settings_template="${ROOT_DIR}/templates/work-dir/.claude/settings.json"
assert_file_exists "scaffold template ships a .claude/settings.json" "${static_settings_template}"
assert_success "scaffolded settings.json has no .env.* wildcard deny that would also block .env.example" \
  _string_lacks "$(cat "${static_settings_template}")" ".env.*"
assert_contains "scaffolded settings.json explicitly allows .env.example" \
  "$(cat "${static_settings_template}")" '"Read(**/.env.example)"'

# The rest of this block exercises secrets-guard's real jq-based merge logic
# through the mock guest filesystem, which shells out to a real `jq` - skip
# gracefully if this machine doesn't have one installed rather than failing
# on an environment gap unrelated to the code under test.
if command -v jq >/dev/null 2>&1; then
  # shellcheck source=modules/system/secrets-guard.sh disable=SC1091
  source "${ROOT_DIR}/modules/system/secrets-guard.sh"
  DRY_RUN=false
  WORK_DIR=/app
  USER_NAME=marek
  configure_secrets_guard 250 >/dev/null
  secrets_guard_settings="$(cat "${MOCK_GUEST_FS}/app/.claude/settings.json")"
  assert_success "secrets-guard's generated settings.json has no .env.* wildcard deny that would also block .env.example" \
    _string_lacks "${secrets_guard_settings}" ".env.*"
  assert_contains "secrets-guard's generated settings.json still denies the real .env file" \
    "${secrets_guard_settings}" '"Read(**/.env)"'
  assert_contains "secrets-guard's generated settings.json allows .env.example" \
    "${secrets_guard_settings}" '"Read(**/.env.example)"'
  unset DRY_RUN
else
  printf '[SKIP] secrets-guard dynamic settings.json merge tests (jq not installed on this machine)\n' >&2
fi

# kopia-client: the client password must never reach an argv, the
# dry-run log or the module's output, and kopia's own error text must be shown.
# shellcheck source=modules/backup/kopia-client.sh disable=SC1091
source "${ROOT_DIR}/modules/backup/kopia-client.sh"
DRY_RUN=true
: > "${MOCK_OPERATIONS_FILE}"
kopia_dry_run_output="$(KOPIA_SERVER_URL=https://keep.test:51515 KOPIA_SERVER_CERT_FINGERPRINT=abc \
  KOPIA_CLIENT_PASSWORD=s3cr3t-kopia-pw configure_kopia_client 250 2>&1)"
unset DRY_RUN
assert_contains "kopia-client dry run still connects to the server" "$(mock_operations)" "repository connect server"
assert_success "kopia-client never passes the password as an argument" \
  _string_lacks "$(mock_operations)" "s3cr3t-kopia-pw"
assert_success "kopia-client never prints the password" \
  _string_lacks "${kopia_dry_run_output}" "s3cr3t-kopia-pw"
kopia_fail_output="$(_kopia_client_fail "Failed to connect." $'ERROR access denied\nsecond line' "a hint" 2>&1)"
assert_contains "kopia-client failures relay kopia's stderr" "${kopia_fail_output}" "kopia: ERROR access denied"
assert_contains "kopia-client failures relay every stderr line" "${kopia_fail_output}" "kopia: second line"
assert_contains "kopia-client failures print the hint" "${kopia_fail_output}" "a hint"
assert_contains "kopia-client points permission errors at keep's ACLs" \
  "$(_kopia_client_acl_hint "snapshot failed: Access Denied")" "keep README"
assert_equal "kopia-client gives no ACL hint for unrelated errors" "" "$(_kopia_client_acl_hint "connection refused")"

# kopia-client paths/excludes and the stdin password.
DRY_RUN=true
: > "${MOCK_OPERATIONS_FILE}"
kopia_stdin_output="$(printf 'pw-from-stdin\n' | KOPIA_SERVER_URL=https://keep.test:51515 \
  KOPIA_SERVER_CERT_FINGERPRINT=abc configure_kopia_client 250 --password-stdin true \
  --paths /app,/mnt/x/ --exclude '/app/sql,/mnt/x/y,/app/projects/*/postgres' 2>&1)"
unset DRY_RUN
assert_contains "kopia-client clears old excludes on every path" "$(mock_operations)" \
  "kopia policy set /mnt/x --keep-latest=7 --keep-daily=7 --keep-weekly=4 --keep-monthly=6 --clear-ignore"
assert_contains "kopia-client anchors excludes at the path they live under" "$(mock_operations)" \
  "kopia policy set /app --add-ignore=/sql --add-ignore=/projects/*/postgres"
assert_contains "kopia-client maps excludes to the right path" "$(mock_operations)" "kopia policy set /mnt/x --add-ignore=/y"
assert_success "kopia-client never passes a stdin password as an argument" \
  _string_lacks "$(mock_operations)" "pw-from-stdin"
assert_success "kopia-client never prints a stdin password" _string_lacks "${kopia_stdin_output}" "pw-from-stdin"
kopia_client_rejects() {
  (DRY_RUN=true KOPIA_SERVER_URL=u KOPIA_SERVER_CERT_FINGERPRINT=f KOPIA_CLIENT_PASSWORD=p \
    configure_kopia_client 250 "$@" >/dev/null 2>&1)
}
assert_failure "kopia-client rejects an exclude outside every path" kopia_client_rejects --paths /app --exclude /srv/x
assert_failure "kopia-client rejects a relative path" kopia_client_rejects --paths app
assert_failure "kopia-client rejects a glob in a backed-up path" kopia_client_rejects --paths '/app/*'
assert_failure "kopia-client requires a password" \
  bash -c "source '${ROOT_DIR}/lib/common.sh'; source '${ROOT_DIR}/lib/options.sh'; source '${ROOT_DIR}/modules/backup/kopia-client.sh'
    KOPIA_SERVER_URL=u KOPIA_SERVER_CERT_FINGERPRINT=f configure_kopia_client 250 --password-stdin true </dev/null >/dev/null 2>&1"

# kopia-enroll.sh, against a stub pct and configurator.
enroll_dir="${MOCK_ROOT}/enroll"
mkdir -p "${enroll_dir}"
printf '# ctid\thostname\tpaths\texclude\n250\talpha\t/app\t/app/sql\n251\tbeta\t/app,/mnt/b\t-\n' > "${enroll_dir}/clients.tsv"
cat > "${enroll_dir}/pct" <<'EOF'
#!/usr/bin/env bash
printf 'pct %s\n' "$*" >> "${ENROLL_LOG}"
[[ "$1 $3" == "exec --" ]] || exit 9
case "$2" in
  250) [[ "$4" == hostname ]] && echo alpha ;;
  251) [[ "$4" == hostname ]] && echo beta ;;
  112)
    if [[ "$*" == *"user list"* ]]; then echo "beta@beta"; fi
    if [[ "$*" == *"--user-password"* ]]; then printf 'keep-stdin %s\n' "$(cat)" >> "${ENROLL_LOG}"; fi ;;
  *) exit 1 ;;
esac
EOF
cat > "${enroll_dir}/configurator" <<'EOF'
#!/usr/bin/env bash
printf 'module-args %s\nmodule-stdin %s\n' "$*" "$(cat)" >> "${ENROLL_LOG}"
EOF
chmod +x "${enroll_dir}/pct" "${enroll_dir}/configurator"
run_enroll() {
  ENROLL_LOG="${enroll_dir}/log" KOPIA_CLIENTS_FILE="${enroll_dir}/clients.tsv" PCT="${enroll_dir}/pct" \
    CONFIGURATOR="${enroll_dir}/configurator" KOPIA_ENROLL_SKIP_ROOT_CHECK=1 KOPIA_ENROLL_RESTART_WAIT=0 \
    "${ROOT_DIR}/scripts/kopia-enroll.sh" "$@"
}
: > "${enroll_dir}/log"
enroll_output="$(run_enroll --all 2>&1)"
enroll_log="$(cat "${enroll_dir}/log")"
assert_contains "kopia-enroll adds a new user" "${enroll_log}" "sh add alpha@alpha"
assert_contains "kopia-enroll resets an existing user" "${enroll_log}" "sh set beta@beta"
assert_equal "kopia-enroll restarts keep's server once" "1" "$(grep -c 'docker compose restart' <<< "${enroll_log}")"
assert_contains "kopia-enroll passes a row's paths and excludes" "${enroll_log}" \
  "module-args module kopia-client 250 --password-stdin true --paths /app --exclude /app/sql"
assert_contains "kopia-enroll omits --exclude for '-'" "${enroll_log}" \
  "module-args module kopia-client 251 --password-stdin true --paths /app,/mnt/b"
alpha_password="$(sed -n 's/^keep-stdin //p' <<< "${enroll_log}" | head -1)"
assert_success "kopia-enroll generates a password" test -n "${alpha_password}"
assert_contains "kopia-enroll gives the module the password it set on keep" "${enroll_log}" "module-stdin ${alpha_password}"
assert_equal "kopia-enroll generates a different password per client" "2" \
  "$(sed -n 's/^keep-stdin //p' <<< "${enroll_log}" | sort -u | wc -l | tr -d ' ')"
assert_success "kopia-enroll never puts a password in an argv" \
  _string_lacks "$(grep '^pct ' <<< "${enroll_log}")" "${alpha_password}"
assert_success "kopia-enroll never prints a password" _string_lacks "${enroll_output}" "${alpha_password}"
assert_failure "kopia-enroll rejects a CTID with no row" run_enroll 299
printf '112\tkeep\t/app\t-\n' > "${enroll_dir}/keep.tsv"
assert_failure "kopia-enroll refuses to enroll keep itself" \
  env KOPIA_CLIENTS_FILE="${enroll_dir}/keep.tsv" KOPIA_ENROLL_SKIP_ROOT_CHECK=1 "${ROOT_DIR}/scripts/kopia-enroll.sh" 112
printf '250\tgamma\t/app\t-\n' > "${enroll_dir}/wrong.tsv"
assert_failure "kopia-enroll stops when a CTID's hostname does not match" \
  env KOPIA_CLIENTS_FILE="${enroll_dir}/wrong.tsv" ENROLL_LOG=/dev/null PCT="${enroll_dir}/pct" \
  KOPIA_ENROLL_SKIP_ROOT_CHECK=1 "${ROOT_DIR}/scripts/kopia-enroll.sh" 250
enroll_dry_run() {
  ENROLL_LOG=/dev/null PCT="${enroll_dir}/pct" CONFIGURATOR="${enroll_dir}/configurator" \
    KOPIA_ENROLL_SKIP_ROOT_CHECK=1 "${ROOT_DIR}/scripts/kopia-enroll.sh" --dry-run "$@"
}
mkdir -p "${enroll_dir}/custom" "${enroll_dir}/cwd" "${enroll_dir}/empty"
printf '250\talpha\t/srv/custom\t-\n' > "${enroll_dir}/custom/my clients.tsv"
assert_contains "kopia-enroll reads the file KOPIA_CLIENTS_FILE points at" \
  "$(KOPIA_CLIENTS_FILE="${enroll_dir}/custom/my clients.tsv" enroll_dry_run 250 2>&1)" "250: would set a new password"
assert_failure "kopia-enroll does not fall back to ./kopia-clients.tsv when KOPIA_CLIENTS_FILE is set" \
  bash -c "cd '${enroll_dir}/cwd' && cp '${enroll_dir}/clients.tsv' kopia-clients.tsv &&
    KOPIA_CLIENTS_FILE='${enroll_dir}/custom/my clients.tsv' ENROLL_LOG=/dev/null PCT='${enroll_dir}/pct' \
    CONFIGURATOR='${enroll_dir}/configurator' KOPIA_ENROLL_SKIP_ROOT_CHECK=1 \
    '${ROOT_DIR}/scripts/kopia-enroll.sh' --dry-run 251 >/dev/null 2>&1"
assert_success "kopia-enroll defaults to ./kopia-clients.tsv in the current directory" \
  bash -c "cd '${enroll_dir}/cwd' && ENROLL_LOG=/dev/null PCT='${enroll_dir}/pct' \
    CONFIGURATOR='${enroll_dir}/configurator' KOPIA_ENROLL_SKIP_ROOT_CHECK=1 \
    '${ROOT_DIR}/scripts/kopia-enroll.sh' --dry-run 251 >/dev/null 2>&1"
assert_contains "kopia-enroll names KOPIA_CLIENTS_FILE when no clients file is found" \
  "$(cd "${enroll_dir}/empty" && enroll_dry_run 250 2>&1)" "set KOPIA_CLIENTS_FILE"
# shellcheck disable=SC2016  # $0 is awk's, not this shell's.
assert_success "kopia-clients.tsv.example has four columns per row" \
  awk -F'\t' '!/^#/ && NF && NF != 4 {exit 1}' "${ROOT_DIR}/kopia-clients.tsv.example"

cli_command_passes() {
  "${ROOT_DIR}/configurator.sh" "$@" >/dev/null 2>&1
}

assert_success "CLI help is unprivileged" cli_command_passes help
assert_success "CLI version is unprivileged" cli_command_passes version
assert_success "CLI profile list is unprivileged" cli_command_passes profile list
assert_success "CLI module list is unprivileged" cli_command_passes module list
assert_contains "CLI module list shows descriptions" "$("${ROOT_DIR}/configurator.sh" module list)" "$(printf '%-22s %s' alloy 'Install Grafana Alloy')"
assert_success "CLI user help remains available" cli_command_passes module user --help
assert_success "CLI locale help remains available" cli_command_passes module locale --help
assert_success "CLI work-dir help remains available" cli_command_passes module work-dir --help
assert_success "CLI generated list is unprivileged" cli_command_passes generated list
assert_success "CLI migration help is unprivileged" cli_command_passes migrate --help
assert_failure "unknown CLI command fails" cli_command_passes unknown-command
assert_failure "invalid profile command fails" cli_command_passes profile invalid
assert_failure "missing generated script fails" cli_command_passes generated validate missing.sh

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  assert_failure "provisioning remains root-protected" cli_command_passes module base 250
  assert_failure "status remains root-protected" cli_command_passes status
fi

finish_tests
