###############################################################################
# Makefile для Debian ZFS проекта
#
# Использование:
#   make build        — Собрать кастомный Live ISO
#   make test         — Тестировать ISO в QEMU
#   make test-disk    — Тестировать диск в QEMU (DISK=/dev/sdX)
#   make usb          — Записать ISO на USB (USB=/dev/sdX)
#   make clean        — Очистить выходные файлы
#   make help         — Показать доступные команды
#   make docs         — Открыть документацию
#   make check        — Проверить зависимости
#
# Примеры:
#   make build
#   make test
#   make test-disk DISK=/dev/sda
#   make usb USB=/dev/sdb
###############################################################################

.PHONY: help build test test-disk usb clean docs check

# Переменные
OUTPUT_DIR = output
ISO_FILE = $(OUTPUT_DIR)/debian-zfs-live.iso
DISK ?= /dev/sda
USB ?= /dev/sda
MEMORY ?= 4096
CPUS ?= 4

# Цвета для вывода
GREEN = \033[0;32m
YELLOW = \033[1;33m
BLUE = \033[0;34m
NC = \033[0m

###############################################################################
# help — Показать доступные команды
###############################################################################
help:
	@echo "$(BLUE)═══════════════════════════════════════════════════════$(NC)"
	@echo "$(GREEN)Debian ZFS Project — Makefile$(NC)"
	@echo "$(BLUE)═══════════════════════════════════════════════════════$(NC)"
	@echo ""
	@echo "$(YELLOW)Основные команды:$(NC)"
	@echo "  make build          Собрать кастомный Live ISO с ZFS"
	@echo "  make test           Тестировать ISO в QEMU"
	@echo "  make test-disk      Тестировать диск в QEMU"
	@echo "  make usb            Записать ISO на USB-накопитель"
	@echo "  make clean          Очистить выходные файлы"
	@echo ""
	@echo "$(YELLOW)Дополнительные:$(NC)"
	@echo "  make check          Проверить зависимости"
	@echo "  make docs           Показать документацию"
	@echo "  make help           Показать это сообщение"
	@echo ""
	@echo "$(YELLOW)Параметры:$(NC)"
	@echo "  DISK=/dev/sdX       Диск для тестирования (по умолч.: /dev/sda)"
	@echo "  USB=/dev/sdX        USB устройство (по умолч.: /dev/sda)"
	@echo "  MEMORY=4096         RAM для VM в MB"
	@echo "  CPUS=4              CPU для VM"
	@echo ""
	@echo "$(YELLOW)Примеры:$(NC)"
	@echo "  make build"
	@echo "  make test"
	@echo "  make test-disk DISK=/dev/sdb"
	@echo "  make usb USB=/dev/sdc"
	@echo "  make test MEMORY=8192 CPUS=8"
	@echo ""

###############################################################################
# check — Проверить зависимости
###############################################################################
check:
	@echo "$(BLUE)[CHECK]$(NC) Проверка зависимостей..."
	@echo ""
	@# Live build
	@command -v lb >/dev/null 2>&1 && \
		echo "$(GREEN)  ✓$(NC) live-build установлен" || \
		echo "$(YELLOW)  ✗$(NC) live-build НЕ установлен (нужен для make build)"
	@# QEMU
	@command -v qemu-system-x86_64 >/dev/null 2>&1 && \
		echo "$(GREEN)  ✓$(NC) qemu-system-x86_64 установлен" || \
		echo "$(YELLOW)  ✗$(NC) qemu-system-x86_64 НЕ установлен (нужен для make test)"
	@# OVMF
	@test -f /usr/share/OVMF/OVMF_CODE.fd && \
		echo "$(GREEN)  ✓$(NC) OVMF firmware найден" || \
		echo "$(YELLOW)  ✗$(NC) OVMF firmware НЕ найден (нужен для UEFI)"
	@# dd
	@command -v dd >/dev/null 2>&1 && \
		echo "$(GREEN)  ✓$(NC) dd установлен" || \
		echo "$(YELLOW)  ✗$(NC) dd НЕ установлен"
	@echo ""
	@echo "$(BLUE)[INFO]$(NC) Для установки зависимыхостей:"
	@echo "  sudo apt install live-build qemu-system-x86 ovmf"

###############################################################################
# build — Собрать кастомный Live ISO
###############################################################################
build: check
	@echo ""
	@echo "$(BLUE)[BUILD]$(NC) Запуск сборки ISO..."
	@echo ""
	@mkdir -p $(OUTPUT_DIR)
	@if [ "$(id -u)" -eq 0 ]; then \
		bash scripts/build-iso.sh --output-dir $(OUTPUT_DIR); \
	else \
		echo "$(YELLOW)[INFO]$(NC) Требуются root права. Запустите: sudo make build"; \
		sudo bash scripts/build-iso.sh --output-dir $(OUTPUT_DIR); \
	fi

###############################################################################
# test — Тестировать ISO в QEMU
###############################################################################
test:
	@if [ ! -f "$(ISO_FILE)" ]; then \
		echo "$(YELLOW)[WARN]$(NC) ISO файл не найден: $(ISO_FILE)"; \
		echo "$(YELLOW)[INFO]$(NC) Сначала выполните: make build"; \
		exit 1; \
	fi
	@echo ""
	@echo "$(BLUE)[TEST]$(NC) Запуск QEMU с ISO..."
	@echo ""
	@bash scripts/test-vm.sh $(ISO_FILE) --memory $(MEMORY) --cpus $(CPUS)

###############################################################################
# test-disk — Тестировать диск в QEMU
###############################################################################
test-disk:
	@echo "$(YELLOW)[WARN]$(NC) Тестирование диска: $(DISK)"
	@echo "$(YELLOW)[WARN]$(NC) Убедитесь что это правильный диск!"
	@echo ""
	@read -p "Продолжить? (да/нет): " confirm && \
	if [ "$$confirm" = "да" ]; then \
		echo ""; \
		echo "$(BLUE)[TEST]$(NC) Запуск QEMU с диском..."; \
		echo ""; \
		bash scripts/test-vm.sh --disk $(DISK) --memory $(MEMORY) --cpus $(CPUS) --snapshot; \
	fi

###############################################################################
# usb — Записать ISO на USB
###############################################################################
usb:
	@if [ ! -f "$(ISO_FILE)" ]; then \
		echo "$(YELLOW)[WARN]$(NC) ISO файл не найден: $(ISO_FILE)"; \
		echo "$(YELLOW)[INFO]$(NC) Сначала выполните: make build"; \
		exit 1; \
	fi
	@echo ""
	@echo "$(BLUE)[USB]$(NC) Запись ISO на $(USB)..."
	@echo ""
	@sudo bash scripts/usb-write.sh $(USB) $(ISO_FILE)

###############################################################################
# clean — Очистить выходные файлы
###############################################################################
clean:
	@echo "$(BLUE)[CLEAN]$(NC) Очистка..."
	@rm -rf $(OUTPUT_DIR)
	@rm -rf live-build-work
	@rm -f /tmp/qemu-*.fd 2>/dev/null || true
	@rm -f /tmp/qemu-disk-snap-* 2>/dev/null || true
	@echo "$(GREEN)  ✓$(NC) Очистка завершена"

###############################################################################
# docs — Показать документацию
###############################################################################
docs:
	@echo "$(BLUE)═══════════════════════════════════════════════════════$(NC)"
	@echo "$(GREEN)Документация Debian ZFS Project$(NC)"
	@echo "$(BLUE)═══════════════════════════════════════════════════════$(NC)"
	@echo ""
	@echo "$(YELLOW)Файлы документации:$(NC)"
	@echo "  README.md                 — Основная документация"
	@echo "  docs/ARCHITECTURE.md      — Архитектура и структура"
	@echo "  docs/TESTING.md           — Руководство по тестированию"
	@echo "  docs/SOURCES.md           — Источники и ссылки"
	@echo ""
	@echo "$(YELLOW)Скрипты установки:$(NC)"
	@echo "  install/zfs-install.sh         — Установка ZFS root"
	@echo "  install/zfsbootmenu-setup.sh   — Настройка ZFSBootMenu"
	@echo "  install/zram-config.sh         — Настройка ZRAM"
	@echo ""
	@echo "$(YELLOW)Скрипты инструментов:$(NC)"
	@echo "  scripts/build-iso.sh      — Сборка ISO"
	@echo "  scripts/test-vm.sh        — Тестирование в QEMU"
	@echo "  scripts/usb-write.sh      — Запись на USB"
	@echo ""
