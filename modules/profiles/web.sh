#!/usr/bin/env bash
# =============================================================================
# modules/profiles/web.sh - Web server profile (nginx / Apache / OpenLiteSpeed)
# - TCP backlog + network tuning (safe sysctl)
# - raised file limits (systemd LimitNOFILE override)
# =============================================================================

profile_web_run() {
    log_section "PROFILE: Web"

    # --- network tuning (safe) -----------------------------------------------------
    sysctl_write_profile web <<'EOF'
# web profile - managed by server-hardening
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_slow_start_after_idle = 0
EOF

    # --- detected web servers --------------------------------------------------------
    local detected=""
    svc_active nginx && detected+="nginx "
    (svc_active apache2 || svc_active httpd) && detected+="apache "
    (svc_active lsws || [[ -d /usr/local/lsws ]]) && detected+="openlitespeed "

    if [[ -z "$detected" ]] && [[ "$INTERACTIVE" == "1" ]]; then
        log_info "No web server detected (profile still applies kernel/file tuning)"
    fi
    log_info "Web servers detected: ${detected:-none}"

    local nofile
    nofile="$(config_get "limits.nofile_default" 65535)"

    if [[ "$detected" == *nginx* ]]; then
        systemd_override_limit nginx "$nofile"
        log_info "nginx hint: consider worker_rlimit_nofile $nofile; worker_connections 4096"
    fi
    if [[ "$detected" == *apache* ]]; then
        if svc_active apache2; then systemd_override_limit apache2 "$nofile"; else systemd_override_limit httpd "$nofile"; fi
    fi
    if [[ "$detected" == *openlitespeed* ]]; then
        log_info "OpenLiteSpeed: limits are managed in Admin Console (Server > Tuning)"
    fi

    log_ok "Web profile applied"
}
