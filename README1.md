# Local LLM Hub

A self-hosted, LAN-first AI workbench built on Ollama. The core thesis: **the harness is the product** — routing, memory, RAG, workflow, prompt assembly, and cost/latency control matter more than any single model. It runs first on an Apple M2 Pro (32 GB) and serves other machines over the home LAN, with a path to hosted/rented GPU inference for larger open-source models. Private by default (zero data retention posture).

This file is the canonical reference for the repository. It is what humans and agents should read when examining or changing this codebase.

---

## Project goal

Build a modular local/private AI workbench that runs first on an Apple M2 Pro MacBook with 32 GB unified memory, serves other laptops over the home LAN, and can later support hosted or rented GPU inference for larger open-source models. The product should feel closer to a lightweight local ChatGPT/Claude-style workspace than a simple web chat. LAN access is the highest near-term priority.

---

## The product thesis — Three Routing Principles

These are the product thesis. Every routing, context, and model-selection decision should follow from them.

1. **Not every AI task should go to the best model.**
   Most work needs the cheapest model that clears the quality bar. The router's job is not to find the "smartest" model. It is to find the least expensive model that can reliably complete that workflow.

2. **Not every AI task needs low latency.**
   If a human is waiting, speed matters. If it is enrichment, summarization, document processing, model comparison, evals, or overnight work, it can be queued. That changes the infrastructure math — you stop paying premium latency prices for work that doesn't need premium latency.

3. **Not every token deserves execution-model compute.**
   Raw prompt mass is not sacred. A lot of tokens are duplicated, stale, poorly structured, low-signal, or better handled before the main model ever sees them. The router should not only choose the model — it should decide what context gets sent, what gets compressed, what gets dropped, what gets rewritten, and what model is allowed to touch the final task. Use a smaller model to clean, structure, classify, compress, or prepare the prompt. Then send the improved version to the execution model. The output changes materially because the expensive model receives a better task, not simply more text.

4. **Latency is always a factor — KV cache, prefill, and optimization are standing considerations, not afterthoughts.**
   Every change to routing, prompt shape, context assembly, model selection, or the tool loop must be evaluated for its effect on **KV-cache reload, prefill, and the token budget**, not just correctness. On Apple Silicon the model weights and the KV cache share unified memory, so a volatile system prefix forces a full re-prefill every turn (seconds-to-tens-of-seconds) while a byte-stable prefix reuses cached KV (~0s). The rules: keep the system prefix byte-stable across turns (volatile sections live in the user-message tail, never the system prefix); prefer conversation stickiness so the cloud router runs once per conversation instead of every Auto turn; only attach native tool-calling `tools` JSON for native-capable models WITH offered tools so prompt-tag and tool-less turns stay byte-identical; and call out the latency impact in the plan + this README for any new routing/context change. See [Performance on M2: KV cache, prefill, and the token budget](#performance-on-m2-kv-cache-prefill-and-the-token-budget) for the mechanism.

**The wedge**: Stop wasting premium inference on bad routing, bloated prompts, and tasks that never needed the best model in the first place. Standardize workflows. Personalize interfaces. Govern everything.

Multi-select model comparison is how you learn whether Mistral, GLM, Qwen, DeepSeek, or a smaller local model is best for that actual workflow — not generally, specifically.

### Architecture thesis

The value is not the model alone. The value is the harness around models: routing, memory, workflow design, prompt architecture, tool use, evals, cost control, latency control, security, ongoing maintenance. Models do the work. **The harness is the product.** The app orchestration layer owns routing, context assembly, prompt assembly, permissions, logging, UI, and model selection.

### Routing philosophy — three layers

Do not use one global routing policy. Use three layers:

1. **Company policy** — allowed models, security rules, cost ceilings, data permissions, approved tools.
2. **Workflow routing** — process rules, required tools, default/fallback/escalation models, rubric, approval rules, cost target, latency target.
3. **User preference** — tone, summary length, detail level, writing style, preferred behavior, latency tolerance.

Principle: standardize workflows, personalize interfaces, govern everything.

### Workload classes

1. **Real-time** — voice, live chat, copilots while a human waits. Needs low latency.
2. **Near-time** — research, coding agents, CRM enrichment, summaries, workflow execution. Needs reliable completion, not instant response.
3. **Batch/offline** — document processing, evals, lead scoring, audits, reports. Needs throughput and cost control.

Optimize for cost per completed task, quality per completed task, and only paying for low latency when a human is actually waiting.

---

## Quick start

```bash
# Start the server (binds 0.0.0.0:3000 for LAN access)
node server.js

# Run unit tests (zero-dependency runner, uses Node assert)
node test/unit.js

# Run HTTP integration tests (boots server.js on an isolated temp dir)
node test/integration.js

# Run both suites
npm run test:all

# Run a single test group by name (search output for the group name)
node test/unit.js 2>&1 | grep -A 20 "GroupName"

# Migrate chats from JSONL to SQLite
npm run migrate:sqlite

# Export chats from SQLite to JSONL
npm run export:jsonl
```

No build step. No bundler. The only required npm dependency is `better-sqlite3` (native bindings). `mammoth` and `pdf-parse` are optional npm deps used only for `.docx`/`.pdf` attachment extraction — the app degrades gracefully to a placeholder if they are missing.

### Environment variables

No `.env` file — set in shell or systemd unit. All writable runtime paths are env-configurable so a deployment can point them at persistent volumes instead of the repo directory.

| Variable | Default | Purpose |
|----------|---------|---------|
| `PORT` | `3000` | HTTP listen port |
| `HOST` | `0.0.0.0` | HTTP listen host (bind all for LAN; the LAN gate still blocks non-LAN clients) |
| `MAX_BODY_BYTES` | `100000000` (100 MB) | Max request body size. Oversized bodies are rejected **early on `Content-Length`** before buffering (memory-pressure guard); `readBody`/`readRawBody` keep a running-byte cap as the chunked-transfer backstop. Lower this for a tighter cap (e.g. `50000000` for 50 MB). |
| `OLLAMA_BASE_URL` | `http://127.0.0.1:11434` | Ollama API endpoint |
| `GATEWAY_URL` | *(unset)* | If set, takes precedence over `OLLAMA_BASE_URL` for `OLLAMA_GENERATE_URL`/`OLLAMA_CHAT_URL` — use when Ollama is reached via the gateway rather than directly |
| `SEARXNG_URL` | `http://host.docker.internal:8080` | SearXNG search endpoint (container alias to the host; on bare metal use `http://127.0.0.1:8080`) |
| `ROUTER_BACKEND` | `auto` | `auto` (cloud router when `allowCloud` + a cloud router model is live, else local), `cloud` (force cloud, fall through to local on failure), or `local` (always the 0.5B router + heuristics) |
| `CLOUD_ROUTER_MODEL` | `glm-5.2:cloud` | Cloud router for text turns (the preferred Auto brain). Emits a strict JSON plan; fail-closed validated |
| `CLOUD_ROUTER_VISION_MODEL` | `mistral-large-3:675b-cloud` | Cloud router for turns with images — it can see what it is routing |
| `CLOUD_ROUTER_TIMEOUT_MS` | `10000` | Per-call budget before the cloud router fails closed to the local router |
| `CLOUD_ROUTER_MIN_CONFIDENCE` | `0.5` | Reject a cloud plan below this confidence and fall back |
| `ROUTER_MODEL` | `qwen2.5:0.5b` | Fixed local router (fail-safe) — task classification + prompt optimization |
| `ROUTER_ENABLED` | `true` | Enable/disable the LLM router (also gates prompt optimization) |
| `ROUTER_TIMEOUT_MS` | `3000` | Local router model timeout (classification + optimization) |
| `CLOUD_REASONING_MODEL` | `glm-5.2:cloud` | Cloud model the local-router path escalates to on hard reasoning turns when `allowCloud` is on and the model is live (skipped when the cloud router already chose the model). See *Chat fluidity — cloud reasoning escalation*. |
| `ROUTE_LOG_PATH` | `<data>/route.log.jsonl` | Route decision log — one JSON record per Auto turn (customer-scoped under `/data`, never baked into the image) |
| `ROUTE_PIN_PATH` | `<data>/route-pins.json` | Conversation route-pin store — pins the first Auto turn's `{model, policies}` so follow-ups skip the cloud-router call (customer-scoped under `/data`) |
| `AGENT_NATIVE_TOOLS` | `true` | Agentic workflow runner: native-tool-capable models drive the tool loop via Ollama `/api/chat` native `tool_calls` JSON (shared `modelShape.js` adapter); set `false` to force every workflow back to the text-`<tool_call>`-tag path |
| `AGENT_TOOL_RESULT_PROMPT_LIMIT` | `100000` | Max chars of a tool result fed back to the model on the next LLM step (`formatToolResultForPrompt`). Raised from the old 6k default so a real connector payload — a day of calendar events + inbox threads + weather — flows through whole instead of being cut mid-payload (the swarm model's 1M-token window has ample room). Lower it only if you must bound a tool that returns unbounded output |
| `AGENT_RUN_RESULT_LIMIT` | `100000` | Max chars persisted as a run's final `result` (the member report + the workflow answer). Raised from the old 10k so member reports carry the full connector data into the synthesizer |
| `AGENT_AUDIT_TEXT_LIMIT` | `20000` | Max chars of `llmResponse` / tool-result text stored in `audit.jsonl` (diagnostic only — never reaches the model). Raised from 5k so the audit shows the full payload when diagnosing a "no data" recurrence |
| `AGENT_PIPE_CAP` | `100000` | Max chars of a member's output piped into the next member (chain) or the synthesizer (fanout_synthesize). Raised from the old 8k so the synthesizer sees every event/thread a member pulled instead of a truncated prefix |
| `EMBEDDING_MODEL` | `nomic-embed-text` | Model for vector embeddings |
| `CHAT_STORE` | `sqlite` | Storage backend (`sqlite` or `jsonl`) |
| `CHAT_LOG_PATH` | `./chats.jsonl` | Legacy JSONL chat path (store fallback + orphan migration) |
| `CHAT_SQLITE_PATH` | derived from JSONL path | SQLite database file location |
| `CORPORA_DIR` | `./corpora` | RAG corpora directory |
| `MEMORY_DIR` | `./memory` | Dream/memory consolidation directory |
| `LOGS_DIR` | `./logs` | Events + feedback logs directory |
| `AGENTS_DIR` | `./agents` | Agent workflow run state directory |
| `ARTIFACTS_DIR` | `./artifacts` | Tracked image-artifact storage (sandboxed, hex-id filenames) |
| `SKILLS_DIR` | `./skills` | Writing skills (loaded at startup; created/edited at runtime) |
| `USAGE_PATH` | `./usage_stats.json` | Per-model usage stats file |
| `MODEL_CAPABILITIES_PATH` | `./model_capabilities.json` | Capability catalog (tool-calling, vision, strengths, sync) |
| `MODEL_PREFERENCES_PATH` | `./model_preferences.json` | Learned model-preference counts per task type |
| `SETTINGS_PATH` | `./settings.json` | User settings (persisted prefs incl. `imageReviewChain`) |
| `WORKFLOWS_PATH` | `./workflows.json` | Agentic workflow definitions |
| `WORKFLOW_BUILDER_MODEL` | _(empty = autoselect)_ | The model the **AI workflow generator AND the AI swarm generator** Claude CLI authoring agent runs on (both share one builder context, `buildGeneratorContext()`). Empty/unset = autoselect the newest `glm-*:cloud` visible to the app (live roster + `model_capabilities.json` cloud catalog); pin a model here to override. The builder must always receive a **concrete** model id — the app's `"auto"` is a router sentinel, not a real Ollama model, so `ollama launch claude --model auto` exits "model 'auto' not found"; both `generate()`s resolve `"auto"`/empty → the concrete `builderDefault` before launching (the *runtime* workflow/swarm model may still be `"auto"`). See *AI workflow generator* |
| `WORKFLOW_BUILDER_TIMEOUT_MS` | `180000` | Per-run budget for the sandboxed Claude CLI authoring agent before the builder is killed |
| `WORKFLOW_RUNNER_URL` | _(empty = LOCAL mode)_ | Set in REMOTE mode (production/customer deploy): the app delegates `bwrap … workflow-builder.sh` to the `ROLE=runner` sidecar at this URL (e.g. `http://private-ai-<slug>-runner:3100`). Unset = LOCAL mode = byte-identical to the old in-app bwrap path (the dev/test single-container flow). See *AI workflow generator* + *Deploy a customer*. |
| `WORKFLOW_RUNNER_TOKEN` | _(empty = no auth)_ | Shared Bearer secret the runner requires on `POST /generate` + `GET /canary`. App + runner must agree; `deploy-customer.sh` auto-generates + persists it in the customer `.env`. Empty = internal-network-only trust (the runner never publishes its port). |
| `RUNNER_PORT` | `3100` | The runner sidecar's internal listen port. Never published to the host — the app reaches it over the per-customer Docker network (`private-ai-net-<slug>`). |
| `BWRAP_CANARY` | `fail` (was `warn`) | `fail` = DEFAULT — abort the deploy before either container starts if no bwrap security profile passes the runner canary (surface a bad host immediately). `warn` = opt-in to continue: the app always deploys + the runner deploys best-effort, and AI-workflow/swarm generation returns a clear 503 if bwrap namespaces are unavailable (chat/RAG/auth/routing keep working; Docker marks the runner unhealthy). A broken runner is never deployed silently. The canary targets the RUNNER container, not the app. |
| `BWRAP_PRIVILEGED` | `false` | RUNNER-ONLY (the app is never privileged). Unlocks the full security ladder on the runner. With the flag the ladder runs **broadest-first** so the runner actually lands on `--privileged`: c) `--privileged` (tried first), b) `--security-opt seccomp=unconfined --cap-add SYS_ADMIN`, a) `--security-opt seccomp=unconfined` (narrowest). Without the flag the ladder stops at (a) (least privilege). On Docker Desktop for Mac bwrap still needs `--privileged` (seccomp=unconfined alone gets EPERM mounting `/proc`). |
| `CHAT_GOOGLE_AS_TOOL` | _(not `false`)_ | When not `false`, chat offers `google_calendar_list` / `google_mail_recent` on calendar/mail signal detection so "what's my schedule?" / "read my recent email" route to the live Google tools. Set `false` to disable chat connector offering. See *Chat reachability* |
| `JUDGE_MODEL` | `CLOUD_ROUTER_MODEL` | Model the LLM-as-judge correctness gate (`lib/workflowJudge.js`) runs on. Defaults to the cloud router model; falls back to the local `ROUTER_MODEL` when cloud isn't configured. See *Correctness checkpoint* |
| `JUDGE_TIMEOUT_MS` | `10000` | Per-call budget for the correctness judge before it degrades to amber "judge unavailable" |
| `TRUSTED_CLIENT_CIDRS` | _(empty)_ | Comma-separated CIDRs to allowlist beyond RFC1918 (e.g. Tailscale `100.64.0.0/10`, or the Docker bridge `172.16.0.0/12` for host-admin access to customer containers) |
| `PYTHON_BIN` | `python3` | Python interpreter used to run `chunk_articles.py` for document-attachment text extraction (falls back to `PYTHON` env if set) |
| `SYSTEM_CONTEXT_CHAR_BUDGET` | `60000` | System-message safety valve — when the system prompt alone exceeds this, volatile tail sections are dropped to fit (keeps the stable instruction head) |
| `DREAM_AUTO_ENABLED` | `true` | Phase 5 auto-dream: whether the scheduler is armed at boot. Set `false` to revert to manual-only consolidation |
| `DREAM_INTERVAL_HOURS` | `24` | Minimum hours between automatic dream runs (the interval gate) |
| `DREAM_MIN_NEW_SESSIONS` | `5` | Minimum new chat sessions since the last run before auto-dream fires (the new-session gate) |
| `MEMORY_RECALL_TOP_K` | `5` | Number of long-term memories recalled per turn (cosine top-k against the prompt embedding) |
| `MEMORY_INJECT_BUDGET_TOKENS` | `1500` | Token budget for the injected `<memories>` slice in the user-message tail (chars/4 estimate) |
| `CHAT_TOPIC_RESOLUTION` | `true` | Inline follow-up topic resolution — injects the ongoing conversation topic next to a short referential follow-up so weak models keep the thread across any model selection. Set `false` to opt out |
| `AGENT_RECENT_EXCHANGE_LIMIT` | _(= `RECENT_EXCHANGE_LIMIT`)_ | Number of recent exchanges the agentic workflow runner recalls from the chat log to seed a run's conversation history (scoped to `workflow-<id>`). Defaults to the chat value so agent runs inherit the same continuity depth; set `0` to disable agent continuity entirely (degrade to a fresh `[system, user]` history per run) |
| `MEMORY_DECAY_FLOOR` | `0.05` | Decay floor for normal memories; `risk:critical` memories floor at 0.5 and are never pruned |
| `CONNECTORS_CONFIG_PATH` | `./connectors-config.json` | Google connector **OAuth app setup** — client id/secret, redirect host, enabled read-only scopes, mail day limit (gitignored — holds the OAuth client secret, never `settings.json`) |
| `CONNECTORS_CREDENTIALS_PATH` | `./connectors-credentials.json` | Google connector **user tokens** — access/refresh tokens (gitignored — holds the user's refresh token, never `settings.json`) |
| `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` / `GOOGLE_REDIRECT_HOST` | *(unset)* | Supply the OAuth client once at deploy time (e.g. in `.env`) and the end-user Connect flow is pure click → Google login → approve — **no admin panel interaction required**. `GOOGLE_CALENDAR_ENABLED` / `GOOGLE_MAIL_ENABLED` (default `true`) and `GOOGLE_MAIL_DAY_LIMIT` (default `7`) select the enabled read-only scopes + mail window. The on-disk config file (set via the optional panel) overrides these. |

---

## Architecture

### Architecture & data containment — the invariant

**This is a hard invariant. Always follow it unless a change explicitly notes otherwise.**

- **App (functionality)** lives in the `private-ai` Docker container at `/app`. It is the image: server code, `public/` assets, `lib/`, scripts, skills. Updating the app = rebuilding the image. This **never** touches customer data.
- **`/data` (customer data)** is a separately-mounted volume: chats, workflows, swarms, connectors (config + tokens), agent workspaces + report files, settings, memory, corpora, usage stats, route pins. It **survives image updates and container recreation.** Every writable path env var resolves under `/data` — see `docker-compose.dev.yml` and `scripts/deploy-customer.sh` (`WORKFLOWS_PATH`, `SWARMS_PATH`, `SETTINGS_PATH`, `CONNECTORS_*_PATH`, `AGENTS_DIR`, etc.). **New app features that persist state MUST write under `/data`, never under `/app`.** Anything written under `/app` is wiped on the next image rebuild — that is a customer-data-loss bug, not a deployment convenience.
- **Ollama + SearXNG run on the VM OS**, outside the app container. The container reaches them over the network via `OLLAMA_BASE_URL` / `SEARXNG_URL` (`host.docker.internal` in dev; the VM host in prod). The container never runs inference or a search index itself.
- The app container has **no user auth.** The WireGuard/VPN gate (or LAN-first gate) is the access control — see `docs/VM-INSTALL.md`.

The rename from "Folders" to "Swarms" was also where `SWARMS_PATH` was first wired to `/data/swarms.json` (it had defaulted to `/app/folders.json`, which an image rebuild would have wiped — exactly the containment violation above). A one-time startup migration (`migrateLegacyFolderStore` in `server.js`) moves a legacy `folders.json` → `swarms.json` so existing swarm definitions survive both the rename and the isolation fix.

### Entry point & server

`server.js` is the main orchestrator. It creates the HTTP server, initializes all modules, defines inline routes, and delegates to `routes/` modules. Startup sequence:

1. Open the `better-sqlite3` database (shared singleton passed to modules)
2. Initialize corpus manager, rate limiters (30/min generation, 120/min general)
3. Build the app router via `routes/index.js` — a chain of route modules
4. Start the 60-second scheduled-workflow check interval
5. Recover orphaned jobs

Every request passes through: **CSRF check → security headers → private-client (LAN) check → rate limiting → early `Content-Length` body-cap rejection → body parsing (100 MB limit, env-configurable via `MAX_BODY_BYTES`)**. The LAN gate (`lib/clientAccess.js`, `isPrivateClientAddress` + `TRUSTED_CLIENT_CIDRS`) is the single chokepoint that keeps the app private by default; the early body-cap rejection refuses an oversized upload before it is buffered into memory.

### Route modules (`routes/`)

`routes/index.js` creates one router function that chains modules in order. Each returns `true` if it handled the request, `false` to pass to the next:

- `static.js` — serves `public/` assets and CSS
- `conversations.js` — conversation CRUD
- `health.js` — `/admin/health` endpoint
- `chat.js` — `/ask`, `/api/chat/stream`, `/api/chat/multi`, `/api/chat/image`, `/cancel`
- `dream.js` — dream (memory consolidation) endpoints

Remaining routes (admin, RAG, workflows, skills, artifact serving, etc.) are inline in `server.js`.

### Chat handler factory + chat pipeline

Chat logic lives in a factory: `lib/chatHandlers.js` exports `createChatHandlers(config)`. `server.js` constructs the handler instance by injecting all dependencies (db, paths, module references, the prepared-request function) and passes the handler object (`handleAsk`, `handleAskStream`, `handleAskMulti`, `handleImageChat`, …) into route modules via a context object.

The request-prep brain — `prepareChatRequest`, `buildAutoContextPlan`, `applyAutoContext`, `applyWorkflow` — lives in `lib/chatPipeline.js` (extracted from `server.js`; `server.js` wires the server-local collaborators and runtime paths/limits into the factory). This is the orchestrator that turns a raw user input + flags into a `{ model, finalPrompt, contextPlan, … }` payload ready for Ollama.

### Auto-context pipeline

`buildAutoContextPlan` (in `lib/chatPipeline.js`) detects signals in the user prompt:

- **Writing signals** (LinkedIn, blog) → applies a writing skill
- **Memory signals** ("earlier", "we discussed") → includes conversation history
- **Web signals** ("current", "latest", "news") → triggers web search
- **RAG signals** ("my articles", "my writing") → activates RAG retrieval
- **Weather signals** → fetches weather via wttr.in
- Infers task type, RAG depth, and RAG mode

**Critical routing rule**: web results always take priority over RAG when both are active. RAG becomes background context. Do not break this.

### Model routing chain (priority order)

1. **Explicit model dropdown selection** — always wins (including cloud models; picking a cloud model from the dropdown is itself consent to cloud for that request). The choice is pinned to the conversation (`lib/routePin.js`).
2. **Reused conversation pin** (Auto follow-ups) — the first Auto turn's `{model, taskType, contextPolicy, reasoningPolicy, executionMode}` is pinned to the conversation; materially-identical follow-ups reuse it and **skip routing entirely** (latency win). Re-route only on a genuine shift (task-type change, images/files added or removed, selected-web or RAG toggled, pinned model leaving the live roster) or an explicit re-route. Tools are re-evaluated every turn regardless.
3. **Cloud-LLM router** (preferred Auto brain when `allowCloud` is on) — a large cloud model reasons about each model's tool-calling / reasoning / request shape and emits a strict JSON plan (`lib/cloudRouter.js`): `{model, taskType, difficulty, toolsFormat, contextPolicy, reasoningPolicy, executionMode, confidence, fallbackModel, rationale}`. Mistral Large 3 routes turns with images (it can see what it is routing); GLM 5.2 routes text turns. The plan is **fail-closed validated** (model in live roster; `toolsFormat=native` only for native-capable models; vision tasks to vision models; `confidence ≥ CLOUD_ROUTER_MIN_CONFIDENCE`; selected-web priority preserved); any failure → `model:null` → fallback. The router recommends; the harness decides.
4. **Fixed local 0.5B router** (`qwen2.5:0.5b`, `lib/router.js`) — the fail-safe when the cloud router is disabled (`ROUTER_BACKEND=local`) or failed closed. Roster-driven, de-biased, with per-model hints read from the curated `strengths` arrays in `model_capabilities.json`.
5. **Capability-aware heuristic fallback** (`chooseModelByCapability`) — if a router times out / can't parse / its model is missing: picks the cheapest **installed** model whose `strengths` match the inferred task type (reasoning→reasoning-strength, coding→coding/tool-capable, vision→vision-capable when a photo is attached), instead of a hardcoded taskType→default switch.
6. **Saved model preferences** (3+ wins) override the router choice.
7. **Feedback-based model preference override.**

The cloud router's authority is respected downstream: the reasoning guard and cloud-escalation safety nets skip `cloud_router`, `pin_reused`, and `user_explicit` results so they don't override a decision the router (or the user) already made. Every Auto turn emits one JSON record to the route decision log (`lib/routeLog.js`, `ROUTE_LOG_PATH`, customer-scoped under `/data`): which router ran, what it picked, pin reuse, the fallback path, and the turn's context signals.

### Request shape — who decides vs. who builds (and what needs updating when)

Three terms get conflated; they are deliberately separate layers:

- **Tool-calling** is a *property of a model* — `none` / `prompt` / `native` — declared in `model_capabilities.json` and read by `lib/modelCapabilities.js` (`isNativeToolCalling`, `isToolCapable`, `isVisionCapableModel`). It is an **input**.
- **Shape** is the *form of the request payload* — does it carry Ollama `tools` JSON? does the system prompt carry a text tool-section? what message roles (`tool` vs `user`)? It is the **output/consequence** of the tool-calling capability + whether tools are offered this turn. The vocabulary is `native` / `prompt-tags` / `none` (`lib/modelShape.js`).
- **Adapter** is the *component* that performs the translation canonical-messages → model-specific shape: `lib/modelShape.js` (`buildModelPayload`, `extractNativeToolCalls`). It is the **agent**; shape is its output; tool-calling capability is its input.

The cloud router is **not** the adapter. It is a *shape-aware recommender*. The pipeline is two stages, decoupled on purpose so a wrong/drifting router recommendation can never reach the model unchecked:

1. **`lib/cloudRouter.js` — recommender.** Reasons about each model's tool-calling / reasoning / request-shape abilities and emits a JSON plan that *includes* a `toolsFormat` field (`native` / `prompt-tags` / `none`) plus the model. **It does not build the payload.** "The router recommends; the harness decides."
2. **Fail-closed validation** (`validateCloudRouterPlan`). If the router says `toolsFormat=native` for a model that isn't native-tool-capable, it **downgrades to `prompt-tags`, not null** — the router's shape claim is never trusted unchecked; the capability catalog is the source of truth. Any other validation failure → `model:null` → fallback chain.
3. **`lib/modelShape.js` — adapter / shape-maker.** Takes the validated plan + canonical message array and emits the concrete Ollama payload: native `tools` JSON (and the text tool-section stripped so the model gets no conflicting instructions), or the text tool-section baked in by the prompt builder, or nothing. Shared by both chat (`lib/chatHandlers.js`) and the workflow runner (`lib/agentRunner.js`) so the two paths never diverge.

**Maintenance boundary — what moves per model vs. per protocol.** The adapter is **shape-vocabulary-driven, not model-driven**: `lib/modelShape.js` contains no model-name string checks — every branch keys off the capability catalog. So:

- **New model / model upgrade that fits the existing vocabulary** (none / prompt-tags / native) and speaks Ollama's OpenAI-compatible `/api/chat` + function-schema tools → **no adapter code change.** Add a `model_capabilities.json` entry (`tool_calling` tier, `vision`, `thinking`, `strengths`) via `addOrUpdateCapability` / the admin model sync. A newly-pulled model with no entry still functions via heuristic fallbacks (e.g. `isVisionCapableModel` falls back to name patterns like `llava|gemma|moondream|…`); the entry is needed for *optimal* routing/shaping, not for the model to run.
- **The catalog is the part that moves per model; the adapter moves only when a new provider protocol appears.** `lib/modelShape.js` needs code changes only for: (a) a new **payload shape** beyond `payloadShape: "messages"` / `endpoint: "ollama-chat"` (a provider whose request format isn't Ollama-OpenAI-compatible); (b) a new **tool-schema dialect** beyond OpenAI-function schemas (the header flags this as future work); (c) a new **tool-format tier** beyond `none` / `prompt-tags` / `native`; (d) a new **response wrapping** in `extractNativeToolCalls` (it already handles `{name,arguments}` and `{function:{name,arguments}}`, plus string-vs-object args). These are architectural/rare, not per-model-per-upgrade.

**Agentic workflow shape + same-model fallback.** The workflow runner (`lib/agentRunner.js`) folds onto the same `modelShape.js` adapter: native-tool-capable workflow models (e.g. `glm-5.2:cloud` on a workflow card) drive the loop via Ollama `/api/chat` native `tool_calls` JSON (tool results return as `role:"tool"` messages); prompt-tag / tool-less models keep the flat `/api/generate` text-tag + regex-parse path, byte-identical. The branch is gated on `isNativeToolCalling(model)` + offered tools + `AGENT_NATIVE_TOOLS` (default on; `false` forces every workflow back to the text-tag path). If a native `/api/chat` call fails (e.g. a cloud bridge rejects the `tools` field), the runner retries the **same** model via the prompt-tag `/api/generate` path before walking the model fallback chain — audited as `native_to_prompttag_fallback` — so a cloud model runs an agentic workflow "within reason" even when its native tool channel is unavailable. Workflow fallback chains, goal/instructions, and card model selection are unchanged.

**Selected-web priority invariant.** When selected web search results are active, they sit **above** RAG context and are the primary source context; RAG is supporting/background. This holds in both flat and chat (structured-message) modes — `lib/promptBuilder.js` emits the web context before the RAG context, and the cloud router's `contextPolicy` encodes it (`web_priority` / mixed-with-web-priority); the fail-closed validator rejects a plan that has both selected-web and RAG active but does not preserve web priority. No routing or prompt-shape change may reverse this. (On a *follow-up* turn, the conversation history becomes the primary referent and selected web results are demoted to supporting-for-current/external-facts — that is the one documented exception, and it does not reverse web-over-RAG ordering.)

The model list comes dynamically from Ollama. Avoid hardcoding models unless necessary. The fallback is driven by `lib/router.js` (`chooseModelByCapability`) + `lib/modelCapabilities.js` (`getModelCapability`, `isVisionCapableModel`); when a photo is attached and the user is on Auto, the fallback's `requireVision` flag lands on a vision-capable model directly so the image isn't silently routed to a text model (the chatHandlers image-review path remains the safety net — see *Image artifact handling*).

**Dynamic dropdown + general-chat routing (WS5).** The model dropdown refreshes itself while the page is open: `loadModels` runs on a 30s interval, on `visibilitychange`, and after an admin model sync — so a model pulled or removed in another tab shows up without a full reload. (The `/models` endpoint is uncached and reads the live Ollama roster; it deliberately does **not** route through the 60s-cached `getAvailableModels`.) General chat routes to `qwen3.6:35b` (`DEFAULT_GENERAL_MODEL`), resolved dynamically by `lib/fleetResolve.js` (role `local_execution`) over the live roster + capability cards, not the smaller `gemma4`: `TASK_STRENGTHS.general` is `["general"]` only (the `fast` latency trait was dropped as a quality dimension), so the primary local model and `gemma4` tie on the `general` strength and the `preferredFallback` tiebreak picks the primary local model as the larger/better general model. `DEFAULT_CODING_MODEL` repoints to the control-plane router (`glm-5.2:cloud`) when cloud is allowed and the turn isn't token-heavy; there is no dedicated local coder in the fleet, so token-heavy coding stays local on `qwen3.6:35b`. The routing decision is emitted as a `model_routed` event and surfaced in the context panel's routing trace by default (no need to toggle showFullContext).

### Production routing + the dynamic fleet (nothing static)

The routing/artifact design is rebuilt around the **actual model fleet**, with one overriding constraint: **nothing is static.** The fleet IDs below are the **base-install seed**, not a hardcode. Model selection stays dynamic — adding or removing a model (e.g. a future `glm-5.3:cloud`) is a pull + a router-authored capability card, with **no code change**. The adapter is a router-authored artifact built **once** per model and regenerated only when its tool-calling / vision / endpoint shape change.

**The base fleet** (seed; `:cloud` / `-cloud` suffix convention kept — swapping it would touch `isCloudModelName` + every constant for no benefit):

| Model | Role tag (`routing_role`) | Domain |
|-------|--------------------------|--------|
| `qwen3.6:35b` | `local_execution` | Primary local executor — chat, fast reasoning, simple tool tasks, internal summaries, local-first customer work. Native tool calling + thinking. No vision. |
| `gemma4:latest` | `local_vision` | Local multimodal — the **smaller** gemma (M2 / dev / CPU-only boxes where the larger gemma won't fit). **Never co-loaded with `qwen3.6:35b` under memory pressure** — the gateway overflows gemma4 vision to the cloud image router instead of OOM-ing. |
| `gemma3:27b` | `local_vision` | Local multimodal — the **larger** gemma (the GPU VM per `models.yml`). Same role as `gemma4:latest` but bigger/sharper; the live-roster scan picks whichever vision model is actually pulled (`gemma3:27b` on the VM, `gemma4:latest` on the M2). Overflows to the cloud image router under memory pressure. |
| `glm-5.2:cloud` | `control_plane` | The **control plane** — routing, workflow planning, tool selection, internal-vs-external tool calls, **non-vision** card/adapter authoring, fallback + continuity, structured-artifact schema, code-plan patch shape. Native tool calling + thinking. **No vision.** |
| `mistral-large-3:675b-cloud` | `cloud_synthesis` + `vision:true` | Premium synthesis (polished customer-facing text, proposals, summaries) **AND the image router** — owns image-turn routing + **vision** card/adapter authoring + the generator-attachment cloud describer. Native tool calling + vision. |
| `deepseek-v4-pro:cloud` | `cloud_reasoning` | Deep reasoning — long-context, hard logic, complex workflow validation (**LLM-as-judge**), second-opinion, repo-scale, math/eng, large-doc/failure analysis. Native tool calling + thinking. No vision. |
| `qwen2.5:0.5b` | `infra_router` | **Infra-only** fail-closed local router fallback — used only when the cloud router is unavailable; never an executor (filtered out of the executor pool). |
| `nomic-embed-text` | `embedding` | RAG / semantic recall only. |
| `x/z-image-turbo:latest` | `image_generation` | `/image` generation (emits images, cannot read them). |

**Removed from the fleet** (do not route to / reference): `qwen3:14b`, `qwen3-coder:30b`, `deepseek-r1:8b`, `qwen3.5:cloud`, `qwen3.6:27b`, `glm-5.1:cloud`, bare `mistral:cloud`, `claude-sonnet-4-6:cloud`. (DeepSeek Flash is deliberately **not** added unless usage cost becomes a problem.) A removed model carries `"removed": true` in the **repo** `model_capabilities.json` (the file that ships with the image). The agentic resolver (`lib/agentRunner.js:resolveAgentModel` → `lib/modelCapabilities.js:isRemovedModel`) honors that flag by checking **both** the runtime `/data/model_capabilities.json` **and** the repo caps — so the fleet-removal decision propagates on every pull even when `/data` caps is stale (see "Agentic model resolution" below). A removed model is never treated as tool-capable and never enters the `auto`/fallback pool, so a stale pin to it shifts to a live in-fleet model instead of running an unloaded model.

**Dynamic resolution (`lib/fleetResolve.js`).** Role-tagged resolvers run over the live roster + `model_capabilities.json` + the admin router override (Phase 5a, persisted to `/data`). Order of precedence in each resolver: **admin override → live-roster autoselect → seed**. The seed is the fallback, never the decision.

- `resolvePrimaryLocalModel()` → seed `qwen3.6:35b` (role `local_execution`). Feeds `DEFAULT_GENERAL_MODEL`, `DEFAULT_CODING_MODEL`, `DEFAULT_REASONING_MODEL`, `DEFAULT_TOOL_MODEL`, `CHAT_SUMMARY_MODEL` (background summary = local/cheap tier).
- `resolveControlPlaneRouter()` → admin-selected control-plane router → else **newest live `glm-*:cloud`** (role `control_plane`) → seed `glm-5.2:cloud`. The "newest glm" autoselect is what makes a future `glm-5.3:cloud` swap in by pull. Feeds `CLOUD_ROUTER_MODEL`, `WORKFLOW_BUILDER_MODEL`, `CLOUD_CODING_MODEL`, `CLOUD_TOOL_REASONING_MODEL`.
- `resolveImageRouter()` → admin-selected image router → else best live **vision-capable** `:cloud`/`-cloud` model (role `cloud_synthesis` + `vision:true`) → seed `mistral-large-3:675b-cloud`. Feeds `CLOUD_ROUTER_VISION_MODEL` (the vision router + image describer + image-card/adapter authoring).
- `resolveCloudReasoningModel()` → role `cloud_reasoning`; seed `deepseek-v4-pro:cloud`. Feeds `CLOUD_REASONING_MODEL` + `JUDGE_MODEL`.
- `resolveCloudSynthesisModel()` → polished text artifacts; seed `mistral-large-3:675b-cloud` (same model as the image router by default, but a distinct role so a future dedicated synthesis model can be swapped in independently).
- `resolveLocalVisionModel()` → existing `imageReview.resolveVisionModel`; seed `gemma4:latest`, but the live-roster scan picks whichever vision model is actually pulled — `gemma3:27b` on the GPU VM (per `models.yml`), `gemma4:latest` on the M2 / local dev.

`ROUTER_MODEL` stays `qwen2.5:0.5b` as the infra-only fail-closed fallback (preserves Auto-mode resilience; never an executor).

**Two router paths by domain (the key design).** Research-confirmed: `mistral-large-3` is the cloud vision router *because* it has `vision:true` in `model_capabilities.json`, consumed at `lib/cloudRouter.js` and `lib/generatorAttachments.js`; `glm-5.2` has no `vision` flag. So:

- **Control-plane router** (default `glm-5.2:cloud`) — owns routing, workflow planning, tool selection, fallback, continuity, AND authors capability cards + adapters for the **non-vision** domains (text / structured / code / spreadsheet / pdf-doc planning). Because glm-5.2 has no vision, it must **not** own image shape/adapter decisions. In the cloud-router plan chain, **Mistral Large 3 routes turns with images** (it can see what it is routing); **GLM 5.2 routes text turns.**
- **Image / vision router** (default `mistral-large-3:675b-cloud`) — owns image-turn routing and authors the **vision-related** card fields + adapters for vision-capable models. When an image is attached or mentioned, the image router builds the shape/adapter for that path; glm-5.2 does the rest.

Both default to the "smartest available" model for their domain but are **admin-changeable** (Phase 5a) so a newly-loaded better model swaps in without code.

**Router-driven card + adapter authoring, split by domain.** A capability card (`{strengths, tool_calling, vision, thinking, context_window, routing_role, notes}`, strict JSON, validated) is authored by a router from `/api/show` facts, with the **authoring router chosen by domain**: non-vision fields + non-vision models → `resolveControlPlaneRouter()` (glm-5.2); vision fields + vision-capable models → `resolveImageRouter()` (mistral). The richer per-model adapter (`{toolCallingFormat, toolSchemaShape, requestShape, contextInjectionStrategy, kvCacheStrategy, latencyNotes}`) is cached as one JSON file per model under `adapters/<model>.adapter.json`; `getShapeProfile()` reads the cached adapter first, falling back to the on-demand capability-driven derivation only if the file is absent. **Built once per model**, invalidated only when the card's `tool_calling` / `vision` / endpoint shape change. The fleet's five executor adapters (qwen3.6:35b, gemma4, glm-5.2, mistral-large-3, deepseek-v4-pro) are authored once, domain-split (glm-5.2 for the four non-vision; mistral for gemma4's vision adapter). `gemma3:27b` (the VM's larger vision model) gets its own mistral-authored vision adapter the same way at startup.

**The agentic "nothing static" mechanism for NEW models.** When a model appears in the roster with no adapter, a **one-time agentic run by glm-5.2 + Claude CLI** authors the adapter from hard research (the model's docs, HuggingFace card, `/api/show`) — reusing the **exact bwrap-sandboxed pattern already built for workflows/swarms** (`lib/bwrapSandbox.js` + `scripts/workflow-builder.sh` + the `ROLE=runner` sidecar), via a builder-script variant `scripts/adapter-builder.sh`. Triggered on first spawn / cache-miss (the "one-time run"), or manually from the operator CLI. **The admin UI does NOT trigger this** — it's the agentic builder + operator CLI, same trust boundary as workflow generation (a model never writes files unvalidated; the adapter/card is validated before saving).

**Auto-authored model adapters (startup pass).** The one-time agentic authoring run above is now **automated** so a newly-pulled model gets a card/adapter with no manual CLI step. At **container STARTUP** — right after the model sync — the app scans the live roster (local Ollama models **and** the catalog's cloud models) and authors any model that is **missing** an adapter or whose adapter file is **stale** (mtime older than `ADAPTER_AUTO_AUTHOR_MAX_AGE_DAYS`, default **30**; adapters carry no internal timestamp so file mtime is the freshness signal). The domain split is the same as manual authoring: **GLM-5.2 authors non-vision models; the image router (mistral-large-3) authors vision models**, and the authoring router is **excluded from authoring its own adapter** (GLM-5.2 never authors GLM-5.2). It runs **sequentially** (one authoring router behind a GPU → no concurrency) and **fail-open per model** — a failure for one model is logged and skipped, the next still runs; if bwrap (LOCAL dev) or the runner sidecar (REMOTE VM deploy) isn't ready, the whole pass is skipped and never blocks boot. This runs at **startup, not `docker build` time**, because authoring needs the live Ollama roster + `/api/show` + a reachable router + bwrap — none of which exist during `docker build`. A rebuild recreates the container, so startup is exactly when your **push → pull on the VM → rebuild** cycle lands: the scan authors new/stale models automatically with no extra step. Agentic-built adapters persist at `ADAPTERS_DIR=/data/adapters` (writable, survives an image rebuild, wins over the committed repo `adapters/` on lookup). Set `ADAPTER_AUTO_AUTHOR=0` to disable. The startup pass is implemented in `lib/adapterAuthorStartup.js` (`planAdapterAuthoring` + `runAdapterAuthoring`) and wired in `server.js` (`authorAdaptersOnStartup`); the `ROLE=runner` sidecar can run the adapter builder over HTTP (its `/generate` allowlists `scriptPath` to `workflow-builder.sh` / `adapter-builder.sh` under `/app/scripts/` and forwards only the `ADAPTER_*` extra-env keys).

**Retry a single failed model (don't rerun the whole pass).** The pass is fail-open per model — one failure does **not** block the others, and you retry just the failing model, not the whole scan: `scripts/build-adapters.sh --customer <slug> --model <name>` (targets the **runner** container, the only privileged one, and clears `WORKFLOW_RUNNER_URL` so the build runs in-process; `--dev` for the compose container, bare host node otherwise). A failed build prints the model's **sandbox + logs path** so you can inspect it. Vision/multimodal authoring uses a longer default timeout (`ADAPTER_BUILDER_TIMEOUT_MS`, default 240000; `ADAPTER_BUILDER_VISION_TIMEOUT_MS`, default 480000 for vision) — raise either if a slow router trips it. `--missing-only` authors **only** models with no adapter file (never re-authors a stale one); `--all` re-authors everything present (except the authoring router). Precedence: `--all` > `--missing-only` > `--max-age-days N` > default (missing + >30 days); `--all`+`--missing-only` and `--missing-only`+`--max-age-days` are mutually exclusive.

**Dynamic upgrade proof.** (a) Pull `glm-5.3:cloud` → the agentic builder runs once → writes its card + adapter → `resolveControlPlaneRouter()` autoselects the newest `glm-*:cloud` → router / builder / coding-plan move to glm-5.3 with **no code change**. (b) Pull a new vision model → the image-router-guided builder writes its card (vision fields) + vision adapter → the admin image-router dropdown lists it → selecting it re-points image turns with **no code change**. (c) Remove a model from the roster → the live-roster filter (`lib/agentRunner.js`) prevents it from being chosen; mark it `"removed": true` in the repo caps and even a stale `/data` caps + a stale workflow pin shift to a live in-fleet model (see "Agentic model resolution" below).

**Agentic model resolution (`lib/agentRunner.js:resolveAgentModel`).** Workflows + swarm members resolve their per-run model through this function (not a live router call — the app applies the same fleet truth the control-plane router would). For `"auto"` it picks the first **live, tool-capable, in-fleet** local model (native > prompt-tag; `qwen3.6:35b`), falling back to a live cloud tool-calling model only when `allowCloud` is on. For an explicit pin it honors the pin **iff** it is live and tool-capable; otherwise it shifts: a dead pin (not in the live roster) or a removed/non-tool-capable pin shifts to a live tool-capable fallback rather than running an unloaded model and failing. Two freshness guarantees: (1) `runAgenticWorkflow` re-probes Ollama for the live roster before resolving, so a model pulled since the last `/admin/status` poll is visible to `auto` immediately (the roster is otherwise a startup + `/admin/status` cached snapshot); (2) every shift emits a loud `model_shifted` event `{requested, used}` so the operator can see the router kept up with the live fleet. Sovereignty is enforced at this layer too: a cloud pin under a local-only posture shifts to local; `LOCAL_ONLY_MODE` is the global kill switch. The workflow workbench and the swarm screen each carry their own **Cloud** toggle (the chat-screen cloud toggle is a different view and is not present on either), so a standalone or swarm `auto` run can opt into cloud tool-calling fallback when the local model isn't pulled.

**Admin "Router" control (Phase 5a).** The admin "Model Routing" card becomes **editable** with two model selectors — the two router paths. This is a **data/config** selection (which loaded model fills each role), persisted to the existing admin settings store under `/data` (customer state, never in the image); `resolveControlPlaneRouter()` / `resolveImageRouter()` read the override first.

- **Control-plane router selector** — default `glm-5.2:cloud` (autoselected newest `glm-*:cloud`); lists every live model with role `control_plane` (or any live cloud model). Changing it re-points routing / workflow-planning / tool-selection / coding-plan / non-vision card-authoring to the chosen model on the next turn.
- **Image router selector** — default `mistral-large-3:675b-cloud`; lists every live **vision-capable** model (`vision:true`, filtered via `isVisionCapableModel`) so only models that can actually see images are offered. Changing it re-points image-turn routing + vision card/adapter authoring + the generator-attachment describer.
- Both surface in `GET /admin/status` `routing` block (the human rules string names the live selections); both persist across restart (read back from `/data`).
- **Explicitly NOT included: an "update model shapes / JS" button.** Code-level adapter / JS changes for a genuinely new architecture are handled by the operator in Claude CLI when updates happen — the admin control never writes code or arbitrary files (only the settings file under `/data`), so admin doesn't need lockdown for filesystem safety. The capability-edit endpoint (`PUT /admin/capabilities/<model>`) and `POST /admin/sync-models` remain available server-side for the operator/CLI but are **not** exposed as destructive UI buttons.

**Artifact planner + per-category routing (`lib/artifactPlanner.js`).** The control-plane router (glm-5.2) produces an artifact plan `{type, format, requiredInputs, sourceContext, tools, local|cloud|tool, approvalRequired, executorModel}` for a request — **except image artifacts, whose plan is produced by the image router** (mistral). Folded into the workflow generator (`buildPromptText` + `SCHEMA_FIELDS`), the swarm generator (`SWARM_SCHEMA_FIELDS` + `buildSwarmPromptText`), and the chat `create_document` tool. Per-category executor routing (all via the dynamic resolvers, never hardcoded):

1. **Text** (proposals, SOWs, LinkedIn, strategy, recaps, sales collateral, distributable memos): polished / customer-facing → `resolveCloudSynthesisModel()` (mistral-large-3); drafts / internal notes / rough summaries → `resolvePrimaryLocalModel()` (qwen3.6:35b).
2. **Structured** (workflow JSON, model cards, routing configs, extraction schemas, tool manifests, eval rubrics, adapter files): `resolveControlPlaneRouter()` (glm-5.2) for schema; **validated with deterministic code** before saving (reuse `validateAgainstSchema` + the `deliver` tool).
3. **Code**: glm-5.2 plans the patch shape; `resolveCloudReasoningModel()` (deepseek-v4-pro) for hard reasoning / repo-wide; **tools write the files** (`file_write`); never trust model text alone — keep validation / diff / rollback.
4. **Image** (planned by the image router, not glm-5.2): existing pipeline **not** bypassed (`imageArtifacts`, `imageRouting`, `imageReview`); `resolveLocalVisionModel()` (gemma3:27b on the VM / gemma4:latest on the M2 — picked from the live roster) for local understanding; `resolveImageRouter()` (mistral) for cloud vision routing / review / polish — the image router both plans this category and reviews output. `generatorAttachments.pickVisionModel` prefers the image router.
5. **Spreadsheet / table**: glm-5.2 schema + extraction logic; **deterministic code** creates the file (`scripts/make_sheet.py` via the Node→Python bridge; `openpyxl` already a dep); mistral-large for the written explanation around it.
6. **PDF / doc**: glm-5.2 plans structure; mistral-large polished language; **deterministic tools generate the actual file** (`scripts/make_document.py` — `python-docx` for `.docx`, `markdown` + `xhtml2pdf` for `.pdf`); never trust model text alone for final file structure.
7. **Selected-web-over-RAG invariant preserved**: when selected web results are active they sit above RAG and are the primary source; RAG is supporting/background. No artifact-routing change may reverse this.

**Artifact UI surfaces (Phase 5).**
- **Swarm per-member `.md` + in-app modal** — `runSwarm` auto-writes each member's `result` as `<workspace>/<member>.md` when the member didn't `file_write` (`ensureMemberReportFile`); `member_results[].files` is always ≥1; the client renders a selectable member list → in-app formatted modal (no new-tab raw markdown). Member-report links are collapsible dropdowns that lazy-load + render each `.md` inline.
- **Current-run artifacts panel** — collapsible right column in the Workflows/Swarms views, populated **client-side** from `run.steps[].toolCalls[].file_write` (workflow) + `member_results[].files` (swarm) via `lib/runArtifacts.js` `extractRunArtifacts` (pure, sandboxed file_write-path extractor; `VIEWABLE_EXTS = {.md,.txt,.json,.csv,.html,.pdf,.docx}`; `reportOnly` for `.md`-only member reports; drops paths escaping the agents dir). View (`.md`/`.txt`/`.html` via `renderMarkdown`, `.pdf` via `<iframe>`, `.docx` via `?as=html`) + Download.
- **Chat document export** — the `create_document` tool → `artifactPlanner` (glm-5.2 plan) → text gen routed (mistral polished / qwen3.6 draft) → deterministic `scripts/make_document.py` writer → `lib/docArtifacts.js` (mirror of `lib/imageArtifacts.js`) → `GET /api/document/:id` (Content-Disposition, LAN-gated) → `data.documents` meta → chat document card UI (View modal + Download). `create_document` is in `buildOfferedTools` + the `_executeChatToolCall` allowlist.

**New / widened routes.**
- `GET /api/document/:id` — serves a generated chat document (inline by default; `?download=1` → `Content-Disposition: attachment`; LAN-gated; reconstructs from `<documentsDir>/<id>.<ext>` + `.meta.json` sidecar).
- `/admin/agents/file` (widened) — safe-extension allowlist (`.md,.txt,.json,.csv,.html,.pdf,.docx`), MIME map, `?download=1` → attachment, `?as=html` → mammoth render for `.docx`; `requireAdminClient` + `isPathInside` containment (the throwing `sandboxEnsureInsideDir` was a real crash-on-traversal bug here — fixed to the non-throwing boolean wrapper so traversal returns 403 instead of an unhandled rejection).
- `PUT /admin/settings` (extended) — persists the two router selections (`controlPlaneRouter`, `imageRouter`) under `/data`.
- `GET /admin/status` (extended) — surfaces both live router selections in the `routing` block; the human rules string names them.

**New deps:** `markdown` + `xhtml2pdf` (Python, for `.pdf` generation in `scripts/make_document.py`); `python-docx` for `.docx`. (`mammoth` + `pdf-parse` were already Node deps for attachment extraction.)

**Gateway latency + memory rules (Phase 4).**
- **GPU queue / inference lock** — a per-model semaphore with `MAX_LOCAL_CONCURRENT` held around `forwardRequest`. Previously `queueTracker` only counted; nothing serialized, so a chat turn + a swarm + a dream could all hammer Ollama concurrently. Now they queue per model.
- **Cloud fallback on failure** — on upstream failure / OOM / timeout the gateway retries against the cloud bridge via `OVERFLOW_MAP` with `reason: upstream_failure|upstream_oom|upstream_timeout`, plus a gateway upstream timeout (previously `signal: null`). **Immediate** — queue only for safe local contention, not failure states.
- **Proactive co-residence guard** — `overflow.js` `decideOverflow` uses `memoryMonitor` `/api/ps` residency: if the requested model + a resident model exceeds the VRAM budget, or `qwen3.6` + `gemma4`/`gemma3:27b` would co-reside unsafely, overflow that vision model → `mistral-large-3:675b-cloud` instead of attempting an OOM-ing load.
- **`VRAM_TOTAL_GB` default `24` → `48`** (48 GB budget).
- **`OVERFLOW_MAP` enabled by default** — the stock deploy shipped it empty, so cloud fallback never fired. Now it maps local → cloud by role (`gemma4:latest` and `gemma3:27b` → `mistral-large-3:675b-cloud`; `*` → `glm-5.2:cloud`).
- **Latency tiers** — a `tier` field on the request (`interactive` = chat, `deliberate` = swarm, `background` = dream / summary) drives gateway queue priority + overflow eagerness, and app model choice: interactive → local-first with immediate cloud fallback; deliberate → allow glm planning + cloud execution; background → cheapest that clears the bar (`resolvePrimaryLocalModel`).

### Prompt optimization ("Don't Optimize")

`lib/promptOptimizer.js` uses the small router model to rewrite the user's prompt for clarity/token-efficiency before the main model sees it (Principle 3 in practice). Fail-safe: returns the original on any error/timeout/no-op. Default is optimization **on** (the "Don't Optimize" checkbox unchecked); checking it sends the prompt exactly as typed. Gated on `ROUTER_ENABLED`. Log records preserve the original `prompt` plus the `optimized_prompt` that was actually sent.

### Chat fluidity — follow-ups, reasoning routing, error recovery

Seven targeted fixes so a multi-turn conversation flows like GPT/Claude instead of losing the thread on follow-ups, opinion/synthesis turns, and recoveries. All preserve Auto model mode, dynamic Ollama model loading, and the opt-in `allowCloud` toggle; no user auth, no public exposure.

1. **Follow-up referent resolution + web-signal gating** (`lib/chatPipeline.js`). `isConversationalFollowUp(prompt, recentRecords)` flags a turn as a follow-up when there's history and the prompt is short (≤6 words) or carries a pronoun/recovery/opinion phrase ("it", "what happened", "what do you think", "put it together", "does it", "tell me more"). When it is a follow-up, the recovery subset of the auto-context web signals (notably `what happened`) is suppressed so a conversational "What happened?" after a failed turn is **not** turned into a junk concatenated web query that retargets the conversation onto unrelated results. The `web_search` *tool* is still offered, so the model can still search when it genuinely needs to. `buildContextAwareSearchQuery` (the web-search hint builder, unchanged) only runs when a fresh-web signal survives the gate.

2. **Don't pin web results as the referent on follow-ups** (`lib/promptBuilder.js`). The flat-mode source-priority rules and the "Selected web search results" block now take a `hasRecentHistory` flag. On a follow-up turn the conversation history is the primary source and web results are demoted to *supporting for current/external facts only*; on an opener turn the existing behavior (web primary for fresh factual queries) is preserved so selected web-result routing still works as documented.

3. **Route opinion/synthesis/recovery to a real model, not gemma4** (`lib/router.js` + `lib/chatPipeline.js`). `detectReasoningSignals(prompt)` flags "what do you think", "what happened", "does it hit on", "is that right", "analyze/compare/synthesize/evaluate", "trade-offs", etc. The router prompt now steers such turns to a live reasoning-strength model (resolved by `pickExampleModel` — `qwen3.6:35b` on the base fleet) as `<model>|reasoning|moderate` and warns the tiny router not to pick a fast/small model for them. A post-router guard in `prepareChatRequest` overrides any fast-only chosen model (no `reasoning`/`math`/`logic` strength) up to `DEFAULT_GENERAL_MODEL` (`qwen3.6:35b`, resolved dynamically by `lib/fleetResolve.js`) and promotes `taskType` to `reasoning`, recording `fallbackReason: "reasoning_signal_overrode_fast_model"`. Explicit user model picks are never overridden; Auto mode is preserved. This closes the "simple general → gemma4" drop.

4. **Tighten skill matching** (`server.js`). `findMatchingSkillSummaries` now matches keywords on **word boundaries** (`\bkeyword(?:s|es|ed|ing|d)?\b`) instead of bare `text.includes(keyword)`, and the stopword set drops generic words that survived the >3-char filter (`need`, `using`, `latest`, `according`, `templates`, `format(s/ting)`). This kills the class of substring false positives where "format" matched inside "information" and injected the full slide-formatting skill body on an unrelated prompt; a skill now needs a content-bearing keyword (e.g. "slide") to match. `david-writing` remains the fallback for writing task types.

5. **Error-recovery is self-explanatory.** Errored chat turns are now persisted with `conversationId` + `prompt` (previously only `{timestamp, error, request_id}`) so they're tied to the conversation. `lib/store.js` gains `readMostRecentRawRecord(conversationId)` (both JSONL + SQLite), which reads the most recent record **including** errored turns that `isVisibleChatRecord` filters out of the visible recent-context window. In `prepareChatRequest`, if the immediately-prior turn for the conversation errored, a `[Note: the previous request failed — <reason>…]` annotation is injected into the user-message tail so a "What happened?" follow-up gets a contextual answer instead of "could you clarify?". The UI (`public/app.js`) gains a one-click **Retry** button on every errored assistant bubble (reuses `regenerateLastUserMessage()` — no new endpoint); previously the only recovery affordance was the Regenerate button on a prior *successful* turn.

6. **Cloud reasoning escalation (opt-in).** When `allowCloud` is on **and** a cloud reasoning model is live in the roster, a genuinely hard turn (`detectReasoningSignals` hit, `taskType === "reasoning"`, or router `difficulty === "complex"`) is promoted to `CLOUD_REASONING_MODEL` (default `glm-5.2:cloud`, env-overridable), recording `fallbackReason: "escalated_to_cloud_reasoning"`. No escalation when the cloud toggle is off — cloud stays explicitly opt-in. Falls back silently to the local `DEFAULT_GENERAL_MODEL` when the configured cloud model isn't installed, so this never routes to a missing model. Explicit user picks are untouched. General chat still defaults to `qwen3.6:35b` (unchanged).

7. **Inline topic resolution for any model selection** (`lib/promptBuilder.js`). Fixes the regression where a short referential follow-up lost the thread *even though the prior exchange was already injected*. The pipeline always attaches the prior-exchange transcript (`buildRecentContext` / `buildRecentMessages`) plus a "resolve references against the prior exchange, never ask the user to restate" preamble — but a small/weak model (e.g. `gemma4`) can skim only the latest user message, ignore that preamble, and answer "what topic — weather?" for a follow-up like "Is there any very recent data available" after a Jill Biden exchange. `buildTopicResolutionNote(prompt, recentRecords)` now resolves the referent **server-side** and injects the ongoing topic **inline** in the user request (both flat `buildFinalPrompt` and structured `buildChatMessages`), right next to the request text, so the topic survives even when the model ignores the standalone preamble. Conservative gate: fires only when the turn reads like a continuation (≤8 words or an anaphora/recovery word) AND there is recent history; clear new-topic openers (`Tell me a joke`, `Write a poem about…`, `weather in <place>`) are skipped so a brand-new request isn't retargeted onto the prior topic, and the note is conditionally phrased ("if this is a genuinely new, unrelated request, ignore this note") as a second safety. Opt out with `CHAT_TOPIC_RESOLUTION=false`. This is what makes continuity hold across **any** model the router selects — the topic is in the request itself, not only in context the model might not read.

8. **Clear-on-send + message queue** (`public/app.js`). Previously the input box held your text until the model finished thinking, and a second send was silently dropped while a run was in flight. Now `send()` clears the input box **immediately** on click/Enter (the text is captured first, then the box empties and the message appears in the chat above when its turn runs), and a send that arrives while a run is in flight is **queued** (`pendingQueue`) instead of dropped — a `#queueBadge` next to the Send button shows the queued count. The queue drains **serially** from the run's `finally`: only one request is ever live per conversation, so the server's per-conversation 409 single-flight lock is never tripped (no server change). The queued message's prompt + attachments are captured by reference at send time (the live `FileList` is emptied by the clear), so a queued follow-up carries its files through to its turn. Multi-model comparison and `/image` stay single-flight (not queued); Cancel clears the queue (cancel = stop, not just the current run). The Send button stays enabled while running so you can queue; only Cancel is gated on the running state.

9. **Weather tool invoked in chat** (`lib/chatPipeline.js` + `lib/promptBuilder.js`). Asking "what's the weather?" in chat used to silently pre-fetch weather as context text (or silently skip with no location named) — the `weather_lookup` tool never *fired*, even though it fires in workflows. Now chat offers `weather_lookup` as a tool when the prompt mentions weather (`CHAT_WEATHER_AS_TOOL`, default on — parity with the workflow path's `withEffectiveTools` auto-add), so the model **invokes it** (visible call) instead of reading pre-fetched context. When the user doesn't name a location, the planner assumes the **last weather location used in the conversation** (scanned most-recent-first from recent records), else `DEFAULT_WEATHER_LOCATION` (default `Denver, Colorado`, the same fallback the workflow path uses), and injects a volatile `weather-tool` note telling the model to call the tool with the assumed location — and to ask the user for a different city and call it again if they want one. The note is a per-turn **volatile** section (user tail), so the cached system prefix stays byte-stable (KV-cache hot). The chat tool-execution guard (`lib/chatHandlers.js`) already dispatches `weather_lookup` → `lookupWeather` once it's in `offeredTools`; the existing model-capability reroute ensures a tool-capable model handles the turn. Set `CHAT_WEATHER_AS_TOOL=false` to keep the legacy silent pre-fetch-as-context behavior.

#### Continuity layers — `lib/continuity.js`

Continuity is now a single named seam, `buildContinuityPrefix(input)`, composed of six explicit layers and shared by **both** the chat path and the agentic workflow runner, so the topic survives any model selection on either path (the agentic gap that let a workflow "forget" the prior run's thread is now closed):

- **L0 source-of-truth store** — `lib/store.js`; read via `readConversationRecent(chatLogPath, conversationId, limit)` only. Continuity is scoped to `conversationId` (chat) or `"workflow-<id>"` (agent), so each workflow run thread is its own conversation in the chat log.
- **L1 history recall** — `recentRecords` + `hasHistory`.
- **L2 structured messages** — `buildRecentMessages(recentRecords)` → `[{role,content}]` (the structured chat path + agent first-user seeding both consume this).
- **L3 flat transcript** — `buildRecentContext(recentRecords)` → "Prior exchange N" blocks (the flat `/api/generate` path consumes this).
- **L4 inline topic resolution** — `buildTopicResolutionNote(prompt, recentRecords)`; honors `CHAT_TOPIC_RESOLUTION=false`; user-tail only (KV-cache invariant — the topic note never enters the cached system prefix).
- **L5 cross-model handoff invariant** — model selection mutates `routerResult.model` only, never `recentRecords`; the facade is read once per turn from `conversationId`, so switching Auto → gemma4 → glm-5.2:cloud mid-conversation yields byte-identical history records.
- **L6 verification** — the `testGroup("Continuity (all models)")` cases in `test/unit.js` (cross-model-switch deep-equal, byte-identical chat structured/flat output before vs after the facade, fail-safe throw, KV-cache invariant, no-`conversationId`).

The facade is fail-safe: on any throw it returns the empty sentinel `{recentRecords:[],recentMessages:[],recentContext:"",topicNote:"",hasHistory:false}` and never propagates. Records are treated read-only — the facade passes the same `recentRecords` ref to the existing builders, so chat output is byte-identical to the pre-facade pipeline (proven by A6.6/A6.7). The chat path passes `fallbackLegacy:true` so the no-`conversationId` legacy path (`readRecentExchanges`) still works; the agent path always has `workflow-<id>`. Agent continuity depth is tuned by `AGENT_RECENT_EXCHANGE_LIMIT` (default = chat's `RECENT_EXCHANGE_LIMIT`; `0` disables).

#### Workflow output modes

A workflow can now declare its deliverable so the run result **is** the deliverable, not the model's process narrative. Set `outputMode` on the workflow object:

- **`conversation`** (default, unchanged) — `run.result` is the model's final message text (sliced to 10 000 chars). Byte-identical to the pre-existing behavior; the regression guard in `test/unit.js` proves it.
- **`file`** — deterministic, works with **any** model. After the agent loop completes, the runner reads `<workspaceDir>/<outputFile>` via the sandboxed workspace reader (paths constrained inside the workspace by `ensureInsideDir` — never reads outside) and sets `run.result` to those contents. If the declared file is missing/empty, it falls back to the model's final text plus a `[Note: declared outputFile "<path>" was not produced; returning the agent's final message instead.]` annotation; a read error never breaks the run. The canonical example is the **Daily Stoic Quote** workflow, which already writes a correct `output.md` (1–3 stack-ranked, fully-cited, scored quotes) — `outputMode:"file"` + `outputFile:"output.md"` returns that artifact verbatim instead of the model's "Step 1 / Step 2…" narration.
- **`structured`** — SOTA, generation-layer constraint. The runner offers a synthetic **`deliver`** tool whose `parameters` are the workflow's `outputSchema` (JSON Schema subset: `type`/`required`/`enum`/`items`/`properties`/`additionalProperties` — hand-rolled, no `ajv` dep), and the system prompt directs: "your FINAL action MUST be a `deliver` tool call carrying the deliverable per the schema; anything not in the `deliver` call is discarded." A valid `deliver` is rendered through `outputTemplate` (`{{field}}`, `{{obj.field}}`, `{{#each list}}…{{/each}}`, missing fields graceful) — or pretty-printed JSON if no template — and becomes `run.result`; an invalid `deliver` feeds the validation error back to the model for a retry bounded by `maxSteps`. If the model never calls `deliver`, it falls back to the conversation answer with `fallbackReason:"structured_deliver_not_called"`. Only offered on native-tool-capable models (`isNativeToolCalling`); non-tool models auto-downgrade to `conversation`, and the workflow generator only assigns `structured` when a tool-capable model is configured.

The workflow generator (`lib/workflowGenerator.js` `deriveOutputMode`) picks per proposal: instructions that say "write … to `output.md`/`output.txt`/`output.json`/…" → `file` + that `outputFile`; otherwise `conversation` (conservative default = no behavior change). `structured` is set by hand on a workflow that wants a typed answer. Coverage: `testGroup("Workflow output modes")` — file contents / missing-file fallback / sandbox-escape rejected, structured valid-render / invalid-errors-retry / no-deliver-fallback, conversation unchanged, template renderer, schema validator, `deliver`-def null cases.

`model_routed` audit events + the context-panel routing trace surface the new `fallbackReason` values (`reasoning_signal_overrode_fast_model`, `escalated_to_cloud_reasoning`) and the `error recovery: prior turn failed — annotation injected` context-plan reason.

### Image artifact handling (vision review)

Generated images are tracked as artifacts so a follow-up prompt ("is this good?", "describe this", "improve this", "recreate this", "make another version") can re-attach the latest image to a **vision-capable** model instead of passing only text history.

- `lib/imageArtifacts.js` — `createImageArtifacts({artifactsDir})`: `register/get/clear/list`. Sandboxed to `ARTIFACTS_DIR` (hex-id filenames, resolved path constrained inside the dir — no traversal, no broad filesystem access). Persists image bytes + a `.meta.json` sidecar; in-memory cache for fast re-attach.
- `lib/imageRouting.js` — pure, unit-tested routing: `planImageHandling({prompt, hasLatestArtifact, attachOverride})` decides whether to attach (auto on review wording, `/image` prefix, or manual force-attach override). `buildVisionGuardrail(model)` builds the message shown when the selected model can't see images.
- `lib/imageUploadRouting.js` — pure, unit-tested routing for **directly-attached photos** (`input.images` from the composer): `planUploadedImageHandling({hasImages, selectedModel, visionModel, chainMode, capabilitiesPath})` decides whether the selected model can see the photo (inactive → normal path attaches it), whether to reroute to a vision model (`direct`), chain vision→text (`chain`, gated on the `imageReviewChain` mode the same way artifacts are), or guardrail when no vision model is installed. This is what makes an uploaded photo visible to a model on Auto — without it a router-selected text model silently ignored the image bytes.
- `lib/modelCapabilities.js` — `isVisionCapableModel(path, model)`: an explicit `vision:true` config flag wins, with a heuristic fallback (`gemma[34]|llava|moondream|cogvlm|minicpm-v|internvl|vision|…` — matches both `gemma4` and `gemma3`) so newly-pulled vision models work before any config entry exists.

If an image would be attached but the chosen model is not vision-capable, the request returns an SSE `done` event (or JSON) with the guardrail text and **makes no model call** — the image is never silently ignored. The same guardrail/reroute/chain logic covers both generated-artifact follow-ups and directly-uploaded photos. In multi-model comparison, uploaded photos are attached only to the vision-capable candidates; text-only candidates run text-only (attachments extracted as text still flow to every candidate). The UI shows a "Latest image — ready for vision review" pill with a thumbnail, a Force-attach override, and a Clear button; `/image` remains the manual generation override.

### Attachment extraction (document converters)

Uploaded attachments are injected as text context. `extractAttachmentTexts` (`server.js`) handles two tiers:

- **Text extensions** (`.txt .md .py .js .json .xml .html .csv .yml …`, see `TEXT_EXTS`) — base64-decoded directly to a string, no external tool.
- **Document extensions** (`DOC_EXTS` = `.pdf .docx .odt .doc .rtf .pptx .xlsx .epub`) — the common types (`.docx`, `.pdf`) are extracted **Node-native first** so they work with **zero python on PATH**; the remaining types fall through to `chunk_articles.py --extract-single`:
  - **Node-native first tier** (no python, no spawn — eliminates the `spawn ENOENT` class of failure for the types people actually attach): `.docx` → `mammoth`, `.pdf` → `pdf-parse`. Both are npm deps (`package.json`), kept entirely in Node so no python interpreter is needed for these two.
  - **Python tier** (the remaining `DOC_EXTS`, only reached when there's no native extractor or it threw) — written to a temp file and extracted by `chunk_articles.py --extract-single`, which dispatches per suffix to a dedicated extractor and prints `title\n\nbody` to stdout:

  | Suffix | Extractor | Dependency |
  |--------|-----------|------------|
  | `.pdf` (python path) | `pdftotext` shellout | `poppler-utils` (apt) → `pypdf`/`PyPDF2` fallback |
  | `.docx` (python path) | `python-docx` | `python-docx` |
  | `.odt` | unzip + ElementTree | _(none — stdlib `zipfile`/`xml`)_ |
  | `.doc` | `antiword` / `catdoc` shellout | `antiword` or `catdoc` (apt) |
  | `.rtf` | `striprtf` if present, else built-in pure-Python stripper | `striprtf` (optional — the built-in stripper needs no dep) |
  | `.pptx` | `python-pptx` (slide text + speaker notes) | `python-pptx` |
  | `.xlsx` | `openpyxl` (rows per sheet, `data_only`) | `openpyxl` |
  | `.epub` | unzip + HTML parser per XHTML file | _(none — stdlib `zipfile`/`html.parser`)_ |

  **Graceful fallback is mandatory**: every extractor degrades to a placeholder when its dependency is missing — extraction never crashes. `chunk_articles.py` lists its pip deps in `requirements.txt`; the runtime `Dockerfile` installs `python3` + `poppler-utils` + `antiword`/`catdoc` + `pip install -r requirements.txt`. On bare metal, install the same (`pip3 install -r requirements.txt`, plus `poppler-utils`/`antiword` if you want `.pdf` shellout / legacy `.doc`). Unknown extensions yield `[Unsupported file type: …]`, also never a crash. The extractor tests round-trip synthetic `.docx/.xlsx/.pptx/.rtf/.epub` and self-skip when a dep is absent (`SKIP_PYTHON_EXTRACT_TESTS=1` skips the whole group).

  **Diagnostics never leak to the model.** When extraction fails (missing `mammoth`/`pdf-parse`, a python dep absent, a spawn `ENOENT`, or a parse error), the **actionable detail** (which module/extractor, the `scripts/dev-container.sh rebuild` command, the real error) goes to the **server log only** (`console.warn`). The model receives a *generic* placeholder — `"[Could not read the attached file \"NAME\". It may be corrupted or in a format I can't open here — try attaching it as plain text, Markdown, or PDF instead.]"` — that names no extractor, no container, no rebuild command, and no dependency. The system's internals must never appear in the conversation.

  **`--build` vs `rebuild` after a dependency change (the gotcha).** `mammoth`/`pdf-parse` live in the image's `node_modules`. The dev container mounts an anonymous named volume (`dev-app-node-modules`) over `/app/node_modules`, and Docker only seeds that volume from the image **once**, when the volume is first created. So `scripts/dev-container.sh --build` (= `up --build`) rebuilds the image but **reuses the stale volume** — newly-added deps stay missing and `require("mammoth")` throws `MODULE_NOT_FOUND`. After any `package.json` change (or if `.docx`/`.pdf` attachments suddenly can't be read), run `scripts/dev-container.sh rebuild` (which does `down -v` — wiping the stale volume — then builds + `up`), not `--build` + `./restart.sh`.

### Context audit + KV-cache-friendly ordering

The final context can be bloated (memory dumped verbatim, oversized RAG, restated preferences) and there was no way to *check* what was actually sent. The context audit fixes that:

- **`lib/contextAudit.js`** (`auditContextShape`) produces a per-section size breakdown, a cheap token estimate (chars/4, no tokenizer dep), and warnings when the context looks wrong: the system message dominates the context, the RAG section is oversized, the volatile date section sits in the cached prefix instead of trailing, or meta-memory and current-memory duplicate each other (a real bloat source — `current.md` dumped verbatim often restates meta-memory prefs). Pure and synchronous.
- **Exposure**: when `showFullContext` is on, every chat response meta carries `full_context` (flat prompt), `chat_messages` (the structured `/api/chat` payload), and `context_audit` (the breakdown + warnings). The frontend (`public/app.js` `renderContextPanel`) renders the breakdown table, warnings, and a collapsible structured-messages view under the existing full-context panel.
- **KV-cache-friendly section ordering**: `promptBuilder.buildSystemSections` now emits named sections (`{name, text}`) with stable sections leading (meta-memory, task-instruction, source-priority, chat-handling, tools) and the **volatile date section trailing last**. Because the date changes every request, keeping it out of the stable prefix head reduces prefix-cache invalidation across turns. (The deeper fix — moving date into the ephemeral user-message tail — lands with the memory rewrite in Phase 5.)
- **System-message safety valve**: `contextWindow.compactSystemMessage` / `manageContextWindow` now also compact the **system message** when it alone exceeds `SYSTEM_CONTEXT_CHAR_BUDGET` (default half the total budget) — previously a 100KB system prompt passed untouched and consumed the whole window. Compaction drops trailing (volatile) sections first, keeping the stable instruction head intact, and appends a `[system context truncated to fit budget]` marker.

This is what makes the final context *inspectable* (the user's actual ask: "a way for the context to be checked to make sure it is including what was needed and not a ton of other stuff that fills up KV cache").

### Performance on M2: KV cache, prefill, and the token budget

This is the framing that actually matters on Apple Silicon — not metric counts. The whole point of the WS4 prefix stabilization is to keep Ollama's prefix cache hot so each turn is fast.

**Prefix caching, in one paragraph.** Ollama caches the KV pairs for the *leading token sequence* of a request. On the next request, if the leading tokens match, it reuses the cached KV and only computes KV for the *new* tokens (the user's latest message + the generation). The moment the leading sequence diverges — even by one token — the cache miss is total: every token from the divergence point onward is recomputed (a full **prefill**), and the cache is rebuilt from the new prefix. So what matters is: *is the system prefix byte-identical turn to turn?*

**What busts the cache (the WS4 root cause).** The old `buildSystemSections` interleaved per-turn-volatile sections — `date`, `rag-context`, `web-context`, `weather`, `feedback-lessons` — *inside* the system prefix. Any of those changing between turns (and the date *always* changes) diverges the prefix → full re-prefill every turn. WS4 moves all of those into the **user-message tail** (ephemeral, never cached) and leaves the system prefix as a small **stable core**: meta-memory, workflow, task-instruction, source-priority, chat-handling, tools, skill. The stable core is byte-identical across turns — verified by a fixture test in `test/unit.js` that asserts the stable prefix is identical across two turns when only the user message changes. Per-section char caps (`SECTION_CHAR_CAPS`: meta-memory/current-memory/skill 6000, rag-context 8000) and a lowered `DEFAULT_SYSTEM_CHAR_BUDGET` (60000 → 10000 chars ≈ 2.5k tokens) keep any single section from blowing the prefix back up.

**The audit reflects reality.** `contextAudit.systemPct` is `systemChars/totalChars×100`. It used to be computed *pre-compaction*, so the 82–93% number the Debug panel showed was unreachable — compaction would shrink it before the model ever saw it. WS4 recomputes `auditContextShape` *after* compaction and passes the model's real char budget in, so the Debug % is what was actually sent. The target: a small stable core (a few hundred to ~2.5k tokens) so `systemPct` is low and, more importantly, *constant* across turns.

**Why this matters on M2 specifically.** Apple Silicon has **unified memory**: the model weights, the KV cache, and everything else share the same RAM. There's no separate VRAM to spill into — KV cache competes directly with the resident weights. For an 8B-class model at 8k context, ~82% of the context being system prefix is roughly **0.8 GiB of KV**; at 32k context that's ~3 GiB — a real chunk of an M2's 16–24 GiB, and it's recomputed on every re-prefill. A stable prefix means that KV is computed *once* and reused; a volatile prefix means seconds-to-tens-of-seconds of re-prefill per turn versus ~0s with a hot cache. The prefill latency target on M2 for this workload is sub-second on a cache hit and a few seconds on a cold miss; the difference is entirely whether the prefix is stable.

**The token budget, concretely.** With a 10k-char (~2.5k-token) system budget and the volatile context moved to the tail, the cached prefix stays small and constant. The user message + recalled memory slice (`MEMORY_INJECT_BUDGET_TOKENS`, ~1500) + RAG/web/weather all live in the non-cached tail, so they can change freely without touching the cache. Net: turn N+1 reuses turn N's prefix KV and only prefills the new tail — the fast path.

**Latency impact of the cloud-LLM router + native tool calling (Phase 3-4).** These changes were designed against this KV-cache framing, not against it:
- The cloud router (a large cloud model) replaces the ~0.5-1s 0.5B local-router call only on the **first Auto turn** of a conversation; conversation stickiness (Phase 4.5, `lib/routePin.js`) pins the chosen `{model, taskType, contextPolicy, reasoningPolicy, executionMode}` to the conversation (customer-scoped sidecar `ROUTE_PIN_PATH`, default `<data>/route-pins.json`) so follow-up Auto turns **skip routing entirely** — no per-turn cloud RTT and the local execution model's KV prefix stays byte-stable/hot. Net break-even on short conversations, a net win on longer ones. The pin re-routes only on a genuine shift (task-type change, images/files added or removed, selected-web or RAG toggled, the pinned model leaving the live roster) or an explicit model choice; **tools are re-evaluated every turn regardless** (the pin stores the model + policies, not the `toolsFormat` — `offeredTools` is recomputed per turn and the shape profile re-derived). Cloud OFF falls back to the fixed 0.5B router + heuristics (same latency as today).
- Native tool-calling JSON does **not** apply to any current local execution model (all are `tool_calling` `none` or `prompt`), so local-model turns keep the prompt-tag/none shape with **no prefill/prefix hit**. Native `tools` JSON is attached only for native-capable models WITH offered tools; prompt-tag and tool-less turns are byte-identical to before, so the prefix cache stays hot for the common path.
- The cloud router's own call goes to the cloud endpoint (separate from the local Ollama prefix cache), so it never invalidates the local execution model's prefix. `CLOUD_ROUTER_TIMEOUT_MS` (default 10s) bounds the worst case before fail-closed fallback to the local router.
- Any future change to routing, prompt shape, context assembly, or the tool loop must repeat this analysis: does it mutate the system prefix? does it add a per-turn call? does it change the request shape for the common path? If yes, the KV-cache/prefill cost goes in the plan and the README. **Latency is always a factor.**

### Attachment extraction safety + inline rendering

Two regressions the post-ship audit caught and fixed:

- **No more "Failed to fetch" on a `.docx`** (WS1): `extractAttachmentTexts` spawns a Python converter (`python3`/`python`). The spawn had no `child.on("error")` listener, so when Python wasn't on the server PATH the async `ENOENT` became an unhandled `'error'` → `uncaughtException` → `process.exit(1)` → the in-flight socket dropped and the browser saw "Failed to fetch" (the try/catch can't catch it — spawn emits async). The fix: the spawn Promise now has `child.on("error", reject)`, so ENOENT/EACCES flow into the existing readable-text fallback (which returns a placeholder string). `lib/startupChecks.js` also probes `PYTHON_BIN` (`resolvePythonBin`: configured → `python3` → `python`) and surfaces a WARN in `/admin/health` + the startup banner, and the top-level `uncaughtException` handler is no longer unconditionally fatal for request-scoped errors. Net: a missing Python binary yields a readable error or successful extraction, never a crash.
- **Attachments render inline and persist** (WS3): previously `_buildChatLogRecord` dropped attachments entirely (zero rows in `chats.sqlite` carried any attachment field) and `loadConversation` rendered only text. Now images are registered through the existing `imageArtifacts` layer (artifact id + filename stored, not base64) and served via `/api/artifact/:id`; the chat log record carries `image_attachments: [{id, filename, mimeType}]` and `document_attachments: [{filename, mimeType, size}]`; `renderMessage` appends a `.message-attachments` block (`<img class="attachment-thumb">` for images, `📎 {filename}` chips for docs) on both the live-send view and the reloaded transcript.
- **Follow-up context loss on photo turns** (WS2): the prompt optimizer (qwen2.5:0.5b) was rewriting short follow-ups like "claude harness" into a brand-new question because it ran with zero conversation history. It now receives `recentRecords` (last 1–2 prior user prompts + an "[uploaded an image]" annotation), skips rewriting for ≤4-word follow-ups when there's history, and is instructed to **preserve referents, not retarget them**. `buildRecentContext`/`buildRecentMessages` annotate prior image turns (`[uploaded an image]` / `[described the uploaded image]`) so the model knows a referent points at a photo.

### Key `lib/` modules

| Module | Purpose |
|--------|---------|
| `ollama.js` | All Ollama API interaction (generate, stream, list models) |
| `promptBuilder.js` | Assembles final prompts with context (RAG, web, history, skills); system sections are named + ordered with stable sections leading and the volatile date section trailing for KV-cache stability. `buildTopicResolutionNote` resolves a short referential follow-up's topic inline in the user request so continuity holds for any model selection |
| `promptOptimizer.js` | Small router model rewrites the prompt (the "Don't Optimize" toggle) |
| `contextAudit.js` | Pure context-shape audit — per-section size breakdown, token estimate, bloat/duplication/KV-cache warnings; surfaced under showFullContext |
| `contextWindow.js` | Context-window compaction (old turns summarized) + system-message safety valve (oversized system prompt truncated to budget) |
| `contextPipeline.js` | Pure utilities for context-signal detection and dedup |
| `chatPipeline.js` | Chat request-prep orchestrator (`prepareChatRequest`, `buildAutoContextPlan`, `applyAutoContext`, `applyWorkflow`) |
| `chatHandlers.js` | Chat/dream handler factory (dependency-injected from `server.js`) |
| `router.js` | Fixed local 0.5B LLM router (fail-safe) + capability-aware heuristic fallback (`chooseModelByCapability` picks the cheapest installed model whose `strengths` match the task; `buildRouterPrompt` reads curated strengths) |
| `cloudRouter.js` | Cloud-LLM router (preferred Auto brain) — GLM 5.2 (text) / Mistral Large 3 (images) emits a strict JSON plan; fail-closed validation; live-roster injection; fallback order primary→alternate→local→heuristic |
| `modelShape.js` | Shared per-model shape adapter — `buildModelPayload` emits native Ollama `tools` JSON for native-capable models, prompt-tags/none for the rest; `extractNativeToolCalls` reads `data.message.tool_calls`. Used by both chat and the workflow runner |
| `routePin.js` | Conversation route pinning — pins the first Auto turn's `{model, policies}`; follow-ups reuse the pin (skip the cloud-router call); re-routes on a genuine shift. Customer-scoped sidecar `ROUTE_PIN_PATH` |
| `routeLog.js` | Route decision logging — one JSON record per Auto turn (router used, model picked, pin reuse, fallback path, turn signals). Customer-scoped `ROUTE_LOG_PATH` |
| `agentRunner.js` | Multi-step agentic workflow loop with tool execution (folded onto the shared `modelShape.js` adapter — native-tool models get native `tool_calls` JSON; prompt-tag models keep the text-tag path) |
| `agentTools.js` | Tool definitions + execution (file read/write/list, web fetch, weather, shell) |
| `modelCapabilities.js` | Model tool-calling tiers (none/prompt/native) + vision-capability check |
| `sandbox.js` | Path-traversal protection — `ensureInsideDir` validates all agent file ops |
| `imageArtifacts.js` | Sandboxed image-artifact tracking layer |
| `imageRouting.js` | Artifact-aware image routing + vision guardrail |
| `imageUploadRouting.js` | Pure routing for directly-attached photos (`input.images`) — reroute/chain/guardrail so a router-selected text model never silently ignores an upload |
| `imageGen.js` | Image generation via an Ollama image model |
| `store.js` | Conversation persistence — SQLite (primary) with JSONL fallback |
| `conversations.js` | Conversation CRUD (create, list, read, delete) |
| `conversationUtils.js` | Title derivation, ID generation, conversation utilities |
| `history.js` | Chat-log read/write (JSONL + SQLite) |
| `rag.js` | Keyword-based RAG search across corpora |
| `vectorRag.js` | Vector/embedding-based hybrid RAG search |
| `corpusManager.js` | Corpus lifecycle (create, rebuild, upload, delete) |
| `webSearch.js` | SearXNG (primary) + DuckDuckGo (fallback) search |
| `skills.js` | Skill definition read/write |
| `workflows.js` | Workflow CRUD (JSON file-based) |
| `dream.js` | Memory consolidation via LLM — auto-run scheduler, triple gate, ADD-only extraction, bi-temporal invalidation, high-risk review queue |
| `memoryStore.js` | jsonl-backed long-term memory CRUD — Ebbinghaus decay, FSRS strength growth, bi-temporal invalidation, prune (rescan), legacy `current.md` importer |
| `memoryRecall.js` | Read-only recall — embed prompt, cosine top-k, Redis-Agent-Memory-Server rerank (semantic + freshness + novelty + decay), inject `<memories>` slice in the user-message tail (KV-cache-friendly); recency fallback when embeddings unavailable |
| `googleAuth.js` | Google OAuth2 connector — **two layers**: (1) app setup (client id/secret/redirect host/enabled read-only scopes/mail day limit) stored in a gitignored config file with validate/redact/`enabledScopes`, and (2) user connection (auth URL build, code→token exchange, refresh, best-effort revoke, state-param CSRF on the redirect callback, token storage to a separate gitignored credentials file). Neither layer ever writes to `settings.json`. |
| `googleCalendar.js` | Read-only Google Calendar listing in a server-built date window (`timeMin`/`timeMax`), AbortSignal timeout, injectable fetch for tests |
| `googleMail.js` | Read-only Gmail listing with a **server-side day limit** — the window is enforced at the API query (`q=after:YYYY/MM/DD before:YYYY/MM/DD`), so the inbox is never read in full; `maxResults` cap; injectable fetch |
| `feedback.js` | Thumbs up/down feedback + model-preference learning |
| `events.js` | Event logging |
| `jobQueue.js` | Async job queue for long-running tasks (corpus rebuild, etc.) |
| `eval.js` | Model-evaluation metrics (quality scores, latency tracking) |
| `usage.js` | Token-usage statistics |
| `health.js` | System health checks (Ollama, SearXNG, disk) |
| `rateLimit.js` | In-memory per-IP rate limiter |
| `settings.js` | Runtime settings read/write (JSON file) |
| `securityHeaders.js` | CSP built from `OLLAMA_BASE_URL` (no hardcoded origin; no `unsafe-eval`) |
| `clientAccess.js` | LAN gate (`isPrivateClientAddress` + `TRUSTED_CLIENT_CIDRS`) |
| `atomicWrite.js` | Atomic temp+rename config writes |

### Frontend (`public/`)

- `index.html` — single-page app, all HTML
- `app.js` — all client logic (vanilla JS, no framework)
- `workflows.js` — workflow-tab UI logic
- `markdown.js` — Markdown-to-HTML renderer
- `styles.css` — all styles

CSRF token is read from a `<meta>` tag injected by the server. Chat input: Enter sends, Shift+Enter inserts a newline.

### Agent / Workflow system

Workflows are defined in `workflows.json` with trigger types (manual/scheduled), task types, model selection, and optional agentic mode with tool access. Agentic workflows use `agentRunner.js`, which runs a multi-step loop:

1. Send prompt + tool definitions to the model
2. Parse tool calls from the response
3. Execute tools via `agentTools.js`
4. Feed results back as tool messages
5. Repeat until no tool calls or max steps reached

**Shared shape adapter (Phase 4.6).** The workflow runner no longer has its own divergent tool-calling shape — it folds onto the same `lib/modelShape.js` adapter chat uses. Native-tool-capable workflow models (e.g. `glm-5.2:cloud` on a workflow card) drive the loop via Ollama `/api/chat` native `tool_calls` JSON (tool results return as `role:"tool"` messages for canonical multi-turn context); prompt-tag and tool-less models keep the existing flat `/api/generate` text-`<tool_call>`-tag + regex-parse path **byte-identical**. The branch is gated strictly on `isNativeToolCalling(model)` + offered tools + `AGENT_NATIVE_TOOLS` (default on; set `false` to force every workflow back to the text-tag path). Workflow fallback chains, goal/instructions, and card model selection are unchanged.
Agent tools are sandboxed: file operations are constrained to `workspaceDir` (realpath-aware `ensureInsideDir`), shell execution requires `allowShellExec: true` and is restricted to an allowlist (argv-array execution, no `sh -c` metachar interpretation). Destructive tools (`file_write`/`shell_exec`) carry an approval floor, but a workflow's own declared tools are authorized at save time and run without per-call approval (validation is the approval); `requireApproval: ["all"]` is the explicit hard gate. See the next paragraph.

**Destructive-tool approval — floor + declared-tool authorization.** `file_write` and `shell_exec` mutate the filesystem / execute processes, so `lib/agentTools.js` `isApprovalRequired` gives them a **hard floor**: a destructive tool requires per-call approval unless the workflow **explicitly** opts it into `constraints.autoApprove` (the auditable, per-tool opt-out recorded in the workflow definition). On top of that floor, the agent runner (`lib/agentRunner.js` `runtimeNeedsApproval`, unit-tested) applies one runtime rule: **a workflow's own declared tools are authorized at save time and run without per-call approval**, unless the workflow sets an explicit hard gate (`constraints.requireApproval: ["all"]`). Declaring a destructive tool in a workflow and saving it *is* the authorization — for AI-generated workflows the proposal was already bwrap-sandbox-validated first (workspace-relative paths only, no `/app`/`docker.sock`/`../`, no shell unless declared), so re-gating a vetted tool per call is pure friction and was what stalled agentic runs at a `file_write` step waiting on an approval no one was watching (the "step 6 spin"). Containment is **not** weakened by this — `executeTool`/`resolveWorkspacePath` enforce `workspaceDir` containment at runtime regardless of approval — and the floor still catches any destructive tool the workflow did **not** declare (defense in depth). New AI-generated workflows additionally have their declared destructive tools written straight into `constraints.autoApprove` by `mapProposalToWorkflow`, so the on-disk record reflects the same policy. The explicit hard gate for a workflow that should prompt per call is `requireApproval: ["all"]`.

**`workspaceDir` containment (manual + AI-generated workflows).** A manually-saved workflow's `workspaceDir` is the root agent file tools operate in. `sanitizeWorkflow` rejects absolute paths and parent-traversal at save time (`lib/workflows.js`), and `buildAgentWorkflowPaths` enforces hard under-`AGENTS_DIR` containment at run time via `ensureInsideDir` (`server.js`) — so a trusted-VPN user, a compromised browser session, or a prompt-injected workflow can't point `file_write`/`shell_exec` outside the agents tree. This applies to all workflows, not only AI-generated ones. Relative `workspaceDir` values resolve against **`AGENTS_DIR`**, not `__dirname` — in Docker the app lives at `/app` while `AGENTS_DIR` is `/data/agents`, so resolving against `__dirname` would reject every valid relative workspace; `AGENTS_DIR` is the correct base and the resolved path is still checked to stay inside it.

**AI workflow generator (the Claude CLI authoring harness).** The "Generate workflow from AI" panel turns a short description into a complete, safe workflow draft. The panel opens showing **only the description box + buttons** — the optional detail fields (Name, Goal, Instructions, Run prompt, Expected response, Trigger/schedule, Tools, Models, Approval mode) are wrapped in `#wfgenDetailFields` with the `[hidden]` attribute and stay collapsed until you Generate; once the AI returns a proposal, `generateWorkflow` populates them via `populateFormFromProposal` and un-hides the wrapper (`display: contents` so the 2-col grid is preserved), so you review/edit/save the AI-filled draft rather than face a wall of empty boxes up front. The authoring agent is the **Claude CLI harness**, launched inside a bubblewrap (bwrap) mount namespace as `ollama launch claude --model <builder-model> -- --dangerously-skip-permissions` (`scripts/workflow-builder.sh`). `--dangerously-skip-permissions` turns off Claude's *own* per-action confirmation prompts so the sandboxed builder runs **unattended to completion** — it can't stop mid-generation to ask a human (bwrap isolates it from any interactive terminal anyway, and a hung prompt would just time out). It can write **only** `proposal.workflow.json` inside its per-run sandbox dir; `/app`, the live workflow store, `.env`, raw secrets, and the Docker socket are absent from the namespace. A hard validation gate (`lib/workflowGenerator.js` `validateProposal`) plus your explicit **Save** approval still stand between any proposal and the live store — the CLI never commits directly.

  **bwrap runs in a separate `ROLE=runner` sidecar, not the app.** bwrap needs user/mount namespaces, which Docker's default seccomp profile blocks; the old deploy probed a security-profile ladder (`seccomp=unconfined` → `+SYS_ADMIN` → `--privileged`) and ran the WHOLE APP under whichever profile passed — weakening the main container's security and causing recurring deploy-reliability failures on kernels that deny even `seccomp=unconfined`. **Now bwrap execution lives in a separate `ROLE=runner` container** (`runner/server.js` — a minimal HTTP sidecar that reuses `lib/bwrapSandbox.js` with NO duplicated bwrap logic and NEVER references the Claude command, which still lives only in `scripts/workflow-builder.sh`). The main app container stays **non-privileged and always starts**; only the runner carries the namespace/security profile. If the runner (or bwrap) is down, **only `/api/workflows/generate` and `/api/swarms/generate` return a clear 503** — chat, RAG, auth, routing, everything else keeps working. The runner's HTTP surface: `GET /health` → `{ok,role:"runner",bwrap:{ok,stderr},uptimeSeconds}` (the Docker `HEALTHCHECK` target, UNauthenticated); `GET /canary` → `{ok,stderr}`; `POST /generate` → `{runDir,dataRoot?,model?,timeoutMs?}` returns `{code,timedOut,signal,error}` and writes `stdout.log`/`stderr.log` into the shared `<runDir>/logs/`. `WORKFLOW_RUNNER_TOKEN` Bearer header is required for `/generate` + `/canary` when set; no token = internal-network-only trust. Binds `0.0.0.0:RUNNER_PORT` (default 3100); the port is NEVER published to the host — the app reaches it over the per-customer Docker network.

  **The app↔runner contract (why this is surgical).** The file layout is UNCHANGED. The app still creates `runDir = /data/workflow-sandbox/runs/<id>`, writes `prompt.md` + inputs, and reads `proposal.workflow.json` back from the SAME `runDir`. Both containers share the host `$DATA_DIR/workflow-sandbox` directory mounted at the IDENTICAL container path `/data/workflow-sandbox`, so `runDir` is byte-identical in both containers. The ONLY thing that moved is WHERE `bwrap … scripts/workflow-builder.sh` executes — from inside the app to inside the runner. Validation/commit are untouched; swarms reuse the same `runBuilder` path automatically (no swarmGenerator change). `scripts/workflow-builder.sh` is unchanged (still the sole place the dangerous Claude command lives; still enforces runDir-under-`/data/workflow-sandbox`, no `/app`, no wholesale `/data` bind).

  **LOCAL vs REMOTE mode (`lib/bwrapSandbox.js`).** `WORKFLOW_RUNNER_URL` unset = LOCAL mode = byte-identical to the old behavior (dev/test single-container path — the dev compose intentionally leaves it unset). Set `WORKFLOW_RUNNER_URL` (e.g. `http://private-ai-<slug>-runner:3100`) = REMOTE mode: `canary()` → `GET <url>/canary` (re-probed each call, no permanent cache, so a runner that recovers is picked up without an app restart); `runBuilder()` → `POST <url>/generate {runDir,dataRoot,model,timeoutMs}` returning the same `{code,timedOut,signal,error}` shape (+ `remote:true`); `ensureReady()` runs one fresh canary in REMOTE mode (no-op in LOCAL — the boot canary stands). Connection failure → `{ok:false, stderr:"workflow runner unreachable at <url>…"}` / `{code:1, error:"…unreachable…"}` — never throws. Both generate handlers (`handleWorkflowGenerate` + `handleSwarmGenerate`) now call `await bwrapSandbox.ensureReady()` then re-check `getBuilderReady()` instead of a stale boot-time check; the `generatorUnavailable(res)` 503 now includes `mode: "remote-runner"|"local-bwrap"` + mode-specific fix text. (`runBuilderLocal` now also honors the `WORKFLOW_BUILDER_SCRIPT` env var — previously a latent bug — and new exports `runBuilderLocal`/`runBuilderRemote`/`ensureReady`/`isRemoteMode` join the existing `canary`/`runBuilder`/`getBuilderReady`/`setBuilderReady`/`canaryArgv`.)

  The builder model is **auto-selected** to the newest `glm-*:cloud` the app can see (live Ollama roster ∪ the `model_capabilities.json` cloud catalog) via `resolveBuilderModel`, so new GLM releases are picked up without a code change; pin one with `WORKFLOW_BUILDER_MODEL` to override. The client defaults to the same newest-GLM checkbox (primary), with the rest available as runtime fallbacks. The CLI is instructed to **fully fill** `name`/`goal`/`instructions`/`runPrompt` from the description (a proposal with a blank required field can't be saved). If the agent is genuinely uncertain it emits a clarification request; and as a safety net, if it returns a proposal with any required field still blank, `generate()` **synthesizes a clarification popup** asking you to fill exactly those blanks — on submit the answers are folded back into the request (`applyClarificationAnswers`) and the agent re-runs to assemble the full proposal. So generation either produces a complete, saveable draft or pops up a question modal — never a dead-end "can't save." (`resolveBuilderModel`/`applyClarificationAnswers`/blank-field synthesis, unit-tested.)

  **File attachments (workflows + swarms).** Both "Generate" panels accept file attachments — PDF, TXT, Markdown, DOC, DOCX, ODT, RTF, CSV, JSON, HTML, images (PNG/JPG/GIF/WebP/BMP/TIFF), and other common types, multiple files at once. The planner reads the documents and drafts the workflow/swarm around their contents. Because the sandboxed CLI can only see its per-run dir and reads `prompt.md` on stdin, `lib/generatorAttachments.js` extracts each attachment to text **before** the builder runs and **inlines** it into the prompt: text/doc files go through the same `extractAttachmentTexts` extractor chat uses (`.docx`→mammoth, `.pdf`→pdf-parse, rest→`chunk_articles.py`); images go through a **vision describe subcall** — a vision-capable model (the configured cloud vision model `CLOUD_ROUTER_VISION_MODEL`, default `mistral-large-3:675b-cloud`, when live; else the local `gemma` vision fallback `GENERATOR_VISION_FALLBACK`, default `gemma4:latest` — the live-roster scan then picks `gemma3:27b` on the GPU VM / `gemma4:latest` on the M2) describes the image and the description is inlined. The full untruncated text is also written to `runDir/attachments/` so the CLI can re-open it via `file_read`. The whole path is **fail-safe**: a bad file or a missing vision model yields a readable placeholder block — generation never blocks on one attachment. Attachments are cleared from the panel after a successful (non-clarification) generate so a stale file can't ride into the next draft. (`lib/generatorAttachments.js`, `prepareAttachmentBlocks`/`attachmentPromptLines`/`writeAttachmentFiles`, unit-tested; wiring in `lib/workflowGenerator.js` + `lib/swarmGenerator.js` + `server.js` `buildGeneratorContext`/`buildSwarmGeneratorContext`.)

### Dream system (memory consolidation)

The dream system turns conversation history into durable, recallable long-term memory. It runs itself now — no manual invoke or approval needed for low-risk facts — and is built around four ideas grounded in how real memory systems work (Ebbinghaus decay, FSRS strength growth, Zep bi-temporal invalidation, mem0 ADD-only extraction, Redis Agent Memory Server rerank, Claude Code prompt-cache breakpoints):

**Storage** — `lib/memoryStore.js` keeps memories in `memory/memories.jsonl`, one JSON record per line: `{id, type, risk, text, source, conversationId, createdAt, lastAccessedAt, accessCount, strength, halfLifeDays, decayScore, tags, linkedIds, supersedesId, supersededById, validFrom, validUntil, checksum}`. The legacy `memory/current.md` is kept as a human-readable append-only mirror (debug/back-compat); a one-time importer (`migrateMemoryIfNeeded`, run at boot if `memories.jsonl` is empty) parses existing `## Approved Dream <ts>` sections into records with `createdAt` from the header timestamp.

**Decay + rescan** — each memory has a type-specific half-life (`preference`/`explicit_user_preference`/`personal_memory` 90d, `fact` 30d, `event` 7d, `correction`/`model_routing_change` 60d, `credential_or_secret` 365d, etc.; default 30d). `decayScore = 0.5^(ageDays/halfLifeDays)`. `risk:critical` memories (allergies, secrets, security permissions) floor at 0.5 and are **never pruned** — they never fully decay. Normal memories floor at `MEMORY_DECAY_FLOOR` (0.05). Every auto-run recomputes decay scores across the whole store (the rescan) and prunes records that have decayed to the floor, so stale/contradicted facts age out automatically.

**Recall (KV-cache-aware)** — `lib/memoryRecall.js` replaces the old full-`current.md` dump. On each turn, the user prompt is embedded with Ollama (`EMBEDDING_MODEL`, default `nomic-embed-text`); memories are cosine-ranked top-k (`MEMORY_RECALL_TOP_K`, default 5), then reranked `final = (0.8·semantic + 0.2·(0.6·freshness + 0.4·novelty)) · decayScore + 0.05·min(1, accessCount/20)`. The resulting ~1500-token (`MEMORY_INJECT_BUDGET_TOKENS`) slice is injected as a `<system-reminder><memories>` block in the **user-message tail**, never the cached system-prompt prefix — so the stable prefix (meta-memory, skills, task instruction, tools) stays cache-hot across turns. Recall is **read-only**: it does not mutate or persist records per turn (avoids a write-per-turn race); strength growth and decay refresh happen at dream/prune time. If the embedding endpoint is unreachable, recall falls back to recency ranking (graceful, never blocks the chat). `CHAT_MEMORY_AS_TOOL` mode keeps working — the `memory_recall` agent tool returns the recalled slices, not the whole file.

**Auto-run** — a scheduler in `server.js` (the Phase 5 `dreamAutoInterval`, mirrors the existing workflow scheduler) checks a triple gate every 5 minutes: `DREAM_AUTO_ENABLED` on, `DREAM_INTERVAL_HOURS` since the last run, and `DREAM_MIN_NEW_SESSIONS` new chat sessions since the last run. When all three pass it runs `runAutoDream`: orient (read current memory + recent sessions) → gather → consolidate (single-pass ADD-only extraction with DUPLICATE/CONTRADICTS/AUGMENTS classification) → prune (the rescan). On CONTRADICTS, the old record is bi-temporally invalidated: `validUntil` + `supersededById` are set on the old record and `supersedesId` on the new one — the old record is **expired, never deleted** (preserves audit history and is excluded from recall by `isValid`).

**Approval — pure no-approval (Claude-CLI analog)** — *every* parsed candidate is auto-approved straight to `memories.jsonl`, preserving its `risk` tag (`high` for `HIGH_RISK_TYPES`: credentials, business conclusions, pricing, security/public-exposure, personal memory; `low` otherwise). There is **no review queue and no gate** — a single-user LAN app doesn't need the friction, and the user won't be typing secrets into chat. `HIGH_RISK_TYPES` is kept only as a *tag source* so high-risk records are still auditable and undoable, not a gate. The extracted `autoApproveCandidates` helper (pure, unit-tested without Ollama) writes each record + appends the `current.md` mirror + an `approved_log.jsonl` entry carrying the record `id` and `risk`.

**Synchronous store + ask tools** — the agent tools `memory_store` (no-approval) and `memory_ask` are available in normal chat whenever memory is on (offered alongside `memory_recall`):
- `memory_store` with `kind:"preference"` appends a permanent user preference to the meta-memory skill file (`skills/meta-memory/SKILL.md`, atomic + de-duped via `lib/skills.js` `appendMetaMemory`); `kind:"fact"` appends an approved long-term record to `memories.jsonl`. Returns `{ok, stored, text}`.
- `memory_ask` surfaces a user-facing yes/no question ("Do you want this added to meta memory? …") and stores nothing itself; on "yes" the model calls `memory_store` (or the frontend posts to `POST /api/memory/store`).
- `chatPipeline.buildAutoContextPlan` detects explicit store signals (`store this`, `put this in memory`, `remember this`, `meta memory`) and forces memory on + offers `memory_store`, so "store this: I prefer tabs" lands in meta memory with no approval. `promptBuilder.buildToolSection` instructs the model to store immediately when asked and to ask only when it's ambiguous.

**Undo last dream (the safety net)** — `POST /admin/dream/undo-last-batch` (admin "Undo last dream" button) reads `approved_log.jsonl`, finds the latest run's entries (by `runTs`), and removes those records from `memories.jsonl` by `id` (`dream.undoLastDreamBatch`). Idempotent and safe when there's nothing to undo; logs an `undo-last-batch` audit entry so the next undo targets the run before the just-undone one. This is the entire safety surface for the no-approval policy — no secret filter, no review queue, just undo.

The pure scoring functions (decay, rerank, strength growth, bi-temporal invalidation, prune, recall top-k, the migration importer, the triple gate, `autoApproveCandidates`, `undoLastDreamBatch`, `appendMetaMemory`) are unit-tested standalone in `test/unit.js`; the gate behavior is integration-tested in `test/integration.js` (does not fire with no sessions; fires once enough new sessions land).

### Google connectors (Calendar + Mail) — two-layer: admin app setup + user connection

Read-only Google Calendar + Gmail connectors over an OAuth2 flow, split into two layers so the end user never touches OAuth credentials:

1. **Admin / OAuth App Setup** — the Google OAuth app's **client ID**, **client secret**, **redirect host**, which **read-only scopes** to enable (Calendar and/or Gmail), and the **mail day limit**. These live in a gitignored **config file** (`CONNECTORS_CONFIG_PATH`, default `./connectors-config.json`, added to `.gitignore` + `.dockerignore`, written `chmod 600`) — **never in `settings.json`**. The client secret is redacted (`redactAppConfig` → `clientSecretConfigured` boolean) before any response reaches the browser; the admin UI shows "(configured)" + a fresh password field to replace it, so the secret value never round-trips through the DOM. User connection stays **disabled until the setup is complete** (`validateAppConfig`: client ID + secret + redirect host + at least one enabled scope).

   **The admin panel is OPTIONAL.** Prefer supplying the OAuth client once at deploy time via environment variables — `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, `GOOGLE_REDIRECT_HOST` (+ `GOOGLE_CALENDAR_ENABLED` / `GOOGLE_MAIL_ENABLED` / `GOOGLE_MAIL_DAY_LIMIT`) in `.env`. With those set, `resolveAppConfig` (file → env fallback) treats the app config as complete, so the end user's Connect flow is pure click → Google login → approve and **no one has to touch the in-app panel at all**. The on-disk config file (set via the panel) overrides the env, so the panel remains available as an optional override. This mirrors how mail clients ship a developer-registered client baked into the app — the user never sees a client ID; here the "developer" is the operator dropping the client into `.env` once.

2. **User / Account Connection** — the end user (the normal flow) clicks **Connect to Google**, approves Google's consent screen for the enabled read-only scopes, and the resulting **access + refresh tokens** are stored in a *separate* gitignored file (`CONNECTORS_CREDENTIALS_PATH`, default `./connectors-credentials.json`, `chmod 600`). **Disconnect** revokes the token at Google (best-effort) and deletes the local token file. The user never pastes a client ID or secret.

A **one-time migration** (`migrateGoogleAppConfigFromSettings`, run at boot) moves any `connectors.google` block left in `settings.json` by older builds into the config file and strips it from `settings.json` — so existing setups survive the upgrade without re-entering credentials.

**Security posture** (matches the LAN-first / no-credential-leakage rule):
- Scopes are read-only only: `calendar.readonly` + `gmail.readonly` (requested individually per the admin's enabled toggles via `enabledScopes`). No send/create/delete.
- The OAuth client secret is stored only in the gitignored config file and is never sent to the browser; OAuth tokens are stored only in the gitignored credentials file. Neither file is committed or baked into the image.
- The OAuth callback is a browser GET redirect, so its CSRF is the `state` nonce (`issueGoogleState`/`consumeGoogleState`, 10-min TTL), not the `X-CSRF-Token` header that guards the other admin routes. A bad/expired `state` is rejected before any token exchange.
- All connector routes are gated by `requireAdminClient` (LAN-first private-client check) and the global `csrfCheck` on mutating methods.

**Mail day-limit enforcement** (the hard guarantee the user asked for): the day window is enforced **at the Gmail API query** via `q=after:YYYY/MM/DD before:YYYY/MM/DD` (`googleMail.buildMailQuery`), not as a post-filter. The Gmail API honors `q=` server-side, so even a `gmail.readonly` scope only returns messages within the window — the inbox is never read in full and never held in memory. `maxResults` caps the count. The mail day limit from the app config flows here. For a **sub-day** window ("read my last 12 hours of email"), `google_mail_recent` takes an optional `hours` param: when finite and ≥ 1, the query becomes `q=after:<unix-seconds>` with no `before:` (up to now), and `hours` **wins over** `dayLimit` if both are given. This is what makes the AI-generated morning brief ("last 12–24h of email") expressible.

**Routes** (mirror the admin route shape — `requireAdminClient` + CSRF on mutating routes):
- `GET  /admin/connectors/google/status` — one response carrying both layers' state: `{connected, email, appConfigured, appConfigComplete, missing:[…], appConfig:{…redacted…}}` so the UI renders from a single fetch.
- `PUT  /admin/connectors/google/app-config` — admin saves the OAuth app setup to the gitignored config file. An empty client-secret field means "keep the existing secret." Returns `{ok, appConfigComplete, missing, appConfig}` (redacted). Saving partial config is allowed — completeness gates the Connect button, not the save.
- `POST /admin/connectors/google/start` — returns the Google consent `authUrl` (requesting only the enabled read-only scopes) + the redirect URI. **400** with `"Google OAuth app config is missing. Complete setup first."` + a `missing` list when the app config is incomplete.
- `GET  /admin/connectors/google/callback?code=&state=` — browser redirect; verifies `state`, exchanges the code (using the app config's client id/secret/redirect host), fetches the connected email, stores tokens, returns a confirmation page.
- `POST /admin/connectors/google/disconnect` — revokes the token at Google (best-effort) then clears the stored tokens.
- `GET  /admin/connectors/google/calendar/events` — lists the next 14 days (read-only).
- `GET  /admin/connectors/google/mail/messages` — lists recent messages within the configured day window (read-only).

**Agent tools** (gated on connected, read-only): `google_calendar_list` (lists upcoming events) and `google_mail_recent` (lists messages in the day window). Both throw a friendly "not connected — an admin must connect via Settings → Connectors" error rather than a raw 401 when no token is present, and refresh the access token transparently when it's stale (using the client id/secret from the gitignored app config). They're available in agentic workflows (the agent run context carries `credentialsPath` + `googleAppConfigPath`) and in chat-mode agentic turns.

**Chat reachability (signal-gated offering).** In chat, the model has no idea how to reach your calendar/mail unless the tools are *offered*. `lib/chatPipeline.js` detects calendar/mail signals in your prompt ("what's my schedule today?", "read my recent email", "who do I need to respond to?", "what's coming up", "unread emails", "what emails did I get today") and pushes `google_calendar_list` / `google_mail_recent` into the offered-tools set, with a system-prompt hint explaining `daysForward`/`daysBack` (days) and `dayLimit` (days) vs `hours` (sub-day). There is **no connection pre-check at plan time** — the planner stays pure/I-O-free; if Google isn't connected, the tool returns the actionable not-connected error and the model relays "connect via Settings → Connectors and stop" at the cost of one round-trip (no invented calendar/email contents). Master switch: `CHAT_GOOGLE_AS_TOOL` (default on; set `false` to disable chat connector offering entirely).

**Manual Connectors toggle (force the tools on).** Next to the Web toggle in the chat Options there's a grouped **Connectors** control with **Calendar** + **Gmail** checkboxes. Checking one forces the corresponding read-only tool on for that turn **even when your phrasing doesn't match a signal** (so "summarize my day" with Calendar checked yields a `google_calendar_list` call regardless of wording) — it overrides the signal gate but **still respects the connection gate** (if Google isn't connected, the checkboxes disable and forcing is a no-op — no dead tool). The decision lives in the pure helper `detectGoogleConnectorOffer` (`lib/chatPipeline.js`), shared with `buildAutoContextPlan`, so the force path is unit-tested independently of the live chat round-trip. In **workflows**, the manual editor exposes **Google Calendar** and **Gmail (recent)** checkboxes (`google_calendar_list` / `google_mail_recent`) alongside the other `.workflow-tool` toggles. **Swarms** get them two ways: (1) by checking those on a member workflow (the runner honors `workflow.tools`), AND (2) automatically via **swarm-level connector intent propagation** — see the next paragraph — so a swarm whose own text says "pull my calendar and recent email" offers the tools to every member even when no checkbox is ticked. The force flags (`forceCalendarTool` / `forceMailTool`) ride on the request/input, not the system prefix, so the KV-cache-stable-prefix invariant is unaffected.

**Swarm-level connector intent propagation (the daily-brief "no calendar / no email" fix).** A swarm auto-offers `google_calendar_list` / `google_mail_recent` to its members by running `withConnectorTools` (`lib/agentRunner.js`) over each member's own free-text (name/goal/instructions/runPrompt) via `detectGoogleConnectorOffer`. That per-member signal detection is **fragile**: a member worded evasively — e.g. *"review today's agenda and appointments; messages needing a reply"* — trips **no** `CALENDAR_SIGNAL`/`MAIL_SIGNAL` (the anchors are `calendar`/`schedule`/`email(s)`/`inbox`/`gmail`, plus compound forms like `my meetings`/`upcoming events` — "agenda", bare "appointments", and "messages" are not anchors), so it got no google tool, the model had nothing to call, and the synthesis said *"No events today / Inbox clear"* even though the connector itself worked (the admin debugger pulled real data). To close that gap, `runSwarm` (server.js) now derives a **swarm-level** `swarmConnectorOffer` from the SWARM's own text (name + description + synthesizerPrompt) and threads it through `runAgenticWorkflow` → `buildAgentRunContext` (`context.swarmConnectorOffer`) → `runAgentLoop` → `withConnectorTools(workflow, calConnected, mailConnected, swarmConnectorOffer)`. The 4th `force` arg reuses the *same* manual-force path the chat Connectors toggle uses (`detectGoogleConnectorOffer`'s `forceCalendarTool`/`forceMailTool`): it overrides the per-member signal gate but **the connection gate still wins** (no dead tools), and it is **additive only** (never drops a declared tool). When the swarm signals neither scope, `swarmConnectorOffer` is `null` and `withConnectorTools` degrades to the byte-identical per-member-signal path — standalone workflow runs are unaffected. To make the path **self-diagnosing**, `runAgentLoop` writes a `connector_tools_resolved` audit entry per member run (the per-scope connection state, the swarm offer, and which google tools were actually offered) into `agents/<member-slug>/runs/<runId>/audit.jsonl`, and `runSwarm` logs a `swarm_connector_offer` event — so a future "no calendar" recurrence is diagnosable without guessing: `calendarToolOffered:false` + `connectorState.calendar:true` = the offer gate blocked it; `true` with no later `toolCall` = the model chose not to call it (downstream). Coverage: `testGroup("Agent Runner")` — incl. `withConnectorTools: swarm-level force offers google tools when the member's own text has NO signal` (the exact regression, using an evasively-worded member) + the `runSwarm` wiring test.

**Swarm member reports render as collapsible dropdowns.** A `fanout_synthesize` swarm appends a `## Full member reports` section of links to each member's full `.md` report (served read-only by `GET /admin/agents/file?path=…`, sandboxed to `AGENTS_DIR`, `.md`/`.txt` only). The client (`renderMarkdown` in `public/markdown.js`) rewrites those `/admin/agents/file` links into collapsible `<details class="member-report-details">` dropdowns that **lazy-load + render the member's markdown inline with full formatting** on first expand (`loadMemberReport` in `public/app.js`, exposed on `window`), rather than opening a hyperlink to an unformatted raw-text page. The fetch is the same cookie-authenticated admin GET the rest of the admin panel uses; re-expansion reuses the cached render. Non-agent links still render as normal hyperlinks. Coverage: `test/unit.js` "Markdown renders /admin/agents/file links as collapsible dropdowns, not hyperlinks" + the non-agent-link guard.

**Dynamic, environment-aware `model:"auto"` resolution (the dead-model fix).** A workflow/swarm member with `model:"auto"` is resolved by `resolveAgentModel` (`lib/agentRunner.js`) against the **live roster for this environment** — `getAvailableModels()` (Ollama `/api/tags` → local models + the cloud catalog), warmed once at startup (`getAvailableModels().then(setCachedModelIds)` in the `server.listen` callback) and re-warmed on each admin models-page visit. The static `model_capabilities.json` lists *capability*, not *presence*: it once listed a since-removed model (`qwen3-coder:30b`) as tool-capable even when it wasn't pulled on the local M2, so `auto` picked it → the run failed `model 'qwen3-coder:30b' not found` → empty result → the synthesis wrote *"No events today / Inbox clear"* while the connector had pulled real data. Now `resolveAgentModel("auto")` filters the capability list to models actually in the live roster (native-tool models preferred over prompt-tag models; local preferred over cloud), so `auto` picks `qwen3.6:35b` on the local host and — through the **same code path** — a bigger qwen on the cloud VM, adapting to the environment without a per-host config. If nothing live is tool-capable it returns `""` so the run fails honestly ("No tool-capable model available") rather than silently picking a dead model. `resolveAgentModelChain` applies the same live-roster filter to `workflow.modelFallbacks`, skipping dead fallbacks. The roster is threaded through `buildAgentRunContext` (`context.liveModels = getAvailableModelsSync()`) → `runAgentLoop`. A latent sort bug was also fixed: the `native > prompt` preference in `getToolCapableModels` (`lib/modelCapabilities.js`) used `(order[t] || 2)` where `order[native] === 0`, and `0 || 2` is `2` — so native models were silently demoted to the *lowest* priority, the opposite of the intent; the fix uses an explicit `!= null` check so native tool-calling models (e.g. `qwen3.6:35b`) are genuinely preferred. With no live roster supplied (weather writer, unit tests, the resume path) the resolver degrades to the prior caps-only behavior, so unrelated paths are byte-identical. Coverage: `testGroup("Agent Runner")` — incl. `resolveAgentModel: auto picks the first LIVE tool-capable model, skipping dead caps entries`, the `degrades to the static caps pick (legacy behavior)` guard, the `returns empty string when nothing live is tool-capable` honest-failure guard, the explicit-live-pin test, and `resolveAgentModelChain: a live roster filters dead fallbacks out of the chain`.

**No-truncation swarm data flow (the 1M-context fix).** The daily-brief swarm pulls weather + calendar + email into a `glm-5.2:cloud` synthesizer with a **1M-token** context window; the member models run ≥262k. Real connector payloads (a day of events + a day of inbox threads + weather) are tiny relative to those windows, yet the old fixed caps silently cut them mid-payload — `TOOL_RESULT_PROMPT_LIMIT` 6k (tool result → next LLM step), `PIPE_CAP` 8k (member → synthesizer), `run.result` 10k, audit 5k — so the synthesizer saw a truncated prefix and wrote *"No events today / Inbox clear"* while the members had pulled real data. All four caps are now **env-tunable and generously defaulted** (100k for the model-facing + result + pipe caps, 20k for the diagnostic-only audit cap): `AGENT_TOOL_RESULT_PROMPT_LIMIT`, `AGENT_RUN_RESULT_LIMIT`, `AGENT_PIPE_CAP`, `AGENT_AUDIT_TEXT_LIMIT`. A realistic payload flows through whole; only a pathologically large payload is still bounded so the context window can't actually blow. The resume path no longer pre-truncates a tool result to the audit limit before re-feeding it to the model — it passes the full result and lets `formatToolResultForPrompt` bound it, so a resumed run sees the same connector data a fresh call would. Coverage: `test/unit.js` `tool results are truncated before the next agent LLM step` (rewritten: an 8k connector payload passes through *untruncated*; a 250k payload is still bounded) + `swarmRunner: a realistic connector payload flows through the pipe UNTRUNCATED`.

**RAG corpus targeting.** `rag_search` takes an optional `corpus` param (a single corpus slug, e.g. `"revops"`, `"resume"`) to scope a call to one corpus; omit/empty to search all corpora (the original behavior). Results are labeled with their `corpus_slug` and the summary echoes the corpus actually searched, so a fallback (named slug didn't match a dir) is visible. **Per-workflow binding:** a workflow can carry a `corpora` field (array of slugs); when non-empty, `rag_search` restricts its fan-out to that set unless a call names a corpus explicitly — so "use the RevOps corpus to rule out ideas I've already written" pins the workflow to `corpora:["revops"]`. The AI workflow generator enumerates available corpora (`corpusManager.listCorpora`) into the authoring prompt and adds a `rag_search` behavioral hint (chat + workflow) listing the exact slugs, so the model emits the right slug and sets `corpora`. The operator must populate `corpora/<slug>/rag_chunks.jsonl` (e.g. via the corpus rebuild flow) for a slug to be targetable. Coverage: `testGroup("Connectors + RAG targeting + Checkpoint")`.

**Correctness checkpoint (needed tools → green → saved → permissions).** The "Generate workflow from AI" panel has an optional **Expected response** field (acceptance criteria). After a **Run test**, the checkpoint panel surfaces **tools declared vs actually invoked** during the run (flagging declared-but-unused clutter and used-but-undeclared tools — the runner doesn't enforce the `tools[]` allowlist at exec, so the mismatch is surfaced for you to reconcile before save), plus an **LLM-as-judge** verdict (green/red/amber) comparing the run output to your expected response. `lib/workflowJudge.js` reuses the inference gateway + router model (`JUDGE_MODEL`, defaults to the cloud router model) with a tight JSON prompt; it is **fail-safe** — any error/timeout/unparseable verdict degrades to amber "judge unavailable", never a silent green. On **Save**, the response includes an explicit **"Permissions granted for: …"** line (the saved workflow's `tools` + `constraints.autoApprove`, which skip per-call approval at run because validation already vetted them) plus `correctnessOk` / `correctnessWarning` / `correctnessUnavailable`. Save is **never hard-blocked** by a red verdict — you retain final judgment; the green path is the clean one. Routes: `POST /api/workflows/judge-run {workflowId, runId, expectedResponse}` → `{verdict, toolsInvoked, declaredTools}`. Coverage: `testGroup("Connectors + RAG targeting + Checkpoint")` (pure units; end-to-end judge + save gating are manual verification).

**Where the card lives + why it can look missing.** The Google Connectors card is rendered dynamically into the Admin panel by `public/app.js` (`loadGoogleConnectors`, the `#googleConnectorsCard` admin card), **not** hardcoded in `index.html`. It is split into two clearly-labeled sections — **"Google OAuth App Setup"** (admin) and **"Google Account Connection"** (user). The Connect button is disabled with the message *"Google OAuth app config is missing. Complete setup first."* until the setup is complete; once complete it opens the Google consent page (`window.open(authUrl, "_blank")`). Tokens persist to the gitignored credentials file; refresh is transparent. If the card isn't visible, you're running a stale `app.js` — see the rebuild/bind-mount note below.

**Rebuild + bind-mount note (Docker).** Client assets (`/app.js`, `/styles.css`, `/markdown.js`, `/workflows.js`, `/workflowGenerator.js`) are now served with `Cache-Control: no-cache` (`routes/static.js`), so a rebuilt image or a bind-mounted edit shows up on the next hard refresh instead of being masked by a cached `app.js`. To see the connectors card after the Phase 6 changes:
- **One-time:** `docker build -t private-ai:latest . && docker compose down && docker compose up -d`, then browser hard-refresh with cache disabled.
- **Dev (`docker-compose.dev.yml`):** the repo is bind-mounted to `/app` (covers `public/`, `server.js`, `lib/`, `routes/`, `scripts/`), so after the one-time rebuild, code changes need only `docker compose restart` + a hard-refresh. Only `package.json` dependency changes require `scripts/dev-container.sh rebuild` (the anonymous `dev-app-node-modules` volume preserves the image's Linux-built `node_modules` / better-sqlite3 native bindings).

Live testing requires the user to provide real Google OAuth credentials (create a Desktop OAuth client in Google Cloud Console, enter the client ID/secret in the **Google OAuth App Setup** section); the query/day-limit + auth-URL + state-CSRF + token-storage + two-layer config/storage logic is covered by mock-fetch unit + integration tests now.

---

## Key configuration files

| File | Purpose |
|------|---------|
| `settings.json` | Runtime settings (showFullContext, imageModel) |
| `model_capabilities.json` | Model tool-calling tiers + vision flags (runtime, gitignored) |
| `model_preferences.json` | Per-taskType model usage counts |
| `workflows.json` | Workflow definitions |
| `chats.sqlite` | SQLite conversation store (primary) |

---

## Testing

The test runner in `test/unit.js` is a zero-dependency harness using Node's `assert` module. `test/integration.js` boots `server.js` on an isolated temp directory (no Ollama needed). `gateway/test/unit.js` covers the inference-gateway overflow/memory/queue logic. Current state: **506 unit + 26 integration + 21 gateway tests** (`npm run test:all`).

Unit coverage includes template-literal escaping (critical — `server.js` builds HTML pages with backticks), context-pipeline signal detection, router prompt building/parsing + capability-aware fallback, prompt-builder output, RAG search, web-search dedup, conversation utilities, model-capability classification, store operations, sandbox/security hardening, image-artifact handling (routing, vision guardrail, uploaded-photo routing, sandboxed tracking layer), attachment converters (round-trip `.docx/.xlsx/.pptx/.rtf/.epub` extraction via `chunk_articles.py`, self-skipping when a Python dep is absent), context audit (per-section breakdown, bloat/duplication/KV-cache warnings, date-trails-last ordering, system-message safety valve), the dream/memory system (Ebbinghaus decay + floors, FSRS strength growth, bi-temporal invalidation, prune/rescan, cosine top-k recall + recency fallback, `<memories>` slice budget cap, legacy `current.md` migration, candidate parsing, the high-risk classifier, and the triple auto-run gate), and the Google connectors (OAuth auth-URL build, code exchange + refresh, token file round-trip, the two-layer app-config file: `enabledScopes`/`validateAppConfig`/`redactAppConfig`/`loadAppConfig`+`saveAppConfig`+`clearAppConfig` round-trip/`revokeToken` best-effort/migration merge+strip, Gmail day-limit query builder, Calendar window builder, mock-fetch listing + 401 handling). **Post-ship fix-round coverage** (WS1–WS7): startup service readiness + Python-bin resolution + attachment spawn-ENOENT safety, prompt-optimizer referent preservation + ≤4-word follow-up skip, `buildRecentContext` image-turn annotation, `imageArtifacts` mimeType round-trip + inline attachment rendering, stable-only `buildSystemSections` + `buildVolatileSections` + per-section `capSection` + post-compaction audit + a byte-identical stable-prefix fixture (proves the prefix cache stays hot), `chooseModelByCapability` general tiebreak (qwen3:14b over gemma4) + coding-fallback-no-uninstalled-model + router examples reference only installed models, pure no-approval `autoApproveCandidates` (high-risk written, no queue) + `undoLastDreamBatch` + `appendMetaMemory` (atomic + dedup) + `memory_store`/`memory_ask` tools, and the dynamic model-dropdown + routing-trace wiring. **Chat-fluidity coverage**: conversational follow-up detection (`isConversationalFollowUp`) + web-signal suppression for recovery follow-ups, `detectReasoningSignals` + router-prompt steering away from fast models for opinion/synthesis, follow-up-aware source-priority rules + web-context demotion (`buildSourcePriorityRules`/`buildWebContext`), word-boundary skill matching (the "format"≠"information" guard against substring false positives), `readMostRecentRawRecord` returning errored turns that the visible reader filters out (JSONL + SQLite), and inline topic resolution for any model selection (`buildTopicResolutionNote`) — fires on a short/anaphoric follow-up with history (Jill Biden "recent data" regression), names the prior topic inline in the user request, skips genuine new-topic openers (`Tell me a joke`, `weather in <place>`), and is opt-out via `CHAT_TOPIC_RESOLUTION=false`; covered in both flat (`buildFinalPrompt`) and structured (`buildChatMessages`) prompt paths. **Continuity (all models)** coverage: the `lib/continuity.js` facade (L0–L6) — all four layers + `hasHistory`, chat structured/flat topic survival, agent first-user seeding, the L5 cross-model-switch deep-equal invariant (qwen3.6:35b / gemma4 / glm-5.2:cloud yield byte-identical `recentRecords`), byte-identical chat structured/flat output before vs after the facade, fail-safe throw, the KV-cache invariant (topic note in the user tail only, never the system prefix), and no-`conversationId`. **Workflow output modes** coverage: `outputMode:"file"` (file contents returned / missing-file fallback / sandbox-escape rejected), `"structured"` (valid `deliver` rendered through the template, invalid `deliver` feeds errors back and retries bounded by `maxSteps`, no-`deliver` fallback with `fallbackReason:"structured_deliver_not_called"`), `"conversation"` unchanged (byte-identical regression guard), the `{{field}}` / `{{#each}}` template renderer, and the JSON-Schema-subset validator. Integration coverage includes the two-layer connector app-config PUT (writes the gitignored config file, secret never echoed, `connectors` absent from `settings.json`), admin status no longer exposing the app config, the status/start (enabled-scopes auth URL, setup-incomplete 400)/callback (state-CSRF) routes, the dream auto-run gate, and `Cache-Control: no-cache` on `/app.js` + `/styles.css` (WS7).

To add a test, add a `testGroup("name", fn)` block with `test("description", fn)` assertions inside.

---

## Development rules (working in this repo)

- **Preserve existing functionality** unless explicitly asked to remove it. In particular, do not break: Auto model mode, dynamic Ollama model loading, task-type selection, memory/context checkboxes, the writing skill, article RAG, selected web-result routing, or existing CSS styling.
- **No public internet exposure** — LAN-first, private/local by default. Binding to `0.0.0.0` is correct for LAN access; do not change it to localhost-only unless explicitly asked.
- **No auth bypasses** — CSRF on all mutating requests; private-client check on admin endpoints.
- **No broad shell execution** — sandboxed filesystem, explicit permissions, allowlist.
- **Do not wire agents directly to the real filesystem over LAN.** Use sandboxed project directories, explicit permissions, approval gates, and no broad shell execution by default. Agents may work on sandboxed copies before touching the live harness.
- **Small safe changes over clever rewrites** — discuss architecture before larger changes; no large rewrites unless specifically requested.
- **Keep it modular** — new features go in `lib/`, routes in `routes/`. `server.js` remains the main orchestrator/stable control plane unless explicitly changed.
- **Template-literal escaping** — `server.js` uses template literals for page HTML; backticks in content must be escaped to avoid syntax errors (see `test/unit.js` for patterns).
- Prefer small, safe changes. Do not guess — if unsure, say so. Call out risk before suggesting anything that increases exposure.

---

## Security rules

Do not introduce: public exposure, auth bypasses, unsafe file execution, broad shell access, unrestricted filesystem access, or direct real-filesystem agent execution over LAN.

Default posture: LAN-first, private/local, no public internet exposure by default, sandboxed file work only, explicit approval for destructive changes. Call out risk before suggesting anything that increases exposure.

---

## Post-audit security + correctness fixes (this change set)

A security/operational audit surfaced the items below. **No user auth was added** — every fix stays inside the README's LAN-first / CSRF / private-client / sandbox model. Each is reflected in the relevant section above and is test-covered.

**P1 — Docker/private-IP access control.** `deploy-customer.sh` now accepts `BIND_HOST` (default `0.0.0.0`) and publishes `-p "$BIND_HOST:$HOST_PORT:3000"`, so production can bind the app port to the LAN/VPN interface IP instead of all interfaces. Keeps the app off the public internet without adding a login. (See *Publishing the app port on a non-public interface*.)

**P1 — Inference gateway exposure.** The gateway now has a request-body cap (`GATEWAY_MAX_BODY_BYTES`, rejected early on `Content-Length`), a per-IP rate limit on `/api/generate` + `/api/chat` (`GATEWAY_RATE_LIMIT_PER_MIN`), and a `GATEWAY_HOST` bind option. The compose gateway is **no longer published** to the host (app replicas reach it over the internal network); the `deploy-customer` + `GATEWAY_URL=host.docker.internal` topology that requires publishing is documented as needing a firewall to the Docker bridge / VPN only. (See *Inference gateway + OOM/cloud overflow*.)

**P1 — Manual agent workflow filesystem + approval boundary.** `file_write` / `shell_exec` carry a **hard approval floor** (`isApprovalRequired`) bypassable via explicit `autoApprove`, *plus* a runtime rule (`runtimeNeedsApproval`) that a workflow's own declared tools are authorized at save time and run without per-call approval unless `requireApproval: ["all"]` is set — so a vetted generated workflow no longer stalls mid-run at a `file_write` step waiting on a per-call approval. `workspaceDir` is rejected at save time if absolute or parent-traversing (`sanitizeWorkflow`), and confined under `AGENTS_DIR` at run time (`buildAgentWorkflowPaths` → `ensureInsideDir`) — containment is enforced regardless of approval. Applies to **all** workflows, not only AI-generated ones. (See *Agent / Workflow system*.)

**P2 — Horizontal-replica coordination.** The `1 gateway + 5 app replicas` compose shape is marked `⚠️ NOT COORDINATION-SAFE` (per-process schedulers/locks + shared `/data` → double-runs and state races). Documented: run one replica, or externalize coordination (single scheduler / durable locks / shared queue). (See *Horizontal-replica coordination*.)

**P2 — Large request buffering.** The app rejects oversized bodies **early on `Content-Length`** before buffering (central dispatcher, 413 with the body drained), `MAX_BODY_BYTES` is now env-configurable, and `readBody`/`readRawBody` keep the running-byte cap as the chunked-transfer backstop. (See *`MAX_BODY_BYTES`* in the env table.)

**Correctness — Google agent tools.** `lib/agentTools.js` `google_calendar_list` / `google_mail_recent` called the async `readConnectorToken(...)` without `await`, so `access_token` was always `undefined` and both tools failed at run time. Now awaited.

**Correctness — SQLite ABI drift.** Loud fallback banner + `/admin/health` surfaces the real active store type and flags a silent SQLite→JSONL fallback. (See *SQLite ABI-drift guard*.)

**P3 — RTF extraction.** `chunk_articles.py`'s `_rtf_to_text` used an invalid `%b` format specifier (a `ValueError` on every control-group strip), so `.rtf` uploads crashed extraction instead of degrading. Fixed to `%s`; round-trip `.rtf` extraction + control-group stripping now pass.

---

## Prompt architecture (direction)

Avoid sending unnecessary prompt mass to expensive execution models. Stable system prompts, workflow prompts, tool rules, style guides, and reusable context should be linted, compressed, cached, or retrieved selectively where possible. Optimize reused prompts first, not one-off prompts.

Prompt optimization should detect: duplication, contradictions, low-signal prose, overlong context, repeated rules, uncached stable text, unnecessary RAG payloads. Do not silently rewrite production prompts — show token count, estimated savings, risk level, and a candidate compressed version, and A/B test the compressed version against the original before it becomes the saved default.

---

## Model comparison & workflow cards (direction)

The product should let users/admins select 2–3 models, run the same task, compare outputs, score against a customer-specific rubric, and save the winning route. The key question: *can this workflow be done on a cheaper model with production-level results?* Start with manual scoring; add automatic scoring later.

Each saved workflow route should eventually include: workflow name, input type, required tools, allowed models, default/fallback/escalation models, rubric, examples of good outputs, known failure modes, cost target, latency target, prompt template, context priority, approval requirement. The routing layer should learn from real workflow performance, not generic benchmarks.

---

## Agents / DeepAgents (direction)

Treat DeepAgents or similar frameworks as a possible agent *runtime* layer, not the product. They may be useful for planning, task state, subagents, context compression, filesystem-style workflows, coding/repo workflows, tool orchestration. Local LLM Hub still owns UI, LAN access, projects, model routing, workflow routing, RAG/web priority, prompt assembly, security boundaries, approval gates, logs, evals, and customer-specific configuration. Do not wire agent frameworks directly to the real filesystem over LAN.

---

## GCP deployment

The app is deployed repo-based (no Docker) on a GCP GPU instance, accessed via WireGuard tunnel. The tunnel assigns `10.x.x.x` addresses, so the existing `isPrivateClientAddress()` check works without modification. Ollama runs on the same box on localhost; SearXNG runs on the same box (or the DuckDuckGo fallback is used).

All writable runtime paths (chat store, corpora, memory, logs, agents, artifacts) are env-configurable so a deployment can point them at persistent volumes instead of the repo directory. The CSP `img-src`/`connect-src` Ollama origin is derived from `OLLAMA_BASE_URL` at startup (`lib/securityHeaders.js`), so a GPU cluster where Ollama is not on localhost relative to the browser still gets a working policy. For VPNs using non-RFC1918 ranges (Tailscale), set `TRUSTED_CLIENT_CIDRS` so the LAN gate admits those clients.

---

## Deployment modes & two-repo split (CPU VM + swappable GPU)

Private AI deploys across **two boxes in two separate git repositories** — this one and `../private-ai-gpu/`, each with its own remote and history (not a branch, not a submodule):

- **This repo (CPU)** — the always-on GCP VM: the app, the inference gateway, the workflow runner, and the **CPU→GPU forward SSH tunnel**. Owns **all** policy (`lib/sovereignty.js` `LOCAL_ONLY_MODE`/`allowCloud`, the router, capability maps, the adapter auto-author startup pass).
- **`../private-ai-gpu/`** — a **standalone repo you clone separately** (a sibling directory), holding only the swappable GPU box (any SSH-reachable host running Ollama — e.g. vast.ai, RunPod, Lambda, or a bare box). It does exactly three things: installs Ollama, pulls the fleet models, and runs `ollama signin` so `:cloud` models work. **It owns no app policy and no tunnel.** See its own README for the full guide.

The GPU box is *swappable*: when your GPU provider reassigns the instance (or you move to a different host), you just re-run `scripts/setup-vast-tunnel.sh <new-host> <new-port> [ssh_key]` on the CPU (the SSH port is provider-assigned and changes on swap). The app's `GATEWAY_URL` never changes; the app/gateway's `OLLAMA_BASE_URL` (`http://host.docker.internal:11434`) never changes.

**CPU cloud-bridge fallback.** When the GPU box is down (swapped, crashed, reaped), the gateway's circuit opens and even `:cloud` models would fail — so a **second, lightweight Ollama on the CPU VM** serves `:cloud` models (a `:cloud` "pull" is a tiny stub; the weights live in Ollama's cloud, no GPU needed). `scripts/setup-cpu-ollama.sh` brings it up one-touch (`ollama signin` prints a URL you approve once; the credential is held in a named volume so it survives recreates). Point the gateway's `CLOUD_BRIDGE_URL` at it (`http://host.docker.internal:11436`) and the existing cloud-fallback paths route there instead of failing; set `GATEWAY_HEALTH_URL` (`http://host.docker.internal:11435/healthz`) on the app to surface the GPU-offline banner. The GPU, when it returns, resumes serving **local** models; `:cloud` simply always goes via the CPU Ollama now. `LOCAL_ONLY_MODE` still holds — the app stamps `X-Private-Local-Only: 1` and the gateway suppresses its cloud fallback for that request, so a local-only deploy + GPU down + a local model in `OVERFLOW_MAP` returns an honest `local_unavailable`, never a silent cloud leak. Full runbook + drill: `DEPLOYMENT-GUIDE.md` §4e-quinquies.

### Three inference modes

At boot, `server.js` prints `[inference] mode=… inference=… tags=…`, and the gateway prints `mode: gateway-upstream`. Which mode you're in is unambiguous:

| Mode | Set by | Path | Used for |
|------|--------|------|---------|
| `dev-direct-ollama` | `GATEWAY_URL` unset, `OLLAMA_BASE_URL`=host/tunnel | `app → OLLAMA_BASE_URL` (host/tunnel Ollama) | local dev; **customer direct-to-tunnel** (`OLLAMA_BASE_URL=http://host.docker.internal:11434`, no gateway) |
| `deployed-gateway` | `GATEWAY_URL` set | app → gateway:11435 → `host.docker.internal:11434` → tunnel → GPU | production with OOM/cloud-overflow fallback |
| `gateway-upstream` | (gateway boot log) | gateway → `OLLAMA_BASE_URL` (`host.docker.internal:11434`) | the gateway's own view of its upstream |

`/api/tags` (model discovery) and embeddings **always** bypass the gateway (`server.js:301`), so model discovery keeps working even if the gateway is down.

### The inference path

There are two deployed shapes. Both reach the GPU through the **same** CPU-side
tunnel container (`private-ai-ollama-tunnel`, created by `scripts/setup-vast-tunnel.sh`),
which publishes `0.0.0.0:11434` on the CPU host; app/gateway containers reach it
at `http://host.docker.internal:11434` (via `--add-host=host.docker.internal:host-gateway`).

```
customer direct-to-tunnel (simplest — no gateway):
  private-ai app ──OLLAMA_BASE_URL──▶ host.docker.internal:11434 ─▶ private-ai-ollama-tunnel ─▶ GPU Ollama 127.0.0.1:11434

deployed-gateway (with OOM/cloud-overflow fallback):
  private-ai app ──GATEWAY_URL──▶ private-ai-gateway:11435 ──OLLAMA_BASE_URL──▶ host.docker.internal:11434
                                                                                       │
                                                                                       ▼
                                                              private-ai-ollama-tunnel  (autossh -L 0.0.0.0:11434:127.0.0.1:11434, CPU→GPU)
                                                                                       ▼
                                                              GPU box Ollama  127.0.0.1:11434  (never public)
```

- The **gateway** (when used) publishes `11435` on the host (the app reaches it via `host.docker.internal:11435`); it must stay off the public internet (WireGuard/LAN/VPN only). In direct-to-tunnel mode there is no gateway — the app talks to the tunnel directly.
- `11434` (the tunnel/Ollama port) **is** published on the CPU host as `0.0.0.0:11434` — deliberately, so app/gateway containers can reach it through `host.docker.internal`. (A loopback-only `127.0.0.1:11434` bind would NOT be reachable from a container via `host.docker.internal`.) The CPU host itself is WireGuard/LAN/VPN-only, so 11434 is never on the public internet.
- The **tunnel** is `autossh` run directly (via `--entrypoint /usr/bin/autossh`) in a standalone `private-ai-ollama-tunnel` container, created one-touch by `scripts/setup-vast-tunnel.sh`. It forwards `0.0.0.0:11434` on the CPU to the GPU's `127.0.0.1:11434`. No `ROLE=tunnel`, no `private-ai-infra` network, no `ollama-proxy` alias.

Swap the GPU box: re-run `sh scripts/setup-vast-tunnel.sh <new-host> <new-port> [ssh_key]` on the CPU (the SSH port is provider-assigned and changes on swap). The app/gateway's `OLLAMA_BASE_URL=http://host.docker.internal:11434` doesn't move. Nothing else changes.

### Reading "LLM call failed" — which layer died?

Every inference response (success **or** failure) carries three attribution headers, and failures carry the same fields as JSON in the body:

- `X-Private-Request-Id` — a per-request correlation id (`crypto.randomUUID()`); echoed on the response and forwarded to the upstream so you can match a failure across the app log, the gateway log, and the Ollama/GPU log.
- `X-Inference-Source` — `gateway` (came through the gateway) or absent (direct Ollama / transport).
- `X-Inference-Error-Class` — **which layer** failed (the table below). Also in the error JSON as `error_class`, alongside `request_id`.

The thrown error in the app is prefixed so it's readable at a glance: `[inference:<source> <errorClass> rid=abc123] <body>`. `lib/agentRunner.js` folds `err.inference.source` + `errorClass` + `requestId` into the "LLM call failed" message and into `run.json`, so a failed agent run records which layer died.

Map `error_class` to the failing layer:

| `error_class` | Failing layer | Meaning / what to check |
|---------------|---------------|-------------------------|
| `upstream_oom` | **Upstream (GPU)** | The GPU Ollama returned a CUDA/GPU out-of-memory. Model too large for VRAM, or too many in flight. The gateway reached it fine. |
| `upstream_failure` | **Upstream (GPU)** | The GPU Ollama returned a non-OOM error (model not found, 500, malformed response). Gateway reached it; GPU rejected the request. |
| `upstream_timeout` | **Upstream (GPU)** | The upstream call aborted/timed out (the gateway's upstream timeout fired). GPU slow or hung, not the transport. |
| `circuit_open` | **Gateway** | The gateway's overflow circuit is open (the local upstream is failing repeatedly, so the gateway refused to try again this turn). A gateway-level decision, not the GPU. |
| `local_unavailable` | **Gateway** | Local inference was down and no cloud fallback was configured (`CLOUD_BRIDGE_URL` unset **and** no `OVERFLOW_MAP` target). Gateway could not route the request at all. |
| `cloud_not_configured` | **Gateway** | A `:cloud` model was requested, but neither `CLOUD_BRIDGE_URL` nor a reachable GPU Ollama serving `:cloud` is available. (In your setup the GPU Ollama serves `:cloud` after `ollama signin`, so this usually means the GPU isn't signed in or the tunnel is down.) |
| `rate_limited` | **Gateway** | The per-IP gateway rate limit (`GATEWAY_RATE_LIMIT_PER_MIN`) tripped. Gateway policy, not the GPU. |
| `gateway_error` | **Gateway** | The gateway itself threw (not an upstream failure). A bug/crash in the gateway. |
| `timeout` | **App (transport)** | A direct (non-gateway) Ollama call hit the app-side 5-min `DEFAULT_TIMEOUT_MS`. Only seen in `dev-direct-ollama` mode. |
| `transport_unreachable` | **Transport** | The fetch itself failed (`ECONNREFUSED` / DNS / network) — the app could not reach the gateway at all (gateway down), or in direct mode could not reach Ollama. Distinct from `upstream_*`: nothing answered. |

The fast triage: **`transport_unreachable`** → the gateway/tunnel is down or the app can't reach it (network/transport). **`upstream_*`** → the gateway reached the GPU, but the GPU rejected/timed-out/OOM'd the request (the tunnel is fine; the GPU or the model is the problem). **`circuit_open` / `local_unavailable` / `cloud_not_configured` / `rate_limited` / `gateway_error`** → the gateway made a decision or hit its own limit (look at the gateway, not the GPU).

**Cloud-blocked is NOT an inference failure.** `lib/sovereignty.js` gates `:cloud` *before* any request leaves the app. A `LOCAL_ONLY_MODE` turn that requests `:cloud` surfaces as `cloud_blocked` (policy) and runs a local model instead — it does **not** become "LLM call failed". This is the "cloud-not-allowed is app policy, not the GPU box" guarantee, and it's unit-tested.

### GPU box: `../private-ai-gpu/`

`private-ai-gpu` is a **standalone git repository of its own** — its own remote, its own history, its own commits. It is **not a branch of this repo and not a submodule**; you do not get it by checking out a branch here. Where it gets cloned depends on context:

- **Dev (both repos on your laptop):** clone it as a sibling next to this one —
  ```sh
  git clone <your-private-ai-gpu-remote> ../private-ai-gpu   # its own repo, alongside this one
  ```
- **Production:** clone it **onto the GPU box itself** (never the CPU VM) — see DEPLOYMENT-GUIDE.md §4d-bis. The `../private-ai-gpu` path in this README is the dev-laptop sibling view; on the actual GPU box it's just `private-ai-gpu` cloned there directly.

It installs Ollama, pulls the fleet models from `models.yml` (aligned to this repo's CPU adapters), runs `ollama signin`, and prints the env the CPU side needs (`VRAM_TOTAL_GB` + a `MODEL_SIZES` skeleton). It binds Ollama to `127.0.0.1:11434` (refuses `0.0.0.0`), owns no tunnel, and owns no policy. The two repos are coupled **only at the seam**: `models.yml` must match this repo's fleet, and `print-cpu-env.sh`'s output feeds the CPU gateway config. See **`../private-ai-gpu/README.md`** and **DEPLOYMENT-GUIDE.md §4d-bis / §4e** for the full bring-up.

---

## Docker customer deployment

> **New to containers / the gateway / the router?** Read **[DEPLOYMENT-GUIDE.md](./DEPLOYMENT-GUIDE.md)** first — it's the beginner walkthrough for migrating your Mac to Docker, the GitHub update loop, standing up the VM, and the "did I forget a setting?" guardrail. This README section is the reference; the guide is the step-by-step.

A clean multi-customer deployment model: **one shared image, many customers**, each isolated by a mounted `/data` volume and a `.env` file. The image carries code + `node_modules` only — no customer data, no customer config, no `.env`. Customers never fork the repo, never `git pull` inside a container, and never run `npm install` at deploy time (dependencies are baked into the image at build time).

### Architecture

- **One image** — `private-ai:latest` — built once from the base repo (`scripts/build-image.sh`). Every customer container runs it.
- **Per customer**: a directory `/opt/private-ai/customers/<slug>/` holding only `data/` (mounted at `/data`, persistent) and `.env` (the container's env, persistent). Customer-specific state lives **only** in those two places.
- **Shared services, one of each per VM**: Ollama runs as a host process (uses the GPU directly); SearXNG runs in its own container, published on the host with `-p 8080:8080`. Neither needs to run "bare on the host" — what matters is that each is reachable at the host's published port. Each customer's `.env` points `OLLAMA_BASE_URL` and `SEARXNG_URL` at those ports via `host.docker.internal` (a Docker-injected alias for the host, created by `--add-host=host.docker.internal:host-gateway` — not a DNS name, not the VM's WireGuard `10.x` address, no DNS setup needed). One Ollama serves all customers. Two VM-install gotchas validated on GCP Ubuntu L4 (both handled by `scripts/vm-install.sh`): (a) Ollama's systemd unit defaults to `127.0.0.1:11434`, which is **not** reachable from a container via `host.docker.internal` — install a `0.0.0.0:11434` override (`/etc/systemd/system/ollama.service.d/override.conf`) and verify with `ss -ltn | grep 11434`; (b) the stock `searxng/searxng` image ships `formats:[html]` only and its limiter 403s requests without `X-Forwarded-For`, so mount a `settings.yml` (`formats: [html, json]`, `limiter: false`) instead of patching in-container. And `/opt/private-ai` must be created + chowned to the operator once (`sudo mkdir -p /opt/private-ai/customers && sudo chown -R $USER:$USER /opt/private-ai`) before the first `deploy-customer.sh` — the script now fails early with this exact fix if it isn't. Full steps: `DEPLOYMENT-GUIDE.md §4a/§4d`.
- **Health check is `/admin/health`, not `/health`** — there is no `/health` route (`routes/health.js` serves `/admin/health`); `/health` returns the app shell, not the JSON report. Verify a deploy with `curl -i http://<host>:<port>/admin/health` (expect `"ok": true` + empty `warnings`). Also note `docker ps` showing `11435/tcp` (no `->`) is just image `EXPOSE` metadata, not an exposure — only host-**published** ports (`0.0.0.0:3000->3000/tcp`) are reachable from the host; app customers never publish 11435, only the optional gateway does. (The runner's `GET /health` is a separate UNauthenticated endpoint on `:3100` used only as the runner container's Docker `HEALTHCHECK` — it is never published to the host either; `3100/tcp` in `docker ps` is the same EXPOSE-metadata-not-an-exposure pattern.)
- **Two containers per customer: app (non-privileged) + runner (`ROLE=runner`)** — the same image runs both. The app publishes `:3000` and mounts the whole customer `data/`; the runner carries the bwrap security profile, mounts ONLY `workflow-sandbox` (rw) + `workflow-templates`/`capabilities` (ro) + the host `ollama` CLI, and listens on `:3100` internally (never published). They share the host `$DATA_DIR/workflow-sandbox` directory mounted at the identical container path `/data/workflow-sandbox`, so the app and runner see byte-identical `runDir`s. Customer secrets (`.env`, `connectors-credentials.json`) never enter the runner. `docker-compose.yml`'s `runner` service is the demo/load-test shape; `scripts/deploy-customer.sh` is the production path with minimum mounts.
- **No cross-customer leakage**: each container mounts only its own `data/` — never the parent customer directory, never the Docker socket.
- **Image is customer-agnostic**: `.dockerignore` excludes `settings.json`, `workflows.json`, `model_capabilities.json`, `model_preferences.json`, `skills/`, all chats/sqlite/logs/corpora/artifacts/memory/agents, backups, and `.env`. Verified at build time that none of these enter the image. The startup diagnostics (`Resolved writable paths:` log line) confirm every writable path resolves under `/data` and is writable.

### Writable-path audit

Every writable runtime path is env-configurable and, in a container, routed to `/data`:

| Path | Env var | In container |
|------|---------|-------------|
| Chat JSONL / SQLite | `CHAT_LOG_PATH` / `CHAT_SQLITE_PATH` | `/data/chats.jsonl`, `/data/chats.sqlite` |
| Corpora / memory / logs | `CORPORA_DIR` / `MEMORY_DIR` / `LOGS_DIR` | `/data/...` |
| Agent runs / artifacts | `AGENTS_DIR` / `ARTIFACTS_DIR` | `/data/agents`, `/data/artifacts` |
| Skills | `SKILLS_DIR` | `/data/skills` |
| Usage / capabilities / prefs | `USAGE_PATH` / `MODEL_CAPABILITIES_PATH` / `MODEL_PREFERENCES_PATH` | `/data/...` |
| Settings / workflows | `SETTINGS_PATH` / `WORKFLOWS_PATH` | `/data/settings.json`, `/data/workflows.json` |

At startup the server logs each resolved path with an `OK`/`FAIL` writability probe and warns (non-fatal) on any that aren't writable. The app tolerates absent config files (`readSettings`/`readWorkflows`/`loadCapabilities` fall back to built-in defaults), so a fresh `/data` boots cleanly; `deploy-customer.sh` seeds the repo's default config + skills into `/data` on first deploy so a new customer starts with the full default set.

**Service-readiness guardrail:** alongside the writable-path probe, startup also runs `lib/startupChecks.js`, which detects container mode and probes Ollama + SearXNG. If a required service URL is still at a container-broken default (e.g. `OLLAMA_BASE_URL=http://127.0.0.1:11434`, which inside a container points at the container itself) or unreachable, it prints a loud **SERVICE READINESS** banner naming the exact `.env` var and value to fix — so a forgotten/mis-set var can't silently fall back to a broken default. This never crashes the process (you can edit `.env` and `docker restart`). See DEPLOYMENT-GUIDE.md §5.

**SQLite ABI-drift guard:** the chat store defaults to SQLite (`CHAT_STORE=sqlite`, via `better-sqlite3`). The native binding can fail to load when it was compiled for a different Node ABI than the running Node (a node upgrade without `npm rebuild better-sqlite3`). `lib/store.js` then falls back to JSONL — correct for a single user but weaker for scale/concurrency (append-only, no SQL indexes). This fallback is now **loud**: the boot log prints a boxed `⚠️ SQLite chat store unavailable — FALLING BACK TO JSONL` banner with the `npm rebuild better-sqlite3` fix, and `/admin/health` reports the **actual** active store type + a failing `chat_store` check (`fellBack:true`, with the underlying error) instead of the previously-misleading `process.env.CHAT_STORE || "jsonl"`. Docker bakes the binding into the image so this mostly affects bare-metal node upgrades; the guard makes sure you notice. (`getStoreRuntimeStatus`, unit-tested.)

### Inference gateway + OOM/cloud overflow (optional — one shared gateway per VM)

**Is the gateway required?** No, for normal operation and for router-selected cloud models. **Yes, only for the OOM/cloud-overflow fallback.** This is not ambiguous — verified against the code:

- The **OOM/cloud-overflow fallback** — transparently rerouting a *local* request to its cloud equivalent when the model's queue is backed up (`QUEUE_WAIT_THRESHOLD`) OR VM VRAM available memory drops below threshold (`MIN_AVAILABLE_MEM_PCT`) — lives **only** in the gateway: `gateway/lib/overflow.js` (`decideOverflow`) wired into `gateway/server.js`. The app has no equivalent. The only `overflow` reference in the app is `lib/chatHandlers.js` *receiving* an `_overflow` marker if a gateway upstream set one; `lib/imageReview.js` explicitly comments "cloud overflow is the gateway's job." So: **app containers that call the VM Ollama directly never get OOM fallback** — a local request goes to the local model regardless of load.
- The app's own `allowCloud` is a **different** thing: it gates whether the *router* may *select* a `:cloud` model (or the user picks one from the dropdown). That works **without any gateway**, because the VM Ollama itself serves the `:cloud` tags (forwarding to your cloud bridge). So normal chat + router/explicit cloud selection need no gateway.

**If you want OOM fallback, the topology is exactly one shared gateway per VM** — never one per customer:

1. **VRAM/memory pressure is a VM-wide resource.** One GPU is shared by all customers through one Ollama. A single gateway polling Ollama `/api/ps` sees the true VM-wide memory state; per-customer gateways would each poll the same shared `/api/ps` (no isolation) and could disagree, while duplicating the polling.
2. **Queue-depth overflow must reflect aggregate load on the shared model.** One shared gateway counts in-flight requests across *all* customers against `QUEUE_WAIT_THRESHOLD`. A per-customer gateway would see only its own requests and stay blind to other customers loading the same model — so a hot customer could overload the shared model and no per-customer gateway would overflow.
3. **Usage metering is VM-wide capacity-planning telemetry** (it tells you when to expand GPUs). One shared gateway aggregates cloud spend across all customers; per-customer gateways would fragment it.
4. One stateless proxy to operate, restart, and version alongside the shared image — not N extra containers per customer.

A per-customer gateway would only make sense if each customer had its own isolated Ollama/GPU, which contradicts the shared-VM-Ollama architecture.

**Running the shared gateway** (same image, `ROLE=gateway`, one per VM):

```sh
# Build once (already done by scripts/build-image.sh — same image serves app + gateway).
# Run the single shared gateway, pointing at the VM Ollama + your cloud bridge:
docker run -d --name private-ai-gateway --restart unless-stopped \
  --add-host=host.docker.internal:host-gateway \
  -p 11435:11435 \
  -e ROLE=gateway \
  -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  -e CLOUD_BRIDGE_URL=<your-ollama-compatible-cloud-bridge-url> \
  -e VRAM_TOTAL_GB=24 -e MIN_AVAILABLE_MEM_PCT=15 -e QUEUE_WAIT_THRESHOLD=1 \
  -v llm-gateway-data:/data \
  private-ai:latest
```

**The gateway has no auth — keep it off the public internet.** It is an internal proxy; exposure must be enforced by the host firewall / reverse proxy / VPN, not by convention. Hardening shipped in `gateway/server.js` + `gateway/lib/config.js`:

- **Body cap** — `GATEWAY_MAX_BODY_BYTES` (default 20 MB). Oversized requests are rejected **early on `Content-Length`** before the body is buffered, with a running-byte backstop for chunked transfers.
- **Per-IP rate limit** — `GATEWAY_RATE_LIMIT_PER_MIN` (default 120) on `/api/generate` + `/api/chat`, so a single looping client can't monopolize local + cloud inference.
- **Bind interface** — `GATEWAY_HOST` (default `0.0.0.0`, which preserves the `host.docker.internal` topology where app containers reach it via the Docker bridge). Set `GATEWAY_HOST=127.0.0.1` when only same-host clients need it. The startup log prints a loud warning when bound to `0.0.0.0`.

These are **defense in depth**, never a substitute for keeping the published port off the public internet. **Avoid publishing the gateway port unless the topology requires it:**

- **Compose (`docker-compose.yml`)** — app replicas reach the gateway over the internal compose network (`http://gateway:11435`), so the gateway is **not** published to the host (`ports:` is intentionally absent). Do not add `ports: ["11435:11435"]` back unless you also firewall that port to the Docker bridge / VPN only.
- **`deploy-customer.sh` + `GATEWAY_URL=host.docker.internal:11435`** — this topology *does* require publishing 11435 on the host (the app container reaches it through the Docker bridge). In that case firewall the published port to the Docker bridge / VPN interface only (e.g. `iptables` allow from `172.16.0.0/12` + your WireGuard range, deny others), or prefer the internal-network compose topology where no publish is needed.

Then opt a customer into OOM fallback by pointing it at the gateway instead of Ollama:

```sh
GATEWAY_URL=http://host.docker.internal:11435 scripts/deploy-customer.sh acme 3001
# deploy-customer.sh prints: overflow: via gateway (OOM/cloud-overflow fallback ENABLED)
# the customer's .env gets OLLAMA_BASE_URL=http://host.docker.internal:11435
```

Customers deployed without `GATEWAY_URL` keep calling the VM Ollama directly (simpler, one fewer hop, no overflow) — that is a valid, supported configuration, not a degraded one. The `decideOverflow` policy, overflow map, and per-model pricing are all env-configurable on the gateway (`OVERFLOW_MAP`, `CLOUD_PRICING`, `CLOUD_BUDGET_USD`, `MEMORY_SOURCE`, etc. — see `gateway/lib/config.js`); the budget is **observability only and never gates routing**.

### Local development (non-Docker)

No Docker required. Clone, install the dependencies, run:

```sh
npm install                # installs better-sqlite3 (required) + mammoth/pdf-parse (optional extractors)
node server.js             # binds 0.0.0.0:3000, reads/writes in the repo dir
node test/unit.js          # unit tests
npm run test:all           # unit + integration + gateway suites
```

All writable-path env vars default to the repo directory, so local dev behavior is unchanged. Docker is an **additional** deployment path; it does not alter the local dev defaults.

### Run the same setup on your Mac in Docker (identical to the VM)

To develop against the *same* runtime the VM uses — the `private-ai:latest` image, the `/data` layout, and a `.env` — without leaving your bare-`node server.js` workflow behind:

```sh
scripts/migrate-local-to-customer.sh        # copies your current chats/settings/skills/etc. into a customer /data,
                                             # builds the image if needed, deploys private-ai-local on :3001
                                             # pointing at your Mac Ollama (host.docker.internal:11434).
```

Your live `node server.js` on `:3000` is untouched; the Docker customer runs on `:3001` so you can compare, then retire the bare-node workflow when ready. Customer root defaults to `~/private-ai/customers` on the Mac (override with `CUSTOMERS_ROOT`). Full walkthrough: DEPLOYMENT-GUIDE.md §2.

### Local Docker dev (live code edits, same container shape)

For day-to-day dev you want the *same* runtime as the VM but with your repo
live-mounted so edits land on restart — no image rebuild per edit. The committed
dev path is `docker-compose.dev.yml` + `scripts/dev-container.sh`: it uses the
**same `private-ai:latest` image** (so `bwrap` + the `ollama`/`claude` CLIs are
identical to prod), bind-mounts the repo to `/app`, bind-mounts `./dev-data` to
`/data`, and points at external Ollama/Gateway via `.env`. The workflow builder
still runs only through bwrap — no fallback.

```sh
cp .env.example .env          # edit OLLAMA_BASE_URL / GATEWAY_URL
scripts/dev-container.sh      # up (builds image if missing) -> http://localhost:3000
scripts/dev-container.sh logs # tail logs (watch the bwrap canary line at boot)
scripts/dev-container.sh rebuild   # after changing dependencies
```

`./dev-data/` and your real `.env` are gitignored (`.env.example` is the
committed template) and excluded from the image via `.dockerignore`. This dev
path is additive — `scripts/deploy-customer.sh` and the VM flow are unchanged.

`./restart.sh` restarts this dev container (not bare `node`) — it picks up your
bind-mounted edits. On Docker Desktop for Mac the dev compose also sets
`privileged: true` (bwrap can't mount `/proc` otherwise) and
`TRUSTED_CLIENT_CIDRS=0.0.0.0/0` (Docker Desktop NATs published-port traffic to a
non-RFC1918 source, which the LAN-first gate would otherwise 403 — even
localhost). Both are dev-only. **This dev compose runs in LOCAL bwrap mode** —
`WORKFLOW_RUNNER_URL` is intentionally UNSET, so the single dev container runs
`bwrap … scripts/workflow-builder.sh` itself (one container + a live bind-mount
of the repo is the whole point of dev). The REMOTE-RUNNER sidecar (separate
`ROLE=runner` container) is the **customer-deploy** path — see *Deploy a customer*
below and `docker-compose.yml` + `scripts/deploy-customer.sh`. Full walkthrough:
DEPLOYMENT-GUIDE.md §2e.

### Build the shared image

Run on the VM (or any Docker host), from the repo:

```sh
scripts/build-image.sh                          # builds private-ai:latest
scripts/build-image.sh --tag private-ai:1.2.0 # custom tag
```

The multi-stage `Dockerfile` builds the `better-sqlite3` native bindings in stage 1 and runs the slim `node:22-slim` runtime in stage 2. `npm install` runs **only** during build. The runtime stage also installs `python3` + `poppler-utils` + `antiword`/`catdoc` and `pip3 install -r requirements.txt` so document-attachment extraction (`.pdf/.docx/.odt/.doc/.rtf/.pptx/.xlsx/.epub` via `chunk_articles.py`) works in-container; each extractor still degrades gracefully to a placeholder if a dep is ever missing. The image contains no customer data or config (enforced by `.dockerignore`; the same image serves every customer).

### Deploy a customer

Run on the VM after the image exists:

```sh
# defaults: Ollama (host process) + SearXNG (its own container, -p 8080:8080),
# both reached from containers via host.docker.internal at their ports
scripts/deploy-customer.sh acme 3001

# or point at specific VM-shared services
OLLAMA_BASE_URL=http://10.0.0.5:11434 SEARXNG_URL=http://10.0.0.5:8080 \
  scripts/deploy-customer.sh acme 3001

# prompts for name + port if omitted
scripts/deploy-customer.sh
```

What it does:

1. Normalizes the customer name to a safe slug (`acme` → `acme`).
2. Verifies the customers root (`/opt/private-ai/customers`) is creatable + writable — fails early with the exact `sudo mkdir`/`chown` fix if `/opt` isn't owned by the operator (a fresh-VM gotcha; `vm-install.sh` sets this up).
3. Creates `/opt/private-ai/customers/acme/{data,.env}` and the `/data` subdirs (`memory logs agents artifacts corpora skills`).
4. Seeds the repo's default `settings.json`, `workflows.json`, `model_capabilities.json`, and `skills/` into `/data` **only if absent** (never clobbers existing customer edits).
5. Writes `.env` with every writable path pointing inside `/data`, plus `OLLAMA_BASE_URL`/`SEARXNG_URL`. Operator metadata (`# DEPLOY_HOST_PORT`, `# DEPLOY_IMAGE`, `# DEPLOY_CONTAINER`) is stored as comments in `.env` so `update-all-customers.sh` can recreate the container unchanged. Auto-generates a `RUNNER_TOKEN` (`od -An -N16 -tx1 /dev/urandom`) and persists it in the customer `.env` as `WORKFLOW_RUNNER_TOKEN` (the runner requires this Bearer secret on `/generate` + `/canary`).
6. Creates a per-customer Docker network `private-ai-net-<slug>` (idempotent).
7. Runs the **bwrap canary against the RUNNER** — a throwaway `--rm` container that runs `bwrap /bin/true` trying security profiles on a ladder. With `BWRAP_PRIVILEGED=true` the ladder runs **broadest-first** so the runner actually lands on `--privileged`: `--privileged` → `+SYS_ADMIN` → `seccomp=unconfined`; without the flag it stops at `seccomp=unconfined` (least privilege). The FIRST that passes becomes the runner's profile. The default `BWRAP_CANARY=fail` aborts the deploy before either container starts if no profile passes (surfaces a bad host immediately); `BWRAP_CANARY=warn` is opt-in to continue — the app always deploys + the runner deploys best-effort, and generation 503s with a clear reason while chat/RAG/auth/routing keep working. A broken runner is never deployed silently.
8. Runs `docker run -d` for the **RUNNER** container `private-ai-<slug>-runner`: `ROLE=runner`, on the network, with the chosen security profile, **narrow `-e` env flags** (NOT `--env-file` — customer secrets stay out of the runner), mounting ONLY `$DATA_DIR/workflow-sandbox:/data/workflow-sandbox` (rw), `$DATA_DIR/workflow-templates:/data/workflow-templates:ro`, `$DATA_DIR/capabilities:/data/capabilities:ro`, and the host ollama CLI bind `-v $HOST_OLLAMA_BIN:/usr/local/bin/ollama:ro` (optional version-pin — the image already ships the `ollama` CLI client, so this bind is NOT required; it overrides the image CLI with the VM host's when set). It does NOT mount wholesale `/data`, `.env`, chats, `connectors-credentials`, or the Docker socket. Adds `--health-cmd "curl -fsS http://127.0.0.1:3100/health"` + interval/timeout/start-period/retries. Port `3100` is internal-only (never published to the host).
9. Runs `docker run -d` for the **APP** container `private-ai-<slug>`: **NON-privileged** (drops the security profile entirely), on the network, `-p 0.0.0.0:<port>:3000`, `-v $DATA_DIR:/data`, `--env-file <customer .env>` (the `.env` carries `GOOGLE_CLIENT_SECRET` — kept OUT of the runner), with `WORKFLOW_RUNNER_URL=http://private-ai-<slug>-runner:3100` + `WORKFLOW_RUNNER_TOKEN` so the app delegates bwrap to the runner. Mounts **only** `data/`; never the parent dir, never the Docker socket, never `npm install`.
10. Prints the customer URL, container name, data path, and env path, plus a deploy-summary block (see below).

```
=== Deploy summary ===
app     : RUNNING  private-ai-<slug>   0.0.0.0:<port>:3000   (non-privileged)
runner  : RUNNING  private-ai-<slug>-runner   :3100 (internal)   bwrap profile: --security-opt seccomp=unconfined
bwrap   : canary OK (runner profile: --security-opt seccomp=unconfined)
network : private-ai-net-<slug>
```

`--print-plan` prints the exact `docker network create` + runner `docker run` + app `docker run` commands plus this deploy-summary block WITHOUT executing (honors `BWRAP_PRIVILEGED=true`, assuming the ladder reaches `--privileged`) — useful for verifying a deploy without a Docker daemon.

Re-running `deploy-customer.sh` for an existing customer preserves its `.env` (pass `--refresh-env` to rewrite it) and recreates the container against the current image — `/data` is untouched because it's a host bind-mount.

**Host-admin access note:** the LAN gate allows localhost + RFC1918 clients. A request made from the VM host through a published port appears to come from the Docker bridge gateway IP (in `172.16.0.0/12`, which the gate does not auto-allow). To administer a customer container from the VM host, either access it from a LAN client, or set `TRUSTED_CLIENT_CIDRS=172.16.0.0/12` in that customer's `.env` (then recreate the container). Access from real LAN/VPN clients works without this.

**Publishing the app port on a non-public interface (`BIND_HOST`):** the app has **no user auth** — the LAN gate (`lib/clientAccess.js`) is the only access control, and it rejects any request that arrives from a non-private source IP. As a belt-and-suspenders guard against a misconfigured host firewall or a renumbered interface, `deploy-customer.sh` accepts a `BIND_HOST` env var (default `0.0.0.0` = all interfaces, the original behavior) and publishes `-p "$BIND_HOST:$HOST_PORT:3000"`. **Production should set `BIND_HOST` to the LAN/VPN interface IP** (or put a firewall / reverse proxy with auth in front) so the published app port is never reachable from the public internet:

```sh
# Publish the app port ONLY on the LAN/VPN interface, not on the public interface:
BIND_HOST=10.0.0.5 scripts/deploy-customer.sh acme 3001
```

This stays within the LAN-first, no-user-auth security model — it tightens *where* the port is published, it does not add a login.

**bwrap canary + `BWRAP_PRIVILEGED` (AI workflow generator safety boundary):** the canary now targets the RUNNER container, not the app. `deploy-customer.sh` runs a throwaway `--rm` container that runs `bwrap /bin/true` in a user/mount namespace (never starts the app server) on a security-profile ladder: a) `--security-opt seccomp=unconfined` (default; most kernels), b) `--security-opt seccomp=unconfined --cap-add SYS_ADMIN`, c) `--privileged` (only with `BWRAP_PRIVILEGED=true`). With `BWRAP_PRIVILEGED=true` the ladder runs **broadest-first** (c→b→a) so the runner actually lands on `--privileged`; without the flag it stops at (a) (least privilege). The FIRST that passes becomes the **runner's** profile — the app container is NON-privileged regardless. On a GCP Ubuntu L4 kernel `seccomp=unconfined` alone wasn't enough (`bwrap: Failed to make / slave: Permission denied`); `BWRAP_PRIVILEGED=true` unlocks the full ladder. On Docker Desktop for Mac bwrap still needs `--privileged` (seccomp=unconfined alone gets EPERM mounting `/proc`). `--privileged` is the broadest setting — only on a private LAN/VPN deploy (the app has no auth); never expose a privileged container publicly. The default `BWRAP_CANARY=fail` **aborts the deploy before either container starts** if no profile passes — a broken runner is never deployed silently. `BWRAP_CANARY=warn` is opt-in to continue: the app always deploys + the runner deploys best-effort, and if no profile passes, AI-workflow/swarm generation 503s with a clear "workflow runner unreachable" reason while chat/RAG/auth/routing keep working. See `DEPLOYMENT-GUIDE.md §4g`.

**Runner down → only generation 503s.** Because bwrap lives in the runner sidecar, a down/unhealthy runner (or a kernel that denies all bwrap profiles) affects ONLY `/api/workflows/generate` + `/api/swarms/generate` — they return a 503 with `mode:"remote-runner"` + the "workflow runner unreachable at <url>…" reason. Chat, RAG, auth, routing, connectors, and everything else keep working on the non-privileged app container. To recover, restart the runner (`docker restart private-ai-<slug>-runner`), not the app — `canary()` is re-probed each call, so a runner that recovers is picked up without an app restart.

### Update all customers

```sh
scripts/update-all-customers.sh            # rebuild image + restart every customer
scripts/update-all-customers.sh --no-build  # image already updated; just restart
scripts/update-all-customers.sh --refresh-env  # also rewrite each .env from template
```

For each customer under `/opt/private-ai/customers/*/`, it reads the port + container name recorded in `.env`, rebuilds the image (unless `--no-build`), and recreates the container with the **same** `data/` mount and `.env`. Customer `/data` is never deleted (it's a host bind-mount; removing the old container can't touch it), and `.env` is never overwritten unless `--refresh-env` is passed.

### Restore a customer from a /data backup

Because all customer state is in `data/` (+ `.env`), restore is a plain file copy:

```sh
# 0. stop the customer (optional but cleanest while restoring)
docker stop private-ai-acme

# 1. restore the data volume from your backup (tarball, rsync, snapshot, etc.)
rm -rf /opt/private-ai/customers/acme/data
tar -xzf /backups/acme-2026-06-17.tgz -C /opt/private-ai/customers/acme/

# 2. (if you also backed up .env) restore it, else leave the existing one
#    tar -xzf /backups/acme-2026-06-17-env.tgz -C /opt/private-ai/customers/acme/

# 3. recreate the container against the current image + restored data
scripts/deploy-customer.sh acme <original-port>
# or, if many customers were restored:
scripts/update-all-customers.sh --no-build
```

The SQLite chat store uses WAL mode; restore the `-wal` and `-shm` files alongside `chats.sqlite` if present, or let the app recreate them. No migration step is needed — the image and schema are independent of the data.

### Future Postgres staging

The chat store is already abstracted behind `lib/store.js` (`createConversationStore`, selected by `CHAT_STORE` = `sqlite` | `jsonl`). A Postgres backend is a future `CHAT_STORE=postgres` option behind the same interface, so customer `.env` files would switch with one var and no code change to the chat pipeline, eval, or dream modules. Until then, per-customer SQLite on the mounted `/data` volume is the production store; for multi-replica HA of a single customer, run one primary writer + replicas against a shared `/data` (WAL) or graduate that customer to Postgres first. The deploy model is unchanged either way — one image, one customer per container, state in `/data` + `.env`.

### Horizontal-replica coordination (the N-replica compose shape is NOT coordination-safe)

`docker-compose.yml` ships a `1 gateway + 5 app replicas` stack as a **demo / load-test shape**, and it is explicitly marked `⚠️ NOT COORDINATION-SAFE` in the file. The reason: the app replicas share one `app-data` volume, but the workflow scheduler (`server.js` 60s check interval), per-workflow run locks, the active-request map, and the dream auto-run gate all live in **per-process memory**. Under N replicas:

- a **scheduled workflow can fire on every replica at once** (double-run), and
- **JSON / agent-state files race** on the shared `/data` volume (concurrent reads/writes of `workflows.json`, `memories.jsonl`, agent run state).

For production, **run ONE app replica**, or externalize coordination first — one of:

1. a **single dedicated scheduler process** (only it arms the scheduled-workflow + dream intervals; the other replicas serve requests only), or
2. **durable file/DB locks** around scheduled runs + state writes (e.g. a `UNIQUE` lock row in SQLite, or `flock` on a state file under `/data`), or
3. a **shared queue** (the agent runner drains jobs from a shared table, not in-process memory).

Do not scale the 5-replica shape to production as-is. The compose file comment is the guardrail.

---

## Commercial / product direction

This may become an independent service or licensable product: private AI workflow systems using open-source models where possible, with routing, memory, prompt architecture, tools, evals, workflow design, and cost control. The code alone is not the moat. The moat is the workflow library, customer-specific routing cards, prompt architecture, model-performance metadata, implementation trust, vertical packaging, GTM/RevOps workflow expertise, fast deployment, and ongoing maintenance.

---

## Near-term priorities

1. LAN access reliability
2. Stable Ollama model listing
3. Clean Auto model routing
4. Web/RAG/context priority working correctly
5. Model comparison
6. Workflow cards
7. Sandboxed coding workflows
8. Prompt linting and compression
9. Better logs and evals
10. Hosted/rented GPU support later