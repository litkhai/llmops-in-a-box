"""
User feedback sidecar for Langfuse score integration.

Flow
----
1. LiteLLM callback (async_log_success_event) calls POST /register with the
   Langfuse trace_id and the response content.
2. This service stores SHA-256(content[:500]) → trace_id in an in-memory dict.
3. When a user submits a rating, the client POSTs to /feedback with the
   response content and a rating of 1 (thumbs up) or -1 (thumbs down).
4. This service looks up the trace_id by content hash and writes a Langfuse
   user_feedback score via the Langfuse REST API.
"""

import hashlib
import os

import httpx
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI(title="Feedback Sidecar", version="1.0")

# ── in-memory store: sha256(content[:500]) → trace_id ────────────────────────
_store: dict[str, str] = {}

_LANGFUSE_HOST = os.environ.get("LANGFUSE_HOST", "http://langfuse-web:3000")
_LANGFUSE_PK   = os.environ.get("LANGFUSE_PUBLIC_KEY", "")
_LANGFUSE_SK   = os.environ.get("LANGFUSE_SECRET_KEY", "")


def _content_hash(text: str) -> str:
    return hashlib.sha256(text[:500].encode()).hexdigest()


# ── models ────────────────────────────────────────────────────────────────────

class RegisterRequest(BaseModel):
    trace_id: str
    content:  str


class FeedbackRequest(BaseModel):
    content: str
    rating:  int   # 1 = thumbs up, -1 = thumbs down


# ── endpoints ─────────────────────────────────────────────────────────────────

@app.post("/register")
async def register(req: RegisterRequest) -> dict:
    """Called by LiteLLM callback after each response."""
    _store[_content_hash(req.content)] = req.trace_id
    return {"ok": True}


@app.post("/feedback")
async def feedback(req: FeedbackRequest) -> dict:
    """Called when a user submits a rating."""
    trace_id = _store.get(_content_hash(req.content))
    if not trace_id:
        return {"ok": False, "reason": "trace not found"}

    value   = 1.0 if req.rating > 0 else 0.0
    comment = "thumbs_up" if req.rating > 0 else "thumbs_down"

    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{_LANGFUSE_HOST}/api/public/scores",
            auth=(_LANGFUSE_PK, _LANGFUSE_SK),
            json={
                "traceId":  trace_id,
                "name":     "user_feedback",
                "value":    value,
                "dataType": "BOOLEAN",
                "comment":  comment,
            },
            timeout=10.0,
        )
        resp.raise_for_status()

    return {"ok": True, "trace_id": trace_id}


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}
