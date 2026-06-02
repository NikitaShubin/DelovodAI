#!/bin/bash
set -e

CONFIG_FILE="/data/config/openclaw.json"
ENV_FILE="/data/config/env"
OPENCLAW_HOME_DIR="/data/openclaw"
AGENTS_MD_SOURCE="/app/AGENTS.md"
AGENTS_MD_TARGET="/data/config/AGENTS.md"

ensure_dirs() {
    mkdir -p /data/config "$OPENCLAW_HOME_DIR" /data/plugins \
             /data/documents/templates /data/documents/generated \
             /data/calendar /data/tasks
}

setup_agents_md() {
    if [ ! -f "$AGENTS_MD_TARGET" ]; then
        cp "$AGENTS_MD_SOURCE" "$AGENTS_MD_TARGET"
    fi
}

link_openclaw_home() {
    mkdir -p "$OPENCLAW_HOME_DIR"
    ln -snf "$OPENCLAW_HOME_DIR" ~/.openclaw
}

load_env() {
    if [ -f "$ENV_FILE" ]; then
        set -a
        source "$ENV_FILE"
        set +a
    fi
}

save_env() {
    cat > "$ENV_FILE" <<-ENVEOF
OLLAMA_HOST=$OLLAMA_HOST
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
WEBUI_PASSWORD=$WEBUI_PASSWORD
WEBUI_PORT=$WEBUI_PORT
DEFAULT_MODEL=$DEFAULT_MODEL
ENVEOF
}

generate_config() {
    CONFIG_FILE="$CONFIG_FILE" node -e '
    var cfg = {
      locale: "ru",
      telemetry: { enabled: false },
      models: {
        providers: {
          ollama: {
            baseUrl: "http://" + (process.env.OLLAMA_HOST || "ollama:11434"),
            apiKey: "ollama-local",
            api: "ollama",
            discovery: { enabled: true }
          }
        }
      },
      agents: {
        defaults: {
          model: {
            primary: "ollama/" + (process.env.DEFAULT_MODEL || "gpt-oss:20b")
          }
        }
      },
      channels: {},
      web: {
        enabled: true,
        port: parseInt(process.env.WEBUI_PORT || "3000", 10)
      },
      tools: {
        web: { search: { provider: "ollama" } }
      },
      plugins: { dirs: ["/data/plugins"] }
    };

    if (process.env.TELEGRAM_BOT_TOKEN) {
      cfg.channels.telegram = {
        enabled: true,
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        dmPolicy: "pairing"
      };
    }

    if (process.env.WEBUI_PASSWORD) {
      cfg.web.auth = {
        type: "shared-secret",
        secret: process.env.WEBUI_PASSWORD
      };
    } else {
      console.warn(
        "WARNING: Web UI has no authentication. " +
        "Set WEBUI_PASSWORD to enable password protection."
      );
    }

    require("fs").writeFileSync(process.env.CONFIG_FILE, JSON.stringify(cfg, null, 2));
    '
}

print_welcome() {
    echo ""
    echo "======================================"
    echo "  DelovodAI v0.1.0"
    echo "  Web UI: http://localhost:${WEBUI_PORT:-3000}"
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        echo "  Telegram: enabled"
    else
        echo "  Telegram: not configured"
    fi
    echo "  Ollama: http://${OLLAMA_HOST:-ollama:11434}"
    echo "  Model: ${DEFAULT_MODEL:-gpt-oss:20b}"
    echo "======================================"
    echo ""
}

if [ -f "$CONFIG_FILE" ]; then
    load_env
    ensure_dirs
    setup_agents_md
    link_openclaw_home
    print_welcome
    exec openclaw gateway
fi

OLLAMA_HOST="${OLLAMA_HOST:-ollama:11434}"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
WEBUI_PASSWORD="${WEBUI_PASSWORD:-}"
WEBUI_PORT="${WEBUI_PORT:-3000}"
DEFAULT_MODEL="${DEFAULT_MODEL:-gpt-oss:20b}"

echo "DelovodAI: first run — generating configuration..."

ensure_dirs
save_env
link_openclaw_home
setup_agents_md
generate_config

print_welcome
exec openclaw gateway
