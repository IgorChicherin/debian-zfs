#!/bin/bash
###############################################################################
# zram-config.sh — ZRAM compressed swap configuration
#
# Usage:
#   sudo bash zram-config.sh [OPTIONS]
#
# Options:
#   --size SIZE         ZRAM size in MB or % RAM (default: min(ram*0.6, 4096))
#   --algorithm ALG     Compression algorithm (default: zstd)
#   --swap              Use as swap (default)
#   --filesystem FS     Use as filesystem (ext4)
#   --remove            Remove ZRAM configuration
#   --status            Show ZRAM status
#   --help              Show help
#
# Examples:
#   # Default configuration (60% RAM, zstd, swap)
#   sudo bash zram-config.sh
#
#   # 8GB ZRAM with lz4
#   sudo bash zram-config.sh --size 8192 --algorithm lz4
#
#   # Check status
#   sudo bash zram-config.sh --status
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}[STEP]${NC} $1"; }

# Parameters
ZRAM_SIZE="min(ram * 0.6, 4096)"
ALGORITHM="zstd"
MODE="swap"
REMOVE_MODE=false
STATUS_MODE=false

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --size) ZRAM_SIZE="$2"; shift 2 ;;
        --algorithm) ALGORITHM="$2"; shift 2 ;;
        --swap) MODE="swap"; shift ;;
        --filesystem) MODE="fs"; shift ;;
        --remove) REMOVE_MODE=true; shift ;;
        --status) STATUS_MODE=true; shift ;;
        --help)
            head -n 30 "$0" | tail -n +2 | sed 's/^# \?//'
            exit 0
            ;;
        *) log_error "Unknown parameter: $1"; exit 1 ;;
    esac
done

# Check root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Run this script as root (sudo)"
    exit 1
fi

###############################################################################
# Status mode
###############################################################################

show_status() {
    log_step "ZRAM Status"

    echo ""
    log_info "ZRAM devices:"
    if command -v zramctl &>/dev/null; then
        zramctl 2>/dev/null || log_warn "ZRAM devices not active"
    else
        log_warn "zramctl not installed"
        log_info "Install with: apt install zram-tools"
    fi

    echo ""
    log_info "Swap devices:"
    if command -v swapon &>/dev/null; then
        swapon --show 2>/dev/null || log_warn "Swap not active"
    else
        log_warn "swapon not found"
    fi

    echo ""
    log_info "ZRAM service:"
    if systemctl is-active dev-zram0.swap &>/dev/null; then
        log_info "dev-zram0.swap: active ✓"
    else
        log_warn "dev-zram0.swap: not active"
    fi

    echo ""
    log_info "Configuration:"
    if [ -f /etc/systemd/zram-generator.conf ]; then
        log_info "File: /etc/systemd/zram-generator.conf"
        cat /etc/systemd/zram-generator.conf
    else
        log_warn "Configuration not found"
    fi

    echo ""
    log_info "Memory:"
    free -h

    exit 0
}

###############################################################################
# Removal mode
###############################################################################

remove_config() {
    log_step "Removing ZRAM configuration"

    # Disable swap
    if [ -e /dev/zram0 ]; then
        log_info "Disabling ZRAM swap..."
        swapoff /dev/zram0 2>/dev/null || true
    fi

    # Stop service
    log_info "Stopping services..."
    systemctl stop dev-zram0.swap 2>/dev/null || true

    # Remove configuration
    if [ -f /etc/systemd/zram-generator.conf ]; then
        log_info "Removing /etc/systemd/zram-generator.conf..."
        rm /etc/systemd/zram-generator.conf
    fi

    # Reload systemd
    log_info "Reloading systemd..."
    systemctl daemon-reload

    log_info "ZRAM removed"
    exit 0
}

###############################################################################
# ZRAM installation
###############################################################################

install_packages() {
    log_step "Installing packages"

    if ! command -v systemd-zram-setup &>/dev/null && [ ! -f /usr/lib/systemd/system-generators/zram-generator ]; then
        log_info "Installing systemd-zram-generator..."
        apt update
        apt install -y systemd-zram-generator
    else
        log_info "systemd-zram-generator already installed"
    fi
}

create_config() {
    log_step "Creating ZRAM configuration"

    local CONFIG_FILE="/etc/systemd/zram-generator.conf"

    # Check existing configuration
    if [ -f "$CONFIG_FILE" ]; then
        log_warn "Configuration already exists:"
        cat "$CONFIG_FILE"
        echo ""
        read -p "Overwrite? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Cancelled"
            exit 0
        fi
    fi

    log_info "Creating $CONFIG_FILE..."

    if [ "$MODE" = "swap" ]; then
        cat > "$CONFIG_FILE" << EOF
[zram0]
# Size: $ZRAM_SIZE
zram-size = $ZRAM_SIZE
compression-algorithm = $ALGORITHM
fs-type = swap
mount-point = none
EOF
    else
        cat > "$CONFIG_FILE" << EOF
[zram0]
# Size: $ZRAM_SIZE (filesystem)
zram-size = $ZRAM_SIZE
compression-algorithm = $ALGORITHM
fs-type = ext4
mount-point = /var/compressed
EOF
    fi

    log_info "Configuration created:"
    cat "$CONFIG_FILE"
}

activate_zram() {
    log_step "Activating ZRAM"

    # Reload systemd
    log_info "Reloading systemd daemon..."
    systemctl daemon-reload

    # Start ZRAM
    if [ "$MODE" = "swap" ]; then
        log_info "Starting ZRAM swap..."
        systemctl start dev-zram0.swap

        # Check
        sleep 2
        if systemctl is-active dev-zram0.swap &>/dev/null; then
            log_info "ZRAM swap active ✓"
        else
            log_error "Failed to activate ZRAM swap"
            log_info "Check logs: journalctl -xeu dev-zram0.swap"
            exit 1
        fi
    else
        log_info "For filesystem mode, create mount point:"
        log_info "  mkdir -p /var/compressed"
        log_info "  systemctl start var-compressed.mount"
    fi
}

verify_zram() {
    log_step "Verifying ZRAM"

    echo ""
    log_info "ZRAM devices:"
    zramctl

    echo ""
    log_info "Swap:"
    swapon --show

    echo ""
    log_info "Memory usage:"
    free -h

    echo ""
    log_info "Service:"
    systemctl status dev-zram0.swap --no-pager -l || true
}

###############################################################################
# Main process
###############################################################################

main() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "ZRAM Configuration Script"
    log_info "Version: 1.0 (April 2026)"
    log_info "═══════════════════════════════════════════════════════"

    # Status mode
    if [ "$STATUS_MODE" = true ]; then
        show_status
    fi

    # Removal mode
    if [ "$REMOVE_MODE" = true ]; then
        remove_config
    fi

    # Main installation
    install_packages
    create_config
    activate_zram
    verify_zram

    log_info ""
    log_warn "═══════════════════════════════════════════════════════"
    log_warn "ZRAM CONFIGURED SUCCESSFULLY!"
    log_warn "═══════════════════════════════════════════════════════"
    log_info ""
    log_info "Configuration:"
    log_info "  Size: $ZRAM_SIZE"
    log_info "  Algorithm: $ALGORITHM"
    log_info "  Mode: $MODE"
    log_info ""
    log_info "Configuration file:"
    log_info "  /etc/systemd/zram-generator.conf"
    log_info ""
    log_info "Useful commands:"
    log_info "  zramctl                 # ZRAM information"
    log_info "  swapon --show           # Swap devices"
    log_info "  systemctl status dev-zram0.swap  # Service status"
    log_info "  free -h                 # Memory usage"
    log_info ""
}

main "$@"
