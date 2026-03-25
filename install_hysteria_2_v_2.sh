#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[*]${NC} $*"; }
ok() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[-]${NC} $*" >&2; }

CERT_MODE=""
CERT_PATH=""
KEY_PATH=""
CA_PATH=""
PIN_SHA256=""
LE_EMAIL=""
DOMAIN=""
PORT=""
NODE_NAME=""
HY_PASSWORD=""
USE_MASQUERADE="no"
MASQ_URL=""
OUTPUT_DIR=""
PC_CONFIG_PATH=""
URI_PATH=""
MOBILE_URI_PATH=""
QRCODE_PATH=""
SHARE_URI=""
MOBILE_URI=""
MOBILE_NOTE=""
SAVED_SERVICES=()

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Запусти скрипт от root: sudo bash $0"
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Не найдена команда: $1"
    exit 1
  }
}

ask() {
  local prompt="$1"
  local var_name="$2"
  local default_value="${3-}"
  local value=""
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
  local value=""
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
  local answer=""
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

is_ip_address() {
  local host="$1"
  [[ "$host" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
  [[ "$host" =~ : ]] && return 0
  return 1
}

backup_file_if_exists() {
  local path="$1"
  if [[ -f "$path" ]]; then
    local ts
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -a "$path" "${path}.bak.${ts}"
    ok "Сделал backup: ${path}.bak.${ts}"
  fi
}

check_os() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    log "Система: ${PRETTY_NAME:-unknown}"
  fi
  command -v systemctl >/dev/null 2>&1 || {
    err "Нужен systemd/systemctl"
    exit 1
  }
}

install_base_packages() {
  log "Устанавливаю базовые зависимости"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates openssl grep sed coreutils
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates openssl grep sed coreutils
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl ca-certificates openssl grep sed coreutils
  else
    err "Неизвестный пакетный менеджер. Установи вручную: curl ca-certificates openssl grep sed coreutils"
    exit 1
  fi
}

maybe_install_qrencode() {
  if command -v qrencode >/dev/null 2>&1; then
    return 0
  fi
  if ! ask_yes_no "Поставить qrencode для QR-кода ссылки?" "n"; then
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y qrencode || warn "Не удалось установить qrencode"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y qrencode || warn "Не удалось установить qrencode"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y qrencode || warn "Не удалось установить qrencode"
  fi
}

stop_known_web_services() {
  local svc
  SAVED_SERVICES=()
  for svc in nginx apache2 httpd caddy; do
    if systemctl is-active --quiet "$svc"; then
      log "Временно останавливаю $svc для проверки Let's Encrypt"
      systemctl stop "$svc"
      SAVED_SERVICES+=("$svc")
    fi
  done
}

restore_known_web_services() {
  local svc
  if [[ ${#SAVED_SERVICES[@]} -eq 0 ]]; then
    return 0
  fi
  for svc in "${SAVED_SERVICES[@]}"; do
    log "Запускаю обратно $svc"
    systemctl start "$svc" || warn "Не удалось вернуть $svc"
  done
}

install_certbot() {
  if command -v certbot >/dev/null 2>&1; then
    ok "Certbot уже установлен"
    return 0
  fi
  log "Ставлю certbot"
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    if apt-get install -y certbot; then
      return 0
    fi
    warn "apt-пакет certbot не установился, пробую snap"
    apt-get install -y snapd
    snap install core
    snap refresh core
    snap install --classic certbot
    ln -sf /snap/bin/certbot /usr/local/bin/certbot
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y certbot
  elif command -v yum >/dev/null 2>&1; then
    yum install -y certbot
  else
    err "Не удалось установить certbot автоматически"
    exit 1
  fi
}

use_existing_le_cert_if_present() {
  local cert="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  local key="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  if [[ -f "$cert" && -f "$key" ]]; then
    CERT_PATH="$cert"
    KEY_PATH="$key"
    CERT_MODE="letsencrypt"
    ok "Нашел существующий Let's Encrypt сертификат"
    return 0
  fi
  return 1
}

issue_letsencrypt_cert() {
  install_certbot
  if is_ip_address "$DOMAIN"; then
    warn "Для Let's Encrypt нужен домен, а не IP"
    return 1
  fi
  if use_existing_le_cert_if_present; then
    return 0
  fi
  stop_known_web_services
  set +e
  certbot certonly --standalone -d "$DOMAIN" -m "$LE_EMAIL" --agree-tos --no-eff-email
  local rc=$?
  set -e
  restore_known_web_services
  if [[ $rc -ne 0 ]]; then
    warn "Не удалось выпустить Let's Encrypt сертификат для $DOMAIN"
    return 1
  fi
  CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
  KEY_PATH="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
  [[ -f "$CERT_PATH" && -f "$KEY_PATH" ]] || {
    warn "Let's Encrypt отработал, но сертификаты не найдены по ожидаемому пути"
    return 1
  }
  CERT_MODE="letsencrypt"
  ok "Let's Encrypt сертификат готов"
  return 0
}

issue_self_signed_cert() {
  local cert_dir="/etc/hysteria/selfsigned"
  mkdir -p "$cert_dir"
  CA_PATH="$cert_dir/ca.crt"
  local ca_key="$cert_dir/ca.key"
  CERT_PATH="$cert_dir/server.crt"
  KEY_PATH="$cert_dir/server.key"
  local csr="$cert_dir/server.csr"
  local ext="$cert_dir/server.ext"
  local pubkey_der="$cert_dir/server-pubkey.der"
  log "Генерирую локальный CA и серверный сертификат"
  openssl genrsa -out "$ca_key" 4096 >/dev/null 2>&1
  openssl req -x509 -new -nodes -key "$ca_key" -sha256 -days 3650 -subj "/CN=Hysteria Local CA" -out "$CA_PATH" >/dev/null 2>&1
  openssl genrsa -out "$KEY_PATH" 2048 >/dev/null 2>&1
  if is_ip_address "$DOMAIN"; then
    cat > "$ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:${DOMAIN}
EOF
  else
    cat > "$ext" <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:${DOMAIN}
EOF
  fi
  openssl req -new -key "$KEY_PATH" -subj "/CN=$DOMAIN" -out "$csr" >/dev/null 2>&1
  openssl x509 -req -in "$csr" -CA "$CA_PATH" -CAkey "$ca_key" -CAcreateserial -out "$CERT_PATH" -days 825 -sha256 -extfile "$ext" >/dev/null 2>&1
  openssl x509 -in "$CERT_PATH" -pubkey -noout | openssl pkey -pubin -outform DER > "$pubkey_der" 2>/dev/null
  PIN_SHA256="$(openssl dgst -sha256 -binary "$pubkey_der" | openssl base64 -A)"
  chmod 600 "$KEY_PATH" "$ca_key"
  chmod 644 "$CERT_PATH" "$CA_PATH"
  CERT_MODE="selfsigned"
  ok "Self-signed сертификат создан"
}

open_port_hint() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1; then
    log "Открываю UDP порт $port в UFW"
    ufw allow "${port}/udp" || warn "Не удалось автоматически открыть порт через UFW"
  else
    warn "UFW не найден. Если есть firewall у системы или у провайдера VPS, открой UDP порт $port вручную"
  fi
}

install_hysteria() {
  log "Ставлю Hysteria 2 через официальный install script"
  HYSTERIA_USER=root bash <(curl -fsSL https://get.hy2.sh/)
}

write_server_config() {
  local cfg="/etc/hysteria/config.yaml"
  mkdir -p /etc/hysteria
  backup_file_if_exists "$cfg"
  cat > "$cfg" <<EOF
listen: :${PORT}

tls:
  cert: ${CERT_PATH}
  key: ${KEY_PATH}

auth:
  type: password
  password: ${HY_PASSWORD}
EOF
  if [[ "${USE_MASQUERADE}" == "yes" ]]; then
    cat >> "$cfg" <<EOF

masquerade:
  type: proxy
  proxy:
    url: ${MASQ_URL}
    rewriteHost: true
EOF
  fi
  chmod 600 "$cfg"
  ok "Серверный конфиг записан в $cfg"
}

write_client_files() {
  local out_dir="/root/hysteria-output"
  mkdir -p "$out_dir"
  local client_pc="$out_dir/client-pc.yaml"
  local client_mobile="$out_dir/client-mobile.txt"
  local client_uri="$out_dir/share-uri.txt"
  local encoded_password
  local encoded_tag
  encoded_password="$(rawurlencode "$HY_PASSWORD")"
  encoded_tag="$(rawurlencode "$NODE_NAME")"
  if [[ "$CERT_MODE" == "letsencrypt" ]]; then
    cat > "$client_pc" <<EOF
server: ${DOMAIN}:${PORT}
auth: ${HY_PASSWORD}

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080
EOF
    SHARE_URI="hysteria2://${encoded_password}@${DOMAIN}:${PORT}/?sni=${DOMAIN}#${encoded_tag}"
    MOBILE_URI="$SHARE_URI"
    MOBILE_NOTE="Подходит и для ПК, и для мобильных клиентов."
  else
    cat > "$client_pc" <<EOF
server: ${DOMAIN}:${PORT}
auth: ${HY_PASSWORD}

tls:
  sni: ${DOMAIN}
  ca: ${CA_PATH}

socks5:
  listen: 127.0.0.1:1080

http:
  listen: 127.0.0.1:8080
EOF
    SHARE_URI="hysteria2://${encoded_password}@${DOMAIN}:${PORT}/?sni=${DOMAIN}&pinSHA256=${PIN_SHA256}&insecure=1#${encoded_tag}"
    MOBILE_URI="$SHARE_URI"
    MOBILE_NOTE="Self-signed режим. Для ПК лучше использовать файл client-pc.yaml с CA, а для мобильных клиентов — ссылку ниже. Если клиент не понимает pinSHA256, импортируй CA или включи insecure вручную."
  fi
  printf '%s\n' "$SHARE_URI" > "$client_uri"
  printf '%s\n' "$MOBILE_URI" > "$client_mobile"
  chmod 600 "$client_pc"
  chmod 644 "$client_mobile" "$client_uri"
  OUTPUT_DIR="$out_dir"
  PC_CONFIG_PATH="$client_pc"
  URI_PATH="$client_uri"
  MOBILE_URI_PATH="$client_mobile"
  if command -v qrencode >/dev/null 2>&1; then
    QRCODE_PATH="$out_dir/share-uri.png"
    qrencode -o "$QRCODE_PATH" -s 8 -m 2 "$SHARE_URI" || warn "Не удалось создать QR-код"
  fi
}

print_summary() {
  echo
  ok "Готово"
  echo
  echo "=== СЕРВЕР ==="
  echo "Домен/IP:         $DOMAIN"
  echo "Порт UDP:         $PORT"
  echo "TLS режим:        $CERT_MODE"
  echo "Сервис:           hysteria-server.service"
  echo "Конфиг:           /etc/hysteria/config.yaml"
  echo
  if [[ "$CERT_MODE" == "selfsigned" ]]; then
    echo "CA сертификат:    $CA_PATH"
    echo "Public key pin:   $PIN_SHA256"
    echo
  fi
  echo "=== КЛИЕНТСКИЕ ФАЙЛЫ ==="
  echo "ПК config:        $PC_CONFIG_PATH"
  echo "URI:              $URI_PATH"
  echo "Mobile URI:       $MOBILE_URI_PATH"
  [[ -n "$QRCODE_PATH" ]] && echo "QR png:           $QRCODE_PATH"
  echo
  echo "=== URI ДЛЯ ИМПОРТА ==="
  cat "$URI_PATH"
  echo
  echo
  echo "=== ПОДСКАЗКА ==="
  echo "$MOBILE_NOTE"
  echo
}

main() {
  require_root
  need_cmd bash
  need_cmd openssl
  need_cmd grep
  need_cmd sed
  check_os
  install_base_packages

  echo
  echo "Настроим Hysteria 2."
  echo "Скрипт ставит Hysteria 2, пытается выпустить Let's Encrypt при наличии домена или делает self-signed, пишет конфиг и генерирует клиентские файлы и ссылки."
  echo

  ask "Домен или IP для Hysteria (пример: hy2.example.com или 1.2.3.4)" DOMAIN
  while true; do
    ask "UDP порт" PORT "8443"
    if validate_port "$PORT"; then
      break
    fi
    warn "Порт должен быть числом от 1 до 65535"
  done
  ask "Имя узла для ссылки (remark)" NODE_NAME "hy2-${DOMAIN}"
  if ask_yes_no "Сгенерировать случайный пароль автоматически?" "y"; then
    HY_PASSWORD="$(random_password)"
    ok "Пароль сгенерирован"
  else
    ask_secret "Пароль для Hysteria" HY_PASSWORD
  fi
  if ask_yes_no "Включить masquerade/proxy?" "n"; then
    USE_MASQUERADE="yes"
    ask "URL для masquerade/proxy" MASQ_URL "https://example.com/"
  else
    USE_MASQUERADE="no"
    ok "Masquerade отключен"
  fi

  echo
  echo "Выбери режим сертификата:"
  echo "  1) Auto: попробовать Let's Encrypt, при неудаче сделать self-signed"
  echo "  2) Только Let's Encrypt"
  echo "  3) Только self-signed"
  while true; do
    ask "Режим сертификата" CERT_CHOICE "1"
    case "$CERT_CHOICE" in
      1|2|3) break ;;
      *) warn "Введи 1, 2 или 3" ;;
    esac
  done

  case "$CERT_CHOICE" in
    1|2)
      if ! is_ip_address "$DOMAIN"; then
        ask "Email для Let's Encrypt" LE_EMAIL
      elif [[ "$CERT_CHOICE" == "2" ]]; then
        err "Let's Encrypt не работает с IP. Нужен домен."
        exit 1
      fi
      ;;
  esac

  case "$CERT_CHOICE" in
    1)
      if ! issue_letsencrypt_cert; then
        warn "Переключаюсь на self-signed"
        issue_self_signed_cert
      fi
      ;;
    2)
      issue_letsencrypt_cert || exit 1
      ;;
    3)
      issue_self_signed_cert
      ;;
  esac

  install_hysteria
  write_server_config
  open_port_hint "$PORT"

  log "Запускаю сервис"
  systemctl enable --now hysteria-server.service
  systemctl restart hysteria-server.service
  if ! systemctl is-active --quiet hysteria-server.service; then
    err "Сервис не поднялся. Логи:"
    journalctl --no-pager -u hysteria-server.service -n 50 || true
    exit 1
  fi

  maybe_install_qrencode
  write_client_files
  print_summary
}

main "$@"
