# Demo flow

A ten-minute walkthrough. The arc is **config → traffic → observability → the ClickHouse close**.

!!! note "Phase 1 scope"
    This is the Phase 1 demo: two frontier models through one gateway, fully traced. From Phase 3 you open with the RunPod pod instead — see [the variation below](#variation-from-phase-3).

---

## Before you start

```bash
./scripts/stack.sh doctor      # every check green
./scripts/stack.sh status      # every endpoint 2xx
```

Have open in tabs: LibreChat (`:3080`), Langfuse (`:3000`), and a terminal.

!!! warning "Rehearse the failure"
    Step 2 deliberately triggers an error trace. Confirm it actually appears in Langfuse **before** the meeting — a demo that shows a failure it cannot then explain is worse than one that shows none.

---

## 1. Config — one file, one script *(2 min)*

Lead with the architecture, not the UI.

```bash
./scripts/stack.sh phases
./scripts/stack.sh config
```

**Talking points**

- One `stack.yaml` describes the whole stack. The deployment target is a flag — the same file runs on a laptop and on EC2.
- **Layers are fixed; implementations are swappable.** vLLM → SGLang, RunPod → on-prem GPU, LibreChat → your own app.
- The build-out is phased on purpose: Phase 1 proves the architecture with no GPU, so every later layer plugs into a tracing pipeline that already works.

```bash
./scripts/stack.sh models
```

- Models are declared once and rendered into both the gateway routing table and the UI picker. No drift between what the UI offers and what the gateway can serve.

---

## 2. Traffic — same client, different providers *(3 min)*

In LibreChat, send the same prompt to both models from the picker. Then show the client code:

```python
for m in ["gpt-4o", "claude-sonnet"]:
    client.chat.completions.create(model=m, messages=[...])
```

**Talking points**

- One endpoint, one SDK, one auth token. Anthropic's different wire format is handled by the gateway.
- Applications do not change when models do. That is the migration story in one line.

Include in the run:

- **one long generation** — so latency and token counts are visibly different between models
- **one deliberate failure** — an invalid model alias, or a revoked key, so an error trace appears

---

## 3. Observability — the actual product *(4 min)*

Open Langfuse. Spend the most time here.

| Show | Say |
|---|---|
| **Traces** list | Every request, both providers, one pane. Nothing was instrumented in the application. |
| A single trace | Full prompt and completion, latency, token counts, **computed cost**. |
| Model comparison | Cost and latency side by side — this is what makes self-hosted vs. API economics decidable rather than theoretical. |
| The error trace | Failures are traced too. Most observability setups only capture successes; you find out about failures from users. |
| **Sessions** | Multi-turn conversations grouped, not scattered across unrelated traces. |
| **Datasets** | Promote a real production trace into a dataset. |
| **Scores** | Score one output — the entry point to systematic evals rather than vibes. |

**The framing that matters**

> Observability lives at the gateway, so this is framework-neutral. Raw SDK, LangChain, LlamaIndex, or an MCP agent — all traced identically, all with zero application code changes.

---

## 4. Close — why ClickHouse *(1 min)*

> Langfuse v3 stores traces in **ClickHouse**. At production volume, LLM tracing is a high-cardinality, append-heavy, aggregate-on-read workload — thousands of traces per minute, each with unique IDs, arbitrary metadata, and queries that scan wide time ranges to compute p95 latency and cost per model.
>
> That is precisely the workload ClickHouse was built for. The same architecture you just saw on a laptop extends to millions of traces per day without changing shape.

Then hand back to the phases: *this is Phase 1. The same config adds tools, self-hosted models, and caching without a rewrite.*

---

## Variation — from Phase 3

Open with the serving layer instead, then follow the same arc:

1. **Serving** — show the RunPod pod running vLLM. *Your model, your infrastructure, live in minutes.* Contrast with EC2 GPU setup: AMI, drivers, networking, quota requests.
2. **Traffic** — now include `qwen-7b` in the comparison. Same client code, one string changed.
3. **Observability** — the cost comparison becomes the centrepiece: self-hosted at zero marginal token cost against per-token API pricing, in one chart.
4. **Close** — as above.

Optional, if the room is compliance-minded:

```bash
./scripts/stack.sh up --profile airgapped
```

Only self-hosted models resolve; the commercial API fallback is **pruned from the generated config**, not merely discouraged. Relevant to 망분리 / ISMS-P contexts where "we configured it not to" is not an acceptable control.

---

## Reset between runs

```bash
./scripts/stack.sh down
./scripts/stack.sh up
```

Use `--purge` to drop volumes and start from an empty Langfuse — worth doing before a recorded demo so the trace list is not cluttered with rehearsal noise.
