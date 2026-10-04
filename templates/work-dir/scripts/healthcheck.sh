#!/usr/bin/env bash

set -euo pipefail

WORK_DIR="${WORK_DIR:-${PWD}}"

cd "${WORK_DIR}"

echo "Running health check for ${HOSTNAME:-project}..."

# Add project-specific health checks here.
#
# Examples:
#   curl --fail http://localhost:3000/health
#   docker compose ps
#   systemctl is-active my-service

echo "Health check passed."
