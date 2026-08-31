#!/usr/bin/env bash
# =============================================================================
# modules/user.sh - Administrator user creation
# - creates the admin user
# - grants sudo (Debian) / wheel (RHEL) privileges
# - installs the SSH public key into authorized_keys
# =============================================================================

module_user_run() {
    log_section "MODULE: Administrator user"

    ADMIN_USERNAME="$(config_get "ssh.new_admin_user" "")"

    if [[ -z "$ADMIN_USERNAME" && "$INTERACTIVE" == "1" ]]; then
        ADMIN_USERNAME="$(prompt_until_valid "Enter administrator username" validate_username "" \
            "Username must match ^[a-z_][a-z0-9_-]{0,31}$ (lowercase)")"
    elif [[ -z "$ADMIN_USERNAME" ]]; then
        log_warn "No admin username configured - skipping user creation"
        return 0
    fi

    # --- create user (interactive retry when the name cannot be used) --------
    local newly_created=0
    while true; do
        if id "$ADMIN_USERNAME" &>/dev/null; then
            log_info "User '$ADMIN_USERNAME' already exists - ensuring privileges and key"
            break
        fi

        log_info "Creating user: $ADMIN_USERNAME"
        local uadd_err=""
        if uadd_err="$(useradd -m -s /bin/bash "$ADMIN_USERNAME" 2>&1)"; then
            log_ok "User created: $ADMIN_USERNAME"
            newly_created=1
            break
        fi

        log_error "Failed to create user '$ADMIN_USERNAME': ${uadd_err:-unknown useradd error}"
        if [[ "$INTERACTIVE" != "1" ]]; then
            register_error "user creation failed for '$ADMIN_USERNAME'"
            return 1
        fi

        log_info "The name is probably taken by an existing user or group - choose another one."
        local retry=""
        while true; do
            retry="$(prompt "Enter another administrator username (empty to skip user creation)" "")"
            [[ -z "$retry" ]] && break
            validate_username "$retry" && break
            log_error "Username must match ^[a-z_][a-z0-9_-]{0,31}$ (lowercase)"
        done
        if [[ -z "$retry" ]]; then
            log_warn "User creation skipped - SSH lockdown will keep root login enabled"
            ADMIN_USERNAME=""
            return 1
        fi
        ADMIN_USERNAME="$retry"
    done

    # --- sudo / wheel privileges -------------------------------------------------
    if [[ "$OS_FAMILY" == "debian" ]]; then
        run_quiet apt-get install -y -qq sudo   # ensure sudo present
        if id -nG "$ADMIN_USERNAME" | grep -qw sudo; then
            log_info "User already in 'sudo' group"
        else
            usermod -aG sudo "$ADMIN_USERNAME"
            log_ok "Added '$ADMIN_USERNAME' to sudo group"
        fi
    else
        if id -nG "$ADMIN_USERNAME" | grep -qw wheel; then
            log_info "User already in 'wheel' group"
        else
            usermod -aG wheel "$ADMIN_USERNAME"
            log_ok "Added '$ADMIN_USERNAME' to wheel group"
        fi
        # ensure wheel group has sudo rights (default on Alma/Rocky)
        if grep -qE '^#?\s*%wheel\s+ALL=\(ALL\)\s+ALL' /etc/sudoers 2>/dev/null; then
            sed -i 's/^#\s*%wheel\s\+ALL=(ALL)\s\+ALL/%wheel\tALL=(ALL)\tALL/' /etc/sudoers
        fi
    fi

    # --- SSH public key ----------------------------------------------------------
    local key
    key="$(config_get "ssh.admin_ssh_public_key" "")"
    if [[ -z "$key" && "$INTERACTIVE" == "1" ]]; then
        echo "Paste the administrator SSH public key (single line, empty to skip):"
        key="$(prompt "SSH public key" "")"
    fi

    ADMIN_KEY_INSTALLED=0
    if [[ -n "$key" ]]; then
        if ! validate_ssh_public_key "$key"; then
            log_warn "Provided SSH key does not look valid - skipping installation"
        else
            install_admin_key "$ADMIN_USERNAME" "$key"
            ADMIN_KEY_INSTALLED=1
        fi
    fi

    if [[ "$ADMIN_KEY_INSTALLED" != "1" ]]; then
        log_warn "No SSH public key installed for '$ADMIN_USERNAME'"
        log_warn "PasswordAuthentication will NOT be disabled later without a key"
        # A freshly created account has NO password and NO key - without one of
        # them the operator cannot log in at all (e.g. for the SSH port test).
        if (( newly_created )) && [[ "$INTERACTIVE" == "1" ]]; then
            if confirm "Set a password for '$ADMIN_USERNAME' now so SSH login is possible?" "yes"; then
                if passwd "$ADMIN_USERNAME"; then
                    log_ok "Password set for '$ADMIN_USERNAME'"
                else
                    log_warn "Password not set - you will NOT be able to log in as '$ADMIN_USERNAME'"
                fi
            else
                log_warn "No key and no password - you will NOT be able to log in as '$ADMIN_USERNAME'"
            fi
        fi
    fi
    return 0
}

install_admin_key() {
    local user="$1" key="$2"
    local home dir_auth
    home="$(getent passwd "$user" | cut -d: -f6)"
    dir_auth="$home/.ssh"
    mkdir -p "$dir_auth"
    chmod 700 "$dir_auth"
    touch "$dir_auth/authorized_keys"
    if grep -qF "$key" "$dir_auth/authorized_keys"; then
        log_info "Key already present in authorized_keys"
    else
        echo "$key" >> "$dir_auth/authorized_keys"
    fi
    chmod 600 "$dir_auth/authorized_keys"
    chown -R "$user:$user" "$dir_auth"
    log_ok "SSH public key installed for '$user'"
}
