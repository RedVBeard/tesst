#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[*]${NC} $*"; }
success() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[-]${NC} $*" >&2; }

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Запусти скрипт от root: sudo bash $0"
    exit 1
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || {
    err "Не найдена команда: $cmd"
    exit 1
  }
}

ask() {
  local prompt="$1"
  local var_name="$2"
  local default_value="${3-}"
  local value

  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt [$default_value]: " value || true
    value="${value:-$default_value}"
  else
    while true; do
      read -r -p "$prompt: " value || true
      [[ -n "$value" ]] && break
      warn "Поле не может быть пустым"
    done
  fi

  printf -v "$var_name" '%s' "$value"
}

ask_secret() {
  local prompt="$1"
  local var_name="$2"
  local value

  while true; do
    read -r -s -p "$prompt: " value || true
    echo
    [[ -n "$value" ]] && break
    warn "Поле не может быть пустым"
  done

  printf -v "$var_name" '%s' "$value"
}

ask_yes_no() {
  local prompt="$1"
  local default_value="${2:-y}"
  local answer
  local suffix="[Y/n]"
  [[ "$default_value" == "n" ]] && suffix="[y/N]"

  while true; do
    read -r -p "$prompt $suffix: " answer || true
    answer="${answer:-$default_value}"
    case "$answer" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO) return 1 ;;
      *) warn "Ответь y или n" ;;
    esac
  done
}

random_password() {
  openssl rand -hex 16
}

rawurlencode() {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for (( pos=0; pos<strlen; pos++ )); do
    c=${string:$pos:1}
    case "$c" in
      [a-zA-Z0-9.~_-]) o="$c" ;;
      *) printf -v o '%%%02X' "'$c" ;;
    esac
    encoded+="${o}"
  done

  printf '%s' "$encoded"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

check_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    log "Система: ${PRETTY_NAME:-unknown}"
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    err "Нужен systemd/systemctl"
    exit 1
  fi
}

install_packages() {
  log "Устанавливаю зависимости"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates openssl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssl
  else
    err "Неизвестный пакетный менеджер. Нужны curl, ca-certificates, openssl"
    exit 1
  fi
}

find_cert_paths() {
  local domain="$1"
  local live_dir="/etc/letsencrypt/live/$domain"

  if [[ -f "$live_dir/fullchain.pem" && -f "$live_dir/privkey.pem" ]]; then
    CERT_PATH="$live_dir/fullchain.pem"
    KEY_PATH="$live_dir/privkey.pem"
    return 0
  fi
  return 1
}

open_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    log "Открываю UDP порт $port в UFW"
    ufw allow "${port}/udp" || warn "Не удалось автоматически открыть порт через UFW"
  else
    warn "UFW не найден. Если есть firewall у системы или провайдера VPS, открой UDP порт $port вручную"
  fi
}

install_hysteria() {
  log "Ставлю Hysteria 2 через официальный install script"
  HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)
}

write_config() {
  local cfg_path="/etc/hysteria/config.yaml"
  mkdir -p /etc/hysteria

  cat > "$cfg_path" <<EOF_CFG
listen: :${PORT}

tls:
  cert: ${CERT_PATH}
  key: ${KEY_PATH}

auth:
  type: password
  password: ${HY_PASSWORD}
EOF_CFG

  if [[ "${USE_MASQUERADE}" == "yes" ]]; then
    cat >> "$cfg_path" <<EOF_CFG

masquerade:
  type: proxy
  proxy:
    url: ${MASQ_URL}
    rewriteHost: true
EOF_CFG
  fi

  chmod 600 "$cfg_path"
  success "Конфиг записан в $cfg_path"
}

show_client_config() {
  local encoded_password
  encoded_password="$(rawurlencode "$HY_PASSWORD")"

  cat <<EOF_CLIENT

================ CLIENT CONFIG ================
server: ${DOMAIN}:${PORT}
auth: ${HY_PASSWORD}

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080
==============================================

URI:
hysteria2://${encoded_password}@${DOMAIN}:${PORT}/?sni=${DOMAIN}#${DOMAIN}
EOF_CLIENT
}

main() {
  require_root
  require_cmd bash
  require_cmd grep
  check_os
  install_packages

  echo
  echo "Настроим Hysteria 2. Скрипт спросит только нужное."
  echo

  ask "Домен/поддомен для Hysteria (например hy2.ashen.city)" DOMAIN

  while true; do
    ask "UDP порт" PORT "8443"
    if validate_port "$PORT"; then
      break
    fi
    warn "Порт должен быть числом от 1 до 65535"
  done

  if ask_yes_no "Сгенерировать случайный пароль автоматически?" "y"; then
    HY_PASSWORD="$(random_password)"
    success "Пароль сгенерирован"
  else
    ask_secret "Пароль для Hysteria" HY_PASSWORD
  fi

  if ask_yes_no "Включить masquerade/proxy?" "n"; then
    USE_MASQUERADE="yes"
    ask "URL для masquerade/proxy" MASQ_URL "https://example.com/"
  else
    USE_MASQUERADE="no"
    success "Masquerade отключен"
  fi

  if find_cert_paths "$DOMAIN"; then
    success "Найден сертификат Let's Encrypt: $CERT_PATH"
  else
    warn "Сертификат Let's Encrypt для $DOMAIN не найден автоматически"
    ask "Путь к cert/fullchain.pem" CERT_PATH
    ask "Путь к key/privkey.pem" KEY_PATH
  fi

  [[ -f "$CERT_PATH" ]] || { err "Файл сертификата не найден: $CERT_PATH"; exit 1; }
  [[ -f "$KEY_PATH" ]] || { err "Файл ключа не найден: $KEY_PATH"; exit 1; }

  install_hysteria
  write_config
  open_port "$PORT"

  log "Перезапускаю сервис"
  systemctl enable --now hysteria-server.service
  systemctl restart hysteria-server.service

  if systemctl is-active --quiet hysteria-server.service; then
    success "Hysteria 2 запущена"
  else
    err "Сервис не поднялся. Показываю логи:"
    journalctl --no-pager -u hysteria-server.service -n 50 || true
    exit 1
  fi

  echo
  success "Готово"
  echo
  systemctl --no-pager --full status hysteria-server.service | sed -n '1,15p' || true
  show_client_config
  echo
  echo "Проверь также firewall в панели провайдера VPS: UDP порт ${PORT} должен быть открыт."
}

main "$@"
