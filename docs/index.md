---
hide:
  - navigation
  - toc
---

<div class="hero" markdown>

<span class="hero-eyebrow">Composable LLMOps reference stack</span>

# LLMOps in a Box

<p class="hero-sub">
One gateway for commercial and self-hosted models, one trace pipeline, and one
declarative stack definition.
</p>

<p class="hero-stack">
LiteLLM · LibreChat · Langfuse · ClickHouse · OpenAI · Anthropic · Cloudflare · MinIO
</p>

[Get started](getting-started.md){ .md-button .md-button--primary }
[Run the workshop](workshop.md){ .md-button }
[See the phases](phases.md){ .md-button }

</div>

---

## Why this exists

Enterprises adopting GenAI keep arriving at the same questions:

<div class="grid cards" markdown>

-   :material-server-network: **Can we run our own models on our own infrastructure?**

    Data residency, network isolation, regulatory compliance.

-   :material-swap-horizontal: **Can we mix self-hosted models with commercial APIs?**

    OpenAI and Anthropic alongside our own models — without rewriting applications.

-   :material-chart-line: **Can we see everything in one place?**

    Every prompt, latency, token, cost, and failure.

-   :material-gavel: **Can the system act on its own quality data?**

    Outputs scored by an LLM judge, and those scores changing how requests are
    routed.

-   :material-layers-triple: **Can we replace a layer without rewriting the stack?**

    vLLM → SGLang, RunPod → on-prem GPU, LibreChat → your own app. No layer
    should be a bet on a single vendor.

-   :material-radar: **Which parts of the sovereign-AI landscape are real?**

    The space turns over every few months and much of it is still claims.
    Standing a layer up is how you find out which ones hold.

</div>

This is a **reference architecture plus deployment scripts** that answers all
six with open-source building blocks. Layers are fixed; implementations are
swappable.

The last two are why the layer boundaries are worth the effort. A fixed layer
with a swappable implementation is both an escape route and an instrument: when
a new serving engine, GPU host, or cache appears, it can be tried in place of
the current one and measured against the same traces, instead of evaluated from
a vendor's benchmark. Keeping current with sovereign AI infrastructure is a
side effect of the architecture rather than a separate research project.

### The destination: an agent platform

Acting on quality data is the question that decides whether an agent platform can
be operated at all, which is why the others serve it.

A single completion can be judged by reading it. An agent cannot. It plans,
calls tools, and takes several steps, so its output space is too large to
inspect by hand and its failures are compositional — a correct answer reached
through the wrong tool call is still a defect, and nobody notices by eye.
Automated scoring is therefore not a reporting feature added at the end. It is
the only mechanism by which an agent's behaviour becomes known, and the only
signal a routing decision can act on.

That is what the layers add up to:

| Layer | What it contributes to the platform |
|---|---|
| Gateway | where models are reached and policy is enforced |
| Serving | models running inside the boundary, so the loop can run on private data |
| Tools | what an agent is permitted to do |
| Observability | what it actually did |
| Evaluation | whether that was any good |
| Routing | what changes as a result |

They are built in that order because each one is what the next has to operate
on: nothing can score what was never traced, and nothing can route on a score
that does not exist. Closing the loop also needs one point that both
**measures** every request and **enforces** where it goes — the same point, or
there is no loop. That is the gateway, which is why it is the first thing built
rather than the last.

Agents arrive in <span class="phase phase-2">Phase 2</span> and
<span class="phase phase-5">Phase 5</span>; the loop that makes them measurable
is [Phase 5.5](phases.md#55-closing-the-loop-judge-scored-routing). What runs
today is the gateway and the trace pipeline underneath all of it.

---

## The full picture

This is the architecture the stack is being built toward, with the phase that
delivers each path. The phases are a build order, not a menu — every layer shown
here is in scope. Today only the <span class="phase phase-1">Phase 1</span>
paths run.

```mermaid
flowchart TB
    U1["End users<br/><small>chat</small>"]
    U2["Apps / SDKs<br/><small>OpenAI-compatible</small>"]

    LC["<b>LibreChat</b><br/><small>:3080 · UI</small>"]
    GW["<b>LiteLLM Gateway</b><br/><small>:4000</small><br/><small>routing · virtual keys · cost tracking</small>"]

    OA["OpenAI API"]
    AN["Anthropic API"]
    CF["Cloudflare Workers AI<br/><small>FLUX.1-schnell</small>"]
    IMGMI[("MinIO<br/><small>generated images<br/>media.&lt;domain&gt;</small>")]
    MCP["MCP servers<br/><small>ClickHouse Cloud</small>"]
    CPU["llama.cpp :8080<br/><small>Qwen2.5-0.5B · CPU</small>"]
    VL["vLLM :8000<br/><small>Qwen2.5-7B on RunPod</small>"]

    LF["<b>Langfuse</b><br/><small>:3000 · traces · sessions<br/>datasets · evals</small>"]
    CH[("ClickHouse Cloud<br/><small>OLAP traces · llmops db</small>")]
    PG[("Postgres")]
    RD[("Redis")]
    MI[("MinIO")]
    ST[("MinIO AIStor<br/><small>datasets · artifacts<br/>weights · KV cache</small>")]

    U1 --> LC --> GW
    U2 --> GW

    GW -->|Phase 1| OA
    GW -->|Phase 1| AN
    GW -->|"Phase 1 (images)"| CF
    CF --> IMGMI
    GW -->|Phase 2| MCP
    GW -->|Phase 3| CPU
    CPU -.->|"Phase 3 (KV cache)"| ST
    GW -->|Phase 4| VL

    GW -.->|"traces: prompt, tokens,<br/>latency, cost, errors"| LF
    LF --- CH
    LF --- PG
    LF --- RD
    LF --- MI

    classDef p1 fill:#1a7f37,stroke:#1a7f37,color:#fff
    classDef p2 fill:#8250df,stroke:#8250df,color:#fff
    classDef p3 fill:#bf8700,stroke:#bf8700,color:#fff
    classDef p4 fill:#2563c9,stroke:#2563c9,color:#fff
    classDef obs fill:#0969da,stroke:#0969da,color:#fff
    class OA,AN,CF,IMGMI p1
    class MCP p2
    class CPU,ST p3
    class VL p4
    class LF obs
```

The two MinIO instances are deliberate. Langfuse runs one for its own blobs;
the image-hosting MinIO is a separate bucket served via `media.<domain>` so
generated images are accessible over HTTPS without coupling to Langfuse's
internal storage. AIStor (Phase 3) adds a third store for dataset and artifact
lifecycle that you own end to end.

### The layers

| Layer | Implementation | Phase |
|---|---|:--:|
| UI | LibreChat | <span class="phase phase-1">1</span> |
| Observability | Langfuse (ClickHouse Cloud · Postgres · Redis · MinIO) | <span class="phase phase-1">1</span> |
| Gateway | LiteLLM — routing, virtual keys, cost tracking | <span class="phase phase-1">1</span> |
| Models | OpenAI · Anthropic | <span class="phase phase-1">1</span> |
| Image generation | Cloudflare Workers AI (FLUX.1-schnell) → MinIO (`media.<domain>`) | <span class="phase phase-1">1</span> |
| Tools | MCP servers — ClickHouse Cloud, wired into LiteLLM gateway | <span class="phase phase-2">2</span> |
| Serving (CPU) | llama.cpp — quantized model on EC2 CPU | <span class="phase phase-3">3</span> |
| Models | Self-hosted — Qwen 0.5B (CPU) | <span class="phase phase-3">3</span> |
| Storage | MinIO AIStor — datasets, artifacts, weights, KV cache | <span class="phase phase-3">3</span> |
| KV cache | LMCache — prefill a long shared prefix once, reuse it | <span class="phase phase-3">3</span> |
| Serving (GPU) | vLLM on RunPod | <span class="phase phase-4">4</span> |
| Models | Self-hosted — Qwen 7B, EXAONE, EEVE | <span class="phase phase-4">4</span> |
| Compute | RunPod GPU | <span class="phase phase-4">4</span> |
| *(recipes)* | Context routing · LibreChat Agents · Langfuse evals — no new layer | <span class="phase phase-5">5</span> |

The layer list is the invariant. Which implementation fills a row is a
configuration decision in `stack.yaml`, which is why the phases can add rows
without rewriting the ones already there.

### A single request, end to end

1. A user sends a message in LibreChat (or any OpenAI-compatible client) and
   picks a model — `gpt-4o`, `claude-sonnet`, `qwen-0.5b` (Phase 3 CPU), or `qwen-7b` (Phase 4 GPU).
   Selecting `auto` activates language-aware routing at the gateway.
2. LiteLLM receives it on **one unified endpoint**, resolves the model alias,
   and routes it to the right provider. Anthropic's format translation is
   handled for you.
3. If the message contains image-generation intent (e.g. "draw", "그려줘"),
   a pre-call hook intercepts the request, fires off image generation to
   **Cloudflare Workers AI** (FLUX.1-schnell) in the background, and streams
   back the finished image as a markdown tag once it's uploaded to **MinIO**
   (`media.<domain>`). The chat UI renders it inline — no separate DALL-E UI
   needed.
4. For plain chat requests, the response streams back from the chosen provider.
5. LiteLLM's callbacks push the full trace — prompt, completion, latency,
   token counts, computed cost — into **Langfuse**, where ClickHouse stores
   and serves high-volume trace analytics.
6. In Langfuse you compare models side by side, build datasets from production
   traces, and score outputs.

!!! tip "Zero application code changes"
    Observability lives at the **gateway** layer, not in your app. Raw SDKs,
    LangChain, LlamaIndex, and future MCP-based agents are all traced
    identically — nothing to instrument.

---

## What runs today

Phase 1 is the subset of the diagram above that is running code:

```mermaid
flowchart LR
    C["LibreChat / applications"]
    G["LiteLLM Gateway"]
    O["OpenAI"]
    A["Anthropic"]
    CF["Cloudflare Workers AI"]
    IMGMI[("MinIO (images)")]
    L["Langfuse"]
    CH[("ClickHouse Cloud<br/><small>llmops db</small>")]
    D["Postgres · Redis · MinIO"]

    C --> G
    G --> O
    G --> A
    G --"image callback"--> CF --> IMGMI
    G -. traces .-> L
    L --- CH
    L --- D
```

- LiteLLM provides one OpenAI-compatible gateway with language-aware routing.
- LibreChat provides the model picker and chat UI.
- OpenAI and Anthropic provide model inference.
- Cloudflare Workers AI (FLUX.1-schnell) generates images on demand; results
  are uploaded to MinIO and served via `media.<domain>`.
- Langfuse records traces, tokens, latency, cost, and failures.
- **ClickHouse Cloud** (`llmops` database) stores trace analytics. Postgres, Redis, and MinIO run locally for Langfuse's application data.

!!! warning "Phase 1 is not an air-gapped deployment"
    At least one external model-provider key is required, and every model
    request leaves the local network. Sovereignty is the argument the
    architecture makes; it becomes demonstrable in Phase 3, when the CPU-served
    `qwen-0.5b` enables `--profile airgapped` with no commercial API. See
    [Background](background.md#the-cross-border-question) for why the transfer
    question is the one that decides it.

---

## How the phases get there

| Phase | Outcome | Target | Status |
|:--:|---|---|---|
| <span class="phase phase-1">1</span> | Gateway, UI, and tracing over frontier APIs | Docker or EC2 | In progress |
| <span class="phase phase-2">2</span> | MCP tool layer, starting with ClickHouse Cloud | EC2 | Runnable — ClickHouse Cloud via MCP |
| <span class="phase phase-3">3</span> | CPU serving (llama.cpp) and MinIO KV cache | EC2 | Not built yet |
| <span class="phase phase-4">4</span> | GPU serving on RunPod | EC2 + RunPod | Not built yet |
| <span class="phase phase-5">5</span> | Routing, agents, guardrails, and judge-scored routing | EC2 | Not built yet |

The Status column reports implementation state, not scope. Phase 1 runs on
local Docker or EC2. Phase 2 and above require `--target aws-ec2`. See
[Build-out phases](phases.md) for the end state and acceptance criteria of each
phase.

---

## Why the gateway matters

Without a shared request path, model selection, cost data, tracing, and policy
are reimplemented by each application. A gateway creates one place to:

- switch providers without changing client protocols
- attribute spend by request, model, or key
- observe success and failure consistently
- apply routing and policy before external egress

The trade-off is another critical service in the request path. See
[Background](background.md) for the design rationale and alternatives.

## Start here

1. [Getting started](getting-started.md) — choose the runnable target and
   configure credentials.
2. [Phase 1 workshop](workshop.md) — start the stack and inspect a traced
   request.
3. [Configuration](configuration.md) — understand `stack.yaml`, profiles, and
   generated files.

Reference pages:

| Topic | Page |
|---|---|
| Credential inventory and security | [Credentials](credentials.md) |
| The end state and the build order | [Build-out phases](phases.md) |
| Lifecycle commands and targets | [Deployment](deployment.md) |
| Presentation script | [Demo flow](demo-flow.md) |
