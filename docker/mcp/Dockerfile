FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

# mcp-clickhouse: official ClickHouse MCP server (FastMCP-based, supports SSE).
# mcp-proxy: wraps stdio servers as SSE — fallback if --transport sse is unsupported.
RUN pip install --no-cache-dir "mcp-clickhouse>=0.3.0" "mcp-proxy>=0.4.0"

EXPOSE 9100

# mcp-clickhouse uses stdio transport; mcp-proxy wraps it as SSE on port 9100.
# --pass-environment ensures CLICKHOUSE_HOST/USER/PASSWORD reach the subprocess.
CMD ["mcp-proxy", "--port", "9100", "--host", "0.0.0.0", "--pass-environment", "mcp-clickhouse"]
