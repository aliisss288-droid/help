#!/usr/bin/env bash
# ============================================================
#  node_setup.sh — полная автонастройка ноды Remnawave одной командой
#
#  Ввёл данные в начале → подтвердил → дальше всё делается само:
#   1. обновление системы, Docker + compose
#   2. sudo-пользователь с SSH-ключом
#   3. BBR, UFW (только нужные порты), блокировка ICMP
#   4. Hysteria2: сертификат Let's Encrypt (certbot) + автопродление (cron, 28-е число)
#   5. remnanode: /opt/remnanode/docker-compose.yml заполняется и запускается сам
#   6. Selfsteal: Caddy с сайтом-заглушкой и своим сертификатом (/opt/caddy)
#   7. Config Profile для панели: /opt/remnanode/profile.json
#   8. SSH на новый порт (старый закрывается только после проверки входа)
#   9. итоговая проверка всего, при ошибке — подсказка, как исправить
#
#  Запуск:
#   sudo bash -c 'bash <(curl -fsSL https://raw.githubusercontent.com/aliisss288-droid/help/main/node_setup.sh)'
#
#  Повторный запуск безопасен: готовые шаги пропускаются или обновляются.
#  Любой вопрос можно пропустить, задав переменную окружения заранее:
#   NEW_USER, USER_PASS, SSH_PORT, SSH_PUBKEY, SECRET_KEY, NODE_PORT, PANEL_IP,
#   PROTOCOLS="tcp,xhttp,grpc,hy2" (или "all"), SELFSTEAL=y|n, SELFSTEAL_DOMAIN,
#   SELFSTEAL_PORT, REALITY_SNI, HY2_DOMAIN, HY2_PORT, CERT_EMAIL,
#   TCP_PORT, XHTTP_PORT, GRPC_PORT, ASSUME_YES=1
# ============================================================
set -Eeuo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/aliisss288-droid/help/main/node_setup.sh"
NODE_DIR="/opt/remnanode"
CERTBOT_DIR="/opt/certbot"
CADDY_DIR="/opt/caddy"
SUMMARY_FILE="/root/node-setup-summary.txt"
INSTALL_LOG=""

# ── Вывод ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
head_()   { echo -e "\n${BOLD}══════ $* ══════${RESET}"; }

# fail <что случилось> [как исправить] — понятная ошибка с готовым решением
fail() {
    echo -e "\n${RED}[ОШИБКА]${RESET}  $1" >&2
    if [[ -n "${2:-}" ]]; then echo -e "${YELLOW}[РЕШЕНИЕ]${RESET} $2" >&2; fi
    if [[ -n "$INSTALL_LOG" ]]; then echo -e "          Подробный лог: tail -50 $INSTALL_LOG" >&2; fi
    echo -e "          После исправления запусти скрипт ещё раз — готовые шаги он пропустит." >&2
    exit 1
}
die() { fail "$@"; }

# Любой неожиданный сбой: показать команду и строку, а не выйти молча
on_error() {
    local rc=$? line=$1 cmd=$2
    [[ "$BASHPID" == "$$" ]] || return 0
    echo -e "\n${RED}[ОШИБКА]${RESET}  Неожиданный сбой (код $rc) в строке $line:" >&2
    echo -e "          $cmd" >&2
    echo -e "${YELLOW}[РЕШЕНИЕ]${RESET} Смотри вывод выше${INSTALL_LOG:+ и лог: tail -50 $INSTALL_LOG}." >&2
    echo -e "          Запусти скрипт ещё раз — готовые шаги он пропустит. Если повторится — пришли этот вывод." >&2
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

# ── Предварительные проверки ─────────────────────────────────
[[ $EUID -eq 0 ]] || die "Скрипт запущен не от root." \
    "Запусти так: sudo bash -c 'bash <(curl -fsSL $SCRIPT_URL)'"
command -v apt-get >/dev/null || die "Поддерживаются только Ubuntu и Debian." \
    "Переустанови сервер на Ubuntu 24.04 или 22.04."
command -v systemctl >/dev/null || die "На сервере нет systemd." \
    "Нужен обычный KVM-VPS с Ubuntu 24.04 или 22.04."

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
    if [[ -n "${!__var:-}" ]]; then return 0; fi
    while true; do
        if [[ -n "$__def" ]]; then
            tty_read __val "$__prompt [$__def]: "
            __val=${__val:-$__def}
        else
            tty_read __val "$__prompt: "
        fi
        if [[ -n "$__val" ]]; then break; fi
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
    if [[ "${__ans,,}" =~ ^(y|yes|д|да|1)$ ]]; then printf -v "$__var" 'y'; else printf -v "$__var" 'n'; fi
}

valid_port()   { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_ip()     { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/([0-9]|[12][0-9]|3[0-2]))?$ ]]; }
valid_email()  { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
valid_domain() { [[ "$1" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]]; }

ask_domain() { # ask_domain <var> <prompt> — убирает https:// и /путь, проверяет формат
    local __var=$1 __d
    while true; do
        ask "$__var" "$2"
        __d="${!__var,,}"; __d="${__d#http://}"; __d="${__d#https://}"; __d="${__d%%/*}"
        printf -v "$__var" '%s' "$__d"
        if valid_domain "$__d"; then return 0; fi
        warn "Некорректный домен: $__d"; printf -v "$__var" '%s' ""
    done
}

# Занятые TCP-порты — чтобы протоколы не конфликтовали между собой
declare -A USED_TCP=()
ask_tcp_port() { # ask_tcp_port <var> <prompt> <default> <label>
    local __var=$1 __p
    while true; do
        ask "$__var" "$2" "$3"
        __p=${!__var}
        if ! valid_port "$__p"; then
            warn "Некорректный порт: $__p"
        elif [[ -n "${USED_TCP[$__p]:-}" ]]; then
            warn "TCP-порт $__p уже занят: ${USED_TCP[$__p]}"
        else
            USED_TCP[$__p]=$4; return 0
        fi
        printf -v "$__var" '%s' ""
    done
}

pubkey_ok() { # проверка публичного ключа через ssh-keygen (или по формату, если его нет)
    local f rc=1
    if command -v ssh-keygen >/dev/null; then
        f="$(mktemp)"; printf '%s\n' "$1" > "$f"
        if ssh-keygen -l -f "$f" >/dev/null 2>&1; then rc=0; fi
        rm -f "$f"; return $rc
    fi
    [[ "$1" =~ ^(ssh-(ed25519|rsa)|ecdsa-sha2-nistp(256|384|521)|sk-[a-z0-9-]+@openssh\.com)[[:space:]]+[A-Za-z0-9+/=]+ ]]
}

get_server_ip() {
    local u addr
    for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
        addr="$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$addr"; return 0; fi
    done
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true
}

check_dns() { # check_dns <domain>
    local domain=$1 resolved go=""
    if [[ -z "$SERVER_IP" ]]; then warn "IP сервера неизвестен — пропускаю проверку DNS для $domain."; return 0; fi
    resolved="$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | head -n1 || true)"
    if [[ "$resolved" == "$SERVER_IP" ]]; then
        success "DNS: $domain → $resolved (совпадает)"
        return 0
    fi
    if [[ -z "$resolved" ]]; then
        warn "Домен $domain не резолвится — нет A-записи."
    else
        warn "A-запись $domain → $resolved, а IP сервера → $SERVER_IP (НЕ совпадает)."
    fi
    warn "Без правильной A-записи сертификат НЕ выпустится. Нужна A-запись: $domain → $SERVER_IP"
    ask_yn go "Продолжить всё равно?" n
    [[ $go == y ]] || die "Остановлено: DNS для $domain не указывает на сервер." \
        "В DNS-панели домена создай A-запись $domain → $SERVER_IP (без прокси Cloudflare), подожди 5–10 минут."
}

# Какие процессы слушают порт: port_owners tcp|udp <port>
port_owners() {
    local flag=t; [[ $1 == udp ]] && flag=u
    { ss -Hlnp$flag "( sport = :$2 )" 2>/dev/null | grep -o 'users:(("[^"]*"' | sed 's/users:(("//; s/"$//' | sort -u | tr '\n' ' '; } || true
}

# Порт должен быть свободен или занят «нашими» процессами (повторный запуск)
check_port_free() { # check_port_free tcp|udp <port> <назначение>
    local owners o
    owners="$(port_owners "$1" "$2")"
    for o in $owners; do
        case "$o" in
            rw-core|xray|caddy|node|docker-proxy|sshd|systemd|certbot) ;;
            *) die "Порт $2/$1 ($3) уже занят программой «$o»." \
                   "Останови её: systemctl disable --now $o  (или apt purge $o), либо выбери другой порт." ;;
        esac
    done
}

# wait_until <секунд> <команда...> — ждать, пока команда не станет успешной
wait_until() {
    local t=$1 i; shift
    for ((i = 0; i < t; i += 3)); do
        if "$@" >/dev/null 2>&1; then return 0; fi
        sleep 3
    done
    return 1
}

# retry <попыток> <команда...> — для сетевых операций
retry() {
    local n=$1 i; shift
    for ((i = 1; i <= n; i++)); do
        if "$@"; then return 0; fi
        if (( i < n )); then echo "[retry] попытка $i/$n не удалась, повтор через 10 с..."; sleep 10; fi
    done
    return 1
}

SERVER_IP="$(get_server_ip)"

# Текущие порты SSH (через них ты сейчас подключён — их не трогаем до проверки входа)
mkdir -p /run/sshd
CURRENT_SSH_PORTS="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | sort -u | tr '\n' ' ' || true)"
CURRENT_SSH_PORTS="${CURRENT_SSH_PORTS:-22}"

# ============================================================
#  1. СБОР ПАРАМЕТРОВ
# ============================================================
head_ "Пользователь и SSH"

while true; do
    ask NEW_USER "Имя нового пользователя"
    if [[ "$NEW_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ && "$NEW_USER" != root ]]; then break; fi
    warn "Недопустимое имя (латиница в нижнем регистре, цифры, _ и -)."; NEW_USER=""
done

_pass2=""
if [[ -z "${USER_PASS:-}" ]]; then
    while true; do
        if id "$NEW_USER" &>/dev/null; then
            tty_read USER_PASS "Пароль для '$NEW_USER' (для sudo; Enter — оставить текущий): " -s
            if [[ -z "$USER_PASS" ]]; then break; fi
        else
            tty_read USER_PASS "Пароль для '$NEW_USER' (нужен для sudo): " -s
            if [[ -z "$USER_PASS" ]]; then warn "Пароль не может быть пустым."; continue; fi
        fi
        tty_read _pass2 "Повтори пароль: " -s
        if [[ "$USER_PASS" == "$_pass2" ]]; then break; fi
        warn "Пароли не совпадают."; USER_PASS=""
    done
fi

ask_tcp_port SSH_PORT "Порт SSH" "8833" "SSH"

while true; do
    ask SSH_PUBKEY "Публичный SSH-ключ (ssh-ed25519 AAAA... или ssh-rsa AAAA...)"
    SSH_PUBKEY="$(printf '%s' "$SSH_PUBKEY" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if pubkey_ok "$SSH_PUBKEY"; then break; fi
    warn "Это не публичный ключ OpenSSH. В PuTTYgen копируй поле «Public key for pasting into OpenSSH authorized_keys»."
    SSH_PUBKEY=""
done

head_ "Нода Remnawave"

while true; do
    ask SECRET_KEY "SECRET_KEY ноды (панель: Nodes → Management → Copy docker-compose.yml)"
    # Чистим, если вставили целиком строку вида SECRET_KEY="...." или - SECRET_KEY=...
    SECRET_KEY="${SECRET_KEY#*SECRET_KEY=}"; SECRET_KEY="${SECRET_KEY#*SECRET_KEY: }"
    SECRET_KEY="${SECRET_KEY//\"/}"; SECRET_KEY="${SECRET_KEY//\'/}"
    SECRET_KEY="$(printf '%s' "$SECRET_KEY" | tr -d '[:space:]')"
    if [[ "$SECRET_KEY" =~ ^[A-Za-z0-9+/=_-]{100,}$ ]]; then break; fi
    warn "SECRET_KEY выглядит неправильно (должна быть длинная строка вида eyJub2RlQ2Vy...). Скопируй заново из панели."
    SECRET_KEY=""
done

ask_tcp_port NODE_PORT "Node Port (порт API ноды, как в панели)" "2222" "Node API"

if [[ -z "${PANEL_IP+x}" ]]; then
    while true; do
        tty_read PANEL_IP "IP панели — открыть Node Port только для него (Enter — для всех): "
        if [[ -z "$PANEL_IP" ]] || valid_ip "$PANEL_IP"; then break; fi
        warn "Некорректный IP: $PANEL_IP"
    done
elif [[ -n "$PANEL_IP" ]] && ! valid_ip "$PANEL_IP"; then
    die "PANEL_IP=$PANEL_IP — некорректный IP." "Укажи IP вида 1.2.3.4 или оставь пустым."
fi

head_ "Протоколы"

USE_TCP=n; USE_XHTTP=n; USE_GRPC=n; USE_HY2=n
if [[ -z "${PROTOCOLS:-}" ]]; then
    echo "  1) VLESS TCP Reality   — proxy (443)"
    echo "  2) VLESS XHTTP Reality — bg (444)"
    echo "  3) VLESS gRPC Reality  — bg-2 (6437)"
    echo "  4) Hysteria2           — UDP 8443"
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
        *) die "Неизвестный протокол: $p" "Вводи номера 1–5 через пробел, например: 1 2 4" ;;
    esac
done

USE_REALITY=n
if [[ $USE_TCP == y || $USE_XHTTP == y || $USE_GRPC == y ]]; then USE_REALITY=y; fi

if [[ $USE_TCP   == y ]]; then ask_tcp_port TCP_PORT   "Порт VLESS TCP Reality (proxy)"  "443"  "proxy (TCP)"; fi
if [[ $USE_XHTTP == y ]]; then ask_tcp_port XHTTP_PORT "Порт VLESS XHTTP Reality (bg)"   "444"  "bg (XHTTP)"; fi
if [[ $USE_GRPC  == y ]]; then ask_tcp_port GRPC_PORT  "Порт VLESS gRPC Reality (bg-2)"  "6437" "bg-2 (gRPC)"; fi

if [[ $USE_HY2 == y ]]; then
    while true; do
        ask HY2_PORT "UDP-порт Hysteria2" "8443"
        if valid_port "$HY2_PORT"; then break; fi
        warn "Некорректный порт."; HY2_PORT=""
    done
    ask_domain HY2_DOMAIN "Домен для сертификата Hysteria2 (например secure-h2.de01.domain.com)"
fi

head_ "Selfsteal"

SELFSTEAL=${SELFSTEAL:-}
if [[ $USE_REALITY == y ]]; then
    ask_yn SELFSTEAL "Нужен Selfsteal (сайт-заглушка для Reality)?" y
else
    ask_yn SELFSTEAL "Нужен Selfsteal (Reality не выбран — обычно не нужен)?" n
fi

if [[ $SELFSTEAL == y ]]; then
    ask_domain SELFSTEAL_DOMAIN "Домен Selfsteal (= serverNames в Reality, например secure-web.de01.domain.com)"
    if [[ $USE_HY2 == y && "$SELFSTEAL_DOMAIN" == "$HY2_DOMAIN" ]]; then
        die "Домены Selfsteal и Hysteria2 совпадают ($HY2_DOMAIN)." "Используй два разных поддомена, например secure-web.* и secure-h2.*"
    fi
    ask_tcp_port SELFSTEAL_PORT "Внутренний HTTPS-порт Selfsteal (= target Reality)" "9443" "Selfsteal"
    REALITY_SNI="$SELFSTEAL_DOMAIN"
    REALITY_TARGET="127.0.0.1:${SELFSTEAL_PORT}"
elif [[ $USE_REALITY == y ]]; then
    ask_domain REALITY_SNI "Чужой домен для маскировки Reality (SNI)"
    REALITY_TARGET="${REALITY_SNI}:443"
fi

# Порт 80 нужен для выпуска сертификатов (certbot / Caddy)
NEED_80=n
if [[ $USE_HY2 == y || $SELFSTEAL == y ]]; then NEED_80=y; fi
if [[ $NEED_80 == y && -n "${USED_TCP[80]:-}" ]]; then
    die "Порт 80 отдан под «${USED_TCP[80]}», а он нужен для выпуска сертификатов." "Выбери для «${USED_TCP[80]}» другой порт."
fi

if [[ $NEED_80 == y && -z "${CERT_EMAIL+x}" ]]; then
    while true; do
        tty_read CERT_EMAIL "E-mail для Let's Encrypt (Enter — без e-mail): "
        if [[ -z "$CERT_EMAIL" ]] || valid_email "$CERT_EMAIL"; then break; fi
        warn "Некорректный e-mail: $CERT_EMAIL"
    done
fi
CERT_EMAIL="${CERT_EMAIL:-}"
if [[ -n "$CERT_EMAIL" ]] && ! valid_email "$CERT_EMAIL"; then
    die "Некорректный e-mail: $CERT_EMAIL" "Укажи настоящий адрес или оставь пустым."
fi

# ── DNS-проверки ─────────────────────────────────────────────
head_ "Проверка DNS"
info "IP сервера: ${SERVER_IP:-не определён}"
if [[ $USE_HY2   == y ]]; then check_dns "$HY2_DOMAIN"; fi
if [[ $SELFSTEAL == y ]]; then check_dns "$SELFSTEAL_DOMAIN"; fi
if [[ $USE_HY2 == n && $SELFSTEAL == n ]]; then info "Домены не требуются."; fi

# ── Подтверждение ────────────────────────────────────────────
head_ "Проверь параметры"
yn() { if [[ $1 == y ]]; then echo "да"; else echo "нет"; fi; }
cat <<EOF
  Пользователь      : $NEW_USER
  SSH-порт          : $SSH_PORT (сейчас: ${CURRENT_SSH_PORTS% })
  SSH-ключ          : ${SSH_PUBKEY:0:40}...
  SECRET_KEY        : ${SECRET_KEY:0:12}... (${#SECRET_KEY} симв.)
  Node Port         : $NODE_PORT ${PANEL_IP:+(только с $PANEL_IP)}
  VLESS TCP         : $(yn $USE_TCP)${TCP_PORT:+, порт $TCP_PORT/tcp}
  VLESS XHTTP       : $(yn $USE_XHTTP)${XHTTP_PORT:+, порт $XHTTP_PORT/tcp}
  VLESS gRPC        : $(yn $USE_GRPC)${GRPC_PORT:+, порт $GRPC_PORT/tcp}
  Hysteria2         : $(yn $USE_HY2)${HY2_PORT:+, порт $HY2_PORT/udp, домен $HY2_DOMAIN}
  Selfsteal         : $(yn $SELFSTEAL)${SELFSTEAL_DOMAIN:+, $SELFSTEAL_DOMAIN → 127.0.0.1:$SELFSTEAL_PORT}
  E-mail (LE)       : ${CERT_EMAIL:-—}
EOF
if [[ $USE_REALITY == y && $SELFSTEAL == n ]]; then echo "  Reality SNI       : $REALITY_SNI"; fi
echo
if [[ "${ASSUME_YES:-}" != 1 ]]; then
    GO=""; ask_yn GO "Всё верно, начинаем? Дальше всё пойдёт автоматически" y
    [[ $GO == y ]] || die "Отменено пользователем."
fi

# С этого момента обрыв SSH не убивает установку:
# SIGHUP игнорируется, весь вывод дублируется в лог (tee не падает, если терминал пропал).
INSTALL_LOG="/var/log/node-setup.log"
echo "===== $(date '+%F %T') node_setup.sh =====" >> "$INSTALL_LOG"
trap '' HUP
exec > >(tee -a --output-error=warn "$INSTALL_LOG") 2>&1
info "Если SSH отвалится — установка продолжится. Следить: tail -f $INSTALL_LOG"

# ── Проверка ресурсов и занятых портов ───────────────────────
head_ "Предварительная проверка"
FREE_MB="$(df -Pm / | awk 'NR==2{print $4}')"
if (( FREE_MB < 2000 )); then
    die "На диске свободно всего ${FREE_MB} МБ." "Нужно минимум 2 ГБ: очисти диск (apt clean, docker system prune -a) или возьми тариф побольше."
fi
for p in "${!USED_TCP[@]}"; do
    if [[ "$p" != "$SSH_PORT" ]]; then check_port_free tcp "$p" "${USED_TCP[$p]}"; fi
done
if [[ $NEED_80 == y ]]; then check_port_free tcp 80 "выпуск сертификатов"; fi
if [[ $USE_HY2 == y ]]; then check_port_free udp "$HY2_PORT" "Hysteria2"; fi
# shellcheck disable=SC2076  # намеренно буквальное совпадение порта в списке
if [[ ! " $CURRENT_SSH_PORTS " =~ " $SSH_PORT " ]]; then check_port_free tcp "$SSH_PORT" "новый SSH"; fi
success "Диск: ${FREE_MB} МБ свободно, нужные порты свободны."

# ============================================================
#  2. ОБНОВЛЕНИЕ СИСТЕМЫ
# ============================================================
head_ "Обновление системы"

# NEEDRESTART_SUSPEND — чтобы apt не перезапускал службы (сеть, ssh) посреди установки
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l NEEDRESTART_SUSPEND=1
APT_OPTS=(-y -qq -o DPkg::Lock::Timeout=600 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# Длинный вывод apt/docker пишем только в лог, на экран — статус
run_logged() { # run_logged <описание> <решение при ошибке> <команда...>
    local desc=$1 sol=$2 out rc=0; shift 2
    info "$desc..."
    out="$(mktemp)"
    retry 3 "$@" >"$out" 2>&1 || rc=$?
    cat "$out" >> "$INSTALL_LOG"
    if (( rc != 0 )); then
        show_output "$out" 15
        rm -f "$out"
        fail "$desc — не удалось." "$sol"
    fi
    rm -f "$out"
}

# show_output <файл> <строк> — показать хвост вывода упавшей команды
show_output() {
    echo "------ вывод команды (последние строки) ------"
    tail -n "$2" "$1" || true
    echo "----------------------------------------------"
}

# Ждём, пока закончится автообновление (иначе apt занят)
if pgrep -x 'apt|apt-get|dpkg|unattended-upgr' >/dev/null; then
    info "Сейчас работает автообновление Ubuntu — жду его завершения (до 10 минут)..."
    if ! wait_until 600 bash -c '! pgrep -x "apt|apt-get|dpkg|unattended-upgr"'; then
        warn "Автообновление висит — останавливаю его."
        systemctl stop unattended-upgrades apt-daily.service apt-daily-upgrade.service 2>/dev/null || true
        pkill -x unattended-upgr 2>/dev/null || true
        sleep 5
    fi
fi
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl disable --now unattended-upgrades 2>/dev/null || true
dpkg --configure -a >>"$INSTALL_LOG" 2>&1 || true

APT_FIX="Проверь интернет на сервере (ping -c3 8.8.8.8) и выполни: dpkg --configure -a && apt-get -f install"
run_logged "Обновление списка пакетов" "$APT_FIX" apt-get update -qq -o DPkg::Lock::Timeout=600
run_logged "Обновление пакетов (может занять 5–10 минут)" "$APT_FIX" apt-get upgrade "${APT_OPTS[@]}"
run_logged "Установка утилит" "$APT_FIX" \
    apt-get install "${APT_OPTS[@]}" curl ca-certificates openssl jq ufw cron iproute2 procps
run_logged "Очистка" "$APT_FIX" apt-get autoremove "${APT_OPTS[@]}"
apt-get clean
systemctl enable --now cron >/dev/null 2>&1 || true
success "Система обновлена."

# ============================================================
#  3. DOCKER
# ============================================================
head_ "Docker"

# Если сеть хостера в диапазоне 172.16–31.x, стандартная сеть Docker (172.17.0.0/16)
# конфликтует с ней и сервер теряет связь. Тогда задаём Docker другой диапазон.
if [[ ! -f /etc/docker/daemon.json ]] && ip -4 route | grep -qE '(^|[[:space:]])172\.(1[6-9]|2[0-9]|3[01])\.' \
   && ! ip -4 addr show docker0 &>/dev/null; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'EOF'
{
  "bip": "10.254.0.1/24",
  "default-address-pools": [{ "base": "10.253.0.0/16", "size": 24 }]
}
EOF
    warn "Сеть хостера в 172.16.0.0/12 — Docker настроен на 10.253.0.0/16, чтобы не было конфликта."
fi

install_docker() {
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh && sh /tmp/get-docker.sh
}
if command -v docker &>/dev/null; then
    success "Docker уже установлен: $(docker --version)"
else
    run_logged "Установка Docker" \
        "Проверь доступ к download.docker.com: curl -I https://download.docker.com" install_docker
    success "Docker установлен: $(docker --version)"
fi
systemctl enable --now docker >/dev/null 2>&1 || true
if ! wait_until 30 docker info; then
    systemctl restart docker || true
    wait_until 30 docker info || die "Docker не запускается." \
        "Посмотри причину: journalctl -u docker --no-pager | tail -30"
fi
if ! docker compose version &>/dev/null; then
    run_logged "Установка docker compose" "$APT_FIX" apt-get install "${APT_OPTS[@]}" docker-compose-plugin
fi
success "$(docker compose version)"

# ============================================================
#  4. ПОЛЬЗОВАТЕЛЬ И SSH-КЛЮЧ
# ============================================================
head_ "Пользователь $NEW_USER"

if id "$NEW_USER" &>/dev/null; then
    success "Пользователь уже существует."
else
    useradd -m -s /bin/bash "$NEW_USER" || die "Не удалось создать пользователя $NEW_USER." "Выбери другое имя."
    success "Пользователь создан."
fi
if [[ -n "${USER_PASS:-}" ]]; then
    echo "${NEW_USER}:${USER_PASS}" | chpasswd || die "Не удалось задать пароль." "Пароль может быть слишком простым — придумай другой."
    success "Пароль установлен."
fi
usermod -aG sudo,docker "$NEW_USER"
success "'$NEW_USER' в группах sudo и docker."

USER_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
SSH_DIR="${USER_HOME}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "$SSH_DIR"
touch "$AUTH_KEYS"
if ! grep -qxF "$SSH_PUBKEY" "$AUTH_KEYS"; then echo "$SSH_PUBKEY" >> "$AUTH_KEYS"; fi
chmod 600 "$AUTH_KEYS"; chown "$NEW_USER:$NEW_USER" "$AUTH_KEYS"
success "Ключ добавлен в $AUTH_KEYS"

# ============================================================
#  5. СЕТЕВОЙ ТЮНИНГ (BBR + буферы для QUIC/Hysteria2)
# ============================================================
head_ "Сетевой тюнинг"
modprobe tcp_bbr 2>/dev/null || true
cat > /etc/sysctl.d/99-remnanode.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
sysctl --system >/dev/null 2>&1 || true
success "Congestion control: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"

# ============================================================
#  6. UFW
# ============================================================
head_ "Firewall (UFW)"

# Сначала разрешаем SSH (текущий и новый порт), потом включаем — чтобы не отрезать себя
for p in $CURRENT_SSH_PORTS; do ufw allow "${p}/tcp" comment 'SSH (current)' >/dev/null; done
ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null

if [[ -n "${PANEL_IP:-}" ]]; then
    ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'Remnawave panel' >/dev/null
else
    ufw allow "${NODE_PORT}/tcp" comment 'Remnawave node API' >/dev/null
fi
if [[ $USE_TCP   == y ]]; then ufw allow "${TCP_PORT}/tcp"   comment 'VLESS TCP'   >/dev/null; fi
if [[ $USE_XHTTP == y ]]; then ufw allow "${XHTTP_PORT}/tcp" comment 'VLESS XHTTP' >/dev/null; fi
if [[ $USE_GRPC  == y ]]; then ufw allow "${GRPC_PORT}/tcp"  comment 'VLESS gRPC'  >/dev/null; fi
if [[ $USE_HY2   == y ]]; then ufw allow "${HY2_PORT}/udp"   comment 'Hysteria2'   >/dev/null; fi
if [[ $NEED_80   == y ]]; then ufw allow 80/tcp comment 'ACME' >/dev/null; fi

# ICMP → DROP (как в server_setup.sh)
BEFORE_RULES="/etc/ufw/before.rules"
if [[ ! -f "${BEFORE_RULES}.orig" ]]; then cp "$BEFORE_RULES" "${BEFORE_RULES}.orig"; fi
for t in time-exceeded parameter-problem echo-request; do
    sed -i "s/-A ufw-before-input -p icmp --icmp-type $t -j ACCEPT/-A ufw-before-input -p icmp --icmp-type $t -j DROP/" "$BEFORE_RULES"
done
for t in destination-unreachable time-exceeded parameter-problem echo-request; do
    sed -i "s/-A ufw-before-forward -p icmp --icmp-type $t -j ACCEPT/-A ufw-before-forward -p icmp --icmp-type $t -j DROP/" "$BEFORE_RULES"
done
if ! grep -q "source-quench" "$BEFORE_RULES"; then
    sed -i '/-A ufw-before-input -p icmp --icmp-type echo-request -j DROP/a -A ufw-before-input -p icmp --icmp-type source-quench -j DROP' "$BEFORE_RULES"
fi

UFW_OK=y
if ufw --force enable >>"$INSTALL_LOG" 2>&1 && ufw reload >>"$INSTALL_LOG" 2>&1; then
    success "UFW включён."
else
    UFW_OK=n
    cp "${BEFORE_RULES}.orig" "$BEFORE_RULES" || true
    ufw --force disable >/dev/null 2>&1 || true
    warn "UFW не смог включиться (ядро VPS без нужных модулей) — firewall оставлен выключенным, установка продолжается."
fi

# ============================================================
#  7. HYSTERIA2: СЕРТИФИКАТ + АВТОПРОДЛЕНИЕ
# ============================================================
if [[ $USE_HY2 == y ]]; then
    head_ "Hysteria2: сертификат для $HY2_DOMAIN"

    mkdir -p "$CERTBOT_DIR/certs" "$CERTBOT_DIR/var-lib-letsencrypt"
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
        run_logged "Загрузка certbot" "Проверь доступ к Docker Hub: docker pull certbot/certbot" \
            docker pull -q certbot/certbot

        # certbot --standalone нужен свободный порт 80 — временно останавливаем контейнеры
        RUNNING_CONTAINERS="$(docker ps -q)"
        restore_containers() {
            if [[ -n "${RUNNING_CONTAINERS:-}" ]]; then docker start $RUNNING_CONTAINERS >/dev/null 2>&1 || true; fi
        }
        if [[ -n "$RUNNING_CONTAINERS" ]]; then
            info "Временно останавливаю контейнеры (освобождаю порт 80)..."
            docker stop $RUNNING_CONTAINERS >/dev/null
            trap restore_containers EXIT
        fi
        check_port_free tcp 80 "certbot"

        CERTBOT_EMAIL_ARGS=(--register-unsafely-without-email)
        if [[ -n "$CERT_EMAIL" ]]; then CERTBOT_EMAIL_ARGS=(--email "$CERT_EMAIL"); fi

        info "Запрашиваю сертификат у Let's Encrypt..."
        CERTBOT_RC=0
        CERTBOT_OUT="$(mktemp)"
        docker run --rm \
            -v "$CERTBOT_DIR/certs:/etc/letsencrypt" \
            -v "$CERTBOT_DIR/var-lib-letsencrypt:/var/lib/letsencrypt" \
            --network host \
            certbot/certbot certonly --standalone \
            --non-interactive --agree-tos "${CERTBOT_EMAIL_ARGS[@]}" \
            -d "$HY2_DOMAIN" >"$CERTBOT_OUT" 2>&1 || CERTBOT_RC=$?
        cat "$CERTBOT_OUT" >> "$INSTALL_LOG"

        restore_containers; trap - EXIT
        if [[ $CERTBOT_RC -ne 0 || ! -f "$CERT_FILE" ]]; then
            show_output "$CERTBOT_OUT" 12
            die "Let's Encrypt не выдал сертификат для $HY2_DOMAIN." \
                "1) A-запись $HY2_DOMAIN должна указывать на ${SERVER_IP:-IP сервера} (без прокси Cloudflare). 2) Порт 80 должен быть открыт у хостера. 3) Если в ответе «too many certificates» — лимит Let's Encrypt, подожди 1 час."
        fi
        success "Сертификат выпущен: $CERTBOT_DIR/certs/live/$HY2_DOMAIN/"
    fi

    # Скрипт продления: certbot --standalone нужен порт 80, поэтому на время
    # останавливаем Caddy (Selfsteal); ноду перезапускаем, только если сертификат обновился.
    cat > "$CERTBOT_DIR/renew.sh" <<EOF
#!/usr/bin/env bash
# Автопродление сертификата Hysteria2 (cron: 28-е число каждого месяца)
CERTBOT_DIR="$CERTBOT_DIR"; CADDY_DIR="$CADDY_DIR"; NODE_DIR="$NODE_DIR"; DOMAIN="$HY2_DOMAIN"
EOF
    cat >> "$CERTBOT_DIR/renew.sh" <<'EOF'
echo "===== $(date '+%F %T') renew ====="
CERT="$CERTBOT_DIR/certs/live/$DOMAIN/fullchain.pem"
before=$(readlink -f "$CERT" 2>/dev/null)
[ -f "$CADDY_DIR/docker-compose.yml" ] && docker compose -f "$CADDY_DIR/docker-compose.yml" stop
cd "$CERTBOT_DIR" && docker compose run --rm certbot renew
rc=$?
[ -f "$CADDY_DIR/docker-compose.yml" ] && docker compose -f "$CADDY_DIR/docker-compose.yml" start
after=$(readlink -f "$CERT" 2>/dev/null)
if [ "$before" != "$after" ]; then
    echo "Сертификат обновлён — перезапускаю remnanode"
    docker compose -f "$NODE_DIR/docker-compose.yml" restart remnanode
fi
exit $rc
EOF
    chmod +x "$CERTBOT_DIR/renew.sh"

    CRON_LINE="0 0 28 * * $CERTBOT_DIR/renew.sh >> /var/log/certbot-renew.log 2>&1"
    { crontab -l 2>/dev/null | grep -vF "certbot renew" | grep -vF "$CERTBOT_DIR/renew.sh" || true; echo "$CRON_LINE"; } | crontab -
    crontab -l 2>/dev/null | grep -qF "$CERTBOT_DIR/renew.sh" \
        || die "Не удалось добавить задание в cron." "Добавь вручную: (crontab -l; echo '$CRON_LINE') | crontab -"
    success "Cron: продление 28-го числа каждого месяца ($CERTBOT_DIR/renew.sh)"
fi

# ============================================================
#  8. НОДА REMNAWAVE — docker-compose.yml заполняется автоматически
# ============================================================
head_ "Remnanode"

mkdir -p "$NODE_DIR"
if [[ -s "$NODE_DIR/docker-compose.yml" ]]; then
    cp "$NODE_DIR/docker-compose.yml" "$NODE_DIR/docker-compose.yml.bak.$(date +%s)"
fi

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
docker compose -f "$NODE_DIR/docker-compose.yml" config -q >>"$INSTALL_LOG" 2>&1 \
    || die "docker-compose.yml ноды получился некорректным." "Пришли вывод: docker compose -f $NODE_DIR/docker-compose.yml config"
success "Создан $NODE_DIR/docker-compose.yml"

run_logged "Загрузка образа remnawave/node" "Проверь доступ к Docker Hub: docker pull remnawave/node:latest" \
    docker compose -f "$NODE_DIR/docker-compose.yml" pull -q
run_logged "Запуск remnanode" "Смотри: docker compose -f $NODE_DIR/docker-compose.yml logs" \
    docker compose -f "$NODE_DIR/docker-compose.yml" up -d --force-recreate

node_ready() {
    [[ "$(docker inspect -f '{{.State.Running}} {{.State.Restarting}}' remnanode 2>/dev/null)" == "true false" ]] \
        && ss -Hltn "( sport = :$NODE_PORT )" | grep -q .
}
info "Жду, пока нода поднимет порт $NODE_PORT (до 60 с)..."
if wait_until 60 node_ready; then
    success "remnanode работает и слушает порт $NODE_PORT."
else
    echo "------ логи remnanode ------"; docker logs --tail 20 remnanode 2>&1 || true; echo "----------------------------"
    die "remnanode не запустился." \
        "Чаще всего — неверный SECRET_KEY: в панели Nodes → Management → Copy docker-compose.yml, скопируй SECRET_KEY заново и запусти скрипт ещё раз."
fi

# ============================================================
#  9. SELFSTEAL — Caddy с сайтом-заглушкой (без ручных шагов)
# ============================================================

caddy_cert_ready() {
    compgen -G "$CADDY_DIR/data/caddy/certificates/*/$SELFSTEAL_DOMAIN/$SELFSTEAL_DOMAIN.crt" >/dev/null
}
caddy_https_ok() {
    [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        --resolve "$SELFSTEAL_DOMAIN:$SELFSTEAL_PORT:127.0.0.1" "https://$SELFSTEAL_DOMAIN:$SELFSTEAL_PORT/")" == 200 ]]
}

if [[ $SELFSTEAL == y ]]; then
    head_ "Selfsteal: $SELFSTEAL_DOMAIN → 127.0.0.1:$SELFSTEAL_PORT"

    # Чужая установка в /opt/caddy (например, selfsteal.sh от DigneZzZ) — останавливаем и сохраняем
    if [[ -f "$CADDY_DIR/docker-compose.yml" && ! -f "$CADDY_DIR/.node_setup" ]]; then
        warn "В $CADDY_DIR найдена другая установка Caddy — останавливаю и переношу в ${CADDY_DIR}.bak"
        docker compose -f "$CADDY_DIR/docker-compose.yml" down >/dev/null 2>&1 || true
        rm -rf "${CADDY_DIR}.bak"; mv "$CADDY_DIR" "${CADDY_DIR}.bak"
    fi
    mkdir -p "$CADDY_DIR/html" "$CADDY_DIR/data" "$CADDY_DIR/config"
    touch "$CADDY_DIR/.node_setup"

    # Caddyfile: сайт слушает только 127.0.0.1:${SELFSTEAL_PORT} (туда ходит Reality),
    # порт 80 — наружу, для выпуска сертификата и редиректа.
    # E-mail — только внутри issuer acme (рядом с ним Caddy не допускает «tls <email>»).
    CADDY_ACME_EMAIL=""
    if [[ -n "$CERT_EMAIL" ]]; then CADDY_ACME_EMAIL=$'\t\t\temail '"$CERT_EMAIL"$'\n'; fi
    cat > "$CADDY_DIR/Caddyfile" <<EOF
{
	https_port ${SELFSTEAL_PORT}
	default_bind 127.0.0.1
	auto_https disable_redirects
	servers {
		protocols h1 h2
	}
}

http://${SELFSTEAL_DOMAIN} {
	bind 0.0.0.0
	redir https://${SELFSTEAL_DOMAIN}{uri} permanent
}

https://${SELFSTEAL_DOMAIN} {
	tls {
		issuer acme {
${CADDY_ACME_EMAIL}			disable_tlsalpn_challenge
		}
	}
	root * /var/www/html
	try_files {path} /index.html
	file_server
}

:${SELFSTEAL_PORT} {
	tls internal
	respond 204
}

:80 {
	bind 0.0.0.0
	respond 204
}
EOF

    # Сайт-заглушка (уникальное название и цвет для каждой установки)
    if [[ ! -f "$CADDY_DIR/html/index.html" ]]; then
        BRANDS=("Northwind Labs" "Lumora Studio" "Brightpath Cloud" "Vectorly" "Cloudnest" "Harborline Systems" "Quantix Data" "Stellar Forge" "Bluepeak Digital" "Mosaic Works")
        BRAND="${BRANDS[RANDOM % ${#BRANDS[@]}]}"
        HUE=$((RANDOM % 360))
        YEAR="$(date +%Y)"
        cat > "$CADDY_DIR/html/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${BRAND} — Cloud infrastructure for growing teams</title>
<meta name="description" content="${BRAND} builds reliable cloud infrastructure, storage and analytics for modern businesses.">
<style>
  :root { --accent: hsl(${HUE} 65% 45%); --bg: #f7f8fa; --text: #1d2330; --muted: #5b6475; }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: var(--bg); color: var(--text); line-height: 1.6; }
  header { display: flex; justify-content: space-between; align-items: center; padding: 20px 6vw; background: #fff; border-bottom: 1px solid #e6e8ee; }
  .logo { font-weight: 700; font-size: 20px; color: var(--accent); }
  nav a { margin-left: 24px; color: var(--muted); text-decoration: none; font-size: 15px; }
  .hero { padding: 96px 6vw 72px; max-width: 900px; }
  .hero h1 { font-size: clamp(32px, 5vw, 52px); line-height: 1.15; margin-bottom: 20px; }
  .hero p { font-size: 19px; color: var(--muted); margin-bottom: 32px; }
  .btn { display: inline-block; background: var(--accent); color: #fff; padding: 14px 28px; border-radius: 8px; text-decoration: none; font-weight: 600; }
  .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 24px; padding: 0 6vw 96px; }
  .card { background: #fff; border: 1px solid #e6e8ee; border-radius: 12px; padding: 28px; }
  .card h3 { margin-bottom: 8px; }
  .card p { color: var(--muted); font-size: 15px; }
  footer { padding: 32px 6vw; color: var(--muted); font-size: 14px; border-top: 1px solid #e6e8ee; background: #fff; }
</style>
</head>
<body>
<header>
  <div class="logo">${BRAND}</div>
  <nav><a href="#">Products</a><a href="#">Pricing</a><a href="#">Docs</a><a href="#">Contact</a></nav>
</header>
<section class="hero">
  <h1>Cloud infrastructure that grows with your team</h1>
  <p>Compute, storage and analytics in one place. Deploy in minutes, scale without limits, and pay only for what you use.</p>
  <a class="btn" href="#">Start free trial</a>
</section>
<section class="grid">
  <div class="card"><h3>Fast deployment</h3><p>Launch production-ready environments in under five minutes with our guided setup.</p></div>
  <div class="card"><h3>Secure by default</h3><p>Encryption at rest and in transit, role-based access and audit logs out of the box.</p></div>
  <div class="card"><h3>24/7 support</h3><p>Our engineers are available around the clock to help your team succeed.</p></div>
</section>
<footer>&copy; ${YEAR} ${BRAND}. All rights reserved.</footer>
</body>
</html>
EOF
    fi

    cat > "$CADDY_DIR/docker-compose.yml" <<'YAML'
services:
  caddy:
    image: caddy:2
    container_name: selfsteal-caddy
    network_mode: host
    restart: always
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./html:/var/www/html:ro
      - ./data:/data
      - ./config:/config
YAML

    run_logged "Загрузка образа Caddy" "Проверь доступ к Docker Hub: docker pull caddy:2" \
        docker compose -f "$CADDY_DIR/docker-compose.yml" pull -q
    CADDY_OUT="$(mktemp)"
    if ! docker run --rm -v "$CADDY_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2 \
            caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >"$CADDY_OUT" 2>&1; then
        cat "$CADDY_OUT" >> "$INSTALL_LOG"
        show_output "$CADDY_OUT" 10
        die "Caddyfile не прошёл проверку." "Пришли вывод выше — это ошибка скрипта."
    fi
    cat "$CADDY_OUT" >> "$INSTALL_LOG"; rm -f "$CADDY_OUT"
    run_logged "Запуск Caddy" "Смотри: docker logs selfsteal-caddy" \
        docker compose -f "$CADDY_DIR/docker-compose.yml" up -d --force-recreate

    info "Жду сертификат Let's Encrypt для $SELFSTEAL_DOMAIN (до 3 минут)..."
    if wait_until 180 caddy_cert_ready && wait_until 30 caddy_https_ok; then

        success "Selfsteal работает: https://$SELFSTEAL_DOMAIN (внутри: 127.0.0.1:$SELFSTEAL_PORT)"
    else
        echo "------ логи Caddy ------"; docker logs --tail 15 selfsteal-caddy 2>&1 || true; echo "------------------------"
        warn "Сертификат для $SELFSTEAL_DOMAIN пока не получен. Caddy продолжит пытаться сам."
        warn "Проверь: A-запись $SELFSTEAL_DOMAIN → ${SERVER_IP:-IP сервера}, порт 80 открыт у хостера."
    fi
fi

# ============================================================
#  10. CONFIG PROFILE ДЛЯ ПАНЕЛИ
# ============================================================
head_ "Config Profile для панели"

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
if [[ $USE_REALITY == y ]]; then
    # Ключи Reality генерируем один раз и сохраняем — при повторном запуске профиль не меняется
    KEYS_FILE="$NODE_DIR/.reality_keys"
    if [[ -f "$KEYS_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$KEYS_FILE"
    else
        KEY_TMP="$(mktemp)"
        openssl genpkey -algorithm X25519 -out "$KEY_TMP" 2>/dev/null
        REALITY_PRIVATE="$(openssl pkey -in "$KEY_TMP" -outform DER | tail -c 32 | b64url)"
        REALITY_PUBLIC="$(openssl pkey -in "$KEY_TMP" -pubout -outform DER | tail -c 32 | b64url)"
        rm -f "$KEY_TMP"
        SHORT_ID="$(openssl rand -hex 8)"
        XHTTP_PATH="/$(openssl rand -hex 6)"
        GRPC_SERVICE="$(openssl rand -hex 6)"
        printf 'REALITY_PRIVATE=%q\nREALITY_PUBLIC=%q\nSHORT_ID=%q\nXHTTP_PATH=%q\nGRPC_SERVICE=%q\n' \
            "$REALITY_PRIVATE" "$REALITY_PUBLIC" "$SHORT_ID" "$XHTTP_PATH" "$GRPC_SERVICE" > "$KEYS_FILE"
        chmod 600 "$KEYS_FILE"
    fi
    [[ ${#REALITY_PRIVATE} -eq 43 ]] || die "Не удалось сгенерировать ключи Reality." "Проверь: openssl version (нужен 1.1.1+)"
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
if [[ $USE_TCP == y ]]; then
    INBOUNDS+=("$(vless_inbound proxy "$TCP_PORT" "$(reality_stream tcp '')")")
fi
if [[ $USE_XHTTP == y ]]; then
    INBOUNDS+=("$(vless_inbound bg "$XHTTP_PORT" \
        "$(reality_stream xhttp "\"xhttpSettings\": { \"path\": \"${XHTTP_PATH}\", \"mode\": \"auto\" },")")")
fi
if [[ $USE_GRPC == y ]]; then
    INBOUNDS+=("$(vless_inbound bg-2 "$GRPC_PORT" \
        "$(reality_stream grpc "\"grpcSettings\": { \"serviceName\": \"${GRPC_SERVICE}\" },")")")
fi
if [[ $USE_HY2 == y ]]; then
    INBOUNDS+=("$(cat <<JSON
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
fi

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
if ! printf '%s\n' "$PROFILE_RAW" | jq . > "$NODE_DIR/profile.json"; then
    printf '%s\n' "$PROFILE_RAW" > "$NODE_DIR/profile.json"
    die "Профиль для панели получился некорректным JSON." "Пришли файл $NODE_DIR/profile.json — это ошибка скрипта."
fi
chmod 600 "$NODE_DIR/profile.json"
success "Профиль сохранён: $NODE_DIR/profile.json (inbound'ов: ${#INBOUNDS[@]})"

# ============================================================
#  11. SSH: НОВЫЙ ПОРТ, ТОЛЬКО КЛЮЧИ
# ============================================================
head_ "SSH"

SSHD_CONFIG="/etc/ssh/sshd_config"
TEMP_OLD="/etc/ssh/sshd_config.d/99-temp-old-port.conf"
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%s)"
mkdir -p /etc/ssh/sshd_config.d

# Порт прописываем прямо в /etc/ssh/sshd_config: "#Port 22" → "Port ${SSH_PORT}".
# Все прочие активные Port (в основном конфиге и drop-in файлах) комментируем.
sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#&/' "$SSHD_CONFIG"
sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#&/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
if grep -qE '^#[[:space:]]*Port[[:space:]]+' "$SSHD_CONFIG"; then
    sed -i -E "0,/^#[[:space:]]*Port[[:space:]]+.*/s//Port ${SSH_PORT}/" "$SSHD_CONFIG"
else
    echo "Port ${SSH_PORT}" >> "$SSHD_CONFIG"
fi
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "$SSHD_CONFIG"; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$SSHD_CONFIG"
fi
# Остальные параметры — в 00- (грузится первым и имеет приоритет над 50-cloud-init.conf)
cat > /etc/ssh/sshd_config.d/00-node-setup.conf <<EOF
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

# Страховка: пока ты не подтвердил вход по новому порту, sshd слушает и старый.
OLD_PORTS=""
for p in $CURRENT_SSH_PORTS; do
    if [[ "$p" != "$SSH_PORT" ]]; then OLD_PORTS+="$p "; fi
done
if [[ -n "$OLD_PORTS" ]]; then
    : > "$TEMP_OLD"
    for p in $OLD_PORTS; do echo "Port $p" >> "$TEMP_OLD"; done
fi

if ! sshd -t 2>>"$INSTALL_LOG"; then
    rm -f "$TEMP_OLD" /etc/ssh/sshd_config.d/00-node-setup.conf
    cp "$(ls -t "${SSHD_CONFIG}".bak.* | head -n1)" "$SSHD_CONFIG"
    die "Новый конфиг sshd не прошёл проверку — откатил изменения, SSH работает как раньше." \
        "Пришли вывод: sshd -t"
fi

# Сервис в Ubuntu/Debian называется ssh, в RHEL-подобных — sshd
if systemctl list-unit-files ssh.service 2>/dev/null | grep -q '^ssh\.service'; then SSH_UNIT=ssh; else SSH_UNIT=sshd; fi

# Перезапуск sshd НЕ рвёт открытые сессии (KillMode=process) — меняется только приём новых подключений.
restart_sshd() {
    systemctl daemon-reload
    # Ubuntu 22.10+: socket activation — порты берутся из ssh.socket (генерируется из sshd_config)
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then systemctl restart ssh.socket; fi
    systemctl restart "$SSH_UNIT"
    sleep 2
}
restart_sshd

SSH_CLOSED_OLD=n
if ! wait_until 15 bash -c "ss -Hltn '( sport = :${SSH_PORT} )' | grep -q ."; then
    warn "SSH НЕ слушает порт $SSH_PORT! Старый порт (${OLD_PORTS:-22}) оставлен — доступ не потерян."
    warn "Проверь: ss -tlnp | grep ssh ; journalctl -u $SSH_UNIT --no-pager | tail -20"
elif [[ -z "$OLD_PORTS" ]]; then
    SSH_CLOSED_OLD=y
    success "SSH слушает порт $SSH_PORT."
else
    success "SSH слушает порты: $SSH_PORT (новый) и ${OLD_PORTS% } (временно, для страховки)."
    ANS=""
    if { : </dev/tty; } 2>/dev/null; then
        echo
        echo -e "${BOLD}${YELLOW}Последний шаг. Открой НОВОЕ окно терминала (это не закрывай!) и проверь вход:${RESET}"
        echo -e "    ${BOLD}ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP:-<IP>}${RESET}"
        echo -e "Если не ответить за 10 минут — старый порт останется открытым (безопасный вариант)."
        read -r -t 600 -p "Вход по порту ${SSH_PORT} работает? Закрыть старый порт ${OLD_PORTS% }? [y/N]: " ANS </dev/tty || true
        echo
    fi
    if [[ "${ANS,,}" =~ ^(y|yes|д|да)$ ]]; then
        rm -f "$TEMP_OLD"
        restart_sshd
        for p in $OLD_PORTS; do ufw delete allow "${p}/tcp" >/dev/null 2>&1 || true; done
        ufw delete allow OpenSSH >/dev/null 2>&1 || true
        SSH_CLOSED_OLD=y
        success "Старый порт закрыт. SSH только на ${SSH_PORT}."
    else
        warn "Старый порт ${OLD_PORTS% } оставлен открытым. Когда проверишь вход по ${SSH_PORT}, закрой его:"
        echo "    sudo rm -f $TEMP_OLD && sudo systemctl daemon-reload && sudo systemctl restart ssh.socket $SSH_UNIT"
        for p in $OLD_PORTS; do echo "    sudo ufw delete allow ${p}/tcp"; done
    fi
fi

# ============================================================
#  12. ИТОГОВАЯ ПРОВЕРКА
# ============================================================
head_ "Итоговая проверка"

CHECK_FAILS=0
check() { # check <что проверяем> <как исправить> <команда...>
    local name=$1 fix=$2; shift 2
    if "$@" >/dev/null 2>&1; then
        echo -e "  ${GREEN}✔${RESET} $name"
    else
        echo -e "  ${RED}✘${RESET} $name"
        echo -e "      ${YELLOW}→${RESET} $fix"
        CHECK_FAILS=$((CHECK_FAILS + 1))
    fi
}
tcp_listen() { ss -Hltn "( sport = :$1 )" | grep -q .; }

check "Docker работает" "systemctl restart docker" docker info
check "remnanode запущен" "docker compose -f $NODE_DIR/docker-compose.yml logs --tail 30" node_ready
check "Нода слушает Node Port $NODE_PORT" "docker logs --tail 30 remnanode (часто — неверный SECRET_KEY)" tcp_listen "$NODE_PORT"
if [[ $USE_HY2 == y ]]; then
    check "Сертификат Hysteria2 есть" "запусти скрипт ещё раз" test -f "$CERTBOT_DIR/certs/live/$HY2_DOMAIN/fullchain.pem"
    check "Сертификат виден внутри ноды" "docker compose -f $NODE_DIR/docker-compose.yml up -d --force-recreate" \
        docker exec remnanode test -f "/etc/letsencrypt/live/$HY2_DOMAIN/fullchain.pem"
    check "Cron автопродления установлен" "запусти скрипт ещё раз" bash -c "crontab -l | grep -qF '$CERTBOT_DIR/renew.sh'"
fi
if [[ $SELFSTEAL == y ]]; then
    check "Caddy (Selfsteal) запущен" "docker logs --tail 30 selfsteal-caddy" \
        bash -c "[[ \$(docker inspect -f '{{.State.Running}}' selfsteal-caddy) == true ]]"
    check "Сертификат Selfsteal получен" "A-запись $SELFSTEAL_DOMAIN → ${SERVER_IP:-IP}; через пару минут: docker logs selfsteal-caddy" caddy_cert_ready
    check "Сайт отвечает на 127.0.0.1:$SELFSTEAL_PORT" "docker logs --tail 30 selfsteal-caddy" caddy_https_ok
fi
check "Профиль для панели создан" "запусти скрипт ещё раз" jq -e '.inbounds | length > 0' "$NODE_DIR/profile.json"
if [[ $UFW_OK == y ]]; then
    check "UFW включён" "ufw --force enable" bash -c "ufw status | grep -q 'Status: active'"
fi
check "SSH слушает порт $SSH_PORT" "ss -tlnp | grep ssh ; journalctl -u $SSH_UNIT | tail" tcp_listen "$SSH_PORT"

# ============================================================
#  13. ИТОГ
# ============================================================
{
echo "===== Remnawave node setup — $(date '+%F %T') ====="
echo "IP сервера      : ${SERVER_IP:-?}"
echo "SSH             : ssh -p ${SSH_PORT} ${NEW_USER}@${SERVER_IP:-<IP>}"
if [[ $SSH_CLOSED_OLD == n && -n "$OLD_PORTS" ]]; then echo "                  (старый порт ${OLD_PORTS% } пока тоже открыт)"; fi
echo "Node Port       : ${NODE_PORT}"
if [[ $USE_TCP   == y ]]; then echo "proxy (TCP)     : ${TCP_PORT}/tcp"; fi
if [[ $USE_XHTTP == y ]]; then echo "bg (XHTTP)      : ${XHTTP_PORT}/tcp, path ${XHTTP_PATH}"; fi
if [[ $USE_GRPC  == y ]]; then echo "bg-2 (gRPC)     : ${GRPC_PORT}/tcp, serviceName ${GRPC_SERVICE}"; fi
if [[ $USE_HY2   == y ]]; then echo "Hysteria2       : ${HY2_PORT}/udp, домен ${HY2_DOMAIN}"; fi
if [[ $USE_REALITY == y ]]; then
    echo "Reality SNI     : ${REALITY_SNI}"
    echo "Reality target  : ${REALITY_TARGET}"
    echo "Reality private : ${REALITY_PRIVATE}"
    echo "Reality public  : ${REALITY_PUBLIC}"
    echo "Reality shortId : ${SHORT_ID}"
fi
if [[ $SELFSTEAL == y ]]; then echo "Selfsteal       : ${SELFSTEAL_DOMAIN} → 127.0.0.1:${SELFSTEAL_PORT} (${CADDY_DIR})"; fi
echo "Нода            : ${NODE_DIR}/docker-compose.yml"
echo "Профиль панели  : ${NODE_DIR}/profile.json"
} > "$SUMMARY_FILE"
chmod 600 "$SUMMARY_FILE"

head_ "ГОТОВО"
cat "$SUMMARY_FILE"
echo
echo -e "${BOLD}Config Profile — скопируй целиком в панель (Config Profiles → +):${RESET}"
echo "────────────────────────────────────────────────────────────"
cat "$NODE_DIR/profile.json"
echo "────────────────────────────────────────────────────────────"
echo
echo -e "${BOLD}В панели осталось:${RESET}"
echo "  1. Config Profiles → создать профиль и вставить JSON выше (или: cat ${NODE_DIR}/profile.json)."
echo "  2. Nodes → у этой ноды выбрать профиль и отметить inbound'ы."
echo "  3. Hosts → создать хост для каждого inbound'а."
echo
if (( CHECK_FAILS > 0 )); then
    warn "Проверок не пройдено: $CHECK_FAILS — исправь по подсказкам «→» выше и запусти скрипт ещё раз."
else
    success "Все проверки пройдены."
fi
echo "Итог сохранён в ${SUMMARY_FILE}, полный лог: ${INSTALL_LOG}"
sleep 1
