# AGENTS.md

## Project Overview

`lxc-configurator` is a Bash-based provisioning and configuration framework for Proxmox LXC containers.

The project is designed around:

* small, composable provisioning modules
* reusable host/guest helper libraries
* configuration profiles
* generated configuration scripts
* interactive configuration
* reusable project scaffolding templates
* idempotent operations
* explicit validation
* safe-by-default behavior

The primary goal is to make LXC provisioning **repeatable, understandable, safe, and maintainable**.

---

## Core Engineering Principles

### 1. Safety first

The configurator operates against real infrastructure. Assume every LXC may contain important data.

**Never perform destructive actions unless the user explicitly requested that exact destructive action.**

Destructive actions include, but are not limited to:

* deleting files or directories
* recursively removing directories
* deleting containers
* recreating containers
* overwriting existing configuration
* resetting configuration
* purging packages
* removing users
* replacing existing project files
* destroying Git history
* resetting Git repositories
* modifying unrelated host configuration
* changing firewall/network rules in a destructive way
* stopping/restarting services when it is not necessary
* changing permissions in a way that could remove existing access

Do not infer permission from context.

For example:

* A container named `test`, `dev`, `temporary`, or `throwaway` is **not automatically disposable**.
* A CTID that looks like a test CTID is **not automatically disposable**.
* A user saying "I'm testing this" does **not** authorize deleting infrastructure.
* A development environment is still treated as persistent unless explicitly stated otherwise.

### Explicit throwaway LXC exception

Destructive operations may be used when the user **explicitly identifies the target LXC as a throwaway/disposable container and explicitly requests or authorizes destructive testing against it**.

The authorization applies only to the explicitly identified container and only for the requested testing purpose.

Do not extend that authorization to:

* other containers
* the Proxmox host
* other filesystems
* other projects
* production resources

When in doubt, stop and ask rather than destroy.

---

## 2. Prefer preservation over replacement

Existing user data always takes precedence over generated defaults.

Provisioning should normally follow this pattern:

```text
does the resource exist?
    |
    +-- yes --> preserve it
    |
    +-- no ---> create it
```

This is especially important for project scaffolding.

Never replace an existing project file merely because a newer template exists.

For example:

```text
/app/docker-compose.yml
/app/README.md
/app/.env.example
/app/scripts/deploy.sh
```

must be preserved if they already exist.

If a future feature needs template synchronization, it must be implemented as an explicit opt-in operation with appropriate safety checks.

---

## 3. Idempotency

Provisioning modules must be safe to execute repeatedly.

Running:

```bash
./configurator.sh module <module> <ctid>
```

multiple times should converge on the desired state rather than progressively modifying or damaging the system.

Prefer:

```text
already configured -> report -> continue
missing -> configure
incorrect -> change only what is necessary
```

Avoid unconditional operations when state can be inspected first.

Good:

```bash
if user_exists; then
    log_info "User already exists."
else
    create_user
fi
```

Avoid blindly recreating users, files, repositories, configuration, or services.

## Configuration and module options

Effective configuration follows this order: explicit module CLI option, supported profile or recipe value, `.env` value, then the module's built-in default. Modules should use the shared helpers in `lib/options.sh` rather than duplicating precedence logic.

Module commands retain the form `module <name> <ctid> [options]`. Each module parses only its own options, rejects unknown options and missing values, and validates resolved values before making changes. Option values must remain quoted and array-based so spaces are preserved; comma-separated values use the shared list helper.

Migrated modules currently support `user` (`--user`, `--shell`, `--groups`), `locale` (`--locale`, `--timezone`), and `work-dir` (`--path`, `--user`). Existing `.env` defaults and profile calls remain valid when no options are supplied.

---

## 4. Validate before changing state

Validate inputs before performing any side effects.

Examples:

* CTID
* IP address
* CIDR
* gateway
* bridge
* hostname
* username
* profile name
* module name
* template path
* generated script path
* script name
* configuration values

Prefer dedicated validation helpers over duplicated validation logic.

Invalid input should fail early with a useful error message.

---

# Architecture

## Repository structure

The project follows this general structure:

```text
lxc-configurator/
├── configurator.sh
├── .env
├── .env.example
├── AGENTS.md
├── README.md
├── lib/
│   ├── common.sh
│   ├── configure.sh
│   ├── create.sh
│   ├── generated.sh
│   ├── guest.sh
│   ├── interactive.sh
│   ├── lxc.sh
│   ├── lxc_config.sh
│   ├── module.sh
│   ├── network.sh
│   ├── profile.sh
│   ├── recipe.sh
│   ├── status.sh
│   ├── template.sh
│   └── version.sh
├── modules/
│   └── ...
├── profiles/
│   └── *.conf
├── templates/
│   └── ...
├── generated/
│   └── ...
└── tests/
    └── ...
```

Do not introduce another abstraction layer unless there is a concrete reason for it.

Reuse existing helpers before creating new ones.

---

# Bash Standards

All Bash scripts should normally use:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
```

Use:

```bash
local variable="${1:-}"
```

for function-local variables.

Always quote variable expansions unless intentional word splitting is required.

Prefer:

```bash
"${variable}"
```

over:

```bash
${variable}
```

Use arrays when handling lists of values.

Avoid parsing structured data with fragile text manipulation when a reliable interface exists.

Avoid unnecessary subshells.

Avoid global mutable state unless it is part of an intentional project-level interface.

Functions should have one clear responsibility.

---

# Error Handling

Failures must be visible.

Use the project's logging helpers:

```bash
log_info
log_success
log_warn
log_error
fatal
```

Expected failure paths should return meaningful non-zero status codes.

Unexpected failures should not be silently swallowed.

Avoid patterns such as:

```bash
command || true
```

unless ignoring the failure is intentional and documented by the surrounding logic.

If a failure is intentionally ignored, make the reason obvious.

---

# Logging

Use concise, useful messages.

Preferred:

```text
[INFO] Configuring user 'marek'...
[INFO] User 'marek' already exists.
[OK] User 'marek' configured.
```

Avoid excessive logging of implementation details.

Never log:

* passwords
* private keys
* tokens
* API secrets
* credentials
* `.env` secret values

Logs should explain **what is happening**, not dump every command.

---

# Host vs Guest Operations

Keep the distinction between Proxmox host operations and guest operations clear.

### Host-side operations

Use the LXC/Proxmox helper layer for operations involving:

* `pct`
* LXC configuration
* container state
* host-side device configuration
* host networking

### Guest-side operations

Use the guest helper layer for commands executed inside an LXC.

Do not duplicate `pct exec` handling throughout modules.

Prefer:

```bash
guest_exec "${ctid}" command ...
```

over implementing custom `pct exec` wrappers inside every module.

Similarly, use existing guest filesystem helpers for file operations.

---

# Provisioning Modules

Each provisioning module should expose:

```bash
configure_<module>()
```

Module filenames should use the established naming convention.

For example:

```text
modules/system/base.sh
```

provides:

```bash
configure_base()
```

A module should:

1. validate required configuration
2. validate the target LXC where necessary
3. inspect existing state
4. make only necessary changes
5. remain idempotent
6. provide useful logging
7. return failure when configuration cannot be completed

Modules should be independently executable.

Example:

```bash
./configurator.sh module docker 250
```

Do not make modules depend on being executed only through a particular profile unless that dependency is explicitly part of the architecture.

---

# Profiles

Profiles are compositions of modules.

A profile should describe **what should be configured**, not contain provisioning implementation.

For example:

```text
tun
base
locale
user
work-dir
scaffold
secrets-guard
ssh
```

A module line may carry trailing options, forwarded verbatim to that module's CLI parsing (same syntax as `./configurator.sh module <name> <ctid> [options]`):

```text
scaffold --component .gitignore --component .claude
```

This exists specifically so a profile can declare which template components `scaffold` should place, rather than always scaffolding everything under `templates/work-dir/`. See `profiles/existing-project.conf`.

Do not duplicate module implementation inside profiles.

If multiple profiles require the same behavior, create or reuse a module.

---

# Templates

Templates are project scaffolding, not provisioning logic.

Templates may contain project files such as:

```text
.env.example
.gitignore
.editorconfig
README.md
AGENTS.md
docker-compose.yml
scripts/
.vscode/
```

Template files may contain supported template variables.

Templates must not contain secrets.

Scaffolding the `AGENTS.md` component also creates `CLAUDE.md` in the guest as a real symlink to `AGENTS.md` (Claude Code only auto-loads `CLAUDE.md`), never a rendered duplicate. This is implemented as a `guest_exec` side effect in `modules/system/scaffold.sh`, not a file under `templates/work-dir/`, because copying a symlinked template file would dereference it and write a disconnected copy. Same preserve-existing-file safety as every other scaffold target.

---

# Template Variables

The template renderer provides values used by project scaffolding.

Currently supported variables include:

| Variable                | Meaning                              |
| ----------------------- | ------------------------------------ |
| `CTID`                  | Target LXC container ID              |
| `HOSTNAME`              | Target LXC hostname                  |
| `WORK_DIR`              | Configured project working directory |
| `USER_NAME`             | Configured primary user              |
| `WORK_DIR_PROJECT_NAME` | Project name; falls back to hostname |

Example:

```text
Project: {{WORK_DIR_PROJECT_NAME}}
Container: {{CTID}}
Hostname: {{HOSTNAME}}
User: {{USER_NAME}}
Directory: {{WORK_DIR}}
```

Template syntax must follow the implementation in `lib/template.sh`.

When adding a new template variable:

1. update the renderer/interface
2. document it in `README.md`
3. document it here if it is part of the supported public template API
4. add tests
5. ensure missing values behave predictably

Do not silently expose secrets through template variables.

---

# Scaffold Safety

Scaffolding is intentionally conservative.

When a target file already exists:

```text
preserve it
```

When a target directory already exists:

```text
preserve it
```

New files may be created.

Existing files must not be overwritten automatically.

This protects project-specific logic from being destroyed by rerunning the configurator.

Any future "force", "overwrite", "sync", or "reset" functionality must be explicit and must include appropriate safety validation.

---

# Generated Scripts

Generated scripts are executable artifacts produced by the interactive generator.

They should be:

* human-readable
* deterministic where practical
* executable
* syntax-valid
* versioned
* associated with the recipe format version
* validated before execution

Generated scripts should contain enough metadata to determine which configurator version created them.

Do not silently execute malformed generated scripts.

Do not silently ignore configurator version incompatibility.

Generated scripts must not embed secrets.

---

# Interactive Generator

The interactive interface should be a frontend over the same underlying configuration mechanisms used by the CLI.

Interactive choices should result in equivalent CLI operations.

The generator should:

1. validate input
2. collect configuration
3. generate a reusable script
4. allow safe handling of existing generated files
5. avoid executing the generated script automatically unless explicitly designed and requested

The generated script should remain understandable to a human administrator.

---

# Recipes

Recipes represent reusable configuration workflows.

Recipes should compose existing functionality rather than reimplementing provisioning logic.

Prefer:

```text
recipe
  -> profile/module
      -> reusable helper
```

rather than:

```text
recipe
  -> duplicated shell commands
```

Recipe format changes must be versioned.

---

# Security Rules

Treat all external input as untrusted.

This includes:

* CLI arguments
* environment variables
* `.env` values
* template values
* profile contents
* recipe contents
* filenames
* hostnames
* usernames
* IP addresses

Never construct shell code from unvalidated input.

Avoid:

```bash
eval "${user_input}"
```

Do not use shell evaluation as a substitute for proper argument handling.

Prefer arrays and quoted arguments.

Example:

```bash
command_args=(
    --bridge
    "${bridge}"
    --hostname
    "${hostname}"
)

some_command "${command_args[@]}"
```

Do not expose credentials in command output.

Do not place passwords or private keys in generated scripts.

---

# File Permissions

Use the least permissive reasonable permissions.

When creating configuration files:

* consider whether the file contains secrets
* use restrictive permissions for sensitive files
* use normal project-readable permissions for non-sensitive files

Do not blindly apply broad permissions such as:

```bash
chmod 777
```

unless there is an exceptional, explicitly justified reason.

---

# Package Management

Package installation should be idempotent.

Do not repeatedly reinstall packages that are already present.

Avoid package removal or purging unless explicitly requested.

Be especially careful with package cleanup because removing apparently unused packages can remove dependencies required by unrelated software.

Long-running package operations should eventually provide appropriate feedback or timeout handling where practical.

---

# Service Management

Do not restart or stop services unnecessarily.

Before changing service state, determine whether the change is actually required.

Do not disable unrelated services.

When a service is already correctly configured, leave it alone.

---

# Networking

Network changes are potentially disruptive.

Validate:

* bridge names
* IP addresses
* CIDRs
* gateways
* interfaces

Avoid modifying host networking unless explicitly required by the feature.

Never assume an automatically selected IP is safe merely because it looks unused.

Where practical, perform both local/interface checks and network availability checks.

---

# Testing

AI agents and developers should run:

```bash
./configurator.sh test
```

before and after significant changes, along with Bash syntax validation for
modified scripts. Normal development and testing must not request or assume
root privileges. Use unit tests, the mock LXC backend, temporary directories,
and dry-run mode instead.

Real LXC provisioning is an integration test for a human operator. Never run
automated provisioning against an arbitrary real LXC; only a human may
explicitly designate a throwaway LXC for that purpose.

Before considering a change complete, run at minimum:

```bash
bash -n configurator.sh
```

and syntax-check every modified Bash file.

Preferably run:

```bash
bash -n <all modified .sh files>
```

and, when available:

```bash
shellcheck <modified files>
```

Tests should cover:

* validation helpers
* template rendering
* generated script validation
* module discovery
* profile parsing
* error paths
* idempotent behavior
* destructive-action safeguards

Tests must not destroy real infrastructure.

Use mocks, temporary directories, fixtures, or explicitly authorized disposable LXCs.

---

# Testing Against Real LXCs

Real LXC testing is allowed only when the target has been explicitly identified as an appropriate test environment.

Never assume that a test-looking container is disposable.

For destructive integration tests, the user must explicitly authorize the target as a throwaway/disposable LXC.

A test must not:

* delete another container
* modify unrelated containers
* alter the Proxmox host unnecessarily
* destroy unrelated project data
* modify production services

Prefer creating a fresh disposable test container when destructive integration testing is required.

---

# Public repository, private homelab

This repository is published under the MIT license. The maintainer's homelab
uses it, but homelab-specific state does not live here. Keep it that way:

* No private inventory: CTIDs, hostnames and backup paths of real containers,
  internal task numbers, private domains or email addresses. Examples use
  invented values (`kopia-clients.tsv.example`). RFC1918 defaults such as
  `192.168.0.x` and the `10.0.0.42` test fixtures are fine.
* No links to private repositories in docs. CI is self-contained
  (`.github/workflows/security-check.yml`, GitHub-hosted runner), because a
  public repo cannot call a reusable workflow in a private one.
  `templates/work-dir/.github/workflows/security-check.yml` is different: it is
  scaffolded into the maintainer's private service repos and calls the org's
  private reusable workflow on purpose. Leave it as is.

Why some defaults look the way they do:

* **Addressing.** `LXC_IP=auto` (last octet == CTID, CTIDs 100-149) assumes the
  router's DHCP pool starts above the guest range (e.g. at `.150`).
* **`.homelab/deploy.json`.** The scaffolded deploy declaration is read by the
  maintainer's deploy tooling; it is inert for anyone else.
* **Kopia.** `kopia-enroll.sh`'s `KEEP_*` defaults point at the maintainer's
  Kopia repository server. Override them, and point `KOPIA_CLIENTS_FILE` at
  your own clients file (see `kopia-clients.tsv.example`).

Before pushing, the leak check in CI (`.github/scripts/leak-check.sh`, run
with `--tree --log`) must pass. Its patterns are private and reach CI as the
org's `LEAK_PATTERNS` secret; a hit prints only an opaque id and a location.
`.leak-allow` lists the few intentional exceptions (`<path-glob>:<id>`).
Rephrase a hit rather than allowlisting it unless it is functional
configuration. The script is a vendored copy: change it upstream, not here.

---

# Repository Hygiene

Do not commit:

* `.env` containing secrets
* SSH private keys
* generated credentials
* tokens
* passwords
* machine-specific secrets
* temporary test artifacts

Generated scripts should only be committed when the repository intentionally treats them as source artifacts.

Temporary/generated runtime output should normally be ignored by Git. This includes the local action ledger (`output/migrations.log`, written by `log_action_record()` in `lib/status.sh`) that the `status` command reads to compare currently running LXCs against what `configure`/`migrate`/`create` have already touched.

---

# Documentation

When behavior changes, update the relevant documentation.

At minimum consider:

* `README.md`
* `AGENTS.md`
* module help output
* `.env.example`
* template variable documentation

Documentation should describe actual implemented behavior, not planned behavior as if it already existed.

Clearly distinguish:

```text
Implemented
Planned
Experimental
```

---

# Change Strategy

When implementing a feature:

1. Inspect the existing architecture.
2. Find existing helpers that can be reused.
3. Identify validation and safety implications.
4. Make the smallest coherent change.
5. Avoid unrelated refactoring.
6. Preserve existing behavior unless the task explicitly changes it.
7. Make the implementation idempotent.
8. Add or update tests.
9. Run syntax validation.
10. Review the diff for accidental destructive behavior.
11. Update documentation if the public behavior changed.

Do not rewrite functioning code simply because another implementation looks cleaner.

---

# Definition of Done

A change is not considered complete merely because the code works once.

Before declaring it complete, verify:

* [ ] Bash syntax is valid.
* [ ] Inputs are validated.
* [ ] Existing data is preserved.
* [ ] The implementation is idempotent.
* [ ] No unnecessary destructive operations were introduced.
* [ ] No secrets are exposed.
* [ ] Existing helpers are reused where appropriate.
* [ ] Errors are handled explicitly.
* [ ] Logs are useful and do not leak sensitive information.
* [ ] Generated artifacts are valid when applicable.
* [ ] Tests pass where applicable.
* [ ] Documentation reflects the actual implementation.

## AI Agent Behavior

When working on this repository, prioritize:

1. **Safety**
2. **Correctness**
3. **Preservation of existing state**
4. **Security**
5. **Idempotency**
6. **Reusability**
7. **Maintainability**
8. **Minimal complexity**

If a requested implementation conflicts with these principles, point out the conflict before making a potentially dangerous change.

If there is uncertainty about whether an operation is destructive, assume that it is and do not perform it without explicit authorization.

If the user explicitly authorizes destructive testing against a named throwaway LXC, limit destructive behavior strictly to that target and requested test.

Never broaden destructive authorization implicitly.
