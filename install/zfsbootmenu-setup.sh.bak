#!/bin/bash
###############################################################################
# zfsbootmenu-setup.sh — ZFSBootMenu setup on existing system
#
# Usage:
#   sudo bash zfsbootmenu-setup.sh [OPTIONS]
#
# Options:
#   --pool NAME         ZFS pool name (default: zroot)
#   --dataset NAME      ROOT dataset (default: ROOT/bookworm)
#   --boot-device DEV   EFI partition (default: /dev/sda1)
#   --boot-disk DEV     Disk with EFI (default: /dev/sda)
#   --boot-part NUM     EFI partition number (default: 1)
#   --update            Update existing installation
#   --help              Show help
#
# Note: Run from live environment or installed system
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
POOL_NAME="zroot"
ROOT_DATASET="ROOT/bookworm"
BOOT_DEVICE="/dev/sda1"
BOOT_DISK="/dev/sda"
BOOT_PART="1"
UPDATE_MODE=false

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --pool) POOL_NAME="$2"; shift 2 ;;
        --dataset) ROOT_DATASET="$2"; shift 2 ;;
        --boot-device) BOOT_DEVICE="$2"; shift 2 ;;
        --boot-disk) BOOT_DISK="$2"; shift 2 ;;
        --boot-part) BOOT_PART="$2"; shift 2 ;;
        --update) UPDATE_MODE=true; shift ;;
        --help)
            head -n 25 "$0" | tail -n +2 | sed 's/^# \?//'
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

    # Check required packages
    local required_packages=(zfs zpool blkid mkfs.vfat curl efibootmgr)
    local missing_packages=()

    for pkg in "${required_packages[@]}"; do
        if ! command -v "$pkg" &>/dev/null; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -gt 0 ]; then
        log_error "Missing required packages:"
        for pkg in "${missing_packages[@]}"; do
            log_error "  - $pkg"
        done
        log_info ""
        log_info "Install missing packages:"
        log_info "  apt install -y dosfstools efibootmgr curl"
        exit 1
    fi

    # Check pool
    if ! zpool list "$POOL_NAME" &>/dev/null; then
        log_error "Pool $POOL_NAME not found!"
        log_info "Available pools:"
        zpool list
        exit 1
    fi

    # Check dataset
    if ! zfs list "$POOL_NAME/$ROOT_DATASET" &>/dev/null; then
        log_error "Dataset $POOL_NAME/$ROOT_DATASET not found!"
        log_info "Available datasets:"
        zfs list
        exit 1
    fi

    # Check boot device
    if [ ! -b "$BOOT_DEVICE" ]; then
        log_warn "Device $BOOT_DEVICE not found"
        log_info "Specify correct device via --boot-device"
        log_info "Current partitions:"
        lsblk -ln -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v loop
        read -p "Continue with specified device? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            exit 1
        fi
    fi

    log_info "Pool: $POOL_NAME ✓"
    log_info "Dataset: $POOL_NAME/$ROOT_DATASET ✓"
    log_info "EFI device: $BOOT_DEVICE"
}

###############################################################################
# ZFSBootMenu setup
###############################################################################

set_dataset_properties() {
    log_step "Configuring dataset properties"

    # Set commandline for ZFSBootMenu
    log_info "Setting org.zfsbootmenu:commandline..."
    zfs set org.zfsbootmenu:commandline="quiet loglevel=0" \
        "$POOL_NAME/$ROOT_DATASET"

    # Check encryption
    local encryption
    encryption=$(zfs get -H -o value encryption "$POOL_NAME/$ROOT_DATASET" 2>/dev/null || echo "off")

    if [ "$encryption" != "off" ]; then
        log_info "Encryption detected, configuring keysource..."
        zfs set org.zfsbootmenu:keysource="$POOL_NAME/$ROOT_DATASET" \
            "$POOL_NAME"
    fi

    log_info "Properties set"
    zfs get org.zfsbootmenu:commandline "$POOL_NAME/$ROOT_DATASET"
}

mount_efi() {
    log_step "Mounting EFI System Partition"

    # Check if already mounted
    if mount | grep -q "/boot/efi"; then
        log_info "EFI already mounted at /boot/efi"
        return 0
    fi

    # Check if partition is formatted as FAT
    local fs_type
    fs_type=$(blkid -s TYPE -o value "$BOOT_DEVICE" 2>/dev/null || echo "")
    
    if [ "$fs_type" != "vfat" ]; then
        log_warn "EFI partition is not formatted as FAT32!"
        log_info "Formatting $BOOT_DEVICE as FAT32..."
        
        # Check if dosfstools is installed
        if ! command -v mkfs.vfat &>/dev/null; then
            log_error "mkfs.vfat not found! Install dosfstools first."
            log_info "Run: apt install -y dosfstools"
            exit 1
        fi
        
        # Format partition
        mkfs.vfat -F32 "$BOOT_DEVICE" || {
            log_error "Failed to format EFI partition!"
            exit 1
        }
        
        log_info "EFI partition formatted successfully"
    fi

    # Add fstab entry if not exists
    if ! grep -q "/boot/efi" /etc/fstab; then
        log_info "Adding entry to /etc/fstab..."
        local BOOT_UUID
        BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEVICE" 2>/dev/null || echo "")

        if [ -n "$BOOT_UUID" ]; then
            echo "UUID=${BOOT_UUID}  /boot/efi  vfat  defaults  0  0" >> /etc/fstab
        else
            echo "${BOOT_DEVICE}  /boot/efi  vfat  defaults  0  0" >> /etc/fstab
        fi
    fi

    # Mount
    log_info "Mounting /boot/efi..."
    mkdir -p /boot/efi
    
    # Try to mount with explicit filesystem type
    mount -t vfat "$BOOT_DEVICE" /boot/efi || {
        log_error "Failed to mount EFI partition!"
        log_info "Try manual mount: mount -t vfat $BOOT_DEVICE /boot/efi"
        exit 1
    }

    log_info "EFI mounted successfully"
}

download_zfsbootmenu() {
    log_step "Installing ZFSBootMenu"

    local ZBM_DIR="/boot/efi/EFI/ZBM"

    # Create directory
    mkdir -p "$ZBM_DIR"

    if [ "$UPDATE_MODE" = true ] && [ -f "$ZBM_DIR/VMLINUZ.EFI" ]; then
        log_info "Update mode — creating backup..."
        cp "$ZBM_DIR/VMLINUZ.EFI" "$ZBM_DIR/VMLINUZ-OLD.EFI"
    fi

    # Download EFI binary
    log_info "Downloading ZFSBootMenu EFI..."
    curl -o "$ZBM_DIR/VMLINUZ.EFI" -L https://get.zfsbootmenu.org/efi

    # Create backup
    log_info "Creating backup..."
    cp "$ZBM_DIR/VMLINUZ.EFI" "$ZBM_DIR/VMLINUZ-BACKUP.EFI"

    # Check
    local size
    size=$(stat -f%z "$ZBM_DIR/VMLINUZ.EFI" 2>/dev/null || stat -c%s "$ZBM_DIR/VMLINUZ.EFI")
    log_info "VMLINUZ.EFI size: $size bytes"

    # Verify version
    if strings "$ZBM_DIR/VMLINUZ.EFI" | grep -q -i zfsbootmenu; then
        log_info "ZFSBootMenu EFI verified ✓"
    else
        log_warn "Could not verify EFI file — may be corrupted"
    fi
}

create_efi_entries() {
    log_step "Creating EFI boot entries"

    # Check efivarfs
    if ! mount | grep -q efivarfs; then
        log_info "Mounting efivarfs..."
        mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
    fi

    # Remove old entries (if updating)
    if [ "$UPDATE_MODE" = true ]; then
        log_info "Removing old ZFSBootMenu entries..."
        efibootmgr | grep "ZFSBootMenu" | awk '{print $1}' | sed 's/Boot//;s/\*//' | while read num; do
            efibootmgr -B -b "$num" 2>/dev/null || true
        done
    fi

    # Create backup entry
    log_info "Creating ZFSBootMenu (Backup) entry..."
    efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
        -L "ZFSBootMenu (Backup)" \
        -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'

    # Create main entry
    log_info "Creating ZFSBootMenu entry..."
    efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
        -L "ZFSBootMenu" \
        -l '\EFI\ZBM\VMLINUZ.EFI'

    # Set boot order
    log_info "Configuring boot order..."
    local current_boot
    current_boot=$(efibootmgr | grep "BootCurrent:" | awk '{print $2}')

    log_info "Current BootCurrent: $current_boot"

    # Show all entries
    log_info "EFI boot entries:"
    efibootmgr -v
}

install_from_source() {
    log_step "Installing ZFSBootMenu from source (optional)"

    log_warn "This method requires additional dependencies"
    read -p "Continue with source installation? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Skipping — using prebuilt EFI"
        return 0
    fi

    # Install dependencies
    log_info "Installing dependencies..."
    apt install -y \
        libsort-versions-perl \
        libboolean-perl \
        libyaml-pp-perl \
        git \
        fzf \
        curl \
        mbuffer \
        kexec-tools \
        dracut-core \
        efibootmgr \
        systemd-boot-efi \
        bsdextrautils

    # Download source
    log_info "Downloading ZFSBootMenu..."
    mkdir -p /usr/local/src/zfsbootmenu
    cd /usr/local/src/zfsbootmenu
    curl -L https://get.zfsbootmenu.org/source | tar -zxv --strip-components=1 -f -

    # Build
    log_info "Building ZFSBootMenu..."
    make core dracut

    # Generate image
    log_info "Generating ZFSBootMenu image..."
    generate-zbm

    log_info "Source installation completed"
}

configure_zfsbootmenu() {
    log_step "Creating ZFSBootMenu configuration"

    local CONFIG_DIR="/etc/zfsbootmenu"
    local CONFIG_FILE="$CONFIG_DIR/config.yaml"

    if [ -f "$CONFIG_FILE" ] && [ "$UPDATE_MODE" = false ]; then
        log_warn "Configuration already exists"
        read -p "Overwrite? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "Skipping"
            return 0
        fi
    fi

    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_FILE" << 'EOF'
# ZFSBootMenu Configuration
# Generated by zfsbootmenu-setup.sh

Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
  PreHooksDir: /etc/zfsbootmenu/generation.d
  PostHooksDir: /etc/zfsbootmenu/post-generation.d
  Resolution: 1920x1080
  splash: true

Components:
  Enabled: false
  UsePreBuilt: true

EFI:
  ImageDir: /boot/efi/EFI/ZBM
  Versions: false
  Enabled: true

Kernel:
  CommandLine: quiet loglevel=0
  AllowUnspecified: true
EOF

    log_info "Configuration created: $CONFIG_FILE"

    # Create hook directories
    mkdir -p /etc/zfsbootmenu/generation.d
    mkdir -p /etc/zfsbootmenu/post-generation.d

    log_info "Hook directories created"
}

generate_image() {
    log_step "Generating ZFSBootMenu image"

    # Check generate-zbm
    if ! command -v generate-zbm &>/dev/null; then
        log_warn "generate-zbm not found"
        log_info "Image already ready (prebuilt EFI)"
        return 0
    fi

    log_info "Generating..."
    generate-zbm

    log_info "Image generated"
}

###############################################################################
# Main process
###############################################################################

main() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "ZFSBootMenu Setup Script"
    log_info "Version: 1.0 (April 2026)"
    log_info "═══════════════════════════════════════════════════════"

    check_prerequisites
    set_dataset_properties
    mount_efi
    download_zfsbootmenu
    configure_zfsbootmenu
    create_efi_entries
    generate_image

    log_info ""
    log_warn "═══════════════════════════════════════════════════════"
    log_warn "ZFSBootMenu CONFIGURED SUCCESSFULLY!"
    log_warn "═══════════════════════════════════════════════════════"
    log_info ""
    log_info "EFI files:"
    log_info "  /boot/efi/EFI/ZBM/VMLINUZ.EFI"
    log_info "  /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI"
    log_info ""
    log_info "EFI Boot entries created for:"
    log_info "  Disk: $BOOT_DISK"
    log_info "  Partition: $BOOT_PART"
    log_info ""
    log_info "Usage:"
    log_info "  ESC during boot — ZFSBootMenu menu"
    log_info "  Ctrl+K — select kernel/snapshot"
    log_info "  Ctrl+D — set as default"
    log_info ""
    log_info "Verification:"
    log_info "  efibootmgr -v"
    log_info "  strings /boot/efi/EFI/ZBM/VMLINUZ.EFI | grep -i zfsbootmenu"
    log_info ""
}

main "$@"
