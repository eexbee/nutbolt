#!/usr/bin/env bash
# =============================================================================
# audit/checks.sh - Individual security checks
# Each check registers: id | weight | description | result | details
# Results are stored in arrays used by scoring.sh and report.sh
# =============================================================================

AUDIT_CHECK_IDS=()
AUDIT_CHECK_DESCS=()
AUDIT_CHECK_WEIGHTS=()
AUDIT_CHECK_RESULTS=()   # 1 = pass, 0 = fail
AUDIT_CHECK_DETAILS=()

audit_register() { # audit_register <id> <weight> <description> <pass:0|1> <details>
    AUDIT_CHECK_IDS+=("$1")
    AUDIT_CHECK_WEIGHTS+=("$2")
    AUDIT_CHECK_DESCS+=("$3")
    AUDIT_CHECK_RESULTS+=("$4")
    AUDIT_CHECK_DETAILS+=("$5")
}

# ---------------------------------------------------------------------------
# effective sshd value
_sshd_val() { /usr/sbin/sshd -T 2>/dev/null | awk -v k="$1" 'tolower($1)==k {print $2; exit}'; }

run_all_checks() {
    _check_ssh_port
    _check_ssh_root
    _check_ssh_password
    _check_ssh_maxauth
    _check_firewall_active
    _check_firewall_default_deny
    _check_fail2ban_installed
    _check_fail2ban_running
    _check_fail2ban_sshd
    _check_clamav_installed
    _check_clamav_fresh
    _check_updates
    _check_syncookies
    _check_somaxconn
    _check_redirects
    _check_source_route
    _check_nofile
}

# --- SSH -------------------------------------------------------------------
_check_ssh_port() {
    local p; p="$(_sshd_val port)"; [[ -z "$p" ]] && p=22
    if [[ "$p" != "22" ]]; then
        audit_register ssh_port 5 "SSH runs on non-default port" 1 "port $p"
    else
        audit_register ssh_port 5 "SSH runs on non-default port" 0 "still on port 22"
    fi
}

_check_ssh_root() {
    local v; v="$(_sshd_val permitrootlogin)"
    if [[ "$v" == "no" ]]; then
        audit_register ssh_root 10 "Root login disabled" 1 "PermitRootLogin no"
    else
        audit_register ssh_root 10 "Root login disabled" 0 "PermitRootLogin $v"
    fi
}

_check_ssh_password() {
    local v; v="$(_sshd_val passwordauthentication)"
    if [[ "$v" == "no" ]]; then
        audit_register ssh_password 10 "Password authentication disabled" 1 "key-only login"
    else
        audit_register ssh_password 10 "Password authentication disabled" 0 "password login allowed"
    fi
}

_check_ssh_maxauth() {
    local v; v="$(_sshd_val maxauthtries)"
    if [[ -n "$v" && "$v" -le 5 ]]; then
        audit_register ssh_maxauth 5 "SSH MaxAuthTries <= 5" 1 "MaxAuthTries $v"
    else
        audit_register ssh_maxauth 5 "SSH MaxAuthTries <= 5" 0 "MaxAuthTries ${v:-unset}"
    fi
}

# --- Firewall -----------------------------------------------------------------
_check_firewall_active() {
    local ok=0 details=""
    if [[ "$FIREWALL" == "ufw" ]]; then
        if ufw status 2>/dev/null | grep -q "Status: active"; then ok=1; details="ufw active"; fi
    else
        if svc_active firewalld; then ok=1; details="firewalld active"; fi
    fi
    audit_register fw_active 10 "Firewall is active" $ok "${details:-firewall not active}"
}

_check_firewall_default_deny() {
    local ok=0 details=""
    if [[ "$FIREWALL" == "ufw" ]]; then
        if ufw status verbose 2>/dev/null | grep -q "Default: deny (incoming)"; then
            ok=1; details="ufw default deny incoming"
        fi
    else
        if svc_active firewalld; then
            local target
            target="$(firewall-cmd --get-default-zone 2>/dev/null | xargs -I{} firewall-cmd --zone={} --get-target 2>/dev/null)"
            if [[ "$target" == "default" || "$target" == "DROP" || "$target" == "%%REJECT%%" ]]; then
                ok=1; details="firewalld $(firewall-cmd --get-default-zone) zone blocks unsolicited inbound"
            fi
        fi
    fi
    audit_register fw_default 5 "Firewall default-deny incoming" $ok "${details:-default incoming policy not verified}"
}

# --- Fail2ban --------------------------------------------------------------------
_check_fail2ban_installed() {
    if command -v fail2ban-server &>/dev/null; then
        audit_register f2b_installed 5 "Fail2ban installed" 1 "$(fail2ban-server --version 2>/dev/null | head -1)"
    else
        audit_register f2b_installed 5 "Fail2ban installed" 0 "not installed"
    fi
}

_check_fail2ban_running() {
    if svc_active fail2ban; then
        audit_register f2b_running 5 "Fail2ban running" 1 "service active"
    else
        audit_register f2b_running 5 "Fail2ban running" 0 "service inactive"
    fi
}

_check_fail2ban_sshd() {
    if fail2ban-client status sshd &>/dev/null; then
        audit_register f2b_sshd 5 "Fail2ban sshd jail enabled" 1 "jail active"
    else
        audit_register f2b_sshd 5 "Fail2ban sshd jail enabled" 0 "jail not active"
    fi
}

# --- ClamAV ------------------------------------------------------------------------
_check_clamav_installed() {
    if command -v clamscan &>/dev/null; then
        audit_register clamav_installed 5 "ClamAV installed" 1 "clamscan present"
    else
        audit_register clamav_installed 5 "ClamAV installed" 0 "not installed"
    fi
}

_check_clamav_fresh() {
    local log="/var/log/clamav/freshclam.log"
    local dbdir
    for dbdir in /var/lib/clamav /var/clamav; do
        if [[ -d "$dbdir" ]] && find "$dbdir" -name '*.c?d' -mmin -10080 &>/dev/null | grep -q .; then
            audit_register clamav_fresh 5 "Antivirus definitions updated (7d)" 1 "$dbdir"
            return
        fi
    done
    if [[ -f "$log" ]] && grep -qiE 'updated|up to date' <(tail -50 "$log" 2>/dev/null); then
        audit_register clamav_fresh 5 "Antivirus definitions updated (7d)" 1 "freshclam log ok"
    else
        audit_register clamav_fresh 5 "Antivirus definitions updated (7d)" 0 "definitions stale or unknown"
    fi
}

# --- Updates -------------------------------------------------------------------------
_check_updates() {
    local ok=0 details=""
    if [[ "$OS_FAMILY" == "debian" ]]; then
        if grep -q 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null \
           && systemctl is-enabled unattended-upgrades &>/dev/null; then
            ok=1; details="unattended-upgrades enabled"
        fi
    else
        if svc_active dnf-automatic.timer; then
            ok=1; details="dnf-automatic.timer active ($(grep -E '^upgrade_type' /etc/dnf/automatic.conf 2>/dev/null))"
        fi
    fi
    audit_register updates 10 "Automatic security updates enabled" $ok "${details:-not enabled}"
}

# --- Kernel ------------------------------------------------------------------------------
_check_syncookies() {
    local v; v="$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null)"
    audit_register syncookies 4 "tcp_syncookies=1" "$( [[ "$v" == "1" ]] && echo 1 || echo 0 )" "value=${v:-?}"
}

_check_somaxconn() {
    local v; v="$(sysctl -n net.core.somaxconn 2>/dev/null)"
    local ok=0
    [[ -n "$v" && "$v" -ge 65535 ]] && ok=1
    audit_register somaxconn 4 "somaxconn >= 65535" $ok "value=${v:-?}"
}

_check_redirects() {
    local v1 v2 ok=0
    v1="$(sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null)"
    v2="$(sysctl -n net.ipv4.conf.default.accept_redirects 2>/dev/null)"
    [[ "$v1" == "0" && "$v2" == "0" ]] && ok=1
    audit_register redirects 4 "ICMP redirects disabled" $ok "all=$v1 default=$v2"
}

_check_source_route() {
    local v1 v2 ok=0
    v1="$(sysctl -n net.ipv4.conf.all.accept_source_route 2>/dev/null)"
    v2="$(sysctl -n net.ipv4.conf.default.accept_source_route 2>/dev/null)"
    [[ "$v1" == "0" && "$v2" == "0" ]] && ok=1
    audit_register source_route 3 "Source routing disabled" $ok "all=$v1 default=$v2"
}

# --- Limits ---------------------------------------------------------------------------------
_check_nofile() {
    local ok=0 details="no nofile limit >= 65535 found"
    local f best=0
    for f in /etc/security/limits.conf /etc/security/limits.d/*.conf; do
        [[ -f "$f" ]] || continue
        local v
        v="$(awk '$1=="*" && $3=="nofile" {print $4}' "$f" | sort -n | tail -1)"
        [[ -n "$v" && "$v" -gt "$best" ]] && best="$v"
    done
    if (( best >= 65535 )); then ok=1; details="wildcard nofile=$best"; fi
    audit_register nofile 5 "nofile limit >= 65535" $ok "$details"
}
