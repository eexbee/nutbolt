#!/usr/bin/env bash
# =============================================================================
# discovery/hardware.sh - CPU / RAM / disks / platform detection
# Prints YAML fragment to stdout.
# =============================================================================

discovery_hardware() {
    local cpu_model cores ram_mb ram_gb swap_mb virt
    cpu_model="$(grep -m1 -i 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//;s/ *$//')"
    [[ -z "$cpu_model" ]] && cpu_model="$(lscpu 2>/dev/null | grep -i '^Model name' | cut -d: -f2- | sed 's/^ *//')"
    cores="$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
    ram_mb="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    ram_gb=$(( ram_mb / 1024 ))
    swap_mb="$(awk '/SwapTotal/ {printf "%d", $2/1024}' /proc/meminfo)"
    virt="$(systemd-detect-virt 2>/dev/null || echo unknown)"

    cat <<EOF
detected:
  hostname: "$(hostname)"
  cpu_model: "${cpu_model:-unknown}"
  cpu_cores: ${cores:-0}
  ram_mb: ${ram_mb:-0}
  ram_gb: ${ram_gb:-0}
  swap_mb: ${swap_mb:-0}
  virtualization: "${virt}"
  disks:
EOF
    lsblk -dnb -o NAME,SIZE,TYPE 2>/dev/null | awk '$3=="disk" {printf "    - %s (%.1f GB)\n", $1, $2/1024/1024/1024}'
    df -hP | awk 'NR>1 && $6 !~ /^(tmpfs|devtmpfs|proc|sysfs|efivarfs|run|boot\/efi)/ {printf "  mounted_%s: \"%s total %s free %s\"\n", $6, $2, $4, $5}' | sed 's/^/  /'
}
