# 🥚 SAE HUB

A relay between the **reporter** (which scans Roblox servers) and the **auto
joiner** (which hops to the server where a good egg just appeared), with a live
web dashboard.

Node.js, zero dependencies, ready for Railway.

```
                     ┌─ scrapes games.roblox.com through rotating proxies
                     ▼
                JOB ID POOL ──GET /api/pool/server──▶ any bot that needs a server
                     │
REPORTER  ──POST /api/report──▶  HUB  ──POST /api/claim──▶  AUTO JOINER
(scans zones)                     │                        (hops to the server)
                                  └──▶ Console (live over SSE)
```

## Layout

| File | What it does |
|---|---|
| `server.js` | HTTP server: API, static files, SSE |
| `lib/store.js` | In-memory state: servers, eggs, claims, clients, activity log |
| `lib/fetcher.js` | Job-id pool: scrapes Roblox through proxies and dispenses servers |
| `lib/rarity.js` | The game's real rarity ladder (Common → Titan) |
| `public/index.html` · `app.js` · `styles.css` | Operations console |
| `scripts/ESP_v9.lua` | Reporter: **one scan, one report**, zone eggs only |
| `scripts/AJ_v5.lua` | Auto joiner: new UI, mobile and PC |
| `Dockerfile` · `railway.json` | Deployment |
| `tools/check-luau.sh` | Compiles both scripts with the real Luau compiler |

Everything the user sees is in English. Internal identifiers (`x-eag-key`, the
hub's file names) are deliberately unchanged so existing deployments keep
working.

## Deploying on Railway

1. **New Project → Deploy from GitHub repo** → this repo.
2. Root Directory: empty (`/`).
3. Variable `API_KEY` = a long random key.
4. Settings → Networking → **Generate Domain**. That URL is your `HUB_URL`.

Optional variables: `PUBLIC_READ` (true = dashboard without a key),
`SERVER_TTL_SEC` (480), `CLAIM_TTL_SEC` (240), and for the job-id pool
`GAME_ID` (107778070777162), `PROXIES`, `SCRAPER_WORKERS` (10),
`MAX_CONCURRENT_REQUESTS` (5), `FETCHER_ENABLED` (1). See `.env.example`.

Locally:

```bash
API_KEY=test node server.js   # http://localhost:3000
```

## Running the scripts

Nothing to configure. The hub serves both scripts with its own URL and key
already filled in, so one loader line is the whole setup:

```lua
-- reporter
loadstring(game:HttpGet("https://YOUR-HUB.up.railway.app/script/reporter.lua?key=YOUR_KEY"))()

-- auto joiner
loadstring(game:HttpGet("https://YOUR-HUB.up.railway.app/script/joiner.lua?key=YOUR_KEY"))()
```

`/script/` requires the key, like every write path — the copy it hands back
carries the key in clear, so it must not be world-readable.

The Dockerfile has to copy `scripts/`. It did not at first, so the route existed
and answered 401 without a key but 404 with one: the files simply were not in the
image. The boot log now prints `scripts served: reporter.lua, joiner.lua`, or
`NONE — scripts/ missing from the image`, and the 404 body says which of the two
it is. The repo files hold
only `__SAE_HUB_URL__` and `__SAE_API_KEY__` placeholders, which is why no real
key is ever committed.

That same URL is what the reporter re-queues on teleport, so the sweep keeps
going with no separate "raw script URL" to keep in sync. Anything you type in
the panel still overrides the baked-in values and is remembered; a blank saved
value no longer wipes them.

## The scripts are checked with Luau, not with Lua

Roblox runs **Luau**, not Lua 5.4, and the two are not the same language.
`luac5.4 -p` accepted a `goto continue` / `::continue::` pair in the reporter's
retry loop; Luau has no `goto` and no labels, so Roblox refused to compile the
chunk, `loadstring` returned `nil`, and the loader died on its second line with
*attempt to call a nil value* — with the joiner working fine, because it had no
`goto`.

```
                      luac5.4 -p     luau-compile
reporter (before)     accepted       SyntaxError at 760 and 776
reporter (after)      accepted       compiled
```

The loop now uses a `delivered` flag, which both dialects accept, and
`tools/check-luau.sh` runs the real compiler over `scripts/`.

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

### Hopping is always on

There is no switch. Reporting one server and stopping there is not useful, so
the hop is simply the last step of the cycle.

The teleport kills the client, so the reporter queues itself to run again on
arrival, loading from `<hub>/script/reporter.lua`. Without that the sweep would
report exactly one server and end.

### Finding servers

The old search only knew one way to get a server: walk
`games.roblox.com/.../servers/Public` from page 1. Measuring that endpoint
changed most of what this code does.

| What was measured | Result |
|---|---|
| How deep the walk goes on a mid-sized place | ~220 servers over **3 pages**, then no `nextPageCursor` |
| What throttling looks like | HTTP **200** with `{"errors":[…]}` and no `data` |
| How fast the list churns | about **10 new servers a minute** |
| `sortOrder=Desc` instead of `Asc` | 196 of 221 servers were the same — not worth a second walk |
| Forging a cursor to jump to a random offset | rejected, the cursor is signed |
| A saved cursor reused later | still valid after **10 minutes**, and returned **0** of page 1's servers |

Two of those are why it ran out of servers:

- **A throttle was read as "this game has no servers left."** The code broke
  out of the page loop on a reply with no `data`, which is exactly what being
  rate limited returns. It then escalated through four levels — up to 80 more
  requests — into the throttle that had just started, and concluded there was
  nothing to hop to.
- **Every hop restarted at page 1.** The teleport kills the client, so the pool
  and the cursor died with it. Each new life re-read the same first hundred
  servers, all of them already visited.

So the cursor is now saved next to the visited list and the sweep resumes where
it stopped, pages are spaced out instead of bursted, `excludeFullGames=true`
does the filtering server-side, an expired cursor restarts the walk instead of
ending it, and a throttle stops the sweep at one request rather than eighty.

### And a second way in, when the list gives nothing

`TeleportService:Teleport` asks Roblox's own matchmaker for a server instead of
naming one. It does not read the server list, so it cannot be throttled by it
and cannot run out. It costs control — the matchmaker may hand back a server
already visited — so it is the fallback, not the rule.

Measured over a simulated two-hour session, against an endpoint that throttles
and churns the way the real one does:

```
                                         hops  distinct servers  list empty  stalled
big game, 8% of servers quiet
  before                                  263        93              20       8 min
  after                                   271       271               0       0
big game, 2% quiet
  before                                  188        24              80      33 min
  after                                   272       272               0       0
busy game, 220 servers visible
  before                                  288       288               0       0
  after                                   287       287               0       0
Roblox API barely answering (3 calls/min)
  before                                   48        11             192      80 min
  after                                   288       283               0       0   (all via matchmaking)
```

The last row is the fallback doing its job: 288 hops on 290 API calls, instead
of 48 hops on 1,199 calls spent arguing with a throttle.

Shortening the visited list's three-hour lifetime was tried and measured
**worse** — the sweep starts re-reporting servers it has already covered (231
distinct in two hours instead of 287) — so it stayed at three hours.

Failures back off (4s → 60s) instead of retrying at a flat 4s forever.

### The send is checked, not assumed

A dropped request used to lose a whole server silently, and nothing verified
that the hub had kept what was sent. The reporter now retries up to three times
and reads `stored` back to confirm the count matches:

```
the hub stores all 5          attempts=1  ok     5 eggs · stored 5 ✓
fails twice, third succeeds   attempts=3  ok     5 eggs · stored 5 ✓
hub only stored 3 of 5        attempts=3  fail   gave up: hub kept 3 of 5
fails every time              attempts=3  fail   gave up: 500
reply unreadable              attempts=1  ok     (not resent — would duplicate)
```

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

## The job-id pool

Roblox rate-limits its server list **per IP**. Forty bots each asking Roblox
directly get all forty throttled — which is exactly what the reporter's own
hop kept running into. So one process does the asking, spreading it over a pool
of proxies, and the bots ask *this* hub for a job id that is already cached.

`lib/fetcher.js` tracks game `107778070777162` by default (`GAME_ID`).

### The ideas that make it work

**The pool is RAM, not a database.** `jobId → {playing, maxPlayers, lastSeen}`.
A restart starts empty and refills in seconds. The information is only true for
minutes, so persisting it would buy nothing and complicate the deploy.

**Dispensing is not deleting.** A job id handed to a bot is marked `dispensed`
but stays in the pool. After `RECYCLE_SEC` the bot has either used it or given
up, so it becomes available again. That is what stops two bots being sent to the
same server without constant re-scraping.

**One proxy per request.** Proxies are consumed round-robin from a shuffled
copy, never starting a new round on the proxy that just went out. With sticky
proxies each line is a distinct exit IP, so more lines means more real
parallelism rather than one IP going faster.

**Two concurrency limits, two different problems.** `AGENT_MAX_SOCKETS` caps
connections through *one* proxy, so a single saturated gateway stops dropping
sockets. `MAX_CONCURRENT_REQUESTS` caps requests in flight across the whole
process — that is what protects the proxy *account*, because exceeding a plan's
concurrent-session limit arrives as a wave of 502s and TLS resets. More proxies
do not fix that; the queue does.

**Adaptive backoff, not a fixed delay.** The gap between requests starts at
100ms and climbs to 10s on a 429, a network error or a 5xx, then eases back down
while the scrape is healthy. A healthy account settles at the floor; an
exhausted one backs off on its own instead of retrying flat out. Measured on one
IP with no proxies: the delay climbed 100 → 960ms over nine 429s and stopped
making things worse, instead of hammering at full speed.

**A response timeout is not enough.** It only starts counting once the
connection is up. A dead HTTPS proxy hangs during the CONNECT handshake, where
that timer never starts, and the request sits there for ever holding a
concurrency slot. There are two guards: one on the CONNECT itself, and a hard
abort that destroys the request whatever phase it is stuck in.

**Pagination stops early.** Each cycle walks up to ten pages of 100. If a whole
page brings nothing new, the cycle ends there — paging on would spend proxy
traffic re-reading what we already hold.

### Ported to zero dependencies

The original ran on `express` + `axios` + `https-proxy-agent`. This hub ships
with no dependencies and its `Dockerfile` never runs an install, so adding three
would have broken the deploy the moment it was pushed. The logic is the same on
node built-ins: an `https.Agent` subclass that tunnels via the proxy's `CONNECT`
verb replaces `https-proxy-agent`, `https.request` replaces `axios`, and the
hub's own router replaces `express`.

### Pool routes

Canonical paths are under `/api/pool/`. The bare names the standalone fetcher
used are kept as aliases, so a bot written against it runs here with only its
host changed.

| Method | Route | Alias | What it does |
|---|---|---|---|
| GET | `/api/pool/server?size=N&max=P` | `/server` | Dispense N job ids, emptiest first |
| POST | `/api/pool/remove` | `/remove` | Body `{jobid}` — drop a dead one, get a replacement in the same trip |
| GET | `/api/pool/servers` | `/servers` | Everything cached, with its state |
| GET | `/api/pool/stats` | `/stats` | Pool, scraper and proxy health |
| GET | `/api/pool/logs` | — | The scraper's log (also live over SSE) |
| POST | `/api/pool/recycle` | `/recycle` | Free every dispensed id whose window has passed |
| POST·DELETE | `/api/pool/clear` | `/clear` | Throw the pool away |

`/server` answers `text/plain`, one job id per line — what the Lua side parses
with a single pattern match. Add `&format=json` for the full record.

`max` is a preference, not a wall: if it leaves too few candidates the filter is
relaxed rather than failing, because a server slightly fuller than asked for
beats no server at all. The response says `relaxed: true` when that happened.

Taking a job id **needs the key even though it is a GET** — it mutates the pool
and spends a scarce resource. `PUBLIC_READ=true` opens the egg feed; it
deliberately does not open the dispenser.

```lua
-- what a bot does
local resp = request({ Url = HUB .. "/api/pool/server?size=1&max=3&key=" .. KEY,
                       Method = "GET", Headers = { username = "bot_1" } })
local jobId = resp.Body:match("[^\r\n]+")
TeleportService:TeleportToPlaceInstance(game.PlaceId, jobId, LocalPlayer)

-- teleport failed? drop it and get the next one in one round trip
local r2 = request({ Url = HUB .. "/api/pool/remove?max=3&key=" .. KEY, Method = "POST",
                     Headers = { username = "bot_1", ["Content-Type"] = "application/json" },
                     Body = HttpService:JSONEncode({ jobid = jobId }) })
local nextJobId = HttpService:JSONDecode(r2.Body).new_jobid
```

### Proxies

`proxies.txt`, one per line, `#` comments allowed. It is **committed to git**
in this repo, so it can be edited straight from GitHub — this only belongs in
a **private** repo, since anyone who can read a public one can read this file,
credentials included.

Accepted per line:

```
user:pass@host:port        host:port:user:pass
user:pass:host:port        http://user:pass@host:port        host:port
```

The `PROXIES` env var (comma or newline separated) is also supported and
**wins over the file** if both are set — useful for a fork that wants to keep
`proxies.txt` empty and configure proxies per Railway environment instead. If
you edit `proxies.txt` and nothing changes, check that `PROXIES` is not also
set and silently overriding it.

A line that cannot be parsed is dropped at load rather than failing later on
every request that happens to draw it. With none configured the scraper still
runs, but clamped to two workers and going out from this host's own IP, and it
says so in the log — Roblox throttles that within seconds.

---

## The console

Six views, reachable with keys `1`–`6`, `/` to focus the current view's search.

| View | What it answers |
|---|---|
| **Overview** | Is the scrape healthy? Pool composition, request rate, throttle and concurrency meters, per-worker state, live tape |
| **Eggs** | The filtered feed — rarity chips, weight, age, claim state |
| **Pool** | Every job id, its population, whether it is fresh / ready / out (with a recycle countdown) |
| **Servers** | Who is reporting, and their best egg |
| **Clients** | Every reporter, auto joiner and pool client, what it has done, and whether it is still there |
| **Logs** | The scraper's tape, filterable by level and text |

The throttle and concurrency meters exist because the two failure modes look
identical from outside: a climbing delay means Roblox is pushing back, while a
queued-request count means the proxy-account limit is doing its job. The console
says which.

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
| GET | `/api/clients` | Dashboard | Connected reporters, auto joiners and pool clients |
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
