"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");
const { URL } = require("url");
const { Store } = require("./lib/store");

const PORT = Number(process.env.PORT) || 3000;
const API_KEY = (process.env.API_KEY || "").trim();
const PUBLIC_READ = /^(1|true|yes)$/i.test(process.env.PUBLIC_READ || "");
const SERVER_TTL_MS = Number(process.env.SERVER_TTL_SEC || 480) * 1000;
const CLAIM_TTL_MS = Number(process.env.CLAIM_TTL_SEC || 240) * 1000;
const MAX_BODY = Number(process.env.MAX_BODY_BYTES || 1024 * 1024);

const store = new Store({ serverTtlMs: SERVER_TTL_MS, claimTtlMs: CLAIM_TTL_MS });

const PUBLIC_DIR = path.join(__dirname, "public");
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".json": "application/json; charset=utf-8",
};

// ------------------------------------------------------------------ helpers
function send(res, code, data, headers) {
  const body = typeof data === "string" ? data : JSON.stringify(data);
  res.writeHead(
    code,
    Object.assign(
      {
        "content-type": "application/json; charset=utf-8",
        "content-length": Buffer.byteLength(body),
        "access-control-allow-origin": "*",
        "cache-control": "no-store",
      },
      headers || {}
    )
  );
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) return resolve({});
      try {
        resolve(JSON.parse(raw));
      } catch (e) {
        reject(new Error("invalid json body"));
      }
    });
    req.on("error", reject);
  });
}

function keyOf(req, url) {
  return (
    req.headers["x-eag-key"] ||
    req.headers["x-api-key"] ||
    (req.headers.authorization || "").replace(/^Bearer\s+/i, "") ||
    url.searchParams.get("key") ||
    ""
  ).trim();
}

function authed(req, url) {
  if (!API_KEY) return true;
  return keyOf(req, url) === API_KEY;
}

// Normalises whatever arrives in a list field. Lua does not distinguish array
// from dictionary, so an empty table can arrive as [] or {} depending on the
// executor. A value that is not a usable list means "no filter": stringifying
// it gave '[object Object]', a filter that matched nothing and left the AJ
// silent without saying why.
function toList(v) {
  if (v == null) return null;
  if (Array.isArray(v)) {
    return v.filter((x) => typeof x === "string" || typeof x === "number").map(String);
  }
  if (typeof v === "string") return v.split(",");
  if (typeof v === "number") return [String(v)];
  return null;
}

function parseList(v) {
  const items = toList(v);
  if (!items) return null;
  const parts = items
    .join(",")
    .split(",")
    .map((s) => s.trim().toLowerCase())
    .filter(Boolean);
  return parts.length ? new Set(parts) : null;
}

function num(v) {
  if (v == null || v === "") return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

function filterFromQuery(q) {
  return {
    rarities: parseList(q.get("rarities") || q.get("rarity")),
    species: parseList(q.get("species")),
    minKg: num(q.get("minKg")),
    maxKg: num(q.get("maxKg")),
    minRank: num(q.get("minRank")),
    since: num(q.get("since")),
    sinceSeq: num(q.get("sinceSeq")),
    maxAgeMs: num(q.get("maxAgeSec")) != null ? num(q.get("maxAgeSec")) * 1000 : null,
    maxPlayers: num(q.get("maxPlayers")),
    jobId: (q.get("jobId") || "").trim() || null,
    excludeJobIds: parseListRaw(q.get("exclude")),
    hasSlot: /^(1|true)$/i.test(q.get("hasSlot") || ""),
    newestFirst: /^(1|true)$/i.test(q.get("newest") || ""),
  };
}

// The same filters, arriving in a POST body (what the AJ sends).
function applyBodyFilter(filter, body) {
  if (!body) return filter;
  if (body.rarities != null) filter.rarities = parseList(body.rarities);
  if (body.species != null) filter.species = parseList(body.species);
  if (body.exclude != null) filter.excludeJobIds = parseListRaw(body.exclude);
  if (body.minKg != null) filter.minKg = Number(body.minKg);
  if (body.maxKg != null) filter.maxKg = Number(body.maxKg);
  if (body.minRank != null) filter.minRank = Number(body.minRank);
  if (body.since != null) filter.since = Number(body.since);
  if (body.sinceSeq != null) filter.sinceSeq = Number(body.sinceSeq);
  if (body.maxAgeSec != null) filter.maxAgeMs = Number(body.maxAgeSec) * 1000;
  if (body.maxPlayers != null) filter.maxPlayers = Number(body.maxPlayers);
  if (body.hasSlot != null) filter.hasSlot = !!body.hasSlot;
  if (body.jobId) filter.jobId = String(body.jobId);
  return filter;
}

function parseListRaw(v) {
  const items = toList(v);
  if (!items) return null;
  const parts = items
    .join(",")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);
  return parts.length ? new Set(parts) : null;
}

function ipOf(req) {
  const xf = req.headers["x-forwarded-for"];
  if (xf) return String(xf).split(",")[0].trim();
  return req.socket.remoteAddress || "";
}

// ------------------------------------------------------------------- static
function serveStatic(req, res, pathname) {
  let rel = pathname === "/" ? "/index.html" : pathname;
  rel = rel.replace(/\.\.+/g, "");
  const file = path.join(PUBLIC_DIR, rel);
  if (!file.startsWith(PUBLIC_DIR)) return send(res, 403, { error: "nope" });
  fs.readFile(file, (err, buf) => {
    if (err) return send(res, 404, { error: "not found" });
    res.writeHead(200, {
      "content-type": MIME[path.extname(file)] || "application/octet-stream",
      "content-length": buf.length,
      "cache-control": rel === "/index.html" ? "no-store" : "public, max-age=300",
    });
    res.end(buf);
  });
}

// ---------------------------------------------------------------- long poll
const WAKE_ON = { eggs: 1, egg: 1, release: 1, purge: 1, gone: 1 };

function waitForChange(req, ms) {
  return new Promise((resolve) => {
    let done = false;
    const finish = (v) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      off();
      req.removeListener("close", onClose);
      resolve(v);
    };
    const off = store.subscribe((ev) => {
      if (WAKE_ON[ev.type]) finish(true);
    });
    const onClose = () => finish(false);
    const timer = setTimeout(() => finish(false), Math.max(0, ms));
    req.on("close", onClose);
  });
}

function waitSecondsOf(q, body) {
  const v = num(q.get("wait"));
  const b = body && body.wait != null ? Number(body.wait) : null;
  const n = v != null ? v : b;
  if (!Number.isFinite(n) || n <= 0) return 0;
  return Math.min(n, 55);
}

// ---------------------------------------------------------------------- SSE
function sse(req, res) {
  res.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache, no-transform",
    connection: "keep-alive",
    "access-control-allow-origin": "*",
    "x-accel-buffering": "no",
  });
  res.write(`retry: 3000\n\n`);
  res.write(`event: hello\ndata: ${JSON.stringify(store.snapshot())}\n\n`);

  const off = store.subscribe((ev) => {
    res.write(`event: ${ev.type}\ndata: ${JSON.stringify(ev)}\n\n`);
  });
  const ping = setInterval(() => res.write(`: ping\n\n`), 20000);

  req.on("close", () => {
    clearInterval(ping);
    off();
  });
}

// ------------------------------------------------------------------- routes
const server = http.createServer(async (req, res) => {
  // A HUB_URL pasted with a trailing slash produces "//api/meta". It has to be
  // fixed BEFORE building the URL: "//something" is a protocol-relative URL, so
  // the parser takes "api" as the host and leaves the path as "/meta". The
  // result was a 404 that looked like the hub was down.
  const rawUrl = String(req.url || "/").replace(/^\/+/, "/");
  const url = new URL(rawUrl, `http://${req.headers.host || "localhost"}`);
  const p = url.pathname.replace(/\/{2,}/g, "/").replace(/\/+$/, "") || "/";
  const q = url.searchParams;

  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "access-control-allow-origin": "*",
      "access-control-allow-methods": "GET,POST,DELETE,OPTIONS",
      "access-control-allow-headers": "content-type,x-eag-key,x-api-key,authorization",
      "access-control-max-age": "86400",
    });
    return res.end();
  }

  if (p === "/healthz" || p === "/health") {
    return send(res, 200, { ok: true, uptimeMs: Date.now() - store.stats.startedAt });
  }

  if (!p.startsWith("/api/")) {
    if (req.method !== "GET") return send(res, 405, { error: "method" });
    return serveStatic(req, res, p);
  }

  const needsWrite = req.method !== "GET";
  const ok = authed(req, url);
  if (!ok && (needsWrite || !PUBLIC_READ)) {
    return send(res, 401, { error: "bad or missing key" });
  }

  try {
    if (p === "/api/report" && req.method === "POST") {
      const body = await readBody(req);
      const out = store.report(body, { ip: ipOf(req) });
      return send(res, 200, Object.assign({ ok: true }, out));
    }

    if (p === "/api/feed" && req.method === "GET") {
      const limit = Math.min(num(q.get("limit")) || 200, 1000);
      const f = filterFromQuery(q);
      const waitSec = waitSecondsOf(q, null);

      if (waitSec > 0) {
        const deadline = Date.now() + waitSec * 1000;
        // The cursor (since / sinceSeq) is honoured here too: if the client
        // asked for "only what is new", waiting must not hand back history.
        while (store.match(f).length === 0 && Date.now() < deadline) {
          const changed = await waitForChange(req, deadline - Date.now());
          if (!changed) break;
        }
      }

      const rows = store.match(f);
      return send(res, 200, {
        ok: true,
        now: Date.now(),
        eggSeq: store._eggSeq,
        total: rows.length,
        eggs: rows.slice(0, limit),
      });
    }

    if (p === "/api/servers" && req.method === "GET") {
      const rows = store.serverRows();
      return send(res, 200, { ok: true, now: Date.now(), total: rows.length, servers: rows });
    }

    if (p === "/api/diag" && (req.method === "POST" || req.method === "GET")) {
      const body = req.method === "POST" ? await readBody(req) : {};
      const filter = applyBodyFilter(filterFromQuery(q), body);
      filter.unclaimedOnly = true;
      return send(res, 200, Object.assign({ ok: true, now: Date.now() }, store.explain(filter)));
    }

    if (p === "/api/events" && req.method === "GET") {
      const rows = store.feedEvents({
        limit: num(q.get("limit")) || 80,
        sinceSeq: num(q.get("sinceSeq")),
        kinds: parseListRaw(q.get("kinds")),
      });
      return send(res, 200, { ok: true, now: Date.now(), seq: store._seq, events: rows });
    }

    if (p === "/api/claim" && (req.method === "POST" || req.method === "GET")) {
      const body = req.method === "POST" ? await readBody(req) : {};
      const filter = applyBodyFilter(filterFromQuery(q), body);

      const client = (body.client || q.get("client") || "anon").toString().slice(0, 64);
      const waitSec = waitSecondsOf(q, body);

      let result = store.claim(filter, client);
      if (!result && waitSec > 0) {
        const deadline = Date.now() + waitSec * 1000;
        while (!result && Date.now() < deadline) {
          const changed = await waitForChange(req, deadline - Date.now());
          if (!changed) break;
          result = store.claim(filter, client);
        }
      }

      if (!result) {
        return send(res, 200, { ok: true, found: false, now: Date.now(), eggSeq: store._eggSeq });
      }
      return send(res, 200, {
        ok: true,
        found: true,
        now: Date.now(),
        eggSeq: store._eggSeq,
        target: result.target,
        eggs: result.eggs,
        expiresAt: result.expiresAt,
        latencyMs: Date.now() - result.target.firstSeen,
      });
    }

    if (p === "/api/release" && req.method === "POST") {
      const body = await readBody(req);
      const done = store.release(String(body.jobId || ""), String(body.client || "*"));
      return send(res, 200, { ok: true, released: done });
    }

    if (p === "/api/hop" && req.method === "POST") {
      const body = await readBody(req);
      return send(res, 200, store.hop(body));
    }

    if (p === "/api/meta" && req.method === "GET") {
      return send(res, 200, Object.assign({ ok: true }, store.snapshot(), {
        config: {
          serverTtlSec: SERVER_TTL_MS / 1000,
          claimTtlSec: CLAIM_TTL_MS / 1000,
          publicRead: PUBLIC_READ,
          keyRequired: !!API_KEY,
        },
      }));
    }

    if (p === "/api/stream" && req.method === "GET") return sse(req, res);

    if (p === "/api/purge" && (req.method === "POST" || req.method === "DELETE")) {
      return send(res, 200, { ok: true, removed: store.purge() });
    }

    return send(res, 404, { error: "unknown endpoint", path: p });
  } catch (err) {
    return send(res, 400, { error: String((err && err.message) || err) });
  }
});

server.keepAliveTimeout = 65000;
server.headersTimeout = 70000;

server.listen(PORT, () => {
  console.log(`[EAG HUB] listening on :${PORT}`);
  console.log(`[EAG HUB] key required: ${API_KEY ? "yes" : "NO (open instance)"}`);
  console.log(`[EAG HUB] public read: ${PUBLIC_READ}`);
});

setInterval(() => store.prune(), 30000).unref();
