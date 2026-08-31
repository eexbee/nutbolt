#!/usr/bin/env bash
# =============================================================================
# lib/config_loader.sh - Minimal YAML loader for the framework configuration.
#
# Supports the YAML subset used by this framework:
#   - nested mappings via 2-space indentation
#   - scalar values: strings, numbers, booleans (true/false/yes/no)
#   - lists: flow style [a, b, c] and block style ("- item" lines)
#   - comments (#) and blank lines
#
# All values are flattened into the global associative array CONFIG:
#   ssh.port -> 22222
#   profiles.web.enabled -> true
# Access via:  config_get "ssh.port" | config_get_bool | config_get_list
# =============================================================================

declare -gA CONFIG

# _yaml_parse_file <file> <prefix>
_yaml_parse_file() {
    local file="$1" file_prefix="${2:-}"
    local line raw indent key value level i
    local -a path=()

    if [[ ! -r "$file" ]]; then
        log_warn "Config file not readable: $file"
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        # strip comments
        line="${line%%#*}"
        # skip blank lines
        [[ -z "${line//[[:space:]]/}" ]] && continue
        # normalize tabs to spaces (defensive)
        line="${line//$'\t'/  }"

        # indentation -> nesting level (2 spaces per level)
        indent=0
        raw="$line"
        while [[ "$raw" == ' '* ]]; do raw="${raw:1}"; ((indent++)); done
        level=$((indent / 2))

        # trim whitespace
        raw="${raw#"${raw%%[![:space:]]*}"}"
        raw="${raw%"${raw##*[![:space:]]}"}"
        [[ -z "$raw" ]] && continue

        if [[ "$raw" == -* ]]; then
            # block list item -> append to last section key
            value="${raw#-}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="$(_yaml_unquote "$value")"
            local lk="${CONFIG_LIST_LAST:-}"
            if [[ -n "$lk" ]]; then
                if [[ -n "${CONFIG[$lk]}" ]]; then
                    CONFIG["$lk"]="${CONFIG[$lk]} $value"
                else
                    CONFIG["$lk"]="$value"
                fi
            fi
            continue
        fi

        if [[ "$raw" == *:* ]]; then
            key="${raw%%:*}"
            value="${raw#*:}"
            key="${key%"${key##*[![:space:]]}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%"${value##*[![:space:]]}"}"

            # keep path in sync with level
            for ((i=${#path[@]}; i>level; i--)); do unset "path[i-1]"; done

            local fullkey="$key" j
            for ((j=level-1; j>=0; j--)); do
                fullkey="${path[j]}.$fullkey"
            done

            if [[ -z "$value" ]]; then
                # section key (or parent of block list)
                path[level]="$key"
                unset "path[level+1]" 2>/dev/null || true
                CONFIG_LIST_LAST="$file_prefix$fullkey"
                # initialise empty so key exists even without children
                if [[ -z "${CONFIG[$file_prefix$fullkey]+x}" ]]; then
                    CONFIG["$file_prefix$fullkey"]=""
                fi
            else
                value="$(_yaml_unquote "$value")"
                value="$(_yaml_flow_list "$value")"
                CONFIG["$file_prefix$fullkey"]="$value"
            fi
        fi
    done < "$file"
}

_yaml_unquote() {
    local v="$1"
    v="${v%\"}"; v="${v#\"}"
    v="${v%\'}"; v="${v#\'}"
    # flow list normalisation happens separately
    echo "$v"
}

# convert "[a, b, c]" -> "a b c" (keeping quoted items intact)
_yaml_flow_list() {
    local v="$1"
    if [[ "$v" == \[*\] ]]; then
        v="${v:1:${#v}-2}"
        v="${v//,/ }"
        # collapse whitespace runs left by ", " separators
        while [[ "$v" == *"  "* ]]; do v="${v//  / }"; done
        v="${v#"${v%%[![:space:]]*}"}"
        v="${v%"${v##*[![:space:]]}"}"
    fi
    echo "$v"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------
config_load_file() { # config_load_file <file> [prefix]
    local file="$1" prefix="${2:-}"
    log_info "Loading config: $file"
    _yaml_parse_file "$file" "$prefix"
}

config_get() { # config_get "key" [default]
    local k="$1" d="${2:-}"
    if [[ -n "${CONFIG[$k]+x}" ]]; then
        local v="${CONFIG[$k]}"
        [[ -z "$v" && "$v" != "0" ]] && v="$v"   # keep literal empties
        echo "$v"
    else
        echo "$d"
    fi
}

config_has() { [[ -n "${CONFIG[$1]+x}" ]]; }

config_get_bool() { # config_get_bool "key" [default:false]
    local v
    v="$(config_get "$1" "${2:-false}")"
    v="${v,,}"
    case "$v" in
        true|yes|1|on)  return 0 ;;
        *)              return 1 ;;
    esac
}

config_get_int() { config_get "$1" "${2:-0}" | tr -d '[:space:]'; }

config_get_list() { # config_get_list "key" -> items on stdout, one per line
    local v
    v="$(config_get "$1" "${2:-}")"
    [[ -z "$v" ]] && return 0
    local item
    for item in $v; do echo "$item"; done
}

config_get_list_csv() { # config_get_list_csv "key" -> "a b c" (space separated)
    config_get "$1" "${2:-}"
}

# Load base config stack: default.yml -> servers/<hostname>.yml -> extra file
config_load_stack() {
    local extra="${1:-}"
    config_load_file "$FRAMEWORK_ROOT/config/default.yml" || true
    local host_cfg="$FRAMEWORK_ROOT/config/servers/$(hostname).yml"
    [[ -f "$host_cfg" ]] && config_load_file "$host_cfg"
    [[ -n "$extra" && -f "$extra" ]] && config_load_file "$extra"
    return 0
}

config_summary() { # dump loaded config keys (for logs/review)
    local k
    for k in "${!CONFIG[@]}"; do
        printf '  %s = %s\n' "$k" "${CONFIG[$k]}"
    done | sort
}
