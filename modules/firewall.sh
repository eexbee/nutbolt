#!/usr/bin/env bash
# =============================================================================
# modules/firewall.sh - Firewall configuration
# Ubuntu -> UFW, RHEL family -> firewalld
# Default policy: deny incoming / allow outgoing. The SSH port (and the old
# SSH port during migration) is ALWAYS allowed before the firewall is enabled.
# =============================================================================

module_firewall_run() {
    log_section "MODULE: Firewall ($FIREWALL)"

    config_get_bool "firewall.enabled" true || { log_info "Firewall disabled in config"; return 0; }

    local ssh_port="${SSH_NEW_PORT:-$(config_get 'ssh.port' 22)}"
    local old_ssh_port="${SSH_OLD_PORT:-22}"
    local tcp_ports udp_ports

    if [[ "$INTERACTIVE" == "1" ]] && ! config_has "firewall.tcp_ports"; then
        local def_tcp="80 443"
        log_info "Detected/selected profiles: ${ACTIVE_PROFILES:-none}"
        [[ -n "${ACTIVE_PROFILES:-}" ]] && def_tcp="$(_suggest_tcp_ports "$ACTIVE_PROFILES")"
        local ans
        ans="$(prompt "TCP ports to allow (space/comma separated)" "$def_tcp")"
        tcp_ports="${ans//,/ }"
        ans="$(prompt "UDP ports to allow (space/comma separated, empty for none)" "")"
        udp_ports="${ans//,/ }"
    else
        tcp_ports="$(config_get_list_csv "firewall.tcp_ports" "")"
        udp_ports="$(config_get_list_csv "firewall.udp_ports" "")"
    fi

    if ! validate_ports_list "$tcp_ports" || ! validate_ports_list "$udp_ports"; then
        log_error "Invalid port list (tcp='$tcp_ports' udp='$udp_ports') - firewall module aborted"
        register_error "firewall invalid ports"
        return 1
    fi

    if [[ "$FIREWALL" == "ufw" ]]; then
        _firewall_ufw "$ssh_port" "$old_ssh_port" "$tcp_ports" "$udp_ports"
    else
        _firewall_firewalld "$ssh_port" "$old_ssh_port" "$tcp_ports" "$udp_ports"
    fi
}

_suggest_tcp_ports() {
    local profiles="$1" ports=""
    if [[ "$profiles" == *web* ]]; then ports+=" 80 443"; fi
    if [[ "$profiles" == *database* ]]; then
        command -v mysql &>/dev/null && ports+=" 3306"
        command -v mariadb &>/dev/null && ports+=" 3306"
        command -v mysqld &>/dev/null && ports+=" 3306"
        command -v psql &>/dev/null && ports+=" 5432"
    fi
    if [[ "$profiles" == *redis* ]]; then ports+=" 6379"; fi
    if [[ "$profiles" == *minio* ]]; then ports+=" 9000 9001"; fi
    echo "${ports# }"
}

# ---------------------------------------------------------------------------
# UFW (Ubuntu)
# ---------------------------------------------------------------------------
_firewall_ufw() {
    local ssh_port="$1" old_port="$2" tcp_ports="$3" udp_ports="$4"

    command -v ufw &>/dev/null || pkg_install ufw
    command -v ufw &>/dev/null || { log_error "ufw not available"; register_error "ufw missing"; return 1; }

    backup_snapshot "ufw-pre-status"        "ufw status verbose"
    backup_snapshot "ufw-pre-rules"         "ufw show added-rules"

    local p added=""
    # SSH first - never lock ourselves out
    ufw allow "$ssh_port"/tcp >/dev/null 2>&1 && added+=" $ssh_port/tcp"
    [[ "$ssh_port" != "$old_port" ]] && { ufw allow "$old_port"/tcp >/dev/null 2>&1 && added+=" $old_port/tcp"; }
    echo "$added" > "$BACKUP_DIR/ufw-added-rules"

    for p in $tcp_ports; do
        [[ -z "$p" ]] && continue
        [[ "$p" == "$ssh_port" ]] && continue
        ufw allow "$p"/tcp >/dev/null 2>&1 && added+=" $p/tcp"
    done
    for p in $udp_ports; do
        [[ -z "$p" ]] && continue
        ufw allow "$p"/udp >/dev/null 2>&1 && added+=" $p/udp"
    done
    echo "$added" > "$BACKUP_DIR/ufw-added-rules"

    ufw default deny incoming   >/dev/null 2>&1
    ufw default allow outgoing  >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1

    log_ok "UFW enabled: default deny incoming / allow outgoing"
    log_ok "Allowed:${added:- (ssh only: $ssh_port/tcp)}"
    ufw status | sed 's/^/  /'
}

# ---------------------------------------------------------------------------
# firewalld (AlmaLinux / Rocky)
# ---------------------------------------------------------------------------
_firewall_firewalld() {
    local ssh_port="$1" old_port="$2" tcp_ports="$3" udp_ports="$4"

    command -v firewall-cmd &>/dev/null || pkg_install firewalld
    command -v firewall-cmd &>/dev/null || { log_error "firewalld not available"; register_error "firewalld missing"; return 1; }

    backup_snapshot "firewalld-pre" "firewall-cmd --list-all"

    svc_enable firewalld
    svc_start  firewalld
    sleep 1
    svc_active firewalld || { log_error "firewalld failed to start"; register_error "firewalld inactive"; return 1; }

    local p added=""
    # SSH first
    firewall-cmd --permanent --add-port="$ssh_port/tcp" >/dev/null 2>&1 && added+=" $ssh_port/tcp"
    [[ "$ssh_port" != "$old_port" ]] && { firewall-cmd --permanent --add-port="$old_port/tcp" >/dev/null 2>&1 && added+=" $old_port/tcp"; }

    for p in $tcp_ports; do
        [[ -z "$p" ]] && continue
        [[ "$p" == "$ssh_port" ]] && continue
        firewall-cmd --permanent --add-port="$p/tcp" >/dev/null 2>&1 && added+=" $p/tcp"
    done
    for p in $udp_ports; do
        [[ -z "$p" ]] && continue
        firewall-cmd --permanent --add-port="$p/udp" >/dev/null 2>&1 && added+=" $p/udp"
    done
    echo "$added" > "$BACKUP_DIR/firewalld-added-ports"

    # default zone: block everything not explicitly allowed
    local zone
    zone="$(firewall-cmd --get-default-zone)"
    firewall-cmd --permanent --zone="$zone" --remove-service=ssh >/dev/null 2>&1 || true

    firewall-cmd --reload >/dev/null 2>&1
    log_ok "firewalld configured (zone: $zone)"
    log_ok "Allowed:${added:- (ssh only: $ssh_port/tcp)}"
    firewall-cmd --list-all | sed 's/^/  /'
}
