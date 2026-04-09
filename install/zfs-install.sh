#!/bin/bash
###############################################################################
# zfs-install.sh — Automated Debian Bookworm installation on ZFS root
#
# Usage:
#   sudo bash zfs-install.sh --disk /dev/sda [OPTIONS]
#
# Options:
#   --disk DISK         Installation disk (required)
#   --encrypt           Enable ZFS native encryption
#   --passphrase PHRASE Encryption passphrase (if not specified, will prompt)
#   --hostname NAME     Hostname (default: debian-zfs)
#   --password PASS     Root password (default: root, CHANGE after installation!)
#   --pool-name NAME    ZFS pool name (default: zroot)
#   --dry-run           Show commands without executing
#   --help              Show this help
#
# Examples:
#   # Without encryption
#   sudo bash zfs-install.sh --disk /dev/sda
#
#   # With encryption
#   sudo bash zfs-install.sh --disk /dev/sda --encrypt --passphrase "MySecurePass"
#
#   # Custom hostname
#   sudo bash zfs-install.sh --disk /dev/nvme0n1 --hostname nas-server
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

# Default parameters
DISK=""
ENCRYPT=false
PASSPHRASE=""
HOSTNAME="debian-zfs"
ROOT_PASSWORD="root"
POOL_NAME="zroot"
DRY_RUN=false
BOOT_PART=1
POOL_PART=2
BOOT_SIZE="+512M"

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
            shift 2
            ;;
        --encrypt)
            ENCRYPT=true
            shift
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

# Check required parameters
if [ -z "$DISK" ]; then
    log_error "Parameter --disk is required!"
    show_help
fi

# Check root privileges
if [ "$(id -u)" -ne 0 ]; then
    log_error "Run this script as root (sudo)"
    exit 1
fi

# Check if disk exists
if [ ! -b "$DISK" ]; then
    log_error "Disk $DISK not found!"
    log_info "Available disks:"
    lsblk -dn -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || fdisk -l 2>/dev/null | grep "Disk /dev"
    exit 1
fi

# Data loss warning
log_warn "WARNING: All data on disk $DISK will be DESTROYED!"
log_warn "Disk: $(lsblk -dn -o NAME,SIZE "$DISK")"

if [ "$DRY_RUN" = false ]; then
    read -p "Continue? (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Cancelled by user"
        exit 0
    fi
fi

# Variables
BOOT_DEVICE="${DISK}${BOOT_PART}"
POOL_DEVICE="${DISK}${POOL_PART}"
MOUNT_POINT="/mnt"
DEBIAN_RELEASE="bookworm"

# For NVMe drives adjust names
if [[ "$DISK" == *nvme* ]]; then
    BOOT_DEVICE="${DISK}p${BOOT_PART}"
    POOL_DEVICE="${DISK}p${POOL_PART}"
fi

log_info "Configuration:"
log_info "  Disk: $DISK"
log_info "  EFI partition: $BOOT_DEVICE"
log_info "  ZFS partition: $POOL_DEVICE"
log_info "  Pool: $POOL_NAME"
log_info "  Encryption: $ENCRYPT"
log_info "  Hostname: $HOSTNAME"

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

install_packages() {
    log_step "Installing required packages"

    log_info "Adding bookworm-backports repository..."
    # Add backports repository
    if ! grep -q "bookworm-backports" /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
        echo "deb http://deb.debian.org/debian bookworm-backports main non-free-firmware contrib" >> /etc/apt/sources.list
    fi

    run_cmd apt update
    
    # Install ZFS packages from backports
    log_info "Installing ZFS packages from backports..."
    run_cmd apt install -y -t bookworm-backports \
        zfsutils-linux \
        zfs-initramfs \
        libnvpair3linux \
        libuutil3linux \
        libzfs6linux \
        libzpool6linux

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

    # Set bootfs
    log_info "Setting bootfs..."
    run_cmd zpool set bootfs=${POOL_NAME}/ROOT/${DEBIAN_RELEASE} "$POOL_NAME"

    # Properties for ZFSBootMenu
    log_info "Configuring ZFSBootMenu properties..."
    run_cmd zfs set org.zfsbootmenu:commandline="quiet loglevel=0" \
        ${POOL_NAME}/ROOT/${DEBIAN_RELEASE}

    if [ "$ENCRYPT" = true ]; then
        run_cmd zfs set org.zfsbootmenu:keysource="${POOL_NAME}/ROOT/${DEBIAN_RELEASE}" \
            ${POOL_NAME}
    fi

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
DEBIAN_RELEASE="bookworm"
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
apt install -y -t bookworm-backports \
    linux-headers-amd64 \
    linux-image-amd64 \
    zfs-initramfs \
    zfsutils-linux \
    libnvpair3linux \
    libuutil3linux \
    libzfs6linux \
    libzpool6linux

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

# Configure DKMS for ZFS
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

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
log_info "Rebuilding initramfs..."
update-initramfs -c -k all

# Configure ZRAM (will be done by separate script)
log_info "ZRAM configured via systemd-zram-generator"

# Set root password
echo "root:$ROOT_PASSWORD_VAR" | chpasswd

log_info "Chroot configuration completed"
CHROOT_SCRIPT

    # Replace variables
    sed -i "s/__HOSTNAME__/$HOSTNAME/g" "$chroot_script"
    sed -i "s/__ROOT_PASSWORD__/$ROOT_PASSWORD/g" "$chroot_script"
    sed -i "s/__ENCRYPT__/$ENCRYPT/g" "$chroot_script"
    sed -i "s/__POOL_NAME__/$POOL_NAME/g" "$chroot_script"

    # Copy and execute
    run_cmd cp "$chroot_script" "$MOUNT_POINT/tmp/chroot-setup.sh"
    run_cmd chmod +x "$MOUNT_POINT/tmp/chroot-setup.sh"

    log_info "Running chroot configuration..."
    run_cmd chroot "$MOUNT_POINT" /bin/bash /tmp/chroot-setup.sh

    # Cleanup
    run_cmd rm "$MOUNT_POINT/tmp/chroot-setup.sh"
    rm "$chroot_script"
}

setup_efi() {
    log_step "Configuring EFI System Partition"

    # Format EFI partition
    log_info "Formatting $BOOT_DEVICE to FAT32..."
    run_cmd mkfs.vfat -F32 "$BOOT_DEVICE"

    # Get UUID
    local BOOT_UUID
    BOOT_UUID=$(run_cmd blkid -s UUID -o value "$BOOT_DEVICE")

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
    
    run_cmd chroot "$MOUNT_POINT" curl -fSL -o /boot/efi/EFI/ZBM/VMLINUZ.EFI \
        "$ZBM_URL" || {
        log_error "Failed to download ZFSBootMenu EFI binary!"
        log_info "Trying alternative URL..."
        
        # Fallback URL
        run_cmd chroot "$MOUNT_POINT" curl -fSL -o /boot/efi/EFI/ZBM/VMLINUZ.EFI \
            "https://get.zfsbootmenu.org/efi" || {
            log_error "All download methods failed!"
            log_warn "You may need to manually download VMLINUZ.EFI"
            log_warn "Place it at: $MOUNT_POINT/boot/efi/EFI/ZBM/VMLINUZ.EFI"
            return 1
        }
    }

    # Create backup copy
    log_info "Creating backup copy..."
    run_cmd chroot "$MOUNT_POINT" cp /boot/efi/EFI/ZBM/VMLINUZ.EFI \
        /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

    # Configure EFI boot entries
    log_info "Creating EFI boot entries..."

    # Primary entry
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

    log_info "ZFSBootMenu installed and configured"
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
    run_cmd umount -n -R "$MOUNT_POINT" || true

    # Export pool
    log_info "Exporting ZFS pool..."
    run_cmd zpool export "$POOL_NAME" || true

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
# Main process
###############################################################################

main() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Debian Bookworm ZFS Root Installation Script"
    log_info "Version: 1.0 (April 2026)"
    log_info "═══════════════════════════════════════════════════════"

    install_packages
    prepare_disk
    create_zfs_pool
    create_datasets
    mount_datasets
    install_debian
    prepare_chroot
    configure_chroot
    setup_efi
    install_zfsbootmenu
    configure_zram
    finalize
}

# Run
main "$@"
