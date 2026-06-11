FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    pandoc \
    texlive-latex-base \
    texlive-latex-extra \
    texlive-fonts-recommended \
    libreoffice-writer-nogui \
    curl \
    jq \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g openclaw@2026.6.5

WORKDIR /app

COPY entrypoint.sh /app/entrypoint.sh
COPY AGENTS.md /app/AGENTS.md

RUN chmod +x /app/entrypoint.sh

ENV TZ=Europe/Moscow \
    OPENCLAW_TELEMETRY=false \
    LANG=ru_RU.UTF-8

ENTRYPOINT ["/app/entrypoint.sh"]
