# coldcascade MCP server

An MCP server over the coldcascade Substreams stream on HyperEVM (chain 999). It exposes the
**HyperCore book archive** — what Hyperliquid's BBO was at a past block or time, which no RPC can
answer — and the **desk's fill record**.

Standard library only. No SDK, no `pip install`, stock Python 3.11+.

```json
{
  "mcpServers": {
    "coldcascade": {
      "command": "python3",
      "args": ["-m", "coldcascade_mcp"],
      "cwd": "/absolute/path/to/coldcascade/mcp"
    }
  }
}
```

Seven tools, three resources, three prompts. **`mcp/SKILL.md` is the manual** and the server
serves it at `coldcascade://skill`.

Smoke test without a client:

```bash
cd mcp && printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"x","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_book_at_time","arguments":{"time":"2026-09-08T16:30:00Z"}}}' \
  | python3 -m coldcascade_mcp
```

Tests: `python3 -m unittest discover -s mcp/tests`.

## Where the data comes from

The server reads the corpus the keeper maintains from the Substreams stream
(`keeper/.cache/desk_events.jsonl`) and what the keeper derived from it
(`results/markouts.json`). **It never falls back to an RPC** — the whole point of the book archive
is that the RPC cannot answer, so a fallback would silently answer a different question.

Run the keeper to refresh both:

```bash
python -m coldcascade markouts        # or ./script/markout-cadence.sh
```
