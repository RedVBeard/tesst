#!/bin/bash

# ─────────────────────────────────────────
#   Hysteria 2 — автоустановка
# ─────────────────────────────────────────

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "  ██╗  ██╗██╗   ██╗███████╗████████╗███████╗██████╗ ██╗ █████╗     ██████╗ "
echo "  ██║  ██║╚██╗ ██╔╝██╔════╝╚══██╔══╝██╔════╝██╔══██╗██║██╔══██╗    ╚════██╗"
echo "  ███████║ ╚████╔╝ ███████╗   ██║   █████╗  ██████╔╝██║███████║     █████╔╝"
echo "  ██╔══██║  ╚██╔╝  ╚════██║   ██║   ██╔══╝  ██╔══██╗██║██╔══██║    ██╔═══╝ "
echo "  ██║  ██║   ██║   ███████║   ██║   ███████╗██║  ██║██║██║  ██║    ███████╗"
echo "  ╚═╝  ╚═╝   ╚═╝   ╚══════╝   ╚═╝   ╚══════╝╚═╝  ╚═╝╚═╝╚═╝  ╚═╝    ╚══════╝"
echo -e "${NC}"
echo -e "${YELLOW}  Автоустановка Hysteria 2 с Let's Encrypt${NC}"
echo ""

# ─── Запрос данных ───────────────────────

read -rp "$(echo -e ${CYAN}Домен (например hystnod.duckdns.org): ${NC})" DOMAIN
read -rp "$(echo -e ${CYAN}Email для Let'\''s Encrypt: ${NC})" EMAIL

while true; do
    read -rsp "$(echo -e ${CYAN}Пароль для подключения: ${NC})" PASSWORD
    echo ""
    read -rsp "$(echo -e ${CYAN}Повторите пароль: ${NC})" PASSWORD2
    echo ""
    if [ "$PASSWORD" = "$PASSWORD2" ]; then
        break
    else
        echo -e "${RED}Пароли не совпадают, попробуйте ещё раз.${NC}"
    fi
done

echo ""
echo -e "${YELLOW}▶ Домен:  ${DOMAIN}${NC}"
echo -e "${YELLOW}▶ Email:  ${EMAIL}${NC}"
echo -e "${YELLOW}▶ Пароль: $(echo "$PASSWORD" | sed 's/./*/g')${NC}"
echo ""
read -rp "Всё верно? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo -e "${RED}Отменено.${NC}"
    exit 1
fi

# ─── Установка Hysteria 2 ────────────────

echo ""
echo -e "${GREEN}[1/4] Устанавливаем Hysteria 2...${NC}"
bash <(curl -fsSL https://get.hy2.sh/)

# ─── Открываем порты ─────────────────────

echo -e "${GREEN}[2/4] Открываем порты 80/tcp и 443/udp...${NC}"
if command -v ufw &>/dev/null; then
    ufw allow 80/tcp  >/dev/null 2>&1
    ufw allow 443/udp >/dev/null 2>&1
    ufw reload        >/dev/null 2>&1
    echo -e "  ${GREEN}✔ UFW обновлён${NC}"
elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=80/tcp  >/dev/null 2>&1
    firewall-cmd --permanent --add-port=443/udp >/dev/null 2>&1
    firewall-cmd --reload                        >/dev/null 2>&1
    echo -e "  ${GREEN}✔ firewalld обновлён${NC}"
else
    iptables -I INPUT -p tcp --dport 80  -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport 443 -j ACCEPT 2>/dev/null || true
    echo -e "  ${YELLOW}⚠ iptables — правила добавлены (не сохранены permanently)${NC}"
fi

# ─── Конфигурация сервера ─────────────────

echo -e "${GREEN}[3/4] Записываем конфигурацию...${NC}"
mkdir -p /etc/hysteria

cat > /etc/hysteria/config.yaml <<EOF
listen: :443

acme:
  domains:
    - ${DOMAIN}
  email: ${EMAIL}

auth:
  type: password
  password: ${PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://news.ycombinator.com/
    rewriteHost: true
EOF

echo -e "  ${GREEN}✔ /etc/hysteria/config.yaml создан${NC}"

# ─── Запуск сервиса ──────────────────────

echo -e "${GREEN}[4/4] Запускаем сервис...${NC}"
systemctl enable hysteria-server >/dev/null 2>&1
systemctl restart hysteria-server

sleep 2

if systemctl is-active --quiet hysteria-server; then
    echo -e "  ${GREEN}✔ Hysteria 2 успешно запущена!${NC}"
else
    echo -e "  ${RED}✘ Сервис не запустился. Проверьте логи:${NC}"
    echo -e "  journalctl -u hysteria-server -f"
    exit 1
fi

# ─── Итог ────────────────────────────────

URI="hysteria2://${PASSWORD}@${DOMAIN}:443"

echo ""
echo -e "${CYAN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Установка завершена!${NC}"
echo -e "${CYAN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}  Данные для v2rayN:${NC}"
echo -e "  Адрес:   ${DOMAIN}"
echo -e "  Порт:    443"
echo -e "  Пароль:  ${PASSWORD}"
echo -e "  SNI:     ${DOMAIN}"
echo -e "  Insecure: false"
echo ""
echo -e "${YELLOW}  URI для импорта:${NC}"
echo -e "  ${GREEN}${URI}${NC}"
echo ""
echo -e "${CYAN}  Логи: journalctl -u hysteria-server -f${NC}"
echo ""
