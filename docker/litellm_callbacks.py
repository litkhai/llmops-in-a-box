"""
Routing callbacks for LLMOps in a Box.

Two routing decisions are made here before the request reaches a provider:

1. IMAGE ROUTING — if the last user message contains image-generation intent
   keywords, the callback:
     a. Starts image generation as a background asyncio task (HF → CF fallback
        handled by LiteLLM router; call traced in Langfuse independently).
     b. Routes the chat request to a cheap LLM call (max_tokens=1, stream=False)
        so a response object exists for the post-call hook to intercept.
     c. In async_post_call_success_hook, awaits the image task and replaces the
        response content with a markdown image tag before it reaches the client.

   LibreChat renders the markdown image tag inline in the chat message.

2. LANGUAGE ROUTING — for plain chat requests the model field is rewritten based
   on the dominant Unicode script of the last user message:
     non-Latin-primary (Korean, CJK, …) → claude-sonnet
     Latin-primary (English, …)          → gpt-4o

   Fallback (configured in litellm_config.yaml):
     gpt-4o ↔ claude-sonnet  (bidirectional)
     auto   → claude-sonnet  (if language-routed target fails)

Script detection is a pure Unicode heuristic — no extra network call, < 1 ms
added to p99 latency.
"""

import asyncio
import os
import re
from typing import Dict

import httpx
import litellm

# ── model aliases (must match stack.yaml / litellm_config.yaml) ──────────────
_ENGLISH_MODEL      = "gpt-4o"
_MULTILINGUAL_MODEL = "claude-sonnet"
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
_NON_LATIN_THRESHOLD = 0.15


def _dominant_script(text: str) -> str:
    if not text:
        return "latin"
    non_latin = sum(1 for c in text if ord(c) > 0x024F)
    return "non-latin" if (non_latin / len(text)) > _NON_LATIN_THRESHOLD else "latin"


# ── image generation ──────────────────────────────────────────────────────────

async def _generate_image(prompt: str) -> str:
    """
    Call LiteLLM's own /v1/images/generations endpoint so the HF → CF fallback
    and Langfuse tracing are handled by the router, not inlined here.
    Returns a markdown image tag or an error message.
    """
    master_key = os.environ.get("LITELLM_MASTER_KEY", "")
    try:
        async with httpx.AsyncClient(timeout=90.0) as client:
            resp = await client.post(
                "http://localhost:4000/v1/images/generations",
                json={"model": _IMAGE_MODEL, "prompt": prompt, "n": 1},
                headers={"Authorization": f"Bearer {master_key}"},
            )
            resp.raise_for_status()
            body = resp.json()
            img = body["data"][0]
            if img.get("url"):
                return f"![generated image]({img['url']})"
            if img.get("b64_json"):
                return f"![generated image](data:image/png;base64,{img['b64_json']})"
    except httpx.HTTPStatusError as exc:
        return f"Image generation failed (HTTP {exc.response.status_code}): {exc.response.text[:200]}"
    except Exception as exc:
        return f"Image generation failed: {exc}"
    return "Image generation returned no result."


# ── callback ──────────────────────────────────────────────────────────────────

class UnifiedRouter(litellm.CustomLogger):
    """
    Pre-call hook: image intent detection + language routing.
    Post-call hook: replace response with generated image if applicable.
    """

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        # Image generation requests from LibreChat's DALL-E UI already go to
        # /v1/images/generations — no interception needed.
        if call_type != "completion":
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

        # ── 1. Image routing ──────────────────────────────────────────────────
        if _IMAGE_RE.search(last_user):
            # Launch image generation concurrently; do not await here so the
            # cheap LLM call runs in parallel and the hook returns immediately.
            _image_tasks[call_id] = asyncio.ensure_future(_generate_image(last_user))
            # Cheap background LLM call — its response will be replaced in the
            # post-call hook once image generation completes.
            data["model"]      = _ENGLISH_MODEL
            data["max_tokens"] = 1
            data["stream"]     = False   # must be non-streaming for post-hook intercept
            return data

        # ── 2. Language routing ───────────────────────────────────────────────
        if _dominant_script(last_user) == "non-latin":
            data["model"] = _MULTILINGUAL_MODEL
        else:
            data["model"] = _ENGLISH_MODEL

        return data

    async def async_post_call_success_hook(self, data, user_api_key_dict, response):
        call_id = str(data.get("litellm_call_id") or id(data))

        if call_id not in _image_tasks:
            return response

        task = _image_tasks.pop(call_id)
        img_markdown = await task   # wait for image generation to finish

        try:
            response.choices[0].message.content = img_markdown
        except (AttributeError, IndexError, TypeError):
            pass

        return response

    async def async_post_call_failure_hook(self, data, user_api_key_dict, original_exception):
        # Clean up the image task on LLM failure so the dict does not leak.
        call_id = str(data.get("litellm_call_id") or id(data))
        task = _image_tasks.pop(call_id, None)
        if task and not task.done():
            task.cancel()


# LiteLLM discovers the callback by module-level instantiation.
language_router = UnifiedRouter()
