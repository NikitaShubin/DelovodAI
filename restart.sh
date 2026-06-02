#!/bin/bash
set -e

cd "$(cd "$(dirname "$0")" && pwd)" || exit

if [ -t 1 ]; then
    GREEN='\033[1;32m'; YELLOW='\033[1;33m'
    BLUE='\033[1;36m'; BOLD='\033[1m'; NC='\033[0m'
else
    GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  Перезапуск DelovodAI${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}⏹  Остановка сервисов...${NC}"
"./stop.sh"
echo ""

echo -e "${GREEN}▶  Запуск сервисов...${NC}"
"./run.sh"
