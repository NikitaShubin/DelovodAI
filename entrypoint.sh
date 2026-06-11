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
        set +e
        . "$ENV_FILE"
        set -e
        set +a
    fi
}

save_env() {
    local tmpfile; tmpfile=$(mktemp)
    if [ -f "$ENV_FILE" ]; then
        cp "$ENV_FILE" "$tmpfile"
    else
        : > "$tmpfile"
    fi
    for key in OLLAMA_HOST TELEGRAM_BOT_TOKEN WEBUI_PASSWORD WEBUI_PORT DEFAULT_MODEL OPENCLAW_GATEWAY_TOKEN TELEGRAM_ALLOWED_USERS; do
        local val; val=$(eval echo "\${$key:-}")
        [ -z "$val" ] && continue
        if grep -qE "^${key}=" "$tmpfile" 2>/dev/null; then
            if [[ "$val" == *"["* || "$val" == *" "* || "$val" == *"\""* || "$val" == *":"* ]]; then
                sed -i "s|^${key}=.*|${key}='${val}'|" "$tmpfile"
            else
                sed -i "s|^${key}=.*|${key}=${val}|" "$tmpfile"
            fi
        else
            if [[ "$val" == *"["* || "$val" == *" "* || "$val" == *"\""* || "$val" == *":"* ]]; then
                echo "${key}='${val}'" >> "$tmpfile"
            else
                echo "${key}=${val}" >> "$tmpfile"
            fi
        fi
    done
    cat "$tmpfile" > "$ENV_FILE"
    rm -f "$tmpfile"
}

generate_config() {
    local primary_model="ollama/${DEFAULT_MODEL:-gpt-oss:20b}"
    local gw_password="${WEBUI_PASSWORD:-}"
    local gw_port="${WEBUI_PORT:-3000}"

    # Generate base config via openclaw onboard (new format v2026.5+)
    openclaw onboard --non-interactive --accept-risk --flow manual \
        --auth-choice skip \
        --gateway-auth password \
        --gateway-password "$gw_password" \
        --gateway-bind lan \
        --gateway-port "$gw_port" \
        --skip-health 2>&1

    # Set default model
    openclaw models set "$primary_model" 2>&1

    # Register model in main config's models.providers.ollama
    if command -v jq &>/dev/null; then
        local tmp; tmp=$(mktemp)
        local model_id="${DEFAULT_MODEL:-gpt-oss:20b}"
        local ollama_url="${OLLAMA_HOST:-http://127.0.0.1:11434}"
        jq --arg id "$model_id" --arg name "$model_id" --arg url "$ollama_url" '
            .models.providers.ollama.baseUrl = $url
            | .models.providers.ollama.models = (
                .models.providers.ollama.models // []
                | if any(.[]; .id == $id) then . else . + [{id: $id, name: $name}] end
            )
        ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    fi

    # Add control UI and allowed origins
    if command -v jq &>/dev/null; then
        local tmp; tmp=$(mktemp)
        jq '.gateway.controlUi = { enabled: true, allowInsecureAuth: true }
            | .gateway.tailscale = { mode: "off", resetOnExit: false }' \
            "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    fi

    # Add telegram channel if token is set
    if [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        openclaw channels add --channel telegram --use-env 2>&1
    fi

    # Create ollama auth profile for the agent
    local auth_file="$OPENCLAW_HOME_DIR/agents/main/agent/auth-profiles.json"
    if ! grep -q '"ollama"' "$auth_file" 2>/dev/null; then
        echo "ollama-local" | openclaw models auth paste-api-key \
            --provider ollama --profile-id ollama:local 2>&1
    fi

    # Register model in agent's models.json and update catalog
    local model_name="${DEFAULT_MODEL:-gpt-oss:20b}"
    local ollama_host="${OLLAMA_HOST:-http://127.0.0.1:11434}"
    local models_json="$OPENCLAW_HOME_DIR/agents/main/agent/models.json"
    local catalog_json="$OPENCLAW_HOME_DIR/agents/main/agent/plugins/ollama/catalog.json"

    if command -v jq &>/dev/null; then
        local tmp; tmp=$(mktemp)

        # Add model to agent models.json
        if [ -f "$models_json" ]; then
            jq --arg id "$model_name" '
                .providers.ollama.models = (
                    .providers.ollama.models // []
                    | if any(.[]; .id == $id) then . else . + [{id: $id}] end
                )
            ' "$models_json" > "$tmp" && mv "$tmp" "$models_json"
        fi

        # Update catalog.json with correct baseUrl and model list
        if [ -f "$catalog_json" ]; then
            jq --arg url "$ollama_host" --arg model "$model_name" '
                .providers.ollama.baseUrl = $url
                | .providers.ollama.models = (
                    .providers.ollama.models // []
                    | if any(.[]; . == $model) then . else . + [$model] end
                )
            ' "$catalog_json" > "$tmp" && mv "$tmp" "$catalog_json"
        fi
    fi
}

apply_model_context() {
    local model_id="${DEFAULT_MODEL:-gpt-oss:20b}"
    local ollama_host="${OLLAMA_HOST:-http://127.0.0.1:11434}"

    if ! command -v curl &>/dev/null || ! command -v jq &>/dev/null; then
        echo "  Skipping model context probe: missing curl or jq"
        return
    fi

    # Env override: skip probe
    if [ -n "${MODEL_NUM_CTX:-}" ]; then
        echo "  Using MODEL_NUM_CTX=$MODEL_NUM_CTX (env override)"
        _write_num_ctx "$model_id" "$MODEL_NUM_CTX"
        return
    fi

    local model_info
    model_info=$(curl -s --connect-timeout 5 "$ollama_host/api/show" \
        -d "{\"model\":\"$model_id\"}" 2>/dev/null || true)

    if [ -z "$model_info" ]; then
        echo "  Could not query Ollama ($ollama_host), keeping default settings"
        return
    fi

    local context_length
    context_length=$(echo "$model_info" | jq -r '
        [.model_info | to_entries[] | select(.key | test("context_length$")) | .value]
        | first // empty
    ' 2>/dev/null || true)

    if [ -z "$context_length" ] || [ "$context_length" = "null" ] || [ "$context_length" -le 0 ] 2>/dev/null; then
        echo "  Could not determine context_length for $model_id, keeping default settings"
        return
    fi

    local max_ctx
    max_ctx=$context_length
    [ "$max_ctx" -gt 65536 ] && max_ctx=65536

    echo ""
    echo "  Probing ${model_id} for max working num_ctx (hardware limit, cap ${max_ctx})..."

    local num_ctx=$max_ctx
    local reduced=false

    while [ "$num_ctx" -ge 2048 ]; do
        echo -n "    Trying num_ctx=${num_ctx}... "
        local resp
        resp=$(curl -s --connect-timeout 10 --max-time 60 \
            "$ollama_host/api/generate" \
            -d "{\"model\":\"$model_id\",\"prompt\":\".\",\"options\":{\"num_ctx\":$num_ctx},\"keep_alive\":0}" \
            2>/dev/null || true)

        if echo "$resp" | grep -qi "out of memory\|CUDA error\|OOM"; then
            echo "OOM"
            reduced=true
            local next=$(( num_ctx / 2 ))
            if [ "$next" -lt 2048 ]; then
                num_ctx=2048
                echo "    Warning: even num_ctx=2048 failed with OOM, using minimal value"
                break
            fi
            num_ctx=$next
        else
            echo "OK"
            break
        fi
    done

    if [ "$reduced" = true ]; then
        echo "  ⚠ Context window reduced from ${max_ctx} to ${num_ctx} (VRAM limit)"
    else
        echo "  Context window: ${num_ctx} (full)"
    fi

    _write_num_ctx "$model_id" "$num_ctx"
}

_write_num_ctx() {
    local model_id="$1" num_ctx="$2"
    local tmp; tmp=$(mktemp)
    jq --arg id "$model_id" --argjson num_ctx "$num_ctx" '
        (.models.providers.ollama.models // []) |= map(
            if .id == $id then . * {params: {num_ctx: $num_ctx}} else . end
        )
        | .agents.defaults.models["ollama/\($id)"] = (
            .agents.defaults.models["ollama/\($id)"] // {}
            | .params.num_ctx = $num_ctx
        )
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
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

ensure_dirs
link_openclaw_home
setup_agents_md
generate_config

apply_model_context

save_env

print_welcome
exec openclaw gateway
