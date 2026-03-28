# Telemt MTProxy Manager

Скрипт создан для друзей Телеграм канала [Клуб «На связи»](https://t.me/na_sviazi66)

Универсальный скрипт для установки и управления MTProxy на базе telemt.

## Возможности

- 🚀 **Автоматическая установка** telemt из исходников с компиляцией Rust
- 👥 **Управление пользователями** (добавление/удаление/список)
- 🔧 **Смена SNI** для обхода блокировок
- 🔌 **Смена порта** (по умолчанию 7443)
- 🤖 **Telegram бот** для удалённого управления прокси
- 📊 **Статус сервера** с выводом IP, порта, SNI, количества пользователей

## Быстрая установка

```bash
curl -sL https://raw.githubusercontent.com/potap1978/Telemt_script/main/telemt-bot_potap.sh -o telemt-bot_potap.sh && chmod +x telemt-bot_potap.sh && sudo ./telemt-bot_potap.sh
