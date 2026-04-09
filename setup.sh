#!/usr/bin/env bash
set -euo pipefail

# Self-hosted Honcho setup for Hermes Agent
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/elkimek/honcho-self-hosted/main/setup.sh -o /tmp/setup.sh
#   bash /tmp/setup.sh

REPO="https://github.com/elkimek/honcho-self-hosted.git"
HONCHO_REPO="https://github.com/plastic-labs/honcho.git"
INSTALL_DIR="$HOME/honcho"
CONFIG_DIR="$HOME/honcho-self-hosted"

echo "=== Self-hosted Honcho setup ==="
echo ""

# --- Check Docker ---
if ! command -v docker &>/dev/null; then
    echo "Docker not found. Installing..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
      https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    sudo usermod -aG docker "$USER"
    echo ""
    echo "Docker installed. You need to log out and back in, then re-run this script."
    exit 0
fi

if ! docker info &>/dev/null; then
    echo "Docker is installed but not accessible. Either:"
    echo "  - Log out and back in (if you just installed Docker)"
    echo "  - Or run: sudo usermod -aG docker \$USER"
    exit 1
fi

echo "[1/5] Docker OK ($(docker --version | cut -d' ' -f3 | tr -d ','))"

# --- Clone repos ---
if [ -d "$CONFIG_DIR" ]; then
    echo "[2/5] Config repo exists, pulling latest..."
    git -C "$CONFIG_DIR" pull -q
else
    echo "[2/5] Cloning config repo..."
    git clone -q "$REPO" "$CONFIG_DIR"
fi

if [ -d "$INSTALL_DIR/.git" ]; then
    echo "[3/5] Honcho repo exists, pulling latest..."
    git -C "$INSTALL_DIR" pull -q 2>/dev/null || true
else
    echo "[3/5] Cloning Honcho..."
    git clone -q --depth 1 "$HONCHO_REPO" "$INSTALL_DIR"
fi

# --- Copy configs (untracked by upstream, safe to overwrite) ---
cp "$CONFIG_DIR/docker-compose.yml" "$INSTALL_DIR/"
cp "$CONFIG_DIR/config.toml" "$INSTALL_DIR/"

# --- LLM provider setup ---
if [ -f "$INSTALL_DIR/.env" ]; then
    echo "[4/5] .env exists, keeping current config"
else
    echo "[4/5] Setting up LLM provider..."
    echo ""
    echo "  How do you want to run LLM inference?"
    echo ""
    echo "  1) Cloud API  — OpenRouter, Venice, Together, etc. (recommended)"
    echo "  2) Local / LAN — Ollama, vLLM, llama.cpp on this or another machine"
    echo ""

    PROVIDER_MODE=""
    while [ "$PROVIDER_MODE" != "1" ] && [ "$PROVIDER_MODE" != "2" ]; do
        read -rp "  Choose [1/2]: " PROVIDER_MODE
    done

    if [ "$PROVIDER_MODE" = "2" ]; then
        # --- Local / LAN setup ---
        echo ""
        echo "  Local inference setup"
        echo "  Your server must expose an OpenAI-compatible API (/v1/chat/completions)"
        echo ""
        echo "  Common URLs:"
        echo "    Ollama (this machine):    http://localhost:11434/v1"
        echo "    Ollama (LAN):             http://192.168.x.x:11434/v1"
        echo "    vLLM:                     http://localhost:8001/v1"
        echo "    llama.cpp:                http://localhost:8080/v1"
        echo ""

        read -rp "  Server URL: " LOCAL_URL
        while [ -z "$LOCAL_URL" ]; do
            echo "  URL is required"
            read -rp "  Server URL: " LOCAL_URL
        done

        read -rp "  API key (press Enter for 'none' if not needed): " LOCAL_KEY
        LOCAL_KEY="${LOCAL_KEY:-none}"

        echo ""
        echo "  You need to set model names in config.toml to match your server."
        echo "  Use model names from your server (e.g. Ollama: 'glm-4.7-flash', vLLM: 'THUDM/GLM-4.7-Flash')"
        echo ""
        read -rp "  Model name for light tasks (deriver, summary) [glm-4.7-flash]: " LIGHT_MODEL
        LIGHT_MODEL="${LIGHT_MODEL:-glm-4.7-flash}"

        read -rp "  Model name for heavy tasks (dream, max dialectic) [glm-4.7-flash]: " HEAVY_MODEL
        HEAVY_MODEL="${HEAVY_MODEL:-$LIGHT_MODEL}"

        echo ""
        echo "  Embeddings require a cloud API (local servers can't serve the embedding model)."
        echo "  You can use a free/cheap key from OpenRouter or OpenAI just for embeddings,"
        echo "  or press Enter to disable embeddings (vector search won't work)."
        echo ""
        read -rp "  Embedding API key (or Enter to disable): " EMBED_KEY

        {
            echo "# Local / LAN LLM provider"
            echo "LLM_VLLM_API_KEY=${LOCAL_KEY}"
            echo "LLM_VLLM_BASE_URL=${LOCAL_URL}"
            echo ""
            echo "# Needed for client initialization"
            echo "LLM_OPENAI_API_KEY=${LOCAL_KEY}"
        } > "$INSTALL_DIR/.env"

        if [ -n "$EMBED_KEY" ]; then
            read -rp "  Embedding API base URL [https://openrouter.ai/api/v1]: " EMBED_URL
            EMBED_URL="${EMBED_URL:-https://openrouter.ai/api/v1}"
            read -rp "  Embedding model name [openai/text-embedding-3-small]: " EMBED_MODEL
            EMBED_MODEL="${EMBED_MODEL:-openai/text-embedding-3-small}"
            {
                echo ""
                echo "# Embeddings via cloud API (local server can't serve embedding models)"
                echo "LLM_EMBEDDING_API_KEY=${EMBED_KEY}"
                echo "LLM_EMBEDDING_BASE_URL=${EMBED_URL}"
                echo "LLM_EMBEDDING_MODEL=${EMBED_MODEL}"
            } >> "$INSTALL_DIR/.env"
            # OPENAI_COMPATIBLE still needed for client init
            {
                echo "LLM_OPENAI_COMPATIBLE_API_KEY=${LOCAL_KEY}"
            } >> "$INSTALL_DIR/.env"
            sed -i "s|OPENAI_COMPATIBLE_BASE_URL = .*|OPENAI_COMPATIBLE_BASE_URL = \"${LOCAL_URL}\"|" "$INSTALL_DIR/config.toml"
        else
            # Disable embeddings entirely
            sed -i 's|EMBED_MESSAGES = true|EMBED_MESSAGES = false|' "$INSTALL_DIR/config.toml"
            sed -i "s|OPENAI_COMPATIBLE_BASE_URL = .*|OPENAI_COMPATIBLE_BASE_URL = \"${LOCAL_URL}\"|" "$INSTALL_DIR/config.toml"
            {
                echo ""
                echo "LLM_OPENAI_COMPATIBLE_API_KEY=${LOCAL_KEY}"
            } >> "$INSTALL_DIR/.env"
            echo "  Embeddings disabled. Honcho will work but vector search won't be available."
        fi

        # Remove backup provider refs (local = single provider)
        sed -i '/^BACKUP_PROVIDER/d; /^BACKUP_MODEL/d' "$INSTALL_DIR/config.toml"

        # Replace all model names — light tier
        sed -i "s|\"z-ai/glm-4.7-flash\"|\"${LIGHT_MODEL}\"|g" "$INSTALL_DIR/config.toml"
        sed -i "s|\"zai-org-glm-4.7-flash\"|\"${LIGHT_MODEL}\"|g" "$INSTALL_DIR/config.toml"

        # Medium tier — use heavy model (local typically has one or two models)
        sed -i "s|\"x-ai/grok-4.1-fast\"|\"${HEAVY_MODEL}\"|g" "$INSTALL_DIR/config.toml"
        sed -i "s|\"grok-41-fast\"|\"${HEAVY_MODEL}\"|g" "$INSTALL_DIR/config.toml"

        # Heavy tier
        sed -i "s|\"z-ai/glm-5\"|\"${HEAVY_MODEL}\"|g" "$INSTALL_DIR/config.toml"
        sed -i "s|\"zai-org-glm-5\"|\"${HEAVY_MODEL}\"|g" "$INSTALL_DIR/config.toml"

        echo "  Configured for local inference at ${LOCAL_URL}"

    else
        # --- Cloud API setup ---
        echo ""

        PRIMARY_KEY=""
        while [ -z "$PRIMARY_KEY" ]; do
            read -rp "  Primary LLM API key (required): " PRIMARY_KEY
            if [ -z "$PRIMARY_KEY" ]; then
                echo "  An API key is required (e.g. from openrouter.ai, venice.ai, together.ai)"
            fi
        done

        read -rp "  Primary API base URL [https://openrouter.ai/api/v1]: " PRIMARY_URL
        PRIMARY_URL="${PRIMARY_URL:-https://openrouter.ai/api/v1}"

        read -rp "  Backup LLM API key (optional, press Enter to skip): " BACKUP_KEY

        {
            echo "# Primary LLM provider"
            echo "LLM_VLLM_API_KEY=${PRIMARY_KEY}"
            echo "LLM_VLLM_BASE_URL=${PRIMARY_URL}"
            echo ""
            echo "# Needed for client initialization"
            echo "LLM_OPENAI_API_KEY=${PRIMARY_KEY}"
        } > "$INSTALL_DIR/.env"

        # Embeddings via primary provider (backup may not support embedding models)
        {
            echo ""
            echo "# Embeddings via primary provider"
            echo "LLM_EMBEDDING_API_KEY=${PRIMARY_KEY}"
            echo "LLM_EMBEDDING_BASE_URL=${PRIMARY_URL}"
            echo "LLM_EMBEDDING_MODEL=openai/text-embedding-3-small"
        } >> "$INSTALL_DIR/.env"

        if [ -n "$BACKUP_KEY" ]; then
            read -rp "  Backup API base URL [https://api.venice.ai/api/v1]: " BACKUP_URL
            BACKUP_URL="${BACKUP_URL:-https://api.venice.ai/api/v1}"
            {
                echo ""
                echo "# Backup LLM provider"
                echo "LLM_OPENAI_COMPATIBLE_API_KEY=${BACKUP_KEY}"
            } >> "$INSTALL_DIR/.env"
            sed -i "s|OPENAI_COMPATIBLE_BASE_URL = .*|OPENAI_COMPATIBLE_BASE_URL = \"${BACKUP_URL}\"|" "$INSTALL_DIR/config.toml"
        else
            # No backup — remove backup provider references from config
            sed -i '/^BACKUP_PROVIDER/d; /^BACKUP_MODEL/d' "$INSTALL_DIR/config.toml"
            {
                echo ""
                echo "LLM_OPENAI_COMPATIBLE_API_KEY=${PRIMARY_KEY}"
            } >> "$INSTALL_DIR/.env"
            sed -i "s|OPENAI_COMPATIBLE_BASE_URL = .*|OPENAI_COMPATIBLE_BASE_URL = \"${PRIMARY_URL}\"|" "$INSTALL_DIR/config.toml"
        fi
    fi

    echo "  Keys saved to $INSTALL_DIR/.env"
fi

# --- Start ---
echo "[5/5] Starting Honcho..."
cd "$INSTALL_DIR"
if ! docker compose up -d --build 2>&1 | tail -20; then
    echo ""
    echo "ERROR: Docker Compose failed. Check logs with: docker compose logs"
    exit 1
fi

echo ""
echo "Waiting for API..."
API_UP=false
for i in $(seq 1 60); do
    if curl -s http://localhost:8000/openapi.json >/dev/null 2>&1; then
        echo "Honcho API is live at http://localhost:8000"
        API_UP=true
        break
    fi
    sleep 1
done

if [ "$API_UP" = false ]; then
    echo "WARNING: API did not respond within 60 seconds."
    echo "Check logs: cd ~/honcho && docker compose logs api"
fi

# --- Hermes config ---
if command -v hermes &>/dev/null; then
    mkdir -p "$HOME/.honcho"
    cp "$CONFIG_DIR/honcho-config.json" "$HOME/.honcho/config.json"
    echo "Hermes configured to use local Honcho"
    echo ""
    echo "Run 'hermes gateway restart' to apply."
else
    echo ""
    echo "Hermes not found. To configure it later:"
    echo "  mkdir -p ~/.honcho"
    echo "  cp $CONFIG_DIR/honcho-config.json ~/.honcho/config.json"
fi

# --- MCP server (optional) ---
echo ""
read -rp "Set up Honcho MCP server? (exposes memory tools to Claude Code/Desktop) [y/N]: " SETUP_MCP

if [ "$SETUP_MCP" = "y" ] || [ "$SETUP_MCP" = "Y" ]; then
    # Check for Node.js
    if ! command -v node &>/dev/null; then
        echo "  Node.js not found. Install it first:"
        echo "    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo bash -"
        echo "    sudo apt-get install -y nodejs"
        echo "  Then re-run this script."
    elif ! command -v bun &>/dev/null && ! [ -x "$HOME/.bun/bin/bun" ]; then
        echo "  Bun not found. Install it first:"
        echo "    curl -fsSL https://bun.sh/install | bash"
        echo "  Then re-run this script."
    else
        BUN="${HOME}/.bun/bin/bun"
        command -v bun &>/dev/null && BUN="bun"

        echo "  Setting up MCP server..."
        cd "$INSTALL_DIR/mcp"

        # Patch to use local Honcho
        sed -i 's|https://api.honcho.dev|http://localhost:8000|' src/config.ts

        "$BUN" install --silent 2>&1 | tail -3

        MCP_PORT=8787

        # Create systemd service
        cat > /tmp/honcho-mcp.service << SVCEOF
[Unit]
Description=Honcho MCP Server
After=network.target docker.service
Wants=docker.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR/mcp
ExecStart=/usr/bin/npx wrangler dev --port $MCP_PORT --ip 0.0.0.0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

        if sudo -n true 2>/dev/null; then
            sudo cp /tmp/honcho-mcp.service /etc/systemd/system/
            sudo systemctl daemon-reload
            sudo systemctl enable --now honcho-mcp
            echo "  MCP server running on port $MCP_PORT (systemd service)"
        else
            echo "  Systemd service file written to /tmp/honcho-mcp.service"
            echo "  Install it with:"
            echo "    sudo cp /tmp/honcho-mcp.service /etc/systemd/system/"
            echo "    sudo systemctl daemon-reload"
            echo "    sudo systemctl enable --now honcho-mcp"
        fi

        echo ""
        echo "  To connect Claude Code (from this machine):"
        echo "    claude mcp add --transport http honcho http://localhost:$MCP_PORT \\"
        echo "      --header \"Authorization: Bearer local\" \\"
        echo "      --header \"X-Honcho-User-Name: \$USER\" \\"
        echo "      --header \"X-Honcho-Workspace-ID: hermes\""
        echo ""
        echo "  From a remote machine, tunnel first:"
        echo "    ssh -f -N -L $MCP_PORT:localhost:$MCP_PORT user@this-server"
    fi
fi

echo ""
echo "Done! Honcho is running on localhost:8000"
