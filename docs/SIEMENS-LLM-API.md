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
## Performance und Routing (Messstand 08.10.2026)

- Explorative Mini-Anfrage mit `max_tokens=8` (je Modell n=1): DeepSeek 16,9 s,
  Siemens-Qwen 123,4 s. Beide nutzten das knappe Budget vollständig für
  Reasoning und lieferten keinen Antwortinhalt. Das belegt nur das Risiko eines
  zu kleinen Budgets — keine allgemeine Aussage über das Reasoning-Verhalten.
- Kontrollierte Kurzprobe: derselbe Prompt (`Return exactly this JSON and nothing
  else: {"ok":true}`), `max_tokens=512`, `temperature=0`, direkte API,
  nicht gestreamt, je Modell n=3. Alle sechs Requests waren HTTP 200 und gaben
  den erwarteten JSON-Inhalt zurück. Die End-to-end-Latenz schwankte stark:

| Modell | Latenzen (s) | Median | Usage je Antwort |
|---|---|---:|---|
| `deepseek-v4.1-flash` | 31.810, 72.128, 16.236 | 31.810 | 43 Prompt + 25 Completion (18 Reasoning), 68 total |
| `qwen-3.8-27b` | 20.110, 2.497, 96.350 | 20.110 | 23 Prompt + 44–45 Completion (36–37 Reasoning), 67–68 total |

Es gab keine Cache-Tokens. Die Requests waren sequenziell; drei Samples pro Modell
sind eine Momentaufnahme, keine belastbare Tail-Latency-Verteilung. Der API-Body
lieferte Tokenusage, aber keinen verifizierbaren Rechnungsbetrag. Der in einem
Claude-Code-Smoke ausgegebene SDK-Kostenwert hatte `costBasis=unknown` und ist
kein Siemens-Abrechnungsnachweis.

Entscheidung: Siemens-Modelle bleiben separat auswählbare Review-/Benchmark-Ziele;
kein automatischer interaktiver Fallback. Der automatische lokale Pfad bleibt
`qwen3.8-flash-next` → `bonsai-2-27b` → `gpt-6-luna`. Bei Benchmarks mindestens
512 Output-Tokens erlauben und Prompt-, Completion- sowie Reasoning-Tokens mitschreiben.

## Modelle (Auswahl, `/v1/models` Stand 08.10.2026)
| Modell | Kontext | Notiz |
|---|---:|---|
| deepseek-v4.1-flash | 1 048 576 | Flaggschiff der Flotte, tools+vision |
| qwen-3.8-27b | 262 144 | Cloud-Pendant zu unserem lokalen qwen-Fork-Thema |
| mistral-large-3-675b-instruct | groß | MoE-Heavy |
| gpt-oss-120b, nemotron-super-3-120b | groß | offene 120B-Klasse |
| ministral-3-{3,8,14}b-instruct | 256k | kleine, schnelle Utility-Modelle |
| gemma-4-{26b-a4b,31b,e2b}, diffusiongemma | — | Experimental |
| bge-m3, qwen3-embedding-{0.6b,8b}, qwen3-reranker | — | Embeddings/Rerank für RAG |
| whisper-large-v3-turbo | — | ASR |

## Client-Anbindungen (aus code.siemens.io Doku)
- **OpenCode**: Siemens-Modelle sind lokal im Provider `local-litellm` als
  `deepseek-v4.1-flash` und `siemens-qwen-3.8-27b` wählbar; dadurch läuft Auth
  zentral über LiteLLM. Der direkte Provider `siemens/<id>` bleibt separat.
- **Claude Code**: Siemens dokumentiert `ANTHROPIC_AUTH_TOKEN` und
  `ANTHROPIC_BASE_URL=https://api.siemens.com/llm`; setzt man dort die
  `DEFAULT_*_MODEL`-Variablen auf `deepseek-v4.1-flash`, ist das weiterhin
  DeepSeek — nicht Claude Opus/Sonnet. Auf dieser Workstation war
  `claude auth status` am 08.10.2026 `loggedIn=false`; echtes Anthropic-Opus/Sonnet
  ist daher nicht verfügbar, solange keine First-Party-Anmeldung erfolgt.
  Der Siemens-DeepSeek-Smoke im Claude-Code-Harness blieb ohne verwertbares
  Ergebnis (unrecognized_model-Warnung; 1-turn-Limit; der 3-turn-Versuch
  hing und wurde nach 300 s abgebrochen). Nicht als funktionierendes Review-Harness werten.
- **Aider**: `AIDER_OPENAI_API_KEY`, `AIDER_OPENAI_API_BASE=https://api.siemens.com/llm/v1`,
  `AIDER_MODEL=openai/deepseek-v4.1-flash` (Syntax `openai/<name>`), max-chat-history 300000.
- **VS Code Copilot**: Command Palette → Chat: Manage Language Models → Custom Endpoint
  (json direkt editieren geht NICHT zuverlässig). Ohne Copilot-Abo: chat.utilityModel +
  utilitySmallModel auf BYOK-Modell stellen (sonst Utility-Fehler).
- **GitHub Copilot CLI / Codex**: ebd. via OpenAI-kompat-Endpunkt bzw. MCP-Anleitung auf der Seite.
- **MCP**: gitlab-csc via OAuth oder Private-Token-Header; Directory via `apikey`-Header
  (SIAK-… aus my.siemens.com, separates Verzeichnis-Abonnement). Achtung vor MCP-Vertrauensfragen
  (Doku sagt selbst: nur geprüfte Server).

## Betrieb im eigenen Stack
- LiteLLM stellt Siemens-Modelle als eigene Modell-IDs bereit; der lokale Fallback bleibt
  ausdrücklich Qwen → Bonsai → Luna. Siemens-Cloud-Latenz kommt nicht in den Kernpfad.
- `scripts/65-configure-siemens-api.sh` übernimmt den Key aus `SIEMENS_LLM_KEY_FILE`
  atomar in `~/.config/llm-infra/gateway.env` (Modus 0600) und regeneriert die Konfiguration.
  Das Skript startet den Gateway absichtlich nicht neu; vor Neustart erst laufende Agenten,
  jüngste Requests und active-request-Metriken prüfen.
- Hermes hat persistente Aliase `siemens-deepseek` und `siemens-qwen`; OpenCode listet beide
  über `local-litellm`. Codex/Copilot-Aufrufe sind noch nicht end-to-end mit Siemens-Modellen
  verifiziert.

## Belegtests (Ergebnisse hier fortschreiben, nie Token-Werte)
- 2026-10-08: `GET /v1/models` → HTTP 200, 20 Modelle.
- 2026-10-08: direkte OpenAI-kompatible Chat-Completions, max_tokens=512, n=3 je Modell;
  siehe Latenz-/Usage-Tabelle oben. Alle sechs Antworten korrekt, aber mit stark schwankender
  End-to-end-Latenz.
- 2026-10-08: LiteLLM-Generator/Modellliste validiert und Commit `b570587` gepusht;
  sichere Key-Provisionierung ist implementiert. Runtime-Neustart und Live-Modellabruf
  bleiben wegen aktiver Agenten-Requests absichtlich ausstehend.
