#!/bin/bash
###############################################################################
# test-vm.sh — ISO/disk testing in QEMU
#
# Usage:
#   bash scripts/test-vm.sh [ISO_OR_DISK] [OPTIONS]
#
# Options:
#   --iso FILE           Test ISO file
#   --disk DEV           Test disk (DANGEROUS!)
#   --memory MB          RAM in MB (default: 4096)
#   --cpus NUM           Number of CPUs (default: 4)
#   --uefi               Use UEFI (default)
#   --bios               Use BIOS/Legacy
#   --snapshot           Snapshot mode (no disk writes)
#   --help               Show help
#
# Examples:
#   # Test ISO
#   bash scripts/test-vm.sh output/debian-zfs-live.iso
#
#   # Test disk
#   bash scripts/test-vm.sh --disk /dev/sdX
#
#   # Custom configuration
#   bash scripts/test-vm.sh test.iso --memory 8192 --cpus 8
###############################################################################

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "\n${BLUE}[STEP]${NC} $1"; }

# Parameters
ISO_FILE=""
DISK=""
MEMORY=4096
CPUS=4
UEFI=true
SNAPSHOT=false

# Argument parsing
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
            log_error "Unknown parameter: $1"
            exit 1
            ;;
        *)
            # Positional argument — ISO file
            if [ -z "$ISO_FILE" ]; then
                ISO_FILE="$1"
            fi
            shift
            ;;
    esac
done

###############################################################################
# Checks
###############################################################################

check_prerequisites() {
    log_step "Checking prerequisites"

    # Check QEMU
    if ! command -v qemu-system-x86_64 &>/dev/null; then
        log_error "QEMU not installed!"
        log_info "Install with: sudo apt install qemu-system-x86 qemu-utils ovmf"
        exit 1
    fi

    # Check OVMF for UEFI
    if [ "$UEFI" = true ]; then
        local ovmf_found=false

        # Search for OVMF files
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
            log_warn "OVMF firmware not found!"
            log_info "Install with: sudo apt install ovmf"
            log_info "Use --bios for non-UEFI boot"
            read -p "Continue with --bios? (yes/no): " confirm
            if [ "$confirm" = "yes" ]; then
                UEFI=false
            else
                exit 1
            fi
        fi
    fi

    # Check ISO/disk
    if [ -n "$ISO_FILE" ]; then
        if [ ! -f "$ISO_FILE" ]; then
            log_error "ISO file not found: $ISO_FILE"
            exit 1
        fi
        log_info "ISO file: $ISO_FILE ✓"
    elif [ -n "$DISK" ]; then
        if [ ! -b "$DISK" ]; then
            log_error "Disk not found: $DISK"
            exit 1
        fi
        log_warn "Disk: $DISK"
        log_warn "WARNING: Make sure this is the correct disk!"
    else
        log_error "Specify ISO file or disk"
        exit 1
    fi

    log_info "QEMU installed ✓"
    log_info "Memory: ${MEMORY}MB"
    log_info "CPU: $CPUS"
}

###############################################################################
# Preparation
###############################################################################

prepare_vars() {
    if [ "$UEFI" = true ] && [ "$SNAPSHOT" = false ]; then
        # Create VARS copy for UEFI
        local temp_vars="/tmp/qemu-ovmf-vars-$$"
        cp "$OVMF_VARS" "$temp_vars"
        OVMF_VARS="$temp_vars"

        log_info "Temporary OVMF VARS: $temp_vars"
    fi
}

###############################################################################
# Run QEMU
###############################################################################

run_qemu() {
    log_step "Starting QEMU"

    log_info "Command:"
    local cmd="qemu-system-x86_64"

    # Main parameters
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

    # UEFI or BIOS
    if [ "$UEFI" = true ]; then
        args+=(
            "-drive" "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
            "-drive" "if=pflash,format=raw,file=$OVMF_VARS"
            "-boot" "menu=on"
        )
        log_info "Mode: UEFI"
    else
        args+=(
            "-bios" "/usr/share/seabios/bios.bin"
            "-boot" "menu=on"
        )
        log_info "Mode: BIOS/Legacy"
    fi

    # ISO or disk
    if [ -n "$ISO_FILE" ]; then
        args+=(
            "-cdrom" "$ISO_FILE"
            "-boot" "d"
        )
        log_info "Booting from ISO"
    elif [ -n "$DISK" ]; then
        if [ "$SNAPSHOT" = true ]; then
            # Create temporary snapshot
            local snap_file="/tmp/qemu-disk-snap-$$"
            qemu-img create -f qcow2 -b "$DISK" -F raw "$snap_file" 2>/dev/null || \
            qemu-img create -f qcow2 "$snap_file" 50G

            args+=(
                "-drive" "file=$snap_file,format=qcow2,if=virtio"
            )
            log_info "Snapshot mode (no writes)"
        else
            args+=(
                "-drive" "file=$DISK,format=raw,if=virtio"
            )
            log_warn "Direct disk access (WRITES ENABLED!)"
        fi
    fi

    # Network
    args+=(
        "-netdev" "user,id=net0,hostname=debian-zfs-test"
        "-device" "virtio-net,netdev=net0"
    )

    # Show command
    echo ""
    log_info "Full command:"
    echo "$cmd ${args[*]}"
    echo ""

    log_warn "═══════════════════════════════════════════════════════"
    log_warn "QEMU STARTING"
    log_warn "═══════════════════════════════════════════════════════"
    log_info ""
    log_info "QEMU hotkeys:"
    log_info "  Ctrl+Alt+G      — Release mouse"
    log_info "  Ctrl+Alt+2      — Monitor console"
    log_info "  Ctrl+Alt+3      — serial0"
    log_info "  Ctrl+Alt+Del    — Reboot"
    log_info "  Close window     — Power off VM"
    log_info ""

    # Run
    "$cmd" "${args[@]}"
}

###############################################################################
# Cleanup
###############################################################################

cleanup() {
    log_step "Cleanup"

    # Remove temporary files
    if [ -f "/tmp/qemu-ovmf-vars-$$" ]; then
        rm -f "/tmp/qemu-ovmf-vars-$$"
        log_info "OVMF VARS removed"
    fi

    if [ -f "/tmp/qemu-disk-snap-$$" ]; then
        rm -f "/tmp/qemu-disk-snap-$$"
        log_info "Disk snapshot removed"
    fi

    log_info "Cleanup completed"
}

trap cleanup EXIT

###############################################################################
# Main process
###############################################################################

main() {
    log_info "═══════════════════════════════════════════════════════"
    log_info "QEMU VM Tester for Debian ZFS"
    log_info "Version: 1.0 (April 2026)"
    log_info "═══════════════════════════════════════════════════════"

    check_prerequisites
    prepare_vars
    run_qemu
}

main "$@"
