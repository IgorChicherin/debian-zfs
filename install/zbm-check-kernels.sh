#!/bin/bash
###############################################################################
# zbm-check-kernels.sh — Check and fix ZFSBootMenu kernel detection
#
# Usage:
#   sudo bash zbm-check-kernels.sh [OPTIONS]
#
# Options:
#   --pool NAME         ZFS pool name (default: zroot)
#   --dataset NAME      ROOT dataset (default: ROOT/trixie)
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
ROOT_DATASET="ROOT/trixie"
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

# Save original dataset properties/state
ORIG_MOUNTPOINT=$(zfs get -H -o value mountpoint "$POOL_NAME/$ROOT_DATASET")
ORIG_CANMOUNT=$(zfs get -H -o value canmount "$POOL_NAME/$ROOT_DATASET")
ORIG_MOUNTED=$(zfs get -H -o value mounted "$POOL_NAME/$ROOT_DATASET")

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
        
        # Reinstall kernel inside target root (not live environment)
        if [ -f "$MOUNT_POINT/etc/debian_version" ]; then
            log_info "Reinstalling kernel inside target root..."
            mount --bind /dev "$MOUNT_POINT/dev"
            mount --bind /proc "$MOUNT_POINT/proc"
            mount --bind /sys "$MOUNT_POINT/sys"

            chroot "$MOUNT_POINT" /bin/bash -lc 'apt update && apt install --reinstall -y linux-image-amd64 zfs-initramfs zfsutils-linux && update-initramfs -c -k all' || true

            umount "$MOUNT_POINT/sys" 2>/dev/null || true
            umount "$MOUNT_POINT/proc" 2>/dev/null || true
            umount "$MOUNT_POINT/dev" 2>/dev/null || true
            
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
    
    bootfs=$(zpool get -H -o value bootfs "$POOL_NAME" 2>/dev/null || echo "-")
    mountpoint=$(zfs get -H -o value mountpoint "$POOL_NAME/$ROOT_DATASET" 2>/dev/null || echo "-")
    canmount=$(zfs get -H -o value canmount "$POOL_NAME/$ROOT_DATASET" 2>/dev/null || echo "-")
    cmdline=$(zfs get -H -o value org.zfsbootmenu:commandline "$POOL_NAME/$ROOT_DATASET" 2>/dev/null || echo "not set")

    log_info "bootfs: $bootfs"
    log_info "mountpoint: $mountpoint"
    log_info "canmount: $canmount"
    log_info "org.zfsbootmenu:commandline: $cmdline"

    if [ "$bootfs" != "$POOL_NAME/$ROOT_DATASET" ]; then
        log_warn "bootfs points to $bootfs, fixing..."
        zpool set bootfs="$POOL_NAME/$ROOT_DATASET" "$POOL_NAME"
    fi

    if [ "$mountpoint" != "/" ]; then
        log_warn "mountpoint is $mountpoint, fixing to /..."
        zfs set mountpoint=/ "$POOL_NAME/$ROOT_DATASET"
    fi

    if [ "$canmount" != "noauto" ]; then
        log_warn "canmount is $canmount, fixing to noauto..."
        zfs set canmount=noauto "$POOL_NAME/$ROOT_DATASET"
    fi
    
    if [ "$cmdline" = "-" ] || [ "$cmdline" = "not set" ]; then
        log_warn "commandline property not set!"
        log_info "Setting default commandline..."
        zfs set org.zfsbootmenu:commandline="quiet loglevel=0" "$POOL_NAME/$ROOT_DATASET"
    fi
fi

# Unmount/restore dataset properties
log_info "Unmounting dataset..."
if [ "$ORIG_MOUNTED" != "yes" ]; then
    zfs unmount "$POOL_NAME/$ROOT_DATASET" 2>/dev/null || true
fi
zfs set mountpoint="$ORIG_MOUNTPOINT" "$POOL_NAME/$ROOT_DATASET"
zfs set canmount="$ORIG_CANMOUNT" "$POOL_NAME/$ROOT_DATASET"
rmdir "$MOUNT_POINT"

log_step "Check completed"
