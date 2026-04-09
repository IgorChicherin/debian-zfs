#!/bin/bash
###############################################################################
# zram-config.sh — Настройка ZRAM сжатой подкачки
#
# Использование:
#   sudo bash zram-config.sh [OPTIONS]
#
# Опции:
#   --size SIZE         Размер ZRAM в MB или % RAM (по умолчанию: min(ram*0.6, 4096))
#   --algorithm ALG     Алгоритм сжатия (по умолчанию: zstd)
#   --swap              Использовать как swap (по умолчанию)
#   --filesystem FS     Использовать как файловую систему (ext4)
#   --remove            Удалить конфигурацию ZRAM
#   --status            Показать статус ZRAM
#   --help              Показать справку
#
# Примеры:
#   # Настройка по умолчанию (60% RAM, zstd, swap)
#   sudo bash zram-config.sh
#
#   # 8GB ZRAM с lz4
#   sudo bash zram-config.sh --size 8192 --algorithm lz4
#
#   # Проверить статус
#   sudo bash zram-config.sh --status
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
ZRAM_SIZE="min(ram * 0.6, 4096)"
ALGORITHM="zstd"
MODE="swap"
REMOVE_MODE=false
STATUS_MODE=false

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --size) ZRAM_SIZE="$2"; shift 2 ;;
        --algorithm) ALGORITHM="$2"; shift 2 ;;
        --swap) MODE="swap"; shift ;;
        --filesystem) MODE="fs"; shift ;;
        --remove) REMOVE_MODE=true; shift ;;
        --status) STATUS_MODE=true; shift ;;
        --help)
            head -n 30 "$0" | tail -n +2 | sed 's/^# \?//'
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
# Режим статуса
###############################################################################

show_status() {
    log_step "Статус ZRAM"
    
    echo ""
    log_info "ZRAM устройства:"
    if command -v zramctl &>/dev/null; then
        zramctl 2>/dev/null || log_warn "ZRAM устройства не активны"
    else
        log_warn "zramctl не установлен"
        log_info "Установите: apt install zram-tools"
    fi
    
    echo ""
    log_info "Swap устройства:"
    if command -v swapon &>/dev/null; then
        swapon --show 2>/dev/null || log_warn "Swap не активен"
    else
        log_warn "swapon не найден"
    fi
    
    echo ""
    log_info "Служба ZRAM:"
    if systemctl is-active dev-zram0.swap &>/dev/null; then
        log_info "dev-zram0.swap: активен ✓"
    else
        log_warn "dev-zram0.swap: не активен"
    fi
    
    echo ""
    log_info "Конфигурация:"
    if [ -f /etc/systemd/zram-generator.conf ]; then
        log_info "Файл: /etc/systemd/zram-generator.conf"
        cat /etc/systemd/zram-generator.conf
    else
        log_warn "Конфигурация не найдена"
    fi
    
    echo ""
    log_info "Память:"
    free -h
    
    exit 0
}

###############################################################################
# Режим удаления
###############################################################################

remove_config() {
    log_step "Удаление конфигурации ZRAM"
    
    # Отключение swap
    if [ -e /dev/zram0 ]; then
        log_info "Отключение ZRAM swap..."
        swapoff /dev/zram0 2>/dev/null || true
    fi
    
    # Остановка службы
    log_info "Остановка служб..."
    systemctl stop dev-zram0.swap 2>/dev/null || true
    
    # Удаление конфигурации
    if [ -f /etc/systemd/zram-generator.conf ]; then
        log_info "Удаление /etc/systemd/zram-generator.conf..."
        rm /etc/systemd/zram-generator.conf
    fi
    
    # Перезагрузка systemd
    log_info "Перезагрузка systemd..."
    systemctl daemon-reload
    
    log_info "ZRAM удален"
    exit 0
}

###############################################################################
# Установка ZRAM
###############################################################################

install_packages() {
    log_step "Установка пакетов"
    
    if ! command -v systemd-zram-setup &>/dev/null && [ ! -f /usr/lib/systemd/system-generators/zram-generator ]; then
        log_info "Установка systemd-zram-generator..."
        apt update
        apt install -y systemd-zram-generator
    else
        log_info "systemd-zram-generator уже установлен"
    fi
}

create_config() {
    log_step "Создание конфигурации ZRAM"
    
    local CONFIG_FILE="/etc/systemd/zram-generator.conf"
    
    # Проверка существующей конфигурации
    if [ -f "$CONFIG_FILE" ]; then
        log_warn "Конфигурация уже существует:"
        cat "$CONFIG_FILE"
        echo ""
        read -p "Перезаписать? (да/нет): " confirm
        if [ "$confirm" != "да" ]; then
            log_info "Отменено"
            exit 0
        fi
    fi
    
    log_info "Создание $CONFIG_FILE..."
    
    if [ "$MODE" = "swap" ]; then
        cat > "$CONFIG_FILE" << EOF
[zram0]
# Размер: $ZRAM_SIZE
zram-size = $ZRAM_SIZE
compression-algorithm = $ALGORITHM
fs-type = swap
mount-point = none
EOF
    else
        cat > "$CONFIG_FILE" << EOF
[zram0]
# Размер: $ZRAM_SIZE (файловая система)
zram-size = $ZRAM_SIZE
compression-algorithm = $ALGORITHM
fs-type = ext4
mount-point = /var/compressed
EOF
    fi
    
    log_info "Конфигурация создана:"
    cat "$CONFIG_FILE"
}

activate_zram() {
    log_step "Активация ZRAM"
    
    # Перезагрузка systemd
    log_info "Перезагрузка systemd daemon..."
    systemctl daemon-reload
    
    # Запуск ZRAM
    if [ "$MODE" = "swap" ]; then
        log_info "Запуск ZRAM swap..."
        systemctl start dev-zram0.swap
        
        # Проверка
        sleep 2
        if systemctl is-active dev-zram0.swap &>/dev/null; then
            log_info "ZRAM swap активен ✓"
        else
            log_error "Не удалось активировать ZRAM swap"
            log_info "Проверьте логи: journalctl -xeu dev-zram0.swap"
            exit 1
        fi
    else
        log_info "Для режима файловой системы создайте точку монтирования:"
        log_info "  mkdir -p /var/compressed"
        log_info "  systemctl start var-compressed.mount"
    fi
}

verify_zram() {
    log_step "Проверка ZRAM"
    
    echo ""
    log_info "ZRAM устройства:"
    zramctl
    
    echo ""
    log_info "Swap:"
    swapon --show
    
    echo ""
    log_info "Использование памяти:"
    free -h
    
    echo ""
    log_info "Служба:"
    systemctl status dev-zram0.swap --no-pager -l || true
}

###############################################################################
# Основной процесс
###############################################################################

main() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "ZRAM Configuration Script"
    log_info "Версия: 1.0 (Апрель 2026)"
    log_info "═══════════════════════════════════════════════════════"
    
    # Режим статуса
    if [ "$STATUS_MODE" = true ]; then
        show_status
    fi
    
    # Режим удаления
    if [ "$REMOVE_MODE" = true ]; then
        remove_config
    fi
    
    # Основная установка
    install_packages
    create_config
    activate_zram
    verify_zram
    
    log_info ""
    log_warn "═══════════════════════════════════════════════════════"
    log_warn "ZRAM НАСТРОЕН УСПЕШНО!"
    log_warn "═══════════════════════════════════════════════════════"
    log_info ""
    log_info "Конфигурация:"
    log_info "  Размер: $ZRAM_SIZE"
    log_info "  Алгоритм: $ALGORITHM"
    log_info "  Режим: $MODE"
    log_info ""
    log_info "Файл конфигурации:"
    log_info "  /etc/systemd/zram-generator.conf"
    log_info ""
    log_info "Полезные команды:"
    log_info "  zramctl                 # Информация о ZRAM"
    log_info "  swapon --show           # Swap устройства"
    log_info "  systemctl status dev-zram0.swap  # Статус службы"
    log_info "  free -h                 # Использование памяти"
    log_info ""
}

main "$@"
