# Архитектура Debian ZFS Root + ZFSBootMenu + ZRAM

## 📊 Общая схема загрузки

```
UEFI Firmware
    ↓
EFI System Partition (FAT32, 512MB)
    ↓
ZFSBootMenu (VMLINUZ.EFI)
    ↓
ZFS Pool Import (zroot)
    ↓
Dataset: zroot/ROOT/debian
    ↓
Linux Kernel + Initramfs (kexec)
    ↓
Systemd → ZFS mount → Root filesystem
```

## 💽 Структура дисков

### Разделы (GPT)

| № | Тип | Код | Размер | Назначение |
|---|-----|-----|--------|------------|
| 1 | EFI System Partition | EF00 | 512 MB | Загрузчик ZFSBootMenu |
| 2 | ZFS | BF00 | Всё остальное | ZFS pool (zroot) |

### Пример разметки

```bash
DISK="/dev/sda"

# Очистка диска
sgdisk --zap-all "$DISK"
wipefs -a "$DISK"

# EFI раздел (512MB)
sgdisk -n 1:1m:+512m -t 1:ef00 "$DISK"

# ZFS раздел (всё остальное)
sgdisk -n 2:0:-10m -t 2:bf00 "$DISK"
```

## 🗂 ZFS Pool и Dataset структура

### Pool: zroot

Параметры создания:

```bash
zpool create -f \
  -o ashift=12 \              # Выравнивание по 4K секторам
  -O compression=lz4 \        # Сжатие по умолчанию
  -O acltype=posixacl \       # POSIX ACL
  -O xattr=sa \               # Расширенные атрибуты в inode
  -O relatime=on \            # Относительное время доступа
  -o autotrim=on \            # Автоматический TRIM для SSD
  -o compatibility=openzfs-2.2-linux \
  -m none \                   # Не монтировать автоматически
  zroot /dev/disk/by-id/...
```

### Dataset иерархия

```
zroot                         (pool root)
├── ROOT                      (mountpoint=none)
│   └── debian                (mountpoint=/, canmount=noauto)
├── home                      (mountpoint=/home)
└── var-log                   (mountpoint=/var/log, опционально)
```

### Создание датасетов

```bash
# ROOT датасет (бебут)
zfs create -o mountpoint=none zroot/ROOT

# Корневой датасет для этой установки
zfs create -o mountpoint=/ -o canmount=noauto zroot/ROOT/debian

# Домашний каталог (отдельный датасет для снапшотов)
zfs create -o mountpoint=/home zroot/home

# Опционально: логи отдельно
zfs create -o mountpoint=/var/log zroot/var-log

# Установить загрузочный датасет
zpool set bootfs=zroot/ROOT/debian zroot
```

### Свойства датасетов

```bash
# Для ZFSBootMenu
zfs set org.zfsbootmenu:commandline="quiet loglevel=0" zroot/ROOT/debian

# Для шифрования (если используется)
zfs set org.zfsbootmenu:keysource="zroot/ROOT/debian" zroot
```

## 🔐 Шифрование (ZFS Native Encryption)

### Создание с шифрованием

```bash
# Генерация ключа
echo 'YourStrongPassphrase' > /etc/zfs/zroot.key
chmod 000 /etc/zfs/zroot.key

# Создание пула с шифрованием
zpool create -f \
  -O encryption=aes-256-gcm \
  -O keylocation=file:///etc/zfs/zroot.key \
  -O keyformat=passphrase \
  [... остальные параметры ...] \
  zroot /dev/disk/by-id/...

# Копирование ключа в chroot
mkdir /mnt/etc/zfs
cp /etc/zfs/zroot.key /mnt/etc/zfs/
chmod 000 /mnt/etc/zfs/zroot.key
```

### Загрузка с шифрованием

ZFSBootMenu запросит passphrase при загрузке.

## 🔄 ZFSBootMenu

### Установка (Prebuilt EFI бинарь)

```bash
# Создать директорию
mkdir -p /boot/efi/EFI/ZBM

# Скачать EFI бинарь
curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi

# Создать резервную копию
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
```

### Регистрация в UEFI

```bash
# Основная запись
efibootmgr -c -d /dev/sda -p 1 \
  -L "ZFSBootMenu" \
  -l '\EFI\ZBM\VMLINUZ.EFI'

# Резервная запись
efibootmgr -c -d /dev/sda -p 1 \
  -L "ZFSBootMenu (Backup)" \
  -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'
```

### Конфигурация

Файл: `/etc/zfsbootmenu/config.yaml`

```yaml
Global:
  ManageImages: true
  BootMountPoint: /boot/efi
  DracutConfDir: /etc/zfsbootmenu/dracut.conf.d
Components:
  Enabled: false
EFI:
  ImageDir: /boot/efi/EFI/ZBM
  Versions: false
  Enabled: true
Kernel:
  CommandLine: quiet loglevel=0
```

### Генерация образа

```bash
# После изменений в конфигурации
generate-zbm
```

### Использование

- **ESC** при загрузке — вход в меню ZFSBootMenu
- **Ctrl+K** — выбор ядра/снапшота
- **Ctrl+D** — установить выбранный вариант по умолчанию
- **Ctrl+R** — восстановление из снапшота

## 🧠 ZRAM (Сжатая подкачка в RAM)

### systemd-zram-generator (Рекомендуется)

Пакет: `systemd-zram-generator`

Конфигурация: `/etc/systemd/zram-generator.conf`

```ini
[zram0]
zram-size = min(ram * 0.6, 4096)  # 60% RAM или 4GB
compression-algorithm = zstd
fs-type = swap
mount-point = none
```

### Активация

```bash
# Перезагрузка systemd
systemctl daemon-reload

# Проверка
systemctl status dev-zram0.swap

# Информация об использовании
zramctl
```

### Почему systemd-zram-generator?

| Критерий | zram-tools | systemd-zram-generator |
|----------|-----------|------------------------|
| Интеграция | Отдельный сервис | Нативная systemd |
| Настройка | /etc/default/zramswap | /etc/systemd/zram-generator.conf |
| Зависимости | Дополнительные | Минимальные |
| Рекомендация | ❌ Устарел | ✅ Современный |

## 📦 Пакеты

### В Live-среде

```bash
apt install \
  openssh-server \
  debootstrap \
  gdisk \
  dkms \
  linux-headers-$(uname -r) \
  zfsutils-linux \
  curl
```

### В целевой системе (chroot)

```bash
apt install \
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
  systemd-zram-generator
```

### Настройка APT Priorities

Файл: `/etc/apt/preferences.d/90_zfs`

```
Package: src:zfs-linux
Pin: release n=bookworm-backports
Pin-Priority: 990
```

## 🔧 Initramfs и DKMS

### Конфигурация DKMS

Файл: `/etc/dkms/zfs.conf`

```bash
REMAKE_INITRD=yes
```

### Пересборка initramfs

```bash
# Создать новый initramfs для всех ядер
update-initramfs -c -k all

# Обновить существующий
update-initramfs -u -k all
```

## 🎯 Systemd службы ZFS

```bash
# Включить службы ZFS
systemctl enable zfs.target
systemctl enable zfs-import-cache
systemctl enable zfs-mount
systemctl enable zfs-import.target
```

## 📋 Команды для проверки

```bash
# Проверка пула
zpool status
zpool list

# Проверка датасетов
zfs list
zfs get mountpoint

# Проверка EFI записей
efibootmgr -v

# Проверка ZRAM
zramctl
swapon --show

# Проверка ZFSBootMenu
strings /boot/efi/EFI/ZBM/VMLINUZ.EFI | grep -c zfsbootmenu
```

## 🔄 Процесс обновления ZFSBootMenu

```bash
# Скачать новую версию
curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi

# Создать резервную копию
cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

# Перегенерировать образ (если нужно)
generate-zbm
```

## ⚠️ Важные замечания

1. **Не используйте GRUB** вместе с ZFSBootMenu — они конфликтуют
2. **Hostid** должен быть фиксированным: `zgenhostid -f 0x00bab10c`
3. **EFI раздел** должен быть смонтирован в `/boot/efi` для работы ZFSBootMenu
4. **ZFSBootMenu** загружает ядро через kexec, минуя BIOS/UEFI после начальной загрузки
5. **ZRAM** не подходит для hibernation — используйте обычный swap если нужна гибернация
