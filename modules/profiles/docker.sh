#!/usr/bin/env bash
# =============================================================================
# modules/profiles/docker.sh - Docker host profile
# - /etc/docker/daemon.json: json-file log rotation + live-restore
# - NEVER touches network/iptables settings (production safety)
# - optionally installs Docker when missing
# =============================================================================

profile_docker_run() {
    log_section "PROFILE: Docker"

    # --- install if missing ------------------------------------------------------------
    if ! command -v docker &>/dev/null && ! svc_exists docker; then
        local install_docker=1
        if [[ "$INTERACTIVE" == "1" ]]; then
            confirm "Docker is not installed. Install it now?" "no" || install_docker=0
        else
            config_get_bool "profiles.docker.install" false && install_docker=1 || install_docker=0
        fi
        if (( install_docker )); then
            _docker_install
        else
            log_info "Docker not installed and installation declined - applying config only"
            return 0
        fi
    fi

    # --- daemon.json ---------------------------------------------------------------------
    local daemonjson="/etc/docker/daemon.json"
    local tmp_existing=""
    if [[ -f "$daemonjson" ]]; then
        backup_file_once "$daemonjson"
        tmp_existing="$(cat "$daemonjson")"
    fi

    local log_size log_files
    log_size="$(config_get "profiles.docker.log_max_size" "10m")"
    log_files="$(config_get "profiles.docker.log_max_file" "3")"

    mkdir -p /etc/docker
    local merged
    merged="$(_docker_merge_daemon_json "$tmp_existing" "$log_size" "$log_files")"
    if [[ -z "$merged" ]]; then
        cat > "$daemonjson" <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "${log_size}",
    "max-file": "${log_files}"
  },
  "live-restore": true
}
EOF
    else
        printf '%s\n' "$merged" > "$daemonjson"
    fi
    [[ -z "$tmp_existing" ]] && track_created "$daemonjson"
    log_ok "daemon.json written (json-file rotation: ${log_size} x ${log_files}, live-restore: true)"
    log_info "Existing daemon.json options were preserved; networking was NOT modified"

    # --- enable docker ----------------------------------------------------------------------
    run_quiet systemctl daemon-reload
    if ! svc_active docker; then
        run_quiet systemctl enable --now docker
    else
        # live-restore=true keeps containers running across daemon restarts
        log_warn "Restarting docker daemon (containers keep running via live-restore)"
        svc_restart docker
    fi

    if docker info &>/dev/null; then
        log_ok "Docker is running"
    else
        log_error "Docker failed to start - check: journalctl -u docker -n 50"
        register_error "docker not running"
    fi
}

_docker_install() {
    log_info "Installing Docker"
    if [[ "$OS_FAMILY" == "debian" ]]; then
        pkg_install docker.io docker-compose-v2 2>/dev/null || pkg_install docker.io docker-compose
    else
        # AlmaLinux/Rocky: docker-ce from the official Docker repository
        dnf config-manager --add-repo \
            https://download.docker.com/linux/centos/docker-ce.repo \
            && pkg_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
    command -v docker &>/dev/null || { log_error "Docker installation failed"; register_error "docker install"; return 1; }
    run_quiet systemctl enable --now docker
    log_ok "Docker installed and started"
}

# merge existing daemon.json with our log rotation settings (python3 preferred)
_docker_merge_daemon_json() {
    local existing="$1" log_size="$2" log_files="$3"
    if [[ -z "$existing" ]]; then echo ""; return 0; fi
    if command -v python3 &>/dev/null; then
        python3 - "$log_size" "$log_files" <<'PYEOF' <<<"$existing" 2>/dev/null && return 0
import json, sys
max_size, max_file = sys.argv[1], sys.argv[2]
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)
data.setdefault("log-driver", "json-file")
opts = data.get("log-opts", {})
opts["max-size"] = max_size
opts["max-file"] = max_file
data["log-opts"] = opts
data.setdefault("live-restore", True)
print(json.dumps(data, indent=2))
PYEOF
    fi
    if command -v jq &>/dev/null; then
        jq --arg s "$log_size" --arg f "$log_files" \
           '.["log-driver"]="json-file" | .["log-opts"]=((.["log-opts"]//{})+{"max-size":$s,"max-file":$f}) | .["live-restore"]=true' \
           <<<"$existing" 2>/dev/null && return 0
    fi
    # cannot merge safely - keep existing file and warn
    log_warn "python3/jq unavailable - daemon.json left untouched (add log rotation manually)"
    printf '%s\n' "$existing"
}
