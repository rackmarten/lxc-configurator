# LXC Configurator

[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-support-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/rackmarten)

Modular Bash provisioning and configuration for **Proxmox LXC containers**,
for anyone running a Proxmox host who wants new and existing containers set up
the same way every time, without one big monolithic script.

It runs on the Proxmox host and drives each container through `pct`: small,
idempotent modules (users, SSH, Docker, locale, scaffolding, ...) composed
into profiles, plus an interactive generator that writes reusable
provisioning scripts. Re-running anything is safe; existing files are
preserved, never overwritten.

## Requirements

* A Proxmox VE host, with root access for real provisioning (dry runs and
  the test suite run unprivileged)
* Bash 4.3 or newer, plus `pct`, `ip` and `ping` (all present on a stock
  Proxmox host)
* `whiptail` for interactive mode (`apt install whiptail`)
* Debian or Ubuntu guests; modules install what they need inside the guest

## Quickstart

On the Proxmox host:

```bash
git clone https://github.com/rackmarten/lxc-configurator.git
cd lxc-configurator
cp .env.example .env              # then edit: user, SSH key, network, ...

./configurator.sh module list     # what can be configured
./configurator.sh profile list    # predefined module sets

# Create a new container and configure it with the default profile
./configurator.sh create 120 default --hostname my-app --dry-run
./configurator.sh create 120 default --hostname my-app

# Or bring an existing container in line with a profile
./configurator.sh configure 121 minimal --dry-run
./configurator.sh configure 121 minimal

# Or run a single module
./configurator.sh module docker 121
```

`--dry-run` prints what would happen without touching the host or guest.
See [CLI](#cli) for every command.

## Modules

| Module | What it does |
| --- | --- |
| `alloy` | Install Grafana Alloy (ships the guest's journal and Docker logs to Loki) |
| `base` | Install base system packages |
| `docker` | Install Docker |
| `incinerator` | Install a local disk cleanup with daily and disk-pressure timers |
| `kopia-client` | Install and register a Kopia backup client |
| `kvm` | Pass `/dev/kvm` through for hardware-accelerated nested virtualization |
| `locale` | Configure locale and timezone |
| `scaffold` | Create the project scaffold and optionally initialize Git |
| `secrets-guard` | Scan the project for secrets and extend `.gitignore`/`.claude/settings.json` |
| `shell` | Configure the shell environment |
| `ssh` | Configure SSH security |
| `tailscale` | Configure Tailscale |
| `tun` | Configure TUN device access |
| `unattended-upgrades` | Configure unattended upgrades |
| `user` | Configure the primary user, groups, shell, SSH key and Git identity |
| `work-dir` | Configure the working directory |

`./configurator.sh module <name> --help` lists a module's options.

## Features

* Proxmox LXC validation and execution helpers
* Modular provisioning system and configuration profiles
* LXC creation, with a predictable address per container (IP derived from the CTID)
* Interactive provisioning generator using `whiptail`
* Generated configuration scripts, validated and versioned before execution
* Environment-based configuration (`.env`), overridable per module on the CLI
* Template rendering and project scaffolding; existing files are always preserved
* Scaffolded files/directories are chowned to the module user, never left root-owned
* Dynamic secret scanning: `.gitignore`/`.claude/settings.json` hardening based on the project's actual contents
* Kopia backup client enrollment (`scripts/kopia-enroll.sh`)
* Safe migration of existing LXCs using profiles
* `status` command: running LXCs vs. a local migration ledger, VMs excluded
* Dry-run mode for every provisioning command, and an unprivileged test suite

## Design Goals

The project is intentionally built around a few principles.

### Idempotency

Running a module multiple times should be safe.

A module should detect an already-configured state and avoid unnecessarily changing it.

For example:

```text
[INFO] User 'marek' already exists.
[INFO] User shell is already /bin/zsh.
[OK] User 'marek' configured.
```

### Existing data is more important than scaffolding

The scaffold module must never blindly overwrite files in an existing project.

If a scaffold target already exists, it is preserved:

```text
[INFO] File '/app/README.md' already exists, preserving it.
```

This is especially important when applying the configurator to an existing LXC containing an actual project.

### Modules should remain independent

Provisioning functionality belongs in modules rather than in the main CLI.

A module should generally expose:

```bash
configure_<module>()
```

and be executable through:

```bash
./configurator.sh module <module> <ctid>
```

### Configuration belongs in `.env`

Environment-specific values should not be hardcoded into modules.

The repository contains `.env.example` as the reference configuration.

The real `.env` is intentionally not committed.

Effective configuration uses this precedence:

1. Explicit module CLI option
2. Profile or recipe value, when supported
3. `.env` value
4. Module built-in default

### Templates are rendered before being copied

Files in the project scaffold can contain template variables.

The scaffold module renders the template before writing it into the guest.

## Repository Structure

```text
.
├── configurator.sh
├── .env
├── .env.example
├── README.md
├── AGENTS.md
│
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
│
├── modules/
│   ├── system/
│   └── ...
│
├── profiles/
│   └── *.conf
│
├── templates/
│   └── work-dir/
│
└── generated/
    └── *.sh
```

## Requirements

The configurator runs on the **Proxmox host**.

Required host functionality includes:

* Bash
* Proxmox `pct`
* `ip`
* `ping`
* `whiptail` for interactive mode

Some provisioning modules require additional tools inside the guest.

Install `whiptail` if interactive mode is unavailable:

```bash
apt install whiptail
```

## Environment Configuration

Copy the example environment file:

```bash
cp .env.example .env
```

Then adjust the values for your environment.

The `.env` file is loaded automatically by `configurator.sh`.

### Addressing: a container's IP is its CTID

`LXC_IP` defaults to `auto`, which derives the address from the CTID by using
it as the last octet: container 117 gets `192.168.0.117`. The point is that a
container's address is never something to look up, guess, or keep a list of -
if you know the CTID you know the IP, and vice versa.

This only works if your router hands out DHCP leases outside the container
range. The defaults assume a DHCP pool from `.150` upward, leaving `100-149`
for containers addressed this way, so `auto` refuses any CTID outside that
range rather than generating an address the router could also lease to
something else:

```
CTID 304 is outside 100-149, which --ip auto requires (the last octet is the
CTID). Pick a CTID in range, or pass an explicit --ip.
```

The floor of 100 is Proxmox's own minimum VMID, so it costs nothing. The
ceiling is the part to watch: it must stay below the router's DHCP pool, and
raising it means shrinking that pool on the router first. Adjust
`LXC_LAN_PREFIX`, `LXC_CTID_MIN`/`LXC_CTID_MAX` and `LXC_GATEWAY` to match
your network.

The relevant settings:

| Variable | Default | Meaning |
| --- | --- | --- |
| `LXC_IP` | `auto` | `auto`, `dhcp`, or an explicit `address/cidr` |
| `LXC_LAN_PREFIX` | `192.168.0` | first three octets `auto` builds on |
| `LXC_LAN_CIDR` | `24` | prefix length applied to an `auto` address |
| `LXC_CTID_MIN` | `100` | lowest CTID `auto` accepts |
| `LXC_CTID_MAX` | `149` | highest CTID `auto` accepts (stay below the DHCP pool) |
| `LXC_GATEWAY` | `192.168.0.1` | default route for any non-DHCP address |

Pass `--ip dhcp` for a throwaway container that does not need a predictable
address, or `--ip <address>/<cidr>` to place one outside the scheme entirely.

Example:

```dotenv
USER_NAME=marek
USER_PASSWORD=change-me

USER_SHELL=/bin/zsh
USER_GROUPS=sudo,docker

GIT_USER_NAME=Marek
GIT_USER_EMAIL=marek@example.com
GIT_DEFAULT_BRANCH=main

WORK_DIR=/app
WORK_DIR_PROJECT_NAME=my-project

WORK_DIR_SCAFFOLD_INIT_GIT=true

LOCALE=en_US.UTF-8
TIMEZONE=UTC
```

The exact variables supported by the current modules are documented below.

Module-specific options override `.env` values:

```bash
./configurator.sh module user 250 --shell /bin/bash --groups sudo,docker
./configurator.sh module locale 250 --locale en_GB.UTF-8 --timezone Europe/London
./configurator.sh module work-dir 250 --path /srv/my-project
```

Use `--help` after a module name to list its options.

Each module declares its own metadata in its module file. The required fields
are `MODULE_NAME`, `MODULE_DESCRIPTION`, `MODULE_SUPPORTS_DRY_RUN`, and
`MODULE_REQUIRES_ROOT`. `MODULE_DEPENDS` is reserved for future dependency
support. `module list` discovers these declarations directly from the module
files and validates them before displaying the list.

## CLI

Show help:

```bash
./configurator.sh help
```

Show the current version:

```bash
./configurator.sh version
```

List profiles:

```bash
./configurator.sh profile list
```

List provisioning modules:

```bash
./configurator.sh module list
```

Run a module:

```bash
./configurator.sh module base 250
```

Configure an existing LXC using a profile:

```bash
./configurator.sh configure 250 minimal
```

Perform a dry run:

```bash
./configurator.sh configure 250 minimal --dry-run
```

Dry-run mode does not require root and does not modify the host or guest. It
reports the guest and LXC operations that provisioning would request. Real
provisioning commands remain root-protected.

List currently running LXCs and see which ones this tool has already
touched:

```bash
./configurator.sh status
```

`status` reads `pct list`, so Proxmox VMs (a Home Assistant OS guest, for
example) never show up - `pct` and `qm` are separate namespaces and separate
tools, so containers and VMs can never collide by ID. Each running LXC is
then cross-referenced against a local action ledger (`output/migrations.log`,
gitignored) that `configure`, `migrate`, and `create` append to on every
successful, non-dry-run run, so a container is shown as already migrated
only once one of those commands has actually completed against it.

Run the unprivileged test suite:

```bash
./configurator.sh test
# or
./tests/test.sh
```

The tests use temporary directories and a small mock LXC backend. They never
call Proxmox commands or modify the host, `/etc`, or a real container.

Create a new LXC:

```bash
./configurator.sh create 250
```

Start interactive configuration:

```bash
./configurator.sh interactive 250
```

Generate equivalent CLI commands instead:

```bash
./configurator.sh interactive 250 --generate-cli-command
```

List generated scripts:

```bash
./configurator.sh generated list
```

Validate a generated script:

```bash
./configurator.sh generated validate generated/minimal.sh
```

Execute a generated script:

```bash
./configurator.sh execute generated/minimal.sh
```

Arguments passed to the generated script override its captured defaults:

```bash
./configurator.sh execute generated/minimal.sh 250 my-lxc
```

## Profiles

Profiles are lists of provisioning modules, one per line.

Example:

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

A module line may carry trailing options, exactly like the CLI. This is mainly useful for `scaffold`, to restrict which template components get scaffolded for that profile instead of the default of everything under `templates/work-dir/`:

```text
scaffold --component .gitignore --component .claude --component .editorconfig --component .vscode --component .github
```

See [`profiles/existing-project.conf`](profiles/existing-project.conf) for a complete example profile aimed at an LXC whose `/app` already holds a real project, where only the safety-net and tooling components (`.gitignore`, `.claude`, `.editorconfig`, `.vscode`, `.github`, and `.homelab`, a deploy declaration for external deploy tooling) should be scaffolded rather than the full human-facing template (`README.md`, `AGENTS.md`, `docker-compose.yml`, `scripts/`).

Lines starting with `#` are comments and blank lines are ignored.

A profile can then be applied with:

```bash
./configurator.sh configure 250 minimal
```

Profiles are intended to represent common LXC configurations.

Examples might eventually include:

```text
minimal
docker
development
monitoring
```

## Modules

Modules are discovered automatically from `modules/`.

A module named:

```text
modules/system/docker.sh
```

maps to:

```bash
configure_docker()
```

and can be executed with:

```bash
./configurator.sh module docker 250
```

Modules should:

* Validate their required configuration
* Be idempotent
* Use the shared guest/LXC helpers
* Avoid duplicating functionality already implemented elsewhere
* Produce useful log messages
* Fail clearly when configuration cannot be completed

## Template System

Templates are primarily used by the scaffold module.

Templates currently live under:

```text
templates/work-dir/
```

A template is rendered before being copied into the guest.

### Available Template Variables

The scaffold renderer currently exposes the following variables.

| Variable                | Description                             |
| ----------------------- | --------------------------------------- |
| `CTID`                  | Proxmox LXC container ID                |
| `HOSTNAME`              | Target LXC hostname                     |
| `WORK_DIR`              | Configured project working directory    |
| `USER_NAME`             | Configured primary user                 |
| `WORK_DIR_PROJECT_NAME` | Project name used by scaffold templates |

Example:

```text
Project: {{WORK_DIR_PROJECT_NAME}}
Container: {{CTID}}
Hostname: {{HOSTNAME}}
Owner: {{USER_NAME}}
Directory: {{WORK_DIR}}
```

`WORK_DIR_PROJECT_NAME` falls back to the hostname when it is not explicitly configured.

### Known issue: `${TIMEZONE}` in the work-dir README template

`templates/work-dir/README.md` references `${TIMEZONE}`, but `TIMEZONE` is not
one of the variables the scaffold renderer actually substitutes (see table
above) - the placeholder is copied through literally into every newly
scaffolded project's README instead of the configured timezone. Fix by hand
in the generated `README.md` until this is addressed at the source.

### Important

Template variables are rendered when the scaffold module runs.

A literal value that needs to survive into the generated project should therefore be escaped or otherwise protected according to the template renderer's supported syntax.

The template engine implementation in `lib/template.sh` is the authoritative source for supported rendering behavior.

## Scaffold

The scaffold module copies a predefined project structure into the configured working directory.

Example:

```bash
./configurator.sh module scaffold 250
```

By default, every top-level file and directory under `templates/work-dir/` is scaffolded - there is no fixed list to keep in sync with the template directory.

To scaffold a subset instead, select components explicitly:

```bash
./configurator.sh module scaffold 250 \
  --component .env.example \
  --component .gitignore
```

Directories are copied recursively.

Existing files are intentionally preserved.

For example:

```text
[INFO] File '/app/docker-compose.yml' already exists, preserving it.
```

This allows the scaffold module to be safely used against an existing project.

Scaffolding the `AGENTS.md` component also creates `CLAUDE.md` in the guest as
a real symlink to `AGENTS.md` (`ln -s AGENTS.md CLAUDE.md`), not a rendered
copy - Claude Code only auto-loads `CLAUDE.md`, not `AGENTS.md`, and a plain
copy would drift the moment `AGENTS.md` changes. Like every other scaffold
target, an existing `CLAUDE.md` is preserved rather than overwritten.

### Git

Git initialization can be enabled with:

```dotenv
WORK_DIR_SCAFFOLD_INIT_GIT=true
```

or explicitly:

```bash
./configurator.sh module scaffold 250 --git
```

An existing repository is preserved.

## Incinerator

The `incinerator` module installs a local disk cleanup: `/usr/local/sbin/incinerator` (bash + jq; the module installs `jq`) and the systemd units `incinerator-daily.timer` (03:30 plus up to 45 minutes random delay) and `incinerator-pressure.timer` (every 15 minutes). Sources live in `modules/system/incinerator/`. Files are only rewritten when their content changed, so re-running the module is a no-op on an up-to-date guest.

```bash
./configurator.sh module incinerator 250
```

In the guest:

```bash
incinerator --daily|--pressure [--dry-run] [--verbose]
journalctl -t incinerator          # one JSON line per run: usage before/after, bytes freed per category, errors
```

The `alloy` module labels these lines `syslog_identifier="incinerator"` in Loki, so an alert can select on them (for example, one that fires when a host's cleanup has gone silent).

`--pressure` does nothing unless `/` usage is at or above the policy threshold. The per-host policy is `/app/.homelab/incinerator.json` (built-in defaults without it; an invalid file burns nothing). `DEFAULT_POLICY` near the top of `modules/system/incinerator/incinerator` shows every policy key. Tests: `node --test tests/incinerator.test.mjs`.

## Secrets Guard

The `secrets-guard` module scans the actual contents of `WORK_DIR` and hardens the project accordingly, instead of relying on a fixed, static template.

Example:

```bash
./configurator.sh module secrets-guard 250
```

It does three things:

1. **Extends `.gitignore` dynamically.** If a `docker-compose.yml`/`compose.yml` is present, its relative bind-mounted volume paths (e.g. `./data/mail`) are added to `.gitignore`, but only when that directory actually exists on disk. Well-known secret filenames (`id_rsa`, `.npmrc`, `.netrc`, `.pgpass`, `credentials.json`, `secrets.{json,yaml,yml}`, ...) found anywhere in the project are added the same way.
2. **Extends the committed `.claude/settings.json`.** A baseline `permissions.deny` list always covers the literal `.env` file for the `Read`/`Edit` tools, plus best-effort `Bash` rules for the literal `cat .env`/`rg .env`/`shellcheck .env` invocations, alongside a baseline `permissions.allow` entry that keeps `.env.example` itself readable/editable (deny rules always win over allow rules, so the baseline deliberately never uses a `.env.*` wildcard that would also catch `.env.example`). Any well-known secret file actually found in the project gets its own `Read`/`Edit`/`Bash` deny rules by its real path. Existing settings are merged, never overwritten.
3. **Flags hardcoded credentials already committed.** If a `docker-compose.yml` is tracked by Git, lines that look like a literal (non-`${VAR}`) password/secret/token/API key value are reported as warnings so a human moves them into `.env` before the repo is pushed anywhere.

The `Bash` deny rules are best-effort only: they block the exact `cat .env`/`rg .env`/`shellcheck .env` invocations shown in the deny list but cannot catch every way to read a file via Bash (other readers, absolute paths, `rg` with a variable search pattern before the filename, scripted access, etc). Treat them as a speed bump, not a guarantee.

## Kopia Backup Clients

The `kopia-client` module makes an LXC a backup client of a Kopia repository
server that itself runs in an LXC (`KEEP_CTID`, default `112`, with Kopia in
a Docker Compose service `KEEP_SERVICE`, default `kopia`, under
`KEEP_APP_DIR`, default `/app`). It installs `kopia`, connects as
`<hostname>@<hostname>`, sets retention and excludes, and installs a daily
`kopia-backup.timer` (03:00, up to 30 minutes random delay).

Don't run the module by hand for a new client. Describe your clients in a
clients file and run the enroll script as root on the Proxmox host instead:

```bash
cp kopia-clients.tsv.example kopia-clients.tsv   # then list your own LXCs
./scripts/kopia-enroll.sh --dry-run 130 131      # shows what would happen
./scripts/kopia-enroll.sh 130 131
./scripts/kopia-enroll.sh --all                  # every row in the file

# Or keep the clients file elsewhere (e.g. next to your Kopia server's config):
KOPIA_CLIENTS_FILE=/path/to/kopia-clients.tsv ./scripts/kopia-enroll.sh --all
```

The clients file is `$KOPIA_CLIENTS_FILE`, or `./kopia-clients.tsv` in the
current directory when that is unset (gitignored here, so your inventory
never ends up in this repo).

For each CTID it generates a random password, registers or resets the user
on the server (`kopia server user add`/`set`, inside the server's container),
restarts the Kopia server once, then runs the module with that row's paths
and excludes. The password is passed over stdin and is never printed, stored
on the host or put on a command line. It lives only in the client's
`/root/.config/kopia/repository.config`. Each client has its own password,
so a compromised LXC cannot log in as another client and delete that
client's snapshots. To repair or rebuild a client, enroll it again. That
sets a new password.

Each row of the clients file is the per-host scope: CTID, hostname,
comma-separated paths, and comma-separated excluded paths (globs allowed,
`-` for none); see `kopia-clients.tsv.example`. The script refuses a CTID
whose actual hostname differs from its row. Excludes become Kopia ignore
rules anchored at the path they live under (`/app/sql` under `/app` becomes
`/sql`). Re-running replaces a client's excludes; it does not add to them.

**Databases.** A file copy of a running database (a Postgres data dir, or a
SQLite file in WAL mode) is not a reliable backup. If
`/app/scripts/backup-dump.sh` exists and is executable,
`kopia-backup.service` runs it (`ExecStartPre`) before every snapshot. The
project's script dumps its database into `/app/backups/`, and the live files
are excluded in the clients file (for SQLite, use its online backup API
rather than copying the file). A store kept outside the snapshot paths needs
no exclude; only its dumps in `/app/backups` are snapshotted. A failing dump
fails the whole run, so the missing backup shows up as a stale snapshot and
is never silently incomplete. Check a client with
`systemctl status kopia-backup.service` and
`journalctl -u kopia-backup.service` inside the LXC.

## Generated Configuration Scripts

Interactive configuration can generate a standalone provisioning script.

Example:

```bash
./configurator.sh interactive 250
```

The generated script contains:

* Configurator version
* Recipe format version
* Generation timestamp
* Default CTID
* Default hostname
* Selected profile or modules

Example:

```bash
./configurator.sh execute generated/minimal.sh 250 my-lxc
```

Generated scripts are validated before execution.

Validation includes:

* File location
* Executable bit
* Bash shebang
* Bash syntax
* Configurator version metadata
* Recipe format metadata

Generated scripts are intended to be reproducible artifacts that can be stored alongside infrastructure configuration.

## Current Status

### Implemented

* [x] Modular provisioning architecture
* [x] Profiles
* [x] LXC helper layer
* [x] Guest helper layer
* [x] LXC creation
* [x] Network configuration
* [x] Environment configuration
* [x] Template rendering
* [x] Project scaffolding
* [x] Idempotent scaffold behavior
* [x] Scaffolded output is never left root-owned
* [x] Dynamic secret scanning (gitignore + `.claude/settings.json` hardening)
* [x] Interactive configuration
* [x] Generated scripts
* [x] Generated script validation
* [x] Script/configurator version metadata
* [x] Recipe format metadata
* [x] Basic provisioning modules

### Planned

The project is still actively evolving. Planned improvements include:

* [ ] More robust recipe representation
* [ ] Better generated-script inspection
* [x] Safe dry-run support
* [ ] Better validation of module configuration
* [ ] Improved error reporting and execution summaries
* [ ] More reusable template functionality
* [ ] More provisioning modules
* [x] Lightweight unprivileged testing infrastructure
* [x] ShellCheck integration (CI)
* [ ] Automated integration tests using disposable LXCs
* [ ] Better documentation for individual modules
* [ ] Versioned recipe compatibility handling
* [x] Safer handling of secrets during provisioning (baseline `.env` guard + dynamic scan; not exhaustive)

The roadmap is intentionally flexible and should reflect the actual state of the project rather than promising a fixed release schedule.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for running the tests and ShellCheck,
the module layout, and commit conventions.

When adding a module, test both:

1. First execution against a clean, disposable LXC.
2. Second execution against the already-configured LXC.

The second execution should not unnecessarily modify the system.

## Safety

This tool performs system-level operations on Proxmox and inside LXC containers.

Always test changes against a disposable container before applying them to important infrastructure.

In particular:

* Review `.env` before provisioning.
* Do not commit secrets. The `secrets-guard` module helps catch common cases, but it is a best-effort scan, not a guarantee.
* Be careful when changing SSH configuration.
* Be careful when modifying network configuration.
* Test provisioning modules independently before adding them to a profile.
* Treat generated scripts as executable infrastructure code.

## Support this project

If LXC Configurator saves you time, you can support its development on
[Ko-fi](https://ko-fi.com/rackmarten):

[![Support on Ko-fi](https://img.shields.io/badge/Ko--fi-support-FF5E5B?logo=kofi&logoColor=white)](https://ko-fi.com/rackmarten)

Bug reports, ideas and pull requests
are just as welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT. See [LICENSE](LICENSE).
