#!/usr/bin/env bash
# ============================================================
#  server_setup.sh — Server hardening & SSH configuration
# ============================================================
set -euo pipefail

# ── Цвета ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

# ── Root-проверка ─────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Запусти скрипт от root: sudo bash $0"

# ============================================================
#  1. ПЕРЕМЕННЫЕ — измени при необходимости
# ============================================================
NEW_USER="allison"
SSH_PORT=8833          # порт SSH

# Публичный ключ: укажи прямо здесь или оставь пустым — скрипт спросит
SSH_PUBKEY=""

# ============================================================
#  2. ВВОД ПУБЛИЧНОГО КЛЮЧА (если не задан выше)
# ============================================================
if [[ -z "$SSH_PUBKEY" ]]; then
    echo
    echo -e "${BOLD}Вставь публичный SSH-ключ для пользователя '${NEW_USER}'${RESET}"
    echo -e "(например: ssh-ed25519 AAAA... user@host)"
    read -rp "> " SSH_PUBKEY
    [[ -n "$SSH_PUBKEY" ]] || die "Публичный ключ не может быть пустым."
fi

# ============================================================
#  3. СНЯТИЕ БЛОКИРОВКИ DPKG (на случай unattended-upgrades)
# ============================================================
info "Проверка блокировок dpkg..."

# Убиваем unattended-upgrades если запущен
if pgrep -x unattended-upgr &>/dev/null; then
    warn "Обнаружен процесс unattended-upgrades — останавливаем..."
    systemctl stop unattended-upgrades 2>/dev/null || true
    killall unattended-upgrades 2>/dev/null || true
    sleep 3
fi

# Снимаем блокировки
rm -f /var/lib/dpkg/lock-frontend
rm -f /var/lib/dpkg/lock
rm -f /var/cache/apt/archives/lock

# Восстанавливаем dpkg если нужно
dpkg --configure -a 2>/dev/null || true

# Отключаем автообновление чтобы не мешало в будущем
systemctl disable unattended-upgrades 2>/dev/null || true
systemctl mask unattended-upgrades 2>/dev/null || true

success "Блокировки сняты."

# ============================================================
#  4. ОБНОВЛЕНИЕ UBUNTU
# ============================================================
info "Обновление системы Ubuntu..."

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq
apt-get clean

success "Система обновлена."

# ============================================================
#  5. УСТАНОВКА DOCKER
# ============================================================
info "Установка Docker..."

if command -v docker &>/dev/null; then
    warn "Docker уже установлен: $(docker --version) — пропускаем."
else
    # Удаляем старые версии если есть
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Зависимости
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Официальный GPG-ключ Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Репозиторий Docker
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" \
        | tee /etc/apt/sources.list.d/docker.list > /dev/null

    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    # Запуск и автозапуск
    systemctl enable docker
    systemctl start docker

    success "Docker установлен: $(docker --version)"
fi

# Проверяем что Docker демон реально запущен
info "Проверка Docker демона..."
if ! systemctl is-active --quiet docker; then
    warn "Docker демон не запущен — запускаем..."
    systemctl enable docker
    systemctl start docker
    sleep 3
fi

# Финальная проверка доступности сокета
if ! docker info &>/dev/null; then
    warn "Docker сокет недоступен — пробуем перезапустить..."
    systemctl restart docker
    sleep 5
    docker info &>/dev/null || die "Docker демон не запустился! Проверь: systemctl status docker"
fi

success "Docker демон запущен и работает."

# Проверяем docker compose plugin отдельно
info "Проверка docker compose plugin..."
if docker compose version &>/dev/null; then
    success "docker compose: $(docker compose version)"
else
    warn "docker compose plugin не найден — устанавливаем..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq docker-compose-plugin
    if docker compose version &>/dev/null; then
        success "docker compose установлен: $(docker compose version)"
    else
        die "Не удалось установить docker compose plugin!"
    fi
fi

# Добавляем пользователя в группу docker
if id "${NEW_USER}" &>/dev/null; then
    usermod -aG docker "${NEW_USER}"
    success "'${NEW_USER}' добавлен в группу docker."
fi

# ============================================================
#  6. UFW — базовые правила
# ============================================================
info "Настройка UFW..."

# Устанавливаем ufw если нет
apt-get install -y -qq ufw

ufw --force enable
ufw allow OpenSSH          # временно, пока не переключимся на новый порт

ufw allow 80/tcp
ufw allow 2222/tcp
ufw allow "${SSH_PORT}/tcp"
ufw allow 9443/tcp
ufw allow 443/tcp

success "Базовые правила UFW добавлены."

# ============================================================
#  7. /etc/ufw/before.rules — блокировка лишних ICMP
# ============================================================
info "Патчим /etc/ufw/before.rules (DROP для ICMP)..."

BEFORE_RULES="/etc/ufw/before.rules"
cp "${BEFORE_RULES}" "${BEFORE_RULES}.bak.$(date +%s)"

# Меняем ACCEPT → DROP для нежелательных icmp-типов
sed -i \
    -e 's/-A ufw-before-input -p icmp --icmp-type time-exceeded -j ACCEPT/-A ufw-before-input -p icmp --icmp-type time-exceeded -j DROP/' \
    -e 's/-A ufw-before-input -p icmp --icmp-type parameter-problem -j ACCEPT/-A ufw-before-input -p icmp --icmp-type parameter-problem -j DROP/' \
    -e 's/-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/' \
    "${BEFORE_RULES}"

# source-quench: добавляем, если ещё нет
if ! grep -q "source-quench" "${BEFORE_RULES}"; then
    sed -i '/--icmp-type echo-request -j DROP/a -A ufw-before-input -p icmp --icmp-type source-quench -j DROP' \
        "${BEFORE_RULES}"
fi

# FORWARD-блок: destination-unreachable → DROP
sed -i \
    -e 's/-A ufw-before-forward -p icmp --icmp-type destination-unreachable -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type destination-unreachable -j DROP/' \
    -e 's/-A ufw-before-forward -p icmp --icmp-type time-exceeded -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type time-exceeded -j DROP/' \
    -e 's/-A ufw-before-forward -p icmp --icmp-type parameter-problem -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type parameter-problem -j DROP/' \
    -e 's/-A ufw-before-forward -p icmp --icmp-type echo-request -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type echo-request -j DROP/' \
    "${BEFORE_RULES}"

# Перезагружаем UFW чтобы правила вступили в силу
ufw disable && ufw --force enable
success "ICMP-правила применены."

# ============================================================
#  8. Создание пользователя
# ============================================================
info "Создание пользователя '${NEW_USER}'..."

if id "${NEW_USER}" &>/dev/null; then
    warn "Пользователь '${NEW_USER}' уже существует — пропускаем создание."
else
    adduser --gecos "" "${NEW_USER}"
    success "Пользователь '${NEW_USER}' создан."
fi

usermod -aG sudo "${NEW_USER}"
success "'${NEW_USER}' добавлен в группу sudo."

# ============================================================
#  9. SSH-ключ для нового пользователя
# ============================================================
info "Настройка SSH-ключа..."

SSH_DIR="/home/${NEW_USER}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chown "${NEW_USER}:${NEW_USER}" "${SSH_DIR}"

echo "${SSH_PUBKEY}" > "${AUTH_KEYS}"
chmod 600 "${AUTH_KEYS}"
chown "${NEW_USER}:${NEW_USER}" "${AUTH_KEYS}"

success "authorized_keys настроен."

# Проверка прав
info "Проверка прав директорий:"
ls -ld /home/"${NEW_USER}"
ls -ld "${SSH_DIR}"
ls -l  "${AUTH_KEYS}"

# ============================================================
#  10. sshd_config
# ============================================================
info "Настройка /etc/ssh/sshd_config..."

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "${SSHD_CONFIG}" "${SSHD_CONFIG}.bak.$(date +%s)"

# Функция: установить или заменить параметр
set_sshd() {
    local key="$1" val="$2"
    if grep -qE "^#?[[:space:]]*${key}[[:space:]]" "${SSHD_CONFIG}"; then
        sed -i -E "s|^#?[[:space:]]*${key}[[:space:]].*|${key} ${val}|" "${SSHD_CONFIG}"
    else
        echo "${key} ${val}" >> "${SSHD_CONFIG}"
    fi
}

set_sshd "Port"                          "${SSH_PORT}"
set_sshd "PermitRootLogin"               "yes"
set_sshd "PubkeyAuthentication"          "yes"
set_sshd "PasswordAuthentication"        "no"
set_sshd "KbdInteractiveAuthentication"  "no"
set_sshd "X11Forwarding"                 "yes"
set_sshd "PrintMotd"                     "no"
set_sshd "UsePAM"                        "yes"

success "sshd_config обновлён (порт ${SSH_PORT}, парольная аутентификация отключена)."

# Перезапуск SSH
systemctl daemon-reload
systemctl restart ssh
success "SSH-сервис перезапущен."

# ============================================================
#  11. Удаление старых UFW-правил для стандартного SSH
# ============================================================
info "Удаление правил для стандартного SSH (22/OpenSSH)..."

ufw delete allow OpenSSH   2>/dev/null && success "Правило OpenSSH удалено." || warn "Правило OpenSSH не найдено — ок."
ufw delete allow 22/tcp    2>/dev/null && success "Правило 22/tcp удалено."   || warn "Правило 22/tcp не найдено — ок."

# ============================================================
#  12. Итоговая проверка
# ============================================================
echo
echo -e "${BOLD}══════════════ ИТОГ ══════════════${RESET}"

echo -e "\n${CYAN}Версии:${RESET}"
docker --version
docker compose version

echo -e "\n${CYAN}UFW статус:${RESET}"
ufw status

echo -e "\n${CYAN}SSH listening:${RESET}"
ss -tlnp | grep ssh || warn "SSH не слушает? Проверь вручную: ss -tlnp"

echo
success "Скрипт завершён. Подключайся: ssh -p ${SSH_PORT} ${NEW_USER}@<IP>"
warn "НЕ закрывай текущую сессию до проверки нового подключения!"
