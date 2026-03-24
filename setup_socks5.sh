#!/bin/bash

# ============================================
#   SOCKS5 (Dante) — автоустановка для Telegram
# ============================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "============================================"
echo "   SOCKS5 прокси для Telegram (Dante)"
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
apt-get install -y dante-server > /dev/null 2>&1
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

# --- Проверка ---
sleep 1
STATUS=$(systemctl is-active danted)
if [[ "$STATUS" == "active" ]]; then
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}   Прокси успешно запущен!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "  Тип:     ${CYAN}SOCKS5${NC}"
    echo -e "  Сервер:  ${CYAN}${SERVER_IP}${NC}"
    echo -e "  Порт:    ${CYAN}${PORT}${NC}"
    echo -e "  Логин:   ${CYAN}${USERNAME}${NC}"
    echo -e "  Пароль:  ${CYAN}${PASSWORD}${NC}"
    echo ""
    echo -e "${YELLOW}  Telegram → Настройки → Конфиденциальность → Прокси → SOCKS5${NC}"
    echo ""
else
    echo -e "${RED}[!] Dante не запустился. Проверьте лог:${NC}"
    echo "    journalctl -u danted -n 20"
fi
