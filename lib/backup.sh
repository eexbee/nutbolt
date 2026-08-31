#!/usr/bin/env bash
# =============================================================================
# lib/backup.sh - Backup / rollback bookkeeping
# Every modification is journaled in backups/<timestamp>/manifest.txt
#   BACKUP<TAB>/original/path<TAB>relative/path/under/files
#   CREATED<TAB>/path/we/created
# rollback.sh replays the journal in reverse.
# =============================================================================

BACKUP_ROOT="${BACKUP_ROOT:-$FRAMEWORK_ROOT/backups}"
BACKUP_DIR=""

backup_init() {
    BACKUP_DIR="$BACKUP_ROOT/$(date +%Y-%m-%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR/files"
    chmod 700 "$BACKUP_DIR"
    {
        echo "# nutbolt backup manifest"
        echo "# created: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# host:    $(hostname)"
        echo "# format:  ACTION<TAB>PATH<TAB>BACKUP_RELATIVE_PATH"
    } > "$BACKUP_DIR/manifest.txt"
    # convenience pointer
    ln -sfn "$(basename "$BACKUP_DIR")" "$BACKUP_ROOT/LATEST"
    log_ok "Backup directory ready: $BACKUP_DIR"
}

_manifest_add() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$BACKUP_DIR/manifest.txt"; }

# backup_file /etc/ssh/sshd_config -> copies preserving structure, journal entry
backup_file() {
    local f="$1"
    [[ -n "$BACKUP_DIR" ]] || { log_error "backup_file: backup not initialised"; return 1; }
    if [[ ! -e "$f" ]]; then
        log_warn "backup_file: '$f' does not exist, skipping"
        return 1
    fi
    local rel="${f#/}"
    local dest="$BACKUP_DIR/files/$rel"
    mkdir -p "$(dirname "$dest")"
    if [[ -d "$f" ]]; then
        cp -a "$f" "$dest"
    else
        cp -a --parents "$f" "$BACKUP_DIR/files/" 2>/dev/null || cp -a "$f" "$dest"
    fi
    _manifest_add "BACKUP" "$f" "files/$rel"
    log_debug "Backed up: $f"
}

# backup_file_once - avoid duplicate entries for the same path
backup_file_once() {
    local f="$1"
    grep -qF "BACKUP"$'\t'"$f"$'\t' "$BACKUP_DIR/manifest.txt" 2>/dev/null && return 0
    backup_file "$f"
}

# track_created /path -> journal a file/directory created by the framework
track_created() {
    local f="$1"
    [[ -n "$BACKUP_DIR" ]] || return 1
    grep -qF "CREATED"$'\t'"$f" "$BACKUP_DIR/manifest.txt" 2>/dev/null && return 0
    _manifest_add "CREATED" "$f" "-"
}

# backup_snapshot "name" "command..." - store command output (e.g. firewall state)
backup_snapshot() {
    local name="$1"; shift
    [[ -n "$BACKUP_DIR" ]] || return 1
    mkdir -p "$BACKUP_DIR/snapshots"
    eval "$*" > "$BACKUP_DIR/snapshots/$name" 2>&1
    _manifest_add "SNAPSHOT" "$name" "snapshots/$name"
}

# backup_list_available -> prints usable backup dirs (newest last)
backup_list_available() {
    local d
    for d in "$BACKUP_ROOT"/[0-9]*[0-9]/; do
        [[ -f "$d/manifest.txt" ]] && echo "${d%/}"
    done
}
