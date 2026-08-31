#!/usr/bin/env bash
# =============================================================================
# modules/fail2ban.sh - Fail2ban intrusion prevention
# - SSH jail:      maxretry=5, bantime=1h
# - Web jails:     nginx / apache / OpenLiteSpeed (when detected or profile)
# =============================================================================

module_fail2ban_run() {
    log_section "MODULE: Fail2ban"

    config_get_bool "security.fail2ban.enabled" true || { log_info "Fail2ban disabled in config"; return 0; }

    local maxretry bantime findtime
    maxretry="$(config_get "security.fail2ban.maxretry" "5")"
    bantime="$(config_get "security.fail2ban.bantime" "1h")"
    findtime="$(config_get "security.fail2ban.findtime" "10m")"

    # --- install ------------------------------------------------------------------
    if ! pkg_installed fail2ban; then
        [[ "$OS_FAMILY" == "rhel" ]] && ensure_epel
        pkg_install fail2ban
    fi
    command -v fail2ban-server &>/dev/null || { log_error "fail2ban installation failed"; register_error "fail2ban install"; return 1; }

    # --- configuration ------------------------------------------------------------
    local jaildir="/etc/fail2ban/jail.d"
    mkdir -p "$jaildir"
    local jailfile="$jaildir/99-nutbolt.local"
    [[ ! -f "$jailfile" ]] && track_created "$jailfile"

    local banaction
    if [[ "$FIREWALL" == "ufw" ]]; then
        banaction="iptables-multiport"
    else
        banaction="firewallcmd-rich-rules"
    fi

    local ssh_port="${SSH_NEW_PORT:-$(config_get 'ssh.port' 22)}"

    {
        echo "# managed by nutbolt"
        echo "[DEFAULT]"
        echo "bantime  = $bantime"
        echo "findtime = $findtime"
        echo "maxretry = $maxretry"
        echo "banaction = $banaction"
        echo ""
        echo "[sshd]"
        echo "enabled = true"
        echo "port    = $ssh_port"
    } > "$jailfile"

    log_ok "Fail2ban jail written: $jailfile (sshd: maxretry=$maxretry bantime=$bantime)"

    # --- web protection ------------------------------------------------------------
    if config_get_bool "security.fail2ban.protect_web" true; then
        _fail2ban_web_jails "$jailfile"
    fi

    # --- start ---------------------------------------------------------------------
    svc_enable  fail2ban
    svc_restart fail2ban
    sleep 2
    if svc_active fail2ban; then
        log_ok "Fail2ban is running"
        run_quiet fail2ban-client status
    else
        log_error "Fail2ban failed to start - check: journalctl -u fail2ban -n 50"
        register_error "fail2ban not running"
        return 1
    fi
}

_fail2ban_web_jails() {
    local jailfile="$1"
    local detected=""
    svc_active nginx 2>/dev/null && detected+=" nginx"
    svc_active apache2 2>/dev/null && detected+=" apache"
    svc_active httpd 2>/dev/null && detected+=" apache"
    svc_active lsws 2>/dev/null || svc_active openlitespeed 2>/dev/null && detected+=" ols"
    command -v nginx &>/dev/null && detected+=" nginx"
    command -v lshttpd &>/dev/null || [[ -d /usr/local/lsws ]] && detected+=" ols"

    local appended=""
    if [[ "$detected" == *nginx* ]]; then
        cat >> "$jailfile" <<'EOF'

[nginx-http-auth]
enabled = true
port    = http,https
logpath = /var/log/nginx/error.log
EOF
        appended+=" nginx-http-auth"
    fi
    if [[ "$detected" == *apache* ]]; then
        cat >> "$jailfile" <<'EOF'

[apache-auth]
enabled = true
port    = http,https
logpath = /var/log/*error*.log
EOF
        appended+=" apache-auth"
    fi
    if [[ "$detected" == *ols* ]]; then
        _fail2ban_ols_filter
        cat >> "$jailfile" <<'EOF'

[openlitespeed-auth]
enabled  = true
port     = http,https
logpath  = /usr/local/lsws/logs/error.log
filter   = openlitespeed-auth
maxretry = 5
EOF
        appended+=" openlitespeed-auth"
    fi
    [[ -n "$appended" ]] && log_ok "Web jails enabled:$appended"
    return 0
}

_fail2ban_ols_filter() {
    local f="/etc/fail2ban/filter.d/openlitespeed-auth.conf"
    [[ ! -f "$f" ]] && track_created "$f"
    cat > "$f" <<'EOF'
# managed by nutbolt - OpenLiteSpeed auth failures
[Definition]
failregex = ^.*\[ERROR\].*(failed to login|auth.*fail|permission denied).*$
            ^.*"(GET|POST) /[^"]*" (401|403) .*$
ignoreregex =
EOF
}
