#!/usr/bin/env bash
# =============================================================================
# discovery/packages.sh - Installed packages relevant to hardening/workloads
# Prints YAML fragment to stdout and writes the full package list to a file.
# =============================================================================

discovery_packages() {
    local out_dir="${1:-$FRAMEWORK_ROOT/config/generated}"
    local list_file="$out_dir/packages-$(date +%Y%m%d-%H%M%S).txt"

    if [[ "$PKG_MGR" == "apt" ]]; then
        dpkg -l 2>/dev/null | awk '/^ii/ {print $2" "$3}' > "$list_file"
        _pkg_installed() { dpkg -s "$1" &>/dev/null; }
    else
        dnf -q repoquery --installed --qf '%{name} %{version}' 2>/dev/null > "$list_file"
        _pkg_installed() { dnf -q list installed "$1" &>/dev/null; }
    fi

    echo "packages:"
    echo "  full_list: \"$list_file\""
    local p
    for p in nginx apache2 httpd openlitespeed mariadb-server mysql-server \
             postgresql-server redis minio docker-ce docker.io fail2ban \
             clamav clamav-daemon clamd unattended-upgrades dnf-automatic ufw firewalld; do
        if _pkg_installed "$p"; then
            echo "  $p: installed"
        fi
    done
    return 0
}
