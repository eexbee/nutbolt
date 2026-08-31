#!/usr/bin/env bash
# =============================================================================
# rollback.sh - Restore server state from a hardening backup
# Restores: SSH, sysctl, limits, firewall (and removes files we created)
#
# Usage:
#   sudo ./rollback.sh            # interactive selection (default: latest)
#   sudo ./rollback.sh <backup-dir-or-timestamp>
#   sudo ./rollback.sh --latest
# =============================================================================
set -u

FRAMEWORK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FRAMEWORK_ROOT

source "$FRAMEWORK_ROOT/lib/logging.sh"
source "$FRAMEWORK_ROOT/lib/common.sh"
source "$FRAMEWORK_ROOT/lib/backup.sh"
source "$FRAMEWORK_ROOT/lib/os_detect.sh"

INTERACTIVE=1
BACKUP_ROOT="$FRAMEWORK_ROOT/backups"
TARGET_BACKUP=""

for arg in "$@"; do
    case "$arg" in
        --latest) TARGET_BACKUP="$(backup_list_available | tail -1)" ;;
        -y|--yes) INTERACTIVE=0 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
        *)  TARGET_BACKUP="$arg" ;;
    esac
done

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo ./rollback.sh)"; exit 1; }

logging_init
log_section "ROLLBACK"

os_detect || true

# ---------------------------------------------------------------- select backup
if [[ -z "$TARGET_BACKUP" ]]; then
    mapfile -t available < <(backup_list_available)
    if (( ${#available[@]} == 0 )); then
        log_error "No backups found in $BACKUP_ROOT"
        exit 1
    fi
    echo "Available backups:"
    i=1
    for b in "${available[@]}"; do
        echo "  $i) $(basename "$b")  ($(grep -c '^BACKUP' "$b/manifest.txt" 2>/dev/null) files, $(grep -c '^CREATED' "$b/manifest.txt" 2>/dev/null) created)"
        i=$((i+1))
    done
    choice="$(prompt "Select backup to restore" "$(( ${#available[@]} ))")"
    TARGET_BACKUP="${available[$(( choice - 1 ))]}"
fi
# accept bare timestamp too
[[ -d "$TARGET_BACKUP" ]] || TARGET_BACKUP="$BACKUP_ROOT/$TARGET_BACKUP"
if [[ ! -f "$TARGET_BACKUP/manifest.txt" ]]; then
    log_error "Not a valid backup: $TARGET_BACKUP (missing manifest.txt)"
    exit 1
fi
log_info "Rolling back to backup: $TARGET_BACKUP"
log_info "Created: $(head -2 "$TARGET_BACKUP/manifest.txt" | grep created | cut -d: -f2-)"

# ---------------------------------------------------------------- plan
restore_files=()   # pairs: orig<TAB>backuprel
remove_created=()
while IFS=$'\t' read -r action path rel; do
    case "$action" in
        BACKUP) restore_files+=("$path"$'\t'"$rel") ;;
        CREATED)
            [[ -e "$path" ]] && remove_created+=("$path")
            ;;
    esac
done < <(grep -E '^(BACKUP|CREATED)' "$TARGET_BACKUP/manifest.txt")

echo ""
echo "Will restore ${#restore_files[@]} file(s):"
printf '  %s\n' "${restore_files[@]//[$'\t']/  <-  }"
echo "Will remove ${#remove_created[@]} created file(s):"
printf '  %s\n' "${remove_created[@]:-none}"
echo ""

if [[ "$INTERACTIVE" == "1" ]]; then
    confirm "Proceed with rollback?" "no" || { log_info "Aborted"; exit 0; }
fi

# ---------------------------------------------------------------- restore files
for pair in "${restore_files[@]}"; do
    orig="${pair%%$'\t'*}"
    rel="${pair##*$'\t'}"
    if [[ -f "$TARGET_BACKUP/$rel" ]]; then
        mkdir -p "$(dirname "$orig")"
        if cp -a "$TARGET_BACKUP/$rel" "$orig"; then
            log_ok "Restored: $orig"
        else
            log_error "Failed to restore: $orig"
        fi
    else
        log_warn "Backup file missing for $orig ($rel)"
    fi
done

# ---------------------------------------------------------------- remove created
for f in "${remove_created[@]}"; do
    if [[ -e "$f" ]]; then
        rm -rf "$f" && log_ok "Removed: $f"
    fi
done

# ---------------------------------------------------------------- firewall rollback
if [[ -f "$TARGET_BACKUP/ufw-added-rules" ]]; then
    rule_file="$TARGET_BACKUP/ufw-added-rules"
    while read -r rule; do
        [[ -z "$rule" ]] && continue
        run_quiet ufw delete allow "$rule"
        log_ok "ufw rule removed: $rule"
    done < "$rule_file"
    # if firewall was inactive before hardening, disable it now
    if grep -qi "Status: inactive" "$TARGET_BACKUP/snapshots/ufw-pre-status" 2>/dev/null; then
        run_quiet ufw --force disable
        log_ok "ufw disabled (was inactive before hardening)"
    else
        run_quiet ufw reload
    fi
fi
if [[ -f "$TARGET_BACKUP/firewalld-added-ports" ]]; then
    while read -r port; do
        [[ -z "$port" ]] && continue
        run_quiet firewall-cmd --permanent --remove-port="$port"
        log_ok "firewalld port removed: $port"
    done < "$TARGET_BACKUP/firewalld-added-ports"
    run_quiet firewall-cmd --reload
fi

# ---------------------------------------------------------------- re-enable disabled services
if [[ -f "$TARGET_BACKUP/disabled-services" ]]; then
    while read -r s; do
        [[ -z "$s" ]] && continue
        run_quiet systemctl enable --now "$s" 2>/dev/null \
            && log_ok "Service re-enabled: $s"
    done < "$TARGET_BACKUP/disabled-services"
fi

# ---------------------------------------------------------------- reload daemons
log_info "Reloading system configuration"
run_quiet systemctl daemon-reload
run_quiet sysctl --system

# restore runtime sysctl values captured before hardening
if [[ -f "$TARGET_BACKUP/snapshots/sysctl-pre" ]]; then
    while read -r k v; do
        [[ "$k" == net.* || "$k" == fs.* || "$k" == vm.* || "$k" == kernel.* ]] || continue
        [[ -n "$v" ]] || continue
        run_quiet sysctl -w "$k=$v" && log_ok "sysctl restored: $k=$v"
    done < <(grep -E '^[a-z]' "$TARGET_BACKUP/snapshots/sysctl-pre" | awk '{print $1" "$3}')
fi

# ssh: validate BEFORE restart (philosophy #3)
if [[ -f /etc/ssh/sshd_config ]]; then
    if /usr/sbin/sshd -t 2>/dev/null; then
        run_quiet systemctl restart "${SSH_UNIT}.socket" 2>/dev/null || true
        run_quiet systemctl restart "$SSH_UNIT"
        log_ok "SSH configuration restored and reloaded"
    else
        log_error "sshd -t failed after restore - manual fix required!"
    fi
fi

svc_active fail2ban && svc_restart fail2ban

log_section "ROLLBACK COMPLETE"
log_warn "If the SSH port was reverted, reconnect with the ORIGINAL port."
log_info "Changes made AFTER this backup are NOT reverted."
exit 0
