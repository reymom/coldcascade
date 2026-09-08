"""MCP over stdio, JSON-RPC 2.0, standard library only.

No SDK on purpose. The keeper next door is stdlib and `cast`, and the same property is worth more
here than the convenience: a judge or an integrator can run this with a stock Python and no
install step, and the whole protocol surface is one readable file rather than a framework.

Protocol version 2024-11-05, which is what The Graph's own Subgraph MCP Server negotiates.
"""

from __future__ import annotations

import json
import sys
import traceback
from pathlib import Path

from .instructions import SERVER_INSTRUCTIONS
from .store import Store, parse_time, provenance

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "coldcascade-mcp"
SERVER_VERSION = "0.1.0"
SKILL_PATH = Path(__file__).resolve().parents[1] / "SKILL.md"

_LIMITS = {
    "notForTrading": (
        "Observations and their limits. This server does not produce trading advice, signals or "
        "recommendations."
    ),
    "priceScale": "Raw L1 units, USD * 10^(6 - szDecimals). BTC: divide by 10. *Usd fields are converted.",
}


def _tools() -> list[dict]:
    return [
        {
            "name": "get_book_at_time",
            "description": (
                "What Hyperliquid's BBO was at a past moment. THE query no RPC can answer: the "
                "HyperCore precompiles ignore the block tag and return the current book, so this "
                "instant exists only because a poke wrote it into a log. Returns the observations "
                "bracketing the moment; never interpolates."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "time": {
                        "type": ["string", "number"],
                        "description": "ISO-8601 (e.g. 2026-09-08T16:30:00Z) or unix seconds. UTC if no offset.",
                    }
                },
                "required": ["time"],
            },
        },
        {
            "name": "get_book_at_block",
            "description": (
                "What Hyperliquid's BBO was at a past HyperEVM block. Same archive as "
                "get_book_at_time, addressed by block number."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {"block": {"type": "integer", "description": "HyperEVM block number on chain 999."}},
                "required": ["block"],
            },
        },
        {
            "name": "get_book_series",
            "description": (
                "The book archive over a window, with its cadence and every hole wider than 180 "
                "seconds. Use it to see what is and is not covered before trusting a point query."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "from_time": {"type": ["string", "number"], "description": "ISO-8601 or unix seconds."},
                    "to_time": {"type": ["string", "number"], "description": "ISO-8601 or unix seconds."},
                    "limit": {"type": "integer", "description": "Max observations to return (default 200)."},
                },
            },
        },
        {
            "name": "get_fill",
            "description": (
                "One fill in full: the book it was priced against, vsTouchBps, poolDevBps, the "
                "desk's quietBps, the markouts at each horizon, and a sentence saying whether the "
                "bound or the curve set the price. Accepts a full or partial transaction hash."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {"tx_hash": {"type": "string", "description": "Transaction hash, or a unique prefix."}},
                "required": ["tx_hash"],
            },
        },
        {
            "name": "list_fills",
            "description": (
                "The desk's fills, filterable by desk, side, and whether the price was set by the "
                "bound or by the curve. Returns the per-side summary alongside."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "desk": {"type": "string", "description": "deskName (demoDesk, canonicalDesk, hedgedDesk) or address."},
                    "side": {"type": "string", "enum": ["buysBase", "sellsBase"], "description": "The maker's side."},
                    "priced_by": {"type": "string", "enum": ["bound", "curve"], "description": "Which rule set the price."},
                    "since": {"type": ["string", "number"], "description": "ISO-8601 or unix seconds."},
                    "limit": {"type": "integer", "description": "Max fills to return (default 50)."},
                },
            },
        },
        {
            "name": "get_markouts",
            "description": (
                "Markouts at 5, 15 and 60 minutes, each with an honest status and whether it has "
                "been posted to MarkoutLedger on chain. Not a performance claim — see the status "
                "vocabulary and the server instructions."
            ),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "fill_id": {"type": "string", "description": "fillId, or a prefix."},
                    "horizon": {"type": "integer", "enum": [5, 15, 60], "description": "Horizon in minutes."},
                },
            },
        },
        {
            "name": "describe_coverage",
            "description": (
                "What this server holds, how dense it is, and — explicitly — what it cannot "
                "answer. Call this first when the time range is not already known."
            ),
            "inputSchema": {"type": "object", "properties": {}},
        },
    ]


class Server:
    def __init__(self) -> None:
        self.store = Store()

    # --- dispatch ----------------------------------------------------------------------------

    def call_tool(self, name: str, args: dict) -> dict:
        s = self.store
        s.load()  # the keeper rewrites the corpus every twenty minutes; never serve a stale one

        if name == "get_book_at_time":
            t = parse_time(args["time"])
            body = s.book_at(time=t)
            blk = (body.get("before") or body.get("after") or {}).get("atBlock")
            body["provenance"] = provenance("book", block=blk)
        elif name == "get_book_at_block":
            body = s.book_at(block=int(args["block"]))
            body["provenance"] = provenance("book", block=int(args["block"]))
        elif name == "get_book_series":
            body = s.series(
                from_time=parse_time(args["from_time"]) if args.get("from_time") is not None else None,
                to_time=parse_time(args["to_time"]) if args.get("to_time") is not None else None,
                limit=int(args.get("limit", 200)),
            )
            body["provenance"] = provenance("book")
        elif name == "get_fill":
            body = s.fill(args["tx_hash"])
            f = body.get("fill") or {}
            body["provenance"] = provenance("fill", block=f.get("block"), tx_hash=f.get("txHash"))
        elif name == "list_fills":
            body = s.list_fills(
                desk=args.get("desk"), side=args.get("side"), priced_by=args.get("priced_by"),
                since=parse_time(args["since"]) if args.get("since") is not None else None,
                limit=int(args.get("limit", 50)),
            )
            body["provenance"] = provenance("fill")
        elif name == "get_markouts":
            body = s.markouts_for(args.get("fill_id"), args.get("horizon"))
            body["provenance"] = provenance("markout")
        elif name == "describe_coverage":
            body = s.coverage()
            body["provenance"] = provenance("book")
        else:
            raise KeyError(f"unknown tool: {name}")

        body.setdefault("limits", {}).update(_LIMITS)
        return body

    def handle(self, msg: dict):
        method, mid = msg.get("method"), msg.get("id")
        params = msg.get("params") or {}

        if method == "initialize":
            return {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}, "resources": {}, "prompts": {}},
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "instructions": SERVER_INSTRUCTIONS,
            }
        if method in ("notifications/initialized", "notifications/cancelled"):
            return None
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": _tools()}
        if method == "tools/call":
            name = params.get("name", "")
            try:
                body = self.call_tool(name, params.get("arguments") or {})
            except Exception as e:  # a tool error is a result, not a protocol error
                return {
                    "content": [{"type": "text", "text": json.dumps(
                        {"error": str(e), "tool": name,
                         "hint": "Call describe_coverage to see what this server holds."},
                        indent=2)}],
                    "isError": True,
                }
            return {"content": [{"type": "text", "text": json.dumps(body, indent=2)}],
                    "structuredContent": body}
        if method == "resources/list":
            return {"resources": [
                {"uri": "coldcascade://instructions", "name": "coldcascade Server Instructions",
                 "description": "How to query the book archive and the desk's record, and how to read the answers.",
                 "mimeType": "text/markdown"},
                {"uri": "coldcascade://skill", "name": "coldcascade SKILL",
                 "description": "The full manual: endpoint, package, tools, output shapes, and what this cannot answer.",
                 "mimeType": "text/markdown"},
                {"uri": "coldcascade://coverage", "name": "Current coverage",
                 "description": "Live extent of the book archive and the desk's record.",
                 "mimeType": "application/json"},
            ]}
        if method == "resources/read":
            uri = params.get("uri", "")
            if uri == "coldcascade://instructions":
                text, mime = SERVER_INSTRUCTIONS, "text/markdown"
            elif uri == "coldcascade://skill":
                text = SKILL_PATH.read_text() if SKILL_PATH.exists() else SERVER_INSTRUCTIONS
                mime = "text/markdown"
            elif uri == "coldcascade://coverage":
                self.store.load()
                text, mime = json.dumps(self.store.coverage(), indent=2), "application/json"
            else:
                raise KeyError(f"resource not found: {uri}")
            return {"contents": [{"uri": uri, "mimeType": mime, "text": text}]}
        if method == "prompts/list":
            return {"prompts": [
                {"name": "book_at",
                 "description": "What was Hyperliquid's BBO at a given time or block?",
                 "arguments": [{"name": "when", "description": "ISO-8601 time, or a block number.", "required": True}]},
                {"name": "explain_fill",
                 "description": "Explain one fill: the book it met, where it printed, and which rule set the price.",
                 "arguments": [{"name": "tx_hash", "description": "The fill's transaction hash.", "required": True}]},
                {"name": "coverage",
                 "description": "What does this archive cover, and what can it not answer?",
                 "arguments": []},
            ]}
        if method == "prompts/get":
            name = params.get("name", "")
            arg = (params.get("arguments") or {})
            texts = {
                "book_at": (
                    f"Using the coldcascade tools, tell me what Hyperliquid's BTC BBO was at "
                    f"{arg.get('when', '<when>')} on chain 999. If no poke landed at that exact "
                    f"moment, give me both bracketing observations and their distances rather than "
                    f"a single number, and include the reproduce command from the provenance."),
                "explain_fill": (
                    f"Using the coldcascade tools, explain fill {arg.get('tx_hash', '<txHash>')}: "
                    f"the L1 book it was priced against, where it printed against the touch, "
                    f"whether the bound or the curve set that price and why, and the state of its "
                    f"markouts. Include the commands that reproduce and verify it."),
                "coverage": (
                    "Using describe_coverage, summarise what the coldcascade book archive covers, "
                    "how dense it is, where the holes are, and what it explicitly cannot answer."),
            }
            if name not in texts:
                raise KeyError(f"prompt not found: {name}")
            return {"description": name,
                    "messages": [{"role": "user", "content": {"type": "text", "text": texts[name]}}]}
        raise KeyError(f"unknown method: {method}")


def main() -> int:
    server = Server()
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        mid = msg.get("id")
        try:
            result = server.handle(msg)
        except KeyError as e:
            if mid is None:
                continue
            resp = {"jsonrpc": "2.0", "id": mid,
                    "error": {"code": -32601, "message": str(e)}}
            out.write(json.dumps(resp) + "\n"); out.flush(); continue
        except Exception as e:
            if mid is None:
                continue
            print(traceback.format_exc(), file=sys.stderr)
            resp = {"jsonrpc": "2.0", "id": mid,
                    "error": {"code": -32603, "message": f"internal error: {e}"}}
            out.write(json.dumps(resp) + "\n"); out.flush(); continue
        if result is None or mid is None:      # notifications get no reply
            continue
        out.write(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}) + "\n")
        out.flush()
    return 0
