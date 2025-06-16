#!/bin/bash

# Generic Backup Tool - Streamlined version with TOML config support
set -euo pipefail

# Defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/backup.toml"
DRY_RUN=false VERBOSE=false FORCE_INIT=false

# Colors & Logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m' NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_debug() { [[ "$VERBOSE" == "true" ]] && echo -e "${BLUE}[DEBUG]${NC} $1" >&2; }

# TOML Parser (macOS compatible)
parse_toml() {
    local file="$1" section="$2" key="$3" default="$4"
    local value=$(sed -n "/^\[$section\]/,/^\[/p" "$file" | \
                  grep -E "^[[:space:]]*$key[[:space:]]*=" | head -1 | \
                  sed -E 's/^[[:space:]]*[^=]*=[[:space:]]*//; s/[[:space:]]*#.*$//; s/^["'\'']*//; s/["'\'']*[[:space:]]*$//')
    echo "${value:-$default}"
}

parse_toml_array() {
    local file="$1" section="$2" key="$3" temp=$(mktemp)
    sed -n "/^\[$section\]/,/^\[/p" "$file" > "$temp"
    
    if grep -q "^[[:space:]]*$key[[:space:]]*=[[:space:]]*\[.*\]" "$temp"; then
        # Single line array
        grep "^[[:space:]]*$key[[:space:]]*=" "$temp" | \
        sed -E 's/^[[:space:]]*[^=]*=[[:space:]]*\[//; s/\][[:space:]]*$//; s/[[:space:]]*,[[:space:]]*/\n/g' | \
        sed -E 's/^[[:space:]]*["'\'']*|["'\'']*[[:space:]]*$//g' | grep -v '^[[:space:]]*$'
    else
        # Multi-line array
        awk -v key="$key" 'BEGIN{in_array=0} $0~"^[[:space:]]*"key"[[:space:]]*=[[:space:]]*\\["{in_array=1;next} in_array&&/\]/{in_array=0;next} in_array&&!/^[[:space:]]*#/&&NF>0{gsub(/^[[:space:]]*|[[:space:]]*,$/,"");gsub(/^["'\'']*|["'\'']*$/,"");if($0!="")print}' "$temp"
    fi
    rm -f "$temp"
}

# Load & validate config
load_config() {
    [[ ! -f "$1" ]] && { log_error "Config not found: $1"; return 1; }
    log_debug "Loading config: $1"
    
    # Load values
    SOURCE=$(parse_toml "$1" "backup" "source" "")
    DEST=$(parse_toml "$1" "backup" "dest" "")
    MODE=$(parse_toml "$1" "backup" "mode" "incremental")
    TIME_WINDOW=$(parse_toml "$1" "backup" "time_window" "5")
    COMPRESSION=$(parse_toml "$1" "backup" "compression" "zstd,9")
    USE_DEDUP=$(parse_toml "$1" "backup" "use_dedup" "true")
    PASSPHRASE=$(parse_toml "$1" "backup" "passphrase" "")
    
    # Retention
    KEEP_HOURLY=$(parse_toml "$1" "retention" "hourly" "12")
    KEEP_DAILY=$(parse_toml "$1" "retention" "daily" "14")
    KEEP_WEEKLY=$(parse_toml "$1" "retention" "weekly" "4")
    KEEP_MONTHLY=$(parse_toml "$1" "retention" "monthly" "12")
    KEEP_YEARLY=$(parse_toml "$1" "retention" "yearly" "5")
    
    # Exclude patterns
    EXCLUDE_PATTERNS=(); MEDIA_PATTERNS=()
    while IFS= read -r pattern; do [[ -n "$pattern" ]] && EXCLUDE_PATTERNS+=("$pattern"); done < <(parse_toml_array "$1" "exclude" "patterns")
    while IFS= read -r pattern; do [[ -n "$pattern" ]] && MEDIA_PATTERNS+=("$pattern"); done < <(parse_toml_array "$1" "exclude" "media_patterns")
}

validate_config() {
    local errors=0
    [[ -z "$SOURCE" ]] && { log_error "Source not specified"; ((errors++)); }
    [[ ! -d "$SOURCE" ]] && { log_error "Source not found: $SOURCE"; ((errors++)); }
    [[ -z "$DEST" ]] && { log_error "Destination not specified"; ((errors++)); }
    [[ ! "$MODE" =~ ^(incremental|full|borg-auto)$ ]] && { log_error "Invalid mode: $MODE"; ((errors++)); }
    [[ ! "$TIME_WINDOW" =~ ^[0-9]+$ ]] && { log_error "Invalid time window: $TIME_WINDOW"; ((errors++)); }
    return $errors
}

# Borg functions
init_repo() {
    local repo="$1" compression="$2"
    [[ -d "$repo" && "$FORCE_INIT" != "true" ]] && { log_debug "Repo exists: $repo"; return 0; }
    
    log_info "Initializing borg repository: $repo"
    [[ "$DRY_RUN" == "true" ]] && { log_info "[DRY RUN] Would init repo"; return 0; }
    
    local cmd="borg init --encryption=repokey"
    [[ "$compression" != "none" ]] && cmd="$cmd --compression=$compression"
    eval "$cmd '$repo'" && log_info "Repository initialized" || { log_error "Init failed"; return 1; }
}

build_excludes() {
    local args=""
    [[ ${#EXCLUDE_PATTERNS[@]} -gt 0 ]] && for pattern in "${EXCLUDE_PATTERNS[@]}"; do [[ -n "$pattern" ]] && args="$args --exclude '$pattern'"; done
    [[ ${#MEDIA_PATTERNS[@]} -gt 0 ]] && for pattern in "${MEDIA_PATTERNS[@]}"; do [[ -n "$pattern" ]] && args="$args --exclude '$pattern'"; done
    echo "$args"
}

find_changed() {
    local source="$1" window="$2" temp=$(mktemp)
    log_debug "Finding files changed in last $window minutes"
    find "$source" -type f -mmin -"$window" > "$temp" 2>/dev/null || true
    local count=$(wc -l < "$temp")
    log_info "Found $count changed files in last $window minutes"
    [[ "$VERBOSE" == "true" && "$count" -gt 0 ]] && { log_debug "Changed files:"; while read -r f; do log_debug "  $f"; done < "$temp"; }
    echo "$temp"
}

run_backup() {
    local source="$1" dest="$2" mode="$3" compression="$4" window="$5"
    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local archive="backup_$timestamp"
    local excludes=$(build_excludes)
    
    # Environment
    export BORG_REPO="$dest"
    [[ -n "$PASSPHRASE" ]] && export BORG_PASSPHRASE="$PASSPHRASE"
    
    init_repo "$dest" "$compression" || return 1
    
    # Base command
    local cmd="borg create"
    [[ "$compression" != "none" ]] && cmd="$cmd --compression=$compression"
    [[ "$USE_DEDUP" == "true" ]] && cmd="$cmd --chunker-params=19,23,21,4095"
    [[ -n "$excludes" ]] && cmd="$cmd $excludes"
    [[ "$VERBOSE" == "true" ]] && cmd="$cmd --verbose --list"
    
    case "$mode" in
        "incremental")
            local changed=$(find_changed "$source" "$window") count=$(wc -l < "$changed")
            if [[ "$count" -eq 0 ]]; then
                log_info "No changes, skipping backup"
                rm -f "$changed"; return 0
            fi
            
            log_info "Creating incremental backup ($count files)"
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would backup:"
                head -5 "$changed"; [[ "$count" -gt 5 ]] && log_info "... and $((count-5)) more"
            else
                cmd="$cmd --files-from='$changed' '$dest::$archive' ."
                (cd "$source" && eval "$cmd") && log_info "Incremental backup completed" || { log_error "Backup failed"; rm -f "$changed"; return 1; }
            fi
            rm -f "$changed"
            ;;
        "full"|"borg-auto")
            log_info "Creating $mode backup"
            cmd="$cmd '$dest::$archive' '$source'"
            if [[ "$DRY_RUN" == "true" ]]; then
                log_info "[DRY RUN] Would run: $cmd"
            else
                eval "$cmd" && log_info "$mode backup completed" || { log_error "Backup failed"; return 1; }
            fi
            ;;
    esac
    
    # Prune
    log_info "Pruning (keep: ${KEEP_HOURLY}h ${KEEP_DAILY}d ${KEEP_WEEKLY}w ${KEEP_MONTHLY}m ${KEEP_YEARLY}y)"
    local prune="borg prune --keep-hourly=$KEEP_HOURLY --keep-daily=$KEEP_DAILY --keep-weekly=$KEEP_WEEKLY --keep-monthly=$KEEP_MONTHLY --keep-yearly=$KEEP_YEARLY"
    [[ "$VERBOSE" == "true" ]] && prune="$prune --verbose --list"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY RUN] Would prune with: $prune '$dest'"
    else
        eval "$prune '$dest'" && log_info "Pruning completed" || log_warn "Pruning failed (non-critical)"
    fi
}

# Usage
usage() {
    cat << 'EOF'
Generic Backup Tool - TOML Configuration

USAGE: ./backup.sh [OPTIONS]

OPTIONS:
  -c, --config FILE    Config file (default: backup.toml)  
  -s, --source DIR     Source directory (overrides config)
  -d, --dest DIR       Destination directory (overrides config)
  -m, --mode MODE      Mode: incremental|full|borg-auto (overrides config)
  -t, --time MINS      Time window for incremental (overrides config)
  -n, --dry-run        Show what would be done
  -v, --verbose        Verbose output
  -f, --force-init     Force repository initialization
  -h, --help           Show this help

EXAMPLES:
  ./backup.sh                    # Use backup.toml config
  ./backup.sh --dry-run -v       # Test run with verbose output
  ./backup.sh -s /src -d /dest   # Override source/destination
  ./backup.sh -m full            # Force full backup
EOF
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -s|--source) SOURCE_OVERRIDE="$2"; shift 2 ;;
        -d|--dest) DEST_OVERRIDE="$2"; shift 2 ;;
        -m|--mode) MODE_OVERRIDE="$2"; shift 2 ;;
        -t|--time) TIME_WINDOW_OVERRIDE="$2"; shift 2 ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        -v|--verbose) VERBOSE=true; shift ;;
        -f|--force-init) FORCE_INIT=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# Main execution
log_info "Generic Backup Tool Starting"

# Load and validate config
load_config "$CONFIG_FILE" || exit 1

# Apply overrides
[[ -n "${SOURCE_OVERRIDE:-}" ]] && SOURCE="$SOURCE_OVERRIDE"
[[ -n "${DEST_OVERRIDE:-}" ]] && DEST="$DEST_OVERRIDE"
[[ -n "${MODE_OVERRIDE:-}" ]] && MODE="$MODE_OVERRIDE"
[[ -n "${TIME_WINDOW_OVERRIDE:-}" ]] && TIME_WINDOW="$TIME_WINDOW_OVERRIDE"

validate_config || exit 1

# Display config
log_info "Config: $SOURCE -> $DEST ($MODE, ${TIME_WINDOW}min, ${#EXCLUDE_PATTERNS[@]} excludes)"

# Check borg
command -v borg >/dev/null || { log_error "borg not found"; exit 1; }

# Run backup
run_backup "$SOURCE" "$DEST" "$MODE" "$COMPRESSION" "$TIME_WINDOW" && {
    log_info "Backup completed successfully"
} || {
    log_error "Backup failed"
    exit 1
}

