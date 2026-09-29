#!/usr/bin/env bash
# ============================================================
#  node_setup.sh — полная автонастройка ноды Remnawave одной командой
#
#  Что делает:
#   - снимает блокировки dpkg, обновляет систему
#   - ставит Docker + compose
#   - создаёт sudo-пользователя с SSH-ключом, переносит SSH на новый порт
#   - поднимает remnanode (/opt/remnanode) с SECRET_KEY из панели
#   - по выбору: Hysteria2 (certbot + проброс сертификатов + cron),
#                Selfsteal (Caddy-заглушка для Reality)
#   - открывает нужные порты в UFW, режет ICMP, включает BBR
#   - генерирует готовый Config Profile для панели (/opt/remnanode/profile.json)
#
#  Запуск:
#   sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/aliisss288-droid/help/main/node_setup.sh)'
#
#  Любой вопрос можно пропустить, задав переменную окружения заранее:
#   NEW_USER, USER_PASS, SSH_PORT, SSH_PUBKEY, SECRET_KEY, NODE_PORT, PANEL_IP,
#   PROTOCOLS="tcp,xhttp,grpc,hy2" (или "all"), SELFSTEAL=y|n, SELFSTEAL_DOMAIN,
#   SELFSTEAL_PORT, REALITY_SNI, HY2_DOMAIN, HY2_PORT, CERT_EMAIL,
#   TCP_PORT, XHTTP_PORT, GRPC_PORT, ASSUME_YES=1
# ============================================================
set -euo pipefail

# ── Цвета ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
die()     { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
head_()   { echo -e "\n${BOLD}══════ $* ══════${RESET}"; }

[[ $EUID -eq 0 ]] || die "Запусти скрипт от root: sudo bash $0"

NODE_DIR="/opt/remnanode"
CERTBOT_DIR="/opt/certbot"
CADDY_DIR="/opt/caddy"
SUMMARY_FILE="/root/node-setup-summary.txt"

# ============================================================
#  Помощники ввода (читаем из /dev/tty — работает и через curl | bash)
# ============================================================
tty_read() { # tty_read <var> <prompt> [-s]
    local __v
    if [[ "${3:-}" == "-s" ]]; then read -rsp "$2" __v </dev/tty; echo >&2
    else read -rp "$2" __v </dev/tty; fi
    printf -v "$1" '%s' "$__v"
}

# ask <var> <prompt> [default] — пропускается, если переменная уже задана
ask() {
    local __var=$1 __prompt=$2 __def=${3:-} __val
    [[ -n "${!__var:-}" ]] && return 0
    while true; do
        if [[ -n "$__def" ]]; then
            tty_read __val "$__prompt [$__def]: "
            __val=${__val:-$__def}
        else
            tty_read __val "$__prompt: "
        fi
        [[ -n "$__val" ]] && break
        warn "Значение не может быть пустым."
    done
    printf -v "$__var" '%s' "$__val"
}

ask_yn() { # ask_yn <var> <prompt> <default y|n>
    local __var=$1 __ans
    if [[ -z "${!__var:-}" ]]; then
        tty_read __ans "$2 [$( [[ $3 == y ]] && echo 'Y/n' || echo 'y/N')]: "
        __ans=${__ans:-$3}
    else
        __ans=${!__var}
    fi
    [[ "${__ans,,}" =~ ^(y|yes|д|да|1)$ ]] && printf -v "$__var" 'y' || printf -v "$__var" 'n'
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

# Занятые TCP-порты — чтобы протоколы не конфликтовали между собой
declare -A USED_TCP=()
ask_tcp_port() { # ask_tcp_port <var> <prompt> <default> <label>
    local __var=$1
    while true; do
        ask "$__var" "$2" "$3"
        local p=${!__var}
        if ! valid_port "$p"; then
            warn "Некорректный порт: $p"
        elif [[ -n "${USED_TCP[$p]:-}" ]]; then
            warn "TCP-порт $p уже занят: ${USED_TCP[$p]}"
        else
            USED_TCP[$p]=$4; return 0
        fi
        printf -v "$__var" '%s' ""
    done
}

check_dns() { # check_dns <domain>
    local domain=$1 resolved
    [[ -z "$SERVER_IP" ]] && { warn "IP сервера неизвестен — пропускаю проверку DNS для $domain."; return 0; }
    resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
    if [[ "$resolved" == "$SERVER_IP" ]]; then
        success "DNS: $domain → $resolved (совпадает)"
        return 0
    fi
    if [[ -z "$resolved" ]]; then
        warn "Домен $domain не резолвится. Проверь A-запись."
    else
        warn "A-запись $domain → $resolved, а сервер → $SERVER_IP (НЕ совпадает)."
    fi
    local go=""
    ask_yn go "Продолжить всё равно?" n
    [[ $go == y ]] || die "Отмена. Исправь DNS и запусти скрипт заново."
}

SERVER_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"

# ============================================================
#  1. СБОР ПАРАМЕТРОВ
# ============================================================
head_ "Пользователь и SSH"

while true; do
    ask NEW_USER "Имя нового пользователя"
    [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$NEW_USER" != root ]] && break
    warn "Недопустимое имя (латиница в нижнем регистре, цифры, _ и -)."; NEW_USER=""
done

if [[ -z "${USER_PASS:-}" ]]; then
    while true; do
        if id "$NEW_USER" &>/dev/null; then
            tty_read USER_PASS "Пароль для '$NEW_USER' (для sudo; Enter — оставить текущий): " -s
            [[ -z "$USER_PASS" ]] && break
        else
            tty_read USER_PASS "Пароль для '$NEW_USER' (нужен для sudo): " -s
            [[ -z "$USER_PASS" ]] && { warn "Пароль не может быть пустым."; continue; }
        fi
        tty_read _pass2 "Повтори пароль: " -s
        [[ "$USER_PASS" == "$_pass2" ]] && break
        warn "Пароли не совпадают."; USER_PASS=""
    done
fi

ask_tcp_port SSH_PORT "Порт SSH" "8833" "SSH"

while true; do
    ask SSH_PUBKEY "Публичный SSH-ключ (ssh-ed25519 AAAA... user@host)"
    [[ "$SSH_PUBKEY" =~ ^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp(256|384|521)|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]] && break
    warn "Это не похоже на публичный ключ OpenSSH."; SSH_PUBKEY=""
done

head_ "Нода Remnawave"

ask SECRET_KEY "SECRET_KEY ноды (из панели: Nodes → Management → Copy docker-compose.yml)"
# Чистим, если вставили целиком строку вида SECRET_KEY="...."
SECRET_KEY="${SECRET_KEY#*SECRET_KEY=}"
SECRET_KEY="${SECRET_KEY//\"/}"; SECRET_KEY="${SECRET_KEY//\'/}"
SECRET_KEY="$(echo -n "$SECRET_KEY" | tr -d '[:space:]')"
[[ -n "$SECRET_KEY" ]] || die "SECRET_KEY пустой."

ask_tcp_port NODE_PORT "Node Port (порт API ноды, как в панели)" "2222" "Node API"

if [[ -z "${PANEL_IP+x}" ]]; then
    tty_read PANEL_IP "IP панели — открыть Node Port только для него (Enter — для всех): "
fi

head_ "Протоколы"

USE_TCP=n; USE_XHTTP=n; USE_GRPC=n; USE_HY2=n
if [[ -z "${PROTOCOLS:-}" ]]; then
    echo "  1) VLESS TCP Reality   — proxy (443)"
    echo "  2) VLESS XHTTP Reality — bg (444)"
    echo "  3) VLESS gRPC Reality  — bg-2 (6437)"
    echo "  4) Hysteria2"
    echo "  5) Все протоколы"
    tty_read PROTOCOLS "Какие включить? Номера через пробел или запятую [1]: "
    PROTOCOLS=${PROTOCOLS:-1}
fi
for p in ${PROTOCOLS//,/ }; do
    case "${p,,}" in
        1|tcp)            USE_TCP=y ;;
        2|xhttp)          USE_XHTTP=y ;;
        3|grpc)           USE_GRPC=y ;;
        4|hy2|hysteria2)  USE_HY2=y ;;
        5|all|все)        USE_TCP=y; USE_XHTTP=y; USE_GRPC=y; USE_HY2=y ;;
        *) die "Неизвестный протокол: $p" ;;
    esac
done
[[ $USE_TCP$USE_XHTTP$USE_GRPC$USE_HY2 == *y* ]] || die "Не выбран ни один протокол."

USE_REALITY=n
[[ $USE_TCP == y || $USE_XHTTP == y || $USE_GRPC == y ]] && USE_REALITY=y

[[ $USE_TCP   == y ]] && ask_tcp_port TCP_PORT   "Порт VLESS TCP Reality (proxy)"  "443"  "proxy (TCP)"
[[ $USE_XHTTP == y ]] && ask_tcp_port XHTTP_PORT "Порт VLESS XHTTP Reality (bg)" "444"  "bg (XHTTP)"
[[ $USE_GRPC  == y ]] && ask_tcp_port GRPC_PORT  "Порт VLESS gRPC Reality (bg-2)" "6437" "bg-2 (gRPC)"

if [[ $USE_HY2 == y ]]; then
    while true; do
        ask HY2_PORT "UDP-порт Hysteria2" "8443"
        valid_port "$HY2_PORT" && break
        warn "Некорректный порт."; HY2_PORT=""
    done
    ask HY2_DOMAIN "Домен для сертификата Hysteria2 (например secure-h2.de01.domain.com)"
    ask CERT_EMAIL "E-mail для Let's Encrypt" "Mail.com"
fi

head_ "Selfsteal"

SELFSTEAL=${SELFSTEAL:-}
if [[ $USE_REALITY == y ]]; then
    ask_yn SELFSTEAL "Нужен Selfsteal (Caddy-заглушка для Reality)?" y
else
    ask_yn SELFSTEAL "Нужен Selfsteal (Reality не выбран — обычно не нужен)?" n
fi

if [[ $SELFSTEAL == y ]]; then
    ask SELFSTEAL_DOMAIN "Домен Selfsteal (= serverNames в Reality, например secure-web.de01.domain.com)"
    ask_tcp_port SELFSTEAL_PORT "HTTPS-порт Selfsteal (= target Reality)" "9443" "Selfsteal"
    REALITY_SNI="$SELFSTEAL_DOMAIN"
    REALITY_TARGET="127.0.0.1:${SELFSTEAL_PORT}"
elif [[ $USE_REALITY == y ]]; then
    ask REALITY_SNI "Чужой домен для маскировки Reality (SNI)" "www.google.com"
    REALITY_TARGET="${REALITY_SNI}:443"
fi

# Порт 80 нужен для выпуска сертификатов (certbot / Caddy)
NEED_80=n
[[ $USE_HY2 == y || $SELFSTEAL == y ]] && NEED_80=y
if [[ $NEED_80 == y && -n "${USED_TCP[80]:-}" ]]; then
    die "Порт 80 занят (${USED_TCP[80]}), а он нужен для выпуска сертификатов."
fi

# ── DNS-проверки ─────────────────────────────────────────────
head_ "Проверка DNS"
info "IP сервера: ${SERVER_IP:-не определён}"
[[ $USE_HY2   == y ]] && check_dns "$HY2_DOMAIN"
[[ $SELFSTEAL == y ]] && check_dns "$SELFSTEAL_DOMAIN"
[[ $USE_HY2 == n && $SELFSTEAL == n ]] && info "Домены не требуются."

# ── Подтверждение ────────────────────────────────────────────
head_ "Проверь параметры"
yn() { [[ $1 == y ]] && echo "да" || echo "нет"; }
cat <<EOF
  Пользователь      : $NEW_USER
  SSH-порт          : $SSH_PORT
  SSH-ключ          : ${SSH_PUBKEY:0:40}...
  SECRET_KEY        : ${SECRET_KEY:0:12}... (${#SECRET_KEY} симв.)
  Node Port         : $NODE_PORT ${PANEL_IP:+(только с $PANEL_IP)}
  VLESS TCP         : $(yn $USE_TCP)${TCP_PORT:+, порт $TCP_PORT/tcp}
  VLESS XHTTP       : $(yn $USE_XHTTP)${XHTTP_PORT:+, порт $XHTTP_PORT/tcp}
  VLESS gRPC        : $(yn $USE_GRPC)${GRPC_PORT:+, порт $GRPC_PORT/tcp}
  Hysteria2         : $(yn $USE_HY2)${HY2_PORT:+, порт $HY2_PORT/udp, домен $HY2_DOMAIN}
  Selfsteal         : $(yn $SELFSTEAL)${SELFSTEAL_DOMAIN:+, $SELFSTEAL_DOMAIN → 127.0.0.1:$SELFSTEAL_PORT}
EOF
[[ $USE_REALITY == y && $SELFSTEAL == n ]] && echo "  Reality SNI       : $REALITY_SNI"
echo
if [[ "${ASSUME_YES:-}" != 1 ]]; then
    GO=""; ask_yn GO "Всё верно, начинаем?" y
    [[ $GO == y ]] || die "Отменено пользователем."
fi

# С этого момента обрыв SSH не убивает установку:
# SIGHUP игнорируется, весь вывод дублируется в лог (tee не падает, если терминал пропал).
INSTALL_LOG="/var/log/node-setup.log"
echo "===== $(date '+%F %T') node_setup.sh =====" >> "$INSTALL_LOG"
trap '' HUP
exec > >(tee -a --output-error=warn "$INSTALL_LOG") 2>&1
info "Если SSH отвалится — установка продолжится. Следить: tail -f $INSTALL_LOG"

# ============================================================
#  2. БЛОКИРОВКИ DPKG И ОБНОВЛЕНИЕ СИСТЕМЫ
# ============================================================
head_ "Обновление системы"

if pgrep -x unattended-upgr &>/dev/null; then
    warn "Останавливаю unattended-upgrades..."
    systemctl stop unattended-upgrades 2>/dev/null || true
    killall unattended-upgrades 2>/dev/null || true
    sleep 3
fi
rm -f /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock
dpkg --configure -a 2>/dev/null || true
systemctl disable unattended-upgrades 2>/dev/null || true
systemctl mask unattended-upgrades 2>/dev/null || true

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
# Длинный вывод apt/dpkg пишем в лог, на экран — только статус
run_logged() { # run_logged <описание> <команда...>
    info "$1... (лог: $INSTALL_LOG)"
    shift
    "$@" >>"$INSTALL_LOG" 2>&1 || die "Ошибка на шаге выше. Смотри: tail -50 $INSTALL_LOG"
}
run_logged "apt update"            apt-get update -qq
run_logged "Обновление пакетов"    apt-get upgrade "${APT_OPTS[@]}"
run_logged "Установка утилит"      apt-get install "${APT_OPTS[@]}" curl ca-certificates openssl jq ufw cron dnsutils
run_logged "Очистка"               apt-get autoremove "${APT_OPTS[@]}"
apt-get clean
success "Система обновлена."

# ============================================================
#  3. DOCKER
# ============================================================
head_ "Docker"

if command -v docker &>/dev/null; then
    success "Docker уже установлен: $(docker --version)"
else
    run_logged "Установка Docker" sh -c "curl -fsSL https://get.docker.com | sh"
    success "Docker установлен: $(docker --version)"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
if ! docker info &>/dev/null; then
    systemctl restart docker; sleep 5
    docker info &>/dev/null || die "Docker не запустился: systemctl status docker"
fi
docker compose version &>/dev/null || run_logged "Установка docker compose" apt-get install "${APT_OPTS[@]}" docker-compose-plugin
docker compose version &>/dev/null || die "Не удалось установить docker compose plugin."
success "$(docker compose version)"

# ============================================================
#  4. ПОЛЬЗОВАТЕЛЬ И SSH-КЛЮЧ
# ============================================================
head_ "Пользователь $NEW_USER"

if id "$NEW_USER" &>/dev/null; then
    warn "Пользователь уже существует — не создаю."
else
    useradd -m -s /bin/bash "$NEW_USER"
    success "Пользователь создан."
fi
[[ -n "${USER_PASS:-}" ]] && echo "${NEW_USER}:${USER_PASS}" | chpasswd && success "Пароль установлен."
usermod -aG sudo,docker "$NEW_USER"
success "'$NEW_USER' добавлен в группы sudo и docker."

USER_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$SSH_DIR"
touch "$AUTH_KEYS"
grep -qxF "$SSH_PUBKEY" "$AUTH_KEYS" || echo "$SSH_PUBKEY" >> "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"; chown "$NEW_USER:$NEW_USER" "$AUTH_KEYS"
success "Ключ добавлен в $AUTH_KEYS"

# ============================================================
#  5. СЕТЕВОЙ ТЮНИНГ (BBR + буферы для QUIC/Hysteria2)
# ============================================================
head_ "Сетевой тюнинг"
cat > /etc/sysctl.d/99-remnanode.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sysctl --system >/dev/null 2>&1 || true
success "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"

# ============================================================
#  6. UFW
# ============================================================
head_ "Firewall (UFW)"

# Сначала открываем SSH (и старый, и новый), потом включаем — чтобы не отрезать себя
ufw allow OpenSSH >/dev/null
ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null

if [[ -n "${PANEL_IP:-}" ]]; then
    ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'Remnawave panel' >/dev/null
else
    ufw allow "${NODE_PORT}/tcp" comment 'Remnawave node API' >/dev/null
fi
[[ $USE_TCP   == y ]] && ufw allow "${TCP_PORT}/tcp"   comment 'VLESS TCP'   >/dev/null
[[ $USE_XHTTP == y ]] && ufw allow "${XHTTP_PORT}/tcp" comment 'VLESS XHTTP' >/dev/null
[[ $USE_GRPC  == y ]] && ufw allow "${GRPC_PORT}/tcp"  comment 'VLESS gRPC'  >/dev/null
[[ $USE_HY2   == y ]] && ufw allow "${HY2_PORT}/udp"   comment 'Hysteria2'   >/dev/null
[[ $NEED_80   == y ]] && ufw allow 80/tcp comment 'ACME' >/dev/null

# ICMP → DROP (как в server_setup.sh)
BEFORE_RULES="/etc/ufw/before.rules"
[[ -f "${BEFORE_RULES}.orig" ]] || cp "$BEFORE_RULES" "${BEFORE_RULES}.orig"
for t in time-exceeded parameter-problem echo-request; do
    sed -i "s/-A ufw-before-input -p icmp --icmp-type $t -j ACCEPT/-A ufw-before-input -p icmp --icmp-type $t -j DROP/" "$BEFORE_RULES"
done
for t in destination-unreachable time-exceeded parameter-problem echo-request; do
    sed -i "s/-A ufw-before-forward -p icmp --icmp-type $t -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type $t -j DROP/" "$BEFORE_RULES"
done
grep -q "source-quench" "$BEFORE_RULES" || \
    sed -i '/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/a -A ufw-before-input -p icmp --icmp-type source-quench -j DROP' "$BEFORE_RULES"

ufw --force enable >/dev/null
ufw reload >/dev/null
success "UFW включён."

# ============================================================
#  7. HYSTERIA2: СЕРТИФИКАТ
# ============================================================
if [[ $USE_HY2 == y ]]; then
    head_ "Hysteria2: сертификат для $HY2_DOMAIN"

    mkdir -p "$CERTBOT_DIR/certs"
    cat > "$CERTBOT_DIR/docker-compose.yml" <<'YAML'
services:
  certbot:
    container_name: certbot
    image: certbot/certbot
    network_mode: host
    volumes:
      - ./certs:/etc/letsencrypt
      - ./var-lib-letsencrypt:/var/lib/letsencrypt
YAML

    CERT_FILE="$CERTBOT_DIR/certs/live/$HY2_DOMAIN/fullchain.pem"
    if [[ -f "$CERT_FILE" ]]; then
        success "Сертификат уже есть — пропускаю выпуск."
    else
        # Освобождаем порт 80 для certbot --standalone
        RUNNING_CONTAINERS="$(docker ps -q)"
        restore_containers() {
            [[ -n "${RUNNING_CONTAINERS:-}" ]] && docker start $RUNNING_CONTAINERS >/dev/null 2>&1 || true
        }
        if [[ -n "$RUNNING_CONTAINERS" ]]; then
            info "Временно останавливаю контейнеры (освобождаю порт 80)..."
            docker stop $RUNNING_CONTAINERS >/dev/null
            trap restore_containers EXIT
        fi

        set +e
        docker run --rm \
            -v "$CERTBOT_DIR/certs:/etc/letsencrypt" \
            -v "$CERTBOT_DIR/var-lib-letsencrypt:/var/lib/letsencrypt" \
            --network host \
            certbot/certbot certonly --standalone \
            --non-interactive --agree-tos \
            --email "$CERT_EMAIL" \
            -d "$HY2_DOMAIN"
        CERTBOT_RC=$?
        set -e

        restore_containers; trap - EXIT
        [[ $CERTBOT_RC -eq 0 && -f "$CERT_FILE" ]] || die "certbot не выпустил сертификат. Проверь DNS и что порт 80 свободен."
        success "Сертификат выпущен: $CERTBOT_DIR/certs/live/$HY2_DOMAIN/"
    fi

    # Скрипт продления: останавливает Caddy (порт 80), продлевает,
    # и перезапускает ноду только если сертификат реально обновился.
    cat > "$CERTBOT_DIR/renew.sh" <<EOF
#!/usr/bin/env bash
CERT="$CERTBOT_DIR/certs/live/$HY2_DOMAIN/fullchain.pem"
before=\$(readlink -f "\$CERT" 2>/dev/null)
[[ -f $CADDY_DIR/docker-compose.yml ]] && (cd $CADDY_DIR && docker compose stop)
cd $CERTBOT_DIR && docker compose run --rm certbot renew --quiet
rc=\$?
[[ -f $CADDY_DIR/docker-compose.yml ]] && (cd $CADDY_DIR && docker compose start)
after=\$(readlink -f "\$CERT" 2>/dev/null)
[[ "\$before" != "\$after" ]] && (cd $NODE_DIR && docker compose restart remnanode)
exit \$rc
EOF
    chmod +x "$CERTBOT_DIR/renew.sh"

    CRON_LINE="0 0 28 * * $CERTBOT_DIR/renew.sh >> /var/log/certbot-renew.log 2>&1"
    ( crontab -l 2>/dev/null | grep -v "certbot renew" | grep -vF "$CERTBOT_DIR/renew.sh"; echo "$CRON_LINE" ) | crontab -
    success "Cron: продление 28-го числа каждого месяца ($CERTBOT_DIR/renew.sh)"
fi

# ============================================================
#  8. НОДА REMNAWAVE
# ============================================================
head_ "Remnanode"

mkdir -p "$NODE_DIR"
[[ -f "$NODE_DIR/docker-compose.yml" ]] && cp "$NODE_DIR/docker-compose.yml" "$NODE_DIR/docker-compose.yml.bak.$(date +%s)"

{
cat <<YAML
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      NODE_PORT: "${NODE_PORT}"
      SECRET_KEY: "${SECRET_KEY}"
YAML
if [[ $USE_HY2 == y ]]; then
cat <<YAML
    volumes:
      - '${CERTBOT_DIR}/certs:/etc/letsencrypt:ro'
YAML
fi
} > "$NODE_DIR/docker-compose.yml"
chmod 600 "$NODE_DIR/docker-compose.yml"

( cd "$NODE_DIR" && docker compose pull -q && docker compose up -d --force-recreate )
sleep 3
docker ps --filter name=remnanode --format '{{.Status}}' | grep -q '^Up' \
    && success "remnanode запущен." \
    || warn "remnanode не в статусе Up — смотри: cd $NODE_DIR && docker compose logs"

# ============================================================
#  9. SELFSTEAL
# ============================================================
if [[ $SELFSTEAL == y ]]; then
    head_ "Selfsteal"
    if command -v selfsteal &>/dev/null || [[ -d "$CADDY_DIR" ]]; then
        warn "Selfsteal уже установлен — пропускаю. Управление: selfsteal status"
    elif ! { : </dev/tty; } 2>/dev/null; then
        warn "Терминал недоступен (SSH отвалился?) — мастер Selfsteal пропущен."
        warn "Запусти вручную: sudo bash -c 'bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install'"
    else
        echo -e "${YELLOW}Сейчас запустится мастер Selfsteal. Отвечай так:${RESET}"
        echo -e "  Домен       → ${BOLD}${SELFSTEAL_DOMAIN}${RESET}"
        echo -e "  Проверка DNS→ ${BOLD}1${RESET}"
        echo -e "  HTTPS-порт  → ${BOLD}${SELFSTEAL_PORT}${RESET}"
        echo
        set +e
        bash <(curl -Ls https://github.com/DigneZzZ/remnawave-scripts/raw/main/selfsteal.sh) @ install </dev/tty
        SS_RC=$?
        set -e
        [[ $SS_RC -eq 0 ]] && success "Selfsteal установлен." \
                          || warn "Установщик Selfsteal завершился с кодом $SS_RC — проверь вручную."
    fi
fi

# ============================================================
#  10. CONFIG PROFILE ДЛЯ ПАНЕЛИ
# ============================================================
head_ "Config Profile для панели"

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
if [[ $USE_REALITY == y ]]; then
    KEY_TMP="$(mktemp)"
    openssl genpkey -algorithm X25519 -out "$KEY_TMP" 2>/dev/null
    REALITY_PRIVATE="$(openssl pkey -in "$KEY_TMP" -outform DER | tail -c 32 | b64url)"
    REALITY_PUBLIC="$(openssl pkey -in "$KEY_TMP" -pubout -outform DER | tail -c 32 | b64url)"
    rm -f "$KEY_TMP"
    SHORT_ID="$(openssl rand -hex 8)"
    XHTTP_PATH="/$(openssl rand -hex 6)"
    GRPC_SERVICE="$(openssl rand -hex 6)"
fi

reality_stream() { # reality_stream <network> <extra-json>
    cat <<JSON
{
  "network": "$1", $2
  "security": "reality",
  "realitySettings": {
    "show": false, "xver": 0,
    "target": "${REALITY_TARGET}",
    "serverNames": ["${REALITY_SNI}"],
    "privateKey": "${REALITY_PRIVATE}",
    "shortIds": ["", "${SHORT_ID}"]
  }
}
JSON
}
vless_inbound() { # vless_inbound <tag> <port> <stream-json>
    cat <<JSON
{
  "tag": "$1", "port": $2, "listen": "0.0.0.0", "protocol": "vless",
  "settings": { "clients": [], "decryption": "none" },
  "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"] },
  "streamSettings": $3
}
JSON
}

INBOUNDS=()
[[ $USE_TCP == y ]] && INBOUNDS+=("$(vless_inbound proxy "$TCP_PORT" \
    "$(reality_stream tcp '')")")
[[ $USE_XHTTP == y ]] && INBOUNDS+=("$(vless_inbound bg "$XHTTP_PORT" \
    "$(reality_stream xhttp "\"xhttpSettings\": { \"path\": \"${XHTTP_PATH}\", \"mode\": \"auto\" },")")")
[[ $USE_GRPC == y ]] && INBOUNDS+=("$(vless_inbound bg-2 "$GRPC_PORT" \
    "$(reality_stream grpc "\"grpcSettings\": { \"serviceName\": \"${GRPC_SERVICE}\" },")")")
[[ $USE_HY2 == y ]] && INBOUNDS+=("$(cat <<JSON
{
  "tag": "HYSTERIA-BBR", "port": ${HY2_PORT}, "listen": "0.0.0.0", "protocol": "hysteria",
  "settings": { "clients": [], "version": 2 },
  "streamSettings": {
    "network": "hysteria",
    "security": "tls",
    "finalmask": { "quicParams": { "debug": false, "congestion": "bbr" } },
    "tlsSettings": {
      "alpn": ["h3"],
      "certificates": [{
        "keyFile": "/etc/letsencrypt/live/${HY2_DOMAIN}/privkey.pem",
        "certificateFile": "/etc/letsencrypt/live/${HY2_DOMAIN}/fullchain.pem"
      }]
    },
    "hysteriaSettings": { "version": 2 }
  }
}
JSON
)")

INBOUNDS_JSON="$(IFS=,; echo "${INBOUNDS[*]}")"
PROFILE_RAW=$(cat <<JSON
{
  "log": { "loglevel": "none" },
  "inbounds": [ ${INBOUNDS_JSON} ],
  "outbounds": [
    { "tag": "DIRECT", "protocol": "freedom" },
    { "tag": "BLOCK", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      { "ip": ["geoip:private"], "outboundTag": "BLOCK" },
      { "domain": ["geosite:private"], "outboundTag": "BLOCK" },
      { "protocol": ["bittorrent"], "outboundTag": "BLOCK" }
    ]
  }
}
JSON
)
if echo "$PROFILE_RAW" | jq . > "$NODE_DIR/profile.json" 2>/dev/null; then
    success "Профиль сохранён: $NODE_DIR/profile.json"
else
    echo "$PROFILE_RAW" > "$NODE_DIR/profile.json"
    warn "JSON профиля не прошёл проверку jq — проверь $NODE_DIR/profile.json вручную."
fi
chmod 600 "$NODE_DIR/profile.json"

# ============================================================
#  11. SSH: НОВЫЙ ПОРТ, ТОЛЬКО КЛЮЧИ
# ============================================================
head_ "SSH"

SSHD_CONFIG="/etc/ssh/sshd_config"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"
# Порт прописываем прямо в /etc/ssh/sshd_config: "#Port 22" → "Port ${SSH_PORT}".
# Сначала комментируем все активные Port (иначе sshd слушает несколько портов),
# затем первую строку "#Port ..." заменяем на нужный порт.
sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#&/' "$SSHD_CONFIG"
if grep -qE '^#[[:space:]]*Port[[:space:]]+' "$SSHD_CONFIG"; then
    sed -i -E "0,/^#[[:space:]]*Port[[:space:]]+.*/s//Port ${SSH_PORT}/" "$SSHD_CONFIG"
else
    echo "Port ${SSH_PORT}" >> "$SSHD_CONFIG"
fi
mkdir -p /etc/ssh/sshd_config.d
# Port в drop-in файлах (cloud-init и т.п.) тоже глушим
sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#&/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONFIG" || \
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_CONFIG"
# Остальные параметры — в 00- (грузится первым и имеет приоритет над 50-cloud-init.conf)
cat > /etc/ssh/sshd_config.d/00-node-setup.conf <<EOF
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

# Страховка: на время проверки sshd слушает И новый порт, И 22.
# Порт 22 закрывается только после того, как ты подтвердишь вход по новому порту.
TEMP22="/etc/ssh/sshd_config.d/99-temp-port22.conf"
[[ "$SSH_PORT" != 22 ]] && echo "Port 22" > "$TEMP22"

mkdir -p /run/sshd
if ! sshd -t; then
    rm -f "$TEMP22"
    die "Ошибка в конфиге sshd — sshd НЕ перезапускался. Бэкап: ${SSHD_CONFIG}.bak.*"
fi
info "sshd_config: $(grep -E '^Port[[:space:]]' "$SSHD_CONFIG")"

# Сервис в Ubuntu/Debian называется ssh, в RHEL-подобных — sshd
if systemctl list-unit-files ssh.service 2>/dev/null | grep -q '^ssh\.service'; then
    SSH_UNIT=ssh
else
    SSH_UNIT=sshd
fi

# Перезапуск sshd НЕ рвёт текущие сессии (KillMode=process) — рвётся только прослушивающий процесс.
restart_sshd() {
    systemctl daemon-reload
    # Ubuntu 22.10+: socket activation — порты берутся из ssh.socket (генерируется из sshd_config)
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        systemctl restart ssh.socket
    fi
    systemctl restart "$SSH_UNIT"
    sleep 2
}
restart_sshd

if ! ss -tln | grep -q ":${SSH_PORT}\b"; then
    warn "SSH НЕ слушает $SSH_PORT! Оставляю порт 22. Проверь: ss -tlnp | grep ssh"
else
    success "SSH слушает порты: $(ss -tlnH | awk '{print $4}' | grep -oE '[0-9]+$' | grep -xE "22|${SSH_PORT}" | sort -u | tr '\n' ' ')"
    CONFIRMED=n
    if [[ "$SSH_PORT" == 22 ]]; then
        CONFIRMED=y
    elif { : </dev/tty; } 2>/dev/null; then
        echo
        echo -e "${BOLD}${YELLOW}Проверь вход по новому порту в НОВОМ окне терминала (это не закрывай!):${RESET}"
        echo -e "    ${BOLD}ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP:-<IP>}${RESET}"
        CONFIRMED=""; ask_yn CONFIRMED "Вход по порту ${SSH_PORT} работает? Закрыть порт 22?" n
    fi

    if [[ $CONFIRMED == y ]]; then
        rm -f "$TEMP22"
        restart_sshd
        ufw delete allow OpenSSH >/dev/null 2>&1 || true
        ufw delete allow 22/tcp  >/dev/null 2>&1 || true
        success "Порт 22 закрыт. SSH только на ${SSH_PORT}."
    else
        warn "Порт 22 оставлен открытым (страховка). Когда проверишь вход по ${SSH_PORT}, закрой его:"
        echo "    sudo rm -f $TEMP22 && sudo systemctl daemon-reload && sudo systemctl restart ssh.socket; sudo systemctl restart $SSH_UNIT"
        echo "    sudo ufw delete allow OpenSSH; sudo ufw delete allow 22/tcp"
    fi
fi

# ============================================================
#  12. ИТОГ
# ============================================================
{
echo "===== Remnawave node setup — $(date '+%F %T') ====="
echo "IP сервера      : ${SERVER_IP:-?}"
echo "SSH             : ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP:-<IP>}"
echo "Node Port       : ${NODE_PORT}"
[[ $USE_TCP   == y ]] && echo "VLESS TCP       : ${TCP_PORT}/tcp"
[[ $USE_XHTTP == y ]] && echo "VLESS XHTTP     : ${XHTTP_PORT}/tcp, path ${XHTTP_PATH}"
[[ $USE_GRPC  == y ]] && echo "VLESS gRPC      : ${GRPC_PORT}/tcp, serviceName ${GRPC_SERVICE}"
[[ $USE_HY2   == y ]] && echo "Hysteria2       : ${HY2_PORT}/udp, домен ${HY2_DOMAIN}"
if [[ $USE_REALITY == y ]]; then
    echo "Reality SNI     : ${REALITY_SNI}"
    echo "Reality target  : ${REALITY_TARGET}"
    echo "Reality private : ${REALITY_PRIVATE}"
    echo "Reality public  : ${REALITY_PUBLIC}"
    echo "Reality shortId : ${SHORT_ID}"
fi
[[ $SELFSTEAL == y ]] && echo "Selfsteal       : ${SELFSTEAL_DOMAIN} → 127.0.0.1:${SELFSTEAL_PORT} (${CADDY_DIR})"
echo "Профиль панели  : ${NODE_DIR}/profile.json"
} > "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"

head_ "ГОТОВО"
cat "$SUMMARY_FILE"
echo
echo -e "${CYAN}UFW:${RESET}"; ufw status
echo
echo -e "${BOLD}Что осталось сделать в панели:${RESET}"
echo "  1. Config Profiles → создать профиль и вставить содержимое:"
echo "       cat ${NODE_DIR}/profile.json"
echo "  2. Nodes → привязать профиль к ноде, включить нужные inbound'ы."
echo "  3. Hosts → создать хосты для каждого inbound'а."
echo
echo "Итог сохранён в ${SUMMARY_FILE}"
warn "НЕ закрывай текущую сессию, пока не проверишь вход: ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP:-<IP>}"
