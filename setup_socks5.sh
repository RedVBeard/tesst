#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m'

CONFIG_FILE="/etc/danted.conf"
SQUID_CONFIG_FILE="/etc/squid/squid.conf"
SQUID_PASSWD_FILE="/etc/squid/passwd"

echo -e "${CYAN}"
echo "============================================"
echo "  SOCKS5 для Telegram + HTTP для браузеров"
echo "============================================"
echo -e "${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[!] Запустите от root: sudo bash setup_socks5.sh${NC}"
    exit 1
fi

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo -e "${RED}[!] Не найдена команда: $1${NC}"
        exit 1
    }
}

detect_interface() {
    local iface
    iface="$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
    if [[ -z "$iface" ]]; then
        iface="$(ip route | awk '/default/ {print $5; exit}')"
    fi
    echo "$iface"
}

detect_server_ip() {
    local ip=""
    ip="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(hostname -I | awk '{print $1}')"
    fi
    echo "$ip"
}

detect_squid_auth_helper() {
    local candidates=(
        /usr/lib/squid/basic_ncsa_auth
        /usr/lib64/squid/basic_ncsa_auth
        /usr/libexec/squid/basic_ncsa_auth
        /lib/squid/basic_ncsa_auth
    )
    local helper

    for helper in "${candidates[@]}"; do
        if [[ -x "$helper" ]]; then
            echo "$helper"
            return 0
        fi
    done

    echo ""
}

generate_password() {
    openssl rand -base64 24 | tr -d '=+/' | cut -c1-20
}

urlencode() {
    local input="$1"
    local output=""
    local i char hex

    for ((i=0; i<${#input}; i++)); do
        char="${input:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-])
                output+="$char"
                ;;
            *)
                printf -v hex '%%%02X' "'$char"
                output+="$hex"
                ;;
        esac
    done

    printf '%s' "$output"
}

ask_password_twice() {
    local p1="" p2=""
    while true; do
        read -r -s -p "$(echo -e ${YELLOW})[?] Пароль: $(echo -e ${NC})" p1
        echo ""
        read -r -s -p "$(echo -e ${YELLOW})[?] Повторите пароль: $(echo -e ${NC})" p2
        echo ""
        if [[ -n "$p1" && "$p1" == "$p2" ]]; then
            PASSWORD="$p1"
            return 0
        fi
        echo -e "${RED}[!] Пароли не совпадают или пустые, попробуйте снова${NC}"
    done
}

ensure_base_cmds() {
    need_cmd ip
    need_cmd curl
}

ensure_install_deps() {
    echo -e "${CYAN}[*] Устанавливаю зависимости...${NC}"
    apt-get update -qq
    apt-get install -y dante-server squid apache2-utils qrencode curl openssl >/dev/null 2>&1
    echo -e "${GREEN}[✓] Зависимости установлены${NC}"
}

ensure_quick_cmds_for_user_add() {
    local packages=()

    if ! command -v qrencode >/dev/null 2>&1; then
        packages+=(qrencode)
    fi
    if ! command -v openssl >/dev/null 2>&1; then
        packages+=(openssl)
    fi
    if ! command -v htpasswd >/dev/null 2>&1; then
        packages+=(apache2-utils)
    fi

    if [[ ${#packages[@]} -gt 0 ]]; then
        echo -e "${YELLOW}[~] Ставлю недостающие пакеты: ${packages[*]}${NC}"
        apt-get update -qq
        apt-get install -y "${packages[@]}" >/dev/null 2>&1
    fi
}

write_dante_config() {
    local iface="$1"
    local port="$2"

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

    cat > "$CONFIG_FILE" <<EOF
logoutput: syslog

internal: 0.0.0.0 port = ${port}
external: ${iface}

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
}

write_squid_config() {
    local http_port="$1"
    local auth_helper="$2"

    cp "$SQUID_CONFIG_FILE" "${SQUID_CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

    mkdir -p "$(dirname "$SQUID_PASSWD_FILE")"
    touch "$SQUID_PASSWD_FILE"
    chmod 640 "$SQUID_PASSWD_FILE"

    cat > "$SQUID_CONFIG_FILE" <<EOF
http_port ${http_port}

auth_param basic program ${auth_helper} ${SQUID_PASSWD_FILE}
auth_param basic realm PrivateProxy
auth_param basic credentialsttl 2 hours

acl authenticated proxy_auth REQUIRED
http_access allow authenticated
http_access deny all

cache deny all
dns_v4_first on
forwarded_for delete
via off

access_log stdio:/var/log/squid/access.log
cache_log stdio:/var/log/squid/cache.log
pid_filename /run/squid.pid
EOF
}

validate_dante_config() {
    if ! /usr/sbin/danted -D -f "$CONFIG_FILE" >/tmp/danted_check.log 2>&1; then
        echo -e "${RED}[!] Конфиг Dante не прошёл проверку${NC}"
        cat /tmp/danted_check.log
        exit 1
    fi
}

validate_squid_config() {
    if ! squid -k parse -f "$SQUID_CONFIG_FILE" >/tmp/squid_check.log 2>&1; then
        echo -e "${RED}[!] Конфиг Squid не прошёл проверку${NC}"
        cat /tmp/squid_check.log
        exit 1
    fi
}

restart_dante() {
    systemctl enable danted >/dev/null 2>&1
    systemctl restart danted
    if ! systemctl is-active --quiet danted; then
        echo -e "${RED}[!] Dante не запустился${NC}"
        journalctl -u danted -n 30 --no-pager
        exit 1
    fi
    echo -e "${GREEN}[✓] Dante запущен${NC}"
}

restart_squid() {
    systemctl enable squid >/dev/null 2>&1
    systemctl restart squid
    if ! systemctl is-active --quiet squid; then
        echo -e "${RED}[!] Squid не запустился${NC}"
        journalctl -u squid -n 30 --no-pager
        exit 1
    fi
    echo -e "${GREEN}[✓] HTTP proxy Squid запущен${NC}"
}

open_firewall() {
    local socks_port="$1"
    local http_port="$2"

    if command -v ufw >/dev/null 2>&1; then
        ufw allow "${socks_port}/tcp" >/dev/null 2>&1 || true
        ufw allow "${http_port}/tcp" >/dev/null 2>&1 || true
        echo -e "${GREEN}[✓] Порты ${socks_port} и ${http_port} открыты в UFW${NC}"
    fi
}

create_or_update_socks_user() {
    local user="$1"
    local pass="$2"

    if id "$user" >/dev/null 2>&1; then
        echo -e "${YELLOW}[~] Пользователь ${user} уже существует, обновляю пароль${NC}"
    else
        useradd -r -s /usr/sbin/nologin "$user"
        echo -e "${GREEN}[✓] Пользователь ${user} создан${NC}"
    fi

    echo "${user}:${pass}" | chpasswd
    echo -e "${GREEN}[✓] Пароль SOCKS5 для ${user} установлен${NC}"
}

create_or_update_http_user() {
    local user="$1"
    local pass="$2"

    if [[ ! -f "$SQUID_PASSWD_FILE" ]]; then
        touch "$SQUID_PASSWD_FILE"
        chmod 640 "$SQUID_PASSWD_FILE"
    fi

    if grep -q "^${user}:" "$SQUID_PASSWD_FILE" 2>/dev/null; then
        htpasswd -b "$SQUID_PASSWD_FILE" "$user" "$pass" >/dev/null
    else
        if [[ ! -s "$SQUID_PASSWD_FILE" ]]; then
            htpasswd -b -c "$SQUID_PASSWD_FILE" "$user" "$pass" >/dev/null
        else
            htpasswd -b "$SQUID_PASSWD_FILE" "$user" "$pass" >/dev/null
        fi
    fi

    echo -e "${GREEN}[✓] Пароль HTTP proxy для ${user} установлен${NC}"
}

create_or_update_proxy_user() {
    local user="$1"
    local pass="$2"

    create_or_update_socks_user "$user" "$pass"

    if command -v htpasswd >/dev/null 2>&1; then
        create_or_update_http_user "$user" "$pass"
    else
        echo -e "${YELLOW}[~] htpasswd не найден, HTTP user не создан${NC}"
    fi
}

print_qr() {
    local text="$1"
    qrencode -m 1 -t ANSIUTF8 "$text" || true
}

show_links() {
    local server_ip="$1"
    local socks_port="$2"
    local http_port="$3"
    local user="$4"
    local pass="$5"

    local encoded_user encoded_pass tg_link socks_uri http_uri export_file
    encoded_user="$(urlencode "$user")"
    encoded_pass="$(urlencode "$pass")"
    tg_link="https://t.me/socks?server=${server_ip}&port=${socks_port}&user=${encoded_user}&pass=${encoded_pass}"
    socks_uri="socks5://${encoded_user}:${encoded_pass}@${server_ip}:${socks_port}"
    http_uri="http://${encoded_user}:${encoded_pass}@${server_ip}:${http_port}"
    export_file="/root/proxy_${user}.txt"

    cat > "$export_file" <<EOF
SOCKS5 для Telegram
Server: ${server_ip}
Port: ${socks_port}
Username: ${user}
Password: ${pass}

HTTP proxy для браузеров
Server: ${server_ip}
Port: ${http_port}
Username: ${user}
Password: ${pass}

Telegram:
Settings -> Data and Storage -> Proxy -> Add Proxy -> SOCKS5

Firefox/Chrome/Edge:
Type: HTTP proxy
Host: ${server_ip}
Port: ${http_port}
Username: ${user}
Password: ${pass}

SOCKS URI:
${socks_uri}

HTTP URI:
${http_uri}

Telegram link:
${tg_link}
EOF

    echo ""
    echo -e "${BLUE}Telegram через SOCKS5${NC}"
    echo -e "Ссылка:"
    echo -e "${CYAN}${tg_link}${NC}"
    echo ""
    echo -e "${BLUE}QR-код Telegram:${NC}"
    print_qr "$tg_link"

    echo ""
    echo -e "${MAGENTA}HTTP proxy для браузеров${NC}"
    echo -e "Host:     ${CYAN}${server_ip}${NC}"
    echo -e "Port:     ${CYAN}${http_port}${NC}"
    echo -e "Login:    ${CYAN}${user}${NC}"
    echo -e "Password: ${CYAN}${pass}${NC}"
    echo -e "URI:      ${CYAN}${http_uri}${NC}"
    echo ""
    echo -e "${MAGENTA}QR-код HTTP URI:${NC}"
    print_qr "$http_uri"

    echo ""
    echo -e "${YELLOW}Firefox:${NC}"
    echo -e "  HTTP proxy:  ${CYAN}${server_ip}:${http_port}${NC}"
    echo -e "  HTTPS proxy: ${CYAN}${server_ip}:${http_port}${NC}"
    echo -e "  SOCKS:       пусто"
    echo -e "  Логин/пароль браузер должен запросить сам"

    echo ""
    echo -e "${YELLOW}Chrome / Edge:${NC}"
    echo -e "  Проще всего использовать HTTP proxy ${CYAN}${server_ip}:${http_port}${NC}"
    echo -e "  Если браузер не спрашивает пароль, лучше использовать расширение типа FoxyProxy"

    echo ""
    echo -e "${GREEN}[✓] Данные также сохранены в ${export_file}${NC}"
}

get_current_socks_port() {
    local port
    port="$(sed -n 's/^internal: .* port = \([0-9][0-9]*\)$/\1/p' "$CONFIG_FILE" | head -n1)"
    echo "${port:-443}"
}

get_current_http_port() {
    local port
    port="$(sed -n 's/^http_port[[:space:]]\+\([0-9][0-9]*\)$/\1/p' "$SQUID_CONFIG_FILE" | head -n1)"
    echo "${port:-8080}"
}

install_proxy() {
    local interface server_ip socks_port http_port username auth_helper
    interface="$(detect_interface)"
    server_ip="$(detect_server_ip)"

    echo -e "${GREEN}[✓] Интерфейс: ${interface}${NC}"
    echo -e "${GREEN}[✓] Внешний IP: ${server_ip}${NC}"
    echo ""

    read -r -p "$(echo -e ${YELLOW})[?] Порт SOCKS5 для Telegram [по умолчанию 443]: $(echo -e ${NC})" socks_port
    socks_port="${socks_port:-443}"
    if ! [[ "$socks_port" =~ ^[0-9]+$ ]] || (( socks_port < 1 || socks_port > 65535 )); then
        echo -e "${RED}[!] Некорректный порт SOCKS5${NC}"
        exit 1
    fi

    read -r -p "$(echo -e ${YELLOW})[?] Порт HTTP proxy для браузеров [по умолчанию 8080]: $(echo -e ${NC})" http_port
    http_port="${http_port:-8080}"
    if ! [[ "$http_port" =~ ^[0-9]+$ ]] || (( http_port < 1 || http_port > 65535 )); then
        echo -e "${RED}[!] Некорректный порт HTTP proxy${NC}"
        exit 1
    fi

    if [[ "$socks_port" == "$http_port" ]]; then
        echo -e "${RED}[!] Порты SOCKS5 и HTTP должны отличаться${NC}"
        exit 1
    fi

    read -r -p "$(echo -e ${YELLOW})[?] Логин пользователя [по умолчанию tguser]: $(echo -e ${NC})" username
    username="${username:-tguser}"

    if [[ -z "$username" ]]; then
        echo -e "${RED}[!] Пустой логин недопустим${NC}"
        exit 1
    fi

    if command -v openssl >/dev/null 2>&1; then
        read -r -p "$(echo -e ${YELLOW})[?] Сгенерировать пароль автоматически? (Y/n): $(echo -e ${NC})" genpass
        if [[ -z "${genpass:-}" || "$genpass" =~ ^[Yy]$ ]]; then
            PASSWORD="$(generate_password)"
            echo -e "${GREEN}[✓] Сгенерирован пароль: ${PASSWORD}${NC}"
        else
            ask_password_twice
        fi
    else
        ask_password_twice
    fi

    ensure_install_deps
    auth_helper="$(detect_squid_auth_helper)"
    if [[ -z "$auth_helper" ]]; then
        echo -e "${RED}[!] Не удалось найти basic_ncsa_auth для Squid${NC}"
        exit 1
    fi

    write_dante_config "$interface" "$socks_port"
    write_squid_config "$http_port" "$auth_helper"
    validate_dante_config
    validate_squid_config
    create_or_update_proxy_user "$username" "$PASSWORD"
    restart_dante
    restart_squid
    open_firewall "$socks_port" "$http_port"

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}   Прокси успешно запущен${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo -e "Telegram SOCKS5:"
    echo -e "  Сервер:  ${CYAN}${server_ip}${NC}"
    echo -e "  Порт:    ${CYAN}${socks_port}${NC}"
    echo -e "  Логин:   ${CYAN}${username}${NC}"
    echo -e "  Пароль:  ${CYAN}${PASSWORD}${NC}"
    echo ""
    echo -e "HTTP proxy для браузеров:"
    echo -e "  Сервер:  ${CYAN}${server_ip}${NC}"
    echo -e "  Порт:    ${CYAN}${http_port}${NC}"
    echo -e "  Логин:   ${CYAN}${username}${NC}"
    echo -e "  Пароль:  ${CYAN}${PASSWORD}${NC}"

    show_links "$server_ip" "$socks_port" "$http_port" "$username" "$PASSWORD"
}

add_new_user() {
    local username socks_port http_port server_ip
    server_ip="$(detect_server_ip)"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${RED}[!] ${CONFIG_FILE} не найден. Сначала установите прокси.${NC}"
        exit 1
    fi

    ensure_base_cmds
    ensure_quick_cmds_for_user_add

    socks_port="$(get_current_socks_port)"
    http_port="$(get_current_http_port)"

    read -r -p "$(echo -e ${YELLOW})[?] Логин нового пользователя: $(echo -e ${NC})" username
    if [[ -z "$username" ]]; then
        echo -e "${RED}[!] Логин не может быть пустым${NC}"
        exit 1
    fi

    read -r -p "$(echo -e ${YELLOW})[?] Сгенерировать пароль автоматически? (Y/n): $(echo -e ${NC})" genpass
    if [[ -z "${genpass:-}" || "$genpass" =~ ^[Yy]$ ]]; then
        PASSWORD="$(generate_password)"
        echo -e "${GREEN}[✓] Сгенерирован пароль: ${PASSWORD}${NC}"
    else
        ask_password_twice
    fi

    create_or_update_proxy_user "$username" "$PASSWORD"

    echo ""
    echo -e "${GREEN}[✓] Новый пользователь добавлен${NC}"
    echo -e "Telegram SOCKS5: ${CYAN}${server_ip}:${socks_port}${NC}"
    echo -e "HTTP proxy:      ${CYAN}${server_ip}:${http_port}${NC}"
    echo -e "Логин:           ${CYAN}${username}${NC}"
    echo -e "Пароль:          ${CYAN}${PASSWORD}${NC}"

    show_links "$server_ip" "$socks_port" "$http_port" "$username" "$PASSWORD"
}

ensure_base_cmds

echo -e "${YELLOW}Выберите действие:${NC}"
echo "1) Установить / переустановить прокси"
echo "2) Добавить нового пользователя"
read -r -p "Введите номер [1-2]: " MODE

case "$MODE" in
    1) install_proxy ;;
    2) add_new_user ;;
    *)
        echo -e "${RED}[!] Неверный выбор${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${CYAN}Проверка:${NC}"
echo "  systemctl status danted --no-pager"
echo "  systemctl status squid --no-pager"
echo "  journalctl -u danted -n 30 --no-pager"
echo "  journalctl -u squid -n 30 --no-pager"
echo "  ss -lntp | grep -E 'danted|squid'"
