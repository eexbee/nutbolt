#!/usr/bin/env bash
# =============================================================================
# install.sh - Interactive production server hardening
#
# Workflow:
#   initial checks -> backup -> [user -> ssh(2-phase) -> firewall ->
#   fail2ban -> clamav -> updates -> sysctl -> limits -> services ->
#   profiles] -> summary
#
# Usage:
#   sudo ./install.sh                       # interactive
#   sudo ./install.sh --config FILE.yml     # config-driven (semi-interactive)
#   sudo ./install.sh --non-interactive --config FILE.yml
#   sudo ./install.sh --skip ssh,clamav     # skip modules
#   sudo ./install.sh --only firewall,fail2ban
#
# Options:
#   -c, --config FILE       merge additional YAML config (highest priority)
#   -n, --non-interactive   never prompt; requires complete config
#   -s, --skip LIST         comma separated modules to skip
#       --only LIST         run only these modules
#   -v, --verbose           debug logging
#   -h, --help              this help
# =============================================================================
set -u

FRAMEWORK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export FRAMEWORK_ROOT

source "$FRAMEWORK_ROOT/lib/logging.sh"
source "$FRAMEWORK_ROOT/lib/common.sh"
source "$FRAMEWORK_ROOT/lib/backup.sh"
source "$FRAMEWORK_ROOT/lib/os_detect.sh"
source "$FRAMEWORK_ROOT/lib/config_loader.sh"
source "$FRAMEWORK_ROOT/lib/validation.sh"

INTERACTIVE=1
VERBOSE=0
CONFIG_FILE=""
SKIP_MODULES=""
ONLY_MODULES=""

# ---------------------------------------------------------------- arg parsing
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)         CONFIG_FILE="$2"; shift 2 ;;
        -n|--non-interactive) INTERACTIVE=0; shift ;;
        -s|--skip)           SKIP_MODULES="${2//,/ }"; shift 2 ;;
        --only)              ONLY_MODULES="${2//,/ }"; shift 2 ;;
        -v|--verbose)        VERBOSE=1; shift ;;
        -h|--help)           grep '^#' "$0" | sed 's/^# \{0,2\}//'; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
done
export VERBOSE

MODULES_ORDER=(user ssh firewall fail2ban clamav updates sysctl limits services)

# ---------------------------------------------------------------- entry check
print_banner() {
    cat <<'EOF'
 _   _       _   _           _ _
| \ | |_   _| |_| |__   ___ | | |_
|  \| | | | | __| '_ \ / _ \| | __|
| |\  | |_| | |_| |_) | (_) | | |_
|_| \_|\__,_|\__|_.__/ \___/|_|\__|
          Production Linux Server Hardening Framework
EOF
}

initial_checks() {
    log_section "STEP 1/3: Initial checks"

    if [[ $EUID -ne 0 ]]; then
        log_error "This script must run as root: sudo ./install.sh"
        exit 1
    fi
    log_ok "Running as root"

    os_detect || exit 1

    # internet access (warning only)
    if run_quiet 'timeout 8 bash -c "echo > /dev/tcp/1.1.1.1/53" 2>/dev/null' \
       || ping -c1 -W3 1.1.1.1 &>/dev/null; then
        log_ok "Internet access available"
    else
        log_warn "No internet access detected - package installation may fail"
        ! confirm "Continue without internet access?" "no" && exit 1
    fi

    # resources / ssh session
    os_resource_summary
    if svc_active "${SSH_UNIT:-ssh}" || svc_active sshd || pgrep -x sshd &>/dev/null; then
        log_ok "SSH daemon is running"
    else
        log_warn "SSH daemon not detected as running"
    fi
    return 0
}

load_configuration() {
    log_section "STEP 2/3: Configuration"

    config_load_stack "$CONFIG_FILE"

    if (( VERBOSE )); then
        log_info "Effective configuration:"
        config_summary | sed 's/^/  /'
    fi

    # in non-interactive mode the config must be complete
    if [[ "$INTERACTIVE" != "1" ]]; then
        local missing=()
        config_has "ssh.port"          || missing+=("ssh.port")
        config_has "ssh.new_admin_user" || missing+=("ssh.new_admin_user")
        config_has "ssh.admin_ssh_public_key" || missing+=("ssh.admin_ssh_public_key")
        if (( ${#missing[@]} > 0 )); then
            log_error "Non-interactive mode requires config keys: ${missing[*]}"
            exit 1
        fi
    fi
}

select_profiles() {
    ACTIVE_PROFILES=""
    local p found_any=0
    for p in web database redis minio docker; do
        if config_get_bool "profiles.$p.enabled" false; then
            ACTIVE_PROFILES+=" $p"
            found_any=1
        fi
    done
    ACTIVE_PROFILES="${ACTIVE_PROFILES# }"

    if [[ "$INTERACTIVE" == "1" && "$found_any" != "1" ]]; then
        echo ""
        echo "Select workload profiles (combinable):"
        for p in web database redis minio docker; do
            confirm "  [ ] Enable profile: $p?" "no" && ACTIVE_PROFILES+=" $p"
        done
        ACTIVE_PROFILES="${ACTIVE_PROFILES# }"
    fi
    log_info "Active profiles: ${ACTIVE_PROFILES:-none}"
    export ACTIVE_PROFILES
}

confirm_plan() {
    log_section "STEP 3/3: Hardening plan review"
    cat <<EOF
  OS            : $OS_DESC
  Admin user    : $(config_get "ssh.new_admin_user" "<prompted later>")
  SSH port      : $(config_get "ssh.port" "<current>")
  TCP ports     : $(config_get_list_csv "firewall.tcp_ports" "<prompted later>")
  Profiles      : ${ACTIVE_PROFILES:-none}
  Modules       : $(join_by , "${MODULES_ORDER[@]}")
  Skip          : ${SKIP_MODULES:-none}
  Backup dir    : $FRAMEWORK_ROOT/backups/<timestamp>
EOF
    echo ""
    if [[ "$INTERACTIVE" == "1" ]]; then
        confirm "Start hardening now?" "no" || { log_info "Aborted by user"; exit 0; }
    fi
}

should_run_module() { # should_run_module <name>
    local m="$1"
    if [[ -n "$ONLY_MODULES" ]]; then
        in_list "$m" $ONLY_MODULES || return 1
    fi
    [[ -n "$SKIP_MODULES" ]] && in_list "$m" $SKIP_MODULES && return 1
    return 0
}

run_modules() {
    local m
    for m in "${MODULES_ORDER[@]}"; do
        should_run_module "$m" || { log_info "Skipping module: $m"; continue; }
        # shellcheck disable=SC1090
        source "$FRAMEWORK_ROOT/modules/$m.sh"
        "module_${m}_run" || log_warn "Module '$m' reported issues"
    done
}

run_profiles() {
    local p
    for p in $ACTIVE_PROFILES; do
        should_run_module "$p" || { log_info "Skipping profile: $p"; continue; }
        # shellcheck disable=SC1090
        source "$FRAMEWORK_ROOT/modules/profiles/$p.sh"
        "profile_${p}_run" || log_warn "Profile '$p' reported issues"
    done
}

final_summary() {
    log_section "HARDENING COMPLETE"
    cat <<EOF
  Backup   : $BACKUP_DIR
  Log file : $LOG_FILE
  Errors   : ${ERRORS_COUNT:-0}
EOF
    if (( ${ERRORS_COUNT:-0} > 0 )); then
        log_warn "Some steps reported problems - review the log"
        printf "$LAST_ERROR" | sed 's/^/    /'
    else
        log_ok "All modules finished"
    fi
    echo ""
    log_info "Recommended next steps:"
    local port user
    port="${SSH_NEW_PORT:-$(config_get 'ssh.port' 22)}"
    user="${ADMIN_USERNAME:-$(config_get 'ssh.new_admin_user' '<user>')}"
    log_info "  1. Verify SSH login: ssh ${user}@<server-ip> -p ${port}"
    log_info "  2. Run an audit:     sudo ./audit.sh"
    log_info "  3. Rollback if needed: sudo ./rollback.sh"
}

# =============================================================================
# main
# =============================================================================
main() {
    print_banner
    initial_checks
    logging_init

    load_configuration
    select_profiles
    confirm_plan

    backup_init

    log_section "APPLYING HARDENING"
    run_modules
    run_profiles

    final_summary
    exit $(( ${ERRORS_COUNT:-0} > 0 ? 1 : 0 ))
}

main "$@"
