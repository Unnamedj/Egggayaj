"use strict";

const { LADDER, rarityRank, rarityColor } = require("./rarity");

function norm(s) {
  return String(s == null ? "" : s).trim();
}

function numOr(v, fallback) {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

class Store {
  constructor(opts) {
    opts = opts || {};
    this.serverTtlMs = opts.serverTtlMs || 8 * 60 * 1000;
    this.claimTtlMs = opts.claimTtlMs || 4 * 60 * 1000;
    this.maxServers = opts.maxServers || 4000;
    this.maxEvents = opts.maxEvents || 500;

    this.servers = new Map();
    this.claims = new Map();
    this.raritiesSeen = new Map();

    // Timestamped activity log: this is what feeds the dashboard's "12s ago".
    // Ring buffer, newest first.
    this.events = [];

    this.stats = {
      startedAt: Date.now(),
      reports: 0,
      eggsIngested: 0,
      eggsNew: 0,
      eggsGone: 0,
      claims: 0,
      hops: 0,
      hopsOk: 0,
      hopsFail: 0,
    };

    this.listeners = new Set();
    this._seq = 0;      // event sequence
    this._eggSeq = 0;   // discovered-egg sequence (the AJ's cursor)
  }

  subscribe(fn) {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  emit(type, data) {
    const payload = { type, seq: ++this._seq, at: Date.now(), data };
    for (const fn of this.listeners) {
      try {
        fn(payload);
      } catch (_) {}
    }
    return payload;
  }

  // An event that is also kept in the history the dashboard reads.
  log(kind, data) {
    const ev = this.emit(kind, data);
    this.events.unshift({ seq: ev.seq, at: ev.at, kind, ...data });
    if (this.events.length > this.maxEvents) this.events.length = this.maxEvents;
    return ev;
  }

  // ------------------------------------------------------------------- intake
  report(body, meta) {
    const now = Date.now();
    const jobId = norm(body.jobId);
    if (!jobId) throw new Error("jobId is required");

    let srv = this.servers.get(jobId);
    const isNewServer = !srv;
    if (!srv) {
      srv = {
        jobId,
        placeId: norm(body.placeId),
        firstSeen: now,
        reports: 0,
        eggs: new Map(),
        bestRank: 0,
        bestKg: 0,
      };
      this.servers.set(jobId, srv);
    }

    srv.placeId = norm(body.placeId) || srv.placeId;
    srv.players = numOr(body.players, srv.players || 0);
    srv.maxPlayers = numOr(body.maxPlayers, srv.maxPlayers || 0);
    srv.region = norm(body.region) || srv.region || "";
    srv.reporter = norm(body.reporter) || srv.reporter || "";
    srv.updatedAt = now;
    srv.reports++;
    srv.ip = (meta && meta.ip) || srv.ip || "";

    const incoming = Array.isArray(body.eggs) ? body.eggs : [];
    const fresh = [];
    const seenUids = new Set();

    for (const raw of incoming) {
      if (!raw || typeof raw !== "object") continue;
      const uid = norm(raw.uid) || `${jobId}:${norm(raw.name)}:${srv.eggs.size}`;
      seenUids.add(uid);

      const kg = Number(raw.kg);
      const egg = {
        uid,
        jobId,
        placeId: srv.placeId,
        name: norm(raw.name) || "Unknown",
        species: norm(raw.species),
        rarity: norm(raw.rarity) || "Unknown",
        kg: Number.isFinite(kg) ? Math.round(kg * 100) / 100 : 0,
        petName: norm(raw.petName),
        growth: norm(raw.growth),
        growthSec: numOr(raw.growthSec, null),
        earn: norm(raw.earn),
        earnRate: numOr(raw.earnRate, null),
        odds: norm(raw.odds),
        area: norm(raw.area),
        source: norm(raw.source) || "zone",
        owner: norm(raw.owner),
        pos: norm(raw.pos),
        lastSeen: now,
      };

      const prev = srv.eggs.get(uid);
      if (prev) {
        // Already known: keep its age and its cursor, and do not lose fields
        // this particular report happens not to carry.
        egg.firstSeen = prev.firstSeen;
        egg.seq = prev.seq;
        if (!egg.petName) egg.petName = prev.petName;
        if (!egg.growth) egg.growth = prev.growth;
        if (egg.growthSec == null) egg.growthSec = prev.growthSec;
        if (!egg.earn) egg.earn = prev.earn;
        if (egg.earnRate == null) egg.earnRate = prev.earnRate;
        if (!egg.odds) egg.odds = prev.odds;
        if (!egg.area) egg.area = prev.area;
        if (!egg.kg) egg.kg = prev.kg;
      } else {
        egg.firstSeen = now;
        egg.seq = ++this._eggSeq;
        fresh.push(egg);
        this.stats.eggsNew++;
      }

      srv.eggs.set(uid, egg);
      this.stats.eggsIngested++;
      this.raritiesSeen.set(egg.rarity, (this.raritiesSeen.get(egg.rarity) || 0) + 1);
    }

    // full = "this is EVERYTHING on this server right now". Without it, eggs
    // already taken stayed stuck in the feed forever.
    let removed = 0;
    if (body.full === true || body.full === "true") {
      for (const uid of [...srv.eggs.keys()]) {
        if (!seenUids.has(uid)) {
          srv.eggs.delete(uid);
          removed++;
        }
      }
      if (removed) this.stats.eggsGone += removed;
    }

    // Best egg on the server, so the server list can be ordered.
    srv.bestRank = 0;
    srv.bestKg = 0;
    srv.best = null;
    for (const e of srv.eggs.values()) {
      const r = rarityRank(e.rarity);
      if (r > srv.bestRank || (r === srv.bestRank && e.kg > srv.bestKg)) {
        srv.bestRank = r;
        srv.bestKg = e.kg;
        srv.best = { name: e.name, rarity: e.rarity, kg: e.kg };
      }
    }

    this.stats.reports++;
    this.prune();

    if (isNewServer) {
      this.log("server-up", {
        jobId,
        placeId: srv.placeId,
        reporter: srv.reporter,
        players: srv.players,
        maxPlayers: srv.maxPlayers,
      });
    }

    if (fresh.length) {
      // One event per new egg: the dashboard wants the timeline, not an
      // aggregate counter.
      for (const e of fresh.slice(0, 24)) {
        this.log("egg", {
          jobId,
          uid: e.uid,
          name: e.name,
          rarity: e.rarity,
          kg: e.kg,
          area: e.area,
          reporter: srv.reporter,
          seq: e.seq,
        });
      }
      this.emit("eggs", { jobId, count: fresh.length });
    }
    if (removed) this.emit("gone", { jobId, count: removed });

    this.emit("server", { jobId, eggs: srv.eggs.size, players: srv.players });

    return { jobId, stored: srv.eggs.size, fresh: fresh.length, removed };
  }

  prune() {
    const now = Date.now();
    for (const [jobId, srv] of this.servers) {
      if (now - srv.updatedAt > this.serverTtlMs) {
        this.servers.delete(jobId);
        this.claims.delete(jobId);
        this.log("server-down", { jobId, eggs: srv.eggs.size, reporter: srv.reporter });
      }
    }
    for (const [jobId, c] of this.claims) {
      if (now > c.expiresAt) this.claims.delete(jobId);
    }
    if (this.servers.size > this.maxServers) {
      const sorted = [...this.servers.values()].sort((a, b) => a.updatedAt - b.updatedAt);
      for (const s of sorted.slice(0, this.servers.size - this.maxServers)) {
        this.servers.delete(s.jobId);
        this.claims.delete(s.jobId);
      }
    }
  }

  // -------------------------------------------------------------------- query
  // match() and explain() share these two judges on purpose: if they drifted,
  // the diagnosis would lie exactly when it is needed most.
  // Return null when the egg passes, or the name of the first rule that drops it.
  serverReject(srv, filter, now) {
    if (filter.jobId && srv.jobId !== filter.jobId) return "jobId";
    if (filter.excludeJobIds && filter.excludeJobIds.has(srv.jobId)) return "excluded";
    if (filter.unclaimedOnly) {
      const c = this.claims.get(srv.jobId);
      if (c && c.expiresAt > now) return "already claimed";
    }
    if (filter.hasSlot && srv.maxPlayers && srv.players >= srv.maxPlayers) return "server full";
    if (filter.maxPlayers != null && srv.players > filter.maxPlayers) return "too many players";
    if (filter.freshServer != null && now - srv.updatedAt > filter.freshServer) return "stale server";
    return null;
  }

  eggReject(egg, filter, now) {
    // The two cut-offs the AJ uses so it never jumps to a stale find.
    if (filter.sinceSeq != null && egg.seq <= filter.sinceSeq) return "before cursor";
    if (filter.since != null && egg.firstSeen <= filter.since) return "before cursor";
    if (filter.maxAgeMs != null && now - egg.firstSeen > filter.maxAgeMs) return "too old";
    if (filter.minKg != null && egg.kg < filter.minKg) return "under min kg";
    if (filter.maxKg != null && egg.kg > filter.maxKg) return "over max kg";
    if (filter.minRank != null && rarityRank(egg.rarity) < filter.minRank) return "rarity too low";
    if (filter.rarities && !filter.rarities.has(egg.rarity.toLowerCase())) return "rarity not selected";
    if (filter.species && !filter.species.has((egg.species || egg.name).toLowerCase())) return "species";
    return null;
  }

  match(filter) {
    filter = filter || {};
    this.prune();
    const now = Date.now();
    const out = [];

    for (const srv of this.servers.values()) {
      if (this.serverReject(srv, filter, now)) continue;
      for (const egg of srv.eggs.values()) {
        if (this.eggReject(egg, filter, now)) continue;
        out.push(this.decorate(egg, srv, now));
      }
    }

    if (filter.newestFirst) {
      out.sort((a, b) => b.seq - a.seq);
    } else {
      out.sort((a, b) => {
        const rr = rarityRank(b.rarity) - rarityRank(a.rarity);
        if (rr !== 0) return rr;
        if (b.kg !== a.kg) return b.kg - a.kg;
        return b.seq - a.seq;
      });
    }
    return out;
  }

  decorate(egg, srv, now) {
    const claim = this.claims.get(srv.jobId);
    const claimed = !!(claim && claim.expiresAt > now);
    return {
      uid: egg.uid,
      seq: egg.seq,
      name: egg.name,
      species: egg.species,
      rarity: egg.rarity,
      rarityRank: rarityRank(egg.rarity),
      color: rarityColor(egg.rarity),
      kg: egg.kg,
      petName: egg.petName,
      growth: egg.growth,
      growthSec: egg.growthSec,
      earn: egg.earn,
      earnRate: egg.earnRate,
      odds: egg.odds,
      area: egg.area,
      source: egg.source,
      owner: egg.owner,
      pos: egg.pos,
      jobId: srv.jobId,
      placeId: srv.placeId,
      players: srv.players,
      maxPlayers: srv.maxPlayers,
      reporter: srv.reporter,
      firstSeen: egg.firstSeen,
      lastSeen: egg.lastSeen,
      ageMs: now - egg.firstSeen,
      staleMs: now - srv.updatedAt,
      claimed,
      claimedBy: claimed ? claim.by : null,
      claimExpiresAt: claimed ? claim.expiresAt : null,
    };
  }

  serverRows() {
    this.prune();
    const now = Date.now();
    const rows = [];
    for (const s of this.servers.values()) {
      const byRarity = {};
      let heaviest = 0;
      for (const e of s.eggs.values()) {
        byRarity[e.rarity] = (byRarity[e.rarity] || 0) + 1;
        if (e.kg > heaviest) heaviest = e.kg;
      }
      const claim = this.claims.get(s.jobId);
      const claimed = !!(claim && claim.expiresAt > now);
      rows.push({
        jobId: s.jobId,
        placeId: s.placeId,
        players: s.players || 0,
        maxPlayers: s.maxPlayers || 0,
        eggs: s.eggs.size,
        best: s.best || null,
        bestRank: s.bestRank || 0,
        heaviestKg: heaviest,
        byRarity,
        reporter: s.reporter || "",
        region: s.region || "",
        reports: s.reports,
        firstSeen: s.firstSeen,
        updatedAt: s.updatedAt,
        aliveMs: now - s.firstSeen,
        staleMs: now - s.updatedAt,
        claimed,
        claimedBy: claimed ? claim.by : null,
      });
    }
    rows.sort((a, b) => {
      if (b.bestRank !== a.bestRank) return b.bestRank - a.bestRank;
      return b.updatedAt - a.updatedAt;
    });
    return rows;
  }

  // Why there is no target. Walks the same funnel as match() and counts how
  // many eggs each rule drops, so the AJ can say "4 eggs, but 3 are a rarity
  // you did not select and 1 is behind the cursor" instead of going quiet.
  explain(filter) {
    filter = filter || {};
    this.prune();
    const now = Date.now();
    const drops = {};
    let total = 0;
    let passed = 0;
    const bump = (k) => (drops[k] = (drops[k] || 0) + 1);

    for (const srv of this.servers.values()) {
      const sr = this.serverReject(srv, filter, now);
      for (const egg of srv.eggs.values()) {
        total++;
        if (sr) { bump(sr); continue; }
        const er = this.eggReject(egg, filter, now);
        if (er) { bump(er); continue; }
        passed++;
      }
    }

    // The reason that drops the most eggs: that is the one to surface first.
    let top = null;
    for (const [reason, n] of Object.entries(drops)) {
      if (!top || n > top.count) top = { reason, count: n };
    }

    return {
      servers: this.servers.size,
      total,
      passed,
      drops,
      top,
      cursor: this._eggSeq,
      // A rarity filter naming no known rarity can never match: that is
      // almost always a misconfiguration rather than a shortage of eggs.
      rarityFilterUnknown:
        !!filter.rarities && ![...filter.rarities].some((r) => rarityRank(r) > 0),
    };
  }

  feedEvents(opts) {
    opts = opts || {};
    const limit = Math.min(opts.limit || 80, this.maxEvents);
    let rows = this.events;
    if (opts.sinceSeq != null) rows = rows.filter((e) => e.seq > opts.sinceSeq);
    if (opts.kinds) rows = rows.filter((e) => opts.kinds.has(e.kind));
    return rows.slice(0, limit).map((e) => ({ ...e, ageMs: Date.now() - e.at }));
  }

  // ------------------------------------------------------------------- claims
  claim(filter, clientId) {
    const candidates = this.match(Object.assign({}, filter, { unclaimedOnly: true }));
    if (!candidates.length) return null;

    const best = candidates[0];
    const now = Date.now();
    this.claims.set(best.jobId, {
      by: clientId || "anon",
      at: now,
      expiresAt: now + this.claimTtlMs,
      uid: best.uid,
    });
    this.stats.claims++;
    this.log("claim", {
      jobId: best.jobId,
      by: clientId || "anon",
      uid: best.uid,
      name: best.name,
      rarity: best.rarity,
      kg: best.kg,
    });

    const bundle = candidates.filter((e) => e.jobId === best.jobId);
    return { target: best, eggs: bundle, expiresAt: now + this.claimTtlMs };
  }

  release(jobId, clientId) {
    const c = this.claims.get(jobId);
    if (!c) return false;
    if (clientId && c.by !== clientId && clientId !== "*") return false;
    this.claims.delete(jobId);
    this.log("release", { jobId, by: c.by });
    return true;
  }

  hop(body) {
    const jobId = norm(body.jobId);
    const ok = !!body.ok;
    this.stats.hops++;
    if (ok) this.stats.hopsOk++;
    else this.stats.hopsFail++;
    if (!ok && jobId) this.release(jobId, "*");
    this.log("hop", {
      jobId,
      ok,
      by: norm(body.client),
      reason: norm(body.reason),
    });
    return { ok: true };
  }

  // ------------------------------------------------------------------ summary
  snapshot() {
    this.prune();
    const now = Date.now();
    let eggs = 0;
    let players = 0;
    let newestEggAt = 0;
    const byRarity = {};
    const byArea = {};
    const reporters = new Set();

    for (const srv of this.servers.values()) {
      eggs += srv.eggs.size;
      players += srv.players || 0;
      if (srv.reporter) reporters.add(srv.reporter);
      for (const e of srv.eggs.values()) {
        byRarity[e.rarity] = (byRarity[e.rarity] || 0) + 1;
        if (e.area) byArea[e.area] = (byArea[e.area] || 0) + 1;
        if (e.firstSeen > newestEggAt) newestEggAt = e.firstSeen;
      }
    }

    return {
      now,
      seq: this._seq,
      eggSeq: this._eggSeq,
      uptimeMs: now - this.stats.startedAt,
      servers: this.servers.size,
      eggs,
      players,
      claims: this.claims.size,
      reporters: reporters.size,
      newestEggAt: newestEggAt || null,
      newestEggAgeMs: newestEggAt ? now - newestEggAt : null,
      byRarity,
      byArea,
      ladder: LADDER,
      rarities: LADDER.map((r) => r.name),
      stats: this.stats,
    };
  }

  purge() {
    const n = this.servers.size;
    this.servers.clear();
    this.claims.clear();
    this.events.length = 0;
    this.log("purge", { servers: n });
    return n;
  }
}

module.exports = { Store, LADDER, rarityRank, rarityColor };
