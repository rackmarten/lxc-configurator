#!/usr/bin/env bash
# Enroll (or re-enroll) LXCs as Kopia backup clients of keep, each with its
# own generated password. Runs on the Proxmox host as root:
#
#   ./scripts/kopia-enroll.sh [--dry-run] <ctid> [<ctid> ...]
#   ./scripts/kopia-enroll.sh [--dry-run] --all
#
# Per CTID (which must have a row in the clients file: $KOPIA_CLIENTS_FILE,
# default ./kopia-clients.tsv in the current directory; see
# kopia-clients.tsv.example for the format) it:
#   1. generates a random password, held only in this script's memory,
#   2. registers <hostname>@<hostname> on keep with it ("server user add",
#      or "server user set" when the user already exists),
# then restarts keep's Kopia server once so the users are live immediately,
# and runs the kopia-client module for each CTID with that row's paths and
# excludes, passing the password over stdin.
#
# The password is never printed, written to disk or put in an argv on this
# host; it only lives on in the client's own repository.config. A rebuilt or
# broken client is fixed by enrolling it again, which sets a new password.
# One password per client means a compromised LXC can only reach its own
# snapshots.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

CLIENTS_FILE="${KOPIA_CLIENTS_FILE:-./kopia-clients.tsv}"
CONFIGURATOR="${CONFIGURATOR:-${ROOT_DIR}/configurator.sh}"
PCT="${PCT:-pct}"
KEEP_CTID="${KEEP_CTID:-112}"
KEEP_APP_DIR="${KEEP_APP_DIR:-/app}"
KEEP_SERVICE="${KEEP_SERVICE:-kopia}"

usage() {
    sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-2}"
}

die() {
    printf 'kopia-enroll: %s\n' "$*" >&2
    exit 1
}

dry_run=false
all=false
ctids=()
for argument in "$@"; do
    case "${argument}" in
        --dry-run) dry_run=true ;;
        --all) all=true ;;
        -h|--help) usage 0 ;;
        [0-9]*) ctids+=("${argument}") ;;
        *) usage ;;
    esac
done

[[ -f "${CLIENTS_FILE}" ]] ||
    die "missing ${CLIENTS_FILE} (set KOPIA_CLIENTS_FILE; see kopia-clients.tsv.example)"

declare -A row_hostname=() row_paths=() row_exclude=()
declare -a known_ctids=()
while IFS=$'\t' read -r ctid hostname paths exclude; do
    [[ -z "${ctid}" || "${ctid}" == \#* ]] && continue
    [[ -n "${hostname}" && -n "${paths}" && -n "${exclude}" ]] ||
        die "malformed row for CTID ${ctid} in ${CLIENTS_FILE}"
    row_hostname["${ctid}"]="${hostname}"
    row_paths["${ctid}"]="${paths}"
    row_exclude["${ctid}"]="${exclude}"
    known_ctids+=("${ctid}")
done < "${CLIENTS_FILE}"

if [[ "${all}" == "true" ]]; then
    ctids=("${known_ctids[@]}")
fi
((${#ctids[@]} > 0)) || usage

for ctid in "${ctids[@]}"; do
    [[ -v "row_hostname[${ctid}]" ]] || die "CTID ${ctid} has no row in ${CLIENTS_FILE}"
    [[ "${ctid}" != "${KEEP_CTID}" ]] || die "keep (${KEEP_CTID}) is the server, not a client"
done

if [[ "${EUID:-$(id -u)}" -ne 0 && -z "${KOPIA_ENROLL_SKIP_ROOT_CHECK:-}" ]]; then
    die "run as root on the Proxmox host"
fi

# Catch a CTID that was reassigned since the table was written before any
# password is set for the wrong identity.
for ctid in "${ctids[@]}"; do
    actual="$("${PCT}" exec "${ctid}" -- hostname)" || die "cannot reach LXC ${ctid}"
    [[ "${actual}" == "${row_hostname[${ctid}]}" ]] ||
        die "LXC ${ctid} is '${actual}', but ${CLIENTS_FILE} says '${row_hostname[${ctid}]}'"
done

if [[ "${dry_run}" == "true" ]]; then
    for ctid in "${ctids[@]}"; do
        identity="${row_hostname[${ctid}]}@${row_hostname[${ctid}]}"
        printf '[DRY-RUN] %s: would set a new password for %s on keep, then run the module:\n' "${ctid}" "${identity}"
        module_args=(--paths "${row_paths[${ctid}]}")
        [[ "${row_exclude[${ctid}]}" == "-" ]] || module_args+=(--exclude "${row_exclude[${ctid}]}")
        printf 'dry-run-password\n' | "${CONFIGURATOR}" module kopia-client "${ctid}" \
            --password-stdin true "${module_args[@]}" --dry-run
    done
    exit 0
fi

# All keep-side commands go through here. The password arrives on stdin and
# is read inside keep's container, so it reaches no argv outside it.
keep_kopia() {
    # shellcheck disable=SC2016  # expanded by the shells inside keep.
    "${PCT}" exec "${KEEP_CTID}" -- sh -c \
        'cd "$1" && shift && exec docker compose exec -T "$@"' \
        sh "${KEEP_APP_DIR}" "${KEEP_SERVICE}" "$@"
}

existing_users="$(keep_kopia kopia server user list </dev/null)" ||
    die "cannot list users on keep (CTID ${KEEP_CTID})"

declare -A passwords=()
for ctid in "${ctids[@]}"; do
    identity="${row_hostname[${ctid}]}@${row_hostname[${ctid}]}"
    verb="add"
    if grep -qxF "${identity}" <<< "${existing_users}"; then
        verb="set"
    fi

    passwords["${ctid}"]="$(openssl rand -hex 24)"
    # shellcheck disable=SC2016  # expanded by the shell inside keep's container.
    printf '%s\n' "${passwords[${ctid}]}" | keep_kopia sh -c \
        'IFS= read -r p; exec kopia server user "$1" "$2" --user-password="$p"' \
        sh "${verb}" "${identity}" >/dev/null ||
        die "failed to ${verb} ${identity} on keep; clients already reset in this run need enrolling again"
    printf 'kopia-enroll: %s %s on keep\n' "${verb}" "${identity}"
done

printf 'kopia-enroll: restarting keep'\''s Kopia server so the new passwords are live\n'
# shellcheck disable=SC2016  # expanded by the shell inside keep.
"${PCT}" exec "${KEEP_CTID}" -- sh -c 'cd "$1" && docker compose restart "$2" >/dev/null' \
    sh "${KEEP_APP_DIR}" "${KEEP_SERVICE}" </dev/null ||
    die "failed to restart ${KEEP_SERVICE} on keep"
sleep "${KOPIA_ENROLL_RESTART_WAIT:-10}"

failed=()
for ctid in "${ctids[@]}"; do
    module_args=(--paths "${row_paths[${ctid}]}")
    [[ "${row_exclude[${ctid}]}" == "-" ]] || module_args+=(--exclude "${row_exclude[${ctid}]}")

    if printf '%s\n' "${passwords[${ctid}]}" | "${CONFIGURATOR}" module kopia-client "${ctid}" \
        --password-stdin true "${module_args[@]}"; then
        printf 'kopia-enroll: %s (%s) enrolled\n' "${ctid}" "${row_hostname[${ctid}]}"
    else
        failed+=("${ctid}")
    fi
    unset "passwords[${ctid}]"
done

if ((${#failed[@]} > 0)); then
    printf 'kopia-enroll: failed: %s (fix the cause and enroll those again)\n' "${failed[*]}" >&2
    exit 1
fi

printf 'kopia-enroll: done. Check on keep: docker compose exec kopia kopia snapshot list --all\n'
