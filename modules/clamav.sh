#!/usr/bin/env bash
# =============================================================================
# modules/clamav.sh - ClamAV antivirus
# - installs ClamAV + daemon + signature updater
# - provides /usr/local/bin/security-scan (nice + ionice, safe exclusions)
# - database directories / Docker storage / MinIO data are excluded from
#   scanning unless explicitly enabled in configuration.
# =============================================================================

module_clamav_run() {
    log_section "MODULE: ClamAV"

    config_get_bool "security.clamav.enabled" true || { log_info "ClamAV disabled in config"; return 0; }

    # --- install ------------------------------------------------------------------
    if [[ "$OS_FAMILY" == "debian" ]]; then
        pkg_install clamav clamav-daemon clamav-freshclam
    else
        ensure_epel
        pkg_install clamav clamav-update clamd
    fi
    command -v clamscan &>/dev/null || { log_error "ClamAV installation failed"; register_error "clamav install"; return 1; }

    # --- signature update service ---------------------------------------------------
    if [[ "$OS_FAMILY" == "debian" ]]; then
        svc_enable  clamav-freshclam
        svc_restart clamav-freshclam
        svc_enable  clamav-daemon
        svc_restart clamav-daemon || log_warn "clamav-daemon may still be loading initial signatures"
    else
        # RHEL: freshclam via clamav-update + clamd@scan
        if [[ -f /etc/sysconfig/freshclam ]] || [[ -f /etc/freshclam.conf ]]; then
            if [[ -f /etc/cron.d/clamav-update ]]; then
                backup_file_once /etc/cron.d/clamav-update
                sed -i 's/^#\s*FRESHCLAM_DELAY/FRESHCLAM_DELAY/' /etc/cron.d/clamav-update 2>/dev/null || true
            fi
        fi
        if svc_exists clamav-freshclam.service; then
            svc_enable  clamav-freshclam
            svc_restart clamav-freshclam
        elif svc_exists clamd@scan.service; then
            # allow LocalSocket for clamdscan
            if [[ -f /etc/clamd.d/scan.conf ]]; then
                backup_file_once /etc/clamd.d/scan.conf
                sed -i 's/^#\s*LocalSocket\s.*$/LocalSocket \/run\/clamd.scan\/clamd.sock/' /etc/clamd.d/scan.conf
                sed -i 's/^#\s*Example$//' /etc/clamd.d/scan.conf
            fi
            svc_enable  clamd@scan
            svc_restart clamd@scan
        fi
    fi

    # --- security-scan command -------------------------------------------------------
    _clamav_install_security_scan

    # --- optional daily scan ----------------------------------------------------------
    if config_get_bool "security.clamav.daily_scan" false; then
        local cronfile="/etc/cron.d/security-scan"
        [[ ! -f "$cronfile" ]] && track_created "$cronfile"
        local hour
        hour="$(config_get "security.clamav.daily_scan_hour" "3")"
        cat > "$cronfile" <<EOF
# managed by nutbolt - daily ClamAV scan
0 $hour * * * root /usr/local/bin/security-scan / --quiet >> /var/log/security-scan.log 2>&1
EOF
        chmod 644 "$cronfile"
        log_ok "Daily scan scheduled at $hour:00 -> /var/log/security-scan.log"
    fi

    log_ok "ClamAV module finished"
    log_ok "Usage: security-scan /path/to/scan"
}

_clamav_install_security_scan() {
    local scan_bin="/usr/local/bin/security-scan"
    [[ ! -f "$scan_bin" ]] && track_created "$scan_bin"

    # Build exclude-dir regex list
    local -a excludes=()
    if config_get_bool "security.clamav.exclude_defaults" true; then
        excludes+=('/var/lib/mysql' '/var/lib/postgresql' '/var/lib/docker' '/var/lib/containerd' '/var/lib/minio' '/mnt/minio' '/srv/minio' '/var/lib/redis')
    fi
    local x
    while IFS= read -r x; do
        [[ -n "$x" ]] && excludes+=("$x")
    done < <(config_get_list "security.clamav.exclude_paths")

    local excl_args=""
    for x in "${excludes[@]}"; do
        excl_args+=" --exclude-dir=\"^$x\""
    done

    cat > "$scan_bin" <<EOF
#!/usr/bin/env bash
# =============================================================================
# security-scan - ClamAV on-demand scanner installed by nutbolt
# Runs with low CPU/IO priority (nice + ionice) to protect production load.
# Usage:   security-scan [path]      (default: /)
#          security-scan /www --quiet
# Exit:    0 = clean, 1 = infected, 2 = error
# =============================================================================
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TARGET="\${1:-/}"
QUIET_MODE="\${2:-}"

SCAN_CMD=(clamscan)
# use clamdscan when the daemon is available (much faster, shared signatures)
if command -v clamdscan >/dev/null 2>&1 && clamdscan --ping 2>/dev/null; then
    SCAN_CMD=(clamdscan --multiscan --fdpass)
fi

echo "Scanning: \$TARGET (engine: \${SCAN_CMD[0]})"
nice -n 19 ionice -c3 "\${SCAN_CMD[@]}" --infected --recursive \$QUIET_MODE$excl_args "\$TARGET"
rc=\$?
case \$rc in
    0) echo "RESULT: CLEAN"; exit 0 ;;
    1) echo "RESULT: INFECTED FILES FOUND"; exit 1 ;;
    *) echo "RESULT: ERROR (exit \$rc)"; exit 2 ;;
esac
EOF
    chmod 755 "$scan_bin"
    log_ok "Installed: $scan_bin"
}
