#!/bin/bash
###############################################################################
# zfsbootmenu-setup.sh — Настройка ZFSBootMenu на существующей системе
#
# Использование:
#   sudo bash zfsbootmenu-setup.sh [OPTIONS]
#
# Опции:
#   --pool NAME         Имя ZFS пула (по умолчанию: zroot)
#   --dataset NAME      ROOT датасет (по умолчанию: ROOT/bookworm)
#   --boot-device DEV   EFI раздел (по умолчанию: /dev/sda1)
#   --boot-disk DEV     Диск с EFI (по умолчанию: /dev/sda)
#   --boot-part NUM     Номер раздела EFI (по умолчанию: 1)
#   --update            Обновить существующую установку
#   --help              Показать справку
#
# Примечание: Запускайте ИЗ live-среды или установленной системы
###############################################################################

set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}[STEP]${NC} $1"; }

# Параметры
POOL_NAME="zroot"
ROOT_DATASET="ROOT/bookworm"
BOOT_DEVICE="/dev/sda1"
BOOT_DISK="/dev/sda"
BOOT_PART="1"
UPDATE_MODE=false

# Парсинг аргументов
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
        *) log_error "Неизвестный параметр: $1"; exit 1 ;;
    esac
done

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Запустите скрипт от имени root (sudo)"
    exit 1
fi

###############################################################################
# Проверки
###############################################################################

check_prerequisites() {
    log_step "Проверка предварительных условий"
    
    # Проверка пула
    if ! zpool list "$POOL_NAME" &>/dev/null; then
        log_error "Пул $POOL_NAME не найден!"
        log_info "Доступные пулы:"
        zpool list
        exit 1
    fi
    
    # Проверка датасета
    if ! zfs list "$POOL_NAME/$ROOT_DATASET" &>/dev/null; then
        log_error "Датасет $POOL_NAME/$ROOT_DATASET не найден!"
        log_info "Доступные датасеты:"
        zfs list
        exit 1
    fi
    
    # Проверка boot устройства
    if [ ! -b "$BOOT_DEVICE" ]; then
        log_warn "Устройство $BOOT_DEVICE не найдено"
        log_info "Укажите правильное устройство через --boot-device"
        log_info "Текущие разделы:"
        lsblk -ln -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v loop
        read -p "Продолжить с указанным устройством? (да/нет): " confirm
        if [ "$confirm" != "да" ]; then
            exit 1
        fi
    fi
    
    log_info "Пул: $POOL_NAME ✓"
    log_info "Датасет: $POOL_NAME/$ROOT_DATASET ✓"
    log_info "EFI устройство: $BOOT_DEVICE"
}

###############################################################################
# Настройка ZFSBootMenu
###############################################################################

set_dataset_properties() {
    log_step "Настройка свойств датасетов"
    
    # Установка commandline для ZFSBootMenu
    log_info "Установка org.zfsbootmenu:commandline..."
    zfs set org.zfsbootmenu:commandline="quiet loglevel=0" \
        "$POOL_NAME/$ROOT_DATASET"
    
    # Проверка шифрования
    local encryption
    encryption=$(zfs get -H -o value encryption "$POOL_NAME/$ROOT_DATASET" 2>/dev/null || echo "off")
    
    if [ "$encryption" != "off" ]; then
        log_info "Обнаружено шифрование, настройка keysource..."
        zfs set org.zfsbootmenu:keysource="$POOL_NAME/$ROOT_DATASET" \
            "$POOL_NAME"
    fi
    
    log_info "Свойства установлены"
    zfs get org.zfsbootmenu:commandline "$POOL_NAME/$ROOT_DATASET"
}

mount_efi() {
    log_step "Монтирование EFI System Partition"
    
    # Проверка монтирования
    if mount | grep -q "/boot/efi"; then
        log_info "EFI уже смонтирован в /boot/efi"
        return 0
    fi
    
    # Создание fstab записи если не существует
    if ! grep -q "/boot/efi" /etc/fstab; then
        log_info "Добавление записи в /etc/fstab..."
        local BOOT_UUID
        BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEVICE" 2>/dev/null || echo "")
        
        if [ -n "$BOOT_UUID" ]; then
            echo "UUID=${BOOT_UUID}  /boot/efi  vfat  defaults  0  0" >> /etc/fstab
        else
            echo "${BOOT_DEVICE}  /boot/efi  vfat  defaults  0  0" >> /etc/fstab
        fi
    fi
    
    # Монтирование
    log_info "Монтирование /boot/efi..."
    mkdir -p /boot/efi
    mount /boot/efi
    
    log_info "EFI смонтирован"
}

download_zfsbootmenu() {
    log_step "Установка ZFSBootMenu"
    
    local ZBM_DIR="/boot/efi/EFI/ZBM"
    
    # Создание директории
    mkdir -p "$ZBM_DIR"
    
    if [ "$UPDATE_MODE" = true ] && [ -f "$ZBM_DIR/VMLINUZ.EFI" ]; then
        log_info "Режим обновления — создаю резервную копию..."
        cp "$ZBM_DIR/VMLINUZ.EFI" "$ZBM_DIR/VMLINUZ-OLD.EFI"
    fi
    
    # Скачивание EFI бинаря
    log_info "Скачивание ZFSBootMenu EFI..."
    curl -o "$ZBM_DIR/VMLINUZ.EFI" -L https://get.zfsbootmenu.org/efi
    
    # Создание резервной копии
    log_info "Создание резервной копии..."
    cp "$ZBM_DIR/VMLINUZ.EFI" "$ZBM_DIR/VMLINUZ-BACKUP.EFI"
    
    # Проверка
    local size
    size=$(stat -f%z "$ZBM_DIR/VMLINUZ.EFI" 2>/dev/null || stat -c%s "$ZBM_DIR/VMLINUZ.EFI")
    log_info "Размер VMLINUZ.EFI: $size байт"
    
    # Проверка версии
    if strings "$ZBM_DIR/VMLINUZ.EFI" | grep -q -i zfsbootmenu; then
        log_info "ZFSBootMenu EFI проверен ✓"
    else
        log_warn "Не удалось проверить EFI файл — возможно поврежден"
    fi
}

create_efi_entries() {
    log_step "Создание EFI boot записей"
    
    # Проверка efivarfs
    if ! mount | grep -q efivarfs; then
        log_info "Монтирование efivarfs..."
        mount -t efivarfs efivarfs /sys/firmware/efi/efivars 2>/dev/null || true
    fi
    
    # Удаление старых записей (если обновление)
    if [ "$UPDATE_MODE" = true ]; then
        log_info "Удаление старых записей ZFSBootMenu..."
        efibootmgr | grep "ZFSBootMenu" | awk '{print $1}' | sed 's/Boot//;s/\*//' | while read num; do
            efibootmgr -B -b "$num" 2>/dev/null || true
        done
    fi
    
    # Создание резервной записи
    log_info "Создание записи ZFSBootMenu (Backup)..."
    efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
        -L "ZFSBootMenu (Backup)" \
        -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'
    
    # Создание основной записи
    log_info "Создание записи ZFSBootMenu..."
    efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" \
        -L "ZFSBootMenu" \
        -l '\EFI\ZBM\VMLINUZ.EFI'
    
    # Установка порядка загрузки
    log_info "Настройка порядка загрузки..."
    local current_boot
    current_boot=$(efibootmgr | grep "BootCurrent:" | awk '{print $2}')
    
    log_info "Текущий BootCurrent: $current_boot"
    
    # Показать все записи
    log_info "EFI boot записи:"
    efibootmgr -v
}

install_from_source() {
    log_step "Установка ZFSBootMenu из исходников (опционально)"
    
    log_warn "Этот метод требует дополнительных зависимостей"
    read -p "Продолжить установку из исходников? (да/нет): " confirm
    if [ "$confirm" != "да" ]; then
        log_info "Пропуск — используется prebuilt EFI"
        return 0
    fi
    
    # Установка зависимостей
    log_info "Установка зависимостей..."
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
    
    # Скачивание исходников
    log_info "Скачивание ZFSBootMenu..."
    mkdir -p /usr/local/src/zfsbootmenu
    cd /usr/local/src/zfsbootmenu
    curl -L https://get.zfsbootmenu.org/source | tar -zxv --strip-components=1 -f -
    
    # Сборка
    log_info "Сборка ZFSBootMenu..."
    make core dracut
    
    # Генерация образа
    log_info "Генерация ZFSBootMenu образа..."
    generate-zbm
    
    log_info "Установка из исходников завершена"
}

configure_zfsbootmenu() {
    log_step "Создание конфигурации ZFSBootMenu"
    
    local CONFIG_DIR="/etc/zfsbootmenu"
    local CONFIG_FILE="$CONFIG_DIR/config.yaml"
    
    if [ -f "$CONFIG_FILE" ] && [ "$UPDATE_MODE" = false ]; then
        log_warn "Конфигурация уже существует"
        read -p "Перезаписать? (да/нет): " confirm
        if [ "$confirm" != "да" ]; then
            log_info "Пропуск"
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
    
    log_info "Конфигурация создана: $CONFIG_FILE"
    
    # Создание директорий для hooks
    mkdir -p /etc/zfsbootmenu/generation.d
    mkdir -p /etc/zfsbootmenu/post-generation.d
    
    log_info "Директории для hooks созданы"
}

generate_image() {
    log_step "Генерация ZFSBootMenu образа"
    
    # Проверка generate-zbm
    if ! command -v generate-zbm &>/dev/null; then
        log_warn "generate-zbm не найден"
        log_info "Образ уже готов (prebuilt EFI)"
        return 0
    fi
    
    log_info "Генерация..."
    generate-zbm
    
    log_info "Образ сгенерирован"
}

###############################################################################
# Основной процесс
###############################################################################

main() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "ZFSBootMenu Setup Script"
    log_info "Версия: 1.0 (Апрель 2026)"
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
    log_warn "ZFSBootMenu НАСТРОЕН УСПЕШНО!"
    log_warn "═══════════════════════════════════════════════════════"
    log_info ""
    log_info "EFI файлы:"
    log_info "  /boot/efi/EFI/ZBM/VMLINUZ.EFI"
    log_info "  /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI"
    log_info ""
    log_info "EFI Boot записи созданы для:"
    log_info "  Диск: $BOOT_DISK"
    log_info "  Раздел: $BOOT_PART"
    log_info ""
    log_info "Использование:"
    log_info "  ESC при загрузке — меню ZFSBootMenu"
    log_info "  Ctrl+K — выбор ядра/снапшота"
    log_info "  Ctrl+D — установить по умолчанию"
    log_info ""
    log_info "Проверка:"
    log_info "  efibootmgr -v"
    log_info "  strings /boot/efi/EFI/ZBM/VMLINUZ.EFI | grep -i zfsbootmenu"
    log_info ""
}

main "$@"
