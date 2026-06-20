#!/usr/bin/env bash
set -e

echo "🧠 Debian Trixie + ZFSBootMenu FULL installer"
echo "---------------------------------------------"

# =========================================================
# 1. REPOSITORIES FIX (ТО ЧЕГО НЕ ХВАТАЛО)
# =========================================================
echo "🌐 Fixing repositories..."

echo "deb http://deb.debian.org/debian trixie-backports main non-free-firmware contrib" >> /etc/apt/sources.list
apt update

# =========================================================
# 2. PACKAGES INSTALL (ТО ЧТО ТЫ НЕ МОГ СТАВИТЬ РАНЬШЕ)
# =========================================================
echo "Removing conflicting ZFS packages..."
apt remove -y \
    zfsutils-linux \
    zfs-initramfs \
    zfs-dkms \
    libzfs6linux \
    libzpool6linux \
    libuutil3linux \
    libnvpair3linux \
    2>/dev/null || true

echo "📦 Installing required packages..."
apt install -y -t trixie-backports \
    zfsutils-linux \
    zfs-initramfs \
    zfs-dkms

apt install -y \
    debootstrap \
    gdisk \
    dkms \
    "linux-headers-$(uname -r)" \
    curl \
    dosfstools \
    efibootmgr \
    cpio \
    kexec-tools \
    mdadm

# =========================================================
# DISK SELECTION
# =========================================================
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT

echo ""
read -rp "EFI partition (e.g. /dev/nvme0n1p1): " EFI
read -rp "ZFS partition (e.g. /dev/nvme0n1p2): " ZFS
read -rp "Hostname: " HOST

echo ""
echo "EFI  = $EFI"
echo "ZFS  = $ZFS"
echo "HOST = $HOST"
echo ""

read -rp "Type YES to continue: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && exit 1

# =========================================================
# 3. FORMAT EFI
# =========================================================
echo "💾 Formatting EFI..."
mkfs.fat -F32 "$EFI"

# =========================================================
# 4. ZFS POOL
# =========================================================
modprobe zfs

echo "🧠 Creating ZFS pool..."

zpool create -f \
  -o ashift=12 \
  -o autotrim=on \
  -O compression=lz4 \
  -O atime=off \
  -O xattr=sa \
  -O acltype=posixacl \
  -O mountpoint=none \
  zroot "$ZFS"

# =========================================================
# 5. DATASETS
# =========================================================
echo "📦 Creating datasets..."

zfs create zroot/ROOT
zfs create zroot/ROOT/debian
zfs create zroot/home
zfs create zroot/var
zfs create zroot/tmp

zfs set mountpoint=/ zroot/ROOT/debian
zfs set mountpoint=/home zroot/home
zfs set mountpoint=/var zroot/var
zfs set mountpoint=/tmp zroot/tmp

# =========================================================
# 6. MOUNT SYSTEM
# =========================================================
echo "📍 Mounting system..."

mount -t zfs zroot/ROOT/debian /mnt
mkdir -p /mnt/boot/efi
mount "$EFI" /mnt/boot/efi

# =========================================================
# 7. BASE SYSTEM INSTALL
# =========================================================
echo "📥 Installing Debian base system..."

debootstrap trixie /mnt

# =========================================================
# 8. BIND SYSTEM
# =========================================================
mount --rbind /dev /mnt/dev
mount --rbind /proc /mnt/proc
mount --rbind /sys /mnt/sys

# =========================================================
# 9. CHROOT SCRIPT (REAL SYSTEM SETUP)
# =========================================================
cat > /mnt/root/chroot.sh <<'EOF'
#!/bin/bash
set -e

echo "⚙️ CHROOT SETUP"

echo "deb http://deb.debian.org/debian trixie-backports main non-free-firmware contrib" >> /etc/apt/sources.list
apt update

apt remove -y \
    zfsutils-linux \
    zfs-initramfs \
    zfs-dkms \
    libzfs6linux \
    libzpool6linux \
    libuutil3linux \
    libnvpair3linux \
    2>/dev/null || true

echo "📦 Installing required packages..."
apt install -y -t trixie-backports \
    zfsutils-linux \
    zfs-initramfs \
    zfs-dkms

apt install -y \
    debootstrap \
    gdisk \
    dkms \
    "linux-headers-$(uname -r)" \
    curl \
    dosfstools \
    efibootmgr \
    cpio \
    kexec-tools \
    mdadm

apt install -y \
  linux-image-amd64 \
  systemd-sysv \
  zfsutils-linux \
  initramfs-tools \
  curl \
  efibootmgr

echo "$HOST" > /etc/hostname

cat > /etc/hosts <<EOL
127.0.0.1 localhost
127.0.1.1 $HOST
EOL

# =====================================================
# DRIVERS FOR VMD / NVME / RAID
# =====================================================
cat > /etc/initramfs-tools/modules <<EOM
vmd
nvme
md_mod
raid0
raid1
raid10
EOM

update-initramfs -u -k all

# =====================================================
# ZFS BOOT CONFIG
# =====================================================
zpool set bootfs=zroot/ROOT/debian zroot

# =====================================================
# ZFSBOOTMENU
# =====================================================
mkdir -p /boot/efi/EFI/ZBM

curl -Lo /boot/efi/EFI/ZBM/VMLINUZ.EFI \
https://get.zfsbootmenu.org/efi

# =====================================================
# UEFI ENTRY
# =====================================================
efibootmgr -c \
-d $(lsblk -no PKNAME "$EFI") \
-p $(lsblk -no PARTNUM "$EFI") \
-L "ZFSBootMenu" \
-l '\EFI\ZBM\VMLINUZ.EFI'

echo "DONE"
EOF

chmod +x /mnt/root/chroot.sh

# =========================================================
# 10. RUN CHROOT
# =========================================================
chroot /mnt /root/chroot.sh

# =========================================================
# 11. CLEANUP
# =========================================================
echo "🚪 Cleaning up..."

umount -R /mnt
zpool export zroot

echo "✅ INSTALL COMPLETE"
echo "👉 reboot now"
