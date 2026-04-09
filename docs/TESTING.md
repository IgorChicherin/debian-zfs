# Руководство по тестированию Debian ZFS

## 🧪 Стратегии тестирования

### 1. Тестирование в QEMU (Рекомендуется)

Безопасный способ проверки установки без риска для данных.

#### Требования

```bash
# Debian/Ubuntu
sudo apt install qemu-system-x qemu-utils ovmf

# Проверка установки
qemu-system-x86_64 --version
```

#### Тестирование ISO

```bash
# Запуск ISO в QEMU с UEFI
qemu-system-x86_64 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=/usr/share/OVMF/OVMF_VARS.fd \
  -cdrom output/debian-zfs.iso \
  -m 4096 \
  -smp 4 \
  -boot menu=on \
  -vga virtio \
  -enable-kvm
```

#### Тестирование установленной системы

```bash
# Создать виртуальный диск
qemu-img create -f qcow2 zfs-test.qcow2 50G

# Запуск с виртуальным диском
qemu-system-x86_64 \
  -drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE.fd \
  -drive if=pflash,format=raw,file=test-vars.fd \
  -drive file=zfs-test.qcow2,format=qcow2 \
  -m 4096 \
  -smp 4 \
  -boot menu=on \
  -vga virtio \
  -enable-kvm
```

#### Автоматизированный тест

```bash
# Использовать скрипт test-vm.sh
bash scripts/test-vm.sh output/debian-zfs.iso
```

### 2. Тестирование на отдельном диске

Если есть второй диск/SSD для экспериментов.

#### Подготовка

```bash
# Определить диск (ОСТОРОЖНО!)
lsblk
fdisk -l

# Диск должен быть полностью пустым или не содержать важных данных
```

#### Установка

```bash
# Загрузиться с Live USB
# Выполнить скрипт установки
sudo bash install/zfs-install.sh --disk /dev/sdX
```

#### Первая загрузка

1. Перезагрузите систему
2. Войдите в UEFI/BIOS (F2/Del)
3. Выберите "ZFSBootMenu" как устройство загрузки
4. Система загрузится с ZFS root

### 3. Тестирование в виртуальной машине (VirtualBox/VMware)

#### VirtualBox

```bash
# Создать VM
VBoxManage createvm --name "Debian-ZFS" --register

# Настроить UEFI
VBoxManage modifyvm "Debian-ZFS" --firmware efi

# Добавить диск
VBoxManage createhd --filename zfs-test.vdi --size 51200
VBoxManage storagectl "Debian-ZFS" --name "SATA" --add sata
VBoxManage storageattach "Debian-ZFS" --storagectl "SATA" --port 0 --type hdd --medium zfs-test.vdi

# Загрузиться с ISO
VBoxManage storageattach "Debian-ZFS" --storagectl "SATA" --port 1 --type dvddrive --medium debian-zfs.iso
```

## ✅ Чеклист проверки после установки

### ZFS Pool

```bash
# Проверка статуса пула
zpool status

# Ожидаемый результат:
# pool: zroot
# state: ONLINE
# scan: none requested

# Проверка свойств
zpool get all zroot

# Ожидаемые значения:
# compression: lz4
# autotrim: on
# ashift: 12
```

### ZFS Datasets

```bash
# Список датасетов
zfs list

# Ожидаемая структура:
# zroot
# zroot/ROOT
# zroot/ROOT/debian    (смонтирован в /)
# zroot/home            (смонтирован в /home)

# Проверка точек монтирования
zfs get mountpoint zroot/ROOT/debian
zfs get mountpoint zroot/home
```

### Загрузка (ZFSBootMenu)

```bash
# Проверка EFI записей
efibootmgr -v

# Ожидаемый результат:
# BootCurrent: 0001
# BootOrder: 0001,0002
# Boot0001* ZFSBootMenu
# Boot0002* ZFSBootMenu (Backup)

# Проверка наличия EFI бинаря
ls -lh /boot/efi/EFI/ZBM/VMLINUZ.EFI
ls -lh /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI

# Проверка версии ZFSBootMenu
strings /boot/efi/EFI/ZBM/VMLINUZ.EFI | grep -i zfsbootmenu | head -n 5
```

### ZRAM

```bash
# Проверка ZRAM устройств
zramctl

# Ожидаемый результат:
# NAME       ALGORITHM DISKSIZE  DATA COMPR TOTAL STREAMS MOUNTPOINT
# /dev/zram0 zstd      2.4G      4K   66B   4K    4       [SWAP]

# Проверка swap
swapon --show

# Ожидаемый результат:
# NAME       TYPE SIZE USED PRIO
# /dev/zram0 partition 2.4G 0B 100

# Проверка службы
systemctl status dev-zram0.swap
```

### Система

```bash
# Проверка версии ядра
uname -r

# Проверка загрузки модулей ZFS
lsmod | grep zfs

# Проверка служб ZFS
systemctl list-units --type=service | grep zfs

# Ожидаемые службы:
# zfs-import-cache.service
# zfs-mount.service
# zfs-import.target
# zfs.target
```

## 🐛 Отладка проблем

### ZFS Pool не импортируется

```bash
# Проверка доступности дисков
zpool import

# Принудительный импорт
zpool import -f zroot

# Проверка dmesg
dmesg | grep -i zfs
```

### ZFSBootMenu не загружается

```bash
# Проверка EFI раздела
mount | grep /boot/efi
ls -l /boot/efi/EFI/ZBM/

# Проверка EFI записей
efibootmgr -v

# Перегенерировать образ
generate-zbm
```

### ZRAM не активируется

```bash
# Проверка конфигурации
cat /etc/systemd/zram-generator.conf

# Перезагрузка systemd
systemctl daemon-reload

# Проверка логов
journalctl -xeu dev-zram0.swap

# Ручная активация
systemctl start dev-zram0.swap
```

### Initramfs не загружает ZFS

```bash
# Проверка initramfs
lsinitramfs /boot/initrd.img-* | grep zfs

# Пересборка
update-initramfs -c -k all

# Проверка DKMS
dkms status
```

## 📊 Тестирование производительности

### ZFS I/O

```bash
# Sequential read/write
dd if=/dev/zero of=/tmp/test bs=1M count=1024 oflag=direct
dd if=/tmp/test of=/dev/null bs=1M count=1024 iflag=direct

# Random I/O (требуется fio)
fio --name=random-io --ioengine=libaio --iodepth=32 --rw=randrw \
  --bs=4k --direct=1 --size=1G --numjobs=4 --runtime=60 \
  --group_reporting --directory=/tmp
```

### ZRAM эффективность

```bash
# Проверка коэффициента сжатия
zramctl

# Мониторинг использования
watch -n 1 'zramctl && echo "---" && swapon --show'

# Нагрузка памяти (стресс-тест)
stress --vm 4 --vm-bytes 512M --timeout 60s
```

## 🔄 Тестирование снапшотов и восстановления

### Создание снапшота

```bash
# Снапшот корневой системы
zfs snapshot zroot/ROOT/debian@before-update

# Снапшот home
zfs snapshot zroot/home@before-changes

# Список снапшотов
zfs list -t snapshot
```

### Восстановление из снапшота

```bash
# Через ZFSBootMenu:
# 1. Нажмите ESC при загрузке
# 2. Выберите снапшот из списка
# 3. Загрузитесь с него

# Ручное восстановление (из Live-среды)
zfs rollback zroot/ROOT/debian@before-update
```

## 🎯 Автоматизированное тестирование

### Создание тестового скрипта

```bash
#!/bin/bash
# test-zfs-install.sh

set -e

echo "=== Проверка ZFS Pool ==="
zpool status zroot || { echo "FAIL: Pool not found"; exit 1; }

echo "=== Проверка датасетов ==="
zfs list | grep -q "zroot/ROOT/debian" || { echo "FAIL: ROOT dataset missing"; exit 1; }
zfs list | grep -q "zroot/home" || { echo "FAIL: home dataset missing"; exit 1; }

echo "=== Проверка ZFSBootMenu ==="
[ -f /boot/efi/EFI/ZBM/VMLINUZ.EFI ] || { echo "FAIL: ZFSBootMenu EFI not found"; exit 1; }
efibootmgr | grep -q "ZFSBootMenu" || { echo "FAIL: EFI boot entry missing"; exit 1; }

echo "=== Проверка ZRAM ==="
zramctl | grep -q "zram0" || { echo "FAIL: ZRAM not active"; exit 1; }
swapon --show | grep -q "zram" || { echo "FAIL: ZRAM swap not active"; exit 1; }

echo "=== Все проверки пройдены! ==="
```

### Запуск тестов

```bash
chmod +x test-zfs-install.sh
sudo bash test-zfs-install.sh
```

## ⚠️ Предостережения

1. **Никогда не тестируйте на дисках с важными данными**
2. **Всегда проверяйте переменную DISK** перед запуском скриптов
3. **UEFI тестирование** требует OVMF/Tianocore firmware
4. **ZFS требует минимум 2GB RAM**, рекомендуется 4GB+
5. **Виртуальные машины** могут работать медленнее из-за вложенной виртуализации

## 📝 Логирование

```bash
# Лог установки
script -t 2>install-time.log -a install.log
bash install/zfs-install.sh --disk /dev/sdX
exit

# Логи системы
journalctl -xe
dmesg | tail -n 100

# Логи ZFSBootMenu
cat /var/log/zfsbootmenu.log
```

## 🆘 Получение помощи

1. Проверьте логи: `journalctl -xe`
2. Проверьте статус ZFS: `zpool status -v`
3. Создайте issue в репозитории с логами
4. Укажите: версию ядра, ZFS, ZFSBootMenu
