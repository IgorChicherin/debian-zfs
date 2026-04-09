#!/bin/bash
###############################################################################
# zbm-check-kernels.sh — Check and fix ZFSBootMenu kernel detection
#
# Usage:
#   sudo bash zbm-check-kernels.sh [OPTIONS]
#
# Options:
#   --pool NAME         ZFS pool name (default: zroot)
#   --dataset NAME      ROOT dataset (default: ROOT/bookworm)
#   --fix               Attempt to fix kernel detection
#   --help              Show help
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
FIX_MODE=false

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --pool) POOL_NAME="$2"; shift 2 ;;
        --dataset) ROOT_DATASET="$2"; shift 2 ;;
        --fix) FIX_MODE=true; shift ;;
        --help)
            head -n 15 "$0" | tail -n +2 | sed 's/^# \?//'
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

log_step "Checking ZFSBootMenu kernel detection"

log_info "Pool: $POOL_NAME"
log_info "Dataset: $POOL_NAME/$ROOT_DATASET"

# Check if dataset exists
if ! zfs list "$POOL_NAME/$ROOT_DATASET" &>/dev/null; then
    log_error "Dataset $POOL_NAME/$ROOT_DATASET not found!"
    exit 1
fi

# Mount dataset temporarily
MOUNT_POINT=$(mktemp -d)
log_info "Mounting dataset to $MOUNT_POINT..."
zfs set mountpoint="$MOUNT_POINT" "$POOL_NAME/$ROOT_DATASET"
zfs mount "$POOL_NAME/$ROOT_DATASET"

# Check for kernels
log_step "Checking for kernel files"

KERNEL_COUNT=$(find "$MOUNT_POINT/boot" -name "vmlinuz-*" 2>/dev/null | wc -l)
INITRD_COUNT=$(find "$MOUNT_POINT/boot" -name "initrd.img-*" 2>/dev/null | wc -l)

log_info "Found $KERNEL_COUNT kernel(s) and $INITRD_COUNT initrd(s)"

if [ "$KERNEL_COUNT" -eq 0 ] || [ "$INITRD_COUNT" -eq 0 ]; then
    log_error "No kernels or initrds found!"
    log_info "Files in /boot:"
    ls -la "$MOUNT_POINT/boot/" 2>/dev/null || log_warn "/boot directory empty or missing"
    
    if [ "$FIX_MODE" = true ]; then
        log_step "Attempting to fix..."
        
        # Check if we can reinstall kernel
        log_info "Checking if we can access apt..."
        if command -v apt &>/dev/null; then
            log_info "Reinstalling kernel..."
            apt update
            apt install --reinstall -y linux-image-amd64
            
            # Regenerate initramfs
            log_info "Regenerating initramfs..."
            update-initramfs -c -k all
            
            KERNEL_COUNT=$(find "$MOUNT_POINT/boot" -name "vmlinuz-*" 2>/dev/null | wc -l)
            INITRD_COUNT=$(find "$MOUNT_POINT/boot" -name "initrd.img-*" 2>/dev/null | wc -l)
            
            if [ "$KERNEL_COUNT" -gt 0 ] && [ "$INITRD_COUNT" -gt 0 ]; then
                log_info "Fix successful!"
            else
                log_error "Fix failed!"
            fi
        else
            log_error "Cannot access apt in this environment"
            log_info "You may need to chroot into the system and reinstall kernel"
        fi
    else
        log_warn "Run with --fix to attempt automatic repair"
    fi
else
    log_info "Kernels detected ✓"
    
    # List found kernels
    log_info "Kernels:"
    find "$MOUNT_POINT/boot" -name "vmlinuz-*" -exec ls -lh {} \;
    
    log_info "Initrds:"
    find "$MOUNT_POINT/boot" -name "initrd.img-*" -exec ls -lh {} \;
    
    # Check ZFSBootMenu properties
    log_step "Checking ZFSBootMenu properties"
    
    cmdline=$(zfs get -H -o value org.zfsbootmenu:commandline "$POOL_NAME/$ROOT_DATASET" 2>/dev/null || echo "not set")
    log_info "org.zfsbootmenu:commandline: $cmdline"
    
    if [ "$cmdline" = "-" ] || [ "$cmdline" = "not set" ]; then
        log_warn "commandline property not set!"
        log_info "Setting default commandline..."
        zfs set org.zfsbootmenu:commandline="quiet loglevel=0" "$POOL_NAME/$ROOT_DATASET"
    fi
fi

# Unmount
log_info "Unmounting dataset..."
zfs unmount "$POOL_NAME/$ROOT_DATASET"
zfs set mountpoint="/" "$POOL_NAME/$ROOT_DATASET"
rmdir "$MOUNT_POINT"

log_step "Check completed"
