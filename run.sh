#!/bin/bash
set -e

cd "$(cd "$(dirname "$0")" && pwd)" || exit

# ── Colors ──────────────────────────────────────────
if [ -t 1 ]; then
    GREEN='\033[1;32m'; RED='\033[1;31m'; YELLOW='\033[1;33m'
    BLUE='\033[1;94m'; CYAN='\033[1;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# ── Defaults ────────────────────────────────────────
DEF_OLLAMA_HOST="ollama:11434"
DEF_MODEL="qwen3.6:35b-a3b-q8_0"
DEF_WEBUI_PORT="3000"
DEF_TZ="Europe/Moscow"

# ── Save env values before local vars shadow them ──
_ENV_OLLAMA_HOST="${OLLAMA_HOST:-}"
_ENV_TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
_ENV_WEBUI_PASSWORD="${WEBUI_PASSWORD:-}"
_ENV_WEBUI_PORT="${WEBUI_PORT:-}"
_ENV_CALDAV_PORT="${CALDAV_PORT:-}"
_ENV_MODEL="${DEFAULT_MODEL:-}"
_ENV_TZ="${TZ:-}"
_ENV_TELEGRAM_ALLOWED_USERS="${TELEGRAM_ALLOWED_USERS:-}"

# ── CLI args (defaults = empty = "not set") ──
OLLAMA_HOST=""
TELEGRAM_BOT_TOKEN=""
WEBUI_PASSWORD=""
WEBUI_PORT=""
CALDAV_PORT=""
MODEL=""
TZ=""
TELEGRAM_ALLOWED_USERS=""
NON_INTERACTIVE=false
RECONFIGURE=false
APPROVE_CODE=""

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -o, --ollama-host HOST     Ollama server address (host:port)
  -t, --telegram-token TOKEN Telegram bot token
  -w, --webui-password PASS  Web UI password
  -p, --webui-port PORT      Web UI port (default: $DEF_WEBUI_PORT)
  -c, --caldav-port PORT     CalDAV port (empty = internal only)
  -m, --model NAME           Ollama model name
  -z, --tz TIMEZONE          Timezone (default: $DEF_TZ)
  -n, --non-interactive      Non-interactive mode
  -r, --reconfigure          Re-run interactive configuration
  -a, --approve CODE         Approve Telegram pairing code in running container
  -h, --help                 Show this help
EOF
    exit 0
}

PARSED=$(getopt -o "o:t:w:p:c:m:z:nra:h" \
    --long "ollama-host:,telegram-token:,webui-password:,webui-port:,caldav-port:,model:,tz:,non-interactive,reconfigure,approve:,help" \
    -n "$0" -- "$@") || exit 1
eval set -- "$PARSED"

while true; do
    case "$1" in
        -o|--ollama-host) OLLAMA_HOST="$2"; shift 2 ;;
        -t|--telegram-token) TELEGRAM_BOT_TOKEN="$2"; shift 2 ;;
        -w|--webui-password) WEBUI_PASSWORD="$2"; shift 2 ;;
        -p|--webui-port) WEBUI_PORT="$2"; shift 2 ;;
        -c|--caldav-port) CALDAV_PORT="$2"; shift 2 ;;
        -m|--model) MODEL="$2"; shift 2 ;;
        -z|--tz) TZ="$2"; shift 2 ;;
        -n|--non-interactive) NON_INTERACTIVE=true; shift ;;
        -r|--reconfigure) RECONFIGURE=true; shift ;;
        -a|--approve) APPROVE_CODE="$2"; shift 2 ;;
        -h|--help) usage ;;
        --) shift; break ;;
        *) echo "Internal error!"; exit 1 ;;
    esac
done

# ── Approve mode (early exit) ─────────────────────
if [ -n "$APPROVE_CODE" ]; then
    echo -e "${DIM}Одобряю код Telegram: ${APPROVE_CODE}...${NC}"
    if docker exec delovodai openclaw pairing approve telegram "$APPROVE_CODE"; then
        echo -e "${GREEN}✓${NC} Пользователь одобрен"
    else
        echo -e "${YELLOW}⚠${NC} Ошибка: контейнер запущен? код верен?"
    fi
    exit $?
fi

# ── Helpers ─────────────────────────────────────────

# resolve_val <saved_env_value> <cli_value> <default>
resolve_val() {
    local saved_val="$1" cli_val="$2" default="$3"
    if [ -n "$cli_val" ]; then
        echo "$cli_val"
    elif [ -n "$saved_val" ]; then
        echo "$saved_val"
    else
        echo "$default"
    fi
}

prompt() {
    local msg="$1" default="$2"
    local input
    read -p "$(echo -e "${BOLD}${msg}${NC} ${DIM}[${default}]: ${NC}")" input
    input="${input:-$default}"
    echo "$input"
}

prompt_optional() {
    local msg="$1" default="$2"
    local input
    read -p "$(echo -e "${DIM}${msg} [${default}]: ${NC}")" input
    input="${input:-$default}"
    echo "$input"
}

interactive_select() {
    local items=("$@")
    local n=${#items[@]}
    [ "$n" -eq 0 ] && return 1

    if [ ! -t 0 ]; then
        select sel in "${items[@]}"; do
            [ -n "$sel" ] && echo "$sel" && return 0
        done
        return 1
    fi

    local selected=0
    local old_settings
    old_settings=$(stty -g 2>/dev/null || true)

    _render() {
        for i in "${!items[@]}"; do
            if [ "$i" -eq "$selected" ]; then
                echo -e "\033[7m > ${items[$i]}\033[0m " >&2
            else
                echo "   ${items[$i]}" >&2
            fi
        done
    }

    stty -icanon -echo 2>/dev/null
    echo -en "\033[?25l" >&2
    _render

    while true; do
        local key
        IFS= read -s -n1 key 2>/dev/null
        if [ "$key" = $'\x1b' ]; then
            local seq
            IFS= read -s -n2 -t 0.1 seq 2>/dev/null || true
            case "$seq" in
                '[A') [ "$selected" -gt 0 ] && ((selected--)) ;;
                '[B') [ "$selected" -lt "$((n - 1))" ] && ((selected++)) ;;
            esac
        elif [ -z "$key" ] || [ "$key" = $'\n' ] || [ "$key" = $'\r' ]; then
            break
        fi
        echo -en "\033[${n}A" >&2
        _render
    done

    echo -en "\033[${n}B\033[?25h" >&2
    stty "$old_settings" 2>/dev/null
    echo "${items[$selected]}"
}

fetch_ollama_models() {
    local host="$1"
    host="${host#http://}"
    host="${host#https://}"
    local resp
    resp=$(curl -s --connect-timeout 5 "http://${host}/api/tags" 2>/dev/null) || return 1
    if command -v jq &>/dev/null; then
        echo "$resp" | jq -r '.models[].name' 2>/dev/null
    else
        echo "$resp" | grep -oP '"name":"[^"]*"' | sed 's/"name":"//;s/"//' 2>/dev/null
    fi
}

resolve_telegram_ids() {
    local token="$1"
    shift
    local raw_ids=("$@")
    local resolved=()

    for raw in "${raw_ids[@]}"; do
        raw="${raw#@}"
        if [[ "$raw" =~ ^[0-9]+$ ]]; then
            resolved+=("$raw")
        else
            echo -ne "  ${DIM}Получаю ID для @${raw}...${NC}" >&2
            local id
            id=$(curl -s --connect-timeout 5 --max-time 10 \
              "https://api.telegram.org/bot${token}/getChat?chat_id=@${raw}" 2>/dev/null | \
              jq -r '.result.id // empty' 2>/dev/null)
            if [ -z "$id" ]; then
                local updates last_id offset deadline
                updates=$(curl -s --connect-timeout 5 --max-time 10 \
                  "https://api.telegram.org/bot${token}/getUpdates" 2>/dev/null)
                id=$(echo "$updates" | jq -r --arg u "$raw" '
                  .result[] | select(.message != null) | .message.from |
                  select(.username == $u) | .id
                ' 2>/dev/null | head -1)
                if [ -z "$id" ]; then
                    last_id=$(echo "$updates" | jq -r '[.result[].update_id] | max // 0' 2>/dev/null)
                    offset=$((last_id + 1))
                    echo -e "\r  ${DIM}Ожидаю сообщение от @${raw} (напишите боту /start)...${NC}" >&2
                    deadline=$(($(date +%s) + 15))
                    while [ "$(date +%s)" -lt "$deadline" ]; do
                        sleep 2
                        updates=$(curl -s --connect-timeout 5 --max-time 8 \
                          "https://api.telegram.org/bot${token}/getUpdates?offset=${offset}&timeout=5" 2>/dev/null)
                        id=$(echo "$updates" | jq -r --arg u "$raw" '
                          .result[] | select(.message != null) | .message.from |
                          select(.username == $u) | .id
                        ' 2>/dev/null | head -1)
                        [ -n "$id" ] && break
                        last_id=$(echo "$updates" | jq -r '[.result[].update_id] | max // 0' 2>/dev/null)
                        offset=$((last_id + 1))
                    done
                fi
            fi
            if [ -n "$id" ]; then
                echo -e "\r  ${GREEN}✓${NC} @${raw} → ID ${id}" >&2
                resolved+=("$id")
            else
                echo -e "\r  ${YELLOW}⚠${NC} Не удалось получить ID для @${raw}" >&2
            fi
        fi
    done

    local json_items=""
    for id in "${resolved[@]}"; do
        [ -n "$json_items" ] && json_items+=", "
        json_items+="$id"
    done
    echo "[${json_items}]"
}

update_caldav_override() {
    local port="$1"
    if [ -n "$port" ]; then
        cat > docker-compose.override.yml << EOF
services:
  radicale:
    ports:
      - "${port}:5232"
EOF
        echo -e "  ${GREEN}CalDAV:${NC} порт ${port} открыт наружу"
    else
        rm -f docker-compose.override.yml
        echo -e "  ${DIM}CalDAV:${NC} только внутри Docker-сети"
    fi
}

save_env() {
    cat > .env << EOF
# DelovodAI — конфигурация окружения
OLLAMA_HOST=${1}
TELEGRAM_BOT_TOKEN=${2}
WEBUI_PASSWORD=${3}
WEBUI_PORT=${4}
CALDAV_PORT=${5}
DEFAULT_MODEL=${6}
TZ=${7}
TELEGRAM_ALLOWED_USERS=${8}
EOF
}

read_env_val() {
    local key="$1"
    grep -oP "^${key}=\K.*" .env 2>/dev/null || true
}

# ════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════

# ── Determine if we should run interactive ─────────
RUN_INTERACTIVE=false
if [ ! -f ".env" ] || [ ! -d "data" ] || [ ! -f "data/config/env" ]; then
    RUN_INTERACTIVE=true
fi
if [ "$RECONFIGURE" = true ]; then
    RUN_INTERACTIVE=true
    if [ -f ".env" ]; then
        _ENV_OLLAMA_HOST=$(read_env_val "OLLAMA_HOST")
        _ENV_TELEGRAM_BOT_TOKEN=$(read_env_val "TELEGRAM_BOT_TOKEN")
        _ENV_WEBUI_PASSWORD=$(read_env_val "WEBUI_PASSWORD")
        _ENV_WEBUI_PORT=$(read_env_val "WEBUI_PORT")
        _ENV_CALDAV_PORT=$(read_env_val "CALDAV_PORT")
        _ENV_MODEL=$(read_env_val "DEFAULT_MODEL")
        _ENV_TZ=$(read_env_val "TZ")
        _ENV_TELEGRAM_ALLOWED_USERS=$(read_env_val "TELEGRAM_ALLOWED_USERS")
    fi
fi

if [ "$RUN_INTERACTIVE" = true ] && [ "$NON_INTERACTIVE" = false ]; then
    echo ""
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Настройка DelovodAI${NC}"
    echo -e "${BLUE}  Заполните параметры или нажмите Enter${NC}"
    echo -e "${BLUE}  для значений по умолчанию${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo ""

    # 1. Ollama host
    OLLAMA_HOST=$(prompt "Адрес Ollama-сервера" "$(resolve_val "$_ENV_OLLAMA_HOST" "$OLLAMA_HOST" "$DEF_OLLAMA_HOST")")

    # 2. Model selection
    echo ""
    echo -e "${DIM}Запрашиваю список доступных моделей...${NC}"
    models=()
    while IFS= read -r line; do
        [ -n "$line" ] && models+=("$line")
    done < <(fetch_ollama_models "$OLLAMA_HOST" 2>/dev/null || true)

    if [ ${#models[@]} -gt 0 ]; then
        echo -e "${GREEN}✓${NC} Найдено ${#models[@]} моделей. Выберите (↑↓, Enter):"
        MODEL=$(interactive_select "${models[@]}")
    else
        echo -e "${YELLOW}⚠${NC} Не удалось получить список моделей с ${OLLAMA_HOST}"
        MODEL=$(prompt "Название модели" "$(resolve_val "$_ENV_MODEL" "$MODEL" "$DEF_MODEL")")
    fi

    # 3. WebUI password
    echo ""
    if [ -n "$_ENV_WEBUI_PASSWORD" ]; then
        echo -e "${DIM}Пароль Web UI задан через переменную окружения.${NC}"
        echo -e "${DIM}Enter = оставить, введите новый = заменить.${NC}"
        read -s -p "$(echo -e "${DIM}Пароль Web UI: ${NC}")" input
        echo
        WEBUI_PASSWORD="${input:-$_ENV_WEBUI_PASSWORD}"
    else
        echo -e "${DIM}Пароль Web UI (Enter = без пароля):${NC}"
        read -s input
        echo
        WEBUI_PASSWORD="${input:-нет}"
        [ "$WEBUI_PASSWORD" = "нет" ] && WEBUI_PASSWORD=""
    fi
    if [ -z "$WEBUI_PASSWORD" ]; then
        echo -e "${YELLOW}⚠  Внимание: Web UI будет без аутентификации!${NC}"
    fi

    # 4. Telegram bot token
    echo ""
    if [ -n "$_ENV_TELEGRAM_BOT_TOKEN" ]; then
        token_preview="${_ENV_TELEGRAM_BOT_TOKEN:0:4}…${_ENV_TELEGRAM_BOT_TOKEN: -4}"
        tg_input=$(prompt_optional "Токен Telegram-бота (Enter = оставить)" "$token_preview")
        [ "$tg_input" = "$token_preview" ] && tg_input=""
        TELEGRAM_BOT_TOKEN="${tg_input:-$_ENV_TELEGRAM_BOT_TOKEN}"
    else
        echo ""
        echo -e "${DIM}  → Напишите @BotFather в Telegram, отправьте /newbot,${NC}"
        echo -e "${DIM}    скопируйте полученный токен (вида 123:abc...def).${NC}"
        echo ""
        TELEGRAM_BOT_TOKEN=$(prompt_optional "Токен Telegram-бота (Enter = пропустить)" "нет")
        [ "$TELEGRAM_BOT_TOKEN" = "нет" ] && TELEGRAM_BOT_TOKEN=""
    fi

    # 5. Telegram allowed users (if token provided)
    TELEGRAM_ALLOWED_USERS="[]"
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        echo ""
        echo -e "${DIM}Введите Telegram username или числовой ID пользователей,${NC}"
        echo -e "${DIM}которым разрешён доступ к боту (через пробел).${NC}"
        echo -e "${DIM}Username будет преобразован в ID автоматически.${NC}"
        echo -e "${DIM}Подсказка: если скрипт не найдёт ID сразу, он будет ждать${NC}"
        echo -e "${DIM}        15 секунд — просто напишите боту /start в этот момент.${NC}"
        echo -e "${DIM}ID также можно узнать у @userinfobot.${NC}"
        echo -e "${DIM}Пример: @user1 123456789 @user2${NC}"
        echo -e "${DIM}Enter = ручное подтверждение через pairing.${NC}"

        default_hint=""
        [ -n "$_ENV_TELEGRAM_ALLOWED_USERS" ] && default_hint=" (текущий: $_ENV_TELEGRAM_ALLOWED_USERS)"
        read -p "$(echo -e "${DIM}Пользователи Telegram${default_hint}: ${NC}")" tg_users_input

        if [ -n "$tg_users_input" ]; then
            IFS=' ' read -ra raw_arr <<< "$tg_users_input"
            TELEGRAM_ALLOWED_USERS=$(resolve_telegram_ids "$TELEGRAM_BOT_TOKEN" "${raw_arr[@]}")
            [ -z "$TELEGRAM_ALLOWED_USERS" ] && TELEGRAM_ALLOWED_USERS="[]"

            if [ "$TELEGRAM_ALLOWED_USERS" = "[]" ]; then
                echo ""
                echo -e "${YELLOW}⚠${NC} Не удалось получить ID через API Telegram (возможна блокировка)."
                echo -e "${DIM}Узнайте ID у @userinfobot (напишите /start).${NC}"
                echo -e "${DIM}Либо напишите боту через искомый аккаунт, запустите скрипт снова.${NC}"
                echo -e "${DIM}Введите числовые ID через пробел, или нажмите Enter для pairing.${NC}"
                read -p "$(echo -e "${DIM}Числовые ID: ${NC}")" manual_ids
                ids_arr=()
                for id in $manual_ids; do
                    [[ "$id" =~ ^[0-9]+$ ]] && ids_arr+=("$id")
                done
                if [ ${#ids_arr[@]} -gt 0 ]; then
                    joined=""
                    for id in "${ids_arr[@]}"; do
                        [ -n "$joined" ] && joined+=", "
                        joined+="$id"
                    done
                    TELEGRAM_ALLOWED_USERS="[${joined}]"
                fi
            fi
        elif [ -n "$_ENV_TELEGRAM_ALLOWED_USERS" ]; then
            TELEGRAM_ALLOWED_USERS="$_ENV_TELEGRAM_ALLOWED_USERS"
        fi
    fi

    # 6. WebUI port
    echo ""
    WEBUI_PORT=$(prompt_optional "Порт Web UI" "$(resolve_val "$_ENV_WEBUI_PORT" "$WEBUI_PORT" "$DEF_WEBUI_PORT")")

    # 7. CalDAV port
    echo ""
    echo -e "${DIM}Укажите порт CalDAV для доступа снаружи.${NC}"
    echo -e "${DIM}Enter = календарь только внутри Docker (безопаснее).${NC}"
    CALDAV_PORT=$(prompt_optional "Порт CalDAV (Enter = внутренний)" "внутренний")
    [ "$CALDAV_PORT" = "внутренний" ] && CALDAV_PORT=""

    # 8. Timezone
    echo ""
    TZ=$(prompt_optional "Часовой пояс" "$(resolve_val "$_ENV_TZ" "$TZ" "$DEF_TZ")")

    save_env "$OLLAMA_HOST" "$TELEGRAM_BOT_TOKEN" "$WEBUI_PASSWORD" \
             "$WEBUI_PORT" "$CALDAV_PORT" "$MODEL" "$TZ" "$TELEGRAM_ALLOWED_USERS"
    rm -f data/config/env 2>/dev/null || true
    echo ""
    echo -e "${GREEN}✓${NC} Конфигурация сохранена в .env"

elif [ "$RUN_INTERACTIVE" = true ] && [ "$NON_INTERACTIVE" = true ]; then
    OLLAMA_HOST=$(resolve_val "$_ENV_OLLAMA_HOST" "$OLLAMA_HOST" "$DEF_OLLAMA_HOST")
    MODEL=$(resolve_val "$_ENV_MODEL" "$MODEL" "$DEF_MODEL")
    WEBUI_PASSWORD=$(resolve_val "$_ENV_WEBUI_PASSWORD" "$WEBUI_PASSWORD" "")
    TELEGRAM_BOT_TOKEN=$(resolve_val "$_ENV_TELEGRAM_BOT_TOKEN" "$TELEGRAM_BOT_TOKEN" "")
    WEBUI_PORT=$(resolve_val "$_ENV_WEBUI_PORT" "$WEBUI_PORT" "$DEF_WEBUI_PORT")
    CALDAV_PORT=$(resolve_val "$_ENV_CALDAV_PORT" "$CALDAV_PORT" "")
    TZ=$(resolve_val "$_ENV_TZ" "$TZ" "$DEF_TZ")
    TELEGRAM_ALLOWED_USERS=$(resolve_val "$_ENV_TELEGRAM_ALLOWED_USERS" "$TELEGRAM_ALLOWED_USERS" "[]")

    save_env "$OLLAMA_HOST" "$TELEGRAM_BOT_TOKEN" "$WEBUI_PASSWORD" \
             "$WEBUI_PORT" "$CALDAV_PORT" "$MODEL" "$TZ" "$TELEGRAM_ALLOWED_USERS"
fi

# ── Sync CalDAV override from .env ──────────────────
if [ -f ".env" ]; then
    cport=$(read_env_val "CALDAV_PORT")
    update_caldav_override "$cport"
fi

# ── Build & start ───────────────────────────────────
echo ""
echo -e "${BOLD}Сборка образов...${NC}"
docker compose build 2>&1 | sed 's/^/   /'

echo -e "${BOLD}Запуск контейнеров...${NC}"
docker compose up -d 2>&1 | sed 's/^/   /'
echo ""

# ── Wait for services ───────────────────────────────
echo -e "${DIM}Ожидание запуска сервисов...${NC}"

WAIT_START=$(date +%s)
TIMEOUT=60

wait_web() {
    local name=$1 url=$2 color=$3
    echo -ne "  ${DIM}${name}...${NC}"
    while true; do
        if timeout 3 curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -q .; then
            echo -e "\r  ${color}✓ ${name}${NC}"
            return 0
        fi
        elapsed=$(( $(date +%s) - WAIT_START ))
        if [ "$elapsed" -ge "$TIMEOUT" ]; then
            echo -e "\r  ${RED}✗ ${name} (таймаут ${TIMEOUT}с)${NC}"
            return 1
        fi
        echo -n "."
        sleep 2
    done
}

# ── Resolve final display values: CLI → .env → saved env → default ──
final_val() {
    local local_var="$1" env_key="$2" saved_env="$3" default="$4"
    if [ -n "$local_var" ]; then echo "$local_var"
    elif [ -n "$(read_env_val "$env_key")" ]; then read_env_val "$env_key"
    elif [ -n "$saved_env" ]; then echo "$saved_env"
    else echo "$default"
    fi
}

FINAL_OLLAMA_HOST=$(final_val "$OLLAMA_HOST" "OLLAMA_HOST" "$_ENV_OLLAMA_HOST" "$DEF_OLLAMA_HOST")
FINAL_MODEL=$(final_val "$MODEL" "DEFAULT_MODEL" "$_ENV_MODEL" "$DEF_MODEL")
FINAL_WEBUI_PORT=$(final_val "$WEBUI_PORT" "WEBUI_PORT" "$_ENV_WEBUI_PORT" "$DEF_WEBUI_PORT")
FINAL_CALDAV_PORT=$(final_val "$CALDAV_PORT" "CALDAV_PORT" "$_ENV_CALDAV_PORT" "")
FINAL_TG_TOKEN=$(final_val "$TELEGRAM_BOT_TOKEN" "TELEGRAM_BOT_TOKEN" "$_ENV_TELEGRAM_BOT_TOKEN" "")

wait_web "DelovodAI" "http://localhost:${FINAL_WEBUI_PORT}" "$CYAN"
if [ -n "$FINAL_CALDAV_PORT" ]; then
    wait_web "Radicale" "http://localhost:${FINAL_CALDAV_PORT}" "$GREEN"
fi

# ── Read gateway token for Web UI (after container start) ──
GW_TOKEN_HINT=""
FINAL_GW_PASSWORD=$(final_val "$WEBUI_PASSWORD" "WEBUI_PASSWORD" "$_ENV_WEBUI_PASSWORD" "")
if [ -z "$FINAL_GW_PASSWORD" ]; then
    GW_TOKEN_HINT=$(grep -oP '^OPENCLAW_GATEWAY_TOKEN=\K.*' data/config/env 2>/dev/null || true)
fi

# ── Summary ─────────────────────────────────────────
echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  DelovodAI запущен${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "  Web UI:    ${CYAN}http://localhost:${FINAL_WEBUI_PORT}${NC}"
if [ -n "$FINAL_GW_PASSWORD" ]; then
    echo -e "  Пароль:    ${GREEN}(задан)${NC}"
elif [ -n "$GW_TOKEN_HINT" ]; then
    echo -e "  Токен:     ${GW_TOKEN_HINT}"
    echo -e "             ${DIM}(введите в Web UI как пароль)${NC}"
else
    echo -e "  ${YELLOW}  ⚠ Пароль Web UI не задан — без него вход невозможен.${NC}"
    echo -e "  ${YELLOW}  Задайте пароль через: ./run.sh -r${NC}"
fi
if [ -n "$FINAL_CALDAV_PORT" ]; then
    echo -e "  CalDAV:    ${GREEN}http://localhost:${FINAL_CALDAV_PORT}${NC}"
else
    echo -e "  CalDAV:    ${YELLOW}только внутри Docker${NC}"
fi
if [ -n "$FINAL_TG_TOKEN" ]; then
    FINAL_TG_USERS=$(read_env_val "TELEGRAM_ALLOWED_USERS")
    if [ -z "$FINAL_TG_USERS" ] || [ "$FINAL_TG_USERS" = "[]" ]; then
        echo -e "  Telegram:  ${GREEN}включён${NC}"
        echo -e "             ${YELLOW}⚠ Пользователи не указаны — нужно подтверждение pairing.${NC}"
        echo -e "             ${DIM}Напишите боту, получите код и выполните: ./run.sh -a <КОД>${NC}"
    else
        echo -e "  Telegram:  ${GREEN}включён (${FINAL_TG_USERS})${NC}"
    fi
else
    echo -e "  Telegram:  ${YELLOW}не настроен (TELEGRAM_BOT_TOKEN)${NC}"
    echo -e "             ${DIM}Задайте через: ./run.sh -r${NC}"
fi
echo -e "  Ollama:    ${CYAN}http://${FINAL_OLLAMA_HOST}${NC}"
echo -e "  Модель:    ${FINAL_MODEL}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""
