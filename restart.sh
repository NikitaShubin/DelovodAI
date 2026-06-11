#!/bin/bash
set -e

cd "$(cd "$(dirname "$0")" && pwd)" || exit

if [ -t 1 ]; then
    GREEN='\033[1;32m'; YELLOW='\033[1;33m'
    BLUE='\033[1;94m'; NC='\033[0m'
else
    GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  Перезапуск DelovodAI${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

echo -e "${YELLOW}⏹  Остановка сервисов...${NC}"
"./stop.sh"
echo ""

RECONFIGURE=""
for arg in "$@"; do
    [ "$arg" = "--reconfigure" ] || [ "$arg" = "-r" ] && RECONFIGURE="--reconfigure"
done

echo -e "${GREEN}▶  Запуск сервисов...${NC}"
"./run.sh" $RECONFIGURE
