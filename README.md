# 🥚 SAE HUB

A relay between the **reporter** (which scans Roblox servers) and the **auto
joiner** (which hops to the server where a good egg just appeared), with a live
web dashboard.

Node.js, zero dependencies, ready for Railway.

```
REPORTER  ──POST /api/report──▶  HUB  ──POST /api/claim──▶  AUTO JOINER
(scans zones)                     │                        (hops to the server)
                                  └──▶ Dashboard (live over SSE)
```

## Layout

| File | What it does |
|---|---|
| `server.js` | HTTP server: API, static files, SSE |
| `lib/store.js` | In-memory state: servers, eggs, claims, activity log |
| `lib/rarity.js` | The game's real rarity ladder (Common → Titan) |
| `public/index.html` · `app.js` · `styles.css` | Dashboard |
| `scripts/ESP_v9.lua` | Reporter: **one scan, one report**, zone eggs only |
| `scripts/AJ_v5.lua` | Auto joiner: new UI, mobile and PC |
| `Dockerfile` · `railway.json` | Deployment |

Everything the user sees is in English. Internal identifiers (`x-eag-key`, the
hub's file names) are deliberately unchanged so existing deployments keep
working.

## Deploying on Railway

1. **New Project → Deploy from GitHub repo** → this repo.
2. Root Directory: empty (`/`).
3. Variable `API_KEY` = a long random key.
4. Settings → Networking → **Generate Domain**. That URL is your `HUB_URL`.

Optional variables: `PUBLIC_READ` (true = dashboard without a key),
`SERVER_TTL_SEC` (480), `CLAIM_TTL_SEC` (240).

Locally:

```bash
API_KEY=test node server.js   # http://localhost:3000
```

## Configuring the scripts

In the **reporter** (HUB tab) and the **auto joiner** (SETTINGS tab), set the
same `HUB_URL` and the same `API_KEY`.

---

## How the reporter works

Four steps, in this order, never getting ahead of itself:

1. **Wait** for the server to finish loading. It does not scan to find that out
   — it listens to the egg container's `ChildAdded`. While models keep arriving
   the server is still loading; once it has been quiet for 2.5 s it is ready.
2. **One scan.** Just one.
3. **Send** that result in a single report, with `full=true`.
4. **Only then, hop.**

It adapts on its own, with no magic numbers:

```
SCENARIO                        READY AT   MODELS   SCAN PASSES
fast load                       3.9s       5        1
dripping in over 8s             10.8s      5        1
12 eggs dripping in over 15s    17.7s      12       1
models fast, records slow       14.1s      3        1
very slow (30s)                 32.7s      3        1
```

If zone models are present and none of them resolve, nothing is sent — an empty
`full=true` would tell the hub the server is clean and wipe a good earlier
report. After three such servers in a row it stops hopping: at that point the
fault is not the server.

A heartbeat resends the identical payload every 2 minutes, because the hub
forgets a server after `SERVER_TTL_SEC` without a signal. Same uids, so it
creates no eggs, changes no rarity and does not reset any age.

### Only zone eggs are ever sent

A hard rule, not a toggle: if an egg does not come from `AreaEggSlotsClient`, it
reaches neither the webhook nor the hub. A single function decides, and both
send paths go through it. The remaining toggle only affects what is drawn on
screen.

Each egg also carries its real **zone** (Forest, Volcano, Snow, Abyss Ocean,
Titan Temple…), resolved against `Workspace.__OBJECTS.Areas.GuardAreas`.

### Rarity resolution

The lookup is broad but **deterministic**: priority fields in a fixed order,
then the display name, and finally the remaining fields only if they all agree.
A collision is judged on whether two records *disagree* on the asset, not on
whether they are the same table — the game returns the same egg from two
different reads, and comparing by identity nulled the key and resolved nothing
at all.

Anything not resolved with certainty is left out rather than sent with the wrong
rarity. The **DIAGNOSTICS** tab reports module load state, model and record
counts, per-egg rejection reasons, and the field names of a real record.

---

## How the auto joiner works

- Freshness is decided by **MAX AGE**, not by when you pressed the button.
  Finds older than that stay visible in the list, tagged `stale`, and auto join
  skips them — you can still join one yourself with ▶.
- Joining raises a **JOINING <egg>** banner in the egg's rarity colour. It lives
  outside the panel, so it shows even when the panel is closed.
- On landing, the GUI shows **IN THE SERVER** with the egg that brought you
  there. The handover file carries the whole egg, so it survives the teleport.
- The panel scales itself to the viewport, and on touch devices a draggable
  floating button opens it — mobile has no Right Control.

When there is nothing to join it says why, via `POST /api/diag`:

| Situation | What you see |
|---|---|
| Nobody reporting | «no reporter is sending» |
| Servers with no eggs | «the servers are empty (3 reporting)» |
| Rarity filter wrong | «your rarities do not exist in the game» → **SELECT THE RARE ONES** |
| Everything behind the cursor | «2 before cursor» → **ACCEPT CURRENT ONES** |
| Rarity not selected | «3 rarity not selected» → **GO TO FILTERS** |

`/api/diag` and `/api/claim` share the same judges (`serverReject` /
`eggReject`) on purpose: if they drifted, the diagnosis would lie exactly when
it is needed most.

---

## API

| Method | Route | Who | What it does |
|---|---|---|---|
| POST | `/api/report` | Reporter | Upload eggs. `full:true` = complete snapshot |
| GET | `/api/feed` | Dashboard / AJ | Filtered list (long-poll with `wait=20`) |
| POST | `/api/claim` | AJ | Request a target and lock its server |
| POST | `/api/release` | AJ | Release a claim |
| POST | `/api/hop` | AJ | Report whether the teleport worked |
| GET | `/api/meta` | Everyone | Stats, rarity ladder, `eggSeq` cursor |
| GET | `/api/servers` | Dashboard | Servers in detail |
| GET | `/api/events` | Dashboard | Timestamped activity log |
| POST | `/api/diag` | AJ | Why a filter returns nothing |
| GET | `/api/stream` | Dashboard | Live SSE |
| POST | `/api/purge` | Admin | Wipe everything |
| GET | `/healthz` | Railway | Health check |

### Filters for `/api/feed` and `/api/claim`

By query string (GET) or in the JSON body (POST):

| Filter | Example | What it does |
|---|---|---|
| `rarities` | `Cosmic,Titan` | Only these rarities |
| `minKg` / `maxKg` | `25` / `9000` | Weight range |
| `minRank` | `7` | Minimum rarity by rank (7 = Cosmic) |
| `sinceSeq` | `1420` | Only eggs discovered after this cursor |
| `maxAgeSec` | `90` | Drop finds older than this |
| `hasSlot` | `1` | Only servers with a free slot |
| `maxPlayers` | `4` | Servers with at most N players |
| `exclude` | `job1,job2` | Ignore these servers |
| `wait` | `20` | Long-poll: wait up to N s for something to appear |

Auth: header `x-eag-key`, `x-api-key`, `Authorization: Bearer …` or `?key=`.
Writing always requires the key; reading does too, unless `PUBLIC_READ=true`.

---

## The rarity ladder is the game's own

The hub used to know only `Common…Divine`. Real rarities such as **Cosmic,
Eternal, Exotic, Titan, Squishy God, Rainbow** did not exist in the list, so
they could not be filtered on and sorted *below* Common — a 52,000 kg Titan
appeared under a Chicken Egg.

`lib/rarity.js` now mirrors the game's `RarityNumber` table (1 → 11) with its
colours. The hub, the dashboard and both scripts read that one ladder, so they
always agree. The auto joiner also ships it built in, so the filter chips still
render when the hub is unreachable.

## Notes

Everything lives in memory: if Railway restarts the container the feed empties
and refills within seconds on the reporter's next report.

A hub URL ending in `/` used to produce `//api/meta`, which Node reads as a
protocol-relative URL — it took `api` for the host and returned a 404 that
looked like the hub was down. The server now collapses repeated slashes before
routing, and the scripts normalise the URL on every request.
