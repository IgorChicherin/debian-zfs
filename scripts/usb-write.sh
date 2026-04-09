#!/bin/bash
###############################################################################
# usb-write.sh — Запись ISO на USB-накопитель
#
# Использование:
#   sudo bash scripts/usb-write.sh /dev/sdX
#
# ВАЖНО: Убедитесь что указали правильный диск!
# Все данные на диске будут УНИЧТОЖЕНЫ!
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

# Параметры
USB_DEVICE="${1:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
ISO_FILE="${2:-$PROJECT_DIR/output/debian-zfs-live.iso}"

# Проверка
if [ -z "$USB_DEVICE" ]; then
    log_error "Укажите USB устройство!"
    log_info "Использование: sudo bash scripts/usb-write.sh /dev/sdX [ISO_FILE]"
    log_info ""
    log_info "Доступные диски:"
    lsblk -dn -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v loop
    exit 1
fi

# Проверка root
if [ "$(id -u)" -ne 0 ]; then
    log_error "Запустите скрипт от имени root (sudo)"
    exit 1
fi

# Проверка устройства
if [ ! -b "$USB_DEVICE" ]; then
    log_error "Устройство не найдено: $USB_DEVICE"
    log_info "Доступные диски:"
    lsblk -dn -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v loop
    exit 1
fi

# Проверка ISO
if [ ! -f "$ISO_FILE" ]; then
    log_error "ISO файл не найден: $ISO_FILE"
    exit 1
fi

# Предупреждение
log_warn "═══════════════════════════════════════════════════════"
log_warn "ВНИМАНИЕ!"
log_warn "═══════════════════════════════════════════════════════"
log_warn ""
log_warn "Диск: $USB_DEVICE"
log_warn "Размер: $(lsblk -dn -o SIZE "$USB_DEVICE")"
log_warn ""
log_warn "Все данные на этом диске будут УНИЧТОЖЕНЫ!"
log_warn ""

# Проверка что это не системный диск
if mount | grep -q "$USB_DEVICE"; then
    log_error "Устройство смонтировано! Размонтируйте перед записью"
    exit 1
fi

# Проверка что это не корневой диск
ROOT_DEV=$(df / | tail -1 | cut -d' ' -f1)
if [ "$USB_DEVICE" = "$ROOT_DEV" ]; then
    log_error "Нельзя записывать на корневой диск!"
    exit 1
fi

read -p "Продолжить? (да/нет): " confirm
if [ "$confirm" != "да" ]; then
    log_info "Отменено"
    exit 0
fi

# Размонтирование
log_step "Размонтирование устройства..."
umount "$USB_DEVICE"* 2>/dev/null || true
log_info "Устройство размонтировано"

# Запись
log_step "Запись ISO на $USB_DEVICE..."
log_info "Источник: $ISO_FILE"
log_info "Размер ISO: $(du -h "$ISO_FILE" | cut -f1)"
log_info ""

# Используем dd с прогрессом
if dd --version 2>&1 | grep -q "status=progress"; then
    dd if="$ISO_FILE" of="$USB_DEVICE" bs=4M status=progress oflag=sync
else
    # Альтернатива без status=progress
    dd if="$ISO_FILE" of="$USB_DEVICE" bs=4M oflag=sync &
    DD_PID=$!

    # Прогресс
    while kill -0 $DD_PID 2>/dev/null; do
        sleep 2
        written=$(cat /proc/$DD_PID/io 2>/dev/null | grep write | awk '{print $2}' || echo "0")
        if [ "$written" != "0" ]; then
            echo -ne "\rЗаписано: $(numfmt --to=iec $written 2>/dev/null || echo "${written}B")"
        fi
    done
    wait $DD_PID
    echo ""
fi

# Синхронизация
log_step "Синхронизация..."
sync

# Готово
log_info ""
log_warn "═══════════════════════════════════════════════════════"
log_warn "USB НАКОПИТЕЛЬ ГОТОВ!"
log_warn "═══════════════════════════════════════════════════════"
log_info ""
log_info "Теперь вы можете:"
log_info "  1. Загрузиться с USB на целевой машине"
log_info "  2. Выполнить установку Debian на ZFS"
log_info "  3. Протестировать в QEMU:"
log_info "     bash scripts/test-vm.sh --disk $USB_DEVICE"
log_info ""
