# Changelog

Notable changes to `lxc-configurator`, the Bash-based provisioning and
configuration framework for Proxmox LXC containers. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) (Added/Changed/
Fixed/Removed), grouped by date rather than version - this repo has no
release boundary to version against. See `homelab/AGENTS.md`'s "Where
project knowledge goes" for what belongs here versus a repo's own pinboard
project tasks/context.

## 2026-10-03

### Added
- Leak check in CI: `.github/scripts/leak-check.sh` (vendored from the
  maintainer's workspace, do not edit here) runs with `--tree --log` against
  the org secret `LEAK_PATTERNS`, and `.leak-allow` lists the intentional
  exceptions. Without the secret it passes with a notice, except on the
  public org's own non-fork runs.
- MIT `LICENSE`, `CONTRIBUTING.md`, GitHub issue templates and a "Support this
  project" README section, ahead of publishing the repo.
- `kopia-clients.tsv.example` with invented rows.

### Changed
- AGENTS.md "Public repository, private homelab" trimmed to what a public
  reader needs, and CHANGELOG/README/comments rephrased so the tree passes
  the leak check.
- `scripts/kopia-enroll.sh` reads its clients file from `$KOPIA_CLIENTS_FILE`,
  defaulting to `./kopia-clients.tsv` in the current directory (gitignored)
  instead of a fixed file in this repo.
- CI runs its checks inline on `ubuntu-latest` (gitleaks, `bash -n`,
  ShellCheck, yamllint, JSON, the compose template, both test suites) instead
  of calling the org's private reusable workflow on the self-hosted runner.
- README rewritten for new users: what it is, requirements, quickstart and a
  module table first. Homelab-specific context moved to `AGENTS.md`.

### Fixed
- `tests/test.sh` no longer depends on a local `generated/minimal.sh`, and its
  expected module list includes `incinerator`, `kopia-client` and `kvm`.

### Removed
- `kopia-clients.tsv` (the real client inventory) moved to the `keep` repo.

## 2026-09-30

### Changed
- `alloy` module: journal lines with syslog identifier `incinerator` get a
  `syslog_identifier="incinerator"` Loki label (no other identifier is
  labelled, to keep stream count flat), so an alert can select on it.
  Re-run the module on each incinerator host to pick it up.

## 2026-09-29

### Changed
- `kopia-clients.tsv`: per-client excludes for live database files
  (RocksDB, SQLite) that the service dumps into `/app/backups` before each
  snapshot instead. Takes effect once that client is re-enrolled with
  `scripts/kopia-enroll.sh <ctid>`.

## 2026-09-28 (incinerator)

### Added
- `incinerator` module (pinboard #447): installs `/usr/local/sbin/incinerator`
  (bash + jq, installs `jq`) and `incinerator-daily.timer` (03:30 + up to 45m)
  / `incinerator-pressure.timer` (every 15 min, acts only at or above the
  policy threshold). Prunes unused docker images, build cache, stopped
  containers, optionally dangling anonymous volumes (named volumes never),
  vacuums journald, cleans apt, and ages/size-caps policy paths. Per-host
  policy in `/app/.homelab/incinerator.json`. Added to `profiles/default.conf`.
  Tests: `node --test tests/incinerator.test.mjs`.

## 2026-09-28

### Fixed
- CI's secret scan is green again. It had failed on every push since
  2026-09-25 because gitleaks flagged the dummy kopia-client password in
  `tests/test.sh`. `.gitleaksignore` now lists that fingerprint,
  and says what may and may not be added there.
- `tailscale`: `tailscale up` now has a timeout (`TAILSCALE_UP_TIMEOUT`,
  default `60s`) and prints tailscale's own error on failure. Before, an
  unreachable login server made it hang forever with no output.
- `tailscale`: an existing `/etc/hosts` pin for the login server that points
  at a different address is now replaced. Before, any existing line was kept,
  so a wrong pin (the control server's own address instead of the
  TLS-terminating proxy's)
  survived every re-run.

## 2026-09-25

### Added
- `scripts/kopia-enroll.sh`: enrolls LXCs as Kopia clients of keep, each with
  its own generated password that is registered on keep and passed to the
  module over stdin, never printed or stored.
- `kopia-clients.tsv`: per-host backup paths and excludes for every client.
- `kopia-client` takes `--paths` and `--exclude` (comma-separated, excludes
  may be globs) and `--password-stdin true`, and runs the repo's
  `/app/scripts/backup-dump.sh` before each snapshot when there is one.

### Changed
- `KOPIA_CLIENT_PASSWORD` and `KOPIA_BACKUP_PATH` are gone from
  `.env.example`. A single shared client password is no longer the intended
  setup. The module still reads both as a fallback.

### Fixed
- `kopia-client` prints Kopia's own error text on a failed connect, policy
  set or initial snapshot, with hints at the known causes (new server user
  not yet active on keep, keep's ACLs missing Kopia's defaults), instead of a
  bare "Failed to ...".
- `kopia-client` reconnects a client whose stored server URL is not
  `KOPIA_SERVER_URL`, so re-running the module repairs clients enrolled
  before keep moved from `.120` to `.112` in the 2026-09-20 LAN cutover.
- `kopia-client` passes the client password to the guest over stdin; the
  dry-run log used to print it as part of the command line. Dry runs also
  no longer claim an existing connection or a failed initial snapshot.

## 2026-09-22

### Added
- Scaffold template `.homelab/deploy.json`, the repo's deploy declaration read
  by homelab's `deploy-service.sh` and foreman's pipeline.
  Included in the `existing-project` profile too.

## 2026-09-20

### Changed
- `LXC_IP` now defaults to `auto` instead of `dhcp`, for both `create` and
  `recipe`. `auto` already existed but was never the default, so every
  container provisioned so far took a DHCP lease and changed address
  whenever the router restarted - which broke `reverse-proxy`'s Caddyfile,
  Prometheus' scrape targets and a handful of `.env` files, since those all
  hardcode LAN IPs. A new container now gets `<LXC_LAN_PREFIX>.<CTID>`.

### Added
- `auto` refuses a CTID outside `LXC_CTID_MIN`-`LXC_CTID_MAX` (100-149)
  rather than generating an address the router could also lease out. The
  floor is Proxmox's own minimum VMID; the ceiling tracks the router's DHCP
  pool, which now starts at `.150`, so raising it means shrinking that pool
  first.
- `LXC_LAN_PREFIX` (default `192.168.0`) and `LXC_LAN_CIDR` (default `24`)
  make `auto` configurable; the prefix and `/24` were previously hardcoded
  in `lib/network.sh`.
- Ten tests covering `_resolve_create_ip`: CTID derivation, custom prefix,
  both range boundaries, three rejection cases, and that `dhcp` and explicit
  addresses still pass through untouched. `lib/network.sh` had no test
  coverage at all before this.
- README: "Addressing: a container's IP is its CTID", explaining the scheme,
  why the 100-199 bound exists, and the settings that control it.

## 2026-09-19

### Fixed
- `tailscale` module: optional `TAILSCALE_LOGIN_SERVER_LAN_IP` pins the
  login server's hostname to its LAN address in the LXC's `/etc/hosts`
  before `tailscale up`. Without it, every LXC reached the control server
  (and its embedded DERP) via the public IP, and the ISP router's hairpin NAT drops
  those connections after ~30-60s idle, causing constant Tailscale
  reconnects and unstable networking tailnet-wide. Pairs with blanking
  the control server's DERP IPv4 setting. Existing LXCs were patched
  by hand on the same day.

## 2026-09-13

### Changed
- CI checks now run on the org's self-hosted runner instead of GitHub-hosted `ubuntu-latest`.

## 2026-09-10

### Added
- `modules/backup/kopia-client.sh`, modeled on the `alloy`
  module: installs the `kopia` binary via its apt repo, connects the
  client to `keep`'s Kopia repository server as `<hostname>@<hostname>`,
  sets a retention policy, and installs/enables a daily systemd timer for
  snapshots. Part of the `keep` project's backup rollout (piloted against
  `glance` - see `keep`'s own changelog).

### Fixed
- `kopia-backup.service` failed with "repository is not connected" the
  first time the systemd timer (or a manual `systemctl start`) fired, even
  though the module's own interactive install had already connected the
  client successfully. Cause: systemd services get no `HOME` env by
  default, so `kopia` couldn't find `/root/.config/kopia/repository.config`
  - it only worked when run interactively via `pct exec`, where `HOME` is
  set. Fixed by pinning `Environment=HOME=/root` on the service unit and
  passing `--config-file` explicitly instead of relying on `HOME`
  inference. The module now also runs and checks an initial snapshot
  during configuration, so this class of bug is caught at provisioning
  time instead of at the next scheduled run.
