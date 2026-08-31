#!/usr/bin/env bash
# =============================================================================
# modules/limits.sh - Resource limits (open files / nofile)
# Default  : 65535
# Database : 100000   (mariadb/mysql/postgres users)
# MinIO    : 200000  (minio user)
# When multiple profiles are combined the * wildcard limit is the maximum.
# =============================================================================

module_limits_run() {
    log_section "MODULE: Resource limits"

    local base db minio nofile
    base="$(config_get  "limits.nofile_default"  "65535")"
    db="$(config_get   "limits.nofile_database" "100000")"
    minio="$(config_get "limits.nofile_minio"    "200000")"

    # wildcard limit = max of base + enabled profiles
    nofile="$base"
    profile_enabled database && (( db > nofile )) && nofile="$db"
    profile_enabled minio    && (( minio > nofile )) && nofile="$minio"
    LIMITS_NOFILE="$nofile"

    local f="/etc/security/limits.d/99-server-hardening.conf"
    [[ ! -f "$f" ]] && track_created "$f"
    backup_file_once /etc/security/limits.conf

    {
        echo "# managed by server-hardening"
        echo "*    soft nofile $nofile"
        echo "*    hard nofile $nofile"
        echo "root soft nofile $nofile"
        echo "root hard nofile $nofile"
    } > "$f"

    log_ok "nofile limit ($nofile) written to $f"
    log_info "Per-service systemd LimitNOFILE overrides are handled by profile modules"
}

profile_enabled() { # profile_enabled "web" -> 0 if profile active
    [[ "${ACTIVE_PROFILES:-}" == *"$1"* ]]
}

# ---------------------------------------------------------------------------
# helper used by profile modules: systemd_override <unit> <LimitNOFILE>
# does NOT restart the unit (production safety) - takes effect on next restart
# ---------------------------------------------------------------------------
systemd_override_limit() {
    local unit="$1" nofile="$2"
    local dir="/etc/systemd/system/${unit}.d"
    mkdir -p "$dir"
    local f="$dir/99-server-hardening.conf"
    [[ ! -f "$f" ]] && track_created "$f"
    cat > "$f" <<EOF
# managed by server-hardening - takes effect on next service restart
[Service]
LimitNOFILE=$nofile
EOF
    run_quiet systemctl daemon-reload
    log_ok "systemd override: $unit LimitNOFILE=$nofile (applies on next restart)"
}
