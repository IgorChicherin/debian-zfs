#!/bin/bash
###############################################################################
# test-vm.sh — Тестирование ISO/диска в QEMU
#
# Использование:
#   bash scripts/test-vm.sh [ISO_OR_DISK] [OPTIONS]
#
# Опции:
#   --iso FILE           Тестировать ISO файл
#   --disk DEV           Тестировать диск (ОПАСНО!)
#   --memory MB          RAM в MB (по умолчанию: 4096)
#   --cpus NUM           Количество CPU (по умолчанию: 4)
#   --uefi               Использовать UEFI (по умолчанию)
#   --bios               Использовать BIOS/Legacy
#   --snapshot           Режим снапшота (без записи на диск)
#   --help               Показать справку
#
# Примеры:
#   # Тестирование ISO
#   bash scripts/test-vm.sh output/debian-zfs-live.iso
#
#   # Тестирование диска
#   bash scripts/test-vm.sh --disk /dev/sdX
#
#   # Кастомная конфигурация
#   bash scripts/test-vm.sh test.iso --memory 8192 --cpus 8
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
ISO_FILE=""
DISK=""
MEMORY=4096
CPUS=4
UEFI=true
SNAPSHOT=false

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --iso) ISO_FILE="$2"; shift 2 ;;
        --disk) DISK="$2"; shift 2 ;;
        --memory) MEMORY="$2"; shift 2 ;;
        --cpus) CPUS="$2"; shift 2 ;;
        --uefi) UEFI=true; shift ;;
        --bios) UEFI=false; shift ;;
        --snapshot) SNAPSHOT=true; shift ;;
        --help)
            head -n 25 "$0" | tail -n +2 | sed 's/^# \?//'
            exit 0
            ;;
        -*)
            log_error "Неизвестный параметр: $1"
            exit 1
            ;;
        *)
            # Позиционный аргумент — ISO файл
            if [ -z "$ISO_FILE" ]; then
                ISO_FILE="$1"
            fi
            shift
            ;;
    esac
done

###############################################################################
# Проверки
###############################################################################

check_prerequisites() {
    log_step "Проверка предварительных условий"
    
    # Проверка QEMU
    if ! command -v qemu-system-x86_64 &>/dev/null; then
        log_error "QEMU не установлен!"
        log_info "Установите: sudo apt install qemu-system-x86 qemu-utils ovmf"
        exit 1
    fi
    
    # Проверка OVMF для UEFI
    if [ "$UEFI" = true ]; then
        local ovmf_found=false
        
        # Поиск OVMF файлов
        local ovmf_code_vars=(
            "/usr/share/OVMF/OVMF_CODE.fd"
            "/usr/share/ovmf/OVMF.fd"
            "/usr/share/qemu/ovmf-x86_64-code.fd"
        )
        
        local ovmf_vars=(
            "/usr/share/OVMF/OVMF_VARS.fd"
            "/usr/share/ovmf/OVMF_VARS.fd"
            "/usr/share/qemu/ovmf-x86_64-vars.fd"
        )
        
        OVMF_CODE=""
        OVMF_VARS=""
        
        for path in "${ovmf_code_vars[@]}"; do
            if [ -f "$path" ]; then
                OVMF_CODE="$path"
                break
            fi
        done
        
        for path in "${ovmf_vars[@]}"; do
            if [ -f "$path" ]; then
                OVMF_VARS="$path"
                break
            fi
        done
        
        if [ -z "$OVMF_CODE" ] || [ -z "$OVMF_VARS" ]; then
            log_warn "OVMF firmware не найден!"
            log_info "Установите: sudo apt install ovmf"
            log_info "Используйте --bios для загрузки без UEFI"
            read -p "Продолжить с --bios? (да/нет): " confirm
            if [ "$confirm" = "да" ]; then
                UEFI=false
            else
                exit 1
            fi
        fi
    fi
    
    # Проверка ISO/диска
    if [ -n "$ISO_FILE" ]; then
        if [ ! -f "$ISO_FILE" ]; then
            log_error "ISO файл не найден: $ISO_FILE"
            exit 1
        fi
        log_info "ISO файл: $ISO_FILE ✓"
    elif [ -n "$DISK" ]; then
        if [ ! -b "$DISK" ]; then
            log_error "Диск не найден: $DISK"
            exit 1
        fi
        log_warn "Диск: $DISK"
        log_warn "ВНИМАНИЕ: Убедитесь что это правильный диск!"
    else
        log_error "Укажите ISO файл или диск"
        exit 1
    fi
    
    log_info "QEMU установлен ✓"
    log_info "Память: ${MEMORY}MB"
    log_info "CPU: $CPUS"
}

###############################################################################
# Подготовка
###############################################################################

prepare_vars() {
    if [ "$UEFI" = true ] && [ "$SNAPSHOT" = false ]; then
        # Создание копии VARS для UEFI
        local temp_vars="/tmp/qemu-ovmf-vars-$$"
        cp "$OVMF_VARS" "$temp_vars"
        OVMF_VARS="$temp_vars"
        
        log_info "Временный OVMF VARS: $temp_vars"
    fi
}

###############################################################################
# Запуск QEMU
###############################################################################

run_qemu() {
    log_step "Запуск QEMU"
    
    log_info "Команда:"
    local cmd="qemu-system-x86_64"
    
    # Основные параметры
    local args=(
        "-enable-kvm"
        "-m" "$MEMORY"
        "-smp" "$CPUS"
        "-vga" "virtio"
        "-device" "virtio-balloon"
        "-usb"
        "-device" "usb-tablet"
        "-name" "Debian-ZFS-Test"
    )
    
    # UEFI или BIOS
    if [ "$UEFI" = true ]; then
        args+=(
            "-drive" "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
            "-drive" "if=pflash,format=raw,file=$OVMF_VARS"
            "-boot" "menu=on"
        )
        log_info "Режим: UEFI"
    else
        args+=(
            "-bios" "/usr/share/seabios/bios.bin"
            "-boot" "menu=on"
        )
        log_info "Режим: BIOS/Legacy"
    fi
    
    # ISO или диск
    if [ -n "$ISO_FILE" ]; then
        args+=(
            "-cdrom" "$ISO_FILE"
            "-boot" "d"
        )
        log_info "Загрузка с ISO"
    elif [ -n "$DISK" ]; then
        if [ "$SNAPSHOT" = true ]; then
            # Создание временного снапшота
            local snap_file="/tmp/qemu-disk-snap-$$"
            qemu-img create -f qcow2 -b "$DISK" -F raw "$snap_file" 2>/dev/null || \
            qemu-img create -f qcow2 "$snap_file" 50G
            
            args+=(
                "-drive" "file=$snap_file,format=qcow2,if=virtio"
            )
            log_info "Режим снапшота (без записи)"
        else
            args+=(
                "-drive" "file=$DISK,format=raw,if=virtio"
            )
            log_warn "Прямой доступ к диску (ЗАПИСЬ ВКЛЮЧЕНА!)"
        fi
    fi
    
    # Сеть
    args+=(
        "-netdev" "user,id=net0,hostname=debian-zfs-test"
        "-device" "virtio-net,netdev=net0"
    )
    
    # Вывод команды
    echo ""
    log_info "Полная команда:"
    echo "$cmd ${args[*]}"
    echo ""
    
    log_warn "═══════════════════════════════════════════════════════"
    log_warn "QEMU ЗАПУСКАЕТСЯ"
    log_warn "═══════════════════════════════════════════════════════"
    log_info ""
    log_info "Горячие клавиши QEMU:"
    log_info "  Ctrl+Alt+G      — Освободить мышь"
    log_info "  Ctrl+Alt+2      — Консоль мониторинга"
    log_info "  Ctrl+Alt+3      — serial0"
    log_info "  Ctrl+Alt+Del    — Перезагрузка"
    log_info "  Закрытие окна    — Выключение VM"
    log_info ""
    
    # Запуск
    "$cmd" "${args[@]}"
}

###############################################################################
# Очистка
###############################################################################

cleanup() {
    log_step "Очистка"
    
    # Удаление временных файлов
    if [ -f "/tmp/qemu-ovmf-vars-$$" ]; then
        rm -f "/tmp/qemu-ovmf-vars-$$"
        log_info "OVMF VARS удален"
    fi
    
    if [ -f "/tmp/qemu-disk-snap-$$" ]; then
        rm -f "/tmp/qemu-disk-snap-$$"
        log_info "Disk snapshot удален"
    fi
    
    log_info "Очистка завершена"
}

trap cleanup EXIT

###############################################################################
# Основной процесс
###############################################################################

main() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "QEMU VM Tester для Debian ZFS"
    log_info "Версия: 1.0 (Апрель 2026)"
    log_info "═══════════════════════════════════════════════════════"
    
    check_prerequisites
    prepare_vars
    run_qemu
}

main "$@"
