###############################################################################
# Makefile — Debian ZFS project
#
#   make build                 Build the live ISO (root)
#   make test                  Boot the ISO in QEMU
#   make test-install          Boot the ISO with an empty 40G install disk
#   make test-disk DISK=/dev/sdX   Boot a disk in QEMU (snapshot, no writes)
#   make usb [USB=/dev/sdX]    Write the ISO to a USB drive (asks if USB unset)
#   make check                 Check host dependencies
#   make lint                  Byte-compile all Python scripts
#   make clean                 Remove build output
###############################################################################

.PHONY: help build test test-install test-disk usb check lint clean

PYTHON     ?= python3
OUTPUT_DIR ?= output
ISO_FILE   = $(OUTPUT_DIR)/debian-zfs-live.iso
MEMORY     ?= 4096
CPUS       ?= 4
DISK       ?=
USB        ?=

help:
	@sed -n '2,13p' Makefile | sed 's/^# \{0,1\}//'

check:
	@for c in $(PYTHON) lb qemu-system-x86_64 qemu-img; do \
		if command -v $$c >/dev/null 2>&1; then echo "  ok       $$c"; else echo "  missing  $$c"; fi; done
	@if ls /usr/share/OVMF/OVMF_CODE*.fd >/dev/null 2>&1; then echo "  ok       OVMF"; else echo "  missing  OVMF (UEFI VMs)"; fi
	@echo "Install: sudo apt install python3 live-build debian-archive-keyring qemu-system-x86 qemu-utils ovmf"

lint:
	@$(PYTHON) -m py_compile install/*.py scripts/*.py && echo "Python OK"

build:
	sudo $(PYTHON) scripts/build-iso.py --output-dir $(OUTPUT_DIR)

$(ISO_FILE):
	@echo "ISO not found: $(ISO_FILE) — run 'make build' first"; exit 1

test: $(ISO_FILE)
	$(PYTHON) scripts/test-vm.py $(ISO_FILE) --memory $(MEMORY) --cpus $(CPUS)

test-install: $(ISO_FILE)
	$(PYTHON) scripts/test-vm.py $(ISO_FILE) --target-disk 40G --memory $(MEMORY) --cpus $(CPUS)

test-disk:
	@test -n "$(DISK)" || { echo "Usage: make test-disk DISK=/dev/sdX"; exit 1; }
	sudo $(PYTHON) scripts/test-vm.py --disk $(DISK) --snapshot --memory $(MEMORY) --cpus $(CPUS)

usb: $(ISO_FILE)
	sudo $(PYTHON) scripts/usb-write.py $(USB) $(if $(USB),$(ISO_FILE),)

clean:
	rm -rf $(OUTPUT_DIR) live-build-work
	@echo "Clean"
