#!/bin/bash
###############################################################################
# zfs-install.sh — Automated Debian Trixie installation on ZFS root
#
# Usage:
#   sudo bash zfs-install.sh --disk /dev/sda [OPTIONS]
#   sudo bash zfs-install.sh --use-existing-pool
#   sudo bash zfs-install.sh --interactive
#
# Installation Modes:
#   1. Fresh installation on disk:
#      --disk DISK         Installation disk (required)
#   
#   2. Use existing ZFS pool + EFI:
#      --use-existing-pool  Interactive selection of existing pool and EFI
#      --pool POOL_NAME     Use specific ZFS pool
#      --efi-device DEV     Use specific EFI partition
#   
#   3. Interactive mode (wizard):
#      --interactive        Guide through all options step-by-step
#
# Common Options:
#   --use-free-space    Install alongside Windows using existing free GPT space
#   --efi-part NUM      Reuse existing EFI partition number (auto-detect by default)
#   --encrypt           Enable ZFS native encryption
#   --passphrase PHRASE Encryption passphrase (if not specified, will prompt)
#   --hostname NAME     Hostname (default: debian-zfs)
#   --password PASS     Root password (default: root, CHANGE after installation!)
#   --pool-name NAME    ZFS pool name (default: zroot)
#   --dry-run           Show commands without executing
#   --help              Show this help
#
# Examples:
#   # Fresh install on single disk
#   sudo bash zfs-install.sh --disk /dev/sda
#
#   # Fresh install on Intel RST RAID 0 (2x NVMe)
#   sudo bash zfs-install.sh --disk /dev/md127
#
#   # Use existing ZFS pool interactively
#   sudo bash zfs-install.sh --use-existing-pool
#
#   # Use specific existing pool and EFI
#   sudo bash zfs-install.sh --pool zroot --efi-device /dev/sda1
#
#   # Interactive wizard (recommended for beginners)
#   sudo bash zfs-install.sh --interactive
#
#   # With encryption
#   sudo bash zfs-install.sh --disk /dev/sda --encrypt --passphrase "MySecurePass"
#
#   # Install next to Windows
#   sudo bash zfs-install.sh --disk /dev/nvme0n1 --use-free-space
###############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_step() {
    echo -e "\n${BLUE}[STEP]${NC} $1"
}

###############################################################################
# RAID Detection and Validation Functions
###############################################################################

detect_raid_array() {
    local disk="$1"
    
    # Check if it's a software RAID device (mdadm)
    if [[ "$disk" == /dev/md* ]]; then
        log_info "Detected mdadm RAID array: $disk"
        cat "$disk" 2>/dev/null || true
        return 0
    fi
    
    # Check if it's a device mapper device (Intel RST RAID)
    if [[ "$disk" == /dev/dm-* ]] || [[ "$disk" == /dev/mapper/* ]]; then
        log_info "Detected device-mapper (Intel RST RAID) device: $disk"
        return 0
    fi
    
    # Check if underlying devices are in a RAID array
    if command -v mdadm &> /dev/null; then
        local md_arrays
        md_arrays=$(mdadm --detail --scan 2>/dev/null | grep -c ARRAY || true)
        if [ "$md_arrays" -gt 0 ]; then
            log_warn "Active mdadm RAID arrays detected on system"
            mdadm --detail --scan 2>/dev/null || true
        fi
    fi
}

validate_disk_for_installation() {
    local disk="$1"
    
    # Check if disk is already part of a ZFS pool
    if command -v zpool &> /dev/null; then
        if zpool status "$disk" &>/dev/null 2>&1; then
            log_error "Disk $disk is already part of a ZFS pool!"
            log_info "Run 'zpool status' to see pool information"
            return 1
        fi
    fi
    
    # Check if disk is part of mdadm RAID array (if using non-RAID disk)
    if [[ "$disk" != /dev/md* && "$disk" != /dev/dm-* && "$disk" != /dev/mapper/* ]]; then
        if command -v mdadm &> /dev/null; then
            local is_in_raid
            is_in_raid=$(mdadm --examine "$disk" 2>/dev/null | grep -c "MD Bitmap" || echo 0)
            if [ "$is_in_raid" -gt 0 ]; then
                log_error "Disk $disk appears to be part of an mdadm RAID array!"
                log_warn "This would destroy your RAID array!"
                log_info "If you want to install on a RAID array, use the RAID device:"
                mdadm --detail --scan 2>/dev/null || true
                return 1
            fi
        fi
    fi
    
    return 0
}

show_raid_info() {
    log_info ""
    log_info "RAID/Device Configuration:"
    log_info "  Current disk: $DISK"
    
    if [[ "$DISK" == /dev/md* ]]; then
        log_info "  Type: mdadm software RAID"
        if command -v mdadm &> /dev/null; then
            log_info "  Details:"
            mdadm --detail "$DISK" 2>/dev/null | sed 's/^/    /'
        fi
    elif [[ "$DISK" == /dev/dm-* || "$DISK" == /dev/mapper/* ]]; then
        log_info "  Type: Device Mapper (Intel RST RAID or LVM)"
        if command -v dmsetup &> /dev/null; then
            log_info "  Details:"
            dmsetup info "$DISK" 2>/dev/null | sed 's/^/    /'
        fi
    else
        log_info "  Type: Direct attached disk (NVMe, SATA, etc.)"
    fi
    log_info ""
}

###############################################################################
# Existing Pool/EFI Selection Functions
###############################################################################

list_zfs_pools() {
    log_info "Available ZFS pools:"
    if ! zpool list -H -o name 2>/dev/null; then
        log_error "No ZFS pools found!"
        return 1
    fi
}

select_zfs_pool() {
    log_step "Select ZFS Pool"
    
    local pools
    pools=$(zpool list -H -o name 2>/dev/null || true)
    
    if [ -z "$pools" ]; then
        log_error "No ZFS pools available!"
        log_info "Create a pool first: zpool create -f poolname /dev/xxx"
        return 1
    fi
    
    echo ""
    log_info "Available pools:"
    local count=0
    declare -a pool_array
    while IFS= read -r pool; do
        ((count++))
        pool_array[$count]="$pool"
        log_info "  $count) $pool"
    done <<< "$pools"
    
    echo ""
    read -p "Select pool (1-$count): " pool_choice
    
    if [ -z "$pool_choice" ] || [ "$pool_choice" -lt 1 ] || [ "$pool_choice" -gt $count ]; then
        log_error "Invalid selection"
        return 1
    fi
    
    POOL_NAME="${pool_array[$pool_choice]}"
    log_info "Selected pool: $POOL_NAME"
}

select_efi_partition() {
    log_step "Select EFI System Partition"
    
    log_info "Available EFI partitions:"
    local count=0
    declare -a efi_array
    
    # Find EFI partitions
    while IFS= read -r part; do
        ((count++))
        efi_array[$count]="$part"
        local size
        size=$(lsblk -dn -o SIZE "$part" 2>/dev/null || echo "unknown")
        log_info "  $count) $part ($size)"
    done < <(sudo fdisk -l 2>/dev/null | grep "EFI" | awk '{print $1}' || true)
    
    if [ "$count" -eq 0 ]; then
        log_warn "No EFI partitions found automatically"
        log_info "Enter EFI partition path manually (e.g., /dev/sda1):"
        read -p "EFI partition: " EFI_DEVICE
        
        if [ ! -b "$EFI_DEVICE" ]; then
            log_error "Invalid EFI partition: $EFI_DEVICE"
            return 1
        fi
    else
        echo ""
        read -p "Select EFI partition (1-$count, or 'c' for custom): " efi_choice
        
        if [ "$efi_choice" = "c" ]; then
            log_info "Enter EFI partition path manually (e.g., /dev/sda1):"
            read -p "EFI partition: " EFI_DEVICE
            
            if [ ! -b "$EFI_DEVICE" ]; then
                log_error "Invalid EFI partition: $EFI_DEVICE"
                return 1
            fi
        elif [ -z "$efi_choice" ] || [ "$efi_choice" -lt 1 ] || [ "$efi_choice" -gt $count ]; then
            log_error "Invalid selection"
            return 1
        else
            EFI_DEVICE="${efi_array[$efi_choice]}"
        fi
    fi
    
    log_info "Selected EFI partition: $EFI_DEVICE"
}

interactive_mode_setup() {
    log_step "Debian ZFS Installation - Interactive Wizard"
    
    echo ""
    log_info "This wizard will guide you through the installation process."
    
    # Step 1: Choose installation mode
    log_step "Step 1: Installation Mode"
    log_info "How do you want to install?"
    log_info "  1) Fresh install on a disk"
    log_info "  2) Use existing ZFS pool"
    
    read -p "Choose (1 or 2): " mode_choice
    
    if [ "$mode_choice" = "2" ]; then
        MODE="existing"
        USE_EXISTING_POOL=true
    else
        MODE="disk"
    fi
    
    # Step 2: Get hostname
    log_step "Step 2: Hostname"
    read -p "Hostname [debian-zfs]: " user_hostname
    HOSTNAME="${user_hostname:-debian-zfs}"
    
    # Step 3: Get root password
    log_step "Step 3: Root Password"
    read -s -p "Root password [root]: " user_password
    ROOT_PASSWORD="${user_password:-root}"
    echo ""
    
    # Step 4: Encryption
    log_step "Step 4: ZFS Encryption"
    read -p "Enable ZFS encryption? (y/n) [n]: " use_encrypt
    if [ "$use_encrypt" = "y" ]; then
        ENCRYPT=true
        read -s -p "Encryption passphrase: " PASSPHRASE
        echo ""
    fi
    
    # Step 5: Disk/Pool selection
    if [ "$MODE" = "disk" ]; then
        log_step "Step 5: Select Disk"
        log_info "Available disks:"
        lsblk -dn -o NAME,SIZE,TYPE
        echo ""
        read -p "Disk path (e.g., /dev/sda, /dev/nvme0n1): " DISK
        
        if [ ! -b "$DISK" ]; then
            log_error "Invalid disk: $DISK"
            return 1
        fi
    else
        log_step "Step 5: Select ZFS Pool and EFI"
        if ! select_zfs_pool; then
            return 1
        fi
        if ! select_efi_partition; then
            return 1
        fi
    fi
    
    # Summary
    log_step "Summary"
    echo ""
    log_info "Configuration:"
    log_info "  Mode: $MODE"
    log_info "  Hostname: $HOSTNAME"
    log_info "  Encryption: $ENCRYPT"
    if [ "$MODE" = "disk" ]; then
        log_info "  Disk: $DISK"
    else
        log_info "  Pool: $POOL_NAME"
        log_info "  EFI: $EFI_DEVICE"
    fi
    echo ""
    
    read -p "Proceed with installation? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Installation cancelled"
        exit 0
    fi
}

# Default parameters
DISK=""
ENCRYPT=false
PASSPHRASE=""
HOSTNAME="debian-zfs"
ROOT_PASSWORD="root"
POOL_NAME="zroot"
DRY_RUN=false
USE_FREE_SPACE=false
BOOT_PART=1
POOL_PART=2
BOOT_SIZE="+1G"
EFI_PART=""
EFI_DEVICE=""
MIN_FREE_SPACE_GIB=20
MIN_EFI_SIZE_MIB=1024
REUSE_EXISTING_EFI=false

# Installation modes
MODE="disk"  # disk, existing, or interactive
USE_EXISTING_POOL=false
INTERACTIVE_MODE=false

# Help function
show_help() {
    head -n 35 "$0" | tail -n +2 | sed 's/^# \?//'
    exit 0
}

# Argument parsing
while [[ $# -gt 0 ]]; do
    case $1 in
        --disk)
            DISK="$2"
            MODE="disk"
            shift 2
            ;;
        --use-existing-pool)
            USE_EXISTING_POOL=true
            MODE="existing"
            shift
            ;;
        --pool)
            POOL_NAME="$2"
            MODE="existing"
            shift 2
            ;;
        --efi-device)
            EFI_DEVICE="$2"
            shift 2
            ;;
        --interactive)
            INTERACTIVE_MODE=true
            MODE="interactive"
            shift
            ;;
        --encrypt)
            ENCRYPT=true
            shift
            ;;
        --use-free-space)
            USE_FREE_SPACE=true
            shift
            ;;
        --efi-part)
            EFI_PART="$2"
            shift 2
            ;;
        --passphrase)
            PASSPHRASE="$2"
            shift 2
            ;;
        --hostname)
            HOSTNAME="$2"
            shift 2
            ;;
        --password)
            ROOT_PASSWORD="$2"
            shift 2
            ;;
        --pool-name)
            POOL_NAME="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help)
            show_help
            ;;
        *)
            log_error "Unknown parameter: $1"
            show_help
            ;;
    esac
done

# Check required parameters based on mode
# Interactive mode handles parameter collection
if [ "$INTERACTIVE_MODE" = true ]; then
    interactive_mode_setup
fi

# Mode validation
if [ "$MODE" = "disk" ] && [ -z "$DISK" ]; then
    log_error "Parameter --disk is required for disk mode!"
    log_info "Or use --use-existing-pool, --pool, or --interactive"
    show_help
fi

if [ "$MODE" = "existing" ]; then
    if [ "$USE_EXISTING_POOL" = true ] && [ -z "$POOL_NAME" ] && [ -z "$EFI_DEVICE" ]; then
        log_info "Interactive pool/EFI selection mode"
        if ! select_zfs_pool; then
            exit 1
        fi
        if ! select_efi_partition; then
            exit 1
        fi
    elif [ -z "$POOL_NAME" ] || [ -z "$EFI_DEVICE" ]; then
        log_error "Existing pool mode requires --pool and --efi-device!"
        log_info "Example: --pool zroot --efi-device /dev/sda1"
        show_help
    fi
fi

# Check root privileges
if [ "$(id -u)" -ne 0 ]; then
    log_error "Run this script as root (sudo)"
    exit 1
fi

# Validate disk/pool exists (only for disk mode)
if [ "$MODE" = "disk" ]; then
    if [ ! -b "$DISK" ]; then
        log_error "Disk $DISK not found!"
        log_info "Available disks:"
        lsblk -dn -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || fdisk -l 2>/dev/null | grep "Disk /dev"
        exit 1
    fi

    # Detect and validate RAID configuration
    log_info "Detecting RAID/device configuration..."
    detect_raid_array "$DISK"

    # Validate disk is safe to use
    if ! validate_disk_for_installation "$DISK"; then
        exit 1
    fi
fi

# Validate existing pool/EFI (for existing mode)
if [ "$MODE" = "existing" ]; then
    if ! zpool list "$POOL_NAME" &>/dev/null; then
        log_error "ZFS pool $POOL_NAME not found!"
        log_info "Available pools:"
        zpool list
        exit 1
    fi
    
    if [ ! -b "$EFI_DEVICE" ]; then
        log_error "EFI device $EFI_DEVICE not found!"
        exit 1
    fi
    
    log_info "Validating existing pool and EFI..."
    log_info "  Pool: $POOL_NAME"
    log_info "  EFI: $EFI_DEVICE"
fi

# Variables
MOUNT_POINT="/mnt"
DEBIAN_RELEASE="trixie"

BOOT_DEVICE=""
POOL_DEVICE=""
POOL_DATASET=""

###############################################################################
# Functions
###############################################################################

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

partition_device() {
    local disk="$1"
    local part="$2"

    # Support for mdadm RAID devices
    if [[ "$disk" == /dev/md* ]]; then
        echo "${disk}p${part}"
        return 0
    fi
    
    # Support for device mapper (Intel RST, LVM, etc.)
    if [[ "$disk" == /dev/dm-* ]] || [[ "$disk" == /dev/mapper/* ]]; then
        echo "${disk}p${part}"
        return 0
    fi

    # Original logic for standard disks
    if [[ "$disk" == *nvme* ]] || [[ "$disk" == *mmcblk* ]]; then
        echo "${disk}p${part}"
    else
        echo "${disk}${part}"
    fi
}

require_gpt_disk() {
    if ! sgdisk -p "$DISK" >/tmp/sgdisk-layout.$$ 2>&1; then
        cat /tmp/sgdisk-layout.$$ >&2 || true
        rm -f /tmp/sgdisk-layout.$$
        log_error "Failed to read partition table from $DISK"
        exit 1
    fi

    if ! grep -q "GPT" /tmp/sgdisk-layout.$$; then
        rm -f /tmp/sgdisk-layout.$$
        log_error "$DISK must use GPT for --use-free-space mode"
        exit 1
    fi

    rm -f /tmp/sgdisk-layout.$$
}

find_existing_efi_part() {
    sgdisk -p "$DISK" | awk '$1 ~ /^[0-9]+$/ && toupper($6) == "EF00" {print $1; exit}'
}

next_partition_number() {
    sgdisk -p "$DISK" | awk '$1 ~ /^[0-9]+$/ {last=$1} END {print (last ? last + 1 : 1)}'
}

check_partition_type() {
    local part="$1"
    local expected="$2"
    local actual
    actual=$(sgdisk -i "$part" "$DISK" 2>/dev/null | awk -F': ' '/Partition GUID code/ {print toupper(substr($2, 1, 4)); exit}')
    [ "$actual" = "$expected" ]
}

partition_size_mib() {
    local part_device="$1"
    local size_bytes
    size_bytes=$(lsblk -bno SIZE "$part_device" 2>/dev/null || echo 0)
    echo $((size_bytes / 1024 / 1024))
}

resolve_install_layout() {
    if [ "$USE_FREE_SPACE" = true ]; then
        require_gpt_disk

        local free_start free_end free_sectors free_bytes free_gib required_bytes
        local sector_size
        sector_size=$(blockdev --getss "$DISK")
        free_start=$(sgdisk -F "$DISK" 2>/dev/null || true)
        free_end=$(sgdisk -E "$DISK" 2>/dev/null || true)

        if [[ -z "$free_start" || -z "$free_end" || "$free_start" = "0" || "$free_end" = "0" ]]; then
            log_error "No free GPT space found on $DISK"
            log_info "Shrink the Windows partition first to create unallocated space"
            exit 1
        fi

        if [ "$free_end" -lt "$free_start" ]; then
            log_error "Invalid free-space range detected on $DISK"
            exit 1
        fi

        free_sectors=$((free_end - free_start + 1))
        free_bytes=$((free_sectors * sector_size))
        free_gib=$((free_bytes / 1024 / 1024 / 1024))

        if [ -n "$EFI_PART" ]; then
            REUSE_EXISTING_EFI=true
            BOOT_PART="$EFI_PART"

            if ! check_partition_type "$BOOT_PART" "EF00"; then
                log_error "Partition $BOOT_PART on $DISK is not an EFI System Partition"
                exit 1
            fi

            BOOT_DEVICE=$(partition_device "$DISK" "$BOOT_PART")
            local efi_size_mib
            efi_size_mib=$(partition_size_mib "$BOOT_DEVICE")
            if [ "$efi_size_mib" -lt "$MIN_EFI_SIZE_MIB" ]; then
                log_error "EFI partition $BOOT_DEVICE is ${efi_size_mib} MiB (< ${MIN_EFI_SIZE_MIB} MiB required)"
                log_info "Do not pass --efi-part to create dedicated EFI in free space"
                exit 1
            fi

            POOL_PART=$(next_partition_number)
            POOL_DEVICE=$(partition_device "$DISK" "$POOL_PART")
        else
            REUSE_EXISTING_EFI=false
            BOOT_PART=$(next_partition_number)
            POOL_PART=$((BOOT_PART + 1))
            BOOT_DEVICE=$(partition_device "$DISK" "$BOOT_PART")
            POOL_DEVICE=$(partition_device "$DISK" "$POOL_PART")

            required_bytes=$((MIN_FREE_SPACE_GIB * 1024 * 1024 * 1024 + MIN_EFI_SIZE_MIB * 1024 * 1024))
            if [ "$free_bytes" -lt "$required_bytes" ]; then
                log_error "Not enough free space for dedicated EFI + ZFS root"
                log_info "Need at least ${MIN_FREE_SPACE_GIB} GiB + ${MIN_EFI_SIZE_MIB} MiB EFI"
                exit 1
            fi
        fi

        if [ "$free_gib" -lt "$MIN_FREE_SPACE_GIB" ]; then
            log_error "Only ${free_gib} GiB of free space found on $DISK"
            log_info "At least ${MIN_FREE_SPACE_GIB} GiB of free space is required"
            exit 1
        fi

        log_warn "Windows-preserving mode enabled"
        log_warn "Existing partitions will be kept; only free space will be used"
        log_warn "Disk: $(lsblk -dn -o NAME,SIZE "$DISK")"
        if [ "$REUSE_EXISTING_EFI" = true ]; then
            log_warn "EFI partition (reused): $BOOT_DEVICE"
        else
            log_warn "EFI partition (new): $BOOT_DEVICE (${BOOT_SIZE})"
        fi
        log_warn "Free space selected for ZFS: ${free_gib} GiB"

        if [ "$DRY_RUN" = false ]; then
            if [ "$REUSE_EXISTING_EFI" = true ]; then
                read -p "Create Debian ZFS in free space and reuse EFI partition ${BOOT_PART}? (yes/no): " confirm
            else
                read -p "Create Debian ZFS in free space with dedicated EFI (${BOOT_SIZE})? (yes/no): " confirm
            fi
            if [ "$confirm" != "yes" ]; then
                log_info "Cancelled by user"
                exit 0
            fi
        fi
    else
        BOOT_DEVICE=$(partition_device "$DISK" "$BOOT_PART")
        POOL_DEVICE=$(partition_device "$DISK" "$POOL_PART")

        log_warn "WARNING: All data on disk $DISK will be DESTROYED!"
        log_warn "Disk: $(lsblk -dn -o NAME,SIZE "$DISK")"

        if [ "$DRY_RUN" = false ]; then
            read -p "Continue? (yes/no): " confirm
            if [ "$confirm" != "yes" ]; then
                log_info "Cancelled by user"
                exit 0
            fi
        fi
    fi

    log_info "Configuration:"
    log_info "  Disk: $DISK"
    log_info "  Mode: $([ "$USE_FREE_SPACE" = true ] && echo "free-space" || echo "wipe-disk")"
    log_info "  EFI partition: $BOOT_DEVICE"
    log_info "  ZFS partition: $POOL_DEVICE"
    log_info "  Pool: $POOL_NAME"
    log_info "  Encryption: $ENCRYPT"
    log_info "  Hostname: $HOSTNAME"
}

install_packages() {
    log_step "Installing required packages"

    log_info "Adding trixie-backports repository..."
    # Add backports repository
    if ! grep -q "trixie-backports" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        echo "deb http://deb.debian.org/debian trixie-backports main non-free-firmware contrib" >> /etc/apt/sources.list
    fi

    run_cmd apt update
    
    # Remove conflicting old ZFS packages/libraries
    log_info "Removing conflicting ZFS packages..."
    run_cmd apt remove -y \
        zfsutils-linux \
        zfs-initramfs \
        zfs-dkms \
        libzfs6linux \
        libzpool6linux \
        libuutil3linux \
        libnvpair3linux \
        2>/dev/null || true
    
    # Install ZFS packages from backports (use latest available)
    log_info "Installing ZFS packages from backports..."
    run_cmd apt install -y -t trixie-backports \
        zfsutils-linux \
        zfs-initramfs \
        zfs-dkms

    # Install other required packages
    log_info "Installing other required packages..."
    run_cmd apt install -y \
        debootstrap \
        gdisk \
        dkms \
        "linux-headers-$(uname -r)" \
        curl \
        dosfstools \
        efibootmgr \
        cpio \
        kexec-tools
}

prepare_disk() {
    log_step "Preparing disk $DISK"

    if [ "$USE_FREE_SPACE" = true ]; then
        local free_start free_end
        free_start=$(sgdisk -F "$DISK")
        free_end=$(sgdisk -E "$DISK")

        if [ "$REUSE_EXISTING_EFI" = true ]; then
            log_info "Reusing existing EFI partition: $BOOT_DEVICE"
            log_info "Creating ZFS partition in free space (${POOL_DEVICE})..."
            run_cmd sgdisk -n "${POOL_PART}:${free_start}:${free_end}" -t "${POOL_PART}:bf00" "$DISK"
        else
            log_info "Creating dedicated EFI partition (${BOOT_DEVICE}, ${BOOT_SIZE})..."
            run_cmd sgdisk -n "${BOOT_PART}:${free_start}:${BOOT_SIZE}" -t "${BOOT_PART}:ef00" "$DISK"
            log_info "Creating ZFS partition in remaining free space (${POOL_DEVICE})..."
            run_cmd sgdisk -n "${POOL_PART}:0:${free_end}" -t "${POOL_PART}:bf00" "$DISK"
        fi
    else
        # Clear old partitions
        log_info "Clearing disk..."
        run_cmd zpool labelclear -f "$DISK" 2>/dev/null || true
        run_cmd wipefs -a "$DISK"
        run_cmd sgdisk --zap-all "$DISK"

        # Create partitions
        log_info "Creating EFI partition (${BOOT_SIZE})..."
        run_cmd sgdisk -n "${BOOT_PART}:1m:${BOOT_SIZE}" -t "${BOOT_PART}:ef00" "$DISK"

        log_info "Creating ZFS partition (remaining space)..."
        run_cmd sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" "$DISK"
    fi

    # Update partition table
    run_cmd partprobe "$DISK" 2>/dev/null || true

    log_info "Partitions created:"
    run_cmd sgdisk -p "$DISK"
}

create_zfs_pool() {
    log_step "Creating ZFS pool $POOL_NAME"

    local common_opts=(
        -f
        -o ashift=12
        -O compression=lz4
        -O acltype=posixacl
        -O xattr=sa
        -O relatime=on
        -o autotrim=on
        -o compatibility=openzfs-2.2-linux
        -m none
    )

    if [ "$ENCRYPT" = true ]; then
        if [ -z "$PASSPHRASE" ]; then
            log_warn "Passphrase not specified, will prompt interactively"
            read -s -p "Enter ZFS encryption passphrase: " PASSPHRASE
            echo
        fi

        # Create key file
        log_info "Creating key file..."
        echo "$PASSPHRASE" > /etc/zfs/${POOL_NAME}.key
        run_cmd chmod 000 /etc/zfs/${POOL_NAME}.key

        log_info "Creating encrypted pool..."
        run_cmd zpool create "${common_opts[@]}" \
            -O encryption=aes-256-gcm \
            -O keylocation=file:///etc/zfs/${POOL_NAME}.key \
            -O keyformat=passphrase \
            "$POOL_NAME" "$POOL_DEVICE"
    else
        log_info "Creating unencrypted pool..."
        run_cmd zpool create "${common_opts[@]}" \
            "$POOL_NAME" "$POOL_DEVICE"
    fi

    log_info "Pool created:"
    run_cmd zpool status "$POOL_NAME"
}

ensure_boot_environment_properties() {
    local be_dataset="$1"

    log_info "Ensuring boot environment properties on $be_dataset..."

    # Required for ZFSBootMenu BE discovery
    run_cmd zfs set mountpoint=/ "$be_dataset"
    run_cmd zfs set canmount=noauto "$be_dataset"
    run_cmd zpool set bootfs="$be_dataset" "$POOL_NAME"
    run_cmd zfs set org.zfsbootmenu:commandline="quiet loglevel=0" "$be_dataset"

    # Required for encrypted pools
    local encryption
    encryption=$(zfs get -H -o value encryption "$be_dataset" 2>/dev/null || echo "off")
    if [ "$ENCRYPT" = true ] || [ "$encryption" != "off" ]; then
        run_cmd zfs set org.zfsbootmenu:keysource="$be_dataset" "$POOL_NAME"
    fi
}

create_datasets() {
    log_step "Creating ZFS datasets"

    # ROOT dataset (container)
    log_info "Creating zroot/ROOT..."
    run_cmd zfs create -o mountpoint=none ${POOL_NAME}/ROOT

    # Root dataset
    log_info "Creating zroot/ROOT/${DEBIAN_RELEASE}..."
    run_cmd zfs create -o mountpoint=/ -o canmount=noauto \
        ${POOL_NAME}/ROOT/${DEBIAN_RELEASE}

    # Home dataset
    log_info "Creating zroot/home..."
    run_cmd zfs create -o mountpoint=/home ${POOL_NAME}/home

    # Var-log dataset (optional, for log isolation)
    log_info "Creating zroot/var-log..."
    run_cmd zfs create -o mountpoint=/var/log ${POOL_NAME}/var-log

    # Properties for ZFSBootMenu + BE discovery
    log_info "Configuring boot environment properties..."
    ensure_boot_environment_properties "${POOL_NAME}/ROOT/${DEBIAN_RELEASE}"

    log_info "Datasets created:"
    run_cmd zfs list
}

mount_datasets() {
    log_step "Mounting datasets to $MOUNT_POINT"

    # Export and import with new mount point
    log_info "Exporting pool..."
    run_cmd zpool export "$POOL_NAME"

    log_info "Importing pool with mountpoint=$MOUNT_POINT..."
    run_cmd zpool import -N -R "$MOUNT_POINT" "$POOL_NAME"

    # For encryption need to load key
    if [ "$ENCRYPT" = true ]; then
        log_info "Loading encryption key..."
        run_cmd zfs load-key -L file:///etc/zfs/${POOL_NAME}.key ${POOL_NAME}/ROOT/${DEBIAN_RELEASE}
    fi

    # Mount datasets
    log_info "Mounting ROOT..."
    run_cmd zfs mount ${POOL_NAME}/ROOT/${DEBIAN_RELEASE}

    log_info "Mounting home..."
    run_cmd zfs mount ${POOL_NAME}/home

    log_info "Mounting var-log..."
    run_cmd zfs mount ${POOL_NAME}/var-log

    # Check
    log_info "Mounted filesystems:"
    run_cmd mount | grep "$MOUNT_POINT"
}

install_debian() {
    log_step "Installing Debian $DEBIAN_RELEASE via debootstrap"

    log_info "Running debootstrap (this may take several minutes)..."
    run_cmd debootstrap "$DEBIAN_RELEASE" "$MOUNT_POINT" \
        http://deb.debian.org/debian/

    log_info "Debian installed to $MOUNT_POINT"
}

prepare_chroot() {
    log_step "Preparing chroot environment"

    # Copy hostid
    log_info "Copying ZFS hostid..."
    run_cmd cp /etc/hostid "$MOUNT_POINT/etc/hostid"

    # Copy resolv.conf
    log_info "Copying DNS configuration..."
    run_cmd cp /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf"

    # Copy encryption key
    if [ "$ENCRYPT" = true ]; then
        log_info "Copying encryption key..."
        run_cmd mkdir -p "$MOUNT_POINT/etc/zfs"
        run_cmd cp /etc/zfs/${POOL_NAME}.key "$MOUNT_POINT/etc/zfs/${POOL_NAME}.key"
        run_cmd chmod 000 "$MOUNT_POINT/etc/zfs/${POOL_NAME}.key"
    fi

    # Mount virtual filesystems
    log_info "Mounting proc, sys, dev..."
    run_cmd mount -t proc proc "$MOUNT_POINT/proc"
    run_cmd mount -t sysfs sys "$MOUNT_POINT/sys"
    run_cmd mount -B /dev "$MOUNT_POINT/dev"
    run_cmd mount -t devpts pts "$MOUNT_POINT/dev/pts"

    log_info "Chroot environment ready"
}

configure_chroot() {
    log_step "Configuring system in chroot"

    # Create script for chroot execution
    local chroot_script="/tmp/chroot-setup.sh"

    cat > "$chroot_script" << 'CHROOT_SCRIPT'
#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive
DEBIAN_RELEASE="trixie"
HOSTNAME_VAR="__HOSTNAME__"
ROOT_PASSWORD_VAR="__ROOT_PASSWORD__"
ENCRYPT_VAR="__ENCRYPT__"
POOL_NAME_VAR="__POOL_NAME__"

# Configure hostname
echo "$HOSTNAME_VAR" > /etc/hostname
echo "127.0.1.1	$HOSTNAME_VAR" >> /etc/hosts

# Configure package sources
cat > /etc/apt/sources.list << EOF
deb http://deb.debian.org/debian/ ${DEBIAN_RELEASE} main non-free-firmware contrib
deb-src http://deb.debian.org/debian/ ${DEBIAN_RELEASE} main non-free-firmware contrib
deb http://deb.debian.org/debian-security ${DEBIAN_RELEASE}-security main non-free-firmware contrib
deb-src http://deb.debian.org/debian-security/ ${DEBIAN_RELEASE}-security main non-free-firmware contrib
deb http://deb.debian.org/debian ${DEBIAN_RELEASE}-updates main non-free-firmware contrib
deb-src http://deb.debian.org/debian ${DEBIAN_RELEASE}-updates main non-free-firmware contrib
deb http://deb.debian.org/debian/ ${DEBIAN_RELEASE}-backports main non-free-firmware contrib
deb-src http://deb.debian.org/debian/ ${DEBIAN_RELEASE}-backports main non-free-firmware contrib
EOF

# Update packages
apt update

# Install locale and timezone
apt install -y locales keyboard-configuration console-setup tzdata
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# Install kernel and ZFS
log_info "Installing kernel and ZFS packages from backports..."
apt remove -y \
    zfsutils-linux \
    zfs-initramfs \
    zfs-dkms \
    libzfs6linux \
    libzpool6linux \
    libuutil3linux \
    libnvpair3linux \
    2>/dev/null || true
apt install -y -t trixie-backports \
    linux-headers-amd64 \
    linux-image-amd64 \
    zfs-initramfs \
    zfsutils-linux \
    zfs-dkms || {
    log_error "Failed to install kernel and ZFS packages!"
    log_info "Trying without backports..."
    apt install -y \
        linux-headers-amd64 \
        linux-image-amd64 \
        zfs-initramfs \
        zfsutils-linux
}

apt install -y \
    dosfstools \
    efibootmgr \
    locales \
    keyboard-configuration \
    console-setup \
    openssh-server \
    sudo \
    curl \
    systemd-zram-generator \
    cpio \
    kexec-tools

# Verify kernel installation
log_info "Verifying kernel installation..."
if [ ! -f /boot/vmlinuz-* ] || [ ! -f /boot/initrd.img-* ]; then
    log_error "Kernel files not found in /boot!"
    log_info "Files in /boot:"
    ls -la /boot/ || true
    log_warn "Installation may be incomplete!"
else
    log_info "Kernel files found:"
    ls -lh /boot/vmlinuz-* /boot/initrd.img-* 2>/dev/null || true
fi

# Configure DKMS for ZFS
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

# Configure initramfs for ZFS
log_info "Configuring initramfs for ZFS..."

# Add ZFS modules to initramfs
cat > /etc/initramfs-tools/modules.d/zfs << 'EOF'
# ZFS modules for initramfs
zfs
zcommon
znvpair
zavl
zunicode
zlua
icp
spl
zunicode
EOF

# Enable ZFS in initramfs
echo "ZFS_INITRD=yes" > /etc/initramfs-tools/conf.d/zfs

# Enable ZFS services
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target

# For encryption
if [ "$ENCRYPT_VAR" = "true" ]; then
    echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
fi

# Rebuild initramfs
log_info "Rebuilding initramfs with ZFS support..."
update-initramfs -c -k all

# Verify initramfs creation
log_info "Verifying initramfs..."
if [ ! -f /boot/initrd.img-* ]; then
    log_error "initramfs not created!"
    log_warn "This may cause boot issues"
else
    log_info "initramfs created successfully"
    ls -lh /boot/initrd.img-* 2>/dev/null || true
fi

# Configure ZRAM (will be done by separate script)
log_info "ZRAM configured via systemd-zram-generator"

# Set root password
echo "root:$ROOT_PASSWORD_VAR" | chpasswd

log_info "Chroot configuration completed"
CHROOT_SCRIPT

    # Replace variables using safe method (fixes security issue with unescaped variables)
    local temp_script="/tmp/chroot-setup-${RANDOM}.sh"
    sed -e "s|__HOSTNAME__|$(printf '%s\n' "$HOSTNAME" | sed -e 's/[\/&]/\\&/g')|g" \
        -e "s|__POOL_NAME__|$(printf '%s\n' "$POOL_NAME" | sed -e 's/[\/&]/\\&/g')|g" \
        -e "s|__ENCRYPT__|$ENCRYPT|g" \
        "$chroot_script" > "$temp_script"
    
    # Handle password separately with special care (never log this)
    sed -i "s|__ROOT_PASSWORD__|$(printf '%s\n' "$ROOT_PASSWORD" | sed -e 's/[\/&]/\\&/g')|g" "$temp_script"

    # Copy and execute
    run_cmd cp "$temp_script" "$MOUNT_POINT/tmp/chroot-setup.sh"
    run_cmd chmod +x "$MOUNT_POINT/tmp/chroot-setup.sh"

    log_info "Running chroot configuration..."
    run_cmd chroot "$MOUNT_POINT" /bin/bash /tmp/chroot-setup.sh

    # Cleanup
    run_cmd rm "$MOUNT_POINT/tmp/chroot-setup.sh"
    rm "$chroot_script"
    rm "$temp_script"
}

setup_efi() {
    log_step "Configuring EFI System Partition"

    if [ "$USE_FREE_SPACE" = true ] && [ "$REUSE_EXISTING_EFI" = true ]; then
        log_info "Reusing existing EFI System Partition: $BOOT_DEVICE"
    else
        # Format EFI partition
        log_info "Formatting $BOOT_DEVICE to FAT32..."
        run_cmd mkfs.vfat -F32 "$BOOT_DEVICE"
    fi

    # Get UUID (fixes issue with DRY-RUN prefix)
    local BOOT_UUID
    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY-RUN: Would get UUID from $BOOT_DEVICE"
        BOOT_UUID="00000000-0000-0000-0000-000000000000"
    else
        BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEVICE") || {
            log_error "Failed to get UUID from $BOOT_DEVICE"
            return 1
        }
    fi

    # Create fstab
    log_info "Configuring /etc/fstab..."
    cat > "$MOUNT_POINT/etc/fstab" << EOF
# EFI System Partition
UUID=${BOOT_UUID}  /boot/efi  vfat  defaults  0  0
EOF

    # Mount EFI
    log_info "Mounting EFI partition..."
    run_cmd mkdir -p "$MOUNT_POINT/boot/efi"
    run_cmd chroot "$MOUNT_POINT" mount /boot/efi

    log_info "EFI partition configured"
}

install_zfsbootmenu() {
    log_step "Installing ZFSBootMenu"

    # Create directory for ZFSBootMenu
    log_info "Creating ZFSBootMenu directory..."
    run_cmd chroot "$MOUNT_POINT" mkdir -p /boot/efi/EFI/ZBM

    # Download latest ZFSBootMenu EFI binary from GitHub releases
    log_info "Downloading ZFSBootMenu EFI binary..."
    
    # Get latest release URL
    local ZBM_URL="https://github.com/zbm-dev/zfsbootmenu/releases/latest/download/VMLINUZ.EFI"
    local download_success=false
    
    # Primary download attempt
    if run_cmd chroot "$MOUNT_POINT" curl -fSL --connect-timeout 10 -m 300 \
        -o /boot/efi/EFI/ZBM/VMLINUZ.EFI "$ZBM_URL"; then
        download_success=true
    fi
    
    # Fallback download attempt
    if [ "$download_success" = false ]; then
        log_warn "Primary download failed, trying alternative URL..."
        if run_cmd chroot "$MOUNT_POINT" curl -fSL --connect-timeout 10 -m 300 \
            -o /boot/efi/EFI/ZBM/VMLINUZ.EFI "https://get.zfsbootmenu.org/efi"; then
            download_success=true
        fi
    fi
    
    # Handle download failure
    if [ "$download_success" = false ]; then
        log_error "Failed to download ZFSBootMenu EFI binary from all sources!"
        log_warn "You can manually download and place it at: $MOUNT_POINT/boot/efi/EFI/ZBM/VMLINUZ.EFI"
        log_warn "Download from: https://github.com/zbm-dev/zfsbootmenu/releases"
        return 1
    fi

    # Create backup copy
    log_info "Creating backup copy..."
    run_cmd chroot "$MOUNT_POINT" cp /boot/efi/EFI/ZBM/VMLINUZ.EFI \
        /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

    # Create UEFI fallback path (many firmware only check EFI/BOOT/BOOTX64.EFI)
    log_info "Creating UEFI fallback boot path..."
    run_cmd chroot "$MOUNT_POINT" mkdir -p /boot/efi/EFI/BOOT
    run_cmd chroot "$MOUNT_POINT" cp /boot/efi/EFI/ZBM/VMLINUZ.EFI \
        /boot/efi/EFI/BOOT/BOOTX64.EFI

    # Configure EFI boot entries
    log_info "Creating EFI boot entries..."

    # Derive DISK/BOOT_PART from EFI_DEVICE in existing-pool mode
    if { [ -z "$DISK" ] || [ -z "${BOOT_PART:-}" ]; } && [ -n "$EFI_DEVICE" ]; then
        local detected_disk detected_part
        detected_disk=$(lsblk -no PKNAME "$EFI_DEVICE" 2>/dev/null || true)
        detected_part=$(lsblk -no PARTN "$EFI_DEVICE" 2>/dev/null || true)
        if [ -n "$detected_disk" ]; then
            DISK="/dev/${detected_disk}"
        fi
        if [ -n "$detected_part" ]; then
            BOOT_PART="$detected_part"
        fi
    fi

    # Primary entry
    if [ -n "$DISK" ] && [ -n "${BOOT_PART:-}" ]; then
        run_cmd efibootmgr -c -d "$DISK" -p "$BOOT_PART" \
            -L "ZFSBootMenu" \
            -l '\EFI\ZBM\VMLINUZ.EFI' || {
            log_warn "Failed to create EFI boot entry (may need to be done manually)"
        }

        # Backup entry
        run_cmd efibootmgr -c -d "$DISK" -p "$BOOT_PART" \
            -L "ZFSBootMenu (Backup)" \
            -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI' || {
            log_warn "Failed to create backup EFI boot entry"
        }
    else
        log_warn "Could not detect boot disk/partition for efibootmgr entries"
        log_warn "Fallback EFI path created: \\EFI\\BOOT\\BOOTX64.EFI"
    fi

    log_info "ZFSBootMenu installed and configured"
}

verify_boot_environment() {
    log_step "Verifying boot environment"

    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY-RUN: skipping boot environment verification"
        return 0
    fi

    local be_dataset
    if [ "$MODE" = "existing" ] && [ -n "$POOL_DATASET" ]; then
        be_dataset="$POOL_DATASET"
    else
        be_dataset="${POOL_NAME}/ROOT/${DEBIAN_RELEASE}"
    fi

    # Re-assert BE properties after chroot setup
    ensure_boot_environment_properties "$be_dataset"

    local kernel_count initrd_count
    kernel_count=$(find "$MOUNT_POINT/boot" -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | wc -l)
    initrd_count=$(find "$MOUNT_POINT/boot" -maxdepth 1 -name 'initrd.img-*' 2>/dev/null | wc -l)
    log_info "Kernel files in target root: $kernel_count"
    log_info "Initrd files in target root: $initrd_count"

    if [ "$kernel_count" -eq 0 ] || [ "$initrd_count" -eq 0 ]; then
        log_warn "Kernel/initrd missing. Reinstalling in chroot..."
        run_cmd chroot "$MOUNT_POINT" /bin/bash -lc \
            'apt update && apt install -y --reinstall linux-image-amd64 zfs-initramfs zfsutils-linux && update-initramfs -c -k all'

        kernel_count=$(find "$MOUNT_POINT/boot" -maxdepth 1 -name 'vmlinuz-*' 2>/dev/null | wc -l)
        initrd_count=$(find "$MOUNT_POINT/boot" -maxdepth 1 -name 'initrd.img-*' 2>/dev/null | wc -l)
        log_info "After repair: kernels=$kernel_count, initrds=$initrd_count"
    fi

    if [ "$kernel_count" -eq 0 ] || [ "$initrd_count" -eq 0 ]; then
        log_error "No bootable kernel/initrd found in target boot environment"
        return 1
    fi

    log_info "Boot environment verification passed"
}

auto_fix_no_be() {
    log_step "Auto-fix for 'no boot environments found'"

    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY-RUN: skipping auto-fix"
        return 0
    fi

    local be_dataset
    if [ "$MODE" = "existing" ] && [ -n "$POOL_DATASET" ]; then
        be_dataset="$POOL_DATASET"
    else
        be_dataset="${POOL_NAME}/ROOT/${DEBIAN_RELEASE}"
    fi

    # Re-assert required BE properties
    ensure_boot_environment_properties "$be_dataset"

    # Ensure fallback EFI path exists
    if [ -f "$MOUNT_POINT/boot/efi/EFI/ZBM/VMLINUZ.EFI" ]; then
        run_cmd mkdir -p "$MOUNT_POINT/boot/efi/EFI/BOOT"
        run_cmd cp "$MOUNT_POINT/boot/efi/EFI/ZBM/VMLINUZ.EFI" \
            "$MOUNT_POINT/boot/efi/EFI/BOOT/BOOTX64.EFI"
    else
        log_error "Missing $MOUNT_POINT/boot/efi/EFI/ZBM/VMLINUZ.EFI"
        return 1
    fi

    # Ensure efibootmgr entry when disk/part known
    if { [ -z "$DISK" ] || [ -z "${BOOT_PART:-}" ]; } && [ -n "$EFI_DEVICE" ]; then
        local detected_disk detected_part
        detected_disk=$(lsblk -no PKNAME "$EFI_DEVICE" 2>/dev/null || true)
        detected_part=$(lsblk -no PARTN "$EFI_DEVICE" 2>/dev/null || true)
        [ -n "$detected_disk" ] && DISK="/dev/${detected_disk}"
        [ -n "$detected_part" ] && BOOT_PART="$detected_part"
    fi

    if command -v efibootmgr >/dev/null 2>&1 && [ -n "$DISK" ] && [ -n "${BOOT_PART:-}" ]; then
        if ! efibootmgr -v | grep -q "\\EFI\\ZBM\\VMLINUZ.EFI"; then
            run_cmd efibootmgr -c -d "$DISK" -p "$BOOT_PART" \
                -L "ZFSBootMenu" -l '\\EFI\\ZBM\\VMLINUZ.EFI' || true
        fi
    fi

    # Final diagnostics
    run_cmd zpool get bootfs "$POOL_NAME" || true
    run_cmd zfs get mountpoint,canmount,org.zfsbootmenu:commandline "$be_dataset" || true
    run_cmd ls -lh "$MOUNT_POINT"/boot/vmlinuz-* "$MOUNT_POINT"/boot/initrd.img-* 2>/dev/null || true
    log_info "Auto-fix complete"
}

configure_zram() {
    log_step "Configuring ZRAM"

    # Create systemd-zram-generator configuration
    log_info "Creating ZRAM configuration..."
    run_cmd mkdir -p "$MOUNT_POINT/etc/systemd"

    cat > "$MOUNT_POINT/etc/systemd/zram-generator.conf" << 'EOF'
[zram0]
# Use 60% RAM or maximum 4GB
zram-size = min(ram * 0.6, 4096)
compression-algorithm = zstd
fs-type = swap
mount-point = none
EOF

    log_info "ZRAM configuration created"
    log_info "File: /etc/systemd/zram-generator.conf"
}

finalize() {
    log_step "Finalizing installation"

    # Exit chroot
    log_info "Unmounting filesystems..."
    run_cmd umount -lf "$MOUNT_POINT/dev/pts" 2>/dev/null || true
    run_cmd umount -lf "$MOUNT_POINT/dev" 2>/dev/null || true
    run_cmd umount -lf "$MOUNT_POINT/proc" 2>/dev/null || true
    run_cmd umount -lf "$MOUNT_POINT/sys" 2>/dev/null || true
    run_cmd umount -lf "$MOUNT_POINT/boot/efi" 2>/dev/null || true
    run_cmd umount -n -R "$MOUNT_POINT" 2>/dev/null || true

    # Export pool (retry if busy)
    log_info "Exporting ZFS pool..."
    if ! run_cmd zpool export "$POOL_NAME" 2>/dev/null; then
        log_warn "Pool busy, attempting force unmount of pool datasets..."
        run_cmd zfs unmount -r "$POOL_NAME" 2>/dev/null || true
        sleep 1
        run_cmd zpool export "$POOL_NAME" 2>/dev/null || {
            log_warn "Could not export pool automatically (dataset busy)."
            log_warn "You can export manually after checking active mounts/processes:"
            log_warn "  zpool export $POOL_NAME"
        }
    fi

    log_info ""
    log_warn "═══════════════════════════════════════════════════════"
    log_warn "INSTALLATION COMPLETED SUCCESSFULLY!"
    log_warn "═══════════════════════════════════════════════════════"
    log_info ""
    log_info "Next steps:"
    log_info "  1. Reboot system: reboot"
    log_info "  2. Remove Live USB"
    log_info "  3. Select 'ZFSBootMenu' in UEFI"
    log_info "  4. Login (root / $ROOT_PASSWORD)"
    log_info "  5. CHANGE password: passwd"
    log_info ""
    log_info "Note: ZFSBootMenu installed as EFI binary (no package required)"
    log_info ""
    if [ "$ENCRYPT" = true ]; then
        log_warn "WARNING: Passphrase will be required for ZFS at boot!"
        log_info ""
    fi
    log_info "Useful commands after boot:"
    log_info "  zpool status              # Check ZFS pool"
    log_info "  zfs list                  # List datasets"
    log_info "  zramctl                   # Check ZRAM"
    log_info "  efibootmgr -v             # EFI boot entries"
    log_info ""
    log_warn "DON'T FORGET TO CHANGE THE ROOT PASSWORD!"
    log_warn "═══════════════════════════════════════════════════════"
}

###############################################################################
# Existing Pool Installation Mode
###############################################################################

prepare_existing_pool() {
    log_step "Preparing existing ZFS pool"
    
    log_info "Pool: $POOL_NAME"
    log_info "EFI partition: $EFI_DEVICE"
    
    # Get list of root datasets
    log_info "Available ROOT datasets in pool $POOL_NAME:"
    local datasets
    datasets=$(zfs list -H -o name -r "$POOL_NAME" 2>/dev/null | grep "^${POOL_NAME}/ROOT/" || true)
    
    if [ -z "$datasets" ]; then
        log_error "No ROOT datasets found in pool $POOL_NAME"
        log_info "Create dataset first: zfs create -o mountpoint=/ $POOL_NAME/ROOT/trixie"
        return 1
    fi
    
    # Select or use the first one
    local dataset_count
    dataset_count=$(echo "$datasets" | wc -l)
    
    if [ "$dataset_count" -eq 1 ]; then
        POOL_DATASET="$datasets"
        log_info "Using dataset: $POOL_DATASET"
    else
        log_info "Multiple ROOT datasets available:"
        local count=0
        declare -a dataset_array
        while IFS= read -r ds; do
            ((count++))
            dataset_array[$count]="$ds"
            log_info "  $count) $ds"
        done <<< "$datasets"
        
        read -p "Select dataset (1-$count): " ds_choice
        
        if [ -z "$ds_choice" ] || [ "$ds_choice" -lt 1 ] || [ "$ds_choice" -gt $count ]; then
            log_error "Invalid selection"
            return 1
        fi
        
        POOL_DATASET="${dataset_array[$ds_choice]}"
        log_info "Selected dataset: $POOL_DATASET"
    fi
    
    # Extract dataset for later use
    DEBIAN_RELEASE=$(echo "$POOL_DATASET" | sed "s|^${POOL_NAME}/ROOT/||")

    # Existing dataset may miss BE props; enforce for ZFSBootMenu
    ensure_boot_environment_properties "$POOL_DATASET"
    
    # Mount the dataset
    log_info "Mounting pool dataset..."
    run_cmd zpool export "$POOL_NAME" 2>/dev/null || true
    
    log_info "Importing pool with mountpoint=$MOUNT_POINT..."
    run_cmd zpool import -N -R "$MOUNT_POINT" "$POOL_NAME"
    
    # For encryption need to load key
    if [ "$ENCRYPT" = true ]; then
        log_info "Loading encryption key..."
        read -s -p "Enter ZFS encryption passphrase: " key_pass
        echo "$key_pass" | run_cmd zfs load-key -L prompt "$POOL_DATASET" || {
            log_error "Failed to load encryption key"
            return 1
        }
    fi
    
    # Mount datasets
    log_info "Mounting dataset..."
    run_cmd zfs mount "$POOL_DATASET"
    
    log_info "Mounted filesystems:"
    run_cmd mount | grep "$MOUNT_POINT" || true
}

install_on_existing_pool() {
    log_step "Installing Debian on existing ZFS pool"
    
    prepare_existing_pool || return 1
    install_debian
    prepare_chroot
    configure_chroot
    verify_boot_environment
    setup_efi_existing
    install_zfsbootmenu
    auto_fix_no_be
    configure_zram
    finalize
}

setup_efi_existing() {
    log_step "Configuring EFI System Partition (existing)"
    
    # Verify EFI partition
    log_info "Verifying EFI partition: $EFI_DEVICE"
    
    # Get UUID
    local BOOT_UUID
    if [ "$DRY_RUN" = true ]; then
        log_warn "DRY-RUN: Would get UUID from $EFI_DEVICE"
        BOOT_UUID="00000000-0000-0000-0000-000000000000"
    else
        BOOT_UUID=$(blkid -s UUID -o value "$EFI_DEVICE") || {
            log_error "Failed to get UUID from $EFI_DEVICE"
            return 1
        }
    fi
    
    # Create fstab entry
    log_info "Configuring /etc/fstab..."
    cat > "$MOUNT_POINT/etc/fstab" << EOF
# EFI System Partition
UUID=${BOOT_UUID}  /boot/efi  vfat  defaults  0  0
EOF
    
    # Mount EFI
    log_info "Mounting EFI partition..."
    run_cmd mkdir -p "$MOUNT_POINT/boot/efi"
    run_cmd chroot "$MOUNT_POINT" mount /boot/efi
    
    log_info "EFI partition configured"
}

###############################################################################
# Main process
###############################################################################

main() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Debian Trixie ZFS Root Installation Script"
    log_info "Version: 2.1 (April 2026) - With Existing Pool Support"
    log_info "═══════════════════════════════════════════════════════"

    # Route to appropriate installation mode
    case "$MODE" in
        disk)
            show_raid_info
            resolve_install_layout
            install_packages
            prepare_disk
            create_zfs_pool
            create_datasets
            mount_datasets
            install_debian
            prepare_chroot
            configure_chroot
            verify_boot_environment
            setup_efi
            install_zfsbootmenu
            auto_fix_no_be
            configure_zram
            finalize
            ;;
        existing)
            log_info "Using existing ZFS pool: $POOL_NAME"
            log_info "EFI partition: $EFI_DEVICE"
            
            install_on_existing_pool
            ;;
        interactive)
            # Handled by interactive_mode_setup, then falls through to disk mode
            show_raid_info
            resolve_install_layout
            install_packages
            prepare_disk
            create_zfs_pool
            create_datasets
            mount_datasets
            install_debian
            prepare_chroot
            configure_chroot
            verify_boot_environment
            setup_efi
            install_zfsbootmenu
            auto_fix_no_be
            configure_zram
            finalize
            ;;
        *)
            log_error "Unknown installation mode: $MODE"
            exit 1
            ;;
    esac
}

# Run
main "$@"
