#!/usr/bin/env bash
# =============================================================================
# lib/common.sh - Common helpers: prompts, packages, services
# Requires: lib/logging.sh
# =============================================================================

# ---------------------------------------------------------------------------
# Prompts (interactive). All read from stdin so they can be piped/scripted.
# ---------------------------------------------------------------------------
prompt() { # prompt "question" [default] -> echoes answer on stdout
    local question="$1" default="${2:-}" answer=""
    if [[ -n "$default" ]]; then
        read -r -p "$question [$default]: " answer
        echo "${answer:-$default}"
    else
        read -r -p "$question: " answer
        echo "$answer"
    fi
}

prompt_secret() { # like prompt but hides input (for secrets)
    local question="$1" answer=""
    read -r -s -p "$question: " answer
    echo >&2
    echo "$answer"
}

confirm() { # confirm "question" [yes|no default] -> return 0 on yes
    local question="$1" default="${2:-yes}" answer=""
    if [[ "$default" == "yes" ]]; then
        read -r -p "$question [Y/n]: " answer
        answer="${answer:-y}"
    else
        read -r -p "$question [y/N]: " answer
        answer="${answer:-n}"
    fi
    [[ "$answer" =~ ^[Yy] ]]
}

prompt_multiline() { # prompt_multiline "question" terminator -> reads until terminator line
    local question="$1" terminator="${2:-END}" line=""
    echo "$question (finish with a line containing only '$terminator'):" >&2
    while IFS= read -r line; do
        [[ "$line" == "$terminator" ]] && break
        echo "$line"
    done
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
cmd_exists() { command -v "$1" &>/dev/null; }

svc_exists()  { systemctl list-unit-files 2>/dev/null | grep -qE "^$1\.(service|socket)"; }
svc_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_enabled() { systemctl is-enabled --quiet "$1" 2>/dev/null; }
svc_enable()  { run_quiet systemctl enable "$1"; }
svc_start()   { run_quiet systemctl start "$1"; }
svc_restart() { run_quiet systemctl restart "$1"; }
svc_reload()  { run_quiet systemctl reload "$1" 2>/dev/null || run_quiet systemctl restart "$1"; }

pkg_installed() {
    if [[ "$PKG_MGR" == "apt" ]]; then
        dpkg -s "$1" &>/dev/null
    else
        dnf -q list installed "$1" &>/dev/null
    fi
}

pkg_install() { # pkg_install pkg1 [pkg2 ...]
    local pkgs=("$@")
    if (( ${#pkgs[@]} == 0 )); then return 0; fi
    if [[ "$PKG_MGR" == "apt" ]]; then
        log_info "Installing with apt: ${pkgs[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${pkgs[@]}"
    else
        log_info "Installing with dnf: ${pkgs[*]}"
        dnf install -y -q "${pkgs[@]}"
    fi
}

pkg_update_cache() {
    if [[ "$PKG_MGR" == "apt" ]]; then
        apt-get update -qq
    else
        dnf -q makecache
    fi
}

ensure_epel() { # RHEL family only: enable EPEL repository
    [[ "$OS_FAMILY" == "rhel" ]] || return 0
    if ! dnf repolist --enabled 2>/dev/null | grep -qi epel; then
        log_info "Enabling EPEL repository"
        pkg_install epel-release || dnf install -y \
            "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm"
    fi
}

join_by() { local IFS="$1"; shift; echo "$*"; }

in_list() { # in_list "item" "list..." 
    local item="$1"; shift
    local e
    for e in "$@"; do [[ "$e" == "$item" ]] && return 0; done
    return 1
}

human_size() { numfmt --to=iec "$1" 2>/dev/null || echo "$1"; }

# Best-effort detection of the address an operator would use to reach this
# server: public IP first (external service), then first interface address.
# Requires: lib/validation.sh (validate_ip) at call time.
detect_server_ip() {
    local ip=""
    if cmd_exists curl; then
        ip="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || true)"
        validate_ip "$ip" || ip="$(curl -fsS -m 5 https://ifconfig.me 2>/dev/null || true)"
    elif cmd_exists wget; then
        ip="$(wget -qO- -T 5 https://api.ipify.org 2>/dev/null || true)"
    fi
    validate_ip "$ip" || ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    validate_ip "$ip" || ip=""
    echo "$ip"
}

# Non-fatal error counter used by install.sh summary
register_error() {
    ERRORS_COUNT=$((ERRORS_COUNT + 1))
    LAST_ERROR="${LAST_ERROR:-}$1\n"
}
ERRORS_COUNT=0
