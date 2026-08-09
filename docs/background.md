# Background

Why this stack is shaped the way it is: the failure mode it is built against, the one architectural decision everything else follows from, what was chosen at each layer and what was considered instead, and the regulatory context that makes self-hosting a requirement rather than a preference for some buyers.

If you want to run something first, start at
[Getting started](getting-started.md).

---

## What goes wrong without this

The usual path into GenAI is not a decision, it is an accumulation. One team ships a feature with the OpenAI SDK. Another prefers Anthropic. A third adopts LangChain. A data scientist has a notebook with a personal key in it. None of that is wrong on its own, and after a year it produces a predictable set of problems:

**Nobody can answer what it costs.** Spend is spread across provider invoices with no attribution to teams, features, or users. The finance question — *which product line is spending this, and on what* — has no owner and no data behind it.

**Nobody can answer what it does.** Prompts, completions, latencies and failures live wherever each framework happens to log them, if at all. When quality regresses there is no record to compare against. When something goes wrong, the first report usually comes from a user.

**Changing models means changing applications.** A better or cheaper model appears and adopting it means touching every codebase that calls the old one. The cost of the switch is what stops the switch, so teams stay on whatever they started with.

**There is no place to put a policy.** PII redaction, rate limits, budget caps, an audit log, a model allow-list — each has to be implemented in every application, by every team, correctly. The next notebook walks past all of it.

**Nobody can tell whether it is getting better.** Quality is discussed anecdotally — someone saw a bad answer, someone else believes the new prompt helped. With no scores attached to real traffic there is no baseline to regress against, so prompt and model changes ship on conviction. And because nothing measures quality, nothing can act on it: routing stays a static config that cannot respond to a route getting worse.

Each of these is the same problem: **there is no single point every request passes through.** The stack in this repo is the argument that creating one is the highest-leverage thing an enterprise can do early, because every other capability becomes available once it exists.

The last one is also the reason the *same* point has to do both jobs. Measuring quality and deciding where a request goes are separate concerns right up until you want the first to change the second — and then they have to live together, or the loop cannot close. That is what [Phase 5.5](phases.md#55-closing-the-loop-judge-scored-routing) builds, and why it is the destination rather than a late addition.

---

## The load-bearing decision: a gateway

There are three common places to put the abstraction over models. The choice determines what is possible later.

| | Per-app provider SDK | Framework abstraction | **Gateway** |
|---|---|---|---|
| Where model choice lives | each codebase | each codebase's framework config | one config, centrally |
| Cost attribution | provider invoices | none by default | per request, per key, per model |
| Tracing consistency | per team, if any | per framework | uniform, framework-neutral |
| Policy enforcement point | none | none | one, unavoidable |
| Cost of swapping models | touch every app | touch every app | change one string |
| Works for notebooks, cron, `curl` | separately | no | yes, same as apps |
| Added failure domain | none | none | **yes — one more hop** |

The last row is the honest cost. A gateway is a component that can be down, and when it is down everything is down. That is a real trade, mitigated but not eliminated by retries, timeouts and fallbacks — all of which this stack configures explicitly in `layers.gateway.options`.

The reason it is still worth it: the other three columns cannot be retrofitted. Cost attribution, uniform tracing and a policy enforcement point are properties of *where requests flow*, not features you can add to an application later. If the flow is already centralised, all three are configuration. If it is not, all three are a migration.

!!! note "Framework abstraction and a gateway are not competitors"
    LangChain or LlamaIndex sitting *on top of* the gateway is a perfectly good arrangement, and this stack traces it identically to a raw SDK call — that is what "framework-neutral" means. The point is that the framework is the wrong layer to make the model choice and enforce policy at, because it only covers the applications that use it.

---

## Why observability at the gateway rather than in the app

Application-level LLM tracing is the more common pattern, and it is genuinely better at one thing: it sees business context the gateway cannot — which user, which feature, which step of your own workflow.

The gateway sees something different and, for this purpose, more useful: **every request, from every client, in the same shape**, whether that client is a production service, a notebook, a scheduled job or an agent framework nobody told you about. It also sees the failures, which app-level instrumentation frequently drops because the error path is not the path that got instrumented.

The two compose. Pass your own identifiers through as metadata and you get both — the gateway's completeness plus your context. What you cannot do is start with app-level tracing and later derive fleet-wide cost and failure data from it.

---

## What each layer is, and what was considered instead

The layers are fixed; the implementations are swappable. Reasons for each current choice, and the honest trade in each case.

### Gateway — LiteLLM

An OpenAI-compatible proxy in front of every model, translating wire formats, routing aliases, tracking cost, issuing scoped keys.

**Considered:** hosted routers such as OpenRouter (removes the self-hosting requirement, but sends every prompt to a third party — a non-starter for the buyers this stack targets); commercial AI gateways like Portkey; API gateways with LLM plugins such as Kong; writing a thin proxy in-house.

**Why LiteLLM:** self-hostable and open source, so it can live inside a network boundary; broad provider coverage, so the abstraction does not leak the first time someone wants a new model; Langfuse SDK integration in the custom callback, logging completion calls only — which is what makes gateway-level tracing work without glue code while keeping management API noise out of traces; virtual keys and budgets built in, so the policy point is usable on day one.

**The trade:** it is a young, fast-moving project, and the surface area it covers — dozens of providers — is large enough that edge cases exist. `drop_params: true` in this stack's config exists precisely because providers disagree about parameters.

### Observability — Langfuse

Traces, sessions, cost, datasets, scores and evals in one place.

**Considered:** LangSmith (excellent, but SaaS-first and tied to the LangChain ecosystem); Arize Phoenix; Helicone; OpenLLMetry/OpenTelemetry-based setups feeding a generic backend.

**Why Langfuse:** it self-hosts, stores trace workloads in ClickHouse, and
keeps datasets, scores, and evaluations beside the traces. That makes promoting
a production trace into a later evaluation set practical.

**The trade:** self-hosting Langfuse is not one container. It needs
ClickHouse, Postgres, Redis, an S3-compatible blob store, and a worker. That
operational cost is visible even in the local demo.

### Serving — vLLM

The inference server for self-hosted models, exposing an OpenAI-compatible endpoint so the gateway treats it like any other provider.

**Considered:** Hugging Face TGI; SGLang; Ollama and llama.cpp (excellent for local development, not aimed at concurrent serving); NVIDIA Triton/TensorRT-LLM (faster ceiling, considerably more setup).

**Why vLLM:** continuous batching and paged attention give it strong throughput under concurrency, which is the regime that matters when a GPU is being paid for by the second; and its OpenAI-compatible server means the gateway needs no special case for it — a self-hosted model is configured exactly like a commercial one.

### UI — LibreChat

A chat front end so there is something to demo, and so non-developers can use the stack.

**Considered:** Open WebUI; Chainlit or Streamlit for a bespoke UI; no UI at all (the `headless` profile exists for that).

**Why LibreChat:** it is configured by a file rather than by clicking, so its model list can be generated from the same `stack.yaml` catalog as the gateway's routing table — no drift between what the UI offers and what the gateway can serve. It also supports agents and MCP tools, which is what [Phase 5.2](phases.md#52-librechat-agents-over-the-mcp-tool-layer) builds on.

### Compute — RunPod

GPU hosting for the serving layer.

**Considered:** EC2/GCE GPU instances; Lambda Labs; on-premise GPUs; serverless inference APIs.

**Why RunPod for this stack:** per-second billing with no charge when a pod is stopped, and prebuilt vLLM templates, which together make the GPU half of the demo cheap and fast to stand up. For a reference architecture that gets brought up and torn down repeatedly, that matters more than committed-use discounts.

**The trade, stated plainly:** RunPod is not the likely production destination
for a regulated enterprise. It is the planned way to prove the architecture
with a real GPU. Moving serving to EC2 or on-premises remains a design goal,
not a capability implemented in this repository.

### Tools — MCP, with ClickHouse Cloud first

**MCP** (Model Context Protocol) is an open protocol for exposing tools, data sources and prompts to language models over a uniform interface. Before it, every framework had its own tool-calling convention and every integration was bespoke. MCP makes a tool server reusable across clients — the same reason the gateway argument works, applied to tools instead of models.

Here it means agents reach the warehouse through a declared, scoped server rather than through code embedded in an application — and because the calls pass through the gateway, they are traced alongside the completions that triggered them.

---

## Why ClickHouse is under Langfuse

Worth understanding rather than taking on faith, because it is also the closing argument of the [demo](demo-flow.md#4-close-why-clickhouse-1-min).

LLM tracing has an unusual workload shape:

| Property | What it looks like here |
|---|---|
| Write pattern | append-heavy, effectively never updated |
| Cardinality | very high — every trace, span and session has a unique ID |
| Schema | wide and semi-structured; arbitrary user metadata per trace |
| Read pattern | aggregate over wide time ranges — p95 latency, cost per model per day, token totals |
| Row counts | thousands per minute at modest production volume |

A row-oriented transactional database is built for the opposite of most of that. It can hold the data, and Langfuse v2 did exactly that in Postgres — but the aggregate-on-read queries that make the dashboard useful scan far more data than they return, and that is where a row store spends its time reading columns nobody asked for.

A column-oriented OLAP store reads only the columns in the query and is
designed for append-then-aggregate workloads. Langfuse therefore uses
ClickHouse for traces and Postgres for transactional metadata.

---

## Regulatory context — 망분리 and ISMS-P

This stack's self-hosting emphasis is not a preference. For a meaningful set of Korean enterprises, calling a commercial LLM API from an internal network is not a thing they are permitted to do.

!!! warning "Orientation, not legal advice"
    This section exists so the architecture's shape makes sense. Thresholds, scope and interpretation change, and they turn on specifics of a given organisation. Confirm anything load-bearing with your own compliance function.

### 망분리 — network separation

**What it is.** A requirement to keep internal business networks separated from the internet, so that a compromise of one does not reach the other. It shows up in the financial sector through the 전자금융감독규정 (Regulation on Supervision of Electronic Financial Transactions) and in the public sector through government security guidance.

Implementations take two broad forms — **물리적 망분리**, where internal work happens on machines with no internet path at all, and **논리적 망분리**, where the separation is enforced through virtualisation.

**Why it decides this architecture.** In a separated environment there is no route from the internal network to `api.openai.com`. This is not a matter of a firewall rule someone could be persuaded to add — the absence of that route *is* the control. So for these buyers:

- Phase 1 of this stack, which sends every request to a commercial API, **cannot run inside the boundary at all**
- the model has to be served inside the boundary, which is what [Phase 3](phases.md#phase-3--cpu-serving-and-minio-kv-cache) (CPU) and [Phase 4](phases.md#phase-4--gpu-serving-on-runpod) (GPU) are for
- the observability stack has to be self-hosted too, since traces contain the prompts
- `--profile airgapped` **prunes** commercial fallbacks from the generated config rather than merely disabling them — because in this context "we configured it not to" is a promise, not a control

That last distinction is the one worth carrying into a compliance conversation. A config that *could* egress and is set not to, and a config in which the egress path does not exist, are different artifacts. This stack generates the second.

### ISMS-P — the certification

**What it is.** 정보보호 및 개인정보보호 관리체계 (ISMS-P) is Korea's combined certification for information security and personal information protection management, administered under KISA. It extends the security-only ISMS scheme with personal-data controls. Certification is mandatory for certain categories of operator, with the categories keyed to things like sector, revenue and user counts.

**Which parts this stack touches.** An LLM deployment is not a special case; it inherits the ordinary control domains, and this repo's structure maps onto several of them:

| Control area | What the stack does about it |
|---|---|
| Access control | virtual keys per team through the gateway; a dedicated read-only warehouse user for the MCP server rather than a shared admin account |
| Credential management | every secret inventoried in one file with owner, scope and rotation cadence — see [Credentials](credentials.md) |
| Operational logging | every request traced with prompt, completion, latency, cost and outcome, including failures |
| Third-party / outsourcing | the model catalog makes explicit which models are commercial APIs and which run inside the boundary |
| Cross-border transfer | see below — the sharpest one |

### The cross-border question

This is the point that most often surprises teams, and it is worth stating on its own.

A prompt is data. If a prompt contains personal information and the request goes to a provider outside Korea, that is a **cross-border transfer of personal data (개인정보 국외이전)** under 개인정보보호법 (PIPA), with its own consent and disclosure obligations. It does not stop being one because the transfer happened inside an LLM call rather than a database export.

Two consequences for how this stack is built:

1. **Guardrails have to run before egress.** A PII filter that runs on the response has already sent the prompt. This is why [Phase 5.4](phases.md#54-guardrails-at-the-gateway) treats the `pre_call` versus `post_call` distinction as the whole point rather than a detail.
2. **A hosted guardrail service can reintroduce the problem it was added to solve.** Sending prompts to a third-party API to be *checked* for sensitive data is still sending them to a third party. If the deployment claims a boundary, the guardrail has to be inside it.

---

## Glossary

| Term | Meaning here |
|---|---|
| Gateway | The shared OpenAI-compatible model endpoint; LiteLLM in this stack |
| Model alias | A stable client-facing name mapped to a provider model |
| Virtual key | A gateway-issued consumer key with attribution and limits |
| Trace / span | One logical operation / one step within it |
| Context window | The maximum input and output token capacity of a model |
| Prefix caching | Reusing attention state for an identical prompt prefix |
| Semantic cache | Reusing a completed answer for a similar prompt; a different mechanism |
| MCP | A protocol for exposing tools and data to model clients |

---

## Where to go next

| If you want to | Read |
|---|---|
| Understand the build order and what each phase proves | [Build-out phases](phases.md) |
| See how one file describes the whole stack | [Configuration](configuration.md) |
| Prepare and run it | [Getting started](getting-started.md) |
| Know which keys exist and how they are handled | [Credentials](credentials.md) |
| Present it | [Demo flow](demo-flow.md) |
