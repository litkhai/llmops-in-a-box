"""
Routing callbacks for LLMOps in a Box.

Two routing decisions are made here before the request reaches a provider:

1. IMAGE ROUTING — if the last user message contains image-generation intent
   keywords, the callback:
     a. Starts image generation as a background asyncio task (Cloudflare
        Workers AI FLUX.1-schnell; call traced in Langfuse independently).
     b. Routes the chat request to a cheap LLM call (max_tokens=1) so a
        response object exists for the post-call hook to intercept.
     c. In async_post_call_streaming_iterator_hook, drains the 1-token stream,
        awaits the image task, and yields a replacement SSE chunk containing
        a markdown image tag before it reaches the client.

   LibreChat renders the markdown image tag inline in the chat message.

2. LANGUAGE ROUTING — for plain chat requests the model field is rewritten based
   on the dominant Unicode script of the last user message:
     Hangul-primary (Korean)             → claude-sonnet
     CJK-primary (Chinese, Japanese, …) → qwen-7b  (RunPod self-hosted)
     Latin-primary (English, …)          → qwen-7b  (RunPod self-hosted)

   Fallback (configured in litellm_config.yaml):
     qwen-7b → claude-sonnet  (when the self-hosted pod is cold or down)
     auto    → claude-sonnet  (if language-routed target fails)

Script detection is a pure Unicode heuristic — no extra network call, < 1 ms
added to p99 latency.
"""

import asyncio
import base64
import hashlib
import hmac
import os
import re
import uuid
from datetime import datetime, timezone
from typing import Dict, Optional

import json

import httpx
import litellm
from langfuse import Langfuse

_langfuse = Langfuse()  # reads LANGFUSE_* env vars already set in litellm container

# ── scoring constants ─────────────────────────────────────────────────────────
_LATENCY_CAP_S  = 30.0     # latency_score = 0.0 at 30 s or above
_JUDGE_MODEL    = "claude-haiku-4-5-20251001"
_FEEDBACK_URL   = os.environ.get("FEEDBACK_SERVICE_URL", "http://feedback:8080")

# ── dataset + annotation queue ────────────────────────────────────────────────
_DATASET_NAME      = "auto-review"
_REVIEW_THRESHOLD  = 0.5   # helpfulness below this → flagged for review
_LANGFUSE_HOST     = os.environ.get("LANGFUSE_HOST", "http://langfuse-web:3000")
_annotation_queue_id: Optional[str] = None

# ── MCP tool injection ────────────────────────────────────────────────────────
# When the tools layer is active (MCP_CLICKHOUSE_URL set), MCP tools are
# injected into every chat request automatically.  The model decides whether to
# call them; if it does, the post-call hook executes the tool and runs a follow-
# up completion so the client always receives a plain text response.
_MCP_ENABLED = bool(os.environ.get("MCP_CLICKHOUSE_URL"))
_LITELLM_INTERNAL_URL = "http://localhost:4000"
_mcp_tools_cache: Optional[list] = None
_mcp_tool_server_map: dict = {}   # tool_name → server_id for /mcp-rest/tools/call


async def _get_mcp_tools() -> list:
    """Fetch MCP tool definitions from LiteLLM REST endpoint; cache on first call."""
    global _mcp_tools_cache, _mcp_tool_server_map
    if _mcp_tools_cache is not None:
        return _mcp_tools_cache
    master_key = os.environ.get("LITELLM_MASTER_KEY", "")
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                f"{_LITELLM_INTERNAL_URL}/mcp-rest/tools/list",
                headers={"Authorization": f"Bearer {master_key}"},
                timeout=5.0,
            )
            if r.status_code == 200:
                raw = r.json().get("tools", [])
                _mcp_tools_cache = []
                for t in raw:
                    _mcp_tools_cache.append({
                        "type": "function",
                        "function": {
                            "name": t["name"],
                            "description": t.get("description", ""),
                            "parameters": t.get("inputSchema", {"type": "object", "properties": {}}),
                        },
                    })
                    # server_id is nested under mcp_info; required for /mcp-rest/tools/call
                    server_id = (t.get("mcp_info") or {}).get("server_id") or ""
                    if server_id:
                        _mcp_tool_server_map[t["name"]] = server_id
            else:
                _mcp_tools_cache = []
    except Exception:
        _mcp_tools_cache = []
    print(f"[mcp_inject] tool server map: {_mcp_tool_server_map}", flush=True)
    return _mcp_tools_cache


async def _call_mcp_tool(name: str, arguments: dict) -> str:
    """Execute a single MCP tool via the LiteLLM REST endpoint."""
    master_key = os.environ.get("LITELLM_MASTER_KEY", "")
    server_id = _mcp_tool_server_map.get(name, "")
    body = {"name": name, "arguments": arguments}
    if server_id:
        body["server_id"] = server_id
    print(f"[mcp_call] tool={name} server_id={server_id!r} args={arguments}", flush=True)
    try:
        async with httpx.AsyncClient() as client:
            r = await client.post(
                f"{_LITELLM_INTERNAL_URL}/mcp-rest/tools/call",
                headers={"Authorization": f"Bearer {master_key}"},
                json=body,
                timeout=30.0,
            )
            print(f"[mcp_call] status={r.status_code} body={r.text[:300]}", flush=True)
            r.raise_for_status()
            resp_body = r.json()
            # LiteLLM returns content at the top level: {"content": [...], "_meta": ...}
            content = resp_body.get("content") or (resp_body.get("result") or {}).get("content") or []
            if isinstance(content, list):
                text = "\n".join(c.get("text", str(c)) for c in content if c)
                print(f"[mcp_call] result_text={text[:200]}", flush=True)
                return text
            return json.dumps(resp_body)
    except Exception as exc:
        return f"Tool error: {exc}"


async def _call_model_once(model: str, messages: list) -> Optional[dict]:
    """Single non-streaming model call via the LiteLLM HTTP proxy.

    Returns the raw JSON response dict, or None on error.
    is_tool_followup prevents recursive MCP tool injection.
    """
    master_key = os.environ.get("LITELLM_MASTER_KEY", "")
    try:
        async with httpx.AsyncClient() as client:
            r = await client.post(
                f"{_LITELLM_INTERNAL_URL}/v1/chat/completions",
                headers={"Authorization": f"Bearer {master_key}", "Content-Type": "application/json"},
                json={"model": model, "messages": messages,
                      "metadata": {"is_tool_followup": True}, "stream": False},
                timeout=60.0,
            )
            r.raise_for_status()
            return r.json()
    except Exception as exc:
        print(f"[mcp_loop] _call_model_once error: {exc}", flush=True)
        return None


async def _run_agentic_loop(model: str, messages: list, max_hops: int = 5) -> Optional[str]:
    """Multi-hop MCP agentic loop.

    Calls the model, executes any tool_calls, appends results, and repeats
    until the model returns finish_reason=stop or max_hops is reached.
    """
    for hop in range(max_hops):
        resp = await _call_model_once(model, messages)
        if not resp:
            return None
        choice = resp.get("choices", [{}])[0]
        finish_reason = choice.get("finish_reason")
        msg = choice.get("message", {})
        content = msg.get("content")
        tool_calls = msg.get("tool_calls")

        print(f"[mcp_loop] hop={hop} finish={finish_reason} tools={bool(tool_calls)}", flush=True)

        if finish_reason == "stop" or not tool_calls:
            return content

        # Execute all tool calls this hop
        tool_msgs = []
        for tc in tool_calls:
            try:
                args = json.loads(tc["function"]["arguments"] or "{}")
            except Exception:
                args = {}
            result = await _call_mcp_tool(tc["function"]["name"], args)
            tool_msgs.append({
                "role": "tool",
                "tool_call_id": tc["id"],
                "name": tc["function"]["name"],
                "content": result,
            })

        messages = messages + [{"role": "assistant", "content": content, "tool_calls": tool_calls}] + tool_msgs

    return None  # max hops reached


async def _followup_completion(model: str, messages: list) -> Optional[str]:
    """Compatibility shim — delegates to _run_agentic_loop."""
    return await _run_agentic_loop(model, messages)


# ── model costs (must match litellm_config.yaml model_info) ──────────────────
# Used to pass explicit cost to Langfuse so the cost dashboard populates
# regardless of whether Langfuse's model registry recognises the model name.
# RUNPOD_COST_PER_TOKEN: approximate per-token cost for RunPod GPU time.
# Example: RTX 4090 at $0.44/hr, ~800 tok/s → 0.44/(800*3600) ≈ 1.5e-7.
# Set in .env alongside VLLM_API_BASE. Defaults to 0 (cost tracked by pod-hour
# externally, not per-token here).
_RUNPOD_COST = float(os.environ.get("RUNPOD_COST_PER_TOKEN", "0") or "0")
_MODEL_COSTS: Dict[str, tuple] = {
    "claude-sonnet": (3e-06, 1.5e-05),       # (input $/token, output $/token)
    "qwen-7b":       (_RUNPOD_COST, _RUNPOD_COST),  # RunPod GPU; set via env
}

# ── model aliases (must match stack.yaml / litellm_config.yaml) ──────────────
# Phase 4 (RunPod) activates qwen-7b; fall back to claude-sonnet when VLLM is
# not configured (Phase 1).
_VLLM_ACTIVE        = bool(os.environ.get("VLLM_API_BASE"))
_ENGLISH_MODEL      = "qwen-7b" if _VLLM_ACTIVE else "claude-sonnet"
_MULTILINGUAL_MODEL = "claude-sonnet"    # Hangul (Korean)
_CJK_MODEL          = "qwen-7b" if _VLLM_ACTIVE else "claude-sonnet"
_IMAGE_MODEL        = "dall-e-3"

# Only "auto" and "" trigger routing; explicit model names are respected.
_ROUTABLE_ALIASES = {"auto", ""}

# ── image intent detection ────────────────────────────────────────────────────
_IMAGE_RE = re.compile(
    r"(그려|그림|이미지|사진"
    r"|만들어\s*줘|생성해\s*줘|그려\s*줘|그려\s*봐|그려\s*주세요"
    r"|draw\b|paint\b|illustrat"
    r"|generate\s+(an?\s+)?(image|picture|photo|illustration)"
    r"|create\s+(an?\s+)?(image|picture|photo|illustration)"
    r"|\bimage\s+of\b|\bpicture\s+of\b)",
    re.IGNORECASE,
)

# ── in-flight image tasks: call_id → asyncio.Task[str] ───────────────────────
_image_tasks: Dict[str, "asyncio.Task[str]"] = {}

# ── MCP-injected call tracking (call_id set) ──────────────────────────────────
# Metadata written in async_pre_call_hook is not guaranteed to propagate to
# async_post_call_streaming_iterator_hook.  Use a global set keyed by call_id
# (same pattern as _image_tasks) so the streaming hook can detect MCP calls.
_mcp_injected_calls: set = set()

# ── language heuristic ────────────────────────────────────────────────────────
_SCRIPT_THRESHOLD = 0.15


def _dominant_script(text: str) -> str:
    """Return 'hangul', 'cjk', or 'latin' based on the dominant Unicode script.

    Checked in priority order: Hangul first (Korean), then CJK/kana (Chinese /
    Japanese), then Latin default.  Threshold: fraction of characters that must
    belong to a script for it to win.
    """
    if not text:
        return "latin"
    total = len(text)
    hangul = sum(
        1 for c in text
        if 0xAC00 <= ord(c) <= 0xD7A3   # Hangul syllables
        or 0x1100 <= ord(c) <= 0x11FF   # Hangul Jamo
        or 0x3130 <= ord(c) <= 0x318F   # Hangul Compatibility Jamo
    )
    if hangul / total > _SCRIPT_THRESHOLD:
        return "hangul"
    cjk = sum(
        1 for c in text
        if 0x4E00 <= ord(c) <= 0x9FFF   # CJK Unified Ideographs
        or 0x3400 <= ord(c) <= 0x4DBF   # CJK Extension A
        or 0xF900 <= ord(c) <= 0xFAFF   # CJK Compatibility
        or 0x3040 <= ord(c) <= 0x30FF   # Hiragana + Katakana (Japanese)
    )
    if cjk / total > _SCRIPT_THRESHOLD:
        return "cjk"
    return "latin"


# ── image generation ──────────────────────────────────────────────────────────

async def _call_cloudflare(prompt: str, client: httpx.AsyncClient) -> str:
    """
    Call Cloudflare AI Workers (FLUX.1-schnell).
    Returns a base64-encoded JPEG string (already encoded by Cloudflare).
    """
    cf_token   = os.environ.get("CF_API_TOKEN", "")
    cf_account = os.environ.get("CF_ACCOUNT_ID", "")
    resp = await client.post(
        f"https://api.cloudflare.com/client/v4/accounts/{cf_account}"
        f"/ai/run/@cf/black-forest-labs/flux-1-schnell",
        json={"prompt": prompt},
        headers={"Authorization": f"Bearer {cf_token}"},
        timeout=90.0,
    )
    resp.raise_for_status()
    body = resp.json()
    if not body.get("success"):
        raise ValueError(f"CF API error: {body.get('errors', body)}")
    b64 = body["result"]["image"]   # CF returns base64-encoded JPEG
    return b64


def _minio_put_url(bucket: str, key: str, img_bytes: bytes) -> str:
    """
    Upload image bytes to MinIO using AWS SigV4 (pure stdlib).
    Returns the public URL for the uploaded object.
    """
    access_key = os.environ.get("MINIO_ROOT_USER", "admin")
    secret_key  = os.environ.get("MINIO_ROOT_PASSWORD", "")
    endpoint    = os.environ.get("MINIO_ENDPOINT", "http://minio:9000")
    public_host = os.environ.get("MINIO_PUBLIC_HOST", "")

    now = datetime.now(timezone.utc)
    datestamp  = now.strftime("%Y%m%d")
    amzdate    = now.strftime("%Y%m%dT%H%M%SZ")
    region, service = "us-east-1", "s3"

    payload_hash = hashlib.sha256(img_bytes).hexdigest()
    content_type = "image/jpeg"

    headers_to_sign = {
        "content-type": content_type,
        "host": endpoint.split("//", 1)[1],
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amzdate,
    }
    signed_headers = ";".join(sorted(headers_to_sign))
    canonical_headers = "".join(f"{k}:{v}\n" for k, v in sorted(headers_to_sign.items()))
    canonical_request = "\n".join([
        "PUT", f"/{bucket}/{key}", "",
        canonical_headers, signed_headers, payload_hash,
    ])

    credential_scope = f"{datestamp}/{region}/{service}/aws4_request"
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amzdate, credential_scope,
        hashlib.sha256(canonical_request.encode()).hexdigest(),
    ])

    def _sign(key: bytes, msg: str) -> bytes:
        return hmac.new(key, msg.encode(), hashlib.sha256).digest()

    signing_key = _sign(_sign(_sign(_sign(
        f"AWS4{secret_key}".encode(), datestamp),
        region), service), "aws4_request")
    signature = hmac.new(signing_key, string_to_sign.encode(), hashlib.sha256).hexdigest()

    auth = (
        f"AWS4-HMAC-SHA256 Credential={access_key}/{credential_scope},"
        f" SignedHeaders={signed_headers}, Signature={signature}"
    )

    import urllib.request
    req = urllib.request.Request(
        f"{endpoint}/{bucket}/{key}",
        data=img_bytes,
        method="PUT",
        headers={
            "Authorization": auth,
            "Content-Type": content_type,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": amzdate,
        },
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        if r.status not in (200, 201):
            raise RuntimeError(f"MinIO PUT {r.status}")

    base = public_host or endpoint
    return f"{base}/{bucket}/{key}"


async def _generate_image(prompt: str) -> str:
    """
    Generate an image via Cloudflare Workers AI (FLUX.1-schnell).
    Uploads to MinIO and returns a public URL.

    MINIO_PUBLIC_HOST must be set to the server's public address (e.g.
    http://43.201.101.143:9002) so the URL is browser-resolvable.  Without
    it, _minio_put_url falls back to the internal Docker hostname (http://minio:9000)
    which the user's browser cannot reach — that is the root cause of broken images.
    """
    async with httpx.AsyncClient() as client:
        try:
            b64 = await _call_cloudflare(prompt, client)
            img_bytes = base64.b64decode(b64)
            if len(img_bytes) < 100:
                raise ValueError(f"Cloudflare returned too-small image ({len(img_bytes)} bytes)")
            if img_bytes[:8] == b'\x89PNG\r\n\x1a\n':
                ext = "png"
            else:
                ext = "jpg"
            key = f"generated/{uuid.uuid4().hex}.{ext}"
            url = _minio_put_url("images", key, img_bytes)
            return f"![generated image]({url})"
        except Exception as exc:
            return f"Image generation failed: {exc}"


# ── langfuse helpers ──────────────────────────────────────────────────────────

def _extract_output(response_obj) -> str:
    try:
        return response_obj.choices[0].message.content or ""
    except (AttributeError, IndexError):
        return str(response_obj)


def _span(trace_id: str, name: str, input_: dict, output: dict) -> None:
    """Create a completed Langfuse span nested under an existing trace."""
    try:
        s = _langfuse.span(trace_id=trace_id, name=name, input=input_, output=output)
        s.end()
    except Exception:
        pass  # never let observability code break the critical path


# ── rule-based scoring ────────────────────────────────────────────────────────

def _score_routing(trace_id: str, tags: list) -> None:
    """1.0 if routed to intended model, 0.0 if a fallback was triggered."""
    is_fallback = "fallback:true" in tags
    try:
        _langfuse.score(
            trace_id=trace_id,
            name="routing_accuracy",
            value=0.0 if is_fallback else 1.0,
            data_type="BOOLEAN",
            comment="fallback triggered" if is_fallback else "routed as intended",
        )
    except Exception:
        pass


def _score_language_consistency(trace_id: str, input_script: str, output_text: str) -> None:
    """1.0 if the response language matches the detected input script."""
    output_script = _dominant_script(output_text[:500])
    # Latin output is always acceptable (e.g. model names, code, proper nouns).
    consistent = (output_script == input_script) or (output_script == "latin")
    try:
        _langfuse.score(
            trace_id=trace_id,
            name="language_consistency",
            value=1.0 if consistent else 0.0,
            data_type="BOOLEAN",
            comment=f"input:{input_script} output:{output_script}",
        )
    except Exception:
        pass


def _score_latency(trace_id: str, start_time, end_time) -> None:
    """0.0–1.0 inversely proportional to latency; 0.0 at >= 30 s."""
    try:
        if isinstance(start_time, datetime) and isinstance(end_time, datetime):
            latency = (end_time - start_time).total_seconds()
        else:
            latency = float(end_time) - float(start_time)
        score = max(0.0, 1.0 - latency / _LATENCY_CAP_S)
        _langfuse.score(
            trace_id=trace_id,
            name="latency_score",
            value=round(score, 3),
            data_type="NUMERIC",
            comment=f"{latency:.1f}s",
        )
    except Exception:
        pass


# ── LLM-as-judge ──────────────────────────────────────────────────────────────

async def _judge_response(trace_id: str, messages: list, output: str) -> None:
    """Call claude-haiku to score helpfulness and language match.

    Runs as a fire-and-forget asyncio task.  Skipped when ANTHROPIC_API_KEY is
    absent so the stack works fully offline.
    """
    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key or not output:
        return

    last_user = next(
        (m.get("content", "") for m in reversed(messages) if m.get("role") == "user"),
        "",
    )
    if not last_user:
        return

    _hardcoded_prompt = (
        "Evaluate the AI response below. Return JSON only, no explanation.\n\n"
        f"User: {last_user[:400]}\n"
        f"Assistant: {output[:400]}\n\n"
        '{"helpfulness": <float 0.0-1.0, how well it answers the question>, '
        '"language_match": <1 if response language matches the user message language, else 0>}'
    )
    try:
        prompt_client = _langfuse.get_prompt("judge-v1")
        prompt = prompt_client.compile(user_message=last_user[:400], output=output[:400])
    except Exception:
        prompt = _hardcoded_prompt

    try:
        async with httpx.AsyncClient() as client:
            resp = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={
                    "x-api-key": api_key,
                    "anthropic-version": "2023-06-01",
                    "content-type": "application/json",
                },
                json={
                    "model": _JUDGE_MODEL,
                    "max_tokens": 60,
                    "temperature": 0,
                    "messages": [{"role": "user", "content": prompt}],
                },
                timeout=30.0,
            )
            resp.raise_for_status()
            raw = resp.json()["content"][0]["text"].strip()
            match = re.search(r"\{[^}]+\}", raw)
            if not match:
                return
            scores = json.loads(match.group())
            helpfulness_val = round(max(0.0, min(1.0, float(scores.get("helpfulness", 0.5)))), 3)
            _langfuse.score(
                trace_id=trace_id,
                name="helpfulness",
                value=helpfulness_val,
                data_type="NUMERIC",
            )
            _langfuse.score(
                trace_id=trace_id,
                name="judge_language_match",
                value=float(scores.get("language_match", 1)),
                data_type="BOOLEAN",
            )
            _langfuse.flush()
            if helpfulness_val < _REVIEW_THRESHOLD:
                await _flag_for_review(trace_id, messages, f"low_helpfulness:{helpfulness_val:.2f}")
    except Exception:
        pass


# ── user feedback registration ─────────────────────────────────────────────────

async def _register_for_feedback(trace_id: str, content: str) -> None:
    """Push trace_id + response content to the feedback sidecar.

    The feedback service stores a content-hash → trace_id mapping so that
    user ratings (submitted with the response text) can be linked back to the
    correct Langfuse trace.  Silently skipped if the sidecar is not running.
    """
    if not content:
        return
    try:
        async with httpx.AsyncClient() as client:
            await client.post(
                f"{_FEEDBACK_URL}/register",
                json={"trace_id": trace_id, "content": content},
                timeout=2.0,
            )
    except Exception:
        pass


# ── dataset + annotation queue helpers ───────────────────────────────────────

async def _ensure_annotation_queue() -> Optional[str]:
    """Get or create the 'low-quality-traces' annotation queue; cache its ID."""
    global _annotation_queue_id
    if _annotation_queue_id:
        return _annotation_queue_id

    pub = os.environ.get("LANGFUSE_PUBLIC_KEY", "")
    sec = os.environ.get("LANGFUSE_SECRET_KEY", "")
    if not pub or not sec:
        return None

    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                f"{_LANGFUSE_HOST}/api/public/annotation-queues",
                auth=(pub, sec),
                timeout=5.0,
            )
            if r.status_code == 200:
                for q in r.json().get("data", []):
                    if q.get("name") == "low-quality-traces":
                        _annotation_queue_id = q["id"]
                        return _annotation_queue_id
            # Langfuse v4 requires at least one scoreConfigId.
            # Fetch existing configs and use the first one found.
            rc = await client.get(
                f"{_LANGFUSE_HOST}/api/public/score-configs?limit=10",
                auth=(pub, sec), timeout=5.0,
            )
            config_ids = [c["id"] for c in rc.json().get("data", [])] if rc.status_code == 200 else []
            if not config_ids:
                return None
            r2 = await client.post(
                f"{_LANGFUSE_HOST}/api/public/annotation-queues",
                auth=(pub, sec),
                json={"name": "low-quality-traces",
                      "description": "Traces flagged for human review",
                      "scoreConfigIds": config_ids[:1]},
                timeout=5.0,
            )
            if r2.status_code in (200, 201):
                _annotation_queue_id = r2.json().get("id")
                return _annotation_queue_id
    except Exception:
        pass
    return None


async def _flag_for_review(trace_id: str, messages: list, reason: str) -> None:
    """Add trace to the auto-review dataset and the annotation queue."""
    try:
        _langfuse.create_dataset_item(
            dataset_name=_DATASET_NAME,
            source_trace_id=trace_id,
            input={"messages": messages[-3:] if len(messages) > 3 else messages},
            metadata={"reason": reason},
        )
    except Exception:
        pass

    queue_id = await _ensure_annotation_queue()
    if not queue_id:
        return
    pub = os.environ.get("LANGFUSE_PUBLIC_KEY", "")
    sec = os.environ.get("LANGFUSE_SECRET_KEY", "")
    try:
        async with httpx.AsyncClient() as client:
            # Langfuse v4 uses objectId/objectType instead of traceId
            await client.post(
                f"{_LANGFUSE_HOST}/api/public/annotation-queues/{queue_id}/items",
                auth=(pub, sec),
                json={"objectId": trace_id, "objectType": "TRACE"},
                timeout=5.0,
            )
    except Exception:
        pass


# ── callback ──────────────────────────────────────────────────────────────────

class UnifiedRouter(litellm.CustomLogger):
    """
    Pre-call hook: image intent detection + language routing.
    Post-call hook: replace response with generated image if applicable.
    """

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        # Image generation requests from LibreChat's DALL-E UI already go to
        # /v1/images/generations — no interception needed.
        # call_type is "acompletion" for async chat completions; accept both.
        if call_type not in ("completion", "acompletion"):
            return data

        # ── 0. MCP tool injection ─────────────────────────────────────────────
        # Must run before the _ROUTABLE_ALIASES early-return so that explicitly
        # named models (e.g. "claude-sonnet") also receive ClickHouse tools.
        # Skipped for follow-up completions and image-generation requests so that
        # image routing (step 2) is not bypassed by the tool-use routing (step 1).
        _pre_messages = data.get("messages") or []
        _pre_last_user = next(
            (m.get("content", "") for m in reversed(_pre_messages) if m.get("role") == "user"), ""
        )
        if (
            _MCP_ENABLED
            and not data.get("tools")
            and not (data.get("metadata") or {}).get("is_tool_followup")
            and not _IMAGE_RE.search(_pre_last_user)
        ):
            mcp_tools = await _get_mcp_tools()
            if mcp_tools:
                data["tools"] = mcp_tools
                data["tool_choice"] = "auto"
                data.setdefault("metadata", {})["mcp_tools_injected"] = True
                _mcp_injected_calls.add(str(data.get("litellm_call_id") or id(data)))
                # Prepend a system message so the model knows to use tools for data questions.
                messages = data.get("messages") or []
                if not any(m.get("role") == "system" for m in messages):
                    data["messages"] = [{"role": "system", "content": (
                        "You have access to ClickHouse database tools. "
                        "When the user asks about databases, tables, data, or queries, "
                        "call the available tools to retrieve the information rather than "
                        "saying you cannot access the data. "
                        "Follow this workflow: first call list_databases to discover available "
                        "databases, then call list_tables with the correct database name to see "
                        "the schema, then call run_query with fully-qualified table names "
                        "(e.g. database.table). Never guess table names — always verify with "
                        "list_tables first."
                    )}] + messages
                print(f"[mcp_inject] injected {len(mcp_tools)} tools into model={data.get('model','?')} call_type={call_type}", flush=True)
            else:
                print(f"[mcp_inject] _get_mcp_tools() returned empty list", flush=True)
        elif _MCP_ENABLED:
            print(f"[mcp_inject] skip: tools={bool(data.get('tools'))} is_followup={(data.get('metadata') or {}).get('is_tool_followup')}", flush=True)

        requested = data.get("model", "")
        if requested not in _ROUTABLE_ALIASES:
            return data

        messages = data.get("messages") or []
        last_user = next(
            (m.get("content", "") for m in reversed(messages) if m.get("role") == "user"),
            "",
        )

        call_id = str(data.get("litellm_call_id") or id(data))

        # Use call_id as trace_id so our custom spans nest under LiteLLM's generation.
        data.setdefault("metadata", {})
        trace_id = data["metadata"].get("trace_id") or call_id
        data["metadata"]["trace_id"] = trace_id

        # ── 1. Tool-use routing — skip language routing for agentic requests ──
        # Route tool-use requests to claude-sonnet regardless of language; it
        # has the most reliable function-calling across all tool types.
        if data.get("tools"):
            data["model"] = _MULTILINGUAL_MODEL
            data["metadata"]["detected_script"] = "tool-use"
            data["metadata"]["routed_model"]    = _ENGLISH_MODEL
            data["metadata"]["trace_name"]      = "chat/tool-use"
            data["metadata"]["generation_name"] = f"{_ENGLISH_MODEL}/response"
            _tool_tags = ["script:tool-use", f"routed:{_ENGLISH_MODEL}"]
            if _VLLM_ACTIVE and _ENGLISH_MODEL == "qwen-7b":
                _tool_tags.append("provider:runpod")
            data["metadata"]["tags"]            = _tool_tags
            _span(trace_id, "routing", {"script": "tool-use", "tools": [t.get("function", {}).get("name") for t in (data.get("tools") or [])]}, {"routed": _ENGLISH_MODEL})
            # Log any tool results from LibreChat's agentic loop as individual spans.
            for msg in messages:
                if msg.get("role") == "tool":
                    _span(trace_id, f"tool-result/{msg.get('name', 'unknown')}", {"tool_call_id": msg.get("tool_call_id")}, {"content": str(msg.get("content", ""))[:500]})
            return data

        # ── 2. Image routing ──────────────────────────────────────────────────
        if _IMAGE_RE.search(last_user):
            _image_tasks[call_id] = asyncio.ensure_future(_generate_image(last_user))
            # Always use _MULTILINGUAL_MODEL (claude-sonnet) for the 1-token stub.
            # The LLM response is discarded; Cloudflare generates the actual image.
            # Using _ENGLISH_MODEL (qwen-7b) fails when RunPod is not running.
            data["model"]      = _MULTILINGUAL_MODEL
            data["max_tokens"] = 1
            data["metadata"]["detected_script"] = "image"
            data["metadata"]["routed_model"]    = _IMAGE_MODEL
            data["metadata"]["trace_name"]      = "image/generate"
            data["metadata"]["generation_name"] = "image-stub"
            data["metadata"]["tags"]            = ["script:image", f"routed:{_IMAGE_MODEL}"]
            _span(trace_id, "routing", {"script": "image", "prompt": last_user[:200]}, {"routed": _IMAGE_MODEL})
            # stream stays as-is — streaming calls use async_post_call_streaming_iterator_hook,
            # non-streaming calls use async_post_call_success_hook.
            return data

        # ── 3. Language routing ───────────────────────────────────────────────
        script = _dominant_script(last_user)
        if script == "hangul":
            routed = _MULTILINGUAL_MODEL
        elif script == "cjk":
            routed = _CJK_MODEL
        else:
            routed = _ENGLISH_MODEL
        data["model"] = routed

        tags = [f"script:{script}", f"routed:{routed}"]
        if _VLLM_ACTIVE and routed == "qwen-7b":
            tags.append("provider:runpod")
        data["metadata"]["detected_script"] = script
        data["metadata"]["routed_model"]    = routed
        data["metadata"]["trace_name"]      = f"chat/{script}"
        data["metadata"]["generation_name"] = f"{routed}/response"
        data["metadata"]["tags"]            = tags
        _span(trace_id, "routing", {"script": script, "message_preview": last_user[:200]}, {"routed": routed})

        return data

    async def async_post_call_success_hook(self, data, user_api_key_dict, response):
        call_id = str(data.get("litellm_call_id") or id(data))

        # ── image replacement ─────────────────────────────────────────────────
        if call_id in _image_tasks:
            task = _image_tasks.pop(call_id)
            img_markdown = await task
            try:
                response.choices[0].message.content = img_markdown
            except (AttributeError, IndexError, TypeError):
                pass
            return response

        # ── MCP agentic loop ──────────────────────────────────────────────────
        # If the model returned tool_calls (because we injected MCP tools),
        # execute each tool against mcp-clickhouse and run one follow-up
        # completion that synthesises a final plain-text response.
        meta = data.get("metadata") or {}
        choice = response.choices[0] if getattr(response, "choices", None) else None
        finish_reason = getattr(choice, "finish_reason", None) if choice else None
        print(f"[mcp_loop] mcp_enabled={_MCP_ENABLED} injected={meta.get('mcp_tools_injected')} followup={meta.get('is_tool_followup')} finish={finish_reason}", flush=True)
        if (
            _MCP_ENABLED
            and meta.get("mcp_tools_injected")
            and not meta.get("is_tool_followup")
            and choice
            and finish_reason == "tool_calls"
            and getattr(choice.message, "tool_calls", None)
        ):
            tool_msgs = []
            for tc in choice.message.tool_calls:
                try:
                    args = json.loads(tc.function.arguments or "{}")
                except Exception:
                    args = {}
                result = await _call_mcp_tool(tc.function.name, args)
                tool_msgs.append({
                    "role": "tool",
                    "tool_call_id": tc.id,
                    "name": tc.function.name,
                    "content": result,
                })

            assistant_msg = {
                "role": "assistant",
                "content": choice.message.content,
                "tool_calls": [
                    {
                        "id": tc.id,
                        "type": "function",
                        "function": {
                            "name": tc.function.name,
                            "arguments": tc.function.arguments,
                        },
                    }
                    for tc in choice.message.tool_calls
                ],
            }
            messages = list(data.get("messages", [])) + [assistant_msg] + tool_msgs

            final_content = await _followup_completion(
                model=data.get("model", "auto"),
                messages=messages,
            )
            if final_content:
                response.choices[0].message.content = final_content
                response.choices[0].message.tool_calls = None
                response.choices[0].finish_reason = "stop"

        return response

    async def async_post_call_streaming_iterator_hook(self, user_api_key_dict, response, request_data):
        from litellm.types.utils import ModelResponseStream, StreamingChoices, Delta

        call_id = str(request_data.get("litellm_call_id") or id(request_data))
        meta = request_data.get("metadata") or {}

        # ── Image generation ──────────────────────────────────────────────────
        if call_id in _image_tasks:
            try:
                async for _ in response:
                    pass
            except Exception:
                pass
            task = _image_tasks.pop(call_id)
            try:
                img_markdown = await task
            except Exception as exc:
                img_markdown = f"Image generation failed: {exc}"
            import time as _time
            now = int(_time.time())
            chunk_id = f"chatcmpl-img-{uuid.uuid4().hex[:12]}"
            yield ModelResponseStream(
                id=chunk_id, created=now,
                choices=[StreamingChoices(index=0, delta=Delta(role="assistant", content=img_markdown), finish_reason=None)],
            )
            yield ModelResponseStream(
                id=chunk_id, created=now,
                choices=[StreamingChoices(index=0, delta=Delta(), finish_reason="stop")],
            )
            return

        # ── MCP agentic loop for streaming clients (e.g. LibreChat) ──────────
        # Buffer the entire stream so we can detect tool_calls before anything
        # reaches the client.  If the model picks a tool we execute it and
        # stream only the final plain-text follow-up response.
        # Use _mcp_injected_calls (call_id set) rather than metadata because
        # metadata written in async_pre_call_hook is not reliably propagated
        # to this hook's request_data.
        if _MCP_ENABLED and call_id in _mcp_injected_calls and not meta.get("is_tool_followup"):
            _mcp_injected_calls.discard(call_id)
            chunks = []
            async for chunk in response:
                chunks.append(chunk)

            # Reconstruct tool_calls by aggregating deltas
            finish_reason = None
            tool_calls_map: dict = {}
            for chunk in chunks:
                for choice in getattr(chunk, "choices", []):
                    fr = getattr(choice, "finish_reason", None)
                    if fr:
                        finish_reason = fr
                    delta = getattr(choice, "delta", None)
                    if not delta:
                        continue
                    for tc_delta in getattr(delta, "tool_calls", None) or []:
                        idx = getattr(tc_delta, "index", 0)
                        if idx not in tool_calls_map:
                            tool_calls_map[idx] = {"id": "", "name": "", "arguments": ""}
                        if getattr(tc_delta, "id", None):
                            tool_calls_map[idx]["id"] = tc_delta.id
                        func = getattr(tc_delta, "function", None)
                        if func:
                            if getattr(func, "name", None):
                                tool_calls_map[idx]["name"] += func.name or ""
                            if getattr(func, "arguments", None):
                                tool_calls_map[idx]["arguments"] += func.arguments or ""

            if finish_reason != "tool_calls" or not tool_calls_map:
                # No tool use — pass through all buffered chunks
                for chunk in chunks:
                    yield chunk
                return

            # Execute each tool
            tool_calls = list(tool_calls_map.values())
            tool_msgs = []
            for tc in tool_calls:
                try:
                    args = json.loads(tc["arguments"] or "{}")
                except Exception:
                    args = {}
                result = await _call_mcp_tool(tc["name"], args)
                tool_msgs.append({
                    "role": "tool",
                    "tool_call_id": tc["id"],
                    "name": tc["name"],
                    "content": result,
                })

            assistant_msg = {
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {"id": tc["id"], "type": "function",
                     "function": {"name": tc["name"], "arguments": tc["arguments"]}}
                    for tc in tool_calls
                ],
            }
            messages = list(request_data.get("messages", [])) + [assistant_msg] + tool_msgs
            final_content = await _followup_completion(
                model=request_data.get("model", "auto"),
                messages=messages,
            )

            if not final_content:
                for chunk in chunks:
                    yield chunk
                return

            # Stream final answer as two synthetic chunks
            import time as _time
            now = int(_time.time())
            chunk_id = f"chatcmpl-mcp-{uuid.uuid4().hex[:12]}"
            yield ModelResponseStream(
                id=chunk_id, created=now,
                choices=[StreamingChoices(index=0, delta=Delta(role="assistant", content=final_content), finish_reason=None)],
            )
            yield ModelResponseStream(
                id=chunk_id, created=now,
                choices=[StreamingChoices(index=0, delta=Delta(), finish_reason="stop")],
            )
            return

        # ── Default pass-through ──────────────────────────────────────────────
        async for chunk in response:
            yield chunk

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        # Only log completion calls — skip management API noise (/v2/user/info, etc.)
        if kwargs.get("call_type") not in ("completion", "acompletion"):
            return
        if kwargs.get("messages") == "default-message-value":
            return

        meta = kwargs.get("litellm_params", {}).get("metadata") or {}
        if not meta.get("routed_model"):
            return

        # Use litellm_params.model for the actual provider model string
        # (e.g. "anthropic/claude-sonnet-4-5") because response_obj.model echoes
        # the original alias ("auto") before pre-call hook routing took effect.
        actual = (
            (kwargs.get("litellm_params") or {}).get("model")
            or getattr(response_obj, "model", None)
            or kwargs.get("model", "")
        )
        actual_alias = actual.split("/")[-1] if "/" in actual else actual

        tags = list(meta.get("tags") or [])
        tags.append(f"actual:{actual_alias}")
        if actual_alias != meta.get("routed_model"):
            tags.append("fallback:true")

        trace_id  = kwargs.get("litellm_call_id") or str(id(kwargs))
        usage     = getattr(response_obj, "usage", None)
        is_image  = meta.get("detected_script") == "image"

        # LibreChat passes the user's internal ID as `user`; use it to group all
        # of that user's traces under one Langfuse session so the Sessions view
        # is populated. Not per-conversation, but enough to demonstrate the feature.
        user_id   = kwargs.get("user") or ""
        session_id = f"user-{user_id}" if user_id else None

        try:
            trace = _langfuse.trace(
                id=trace_id,
                name=meta.get("trace_name", f"chat/{meta.get('detected_script', 'unknown')}"),
                tags=tags,
                session_id=session_id,
                user_id=user_id or None,
                metadata={"detected_script": meta.get("detected_script"), "routed_model": meta.get("routed_model")},
                input=None if is_image else kwargs.get("messages"),
                output=None if is_image else _extract_output(response_obj),
            )
            if not is_image:
                inp_tok = getattr(usage, "prompt_tokens", 0) or 0
                out_tok = getattr(usage, "completion_tokens", 0) or 0
                # routed_model is the alias we set in the pre-call hook;
                # it's the only reliable model identifier available in the
                # callback kwargs (response_obj.model echoes the original alias).
                routed_alias = meta.get("routed_model", actual_alias)
                in_rate, out_rate = _MODEL_COSTS.get(routed_alias, (0.0, 0.0))
                gen = _langfuse.generation(
                    trace_id=trace_id,
                    name=meta.get("generation_name", f"{routed_alias}/response"),
                    model=routed_alias,
                    input=kwargs.get("messages"),
                    output=_extract_output(response_obj),
                    usage={
                        "input": inp_tok,
                        "output": out_tok,
                        "total": inp_tok + out_tok,
                        "input_cost": round(inp_tok * in_rate, 8),
                        "output_cost": round(out_tok * out_rate, 8),
                        "total_cost": round(inp_tok * in_rate + out_tok * out_rate, 8),
                    } if usage else None,
                    start_time=start_time,
                    end_time=end_time,
                )
                gen.end()
            _langfuse.flush()
        except Exception:
            pass

        # ── scores ────────────────────────────────────────────────────────────
        output   = _extract_output(response_obj)
        messages = kwargs.get("messages") or []
        _score_routing(trace_id, tags)
        _score_language_consistency(trace_id, meta.get("detected_script", "latin"), output)
        _score_latency(trace_id, start_time, end_time)
        if "fallback:true" in tags:
            asyncio.ensure_future(_flag_for_review(trace_id, messages, "routing_fallback"))
        asyncio.ensure_future(_judge_response(trace_id, messages, output))
        asyncio.ensure_future(_register_for_feedback(trace_id, output))

    async def async_post_call_failure_hook(self, *args, **kwargs):
        # Signature changed across LiteLLM versions; accept both positional and keyword.
        data = kwargs.get("data") or kwargs.get("request_data") or (args[0] if args else {})
        original_exception = kwargs.get("original_exception") or (args[1] if len(args) > 1 else None)
        # Clean up the image task on LLM failure so the dict does not leak.
        call_id = str(data.get("litellm_call_id") or id(data))
        task = _image_tasks.pop(call_id, None)
        if task and not task.done():
            task.cancel()

        # Log failure to Langfuse (management API calls excluded by "default-message-value" check).
        if data.get("messages") == "default-message-value":
            return
        meta = data.get("metadata") or {}
        if not meta.get("routed_model"):
            return
        trace_id = str(data.get("litellm_call_id") or id(data))
        try:
            _langfuse.trace(
                id=trace_id,
                name=meta.get("trace_name", "chat/error"),
                tags=(meta.get("tags") or []) + ["error:true"],
                metadata={"error": str(original_exception)[:500], "routed_model": meta.get("routed_model")},
            )
            _langfuse.flush()
        except Exception:
            pass


# LiteLLM discovers the callback by module-level instantiation.
language_router = UnifiedRouter()
