#!/usr/bin/env bash
# =============================================================================
# modules/profiles/database.sh - Database profile
# MariaDB / MySQL / PostgreSQL
# - file descriptors: nofile 100000 (limits.conf + systemd override)
# - IO-related settings (conservative swappiness / dirty ratios)
# Databases are NEVER restarted automatically - overrides apply on next restart.
# =============================================================================

profile_database_run() {
    log_section "PROFILE: Database"

    local nofile
    nofile="$(config_get "limits.nofile_database" 100000)"

    # --- IO-related sysctl (conservative) --------------------------------------------
    sysctl_write_profile database <<'EOF'
# database profile - managed by nutbolt
vm.swappiness = 10
vm.dirty_background_ratio = 10
vm.dirty_ratio = 20
EOF

    # --- limits.conf per database user -------------------------------------------------
    local f="/etc/security/limits.d/99-nutbolt-database.conf"
    [[ ! -f "$f" ]] && track_created "$f"
    : > "$f"
    local user
    for user in mysql postgres; do
        if id "$user" &>/dev/null; then
            {
                echo "# managed by nutbolt - database profile"
                echo "$user soft nofile $nofile"
                echo "$user hard nofile $nofile"
                echo "$user soft nproc  65535"
                echo "$user hard nproc  65535"
            } >> "$f"
            log_ok "limits.conf: $user nofile=$nofile"
        fi
    done

    # --- systemd overrides --------------------------------------------------------------
    local detected=""
    if svc_exists mariadb; then
        systemd_override_limit mariadb "$nofile"
        detected+="mariadb "
    fi
    if svc_exists mysqld; then
        systemd_override_limit mysqld "$nofile"
        detected+="mysql "
    fi
    if svc_exists postgresql \
        || systemctl list-unit-files 2>/dev/null | grep -qE '^postgresql-[0-9]+\.service'; then
        systemd_override_limit postgresql "$nofile"
        detected+="postgresql "
    fi

    if [[ -z "$detected" ]] && [[ "$INTERACTIVE" == "1" ]]; then
        log_info "No database service detected (kernel/IO tuning still applied)"
    else
        log_info "Databases detected: ${detected:-none}"
        log_warn "LimitNOFILE overrides take effect on the NEXT database restart"
    fi

    log_ok "Database profile applied (nofile=$nofile, swappiness=10)"
}
