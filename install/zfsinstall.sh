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
    zfs-dkms \
    curl

apt install -y \
    debootstrap \
    gdisk \
    dkms \
    "linux-headers-$(uname -r)" \
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
read -rp "Username (leave empty for root-only): " USERNAME
if [ -n "$USERNAME" ]; then
    read -rsp "Password for $USERNAME: " USERPASS
    echo
    read -rsp "Confirm password: " USERPASS2
    echo
    [[ "$USERPASS" != "$USERPASS2" ]] && echo "Passwords don't match" && exit 1
fi
read -rsp "Root password: " ROOTPASS
echo
read -rsp "Confirm root password: " ROOTPASS2
echo
[[ "$ROOTPASS" != "$ROOTPASS2" ]] && echo "Passwords don't match" && exit 1

echo ""
echo "EFI  = $EFI"
echo "ZFS  = $ZFS"
echo "HOST = $HOST"
[ -n "$USERNAME" ] && echo "USER = $USERNAME"
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
# Resolve EFI disk/partition now (lsblk may not work inside chroot)
EFI_DISK=$(lsblk -no PKNAME "$EFI")
EFI_PART=$(lsblk -no PARTN "$EFI")
echo "📍 Mounting system..."

mount -t zfs -o zfsutil zroot/ROOT/debian /mnt
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

# Copy pre-built ZBM EFI into chroot for installation
mkdir -p /mnt/root/zbm
cp /usr/share/zbm/* /mnt/root/zbm/

cat > /mnt/root/chroot.sh <<EOF
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
    zfs-dkms \
    curl

apt install -y \
    debootstrap \
    gdisk \
    dkms \
    dosfstools \
    efibootmgr \
    cpio \
    kexec-tools \
    mdadm

apt install -y \
  linux-image-amd64 \
  linux-headers-amd64 \
  sudo \
  systemd-sysv \
  zfsutils-linux \
  initramfs-tools \
  efibootmgr \
  kde-plasma-desktop \
  sddm \
  nvidia-driver \
  firmware-nvidia-gsp

echo "$HOST" > /etc/hostname

cat > /etc/hosts <<EOL
127.0.0.1 localhost
127.0.1.1 $HOST
EOL

# =====================================================
# USERS & PASSWORDS
# =====================================================
echo "root:$ROOTPASS" | chpasswd
if [ -n "$USERNAME" ]; then
    useradd -m -G sudo -s /bin/bash "$USERNAME"
    echo "$USERNAME:$USERPASS" | chpasswd
fi

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
# ZFSBOOTMENU (use pre-built EFI with RAID modules)
# =====================================================
mkdir -p /boot/efi/EFI/ZBM

# Copy pre-built ZBM EFI files bundled in the live ISO
cp /root/zbm/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ.EFI

# =====================================================
# UEFI ENTRY
# =====================================================
efibootmgr -c \
-d /dev/$EFI_DISK \
-p $EFI_PART \
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

# Kill any processes still using the chroot
fuser -km /mnt 2>/dev/null || true
sleep 1

# Recursive unmount with lazy fallback
umount -R /mnt 2>/dev/null || umount -Rl /mnt 2>/dev/null || true

zpool export zroot 2>/dev/null || zpool export -f zroot 2>/dev/null || true

echo "✅ INSTALL COMPLETE"
echo "👉 reboot now"
