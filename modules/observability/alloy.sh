#!/usr/bin/env bash

# shellcheck disable=SC2034  # MODULE_* metadata is read externally by lib/module.sh after sourcing this file.
MODULE_NAME="alloy"
MODULE_DESCRIPTION="Install Grafana Alloy"
MODULE_SUPPORTS_DRY_RUN=true
MODULE_REQUIRES_ROOT=true
MODULE_DEPENDS=()

configure_alloy() {
    local ctid="${1:-}"

    if [[ -z "${ctid}" ]]; then
        log_error "Alloy configuration requires a CTID."
        return 2
    fi

    : "${LOKI_URL:?LOKI_URL is required}"

    log_info "Configuring Grafana Alloy for LXC ${ctid}..."

    guest_install_packages "${ctid}" \
        ca-certificates \
        gpg \
        wget

    if guest_command_exists "${ctid}" alloy; then
        log_info "Grafana Alloy is already installed."
    else
        log_info "Installing Grafana Alloy..."

        guest_exec "${ctid}" install -d -m 755 /etc/apt/keyrings

        if ! guest_exec "${ctid}" sh -c \
            'wget -q -O /tmp/grafana.gpg.key https://apt.grafana.com/gpg.key'; then
            log_error "Failed to download Grafana repository key."
            return 1
        fi

        if ! guest_exec "${ctid}" sh -c \
            'gpg --dearmor < /tmp/grafana.gpg.key > /etc/apt/keyrings/grafana.gpg'; then
            log_error "Failed to install Grafana repository key."
            return 1
        fi

        guest_exec "${ctid}" rm -f /tmp/grafana.gpg.key

        guest_file_write \
            "${ctid}" \
            /etc/apt/sources.list.d/grafana.list \
            'deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main'

        if ! guest_install_packages "${ctid}" alloy; then
            log_error "Failed to install Grafana Alloy."
            return 1
        fi

        log_success "Grafana Alloy installed."
    fi

    if ! guest_command_exists "${ctid}" alloy; then
        log_error "Alloy executable is not available after installation."
        return 1
    fi

    if guest_exec "${ctid}" getent group docker >/dev/null 2>&1; then
        if guest_exec "${ctid}" id alloy >/dev/null 2>&1; then
            if guest_exec "${ctid}" id -nG alloy |
                tr ' ' '\n' |
                grep -qx docker; then
                log_info "Alloy is already in the docker group."
            else
                guest_exec "${ctid}" usermod -aG docker alloy
                log_success "Added Alloy to docker group."
            fi
        fi
    else
        log_warn "Docker group does not exist; Docker log collection may not work."
    fi

    local hostname_value
    hostname_value="$(guest_exec "${ctid}" hostname)"

    guest_exec "${ctid}" install -d -m 755 /etc/alloy

    local config
    config="$(cat <<EOF
logging {
  level  = "info"
  format = "logfmt"
}

discovery.docker "containers" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "containers" {
  targets = discovery.docker.containers.targets

  rule {
    source_labels = ["__meta_docker_container_name"]
    regex         = "/(.*)"
    target_label  = "container"
  }

  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_project"]
    target_label  = "compose_project"
  }

  rule {
    source_labels = ["__meta_docker_container_label_com_docker_compose_service"]
    target_label  = "compose_service"
  }

  rule {
    target_label = "hostname"
    replacement  = "${hostname_value}"
  }

  rule {
    target_label = "source"
    replacement  = "docker"
  }
}

loki.source.docker "containers" {
  host          = "unix:///var/run/docker.sock"
  targets       = discovery.docker.containers.targets
  relabel_rules = discovery.relabel.containers.rules
  forward_to    = [loki.write.default.receiver]
}

// Only incinerator's identifier becomes a label (for an
// "incinerator silent" alert); a label per identifier would multiply streams.
loki.relabel "journal" {
  forward_to = []

  rule {
    source_labels = ["__journal_syslog_identifier"]
    regex         = "(incinerator)"
    target_label  = "syslog_identifier"
  }
}

loki.source.journal "system" {
  forward_to    = [loki.write.system.receiver]
  relabel_rules = loki.relabel.journal.rules

  labels = {
    hostname = "${hostname_value}",
    source   = "system",
  }
}

loki.write "default" {
  endpoint {
    url = "${LOKI_URL}"
  }
}

loki.write "system" {
  endpoint {
    url = "${LOKI_URL}"
  }
}
EOF
)"

    guest_file_write \
        "${ctid}" \
        /etc/alloy/config.alloy \
        "${config}"

    log_info "Validating Alloy configuration..."

    if ! guest_exec "${ctid}" alloy validate /etc/alloy/config.alloy >/dev/null 2>&1; then
        log_error "Alloy configuration validation failed."
        return 1
    fi

    guest_exec "${ctid}" systemctl enable alloy >/dev/null 2>&1 || true

    if guest_exec "${ctid}" systemctl is-active --quiet alloy; then
        guest_exec "${ctid}" systemctl restart alloy >/dev/null 2>&1
    else
        guest_exec "${ctid}" systemctl start alloy >/dev/null 2>&1
    fi

    if ! guest_exec "${ctid}" systemctl is-active --quiet alloy; then
        log_error "Alloy failed to start."
        return 1
    fi

    log_success "Grafana Alloy configured for LXC ${ctid}."
}
