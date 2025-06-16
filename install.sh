#!/bin/bash
# Generic Backup Tool Installer - Cross-platform automated scheduling
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
CONFIG_FILE="$SCRIPT_DIR/backup.toml"
EXAMPLE_CONFIG_FILE="$SCRIPT_DIR/backup.example.toml"
SERVICE_NAME="snapshots"

# Installation paths
INSTALLED_BACKUP_SCRIPT="$HOME/backup.sh"
INSTALLED_CONFIG_FILE="$HOME/backup.toml"

# Colors & Logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# OS Detection
detect_os() { [[ "$OSTYPE" == "darwin"* ]] && echo "macos" || echo "linux"; }

# Copy files to user home
copy_files() {
    log_info "Copying backup files to home directory..."
    
    # Copy backup script
    cp "$BACKUP_SCRIPT" "$INSTALLED_BACKUP_SCRIPT" || { log_error "Failed to copy backup script"; return 1; }
    chmod +x "$INSTALLED_BACKUP_SCRIPT"
    log_info "Copied: $INSTALLED_BACKUP_SCRIPT"
    
    # Copy config file (only if it doesn't exist to preserve user customizations)
    if [[ ! -f "$INSTALLED_CONFIG_FILE" ]]; then
        # Use local backup.toml if it exists, otherwise use example
        local source_config="$CONFIG_FILE"
        [[ ! -f "$source_config" ]] && source_config="$EXAMPLE_CONFIG_FILE"
        
        cp "$source_config" "$INSTALLED_CONFIG_FILE" || { log_error "Failed to copy config file"; return 1; }
        log_info "Copied: $INSTALLED_CONFIG_FILE (from $(basename "$source_config"))"
        
        # If we used the example, remind user to customize
        [[ "$source_config" == "$EXAMPLE_CONFIG_FILE" ]] && log_warn "Please customize $INSTALLED_CONFIG_FILE with your paths"
    else
        log_info "Config exists: $INSTALLED_CONFIG_FILE (preserved)"
    fi
}

# Remove installed files
remove_files() {
    log_info "Removing installed backup files..."
    [[ -f "$INSTALLED_BACKUP_SCRIPT" ]] && { rm -f "$INSTALLED_BACKUP_SCRIPT"; log_info "Removed: $INSTALLED_BACKUP_SCRIPT"; }
    [[ -f "$INSTALLED_CONFIG_FILE" ]] && { 
        read -p "Remove config file $INSTALLED_CONFIG_FILE? [y/N]: " -n 1 -r
        echo
        [[ $REPLY =~ ^[Yy]$ ]] && { rm -f "$INSTALLED_CONFIG_FILE"; log_info "Removed: $INSTALLED_CONFIG_FILE"; }
    }
}

# Validation
validate() {
    # Check for config file (either backup.toml or backup.example.toml)
    local config_to_check="$CONFIG_FILE"
    [[ ! -f "$config_to_check" ]] && config_to_check="$EXAMPLE_CONFIG_FILE"
    [[ ! -f "$config_to_check" ]] && { log_error "No config found: $CONFIG_FILE or $EXAMPLE_CONFIG_FILE"; return 1; }
    
    [[ ! -x "$BACKUP_SCRIPT" ]] && { log_error "Backup script not executable: $BACKUP_SCRIPT"; return 1; }
    
    # Test with the available config
    "$BACKUP_SCRIPT" --config "$config_to_check" --dry-run >/dev/null 2>&1 || { 
        log_error "Config validation failed with $config_to_check"
        [[ "$config_to_check" == "$EXAMPLE_CONFIG_FILE" ]] && log_warn "Example config has placeholder paths - this is expected"
        return 1
    }
    log_info "Configuration validated"
}

# macOS Installation (launchd)
install_macos() {
    local install_type="$1" interval="$2"
    local plist_dir="$([[ "$install_type" == "system" ]] && echo "/Library/LaunchDaemons" || echo "$HOME/Library/LaunchAgents")"
    local plist_file="$plist_dir/snapshots.plist"
    
    log_info "Installing macOS service ($install_type level)"
    
    # Copy files to home directory
    copy_files || return 1
    
    mkdir -p "$plist_dir"
    
    cat > "$plist_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>snapshots</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALLED_BACKUP_SCRIPT</string>
        <string>--config</string>
        <string>$INSTALLED_CONFIG_FILE</string>
    </array>
    <key>StartInterval</key><integer>$interval</integer>
    <key>RunAtLoad</key><false/>
    <key>StandardOutPath</key><string>/var/log/snapshots.log</string>
    <key>StandardErrorPath</key><string>/var/log/snapshots-error.log</string>
    <key>WorkingDirectory</key><string>$HOME</string>
    <key>UserName</key><string>$(whoami)</string>
</dict>
</plist>
EOF

    launchctl load "$plist_file" && {
        log_info "Service installed (runs every $((interval/60)) minutes)"
        log_info "Logs: /var/log/snapshots.log"
    } || { log_error "Service installation failed"; return 1; }
}

# Linux Installation (systemd)
install_linux() {
    local install_type="$1" interval="$2"
    local systemd_dir="$([[ "$install_type" == "system" ]] && echo "/etc/systemd/system" || echo "$HOME/.config/systemd/user")"
    [[ "$install_type" == "user" ]] && mkdir -p "$systemd_dir"
    
    log_info "Installing Linux service ($install_type level)"
    
    # Copy files to home directory
    copy_files || return 1
    
    # Service file
    cat > "$systemd_dir/$SERVICE_NAME.service" << EOF
[Unit]
Description=Generic Backup Tool
After=network.target

[Service]
Type=oneshot
User=$(whoami)
WorkingDirectory=$HOME
ExecStart=$INSTALLED_BACKUP_SCRIPT --config $INSTALLED_CONFIG_FILE
StandardOutput=journal
StandardError=journal
EOF

    # Timer file
    cat > "$systemd_dir/$SERVICE_NAME.timer" << EOF
[Unit]
Description=Run Generic Backup Tool every ${interval} seconds
Requires=$SERVICE_NAME.service

[Timer]
OnBootSec=${interval}sec
OnUnitActiveSec=${interval}sec
Persistent=true

[Install]
WantedBy=timers.target
EOF

    # Enable and start
    local ctl="systemctl $([[ "$install_type" == "user" ]] && echo "--user")"
    $ctl daemon-reload
    $ctl enable "$SERVICE_NAME.timer"
    $ctl start "$SERVICE_NAME.timer"
    
    log_info "Service installed (runs every $((interval/60)) minutes)"
    log_info "View logs: journalctl $([[ "$install_type" == "user" ]] && echo "--user") -u $SERVICE_NAME.service -f"
}

# Uninstallation
uninstall() {
    local os_type="$1" install_type="$2"
    log_info "Uninstalling service..."
    
    case "$os_type" in
        "macos")
            local plist="$([[ "$install_type" == "system" ]] && echo "/Library/LaunchDaemons" || echo "$HOME/Library/LaunchAgents")/snapshots.plist"
            [[ -f "$plist" ]] && { launchctl unload "$plist" 2>/dev/null || true; rm -f "$plist"; }
            ;;
        "linux")
            local ctl="systemctl $([[ "$install_type" == "user" ]] && echo "--user")"
            $ctl stop "$SERVICE_NAME.timer" 2>/dev/null || true
            $ctl disable "$SERVICE_NAME.timer" 2>/dev/null || true
            local dir="$([[ "$install_type" == "system" ]] && echo "/etc/systemd/system" || echo "$HOME/.config/systemd/user")"
            rm -f "$dir/$SERVICE_NAME.service" "$dir/$SERVICE_NAME.timer"
            $ctl daemon-reload
            ;;
    esac
    log_info "Service uninstalled"
    
    # Remove installed files
    remove_files
}

# Status check
status() {
    local os_type="$1" install_type="$2"
    case "$os_type" in
        "macos") launchctl list | grep "snapshots" || log_warn "Service not found" ;;
        "linux") 
            local ctl="systemctl $([[ "$install_type" == "user" ]] && echo "--user")"
            $ctl status "$SERVICE_NAME.timer" --no-pager -l || log_warn "Service not found"
            ;;
    esac
}

# Usage
usage() {
    cat << 'EOF'
Generic Backup Tool Installer

USAGE: ./install.sh [OPTIONS] COMMAND

COMMANDS:
  install      Install and start backup service (copies files to ~/backup.sh and ~/backup.toml)
  uninstall    Remove backup service and installed files
  status       Show service status
  test         Test backup configuration

OPTIONS:
  --user       User service (default)
  --system     System service (requires sudo)
  --interval N Backup interval in seconds (default: 300)
  -h, --help   Show help

EXAMPLES:
  ./install.sh install                # Install user service
  ./install.sh install --system       # Install system service  
  ./install.sh install --interval 180 # 3-minute interval
  ./install.sh status                 # Show status
  ./install.sh uninstall              # Remove service and files

NOTES:
  - Installation copies backup.sh and backup.toml to your home directory
  - Existing ~/backup.toml is preserved during installation
  - Uninstall prompts before removing ~/backup.toml (preserves customizations)
EOF
}

# Main execution
install_type="user" interval=300 command=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        install|uninstall|status|test) command="$1"; shift ;;
        --user) install_type="user"; shift ;;
        --system) install_type="system"; shift ;;
        --interval) interval="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

[[ -z "$command" ]] && { log_error "No command specified"; usage; exit 1; }

# OS detection
os_type=$(detect_os)
[[ "$os_type" == "linux" ]] || [[ "$os_type" == "macos" ]] || { log_error "Unsupported OS: $OSTYPE"; exit 1; }
log_info "Detected OS: $os_type"

# Validate interval and privileges
[[ ! "$interval" =~ ^[0-9]+$ || "$interval" -lt 60 ]] && { log_error "Invalid interval: $interval (min 60s)"; exit 1; }
[[ "$install_type" == "system" && "$EUID" -ne 0 ]] && { log_error "System install requires sudo"; exit 1; }

# Execute command
case "$command" in
    "test") validate ;;
    "status") status "$os_type" "$install_type" ;;
    "install") 
        validate || exit 1
        case "$os_type" in
            "macos") install_macos "$install_type" "$interval" ;;
            "linux") install_linux "$install_type" "$interval" ;;
        esac
        ;;
    "uninstall") uninstall "$os_type" "$install_type" ;;
esac 