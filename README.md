# Self-Hosted Honcho for Hermes Agent

Self-host [Honcho](https://github.com/plastic-labs/honcho) (Plastic Labs' memory layer) on your own VM instead of using their cloud. Works with [Hermes Agent](https://github.com/NousResearch/hermes-agent) out of the box.

**No fork required** — just 3 config files on top of upstream Honcho.

## What this does

- Runs Honcho's full memory stack (API, Deriver, PostgreSQL, Redis) on your VM
- Routes LLM calls through **OpenRouter** (primary) with **Venice AI** as backup
- Embeddings via Venice AI (`openai/text-embedding-3-small`) — see [Known Limitations](#known-limitations)
- All your data stays on your VM — no third-party cloud storage

## Architecture

```
Hermes Agent ──► localhost:8000 (self-hosted Honcho API)
                      │
                      ├── PostgreSQL + pgvector (your VM)
                      ├── Redis cache (your VM)
                      │
                      └── Deriver/Dialectic/Dream workers
                              │
                              ├── Primary: OpenRouter (200+ provider fallbacks)
                              └── Backup:  Venice AI (if OpenRouter is down)
```

## Prerequisites

- Ubuntu 22.04+ VM (tested on 22.04, 6GB RAM, 80GB disk)
- Docker Engine + Compose plugin
- OpenRouter API key ([openrouter.ai](https://openrouter.ai))
- Venice AI API key ([venice.ai](https://venice.ai)) — optional backup + embeddings

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

Replace the placeholder values with your actual keys:
- `LLM_VLLM_API_KEY` — your OpenRouter key (primary LLM)
- `LLM_OPENAI_COMPATIBLE_API_KEY` — your Venice key (backup LLM + embeddings)
- `LLM_OPENAI_API_KEY` — your OpenRouter key again (needed for client init)

Any OpenAI-compatible provider works — just swap the URL and key. See [Using different providers](#using-different-providers) for details.

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

LLM calls are tiered by task complexity:

| Component | Primary (OpenRouter) | Backup (Venice) | When it runs |
|-----------|---------------------|-----------------|-------------|
| **Deriver** | `qwen/qwen3-5-35b-a3b` | `qwen3-5-35b-a3b` | Every message |
| **Summary** | `qwen/qwen3-5-35b-a3b` | `qwen3-5-35b-a3b` | Every 20/60 messages |
| **Dialectic** (low) | `qwen/qwen3-5-35b-a3b` | `qwen3-5-35b-a3b` | Per Hermes turn |
| **Dialectic** (med/high) | `qwen/qwen3-5-122b-a10b` | `qwen3-5-122b-a10b` | Complex queries |
| **Dialectic** (max) | `deepseek/deepseek-chat-v3-0324` | `deepseek-v3.2` | Hardest queries |
| **Dream** | `deepseek/deepseek-chat-v3-0324` | `deepseek-v3.2` | Every ~8 hours |

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

- **Embeddings go through Venice** — Honcho's "openrouter" embedding client shares `OPENAI_COMPATIBLE_*` config with the "custom" LLM client. Can't separate them without code changes. Venice embedding cost is negligible.
- **One backup per component** — Honcho supports primary + one backup provider, not a full failover chain. Using OpenRouter as primary mitigates this since OpenRouter has its own multi-provider routing.
- **No E2EE** — Honcho's agents use function calling, which Venice E2EE doesn't support. LLM request content is visible to the provider, but your stored data (sessions, observations, embeddings) stays on your VM.

## Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Docker deployment — API, Deriver, PostgreSQL, Redis |
| `config.toml` | Honcho config — providers, models, feature flags |
| `env.example` | API keys template — copy to `~/honcho/.env` and fill in |
| `honcho-config.json` | Hermes-side config — tells Hermes to use localhost:8000 |
| `setup.sh` | One-command installer — handles everything |

## Credits

- [Honcho](https://github.com/plastic-labs/honcho) by Plastic Labs
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) by Nous Research
- [Venice AI](https://venice.ai) for private inference
- [OpenRouter](https://openrouter.ai) for multi-provider routing
