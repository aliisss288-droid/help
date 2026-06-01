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
SSH_PORT=8080          # порт SSH

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
#  3. UFW — базовые правила
# ============================================================
info "Настройка UFW..."

ufw --force enable
ufw allow OpenSSH          # временно, пока не переключимся на новый порт

ufw allow 8080/tcp
ufw allow "${SSH_PORT}/tcp"
ufw allow 9443/tcp
ufw allow 443/tcp

success "Базовые правила UFW добавлены."

# ============================================================
#  4. /etc/ufw/before.rules — блокировка лишних ICMP
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
#  5. Создание пользователя
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
#  6. SSH-ключ для нового пользователя
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
#  7. sshd_config
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
#  8. Удаление старых UFW-правил для стандартного SSH
# ============================================================
info "Удаление правил для стандартного SSH (22/OpenSSH)..."

ufw delete allow OpenSSH   2>/dev/null && success "Правило OpenSSH удалено." || warn "Правило OpenSSH не найдено — ок."
ufw delete allow 22/tcp    2>/dev/null && success "Правило 22/tcp удалено."   || warn "Правило 22/tcp не найдено — ок."

# ============================================================
#  9. Итоговая проверка
# ============================================================
echo
echo -e "${BOLD}══════════════ ИТОГ ══════════════${RESET}"

echo -e "\n${CYAN}UFW статус:${RESET}"
ufw status

echo -e "\n${CYAN}SSH listening:${RESET}"
ss -tlnp | grep ssh || warn "SSH не слушает? Проверь вручную: ss -tlnp"

echo
success "Скрипт завершён. Подключайся: ssh -p ${SSH_PORT} ${NEW_USER}@<IP>"
warn "НЕ закрывай текущую сессию до проверки нового подключения!"
