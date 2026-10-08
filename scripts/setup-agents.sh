#!/usr/bin/env bash
# Configure installed WSL agents to prefer the local LiteLLM/Pennyroyal route.
# Idempotent: preserve unrelated user settings and never copy credentials into Git.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/secrets.sh"

[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
[[ -f "${root}/config/model.env" ]] && source "${root}/config/model.env"
: "${PENNY_CUDA_VISIBLE_DEVICES:=GPU-780d3589-9811-40ec-db66-93a9146697f3}"
export PENNY_CUDA_VISIBLE_DEVICES

ensure_base_credentials
master="$(awk -F= '$1 == "LITELLM_MASTER_KEY" {sub(/^[^=]*=/, ""); print; exit}' "${HOME}/.config/llm-infra/gateway.env")"
if ! grep -Fq 'LLM_INFRA_API_KEY=' "${HOME}/.config/llm-infra/gateway.env"; then
  printf '\nLLM_INFRA_API_KEY=%s\n' "$master" >> "${HOME}/.config/llm-infra/gateway.env"
  chmod 0600 "${HOME}/.config/llm-infra/gateway.env"
fi
install -d -m 0700 "${HOME}/.config/opencode" "${HOME}/.codex" "${HOME}/.hermes"

python - "$HOME" "$root" <<'PY'
import json
import pathlib
import re
import sys

home, repo = map(pathlib.Path, sys.argv[1:])
opencode = home / ".config/opencode/opencode.json"
config = {}
if opencode.exists():
    config = json.loads(opencode.read_text())
config["$schema"] = "https://opencode.ai/config.json"
config["model"] = "local-litellm/qwen3.8-flash-next"
config["small_model"] = "local-litellm/qwen3.8-flash-next"
config["default_agent"] = "build"
config.setdefault("share", "disabled")
config.setdefault("provider", {})["local-litellm"] = {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Local LiteLLM / Pennyroyal",
    "options": {"baseURL": "http://127.0.0.1:4000/v1", "apiKey": "{env:LLM_INFRA_API_KEY}"},
    "models": {"qwen3.8-flash-next": {
        "name": "Qwen3.8 Flash-Next (local)", "tool_call": True,
        "limit": {"context": 500000, "output": 32000},
    }},
}
config.setdefault("agent", {})["build"] = {
    **config.get("agent", {}).get("build", {}),
    "mode": "primary",
    "permission": {"*": "allow"},
}
config["permission"] = {"*": "allow"}
for agent in ("general", "explore"):
    config.setdefault("agent", {}).setdefault(agent, {"permission": {"*": "allow"}})
opencode.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
opencode.chmod(0o600)
json.loads(opencode.read_text())

PY

python - "$HOME" <<'PY'
import pathlib
import re
import sys
import yaml

home = pathlib.Path(sys.argv[1])
codex = home / ".codex/config.toml"
codex.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
text = codex.read_text() if codex.exists() else ""
start, end = "# BEGIN llm-infra managed agent defaults", "# END llm-infra managed agent defaults"
block = '''# BEGIN llm-infra managed agent defaults
model = "qwen3.8-flash-next"
model_provider = "local-litellm"
model_context_window = 500000
approval_policy = "never"
sandbox_mode = "danger-full-access"

[model_providers.local-litellm]
name = "Local LiteLLM / Pennyroyal"
base_url = "http://127.0.0.1:4000/v1"
env_key = "LLM_INFRA_API_KEY"
wire_api = "responses"
# END llm-infra managed agent defaults'''
if start in text and end in text:
    text = re.sub(re.escape(start) + r".*?" + re.escape(end), block, text, flags=re.S)
else:
    text = text.rstrip() + "\n\n" + block + "\n"
import tomllib
tomllib.loads(text)
codex.write_text(text)
codex.chmod(0o600)

# Keep the existing Windows Terminal marketplace/plugin section intact.
bashrc = home / ".bashrc"
marker = "# BEGIN llm-infra agent launchers"
launchers = '''# BEGIN llm-infra agent launchers
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
if [[ $- == *i* && -r "$HOME/work/llm-infra-setup/scripts/llm-env.sh" ]]; then
  source "$HOME/work/llm-infra-setup/scripts/llm-env.sh" 2>/dev/null || true
fi
if command -v copilot >/dev/null 2>&1; then
  copilot() {
    if [[ -n "${LLM_INFRA_API_KEY:-}" ]] && curl -fsS --max-time 2 http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1 && curl -fsS --max-time 2 http://127.0.0.1:8001/health >/dev/null 2>&1; then
      COPILOT_PROVIDER_BASE_URL="${LLM_INFRA_BASE_URL}" COPILOT_PROVIDER_API_KEY="${LLM_INFRA_API_KEY}" \\
        COPILOT_MODEL=qwen3.8-flash-next command copilot --yolo "$@"
    else
      command copilot --yolo --model gpt-6-luna "$@"
    fi
  }
fi
if command -v opencode >/dev/null 2>&1; then opencode() { command "$HOME/.opencode/bin/opencode" --auto "$@"; }; fi
if command -v hermes >/dev/null 2>&1; then hermes() { command "$HOME/.local/bin/hermes" --yolo "$@"; }; fi
# END llm-infra agent launchers'''
old = bashrc.read_text() if bashrc.exists() else ""
if marker in old:
    old = re.sub(re.escape(marker) + r".*?# END llm-infra agent launchers", launchers, old, flags=re.S)
else:
    old = old.rstrip() + "\n\n" + launchers + "\n"
bashrc.write_text(old)
PY

# Hermes primary: local gateway. Cloud fallbacks stay configured in YAML.
python - "$HOME" <<'PY'
import os
import pathlib
import re
import sys
import yaml

home = pathlib.Path(sys.argv[1])
cfg = home / ".hermes/config.yaml"
env_file = home / ".hermes/.env"
gateway = home / ".config/llm-infra/gateway.env"
cfg.parent.mkdir(mode=0o700, parents=True, exist_ok=True)

text = cfg.read_text() if cfg.exists() else ""
start, end = "# BEGIN llm-infra managed model routing", "# END llm-infra managed model routing"
data = yaml.safe_load(text) if text else {}
data = data or {}
model = data.setdefault("model", {})
model.update({"provider": "custom", "default": "qwen3.8-flash-next",
              "base_url": "http://127.0.0.1:4000/v1", "api_mode": "chat_completions", "key_env": "LLM_INFRA_API_KEY"})
data["fallback_providers"] = [{"provider": "copilot", "model": "gpt-6-luna"}]
cfg.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
cfg.chmod(0o600)

key = ""
for line in gateway.read_text().splitlines():
    if line.startswith("LITELLM_MASTER_KEY="):
        key = line.split("=", 1)[1]
        break
if not key:
    raise SystemExit("LITELLM_MASTER_KEY missing in gateway.env")
env = env_file.read_text() if env_file.exists() else ""
env = re.sub(r"(?m)^LLM_INFRA_API_KEY=.*\n?", "", env)
env = env.rstrip() + f"\nLLM_INFRA_API_KEY={key}\n"
env_file.write_text(env)
env_file.chmod(0o600)
PY

"${root}/scripts/install-llmlogs.sh"
log 'Local agent defaults installed. Cloud OAuth logins remain managed by their CLIs.'
log 'For OpenAI Codex Plus sign-in, run: codex login'
log 'For OpenCode GitHub Copilot sign-in, run: opencode providers login'
