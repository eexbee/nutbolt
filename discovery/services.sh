#!/usr/bin/env bash
# =============================================================================
# discovery/services.sh - Detect running services and classify workload profiles
# Prints YAML fragment to stdout. Sets DISCOVERED_PROFILES (space separated)
# and DISCOVERED_WEB_SERVER / DISCOVERED_DB_SERVER in the caller's shell.
# =============================================================================

_svc_up() { systemctl is-active --quiet "$1" 2>/dev/null; }
_bin()    { command -v "$1" &>/dev/null; }
_port_open() { ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"; }

discovery_services() {
    DISCOVERED_PROFILES=""
    DISCOVERED_WEB=""
    DISCOVERED_DB=""

    echo "detected_services:"

    # ---- web ------------------------------------------------------------------
    local web=""
    { _svc_up nginx || _bin nginx; }        && web="nginx"
    { _svc_up apache2 || _svc_up httpd || _bin httpd; } && [[ -z "$web" ]] && web="apache"
    { _svc_up lsws || [[ -d /usr/local/lsws ]]; } && [[ -z "$web" ]] && web="openlitespeed"
    if [[ -n "$web" ]] || _port_open 80 || _port_open 443; then
        [[ -z "$web" ]] && web="unknown(listening on 80/443)"
        DISCOVERED_WEB="$web"
        DISCOVERED_PROFILES+=" web"
        echo "  web_server: \"$web\""
    fi

    # ---- database --------------------------------------------------------------
    local db=""
    _svc_up mariadb    || _bin mariadbd      || _port_open 3306 && db="mariadb"
    { _svc_up mysqld   || _bin mysqld; }     && [[ -z "$db" ]]  && db="mysql"
    { _svc_up postgresql || systemctl list-units --type=service 2>/dev/null | grep -q postgresql || _bin psql || _port_open 5432; } \
                                              && [[ -z "$db" ]]  && db="postgresql"
    if [[ -n "$db" ]]; then
        DISCOVERED_DB="$db"
        DISCOVERED_PROFILES+=" database"
        echo "  database_server: \"$db\""
    fi

    # ---- redis -------------------------------------------------------------------
    if _svc_up redis || _svc_up redis-server || _bin redis-server || _port_open 6379; then
        DISCOVERED_PROFILES+=" redis"
        echo "  redis: true"
    else
        echo "  redis: false"
    fi

    # ---- minio ---------------------------------------------------------------------
    if _svc_up minio || _bin minio || _port_open 9000; then
        DISCOVERED_PROFILES+=" minio"
        echo "  minio: true"
    else
        echo "  minio: false"
    fi

    # ---- docker -----------------------------------------------------------------------
    if _svc_up docker || _bin docker; then
        DISCOVERED_PROFILES+=" docker"
        local ncont
        ncont="$(docker ps -q 2>/dev/null | wc -l)"
        echo "  docker: true"
        echo "  docker_containers: ${ncont:-0}"
    else
        echo "  docker: false"
    fi

    DISCOVERED_PROFILES="${DISCOVERED_PROFILES# }"
}
