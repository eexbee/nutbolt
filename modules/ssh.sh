#!/usr/bin/env bash
# =============================================================================
# modules/ssh.sh - SSH hardening (two-phase, safe migration)
#
# Phase 1: change port (old port kept open) + MaxAuthTries, validate, restart,
#          then REQUIRE the operator to confirm login on the new port works.
# Phase 2: only after confirmation -> PermitRootLogin no,
#          PasswordAuthentication no (only when an admin key exists),
#          PubkeyAuthentication yes.
#
# Every change is validated with `sshd -t` BEFORE the service is restarted.
# If validation fails the previous configuration is restored automatically.
# =============================================================================

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BIN="/usr/sbin/sshd"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
sshd_effective() { # sshd_effective "port" -> effective value from sshd -T
    "$SSHD_BIN" -T 2>/dev/null | awk -v k="$(echo "$1" | tolower_str)" 'tolower($1)==k {print $2; exit}'
}
tolower_str() { tr '[:upper:]' '[:lower:]'; }

# set_sshd_option <Key> <Value>  (removes ALL existing occurrences, appends one)
set_sshd_option() {
    local key="$1" value="$2"
    sed -i -E "/^[[:space:]]*#?[[:space:]]*${key}[[:space:]]/Id" "$SSHD_CONFIG"
    printf '%s %s\n' "$key" "$value" >> "$SSHD_CONFIG"
    log_info "sshd_config: $key $value"
}

sshd_validate() {
    if ! "$SSHD_BIN" -t 2>/dev/null; then
        log_error "sshd -t FAILED - configuration invalid"
        "$SSHD_BIN" -t || true
        return 1
    fi
    log_ok "sshd -t passed"
}

ssh_restart() {
    local unit="$SSH_UNIT"
    # handle socket-activated ssh (Ubuntu 24.04+) as well
    if svc_active "${SSH_UNIT}.socket" 2>/dev/null || systemctl is-active ssh.socket &>/dev/null; then
        run_quiet systemctl daemon-reload
        run_quiet systemctl restart "${SSH_UNIT}.socket"
        run_quiet systemctl restart "${SSH_UNIT}.service" 2>/dev/null || true
    else
        svc_restart "$unit"
    fi
}

# manage ssh.socket ListenStream override (socket activation, Ubuntu)
ssh_socket_set_ports() { # args: ports...
    local ports=("$@") dropdir="/etc/systemd/system/${SSH_UNIT}.socket.d"
    mkdir -p "$dropdir"
    if [[ ! -f "$dropdir/nutbolt-ports.conf" ]]; then
        track_created "$dropdir/nutbolt-ports.conf"
    fi
    {
        echo "[Socket]"
        echo "# managed by nutbolt"
        echo "ListenStream="
        local p
        for p in "${ports[@]}"; do
            echo "ListenStream=0.0.0.0:${p}"
            echo "ListenStream=[::]:${p}"
        done
    } > "$dropdir/nutbolt-ports.conf"
    run_quiet systemctl daemon-reload
    log_info "ssh.socket ports: ${ports[*]}"
}

ssh_socket_active() {
    systemctl is-active --quiet "${SSH_UNIT}.socket" 2>/dev/null || \
    systemctl is-active --quiet ssh.socket 2>/dev/null
}

# ---------------------------------------------------------------------------
# module entry
# ---------------------------------------------------------------------------
module_ssh_run() {
    log_section "MODULE: SSH hardening"

    [[ -f "$SSHD_CONFIG" ]] || { log_error "$SSHD_CONFIG not found"; return 1; }
    backup_file_once "$SSHD_CONFIG"

    local current_port
    current_port="$(sshd_effective port)"
    [[ -z "$current_port" ]] && current_port=22

    # ---- gather target settings -------------------------------------------------
    local new_port max_tries
    max_tries="$(config_get "ssh.max_auth_tries" "5")"
    new_port="$(config_get "ssh.port" "")"

    if [[ "$INTERACTIVE" == "1" ]]; then
        local cfg_hint="" answer
        [[ -n "$new_port" ]] && cfg_hint=" (config default: $new_port)"
        while true; do
            answer="$(prompt "Enter new SSH port (empty = keep $current_port)${cfg_hint}" "")"
            [[ -z "$answer" ]] && { new_port=""; break; }
            if validate_port "$answer"; then new_port="$answer"; break; fi
            log_error "Port must be between 1 and 65535"
        done
    fi
    [[ -z "$new_port" ]] && { log_warn "No SSH port configured - keeping $current_port"; new_port="$current_port"; }

    if [[ "$new_port" == "$current_port" ]]; then
        log_info "SSH port stays at $new_port (no migration needed)"
        SSH_NEW_PORT="$new_port"
    else
        # ---------------- phase 1: add new port (keep old open) -----------------
        log_info "Phase 1: adding port $new_port (old port $current_port stays open for safety)"
        set_sshd_option "MaxAuthTries" "$max_tries"
        # remove any existing Port lines, then add old+new
        sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]/Id' "$SSHD_CONFIG"
        printf 'Port %s\nPort %s\n' "$current_port" "$new_port" >> "$SSHD_CONFIG"
        log_info "sshd_config: Port $current_port (kept) + Port $new_port (new)"

        if ssh_socket_active; then
            log_info "Socket activation detected - updating ${SSH_UNIT}.socket"
            ssh_socket_set_ports "$current_port" "$new_port"
        fi

        if ! sshd_validate; then
            _ssh_restore_config
            return 1
        fi
        ssh_restart
        sleep 1

        local server_ip login_user
        server_ip="$(_ssh_server_ip)"
        [[ -z "$server_ip" ]] && server_ip="<server-ip>"
        login_user="${ADMIN_USERNAME:-root}"
        _ssh_show_test_instructions "$new_port" "$server_ip" "$login_user"

        local confirmed="no"
        if [[ "$INTERACTIVE" == "1" ]]; then
            confirm "Can you successfully log in with: ssh ${login_user}@${server_ip} -p $new_port ?" "no"
            confirmed=$?
        else
            # non-interactive: assume tested (operator is responsible)
            log_warn "Non-interactive mode: skipping login confirmation prompt"
            log_warn "VERIFY NOW: ssh ${login_user}@${server_ip} -p $new_port"
            confirmed=0
        fi

        if [[ "$confirmed" != "0" ]]; then
            log_warn "Login on new port NOT confirmed - reverting to port $current_port only"
            sed -i -E '/^[[:space:]]*#?[[:space:]]*Port[[:space:]]/Id' "$SSHD_CONFIG"
            printf 'Port %s\n' "$current_port" >> "$SSHD_CONFIG"
            if ssh_socket_active; then ssh_socket_set_ports "$current_port"; fi
            if sshd_validate; then ssh_restart; else _ssh_restore_config; fi
            log_error "SSH port migration aborted. Old port $current_port restored."
            register_error "ssh port migration reverted"
            SSH_NEW_PORT="$current_port"
            return 1
        fi
        log_ok "Login confirmed on port $new_port"
        SSH_NEW_PORT="$new_port"
    fi

    # ---------------- phase 2: lock down ------------------------------------------
    module_ssh_lockdown
}

module_ssh_lockdown() {
    log_info "Phase 2: disabling root login and password authentication"

    local disable_root disable_password
    config_get_bool "ssh.disable_root_login" true     && disable_root=1   || disable_root=0
    config_get_bool "ssh.disable_password_auth" true  && disable_password=1 || disable_password=0

    # NEVER disable root/password auth before an admin key exists (philosophy #2)
    if [[ "$disable_root" == "1" && -z "${ADMIN_USERNAME:-}" ]]; then
        log_warn "No admin user was created - keeping PermitRootLogin enabled"
        disable_root=0
    fi
    if [[ "$disable_password" == "1" && "${ADMIN_KEY_INSTALLED:-0}" != "1" ]]; then
        log_warn "No admin SSH key installed - keeping PasswordAuthentication enabled"
        disable_password=0
    fi

    set_sshd_option "PubkeyAuthentication" "yes"

    if (( disable_root )); then
        set_sshd_option "PermitRootLogin" "no"
    else
        log_info "PermitRootLogin unchanged"
    fi

    if (( disable_password )); then
        set_sshd_option "PasswordAuthentication" "no"
        set_sshd_option "KbdInteractiveAuthentication" "no"
        set_sshd_option "ChallengeResponseAuthentication" "no"
        # lock out password auth system-wide drop-in (Ubuntu ships 50-cloud-init)
        local d="/etc/ssh/sshd_config.d"
        if [[ -d "$d" ]]; then
            local f
            for f in "$d"/*.conf; do
                [[ -f "$f" ]] || continue
                if grep -qiE '^[[:space:]]*PasswordAuthentication[[:space:]]+yes' "$f"; then
                    backup_file_once "$f"
                    sed -i -E 's/^([[:space:]]*)PasswordAuthentication[[:space:]]+yes/\1PasswordAuthentication no/I' "$f"
                    log_info "Fixed conflicting PasswordAuthentication in $f"
                fi
            done
        fi
    else
        log_info "PasswordAuthentication unchanged"
    fi

    if ! sshd_validate; then
        _ssh_restore_config
        return 1
    fi
    ssh_restart
    sleep 1

    local root_state="enabled" pass_state="enabled"
    (( disable_root ))     && root_state="disabled"
    (( disable_password )) && pass_state="disabled"
    log_ok "SSH hardening applied:"
    log_ok "  Port: $SSH_NEW_PORT | MaxAuthTries: $(config_get 'ssh.max_auth_tries' 5) | RootLogin: $root_state | PasswordAuth: $pass_state"
}

_ssh_server_ip() { # resolves once per run (public IP preferred), cached in SERVER_IP
    if [[ -z "${SERVER_IP+x}" ]]; then
        SERVER_IP="$(detect_server_ip)"
        export SERVER_IP
        if [[ -n "$SERVER_IP" ]]; then
            log_info "Server address for SSH verification: $SERVER_IP"
        else
            log_warn "Could not detect the server IP - replace <server-ip> manually"
        fi
    fi
    echo "${SERVER_IP}"
}

_ssh_show_test_instructions() { # <port> <ip> <login_user>
    local port="$1" ip="$2" login_user="$3"
    local auth_hint
    if [[ -z "${ADMIN_USERNAME:-}" ]]; then
        auth_hint="No admin user was created - log in as root (still enabled at this point)."
    elif [[ "${ADMIN_KEY_INSTALLED:-0}" == "1" ]]; then
        auth_hint="Authenticate with your SSH key (installed for '$login_user')."
    else
        auth_hint="No SSH key was installed - authenticate with the password you set for '$login_user'."
    fi
    cat <<EOF

$(printf '\033[0;33m================================================================================\033[0m')
  IMPORTANT: Open ANOTHER terminal and test the new SSH port BEFORE continuing:

      ssh ${login_user}@${ip} -p ${port}

  ${auth_hint}
  Keep your current session open. Only confirm when the new login WORKS.
$(printf '\033[0;33m================================================================================\033[0m')

EOF
}

_ssh_restore_config() {
    log_error "Restoring SSH configuration from backup"
    local rel="${SSHD_CONFIG#/}"
    if [[ -f "$BACKUP_DIR/files/$rel" ]]; then
        cp -a "$BACKUP_DIR/files/$rel" "$SSHD_CONFIG"
        if sshd_validate; then
            ssh_restart
            log_warn "Previous SSH configuration restored and reloaded"
        else
            log_error "CRITICAL: restored config also invalid - manual intervention required!"
        fi
    else
        log_error "No backup available for $SSHD_CONFIG"
    fi
    register_error "ssh configuration restored from backup"
    return 1
}
