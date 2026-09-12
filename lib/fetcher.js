"use strict";

/*
  JOB ID FETCHER — scrapes Roblox's public server list through rotating proxies
  and keeps the job ids it finds in an in-memory pool.

  Why this exists at all. Roblox rate-limits the server list per IP. Forty bots
  each asking Roblox directly get every one of them throttled. So one process
  scrapes — spreading the load over a pool of proxies, so Roblox sees many IPs
  rather than one — and the bots ask THIS process for a job id that is already
  cached. They hit our own host, which has no rate limit worth speaking of.

  The port. The original ran on express + axios + https-proxy-agent. This hub
  ships with no dependencies and its Dockerfile never runs an install, so adding
  three would have broken the deploy the moment it was pushed. Everything below
  is the same logic on node built-ins: a CONNECT-tunnelling https.Agent in place
  of https-proxy-agent, https.request in place of axios, and the hub's own
  router in place of express.

  The ideas worth keeping in mind:

  · THE POOL IS RAM, NOT A DATABASE. `servers` is jobId -> {playing, maxPlayers,
    lastSeen}. A restart starts empty and refills in seconds. The information is
    only true for minutes, so persisting it would buy nothing and complicate the
    deploy.

  · DISPENSING IS NOT DELETING. A job id handed to a bot goes into `dispensed`
    with a timestamp but stays in the pool. After RECYCLE_MS the bot has either
    used it or given up, so it becomes available again. That is what stops two
    bots getting the same server without constant re-scraping.

  · ONE PROXY PER REQUEST. getNextProxy() walks a shuffled copy of the list
    round-robin. With sticky proxies each line is a distinct exit IP, so more
    lines means more real parallelism rather than the same IP going faster.

  · TWO CONCURRENCY LIMITS, TWO DIFFERENT PROBLEMS. AGENT_MAX_SOCKETS caps
    connections through ONE proxy, so a single saturated gateway stops dropping
    sockets. MAX_CONCURRENT_REQUESTS caps requests in flight across the whole
    process, which is what actually protects the proxy account: each sticky
    session is a connection the provider has to open, and exceeding the plan's
    concurrent-session limit arrives as a wave of 502s and TLS resets. More
    proxies do not fix that; a queue does.

  · ADAPTIVE BACKOFF, NOT A FIXED DELAY. `delay` starts at 100ms and climbs to
    10s on a 429, a network error or a 5xx, then eases back down while things go
    well. A healthy account settles at the floor and scrapes fast; an exhausted
    one backs off on its own instead of retrying flat out.

  · A REQUEST TIMEOUT IS NOT ENOUGH. A response timeout only starts counting
    once the connection is up. A dead HTTPS proxy hangs during the CONNECT
    handshake, where that timer never starts, and the request sits there forever
    holding a concurrency slot. So there are two guards: one on the CONNECT
    itself and a hard abort that destroys the request whatever phase it is
    stuck in.

  · PAGINATION STOPS EARLY. Each cycle walks up to MAX_PAGES pages of 100. If a
    whole page brings nothing new, the cycle ends there — paging further spends
    proxy traffic re-reading what we already hold.
*/

const http = require("http");
const https = require("https");
const tls = require("tls");
const fs = require("fs");

const envNum = (name, fallback) => {
  const n = parseInt(process.env[name], 10);
  return Number.isFinite(n) && n > 0 ? n : fallback;
};

// ---------------------------------------------------------------- proxy input
// Accepted shapes, all of which some provider emits:
//   user:pass@host:port           (the usual one)
//   host:port:user:pass
//   user:pass:host:port
//   protocol://user:pass@host:port
//   host:port                     (no credentials)

// Some rotating providers bury a session id in the username, e.g.
// "user_session-abc123_lifetime-10". Nettify's normal format has none, but
// stripping it is harmless when it does show up.
function stripSessionParams(auth) {
  if (!auth) return auth;
  return auth
    .replace(/_session-[^_]+/g, "")
    .replace(/_lifetime-[^_]+/g, "")
    .replace(/_+$/, "");
}

function parseProxy(raw) {
  if (!raw) return null;
  const s = String(raw).trim();
  if (!s) return null;

  const done = (host, port, username, password) => {
    const p = parseInt(port, 10);
    if (!host || !Number.isFinite(p) || p <= 0 || p > 65535) return null;
    return {
      host,
      port: p,
      username: stripSessionParams(username) || null,
      password: stripSessionParams(password) || null,
    };
  };

  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(s)) {
    try {
      const u = new URL(s);
      return done(
        u.hostname,
        u.port || "80",
        u.username ? decodeURIComponent(u.username) : null,
        u.password ? decodeURIComponent(u.password) : null
      );
    } catch (_) {
      return null;
    }
  }

  if (s.includes("@")) {
    const at = s.lastIndexOf("@");
    const left = s.slice(0, at);
    const right = s.slice(at + 1);
    const [host, port] = right.split(":");
    const colon = left.indexOf(":");
    if (colon === -1) return null;
    return done(host, port, left.slice(0, colon), left.slice(colon + 1));
  }

  const parts = s.split(":");
  if (parts.length === 4) {
    // Tell the two orderings apart by whether the second field looks like a
    // port. A password of "8080" would fool this, but so would any heuristic,
    // and host:port:user:pass is overwhelmingly the common case.
    const secondIsPort = !isNaN(parseInt(parts[1], 10)) && parts[1].length < 6;
    return secondIsPort
      ? done(parts[0], parts[1], parts[2], parts[3])
      : done(parts[2], parts[3], parts[0], parts[1]);
  }
  if (parts.length === 2) return done(parts[0], parts[1], null, null);
  return null;
}

// ------------------------------------------------------------- proxy tunnel
// https.Agent that reaches the target through an HTTP proxy's CONNECT verb.
// Subclassing the agent rather than dialling by hand keeps node's own keep-alive
// and maxSockets pooling, which is the whole point of AGENT_MAX_SOCKETS.
class ProxyAgent extends https.Agent {
  constructor(proxy, opts) {
    super(Object.assign({ keepAlive: true, timeout: 30000 }, opts));
    this.proxy = proxy;
    this.connectTimeout = (opts && opts.connectTimeout) || 12000;
  }

  createConnection(options, cb) {
    const target = `${options.host}:${options.port || 443}`;
    const headers = { host: target, connection: "keep-alive" };
    if (this.proxy.username || this.proxy.password) {
      const raw = `${this.proxy.username || ""}:${this.proxy.password || ""}`;
      headers["proxy-authorization"] = "Basic " + Buffer.from(raw).toString("base64");
    }

    const req = http.request({
      host: this.proxy.host,
      port: this.proxy.port,
      method: "CONNECT",
      path: target,
      headers,
      agent: false,
      timeout: this.connectTimeout,
    });

    let settled = false;
    const fail = (err) => {
      if (settled) return;
      settled = true;
      req.destroy();
      cb(err);
    };

    req.once("connect", (res, socket) => {
      if (res.statusCode !== 200) {
        socket.destroy();
        return fail(new Error(`proxy CONNECT returned ${res.statusCode}`));
      }
      socket.setTimeout(0);
      const secure = tls.connect(
        {
          socket,
          servername: options.host,
          ALPNProtocols: ["http/1.1"],
        },
        () => {
          if (settled) return secure.destroy();
          settled = true;
          cb(null, secure);
        }
      );
      // Before the handshake completes this is the only place an error can
      // surface; afterwards the agent owns the socket and handles its own.
      secure.once("error", (err) => {
        if (!settled) fail(err);
      });
    });

    req.once("timeout", () => fail(new Error("proxy CONNECT timed out")));
    req.once("error", fail);
    req.end();
  }
}

// ------------------------------------------------------------------- fetcher
class Fetcher {
  constructor(opts) {
    opts = opts || {};

    // The game whose public servers get scraped.
    this.gameId = String(opts.gameId || process.env.GAME_ID || "107778070777162");

    // A dispensed job id frees up again after this long.
    this.RECYCLE_MS = envNum("RECYCLE_SEC", 90) * 1000;
    // Roblox never says a server has closed, it just stops listing it. Without
    // a periodic cull, servers that died hours ago would sit in the pool for
    // ever, so most of it is dropped on a timer and re-learned.
    this.WIPE_MS = envNum("CACHE_WIPE_SEC", 2 * 60 * 60) * 1000;
    this.WIPE_FRACTION = 0.8;
    // Safety valve: a pool this large for this long means something is wrong,
    // so throw it away rather than let it grow unbounded.
    this.THRESHOLD = envNum("POOL_THRESHOLD", 50000);
    this.THRESHOLD_MS = envNum("POOL_THRESHOLD_SEC", 50 * 60) * 1000;

    this.WORKERS = envNum("SCRAPER_WORKERS", 10);
    this.AGENT_MAX_SOCKETS = envNum("AGENT_MAX_SOCKETS", 4);
    this.MAX_CONCURRENT = envNum("MAX_CONCURRENT_REQUESTS", 5);
    this.MAX_PAGES = envNum("SCRAPER_MAX_PAGES", 10);
    this.BASE_COOLDOWN = envNum("SCRAPER_COOLDOWN_MS", 2000);
    this.IDLE_COOLDOWN = envNum("SCRAPER_IDLE_COOLDOWN_MS", 10000);

    this.MIN_DELAY = 100;
    this.MAX_DELAY = 10000;
    this.delay = this.MIN_DELAY;

    this.proxyFile = process.env.PROXY_FILE || "proxies.txt";

    // jobId -> { playing, maxPlayers, lastSeen }
    this.servers = new Map();
    // jobId -> when it was handed out. Still in `servers` the whole time.
    this.dispensed = new Map();
    // Seen but never handed out. Preferred after "emptiest", so the same old
    // servers are not dispensed over and over.
    this.fresh = new Set();
    // Reported dead or full by a client. Statistics only: if Roblox lists one
    // again it may genuinely have emptied, so it is not blocked from returning.
    this.removed = new Set();

    this.proxies = [];
    this.order = [];
    this.orderIndex = 0;
    this.lastProxy = null;
    this.agents = new Map();

    this.active = 0;
    this.queue = [];

    this.counters = {
      startedAt: Date.now(),
      requests: 0,
      ok: 0,
      failed: 0,
      rateLimits: 0,
      proxyErrors: 0,
      pages: 0,
      discovered: 0,
      dispensed: 0,
      removed: 0,
      recycled: 0,
      wipes: 0,
    };

    this.lastWipe = Date.now();
    this.overThresholdSince = null;
    this.started = false;
    this.timers = [];
    this.workerState = [];

    // Ring buffer behind the dashboard's Logs tab. The original only had
    // console.log, which is invisible from a browser.
    this.log = [];
    this.logSeq = 0;
    this.maxLog = envNum("FETCHER_LOG_LINES", 400);
    this.listeners = new Set();

    // One dispense at a time, so two concurrent callers cannot be handed the
    // same job id between the read and the mark.
    this.dispensing = Promise.resolve();
  }

  // ------------------------------------------------------------------ events
  subscribe(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  say(level, text) {
    const row = { seq: ++this.logSeq, at: Date.now(), level, text };
    this.log.unshift(row);
    if (this.log.length > this.maxLog) this.log.length = this.maxLog;
    const tag = level === "error" ? "ERR" : level === "warn" ? "WRN" : "···";
    console.log(`[POOL ${tag}] ${text}`);
    for (const fn of this.listeners) {
      try {
        fn(row);
      } catch (_) {}
    }
    return row;
  }

  logs(opts) {
    opts = opts || {};
    let rows = this.log;
    if (opts.sinceSeq != null) rows = rows.filter((r) => r.seq > opts.sinceSeq);
    if (opts.level) rows = rows.filter((r) => r.level === opts.level);
    return rows.slice(0, Math.min(opts.limit || 200, this.maxLog));
  }

  // ----------------------------------------------------------------- proxies
  // PROXIES wins over the file: on Railway the filesystem is rebuilt from git on
  // every deploy, so real credentials must not live in a committed proxies.txt.
  loadProxies() {
    let raw = [];
    let from = "";

    if (process.env.PROXIES && process.env.PROXIES.trim()) {
      raw = process.env.PROXIES.split(/[\n,]/);
      from = "the PROXIES env var";
    } else {
      try {
        raw = fs.readFileSync(this.proxyFile, "utf8").split("\n");
        from = this.proxyFile;
      } catch (_) {
        this.proxies = [];
        this.resetOrder();
        return 0;
      }
    }

    const lines = raw.map((l) => l.trim()).filter((l) => l && !l.startsWith("#"));
    const unique = [...new Set(lines)];
    // A line that cannot be parsed is dropped here rather than failing later on
    // every single request that happens to draw it.
    const good = unique.filter((p) => parseProxy(p));
    const bad = unique.length - good.length;

    this.proxies = good;
    this.resetOrder();
    this.say(
      "info",
      `loaded ${good.length} proxies from ${from}` +
        (lines.length !== unique.length ? ` (${lines.length - unique.length} duplicates dropped)` : "") +
        (bad ? ` (${bad} unparseable dropped)` : "")
    );
    return good.length;
  }

  // Reshuffles the consumption order, avoiding a first entry equal to the proxy
  // just used — otherwise a new round can reuse the same exit IP back to back.
  resetOrder() {
    this.order = this.proxies.slice();
    this.orderIndex = 0;
    if (this.order.length < 2) return;
    for (let i = this.order.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [this.order[i], this.order[j]] = [this.order[j], this.order[i]];
    }
    if (this.lastProxy && this.order[0] === this.lastProxy) {
      for (let i = 1; i < this.order.length; i++) {
        if (this.order[i] !== this.lastProxy) {
          [this.order[0], this.order[i]] = [this.order[i], this.order[0]];
          break;
        }
      }
    }
  }

  nextProxy() {
    if (!this.order.length) return null;
    const p = this.order[this.orderIndex];
    this.orderIndex = (this.orderIndex + 1) % this.order.length;
    this.lastProxy = p;
    return p;
  }

  agentFor(proxyString) {
    let agent = this.agents.get(proxyString);
    if (!agent) {
      agent = new ProxyAgent(parseProxy(proxyString), {
        maxSockets: this.AGENT_MAX_SOCKETS,
      });
      this.agents.set(proxyString, agent);
    }
    return agent;
  }

  // ------------------------------------------------------------- concurrency
  acquire() {
    if (this.active < this.MAX_CONCURRENT) {
      this.active++;
      return Promise.resolve();
    }
    return new Promise((resolve) => this.queue.push(resolve));
  }

  release() {
    const next = this.queue.shift();
    // Hand the slot straight over when someone is waiting: the count is
    // unchanged because the slot never actually went idle.
    if (next) next();
    else this.active = Math.max(0, this.active - 1);
  }

  // -------------------------------------------------------------- the request
  // Resolves to the parsed body, or null on any failure. Failures are folded
  // into the adaptive delay rather than thrown: a worker's next move is the
  // same either way.
  fetch(url, proxyString) {
    return this.acquire().then(
      () =>
        new Promise((resolve) => {
          const started = Date.now();
          const budget = proxyString ? 15000 : 8000;
          let settled = false;

          const finish = (value) => {
            if (settled) return;
            settled = true;
            clearTimeout(hardStop);
            this.release();
            resolve(value);
          };

          const fail = (kind, detail, status) => {
            this.counters.failed++;
            if (status === 429) {
              this.counters.rateLimits++;
              this.delay = Math.min(this.MAX_DELAY, this.delay + 100);
              this.say("warn", `429 from Roblox · delay now ${this.delay}ms`);
            } else if (kind === "network" || kind === "overload") {
              // Usually the proxy account is over its concurrent-session limit.
              // Punished harder than a plain 429 to give it room.
              this.counters.proxyErrors++;
              this.delay = Math.min(this.MAX_DELAY, this.delay + 250);
              this.say(
                "error",
                `${proxyString ? shortProxy(proxyString) : "direct"}: ${detail} · delay now ${this.delay}ms`
              );
            } else {
              this.say("error", `fetch failed (${proxyString ? shortProxy(proxyString) : "direct"}): ${detail}`);
            }
            finish(null);
          };

          let req;
          try {
            const opts = { timeout: budget, headers: { "user-agent": UA, accept: "application/json" } };
            if (proxyString) opts.agent = this.agentFor(proxyString);
            req = https.request(url, opts, (res) => {
              const status = res.statusCode || 0;
              const chunks = [];
              let size = 0;
              res.on("data", (c) => {
                size += c.length;
                // A server list page is ~30KB. Anything this big is not one.
                if (size > 4 * 1024 * 1024) {
                  req.destroy(new Error("response too large"));
                  return;
                }
                chunks.push(c);
              });
              res.on("end", () => {
                if (status === 429) return fail("status", "rate limited", 429);
                if (status >= 500) return fail("overload", `HTTP ${status}`, status);
                if (status < 200 || status >= 300) return fail("status", `HTTP ${status}`, status);
                let body;
                try {
                  body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
                } catch (_) {
                  return fail("status", "unparseable body");
                }
                this.counters.ok++;
                this.lastLatencyMs = Date.now() - started;
                // Success eases the delay back toward the floor, slowly enough
                // that one lucky response does not undo a real backoff.
                if (this.delay > this.MIN_DELAY) {
                  this.delay = Math.max(this.MIN_DELAY, this.delay - 10);
                }
                finish(body);
              });
              res.on("error", (err) => fail("network", err.message));
            });
          } catch (err) {
            return fail("network", err.message);
          }

          this.counters.requests++;
          // The belt to the timeout's braces: destroy() ends the request in any
          // phase, including while it is still queued behind the agent waiting
          // for a socket, where no response timer is running yet.
          const hardStop = setTimeout(() => {
            req.destroy(new Error(`aborted after ${budget}ms`));
          }, budget + 1000);

          req.on("timeout", () => req.destroy(new Error("response timed out")));
          req.on("error", (err) => fail("network", err.message));
          req.end();
        })
    );
  }

  // ------------------------------------------------------------ pool updates
  // Roblox answers { data: [{ id, playing, maxPlayers, ... }], nextPageCursor }.
  // Returns the ids that were not already known.
  absorb(body) {
    if (!body || !Array.isArray(body.data)) return [];
    const now = Date.now();
    const added = [];
    for (const s of body.data) {
      if (!s || !s.id) continue;
      const info = {
        playing: Number(s.playing) || 0,
        maxPlayers: Number(s.maxPlayers) || 0,
        lastSeen: now,
      };
      // Re-seeing a server is how its population stays current. A job id that
      // was empty ten minutes ago is worthless if we still believe that.
      if (!this.servers.has(s.id)) {
        this.fresh.add(s.id);
        added.push(s.id);
        this.counters.discovered++;
      }
      this.servers.set(s.id, info);
    }
    return added;
  }

  // Candidates worth handing out. Dispensed ones are held back until they
  // recycle; so are servers already full, or fuller than the caller asked for.
  // Order: emptiest, then never-dispensed, then most recently confirmed.
  available(maxPlaying) {
    const out = [];
    for (const [id, info] of this.servers) {
      if (this.dispensed.has(id)) continue;
      if (info.maxPlayers > 0 && info.playing >= info.maxPlayers) continue;
      if (maxPlaying != null && info.playing > maxPlaying) continue;
      out.push({
        id,
        playing: info.playing,
        maxPlayers: info.maxPlayers,
        fresh: this.fresh.has(id),
        lastSeen: info.lastSeen,
      });
    }
    out.sort(
      (a, b) =>
        a.playing - b.playing ||
        (b.fresh === a.fresh ? 0 : b.fresh ? 1 : -1) ||
        b.lastSeen - a.lastSeen
    );
    return out;
  }

  // --------------------------------------------------------------- endpoints
  // Four variants of the same call. Always asking for one gives very repetitive
  // results, so each cycle picks at random and covers more of the listing.
  endpoints() {
    const base = `https://games.roblox.com/v1/games/${this.gameId}/servers/Public?limit=100`;
    return [
      `${base}&excludeFullGames=true&sortOrder=Asc`,
      `${base}&sortOrder=Asc`,
      `${base}&excludeFullGames=true&sortOrder=Desc`,
      `${base}&sortOrder=Desc`,
    ];
  }

  // ----------------------------------------------------------------- workers
  async worker(id) {
    const eps = this.endpoints();
    const me = { id, state: "idle", cycles: 0, found: 0, at: Date.now() };
    this.workerState[id] = me;

    while (this.started) {
      const endpoint = eps[Math.floor(Math.random() * eps.length)];
      let cursor = null;
      let totalNew = 0;
      let pages = 0;

      me.state = "scraping";
      me.at = Date.now();

      while (pages < this.MAX_PAGES && this.started) {
        const url = cursor ? `${endpoint}&cursor=${encodeURIComponent(cursor)}` : endpoint;
        await sleep(this.delay);

        const body = await this.fetch(url, this.nextProxy());
        if (!body) {
          // Already backed off inside fetch(); wait out a bit more if we are in
          // the middle of a run of 429s before the next cycle starts.
          if (this.counters.rateLimits > 0) await sleep(this.delay * 2);
          break;
        }

        const added = this.absorb(body);
        totalNew += added.length;
        pages++;
        this.counters.pages++;

        // A whole page with nothing new means we are re-reading what we hold.
        // Paging on would spend proxy traffic for no information.
        if (added.length === 0 && pages > 1) break;
        if (!body.nextPageCursor) break;
        cursor = body.nextPageCursor;
      }

      me.cycles++;
      me.found += totalNew;
      me.at = Date.now();

      if (totalNew > 0) {
        this.say("info", `worker ${id}: +${totalNew} new across ${pages} page(s) · pool ${this.servers.size}`);
        me.state = "cooldown";
        await sleep(this.BASE_COOLDOWN);
      } else {
        // Nothing new: the pool is warm, so back off further rather than burn
        // proxy traffic confirming what we already know.
        me.state = "idle";
        await sleep(this.IDLE_COOLDOWN);
      }
    }
    me.state = "stopped";
  }

  start() {
    if (this.started) return;
    this.started = true;

    this.loadProxies();

    let workers = this.WORKERS;
    if (!this.proxies.length) {
      // Ten workers on one IP is the fastest possible way to get that IP
      // throttled. Still scrape — a hub with no proxies configured should do
      // something useful — but slowly, and say why.
      workers = Math.min(workers, 2);
      this.say(
        "warn",
        `no proxies configured — scraping direct from this host's IP with ${workers} worker(s). ` +
          "Set PROXIES or proxies.txt to scrape properly."
      );
    }

    this.say("info", `tracking game ${this.gameId} with ${workers} worker(s)`);
    for (let i = 0; i < workers; i++) {
      // Staggered so they do not all fire their first request at once.
      setTimeout(() => this.worker(i), i * 500).unref();
    }

    // Free dispensed job ids whose recycle window has passed.
    this.timers.push(
      setInterval(() => {
        const n = this.recycle();
        if (n > 0) {
          this.say("info", `recycled ${n} · ${this.servers.size - this.dispensed.size} available`);
        }
      }, 30000).unref()
    );

    this.timers.push(setInterval(() => this.periodicWipe(), this.WIPE_MS).unref());
    this.timers.push(setInterval(() => this.thresholdWipe(), 60000).unref());
  }

  stop() {
    this.started = false;
    for (const t of this.timers) clearInterval(t);
    this.timers = [];
  }

  // ------------------------------------------------------------ maintenance
  recycle() {
    const now = Date.now();
    let n = 0;
    for (const [jobId, at] of this.dispensed) {
      if (now - at >= this.RECYCLE_MS) {
        this.dispensed.delete(jobId);
        n++;
      }
    }
    this.counters.recycled += n;
    return n;
  }

  periodicWipe() {
    const before = this.servers.size;
    if (!before) return;
    const ids = [...this.servers.keys()];
    for (let i = ids.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [ids[i], ids[j]] = [ids[j], ids[i]];
    }
    const keep = ids.slice(0, Math.floor(ids.length * (1 - this.WIPE_FRACTION)));
    const kept = new Map();
    for (const id of keep) kept.set(id, this.servers.get(id));

    this.servers = kept;
    this.dispensed.clear();
    this.fresh = new Set(kept.keys());
    this.lastWipe = Date.now();
    this.counters.wipes++;
    this.say("info", `periodic wipe · ${before} -> ${this.servers.size}`);
  }

  thresholdWipe() {
    const total = this.servers.size;
    if (total > this.THRESHOLD) {
      if (!this.overThresholdSince) {
        this.overThresholdSince = Date.now();
        this.say("warn", `pool at ${total}, over ${this.THRESHOLD} — watching for ${this.THRESHOLD_MS / 60000}min`);
      } else if (Date.now() - this.overThresholdSince >= this.THRESHOLD_MS) {
        this.say("warn", `pool held over ${this.THRESHOLD} too long — clearing everything`);
        this.clear();
        this.overThresholdSince = null;
      }
    } else {
      if (this.overThresholdSince) this.say("info", `pool back under ${this.THRESHOLD}`);
      this.overThresholdSince = null;
    }
  }

  clear() {
    const n = this.servers.size;
    this.servers.clear();
    this.dispensed.clear();
    this.fresh.clear();
    this.removed.clear();
    this.lastWipe = Date.now();
    this.counters.wipes++;
    this.say("warn", `pool cleared (${n} servers)`);
    return n;
  }

  // ----------------------------------------------------------------- serving
  // Serialised against itself so two callers arriving together cannot both be
  // handed the same job id.
  lock(fn) {
    const run = this.dispensing.then(fn, fn);
    this.dispensing = run.then(
      () => {},
      () => {}
    );
    return run;
  }

  // Hands out `size` job ids, emptiest first. If `maxPlaying` leaves too few
  // candidates the filter is relaxed rather than failing: a server slightly
  // fuller than asked for beats no server at all.
  dispense(size, maxPlaying, client) {
    return this.lock(() => {
      let candidates = this.available(maxPlaying);
      let relaxed = false;
      if (candidates.length < size && maxPlaying != null) {
        candidates = this.available(null);
        relaxed = true;
      }
      if (!candidates.length) {
        return { ok: false, error: "pool empty", have: 0, requested: size };
      }

      const picked = candidates.slice(0, size);
      const now = Date.now();
      for (const c of picked) {
        this.dispensed.set(c.id, now);
        this.fresh.delete(c.id);
      }
      this.counters.dispensed += picked.length;
      this.say(
        "info",
        `dispensed ${picked.length} to ${client || "anon"}${relaxed ? " (max relaxed)" : ""}`
      );
      return {
        ok: true,
        relaxed,
        short: picked.length < size,
        servers: picked.map((c) => ({ jobId: c.id, playing: c.playing, maxPlayers: c.maxPlayers, fresh: c.fresh })),
      };
    });
  }

  // What a bot calls when a teleport fails: drop the dead job id and get a
  // replacement in the same round trip, rather than two calls.
  replace(jobId, maxPlaying, client) {
    return this.lock(() => {
      const known = this.servers.has(jobId);
      this.servers.delete(jobId);
      this.dispensed.delete(jobId);
      this.fresh.delete(jobId);
      this.removed.add(jobId);
      this.counters.removed++;

      let candidates = this.available(maxPlaying);
      if (!candidates.length && maxPlaying != null) candidates = this.available(null);
      if (!candidates.length) {
        return { ok: false, error: "pool empty", dropped: known };
      }

      const pick = candidates[0];
      this.dispensed.set(pick.id, Date.now());
      this.fresh.delete(pick.id);
      this.counters.dispensed++;
      this.say("info", `${client || "anon"} dropped ${jobId.slice(0, 8)} -> ${pick.id.slice(0, 8)} (${pick.playing}p)`);
      return {
        ok: true,
        dropped: known,
        jobId: pick.id,
        playing: pick.playing,
        maxPlayers: pick.maxPlayers,
        fresh: pick.fresh,
      };
    });
  }

  rows(limit, maxPlaying) {
    const now = Date.now();
    const out = [];
    for (const [id, info] of this.servers) {
      const at = this.dispensed.get(id);
      if (maxPlaying != null && info.playing > maxPlaying) continue;
      out.push({
        jobId: id,
        playing: info.playing,
        maxPlayers: info.maxPlayers,
        fresh: this.fresh.has(id),
        dispensed: at != null,
        recyclesInMs: at != null ? Math.max(0, this.RECYCLE_MS - (now - at)) : null,
        full: info.maxPlayers > 0 && info.playing >= info.maxPlayers,
        ageMs: now - info.lastSeen,
      });
    }
    out.sort(
      (a, b) =>
        Number(a.dispensed) - Number(b.dispensed) ||
        a.playing - b.playing ||
        a.ageMs - b.ageMs
    );
    return limit ? out.slice(0, limit) : out;
  }

  stats() {
    const now = Date.now();
    let recycling = 0;
    for (const at of this.dispensed.values()) {
      if (now - at < this.RECYCLE_MS) recycling++;
    }
    const available = this.servers.size - this.dispensed.size;

    // Population histogram, so the dashboard can show at a glance whether the
    // pool is full of quiet servers or only busy ones.
    const buckets = { empty: 0, quiet: 0, busy: 0, full: 0 };
    for (const info of this.servers.values()) {
      if (info.maxPlayers > 0 && info.playing >= info.maxPlayers) buckets.full++;
      else if (info.playing === 0) buckets.empty++;
      else if (info.playing <= 3) buckets.quiet++;
      else buckets.busy++;
    }

    return {
      gameId: this.gameId,
      running: this.started,
      pool: {
        total: this.servers.size,
        available: Math.max(0, available),
        fresh: this.fresh.size,
        ready: Math.max(0, available - this.fresh.size),
        dispensed: this.dispensed.size,
        recycling,
        removed: this.removed.size,
        quiet: this.available(3).length,
        buckets,
      },
      scraper: {
        proxies: this.proxies.length,
        workers: this.workerState.filter(Boolean).length,
        workerStates: this.workerState.filter(Boolean).map((w) => ({
          id: w.id,
          state: w.state,
          cycles: w.cycles,
          found: w.found,
          idleMs: now - w.at,
        })),
        delayMs: this.delay,
        minDelayMs: this.MIN_DELAY,
        maxDelayMs: this.MAX_DELAY,
        activeRequests: this.active,
        queuedRequests: this.queue.length,
        maxConcurrent: this.MAX_CONCURRENT,
        agentMaxSockets: this.AGENT_MAX_SOCKETS,
        lastLatencyMs: this.lastLatencyMs || null,
      },
      counters: this.counters,
      recycleMs: this.RECYCLE_MS,
      lastWipeAgeMs: now - this.lastWipe,
      uptimeMs: now - this.counters.startedAt,
    };
  }
}

const UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36";

const sleep = (ms) => new Promise((r) => setTimeout(r, Math.max(0, ms)));

// Never log proxy credentials — these lines end up on a dashboard.
function shortProxy(s) {
  const p = parseProxy(s);
  return p ? `${p.host}:${p.port}` : "proxy";
}

module.exports = { Fetcher, parseProxy, ProxyAgent };
