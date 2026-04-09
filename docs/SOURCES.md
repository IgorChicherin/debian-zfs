# Источники документации

## 📚 Официальные источники

### OpenZFS и Debian

1. **[OpenZFS — Debian Bookworm](https://openzfs.github.io/openzfs-docs/Getting%20Started/Debian/index.html)**
   - Официальная документация OpenZFS
   - Актуальная версия: 2.3.2+ (bookworm-backports)
   - Дата проверки: Апрель 2026

2. **[Debian Wiki — ZFS](https://wiki.debian.org/ZFS)**
   - Сообщество Debian
   - Установка, настройка, устранение проблем
   - Обновлено: Декабрь 2025

3. **[Debian Wiki — ZRAM](https://wiki.debian.org/ZRam)**
   - Конфигурация zram-tools и systemd-zram-generator
   - Обновлено: Март 2026

### ZFSBootMenu

4. **[ZFSBootMenu Documentation](https://docs.zfsbootmenu.org/)**
   - Версия: 3.1.x
   - Руководство по Debian Bookworm: `/guides/debian/bookworm-uefi.html`
   - Changelog: `/en/v3.1.x/CHANGELOG.html`
   - Обновлено: Январь 2026

### Сообщество и блоги

5. **[Daniel Wayne Armstrong — Debian on ZFS](https://www.dwarmstrong.org/debian-install-zfs/)**
   - Подробное руководство с шифрованием
   - Обновлено: Сентябрь 2024

6. **[Configs — debian-on-zfs.md](https://github.com/ongardie/configs/blob/main/debian-on-zfs.md)**
   - Минималистичный подход
   - Проверенная методика

7. **[Reddit — r/zfs](https://www.reddit.com/r/zfs/)**
   - Обсуждение ZFSBootMenu + Debian
   - Реальный опыт пользователей
   - Актуальные проблемы и решения

## 🛠 Инструменты и пакеты

### Версии пакетов (Апрель 2026)

| Пакет | Версия | Репозиторий | Примечание |
|-------|--------|-------------|------------|
| zfsutils-linux | 2.3.2-2~bpo012+2 | bookworm-backports | Основная утилита |
| zfs-initramfs | 2.3.2-2~bpo012+2 | bookworm-backports | Initramfs модуль |
| zfs-dkms | 2.3.2-2~bpo012+2 | bookworm-backports | DKMS модуль |
| ZFSBootMenu | 3.1.x | get.zfsbootmenu.org | Prebuilt EFI |
| systemd-zram-generator | 1.1.2+ | bookworm | Рекомендуемый |
| zram-tools | 1.2.x | bookworm | Альтернатива |
| linux-image-amd64 | 6.1.x LTS | bookworm | Debian stable |

### Важные изменения в 2025-2026

1. **systemd-zram-generator** стал предпочтительнее zram-tools
   - Лучшая интеграция с systemd
   - Меньше зависимостей
   - Автоматическая активация

2. **ZFSBootMenu 3.x**
   - Улучшенная поддержка UEFI
   - Встроенные драйверы
   - Поддержка нескольких ядер

3. **OpenZFS 2.3.x**
   - Улучшенная производительность
   - Новые свойства совместимости
   - Исправления безопасности

## 🎥 Видео-материалы

1. **[Installing OpenZFS on Debian 12/13](https://www.youtube.com/watch?v=RFNajjss8dQ)**
   - YouTube, Октябрь 2025
   - Визуальное руководство

2. **[Building Debian NAS with ZFS](https://www.youtube.com/watch?v=321UmFpCKHk)**
   - YouTube, Июль 2025
   - Продвинутая настройка

## 💡 Примеры проектов

1. **[mmitch/debian-live-mitch-zfs](https://github.com/mmitch/debian-live-mitch-zfs)**
   - Кастомный Live ISO с ZFS
   - Использование live-build
   - Rescue система

2. **[danfossi/Debian-ZFS-Root-Installation-Script](https://github.com/danfossi/Debian-ZFS-Root-Installation-Script)**
   - Автоматизированная установка
   - Поддержка RAID
   - GRUB и UEFI

3. **[free-pmx ZFSBootMenu guide](https://free-pmx.org/guides/zfs-boot/)**
   - Proxmox VE с ZFSBootMenu
   - Feature-complete bootloader

## 📝 Изменения и уточнения

### Что изменилось с 2024

- ✅ ZFSBootMenu теперь 3.1.x (было 2.x)
- ✅ systemd-zram-generator предпочтительнее zram-tools
- ✅ OpenZFS 2.3.x в backports (было 2.1.x)
- ✅ Новая опция compatibility=openzfs-2.2-linux
- ✅ Улучшена документация по шифрованию

### Что осталось прежним

- ✅ Структура датасетов (zroot/ROOT/debian)
- ✅ Основные параметры пула (ashift=12, compression=lz4)
- ✅ Процесс debootstrap + chroot
- ✅ ZFSBootMenu EFI бинарь (get.zfsbootmenu.org)

## 🔍 Проверка актуальности

```bash
# Проверка версии ZFS
apt-cache policy zfsutils-linux

# Проверка версии ZFSBootMenu
strings /boot/efi/EFI/ZBM/VMLINUZ.EFI | grep -i version

# Проверка версии ядра
uname -r

# Проверка доступных версий в backports
apt-cache madison zfsutils-linux
```

## 📞 Поддержка

1. **GitHub Issues** — для багов и предложений
2. **Reddit r/zfs** — для обсуждения
3. **Debian Forums** — для общих вопросов
4. **ZFSBootMenu Discord** — для помощи с загрузкой
