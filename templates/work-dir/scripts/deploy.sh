#!/usr/bin/env bash

set -euo pipefail

WORK_DIR="${WORK_DIR:-${PWD}}"

cd "${WORK_DIR}"

echo "Deploying ${HOSTNAME:-project} from ${WORK_DIR}..."

# Add project-specific deployment commands here.
#
# Examples:
#   docker compose pull
#   docker compose up -d
#   npm ci
#   npm run build
#   systemctl restart my-service

echo "Deployment completed."
