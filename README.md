# Self-Hosted Honcho for Hermes Agent

Self-host [Honcho](https://github.com/plastic-labs/honcho) (Plastic Labs' memory layer) on your own server instead of using their cloud. Works with [Hermes Agent](https://github.com/NousResearch/hermes-agent) out of the box.

**No fork required** — just 3 config files on top of upstream Honcho.

## Background: Hermes L4 Memory

Hermes Agent has a 4-layer memory system. The cross-session memory layer is powered by [Honcho](https://github.com/plastic-labs/honcho), which builds a deepening model of the user across conversations — extracting observations, recalling context, and consolidating memories over time.

By default, Hermes uses Plastic Labs' managed cloud ([honcho.dev](https://honcho.dev)) + their [Neuromancer](https://plasticlabs.ai/neuromancer) models. This works out of the box but means your conversation data and user profile live on their servers.

### What are Neuromancer models?

[Neuromancer XR](https://blog.plasticlabs.ai/research/Introducing-Neuromancer-XR) is a specialized 8B model fine-tuned from Qwen3-8B specifically for extracting logical conclusions from conversations. Unlike general-purpose LLMs which are optimized for plausible text generation, Neuromancer is trained on ~10,000 curated social reasoning traces to follow formal logic — extracting both explicit facts ("user said they like Python") and deductive conclusions ("user is likely a developer").

It scores 86.9% on the LoCoMo memory benchmark vs. 69.6% for base Qwen3-8B and 80.0% for Claude 4 Sonnet.

**Tradeoff of not using it:** General-purpose models work well for observation extraction and memory recall — Honcho's prompts and tool-calling pipeline compensate for much of the gap. You may get slightly less precise deductive reasoning, but capable models (GLM-5, Grok 4.1) with strong function calling largely close the difference. The main advantage of self-hosting is data sovereignty, not matching Neuromancer's exact reasoning quality.

## Deployment Options

| Option | Privacy | Data location | LLM for memory | Setup | Cost |
|--------|---------|--------------|----------------|-------|------|
| **Managed cloud** (default) | Low — data + inference on 3rd party | Plastic Labs servers | Neuromancer (Plastic Labs) | None — built into Hermes | Free tier / paid |
| **Self-hosted + API** (this repo) | Medium — data on your machine, inference via API | Your machine | Any OpenAI-compatible API | ~3 minutes | API usage only |
| **Self-hosted + local model** | High — nothing leaves your network | Your machine | Local LLM (Ollama, vLLM) | More setup | Hardware only |

**Managed cloud** — Zero setup. Best for getting started. Your data is on Plastic Labs' infrastructure.

**Self-hosted + API** — This repo. Your data stays on your machine. LLM calls go to a cloud API for inference only — the provider sees request content but doesn't store your memory data. Best balance of privacy and capability.

**Self-hosted + local model** — Maximum privacy. No data leaves your network. Requires a GPU or capable CPU on your LAN running an inference server (Ollama, vLLM, llama.cpp). Set `LLM_VLLM_BASE_URL` to your local server. Trade-off: smaller models may produce lower quality observations and reasoning than cloud APIs.

## What this does

- Runs Honcho's full memory stack (API, Deriver, PostgreSQL, Redis) on your machine
- Routes LLM calls through any OpenAI-compatible provider (primary + backup)
- All your data stays on your machine — no third-party cloud storage
- Works with OpenRouter, Venice, Routstr, Together, Ollama, or any other provider

## Architecture

```
Hermes Agent ──► localhost:8000 (self-hosted Honcho API)
                      │
                      ├── PostgreSQL + pgvector (your machine)
                      ├── Redis cache (your machine)
                      │
                      └── Deriver/Dialectic/Dream workers
                              │
                              ├── Primary LLM provider (any OpenAI-compatible API)
                              └── Backup LLM provider (optional)
```

## Prerequisites

- Ubuntu 22.04+ (VM, VPS, bare metal, or any Linux server — tested on 22.04, 6GB RAM, 80GB disk)
- Docker Engine + Compose plugin
- API key from any OpenAI-compatible provider ([openrouter.ai](https://openrouter.ai), [venice.ai](https://venice.ai), [together.ai](https://together.ai), etc.)
- Second API key for backup (optional)

## Quick Start

```bash
curl -sL https://raw.githubusercontent.com/elkimek/honcho-self-hosted/main/setup.sh -o /tmp/setup.sh
bash /tmp/setup.sh
```

This installs Docker (if needed), clones Honcho, copies configs, prompts for API keys, starts everything, and configures Hermes. ~3 minutes.

## Manual Setup

### 1. Install Docker

```bash
sudo apt-get update && sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker $USER
```

Log out and back in for the group change to take effect.

### 2. Clone repos + copy configs

```bash
# Clone this config repo
git clone https://github.com/elkimek/honcho-self-hosted.git ~/honcho-self-hosted

# Clone upstream Honcho
git clone --depth 1 https://github.com/plastic-labs/honcho.git ~/honcho

# Copy config files into the Honcho clone
cp ~/honcho-self-hosted/docker-compose.yml ~/honcho/
cp ~/honcho-self-hosted/config.toml ~/honcho/
cp ~/honcho-self-hosted/env.example ~/honcho/.env
```

### 3. Set your API keys

Edit `~/honcho/.env`:

```bash
nano ~/honcho/.env
```

Replace the placeholder values with your actual API keys:
- `LLM_VLLM_API_KEY` — primary LLM provider
- `LLM_VLLM_BASE_URL` — primary provider's API URL
- `LLM_OPENAI_COMPATIBLE_API_KEY` — backup LLM provider (also used for embeddings)
- `LLM_OPENAI_API_KEY` — same as your primary key (needed for client init)

Any OpenAI-compatible provider works (OpenRouter, Venice, Routstr, Together, etc.) — just set the key and URL. See [Using different providers](#using-different-providers) for details.

**If you don't want a backup provider:** remove all `BACKUP_PROVIDER` and `BACKUP_MODEL` lines from `config.toml`, and set `LLM_OPENAI_COMPATIBLE_API_KEY` + `OPENAI_COMPATIBLE_BASE_URL` to the same values as your primary (needed for embeddings). The setup script handles this automatically.

### 4. Start Honcho

```bash
cd ~/honcho
docker compose up -d
```

First run builds images and runs DB migrations (~2 minutes). Check status:

```bash
docker compose ps
docker compose logs -f api deriver
```

Wait ~10 seconds for the API to start, then verify:

```bash
curl -s http://localhost:8000/openapi.json | head -1
```

### 5. Configure Hermes

```bash
mkdir -p ~/.honcho
cp ~/honcho-self-hosted/honcho-config.json ~/.honcho/config.json
hermes gateway restart
```

Hermes will now use your local Honcho instead of `api.honcho.dev`.

## Model Configuration

Honcho has 4 background components that use LLM calls:

- **Deriver** — Reads every message and extracts observations about the user ("prefers Python", "privacy-focused"). Memory formation.
- **Dialectic** — Answers questions about the user on demand, with 5 reasoning levels (minimal → max). Memory recall.
- **Summary** — Compresses long sessions into short/long summaries to keep context manageable.
- **Dream** — Runs every ~8 hours. Merges redundant observations, deletes outdated ones, infers higher-level patterns. Memory consolidation.

LLM calls are tiered by task complexity. Defaults are chosen for **function-calling reliability** (the primary requirement for Honcho's tool-using agents):

| Component | Default model | Tier | When it runs |
|-----------|--------------|------|-------------|
| **Deriver** | `z-ai/glm-4.7-flash` | Light — fast, cheap, 79.5% tau-bench | Every message |
| **Summary** | `z-ai/glm-4.7-flash` | Light | Every 20/60 messages |
| **Dialectic** (low) | `z-ai/glm-4.7-flash` | Light | Per Hermes turn |
| **Dialectic** (med/high) | `x-ai/grok-4.1-fast` | Medium — built for tool use, 2M context | Complex queries |
| **Dialectic** (max) | `z-ai/glm-5` | Heavy — 89.7% tau2-bench | Hardest queries |
| **Dream** | `z-ai/glm-5` | Heavy | Every ~8 hours |

These are [OpenRouter](https://openrouter.ai) model IDs. Any model your provider supports will work — just change the name in `config.toml`. Each component also has a backup provider that fires automatically if the primary fails on the last retry.

To change models, edit `~/honcho/config.toml` and rebuild:

```bash
cd ~/honcho
docker compose up -d --build
```

## Using different providers

Honcho supports these provider slots natively:

| Slot | Config key | How to use |
|------|-----------|------------|
| `custom` | `OPENAI_COMPATIBLE_BASE_URL` + `OPENAI_COMPATIBLE_API_KEY` | Any OpenAI-compatible API |
| `vllm` | `VLLM_BASE_URL` + `VLLM_API_KEY` | Any OpenAI-compatible API |
| `openai` | `OPENAI_API_KEY` | OpenAI direct |
| `anthropic` | `ANTHROPIC_API_KEY` | Anthropic direct |
| `google` | `GEMINI_API_KEY` | Google Gemini |
| `groq` | `GROQ_API_KEY` | Groq |

You can mix providers per component in `config.toml`:

```toml
[deriver]
PROVIDER = "groq"          # fast for frequent tasks
MODEL = "llama-3.3-70b"

[dream]
PROVIDER = "anthropic"     # best reasoning for rare tasks
MODEL = "claude-sonnet-4-6"
```

## Local / LAN Inference

For maximum privacy, run a local model instead of a cloud API. Any server with an OpenAI-compatible endpoint works.

Local servers have different model catalogs than cloud APIs, so model names will differ. The setup script asks you for the model name your server provides.

Recommended local models for reliable function calling:

| Model | Params | Ollama name | Notes |
|-------|--------|------------|-------|
| **GLM-4.7 Flash** | 30B MoE | `glm-4.7-flash` | Same family as cloud default, best tool use in 30B class |
| **Llama 3.3** | 70B | `llama3.3:70b` | Battle-tested tools, needs ~40GB VRAM |

### Ollama (easiest)

```bash
# Install Ollama on this machine or another on your LAN
curl -fsSL https://ollama.com/install.sh | sh

# Pull a model with strong function calling
ollama pull glm-4.7-flash
```

Then run the setup script and choose option 2 (Local / LAN):

```
Server URL: http://localhost:11434/v1
Model name for light tasks: glm-4.7-flash
Model name for heavy tasks: glm-4.7-flash
```

For a separate LAN machine, use its IP: `http://192.168.x.x:11434/v1`

### vLLM

```bash
# Serve a model with tool calling support
vllm serve THUDM/GLM-4.7-Flash --port 8001 --enable-auto-tool-choice
```

Setup: `http://localhost:8001/v1` with model name `THUDM/GLM-4.7-Flash`

### Considerations

- **Model size matters** — Honcho's agents need reliable function calling and structured JSON. Models under 14B may miss tool calls or malform output. 32B+ recommended.
- **Embeddings need a cloud API** — Honcho uses `openai/text-embedding-3-small` for vector embeddings, which local servers can't serve. The setup script asks for a separate cloud API key for embeddings (e.g. a free OpenRouter key), or lets you disable embeddings entirely (Honcho works but without vector search).
- **Same model for all tiers** — locally you'll typically run one model. The script sets it for all components. You can differentiate later in `config.toml` if you serve multiple models.
- **No backup provider** — local mode uses a single server. If it goes down, Honcho's deriver queues work until it's back.

## MCP Server (optional)

Honcho includes an MCP server that exposes memory tools (search, chat, observations, peer cards) to any MCP-compatible client like Claude Code or Claude Desktop.

The hosted version at `mcp.honcho.dev` points at Plastic Labs' cloud. For self-hosted, run the MCP server locally and point it at your Honcho instance.

### Setup

Requires Node.js 22+ and Bun on the server:

```bash
cd ~/honcho/mcp

# Patch to use local Honcho instead of honcho.dev
sed -i 's|https://api.honcho.dev|http://localhost:8000|' src/config.ts

bun install
```

### Run as a service

Create `/etc/systemd/system/honcho-mcp.service`:

```ini
[Unit]
Description=Honcho MCP Server
After=network.target docker.service

[Service]
Type=simple
User=your-username
WorkingDirectory=/home/your-username/honcho/mcp
ExecStart=/usr/bin/npx wrangler dev --port 8787 --ip 0.0.0.0
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Then:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now honcho-mcp
```

### Connect Claude Code

If the MCP server is on a remote machine, tunnel the port over SSH:

```bash
ssh -f -N -L 8787:localhost:8787 user@your-server
```

Then add to Claude Code:

```bash
claude mcp add --transport http honcho http://localhost:8787 \
  --header "Authorization: Bearer local" \
  --header "X-Honcho-User-Name: your-name" \
  --header "X-Honcho-Workspace-ID: hermes"
```

### Connect Claude Desktop

Add to your Claude Desktop config (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "honcho": {
      "command": "npx",
      "args": [
        "mcp-remote",
        "http://localhost:8787",
        "--header", "Authorization:${AUTH_HEADER}",
        "--header", "X-Honcho-User-Name:${USER_NAME}"
      ],
      "env": {
        "AUTH_HEADER": "Bearer local",
        "USER_NAME": "your-name"
      }
    }
  }
}
```

## Maintenance

**Update Honcho:**

```bash
cd ~/honcho
docker compose down
git pull            # our config files are untracked by upstream, no conflicts
docker compose up -d --build
```

**View logs:**
```bash
docker compose logs -f api deriver
```

**Check queue status:**
```bash
curl -s http://localhost:8000/v3/workspaces/hermes/queue/status | python3 -m json.tool
```

**Backup data:**
```bash
docker compose exec database pg_dump -U honcho honcho > backup.sql
```

## Known Limitations

- **Embeddings share backup provider config** — Honcho's embedding client shares `OPENAI_COMPATIBLE_*` config with the backup LLM provider. If you configure a backup, embeddings route through it too. Embedding cost is negligible.
- **One backup per component** — Honcho supports primary + one backup provider, not a full failover chain. Using a multi-provider router (e.g. OpenRouter) as primary mitigates this.
- **No E2EE** — Honcho's agents use function calling, which isn't compatible with end-to-end encryption. LLM request content is visible to the provider, but your stored data (sessions, observations, embeddings) stays on your machine.

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Docker deployment — API, Deriver, PostgreSQL, Redis |
| `config.toml` | Honcho config — providers, models, feature flags |
| `env.example` | API keys template — copy to `~/honcho/.env` and fill in |
| `honcho-config.json` | Hermes-side config — tells Hermes to use localhost:8000 |
| `setup.sh` | One-command installer — handles everything |

## License

GPL-3.0

## Credits

- [Honcho](https://github.com/plastic-labs/honcho) by Plastic Labs
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research
