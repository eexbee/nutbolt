#!/usr/bin/env bash
# =============================================================================
# modules/profiles/minio.sh - MinIO / object storage profile
# - file limits: nofile 200000 (limits.conf + systemd override)
# - storage workload sysctl tuning
# =============================================================================

profile_minio_run() {
    log_section "PROFILE: MinIO / object storage"

    local nofile
    nofile="$(config_get "limits.nofile_minio" 200000)"

    # --- storage workload sysctl ---------------------------------------------------
    sysctl_write_profile minio <<'EOF'
# minio profile - managed by server-hardening
fs.aio-max-nr = 1048576
fs.file-max = 2097152
vm.dirty_background_ratio = 5
vm.dirty_ratio = 15
EOF

    # --- limits.conf ------------------------------------------------------------------
    local f="/etc/security/limits.d/99-server-hardening-minio.conf"
    [[ ! -f "$f" ]] && track_created "$f"
    : > "$f"
    local user
    for user in minio minio-user; do
        if id "$user" &>/dev/null; then
            {
                echo "# managed by server-hardening - minio profile"
                echo "$user soft nofile $nofile"
                echo "$user hard nofile $nofile"
            } >> "$f"
            log_ok "limits.conf: $user nofile=$nofile"
        fi
    done

    # --- systemd override --------------------------------------------------------------
    if svc_exists minio; then
        systemd_override_limit minio "$nofile"
        log_warn "Restart minio to apply: systemctl restart minio"
    else
        log_info "minio service not found (limits still set for users wildcard + minio user if present)"
        log_info "XFS is the recommended filesystem for MinIO data volumes"
    fi

    log_ok "MinIO profile applied (nofile=$nofile)"
}
