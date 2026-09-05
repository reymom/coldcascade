// A small ABI codec, written rather than imported.
//
// The page needs eleven calls and no build step, and every byte it sends has to be one this
// repository can be held to. A CDN import would put a third party between the judge's browser and
// the router's calldata, on a page whose whole claim is that what you see is what the chain did.
//
// It is generic over a type tree rather than hand-rolled per call, because per-call offset
// arithmetic is exactly the class of mistake that ships a strategy nobody can reach: one encoder,
// exercised by every call on the page.

const WORD = 32;

/** @param {string} t a solidity type: uint256, address, bool, bytes32, bytes, string, T[], (A,B) */
export function parseType(t) {
  t = t.trim();
  if (t.endsWith("]")) {
    const open = matchBracket(t);
    const inner = parseType(t.slice(0, open));
    const size = t.slice(open + 1, -1);
    return size === ""
      ? { kind: "array", of: inner, dynamic: true }
      : { kind: "array", of: inner, length: Number(size), dynamic: inner.dynamic };
  }
  if (t.startsWith("(")) {
    const parts = splitTop(t.slice(1, -1)).map(parseType);
    return { kind: "tuple", parts, dynamic: parts.some((p) => p.dynamic) };
  }
  if (t === "bytes" || t === "string") return { kind: t, dynamic: true };
  if (t === "address") return { kind: "address", dynamic: false };
  if (t === "bool") return { kind: "bool", dynamic: false };
  if (/^bytes(\d+)$/.test(t)) return { kind: "bytesN", n: Number(t.slice(5)), dynamic: false };
  if (/^u?int(\d+)?$/.test(t)) return { kind: "int", signed: t[0] === "i", bits: Number(t.replace(/\D/g, "") || 256), dynamic: false };
  throw new Error(`abi: unsupported type ${t}`);
}

/** Split a top-level comma list, ignoring commas inside parentheses. */
function splitTop(s) {
  const out = [];
  let depth = 0, start = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "(" || c === "[") depth++;
    else if (c === ")" || c === "]") depth--;
    else if (c === "," && depth === 0) { out.push(s.slice(start, i)); start = i + 1; }
  }
  if (s.trim() !== "") out.push(s.slice(start));
  return out;
}

/** Index of the '[' that opens the trailing array suffix. */
function matchBracket(t) {
  let depth = 0;
  for (let i = t.length - 1; i >= 0; i--) {
    if (t[i] === "]") depth++;
    else if (t[i] === "[") { depth--; if (depth === 0) return i; }
  }
  throw new Error(`abi: unbalanced ${t}`);
}

const hex = (n, width = 64) => {
  let v = BigInt(n);
  if (v < 0n) v += 1n << BigInt(width * 4);       // two's complement at the encoded width
  return v.toString(16).padStart(width, "0");
};

function encodeOne(type, value) {
  switch (type.kind) {
    case "int": return { head: hex(value), tail: "" };
    case "bool": return { head: hex(value ? 1 : 0), tail: "" };
    case "address": return { head: hex(BigInt(value)), tail: "" };
    case "bytesN": return { head: strip(value).padEnd(64, "0"), tail: "" };
    case "bytes":
    case "string": {
      const raw = type.kind === "string" ? utf8(value) : strip(value);
      const padded = raw.padEnd(Math.ceil(raw.length / 64) * 64, "0");
      return { head: null, tail: hex(raw.length / 2) + padded };
    }
    case "array": {
      const items = value.map((v) => encodeOne(type.of, v));
      const body = pack(type.of, items);
      return type.dynamic || type.length === undefined
        ? { head: null, tail: (type.length === undefined ? hex(value.length) : "") + body }
        : { head: body, tail: "" };
    }
    case "tuple": {
      const items = type.parts.map((p, i) => encodeOne(p, value[i]));
      const body = packHeads(type.parts, items);
      return type.dynamic ? { head: null, tail: body } : { head: body, tail: "" };
    }
    default: throw new Error(`abi: cannot encode ${type.kind}`);
  }
}

/** Heads then tails, with each dynamic head holding the offset of its tail. */
function packHeads(types, items) {
  let headSize = 0;
  types.forEach((t, i) => { headSize += t.dynamic ? WORD : items[i].head.length / 2; });
  let heads = "", tails = "", offset = headSize;
  types.forEach((t, i) => {
    if (t.dynamic) { heads += hex(offset); tails += items[i].tail; offset += items[i].tail.length / 2; }
    else heads += items[i].head;
  });
  return heads + tails;
}

function pack(type, items) {
  return packHeads(items.map(() => type), items);
}

export function encode(types, values) {
  const parsed = types.map(parseType);
  return packHeads(parsed, parsed.map((t, i) => encodeOne(t, values[i])));
}

/** @returns {string} 0x-prefixed calldata for `name(types...)` */
export function calldata(selector, types, values) {
  return selector + encode(types, values);
}

function decodeOne(type, data, base, cursor) {
  const word = () => data.slice(cursor.at, cursor.at + 64);
  switch (type.kind) {
    case "int": {
      let v = BigInt("0x" + word());
      cursor.at += 64;
      if (type.signed && v >= 1n << BigInt(type.bits - 1)) v -= 1n << BigInt(type.bits);
      return v;
    }
    case "bool": { const v = BigInt("0x" + word()) !== 0n; cursor.at += 64; return v; }
    case "address": { const v = "0x" + word().slice(24); cursor.at += 64; return v; }
    case "bytesN": { const v = "0x" + word().slice(0, type.n * 2); cursor.at += 64; return v; }
    case "bytes":
    case "string": {
      const at = base + Number(BigInt("0x" + word())) * 2;
      cursor.at += 64;
      const len = Number(BigInt("0x" + data.slice(at, at + 64)));
      const raw = data.slice(at + 64, at + 64 + len * 2);
      return type.kind === "string" ? fromUtf8(raw) : "0x" + raw;
    }
    case "array": {
      if (type.length !== undefined && !type.dynamic) {
        const out = [];
        for (let i = 0; i < type.length; i++) out.push(decodeOne(type.of, data, base, cursor));
        return out;
      }
      const at = base + Number(BigInt("0x" + word())) * 2;
      cursor.at += 64;
      const len = type.length ?? Number(BigInt("0x" + data.slice(at, at + 64)));
      const body = type.length === undefined ? at + 64 : at;
      const inner = { at: body };
      const out = [];
      for (let i = 0; i < len; i++) out.push(decodeOne(type.of, data, body, inner));
      return out;
    }
    case "tuple": {
      if (!type.dynamic) return type.parts.map((p) => decodeOne(p, data, base, cursor));
      const at = base + Number(BigInt("0x" + word())) * 2;
      cursor.at += 64;
      const inner = { at };
      return type.parts.map((p) => decodeOne(p, data, at, inner));
    }
    default: throw new Error(`abi: cannot decode ${type.kind}`);
  }
}

export function decode(types, data) {
  const raw = strip(data);
  const parsed = types.map(parseType);
  const cursor = { at: 0 };
  return parsed.map((t) => decodeOne(t, raw, 0, cursor));
}

export const strip = (h) => (h ?? "").replace(/^0x/, "");
const utf8 = (s) => Array.from(new TextEncoder().encode(s), (b) => b.toString(16).padStart(2, "0")).join("");
const fromUtf8 = (h) => new TextDecoder().decode(Uint8Array.from(h.match(/../g) ?? [], (b) => parseInt(b, 16)));
