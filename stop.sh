#!/bin/bash
set -e

cd "$(cd "$(dirname "$0")" && pwd)" || exit

if [ -t 1 ]; then
    GREEN='\033[1;32m'; BLUE='\033[1;94m'; BOLD='\033[1m'; NC='\033[0m'
else
    GREEN=''; BLUE=''; BOLD=''; NC=''
fi

echo ""
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${BLUE}  Остановка DelovodAI${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo ""

docker compose -f "./docker-compose.yaml" down 2>&1 | sed 's/^/   /'

echo ""
echo -e "${GREEN}✓${NC} ${BOLD}Контейнеры остановлены${NC}"
echo ""
