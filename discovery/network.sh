#!/usr/bin/env bash
# =============================================================================
# discovery/network.sh - Hostname, interfaces, default IP, listening ports
# Prints YAML fragment to stdout.
# =============================================================================

discovery_network() {
    local default_ip
    default_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -z "$default_ip" ]] && default_ip="$(ip -4 route get 1 2>/dev/null | awk '{print $7; exit}')"

    cat <<EOF
network:
  hostname: "$(hostname)"
  fqdn: "$(hostname -f 2>/dev/null || hostname)"
  primary_ip: "${default_ip:-unknown}"
  interfaces:
EOF
    ip -4 -brief addr show 2>/dev/null | awk 'NR>0 {
        iface=$1; ip=$3;
        printf "    %s: \"%s\"\n", iface, ip
    }'
    echo "  listening_tcp_ports:"
    ss -H -tln 2>/dev/null | awk '{print $4}' | rev | cut -d: -f1 | rev \
        | grep -E '^[0-9]+$' | sort -n | uniq | awk '{printf "    - %s\n", $1}'
    echo "  listening_udp_ports:"
    ss -H -uln 2>/dev/null | awk '{print $4}' | rev | cut -d: -f1 | rev \
        | grep -E '^[0-9]+$' | sort -n | uniq | awk '{printf "    - %s\n", $1}'
}
