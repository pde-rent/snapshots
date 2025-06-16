#!/bin/bash
# Generic Backup Tool Installer - Cross-platform automated scheduling
set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
CONFIG_FILE="$SCRIPT_DIR/backup.toml"
SERVICE_NAME="backup-tool"

# Colors & Logging
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# OS Detection
detect_os() { [[ "$OSTYPE" == "darwin"* ]] && echo "macos" || echo "linux"; }

# Validation
validate() {
    [[ ! -f "$CONFIG_FILE" ]] && { log_error "Config not found: $CONFIG_FILE"; return 1; }
    [[ ! -x "$BACKUP_SCRIPT" ]] && { log_error "Backup script not executable: $BACKUP_SCRIPT"; return 1; }
    "$BACKUP_SCRIPT" --dry-run >/dev/null 2>&1 || { log_error "Config validation failed"; return 1; }
    log_info "Configuration validated"
}

# macOS Installation (launchd)
install_macos() {
    local install_type="$1" interval="$2"
    local plist_dir="$([[ "$install_type" == "system" ]] && echo "/Library/LaunchDaemons" || echo "$HOME/Library/LaunchAgents")"
    local plist_file="$plist_dir/com.backup-tool.plist"
    
    log_info "Installing macOS service ($install_type level)"
    mkdir -p "$plist_dir"
    
    cat > "$plist_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.backup-tool</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BACKUP_SCRIPT</string>
        <string>--config</string>
        <string>$CONFIG_FILE</string>
    </array>
    <key>StartInterval</key><integer>$interval</integer>
    <key>RunAtLoad</key><false/>
    <key>StandardOutPath</key><string>/var/log/backup-tool.log</string>
    <key>StandardErrorPath</key><string>/var/log/backup-tool-error.log</string>
    <key>WorkingDirectory</key><string>$SCRIPT_DIR</string>
    <key>UserName</key><string>$(whoami)</string>
</dict>
</plist>
EOF

    launchctl load "$plist_file" && {
        log_info "Service installed (runs every $((interval/60)) minutes)"
        log_info "Logs: /var/log/backup-tool.log"
    } || { log_error "Service installation failed"; return 1; }
}

# Linux Installation (systemd)
install_linux() {
    local install_type="$1" interval="$2"
    local systemd_dir="$([[ "$install_type" == "system" ]] && echo "/etc/systemd/system" || echo "$HOME/.config/systemd/user")"
    [[ "$install_type" == "user" ]] && mkdir -p "$systemd_dir"
    
    log_info "Installing Linux service ($install_type level)"
    
    # Service file
    cat > "$systemd_dir/$SERVICE_NAME.service" << EOF
[Unit]
Description=Generic Backup Tool
After=network.target

[Service]
Type=oneshot
User=$(whoami)
WorkingDirectory=$SCRIPT_DIR
ExecStart=$BACKUP_SCRIPT --config $CONFIG_FILE
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
            local plist="$([[ "$install_type" == "system" ]] && echo "/Library/LaunchDaemons" || echo "$HOME/Library/LaunchAgents")/com.backup-tool.plist"
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
}

# Status check
status() {
    local os_type="$1" install_type="$2"
    case "$os_type" in
        "macos") launchctl list | grep "backup-tool" || log_warn "Service not found" ;;
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
  install      Install and start backup service
  uninstall    Remove backup service  
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
  ./install.sh uninstall              # Remove service
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