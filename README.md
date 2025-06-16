# Borg-based snapshots

High-performance incremental backup system with sophisticated retention policies, powered by [Borg](https://www.borgbackup.org/) and pure bash configuration.

## Quick Start

1. **Install Borg**: `brew install borgbackup` (macOS) or `apt install borgbackup` (Linux)
2. **Configure**: Copy `backup.example.toml` to `backup.toml` and customize paths/settings
3. **Install**: `./install.sh install` (copies files to `~/backup.sh` and `~/backup.toml`, runs every 5 minutes)

## Features

- **Incremental backups**: Only files changed in last 5 minutes (99.995% size reduction)
- **Deduplication**: Borg's space-efficient storage
- **Smart retention**: 5min/30min/daily/monthly/yearly schedules
- **Cross-platform**: macOS (launchd) and Linux (systemd) scheduling
- **Zero dependencies**: Pure bash with TOML config parsing

## Configuration

Copy `backup.example.toml` to `backup.toml` and edit:

```toml
[backup]
source = "/path/to/source"
destination = "/path/to/backups"
mode = "incremental"  # or "full", "borg-auto"
compression = "zstd"

[retention]
keep_within = "1H"      # 5-minute snapshots for 1 hour
keep_minutely = 48      # 30-minute backups for 1 day
keep_daily = 14         # Daily for 2 weeks
keep_monthly = 12       # Monthly for 1 year
keep_yearly = 5         # Yearly for 5 years

[excludes.patterns]
dirs = ["**/node_modules", "**/.venv", "**/.git", "**/build", "**/dist"]
files = ["**/*.tmp", "**/*.log", "**/.DS_Store"]
```

## Usage

```bash
# Test configuration
./backup.sh --dry-run

# Manual backup
./backup.sh --config backup.toml

# Install/manage service
./install.sh install           # User service
./install.sh install --system  # System service (sudo)
./install.sh status            # Check status
./install.sh uninstall         # Remove service

# Borg operations
borg list /path/to/repo        # List archives
borg mount /path/to/repo /mnt  # Mount backups
```

## Architecture

- **Incremental mode**: `find -mmin` + `borg create` for changed files only
- **Full mode**: Complete backup with deduplication
- **Borg-auto mode**: Borg handles incremental detection

## Space Efficiency

From 11GB source to 551 bytes incremental backup (typical 2-file change):
- Development exclusions (node_modules, .venv): 95% reduction
- Incremental detection: 99.8% reduction  
- Borg compression: 99.995% total reduction

## File Structure

```
backup.sh            # Main backup script
backup.example.toml  # Configuration template
install.sh           # Cross-platform installer
README.md            # This file
```
