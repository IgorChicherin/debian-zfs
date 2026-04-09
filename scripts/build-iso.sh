#!/bin/bash
###############################################################################
# build-iso.sh — Сборка кастомного Debian Live ISO с ZFS
#
# Использование:
#   sudo bash scripts/build-iso.sh [OPTIONS]
#
# Опции:
#   --clean               Очистить предыдущие сборки
#   --debug               Режим отладки
#   --output-dir DIR      Директория вывода (по умолчанию: output)
#   --help                Показать справку
#
# Требования:
#   - Debian Bookworm или новее
#   - Пакет live-build
#   - Минимум 10GB свободного места
#   - Root права
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
CLEAN_MODE=false
DEBUG_MODE=false
OUTPUT_DIR="output"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LB_CONFIG_DIR="$PROJECT_DIR/config/live-build"

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --clean) CLEAN_MODE=true; shift ;;
        --debug) DEBUG_MODE=true; set -x; shift ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --help)
            head -n 20 "$0" | tail -n +2 | sed 's/^# \?//'
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

    # Проверка файловой системы (WSL /mnt/ проблемы)
    local work_dir_path
    work_dir_path="$(pwd)"
    if echo "$work_dir_path" | grep -q '^/mnt/'; then
        log_warn "Обнаружена работа из WSL на смонтированной файловой системе (/mnt/)"
        log_warn "Сборка live-build на NTFS/DrvFs может завершиться с ошибкой tar"
        log_info "Рекомендуется скопировать проект в нативную файловую систему Linux:"
        log_info "  cp -r $work_dir_path ~/debian-zfs && cd ~/debian-zfs"
        read -p "Продолжить несмотря на это? (да/нет): " fs_confirm
        if [ "$fs_confirm" != "да" ]; then
            log_info "Сборка отменена"
            exit 0
        fi
    fi

    # Проверка live-build
    if ! command -v lb &>/dev/null && ! command -v live-build &>/dev/null; then
        log_warn "live-build не установлен"
        read -p "Установить live-build? (да/нет): " confirm
        if [ "$confirm" = "да" ]; then
            DEBIAN_FRONTEND=noninteractive apt update
            DEBIAN_FRONTEND=noninteractive apt install -y live-build
        else
            log_error "live-build необходим для сборки"
            exit 1
        fi
    fi
    
    # Проверка места
    local available_space
    available_space=$(df -BM . | awk 'NR==2 {print $4}' | tr -d 'M')
    available_space=$((available_space / 1024))

    if [ "$available_space" -lt 10 ]; then
        log_error "Недостаточно места! Требуется минимум 10GB"
        log_info "Доступно: ${available_space}GB"
        exit 1
    fi
    
    log_info "live-build установлен ✓"
    log_info "Доступно места: ${available_space}GB ✓"
}

###############################################################################
# Очистка
###############################################################################

clean_previous() {
    if [ "$CLEAN_MODE" = true ]; then
        log_step "Очистка предыдущих сборок"
        
        # Очистка live-build
        if [ -d auto ]; then
            lb clean
        fi
        
        # Удаление выходной директории
        if [ -d "$OUTPUT_DIR" ]; then
            log_info "Удаление $OUTPUT_DIR..."
            rm -rf "$OUTPUT_DIR"
        fi
        
        log_info "Очистка завершена"
    fi
}

###############################################################################
# Настройка live-build
###############################################################################

setup_live_build() {
    log_step "Настройка live-build"

    # Создание рабочей директории
    local work_dir="live-build-work"
    mkdir -p "$work_dir"
    cd "$work_dir"

    # Всегда заново инициализируем чтобы избежать конфликтов конфигурации
    if [ -d auto ]; then
        log_info "Очистка предыдущей конфигурации..."
        lb clean 2>/dev/null || true
        rm -rf auto config
    fi

    # Очистка кеша debootstrap (частая причина tar ошибок)
    if [ -d cache ]; then
        log_info "Очистка кеша debootstrap..."
        rm -rf cache
    fi

    log_info "Инициализация live-build с параметрами bookworm..."

    # Инициализация с явными параметрами (избегаем проблем с auto/config)
    lb config \
        --architecture amd64 \
        --distribution bookworm \
        --archive-areas "main contrib non-free non-free-firmware" \
        --linux-flavours amd64 \
        2>&1 | tee -a build.log

    # Включаем backports (нет параметра командной строки, модифицируем файл)
    log_info "Включение backports..."
    sed -i 's/LB_BACKPORTS="false"/LB_BACKPORTS="true"/g' config/chroot

    # Проверка конфигурации
    log_info "Проверка конфигурации:"
    grep "LB_DISTRIBUTION=" config/bootstrap | head -1
    grep "LB_ARCHIVE_AREAS=" config/bootstrap | head -1
    grep "LB_BACKPORTS=" config/chroot | head -1

    # Копирование конфигурации
    log_info "Копирование конфигурации..."
    
    # Package lists
    if [ -d "$LB_CONFIG_DIR/package-lists" ]; then
        mkdir -p config/package-lists
        cp "$LB_CONFIG_DIR"/package-lists/*.chroot config/package-lists/
        log_info "Package lists скопированы"
    fi
    
    # Includes
    if [ -d "$LB_CONFIG_DIR/includes.chroot" ]; then
        mkdir -p config/includes.chroot
        cp -r "$LB_CONFIG_DIR"/includes.chroot/* config/includes.chroot/
        log_info "Includes скопированы"
    fi

    log_info "Конфигурация live-build готова"
}

###############################################################################
# Сборка
###############################################################################

build_iso() {
    log_step "Сборка ISO"

    mkdir -p "$PROJECT_DIR/$OUTPUT_DIR"

    log_info "Запуск сборки (это может занять 20-40 минут)..."
    log_info "Лог сохраняется в build.log"

    # Запуск сборки (use pipefail-safe pattern)
    local build_status=0
    lb build > build.log 2>&1 || build_status=$?

    if [ "$build_status" -ne 0 ]; then
        log_error "Сборка не удалась! (exit code: $build_status)"
        log_info "Последние 50 строк из build.log:"
        tail -n 50 build.log
        exit 1
    fi

    log_info "Сборка завершена успешно ✓"

    # Копирование ISO (check multiple possible locations/patterns)
    local iso_file=""

    # Try common patterns: live-image-*.iso, binary.iso, or any .iso
    for pattern in "live-image-*.iso" "binary.iso" "*.iso"; do
        if ls $pattern 1>/dev/null 2>&1; then
            iso_file=$(ls -t $pattern 2>/dev/null | head -n 1)
            break
        fi
    done

    if [ -z "$iso_file" ]; then
        # Deep search in subdirectories
        iso_file=$(find . -name "*.iso" -type f 2>/dev/null | head -n 1)
    fi

    if [ -n "$iso_file" ]; then
        cp "$iso_file" "$PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso"

        log_info "ISO скопирован:"
        log_info "  $PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso"

        # Размер
        local size
        size=$(du -h "$PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso" | cut -f1)
        log_info "Размер: $size"
    else
        log_error "ISO файл не найдено!"
        log_info "Содержимое текущей директории:"
        ls -la
        log_info "Проверьте build.log для деталей"
        exit 1
    fi
}

###############################################################################
# Пост-обработка
###############################################################################

post_build() {
    log_step "Пост-обработка"

    # Создание SHA256
    if [ -f "$PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso" ]; then
        log_info "Создание SHA256 хеша..."
        (cd "$PROJECT_DIR/$OUTPUT_DIR" && sha256sum debian-zfs-live.iso > debian-zfs-live.iso.sha256)
        log_info "Хеш создан:"
        cat "$PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso.sha256"
    fi

    # Очистка рабочей директории
    local work_dir="$PROJECT_DIR/live-build-work"
    log_warn "Рабочая директория сохранена для отладки:"
    log_warn "  $work_dir"
    log_info "Для удаления: rm -rf $work_dir"
}

###############################################################################
# Основной процесс
###############################################################################

main() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "Debian ZFS Live ISO Builder"
    log_info "Версия: 1.0 (Апрель 2026)"
    log_info "═══════════════════════════════════════════════════════"
    
    check_prerequisites
    clean_previous
    setup_live_build
    build_iso
    post_build
    
    log_info ""
    log_warn "═══════════════════════════════════════════════════════"
    log_warn "ISO СОБРАН УСПЕШНО!"
    log_warn "═══════════════════════════════════════════════════════"
    log_info ""
    log_info "ISO файл:"
    log_info "  $PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso"
    log_info ""
    log_info "Следующие шаги:"
    log_info "  1. Запишите на USB:"
    log_info "     sudo dd if=$PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso of=/dev/sdX bs=4M status=progress"
    log_info ""
    log_info "  2. Или используйте скрипт:"
    log_info "     sudo bash scripts/usb-write.sh /dev/sdX"
    log_info ""
    log_info "  3. Протестируйте в QEMU:"
    log_info "     bash scripts/test-vm.sh $PROJECT_DIR/$OUTPUT_DIR/debian-zfs-live.iso"
    log_info ""
}

main "$@"
