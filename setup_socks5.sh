#!/bin/bash

set -euo pipefail

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

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Запустите скрипт от root: sudo bash setup_socks5.sh${NC}"
    exit 1
fi

command -v ip >/dev/null 2>&1 || { echo -e "${RED}[!] Не найден iproute2${NC}"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo -e "${RED}[!] Не найден curl${NC}"; exit 1; }

INTERFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
if [[ -z "${INTERFACE}" ]]; then
    INTERFACE="$(ip route | awk '/default/ {print $5; exit}')"
fi

if [[ -z "${INTERFACE}" ]]; then
    echo -e "${RED}[!] Не удалось определить сетевой интерфейс${NC}"
    exit 1
fi

SERVER_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
if [[ -z "${SERVER_IP}" ]]; then
    SERVER_IP="$(hostname -I | awk '{print $1}')"
fi

echo -e "${GREEN}[✓] Сетевой интерфейс: ${INTERFACE}${NC}"
echo -e "${GREEN}[✓] Внешний IP сервера: ${SERVER_IP}${NC}"
echo ""

read -r -p "$(echo -e ${YELLOW})[?] Порт прокси [по умолчанию 443]: $(echo -e ${NC})" PORT
PORT="${PORT:-443}"

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || (( PORT < 1 || PORT > 65535 )); then
    echo -e "${RED}[!] Некорректный порт${NC}"
    exit 1
fi

read -r -p "$(echo -e ${YELLOW})[?] Логин пользователя [по умолчанию tguser]: $(echo -e ${NC})" USERNAME
USERNAME="${USERNAME:-tguser}"

while true; do
    read -r -s -p "$(echo -e ${YELLOW})[?] Пароль: $(echo -e ${NC})" PASSWORD
    echo ""
    read -r -s -p "$(echo -e ${YELLOW})[?] Повторите пароль: $(echo -e ${NC})" PASSWORD2
    echo ""
    if [[ -n "$PASSWORD" && "$PASSWORD" == "$PASSWORD2" ]]; then
        break
    else
        echo -e "${RED}[!] Пароли не совпадают или пустые, попробуйте снова${NC}"
    fi
done

echo ""
echo -e "${CYAN}[*] Устанавливаю Dante...${NC}"
apt-get update -qq
apt-get install -y dante-server qrencode python3 curl >/dev/null 2>&1
echo -e "${GREEN}[✓] Dante установлен${NC}"

cp /etc/danted.conf "/etc/danted.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

cat > /etc/danted.conf <<EOF
logoutput: syslog

internal: 0.0.0.0 port = ${PORT}
external: ${INTERFACE}

user.privileged: root
user.unprivileged: nobody

clientmethod: none
socksmethod: username

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect disconnect error
}

client block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect
    socksmethod: username
    log: connect disconnect error
}

socks block {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: connect error
}
EOF

echo -e "${GREEN}[✓] Конфиг записан${NC}"

if id "$USERNAME" &>/dev/null; then
    echo -e "${YELLOW}[~] Пользователь ${USERNAME} уже существует, обновляю пароль${NC}"
else
    useradd -r -s /usr/sbin/nologin "$USERNAME"
fi

echo "${USERNAME}:${PASSWORD}" | chpasswd
echo -e "${GREEN}[✓] Пользователь ${USERNAME} настроен${NC}"

if ! /usr/sbin/danted -D -f /etc/danted.conf >/tmp/danted_test.log 2>&1; then
    echo -e "${RED}[!] Конфиг Dante не прошел проверку${NC}"
    cat /tmp/danted_test.log
    exit 1
fi

systemctl enable danted >/dev/null 2>&1
systemctl restart danted

if ! systemctl is-active --quiet danted; then
    echo -e "${RED}[!] Dante не запустился${NC}"
    journalctl -u danted -n 30 --no-pager
    exit 1
fi

echo -e "${GREEN}[✓] Dante запущен${NC}"

if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
    echo -e "${GREEN}[✓] Порт ${PORT} открыт в UFW${NC}"
fi

generate_links() {
    local USER="$1"
    local PASS="$2"

    local TG_LINK="https://t.me/socks?server=${SERVER_IP}&port=${PORT}&user=${USER}&pass=${PASS}"
    local TG_QR_FILE="/root/proxy_qr_${USER}.png"
    qrencode -o "$TG_QR_FILE" "$TG_LINK" >/dev/null 2>&1 || true

    local URI="socks5://${USER}:${PASS}@${SERVER_IP}:${PORT}"
    local URI_QR_FILE="/root/proxy_uri_qr_${USER}.png"
    qrencode -o "$URI_QR_FILE" "$URI" >/dev/null 2>&1 || true

    local EXPORT_FILE="/root/proxy_${USER}.txt"
    cat > "$EXPORT_FILE" <<TXT
SOCKS5
Server: ${SERVER_IP}
Port: ${PORT}
Username: ${USER}
Password: ${PASS}

Telegram:
Settings -> Data and Storage -> Proxy -> Add Proxy -> SOCKS5

Firefox:
Настройки -> Сеть -> Настроить -> Ручная настройка прокси
HTTP прокси: пусто
HTTPS прокси: пусто
Узел SOCKS: ${SERVER_IP}
Порт: ${PORT}
SOCKS v5: включить
Отправлять DNS-запросы через прокси при использовании SOCKS 5: включить
Не запрашивать аутентификацию: НЕ включать

URI:
${URI}
TXT

    echo ""
    echo -e "${BLUE}📱 Telegram:${NC}"
    echo -e "  ${CYAN}${TG_LINK}${NC}"
    echo -e "  QR: ${CYAN}${TG_QR_FILE}${NC}"

    echo ""
    echo -e "${MAGENTA}🌐 Браузер:${NC}"
    echo -e "  Это не автоимпорт. Настраивать нужно вручную."
    echo -e "  Узел SOCKS: ${CYAN}${SERVER_IP}${NC}"
    echo -e "  Порт:       ${CYAN}${PORT}${NC}"
    echo -e "  SOCKS:      ${CYAN}SOCKS5${NC}"
    echo -e "  Логин:      ${CYAN}${USER}${NC}"
    echo -e "  Пароль:     ${CYAN}${PASS}${NC}"
    echo -e "  URI:        ${CYAN}${URI}${NC}"
    echo -e "  QR URI:     ${CYAN}${URI_QR_FILE}${NC}"
    echo -e "  TXT:        ${CYAN}${EXPORT_FILE}${NC}"

    echo ""
    echo -e "${YELLOW}Firefox:${NC} HTTP/HTTPS оставить пустыми, заполнить только SOCKS."
    echo -e "${YELLOW}Firefox:${NC} включить 'Отправлять DNS-запросы через прокси при использовании SOCKS 5'."
    echo -e "${YELLOW}Firefox:${NC} НЕ ставить 'Не запрашивать аутентификацию'."
}

echo ""
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}   Прокси успешно запущен${NC}"
echo -e "${GREEN}============================================${NC}"
echo ""
echo -e "${BLUE}📡 Данные подключения:${NC}"
echo -e "  Тип:     ${CYAN}SOCKS5${NC}"
echo -e "  Сервер:  ${CYAN}${SERVER_IP}${NC}"
echo -e "  Порт:    ${CYAN}${PORT}${NC}"
echo -e "  Логин:   ${CYAN}${USERNAME}${NC}"
echo -e "  Пароль:  ${CYAN}${PASSWORD}${NC}"

generate_links "$USERNAME" "$PASSWORD"

echo ""
echo -e "${CYAN}Проверка:${NC}"
echo "  systemctl status danted --no-pager"
echo "  journalctl -u danted -n 30 --no-pager"
echo "  ss -lntp | grep :${PORT}"

echo ""
read -r -p "$(echo -e ${YELLOW})[?] Хотите добавить ещё пользователя? (y/n): $(echo -e ${NC})" ADD_MORE

while [[ "$ADD_MORE" == "y" || "$ADD_MORE" == "Y" ]]; do
    read -r -p "$(echo -e ${YELLOW})[?] Логин: $(echo -e ${NC})" NEW_USER
    while true; do
        read -r -s -p "$(echo -e ${YELLOW})[?] Пароль: $(echo -e ${NC})" NEW_PASS
        echo ""
        read -r -s -p "$(echo -e ${YELLOW})[?] Повторите пароль: $(echo -e ${NC})" NEW_PASS2
        echo ""
        if [[ -n "$NEW_PASS" && "$NEW_PASS" == "$NEW_PASS2" ]]; then
            break
        else
            echo -e "${RED}[!] Пароли не совпадают${NC}"
        fi
    done

    if id "$NEW_USER" &>/dev/null; then
        echo "${NEW_USER}:${NEW_PASS}" | chpasswd
    else
        useradd -r -s /usr/sbin/nologin "$NEW_USER"
        echo "${NEW_USER}:${NEW_PASS}" | chpasswd
    fi

    echo -e "${GREEN}[✓] Пользователь ${NEW_USER} добавлен${NC}"
    generate_links "$NEW_USER" "$NEW_PASS"

    read -r -p "$(echo -e ${YELLOW})[?] Добавить ещё? (y/n): $(echo -e ${NC})" ADD_MORE
done

echo ""
echo -e "${GREEN}Готово${NC}"