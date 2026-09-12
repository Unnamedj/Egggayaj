"use strict";

/*
  Discord relay.

  The hub is the right place for this, not the reporter. It already sees every
  report, it already knows which eggs are NEW (so nothing is announced twice no
  matter how many reporters find it), and it holds the rarity ladder. Doing it
  in Lua would mean one webhook burst per client.

  What Discord actually enforces, and what this has to respect:

  · RATE LIMITS ARE PER WEBHOOK. Roughly 5 requests a second and 30 a minute.
    A reporter finishing a scan can hand over a dozen new eggs at once, so
    every route owns a FIFO queue and drains it no faster than MIN_GAP. A 429
    is not a failure to retry blindly: Discord says how long to wait in
    `retry_after`, and that is obeyed.

  · LOGS WOULD DROWN THE CHANNEL. The scraper emits a line per worker cycle and
    one per 429 — hundreds a minute when Roblox is pushing back. So log lines
    are batched into one message on a timer, identical lines are collapsed into
    "xN", and only warnings and errors go through by default. Info is noise at
    this distance; the health of the scrape is answered instead by a periodic
    summary.

  · A DEAD WEBHOOK MUST NOT TAKE THE HUB WITH IT. Nothing here throws into the
    request path: a send that keeps failing is dropped after a few attempts and
    the queue moves on.
*/

const https = require("https");
const fs = require("fs");
const path = require("path");
const { URL } = require("url");
const { rarityColor, rarityRank } = require("./rarity");

// Discord's own caps, applied defensively so a long field cannot get a whole
// message rejected.
const LIM = { content: 2000, title: 256, desc: 4096, field: 1024, footer: 2048 };

const clip = (s, n) => {
  const t = String(s == null ? "" : s);
  return t.length <= n ? t : t.slice(0, n - 1) + "…";
};

const intColor = (hexish) => {
  const h = String(hexish || "").replace("#", "");
  const n = parseInt(h, 16);
  return Number.isFinite(n) ? n : 0x6b7280;
};

// ------------------------------------------------------------------- one hook
class Hook {
  constructor(url, name, opts) {
    opts = opts || {};
    this.url = url;
    this.name = name;
    this.minGap = opts.minGap || 1100;   // ms between sends on this webhook
    this.maxQueue = opts.maxQueue || 200;
    this.maxTries = opts.maxTries || 3;

    this.queue = [];
    this.draining = false;
    this.blockedUntil = 0;
    this.stats = { sent: 0, dropped: 0, rateLimited: 0, failed: 0 };
  }

  send(payload) {
    if (!this.url) return false;
    if (this.queue.length >= this.maxQueue) {
      // Better to lose the oldest than to grow without bound while Discord is
      // refusing us.
      this.queue.shift();
      this.stats.dropped++;
    }
    this.queue.push({ payload, tries: 0 });
    this.drain();
    return true;
  }

  drain() {
    if (this.draining) return;
    this.draining = true;
    this._loop().catch(() => {}).then(() => { this.draining = false; });
  }

  async _loop() {
    while (this.queue.length) {
      const wait = this.blockedUntil - Date.now();
      if (wait > 0) await sleep(wait);

      const job = this.queue[0];
      let res;
      try {
        res = await this._post(job.payload);
      } catch (err) {
        res = { status: 0, error: err.message };
      }

      if (res.status === 429) {
        this.stats.rateLimited++;
        // retry_after is seconds (may be fractional). Header is a fallback.
        const after = Number(res.retryAfter) || 1;
        this.blockedUntil = Date.now() + Math.min(60000, after * 1000 + 250);
        continue;                      // same job, after the wait
      }

      this.queue.shift();

      if (res.status >= 200 && res.status < 300) {
        this.stats.sent++;
      } else {
        job.tries++;
        if (job.tries < this.maxTries && (res.status === 0 || res.status >= 500)) {
          this.queue.unshift(job);     // transient: put it back
          await sleep(1000 * job.tries);
        } else {
          this.stats.failed++;
        }
      }

      await sleep(this.minGap);
    }
  }

  _post(payload) {
    return new Promise((resolve, reject) => {
      let u;
      try {
        u = new URL(this.url);
      } catch (_) {
        return reject(new Error("bad webhook url"));
      }
      const body = Buffer.from(JSON.stringify(payload), "utf8");
      const req = https.request(
        {
          hostname: u.hostname,
          path: u.pathname + u.search,
          method: "POST",
          timeout: 10000,
          headers: {
            "content-type": "application/json",
            "content-length": body.length,
            "user-agent": "SAE-Hub (+https://github.com/Unnamedj/Egggayaj)",
          },
        },
        (res) => {
          const chunks = [];
          res.on("data", (c) => chunks.push(c));
          res.on("end", () => {
            let retryAfter = res.headers["retry-after"];
            if (res.statusCode === 429) {
              try {
                const j = JSON.parse(Buffer.concat(chunks).toString("utf8"));
                if (j && j.retry_after != null) retryAfter = j.retry_after;
              } catch (_) {}
            }
            resolve({ status: res.statusCode || 0, retryAfter });
          });
          res.on("error", reject);
        }
      );
      req.on("timeout", () => req.destroy(new Error("timeout")));
      req.on("error", reject);
      req.end(body);
    });
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, Math.max(0, ms)));

// ------------------------------------------------------------------ notifier
class Notifier {
  constructor(opts) {
    opts = opts || {};
    this.routes = {};
    this.enabled = false;

    const [table, meta] = loadRoutes(opts.file);
    this.source = meta;
    for (const [name, url] of Object.entries(table)) {
      if (!url) continue;
      this.routes[name] = new Hook(url, name);
      this.enabled = true;
    }

    // Weight alone is worth an alert regardless of rarity. There is no single
    // right number for it — it depends on the game's own scale — so it is a
    // setting, and /api/meta reports the heaviest egg ever seen so it can be
    // chosen from data instead of guessed at.
    // 5000 is not a guess any more: on the live hub the ordinary Eternals sit
    // around 2,400 kg and the heaviest seen was 8,402, so 10,000 meant this
    // route could never fire. Check maxKg in /api/meta and move it if the
    // game's scale turns out different.
    this.insaneKg = Number(process.env.INSANE_KG) || 5000;
    // Rarities that get their own channel. Anything else is not announced.
    this.byRarity = { secret: "secret", eternal: "eternal", divine: "divine" };

    this.logLevels = (process.env.WEBHOOK_LOG_LEVELS || "warn,error")
      .split(",").map((s) => s.trim().toLowerCase()).filter(Boolean);
    this.logFlushMs = Number(process.env.WEBHOOK_LOG_FLUSH_SEC || 20) * 1000;
    this.summaryMs = Number(process.env.WEBHOOK_SUMMARY_MIN || 15) * 60 * 1000;

    this.pending = [];        // buffered log lines
    this.timer = null;
    this.announced = 0;
  }

  route(name) {
    return this.routes[name] || null;
  }

  // ------------------------------------------------------------------- eggs
  // Returns the routes an egg was sent to, so the caller can log it.
  egg(e, srv) {
    if (!this.enabled || !e) return [];
    const kg = Number(e.kg) || 0;
    const rarity = String(e.rarity || "").toLowerCase();
    const hit = [];

    const byRarity = this.byRarity[rarity];
    if (byRarity && this.route(byRarity)) hit.push(byRarity);
    // A heavy Divine belongs in both: one channel is about what it is, the
    // other about how big it is.
    if (kg >= this.insaneKg && this.route("insane")) hit.push("insane");

    if (!hit.length) return [];
    const payload = this.eggEmbed(e, srv, kg >= this.insaneKg);
    for (const r of hit) this.route(r).send(payload);
    this.announced++;
    return hit;
  }

  eggEmbed(e, srv, heavy) {
    const kg = Number(e.kg) || 0;
    const jobId = String(e.jobId || "");
    const placeId = String((srv && srv.placeId) || e.placeId || "");
    const fields = [
      { name: "Weight", value: `**${fmt(kg)}** kg`, inline: true },
      { name: "Rarity", value: clip(e.rarity || "?", LIM.field), inline: true },
    ];
    if (e.area) fields.push({ name: "Area", value: clip(e.area, LIM.field), inline: true });
    if (srv) {
      fields.push({
        name: "Server",
        value: `${srv.players != null ? srv.players : "?"}/${srv.maxPlayers || "?"} players`,
        inline: true,
      });
    }
    if (e.petName && e.petName !== e.name) {
      fields.push({ name: "Pet", value: clip(e.petName, LIM.field), inline: true });
    }
    if (e.earn) fields.push({ name: "Earn", value: clip(e.earn + "/s", LIM.field), inline: true });
    // The join line is the point of the alert: it has to be one copy away.
    fields.push({
      name: "Job ID",
      value: "```\n" + clip(jobId, 200) + "\n```",
      inline: false,
    });
    if (placeId) {
      fields.push({
        name: "Join",
        value: "```js\nRoblox.GameLauncher.joinGameInstance(" + placeId + ', "' + jobId + '")\n```',
        inline: false,
      });
    }

    return {
      username: "SAE Hub",
      embeds: [
        {
          title: clip(`${heavy ? "⚠ " : ""}${e.rarity || "?"} · ${e.name || "Unknown egg"}`, LIM.title),
          color: intColor(rarityColor(e.rarity)),
          fields,
          footer: { text: clip(`rank ${rarityRank(e.rarity)}${srv && srv.reporter ? " · via " + srv.reporter : ""}`, LIM.footer) },
          timestamp: new Date().toISOString(),
        },
      ],
    };
  }

  // ------------------------------------------------------------------- logs
  log(level, text) {
    if (!this.enabled || !this.route("logs")) return;
    if (!this.logLevels.includes(String(level).toLowerCase())) return;
    this.pending.push({ level, text: String(text), at: Date.now() });
    if (this.pending.length > 400) this.pending.shift();
    if (!this.timer) {
      this.timer = setTimeout(() => this.flush(), this.logFlushMs);
      if (this.timer.unref) this.timer.unref();
    }
  }

  flush() {
    this.timer = null;
    const hook = this.route("logs");
    if (!hook || !this.pending.length) return;

    // Identical lines collapse. Without this a run of 429s posts the same
    // sentence sixty times and the channel becomes unreadable.
    const seen = new Map();
    for (const row of this.pending) {
      const k = row.level + "\u0000" + row.text;
      const prev = seen.get(k);
      if (prev) prev.n++;
      else seen.set(k, { level: row.level, text: row.text, at: row.at, n: 1 });
    }
    this.pending = [];

    const mark = { error: "✖", warn: "▲", info: "·" };
    const lines = [];
    for (const row of seen.values()) {
      const t = new Date(row.at).toISOString().slice(11, 19);
      lines.push(`${t} ${mark[row.level] || "·"} ${row.text}${row.n > 1 ? `  ×${row.n}` : ""}`);
    }

    let body = "```\n" + lines.join("\n") + "\n```";
    if (body.length > LIM.content) {
      // Keep the newest and say how many were cut, rather than truncating
      // mid-line and leaving a lie on screen.
      const keep = [];
      let size = 12;
      for (let i = lines.length - 1; i >= 0; i--) {
        if (size + lines[i].length + 1 > LIM.content - 40) break;
        keep.unshift(lines[i]);
        size += lines[i].length + 1;
      }
      const cut = lines.length - keep.length;
      body = "```\n" + keep.join("\n") + (cut ? `\n… ${cut} more line(s)` : "") + "\n```";
    }
    hook.send({ username: "SAE Hub · log", content: body });
  }

  // A compact health line, so "para estar checando" does not mean reading
  // every log line.
  summary(snap) {
    const hook = this.route("logs");
    if (!hook || !snap) return;
    const p = (snap.pool && snap.pool.pool) || {};
    const sc = (snap.pool && snap.pool.scraper) || {};
    hook.send({
      username: "SAE Hub · status",
      embeds: [
        {
          title: "Status",
          color: 0xf0a02a,
          fields: [
            { name: "Servers", value: String(snap.servers || 0), inline: true },
            { name: "Eggs", value: String(snap.eggs || 0), inline: true },
            { name: "Clients", value: String(snap.clientsOnline || 0), inline: true },
            { name: "Pool", value: `${fmt(p.total || 0)} (${fmt(p.available || 0)} free)`, inline: true },
            { name: "Scrape delay", value: `${sc.delayMs || 0} ms`, inline: true },
            { name: "Proxies", value: String(sc.proxies || 0), inline: true },
            { name: "Announced", value: String(this.announced), inline: true },
            { name: "Heaviest seen", value: `${fmt(snap.maxKg || 0)} kg`, inline: true },
            { name: "Alert over", value: `${fmt(this.insaneKg)} kg`, inline: true },
          ],
          timestamp: new Date().toISOString(),
        },
      ],
    });
  }

  start(getSnapshot) {
    if (!this.enabled || !this.route("logs")) return;
    if (this.summaryMs > 0) {
      const t = setInterval(() => {
        try { this.summary(getSnapshot()); } catch (_) {}
      }, this.summaryMs);
      if (t.unref) t.unref();
    }
  }

  stats() {
    const out = {};
    for (const [name, h] of Object.entries(this.routes)) out[name] = h.stats;
    return {
      enabled: this.enabled,
      insaneKg: this.insaneKg,
      source: this.source,
      routes: Object.keys(this.routes),
      logLevels: this.logLevels,
      announced: this.announced,
      hooks: out,
    };
  }
}

function fmt(n) {
  const v = Number(n) || 0;
  return v.toLocaleString("en-US", { maximumFractionDigits: 2 });
}

// Same precedence as the proxies: an env var beats the committed file, so a
// leaked or rotated webhook can be replaced without a commit.
const ROUTES = ["secret", "eternal", "divine", "insane", "logs"];

// Returns the routes, and second a note on where they came from. A silent
// empty table is how the relay once shipped dead: the file was simply not in
// the Docker image, and nothing said so.
function loadRoutes(file) {
  const out = {};
  let fromFile = {};
  const p = file || process.env.WEBHOOK_FILE || path.join(__dirname, "..", "webhooks.json");
  const meta = { path: p, fileFound: false, fileError: null };
  try {
    fromFile = JSON.parse(fs.readFileSync(p, "utf8"));
    meta.fileFound = true;
  } catch (err) {
    fromFile = {};
    meta.fileError = err.code === "ENOENT" ? "not found" : err.message;
  }
  for (const r of ROUTES) {
    const env = process.env["WEBHOOK_" + r.toUpperCase()];
    // An env var that is SET BUT EMPTY means "off", and must not fall back to
    // the committed file: killing a leaked webhook from the dashboard is
    // exactly when that fallback would be at its most harmful.
    const v = env !== undefined ? env.trim() : String(fromFile[r] || "").trim();
    // A placeholder left in the file is not a webhook.
    out[r] = /^https:\/\/(discord\.com|discordapp\.com)\/api\/webhooks\//.test(v) ? v : "";
  }
  return [out, meta];
}

module.exports = { Notifier, Hook, loadRoutes };
