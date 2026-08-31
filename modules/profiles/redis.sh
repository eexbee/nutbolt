#!/usr/bin/env bash
# =============================================================================
# modules/profiles/redis.sh - Redis profile
# - vm.overcommit_memory=1
# - net.core.somaxconn=65535 (base value, reinforced here)
# - disable Transparent Huge Pages (runtime + persistent systemd unit)
# - LimitNOFILE override for redis service
# =============================================================================

profile_redis_run() {
    log_section "PROFILE: Redis"

    # --- required sysctl ------------------------------------------------------------
    sysctl_write_profile redis <<'EOF'
# redis profile - managed by server-hardening (per Redis documentation)
vm.overcommit_memory = 1
net.core.somaxconn = 65535
EOF

    # --- disable THP -------------------------------------------------------------------
    if [[ -e /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        local thp_unit="/etc/systemd/system/hardening-disable-thp.service"
        [[ ! -f "$thp_unit" ]] && track_created "$thp_unit"
        cat > "$thp_unit" <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages (Redis recommendation)
Before=redis.service redis-server.service multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'

[Install]
WantedBy=multi-user.target
EOF
        run_quiet systemctl daemon-reload
        run_quiet systemctl enable --now hardening-disable-thp.service
        run_quiet systemctl restart hardening-disable-thp.service
        local thp
        thp="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null | awk -F'[][]' '{print $2}')"
        log_ok "Transparent Huge Pages: ${thp:-unknown} ([never] expected)"
    else
        log_info "THP not available on this kernel - skipping"
    fi

    # --- service override ---------------------------------------------------------------
    if svc_exists redis; then
        systemd_override_limit redis "$(config_get "limits.nofile_default" 65535)"
        log_warn "Restart redis to apply: systemctl restart redis"
    elif svc_exists redis-server; then
        systemd_override_limit redis-server "$(config_get "limits.nofile_default" 65535)"
        log_warn "Restart redis-server to apply: systemctl restart redis-server"
    else
        log_info "Redis service not present (kernel tuning still applied)"
    fi

    log_ok "Redis profile applied (overcommit_memory=1, somaxconn=65535)"
}
