#!/usr/bin/env bash
# Самостоятельный установщик: оба скрипта встроены в этот файл.
# Источники: dotX12/traffic-guard и предоставленный пользователем менеджер.
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

main() {
    local files_only=false
    case "${1:-}" in
        --files-only) files_only=true ;;
        --help|-h)
            echo 'Использование: sudo bash install.sh [--files-only]'
            echo 'Без параметров: установить TrafficGuard и меню rknpidor.'
            echo '--files-only: восстановить файлы меню без переустановки ПО.'
            return 0 ;;
        '') ;;
        *) echo "Неизвестный параметр: $1" >&2; return 1 ;;
    esac
    [[ $# -le 1 ]] || { echo 'Слишком много параметров.' >&2; return 1; }
    [[ "$(uname -s)" == Linux ]] || { echo 'Нужен сервер Ubuntu/Debian с systemd.' >&2; return 1; }
    [[ $EUID -eq 0 ]] || { echo 'Запустите через sudo bash install.sh.' >&2; return 1; }
    command -v apt-get >/dev/null || { echo 'Требуется apt-get.' >&2; return 1; }
    [[ -d /run/systemd/system ]] || { echo 'Требуется работающий systemd.' >&2; return 1; }

    STAGING_DIR=$(mktemp -d /tmp/trafficguard-installer.XXXXXXXX)
    trap 'rm -rf -- "$STAGING_DIR"' EXIT
    cat > "$STAGING_DIR/install-core.sh" <<'TG_CORE_EMBEDDED_20260920'
#!/usr/bin/env bash

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Константы
REPO="dotX12/traffic-guard"
BINARY_NAME="traffic-guard"
INSTALL_DIR="/usr/local/bin"
LATEST_RELEASE_URL="https://github.com/${REPO}/releases/latest/download"
DEV_MODE=false

# Функция для вывода сообщений
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Проверка прав root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "Необходимо запустить скрипт с правами root (sudo)"
        exit 1
    fi
}

# Определение архитектуры и ОС
detect_system() {
    local os=""
    local arch=""

    # Определение ОС
    case "$(uname -s)" in
        Linux*)
            os="linux"
            ;;
        *)
            log_error "Неподдерживаемая ОС: $(uname -s). Поддерживается только Linux"
            exit 1
            ;;
    esac

    # Определение архитектуры
    case "$(uname -m)" in
        x86_64|amd64)
            arch="amd64"
            ;;
        i386|i686)
            arch="386"
            ;;
        armv7l|armv6l)
            arch="arm"
            ;;
        aarch64|arm64)
            arch="arm64"
            ;;
        *)
            log_error "Неподдерживаемая архитектура: $(uname -m)"
            exit 1
            ;;
    esac

    echo "${os}-${arch}"
}

# Получение последнего релиза (включая pre-release если --dev)
get_latest_release_tag() {
    local api_url="https://api.github.com/repos/${REPO}/releases"

    if [ "$DEV_MODE" = true ]; then
        log_info "Режим DEV: поиск последнего релиза (включая pre-release)..."
        api_url="${api_url}?per_page=1"
    else
        api_url="${api_url}/latest"
    fi

    local tag=""
    if command -v curl &> /dev/null; then
        tag=$(curl -fsSL "${api_url}" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/"tag_name": *"\(.*\)"/\1/')
    elif command -v wget &> /dev/null; then
        tag=$(wget -qO- "${api_url}" | grep -o '"tag_name": *"[^"]*"' | head -1 | sed 's/"tag_name": *"\(.*\)"/\1/')
    else
        log_error "Не найден curl или wget. Установите один из них"
        exit 1
    fi

    if [ -z "$tag" ]; then
        log_error "Не удалось определить версию релиза"
        exit 1
    fi

    echo "$tag"
}

# Скачивание бинарника
download_binary() {
    local platform=$1
    local temp_file
    temp_file=$(mktemp /tmp/traffic-guard.XXXXXXXX)
    local download_url=""

    if [ "$DEV_MODE" = true ]; then
        local tag
        tag=$(get_latest_release_tag)
        log_info "Найдена версия: ${tag}"
        download_url="https://github.com/${REPO}/releases/download/${tag}/${BINARY_NAME}-${platform}"
    else
        download_url="${LATEST_RELEASE_URL}/${BINARY_NAME}-${platform}"
    fi

    log_info "Скачивание ${BINARY_NAME} для ${platform}..."
    log_info "URL: ${download_url}"

    if command -v curl &> /dev/null; then
        if ! curl -fsSL "${download_url}" -o "${temp_file}"; then
            rm -f -- "$temp_file"
            log_error "Ошибка при скачивании бинарника"
            exit 1
        fi
    elif command -v wget &> /dev/null; then
        if ! wget -q "${download_url}" -O "${temp_file}"; then
            rm -f -- "$temp_file"
            log_error "Ошибка при скачивании бинарника"
            exit 1
        fi
    else
        log_error "Не найден curl или wget. Установите один из них"
        exit 1
    fi

    echo "${temp_file}"
}

# Установка бинарника
install_binary() {
    local temp_file=$1
    local install_path="${INSTALL_DIR}/${BINARY_NAME}"

    log_info "Установка в ${install_path}..."

    # Создаём директорию если не существует
    mkdir -p "${INSTALL_DIR}"

    # Копируем файл
    install -m 755 "${temp_file}" "${install_path}"

    # Выдаём права на выполнение
    chmod +x "${install_path}"

    # Удаляем временный файл
    rm -f "${temp_file}"

    log_info "Установка завершена успешно!"
}

# Проверка установки
verify_installation() {
    if command -v ${BINARY_NAME} &> /dev/null; then
        local version
        version=$("${INSTALL_DIR}/${BINARY_NAME}" --version 2>&1)
        log_info "✓ ${BINARY_NAME} успешно установлен"
        log_info "Версия: ${version}"
        log_info "Путь: $(command -v "${BINARY_NAME}")"
        return 0
    else
        log_error "Установка не удалась"
        return 1
    fi
}

# Вывод информации об использовании
show_usage() {
    log_info ""
    log_info "⚠️  ВАЖНО: Обязательно укажите URL с списками подсетей через параметр -u"
    echo "" >&2
    log_info "Публичные списки доступны здесь:"
    echo "  https://github.com/shadow-netlab/traffic-guard-lists/tree/main" >&2
    log_info "Для получения полной справки:"
    echo "" >&2
    echo "  ${BINARY_NAME} --help" >&2
    echo "" >&2
}

# Вывод справки
show_help() {
    echo "Использование: $0 [OPTIONS]" >&2
    echo "" >&2
    echo "Опции:" >&2
    echo "  --dev       Установить последний релиз (включая pre-release)" >&2
    echo "  --help      Показать эту справку" >&2
    echo "" >&2
    exit 0
}

# Парсинг аргументов
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --dev)
                DEV_MODE=true
                shift
                ;;
            --help|-h)
                show_help
                ;;
            *)
                log_error "Неизвестный параметр: $1"
                echo "Используйте --help для справки" >&2
                exit 1
                ;;
        esac
    done
}

# Главная функция
main() {
    # Парсинг аргументов
    parse_args "$@"

    log_info "=== Установка Traffic Guard ==="
    if [ "$DEV_MODE" = true ]; then
        log_warn "Режим DEV: будет установлена последняя версия (включая pre-release)"
    fi
    echo "" >&2

    # Проверка прав
    check_root

    # Определение системы
    local platform
    platform=$(detect_system)
    log_info "Определена система: ${platform}"

    # Скачивание
    local temp_file
    temp_file=$(download_binary "${platform}")

    # Установка
    install_binary "${temp_file}"

    # Проверка
    if verify_installation; then
        echo "" >&2
        show_usage
        exit 0
    else
        exit 1
    fi
}

# Запуск
main "$@"
TG_CORE_EMBEDDED_20260920
    cat > "$STAGING_DIR/trafficguard-manager.sh" <<'TG_MANAGER_EMBEDDED_20260920'
#!/bin/bash
set -u

# --- ЦВЕТА ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

TG_INSTALLER="/opt/trafficguard-install-core.sh"
LIST_GOV="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/government_networks.list"
LIST_SCAN="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/antiscanner.list"
LIST_SKIPA="https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/refs/heads/main/public/skipa.list"
MANUAL_FILE="/opt/trafficguard-manual.list"

check_root() {
    [[ $EUID -ne 0 ]] && { echo -e "${RED}Запуск только от root!${NC}"; exit 1; }
    return 0
}

check_firewall_safety() {
    echo -e "${BLUE}[CHECK] Проверка конфигурации Firewall...${NC}"
    if command -v ufw >/dev/null; then
        UFW_STATUS=$(ufw status | grep "Status" | awk '{print $2}')
        UFW_RULES=$(ufw show added 2>/dev/null)
        if [[ "$UFW_STATUS" == "inactive" ]]; then
            if [[ "$UFW_RULES" != *"22"* ]] && [[ "$UFW_RULES" != *"SSH"* ]] && [[ "$UFW_RULES" != *"OpenSSH"* ]]; then
                echo -e "\n${RED}⛔ АВАРИЙНАЯ ОСТАНОВКА!${NC}"
                echo -e "${YELLOW}UFW выключен и нет правил SSH.${NC}"
                echo "Выполните: ufw allow ssh"
                exit 1
            fi
        fi
    else
        if ! dpkg -l | grep -q netfilter-persistent; then
            DEBIAN_FRONTEND=noninteractive apt-get update -qq && \
            DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent netfilter-persistent
        fi
    fi
}

uninstall_process() {
    echo -e "\n${RED}=== УДАЛЕНИЕ TRAFFICGUARD ===${NC}"
    trap 'echo -e "\nОтмена."; return' INT
    read -p "Вы уверены? (y/N): " confirm < /dev/tty
    trap 'exit 0' INT

    [[ "$confirm" != "y" ]] && return

    # Удаляем файлы менеджера
    rm -f /usr/local/bin/rknpidor /opt/trafficguard-manager.sh "$TG_INSTALLER" "$MANUAL_FILE"

    # Используем встроенный uninstall traffic-guard (чистит UFW, ipset, iptables, systemd, rsyslog)
    if command -v traffic-guard >/dev/null 2>&1; then
        traffic-guard uninstall --yes
    else
        # Fallback: ручная чистка (если бинарник уже удалён)
        systemctl stop antiscan-aggregate.timer antiscan-aggregate.service 2>/dev/null
        systemctl disable antiscan-aggregate.timer antiscan-aggregate.service 2>/dev/null
        rm -f /usr/local/bin/traffic-guard /usr/local/bin/antiscan-aggregate-logs.sh
        rm -f /etc/systemd/system/antiscan-*
        rm -f /etc/rsyslog.d/10-iptables-scanners.conf /etc/logrotate.d/iptables-scanners

        iptables -D INPUT -j SCANNERS-BLOCK 2>/dev/null
        iptables -F SCANNERS-BLOCK 2>/dev/null
        iptables -X SCANNERS-BLOCK 2>/dev/null
        ipset flush SCANNERS-BLOCK-V4 2>/dev/null
        ipset destroy SCANNERS-BLOCK-V4 2>/dev/null
        ipset flush SCANNERS-BLOCK-V6 2>/dev/null
        ipset destroy SCANNERS-BLOCK-V6 2>/dev/null

        # Чистим UFW (причина бага: правила оставались в before.rules)
        sed -i '/SCANNERS-BLOCK/d' /etc/ufw/before.rules 2>/dev/null
        sed -i '/SCANNERS-BLOCK/d' /etc/ufw/before6.rules 2>/dev/null
        ufw reload 2>/dev/null
    fi

    systemctl restart rsyslog 2>/dev/null
    echo -e "${GREEN}✅ Удалено.${NC}"
    exit 0
}

# --- 🧪 УПРАВЛЕНИЕ IP ---
manage_test_ip() {
    # Создаем файл списка, если нет
    touch "$MANUAL_FILE"
    trap 'continue' INT
    
    while true; do
        clear
        echo -e "${YELLOW}=== 🧪 УПРАВЛЕНИЕ IP ===${NC}"
        echo -e " ${RED}1.${NC} ⛔ ЗАБАНИТЬ IP (Add)"
        echo -e " ${GREEN}2.${NC} ✅ РАЗБАНИТЬ IP (Select from list)"
        echo -e " ${CYAN}0.${NC} ↩️  Назад"
        echo ""
        echo -ne "${YELLOW}👉 Действие:${NC} "
        
        read -r action < /dev/tty || continue

        case $action in
            1)
                echo -e "\nВведите IP для БЛОКИРОВКИ ${YELLOW}(Ctrl+C = Отмена)${NC}:"
                trap 'echo -e "\nОтмена."; sleep 1; continue' INT
                read -p "IP: " ip < /dev/tty
                [[ -z "$ip" ]] && continue
                
                OUTPUT=$(ipset add SCANNERS-BLOCK-V4 "$ip" 2>&1)
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✅ IP $ip ЗАБЛОКИРОВАН!${NC}"
                    # Добавляем в файл, если его там еще нет
                    if ! grep -Fxq "$ip" "$MANUAL_FILE"; then
                        echo "$ip" >> "$MANUAL_FILE"
                    fi
                else
                    echo -e "${RED}❌ Ошибка:${NC} $OUTPUT"
                fi
                read -p "[Enter]..." < /dev/tty
                ;;
            2)
                echo -e "\n${GREEN}=== СПИСОК РУЧНЫХ БАНОВ ===${NC}"
                if [ ! -s "$MANUAL_FILE" ]; then
                    echo "Список пуст."
                else
                    # Читаем файл в массив
                    mapfile -t MANUAL_IPS < "$MANUAL_FILE"
                    i=1
                    for ip in "${MANUAL_IPS[@]}"; do
                        echo -e "${CYAN}$i)${NC} $ip"
                        ((i++))
                    done
                fi
                
                echo -e "\nВведите ${CYAN}НОМЕР${NC} из списка или ${CYAN}IP${NC} вручную:"
                trap 'echo -e "\nОтмена."; sleep 1; continue' INT
                read -p "Выбор: " input < /dev/tty
                [[ -z "$input" ]] && continue
                
                TARGET_IP=""
                
                # Проверяем, число это или IP
                if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -le "${#MANUAL_IPS[@]}" ] && [ "$input" -gt 0 ]; then
                    # Это номер из списка (массив начинается с 0, ввод с 1)
                    INDEX=$((input-1))
                    TARGET_IP="${MANUAL_IPS[$INDEX]}"
                else
                    # Это вероятно IP
                    TARGET_IP="$input"
                fi
                
                echo -e "Разбаниваем: ${YELLOW}$TARGET_IP${NC}..."
                
                OUTPUT=$(ipset del SCANNERS-BLOCK-V4 "$TARGET_IP" 2>&1)
                # Удаляем из файла в любом случае
                sed -i "/^$TARGET_IP$/d" "$MANUAL_FILE"
                
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✅ Успешно разбанен!${NC}"
                else
                    echo -e "${RED}⚠️  Warning:${NC} $OUTPUT (Удален из списка)"
                fi
                read -p "[Enter]..." < /dev/tty
                ;;
            0) 
                trap 'exit 0' INT
                return 
                ;;
            *) ;;
        esac
    done
}

update_lists() {
    echo -e "\n${CYAN}🔄 Обновление списков...${NC}"
    traffic-guard full -u "$LIST_GOV" -u "$LIST_SCAN" -u "$LIST_SKIPA" --enable-logging
    echo -e "${GREEN}✅ Готово!${NC}"
    sleep 2
}

install_process() (
    set -Ee -o pipefail
    trap 'echo "Ошибка установки, строка $LINENO. Меню: sudo rknpidor" >&2' ERR
    trap 'exit 1' INT
    clear 2>/dev/null || true
    echo -e "${CYAN}🚀 УСТАНОВКА TRAFFICGUARD PRO${NC}"
    check_firewall_safety
    
    echo -e "\n${BLUE}[INFO] Установка...${NC}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl wget rsyslog ipset iptables ufw grep sed coreutils whois
    systemctl enable --now rsyslog

    if ! bash "$TG_INSTALLER"; then
        echo -e "${RED}Ошибка установщика TrafficGuard.${NC}" >&2
        exit 1
    fi

    echo -e "\n${BLUE}[INFO] Настройка правил...${NC}"
    traffic-guard full -u "$LIST_GOV" -u "$LIST_SCAN" -u "$LIST_SKIPA" --enable-logging

    if [ $? -ne 0 ]; then
        echo -e "\n${RED}❌ ОШИБКА УСТАНОВКИ!${NC}"
        exit 1
    fi

    mkdir -p /var/log
    touch /var/log/iptables-scanners-{ipv4,ipv6}.log
    LOG_GROUP="syslog"; getent group adm >/dev/null && LOG_GROUP="adm"
    chown syslog:$LOG_GROUP /var/log/iptables-scanners-*.log
    chmod 640 /var/log/iptables-scanners-*.log
    
    # Создаем файл для ручных банов, если нет
    touch "$MANUAL_FILE"
    
    systemctl restart rsyslog
    if systemctl cat antiscan-aggregate.timer >/dev/null 2>&1; then
        systemctl restart antiscan-aggregate.timer
    else
        echo 'Таймер antiscan-aggregate.timer отсутствует: агрегация логов недоступна.' >&2
    fi
    
    echo -e "\n${GREEN}✅ Установка завершена!${NC}"
    sleep 2
)

view_log() {
    local file=$1
    echo -e "\n${YELLOW}=== LIVE LOG (Ctrl+C для возврата) ===${NC}"
    trap ':' INT
    tail -f "$file"
    trap 'exit 0' INT
}

show_menu() {
    trap 'exit 0' INT
    while true; do
        clear
        IPSET_CNT=$(ipset list SCANNERS-BLOCK-V4 2>/dev/null | grep "Number of entries" | awk '{print $4}')
        [[ -z "$IPSET_CNT" ]] && IPSET_CNT="${RED}0${NC}"
        PKTS_CNT=$(iptables -vnL SCANNERS-BLOCK 2>/dev/null | grep "LOG" | awk '{print $1}')
        [[ -z "$PKTS_CNT" ]] && PKTS_CNT="0"
        
        echo -e "${CYAN}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║           🛡️  TRAFFICGUARD PRO MANAGER              ║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════╣${NC}"
        echo -e "║  📊 Подсетей:       ${GREEN}${IPSET_CNT}${NC}                             "
        echo -e "║  🔥 Атак отбито:    ${RED}${PKTS_CNT}${NC}                             "
        echo -e "${CYAN}╚══════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e " ${GREEN}1.${NC} 📈 Топ атак (CSV)"
        echo -e " ${GREEN}2.${NC} 🕵 Логи IPv4 (Live)"
        echo -e " ${GREEN}3.${NC} 🕵 Логи IPv6 (Live)"
        echo -e " ${GREEN}4.${NC} 🧪 Управление IP (Ban/Unban)"
        echo -e " ${GREEN}5.${NC} 🔄 Обновить списки (Update)"
        echo -e " ${GREEN}6.${NC} 🛠️  Переустановить (Reinstall)"
        echo -e " ${RED}7.${NC} 🗑️  Удалить (Uninstall)"
        echo -e " ${RED}0.${NC} ❌ Выход"
        echo ""
        
        echo -ne "${CYAN}👉 Ваш выбор:${NC} "
        read -r choice < /dev/tty

        case $choice in
            1)
                echo -e "\n${GREEN}ТОП 20:${NC}"
                [ -f /var/log/iptables-scanners-aggregate.csv ] && tail -20 /var/log/iptables-scanners-aggregate.csv || echo "Нет данных"
                read -p $'\n[Enter] назад...' < /dev/tty
                ;;
            2) view_log "/var/log/iptables-scanners-ipv4.log" ;;
            3) view_log "/var/log/iptables-scanners-ipv6.log" ;;
            4) manage_test_ip ;;
            5) update_lists ;;
            6) 
                rm -f /var/log/iptables-scanners-aggregate.csv
                install_process 
                ;;
            7) uninstall_process ;;
            0) exit 0 ;;
            *) echo "Неверно"; sleep 1 ;;
        esac
    done
}

check_root
case "${1:-}" in
    install) install_process ;;
    monitor) show_menu ;;
    update) update_lists ;;
    uninstall) uninstall_process ;;
    *) show_menu ;; 
esac
TG_MANAGER_EMBEDDED_20260920

    bash -n "$STAGING_DIR/install-core.sh"
    bash -n "$STAGING_DIR/trafficguard-manager.sh"
    local backup_dir
    backup_dir=$(mktemp -d /root/trafficguard-backup.XXXXXXXX)
    local target
    for target in /opt/trafficguard-manager.sh /opt/trafficguard-install-core.sh /usr/local/bin/rknpidor; do
        if [[ -e "$target" || -L "$target" ]]; then
            cp -a -- "$target" "$backup_dir/"
        fi
    done
    install -d -m 755 /opt /usr/local/bin
    install -m 755 "$STAGING_DIR/install-core.sh" /opt/trafficguard-install-core.sh
    install -m 755 "$STAGING_DIR/trafficguard-manager.sh" /opt/trafficguard-manager.sh
    ln -sfnT /opt/trafficguard-manager.sh /usr/local/bin/rknpidor
    echo "Меню установлено: sudo rknpidor. Предыдущие файлы: $backup_dir"
    if [[ "$files_only" == false ]]; then
        # Вход установщика не передаётся дочерним программам при curl | bash.
        bash /opt/trafficguard-manager.sh install </dev/null
    fi
    echo 'Готово. Для открытия меню выполните: sudo rknpidor'
}

main "$@"

bash rknpidor
