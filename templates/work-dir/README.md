# ${HOSTNAME}

Project working directory for LXC ${CTID}.

- Hostname: `${HOSTNAME}`
- Container ID: `${CTID}`
- Working directory: `${WORK_DIR}`
- User: `${USER_NAME}`
- Timezone: `${TIMEZONE}`

## Getting started

Copy the example environment file:

    cp .env.example .env

Review the configuration before starting the project.

## Development

Add project-specific development instructions here.

Do not run a recursive `chown` on `${WORK_DIR}`. Some bind-mounted data directories (a database or mail server's volume, for example) are intentionally owned by the UID/GID that container's own process runs as, not by `${USER_NAME}` — a blanket `chown -R` will break that service.

## Secrets

`.claude/settings.json` denies Claude Code from reading or editing `.env`/`.env.*`. When adding a service with its own credentials, put real values in `.env` and reference them as `${VAR}`, then run `./configurator.sh module secrets-guard ${CTID}` from the Proxmox host so `.gitignore` and `.claude/settings.json` get extended for what the project actually contains.

## Deployment

Run:

    ./scripts/deploy.sh

## Health check

Run:

    ./scripts/healthcheck.sh
