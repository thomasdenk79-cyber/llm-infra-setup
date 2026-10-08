# Siemens LLM API (code.siemens.io) — Anschluss & Betrieb

> Dokumentiert am 2026-10-08 von Hermes. Doku-Portal (SSO-pflichtig): https://code.siemens.io/
> Endpunkte: https://api.siemens.com/llm/v1 (OpenAI-kompatibel, chat/completions + models)
> MCP-Server: https://api.siemens.com/mcp/gitlab (auch gitlab-read), /directory/mcp, https://mcp.siemens.com

## Zugriff
- API-Key vom Typ `SIAK-…`, Scope `llm`, geholt über my.siemens.com.
- Speicherort des Keys NUR hier dokumentiert, Wert niemals in Repos/Logs/Doku:
  `C:\Users\z000g9hu\OneDrive - Siemens AG\tools\myconfigfiles\code.siemens.com_api_ai_token.txt`
- Status laut Portal: Plan `free`, gültig 23.07.2026 → 12.01.2028, Nutzer Z000G9HU.
- Verifikation 08.10.: `GET /v1/models` → HTTP 200, 20 Modelle.
- PERFORMANCE-BEFUND 08.10. 12:47 (Nutzer-Warnung 'oft sehr langsam', bestätigt):
  Mini-Prompt (8 Token Budget): deepseek-v4.1-flash 16,9 s; qwen-3.8-27b 123,4 s.
  BEIDE verbrauchten das Budget vollstaendig fuer reasoning_tokens (content=None) ->
  Always-Reasoning-Modelle: kleine max_tokens-Werte erzeugen LEERE Antwort. Immer Budget
  >=512 senden. Konsequenz fürs Routing: Siemens-Modelle NICHT interaktiv/latenzkritisch,
  sondern als asynchrone Zweitmeinung (Hintergrund-Agenturen). free-Quote kann drosseln.

## Modelle (Auswahl, /v1/models Stand 08.10.2026)
| Modell | Kontext | Notiz |
|---|---|---|
| deepseek-v4.1-flash | 1 048 576 | Flaggschiff der Flotte, tools+vision |
| qwen-3.8-27b | 262 144 | Cloud-Pendant zu unserem lokalen qwen-Fork-Thema |
| mistral-large-3-675b-instruct | groß | MoE-Heavy |
| gpt-oss-120b, nemotron-super-3-120b | groß | offene 120B-Klasse |
| ministral-3-{3,8,14}b-instruct | 256k | kleine, schnelle Titler/Utility |
| gemma-4-{26b-a4b,31b,e2b}, diffusiongemma | — | Experimental |
| bge-m3, qwen3-embedding-{0.6b,8b}, qwen3-reranker | — | Embeddings/Rerank für RAG |
| whisper-large-v3-turbo | — | ASR |

## Client-Anbindungen (aus code.siemens.io Doku)
- **OpenCode V2**: `~/.config/opencode/opencode.json` → provider `siemens`,
  baseURL `https://api.siemens.com/llm/v1`, model `siemens/<id>`. Installer: `curl -fsSL https://opencode.ai/v2/install | bash`.
  our existing V1-style config keeps local-litellm; siemens provider added in parallel.
- **Claude Code**: `~/.claude/settings.json` env-Block mit ANTHROPIC_AUTH_TOKEN=SIAK…,
  ANTHROPIC_BASE_URL=https://api.siemens.com/llm, DEFAULT_*_MODEL deepseek-v4.1-flash,
  CLAUDE_CODE_MAX_CONTEXT_TOKENS 300000, DISABLE_NONESSENTIAL_TRAFFIC=1.
- **Aider**: `AIDER_OPENAI_API_KEY`, `AIDER_OPENAI_API_BASE=https://api.siemens.com/llm/v1`,
  `AIDER_MODEL=openai/deepseek-v4.1-flash` (Syntax `openai/<name>`), max-chat-history 300000.
- **VS Code Copilot**: Command Palette → Chat: Manage Language Models → Custom Endpoint
  (json direkt editieren geht NICHT zuverlässig). Ohne Copilot-Abo: chat.utilityModel +
  utilitySmallModel auf BYOK-Modell stellen (sonst Utility-Fehler).
- **GitHub Copilot CLI / Codex**: ebd. via OpenAI-kompat-Endpunkt bzw. MCP-Anleitung auf der Seite.
- **MCP**: gitlab-csc via OAuth oder Private-Token-Header; Directory via `apikey`-Header
  (SIAK-… aus my.siemens.com, separates Verzeichnis-Abonnement). Achtung vor MCP-Vertrauensfragen
  (Doku sagt selbst: nur geprüfte Server).

## Betrieb im eigenen Stack (Entscheidung offen, A/B-tests)
- Option A (bevorzugt für Benchmarks): Clients (opencode/aider) binden siemens direkt ein —
  Messung Harness × Siemens-Modell ohne LiteLLM-Umweg.
- Option B: LiteLLM-Gateway bekommt siemens/… als 4. Modell + Fallback-Kette; Vorteil central
  logging/costs, Nachteil: free-Late-Risiko im Kernpfad. Erst nach Latenz-Charakterisierung.

## Belegtests (Ergebnisse hier fortschreiben, nie Token-Werte)
- 2026-10-08 12:4x GET /models → 200/20 Modelle. Chat qwen-3.8-27b: Timeout>40s (retry läuft).
