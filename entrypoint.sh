#!/bin/bash
set -e

OPENCLAW_HOME_DIR="/data/openclaw"
CONFIG_FILE="$OPENCLAW_HOME_DIR/openclaw.json"
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
    rm -rf ~/.openclaw
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
    local tmpfile; tmpfile=$(mktemp)
    if [ -f "$ENV_FILE" ]; then
        cp "$ENV_FILE" "$tmpfile"
    else
        : >"$tmpfile"
    fi
    for key in OLLAMA_HOST TELEGRAM_BOT_TOKEN WEBUI_PASSWORD WEBUI_PORT DEFAULT_MODEL OPENCLAW_GATEWAY_TOKEN TELEGRAM_ALLOWED_USERS; do
        local val; val=$(eval echo "\${$key:-}")
        [ -z "$val" ] && continue
        if grep -qE "^${key}=" "$tmpfile" 2>/dev/null; then
            if sed --version 2>/dev/null | grep -q GNU; then
                sed -i "s|^${key}=.*|${key}=${val}|" "$tmpfile"
            else
                sed -i '' "s|^${key}=.*|${key}=${val}|" "$tmpfile"
            fi
        else
            echo "${key}=${val}" >> "$tmpfile"
        fi
    done
    cat "$tmpfile" > "$ENV_FILE"
    rm -f "$tmpfile"
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

    var gwPassword = process.env.WEBUI_PASSWORD;
    var gwPort = parseInt(process.env.WEBUI_PORT || "3000", 10);
    var primaryModel = "ollama/" + (process.env.DEFAULT_MODEL || "gpt-oss:20b");

    var authCfg;
    if (gwPassword) {
      authCfg = { mode: "password", password: gwPassword, token: gwToken };
      console.log("Using password auth");
    } else {
      authCfg = { mode: "token", token: gwToken };
    }

    var cfg = {
      gateway: {
        mode: "local",
        port: gwPort,
        bind: "lan",
        auth: authCfg,
        controlUi: { enabled: true, allowInsecureAuth: true }
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
          },
          imageModel: {
            primary: primaryModel
          }
        }
      },
      session: {
        reset: {
          mode: "daily",
          atHour: 4,
          idleMinutes: 120
        },
        compaction: {
          mode: "default"
        }
      },
      plugins: {
        load: { paths: ["/data/plugins"] }
      }
    };

    if (process.env.TELEGRAM_BOT_TOKEN) {
      var tgPolicy = "pairing";
      var tgAllowFrom = [];
      try {
        var parsed = JSON.parse(process.env.TELEGRAM_ALLOWED_USERS || "[]");
        if (Array.isArray(parsed) && parsed.length > 0) {
          tgPolicy = "allowlist";
          tgAllowFrom = parsed;
        }
      } catch (e) {}

      cfg.channels = {
        telegram: {
          enabled: true,
          botToken: process.env.TELEGRAM_BOT_TOKEN,
          dmPolicy: tgPolicy,
          network: { autoSelectFamily: false }
        }
      };
      if (tgAllowFrom.length > 0) {
        cfg.channels.telegram.allowFrom = tgAllowFrom;
        cfg.commands = {
          ownerAllowFrom: tgAllowFrom.map(function (id) { return "telegram:" + id; })
        };
      }
    }

    require("fs").writeFileSync(
      process.env.HOME + "/.openclaw/openclaw.json",
      JSON.stringify(cfg, null, 2)
    );
    '
}

sync_auth() {
    local current_mode current_password current_token desired_password
    desired_password="${WEBUI_PASSWORD:-}"
    current_mode=$(jq -r '.gateway.auth.mode // empty' "$CONFIG_FILE" 2>/dev/null)
    current_password=$(jq -r '.gateway.auth.password // empty' "$CONFIG_FILE" 2>/dev/null)
    current_token=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null)

    if [ -n "$desired_password" ]; then
        if [ "$current_mode" != "password" ] || [ "$current_password" != "$desired_password" ]; then
            echo "Setting password auth in config"
            if [ -z "$current_token" ]; then
                current_token=$(openssl rand -hex 24 2>/dev/null || node -e "process.stdout.write(require('crypto').randomBytes(24).toString('hex'))")
            fi
            jq --arg mode "password" --arg password "$desired_password" --arg token "$current_token" \
              '.gateway.auth = { mode: $mode, password: $password, token: $token }' \
              "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
    else
        if [ "$current_mode" != "token" ] || [ -z "$current_token" ]; then
            if [ -z "$current_token" ]; then
                current_token=$(openssl rand -hex 24 2>/dev/null || node -e "process.stdout.write(require('crypto').randomBytes(24).toString('hex'))")
            fi
            echo "Setting token auth in config"
            jq --arg mode "token" --arg token "$current_token" \
              '.gateway.auth = { mode: $mode, token: $token }' \
              "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        fi
    fi
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

load_env

# Preserve gateway token if config already exists
if [ -f "$CONFIG_FILE" ]; then
    PRESERVED_TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null)
    if [ -n "$PRESERVED_TOKEN" ]; then
        export OPENCLAW_GATEWAY_TOKEN="$PRESERVED_TOKEN"
    fi
fi

ensure_dirs
link_openclaw_home
setup_agents_md
generate_config

if [ -z "$OPENCLAW_GATEWAY_TOKEN" ]; then
    OPENCLAW_GATEWAY_TOKEN=$(jq -r '.gateway.auth.token // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi

save_env

print_welcome
exec openclaw gateway
