#!/bin/bash
###############################################################################
# build-iso.sh — Custom Debian Live ISO build with ZFS
#
# Usage:
#   sudo bash scripts/build-iso.sh [OPTIONS]
#
# Options:
#   --clean               Clean previous builds
#   --debug               Debug mode
#   --output-dir DIR      Output directory (default: output)
#   --help                Show help
#
# Requirements:
#   - Debian Bookworm or newer
#   - live-build package
#   - Minimum 10GB free space
#   - Root privileges
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
CLEAN_MODE=false
DEBUG_MODE=false
OUTPUT_DIR="output"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LB_CONFIG_DIR="$PROJECT_DIR/config/live-build"

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --clean) CLEAN_MODE=true; shift ;;
        --debug) DEBUG_MODE=true; set -x; shift ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --help)
            head -n 20 "$0" | tail -n +2 | sed 's/^# \?//'
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
# Checks
###############################################################################

check_prerequisites() {
    log_step "Checking prerequisites"

    # Check filesystem (WSL /mnt/ issues)
    local work_dir_path
    work_dir_path="$(pwd)"
    if echo "$work_dir_path" | grep -q '^/mnt/'; then
        log_warn "Detected WSL operation on mounted filesystem (/mnt/)"
        log_warn "live-build on NTFS/DrvFs may fail with tar errors"
        log_info "Recommended to copy project to native Linux filesystem:"
        log_info "  cp -r $work_dir_path ~/debian-zfs && cd ~/debian-zfs"
        read -p "Continue anyway? (yes/no): " fs_confirm
        if [ "$fs_confirm" != "yes" ]; then
            log_info "Build cancelled"
            exit 0
        fi
    fi

    # Check live-build
    if ! command -v lb &>/dev/null && ! command -v live-build &>/dev/null; then
        log_warn "live-build not installed"
        read -p "Install live-build? (yes/no): " confirm
        if [ "$confirm" = "yes" ]; then
            DEBIAN_FRONTEND=noninteractive apt update
            DEBIAN_FRONTEND=noninteractive apt install -y live-build
        else
            log_error "live-build required for build"
            exit 1
        fi
    fi

    # Check space
    local available_space
    available_space=$(df -BM . | awk 'NR==2 {print $4}' | tr -d 'M')
    available_space=$((available_space / 1024))

    if [ "$available_space" -lt 10 ]; then
        log_error "Insufficient space! Minimum 10GB required"
        log_info "Available: ${available_space}GB"
        exit 1
    fi

    log_info "live-build installed ✓"
    log_info "Available space: ${available_space}GB ✓"
}

###############################################################################
# Cleanup
###############################################################################

clean_previous() {
    if [ "$CLEAN_MODE" = true ]; then
        log_step "Cleaning previous builds"

        # Clean live-build
        if [ -d auto ]; then
            lb clean
        fi

        # Remove output directory
        if [ -d "$OUTPUT_DIR" ]; then
            log_info "Removing $OUTPUT_DIR..."
            rm -rf "$OUTPUT_DIR"
        fi

        log_info "Cleanup completed"
    fi
}

###############################################################################
# live-build setup
###############################################################################

setup_live_build() {
    log_step "Configuring live-build"

    # Create working directory
    local work_dir="live-build-work"
    mkdir -p "$work_dir"
    cd "$work_dir"

    # Always reinitialize to avoid configuration conflicts
    if [ -d auto ]; then
        log_info "Cleaning previous configuration..."
        lb clean 2>/dev/null || true
        rm -rf auto config
    fi

    # Clear debootstrap cache (common cause of tar errors)
    if [ -d cache ]; then
        log_info "Clearing debootstrap cache..."
        rm -rf cache
    fi

    log_info "Initializing live-build with bookworm parameters..."

    # Initialize with explicit parameters (avoid auto/config issues)
    lb config \
        --architecture amd64 \
        --distribution bookworm \
        --archive-areas "main contrib non-free non-free-firmware" \
        --linux-flavours amd64 \
        2>&1 | tee -a build.log

    # Enable backports (no command line parameter, modify file directly)
    log_info "Enabling backports..."
    sed -i 's/LB_BACKPORTS="false"/LB_BACKPORTS="true"/g' config/chroot

    # Check configuration
    log_info "Configuration check:"
    grep "LB_DISTRIBUTION=" config/bootstrap | head -1
    grep "LB_ARCHIVE_AREAS=" config/bootstrap | head -1
    grep "LB_BACKPORTS=" config/chroot | head -1

    # Copy configuration
    log_info "Copying configuration..."

    # Package lists
    if [ -d "$LB_CONFIG_DIR/package-lists" ]; then
        mkdir -p config/package-lists
        cp "$LB_CONFIG_DIR"/package-lists/*.chroot config/package-lists/
        log_info "Package lists copied"
    fi

    # Includes
    if [ -d "$LB_CONFIG_DIR/includes.chroot" ]; then
        mkdir -p config/includes.chroot
        cp -r "$LB_CONFIG_DIR"/includes.chroot/* config/includes.chroot/
        log_info "Includes copied"
    fi

    log_info "live-build configuration ready"
}

###############################################################################
# Build
###############################################################################

build_iso() {
    log_step "Building ISO"

    mkdir -p "$PROJECT_DIR/$OUTPUT_DIR"

    log_info "Starting build (this may take 20-40 minutes)..."
    log_info "Log saved to build.log"

    # Start build (use pipefail-safe pattern)
    local build_status=0
    lb build > build.log 2>&1 || build_status=$?

    if [ "$build_status" -ne 0 ]; then
        log_error "Build failed! (exit code: $build_status)"
        log_info "Last 50 lines from build.log:"
        tail -n 50 build.log
        exit 1
    fi

    log_info "Build completed successfully ✓"

    # Copy ISO (check multiple possible locations/patterns)
    local iso_file=""

    # Try common patterns: live-image-*.iso, binary.iso, or any .iso
    for pattern in "live-image-*.iso" "binary.iso" "*.iso"; do
        if ls $pattern 1>/dev/null 2>&1; then
            iso_file=$(ls -t $pattern 2>/dev/null | head -n 1)
            break
        fi
    done

    if [ -z "$iso_file" ]; then
        # Deep search in subdirectories
        iso_file=$(find . -name "*.iso" -type f 2>/dev/null | head -n 1)
    fi

    if [ -n "$iso_file" ]; then
        cp "$iso_file" "$PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso"

        log_info "ISO copied:"
        log_info "  $PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso"

        # Size
        local size
        size=$(du -h "$PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso" | cut -f1)
        log_info "Size: $size"
    else
        log_error "ISO file not found!"
        log_info "Current directory contents:"
        ls -la
        log_info "Check build.log for details"
        exit 1
    fi
}

###############################################################################
# Post-processing
###############################################################################

post_build() {
    log_step "Post-processing"

    # Create SHA256
    if [ -f "$PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso" ]; then
        log_info "Creating SHA256 hash..."
        (cd "$PROJECT_DIR/$OUTPUT_DIR" && sha256sum debian-zfs-live.iso > debian-zfs-live.iso.sha256)
        log_info "Hash created:"
        cat "$PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso.sha256"
    fi

    # Clean working directory
    local work_dir="$PROJECT_DIR/live-build-work"
    log_warn "Working directory preserved for debugging:"
    log_warn "  $work_dir"
    log_info "To remove: rm -rf $work_dir"
}

###############################################################################
# Main process
###############################################################################

main() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Debian ZFS Live ISO Builder"
    log_info "Version: 1.0 (April 2026)"
    log_info "═══════════════════════════════════════════════════════"

    check_prerequisites
    clean_previous
    setup_live_build
    build_iso
    post_build

    log_info ""
    log_warn "═══════════════════════════════════════════════════════"
    log_warn "ISO BUILT SUCCESSFULLY!"
    log_warn "═══════════════════════════════════════════════════════"
    log_info ""
    log_info "ISO file:"
    log_info "  $PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Write to USB:"
    log_info "     sudo dd if=$PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso of=/dev/sdX bs=4M status=progress"
    log_info ""
    log_info "  2. Or use script:"
    log_info "     sudo bash scripts/usb-write.sh /dev/sdX"
    log_info ""
    log_info "  3. Test in QEMU:"
    log_info "     bash scripts/test-vm.sh $PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso"
    log_info ""
}

main "$@"
