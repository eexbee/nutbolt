#!/usr/bin/env bash
# =============================================================================
# lib/logging.sh - Logging facility
# Provides timestamped logging to console and logfile.
# =============================================================================

FRAMEWORK_ROOT="${FRAMEWORK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_DIR="${LOG_DIR:-$FRAMEWORK_ROOT/logs}"
LOG_FILE=""

logging_init() {
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/hardening-$(date +%Y%m%d-%H%M%S).log"
    : > "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    log_info "Logging started: $LOG_FILE"
}

_ts() { date '+%Y-%m-%d %H:%M:%S'; }

_log() {
    local level="$1"; shift
    local msg="$*"
    local line="[$(_ts)] [$level] $msg"
    if [[ -n "$LOG_FILE" ]]; then
        echo "$line" >> "$LOG_FILE" 2>/dev/null
    fi
    case "$level" in
        ERROR) printf '\033[0;31m%s\033[0m\n' "$line" ;;
        WARN)  printf '\033[0;33m%s\033[0m\n' "$line" ;;
        OK)    printf '\033[0;32m%s\033[0m\n' "$line" ;;
        INFO)  printf '%s\n' "$line" ;;
        *)     printf '%s\n' "$line" ;;
    esac
}

log_info()  { _log INFO  "$@"; }
log_ok()    { _log OK    "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "${VERBOSE:-0}" == "1" ]] && _log DEBUG "$@" || true; }

# log_run "command..." -> executes command, streams output to log, returns rc
log_run() {
    local cmd="$*"
    local out rc line
    log_info "EXEC: $cmd"
    out=$(eval "$cmd" 2>&1)
    rc=$?
    if [[ -n "$out" ]]; then
        while IFS= read -r line; do
            [[ -n "$LOG_FILE" ]] && echo "[ $(_ts) ] [EXECOUT] $line" >> "$LOG_FILE"
            [[ "${QUIET_EXEC:-0}" != "1" ]] && printf '  %s\n' "$line"
        done <<< "$out"
    fi
    if [[ $rc -ne 0 ]]; then
        log_warn "Command failed (exit $rc): $cmd"
    fi
    return $rc
}

# Execute a command silently, log output only on failure
run_quiet() {
    local cmd="$*"
    local out rc
    out=$(eval "$cmd" 2>&1); rc=$?
    if [[ $rc -ne 0 ]]; then
        log_warn "Command failed (exit $rc): $cmd"
        [[ -n "$out" ]] && log_info "Output: $out"
    fi
    [[ -n "$out" && -n "$LOG_FILE" ]] && echo "[ $(_ts) ] [EXECOUT] $out" >> "$LOG_FILE"
    return $rc
}

# log_section "Title" - prints a visible section banner
log_section() {
    local title="$1"
    local bar
    bar=$(printf '%*s' 72 '' | tr ' ' '=')
    printf '\n%s\n  %s\n%s\n' "$bar" "$title" "$bar"
    [[ -n "$LOG_FILE" ]] && printf '\n%s\n  %s\n%s\n' "$bar" "$title" "$bar" >> "$LOG_FILE"
}
