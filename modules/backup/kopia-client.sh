#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="kopia-client"
MODULE_DESCRIPTION="Install and register a Kopia backup client"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

KOPIA_CLIENT_CONFIG_FILE=/root/.config/kopia/repository.config
KOPIA_CLIENT_DUMP_HOOK=/app/scripts/backup-dump.sh

# Log a failed kopia step with the reason kopia gave (its stderr) and a hint
# at the known causes, instead of a bare "failed to ...".
_kopia_client_fail() {
    local message="$1"
    local output="$2"
    local hint="${3:-}"

    log_error "${message}"

    if [[ -n "${output}" ]]; then
        local line
        while IFS= read -r line; do
            [[ -n "${line}" ]] && log_error "  kopia: ${line}"
        done <<< "${output}"
    fi

    [[ -n "${hint}" ]] && log_error "${hint}"
}

# Kopia refuses writes when keep's server ACLs lack its defaults, which only
# shows as a permission error on the client.
_kopia_client_acl_hint() {
    local output="$1"

    if [[ "${output,,}" == *"access denied"* || "${output,,}" == *"permission"* || "${output,,}" == *"unauthorized"* ]]; then
        printf '%s' "Looks like a server-side ACL problem: keep's ACLs must include Kopia's defaults (see keep README, \"Web UI\")."
    fi
}

# Split a comma-separated list of absolute paths into the named array.
# Paths end up unquoted in a systemd ExecStart line, so only a safe character
# set is allowed; "*" only when the third argument is "glob" (excludes).
_kopia_client_paths() {
    local value="$1"
    local -n paths_ref="$2"
    local chars='A-Za-z0-9_.@+-'
    [[ "${3:-}" == "glob" ]] && chars="*${chars}"
    local pattern="^/[${chars}]+(/[${chars}]+)*$"
    local item index

    paths_ref=()
    IFS=',' read -r -a paths_ref <<< "${value}"
    for index in "${!paths_ref[@]}"; do
        item="$(trim_whitespace "${paths_ref[${index}]}")"
        item="${item%/}"
        [[ "${item}" =~ ${pattern} ]] ||
            fatal "Invalid absolute path '${item}' in a Kopia path list."
        paths_ref["${index}"]="${item}"
    done
}

# Print "<source>\t/<pattern>" for an excluded absolute path: the backed-up
# path it lives under and the ignore pattern anchored at that path's root.
_kopia_client_exclude_rule() {
    local exclude="$1"
    shift
    local path

    for path in "$@"; do
        if [[ "${exclude}" == "${path}/"* ]]; then
            printf '%s\t/%s\n' "${path}" "${exclude#"${path}"/}"
            return 0
        fi
    done

    return 1
}

configure_kopia_client() {
    local ctid="${1:-}"
    shift || true
    declare -A options=()
    option_parse options "paths,exclude,password-stdin" "$@"

    if [[ -z "${ctid}" ]]; then
        log_error "Kopia client configuration requires a CTID."
        return 2
    fi

    # Read before any guest_exec, which would otherwise inherit and consume
    # stdin. The enroll script passes a per-client password this way.
    local client_password="${KOPIA_CLIENT_PASSWORD:-}"
    local fresh_password=false
    if [[ "$(option_get options password-stdin '' false)" == "true" ]]; then
        IFS= read -r client_password || true
        fresh_password=true
    fi

    : "${KOPIA_SERVER_URL:?KOPIA_SERVER_URL is required}"
    : "${KOPIA_SERVER_CERT_FINGERPRINT:?KOPIA_SERVER_CERT_FINGERPRINT is required}"
    [[ -n "${client_password}" ]] ||
        fatal "A client password is required: use scripts/kopia-enroll.sh, which generates one per client (or --password-stdin true)."

    local backup_paths=()
    local excludes=()
    _kopia_client_paths "$(option_get options paths KOPIA_BACKUP_PATHS "${KOPIA_BACKUP_PATH:-/app}")" backup_paths
    local exclude_value
    exclude_value="$(option_get options exclude KOPIA_EXCLUDES '')"
    [[ -z "${exclude_value}" ]] || _kopia_client_paths "${exclude_value}" excludes glob

    local exclude rule exclude_rules=()
    for exclude in "${excludes[@]}"; do
        rule="$(_kopia_client_exclude_rule "${exclude}" "${backup_paths[@]}")" ||
            fatal "Excluded path '${exclude}' is not inside any backed-up path (${backup_paths[*]})."
        exclude_rules+=("${rule}")
    done

    local keep_latest="${KOPIA_KEEP_LATEST:-7}"
    local keep_daily="${KOPIA_KEEP_DAILY:-7}"
    local keep_weekly="${KOPIA_KEEP_WEEKLY:-4}"
    local keep_monthly="${KOPIA_KEEP_MONTHLY:-6}"

    log_info "Configuring Kopia backup client for LXC ${ctid}..."

    guest_install_packages "${ctid}" \
        ca-certificates \
        gpg \
        curl

    if guest_command_exists "${ctid}" kopia; then
        log_info "Kopia is already installed."
    else
        log_info "Installing Kopia..."

        guest_exec "${ctid}" install -d -m 755 /etc/apt/keyrings

        if ! guest_exec "${ctid}" sh -c \
            'curl -fsSL https://kopia.io/signing-key -o /tmp/kopia.gpg.key'; then
            log_error "Failed to download Kopia repository key."
            return 1
        fi

        if ! guest_exec "${ctid}" sh -c \
            'gpg --dearmor < /tmp/kopia.gpg.key > /etc/apt/keyrings/kopia-keyring.gpg'; then
            log_error "Failed to install Kopia repository key."
            return 1
        fi

        guest_exec "${ctid}" rm -f /tmp/kopia.gpg.key

        guest_file_write \
            "${ctid}" \
            /etc/apt/sources.list.d/kopia.list \
            'deb [signed-by=/etc/apt/keyrings/kopia-keyring.gpg] http://packages.kopia.io/apt/ stable main'

        if ! guest_install_packages "${ctid}" kopia; then
            log_error "Failed to install Kopia."
            return 1
        fi

        log_success "Kopia installed."
    fi

    if ! guest_command_exists "${ctid}" kopia; then
        log_error "Kopia executable is not available after installation."
        return 1
    fi

    local hostname_value
    hostname_value="$(guest_exec "${ctid}" hostname)"
    local client_identity="${hostname_value}@${hostname_value}"

    local output
    local connected=false

    # Dry-run guest commands always "succeed", so a dry run shows a fresh
    # enrollment rather than claiming an existing connection.
    # A password from the enroll script was just set on keep, so any existing
    # connection holds the old one: always reconnect then.
    if ! dry_run_enabled && [[ "${fresh_password}" == "false" ]] &&
        guest_exec "${ctid}" kopia repository status >/dev/null 2>&1; then
        # A client enrolled before keep changed address (the 2026-09-20 LAN
        # cutover) stays "connected" to the old URL, so compare it too.
        if guest_exec "${ctid}" grep -qF -- "\"${KOPIA_SERVER_URL}\"" "${KOPIA_CLIENT_CONFIG_FILE}" 2>/dev/null; then
            connected=true
        fi
    fi

    if [[ "${connected}" == "true" ]]; then
        log_info "Kopia is already connected to ${KOPIA_SERVER_URL}."
    else
        if guest_file_exists "${ctid}" "${KOPIA_CLIENT_CONFIG_FILE}"; then
            log_warn "Existing Kopia connection is unusable or points elsewhere; reconnecting."
            guest_exec "${ctid}" kopia repository disconnect >/dev/null 2>&1 || true
        fi

        log_info "Connecting Kopia client '${client_identity}' to ${KOPIA_SERVER_URL}..."

        # The password goes over stdin, so it never appears in an argv,
        # the dry-run log, or this script's output.
        # shellcheck disable=SC2016  # $(cat) and "$@" expand inside the guest shell.
        if ! output="$(printf '%s' "${client_password}" | guest_exec "${ctid}" sh -c \
            'KOPIA_PASSWORD="$(cat)"; export KOPIA_PASSWORD; exec kopia repository connect server "$@"' sh \
            --url="${KOPIA_SERVER_URL}" \
            --server-cert-fingerprint="${KOPIA_SERVER_CERT_FINGERPRINT}" \
            --override-username="${hostname_value}" \
            --override-hostname="${hostname_value}" \
            --no-check-for-updates \
            2>&1 >/dev/null)"; then
            _kopia_client_fail "Failed to connect Kopia client '${client_identity}' to ${KOPIA_SERVER_URL}." \
                "${output}" \
                "Enroll clients with scripts/kopia-enroll.sh, which registers the user on keep and restarts its server first. Otherwise check KOPIA_SERVER_URL and KOPIA_SERVER_CERT_FINGERPRINT."
            return 1
        fi

        log_success "Kopia client connected as '${client_identity}'."
    fi

    local backup_path
    for backup_path in "${backup_paths[@]}"; do
        log_info "Setting retention and ignore policy for ${backup_path}..."

        # Clear first, in its own call (kopia applies --clear-ignore after any
        # --add-ignore in the same call), so re-running the module leaves
        # exactly the excludes given now rather than piling them on old ones.
        local policy_args=(--clear-ignore)
        local ignore_args=()
        for rule in "${exclude_rules[@]}"; do
            if [[ "${rule%%$'\t'*}" == "${backup_path}" ]]; then
                ignore_args+=("--add-ignore=${rule#*$'\t'}")
            fi
        done

        if ! output="$(guest_exec "${ctid}" kopia policy set "${backup_path}" \
            --keep-latest="${keep_latest}" \
            --keep-daily="${keep_daily}" \
            --keep-weekly="${keep_weekly}" \
            --keep-monthly="${keep_monthly}" \
            "${policy_args[@]}" \
            2>&1 >/dev/null)"; then
            _kopia_client_fail "Failed to set Kopia policy for ${backup_path}." \
                "${output}" "$(_kopia_client_acl_hint "${output}")"
            return 1
        fi

        if ((${#ignore_args[@]} > 0)) &&
            ! output="$(guest_exec "${ctid}" kopia policy set "${backup_path}" "${ignore_args[@]}" 2>&1 >/dev/null)"; then
            _kopia_client_fail "Failed to set Kopia excludes for ${backup_path}." \
                "${output}" "$(_kopia_client_acl_hint "${output}")"
            return 1
        fi
    done

    log_info "Installing systemd timer for periodic snapshots..."

    local service_unit
    service_unit="$(cat <<EOF
[Unit]
Description=Kopia snapshot of ${backup_paths[*]}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=HOME=/root
# A repo with a live database ships ${KOPIA_CLIENT_DUMP_HOOK}, which dumps it
# into a backed-up path. A failing dump fails the run, so keep's freshness
# alert catches it instead of a snapshot silently missing its database.
ExecStartPre=/bin/sh -c 'if [ -x ${KOPIA_CLIENT_DUMP_HOOK} ]; then exec ${KOPIA_CLIENT_DUMP_HOOK}; fi'
ExecStart=/usr/bin/kopia snapshot create --config-file=${KOPIA_CLIENT_CONFIG_FILE} ${backup_paths[*]}
EOF
)"

    local timer_unit
    timer_unit="$(cat <<'EOF'
[Unit]
Description=Daily Kopia snapshot

[Timer]
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=1800
Persistent=true

[Install]
WantedBy=timers.target
EOF
)"

    guest_file_write "${ctid}" /etc/systemd/system/kopia-backup.service "${service_unit}"
    guest_file_write "${ctid}" /etc/systemd/system/kopia-backup.timer "${timer_unit}"

    guest_exec "${ctid}" systemctl daemon-reload >/dev/null 2>&1

    guest_exec "${ctid}" systemctl enable kopia-backup.timer >/dev/null 2>&1 || true

    if guest_exec "${ctid}" systemctl is-active --quiet kopia-backup.timer; then
        guest_exec "${ctid}" systemctl restart kopia-backup.timer >/dev/null 2>&1
    else
        guest_exec "${ctid}" systemctl start kopia-backup.timer >/dev/null 2>&1
    fi

    if ! guest_exec "${ctid}" systemctl is-active --quiet kopia-backup.timer; then
        log_error "kopia-backup.timer failed to start."
        return 1
    fi

    if dry_run_enabled; then
        log_info "[DRY-RUN] Would run an initial snapshot to verify the service works."
        return 0
    fi

    log_info "Running an initial snapshot to verify the service actually works..."

    guest_exec "${ctid}" systemctl start --wait kopia-backup.service >/dev/null 2>&1

    if guest_exec "${ctid}" systemctl is-failed --quiet kopia-backup.service; then
        output="$(guest_exec "${ctid}" journalctl -u kopia-backup.service -n 10 -o cat --no-pager 2>/dev/null || true)"
        _kopia_client_fail "Initial kopia-backup.service run failed in LXC ${ctid}." \
            "${output}" "$(_kopia_client_acl_hint "${output}")"
        return 1
    fi

    log_success "Kopia backup client configured for LXC ${ctid}."
}
