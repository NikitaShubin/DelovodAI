#!/bin/bash
set -e

OPENCLAW_HOME_DIR="/data/openclaw"
ENV_FILE="/data/config/env"
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
    node -e '
    var crypto = require("crypto");
    var host = (process.env.OLLAMA_HOST || "ollama:11434")
      .replace(/^https?:\/\//, "");

    var gwToken = process.env.OPENCLAW_GATEWAY_TOKEN;
    if (!gwToken) {
      gwToken = crypto.randomBytes(24).toString("hex");
      console.log("Generated gateway token: " + gwToken);
    }

    var gwPort = parseInt(process.env.WEBUI_PORT || "3000", 10);
    var primaryModel = "ollama/" + (process.env.DEFAULT_MODEL || "gpt-oss:20b");

    var cfg = {
      gateway: {
        mode: "local",
        port: gwPort,
        bind: "lan",
        auth: { token: gwToken },
        controlUi: { enabled: true }
      },
      models: {
        providers: {
          ollama: {
            baseUrl: "http://" + host,
            apiKey: "ollama-local",
            api: "openai-completions",
            injectNumCtxForOpenAICompat: true
          }
        }
      },
      agents: {
        defaults: {
          model: {
            primary: primaryModel
          }
        }
      },
      plugins: {
        load: { paths: ["/data/plugins"] }
      }
    };

    if (process.env.TELEGRAM_BOT_TOKEN) {
      cfg.channels = {
        telegram: {
          enabled: true,
          botToken: process.env.TELEGRAM_BOT_TOKEN,
          dmPolicy: "pairing"
        }
      };
    }

    require("fs").writeFileSync(
      process.env.HOME + "/.openclaw/openclaw.json",
      JSON.stringify(cfg, null, 2)
    );
    '
}

print_welcome() {
    local host="${OLLAMA_HOST:-ollama:11434}"
    host="${host#http://}"
    host="${host#https://}"

    echo ""
    echo "======================================"
    echo "  DelovodAI v0.1.0"
    echo "  Web UI: http://localhost:${WEBUI_PORT:-3000}"
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        echo "  Telegram: enabled"
    else
        echo "  Telegram: not configured"
    fi
    echo "  Ollama: http://${host}"
    echo "  Model: ${DEFAULT_MODEL:-gpt-oss:20b}"
    echo "======================================"
    echo ""
}

print_welcome() {
    local host="${OLLAMA_HOST:-ollama:11434}"
    host="${host#http://}"
    host="${host#https://}"

    echo ""
    echo "======================================"
    echo "  DelovodAI v0.1.0"
    echo "  Web UI: http://localhost:${WEBUI_PORT:-3000}"
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        echo "  Telegram: enabled"
    else
        echo "  Telegram: not configured"
    fi
    echo "  Ollama: http://${host}"
    echo "  Model: ${DEFAULT_MODEL:-gpt-oss:20b}"
    echo "======================================"
    echo ""
}

CONFIG_FILE="$HOME/.openclaw/openclaw.json"

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
