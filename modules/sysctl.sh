#!/usr/bin/env bash
# =============================================================================
# modules/sysctl.sh - Safe kernel parameter hardening
# Base (always applied, safe for production):
#   net.ipv4.tcp_syncookies=1
#   net.core.somaxconn=65535
#   fs.inotify.max_user_watches=524288
#   redirects + source routing disabled (v4+v6)
# Profiles append their own file: /etc/sysctl.d/98-profile-<name>.conf
# =============================================================================

SYSCTL_FILE="/etc/sysctl.d/99-server-hardening.conf"

module_sysctl_run() {
    log_section "MODULE: Kernel settings (sysctl)"

    backup_snapshot "sysctl-pre" \
        "sysctl net.ipv4.tcp_syncookies net.core.somaxconn fs.inotify.max_user_watches net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.accept_source_route vm.overcommit_memory vm.swappiness"

    [[ ! -f "$SYSCTL_FILE" ]] && track_created "$SYSCTL_FILE"

    cat > "$SYSCTL_FILE" <<'EOF'
# managed by server-hardening - safe production defaults
net.ipv4.tcp_syncookies = 1
net.core.somaxconn = 65535
fs.inotify.max_user_watches = 524288

# disable ICMP redirects (accept/send)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# log martian packets
net.ipv4.conf.all.log_martians = 1
EOF

    if run_quiet sysctl --system; then
        log_ok "sysctl applied: $SYSCTL_FILE"
    else
        log_warn "sysctl --system returned errors - check log"
    fi

    # verify key settings took effect
    local checks=(
        "net.ipv4.tcp_syncookies:1"
        "net.core.somaxconn:65535"
        "net.ipv4.conf.all.accept_redirects:0"
        "net.ipv4.conf.all.accept_source_route:0"
    )
    local c k want got
    for c in "${checks[@]}"; do
        k="${c%%:*}"; want="${c##*:}"
        got="$(sysctl -n "$k" 2>/dev/null)"
        if [[ "$got" == "$want" ]]; then
            log_ok "  $k = $got"
        else
            log_warn "  $k = ${got:-?} (expected $want) - possibly overridden elsewhere"
        fi
    done
}

# ---------------------------------------------------------------------------
# helper used by profile modules
# ---------------------------------------------------------------------------
sysctl_write_profile() { # sysctl_write_profile <name>  (reads stdin)
    local name="$1"
    local f="/etc/sysctl.d/98-profile-${name}.conf"
    [[ ! -f "$f" ]] && track_created "$f"
    cat > "$f"
    run_quiet sysctl --system
    log_ok "Profile sysctl applied: $f"
}
