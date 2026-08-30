(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);
  const FALLBACK_COLOR = "#6b7280";

  const state = {
    key: localStorage.getItem("eag.key") || "",
    rarities: new Set(JSON.parse(localStorage.getItem("eag.rarities") || "[]")),
    eggs: [],
    servers: [],
    events: [],
    meta: null,
    ladder: [],
    colors: {},
    es: null,
    seen: new Set(),
    tab: "eggs",
    // El reloj del navegador y el del hub no tienen por que coincidir; todas
    // las edades se calculan contra el "now" del hub mas lo que ha corrido
    // el reloj local desde que llego la respuesta.
    skew: 0,
    booted: false,
  };

  const hubNow = () => Date.now() - state.skew;
  const colorFor = (r) => state.colors[String(r || "").toLowerCase()] || FALLBACK_COLOR;

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c])
    );
  }

  // "hace 12s" / "hace 4m 03s" / "hace 2h 11m"
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

  function clock(at) {
    const d = new Date(at);
    return (
      String(d.getHours()).padStart(2, "0") +
      ":" + String(d.getMinutes()).padStart(2, "0") +
      ":" + String(d.getSeconds()).padStart(2, "0")
    );
  }

  const fmt = (n) => (n == null ? "—" : Number(n).toLocaleString("es-ES"));

  function copy(text, btn) {
    const done = () => {
      if (!btn) return;
      const old = btn.innerHTML;
      btn.textContent = "✓";
      setTimeout(() => (btn.innerHTML = old), 1000);
    };
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
    copy: '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5"><rect x="5.2" y="5.2" width="8" height="8" rx="1.8"/><path d="M10.6 5.2V3.9c0-.9-.7-1.6-1.6-1.6H4.4c-.9 0-1.6.7-1.6 1.6v4.6c0 .9.7 1.6 1.6 1.6h1.3"/></svg>',
    join: '<svg viewBox="0 0 16 16" fill="currentColor"><path d="M5.6 3.4 12 7.6c.4.2.4.8 0 1L5.6 12.8c-.4.3-1 0-1-.5V3.9c0-.5.6-.8 1-.5Z"/></svg>',
  };

  // ------------------------------------------------------------------- api
  async function api(path) {
    const res = await fetch(path, {
      headers: state.key ? { "x-eag-key": state.key } : {},
      cache: "no-store",
    });
    if (res.status === 401) throw new Error("401");
    if (!res.ok) throw new Error("HTTP " + res.status);
    const data = await res.json();
    if (typeof data.now === "number") state.skew = Date.now() - data.now;
    return data;
  }

  // ------------------------------------------------------------------ gate
  function showGate(msg) {
    $("gate").classList.remove("hidden");
    $("gateErr").textContent = msg || "";
    $("gateKey").focus();
  }

  $("gateForm").addEventListener("submit", (e) => {
    e.preventDefault();
    state.key = $("gateKey").value.trim();
    localStorage.setItem("eag.key", state.key);
    boot(true);
  });

  $("btnLogout").onclick = () => {
    localStorage.removeItem("eag.key");
    state.key = "";
    if (state.es) state.es.close();
    state.es = null;
    showGate("");
  };

  // --------------------------------------------------------------- filtros
  function buildChips() {
    const box = $("chips");
    box.innerHTML = "";
    state.ladder.forEach((r) => {
      const k = r.name.toLowerCase();
      const on = state.rarities.has(k);
      const el = document.createElement("button");
      el.type = "button";
      el.className = "chip" + (on ? " on" : "");
      el.textContent = r.name;
      el.title = r.name + " · " + (r.odds || "");
      el.style.borderColor = r.color;
      el.style.color = r.color;
      if (on) el.style.background = r.color;
      el.onclick = () => {
        if (state.rarities.has(k)) state.rarities.delete(k);
        else state.rarities.add(k);
        saveRarities();
        buildChips();
        refresh();
      };
      box.appendChild(el);
    });
  }

  function saveRarities() {
    localStorage.setItem("eag.rarities", JSON.stringify([...state.rarities]));
  }

  document.querySelectorAll("[data-pick]").forEach((b) => {
    b.onclick = () => {
      const mode = b.dataset.pick;
      state.rarities.clear();
      if (mode === "all") state.ladder.forEach((r) => state.rarities.add(r.name.toLowerCase()));
      // "solo raras" = de Legendary (rank 5) para arriba, que es donde empieza
      // lo que de verdad merece un salto.
      if (mode === "top") {
        state.ladder.filter((r) => r.rank >= 5).forEach((r) => state.rarities.add(r.name.toLowerCase()));
      }
      saveRarities();
      buildChips();
      refresh();
    };
  });

  function query() {
    const p = new URLSearchParams();
    if (state.rarities.size) p.set("rarities", [...state.rarities].join(","));
    const min = Number($("minKg").value);
    if (min > 0) p.set("minKg", String(min));
    const max = Number($("maxKg").value);
    if (max > 0) p.set("maxKg", String(max));
    const age = $("maxAge").value;
    if (age) p.set("maxAgeSec", age);
    if ($("onlySlot").checked) p.set("hasSlot", "1");
    p.set("limit", "400");
    return p;
  }

  // -------------------------------------------------------------- render
  function renderEggs() {
    const term = $("search").value.trim().toLowerCase();
    const onlyFree = $("onlyFree").checked;

    const rows = state.eggs.filter((e) => {
      if (onlyFree && e.claimed) return false;
      if (!term) return true;
      return (
        e.name + " " + (e.species || "") + " " + (e.petName || "") +
        " " + (e.area || "") + " " + e.jobId
      ).toLowerCase().includes(term);
    });

    $("kMatch").textContent = fmt(rows.length);
    $("tEggs").textContent = rows.length;
    $("eggEmpty").classList.toggle("hidden", rows.length > 0);

    const box = $("eggRows");
    box.innerHTML = "";
    const frag = document.createDocumentFragment();

    rows.forEach((e) => {
      const fresh = !state.seen.has(e.uid);
      state.seen.add(e.uid);
      const c = e.color || colorFor(e.rarity);

      const div = document.createElement("div");
      div.className = "row egg" + (fresh && state.booted ? " fresh" : "");

      const meta = [
        e.petName && e.petName !== e.name ? e.petName : null,
        e.area || null,
        e.earn ? e.earn + "/s" : null,
        e.growth ? "eclosión " + e.growth : null,
      ].filter(Boolean).join(" · ");

      div.innerHTML = `
        <div>
          <div class="egg-title"><i class="pip" style="background:${c};color:${c}"></i>${esc(e.name)}</div>
          ${meta ? `<div class="sub">${esc(meta)}</div>` : ""}
        </div>
        <div><span class="tag" style="background:${c}">${esc(e.rarity)}</span></div>
        <div class="kg" style="color:${c}">${fmt(e.kg)}<span class="dim" style="font-size:10px"> kg</span></div>
        <div class="col-srv">
          <div class="job" title="${esc(e.jobId)}">${esc(e.jobId)}</div>
          <div class="sub">${e.players ?? "?"}/${e.maxPlayers || "?"} jug.${e.reporter ? " · " + esc(e.reporter) : ""}</div>
        </div>
        <div class="col-age">
          <div class="age ${e.ageMs < 60000 ? "hot" : ""}" data-at="${e.firstSeen}">hace ${ago(e.ageMs)}</div>
          ${e.claimed ? '<span class="badge">claim</span>' : ""}
        </div>
        <div class="acts">
          <button class="mini" data-a="job" title="Copiar Job ID">${ICON.copy}</button>
          <button class="mini go" data-a="join" title="Copiar comando de join">${ICON.join}</button>
        </div>`;

      div.querySelector('[data-a="job"]').onclick = (ev) => copy(e.jobId, ev.currentTarget);
      div.querySelector('[data-a="join"]').onclick = (ev) =>
        copy(`Roblox.GameLauncher.joinGameInstance(${e.placeId || 0}, "${e.jobId}")`, ev.currentTarget);

      frag.appendChild(div);
    });

    box.appendChild(frag);
  }

  function renderServers() {
    const box = $("srvRows");
    box.innerHTML = "";
    $("tServers").textContent = state.servers.length;
    $("srvEmpty").classList.toggle("hidden", state.servers.length > 0);

    const frag = document.createDocumentFragment();

    state.servers.forEach((s) => {
      const card = document.createElement("div");
      card.className = "srv";

      const mix = Object.entries(s.byRarity || {})
        .sort((a, b) => b[1] - a[1])
        .slice(0, 6)
        .map(([r, n]) => {
          const c = colorFor(r);
          return `<span class="mix" style="border-color:${c}55;color:${c}">${esc(r)} ${n}</span>`;
        })
        .join("");

      const bc = s.best ? colorFor(s.best.rarity) : FALLBACK_COLOR;
      const pct = s.maxPlayers ? Math.min(100, (s.players / s.maxPlayers) * 100) : 0;

      card.innerHTML = `
        <div class="srv-top">
          <div class="job" title="${esc(s.jobId)}">${esc(s.jobId)}</div>
          ${s.claimed ? `<span class="badge">claim ${esc(s.claimedBy || "")}</span>` : ""}
        </div>

        ${s.best ? `
        <div class="srv-best">
          <i class="pip" style="background:${bc};color:${bc}"></i>
          <b>${esc(s.best.name)}</b>
          <span class="tag" style="background:${bc}">${esc(s.best.rarity)}</span>
          <span class="kg" style="color:${bc}">${fmt(s.best.kg)} kg</span>
        </div>` : `<div class="srv-best"><span class="dim">sin huevos ahora mismo</span></div>`}

        <div class="srv-grid">
          <div class="srv-cell"><b>${fmt(s.eggs)}</b><span>huevos</span></div>
          <div class="srv-cell">
            <b>${s.players}<span class="dim" style="font-size:10px">/${s.maxPlayers || "?"}</span></b>
            <span>jugadores</span>
            <div class="bars"><i class="${pct >= 100 ? "full" : ""}" style="width:${pct}%"></i></div>
          </div>
          <div class="srv-cell"><b>${fmt(s.heaviestKg)}</b><span>kg máx</span></div>
        </div>

        ${mix ? `<div class="srv-mix">${mix}</div>` : ""}

        <div class="srv-foot">
          <span title="Último reporte recibido">reporte <b class="age" data-at="${s.updatedAt}">hace ${ago(s.staleMs)}</b></span>
          <span title="Tiempo desde el primer reporte">· vivo ${ago(s.aliveMs)}</span>
          <div class="acts">
            <button class="mini" data-a="job" title="Copiar Job ID">${ICON.copy}</button>
            <button class="mini go" data-a="join" title="Copiar comando de join">${ICON.join}</button>
          </div>
        </div>`;

      card.querySelector('[data-a="job"]').onclick = (ev) => copy(s.jobId, ev.currentTarget);
      card.querySelector('[data-a="join"]').onclick = (ev) =>
        copy(`Roblox.GameLauncher.joinGameInstance(${s.placeId || 0}, "${s.jobId}")`, ev.currentTarget);

      frag.appendChild(card);
    });

    box.appendChild(frag);
  }

  const EV = {
    egg: { color: "#7c5cff" },
    "server-up": { color: "#34d399" },
    "server-down": { color: "#6a7285" },
    claim: { color: "#fbbf24" },
    release: { color: "#22d3ee" },
    hop: { color: "#34d399" },
    purge: { color: "#fb5f78" },
  };

  function eventText(e) {
    const job = `<code>${esc(String(e.jobId || "").slice(0, 8))}</code>`;
    switch (e.kind) {
      case "egg": {
        const c = colorFor(e.rarity);
        return `<b style="color:${c}">${esc(e.name)}</b> ${esc(e.rarity)} · ${fmt(e.kg)} kg` +
          `${e.area ? " · " + esc(e.area) : ""} en ${job}` +
          `${e.reporter ? ` <span class="dim">por ${esc(e.reporter)}</span>` : ""}`;
      }
      case "server-up":
        return `nuevo server ${job} · ${e.players ?? "?"}/${e.maxPlayers || "?"} jugadores` +
          `${e.reporter ? ` <span class="dim">— ${esc(e.reporter)}</span>` : ""}`;
      case "server-down":
        return `server ${job} dejó de reportar <span class="dim">(${fmt(e.eggs)} huevos perdidos)</span>`;
      case "claim":
        return `<b>${esc(e.by || "?")}</b> reservó ${job} · ${esc(e.name || "")} ${fmt(e.kg)} kg`;
      case "release":
        return `claim liberado en ${job}`;
      case "hop":
        return e.ok
          ? `<b style="color:#34d399">salto ok</b> a ${job}${e.by ? " · " + esc(e.by) : ""}`
          : `<b style="color:#fb5f78">salto falló</b> en ${job}${e.reason ? " · " + esc(e.reason) : ""}`;
      case "purge":
        return `hub vaciado (${fmt(e.servers)} servers)`;
      default:
        return esc(e.kind);
    }
  }

  function renderEvents() {
    const box = $("feedRows");
    box.innerHTML = "";
    $("feedEmpty").classList.toggle("hidden", state.events.length > 0);

    const frag = document.createDocumentFragment();
    state.events.forEach((e) => {
      const meta = EV[e.kind] || { color: FALLBACK_COLOR };
      const row = document.createElement("div");
      row.className = "ev";
      row.innerHTML =
        `<div class="ev-time" title="${clock(e.at)}"><span class="age" data-at="${e.at}">hace ${ago(hubNow() - e.at)}</span></div>` +
        `<i class="ev-dot" style="background:${meta.color};color:${meta.color}"></i>` +
        `<div class="ev-txt">${eventText(e)}</div>`;
      frag.appendChild(row);
    });
    box.appendChild(frag);
  }

  function renderDist() {
    const by = (state.meta && state.meta.byRarity) || {};
    const entries = Object.entries(by).sort(
      (a, b) => (rankOf(b[0]) - rankOf(a[0])) || (b[1] - a[1])
    );
    if (!entries.length) {
      $("dist").innerHTML = '<span class="dim">sin datos aún</span>';
      return;
    }
    const max = Math.max(1, ...entries.map((e) => e[1]));
    $("dist").innerHTML = entries
      .map(([r, n]) => {
        const c = colorFor(r);
        return `<div class="dist-row"><span style="color:${c}" title="${esc(r)}">${esc(r)}</span>
          <div class="bar"><i style="width:${(n / max) * 100}%;background:${c}"></i></div>
          <b>${n}</b></div>`;
      })
      .join("");
  }

  function rankOf(name) {
    const k = String(name || "").toLowerCase();
    const hit = state.ladder.find((r) => r.name.toLowerCase() === k);
    return hit ? hit.rank : 0;
  }

  // Repinta solo los textos "hace X" sin volver a pedir nada al hub. Es lo que
  // hace que el dashboard se sienta vivo entre refrescos.
  function tickAges() {
    const now = hubNow();
    document.querySelectorAll(".age[data-at]").forEach((el) => {
      const at = Number(el.dataset.at);
      if (!at) return;
      const d = now - at;
      el.textContent = "hace " + ago(d);
      el.classList.toggle("hot", d < 60000);
    });
  }

  function setConn(ok, label) {
    const p = $("conn");
    p.classList.toggle("on", !!ok);
    p.classList.toggle("off", !ok);
    p.querySelector("span").textContent = label || (ok ? "en vivo" : "sin conexión");
  }

  // -------------------------------------------------------------- fetch
  let busy = false;
  let queued = false;

  async function refresh() {
    if (busy) { queued = true; return; }
    busy = true;
    try {
      const jobs = [api("/api/feed?" + query().toString()), api("/api/meta")];
      if (state.tab === "servers") jobs.push(api("/api/servers"));
      if (state.tab === "feed") jobs.push(api("/api/events?limit=120"));
      const [feed, meta, extra] = await Promise.all(jobs);

      state.eggs = feed.eggs || [];
      state.meta = meta;

      if (Array.isArray(meta.ladder) && meta.ladder.length) {
        state.ladder = meta.ladder;
        state.colors = {};
        meta.ladder.forEach((r) => (state.colors[r.name.toLowerCase()] = r.color));
        if (!$("chips").children.length) buildChips();
      }

      $("kServers").textContent = fmt(meta.servers);
      $("tServers").textContent = meta.servers;
      $("kEggs").textContent = fmt(meta.eggs);
      $("kClaims").textContent = fmt(meta.claims);
      const mins = Math.max(1, meta.uptimeMs / 60000);
      $("kRate").textContent = (meta.stats.eggsNew / mins).toFixed(1);
      $("kLast").textContent = meta.newestEggAgeMs == null ? "—" : ago(meta.newestEggAgeMs);

      renderEggs();
      renderDist();

      if (state.tab === "servers" && extra) {
        state.servers = extra.servers || [];
        renderServers();
      } else if (state.tab === "feed" && extra) {
        state.events = extra.events || [];
        renderEvents();
      }

      setConn(true);
      state.booted = true;
    } catch (e) {
      if (String(e.message) === "401") return showGate("Key inválida.");
      setConn(false);
    } finally {
      busy = false;
      if (queued) { queued = false; refresh(); }
    }
  }

  // Refresco agrupado: el hub puede emitir muchos eventos seguidos y no vale
  // la pena pedir el feed entero por cada uno.
  let burst = null;
  function nudge() {
    if (!$("live").checked) return;
    clearTimeout(burst);
    burst = setTimeout(refresh, 220);
  }

  // ---------------------------------------------------------------- sse
  function connectStream() {
    if (state.es) state.es.close();
    const url = "/api/stream" + (state.key ? "?key=" + encodeURIComponent(state.key) : "");
    const es = new EventSource(url);
    state.es = es;

    es.addEventListener("hello", () => setConn(true));
    ["eggs", "egg", "gone", "claim", "release", "hop", "server-up", "server-down", "purge"]
      .forEach((t) => es.addEventListener(t, nudge));
    es.onerror = () => setConn(false, "reconectando");
  }

  // --------------------------------------------------------------- tabs
  document.querySelectorAll(".tab").forEach((t) => {
    t.onclick = () => {
      document.querySelectorAll(".tab").forEach((x) => x.classList.remove("active"));
      t.classList.add("active");
      state.tab = t.dataset.tab;
      ["eggs", "servers", "feed"].forEach((n) =>
        $("tab-" + n).classList.toggle("hidden", state.tab !== n)
      );
      refresh();
    };
  });

  ["minKg", "maxKg", "search", "onlyFree", "onlySlot", "maxAge"].forEach((id) => {
    const ev = id === "onlyFree" || id === "onlySlot" || id === "maxAge" ? "change" : "input";
    $(id).addEventListener(ev, () => {
      clearTimeout(window.__f);
      window.__f = setTimeout(refresh, 220);
    });
  });

  $("btnCopy").onclick = (ev) => copy(location.origin, ev.currentTarget);

  // ---------------------------------------------------------------- boot
  async function boot(fromGate) {
    $("baseUrl").textContent = location.origin;
    try {
      const meta = await api("/api/meta");
      state.meta = meta;
      state.ladder = meta.ladder || [];
      state.colors = {};
      state.ladder.forEach((r) => (state.colors[r.name.toLowerCase()] = r.color));

      $("gate").classList.add("hidden");
      buildChips();
      connectStream();
      await refresh();
    } catch (e) {
      showGate(fromGate || state.key ? "Key inválida." : "");
    }
  }

  setInterval(tickAges, 1000);
  // Red de seguridad por si el SSE se cae sin avisar.
  setInterval(() => { if ($("live").checked && !document.hidden) refresh(); }, 15000);

  boot(false);
})();
