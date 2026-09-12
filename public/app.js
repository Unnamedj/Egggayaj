(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const GREY = "#5f6875";

  const S = {
    key: localStorage.getItem("eag.key") || "",
    view: localStorage.getItem("eag.view") || "overview",
    rarities: new Set(JSON.parse(localStorage.getItem("eag.rarities") || "[]")),

    meta: null,
    pool: null,
    eggs: [],
    poolRows: [],
    servers: [],
    clients: [],
    logs: [],
    logSeq: 0,

    ladder: [],
    colors: {},
    seen: new Set(),
    seenPool: new Set(),
    es: null,
    booted: false,
    // The browser clock and the hub clock need not agree. Every age is measured
    // against the hub's own "now", offset by however far this clock has moved
    // since the response landed.
    skew: 0,
    // requests-per-window samples behind the overview sparkline
    spark: [],
    lastReq: null,
    logLevel: "",
  };

  const hubNow = () => Date.now() - S.skew;
  const colorFor = (r) => S.colors[String(r || "").toLowerCase()] || GREY;
  const fmt = (n) => (n == null || !isFinite(n) ? "—" : Number(n).toLocaleString("en-US"));

  function esc(s) {
    return String(s == null ? "" : s).replace(
      /[&<>"']/g,
      (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
    );
  }

  function ago(ms) {
    if (ms == null || !isFinite(ms)) return "—";
    const s = Math.max(0, Math.floor(ms / 1000));
    if (s < 60) return s + "s";
    const m = Math.floor(s / 60);
    if (m < 60) return m + "m " + String(s % 60).padStart(2, "0") + "s";
    const h = Math.floor(m / 60);
    if (h < 24) return h + "h " + String(m % 60).padStart(2, "0") + "m";
    return Math.floor(h / 24) + "d " + (h % 24) + "h";
  }

  function hhmmss(at) {
    const d = new Date(at);
    return [d.getHours(), d.getMinutes(), d.getSeconds()]
      .map((n) => String(n).padStart(2, "0"))
      .join(":");
  }

  let toastT;
  function toast(msg) {
    const el = $("toast");
    el.textContent = msg;
    el.classList.add("on");
    clearTimeout(toastT);
    toastT = setTimeout(() => el.classList.remove("on"), 1700);
  }

  function copy(text, label) {
    const done = () => toast(label || "copied");
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, done);
    } else {
      const ta = document.createElement("textarea");
      ta.value = text;
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); } catch (_) {}
      ta.remove();
      done();
    }
  }

  const ICON = {
    copy: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="5.4" y="5.4" width="7.8" height="7.8" rx="1.6"/><path d="M10.6 5.4V4c0-.9-.7-1.6-1.6-1.6H4.4c-.9 0-1.6.7-1.6 1.6v4.6c0 .9.7 1.6 1.6 1.6h1.2"/></svg>',
    join: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M5.6 3.4 12 7.6c.4.2.4.8 0 1L5.6 12.8c-.4.3-1 0-1-.5V3.9c0-.5.6-.8 1-.5Z"/></svg>',
  };

  // --------------------------------------------------------------------- api
  async function api(path, opts) {
    const res = await fetch(path, Object.assign({
      headers: S.key ? { "x-eag-key": S.key, "content-type": "application/json" } : { "content-type": "application/json" },
      cache: "no-store",
    }, opts || {}));
    if (res.status === 401) throw new Error("401");
    const text = await res.text();
    let data = null;
    try { data = JSON.parse(text); } catch (_) { data = { raw: text }; }
    if (!res.ok) throw new Error((data && data.error) || "HTTP " + res.status);
    if (data && typeof data.now === "number") S.skew = Date.now() - data.now;
    return data;
  }

  // -------------------------------------------------------------------- gate
  function showGate(msg) {
    $("gate").classList.remove("hidden");
    $("gateErr").textContent = msg || "";
    $("gateKey").focus();
  }

  $("gateForm").addEventListener("submit", (e) => {
    e.preventDefault();
    S.key = $("gateKey").value.trim();
    localStorage.setItem("eag.key", S.key);
    boot(true);
  });

  $("btnKey").onclick = () => {
    localStorage.removeItem("eag.key");
    S.key = "";
    if (S.es) S.es.close();
    S.es = null;
    showGate("");
  };

  // -------------------------------------------------------------------- nav
  function setView(v) {
    S.view = v;
    localStorage.setItem("eag.view", v);
    document.querySelectorAll(".nav[data-view]").forEach((b) =>
      b.classList.toggle("on", b.dataset.view === v)
    );
    document.querySelectorAll(".view").forEach((s) =>
      s.classList.toggle("on", s.id === "v-" + v)
    );
    refresh();
  }

  document.querySelectorAll(".nav[data-view]").forEach((b) => {
    b.onclick = () => setView(b.dataset.view);
  });

  const ORDER = ["overview", "eggs", "pool", "servers", "clients", "logs"];
  document.addEventListener("keydown", (e) => {
    const typing = /^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName);
    if (e.key === "/" && !typing) {
      e.preventDefault();
      // Whichever view is open has its own search box; from a view without one,
      // fall through to the egg feed.
      const box = { logs: "logFind", pool: "poolFind", servers: "srvFind", eggs: "search" }[S.view];
      if (!box) setView("eggs");
      $(box || "search").focus();
      return;
    }
    if (typing) return;
    const n = parseInt(e.key, 10);
    if (n >= 1 && n <= ORDER.length) setView(ORDER[n - 1]);
  });

  // ----------------------------------------------------------------- header
  function setConn(state, label) {
    const el = $("conn");
    el.dataset.state = state;
    $("connTxt").textContent = label;
  }

  function renderHeader() {
    const m = S.meta || {};
    const p = S.pool || {};
    const pool = p.pool || {};
    const sc = p.scraper || {};

    $("hGame").textContent = p.gameId || (m.config && m.config.gameId) || "—";
    $("kPool").textContent = fmt(pool.total);
    $("kFree").textContent = fmt(pool.available);
    $("kServers").textContent = fmt(m.servers);
    $("kEggs").textContent = fmt(m.eggs);
    $("kClients").textContent = m.clientsOnline == null ? "—" : fmt(m.clientsOnline);
    $("kDelay").textContent = sc.delayMs == null ? "—" : sc.delayMs + "ms";

    $("nPool").textContent = pool.total == null ? "" : fmt(pool.total);
    $("nSrv").textContent = m.servers == null ? "" : fmt(m.servers);
    $("nEggs").textContent = m.eggs == null ? "" : fmt(m.eggs);
    $("nCli").textContent = m.clientsOnline == null ? "" : fmt(m.clientsOnline);
    $("nLog").textContent = S.logs.length ? fmt(S.logs.length) : "";
  }

  // --------------------------------------------------------------- overview
  const BUCKETS = [
    ["empty", "#4ec9a0", "empty"],
    ["quiet", "#55b9e0", "1-3 players"],
    ["busy", "#f0a02a", "4+ players"],
    ["full", "#ef5f56", "full"],
  ];

  function renderOverview() {
    const p = S.pool || {};
    const pool = p.pool || {};
    const sc = p.scraper || {};
    const c = p.counters || {};
    const b = pool.buckets || {};

    // composition
    const total = Math.max(1, BUCKETS.reduce((n, [k]) => n + (b[k] || 0), 0));
    $("poolGauge").innerHTML = BUCKETS.map(
      ([k, col]) => `<i style="width:${((b[k] || 0) / total) * 100}%;background:${col}" title="${k}: ${b[k] || 0}"></i>`
    ).join("");
    $("poolLegend").innerHTML = BUCKETS.map(
      ([k, col, lbl]) => `<div><em style="background:${col}"></em>${lbl} <b>${fmt(b[k] || 0)}</b></div>`
    ).join("");
    $("poolNote").textContent =
      `${fmt(pool.total)} tracked · ${fmt(pool.available)} available · ${fmt(pool.dispensed)} out`;

    // request sparkline
    const bars = S.spark.length ? S.spark : [{ ok: 0, fail: 0 }];
    const peak = Math.max(1, ...bars.map((v) => v.ok + v.fail));
    $("sparkReq").innerHTML = bars
      .map((v) => {
        const cls = v.fail > 0 && v.fail >= v.ok ? "bad" : v.ok > 0 ? "hot" : "";
        const h = Math.max(2, ((v.ok + v.fail) / peak) * 100);
        return `<i class="${cls}" style="height:${h}%" title="${v.ok} ok / ${v.fail} failed"></i>`;
      })
      .join("");
    $("sOk").textContent = fmt(c.ok);
    $("sFail").textContent = fmt(c.failed);
    $("sRate").textContent = fmt(c.rateLimits);
    $("sProxy").textContent = fmt(c.proxyErrors);

    // throttle meter
    const dmin = sc.minDelayMs || 100;
    const dmax = sc.maxDelayMs || 10000;
    const d = sc.delayMs || 0;
    const pct = Math.min(100, ((d - dmin) / Math.max(1, dmax - dmin)) * 100);
    const dm = $("delayBar").parentElement;
    dm.classList.toggle("warn", pct >= 25 && pct < 60);
    dm.classList.toggle("bad", pct >= 60);
    $("delayBar").style.width = Math.max(2, pct) + "%";
    $("delayTxt").textContent = d ? `${d} ms` : "—";
    $("delayHint").textContent =
      pct < 5
        ? "At the floor. The scrape is healthy and running as fast as it is allowed to."
        : pct < 60
        ? "Backed off after some rejected requests. It eases down again on its own while things go well."
        : "Heavily throttled. Roblox or the proxy account is pushing back — more proxies, or fewer workers.";

    // concurrency meter
    const maxc = sc.maxConcurrent || 1;
    const cpct = Math.min(100, ((sc.activeRequests || 0) / maxc) * 100);
    const cm = $("concBar").parentElement;
    cm.classList.toggle("warn", (sc.queuedRequests || 0) > 0);
    $("concBar").style.width = Math.max(2, cpct) + "%";
    $("concTxt").textContent = `${sc.activeRequests || 0} / ${maxc}` + (sc.queuedRequests ? `  ·  ${sc.queuedRequests} queued` : "");
    $("concHint").textContent = sc.queuedRequests
      ? "Requests are waiting for a slot. That is the limit doing its job, not a fault."
      : "Every request that wants a slot has one.";

    // proxies
    $("proxBig").textContent = fmt(sc.proxies);
    $("proxNote").textContent = sc.lastLatencyMs ? `last ${sc.lastLatencyMs}ms` : "";
    $("proxHint").textContent = sc.proxies
      ? `Rotated one per request, at most ${sc.agentMaxSockets} sockets through each.`
      : "None configured — the scraper is going out from this host's own IP and will be rate-limited quickly. Set PROXIES or proxies.txt.";

    // workers
    const ws = sc.workerStates || [];
    $("workers").innerHTML = ws.length
      ? ws
          .map(
            (w) =>
              `<div class="wk" data-s="${esc(w.state)}"><i></i>w${w.id} <b>${esc(w.state)}</b> · ${fmt(w.cycles)} cycles · +${fmt(w.found)}</div>`
          )
          .join("")
      : '<span class="dim">no workers running</span>';

    renderDist();
    renderTape($("tapeMini"), S.logs.slice(0, 14));

    const base = location.origin;
    const k = S.key ? "?key=" + encodeURIComponent(S.key) : "";
    const eps = [
      ["take", `${base}/api/pool/server?size=1&max=3`],
      ["drop", `${base}/api/pool/remove`],
      ["stats", `${base}/api/pool/stats`],
      ["loader", `loadstring(game:HttpGet("${base}/script/reporter.lua${k}"))()`],
    ];
    $("endpoints").innerHTML = eps
      .map(([n, u]) => `<div class="e" data-copy="${esc(u)}"><span>${esc(n)}</span><code>${esc(u)}</code></div>`)
      .join("");
    $("endpoints").querySelectorAll(".e").forEach((el) => {
      el.onclick = () => copy(el.dataset.copy, "endpoint copied");
    });
  }

  function rankOf(name) {
    const k = String(name || "").toLowerCase();
    const hit = S.ladder.find((r) => r.name.toLowerCase() === k);
    return hit ? hit.rank : 0;
  }

  function renderDist() {
    const by = (S.meta && S.meta.byRarity) || {};
    const entries = Object.entries(by).sort((a, b) => rankOf(b[0]) - rankOf(a[0]) || b[1] - a[1]);
    if (!entries.length) {
      $("dist").innerHTML = '<span class="dim">nothing reported yet</span>';
      return;
    }
    const max = Math.max(1, ...entries.map((e) => e[1]));
    $("dist").innerHTML = entries
      .slice(0, 9)
      .map(([r, n]) => {
        const c = colorFor(r);
        return `<div class="dist-row"><span style="color:${c}">${esc(r)}</span>
          <div class="track"><i style="width:${(n / max) * 100}%;background:${c}"></i></div><b>${fmt(n)}</b></div>`;
      })
      .join("");
  }

  // ------------------------------------------------------------------- eggs
  function buildChips() {
    const box = $("chips");
    box.innerHTML = "";
    S.ladder.forEach((r) => {
      const k = r.name.toLowerCase();
      const on = S.rarities.has(k);
      const el = document.createElement("button");
      el.type = "button";
      el.className = "chip" + (on ? " on" : "");
      el.textContent = r.name;
      el.title = r.name + (r.odds ? " · " + r.odds : "");
      el.style.borderColor = r.color;
      el.style.color = r.color;
      el.style.background = on ? r.color : "transparent";
      el.onclick = () => {
        S.rarities.has(k) ? S.rarities.delete(k) : S.rarities.add(k);
        localStorage.setItem("eag.rarities", JSON.stringify([...S.rarities]));
        buildChips();
        refresh();
      };
      box.appendChild(el);
    });
  }

  document.querySelectorAll("[data-pick]").forEach((b) => {
    b.onclick = () => {
      S.rarities.clear();
      if (b.dataset.pick === "all") S.ladder.forEach((r) => S.rarities.add(r.name.toLowerCase()));
      // "rare+" starts at Legendary, which is where a jump begins to be worth
      // the teleport at all.
      if (b.dataset.pick === "top") {
        S.ladder.filter((r) => r.rank >= 5).forEach((r) => S.rarities.add(r.name.toLowerCase()));
      }
      localStorage.setItem("eag.rarities", JSON.stringify([...S.rarities]));
      buildChips();
      refresh();
    };
  });

  function eggQuery() {
    const p = new URLSearchParams();
    if (S.rarities.size) p.set("rarities", [...S.rarities].join(","));
    const min = Number($("minKg").value);
    if (min > 0) p.set("minKg", String(min));
    const max = Number($("maxKg").value);
    if (max > 0) p.set("maxKg", String(max));
    if ($("maxAge").value) p.set("maxAgeSec", $("maxAge").value);
    if ($("onlySlot").checked) p.set("hasSlot", "1");
    p.set("limit", "400");
    return p;
  }

  function joinCmd(placeId, jobId) {
    return `Roblox.GameLauncher.joinGameInstance(${placeId || 0}, "${jobId}")`;
  }

  function renderEggs() {
    const term = $("search").value.trim().toLowerCase();
    const free = $("onlyFree").checked;
    const rows = S.eggs.filter((e) => {
      if (free && e.claimed) return false;
      if (!term) return true;
      return `${e.name} ${e.species || ""} ${e.petName || ""} ${e.area || ""} ${e.jobId}`
        .toLowerCase()
        .includes(term);
    });

    $("eggEmpty").classList.toggle("hidden", rows.length > 0);
    const frag = document.createDocumentFragment();

    rows.forEach((e) => {
      const isNew = !S.seen.has(e.uid);
      S.seen.add(e.uid);
      const c = e.color || colorFor(e.rarity);
      const meta = [
        e.petName && e.petName !== e.name ? e.petName : null,
        e.area || null,
        e.earn ? e.earn + "/s" : null,
        e.growth ? "hatch " + e.growth : null,
      ].filter(Boolean).join(" · ");

      const row = document.createElement("div");
      row.className = "tr" + (isNew && S.booted ? " new" : "");
      row.innerHTML = `
        <div>
          <div class="cell-main"><i class="pip" style="background:${c}"></i><span>${esc(e.name)}</span></div>
          ${meta ? `<div class="sub">${esc(meta)}</div>` : ""}
        </div>
        <div><span class="tag" style="background:${c}">${esc(e.rarity)}</span></div>
        <div class="kg" style="color:${c}">${fmt(e.kg)}</div>
        <div>
          <div class="job">${esc(e.jobId)}</div>
          <div class="sub">${e.players ?? "?"}/${e.maxPlayers || "?"}${e.reporter ? " · " + esc(e.reporter) : ""}</div>
        </div>
        <div>
          <div class="age" data-at="${e.firstSeen}">${ago(e.ageMs)}</div>
          ${e.claimed ? `<span class="badge hot">claimed</span>` : ""}
        </div>
        <div class="acts">
          <button class="mini" data-a="job" title="Copy job id">${ICON.copy}</button>
          <button class="mini go" data-a="join" title="Copy join command">${ICON.join}</button>
        </div>`;
      row.querySelector('[data-a="job"]').onclick = () => copy(e.jobId, "job id copied");
      row.querySelector('[data-a="join"]').onclick = () => copy(joinCmd(e.placeId, e.jobId), "join command copied");
      frag.appendChild(row);
    });

    $("eggRows").replaceChildren(frag);
  }

  // ------------------------------------------------------------------- pool
  function renderPool() {
    const p = (S.pool && S.pool.pool) || {};
    $("poolStrip").innerHTML = [
      ["tracked", p.total],
      ["available", p.available],
      ["never used", p.fresh],
      ["dispensed", p.dispensed],
      ["recycling", p.recycling],
      ["dropped", p.removed],
      ["quiet (≤3)", p.quiet],
    ]
      .map(([k, v]) => `<div class="st"><b>${fmt(v)}</b><span>${esc(k)}</span></div>`)
      .join("");

    const term = $("poolFind").value.trim().toLowerCase();
    const freeOnly = $("poolFree").checked;
    const rows = S.poolRows.filter((r) => {
      if (freeOnly && r.dispensed) return false;
      if (term && !r.jobId.toLowerCase().includes(term)) return false;
      return true;
    });

    $("poolEmpty").classList.toggle("hidden", rows.length > 0);
    const frag = document.createDocumentFragment();

    rows.forEach((r) => {
      const isNew = !S.seenPool.has(r.jobId);
      S.seenPool.add(r.jobId);
      const pct = r.maxPlayers ? Math.min(100, (r.playing / r.maxPlayers) * 100) : 0;
      const cls = pct >= 100 ? "full" : pct >= 60 ? "mid" : "";

      let state;
      if (r.dispensed) {
        state = `<span class="badge hot">out</span> <span class="age">free in ${ago(r.recyclesInMs)}</span>`;
      } else if (r.full) {
        state = `<span class="badge bad">full</span>`;
      } else if (r.fresh) {
        state = `<span class="badge cool">never used</span>`;
      } else {
        state = `<span class="badge ok">ready</span>`;
      }

      const row = document.createElement("div");
      row.className = "tr" + (isNew && S.booted ? " new" : "");
      row.innerHTML = `
        <div class="job">${esc(r.jobId)}</div>
        <div class="pop">
          <div class="pop-bar"><i class="${cls}" style="width:${pct}%"></i></div>
          <span class="pop-n">${r.playing}/${r.maxPlayers || "?"}</span>
        </div>
        <div>${state}</div>
        <div class="age" data-at="${hubNow() - r.ageMs}">${ago(r.ageMs)}</div>
        <div class="acts">
          <button class="mini" data-a="job" title="Copy job id">${ICON.copy}</button>
          <button class="mini go" data-a="join" title="Copy join command">${ICON.join}</button>
        </div>`;
      row.querySelector('[data-a="job"]').onclick = () => copy(r.jobId, "job id copied");
      row.querySelector('[data-a="join"]').onclick = () =>
        copy(joinCmd((S.meta && S.meta.config && S.meta.config.gameId) || S.pool.gameId, r.jobId), "join command copied");
      frag.appendChild(row);
    });

    $("poolRows").replaceChildren(frag);
  }

  $("btnDispense").onclick = async () => {
    const max = $("poolMax").value.trim();
    try {
      const q = new URLSearchParams({ size: "1", format: "json", client: "console" });
      if (max !== "") q.set("max", max);
      const r = await api("/api/pool/server?" + q.toString());
      const s = r.servers[0];
      copy(s.jobId, `took ${s.jobId.slice(0, 8)} · ${s.playing}p${r.relaxed ? " (relaxed)" : ""}`);
      refresh();
    } catch (e) {
      toast(String(e.message) === "401" ? "key rejected" : "nothing to take: " + e.message);
    }
  };

  $("btnRecycle").onclick = async () => {
    try {
      const r = await api("/api/pool/recycle", { method: "POST" });
      toast(`recycled ${r.recycled} · ${r.available} available`);
      refresh();
    } catch (e) { toast("failed: " + e.message); }
  };

  $("btnClear").onclick = async () => {
    if (!confirm("Throw away the whole job-id pool? The scraper refills it, but every bot waiting on it stalls until it does.")) return;
    try {
      const r = await api("/api/pool/clear", { method: "POST" });
      toast(`cleared ${r.cleared}`);
      S.seenPool.clear();
      refresh();
    } catch (e) { toast("failed: " + e.message); }
  };

  // ---------------------------------------------------------------- servers
  function renderServers() {
    const term = $("srvFind").value.trim().toLowerCase();
    const rows = S.servers.filter(
      (s) => !term || (s.jobId + " " + (s.reporter || "")).toLowerCase().includes(term)
    );
    $("srvEmpty").classList.toggle("hidden", rows.length > 0);

    const frag = document.createDocumentFragment();
    rows.forEach((s) => {
      const bc = s.best ? colorFor(s.best.rarity) : GREY;
      const pct = s.maxPlayers ? Math.min(100, (s.players / s.maxPlayers) * 100) : 0;
      const mix = Object.entries(s.byRarity || {})
        .sort((a, b) => b[1] - a[1])
        .slice(0, 5)
        .map(([r, n]) => {
          const c = colorFor(r);
          return `<span class="mix" style="border-color:${c}55;color:${c}">${esc(r)} ${n}</span>`;
        })
        .join("");

      const card = document.createElement("div");
      card.className = "srv";
      card.innerHTML = `
        <div class="srv-top">
          <div class="job">${esc(s.jobId)}</div>
          ${s.claimed ? `<span class="badge hot">${esc(s.claimedBy || "claimed")}</span>` : ""}
        </div>
        <div class="srv-best">${
          s.best
            ? `<i class="pip" style="background:${bc}"></i><b>${esc(s.best.name)}</b>
               <span class="tag" style="background:${bc}">${esc(s.best.rarity)}</span>
               <span class="kg" style="color:${bc}">${fmt(s.best.kg)} kg</span>`
            : '<span class="dim">no eggs right now</span>'
        }</div>
        <div class="srv-grid">
          <div class="srv-cell"><b>${fmt(s.eggs)}</b><span>eggs</span></div>
          <div class="srv-cell"><b>${s.players}<span class="dim">/${s.maxPlayers || "?"}</span></b><span>players</span></div>
          <div class="srv-cell"><b>${fmt(s.heaviestKg)}</b><span>max kg</span></div>
        </div>
        ${mix ? `<div class="srv-mix">${mix}</div>` : ""}
        <div class="srv-foot">
          <span>report <span class="age" data-at="${s.updatedAt}">${ago(s.staleMs)}</span></span>
          <span>· up <span class="age" data-at="${s.firstSeen}">${ago(s.aliveMs)}</span></span>
          <div class="acts">
            <button class="mini" data-a="job" title="Copy job id">${ICON.copy}</button>
            <button class="mini go" data-a="join" title="Copy join command">${ICON.join}</button>
          </div>
        </div>`;
      card.querySelector('[data-a="job"]').onclick = () => copy(s.jobId, "job id copied");
      card.querySelector('[data-a="join"]').onclick = () => copy(joinCmd(s.placeId, s.jobId), "join command copied");
      frag.appendChild(card);
    });
    $("srvRows").replaceChildren(frag);
  }

  // ---------------------------------------------------------------- clients
  const ROLE = {
    joiner: ["auto-joiner", "ok"],
    reporter: ["reporter", "cool"],
    pool: ["pool client", "hot"],
  };

  function renderClients() {
    const rows = S.clients;
    $("cliEmpty").classList.toggle("hidden", rows.length > 0);
    const on = rows.filter((r) => r.online).length;
    $("cliNote").textContent = rows.length
      ? `${on} online of ${rows.length} seen · a client drops off this list after 10 minutes of silence`
      : "";

    const frag = document.createDocumentFragment();
    rows.forEach((c) => {
      const roles = (c.roles.length ? c.roles : [c.lastKind])
        .filter(Boolean)
        .map((r) => {
          const [label, cls] = ROLE[r] || [r, ""];
          return `<span class="badge ${cls}">${esc(label)}</span>`;
        })
        .join(" ");

      const bits = [];
      if (c.claims) bits.push(`${fmt(c.claims)} claims`);
      if (c.hops) bits.push(`${fmt(c.hops)} hops${c.hopFails ? ` (${fmt(c.hopFails)} failed)` : ""}`);
      if (c.reports) bits.push(`${fmt(c.reports)} reports`);
      if (c.jobIds) bits.push(`${fmt(c.jobIds)} job ids`);
      if (c.drops) bits.push(`${fmt(c.drops)} dropped`);
      if (c.releases) bits.push(`${fmt(c.releases)} released`);

      const row = document.createElement("div");
      row.className = "tr";
      row.innerHTML = `
        <div>
          <div class="cell-main">
            <i class="pip" style="background:${c.online ? "#4ec9a0" : "#5f6875"}"></i><span>${esc(c.id)}</span>
          </div>
          <div class="sub">${esc(c.ip || "")} · up ${ago(c.aliveMs)}</div>
        </div>
        <div>${roles}</div>
        <div class="sub" style="margin:0">${bits.length ? esc(bits.join(" · ")) : '<span class="dim">—</span>'}</div>
        <div class="job">${esc(c.lastJobId || "—")}</div>
        <div class="age" data-at="${c.lastSeen}">${ago(c.idleMs)}</div>`;
      frag.appendChild(row);
    });
    $("cliRows").replaceChildren(frag);
  }

  // ------------------------------------------------------------------- logs
  function renderTape(box, rows) {
    if (!rows.length) {
      box.innerHTML = '<span class="dim">nothing yet</span>';
      return;
    }
    box.innerHTML = rows
      .map(
        (l) =>
          `<div class="ln ${esc(l.level)}"><time>${hhmmss(l.at)}</time><em>${esc(l.level)}</em><span>${esc(l.text)}</span></div>`
      )
      .join("");
  }

  function renderLogs() {
    const term = $("logFind").value.trim().toLowerCase();
    const rows = S.logs.filter(
      (l) => (!S.logLevel || l.level === S.logLevel) && (!term || l.text.toLowerCase().includes(term))
    );
    $("logEmpty").classList.toggle("hidden", rows.length > 0);
    renderTape($("tape"), rows.slice(0, 400));
  }

  $("logLevel").querySelectorAll("button").forEach((b) => {
    b.onclick = () => {
      $("logLevel").querySelectorAll("button").forEach((x) => x.classList.remove("on"));
      b.classList.add("on");
      S.logLevel = b.dataset.level;
      renderLogs();
    };
  });

  $("btnLogCopy").onclick = () => {
    const text = S.logs
      .slice(0, 400)
      .reverse()
      .map((l) => `${new Date(l.at).toISOString()} ${l.level.toUpperCase()} ${l.text}`)
      .join("\n");
    copy(text, "log copied");
  };

  function pushLog(row) {
    if (S.logs.length && row.seq <= S.logs[0].seq) return;
    S.logs.unshift(row);
    if (S.logs.length > 600) S.logs.length = 600;
    S.logSeq = Math.max(S.logSeq, row.seq);
    if (S.view === "logs" && $("logFollow").checked) renderLogs();
    if (S.view === "overview") renderTape($("tapeMini"), S.logs.slice(0, 14));
    $("nLog").textContent = fmt(S.logs.length);
  }

  // ------------------------------------------------------------------ ticks
  // Repaints the relative timestamps without asking the hub for anything. It is
  // what keeps the console feeling live between refreshes.
  function tickAges() {
    const now = hubNow();
    document.querySelectorAll(".age[data-at]").forEach((el) => {
      const at = Number(el.dataset.at);
      if (!at) return;
      const d = now - at;
      el.textContent = ago(d);
      el.classList.toggle("hot", d < 60000);
    });
  }

  function sampleRate() {
    const c = S.pool && S.pool.counters;
    if (!c) return;
    if (S.lastReq) {
      S.spark.push({ ok: Math.max(0, c.ok - S.lastReq.ok), fail: Math.max(0, c.failed - S.lastReq.failed) });
      if (S.spark.length > 46) S.spark.shift();
    }
    S.lastReq = { ok: c.ok, failed: c.failed };
  }

  // ---------------------------------------------------------------- refresh
  let busy = false;
  let again = false;

  async function refresh() {
    if (busy) { again = true; return; }
    busy = true;
    try {
      const jobs = [api("/api/meta")];
      const v = S.view;
      if (v === "eggs") jobs.push(api("/api/feed?" + eggQuery().toString()));
      else if (v === "pool") {
        const max = $("poolMax").value.trim();
        jobs.push(api("/api/pool/servers?limit=600" + (max !== "" ? "&max=" + encodeURIComponent(max) : "")));
      }
      else if (v === "servers") jobs.push(api("/api/servers"));
      else if (v === "clients") jobs.push(api("/api/clients"));
      else if (v === "logs") jobs.push(api("/api/pool/logs?limit=400"));

      const [meta, extra] = await Promise.all(jobs);
      S.meta = meta;
      S.pool = meta.pool || S.pool;

      if (Array.isArray(meta.ladder) && meta.ladder.length) {
        S.ladder = meta.ladder;
        S.colors = {};
        meta.ladder.forEach((r) => (S.colors[r.name.toLowerCase()] = r.color));
        if (!$("chips").children.length) buildChips();
      }

      renderHeader();

      if (v === "overview") renderOverview();
      else if (v === "eggs" && extra) { S.eggs = extra.eggs || []; renderEggs(); }
      else if (v === "pool" && extra) { S.poolRows = extra.servers || []; renderPool(); }
      else if (v === "servers" && extra) { S.servers = extra.servers || []; renderServers(); }
      else if (v === "clients" && extra) { S.clients = extra.clients || []; renderClients(); }
      else if (v === "logs" && extra) {
        const rows = extra.logs || [];
        // Merge rather than replace: SSE may have delivered lines this fetch
        // does not carry yet.
        const known = new Set(S.logs.map((l) => l.seq));
        for (const r of rows) if (!known.has(r.seq)) S.logs.push(r);
        S.logs.sort((a, b) => b.seq - a.seq);
        if (S.logs.length > 600) S.logs.length = 600;
        renderLogs();
      }

      setConn("on", "live");
      S.booted = true;
    } catch (e) {
      if (String(e.message) === "401") return showGate("That key was rejected.");
      setConn("off", "offline");
    } finally {
      busy = false;
      if (again) { again = false; refresh(); }
    }
  }

  // Coalesced: the hub can emit a burst of events and refetching per event is
  // not worth it.
  let burst = null;
  function nudge() {
    if (!$("live").checked) return;
    clearTimeout(burst);
    burst = setTimeout(refresh, 240);
  }

  // -------------------------------------------------------------------- sse
  function connectStream() {
    if (S.es) S.es.close();
    const es = new EventSource("/api/stream" + (S.key ? "?key=" + encodeURIComponent(S.key) : ""));
    S.es = es;
    es.addEventListener("hello", () => setConn("on", "live"));
    es.addEventListener("pool-log", (e) => {
      try { pushLog(JSON.parse(e.data)); } catch (_) {}
    });
    ["eggs", "egg", "gone", "claim", "release", "hop", "server-up", "server-down", "purge", "client-up", "client-down"]
      .forEach((t) => es.addEventListener(t, nudge));
    es.onerror = () => setConn("wait", "reconnecting");
  }

  // ------------------------------------------------------------------ wiring
  const debounce = (fn, ms) => {
    let t;
    return () => { clearTimeout(t); t = setTimeout(fn, ms); };
  };

  ["minKg", "maxKg", "maxAge", "onlyFree", "onlySlot", "search"].forEach((id) =>
    $(id).addEventListener(/^(minKg|maxKg|search)$/.test(id) ? "input" : "change", debounce(refresh, 240))
  );
  ["poolMax", "poolFind", "poolFree"].forEach((id) =>
    $(id).addEventListener(id === "poolFree" ? "change" : "input", debounce(() => {
      // Filtering by job id is local; changing the population cap is a query.
      if (id === "poolMax") refresh();
      else renderPool();
    }, 220))
  );
  $("srvFind").addEventListener("input", debounce(renderServers, 200));
  $("logFind").addEventListener("input", debounce(renderLogs, 200));

  // ------------------------------------------------------------------- boot
  async function boot(fromGate) {
    try {
      const meta = await api("/api/meta");
      S.meta = meta;
      S.pool = meta.pool || null;
      S.ladder = meta.ladder || [];
      S.colors = {};
      S.ladder.forEach((r) => (S.colors[r.name.toLowerCase()] = r.color));

      $("gate").classList.add("hidden");
      buildChips();
      connectStream();

      try {
        const l = await api("/api/pool/logs?limit=300");
        S.logs = l.logs || [];
        S.logSeq = l.seq || 0;
      } catch (_) {}

      setView(S.view);
    } catch (e) {
      showGate(fromGate || S.key ? "That key was rejected." : "");
    }
  }

  setInterval(tickAges, 1000);
  setInterval(() => {
    if (!S.meta) return;
    sampleRate();
    if (S.view === "overview") renderOverview();
  }, 5000);
  // Safety net for an SSE that drops without saying so.
  setInterval(() => { if ($("live").checked && !document.hidden) refresh(); }, 15000);

  boot(false);
})();
