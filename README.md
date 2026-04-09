# Debian Bookworm ZFS Root + ZFSBootMenu + ZRAM

Автоматизированная установка Debian Bookworm (12) с корневой файловой системой на ZFS, загрузчиком ZFSBootMenu и сжатой RAM-подкачкой ZRAM.

## 📋 Особенности

- **ZFS Root** — корневая ФС на ZFS с compression=lz4, autotrim, ACL
- **ZFSBootMenu** — современный загрузчик с поддержкой снапшотов и кастомных ядер
- **ZRAM** — сжатая подкачка в RAM через systemd-zram-generator (60% RAM, zstd)
- **UEFI** — поддержка UEFI-загрузки с EFI System Partition
- **Шифрование** — опциональное ZFS native encryption (AES-256-GCM)
- **Кастомный ISO** — сборка собственного Live-образа через live-build

## 🗂 Структура проекта

```
debian-zfs/
├── README.md                      # Этот файл
├── Makefile                       # Автоматизация сборки ISO
├── install/
│   ├── zfs-install.sh             # Основной скрипт установки ZFS root
│   ├── zfsbootmenu-setup.sh       # Настройка ZFSBootMenu
│   └── zram-config.sh             # Настройка ZRAM
├── config/
│   ├── zfsbootmenu/
│   │   └── config.yaml            # Конфигурация ZFSBootMenu
│   ├── zram/
│   │   └── zram-generator.conf    # Конфигурация ZRAM
│   └── live-build/                # Конфигурация для сборки ISO
│       ├── package-lists/
│       │   └── zfs.list.chroot
│       ├── includes.chroot/
│       │   └── etc/
│       └── auto/
│           └── config
├── scripts/
│   ├── build-iso.sh               # Сборка кастомного ISO
│   ├── test-vm.sh                 # Тестирование в QEMU
│   └── usb-write.sh               # Запись на USB-накопитель
└── docs/
    ├── ARCHITECTURE.md            # Архитектура и структура датасетов
    ├── TESTING.md                 # Руководство по тестированию
    └── SOURCES.md                 # Источники документации
```

## 🚀 Быстрый старт

### 1. Подготовка Live-среды

```bash
# Загрузите Debian Bookworm netinst или live ISO
# https://www.debian.org/download

# В live-среде выполните:
sudo -i
git clone <этого репозитория>
cd debian-zfs
```

### 2. Установка ZFS Root

```bash
# Проверьте диски
lsblk

# Отредактируйте переменные в install/zfs-install.sh:
# DISK="/dev/sda"  # ваш диск
# BOOT_PART="1"    # EFI раздел
# POOL_PART="2"    # ZFS раздел

# Запустите установку (без шифрования):
sudo bash install/zfs-install.sh --disk /dev/sda

# Или с шифрованием:
sudo bash install/zfs-install.sh --disk /dev/sda --encrypt --passphrase "YOUR_PASSPHRASE"
```

### 3. Настройка ZFSBootMenu

```bash
# Автоматическая настройка:
sudo bash install/zfsbootmenu-setup.sh

# Или вручную следуйте инструкциям в docs/ARCHITECTURE.md
```

### 4. Настройка ZRAM

```bash
# Установка и настройка ZRAM:
sudo bash install/zram-config.sh
```

## 🛠 Сборка кастомного ISO

```bash
# Установка зависимостей (Debian):
sudo apt install live-build

# Сборка ISO:
make build

# Или напрямую:
sudo bash scripts/build-iso.sh

# Запись на USB:
sudo bash scripts/usb-write.sh /dev/sdX  # ВНИМАНИЕ: правильный диск!
```

## 🧪 Тестирование в QEMU

```bash
# Тестирование ISO в виртуальной машине:
make test

# Или напрямую:
bash scripts/test-vm.sh output/debian-zfs.iso

# Тестирование установленной системы:
bash scripts/test-vm.sh --disk /dev/sdX
```

## 📦 Версии пакетов (Апрель 2026)

| Пакет | Версия | Источник |
|-------|--------|----------|
| zfsutils-linux | 2.3.2+ (backports) | bookworm-backports |
| zfs-initramfs | 2.3.2+ (backports) | bookworm-backports |
| ZFSBootMenu | 3.1.x | get.zfsbootmenu.org |
| systemd-zram-generator | 1.1.2+ | bookworm |
| linux-image-amd64 | 6.1.x LTS | bookworm |

## ⚠️ Важные замечания

1. **ZFS не входит в Debian Installer** из-за лицензионных ограничений — установка выполняется вручную через debootstrap
2. **ZFSBootMenu заменяет GRUB** — не устанавливайте GRUB при использовании ZFSBootMenu
3. **Не используйте одновременно zram-tools и systemd-zram-generator** — выбирайте один (рекомендуется systemd)
4. **Резервная копия EFI** — всегда создавайте резервную копию VMLINUZ.EFI перед обновлением

## 📚 Документация

- [Архитектура и структура датасетов](docs/ARCHITECTURE.md)
- [Руководство по тестированию](docs/TESTING.md)
- [Источники и документация](docs/SOURCES.md)

## 🔗 Источники

- [Официальная документация OpenZFS — Debian Bookworm](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/index.html)
- [ZFSBootMenu Documentation](https://docs.zfsbootmenu.org/)
- [Debian Wiki — ZFS](https://wiki.debian.org/ZFS)
- [Debian Wiki — ZRAM](https://wiki.debian.org/ZRam)

## 📄 Лицензия

MIT License — используйте на свой страх и риск. ZFS имеет лицензию CDDL, которая может быть несовместима с GPL.
