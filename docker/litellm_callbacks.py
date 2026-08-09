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
from typing import Dict

import httpx
import litellm

# ── model aliases (must match stack.yaml / litellm_config.yaml) ──────────────
_ENGLISH_MODEL      = "qwen-7b"          # Latin (English, etc.) — RunPod
_MULTILINGUAL_MODEL = "claude-sonnet"    # Hangul (Korean)
_CJK_MODEL          = "qwen-7b"          # CJK (Chinese, Japanese) — RunPod
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
    Generate an image via Cloudflare Workers AI (FLUX.1-schnell),
    upload to MinIO, and return a markdown image tag with a public URL.
    """
    async with httpx.AsyncClient() as client:
        try:
            b64 = await _call_cloudflare(prompt, client)
            img_bytes = base64.b64decode(b64)
            key = f"generated/{uuid.uuid4().hex}.jpg"
            loop = asyncio.get_event_loop()
            url = await loop.run_in_executor(
                None, _minio_put_url, "images", key, img_bytes
            )
            return f"![generated image]({url})"
        except Exception as exc:
            return f"Image generation failed: {exc}"


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

        # ── 1. Tool-use routing — skip language routing for agentic requests ──
        # qwen-7b is a small model with poor function-calling reliability.
        # Any request that carries tools goes straight to the capable model.
        if data.get("tools"):
            data["model"] = _ENGLISH_MODEL
            data.setdefault("metadata", {})
            data["metadata"]["detected_script"] = "tool-use"
            data["metadata"]["routed_model"]    = _ENGLISH_MODEL
            data["metadata"]["trace_name"]      = "chat/tool-use"
            data["metadata"]["generation_name"] = f"{_ENGLISH_MODEL}/response"
            data["metadata"]["tags"]            = ["script:tool-use", f"routed:{_ENGLISH_MODEL}"]
            return data

        # ── 2. Image routing ──────────────────────────────────────────────────
        if _IMAGE_RE.search(last_user):
            _image_tasks[call_id] = asyncio.ensure_future(_generate_image(last_user))
            data["model"]      = _ENGLISH_MODEL
            data["max_tokens"] = 1
            data.setdefault("metadata", {})
            data["metadata"]["detected_script"] = "image"
            data["metadata"]["routed_model"]    = _IMAGE_MODEL
            data["metadata"]["trace_name"]      = "image/generate"
            data["metadata"]["generation_name"] = "image-stub"
            data["metadata"]["tags"]            = ["script:image", f"routed:{_IMAGE_MODEL}"]
            # stream stays as-is — streaming calls use async_post_call_streaming_iterator_hook,
            # non-streaming calls use async_post_call_success_hook.
            return data

        # ── 2. Language routing ───────────────────────────────────────────────
        script = _dominant_script(last_user)
        if script == "hangul":
            routed = _MULTILINGUAL_MODEL
        elif script == "cjk":
            routed = _CJK_MODEL
        else:
            routed = _ENGLISH_MODEL
        data["model"] = routed

        data.setdefault("metadata", {})
        data["metadata"]["detected_script"] = script
        data["metadata"]["routed_model"]    = routed
        data["metadata"]["trace_name"]      = f"chat/{script}"
        data["metadata"]["generation_name"] = f"{routed}/response"
        data["metadata"]["tags"]            = [f"script:{script}", f"routed:{routed}"]

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
        # Tag the actual model used — may differ from routed_model when fallback occurs.
        meta = kwargs.get("litellm_params", {}).get("metadata") or {}
        if not meta.get("routed_model"):
            return

        actual = getattr(response_obj, "model", None) or kwargs.get("model", "")
        # Normalise: LiteLLM sometimes prefixes with provider, e.g. "openai/gpt-4o"
        actual_alias = actual.split("/")[-1] if "/" in actual else actual

        tags = meta.get("tags") or []
        tags.append(f"actual:{actual_alias}")
        if actual_alias != meta["routed_model"]:
            tags.append("fallback:true")
        meta["tags"] = tags
        meta["actual_model"] = actual_alias

    async def async_post_call_failure_hook(self, data, user_api_key_dict, original_exception):
        # Clean up the image task on LLM failure so the dict does not leak.
        call_id = str(data.get("litellm_call_id") or id(data))
        task = _image_tasks.pop(call_id, None)
        if task and not task.done():
            task.cancel()


# LiteLLM discovers the callback by module-level instantiation.
language_router = UnifiedRouter()
