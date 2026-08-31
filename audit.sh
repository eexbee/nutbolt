#!/usr/bin/env bash
# =============================================================================
# audit.sh - Security audit & scoring
# Checks: SSH hardening, firewall, fail2ban, ClamAV, updates, kernel settings,
# resource limits. Generates a weighted 0-100 score and a text report.
#
# Usage: sudo ./audit.sh
# =============================================================================
set -u

FRAMEWORK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FRAMEWORK_ROOT

source "$FRAMEWORK_ROOT/lib/logging.sh"
source "$FRAMEWORK_ROOT/lib/common.sh"
source "$FRAMEWORK_ROOT/lib/os_detect.sh"

INTERACTIVE=0

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root (sudo ./audit.sh)"; exit 1; }

logging_init
log_section "SECURITY AUDIT"

os_detect || exit 1

source "$FRAMEWORK_ROOT/audit/checks.sh"
source "$FRAMEWORK_ROOT/audit/scoring.sh"
source "$FRAMEWORK_ROOT/audit/report.sh"

run_all_checks
audit_score
audit_print_console
audit_write_report

exit 0
