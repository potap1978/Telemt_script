#!/bin/bash
set -e

# ============================================
# Цвета и оформление
# ============================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

# ============================================
# Конфигурация
# ============================================
TELEMT_BIN="/usr/local/bin/telemt"
TELEMT_CONFIG="/etc/telemt/config.toml"
TELEMT_USER="telemt"
TELEMT_GROUP="telemt"
DATA_DIR="/var/lib/telemt"
LOG_DIR="/var/log/telemt"
SERVICE_FILE="/etc/systemd/system/telemt.service"

# ============================================
# Вспомогательные функции
# ============================================
error() { echo -e "${RED}${BOLD}[ОШИБКА]${NC} $1" >&2; }
info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
step() { echo -e "${CYAN}[→]${NC} $1"; }
success() { echo -e "${GREEN}${BOLD}[✔]${NC} $1"; }

pause() {
    echo ""
    read -p "Нажмите Enter для продолжения..."
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Скрипт должен выполняться от root (используйте sudo)"
        exit 1
    fi
}

check_telemt_installed() {
    if [[ ! -f "$TELEMT_BIN" ]]; then
        warn "Telemt не установлен"
        return 1
    fi
    return 0
}

get_server_ip() {
    ipv4=$(curl -4 -s ifconfig.me 2>/dev/null || curl -4 -s icanhazip.com 2>/dev/null)
    if [[ -n "$ipv4" && "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ipv4"
    else
        ipv4=$(curl -4 -s ipinfo.io/ip 2>/dev/null)
        if [[ -n "$ipv4" && "$ipv4" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ipv4"
        else
            echo "IP_НЕ_ОПРЕДЕЛЕН"
        fi
    fi
}

generate_secret() {
    # Генерируем 30 hex символов + префикс ee = 32 символа
    echo "ee$(openssl rand -hex 15)"
}

get_users_list() {
    grep -E '^[a-zA-Z0-9_-]+ = "ee[a-f0-9]{30}"' $TELEMT_CONFIG 2>/dev/null || true
}

get_users_count() {
    get_users_list | wc -l
}

# ============================================
# Функции установки и удаления
# ============================================
install_telemt() {
    clear
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}           УСТАНОВКА TELEMT${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    step "Проверка наличия telemt..."
    if [[ -f "$TELEMT_BIN" ]]; then
        warn "Telemt уже установлен"
        read -p "Переустановить? (y/N): " reinstall
        if [[ "$reinstall" != "y" && "$reinstall" != "Y" ]]; then
            return
        fi
        step "Остановка старых сервисов..."
        systemctl stop telemt 2>/dev/null
        systemctl disable telemt 2>/dev/null
        step "Удаление старых файлов..."
        rm -f $TELEMT_BIN 2>/dev/null
        rm -rf /etc/telemt /var/lib/telemt /var/log/telemt 2>/dev/null
        rm -f $SERVICE_FILE 2>/dev/null
        systemctl daemon-reload
    fi
    
    step "Установка системных зависимостей..."
    if command -v apt &>/dev/null; then
        apt update -qq && apt install -y curl git build-essential pkg-config libssl-dev
    elif command -v yum &>/dev/null; then
        yum install -y curl git gcc make openssl-devel
    elif command -v pacman &>/dev/null; then
        pacman -S --noconfirm curl git base-devel openssl
    else
        warn "Не удалось определить пакетный менеджер. Установите вручную: curl, git, rust/cargo"
    fi
    
    step "Установка Rust (неинтерактивно)..."
    if ! command -v cargo &>/dev/null; then
        info "Скачивание rustup..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup.sh
        info "Установка Rust (это может занять несколько минут)..."
        sh /tmp/rustup.sh -y --default-toolchain stable
        source "$HOME/.cargo/env"
        rm -f /tmp/rustup.sh
        success "Rust установлен"
    else
        info "Rust уже установлен: $(rustc --version 2>/dev/null)"
    fi
    
    step "Клонирование и сборка telemt..."
    cd /tmp
    rm -rf telemt
    git clone https://github.com/telemt/telemt.git
    cd telemt
    
    step "Компиляция telemt (это может занять 5-10 минут)..."
    cargo build --release
    
    step "Создание пользователя и директорий..."
    id -u $TELEMT_USER &>/dev/null || useradd -r -s /bin/false -d $DATA_DIR $TELEMT_USER
    mkdir -p /etc/telemt $DATA_DIR $LOG_DIR
    chown -R $TELEMT_USER:$TELEMT_GROUP /etc/telemt $DATA_DIR $LOG_DIR
    
    step "Установка бинарного файла..."
    cp target/release/telemt $TELEMT_BIN
    chmod +x $TELEMT_BIN
    
    step "Создание конфигурации..."
    create_default_config
    
    step "Создание systemd сервиса..."
    create_systemd_service
    
    step "Запуск telemt..."
    systemctl daemon-reload
    systemctl enable telemt
    systemctl start telemt
    
    sleep 3
    
    if systemctl is-active --quiet telemt; then
        success "Telemt успешно установлен и запущен!"
        echo ""
        echo -e "${CYAN}Порт по умолчанию:${NC} 7443"
        echo -e "${CYAN}SNI по умолчанию:${NC} www.google.com"
        echo -e "${CYAN}Для добавления пользователя выберите пункт 3${NC}"
    else
        warn "Сервис не запустился. Проверьте логи: journalctl -u telemt -n 20"
    fi
    
    pause
}

create_default_config() {
    # Генерируем тестовый секрет правильной длины (32 символа)
    temp_secret="ee$(openssl rand -hex 15)"
    
    cat > $TELEMT_CONFIG << EOF
# === General Settings ===
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = false
tls = true

[server]
port = 7443

[server.api]
enabled = true
listen = "127.0.0.1:9091"

# === Anti-Censorship & Masking ===
[censorship]
tls_domain = "www.google.com"

[access.users]
# Тестовый пользователь (удалите после добавления своих)
temp_user = "$temp_secret"
EOF
    chown $TELEMT_USER:$TELEMT_GROUP $TELEMT_CONFIG
}

create_systemd_service() {
    cat > $SERVICE_FILE << EOF
[Unit]
Description=Telemt
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$TELEMT_USER
Group=$TELEMT_GROUP
WorkingDirectory=$DATA_DIR
ExecStart=$TELEMT_BIN $TELEMT_CONFIG
Restart=on-failure
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
}

uninstall_telemt() {
    clear
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}${BOLD}           УДАЛЕНИЕ TELEMT${NC}"
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if ! check_telemt_installed; then
        pause
        return
    fi
    
    warn "ВНИМАНИЕ! Это действие полностью удалит telemt и все данные:"
    echo "  • Бинарный файл: $TELEMT_BIN"
    echo "  • Конфигурация: /etc/telemt"
    echo "  • Данные: $DATA_DIR"
    echo "  • Логи: $LOG_DIR"
    echo "  • Systemd сервис"
    echo ""
    read -p "Вы уверены, что хотите удалить telemt? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Удаление отменено"
        pause
        return
    fi
    
    step "Остановка сервиса..."
    systemctl stop telemt 2>/dev/null
    systemctl disable telemt 2>/dev/null
    
    step "Удаление файлов..."
    rm -f $SERVICE_FILE
    rm -f $TELEMT_BIN
    rm -rf /etc/telemt
    rm -rf $DATA_DIR
    rm -rf $LOG_DIR
    rm -rf /tmp/telemt
    
    step "Обновление systemd..."
    systemctl daemon-reload
    
    success "Telemt полностью удален"
    pause
}

# ============================================
# Управление пользователями
# ============================================
add_user() {
    clear
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}           ДОБАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯ${NC}"
    echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if ! check_telemt_installed; then
        pause
        return
    fi
    
    current_sni=$(grep -oP 'tls_domain = "\K[^"]+' $TELEMT_CONFIG 2>/dev/null || echo "www.google.com")
    current_port=$(grep -oP 'port = \K\d+' $TELEMT_CONFIG 2>/dev/null || echo "7443")
    
    echo -e "${CYAN}Текущий SNI сервера:${NC} ${YELLOW}$current_sni${NC}"
    echo -e "${CYAN}Текущий порт:${NC} ${YELLOW}$current_port${NC}"
    echo ""
    
    read -p "Введите имя пользователя (тег): " username
    [[ -z "$username" ]] && username="user_$(date +%s)"
    
    secret=$(generate_secret)
    
    # Добавляем пользователя в конфиг
    echo "$username = \"$secret\"" >> $TELEMT_CONFIG
    
    # Перезапускаем
    systemctl restart telemt
    sleep 2
    
    # Получаем ссылку (в формате tg:// для правильной работы)
    server_ip=$(get_server_ip)
    link="tg://proxy?server=$server_ip&port=$current_port&secret=$secret"
    
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}${BOLD}ПОЛЬЗОВАТЕЛЬ ДОБАВЛЕН!${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}Имя:${NC} $username"
    echo -e "${YELLOW}Секрет:${NC} $secret"
    echo -e "${YELLOW}Ссылка для Telegram (tg://):${NC}"
    echo -e "${GREEN}$link${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    
    pause
}

list_users() {
    clear
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}           СПИСОК ПОЛЬЗОВАТЕЛЕЙ${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if ! check_telemt_installed; then
        pause
        return
    fi
    
    current_sni=$(grep -oP 'tls_domain = "\K[^"]+' $TELEMT_CONFIG 2>/dev/null || echo "не задан")
    current_port=$(grep -oP 'port = \K\d+' $TELEMT_CONFIG 2>/dev/null || echo "не задан")
    
    echo -e "${CYAN}Глобальный SNI сервера:${NC} ${YELLOW}$current_sni${NC}"
    echo -e "${CYAN}Порт:${NC} ${YELLOW}$current_port${NC}"
    echo ""
    
    users=$(get_users_list)
    
    if [[ -z "$users" ]]; then
        warn "Нет добавленных пользователей"
        pause
        return
    fi
    
    echo -e "${CYAN}Список пользователей:${NC}"
    echo "─────────────────────────────────────────────────────────────────────────────"
    printf "${CYAN}%-4s %-20s %-40s${NC}\n" "№" "ИМЯ" "СЕКРЕТ"
    echo "─────────────────────────────────────────────────────────────────────────────"
    
    line_num=1
    while IFS='=' read -r username secret_part; do
        username=$(echo "$username" | xargs)
        secret=$(echo "$secret_part" | xargs | tr -d '"')
        if [[ -n "$username" && "$username" != "#"* ]]; then
            printf "%-4s %-20s %-40s\n" "$line_num" "$username" "$secret"
            ((line_num++))
        fi
    done <<< "$users"
    
    echo "─────────────────────────────────────────────────────────────────────────────"
    info "Всего пользователей: $((line_num - 1))"
    
    pause
}

remove_user() {
    clear
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${RED}${BOLD}           УДАЛЕНИЕ ПОЛЬЗОВАТЕЛЯ${NC}"
    echo -e "${RED}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if ! check_telemt_installed; then
        pause
        return
    fi
    
    users=$(get_users_list)
    
    if [[ -z "$users" ]]; then
        warn "Нет добавленных пользователей"
        pause
        return
    fi
    
    # Показываем список пользователей с номерами
    echo -e "${CYAN}Существующие пользователи:${NC}"
    echo "─────────────────────────────────────────────────────────────────────────────"
    printf "${CYAN}%-4s %-20s %-40s${NC}\n" "№" "ИМЯ" "СЕКРЕТ"
    echo "─────────────────────────────────────────────────────────────────────────────"
    
    line_num=1
    declare -a usernames
    while IFS='=' read -r username secret_part; do
        username=$(echo "$username" | xargs)
        secret=$(echo "$secret_part" | xargs | tr -d '"')
        if [[ -n "$username" && "$username" != "#"* ]]; then
            printf "%-4s %-20s %-40s\n" "$line_num" "$username" "$secret"
            usernames[$line_num]=$username
            ((line_num++))
        fi
    done <<< "$users"
    echo "─────────────────────────────────────────────────────────────────────────────"
    echo ""
    
    read -p "Введите номер пользователя для удаления (1-$((line_num - 1))): " user_num
    
    if ! [[ "$user_num" =~ ^[0-9]+$ ]] || [[ $user_num -lt 1 ]] || [[ $user_num -ge $line_num ]]; then
        error "Неверный номер"
        pause
        return
    fi
    
    username_to_remove="${usernames[$user_num]}"
    
    echo ""
    warn "Вы собираетесь удалить пользователя: ${YELLOW}$username_to_remove${NC}"
    read -p "Подтвердите удаление (y/N): " confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        info "Удаление отменено"
        pause
        return
    fi
    
    # Удаляем пользователя из конфига
    sed -i "/^$username_to_remove = /d" $TELEMT_CONFIG
    
    systemctl restart telemt
    success "Пользователь $username_to_remove удален"
    
    pause
}

# ============================================
# Настройка SNI и порта
# ============================================
change_sni() {
    clear
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${MAGENTA}${BOLD}           СМЕНА SNI${NC}"
    echo -e "${MAGENTA}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if ! check_telemt_installed; then
        pause
        return
    fi
    
    current_sni=$(grep -oP 'tls_domain = "\K[^"]+' $TELEMT_CONFIG 2>/dev/null || echo "www.google.com")
    echo -e "Текущий SNI: ${YELLOW}$current_sni${NC}"
    echo ""
    
    read -p "Введите новый SNI (например: cloudflare.com, www.google.com): " new_sni
    
    if [[ -z "$new_sni" ]]; then
        error "SNI не может быть пустым"
        pause
        return
    fi
    
    step "Обновление конфигурации..."
    sed -i "s/tls_domain = \".*\"/tls_domain = \"$new_sni\"/" $TELEMT_CONFIG
    
    step "Перезапуск сервиса..."
    systemctl restart telemt
    
    success "SNI изменен на $new_sni"
    pause
}

change_port() {
    clear
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}${BOLD}           СМЕНА ПОРТА${NC}"
    echo -e "${CYAN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if ! check_telemt_installed; then
        pause
        return
    fi
    
    current_port=$(grep -oP 'port = \K\d+' $TELEMT_CONFIG 2>/dev/null || echo "7443")
    echo -e "Текущий порт: ${YELLOW}$current_port${NC}"
    echo ""
    
    read -p "Введите новый порт (1-65535, рекомендуется 443 или 8443): " new_port
    
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [[ $new_port -lt 1 ]] || [[ $new_port -gt 65535 ]]; then
        error "Неверный номер порта"
        pause
        return
    fi
    
    step "Обновление порта в конфигурации..."
    sed -i "s/port = [0-9]*/port = $new_port/" $TELEMT_CONFIG
    
    step "Перезапуск сервиса..."
    systemctl restart telemt
    
    if systemctl is-active --quiet telemt; then
        success "Порт изменен на $new_port"
        echo ""
        warn "Если вы используете фаервол, не забудьте открыть порт $new_port:"
        echo "  ufw allow $new_port/tcp"
    else
        error "Сервис не запустился. Проверьте логи: journalctl -u telemt -n 20"
    fi
    
    pause
}

# ============================================
# Статус и информация
# ============================================
show_status() {
    clear
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}${BOLD}           СТАТУС TELEMT${NC}"
    echo -e "${BLUE}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    
    if ! check_telemt_installed; then
        pause
        return
    fi
    
    if systemctl is-active --quiet telemt; then
        echo -e "${GREEN}● Сервис: АКТИВЕН${NC}"
    else
        echo -e "${RED}● Сервис: НЕ АКТИВЕН${NC}"
    fi
    
    if $TELEMT_BIN --version &>/dev/null; then
        version=$($TELEMT_BIN --version 2>&1 | head -1)
        echo -e "${CYAN}● Версия:${NC} $version"
    fi
    
    current_port=$(grep -oP 'port = \K\d+' $TELEMT_CONFIG 2>/dev/null || echo "не задан")
    echo -e "${CYAN}● Порт:${NC} $current_port"
    
    current_sni=$(grep -oP 'tls_domain = "\K[^"]+' $TELEMT_CONFIG 2>/dev/null || echo "не задан")
    echo -e "${CYAN}● SNI:${NC} $current_sni"
    
    users_count=$(get_users_count)
    echo -e "${CYAN}● Пользователей:${NC} $users_count"
    
    server_ip=$(get_server_ip)
    echo -e "${CYAN}● IPv4 сервера:${NC} $server_ip"
    
    echo ""
    echo -e "${YELLOW}Метрики Prometheus:${NC} http://127.0.0.1:9091/metrics"
    echo -e "${YELLOW}API:${NC} http://127.0.0.1:9091/v1/users"
    
    echo ""
    echo -e "${BLUE}Последние логи:${NC}"
    journalctl -u telemt -n 5 --no-pager 2>/dev/null || echo "  (логи недоступны)"
    
    pause
}

# ============================================
# Главное меню
# ============================================
show_menu() {
    clear
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}${BOLD}║${NC}                         ${MAGENTA}TELEMT${NC}                              ${CYAN}${BOLD}║${NC}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo -e "          ${YELLOW}Передай привеД ПОТАПу !!!${NC}"
    echo ""
    echo -e "${GREEN}  УСТАНОВКА И УДАЛЕНИЕ${NC}"
    echo -e "  ${GREEN}1)${NC} Установить telemt"
    echo -e "  ${RED}2)${NC} Удалить telemt (полностью)"
    echo ""
    echo -e "${YELLOW}  УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ${NC}"
    echo -e "  ${YELLOW}3)${NC} Добавить пользователя"
    echo -e "  ${YELLOW}4)${NC} Список пользователей"
    echo -e "  ${YELLOW}5)${NC} Удалить пользователя"
    echo ""
    echo -e "${BLUE}  НАСТРОЙКА${NC}"
    echo -e "  ${BLUE}6)${NC} Сменить SNI (TLS маскировку)"
    echo -e "  ${BLUE}7)${NC} Сменить порт"
    echo ""
    echo -e "${CYAN}  ИНФОРМАЦИЯ${NC}"
    echo -e "  ${CYAN}8)${NC} Статус и информация"
    echo ""
    echo -e "${RED}  0)${NC} Выход"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    read -p "Выберите пункт меню: " choice
}

# ============================================
# Основной цикл
# ============================================
main() {
    check_root
    
    while true; do
        show_menu
        case $choice in
            1) install_telemt ;;
            2) uninstall_telemt ;;
            3) add_user ;;
            4) list_users ;;
            5) remove_user ;;
            6) change_sni ;;
            7) change_port ;;
            8) show_status ;;
            0) 
                clear
                info "До свидания!"
                exit 0
                ;;
            *) 
                error "Неверный выбор. Пожалуйста, выберите от 0 до 8"
                sleep 2
                ;;
        esac
    done
}

main
