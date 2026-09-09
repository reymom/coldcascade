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

Eight tools, three resources, three prompts. **`mcp/SKILL.md` is the manual** and the server
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

Decoded Substreams output, by either of two routes, and every answer says which:

- **`results/desk-events.jsonl`** — a committed snapshot of the corpus, so a fresh clone answers
  with no credentials and no network. `describe_coverage` reports `corpus.kind: "snapshot"` and
  the block it stops at.
- **`keeper/.cache/desk_events.jsonl`** — the live corpus, written either by the keeper's cadence
  or by this server's own `sync_stream`, which runs the package against The Graph Market (Pinax)
  and streams the tail on top of the snapshot. Set `SUBSTREAMS_API_TOKEN` (a free key from
  https://thegraph.market) and install the `substreams` CLI; without them `sync_stream` says what
  is missing and the snapshot keeps answering.

`results/markouts.json` is what the keeper derived from the corpus, and is committed too.

**It never falls back to an RPC for a book** — the whole point of the archive is that the RPC
cannot answer, so a fallback would silently answer a different question. The single node call in
the server is one `eth_blockNumber` inside `sync_stream`, asking where to stop.

Refresh from this side:

```bash
python -m coldcascade markouts        # or ./script/markout-cadence.sh
./script/publish-results.sh           # commits the artifact and the corpus snapshot
```
