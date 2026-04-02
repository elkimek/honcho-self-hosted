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

# --- API keys ---
if [ -f "$INSTALL_DIR/.env" ]; then
    echo "[4/5] .env exists, keeping current keys"
else
    echo "[4/5] Setting up API keys..."
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

    if [ -n "$BACKUP_KEY" ]; then
        read -rp "  Backup API base URL [https://api.venice.ai/api/v1]: " BACKUP_URL
        BACKUP_URL="${BACKUP_URL:-https://api.venice.ai/api/v1}"
        {
            echo ""
            echo "# Backup LLM provider + embeddings"
            echo "LLM_OPENAI_COMPATIBLE_API_KEY=${BACKUP_KEY}"
        } >> "$INSTALL_DIR/.env"
        # Update config.toml with backup URL
        sed -i "s|OPENAI_COMPATIBLE_BASE_URL = .*|OPENAI_COMPATIBLE_BASE_URL = \"${BACKUP_URL}\"|" "$INSTALL_DIR/config.toml"
    else
        # No backup — remove backup provider references from config
        sed -i '/^BACKUP_PROVIDER/d; /^BACKUP_MODEL/d' "$INSTALL_DIR/config.toml"
        sed -i '/^OPENAI_COMPATIBLE_BASE_URL/d' "$INSTALL_DIR/config.toml"
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

echo ""
echo "Done! Honcho is running on localhost:8000"
