#!/bin/bash

# ============================================
#   SOCKS5 (Dante) — автоустановка
#   Telegram + Browser
# ============================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

echo -e "${CYAN}"
echo "============================================"
echo "   SOCKS5 прокси — Telegram + Браузер"
echo "============================================"
echo -e "${NC}"

# --- Проверка root ---
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Запустите скрипт от root: sudo bash setup_socks5.sh${NC}"
    exit 1
fi

# --- Определяем интерфейс автоматически ---
INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
echo -e "${GREEN}[✓] Сетевой интерфейс: ${INTERFACE}${NC}"

# --- Определяем внешний IP автоматически ---
SERVER_IP=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
echo -e "${GREEN}[✓] Внешний IP сервера: ${SERVER_IP}${NC}"
echo ""

# --- Запрашиваем только нужное ---

# Порт
read -p "$(echo -e ${YELLOW})[?] Порт прокси [по умолчанию 443]: $(echo -e ${NC})" PORT
PORT=${PORT:-443}

# Логин
read -p "$(echo -e ${YELLOW})[?] Логин пользователя [по умолчанию tguser]: $(echo -e ${NC})" USERNAME
USERNAME=${USERNAME:-tguser}

# Пароль
while true; do
    read -s -p "$(echo -e ${YELLOW})[?] Пароль: $(echo -e ${NC})" PASSWORD
    echo ""
    read -s -p "$(echo -e ${YELLOW})[?] Повторите пароль: $(echo -e ${NC})" PASSWORD2
    echo ""
    if [[ "$PASSWORD" == "$PASSWORD2" ]]; then
        break
    else
        echo -e "${RED}[!] Пароли не совпадают, попробуйте снова${NC}"
    fi
done

echo ""
echo -e "${CYAN}[*] Устанавливаю Dante...${NC}"

# --- Установка ---
apt-get update -qq
apt-get install -y dante-server qrencode python3 > /dev/null 2>&1
echo -e "${GREEN}[✓] Dante установлен${NC}"

# --- Конфиг ---
cat > /etc/danted.conf <<EOF
logoutput: /var/log/danted.log

internal: 0.0.0.0 port = ${PORT}
external: ${INTERFACE}

clientmethod: none
socksmethod: username

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    socksmethod: username
}
EOF
echo -e "${GREEN}[✓] Конфиг записан${NC}"

# --- Пользователь ---
if id "$USERNAME" &>/dev/null; then
    echo -e "${YELLOW}[~] Пользователь ${USERNAME} уже существует, обновляю пароль${NC}"
else
    useradd -r -s /bin/false "$USERNAME"
fi
echo "${USERNAME}:${PASSWORD}" | chpasswd
echo -e "${GREEN}[✓] Пользователь ${USERNAME} настроен${NC}"

# --- Запуск ---
systemctl enable danted > /dev/null 2>&1
systemctl restart danted
echo -e "${GREEN}[✓] Dante запущен${NC}"

# --- Firewall ---
if command -v ufw &> /dev/null; then
    ufw allow ${PORT}/tcp > /dev/null 2>&1
    echo -e "${GREEN}[✓] Порт ${PORT} открыт в UFW${NC}"
fi

# ============================================
#   Функция генерации ссылок
# ============================================
generate_links() {
    local USER="$1"
    local PASS="$2"

    # --- Telegram ---
    local TG_LINK="https://t.me/socks?server=${SERVER_IP}&port=${PORT}&user=${USER}&pass=${PASS}"
    local ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${TG_LINK}', safe=''))" 2>/dev/null)
    local TG_SHORT=$(curl -s "https://clck.ru/--?url=${ENCODED}" 2>/dev/null || echo "")
    local QR_FILE="/root/proxy_qr_${USER}.png"
    qrencode -o "$QR_FILE" "$TG_LINK" 2>/dev/null && local QR_OK=true || local QR_OK=false

    echo ""
    echo -e "${BLUE}  📱 Telegram:${NC}"
    echo -e "  Полная:   ${CYAN}${TG_LINK}${NC}"
    if [[ -n "$TG_SHORT" && "$TG_SHORT" != *"error"* && ${#TG_SHORT} -lt 60 ]]; then
        echo -e "  Короткая: ${CYAN}${TG_SHORT}${NC}"
    fi
    if [[ "$QR_OK" == true ]]; then
        echo -e "  QR-код:   ${CYAN}${QR_FILE}${NC}"
    fi

    # --- Браузер ---
    local BROWSER_LINK="socks5://${USER}:${PASS}@${SERVER_IP}:${PORT}"
    local BR_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${BROWSER_LINK}', safe=''))" 2>/dev/null)
    local BR_SHORT=$(curl -s "https://clck.ru/--?url=${BR_ENCODED}" 2>/dev/null || echo "")
    local BR_QR_FILE="/root/proxy_browser_qr_${USER}.png"
    qrencode -o "$BR_QR_FILE" "$BROWSER_LINK" 2>/dev/null

    echo ""
    echo -e "${MAGENTA}  🌐 Браузер (SwitchyOmega / Firefox):${NC}"
    echo -e "  Строка:   ${CYAN}${BROWSER_LINK}${NC}"
    if [[ -n "$BR_SHORT" && "$BR_SHORT" != *"error"* && ${#BR_SHORT} -lt 60 ]]; then
        echo -e "  Короткая: ${CYAN}${BR_SHORT}${NC}"
    fi
    echo -e "  QR-код:   ${CYAN}${BR_QR_FILE}${NC}"
    echo ""
    echo -e "${YELLOW}  Firefox → Настройки → Прокси → Вручную → SOCKS5 → включить DNS через SOCKS5${NC}"
    echo -e "${YELLOW}  Chrome  → Расширение Proxy SwitchyOmega → New Profile → SOCKS5${NC}"
}

# --- Итог ---
sleep 1
STATUS=$(systemctl is-active danted)
if [[ "$STATUS" == "active" ]]; then
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}   Прокси успешно запущен!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "${BLUE}  📡 Данные подключения:${NC}"
    echo -e "  Тип:     ${CYAN}SOCKS5${NC}"
    echo -e "  Сервер:  ${CYAN}${SERVER_IP}${NC}"
    echo -e "  Порт:    ${CYAN}${PORT}${NC}"
    echo -e "  Логин:   ${CYAN}${USERNAME}${NC}"
    echo -e "  Пароль:  ${CYAN}${PASSWORD}${NC}"
    generate_links "$USERNAME" "$PASSWORD"
else
    echo -e "${RED}[!] Dante не запустился. Проверьте лог:${NC}"
    echo "    journalctl -u danted -n 20"
    exit 1
fi

# --- Добавление дополнительных пользователей ---
echo ""
read -p "$(echo -e ${YELLOW})[?] Хотите добавить ещё пользователя? (y/n): $(echo -e ${NC})" ADD_MORE

while [[ "$ADD_MORE" == "y" || "$ADD_MORE" == "Y" ]]; do
    read -p "$(echo -e ${YELLOW})[?] Логин: $(echo -e ${NC})" NEW_USER
    while true; do
        read -s -p "$(echo -e ${YELLOW})[?] Пароль: $(echo -e ${NC})" NEW_PASS
        echo ""
        read -s -p "$(echo -e ${YELLOW})[?] Повторите пароль: $(echo -e ${NC})" NEW_PASS2
        echo ""
        if [[ "$NEW_PASS" == "$NEW_PASS2" ]]; then
            break
        else
            echo -e "${RED}[!] Пароли не совпадают${NC}"
        fi
    done

    if id "$NEW_USER" &>/dev/null; then
        echo "${NEW_USER}:${NEW_PASS}" | chpasswd
    else
        useradd -r -s /bin/false "$NEW_USER"
        echo "${NEW_USER}:${NEW_PASS}" | chpasswd
    fi

    echo -e "${GREEN}[✓] Пользователь ${NEW_USER} добавлен!${NC}"
    generate_links "$NEW_USER" "$NEW_PASS"

    read -p "$(echo -e ${YELLOW})[?] Добавить ещё? (y/n): $(echo -e ${NC})" ADD_MORE
done

echo ""
echo -e "${GREEN}Готово!${NC}"
