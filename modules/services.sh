#!/usr/bin/env bash
# =============================================================================
# modules/services.sh - Disable unnecessary services (conservative)
# Only disables services explicitly listed in config (services.disable).
# Default list is empty: the framework never guesses what you might need.
# =============================================================================

module_services_run() {
    log_section "MODULE: Service cleanup"

    local list
    list="$(config_get_list_csv "services.disable" "")"
    if [[ -z "$list" ]] && [[ "$INTERACTIVE" == "1" ]]; then
        log_info "No services.disable list configured"
        cat <<'EOF'
  Suggested candidates (usually safe on servers, YOUR choice):
    avahi-daemon  cups  bluetooth  rpcbind  nfs-common
EOF
        local ans
        ans="$(prompt "Services to disable (space separated, empty to skip)" "")"
        list="${ans//,/ }"
    fi

    [[ -z "$list" ]] && { log_info "No services selected for disabling"; return 0; }

    local s
    for s in $list; do
        s="${s%.service}"
        if svc_exists "$s"; then
            if svc_active "$s"; then
                run_quiet systemctl disable --now "$s"
                log_ok "Disabled+stopped: $s"
            else
                run_quiet systemctl disable "$s" 2>/dev/null
                log_ok "Disabled (was inactive): $s"
            fi
            echo "$s" >> "$BACKUP_DIR/disabled-services"
        else
            log_info "Service not present: $s (skipped)"
        fi
    done
}
