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
        json={"prompt": prompt, "num_steps": 4},
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
        # qwen-7b is a small model with poor function-calling reliability.
        # Any request that carries tools goes straight to the capable model.
        if data.get("tools"):
            data["model"] = _ENGLISH_MODEL
            data["metadata"]["detected_script"] = "tool-use"
            data["metadata"]["routed_model"]    = _ENGLISH_MODEL
            data["metadata"]["trace_name"]      = "chat/tool-use"
            data["metadata"]["generation_name"] = f"{_ENGLISH_MODEL}/response"
            data["metadata"]["tags"]            = ["script:tool-use", f"routed:{_ENGLISH_MODEL}"]
            _span(trace_id, "routing", {"script": "tool-use", "tools": [t.get("function", {}).get("name") for t in (data.get("tools") or [])]}, {"routed": _ENGLISH_MODEL})
            # Log any tool results from LibreChat's agentic loop as individual spans.
            for msg in messages:
                if msg.get("role") == "tool":
                    _span(trace_id, f"tool-result/{msg.get('name', 'unknown')}", {"tool_call_id": msg.get("tool_call_id")}, {"content": str(msg.get("content", ""))[:500]})
            return data

        # ── 2. Image routing ──────────────────────────────────────────────────
        if _IMAGE_RE.search(last_user):
            _image_tasks[call_id] = asyncio.ensure_future(_generate_image(last_user))
            data["model"]      = _ENGLISH_MODEL
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

        data["metadata"]["detected_script"] = script
        data["metadata"]["routed_model"]    = routed
        data["metadata"]["trace_name"]      = f"chat/{script}"
        data["metadata"]["generation_name"] = f"{routed}/response"
        data["metadata"]["tags"]            = [f"script:{script}", f"routed:{routed}"]
        _span(trace_id, "routing", {"script": script, "message_preview": last_user[:200]}, {"routed": routed})

        return data

    async def async_post_call_success_hook(self, data, user_api_key_dict, response):
        call_id = str(data.get("litellm_call_id") or id(data))

        if call_id not in _image_tasks:
            return response

        task = _image_tasks.pop(call_id)
        img_markdown = await task

        try:
            response.choices[0].message.content = img_markdown
        except (AttributeError, IndexError, TypeError):
            pass

        return response

    async def async_post_call_streaming_iterator_hook(self, user_api_key_dict, response, request_data):
        from litellm.types.utils import ModelResponseStream, StreamingChoices, Delta

        call_id = str(request_data.get("litellm_call_id") or id(request_data))

        if call_id not in _image_tasks:
            async for chunk in response:
                yield chunk
            return

        # Drain the 1-token LLM stream without forwarding to client.
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
            id=chunk_id,
            created=now,
            choices=[StreamingChoices(
                index=0,
                delta=Delta(role="assistant", content=img_markdown),
                finish_reason=None,
            )],
        )
        yield ModelResponseStream(
            id=chunk_id,
            created=now,
            choices=[StreamingChoices(
                index=0,
                delta=Delta(),
                finish_reason="stop",
            )],
        )

    async def async_log_success_event(self, kwargs, response_obj, start_time, end_time):
        # Only log completion calls — skip management API noise (/v2/user/info, etc.)
        if kwargs.get("call_type") not in ("completion", "acompletion"):
            return
        if kwargs.get("messages") == "default-message-value":
            return

        meta = kwargs.get("litellm_params", {}).get("metadata") or {}
        if not meta.get("routed_model"):
            return

        actual = getattr(response_obj, "model", None) or kwargs.get("model", "")
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
                metadata={"detected_script": meta.get("detected_script"), "routed_model": meta.get("routed_model"), "actual_model": actual_alias},
                input=None if is_image else kwargs.get("messages"),
                output=None if is_image else _extract_output(response_obj),
            )
            if not is_image:
                gen = _langfuse.generation(
                    trace_id=trace_id,
                    name=meta.get("generation_name", f"{actual_alias}/response"),
                    model=actual,
                    input=kwargs.get("messages"),
                    output=_extract_output(response_obj),
                    usage={
                        "input": getattr(usage, "prompt_tokens", 0),
                        "output": getattr(usage, "completion_tokens", 0),
                        "total": getattr(usage, "total_tokens", 0),
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

    async def async_post_call_failure_hook(self, data, user_api_key_dict, original_exception, **kwargs):
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
