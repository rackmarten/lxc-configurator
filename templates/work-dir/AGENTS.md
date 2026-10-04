# Agent Instructions

## Project

This project runs in `${WORK_DIR}` on `${HOSTNAME}` (LXC ${CTID}).

## General rules

- Read the project documentation before making changes.
- Do not modify `.env` or other local configuration files unless explicitly requested.
- Do not commit secrets, credentials, tokens, private keys, or local configuration.
- Prefer small, focused changes.
- Preserve existing project conventions.
- Run relevant tests and checks before considering a change complete.

## Secrets

`.claude/settings.json` in this project denies reading or editing `.env`/`.env.*` — do not try to work around that (e.g. by piping the file through another command) to see its contents.

If you add a service with its own credentials file, or a new `docker-compose.yml` with an `environment:` block, either put the real values in `.env` and reference them as `${VAR}`, or ask the operator to run:

    ./configurator.sh module secrets-guard ${CTID}

from the Proxmox host. That extends `.gitignore` and `.claude/settings.json` for what the project actually contains, and flags any credential already committed in plaintext.

Never write a real credential, secret, token, or private key into a persistent memory file, under any circumstances — not even to record "where" a secret lives or what it looks like. Memory files are not covered by the deny rules above, and a value written there outlives this conversation.

## Ownership

Never run a recursive `chown` (e.g. `chown -R ${USER_NAME}:${USER_NAME} ${WORK_DIR}`) on this directory. Some bind-mounted data directories (a database or mail server's volume, for example) are intentionally owned by the UID/GID that container's process runs as internally, not by `${USER_NAME}`. A blanket recursive chown breaks that service — it can no longer write to its own data directory and will crash-loop on permission errors.

## Deployment

Do not deploy changes automatically unless explicitly requested.

Use:

    ./scripts/deploy.sh

for deployment.

## Health

Use:

    ./scripts/healthcheck.sh

to verify the deployment.

## Project-specific instructions

Add additional instructions here as the project evolves.
