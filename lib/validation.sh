#!/usr/bin/env bash
# =============================================================================
# lib/validation.sh - Input validation helpers
# =============================================================================

validate_port() { # 1..65535
    [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

validate_ports_list() { # "80 443" or "80,443" -> 0 if all valid
    local list="${1//,/ }" p
    [[ -z "$list" ]] && return 0
    for p in $list; do
        validate_port "$p" || return 1
    done
}

validate_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

validate_ssh_public_key() { # accepts single-line OpenSSH public key
    local key="$1"
    [[ "$key" =~ ^(ssh-(rsa|ed25519)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256))\ [A-Za-z0-9+/=]+ ]]
}

validate_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

validate_bantime() { # "1h", "3600", "7d", "10m"
    [[ "$1" =~ ^[0-9]+(s|m|h|d|w)?$ ]]
}

validate_path() {
    [[ "$1" =~ ^/ ]] && [[ "$1" != *..* ]]
}

# prompt_until_valid "question" "validator_fn" [default] [error_msg]
prompt_until_valid() {
    local question="$1" validator="$2" default="${3:-}" errmsg="${4:-Invalid value, try again.}" answer
    while true; do
        answer="$(prompt "$question" "$default")"
        if "$validator" "$answer"; then
            echo "$answer"
            return 0
        fi
        log_error "$errmsg"
    done
}
