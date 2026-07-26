-- Runs once, on first initialisation of the Postgres volume.
--
-- Langfuse owns the `postgres` database (POSTGRES_DB). LiteLLM needs its own
-- for virtual keys and budget enforcement — `stack.yaml` declares
-- layers.gateway.options.budget.max_budget_usd, and LiteLLM cannot enforce a
-- budget or persist a virtual key without a database. One Postgres server,
-- two logical databases, so the declared guardrail is actually live.
CREATE DATABASE litellm;
