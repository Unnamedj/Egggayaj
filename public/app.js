(() => {
  "use strict";

  const RARITY_COLORS = {
    common: "#9aa4bd",
    uncommon: "#5ad07a",
    rare: "#4aa3ff",
    epic: "#b06bff",
    legendary: "#ffb020",
    mythic: "#ff5470",
    mythical: "#ff5470",
    secret: "#22d3ee",
    divine: "#fff07c",
    unknown: "#6b7280",
  };
  const colorFor = (r) => RARITY_COLORS[String(r || "").toLowerCase()] || RARITY_COLORS.unknown;

  const $ = (id) => document.getElementById(id);
  const state = {
    key: localStorage.getItem("eag.key") || "",
    rarities: new Set(JSON.parse(localStorage.getItem("eag.rarities") || "[]")),
    eggs: [],
    servers: [],
    meta: null,
    es: null,
    seen: new Set(),
    recent: [],
    tab: "eggs",
  };

  // ------------------------------------------------------------------ api
  async function api(path, opts) {
    const o = Object.assign({ headers: {} }, opts || {});
    if (state.key) o.headers["x-eag-key"] = state.key;
    const res = await fetch(path, o);
    if (res.status === 401) throw new Error("401");
    return res.json();
  }

  // ----------------------------------------------------------------- gate
  function showGate(msg) {
    $("gate").classList.remove("hidden");
    $("gateErr").textContent = msg || "";
    $("gateKey").focus();
  }
  function hideGate() {
    $("gate").classList.add("hidden");
  }

  $("gateBtn").onclick = async () => {
    state.key = $("gateKey").value.trim();
    localStorage.setItem("eag.key", state.key);
    boot(true);
  };
  $("gateKey").addEventListener("keydown", (e) => {
    if (e.key === "Enter") $("gateBtn").click();
  });
  $("btnLogout").onclick = () => {
    localStorage.removeItem("eag.key");
    state.key = "";
    if (state.es) state.es.close();
    showGate("");
  };

  // --------------------------------------------------------------- filters
  function buildChips() {
    const list = (state.meta && state.meta.rarities) || ["Common", "Rare", "Legendary"];
    const box = $("rarityChips");
    box.innerHTML = "";
    list.forEach((r) => {
      const el = document.createElement("div");
      el.className = "chip" + (state.rarities.has(r.toLowerCase()) ? " on" : "");
      el.textContent = r;
      const c = colorFor(r);
      el.style.borderColor = state.rarities.has(r.toLowerCase()) ? "transparent" : c + "55";
      if (state.rarities.has(r.toLowerCase())) el.style.background = c;
      else el.style.color = c;
      el.onclick = () => {
        const k = r.toLowerCase();
        if (state.rarities.has(k)) state.rarities.delete(k);
        else state.rarities.add(k);
        localStorage.setItem("eag.rarities", JSON.stringify([...state.rarities]));
        buildChips();
        refresh();
      };
      box.appendChild(el);
    });
  }

  function query() {
    const p = new URLSearchParams();
    if (state.rarities.size) p.set("rarities", [...state.rarities].join(","));
    const min = Number($("minKg").value);
    if (min > 0) p.set("minKg", String(min));
    const max = Number($("maxKg").value);
    if (max > 0) p.set("maxKg", String(max));
    p.set("limit", "300");
    return p;
  }

  // ---------------------------------------------------------------- render
  function ago(ms) {
    const s = Math.floor(ms / 1000);
    if (s < 60) return s + "s";
    if (s < 3600) return Math.floor(s / 60) + "m";
    return Math.floor(s / 3600) + "h";
  }

  function renderEggs() {
    const term = $("search").value.trim().toLowerCase();
    const onlyFree = $("onlyFree").checked;
    const rows = state.eggs.filter((e) => {
      if (onlyFree && e.claimed) return false;
      if (!term) return true;
      return (e.name + " " + (e.species || "") + " " + (e.petName || "")).toLowerCase().includes(term);
    });

    $("kMatch").textContent = rows.length;
    $("empty").style.display = rows.length ? "none" : "block";

    const box = $("rows");
    box.innerHTML = "";
    rows.slice(0, 300).forEach((e) => {
      const div = document.createElement("div");
      div.className = "row" + (state.seen.has(e.uid) ? "" : " new");
      state.seen.add(e.uid);
      const c = colorFor(e.rarity);
      const meta = [
        e.petName,
        e.source === "zone" ? "Zona" : e.source === "base" ? "Base" : null,
        e.earn ? e.earn + "/s" : null,
        e.growth ? "⏱ " + e.growth : null,
      ]
        .filter(Boolean)
        .join(" · ");

      div.innerHTML = `
        <div>
          <div class="egg-name"><i class="dotc" style="background:${c}"></i>${esc(e.name)}</div>
          ${meta ? `<div class="meta">${esc(meta)}</div>` : ""}
        </div>
        <div><span class="tag" style="background:${c}">${esc(e.rarity)}</span></div>
        <div class="kg" style="color:${c}">${e.kg} kg</div>
        <div>
          <div class="job" title="${esc(e.jobId)}">${esc(e.jobId)}</div>
          <div class="meta">${e.players || "?"}/${e.maxPlayers || "?"} jugadores</div>
        </div>
        <div class="age">${ago(e.ageMs)}</div>
        <div class="acts">
          ${e.claimed ? '<span class="badge">claim</span>' : ""}
          <button class="mini ghost" data-a="job" title="Copiar Job ID">⧉</button>
          <button class="mini go" data-a="join" title="Copiar comando de join">▶</button>
        </div>`;

      const flash = (btn, txt) => {
        const old = btn.textContent;
        btn.textContent = txt;
        setTimeout(() => (btn.textContent = old), 1100);
      };
      div.querySelector('[data-a="job"]').onclick = (ev) => {
        navigator.clipboard.writeText(e.jobId);
        flash(ev.target, "✓");
      };
      div.querySelector('[data-a="join"]').onclick = (ev) => {
        navigator.clipboard.writeText(
          `Roblox.GameLauncher.joinGameInstance(${e.placeId || 0}, "${e.jobId}")`
        );
        flash(ev.target, "✓");
      };
      box.appendChild(div);
    });
  }

  function renderServers() {
    const box = $("srows");
    box.innerHTML = "";
    state.servers.forEach((s) => {
      const div = document.createElement("div");
      div.className = "row srv";
      div.innerHTML = `
        <div class="job" title="${esc(s.jobId)}">${esc(s.jobId)}</div>
        <div>${s.players}/${s.maxPlayers || "?"}</div>
        <div class="kg">${s.eggs}</div>
        <div class="age">${ago(s.staleMs)}</div>
        <div>${s.claimed ? '<span class="badge">claim</span>' : '<span class="age">libre</span>'}</div>`;
      box.appendChild(div);
    });
  }

  function renderDist() {
    const by = (state.meta && state.meta.byRarity) || {};
    const entries = Object.entries(by).sort((a, b) => b[1] - a[1]);
    const max = Math.max(1, ...entries.map((e) => e[1]));
    $("dist").innerHTML = entries
      .map(([r, n]) => {
        const c = colorFor(r);
        return `<div class="dist-row"><span style="color:${c}">${esc(r)}</span>
          <div class="bar"><i style="width:${(n / max) * 100}%;background:${c}"></i></div>
          <b>${n}</b></div>`;
      })
      .join("") || '<span class="age">sin datos aún</span>';
  }

  function esc(s) {
    return String(s == null ? "" : s).replace(/[&<>"]/g, (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c])
    );
  }

  // ---------------------------------------------------------------- fetch
  let busy = false;
  async function refresh() {
    if (busy) return;
    busy = true;
    try {
      const [feed, meta] = await Promise.all([
        api("/api/feed?" + query().toString()),
        api("/api/meta"),
      ]);
      state.eggs = feed.eggs || [];
      state.meta = meta;
      $("kServers").textContent = meta.servers;
      $("kEggs").textContent = meta.eggs;
      $("kClaims").textContent = meta.claims;
      const mins = Math.max(1, meta.uptimeMs / 60000);
      $("kRate").textContent = (meta.stats.eggsNew / mins).toFixed(1);
      if (!$("rarityChips").children.length) buildChips();
      renderEggs();
      renderDist();
      if (state.tab === "servers") {
        const s = await api("/api/servers");
        state.servers = s.servers || [];
        renderServers();
      }
      setConn(true);
    } catch (e) {
      if (String(e.message) === "401") return showGate("Key inválida.");
      setConn(false);
    } finally {
      busy = false;
    }
  }

  function setConn(ok) {
    const p = $("connPill");
    p.classList.toggle("on", ok);
    p.classList.toggle("off", !ok);
    p.querySelector("span").textContent = ok ? "en vivo" : "sin conexión";
  }

  // ------------------------------------------------------------------ sse
  function connectStream() {
    if (state.es) state.es.close();
    const u = "/api/stream" + (state.key ? "?key=" + encodeURIComponent(state.key) : "");
    const es = new EventSource(u);
    state.es = es;
    es.addEventListener("hello", () => setConn(true));
    es.addEventListener("eggs", () => refresh());
    es.addEventListener("claim", () => refresh());
    es.addEventListener("release", () => refresh());
    es.onerror = () => setConn(false);
  }

  // ----------------------------------------------------------------- tabs
  document.querySelectorAll(".tab").forEach((t) => {
    t.onclick = () => {
      document.querySelectorAll(".tab").forEach((x) => x.classList.remove("active"));
      t.classList.add("active");
      state.tab = t.dataset.tab;
      $("tab-eggs").classList.toggle("hidden", state.tab !== "eggs");
      $("tab-servers").classList.toggle("hidden", state.tab !== "servers");
      refresh();
    };
  });

  ["minKg", "maxKg", "search", "onlyFree"].forEach((id) => {
    $(id).addEventListener("input", () => {
      clearTimeout(window.__t);
      window.__t = setTimeout(refresh, 250);
    });
  });

  $("btnCopy").onclick = () => {
    navigator.clipboard.writeText(location.origin);
    $("btnCopy").textContent = "✓ copiado";
    setTimeout(() => ($("btnCopy").textContent = "Copiar URL base"), 1200);
  };

  // ----------------------------------------------------------------- boot
  async function boot(fromGate) {
    $("ajUrl").textContent = location.origin;
    try {
      const meta = await api("/api/meta");
      state.meta = meta;
      hideGate();
      buildChips();
      connectStream();
      await refresh();
      setInterval(() => {
        if ($("autoScroll").checked) refresh();
      }, 5000);
    } catch (e) {
      showGate(fromGate ? "Key inválida." : "");
    }
  }

  boot(false);
})();
