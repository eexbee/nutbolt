#!/usr/bin/env bash
# =============================================================================
# modules/updates.sh - Automatic SECURITY-ONLY updates
# Ubuntu -> unattended-upgrades (security origin only)
# RHEL   -> dnf-automatic (upgrade_type = security)
# Feature/major upgrades are never installed automatically.
# =============================================================================

module_updates_run() {
    log_section "MODULE: Automatic security updates"

    config_get_bool "security.updates.enabled" true || { log_info "Automatic updates disabled in config"; return 0; }

    if [[ "$OS_FAMILY" == "debian" ]]; then
        _updates_ubuntu
    else
        _updates_rhel
    fi
}

_updates_ubuntu() {
    pkg_install unattended-upgrades

    local auto="/etc/apt/apt.conf.d/20auto-upgrades"
    [[ ! -f "$auto" ]] && track_created "$auto"
    cat > "$auto" <<'EOF'
// managed by server-hardening
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # restrict to security origin only (no feature/point upgrades)
    local uu="/etc/apt/apt.conf.d/50unattended-upgrades"
    if [[ -f "$uu" ]]; then
        backup_file_once "$uu"
        # comment out non-security origins (e.g. ${distro_codename}-updates)
        sed -i -E 's/^(\s*)"?\$\{distro_id\}:\$\{distro_codename\}-updates"?;/\/\/\1removed by server-hardening (security-only);/' "$uu"
        sed -i -E 's/^(\s*)"?\$\{distro_id\}:\$\{distro_codename\}-proposed"?;/\/\/\1removed by server-hardening (security-only);/' "$uu"
    fi

    # never auto-reboot production servers
    cat > /etc/apt/apt.conf.d/51hardening-noreboot <<'EOF'
// managed by server-hardening - never reboot automatically
Unattended-Upgrade::Automatic-Reboot "false";
EOF
    track_created /etc/apt/apt.conf.d/51hardening-noreboot

    # activate immediately
    run_quiet systemctl enable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer
    log_ok "unattended-upgrades enabled (security-only, no auto-reboot)"
}

_updates_rhel() {
    pkg_install dnf-automatic
    local conf="/etc/dnf/automatic.conf"
    if [[ -f "$conf" ]]; then
        backup_file_once "$conf"
        sed -i -E 's/^\s*upgrade_type\s*=.*/upgrade_type = security/' "$conf"
        sed -i -E 's/^\s*apply_updates\s*=.*/apply_updates = yes/' "$conf"
        # make sure section headers exist before our keys if missing
        grep -q '^upgrade_type' "$conf" || echo "upgrade_type = security" >> "$conf"
        grep -q '^apply_updates' "$conf" || echo "apply_updates = yes" >> "$conf"
    fi
    run_quiet systemctl enable --now dnf-automatic.timer
    svc_active dnf-automatic.timer && log_ok "dnf-automatic enabled (security-only)" \
        || { log_error "dnf-automatic.timer not active"; register_error "dnf-automatic timer"; }
}
