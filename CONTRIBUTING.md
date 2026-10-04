# Contributing

Thanks for taking the time to help. Bug reports and feature ideas go in
[GitHub issues](https://github.com/rackmarten/lxc-configurator/issues); pull
requests are welcome too. For anything larger than a small fix, open an issue
first so we can agree on the approach.

## Running the checks

Nothing here needs root or a real Proxmox host. The tests use temporary
directories and a mock LXC backend, and never call `pct` or touch `/etc`.

```bash
./tests/test.sh                     # or: ./configurator.sh test
node --test tests/incinerator.test.mjs   # incinerator tests (needs Node.js and jq)

git ls-files -z '*.sh' | xargs -0 bash -n
git ls-files -z '*.sh' | xargs -0 shellcheck --severity=warning
```

CI runs the same checks, plus yamllint, a JSON syntax check and a gitleaks
secret scan, on every push and pull request
(`.github/workflows/security-check.yml`).

Only ever test real provisioning against a container you are happy to
destroy.

## Module layout

Modules live under `modules/<category>/<name>.sh` and are discovered
automatically. A module file:

* declares its metadata: `MODULE_NAME`, `MODULE_DESCRIPTION`,
  `MODULE_SUPPORTS_DRY_RUN`, `MODULE_REQUIRES_ROOT`;
* defines `configure_<name>()` (dashes become underscores), which receives the
  CTID followed by the module's own options;
* parses its options with the helpers in `lib/options.sh`, rejecting unknown
  options and validating values before changing anything;
* runs guest commands through `guest_exec` (`lib/guest.sh`) and host-side LXC
  changes through `lib/lxc.sh`/`lib/lxc_config.sh`, never its own `pct exec`;
* is idempotent: inspect first, change only what is missing or wrong, and
  never overwrite existing user data.

Profiles (`profiles/*.conf`) only list modules, one per line, optionally with
options. Scaffold templates live in `templates/work-dir/`.

`AGENTS.md` has the full engineering rules (safety, idempotency, validation,
logging); please read it before a non-trivial change. Update `README.md` and
add tests along with any change in behavior.

## Commits

Keep commits focused, and start the subject with one of these prefixes:

| Prefix | Use for |
| --- | --- |
| `Add:` | new functionality or resource |
| `Edit:` | changes to existing functionality |
| `Fix:` | bug fixes |
| `Update:` | dependency, version, configuration or data updates |
| `Remove:` | removing functionality or a resource |
| `Docs:` | documentation-only changes |
| `DevOps:` | CI, packaging and other operational changes |

For example: `Add: kvm module for nested virtualization`.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
