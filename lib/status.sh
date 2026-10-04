#!/usr/bin/env bash

# Running-LXC discovery and migration-ledger comparison.
#
# `pct list` only ever enumerates LXC containers, never Proxmox VMs (`qm`
# lives in a separate ID namespace and command entirely) - a blackbox VM
# image such as Home Assistant OS can never show up here, so no extra
# filtering is required to keep VMs out of `status`.

ACTION_LOG_FILE="${SCRIPT_DIR}/output/migrations.log"

# Appends one ledger entry after a successful, non-dry-run create/configure/
# migrate action, so a later `status` run can tell which currently running
# LXCs this tool has already touched, and with which profile/action/when.
log_action_record() {
  local action="${1:-}"
  local ctid="${2:-}"
  local hostname="${3:-unavailable}"
  local profile="${4:-default}"

  dry_run_enabled && return 0
  [[ -n "${action}" && -n "${ctid}" ]] || return 0

  mkdir -p "$(dirname "${ACTION_LOG_FILE}")"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "${action}" "${ctid}" "${hostname}" "${profile}" \
    >> "${ACTION_LOG_FILE}"
}

# Prints "ctid<TAB>timestamp<TAB>action<TAB>hostname<TAB>profile" for the
# most recent ledger entry of each ctid. Ledger entries are append-only and
# read in file order, so the last line seen per ctid is the most recent one.
_status_last_action_per_ctid() {
  [[ -f "${ACTION_LOG_FILE}" ]] || return 0

  awk -F'\t' '{ last[$3] = $1 "\t" $2 "\t" $4 "\t" $5 } END { for (ctid in last) print ctid "\t" last[ctid] }' \
    "${ACTION_LOG_FILE}"
}

# Prints "ctid<TAB>name" for every currently running LXC container.
_status_running_lxcs() {
  _lxc_require_pct || return 1

  pct list 2>/dev/null | awk 'NR > 1 && $2 == "running" { print $1 "\t" $NF }'
}

run_status() {
  local ctid name
  local entry_ctid entry_ts entry_action entry_hostname entry_profile
  declare -A last_action=()
  local found_any=false

  while IFS=$'\t' read -r entry_ctid entry_ts entry_action entry_hostname entry_profile; do
    [[ -n "${entry_ctid}" ]] || continue
    last_action["${entry_ctid}"]="${entry_ts}"$'\t'"${entry_action}"$'\t'"${entry_hostname}"$'\t'"${entry_profile}"
  done < <(_status_last_action_per_ctid)

  printf '%s\n' 'Running LXCs' '------------'

  while IFS=$'\t' read -r ctid name; do
    [[ -n "${ctid}" ]] || continue
    found_any=true

    if [[ -v "last_action[${ctid}]" ]]; then
      IFS=$'\t' read -r entry_ts entry_action entry_hostname entry_profile <<< "${last_action[${ctid}]}"
      printf '%-6s %-24s migrated (%s, %s, profile %s, hostname %s)\n' \
        "${ctid}" "${name}" "${entry_action}" "${entry_ts}" "${entry_profile}" "${entry_hostname}"
    else
      printf '%-6s %-24s not migrated\n' "${ctid}" "${name}"
    fi
  done < <(_status_running_lxcs)

  if [[ "${found_any}" == false ]]; then
    printf '%s\n' 'No running LXC containers found.'
  fi
}
