#!/usr/bin/env bash
# =============================================================================
# lib/os_detect.sh - Operating system detection via /etc/os-release
# Sets globals:
#   OS_FAMILY   debian | rhel
#   OS_ID       ubuntu | almalinux | rocky | ...
#   OS_MAJOR    major version number
#   OS_VERSION  full VERSION_ID
#   OS_DESC     PRETTY_NAME
#   PKG_MGR     apt | dnf
#   FIREWALL    ufw | firewalld
#   SSH_UNIT    ssh | sshd
# =============================================================================

os_detect() {
    if [[ ! -r /etc/os-release ]]; then
        log_error "/etc/os-release not found - unsupported operating system"
        return 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-0}"
    OS_MAJOR="${OS_VERSION%%.*}"
    OS_DESC="${PRETTY_NAME:-$OS_ID $OS_VERSION}"

    case "$OS_ID" in
        ubuntu|debian)
            OS_FAMILY="debian" ;;
        almalinux|rocky|rhel|centos)
            OS_FAMILY="rhel" ;;
        *)
            # try ID_LIKE
            case "${ID_LIKE:-}" in
                *debian*|*ubuntu*) OS_FAMILY="debian" ;;
                *rhel*|*fedora*|*centos*) OS_FAMILY="rhel" ;;
                *) OS_FAMILY="unknown" ;;
            esac
            ;;
    esac

    case "$OS_FAMILY" in
        debian) PKG_MGR="apt"  ; FIREWALL="ufw"      ; SSH_UNIT="ssh"  ;;
        rhel)   PKG_MGR="dnf"  ; FIREWALL="firewalld"; SSH_UNIT="sshd" ;;
        *)      PKG_MGR=""     ; FIREWALL=""          ; SSH_UNIT="ssh" ;;
    esac

    _os_supported_check
}

_os_supported_check() {
    local supported=1 reason=""
    case "$OS_ID" in
        ubuntu)
            if (( OS_MAJOR < 22 )); then
                reason="Ubuntu 22.04 LTS or newer required (found $OS_VERSION)"
                supported=0
            fi
            ;;
        almalinux|rocky)
            if (( OS_MAJOR < 9 )); then
                reason="AlmaLinux/Rocky 9 or newer required (found $OS_VERSION)"
                supported=0
            fi
            ;;
        *)
            supported=0
            reason="Unsupported distribution: $OS_DESC (family: $OS_FAMILY)"
            ;;
    esac

    if (( supported == 0 )); then
        log_error "Unsupported OS: $reason"
        log_error "Supported: Ubuntu 22.04/24.04+, AlmaLinux 9+, Rocky Linux 9+"
        return 1
    fi
    log_ok "Detected OS: $OS_DESC (family=$OS_FAMILY pkg=$PKG_MGR firewall=$FIREWALL)"
    return 0
}

# Print a summary of hardware/resources used by initial checks and discovery
os_resource_summary() {
    local cpu cores ram disk
    cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//' )
    [[ -z "$cpu" ]] && cpu=$(grep -m1 'Model Name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')
    cores=$(nproc 2>/dev/null || echo "?")
    ram=$(awk '/MemTotal/ {printf "%d MB", $2/1024}' /proc/meminfo 2>/dev/null)
    disk=$(df -h / 2>/dev/null | awk 'NR==2 {print $2 " total, " $4 " free"}')
    cat <<EOF
  Hostname : $(hostname)
  OS       : $OS_DESC
  CPU      : ${cpu:-unknown} (${cores} cores)
  RAM      : ${ram:-unknown}
  Root FS  : ${disk:-unknown}
EOF
}
