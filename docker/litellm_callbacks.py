"""
Routing callbacks for LLMOps in a Box.

Two routing decisions are made here before the request reaches a provider:

1. IMAGE ROUTING — if the last user message contains image-generation intent
   keywords, the callback calls LiteLLM's own /v1/images/generations endpoint
   (which routes HuggingFace → Cloudflare with automatic fallback) and returns
   the result as a mock chat completion.  LibreChat renders the markdown image
   tag inline.  The separate image generation call is traced in Langfuse
   independently.

2. LANGUAGE ROUTING — for plain chat requests, the model field is rewritten
   based on the dominant Unicode script of the last user message:
     non-Latin-primary (Korean, CJK, …) → claude-sonnet
     Latin-primary (English, …)          → gpt-4o

   Fallback (configured in litellm_config.yaml):
     gpt-4o ↔ claude-sonnet  (bidirectional)
     auto   → claude-sonnet  (if language-routed target fails)

Script detection is a pure Unicode heuristic — no extra network call, < 1 ms
added to p99 latency.
"""

import os
import re

import httpx
import litellm

# ── model aliases (must match stack.yaml / litellm_config.yaml) ──────────────
_ENGLISH_MODEL      = "gpt-4o"
_MULTILINGUAL_MODEL = "claude-sonnet"
_IMAGE_MODEL        = "dall-e-3"   # LiteLLM alias that routes HF → CF

# Aliases the language router is allowed to rewrite.
_ROUTABLE_ALIASES = {_ENGLISH_MODEL, _MULTILINGUAL_MODEL, "auto", ""}

# ── image intent detection ────────────────────────────────────────────────────
# Korean: 그려, 그림, 이미지, 사진, 그려줘/봐/주세요, 만들어줘, 생성해줘, 그려봐
# English: draw, image, picture, generate image, create image, paint, illustrate
_IMAGE_RE = re.compile(
    r"(그려|그림|이미지\s*(만들|생성|그려|그려줘|그려봐)|사진\s*(만들|생성)"
    r"|만들어\s*줘|생성해\s*줘|그려\s*줘|그려\s*봐|그려\s*주세요"
    r"|draw\b|paint\b|illustrat"
    r"|generate\s+(an?\s+)?(image|picture|photo|illustration)"
    r"|create\s+(an?\s+)?(image|picture|photo|illustration)"
    r"|\bimage\s+of\b|\bpicture\s+of\b)",
    re.IGNORECASE,
)

# ── language heuristic ────────────────────────────────────────────────────────
_NON_LATIN_THRESHOLD = 0.15


def _dominant_script(text: str) -> str:
    if not text:
        return "latin"
    non_latin = sum(1 for c in text if ord(c) > 0x024F)
    return "non-latin" if (non_latin / len(text)) > _NON_LATIN_THRESHOLD else "latin"


# ── image generation helper ───────────────────────────────────────────────────

async def _generate_image(prompt: str) -> str:
    """
    Call LiteLLM's own /v1/images/generations endpoint so that:
      - HF → CF fallback is handled by the LiteLLM router
      - The image generation call is traced in Langfuse separately
    Returns a markdown image tag suitable for a chat response.
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
    Pre-call hook that handles both image routing and language routing.

    Priority:
      1. Image intent detected → call image generation, inject mock_response
      2. Plain chat → rewrite model via language routing
    """

    async def async_pre_call_hook(self, user_api_key_dict, cache, data, call_type):
        # Image generation requests from the DALL-E UI already go directly to
        # /v1/images/generations — no rewrite needed.
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

        # ── 1. Image routing ──────────────────────────────────────────────────
        if _IMAGE_RE.search(last_user):
            img_markdown = await _generate_image(last_user)
            # Setting mock_response causes litellm.acompletion() to return a
            # synthetic chat completion without calling any LLM provider.
            data["mock_response"] = img_markdown
            return data

        # ── 2. Language routing ───────────────────────────────────────────────
        if _dominant_script(last_user) == "non-latin":
            data["model"] = _MULTILINGUAL_MODEL
        else:
            data["model"] = _ENGLISH_MODEL

        return data


# LiteLLM discovers the callback by module-level instantiation.
language_router = UnifiedRouter()
