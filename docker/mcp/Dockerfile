FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

# mcp-clickhouse: official ClickHouse MCP server (FastMCP-based, supports SSE).
# mcp-proxy: wraps stdio servers as SSE — fallback if --transport sse is unsupported.
RUN pip install --no-cache-dir "mcp-clickhouse>=0.3.0" "mcp-proxy>=0.4.0"

EXPOSE 9100

# Run in SSE mode so LibreChat can connect over the Docker network.
# mcp-clickhouse is built with FastMCP which accepts --transport sse natively.
# If an older build lacks the flag, swap CMD to:
#   ["mcp-proxy", "--sse-port", "9100", "--", "mcp-clickhouse"]
CMD ["mcp-clickhouse", "--transport", "sse", "--host", "0.0.0.0", "--port", "9100"]
