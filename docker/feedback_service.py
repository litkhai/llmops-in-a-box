"""
User feedback proxy for Langfuse scoring.

Flow
----
1. LiteLLM callback (async_log_success_event) calls POST /register with the
   Langfuse trace_id and the first 300 chars of the response content.
2. This service stores a SHA-256 content hash → trace_id mapping (in-process,
   capped at 2000 entries — sufficient for a running session).
3. When a user submits feedback (thumbs-up/down, star rating, or any numeric
   value), the client POSTs to /score with the response content and the rating.
4. This service looks up the trace_id by content hash and writes a Langfuse
   score via the Langfuse HTTP API.

Client examples
---------------
Thumbs up via curl:
  curl -s http://localhost:8080/score \
       -H "Content-Type: application/json" \
       -d '{"content": "ClickHouse is a column-oriented...", "value": 1.0}'

Thumbs down with a comment:
  curl -s http://localhost:8080/score \
       -H "Content-Type: application/json" \
       -d '{"content": "ClickHouse is a column-oriented...", "value": 0.0, "comment": "missed the point"}'

Direct score by trace_id (if you have it):
  curl -s http://localhost:8080/score-by-id \
       -H "Content-Type: application/json" \
       -d '{"trace_id": "abc123", "value": 0.8, "comment": "mostly helpful"}'
"""

import hashlib
import os
from collections import OrderedDict

import httpx
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

app = FastAPI(title="Langfuse Feedback Proxy", version="1.0")

# ── in-process store: content_hash → trace_id ────────────────────────────────
_store: OrderedDict[str, str] = OrderedDict()
_MAX_ENTRIES = 2000


def _hash(text: str) -> str:
    return hashlib.sha256(text[:300].encode()).hexdigest()[:20]


def _store_put(key: str, value: str) -> None:
    _store[key] = value
    while len(_store) > _MAX_ENTRIES:
        _store.popitem(last=False)


# ── Langfuse helper ───────────────────────────────────────────────────────────

async def _langfuse_score(trace_id: str, value: float, comment: str) -> None:
    host = os.environ.get("LANGFUSE_HOST", "http://langfuse-web:3000")
    pk   = os.environ.get("LANGFUSE_PUBLIC_KEY", "")
    sk   = os.environ.get("LANGFUSE_SECRET_KEY", "")
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{host}/api/public/scores",
            auth=(pk, sk),
            json={
                "traceId":  trace_id,
                "name":     "user_feedback",
                "value":    value,
                "dataType": "NUMERIC",
                "comment":  comment or "",
            },
            timeout=10.0,
        )
        resp.raise_for_status()


# ── endpoints ─────────────────────────────────────────────────────────────────

class RegisterRequest(BaseModel):
    trace_id: str
    content:  str


class ScoreRequest(BaseModel):
    content: str
    value:   float          # 1.0 = positive, 0.0 = negative, or any 0–1 float
    comment: str = ""


class ScoreByIdRequest(BaseModel):
    trace_id: str
    value:    float
    comment:  str = ""


@app.post("/register", summary="Called by LiteLLM callback to register a trace")
async def register(req: RegisterRequest) -> dict:
    _store_put(_hash(req.content), req.trace_id)
    return {"ok": True, "stored": len(_store)}


@app.post("/score", summary="Submit user feedback by response content")
async def score(req: ScoreRequest) -> dict:
    key      = _hash(req.content)
    trace_id = _store.get(key)
    if not trace_id:
        raise HTTPException(
            status_code=404,
            detail="Trace not found — content hash mismatch or entry expired. "
                   "Use /score-by-id if you have the trace_id directly.",
        )
    await _langfuse_score(trace_id, req.value, req.comment)
    return {"ok": True, "trace_id": trace_id}


@app.post("/score-by-id", summary="Submit user feedback directly by Langfuse trace_id")
async def score_by_id(req: ScoreByIdRequest) -> dict:
    await _langfuse_score(req.trace_id, req.value, req.comment)
    return {"ok": True, "trace_id": req.trace_id}


@app.get("/health")
async def health() -> dict:
    return {"ok": True, "stored": len(_store)}
