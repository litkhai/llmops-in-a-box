# Demo flow

A ten-minute walkthrough. The arc is **config → traffic → observability → the ClickHouse close**.

!!! note "Phase 1 — local or EC2"
    The main arc covers the Phase 1 demo: frontier models through one gateway,
    fully traced. It runs on either `--target docker` (local) or
    `--target aws-ec2`. Phase 2 and above require EC2 — see
    [the Phase 2 variation below](#variation-from-phase-2).

!!! tip "Running the full stack"
    On the EC2 deployment all three phases are live, so you can open with the
    self-hosted model instead — see
    [the Phase 3 variation below](#variation-from-phase-3).

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
- The UI shows one model: `auto`. Two chat providers (OpenAI, Anthropic) and one image provider (Cloudflare Workers AI) are wired in behind it — the user never sees a model switch.

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

- One endpoint, one SDK, one model alias. The gateway detects script and routes: Latin/CJK → qwen-7b, Korean → claude-sonnet.
- Applications do not change when models do. That is the migration story in one line.
- Fallback is automatic: if one provider is unavailable, LiteLLM retries on the other. The client always gets a response.

### Image generation via Cloudflare Workers AI

Type an image-intent message directly in the `auto` chat window — no model switch, no separate UI. The `UnifiedRouter` callback detects image keywords in the message, calls Cloudflare Workers AI (FLUX.1-schnell) directly, stores the generated image in MinIO, and injects a markdown image link into the chat response. LibreChat renders the image inline.

```
파란색 배경에 고양이 그림 그려줘
generate an image of a mountain landscape at sunrise
```

**Talking points**

- The chat model picker never changes — `auto` is the only choice. Text, language detection, and image generation are all handled by one callback in the gateway.
- Cloudflare Workers AI (FLUX.1-schnell) is free tier. No credit card, no GPU.

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
| A chat trace | Full prompt and completion, latency, token counts, **computed cost**. Every trace includes a `routing` child span showing the language detection decision and selected model alongside the LLM generation span. |
| An image trace | Same trace format; `model` shows `claude-sonnet` (the 1-token placeholder call used while image generates in background), making the routing decision visible. |
| The language routing trace | `model` shows `qwen-7b` or `claude-sonnet` — the gateway's routing decision is captured, not just the response. |
| Model comparison | Cost and latency side by side — this is what makes self-hosted vs. API economics decidable rather than theoretical. |
| The error trace | Failures are traced too. Most observability setups only capture successes; you find out about failures from users. |
| **Sessions** | Multi-turn conversations grouped, not scattered across unrelated traces. |
| **Datasets** | Promote a real production trace into a dataset. |
| **Scores** | Every completion trace arrives with five automated scores: `routing_accuracy` (was the intended model used?), `language_consistency` (input and output language match?), `latency_score` (0–1 linear, cap 30 s), `helpfulness` and `judge_language_match` (LLM-as-judge via Anthropic Haiku). User ratings from LibreChat attach to the same trace via the feedback sidecar. |

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

## Variation — from Phase 2

**Target:** `aws-ec2`. Phase 2 adds MCP tool calls to the trace story.

After the observability section, add one more prompt that triggers a ClickHouse
tool call:

```
ClickHouse에 어떤 테이블들이 있어?
```

In Langfuse, the trace now contains the `routing` span, the LLM generation span, and `tool-result/[name]` spans for each MCP tool result in the agentic loop — all as sibling spans, with no client-side wiring needed.

**Talking point:** the gateway traces every request path identically. Adding a
tool server changes what the model can do; the trace pipeline doesn't change at
all.

---

## Variation — from Phase 3

**Target:** `aws-ec2` + a live RunPod Serverless endpoint. This is what the EC2
deployment runs today, so it is a variation only in where you start the story.

Open with the serving layer instead, then follow the same arc:

1. **Serving** — show the RunPod Serverless endpoint running vLLM. *Your model, your weights, live in minutes.* Contrast with EC2 GPU setup: AMI, drivers, networking, quota requests.
2. **Traffic** — the English prompt from step 2 is already being served by `qwen-7b`. Same client code, no string changed — the gateway decided.
3. **Observability** — the cost comparison becomes the centrepiece: self-hosted at zero marginal token cost against per-token API pricing, in one chart.
4. **Close** — as above.

Worth rehearsing: stop the RunPod endpoint and send the English prompt again.
`qwen-7b` falls back to `claude-sonnet`, the trace is tagged `fallback:true`, and
`routing_accuracy` scores `0`. A demo that shows a degradation being *measured*
lands better than one that shows only the happy path.

If the room is compliance-minded, be straight about the boundary: the weights and
the serving engine are yours, but the GPU is RunPod's, so this is not 망분리. What
the architecture buys is that moving inference in-boundary is a `stack.yaml`
change rather than a migration — see
[Background — 망분리](background.md#network-separation).

---

## Reset between runs

```bash
./scripts/stack.sh down
./scripts/stack.sh up
```

Use `--purge` to drop volumes and start from an empty Langfuse — worth doing before a recorded demo so the trace list is not cluttered with rehearsal noise.
