#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="locale"
MODULE_DESCRIPTION="Configure locale and timezone"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

_normalize_locale() {
    printf '%s' "${1:-}" |
        tr '[:upper:]' '[:lower:]' |
        sed -E \
            -e 's/[.-]/_/g' \
            -e 's/utf[_-]?8/utf8/g'
}

configure_locale() {
    local ctid="${1:-}"
    shift || true
    declare -A options=()
    option_parse options "locale,timezone" "$@"

    if [[ -z "${ctid}" ]]; then
        log_error "Locale configuration requires a CTID."
        return 2
    fi

    local locale
    local timezone
    locale="$(option_require options locale LOCALE '')"
    timezone="$(option_require options timezone TIMEZONE '')"
    [[ "${locale}" =~ ^[A-Za-z][A-Za-z0-9_.@+-]*$ ]] || fatal "Invalid locale '${locale}'."
    [[ "${timezone}" =~ ^[A-Za-z0-9][A-Za-z0-9_+./-]*$ && "${timezone}" != *..* ]] || fatal "Invalid timezone '${timezone}'."

    log_info "Configuring locale '${locale}' and timezone '${timezone}' for LXC ${ctid}..."

    if ! guest_install_packages "${ctid}" locales; then
        log_error "Failed to install locale package in LXC ${ctid}."
        return 1
    fi

    local locale_normalized
    locale_normalized="$(_normalize_locale "${locale}")"

    if guest_exec "${ctid}" sh -c \
        "locale -a 2>/dev/null |
         tr '[:upper:]' '[:lower:]' |
         sed -E \
             -e 's/[.-]/_/g' \
             -e 's/utf[_-]?8/utf8/g' |
         grep -Fxq '${locale_normalized}'"; then
        log_info "Locale '${locale}' is already generated."
    else
        if ! guest_exec "${ctid}" sh -c \
             "sed -i '/^[#[:space:]]*${locale//./\\.}/s/^#//' /etc/locale.gen &&
             locale-gen '${locale}' >/dev/null 2>&1"; then
            log_error "Failed to generate locale '${locale}' in LXC ${ctid}."
            return 1
        fi

        log_success "Generated locale '${locale}'."
    fi

    local current_locale
    current_locale="$(guest_exec "${ctid}" sh -c \
        "grep '^LANG=' /etc/default/locale 2>/dev/null |
         cut -d= -f2- |
         tr -d '\"'")"

    if [[ "${current_locale}" == "${locale}" ]]; then
        log_info "Locale is already configured."
    else
        if ! guest_exec "${ctid}" sh -c \
            "printf 'LANG=\"%s\"\\n' '${locale}' > /etc/default/locale"; then
            log_error "Failed to configure locale '${locale}' in LXC ${ctid}."
            return 1
        fi

        log_success "Configured locale '${locale}'."
    fi

    if ! guest_exec "${ctid}" test -f \
        "/usr/share/zoneinfo/${timezone}"; then
        log_error "Timezone '${timezone}' does not exist in LXC ${ctid}."
        return 1
    fi

    local current_timezone
    current_timezone="$(guest_exec "${ctid}" cat /etc/timezone 2>/dev/null || true)"

    if [[ "${current_timezone}" == "${timezone}" ]]; then
        log_info "Timezone is already '${timezone}'."
    else
        if ! guest_exec "${ctid}" ln -sf \
            "/usr/share/zoneinfo/${timezone}" \
            /etc/localtime; then
            log_error "Failed to configure timezone '${timezone}' in LXC ${ctid}."
            return 1
        fi

        if ! guest_exec "${ctid}" sh -c \
            "printf '%s\\n' '${timezone}' > /etc/timezone"; then
            log_error "Failed to configure timezone '${timezone}' in LXC ${ctid}."
            return 1
        fi

        log_success "Configured timezone '${timezone}'."
    fi

    log_success "Locale and timezone configured for LXC ${ctid}."
}

configure_locale_help() {
        cat <<'EOF'
Usage: ./configurator.sh module locale <ctid> [options]

Options:
    --locale <value>     Override LOCALE.
    --timezone <value>   Override TIMEZONE.
EOF
}
