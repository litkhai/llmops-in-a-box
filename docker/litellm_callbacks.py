"""
Language-based routing callback for LLMOps in a Box.

Routes requests automatically based on the dominant script of the last user message:
  - Non-Latin-primary text (Korean, Chinese, Japanese, etc.) → claude-sonnet
  - Latin-primary text (English, etc.)                       → gpt-4o

Fallback: claude-sonnet → gpt-4o  (configured in litellm_config.yaml)

The callback rewrites the `model` field before LiteLLM resolves the route, so
it is transparent to the client — the client sends any alias (or nothing) and
the router picks the right model. Explicit model selections other than "auto"
are respected and not overridden.

Script detection is heuristic, not a language model call:
  - Count characters above U+024F (start of extended Latin supplement)
  - If >15% of the message is non-Latin Unicode, classify as non-Latin
  - Fast enough to add < 1 ms to p99 latency; no network call, no dependency
"""

import litellm

# Models must match the aliases declared in stack.yaml / litellm_config.yaml
_ENGLISH_MODEL = "gpt-4o"
_MULTILINGUAL_MODEL = "claude-sonnet"

# Aliases the router is allowed to rewrite. Any other value is treated as an
# explicit client choice and left untouched.
_ROUTABLE_ALIASES = {_ENGLISH_MODEL, _MULTILINGUAL_MODEL, "auto", ""}

# Fraction of characters that must exceed U+024F to classify as non-Latin.
# 0.15 means a single Korean word in an otherwise-English sentence does NOT
# flip the route; a predominantly Korean message does.
_NON_LATIN_THRESHOLD = 0.15


def _dominant_script(text: str) -> str:
    """Return 'latin' or 'non-latin' based on Unicode character composition."""
    if not text:
        return "latin"
    non_latin = sum(1 for c in text if ord(c) > 0x024F)
    return "non-latin" if (non_latin / len(text)) > _NON_LATIN_THRESHOLD else "latin"


class LanguageRouter(litellm.CustomLogger):
    """Pre-call hook that rewrites `model` based on detected script."""

    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data,
        call_type,
    ):
        if call_type != "completion":
            return data

        requested = data.get("model", "")
        if requested not in _ROUTABLE_ALIASES:
            # Client explicitly chose a model — respect it.
            return data

        messages = data.get("messages") or []
        last_user = next(
            (
                m.get("content", "")
                for m in reversed(messages)
                if m.get("role") == "user"
            ),
            "",
        )

        if _dominant_script(last_user) == "non-latin":
            data["model"] = _MULTILINGUAL_MODEL
        else:
            data["model"] = _ENGLISH_MODEL

        return data


# LiteLLM discovers the callback by module-level instantiation.
language_router = LanguageRouter()
