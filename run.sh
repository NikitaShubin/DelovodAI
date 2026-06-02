#!/bin/bash
set -e

cd "$(cd "$(dirname "$0")" && pwd)" || exit

if [ -t 1 ]; then
    GREEN='\033[1;32m'; RED='\033[1;31m'; YELLOW='\033[1;33m'
    BLUE='\033[1;36m'; CYAN='\033[1;34m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
else
    GREEN=''; RED=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; DIM=''; NC=''
fi

# --- .env ---
if [ ! -f ".env" ]; then
    echo -e "${YELLOW}⚠  Файл .env не найден.${NC}"
    cp .env.example .env
    echo -e "${YELLOW}   Создан из .env.example. Отредактируйте при необходимости:${NC}"
    echo -e "${DIM}   nano .env${NC}"
    echo ""
fi

# --- Docker ---
echo -e "${BOLD}Сборка образов...${NC}"
docker compose build 2>&1 | sed 's/^/   /'

echo -e "${BOLD}Запуск контейнеров...${NC}"
docker compose up -d 2>&1 | sed 's/^/   /'
echo ""

# --- Ожидание ---
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

WEBUI_PORT=$(grep -oP '^WEBUI_PORT=\K.*' .env 2>/dev/null || echo "3000")
CALDAV_PORT=$(grep -oP '^CALDAV_PORT=\K.*' .env 2>/dev/null || echo "5232")

wait_web "DelovodAI" "http://localhost:${WEBUI_PORT}" "$CYAN"
wait_web "Radicale" "http://localhost:${CALDAV_PORT}" "$GREEN"

# --- Итог ---
source /dev/stdin <<EOF
export \$(grep -v '^#' .env 2>/dev/null | xargs)
EOF

echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  DelovodAI запущен${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "  Web UI:    ${CYAN}http://localhost:${WEBUI_PORT}${NC}"
echo -e "  CalDAV:    ${GREEN}http://localhost:${CALDAV_PORT}${NC}"
if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
    echo -e "  Telegram:  ${GREEN}включён${NC}"
else
    echo -e "  Telegram:  ${YELLOW}не настроен (TELEGRAM_BOT_TOKEN)${NC}"
fi
echo -e "  Ollama:    http://${OLLAMA_HOST:-ollama:11434}"
echo -e "  Модель:    ${DEFAULT_MODEL:-gpt-oss:20b}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""
