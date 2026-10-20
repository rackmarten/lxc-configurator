# Changelog

All notable changes to `lxc-configurator`, the Bash-based provisioning and
configuration framework for Proxmox LXC containers, are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version is `CONFIGURATOR_VERSION` in `configurator.sh`.

## [Unreleased]

### Added
- `incinerator` policy key `mount` (default `/`): the filesystem whose usage
  the pressure pass compares with `threshold`, also logged as `mount`. Lets a
  WSL distro measure the Windows drive its virtual disk grows on instead of
  the virtual disk itself.
- `docker-mirror` module: points a guest's Docker daemon at a registry
  mirror (pull-through cache) set in `DOCKER_REGISTRY_MIRROR` or `--mirror`.
  It merges the mirror into `/etc/docker/daemon.json` without dropping
  existing keys, lists an `http://` mirror under `insecure-registries`,
  reloads Docker (no restart, so running containers keep running) and checks
  `docker info`. Runs after `docker` in the default profile and is a no-op
  when no mirror is set.

### Changed
- `.env.example` names foreman's own SSH key by fingerprint under
  `SSH_PUBLIC_KEY`, so a new container authorizes it next to the operator's
  key from the start.

### Fixed
- Docker no longer starts containers before Tailscale has taken over DNS on
  boot, which left them with the pre-Tailscale upstreams and unable to
  resolve MagicDNS names until restarted. When a guest has both Docker and
  Tailscale, the `docker` and `tailscale` modules install a `docker.service`
  drop-in (`10-wait-tailscale-dns.conf`) that orders Docker after
  `tailscaled` and waits up to 90s for `nameserver 100.100.100.100` in
  `/etc/resolv.conf`, then starts Docker either way.

## [0.1.0] - 2026-10-04

First public release.

### Added
- `incinerator` module: installs `/usr/local/sbin/incinerator` (bash + jq,
  installs `jq`) and `incinerator-daily.timer` (03:30 + up to 45m) /
  `incinerator-pressure.timer` (every 15 min, acts only at or above the
  policy threshold). Prunes unused docker images, build cache, stopped
  containers, optionally dangling anonymous volumes (named volumes never),
  vacuums journald, cleans apt, and ages/size-caps policy paths. Per-host
  policy in `/app/.homelab/incinerator.json`. Added to `profiles/default.conf`.
  Tests: `node --test tests/incinerator.test.mjs`.
- `modules/backup/kopia-client.sh`, modeled on the `alloy` module: installs
  the `kopia` binary via its apt repo, connects the client to a Kopia
  repository server as `<hostname>@<hostname>`, sets a retention policy, and
  installs/enables a daily systemd timer for snapshots. It takes `--paths`
  and `--exclude` (comma-separated, excludes may be globs) and
  `--password-stdin true`, and runs the repo's `/app/scripts/backup-dump.sh`
  before each snapshot when there is one.
- `scripts/kopia-enroll.sh`: enrolls LXCs as Kopia clients, each with its own
  generated password that is registered on the repository server and passed
  to the module over stdin, never printed or stored. It reads its clients
  file (per-host backup paths and excludes) from `$KOPIA_CLIENTS_FILE`,
  defaulting to `./kopia-clients.tsv` in the current directory (gitignored);
  `kopia-clients.tsv.example` has invented rows.
- Scaffold template `.homelab/deploy.json`, the repo's deploy declaration
  read by the maintainer's deploy tooling. Included in the `existing-project`
  profile too.
- `LXC_IP=auto` refuses a CTID outside `LXC_CTID_MIN`-`LXC_CTID_MAX`
  (100-149) rather than generating an address the router could also lease
  out. The floor is Proxmox's own minimum VMID; the ceiling tracks the
  router's DHCP pool, which is assumed to start at `.150`, so raising it
  means shrinking that pool first.
- `LXC_LAN_PREFIX` (default `192.168.0`) and `LXC_LAN_CIDR` (default `24`)
  make `auto` configurable; the prefix and `/24` were previously hardcoded
  in `lib/network.sh`.
- Tests covering `_resolve_create_ip`: CTID derivation, custom prefix, both
  range boundaries, three rejection cases, and that `dhcp` and explicit
  addresses still pass through untouched.
- README: "Addressing: a container's IP is its CTID", explaining the scheme,
  why the range bound exists, and the settings that control it.
- `tailscale` module: optional `TAILSCALE_LOGIN_SERVER_LAN_IP` pins the login
  server's hostname to its LAN address in the LXC's `/etc/hosts` before
  `tailscale up`. Without it, every LXC reached the control server (and its
  embedded DERP) via the public IP, and a router's hairpin NAT can drop those
  connections after ~30-60s idle, causing constant Tailscale reconnects.
- Leak check in CI: `.github/scripts/leak-check.sh` (vendored, do not edit
  here) runs with `--tree --log` against the org secret `LEAK_PATTERNS`, and
  `.leak-allow` lists the intentional exceptions. Without the secret it
  passes with a notice, except on the public org's own non-fork runs.
- MIT `LICENSE`, `CONTRIBUTING.md`, GitHub issue templates and a "Support this
  project" README section.

### Changed
- The `migrate`/`info` summary no longer asks to add the personal SSH key to
  GitHub. It labels it as a personal key and points at the README section
  "Deploying by push": the working directory receives a `git push` from a
  workstation (`receive.denyCurrentBranch=updateInstead`), so a container
  needs no GitHub access. The scaffolded README.md and AGENTS.md describe the
  same flow. The `user` module still generates the key.
- `LXC_IP` now defaults to `auto` instead of `dhcp`, for both `create` and
  `recipe`, so a new container gets `<LXC_LAN_PREFIX>.<CTID>` instead of a
  DHCP lease that changes whenever the router restarts.
- `alloy` module: journal lines with syslog identifier `incinerator` get a
  `syslog_identifier="incinerator"` Loki label (no other identifier is
  labelled, to keep stream count flat), so an alert can select on it.
- `KOPIA_CLIENT_PASSWORD` and `KOPIA_BACKUP_PATH` are gone from
  `.env.example`; a single shared client password is no longer the intended
  setup. The `kopia-client` module still reads both as a fallback.
- CI runs its checks inline on `ubuntu-latest` (gitleaks, `bash -n`,
  ShellCheck, yamllint, JSON, the compose template, both test suites).
- README rewritten for new users: what it is, requirements, quickstart and a
  module table first. Homelab-specific context moved to `AGENTS.md`, whose
  "Public repository, private homelab" section covers what a public reader
  needs.

### Fixed
- `kopia-backup.service` failed with "repository is not connected" the first
  time the systemd timer (or a manual `systemctl start`) fired, because
  systemd services get no `HOME` and `kopia` couldn't find its repository
  config. The unit now pins `Environment=HOME=/root` and passes
  `--config-file` explicitly, and the module runs and checks an initial
  snapshot during configuration, so this class of bug is caught at
  provisioning time.
- `kopia-client` prints Kopia's own error text on a failed connect, policy
  set or initial snapshot, with hints at the known causes (new server user
  not yet active, server ACLs missing Kopia's defaults), instead of a bare
  "Failed to ...".
- `kopia-client` reconnects a client whose stored server URL is not
  `KOPIA_SERVER_URL`, so re-running the module repairs a client after the
  server's address changes.
- `kopia-client` passes the client password to the guest over stdin; the
  dry-run log used to print it as part of the command line. Dry runs also no
  longer claim an existing connection or a failed initial snapshot.
- `tailscale`: `tailscale up` now has a timeout (`TAILSCALE_UP_TIMEOUT`,
  default `60s`) and prints tailscale's own error on failure. Before, an
  unreachable login server made it hang forever with no output.
- `tailscale`: an existing `/etc/hosts` pin for the login server that points
  at a different address is now replaced. Before, any existing line was
  kept, so a wrong pin (the control server's own address instead of the
  TLS-terminating proxy's) survived every re-run.
- CI's secret scan no longer flags the dummy kopia-client password in
  `tests/test.sh`: `.gitleaksignore` lists that fingerprint, and says what may
  and may not be added there.
- `tests/test.sh` no longer depends on a local `generated/minimal.sh`, and its
  expected module list includes `incinerator`, `kopia-client` and `kvm`.

[Unreleased]: https://github.com/rackmarten/lxc-configurator/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/rackmarten/lxc-configurator/releases/tag/v0.1.0
