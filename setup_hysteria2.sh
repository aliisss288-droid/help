#!/usr/bin/env bash
#
# setup-hysteria2.sh
# Подготовка сервера под Hysteria2 для Remnawave Node.
# Выпускает TLS-сертификат через certbot (отдельный docker-compose в /opt/certbot),
# пробрасывает /opt/certbot/certs в контейнер remnanode как /etc/letsencrypt:ro
# и ставит cron на автообновление (28-е число месяца).
# Firewall НЕ трогает — порты считаются уже открытыми.
# Профиль Hysteria2 в панели настраивается вручную.
#
# Запуск:  sudo bash setup-hysteria2.sh
#
set -euo pipefail

# ── Настройки ────────────────────────────────────────────────
CERT_EMAIL="admin@nimeline.org"
CERTBOT_DIR="/opt/certbot"
NODE_DIR="/opt/remnanode"

# ── Цвета ────────────────────────────────────────────────────
c_ok()   { printf "\033[32m✅ %s\033[0m\n" "$*"; }
c_inf()  { printf "\033[36mℹ️  %s\033[0m\n" "$*"; }
c_warn() { printf "\033[33m⚠️  %s\033[0m\n" "$*"; }
c_err()  { printf "\033[31m❌ %s\033[0m\n" "$*"; }
c_head() { printf "\n\033[1m%s\033[0m\n────────────────────────────────────────\n" "$*"; }

# ── Проверка root ────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  c_err "Запусти через sudo: sudo bash setup-hysteria2.sh"
  exit 1
fi

# ── Проверка docker ──────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  c_err "docker не найден. Нода должна быть уже установлена."
  exit 1
fi

# ── Ввод домена ──────────────────────────────────────────────
c_head "🌐 Домен для Hysteria2"
read -rp "Введи домен для сертификата (например secure-web.de01.nimeline.org): " HY2_DOMAIN
if [[ -z "${HY2_DOMAIN}" ]]; then
  c_err "Домен не введён. Выход."
  exit 1
fi

# ── Проверка DNS ─────────────────────────────────────────────
c_head "🔍 Проверка DNS"
SERVER_IP="$(curl -fsSL https://api.ipify.org 2>/dev/null || echo "")"
if [[ -z "${SERVER_IP}" ]]; then
  c_warn "Не удалось определить внешний IP — пропускаю проверку DNS."
else
  c_inf "IP сервера: ${SERVER_IP}"
  RESOLVED="$(getent ahostsv4 "${HY2_DOMAIN}" 2>/dev/null | awk '{print $1}' | head -n1 || echo "")"
  if [[ -z "${RESOLVED}" ]]; then
    c_warn "Домен ${HY2_DOMAIN} не резолвится. Проверь A-запись."
    read -rp "Продолжить всё равно? [y/N]: " GO
    [[ "${GO,,}" == "y" ]] || { c_err "Отмена."; exit 1; }
  elif [[ "${RESOLVED}" == "${SERVER_IP}" ]]; then
    c_ok "A-запись ${HY2_DOMAIN} → ${RESOLVED} (совпадает)"
  else
    c_warn "A-запись → ${RESOLVED}, сервер → ${SERVER_IP} (НЕ совпадает)."
    read -rp "Продолжить всё равно? [y/N]: " GO
    [[ "${GO,,}" == "y" ]] || { c_err "Отмена."; exit 1; }
  fi
fi

# ── Шаг 1: docker-compose для certbot ────────────────────────
c_head "📦 Настройка Certbot (/opt/certbot)"
mkdir -p "${CERTBOT_DIR}"
cat > "${CERTBOT_DIR}/docker-compose.yml" <<'YAML'
services:
  certbot:
    container_name: certbot
    image: certbot/certbot
    network_mode: host
    volumes:
      - ./certs:/etc/letsencrypt
YAML
c_ok "docker-compose.yml для certbot создан"

# ── Шаг 2: выпуск сертификата ────────────────────────────────
c_head "🔐 Выпуск сертификата Let's Encrypt"

# Освобождаем порт 80 для certbot --standalone: останавливаем все контейнеры.
RUNNING_CONTAINERS="$(docker ps -q)"
if [[ -n "${RUNNING_CONTAINERS}" ]]; then
  c_inf "Останавливаю все запущенные docker-контейнеры (освобождаю порт 80)..."
  docker stop ${RUNNING_CONTAINERS} >/dev/null
  c_ok "Остановлено контейнеров: $(echo "${RUNNING_CONTAINERS}" | wc -w)"
fi

# Восстановление контейнеров при любом выходе.
restore_containers() {
  if [[ -n "${RUNNING_CONTAINERS:-}" ]]; then
    c_inf "Запускаю контейнеры обратно..."
    docker start ${RUNNING_CONTAINERS} >/dev/null 2>&1 || true
    c_ok "Контейнеры восстановлены."
  fi
}
trap restore_containers EXIT

set +e
docker run --rm \
  -v "${CERTBOT_DIR}/certs:/etc/letsencrypt" \
  -v "${CERTBOT_DIR}/var-lib-letsencrypt:/var/lib/letsencrypt" \
  --network host \
  certbot/certbot certonly --standalone \
  --non-interactive --agree-tos \
  --email "${CERT_EMAIL}" \
  -d "${HY2_DOMAIN}"
CERTBOT_RC=$?
set -e

# Восстанавливаем контейнеры сразу и снимаем trap.
restore_containers
trap - EXIT

CERT_FILE="${CERTBOT_DIR}/certs/live/${HY2_DOMAIN}/fullchain.pem"
if [[ ${CERTBOT_RC} -ne 0 || ! -f "${CERT_FILE}" ]]; then
  c_err "certbot не смог выпустить сертификат. Проверь DNS и что порт 80 свободен."
  exit 1
fi
c_ok "Сертификат выпущен: ${CERTBOT_DIR}/certs/live/${HY2_DOMAIN}/"

# ── Шаг 3: проброс сертификатов в ноду ───────────────────────
c_head "📁 Проброс сертификатов в remnanode"
COMPOSE_FILE="${NODE_DIR}/docker-compose.yml"
VOLUME_ENTRY="/opt/certbot/certs:/etc/letsencrypt:ro"
if [[ -f "${COMPOSE_FILE}" ]]; then
  if grep -q "${VOLUME_ENTRY}" "${COMPOSE_FILE}"; then
    c_ok "volume уже присутствует в docker-compose.yml ноды"
  else
    c_warn "Не редактирую docker-compose.yml автоматически, чтобы не сломать YAML."
    echo "Добавь в секцию volumes сервиса remnanode строку:"
    echo ""
    echo "      - '${VOLUME_ENTRY}'"
    echo ""
    read -rp "Открыть docker-compose.yml ноды на редактирование сейчас? [y/N]: " EDIT
    if [[ "${EDIT,,}" == "y" ]]; then
      "${EDITOR:-nano}" "${COMPOSE_FILE}"
    fi
  fi
  c_inf "Перезапускаю ноду (down + up)..."
  ( cd "${NODE_DIR}" && docker compose down && docker compose up -d )
  c_ok "Нода перезапущена"
  c_inf "Проверь, что сертификаты видны в контейнере:"
  echo "   docker exec remnanode ls -la /etc/letsencrypt/live/${HY2_DOMAIN}/"
else
  c_warn "Файл ${COMPOSE_FILE} не найден — добавь volume и перезапусти ноду вручную."
fi

# ── Шаг 5: автообновление через cron ─────────────────────────
c_head "🔄 Автообновление сертификата (cron, 28-е число)"
CRON_LINE="0 0 28 * * cd ${CERTBOT_DIR} && docker compose run --rm certbot renew"
if crontab -l 2>/dev/null | grep -Fq "docker compose run --rm certbot renew"; then
  c_ok "Задание cron уже установлено"
else
  ( crontab -l 2>/dev/null; echo "${CRON_LINE}" ) | crontab -
  c_ok "Cron-задание добавлено: обновление 28-го числа каждого месяца"
fi

# ── Готово ───────────────────────────────────────────────────
c_head "📋 Готово"
c_ok "Сертификат выпущен, проброшен в ноду, автообновление настроено."
c_inf "Осталось вручную: добавить профиль Hysteria2 в панель и создать Host."
c_inf "В путях сертификата профиля используй домен: ${HY2_DOMAIN}"
