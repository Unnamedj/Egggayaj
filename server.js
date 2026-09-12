"use strict";

const http = require("http");
const fs = require("fs");
const path = require("path");
const { URL } = require("url");
const { Store } = require("./lib/store");
const { Fetcher } = require("./lib/fetcher");
const { Notifier } = require("./lib/discord");

const PORT = Number(process.env.PORT) || 3000;
const API_KEY = (process.env.API_KEY || "").trim();
const PUBLIC_READ = /^(1|true|yes)$/i.test(process.env.PUBLIC_READ || "");
const SERVER_TTL_MS = Number(process.env.SERVER_TTL_SEC || 480) * 1000;
const CLAIM_TTL_MS = Number(process.env.CLAIM_TTL_SEC || 240) * 1000;
const MAX_BODY = Number(process.env.MAX_BODY_BYTES || 1024 * 1024);
// The scraper is the one part that reaches out to Roblox on its own, so it has
// an off switch: a second instance of the hub sharing one proxy account would
// double the request rate for no extra coverage.
const POOL_ENABLED = !/^(0|false|no)$/i.test(process.env.FETCHER_ENABLED || "1");

const store = new Store({ serverTtlMs: SERVER_TTL_MS, claimTtlMs: CLAIM_TTL_MS });
const pool = new Fetcher();
const discord = new Notifier();

// Rare finds and heavy ones go to Discord as they are first seen. This is the
// only place it happens, so nothing is announced twice however many reporters
// are running.
store.onFreshEggs = (eggs, srv) => {
  for (const e of eggs) discord.egg(e, srv);
};
// The scraper's warnings are worth seeing without opening the console; the
// notifier batches and de-duplicates them before they reach the channel.
pool.subscribe((row) => discord.log(row.level, row.text));

const PUBLIC_DIR = path.join(__dirname, "public");
const SCRIPTS_DIR = path.join(__dirname, "scripts");
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

// Who is calling. `username` is the header the original fetcher's clients send;
// `client` is what the AJ already used on /api/claim. Accepting both means one
// bot can talk to both halves of the hub without being counted as two.
function clientOf(req, url, body) {
  const raw =
    (body && body.client) ||
    (body && body.username) ||
    req.headers["username"] ||
    req.headers["x-eag-client"] ||
    url.searchParams.get("client") ||
    url.searchParams.get("username") ||
    "";
  return String(raw).trim().slice(0, 64);
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

// ---------------------------------------------------------------- scripts
// Serves the Lua scripts with HUB_URL and API_KEY already filled in, so the
// user pastes one loader line and configures nothing. It is also what the
// reporter re-queues on teleport, which is why there is no "raw script URL"
// field to fill any more.
//
// The key is required to fetch it, exactly like every other write path: the
// served copy carries the key in clear, so it must not be world-readable.
const SCRIPTS = {
  "reporter.lua": "ESP_v9.lua",
  "joiner.lua": "AJ_v5.lua",
};

function serveScript(req, res, name, url) {
  const file = SCRIPTS[name];
  if (!file) return send(res, 404, { error: "unknown script" });

  const abs = path.join(SCRIPTS_DIR, file);
  fs.readFile(abs, "utf8", (err, src) => {
    if (err) {
      // A bare 404 here sent us hunting in the wrong place once already: the
      // Dockerfile was not copying scripts/ at all, so the route existed but
      // the files did not. Say which it is.
      return send(res, 404, {
        error: "script not found",
        path: abs,
        scriptsDirPresent: fs.existsSync(SCRIPTS_DIR),
        hint: fs.existsSync(SCRIPTS_DIR)
          ? "the directory is there but this file is not"
          : "scripts/ is missing from the deployment — check the Dockerfile copies it",
      });
    }

    // Railway terminates TLS, so the scheme comes from the proxy header; with
    // no proxy, ask the socket rather than assuming https and handing back a
    // URL that does not resolve locally.
    const fwd = (req.headers["x-forwarded-proto"] || "").split(",")[0].trim();
    const proto = fwd || (req.socket && req.socket.encrypted ? "https" : "http");
    const host = req.headers.host || "localhost";
    const base = `${proto}://${host}`;

    // Only the two placeholders are substituted, and the key is JSON-escaped
    // so a quote in it cannot break out of the Lua string.
    const body = src
      .replace(/__SAE_HUB_URL__/g, base)
      .replace(/__SAE_API_KEY__/g, JSON.stringify(API_KEY).slice(1, -1));

    res.writeHead(200, {
      "content-type": "text/plain; charset=utf-8",
      "content-length": Buffer.byteLength(body),
      "cache-control": "no-store",
    });
    res.end(body);
  });
}

// ------------------------------------------------------------------- pool
// The scraped job-id pool. Canonical paths live under /api/pool/; the bare
// names the original fetcher used (/server, /remove, …) are kept as aliases so
// a bot written against it works here unchanged.
//
// Everything is behind the same key as the rest of the hub. Dispensing is a
// write in every sense that matters — it mutates the pool and hands out a
// scarce resource — so an open instance would be drained by whoever found it.
async function poolRoute(req, res, name, url) {
  const q = url.searchParams;
  const method = req.method;

  const maxPlaying = (() => {
    const v = num(q.get("max"));
    return v != null && v >= 0 ? v : null;
  })();

  if (name === "stats" && method === "GET") {
    return send(res, 200, Object.assign({ ok: true, now: Date.now() }, pool.stats()));
  }

  if (name === "logs" && method === "GET") {
    return send(res, 200, {
      ok: true,
      now: Date.now(),
      seq: pool.logSeq,
      logs: pool.logs({
        limit: num(q.get("limit")) || 200,
        sinceSeq: num(q.get("sinceSeq")),
        level: (q.get("level") || "").trim() || null,
      }),
    });
  }

  if (name === "servers" && method === "GET") {
    const rows = pool.rows(Math.min(num(q.get("limit")) || 300, 5000), maxPlaying);
    return send(res, 200, { ok: true, now: Date.now(), total: pool.servers.size, servers: rows });
  }

  if (name === "server" && method === "GET") {
    const client = clientOf(req, url, null);
    if (!client) return send(res, 400, { error: "a username header (or ?client=) is required" });
    const size = Math.trunc(num(q.get("size")) || 1);
    if (size < 1 || size > 1000) return send(res, 400, { error: "size must be between 1 and 1000" });

    const out = await pool.dispense(size, maxPlaying, client);
    store.touchClient(client, "pool", {
      ip: ipOf(req),
      dispenses: 1,
      jobIds: out.ok ? out.servers.length : 0,
      jobId: out.ok ? out.servers[0].jobId : null,
    });
    if (!out.ok) return send(res, 503, Object.assign({ ok: false }, out));

    // text/plain, one job id per line, is what the original answered and what
    // the Lua side parses with a single pattern match. JSON is available to
    // anything that asks for it.
    if ((q.get("format") || "").toLowerCase() === "json") {
      return send(res, 200, Object.assign({ ok: true, now: Date.now() }, out));
    }
    const body = out.servers.map((s) => s.jobId).join("\n");
    return send(res, 200, body, { "content-type": "text/plain; charset=utf-8" });
  }

  if (name === "remove" && (method === "POST" || method === "DELETE")) {
    const body = method === "POST" ? await readBody(req) : {};
    const client = clientOf(req, url, body);
    if (!client) return send(res, 400, { error: "a username header (or ?client=) is required" });
    const jobId = String(body.jobid || body.jobId || q.get("jobid") || "").trim();
    if (!jobId) return send(res, 400, { error: "jobid is required" });

    const out = await pool.replace(jobId, maxPlaying, client);
    store.touchClient(client, "pool", { ip: ipOf(req), drops: 1, jobId });
    if (!out.ok) return send(res, 503, Object.assign({ ok: false }, out));
    // new_jobid is the field name the original returned; jobId is the one the
    // rest of this hub uses. Both are sent so neither client has to change.
    return send(res, 200, Object.assign({ ok: true, new_jobid: out.jobId }, out));
  }

  if (name === "recycle" && (method === "GET" || method === "POST")) {
    const n = pool.recycle();
    return send(res, 200, {
      ok: true,
      recycled: n,
      stillDispensed: pool.dispensed.size,
      available: pool.servers.size - pool.dispensed.size,
    });
  }

  if (name === "clear") {
    // A GET that empties the pool is exactly the sort of thing a crawler or a
    // link preview fires by accident.
    if (method === "GET") return send(res, 405, { error: "use POST or DELETE to clear" });
    if (method === "POST" || method === "DELETE") {
      return send(res, 200, { ok: true, cleared: pool.clear() });
    }
  }

  if (name === "reload" && (method === "POST" || method === "GET")) {
    return send(res, 200, { ok: true, proxies: pool.loadProxies() });
  }

  return send(res, 404, { error: "unknown pool endpoint", name, method });
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
  // The scraper's log goes down the same pipe, so the dashboard's Logs tab is
  // live rather than polled.
  const offPool = pool.subscribe((row) => {
    res.write(`event: pool-log\ndata: ${JSON.stringify(row)}\n\n`);
  });
  const ping = setInterval(() => res.write(`: ping\n\n`), 20000);

  req.on("close", () => {
    clearInterval(ping);
    off();
    offPool();
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

  if (p.startsWith("/script/")) {
    if (req.method !== "GET") return send(res, 405, { error: "method" });
    if (!authed(req, url)) return send(res, 401, { error: "bad or missing key" });
    return serveScript(req, res, p.slice("/script/".length), url);
  }

  // The bare paths the standalone fetcher served. Kept so a bot written
  // against it runs here with only its host changed.
  const LEGACY_POOL = {
    "/server": "server",
    "/remove": "remove",
    "/servers": "servers",
    "/stats": "stats",
    "/recycle": "recycle",
    "/clear": "clear",
  };
  const isPool = p.startsWith("/api/pool/") || !!LEGACY_POOL[p];

  if (!p.startsWith("/api/") && !LEGACY_POOL[p]) {
    if (req.method !== "GET") return send(res, 405, { error: "method" });
    return serveStatic(req, res, p);
  }

  // Handing out a job id mutates the pool and spends a scarce resource, so it
  // needs the key even though it is a GET. PUBLIC_READ opens the egg feed to
  // anyone; it must not open the dispenser too.
  const needsWrite = req.method !== "GET" || isPool;
  const ok = authed(req, url);
  if (!ok && (needsWrite || !PUBLIC_READ)) {
    return send(res, 401, { error: "bad or missing key" });
  }

  if (LEGACY_POOL[p]) return poolRoute(req, res, LEGACY_POOL[p], url);

  try {
    if (p.startsWith("/api/pool/")) {
      return await poolRoute(req, res, p.slice("/api/pool/".length), url);
    }

    if (p === "/api/discord" && req.method === "GET") {
      return send(res, 200, Object.assign({ ok: true, now: Date.now() }, discord.stats()));
    }

    if (p === "/api/discord/test" && req.method === "POST") {
      const body = await readBody(req);
      const name = String(body.route || "logs");
      const hook = discord.route(name);
      if (!hook) return send(res, 404, { error: "no such route", route: name });
      hook.send({ username: "SAE Hub", content: "Test from the hub — this route works." });
      return send(res, 200, { ok: true, route: name, queued: true });
    }

    if (p === "/api/clients" && req.method === "GET") {
      const rows = store.clientRows();
      return send(res, 200, {
        ok: true,
        now: Date.now(),
        total: rows.length,
        online: rows.filter((r) => r.online).length,
        clients: rows,
      });
    }

    if (p === "/api/report" && req.method === "POST") {
      const body = await readBody(req);
      const out = store.report(body, { ip: ipOf(req) });
      store.touchClient(clientOf(req, url, body) || body.reporter, "reporter", {
        ip: ipOf(req),
        reports: 1,
        jobId: out.jobId,
      });
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

      store.touchClient(client, "joiner", { ip: ipOf(req) });

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
      store.touchClient(client, "joiner", { claims: 1, jobId: result.target.jobId });
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
      store.touchClient(clientOf(req, url, body), "joiner", { ip: ipOf(req), releases: done ? 1 : 0 });
      return send(res, 200, { ok: true, released: done });
    }

    if (p === "/api/hop" && req.method === "POST") {
      const body = await readBody(req);
      store.touchClient(clientOf(req, url, body), "joiner", {
        ip: ipOf(req),
        hops: 1,
        hopFails: body.ok ? 0 : 1,
        jobId: String(body.jobId || "") || null,
      });
      return send(res, 200, store.hop(body));
    }

    if (p === "/api/meta" && req.method === "GET") {
      return send(res, 200, Object.assign({ ok: true }, store.snapshot(), {
        config: {
          serverTtlSec: SERVER_TTL_MS / 1000,
          claimTtlSec: CLAIM_TTL_MS / 1000,
          publicRead: PUBLIC_READ,
          keyRequired: !!API_KEY,
          gameId: pool.gameId,
          poolEnabled: POOL_ENABLED,
        },
        pool: pool.stats(),
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
  // Surfaced at boot so a deployment missing scripts/ is obvious in the logs
  // rather than only showing up as a 404 from inside the game.
  const names = Object.keys(SCRIPTS).filter((n) =>
    fs.existsSync(path.join(SCRIPTS_DIR, SCRIPTS[n])));
  console.log(`[EAG HUB] scripts served: ${names.length ? names.join(", ") : "NONE — scripts/ missing from the image"}`);

  if (POOL_ENABLED) pool.start();
  else console.log("[EAG HUB] job-id pool disabled (FETCHER_ENABLED=0)");

  const d = discord.stats();
  if (d.enabled) {
    console.log(`[EAG HUB] discord: ${d.routes.join(", ")} · alert over ${d.insaneKg} kg`);
  } else if (!d.source.fileFound) {
    // This exact hole shipped once: the file was in git but not in the image,
    // so the relay was dead and nothing said why.
    console.log(`[EAG HUB] discord: OFF — ${d.source.path} ${d.source.fileError}.` +
      " If it exists in the repo, the Dockerfile is not copying it.");
  } else {
    console.log("[EAG HUB] discord: OFF — webhooks.json was read but holds no valid webhook URL");
  }
  discord.start(() => Object.assign(store.snapshot(), { pool: pool.stats() }));
});

setInterval(() => store.prune(), 30000).unref();
