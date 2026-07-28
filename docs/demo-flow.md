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

- One `stack.yaml` describes the whole stack. The `docker` and `aws-ec2` targets are both runnable today behind the same interface.
- **Layers are fixed; implementations are swappable.** vLLM → SGLang, RunPod → on-prem GPU, LibreChat → your own app.
- The build-out is phased on purpose: Phase 1 proves the architecture with no GPU, so every later layer plugs into a tracing pipeline that already works.

```bash
./scripts/stack.sh models
```

- Models are declared once and rendered into both the gateway routing table and the UI picker. No drift between what the UI offers and what the gateway can serve.
- The UI shows one model: `auto`. Two chat providers and two image providers are wired in behind it — the user never sees a model switch.

---

## 2. Traffic — routing and modalities *(4 min)*

### Chat: language routing via `auto`

LibreChat's model picker shows a single model: `auto`. Send the same prompt in
English and Korean — the gateway routes each to a different provider without any
client change:

```python
for lang, msg in [
    ("English", "Explain ClickHouse in one sentence."),
    ("Korean",  "ClickHouse를 한 문장으로 설명해줘."),
]:
    client.chat.completions.create(
        model="auto",
        messages=[{"role": "user", "content": msg}],
    )
```

**Talking points**

- One endpoint, one SDK, one model alias. The gateway detects script and routes: Latin → GPT-4o, non-Latin → Claude Sonnet.
- Applications do not change when models do. That is the migration story in one line.
- Fallback is automatic: if one provider is unavailable, LiteLLM retries on the other. The client always gets a response.

### Image generation: Cloudflare → HuggingFace fallback

Type an image-intent message directly in the `auto` chat window — no model switch, no separate UI. The `UnifiedRouter` callback detects image keywords in the message, calls Cloudflare Workers AI (FLUX.1-schnell) directly, stores the generated image in MinIO, and injects a markdown image link into the chat response. LibreChat renders the image inline.

```
파란색 배경에 고양이 그림 그려줘
generate an image of a mountain landscape at sunrise
```

**Talking points**

- The chat model picker never changes — `auto` is the only choice. Text, language detection, and image generation are all handled by one callback in the gateway.
- Cloudflare Workers AI is the primary provider; HuggingFace FLUX.1-schnell is the fallback.
- Both providers are free tier. No credit card, no GPU. The same fallback pattern scales to paid providers.

Include in the run:

- **one long chat generation** — so latency and token counts are visibly different between providers
- **one Korean prompt** — to show language routing in action
- **one image prompt** — to show the second routing path
- **one deliberate failure** — an invalid model alias, or a revoked key, so an error trace appears

---

## 3. Observability — the actual product *(4 min)*

Open Langfuse. Spend the most time here.

| Show | Say |
|---|---|
| **Traces** list | Every request — chat and image, both providers — in one pane. Nothing was instrumented in the application. |
| A chat trace | Full prompt and completion, latency, token counts, **computed cost**. |
| An image trace | Same trace format; `model` shows `claude-sonnet` (the 1-token placeholder call used while image generates in background), making the routing decision visible. |
| The language routing trace | `model` shows `gpt-4o` or `claude-sonnet` — the gateway's routing decision is captured, not just the response. |
| Model comparison | Cost and latency side by side — this is what makes self-hosted vs. API economics decidable rather than theoretical. |
| The error trace | Failures are traced too. Most observability setups only capture successes; you find out about failures from users. |
| **Sessions** | Multi-turn conversations grouped, not scattered across unrelated traces. |
| **Datasets** | Promote a real production trace into a dataset. |
| **Scores** | Score one output — the entry point to systematic evals rather than vibes. |

**The framing that matters**

> Observability lives at the gateway, so clients using the same endpoint get a
> consistent provider-level trace. Applications can still add business
> metadata and deeper spans when they need them.

---

## 4. Close — why ClickHouse *(1 min)*

> Langfuse stores traces in **ClickHouse**. LLM tracing is a high-cardinality,
> append-heavy, aggregate-on-read workload: unique request IDs, flexible
> metadata, and time-range queries over latency, tokens, and cost.
>
> That is the workload shape a column-oriented analytical database is designed
> to serve.

Then hand back to the phases: *this is Phase 1. The same config adds tools, self-hosted models, and caching without a rewrite.*

---

## Variation — from Phase 3

This variation arrives with Phase 3. It is not part of the current runnable
demo.

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
