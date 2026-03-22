#!/bin/bash

# ============================================================
#   C³ CELERITY — Скрипт автоматической установки
#   https://github.com/ClickDevTech/CELERITY-panel
# ============================================================

set -e

# --- Цвета ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# --- Баннер ---
echo -e "${CYAN}"
echo "  ██████╗██████╗      ██████╗███████╗██╗     ███████╗██████╗ ██╗████████╗██╗   ██╗"
echo " ██╔════╝╚════██╗    ██╔════╝██╔════╝██║     ██╔════╝██╔══██╗██║╚══██╔══╝╚██╗ ██╔╝"
echo " ██║      █████╔╝    ██║     █████╗  ██║     █████╗  ██████╔╝██║   ██║    ╚████╔╝ "
echo " ██║     ██╔═══╝     ██║     ██╔══╝  ██║     ██╔══╝  ██╔══██╗██║   ██║     ╚██╔╝  "
echo " ╚██████╗███████╗    ╚██████╗███████╗███████╗███████╗██║  ██║██║   ██║      ██║   "
echo "  ╚═════╝╚══════╝     ╚═════╝╚══════╝╚══════╝╚══════╝╚═╝  ╚═╝╚═╝   ╚═╝      ╚═╝   "
echo -e "${NC}"
echo -e "${BOLD}  Панель управления Hysteria 2 — Автоустановка${NC}"
echo -e "  ──────────────────────────────────────────────\n"

# --- Проверка root ---
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[✗] Запустите скрипт от root: sudo bash install-celerity.sh${NC}"
  exit 1
fi

# --- Проверка ОС ---
if ! command -v apt-get &>/dev/null; then
  echo -e "${RED}[✗] Поддерживаются только системы на базе Debian/Ubuntu${NC}"
  exit 1
fi

# ============================================================
#   ВВОД ДАННЫХ
# ============================================================

echo -e "${BOLD}Введите данные для установки:${NC}\n"

# Домен
while true; do
  read -rp "$(echo -e "  ${CYAN}Домен панели${NC} (например: panel.example.com): ")" PANEL_DOMAIN
  if [[ -z "$PANEL_DOMAIN" ]]; then
    echo -e "  ${RED}Домен не может быть пустым${NC}"
  elif [[ ! "$PANEL_DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo -e "  ${RED}Некорректный формат домена${NC}"
  else
    break
  fi
done

# Email
while true; do
  read -rp "$(echo -e "  ${CYAN}Email для SSL-сертификата${NC} (Let's Encrypt): ")" ACME_EMAIL
  if [[ -z "$ACME_EMAIL" ]]; then
    echo -e "  ${RED}Email не может быть пустым${NC}"
  elif [[ ! "$ACME_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    echo -e "  ${RED}Некорректный формат email${NC}"
  else
    break
  fi
done

# Директория установки
INSTALL_DIR="/opt/hysteria-panel"
echo -e "\n  ${CYAN}Директория установки:${NC} ${INSTALL_DIR}"

echo ""
echo -e "${YELLOW}  ┌─────────────────────────────────────────┐${NC}"
echo -e "${YELLOW}  │  Домен:   ${PANEL_DOMAIN}${NC}"
echo -e "${YELLOW}  │  Email:   ${ACME_EMAIL}${NC}"
echo -e "${YELLOW}  │  Папка:   ${INSTALL_DIR}${NC}"
echo -e "${YELLOW}  └─────────────────────────────────────────┘${NC}"
echo ""
read -rp "$(echo -e "  Всё верно? Начать установку? [Y/n]: ")" CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo -e "\n  ${YELLOW}Установка отменена.${NC}"
  exit 0
fi

echo ""

# ============================================================
#   ФУНКЦИИ
# ============================================================

log_step() { echo -e "\n${CYAN}[→]${NC} ${BOLD}$1${NC}"; }
log_ok()   { echo -e "  ${GREEN}[✓]${NC} $1"; }
log_err()  { echo -e "  ${RED}[✗]${NC} $1"; exit 1; }
log_info() { echo -e "  ${YELLOW}[i]${NC} $1"; }

# ============================================================
#   ШАГ 1: Обновление системы
# ============================================================

log_step "Обновление системы..."
apt-get update -qq && apt-get upgrade -y -qq
log_ok "Система обновлена"

# ============================================================
#   ШАГ 2: Установка зависимостей
# ============================================================

log_step "Установка зависимостей..."
apt-get install -y -qq curl wget openssl ca-certificates gnupg lsb-release
log_ok "Зависимости установлены"

# ============================================================
#   ШАГ 3: Установка Docker
# ============================================================

log_step "Проверка Docker..."

if command -v docker &>/dev/null; then
  DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ',')
  log_ok "Docker уже установлен (v${DOCKER_VER})"
else
  log_info "Устанавливаем Docker..."
  curl -fsSL https://get.docker.com | sh -s -- -q
  systemctl enable docker --quiet
  systemctl start docker
  log_ok "Docker установлен"
fi

if ! docker compose version &>/dev/null; then
  log_info "Устанавливаем Docker Compose plugin..."
  apt-get install -y -qq docker-compose-plugin
fi

COMPOSE_VER=$(docker compose version --short 2>/dev/null || echo "?")
log_ok "Docker Compose v${COMPOSE_VER}"

# ============================================================
#   ШАГ 4: Создание директории
# ============================================================

log_step "Подготовка директории ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/greenlock.d"
cd "${INSTALL_DIR}"
log_ok "Директория создана"

# ============================================================
#   ШАГ 5: Скачивание файлов
# ============================================================

log_step "Скачивание файлов CELERITY..."

BASE_URL="https://raw.githubusercontent.com/ClickDevTech/hysteria-panel/main"

curl -fsSL -o docker-compose.hub.yml "${BASE_URL}/docker-compose.hub.yml" \
  || log_err "Не удалось скачать docker-compose.hub.yml"
log_ok "docker-compose.hub.yml"

curl -fsSL -o docker.env.example "${BASE_URL}/docker.env.example" \
  || log_err "Не удалось скачать docker.env.example"
log_ok "docker.env.example"

curl -fsSL -o greenlock.d/config.json "${BASE_URL}/greenlock.d/config.json" \
  || log_err "Не удалось скачать greenlock.d/config.json"
log_ok "greenlock.d/config.json"

# ============================================================
#   ШАГ 6: Генерация секретов и создание .env
# ============================================================

log_step "Генерация секретных ключей..."

ENCRYPTION_KEY=$(openssl rand -hex 16)
SESSION_SECRET=$(openssl rand -hex 32)
MONGO_PASSWORD=$(openssl rand -hex 16)
MONGO_USER="celerity"
MONGO_DB="hysteria_panel"

log_ok "Ключи сгенерированы"

log_step "Создание файла .env..."

cp docker.env.example .env

# Функция замены переменной в .env
set_env() {
  local key="$1"
  local val="$2"
  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

set_env "PANEL_DOMAIN"    "${PANEL_DOMAIN}"
set_env "ACME_EMAIL"      "${ACME_EMAIL}"
set_env "ENCRYPTION_KEY"  "${ENCRYPTION_KEY}"
set_env "SESSION_SECRET"  "${SESSION_SECRET}"
set_env "MONGO_PASSWORD"  "${MONGO_PASSWORD}"
set_env "MONGO_USER"      "${MONGO_USER}"
set_env "MONGO_DB"        "${MONGO_DB}"

log_ok ".env создан и настроен"

# Сохраняем данные для вывода
CREDS_FILE="${INSTALL_DIR}/.credentials"
cat > "${CREDS_FILE}" <<EOF
# C³ CELERITY — Данные установки ($(date '+%Y-%m-%d %H:%M:%S'))
PANEL_URL=https://${PANEL_DOMAIN}/panel
PANEL_DOMAIN=${PANEL_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}
ENCRYPTION_KEY=${ENCRYPTION_KEY}
SESSION_SECRET=${SESSION_SECRET}
MONGO_PASSWORD=${MONGO_PASSWORD}
EOF
chmod 600 "${CREDS_FILE}"

# ============================================================
#   ШАГ 7: Открытие портов (UFW если есть)
# ============================================================

log_step "Проверка файрвола..."

if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow 22/tcp   > /dev/null 2>&1
  ufw allow 80/tcp   > /dev/null 2>&1
  ufw allow 443/tcp  > /dev/null 2>&1
  ufw allow 443/udp  > /dev/null 2>&1
  log_ok "UFW: открыты порты 22, 80, 443 (tcp+udp)"
else
  log_info "UFW не активен — пропускаем (настройте порты вручную если нужно)"
fi

# ============================================================
#   ШАГ 8: Запуск панели
# ============================================================

log_step "Запуск CELERITY..."

docker compose -f docker-compose.hub.yml pull -q
docker compose -f docker-compose.hub.yml up -d

log_ok "Контейнеры запущены"

# ============================================================
#   ШАГ 9: Проверка статуса
# ============================================================

log_step "Проверка статуса контейнеров..."
sleep 5

RUNNING=$(docker compose -f docker-compose.hub.yml ps --status running --quiet | wc -l)

if [[ "$RUNNING" -ge 2 ]]; then
  log_ok "${RUNNING} контейнер(а) работают"
else
  echo ""
  echo -e "${RED}  Внимание: запустилось только ${RUNNING} контейнер(а). Проверьте логи:${NC}"
  echo -e "  cd ${INSTALL_DIR} && docker compose -f docker-compose.hub.yml logs"
fi

# ============================================================
#   ИТОГ
# ============================================================

echo ""
echo -e "${GREEN}${BOLD}"
echo "  ┌──────────────────────────────────────────────────────┐"
echo "  │            ✅  УСТАНОВКА ЗАВЕРШЕНА!                   │"
echo "  └──────────────────────────────────────────────────────┘"
echo -e "${NC}"
echo -e "  ${BOLD}Панель управления:${NC}"
echo -e "  🌐  https://${PANEL_DOMAIN}/panel"
echo ""
echo -e "  ${YELLOW}${BOLD}Подождите 1-2 минуты${NC} — панель получает SSL-сертификат."
echo ""
echo -e "  ${BOLD}Полезные команды:${NC}"
echo -e "  📋  Логи:        cd ${INSTALL_DIR} && docker compose -f docker-compose.hub.yml logs -f"
echo -e "  🔄  Рестарт:     cd ${INSTALL_DIR} && docker compose -f docker-compose.hub.yml restart"
echo -e "  ⬆️   Обновление:  cd ${INSTALL_DIR} && docker compose -f docker-compose.hub.yml pull && docker compose -f docker-compose.hub.yml up -d"
echo -e "  🔑  Данные:      cat ${INSTALL_DIR}/.credentials"
echo ""
echo -e "  ${BOLD}Следующий шаг:${NC} зайдите в панель и добавьте ноду через ${CYAN}Nodes → Add Node → Auto Setup${NC}"
echo ""
