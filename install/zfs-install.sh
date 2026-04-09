#!/bin/bash
###############################################################################
# zfs-install.sh — Автоматическая установка Debian Bookworm на ZFS root
#
# Использование:
#   sudo bash zfs-install.sh --disk /dev/sda [OPTIONS]
#
# Опции:
#   --disk DISK         Диск для установки (обязательно)
#   --encrypt           Включить ZFS native encryption
#   --passphrase PHRASE Passphrase для шифрования (если не указан, будет запрошен)
#   --hostname NAME     Имя хоста (по умолчанию: debian-zfs)
#   --password PASS     Пароль root (по умолчанию: root, СМЕНИТЕ после установки!)
#   --pool-name NAME    Имя ZFS пула (по умолчанию: zroot)
#   --dry-run           Показать команды без выполнения
#   --help              Показать эту справку
#
# Примеры:
#   # Без шифрования
#   sudo bash zfs-install.sh --disk /dev/sda
#
#   # С шифрованием
#   sudo bash zfs-install.sh --disk /dev/sda --encrypt --passphrase "MySecurePass"
#
#   # Кастомный hostname
#   sudo bash zfs-install.sh --disk /dev/nvme0n1 --hostname nas-server
###############################################################################

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Логирование
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

# Параметры по умолчанию
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

# Функция показа справки
show_help() {
    head -n 35 "$0" | tail -n +2 | sed 's/^# \?//'
    exit 0
}

# Парсинг аргументов
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
            log_error "Неизвестный параметр: $1"
            show_help
            ;;
    esac
done

# Проверка обязательных параметров
if [ -z "$DISK" ]; then
    log_error "Параметр --disk обязателен!"
    show_help
fi

# Проверка root прав
if [ "$(id -u)" -ne 0 ]; then
    log_error "Запустите скрипт от имени root (sudo)"
    exit 1
fi

# Проверка что диск существует
if [ ! -b "$DISK" ]; then
    log_error "Диск $DISK не найден!"
    log_info "Доступные диски:"
    lsblk -dn -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || fdisk -l 2>/dev/null | grep "Disk /dev"
    exit 1
fi

# Предупреждение о потере данных
log_warn "ВНИМАНИЕ: Все данные на диске $DISK будут УНИЧТОЖЕНЫ!"
log_warn "Диск: $(lsblk -dn -o NAME,SIZE "$DISK")"

if [ "$DRY_RUN" = false ]; then
    read -p "Продолжить? (да/нет): " confirm
    if [ "$confirm" != "да" ]; then
        log_info "Отменено пользователем"
        exit 0
    fi
fi

# Переменные
BOOT_DEVICE="${DISK}${BOOT_PART}"
POOL_DEVICE="${DISK}${POOL_PART}"
MOUNT_POINT="/mnt"
DEBIAN_RELEASE="bookworm"

# Для NVMe дисков корректируем имена
if [[ "$DISK" == *nvme* ]]; then
    BOOT_DEVICE="${DISK}p${BOOT_PART}"
    POOL_DEVICE="${DISK}p${POOL_PART}"
fi

log_info "Конфигурация:"
log_info "  Диск: $DISK"
log_info "  EFI раздел: $BOOT_DEVICE"
log_info "  ZFS раздел: $POOL_DEVICE"
log_info "  Пул: $POOL_NAME"
log_info "  Шифрование: $ENCRYPT"
log_info "  Hostname: $HOSTNAME"

###############################################################################
# Функции
###############################################################################

run_cmd() {
    if [ "$DRY_RUN" = true ]; then
        echo "[DRY-RUN] $*"
    else
        "$@"
    fi
}

install_packages() {
    log_step "Установка необходимых пакетов"
    
    run_cmd apt update
    run_cmd apt install -y \
        debootstrap \
        gdisk \
        dkms \
        "linux-headers-$(uname -r)" \
        zfsutils-linux \
        curl \
        dosfstools \
        efibootmgr
}

prepare_disk() {
    log_step "Подготовка диска $DISK"
    
    # Очистка старых разделов
    log_info "Очистка диска..."
    run_cmd zpool labelclear -f "$DISK" 2>/dev/null || true
    run_cmd wipefs -a "$DISK"
    run_cmd sgdisk --zap-all "$DISK"
    
    # Создание разделов
    log_info "Создание EFI раздела (${BOOT_SIZE})..."
    run_cmd sgdisk -n "${BOOT_PART}:1m:${BOOT_SIZE}" -t "${BOOT_PART}:ef00" "$DISK"
    
    log_info "Создание ZFS раздела (всё остальное пространство)..."
    run_cmd sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" "$DISK"
    
    # Обновление таблицы разделов
    run_cmd partprobe "$DISK" 2>/dev/null || true
    
    log_info "Разделы созданы:"
    run_cmd sgdisk -p "$DISK"
}

create_zfs_pool() {
    log_step "Создание ZFS пула $POOL_NAME"
    
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
            log_warn "Passphrase не указан, будет запрошен интерактивно"
            read -s -p "Введите passphrase для шифрования ZFS: " PASSPHRASE
            echo
        fi
        
        # Создание файла ключа
        log_info "Создание файла ключа..."
        echo "$PASSPHRASE" > /etc/zfs/${POOL_NAME}.key
        run_cmd chmod 000 /etc/zfs/${POOL_NAME}.key
        
        log_info "Создание зашифрованного пула..."
        run_cmd zpool create "${common_opts[@]}" \
            -O encryption=aes-256-gcm \
            -O keylocation=file:///etc/zfs/${POOL_NAME}.key \
            -O keyformat=passphrase \
            "$POOL_NAME" "$POOL_DEVICE"
    else
        log_info "Создание пула без шифрования..."
        run_cmd zpool create "${common_opts[@]}" \
            "$POOL_NAME" "$POOL_DEVICE"
    fi
    
    log_info "Пул создан:"
    run_cmd zpool status "$POOL_NAME"
}

create_datasets() {
    log_step "Создание ZFS датасетов"
    
    # ROOT dataset (контейнер)
    log_info "Создание zroot/ROOT..."
    run_cmd zfs create -o mountpoint=none ${POOL_NAME}/ROOT
    
    # Корневой датасет
    log_info "Создание zroot/ROOT/${DEBIAN_RELEASE}..."
    run_cmd zfs create -o mountpoint=/ -o canmount=noauto \
        ${POOL_NAME}/ROOT/${DEBIAN_RELEASE}
    
    # Home dataset
    log_info "Создание zroot/home..."
    run_cmd zfs create -o mountpoint=/home ${POOL_NAME}/home
    
    # Var-log dataset (опционально, для изоляции логов)
    log_info "Создание zroot/var-log..."
    run_cmd zfs create -o mountpoint=/var/log ${POOL_NAME}/var-log
    
    # Установка bootfs
    log_info "Установка bootfs..."
    run_cmd zpool set bootfs=${POOL_NAME}/ROOT/${DEBIAN_RELEASE} "$POOL_NAME"
    
    # Свойства для ZFSBootMenu
    log_info "Настройка свойств для ZFSBootMenu..."
    run_cmd zfs set org.zfsbootmenu:commandline="quiet loglevel=0" \
        ${POOL_NAME}/ROOT/${DEBIAN_RELEASE}
    
    if [ "$ENCRYPT" = true ]; then
        run_cmd zfs set org.zfsbootmenu:keysource="${POOL_NAME}/ROOT/${DEBIAN_RELEASE}" \
            ${POOL_NAME}
    fi
    
    log_info "Датасеты созданы:"
    run_cmd zfs list
}

mount_datasets() {
    log_step "Монтирование датасетов в $MOUNT_POINT"
    
    # Экспорт и импорт с новой точкой монтирования
    log_info "Экспорт пула..."
    run_cmd zpool export "$POOL_NAME"
    
    log_info "Импорт пула с mountpoint=$MOUNT_POINT..."
    run_cmd zpool import -N -R "$MOUNT_POINT" "$POOL_NAME"
    
    # Для шифрования нужно загрузить ключ
    if [ "$ENCRYPT" = true ]; then
        log_info "Загрузка ключа шифрования..."
        run_cmd zfs load-key -L file:///etc/zfs/${POOL_NAME}.key ${POOL_NAME}/ROOT/${DEBIAN_RELEASE}
    fi
    
    # Монтирование датасетов
    log_info "Монтирование ROOT..."
    run_cmd zfs mount ${POOL_NAME}/ROOT/${DEBIAN_RELEASE}
    
    log_info "Монтирование home..."
    run_cmd zfs mount ${POOL_NAME}/home
    
    log_info "Монтирование var-log..."
    run_cmd zfs mount ${POOL_NAME}/var-log
    
    # Проверка
    log_info "Смонтированные файловые системы:"
    run_cmd mount | grep "$MOUNT_POINT"
}

install_debian() {
    log_step "Установка Debian $DEBIAN_RELEASE через debootstrap"
    
    log_info "Запуск debootstrap (это может занять несколько минут)..."
    run_cmd debootstrap "$DEBIAN_RELEASE" "$MOUNT_POINT" \
        http://deb.debian.org/debian/
    
    log_info "Debian установлен в $MOUNT_POINT"
}

prepare_chroot() {
    log_step "Подготовка chroot окружения"
    
    # Копирование hostid
    log_info "Копирование ZFS hostid..."
    run_cmd cp /etc/hostid "$MOUNT_POINT/etc/hostid"
    
    # Копирование resolv.conf
    log_info "Копирование DNS конфигурации..."
    run_cmd cp /etc/resolv.conf "$MOUNT_POINT/etc/resolv.conf"
    
    # Копирование ключа шифрования
    if [ "$ENCRYPT" = true ]; then
        log_info "Копирование ключа шифрования..."
        run_cmd mkdir -p "$MOUNT_POINT/etc/zfs"
        run_cmd cp /etc/zfs/${POOL_NAME}.key "$MOUNT_POINT/etc/zfs/${POOL_NAME}.key"
        run_cmd chmod 000 "$MOUNT_POINT/etc/zfs/${POOL_NAME}.key"
    fi
    
    # Монтирование виртуальных ФС
    log_info "Монтирование proc, sys, dev..."
    run_cmd mount -t proc proc "$MOUNT_POINT/proc"
    run_cmd mount -t sysfs sys "$MOUNT_POINT/sys"
    run_cmd mount -B /dev "$MOUNT_POINT/dev"
    run_cmd mount -t devpts pts "$MOUNT_POINT/dev/pts"
    
    log_info "Chroot окружение готово"
}

configure_chroot() {
    log_step "Настройка системы в chroot"
    
    # Создаем скрипт для выполнения в chroot
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

# Настройка hostname
echo "$HOSTNAME_VAR" > /etc/hostname
echo "127.0.1.1	$HOSTNAME_VAR" >> /etc/hosts

# Настройка источников пакетов
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

# Обновление пакетов
apt update

# Установка локали и часового пояса
apt install -y locales keyboard-configuration console-setup tzdata
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

# Установка ядра и ZFS
apt install -y \
    linux-headers-amd64 \
    linux-image-amd64 \
    zfs-initramfs \
    dosfstools \
    efibootmgr \
    locales \
    keyboard-configuration \
    console-setup \
    openssh-server \
    sudo \
    curl \
    systemd-zram-generator

# Настройка DKMS для ZFS
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

# Включение служб ZFS
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target

# Для шифрования
if [ "$ENCRYPT_VAR" = "true" ]; then
    echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
fi

# Пересборка initramfs
update-initramfs -c -k all

# Настройка ZRAM (будет выполнена отдельным скриптом)
log_info "ZRAM настроен через systemd-zram-generator"

# Установка пароля root
echo "root:$ROOT_PASSWORD_VAR" | chpasswd

log_info "Chroot настройка завершена"
CHROOT_SCRIPT

    # Замена переменных
    sed -i "s/__HOSTNAME__/$HOSTNAME/g" "$chroot_script"
    sed -i "s/__ROOT_PASSWORD__/$ROOT_PASSWORD/g" "$chroot_script"
    sed -i "s/__ENCRYPT__/$ENCRYPT/g" "$chroot_script"
    sed -i "s/__POOL_NAME__/$POOL_NAME/g" "$chroot_script"
    
    # Копирование и выполнение
    run_cmd cp "$chroot_script" "$MOUNT_POINT/tmp/chroot-setup.sh"
    run_cmd chmod +x "$MOUNT_POINT/tmp/chroot-setup.sh"
    
    log_info "Выполнение настройки в chroot..."
    run_cmd chroot "$MOUNT_POINT" /bin/bash /tmp/chroot-setup.sh
    
    # Очистка
    run_cmd rm "$MOUNT_POINT/tmp/chroot-setup.sh"
    rm "$chroot_script"
}

setup_efi() {
    log_step "Настройка EFI System Partition"
    
    # Форматирование EFI раздела
    log_info "Форматирование $BOOT_DEVICE в FAT32..."
    run_cmd mkfs.vfat -F32 "$BOOT_DEVICE"
    
    # Получение UUID
    local BOOT_UUID
    BOOT_UUID=$(run_cmd blkid -s UUID -o value "$BOOT_DEVICE")
    
    # Создание fstab
    log_info "Настройка /etc/fstab..."
    cat > "$MOUNT_POINT/etc/fstab" << EOF
# EFI System Partition
UUID=${BOOT_UUID}  /boot/efi  vfat  defaults  0  0
EOF
    
    # Монтирование EFI
    log_info "Монтирование EFI раздела..."
    run_cmd mkdir -p "$MOUNT_POINT/boot/efi"
    run_cmd chroot "$MOUNT_POINT" mount /boot/efi
    
    log_info "EFI раздел настроен"
}

install_zfsbootmenu() {
    log_step "Установка ZFSBootMenu"
    
    # Создание директории
    log_info "Скачивание ZFSBootMenu EFI..."
    run_cmd chroot "$MOUNT_POINT" mkdir -p /boot/efi/EFI/ZBM
    
    # Скачивание EFI бинаря
    run_cmd chroot "$MOUNT_POINT" curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI \
        -L https://get.zfsbootmenu.org/efi
    
    # Резервная копия
    run_cmd chroot "$MOUNT_POINT" cp /boot/efi/EFI/ZBM/VMLINUZ.EFI \
        /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
    
    # Настройка EFI boot записей
    log_info "Создание EFI boot записей..."
    run_cmd efibootmgr -c -d "$DISK" -p "$BOOT_PART" \
        -L "ZFSBootMenu (Backup)" \
        -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'
    
    run_cmd efibootmgr -c -d "$DISK" -p "$BOOT_PART" \
        -L "ZFSBootMenu" \
        -l '\EFI\ZBM\VMLINUZ.EFI'
    
    log_info "ZFSBootMenu установлен"
}

configure_zram() {
    log_step "Настройка ZRAM"
    
    # Создание конфигурации systemd-zram-generator
    log_info "Создание конфигурации ZRAM..."
    run_cmd mkdir -p "$MOUNT_POINT/etc/systemd"
    
    cat > "$MOUNT_POINT/etc/systemd/zram-generator.conf" << 'EOF'
[zram0]
# Использовать 60% RAM или максимум 4GB
zram-size = min(ram * 0.6, 4096)
compression-algorithm = zstd
fs-type = swap
mount-point = none
EOF
    
    log_info "ZRAM конфигурация создана"
    log_info "Файл: /etc/systemd/zram-generator.conf"
}

finalize() {
    log_step "Завершение установки"
    
    # Выход из chroot
    log_info "Размонтирование файловых систем..."
    run_cmd umount -n -R "$MOUNT_POINT" || true
    
    # Экспорт пула
    log_info "Экспорт ZFS пула..."
    run_cmd zpool export "$POOL_NAME" || true
    
    log_info ""
    log_warn "═══════════════════════════════════════════════════════"
    log_warn "УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО!"
    log_warn "═══════════════════════════════════════════════════════"
    log_info ""
    log_info "Следующие шаги:"
    log_info "  1. Перезагрузите систему: reboot"
    log_info "  2. Извлеките Live USB"
    log_info "  3. В UEFI выберите 'ZFSBootMenu'"
    log_info "  4. Войдите в систему (root / $ROOT_PASSWORD)"
    log_info "  5. СМЕНите пароль: passwd"
    log_info ""
    if [ "$ENCRYPT" = true ]; then
        log_warn "ВНИМАНИЕ: При загрузке потребуется passphrase для ZFS!"
        log_info ""
    fi
    log_info "Полезные команды после загрузки:"
    log_info "  zpool status              # Проверка ZFS пула"
    log_info "  zfs list                  # Список датасетов"
    log_info "  zramctl                   # Проверка ZRAM"
    log_info "  efibootmgr -v             # EFI boot записи"
    log_info ""
    log_warn "НЕ ЗАБУДЬТЕ СМЕНИТЬ ПАРОЛЬ ROOT!"
    log_warn "═══════════════════════════════════════════════════════"
}

###############################################################################
# Основной процесс
###############################################################################

main() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Debian Bookworm ZFS Root Installation Script"
    log_info "Версия: 1.0 (Апрель 2026)"
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

# Запуск
main "$@"
