"use strict";

const RARITY_ORDER = [
  "Common",
  "Uncommon",
  "Rare",
  "Epic",
  "Legendary",
  "Mythic",
  "Mythical",
  "Secret",
  "Divine",
];

function rarityRank(name) {
  const i = RARITY_ORDER.findIndex(
    (r) => r.toLowerCase() === String(name || "").toLowerCase()
  );
  return i === -1 ? RARITY_ORDER.length : i;
}

function norm(s) {
  return String(s == null ? "" : s).trim();
}

class Store {
  constructor(opts) {
    opts = opts || {};
    this.serverTtlMs = opts.serverTtlMs || 8 * 60 * 1000;
    this.claimTtlMs = opts.claimTtlMs || 4 * 60 * 1000;
    this.maxServers = opts.maxServers || 4000;

    this.servers = new Map();
    this.claims = new Map();
    this.raritiesSeen = new Map();

    this.stats = {
      startedAt: Date.now(),
      reports: 0,
      eggsIngested: 0,
      eggsNew: 0,
      claims: 0,
      hops: 0,
      hopsOk: 0,
      hopsFail: 0,
    };

    this.listeners = new Set();
    this._seq = 0;
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
  }

  report(body, meta) {
    const now = Date.now();
    const jobId = norm(body.jobId);
    if (!jobId) throw new Error("jobId is required");

    let srv = this.servers.get(jobId);
    if (!srv) {
      srv = {
        jobId,
        placeId: norm(body.placeId),
        firstSeen: now,
        eggs: new Map(),
      };
      this.servers.set(jobId, srv);
    }

    srv.placeId = norm(body.placeId) || srv.placeId;
    srv.players = Number(body.players) || 0;
    srv.maxPlayers = Number(body.maxPlayers) || 0;
    srv.region = norm(body.region) || srv.region || "";
    srv.reporter = norm(body.reporter) || srv.reporter || "";
    srv.updatedAt = now;
    srv.ip = (meta && meta.ip) || srv.ip || "";

    const incoming = Array.isArray(body.eggs) ? body.eggs : [];
    const fresh = [];

    for (const raw of incoming) {
      if (!raw || typeof raw !== "object") continue;
      const uid = norm(raw.uid) || `${jobId}:${norm(raw.name)}:${srv.eggs.size}`;
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
        earn: norm(raw.earn),
        source: norm(raw.source),
        owner: norm(raw.owner),
        pos: norm(raw.pos),
        lastSeen: now,
      };

      const prev = srv.eggs.get(uid);
      if (prev) {
        egg.firstSeen = prev.firstSeen;
        if (!egg.petName) egg.petName = prev.petName;
        if (!egg.growth) egg.growth = prev.growth;
        if (!egg.earn) egg.earn = prev.earn;
        if (!egg.kg) egg.kg = prev.kg;
      } else {
        egg.firstSeen = now;
        fresh.push(egg);
        this.stats.eggsNew++;
      }

      srv.eggs.set(uid, egg);
      this.stats.eggsIngested++;

      const r = egg.rarity;
      this.raritiesSeen.set(r, (this.raritiesSeen.get(r) || 0) + 1);
    }

    this.stats.reports++;
    this.prune();

    if (fresh.length) this.emit("eggs", { jobId, eggs: fresh });
    this.emit("server", { jobId, eggs: srv.eggs.size, players: srv.players });

    return { jobId, stored: srv.eggs.size, fresh: fresh.length };
  }

  prune() {
    const now = Date.now();
    for (const [jobId, srv] of this.servers) {
      if (now - srv.updatedAt > this.serverTtlMs) {
        this.servers.delete(jobId);
        this.claims.delete(jobId);
      }
    }
    for (const [jobId, c] of this.claims) {
      if (now > c.expiresAt) this.claims.delete(jobId);
    }
    if (this.servers.size > this.maxServers) {
      const sorted = [...this.servers.values()].sort(
        (a, b) => a.updatedAt - b.updatedAt
      );
      const drop = sorted.slice(0, this.servers.size - this.maxServers);
      for (const s of drop) {
        this.servers.delete(s.jobId);
        this.claims.delete(s.jobId);
      }
    }
  }

  match(filter) {
    this.prune();
    const now = Date.now();
    const out = [];

    for (const srv of this.servers.values()) {
      if (filter.jobId && srv.jobId !== filter.jobId) continue;
      if (filter.excludeJobIds && filter.excludeJobIds.has(srv.jobId)) continue;
      if (filter.unclaimedOnly) {
        const c = this.claims.get(srv.jobId);
        if (c && c.expiresAt > now) continue;
      }
      if (filter.hasSlot && srv.maxPlayers && srv.players >= srv.maxPlayers)
        continue;

      for (const egg of srv.eggs.values()) {
        if (filter.since && egg.firstSeen <= filter.since) continue;
        if (filter.minKg != null && egg.kg < filter.minKg) continue;
        if (filter.maxKg != null && egg.kg > filter.maxKg) continue;
        if (filter.rarities && !filter.rarities.has(egg.rarity.toLowerCase()))
          continue;
        if (
          filter.species &&
          !filter.species.has((egg.species || egg.name).toLowerCase())
        )
          continue;
        out.push(this.decorate(egg, srv, now));
      }
    }

    out.sort((a, b) => {
      const rr = rarityRank(b.rarity) - rarityRank(a.rarity);
      if (rr !== 0) return rr;
      if (b.kg !== a.kg) return b.kg - a.kg;
      return b.firstSeen - a.firstSeen;
    });

    return out;
  }

  decorate(egg, srv, now) {
    const claim = this.claims.get(srv.jobId);
    return {
      uid: egg.uid,
      name: egg.name,
      species: egg.species,
      rarity: egg.rarity,
      kg: egg.kg,
      petName: egg.petName,
      growth: egg.growth,
      earn: egg.earn,
      source: egg.source,
      owner: egg.owner,
      pos: egg.pos,
      jobId: srv.jobId,
      placeId: srv.placeId,
      players: srv.players,
      maxPlayers: srv.maxPlayers,
      firstSeen: egg.firstSeen,
      lastSeen: egg.lastSeen,
      ageMs: now - egg.firstSeen,
      staleMs: now - srv.updatedAt,
      claimed: !!(claim && claim.expiresAt > now),
      claimedBy: claim && claim.expiresAt > now ? claim.by : null,
    };
  }

  claim(filter, clientId) {
    const candidates = this.match(
      Object.assign({}, filter, { unclaimedOnly: true })
    );
    if (!candidates.length) return null;

    const best = candidates[0];
    const now = Date.now();
    this.claims.set(best.jobId, {
      by: clientId || "anon",
      at: now,
      expiresAt: now + this.claimTtlMs,
    });
    this.stats.claims++;
    this.emit("claim", { jobId: best.jobId, by: clientId, uid: best.uid });

    const bundle = candidates.filter((e) => e.jobId === best.jobId);
    return { target: best, eggs: bundle, expiresAt: now + this.claimTtlMs };
  }

  release(jobId, clientId) {
    const c = this.claims.get(jobId);
    if (!c) return false;
    if (clientId && c.by !== clientId && clientId !== "*") return false;
    this.claims.delete(jobId);
    this.emit("release", { jobId });
    return true;
  }

  hop(body) {
    const jobId = norm(body.jobId);
    const ok = !!body.ok;
    this.stats.hops++;
    if (ok) this.stats.hopsOk++;
    else this.stats.hopsFail++;
    if (!ok && jobId) this.release(jobId, "*");
    this.emit("hop", {
      jobId,
      ok,
      by: norm(body.client),
      reason: norm(body.reason),
    });
    return { ok: true };
  }

  snapshot() {
    this.prune();
    const now = Date.now();
    let eggs = 0;
    const byRarity = {};
    for (const srv of this.servers.values()) {
      eggs += srv.eggs.size;
      for (const e of srv.eggs.values()) {
        byRarity[e.rarity] = (byRarity[e.rarity] || 0) + 1;
      }
    }
    return {
      now,
      uptimeMs: now - this.stats.startedAt,
      servers: this.servers.size,
      eggs,
      claims: this.claims.size,
      byRarity,
      rarities: [...new Set([...RARITY_ORDER, ...this.raritiesSeen.keys()])],
      stats: this.stats,
    };
  }

  purge() {
    const n = this.servers.size;
    this.servers.clear();
    this.claims.clear();
    this.emit("purge", { servers: n });
    return n;
  }
}

module.exports = { Store, RARITY_ORDER, rarityRank };
