#!/bin/bash
###############################################################################
# fix-boot.sh — Fix "no boot environments found" after installation
#
# Run this from live ISO if ZFSBootMenu shows no boot environments.
#
# Usage:
#   sudo bash fix-boot.sh [OPTIONS]
#
# Options:
#   --pool NAME         ZFS pool name (default: zroot)
#   --dataset NAME      ROOT dataset (default: ROOT/trixie)
#   --efi-disk DEV      Disk containing EFI partition (e.g. /dev/sda)
#   --efi-part NUM      EFI partition number (e.g. 1)
#   --dry-run           Show commands without executing
#   --help              Show this help
#
# Examples:
#   sudo bash fix-boot.sh
#   sudo bash fix-boot.sh --pool zroot --dataset ROOT/trixie
#   sudo bash fix-boot.sh --efi-disk /dev/nvme0n1 --efi-part 1
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BLUE}[STEP]${NC}  $1"; }

POOL_NAME="zroot"
ROOT_DATASET="ROOT/trixie"
EFI_DISK=""
EFI_PART=""
DRY_RUN=false
MOUNT_POINT="/mnt/fix-boot"

while [[ $# -gt 0 ]]; do
    case $1 in
        --pool)      POOL_NAME="$2";    shift 2 ;;
        --dataset)   ROOT_DATASET="$2"; shift 2 ;;
        --efi-disk)  EFI_DISK="$2";     shift 2 ;;
        --efi-part)  EFI_PART="$2";     shift 2 ;;
        --dry-run)   DRY_RUN=true;      shift   ;;
        --help)
            head -n 20 "$0" | tail -n +2 | sed 's/^# \?//'
            exit 0
            ;;
        *) log_error "Unknown parameter: $1"; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    log_error "Run as root (sudo)"
    exit 1
fi

run() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

DATASET="${POOL_NAME}/${ROOT_DATASET}"
MOUNTED=false
CHROOT_MOUNTS=false

cleanup() {
    if [ "$CHROOT_MOUNTS" = true ]; then
        umount -lf "$MOUNT_POINT/dev/pts" 2>/dev/null || true
        umount -lf "$MOUNT_POINT/dev"     2>/dev/null || true
        umount -lf "$MOUNT_POINT/proc"    2>/dev/null || true
        umount -lf "$MOUNT_POINT/sys"     2>/dev/null || true
    fi
    if [ -d "$MOUNT_POINT/boot/efi" ]; then
        umount -lf "$MOUNT_POINT/boot/efi" 2>/dev/null || true
    fi
    if [ "$MOUNTED" = true ]; then
        zfs unmount -r "$POOL_NAME" 2>/dev/null || true
        zpool export "$POOL_NAME"   2>/dev/null || true
    fi
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

###############################################################################
# Step 1: Import pool
###############################################################################
log_step "Importing ZFS pool"

if zpool list "$POOL_NAME" &>/dev/null; then
    log_info "Pool $POOL_NAME already imported"
else
    run zpool import -N -R "$MOUNT_POINT" "$POOL_NAME" || {
        log_error "Cannot import pool $POOL_NAME"
        log_info "Try: zpool import -f -N -R /mnt $POOL_NAME"
        exit 1
    }
fi

###############################################################################
# Step 2: Mount root dataset
###############################################################################
log_step "Mounting root dataset"

run mkdir -p "$MOUNT_POINT"

if [ "$(zfs get -H -o value mounted "$DATASET" 2>/dev/null)" = "yes" ]; then
    EXISTING_MP=$(findmnt -n -o TARGET -S "$DATASET" 2>/dev/null || echo "")
    if [ -n "$EXISTING_MP" ]; then
        log_info "Dataset already mounted at $EXISTING_MP, using that"
        MOUNT_POINT="$EXISTING_MP"
    fi
else
    run zpool import -N -R "$MOUNT_POINT" "$POOL_NAME" 2>/dev/null || true
    run zfs mount "$DATASET"
    MOUNTED=true
fi

###############################################################################
# Step 3: Fix BE properties
###############################################################################
log_step "Fixing boot environment properties"

run zpool set bootfs="$DATASET" "$POOL_NAME"
run zfs set mountpoint=/ "$DATASET"
run zfs set canmount=noauto "$DATASET"
run zfs set org.zfsbootmenu:commandline="quiet loglevel=0" "$DATASET"

log_info "BE properties:"
zpool get bootfs "$POOL_NAME"
zfs get mountpoint,canmount,org.zfsbootmenu:commandline "$DATASET"

###############################################################################
# Step 4: Check kernel/initrd
###############################################################################
log_step "Checking kernel and initramfs"

KERNEL_COUNT=$(find "$MOUNT_POINT/boot" -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | wc -l)
INITRD_COUNT=$(find  "$MOUNT_POINT/boot" -maxdepth 1 -name 'initrd.img-*' 2>/dev/null | wc -l)

log_info "Kernels: $KERNEL_COUNT  Initrds: $INITRD_COUNT"

if [ "$KERNEL_COUNT" -eq 0 ] || [ "$INITRD_COUNT" -eq 0 ]; then
    log_warn "Missing kernel/initrd — reinstalling in chroot"

    run mount --rbind /dev  "$MOUNT_POINT/dev"
    run mount --rbind /proc "$MOUNT_POINT/proc"
    run mount --rbind /sys  "$MOUNT_POINT/sys"
    CHROOT_MOUNTS=true

    run chroot "$MOUNT_POINT" /bin/bash -lc \
        'apt update && apt remove -y libzfs6linux libuutil3linux libnvpair3linux libzpool6linux 2>/dev/null || true; apt install -y -t trixie-backports zfsutils-linux zfs-initramfs zfs-dkms && apt install -y --reinstall linux-image-amd64 && update-initramfs -c -k all'

    KERNEL_COUNT=$(find "$MOUNT_POINT/boot" -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | wc -l)
    INITRD_COUNT=$(find  "$MOUNT_POINT/boot" -maxdepth 1 -name 'initrd.img-*' 2>/dev/null | wc -l)
    log_info "After repair — kernels: $KERNEL_COUNT  initrds: $INITRD_COUNT"

    if [ "$KERNEL_COUNT" -eq 0 ] || [ "$INITRD_COUNT" -eq 0 ]; then
        log_error "Kernel/initrd still missing after repair"
        exit 1
    fi
else
    log_info "Kernels OK:"
    find "$MOUNT_POINT/boot" -maxdepth 1 -name 'vmlinuz-*' -exec ls -lh {} \;
fi

###############################################################################
# Step 5: Detect EFI partition if not specified
###############################################################################
log_step "Detecting EFI partition"

if [ -z "$EFI_DISK" ] || [ -z "$EFI_PART" ]; then
    log_info "Auto-detecting EFI partition..."
    EFI_DEVICE=$(fdisk -l 2>/dev/null | awk '/EFI/{print $1}' | head -1 || true)
    if [ -z "$EFI_DEVICE" ]; then
        EFI_DEVICE=$(lsblk -lno NAME,PARTTYPE 2>/dev/null | \
            awk 'tolower($2)~/c12a7328-f81f-11d2-ba4b-00a0c93ec93b/{print "/dev/"$1}' | head -1 || true)
    fi

    if [ -n "$EFI_DEVICE" ]; then
        EFI_DISK=$(lsblk -no PKNAME "$EFI_DEVICE" 2>/dev/null | head -1 || true)
        EFI_PART=$(lsblk -no PARTN  "$EFI_DEVICE" 2>/dev/null | head -1 || true)
        EFI_DISK="/dev/${EFI_DISK}"
        log_info "Auto-detected EFI: disk=$EFI_DISK part=$EFI_PART device=$EFI_DEVICE"
    else
        log_warn "Could not auto-detect EFI partition"
        log_warn "Pass --efi-disk /dev/sdX --efi-part N to fix EFI entries"
    fi
else
    EFI_DEVICE="${EFI_DISK}${EFI_PART}"
    # Handle NVMe/mdadm naming
    if [[ "$EFI_DISK" == *nvme* ]] || [[ "$EFI_DISK" == *mmcblk* ]] || \
       [[ "$EFI_DISK" == *md* ]]   || [[ "$EFI_DISK" == *dm-* ]]; then
        EFI_DEVICE="${EFI_DISK}p${EFI_PART}"
    fi
fi

###############################################################################
# Step 6: Mount EFI and fix ZBM binary / fallback path
###############################################################################
log_step "Fixing EFI boot files"

if [ -n "$EFI_DEVICE" ] && [ -b "$EFI_DEVICE" ]; then
    run mkdir -p "$MOUNT_POINT/boot/efi"

    if ! mount | grep -q "$MOUNT_POINT/boot/efi"; then
        run mount -t vfat "$EFI_DEVICE" "$MOUNT_POINT/boot/efi" || {
            log_warn "Failed to mount EFI partition $EFI_DEVICE"
        }
    fi

    ZBM_EFI="$MOUNT_POINT/boot/efi/EFI/ZBM/VMLINUZ.EFI"
    FALLBACK="$MOUNT_POINT/boot/efi/EFI/BOOT/BOOTX64.EFI"

    # Download ZBM if missing
    if [ ! -f "$ZBM_EFI" ]; then
        log_warn "ZFSBootMenu EFI binary missing — downloading"
        run mkdir -p "$MOUNT_POINT/boot/efi/EFI/ZBM"
        run curl -fSL --connect-timeout 15 -m 300 \
            -o "$ZBM_EFI" "https://get.zfsbootmenu.org/efi" || {
            log_error "Download failed — check internet and retry"
            exit 1
        }
    else
        log_info "ZFSBootMenu EFI binary present: $(ls -lh "$ZBM_EFI")"
    fi

    # Ensure fallback path
    run mkdir -p "$MOUNT_POINT/boot/efi/EFI/BOOT"
    run cp "$ZBM_EFI" "$FALLBACK"
    log_info "Fallback EFI: $FALLBACK"

    # Create backup copy
    run cp "$ZBM_EFI" "$MOUNT_POINT/boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI"

    # Fix NVRAM entries
    if [ -n "$EFI_DISK" ] && [ -n "$EFI_PART" ]; then
        # Mount efivarfs if needed
        if ! mount | grep -q efivarfs; then
            mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
        fi

        if command -v efibootmgr &>/dev/null; then
            # Remove stale ZFSBootMenu entries
            efibootmgr | grep -i "ZFSBootMenu" | sed 's/^Boot//' | sed 's/\*.*//' | \
                awk '{print $1}' | while read -r num; do
                    [ -n "$num" ] && efibootmgr -B -b "$num" 2>/dev/null || true
                done

            run efibootmgr -c -d "$EFI_DISK" -p "$EFI_PART" \
                -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI' || \
                log_warn "Failed to create NVRAM entry (may need manual setup)"

            run efibootmgr -c -d "$EFI_DISK" -p "$EFI_PART" \
                -L "ZFSBootMenu (Backup)" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI' || true

            log_info "EFI boot entries:"
            efibootmgr -v
        else
            log_warn "efibootmgr not found — NVRAM entries not updated"
        fi
    fi
else
    log_warn "EFI device not found or not a block device"
    log_warn "Skipping EFI binary and NVRAM fixes"
    log_warn "Retry with: --efi-disk /dev/sdX --efi-part N"
fi

###############################################################################
# Summary
###############################################################################
log_step "Fix complete"
log_info ""
log_info "Pool bootfs:   $(zpool get -H -o value bootfs "$POOL_NAME" 2>/dev/null)"
log_info "mountpoint:    $(zfs get -H -o value mountpoint "$DATASET" 2>/dev/null)"
log_info "canmount:      $(zfs get -H -o value canmount "$DATASET" 2>/dev/null)"
log_info "cmdline:       $(zfs get -H -o value org.zfsbootmenu:commandline "$DATASET" 2>/dev/null)"
log_info "Kernels found: $KERNEL_COUNT"
log_warn ""
log_warn "Now run: zpool export $POOL_NAME && reboot"
log_warn "Select 'ZFSBootMenu' or 'UEFI OS' in firmware boot menu"
log_warn "If Secure Boot enabled — disable it (ZBM EFI not signed)"
