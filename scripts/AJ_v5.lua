--[[ ─────────────────────────────────────────────────────────────────────────
     SAE · AUTO JOINER  v5   ·   by joszz
     Panel: Right Control (PC)  ·  floating button (mobile)

     The interface is the same instrument panel as the hub's web console:
     near-black ground, ONE amber accent, and colour reserved for state —
     green alive, amber busy, red wrong. Numbers and job ids are monospace so
     columns line up and an id can be read character by character. Radii stay
     small; a tool that watches servers should look machined, not inflated.

     Why a left rail instead of the old top tabs: the readout belongs across
     the top, where it can be read without opening anything, and a vertical
     rail takes a fifth tab without shrinking the other four.

     Behaviour that has not changed, and must not:
       · Stale finds ARE shown, tagged, but auto join will not go for them.
         You can still join them yourself with ▶.
       · The hop banner lives outside the panel, so it shows even when closed.
       · On landing, IN THE SERVER shows the egg that brought you here. It
         survives the teleport through a file on disk.
     ───────────────────────────────────────────────────────────────────────── ]]

-- The hub fills these in when it serves the script, so a fresh run needs no
-- typing. They stay as the literal placeholders only if you loaded the file
-- straight from the repo instead of from the hub.
local HUB_URL_DEFAULT = "__SAE_HUB_URL__"
local API_KEY_DEFAULT = "__SAE_API_KEY__"
local function baked(v) return (not v:match("^__SAE_")) and v or "" end

local CFG = {
    HUB        = baked(HUB_URL_DEFAULT),
    KEY        = baked(API_KEY_DEFAULT),
    CLIENT     = "sae-1",
    POLL       = 4,
    WAIT       = 20,
    COOLDOWN   = 8,
    MIN_KG     = 0,
    MAX_KG     = 0,
    MAX_AGE    = 120,      -- s. Older than this: still shown, never auto-joined
    RARITIES   = { "Legendary", "Mythic", "Cosmic", "Secret", "Exotic",
                   "Eternal", "Divine", "Titan" },
    HAS_SLOT   = true,
    ONLY_NEW   = false,
    _schema    = 3,
}

-- ────────────────────────────────────────────────────────────────── services
local Players = game:GetService("Players")
local TPS     = game:GetService("TeleportService")
local UIS     = game:GetService("UserInputService")
local TS      = game:GetService("TweenService")
local HS      = game:GetService("HttpService")
local RS      = game:GetService("RunService")
local LP      = Players.LocalPlayer

local httpreq = (syn and syn.request) or (fluxus and fluxus.request)
    or http_request or request or (http and http.request)

local IS_TOUCH = UIS.TouchEnabled and not UIS.KeyboardEnabled

-- ─────────────────────────────────────────────────────────────────── palette
-- The hub console's palette, to the byte. One product, one look.
local C = {
    bg     = Color3.fromRGB(10, 11, 13),
    panel  = Color3.fromRGB(16, 18, 22),
    raise  = Color3.fromRGB(21, 24, 30),
    line   = Color3.fromRGB(31, 36, 45),
    line2  = Color3.fromRGB(42, 49, 60),
    txt    = Color3.fromRGB(233, 236, 241),
    dim    = Color3.fromRGB(147, 156, 171),
    faint  = Color3.fromRGB(95, 104, 117),
    amber  = Color3.fromRGB(240, 160, 42),
    green  = Color3.fromRGB(78, 201, 160),
    cyan   = Color3.fromRGB(85, 185, 224),
    red    = Color3.fromRGB(239, 95, 86),
    ink    = Color3.fromRGB(10, 11, 13),
    white  = Color3.fromRGB(255, 255, 255),
}
local MONO = Enum.Font.Code

local function hex(h)
    h = tostring(h or ""):gsub("#", "")
    if #h ~= 6 then return C.faint end
    return Color3.fromRGB(
        tonumber(h:sub(1,2),16) or 120,
        tonumber(h:sub(3,4),16) or 120,
        tonumber(h:sub(5,6),16) or 120)
end

local FALLBACK_LADDER = {
    { name="Titan",       rank=11, color="#ff5252" },
    { name="Divine",      rank=10, color="#f5e63d" },
    { name="Superior",    rank=10, color="#c3ffff" },
    { name="Eternal",     rank=9,  color="#ff35ee" },
    { name="Limited",     rank=9,  color="#c08bff" },
    { name="Secret",      rank=8,  color="#aab2c0" },
    { name="Exotic",      rank=8,  color="#ff3df2" },
    { name="Cosmic",      rank=7,  color="#8b5cff" },
    { name="Exclusive",   rank=7,  color="#b47cff" },
    { name="Mythic",      rank=6,  color="#ff4d7d" },
    { name="Rainbow",     rank=6,  color="#ff5cc8" },
    { name="Squishy God", rank=6,  color="#cb4bff" },
    { name="Legendary",   rank=5,  color="#ffa726" },
    { name="Epic",        rank=4,  color="#c471ff" },
    { name="Rare",        rank=3,  color="#3b9bff" },
    { name="Uncommon",    rank=2,  color="#3ddc84" },
    { name="Celestial",   rank=2,  color="#00dd6b" },
    { name="SuperRare",   rank=2,  color="#22d3ee" },
    { name="Common",      rank=1,  color="#9aa3b2" },
}

local ST = {
    connected  = false,
    servers    = 0, eggsLive = 0,
    hops       = 0, fails = 0,
    lastHop    = 0, latency = -1,
    eggSeq     = 0, cursor = nil,
    pool       = nil,   -- job ids the hub has scraped, for the readout
    ladder     = FALLBACK_LADDER, ladderFrom = "local",
    colors     = {},
    candidates = {},
    diag       = nil,
    logs       = {},
    lastErr    = nil,
    inServer   = nil,   -- the egg that landed us here
    seenUids   = {},
}
local autoOn = false

local function rc(r) return ST.colors[tostring(r):lower()] or C.faint end

local function applyLadder(rows, from)
    ST.ladder, ST.ladderFrom, ST.colors = rows, from, {}
    for _, r in ipairs(rows) do ST.colors[tostring(r.name):lower()] = hex(r.color) end
end
applyLadder(FALLBACK_LADDER, "local")

-- ───────────────────────────────────────────────────────────── persistencia
local FILE    = "sae_aj.json"
local PENDING = "sae_aj_pending.json"
local canFile = (writefile and readfile and isfile) ~= nil

local function save()
    if not canFile then return end
    pcall(function() writefile(FILE, HS:JSONEncode(CFG)) end)
end

local function load()
    if not canFile then return end
    -- Also picks up v4 settings so the URL and key are not lost.
    local src = isfile(FILE) and FILE or (isfile("eag_aj_v4.json") and "eag_aj_v4.json") or nil
    if not src then return end
    local migrated = false
    pcall(function()
        local d = HS:JSONDecode(readfile(src))
        local schema = tonumber(d._schema) or 1
        for k, v in pairs(d) do
            -- A saved blank must not wipe what the hub baked in.
            if CFG[k] ~= nil and not ((k == "HUB" or k == "KEY") and v == "") then
                CFG[k] = v
            end
        end
        if schema < 2 then CFG.ONLY_NEW = false; migrated = true end
        if schema < 3 then CFG._schema = 3; migrated = true end
    end)
    if migrated or src ~= FILE then save() end
end
load()

-- ─────────────────────────────────────────────────────────────────────── http
local function hubBase()
    local u = tostring(CFG.HUB or ""):gsub("%s+", "")
    u = u:gsub("/+$", ""):gsub("/api$", "")
    if u ~= "" and not u:match("^https?://") then u = "https://" .. u end
    return u
end

local function httpJson(method, path, body)
    if not httpreq then return nil, "the executor has no request()" end
    local base = hubBase()
    if base == "" then return nil, "hub URL is missing (SETTINGS)" end
    local opts = {
        Url = base .. path, Method = method,
        Headers = { ["Content-Type"] = "application/json", ["x-eag-key"] = CFG.KEY },
    }
    if body then opts.Body = HS:JSONEncode(body) end
    local ok, res = pcall(httpreq, opts)
    if not ok then return nil, "no network" end
    local code = res.StatusCode or res.Status or 0
    if code == 401 then return nil, "wrong API key" end
    if code == 404 then return nil, "404 · check the hub URL" end
    if code < 200 or code >= 300 then return nil, "HTTP " .. tostring(code) end
    local dok, dec = pcall(function() return HS:JSONDecode(res.Body) end)
    if not dok then return nil, "unreadable response" end
    if type(dec) == "table" and tonumber(dec.eggSeq) then ST.eggSeq = tonumber(dec.eggSeq) end
    return dec
end

-- The base filter. `forJoin` adds the age cut-off: the list shows EVERYTHING,
-- while auto join only goes for what is fresh.
local function filterBody(forJoin)
    local b = { client = CFG.CLIENT, minKg = tonumber(CFG.MIN_KG) or 0, hasSlot = CFG.HAS_SLOT }
    if #CFG.RARITIES > 0 then b.rarities = CFG.RARITIES end
    if (tonumber(CFG.MAX_KG) or 0) > 0 then b.maxKg = CFG.MAX_KG end
    if forJoin and (tonumber(CFG.MAX_AGE) or 0) > 0 then b.maxAgeSec = CFG.MAX_AGE end
    if forJoin and CFG.ONLY_NEW and ST.cursor then b.sinceSeq = ST.cursor end
    if game.JobId ~= "" then b.exclude = { game.JobId } end
    return b
end

local function isStale(e)
    local maxAge = tonumber(CFG.MAX_AGE) or 0
    if maxAge <= 0 then return false end
    return (tonumber(e.ageMs) or 0) > maxAge * 1000
end

-- ───────────────────────────────────────────────────────────────── UI helpers
local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end
local function corner(o, r) mk("UICorner", { CornerRadius = UDim.new(0, r or 4) }, o) end
local function round(o)     mk("UICorner", { CornerRadius = UDim.new(1, 0) }, o) end
local function stroke(o, col, tr, th)
    return mk("UIStroke", { Color = col or C.line, Transparency = tr or 0, Thickness = th or 1 }, o)
end
local function pad(o, l, r, t, b)
    mk("UIPadding", {
        PaddingLeft = UDim.new(0, l or 0), PaddingRight = UDim.new(0, r or 0),
        PaddingTop = UDim.new(0, t or 0), PaddingBottom = UDim.new(0, b or 0),
    }, o)
end
-- A 1px rule. Used instead of borders so a panel can be divided without
-- boxing every region in.
local function rule(parent, x, y, w, h, col)
    return mk("Frame", {
        Position = UDim2.new(0,x,0,y), Size = UDim2.new(w[1], w[2], h[1], h[2]),
        BackgroundColor3 = col or C.line, BorderSizePixel = 0,
    }, parent)
end

local EASE = {
    out  = TweenInfo.new(0.20, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    fast = TweenInfo.new(0.12, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out),
    back = TweenInfo.new(0.34, Enum.EasingStyle.Back,  Enum.EasingDirection.Out),
    soft = TweenInfo.new(0.30, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
}
local function tw(obj, info, props)
    local t = TS:Create(obj, info or EASE.out, props)
    t:Play()
    return t
end

-- Press bounce. Gives a tactile feel, which matters most on mobile.
local function pressable(btn, scaleDown)
    local s = mk("UIScale", { Scale = 1 }, btn)
    local down = scaleDown or 0.95
    local function press() tw(s, EASE.fast, { Scale = down }) end
    local function release() tw(s, EASE.back, { Scale = 1 }) end
    btn.MouseButton1Down:Connect(press)
    btn.MouseButton1Up:Connect(release)
    btn.MouseLeave:Connect(release)
    btn.TouchLongPress:Connect(press)
    return s
end

local function label(parent, text, x, y, w, h, size, col, font)
    return mk("TextLabel", {
        Position = UDim2.new(0,x,0,y), Size = UDim2.new(0,w,0,h),
        BackgroundTransparency = 1, Font = font or Enum.Font.Gotham, TextSize = size or 12,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = col or C.dim, Text = text,
    }, parent)
end
-- Micro-caps. Chrome, not content: small, faint, always upper case.
local function caption(parent, text, x, y, w)
    return mk("TextLabel", {
        Position = UDim2.new(0,x,0,y), Size = UDim2.new(0,w,0,13),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.faint,
        Text = tostring(text):upper(),
    }, parent)
end

local function ago(ms)
    local s = math.max(0, math.floor((tonumber(ms) or 0) / 1000))
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s/60) .. "m " .. (s % 60) .. "s" end
    return math.floor(s/3600) .. "h " .. math.floor((s % 3600)/60) .. "m"
end

local function shortId(id)
    local s = tostring(id or "")
    if #s <= 13 then return s end
    return s:sub(1, 13) .. "…"
end

-- ─────────────────────────────────────────────────────────────────────── root
local gui = mk("ScreenGui", {
    Name = "SAE_AJ", ResetOnSpawn = false, IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
gui.Parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")

-- 632 wide is not arbitrary: minus the 76px rail and 12px gutters it leaves
-- pages exactly 532 wide, which is what they were before the rail existed, so
-- the FILTERS and SETTINGS layouts did not have to be re-measured.
local W, H = 632, 440
local HEADER_H, RAIL_W = 52, 76
local PAGE_X = RAIL_W + 12
local PAGE_W = W - PAGE_X - 12
local PAGE_Y = HEADER_H + 12

local root = mk("Frame", {
    Size = UDim2.new(0, W, 0, H),
    Position = UDim2.new(0.5, -W/2, 0.5, -H/2),
    BackgroundColor3 = C.bg, BorderSizePixel = 0,
    Active = true, Draggable = true,
}, gui)
corner(root, 6)
stroke(root, C.line, 0)

-- The panel shrinks to fit any screen, mobile included, without having to
-- maintain two separate layouts.
local uiScale = mk("UIScale", { Scale = 1 }, root)
local function fitViewport()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local vp = cam.ViewportSize
    if vp.X < 10 then return end
    local s = math.min(1, (vp.X - 20) / W, (vp.Y - 20) / H)
    uiScale.Scale = math.max(0.5, s)
end
fitViewport()
task.spawn(function()
    local cam = workspace.CurrentCamera
    if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(fitViewport) end
end)

-- ── header ────────────────────────────────────────────────────────────────
local header = mk("Frame", { Size = UDim2.new(1,0,0,HEADER_H), BackgroundTransparency = 1 }, root)
rule(header, 0, HEADER_H - 1, {1,0}, {0,1})

label(header, "SAE·AJ", 16, 11, 90, 14, 12.5, C.txt, Enum.Font.GothamBold)
local subLbl = label(header, "connecting to the hub", 16, 27, 210, 12, 10, C.faint, MONO)

-- connection pill
-- Just the state. The egg count used to live here too and did not fit in the
-- pill; it is a number, so it belongs in the readout with the other numbers.
local connPill = mk("Frame", {
    Position = UDim2.new(0,232,0,15), Size = UDim2.new(0,74,0,22),
    BackgroundTransparency = 1, BorderSizePixel = 0,
}, header)
corner(connPill, 3)
local connStroke = stroke(connPill, C.line, 0)
local connDot = mk("Frame", {
    Position = UDim2.new(0,9,0,8), Size = UDim2.new(0,6,0,6),
    BackgroundColor3 = C.amber, BorderSizePixel = 0,
}, connPill)
round(connDot)
local connLbl = mk("TextLabel", {
    Position = UDim2.new(0,21,0,0), Size = UDim2.new(1,-27,1,0),
    BackgroundTransparency = 1, Font = MONO, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.dim, Text = "connecting",
}, connPill)

-- Heartbeat on the dot: reads as alive and costs nothing.
task.spawn(function()
    while connDot.Parent do
        tw(connDot, TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
            { BackgroundTransparency = 0.6 })
        task.wait(0.85)
        tw(connDot, TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
            { BackgroundTransparency = 0 })
        task.wait(0.85)
    end
end)

-- Readout. The numbers that matter, always visible, never behind a tab.
local readout = {}
do
    -- The same four the web console leads with. TARGETS is not among them
    -- because the list header already says "N FRESH OF M" right above it.
    local specs = { {"servers","SERVERS"}, {"eggs","EGGS"}, {"hops","HOPS"}, {"pool","POOL"} }
    -- 60 per column is what fits between the connection pill and the close
    -- button without either of them being overlapped.
    local cw = 60
    local x0 = W - 40 - (#specs * cw)
    for i, spec in ipairs(specs) do
        local x = x0 + (i - 1) * cw
        if i > 1 then rule(header, x, 13, {0,1}, {0,26}) end
        readout[spec[1]] = mk("TextLabel", {
            Position = UDim2.new(0,x,0,10), Size = UDim2.new(0,cw-10,0,16),
            BackgroundTransparency = 1, Font = MONO, TextSize = 14,
            TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.txt, Text = "—",
        }, header)
        mk("TextLabel", {
            Position = UDim2.new(0,x,0,28), Size = UDim2.new(0,cw-10,0,10),
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 8,
            TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.faint, Text = spec[2],
        }, header)
    end
end

do
    local close = mk("TextButton", {
        Position = UDim2.new(1,-34,0,15), Size = UDim2.new(0,22,0,22),
        BackgroundTransparency = 1, BorderSizePixel = 0, Text = "✕",
        Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.faint, AutoButtonColor = false,
    }, header)
    corner(close, 3); stroke(close, C.line, 0)
    pressable(close)
    close.MouseEnter:Connect(function() tw(close, EASE.fast, { TextColor3 = C.red }) end)
    close.MouseLeave:Connect(function() tw(close, EASE.fast, { TextColor3 = C.faint }) end)
    close.MouseButton1Click:Connect(function()
        tw(uiScale, EASE.fast, { Scale = uiScale.Scale * 0.95 })
        task.wait(0.12)
        root.Visible = false
        fitViewport()
    end)
end

-- ── rail ──────────────────────────────────────────────────────────────────
local rail = mk("Frame", {
    Position = UDim2.new(0,0,0,HEADER_H), Size = UDim2.new(0,RAIL_W,1,-HEADER_H),
    BackgroundTransparency = 1, BorderSizePixel = 0,
}, root)
rule(rail, RAIL_W - 1, 0, {0,1}, {1,0})

local function newPage()
    return mk("Frame", {
        Position = UDim2.new(0,PAGE_X,0,PAGE_Y), Size = UDim2.new(0,PAGE_W,1,-(PAGE_Y+12)),
        BackgroundTransparency = 1, Visible = false,
    }, root)
end
local pgHunt, pgFilter, pgConfig, pgLog = newPage(), newPage(), newPage(), newPage()
local pages = { hunt = pgHunt, filter = pgFilter, config = pgConfig, log = pgLog }
local order = { "hunt", "filter", "config", "log" }

local NAV_H, NAV_Y0 = 40, 12
-- A hard amber edge marks the active section. It reads instantly in
-- peripheral vision, which is how a nav rail actually gets used.
local navMark = mk("Frame", {
    Position = UDim2.new(0,0,0,NAV_Y0+6), Size = UDim2.new(0,2,0,NAV_H-12),
    BackgroundColor3 = C.amber, BorderSizePixel = 0,
}, rail)

local navBtns, navNums, navLbls, selectTab = {}, {}, {}, nil
local function mkNav(i, key, text, tip)
    local y = NAV_Y0 + (i - 1) * NAV_H
    local b = mk("TextButton", {
        Position = UDim2.new(0,8,0,y), Size = UDim2.new(0,RAIL_W-17,0,NAV_H-4),
        BackgroundColor3 = C.raise, BackgroundTransparency = 1,
        BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, rail)
    corner(b, 3)
    navBtns[key] = b
    navNums[key] = label(b, tostring(i), 8, 5, 16, 10, 8.5, C.line2, MONO)
    navLbls[key] = label(b, text, 8, 16, RAIL_W-30, 13, 10.5, C.faint, Enum.Font.GothamBold)
    b.MouseButton1Click:Connect(function() selectTab(key) end)
    b.MouseEnter:Connect(function()
        subLbl.Text = tip
        if navLbls[key].TextColor3 ~= C.txt then
            tw(b, EASE.fast, { BackgroundTransparency = 0.55 })
        end
    end)
    b.MouseLeave:Connect(function()
        if navLbls[key].TextColor3 ~= C.txt then
            tw(b, EASE.fast, { BackgroundTransparency = 1 })
        end
    end)
    return b
end
mkNav(1, "hunt",   "Hunt",     "live targets and auto join")
mkNav(2, "filter", "Filters",  "rarity, weight and freshness")
mkNav(3, "config", "Config",   "hub connection and pacing")
mkNav(4, "log",    "Log",      "activity log")

selectTab = function(key)
    for i, k in ipairs(order) do
        local on = (k == key)
        local p = pages[k]
        if on then
            tw(navMark, EASE.out, {
                Position = UDim2.new(0, 0, 0, NAV_Y0 + (i - 1) * NAV_H + 6),
            })
            p.Visible = true
            p.Position = UDim2.new(0, PAGE_X, 0, PAGE_Y + 6)
            tw(p, EASE.out, { Position = UDim2.new(0, PAGE_X, 0, PAGE_Y) })
        else
            p.Visible = false
        end
        tw(navBtns[k], EASE.fast, { BackgroundTransparency = on and 0 or 1 })
        tw(navLbls[k], EASE.fast, { TextColor3 = on and C.txt or C.faint })
        tw(navNums[k], EASE.fast, { TextColor3 = on and C.amber or C.line2 })
    end
end

-- ───────────────────────────────────────────────────────────────── hop banner
-- Lives outside the panel: visible even when the panel is closed.
local banner = mk("Frame", {
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, -80),
    Size = UDim2.new(0, 320, 0, 54),
    BackgroundColor3 = C.panel, BorderSizePixel = 0, Visible = false,
}, gui)
corner(banner, 5)
local bannerStroke = stroke(banner, C.amber, 0.3, 1)
local bannerScale = mk("UIScale", { Scale = 1 }, banner)

local bannerBar = mk("Frame", {
    Position = UDim2.new(0,0,0,0), Size = UDim2.new(0,3,1,0),
    BackgroundColor3 = C.amber, BorderSizePixel = 0,
}, banner)
label(banner, "JOINING", 16, 9, 200, 12, 9, C.amber, Enum.Font.GothamBold)
local bannerName  = label(banner, "", 16, 23, 200, 18, 13.5, C.txt, Enum.Font.GothamBold)
bannerName.TextTruncate = Enum.TextTruncate.AtEnd
local bannerTag = mk("TextLabel", {
    Position = UDim2.new(1,-108,0,18), Size = UDim2.new(0,94,0,20),
    BackgroundTransparency = 1, Font = MONO, TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.faint, Text = "",
}, banner)

-- A bar that drains: signals the teleport is under way.
local bannerProg = mk("Frame", {
    Position = UDim2.new(0,0,1,-2), Size = UDim2.new(1,0,0,2),
    BackgroundColor3 = C.amber, BorderSizePixel = 0,
}, banner)

local bannerToken = 0
local function showBanner(target)
    bannerToken = bannerToken + 1
    local myToken = bannerToken
    local col = rc(target.rarity)

    bannerName.Text = tostring(target.name or "?")
    bannerTag.Text = ("%s · %s kg"):format(
        tostring(target.rarity or "?"),
        tostring(math.floor(tonumber(target.kg) or 0)))
    bannerTag.TextColor3 = col
    bannerBar.BackgroundColor3 = col
    bannerProg.BackgroundColor3 = col
    bannerStroke.Color = col

    banner.Visible = true
    banner.Position = UDim2.new(0.5, 0, 0, -80)
    bannerScale.Scale = 0.94
    bannerProg.Size = UDim2.new(1, 0, 0, 2)
    tw(banner, EASE.back, { Position = UDim2.new(0.5, 0, 0, 14) })
    tw(bannerScale, EASE.back, { Scale = 1 })
    tw(bannerProg, TweenInfo.new(4.2, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 2) })

    task.delay(4.4, function()
        if bannerToken ~= myToken then return end
        tw(banner, EASE.soft, { Position = UDim2.new(0.5, 0, 0, -80) })
        tw(bannerScale, EASE.soft, { Scale = 0.94 })
        task.wait(0.32)
        if bannerToken == myToken then banner.Visible = false end
    end)
end

-- ───────────────────────────────────────────────────────────────────────── log
local logList, renderLog
local function pushLog(txt, col)
    table.insert(ST.logs, 1, { t = os.date("%H:%M:%S"), s = txt, c = col or C.faint })
    if #ST.logs > 120 then table.remove(ST.logs) end
    print("[SAE-AJ]", txt)
    if renderLog then renderLog() end
end

-- ─────────────────────────────────────────────────────────────────── teleport
local function reportHop(jobId, ok, reason)
    task.spawn(function()
        httpJson("POST", "/api/hop", { jobId = jobId, ok = ok, client = CFG.CLIENT, reason = reason or "" })
    end)
end

local layoutHunt   -- defined with the HUNT page
local paintInServer

local function doHop(target)
    if not target or not target.jobId then return end
    if target.jobId == game.JobId then
        pushLog("you are already on that server", C.amber)
        return
    end
    ST.lastHop = os.clock()
    ST.hops = ST.hops + 1
    if tonumber(target.seq) then ST.cursor = math.max(ST.cursor or 0, tonumber(target.seq)) end

    showBanner(target)
    pushLog(("hop -> %s · %s %s kg"):format(
        tostring(target.name), tostring(target.rarity),
        tostring(math.floor(tonumber(target.kg) or 0))), C.cyan)

    -- The whole egg is stored, not just the jobId: on landing the GUI needs to
    -- know WHY it came here in order to show IN THE SERVER.
    if canFile then
        pcall(function()
            writefile(PENDING, HS:JSONEncode({
                jobId = target.jobId, at = os.time(),
                name = target.name, rarity = target.rarity,
                kg = target.kg, area = target.area, uid = target.uid,
            }))
        end)
    end
    -- Re-queue itself from the hub it is already pointing at, so there is no
    -- separate script URL to keep in sync.
    local qt = queue_on_teleport or (syn and syn.queue_on_teleport)
    local base = hubBase()
    if qt and base ~= "" then
        pcall(qt, ('loadstring(game:HttpGet("%s/script/joiner.lua?key=%s"))()')
            :format(base, HS:UrlEncode(CFG.KEY)))
    end

    local placeId = tonumber(target.placeId) or game.PlaceId
    local ok, err = pcall(function()
        TPS:TeleportToPlaceInstance(placeId, target.jobId, LP)
    end)
    if not ok then
        ST.fails = ST.fails + 1
        pushLog("teleport failed: " .. tostring(err), C.red)
        reportHop(target.jobId, false, tostring(err))
    end
end

TPS.TeleportInitFailed:Connect(function(_, result, msg)
    ST.fails = ST.fails + 1
    pushLog("teleport rejected: " .. tostring(msg), C.red)
    if canFile and isfile(PENDING) then
        pcall(function()
            local t = HS:JSONDecode(readfile(PENDING))
            reportHop(t.jobId, false, tostring(result))
            if delfile then delfile(PENDING) end
        end)
    end
end)

-- ═══════════════════════════════════════════════════════════════════════ HUNT
-- IN THE SERVER: the egg that landed us here.
local inCard = mk("Frame", {
    Size = UDim2.new(1,0,0,42), BackgroundColor3 = C.panel,
    BorderSizePixel = 0, Visible = false,
}, pgHunt)
corner(inCard, 4)
local inStroke = stroke(inCard, C.green, 0.4)
local inBar = mk("Frame", {
    Position = UDim2.new(0,0,0,0), Size = UDim2.new(0,3,1,0),
    BackgroundColor3 = C.green, BorderSizePixel = 0,
}, inCard)
local inTitle = label(inCard, "IN THE SERVER", 14, 7, 160, 12, 9, C.green, Enum.Font.GothamBold)
local inName  = label(inCard, "", 14, 21, 300, 15, 12.5, C.txt, Enum.Font.GothamMedium)
inName.TextTruncate = Enum.TextTruncate.AtEnd
local inTag = mk("TextLabel", {
    Position = UDim2.new(1,-158,0,12), Size = UDim2.new(0,146,0,18),
    BackgroundTransparency = 1, Font = MONO, TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.faint, Text = "",
}, inCard)

-- auto join switch
local topRow = mk("Frame", { Size = UDim2.new(1,0,0,48), BackgroundTransparency = 1 }, pgHunt)

local autoCard = mk("Frame", {
    Size = UDim2.new(1,0,0,48), BackgroundColor3 = C.panel, BorderSizePixel = 0,
}, topRow)
corner(autoCard, 4)
local autoStroke = stroke(autoCard, C.line, 0)
label(autoCard, "AUTO JOIN", 14, 10, 170, 13, 10, C.txt, Enum.Font.GothamBold)
local autoSub = mk("TextLabel", {
    Position = UDim2.new(0,14,0,26), Size = UDim2.new(1,-90,0,14),
    BackgroundTransparency = 1, Font = MONO, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextColor3 = C.faint, TextTruncate = Enum.TextTruncate.AtEnd, Text = "paused",
}, autoCard)

local sw = mk("TextButton", {
    Position = UDim2.new(1,-62,0,13), Size = UDim2.new(0,48,0,22),
    BackgroundColor3 = C.raise, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
}, autoCard)
corner(sw, 3)
local swStroke = stroke(sw, C.line, 0)
local knob = mk("Frame", {
    Position = UDim2.new(0,3,0,3), Size = UDim2.new(0,16,0,16),
    BackgroundColor3 = C.faint, BorderSizePixel = 0,
}, sw)
corner(knob, 2)

local function paintAuto()
    tw(knob, EASE.back, {
        Position = autoOn and UDim2.new(0,29,0,3) or UDim2.new(0,3,0,3),
        BackgroundColor3 = autoOn and C.ink or C.faint,
    })
    tw(sw, EASE.out, { BackgroundColor3 = autoOn and C.green or C.raise })
    tw(autoStroke, EASE.out, { Color = autoOn and C.green or C.line, Transparency = autoOn and 0.5 or 0 })
    swStroke.Transparency = autoOn and 1 or 0
    autoSub.Text = autoOn and "looking for fresh targets" or "paused"
    tw(autoSub, EASE.fast, { TextColor3 = autoOn and C.green or C.faint })
end

sw.MouseButton1Click:Connect(function()
    autoOn = not autoOn
    if autoOn and CFG.ONLY_NEW then ST.cursor = ST.eggSeq end
    pushLog(autoOn and "auto join ON" or "auto join paused", autoOn and C.green or C.faint)
    paintAuto()
end)
pressable(sw, 0.96)

-- diagnostics banner
local diagCard = mk("Frame", {
    Size = UDim2.new(1,0,0,42), BackgroundColor3 = C.panel,
    BorderSizePixel = 0, Visible = false,
}, pgHunt)
corner(diagCard, 4)
local diagStroke = stroke(diagCard, C.amber, 0.4)
local diagBar = mk("Frame", {
    Position = UDim2.new(0,0,0,0), Size = UDim2.new(0,3,1,0),
    BackgroundColor3 = C.amber, BorderSizePixel = 0,
}, diagCard)
local diagTitle = label(diagCard, "", 14, 7, 380, 13, 10.5, C.amber, Enum.Font.GothamBold)
local diagBody = mk("TextLabel", {
    Position = UDim2.new(0,14,0,22), Size = UDim2.new(1,-170,0,14),
    BackgroundTransparency = 1, Font = MONO, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.dim,
    TextTruncate = Enum.TextTruncate.AtEnd, Text = "",
}, diagCard)
local diagBtn = mk("TextButton", {
    Position = UDim2.new(1,-150,0,10), Size = UDim2.new(0,138,0,22),
    BackgroundColor3 = C.raise, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
    TextSize = 9.5, TextColor3 = C.dim, Text = "", AutoButtonColor = false, Visible = false,
}, diagCard)
corner(diagBtn, 3); stroke(diagBtn, C.line2, 0); pressable(diagBtn)
local diagAction = nil
diagBtn.MouseButton1Click:Connect(function() if diagAction then diagAction() end end)

local listLabel = caption(pgHunt, "LIVE TARGETS", 2, 0, 260)
local list = mk("ScrollingFrame", {
    Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = C.line2,
    CanvasSize = UDim2.new(0,0,0,0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
}, pgHunt)
mk("UIListLayout", { Padding = UDim.new(0,4), SortOrder = Enum.SortOrder.LayoutOrder }, list)

local emptyLbl = mk("TextLabel", {
    Size = UDim2.new(1,0,0,48), BackgroundTransparency = 1,
    Font = MONO, TextSize = 11, TextColor3 = C.faint, TextWrapped = true,
    Text = "no targets",
}, list)

-- The top cards come and go, so the list repositions itself.
layoutHunt = function(animate)
    local y = 0
    local function place(obj, h)
        if not obj.Visible then return end
        local target = UDim2.new(0, 0, 0, y)
        if animate then tw(obj, EASE.out, { Position = target }) else obj.Position = target end
        y = y + h
    end
    place(inCard, 48)
    place(topRow, 54)
    place(diagCard, 48)
    listLabel.Position = UDim2.new(0, 2, 0, y)
    y = y + 16
    local pos, size = UDim2.new(0,0,0,y), UDim2.new(1,0,1,-y)
    if animate then
        tw(list, EASE.out, { Position = pos, Size = size })
    else
        list.Position, list.Size = pos, size
    end
end

paintInServer = function()
    local s = ST.inServer
    inCard.Visible = (s ~= nil)
    if s then
        local col = rc(s.rarity)
        inName.Text = tostring(s.name or "?")
        inTag.Text = ("%s · %s kg"):format(
            tostring(s.rarity or "?"), tostring(math.floor(tonumber(s.kg) or 0)))
        inTag.TextColor3 = col
        inBar.BackgroundColor3 = col
        inStroke.Color = col
        inTitle.TextColor3 = col
    end
    layoutHunt(true)
end

-- On start: did we arrive from a hop? Then show IN THE SERVER.
task.spawn(function()
    if canFile and isfile(PENDING) then
        local ok, t = pcall(function() return HS:JSONDecode(readfile(PENDING)) end)
        if ok and t and t.jobId then
            local landed = (t.jobId == game.JobId)
            reportHop(t.jobId, landed, landed and "ok" or "landed on a different server")
            if landed then
                ST.inServer = {
                    name = t.name, rarity = t.rarity, kg = t.kg,
                    area = t.area, uid = t.uid, at = t.at,
                }
                pushLog(("landing confirmed · %s"):format(tostring(t.name or "?")), C.green)
                task.wait(0.4)
                pcall(paintInServer)
            else
                pushLog("landed on a different server", C.amber)
            end
        end
        pcall(function() if delfile then delfile(PENDING) end end)
    end
end)

local function buildRow(e, i, isNew)
    local stale = isStale(e)
    local col = rc(e.rarity)
    local row = mk("Frame", {
        Size = UDim2.new(1,-4,0,44), BackgroundColor3 = C.panel,
        BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = i,
    }, list)
    corner(row, 4)
    local rs = stroke(row, C.line, 1)

    mk("Frame", {
        Position = UDim2.new(0,0,0,0), Size = UDim2.new(0,2,1,0),
        BackgroundColor3 = col, BorderSizePixel = 0, BackgroundTransparency = stale and 0.5 or 0,
    }, row)

    -- The right block is measured first so the name can be clipped exactly
    -- before it, never under it.
    local RIGHT = 258

    local nameLbl = label(row, tostring(e.name), 13, 5, 100, 16, 12.5,
        stale and C.dim or C.txt, Enum.Font.GothamMedium)
    nameLbl.TextTruncate = Enum.TextTruncate.AtEnd
    nameLbl.Size = UDim2.new(1, -(RIGHT + 18), 0, 16)

    -- The job id is on screen now, not hidden behind the copy button: it is
    -- what you check against the hub console when something looks wrong.
    local sub = ("%s · %s · %s/%s · %s"):format(
        shortId(e.jobId),
        (e.area ~= nil and e.area ~= "" and e.area or "zone"),
        tostring(e.players or "?"), tostring(e.maxPlayers or "?"), ago(e.ageMs))
    local subLblRow = label(row, sub, 13, 23, 100, 14, 10, C.faint, MONO)
    subLblRow.TextTruncate = Enum.TextTruncate.AtEnd
    subLblRow.Size = UDim2.new(1, -(RIGHT + 18), 0, 14)

    -- state badge (only one can apply at a time in practice; stale wins)
    if stale or e.claimed then
        local txt = stale and "STALE" or "IN USE"
        local bcol = stale and C.faint or C.amber
        local bg = mk("Frame", {
            Position = UDim2.new(1,-RIGHT,0,12), Size = UDim2.new(0,52,0,20),
            BackgroundTransparency = 1, BorderSizePixel = 0,
        }, row)
        corner(bg, 3); stroke(bg, bcol, 0.55)
        mk("TextLabel", {
            Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold, TextSize = 9, TextColor3 = bcol, Text = txt,
        }, bg)
    end

    local tag = mk("Frame", {
        Position = UDim2.new(1,-(RIGHT-58),0,12), Size = UDim2.new(0,80,0,20),
        BackgroundColor3 = col, BorderSizePixel = 0,
        BackgroundTransparency = stale and 0.86 or 0,
    }, row)
    corner(tag, 3)
    mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 9.5,
        TextColor3 = stale and col or C.ink,
        Text = tostring(e.rarity):upper(),
    }, tag)

    mk("TextLabel", {
        Position = UDim2.new(1,-116,0,12), Size = UDim2.new(0,54,0,20),
        BackgroundTransparency = 1, Font = MONO, TextSize = 12.5,
        TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = col,
        Text = ("%s kg"):format(tostring(math.floor((tonumber(e.kg) or 0) + 0.5))),
    }, row)

    local cp = mk("TextButton", {
        Position = UDim2.new(1,-58,0,12), Size = UDim2.new(0,24,0,20),
        BackgroundTransparency = 1, BorderSizePixel = 0, Text = "⧉",
        Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.faint, AutoButtonColor = false,
    }, row)
    corner(cp, 3); stroke(cp, C.line2, 0); pressable(cp)
    cp.MouseEnter:Connect(function() tw(cp, EASE.fast, { TextColor3 = C.txt }) end)
    cp.MouseLeave:Connect(function() tw(cp, EASE.fast, { TextColor3 = C.faint }) end)
    cp.MouseButton1Click:Connect(function()
        local set = setclipboard or toclipboard or (syn and syn.write_clipboard)
        if set then pcall(set, tostring(e.jobId)); pushLog("job id copied", C.faint) end
    end)

    local join = mk("TextButton", {
        Position = UDim2.new(1,-30,0,12), Size = UDim2.new(0,26,0,20),
        BackgroundColor3 = C.amber, BorderSizePixel = 0, Text = "▶",
        Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.ink,
        AutoButtonColor = false,
    }, row)
    corner(join, 3); pressable(join, 0.9)
    join.MouseButton1Click:Connect(function() doHop(e) end)

    row.MouseEnter:Connect(function()
        tw(row, EASE.fast, { BackgroundTransparency = 0 })
        tw(rs, EASE.fast, { Color = C.line2, Transparency = 0 })
    end)
    row.MouseLeave:Connect(function()
        tw(row, EASE.fast, { BackgroundTransparency = stale and 0.5 or 0.25 })
        tw(rs, EASE.fast, { Color = C.line, Transparency = 0 })
    end)

    -- The list repaints every poll, so only genuinely new rows animate: else
    -- everything cascaded in every 4 seconds and it was dizzying.
    local restTr = stale and 0.5 or 0.25
    if isNew then
        task.delay(math.min(i, 12) * 0.025, function()
            if not row.Parent then return end
            tw(row, EASE.out, { BackgroundTransparency = restTr })
            tw(rs, EASE.out, { Transparency = 0 })
            -- one sweep in the rarity colour, then it settles
            local flash = mk("Frame", {
                Size = UDim2.new(1,0,1,0), BackgroundColor3 = col,
                BackgroundTransparency = 0.82, BorderSizePixel = 0, ZIndex = 0,
            }, row)
            corner(flash, 4)
            tw(flash, TweenInfo.new(0.9, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
                { BackgroundTransparency = 1 })
            task.delay(1.0, function() if flash and flash.Parent then flash:Destroy() end end)
        end)
    else
        row.BackgroundTransparency = restTr
        rs.Transparency = 0
    end

    return row
end

local function paintDiag()
    local d = ST.diag
    diagAction = nil
    diagBtn.Visible = false

    local function show(title, body, col, btnText, action)
        diagCard.Visible = true
        diagTitle.Text = title
        diagBody.Text = body
        diagTitle.TextColor3 = col
        diagBar.BackgroundColor3 = col
        diagStroke.Color = col
        if btnText then
            diagBtn.Text = btnText
            diagBtn.Visible = true
            diagAction = action
        end
    end

    if #ST.candidates > 0 then
        diagCard.Visible = false
        layoutHunt(true)
        return
    end
    emptyLbl.Visible = true

    if not ST.connected then
        show("no connection to the hub", tostring(ST.lastErr or "not responding"), C.red)
        emptyLbl.Text = "check the URL and API key under CONFIG"
        layoutHunt(true); return
    end
    if not d then
        diagCard.Visible = false
        emptyLbl.Text = "asking the hub…"
        layoutHunt(true); return
    end
    if (tonumber(d.passed) or 0) > 0 then
        diagCard.Visible = false
        emptyLbl.Text = ("%d target(s) available · claiming…"):format(d.passed)
        layoutHunt(true); return
    end
    if d.servers == 0 then
        show("no reporter is sending", "the hub is empty", C.amber)
        emptyLbl.Text = "waiting for a reporter to upload eggs"
        layoutHunt(true); return
    end
    if d.rarityFilterUnknown then
        show("your rarities do not exist in the game",
            "none of them match the real list", C.red,
            "SELECT THE RARE ONES", function()
                CFG.RARITIES = {}
                for _, r in ipairs(ST.ladder) do
                    if (tonumber(r.rank) or 0) >= 5 then table.insert(CFG.RARITIES, r.name) end
                end
                save()
                pushLog("rarity filter rebuilt", C.green)
            end)
        emptyLbl.Text = "fix the rarity filter"
        layoutHunt(true); return
    end
    if d.total == 0 then
        show("the servers are empty",
            ("%d reporting, 0 eggs right now"):format(d.servers), C.amber)
        emptyLbl.Text = "waiting for eggs"
        layoutHunt(true); return
    end
    if d.top then
        local bits = {}
        for reason, n in pairs(d.drops or {}) do bits[#bits+1] = ("%d %s"):format(n, reason) end
        table.sort(bits)
        local btnText, action
        if d.top.reason == "rarity not selected" then
            btnText, action = "GO TO FILTERS", function() selectTab("filter") end
        elseif d.top.reason == "before cursor" then
            btnText, action = "ACCEPT CURRENT ONES", function()
                ST.cursor = 0
                pushLog("cursor reset to zero", C.amber)
            end
        end
        show(("%d eggs in the hub, none match"):format(d.total),
            table.concat(bits, "  ·  "), C.amber, btnText, action)
        emptyLbl.Text = "adjust the filters or wait for a find"
        layoutHunt(true); return
    end
    diagCard.Visible = false
    emptyLbl.Text = "no targets"
    layoutHunt(true)
end

local function renderList()
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    emptyLbl.Visible = (#ST.candidates == 0)

    local fresh = 0
    for i, e in ipairs(ST.candidates) do
        if i <= 30 then
            local isNew = not ST.seenUids[e.uid]
            ST.seenUids[e.uid] = true
            buildRow(e, i, isNew)
        end
        if not isStale(e) then fresh = fresh + 1 end
    end

    listLabel.Text = (#ST.candidates > 0)
        and ("LIVE TARGETS   ·   %d FRESH OF %d"):format(fresh, #ST.candidates)
        or "LIVE TARGETS"
    paintDiag()
end

-- ═════════════════════════════════════════════════════════════════════ FILTERS
local function field(parent, lbl, x, y, w, value, onChange)
    caption(parent, lbl, x + 2, y, w)
    local box = mk("TextBox", {
        Position = UDim2.new(0,x,0,y+15), Size = UDim2.new(0,w,0,28),
        BackgroundColor3 = C.bg, BorderSizePixel = 0,
        Font = MONO, TextSize = 11.5, TextColor3 = C.txt,
        TextXAlignment = Enum.TextXAlignment.Left,
        ClearTextOnFocus = false, Text = tostring(value),
    }, parent)
    corner(box, 3); pad(box, 9, 9)
    local s = stroke(box, C.line2, 0)
    box.Focused:Connect(function()
        tw(s, EASE.fast, { Color = C.amber, Transparency = 0 })
    end)
    box.FocusLost:Connect(function()
        tw(s, EASE.fast, { Color = C.line2, Transparency = 0 })
        onChange(box.Text); save()
    end)
    return box
end

local function toggleRow(parent, x, y, w, text, get, set)
    local b = mk("TextButton", {
        Position = UDim2.new(0,x,0,y), Size = UDim2.new(0,w,0,30),
        BackgroundTransparency = 1, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, parent)
    corner(b, 3); pressable(b, 0.985)
    local s = stroke(b, C.line, 0)
    local mark = mk("Frame", {
        Position = UDim2.new(0,10,0,9), Size = UDim2.new(0,12,0,12),
        BackgroundColor3 = C.raise, BorderSizePixel = 0,
    }, b)
    corner(mark, 2)
    local ms = stroke(mark, C.line2, 0)
    local tick = mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 9, TextColor3 = C.ink, Text = "✓",
    }, mark)
    local lbl = label(b, text, 30, 0, w - 40, 30, 10.5, C.dim)
    lbl.TextYAlignment = Enum.TextYAlignment.Center
    local function paint()
        local on = get()
        tick.Visible = on
        tw(mark, EASE.fast, { BackgroundColor3 = on and C.green or C.raise })
        tw(ms, EASE.fast, { Color = on and C.green or C.line2 })
        tw(lbl, EASE.fast, { TextColor3 = on and C.txt or C.faint })
        tw(s, EASE.fast, { Color = on and C.green or C.line, Transparency = on and 0.55 or 0 })
    end
    b.MouseButton1Click:Connect(function() set(not get()); paint(); save() end)
    paint()
    return b
end

caption(pgFilter, "ACCEPTED RARITIES", 2, 0, 220)
local ladderNote = mk("TextLabel", {
    Position = UDim2.new(1,-214,0,0), Size = UDim2.new(0,212,0,13),
    BackgroundTransparency = 1, Font = MONO, TextSize = 9.5,
    TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.amber,
    Text = "", Visible = false,
}, pgFilter)

local chipHolder = mk("ScrollingFrame", {
    Position = UDim2.new(0,0,0,17), Size = UDim2.new(1,0,0,88),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.line2, CanvasSize = UDim2.new(0,0,0,0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
}, pgFilter)
do
    local lay = mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0,4), SortOrder = Enum.SortOrder.LayoutOrder,
    }, chipHolder)
    pcall(function() lay.Wraps = true end)
end

local function hasRarity(r)
    for _, v in ipairs(CFG.RARITIES) do
        if tostring(v):lower() == tostring(r):lower() then return true end
    end
    return false
end

local renderChips
renderChips = function()
    for _, c in ipairs(chipHolder:GetChildren()) do
        if c:IsA("TextButton") then c:Destroy() end
    end
    if ladderNote then
        ladderNote.Visible = (ST.ladderFrom ~= "hub")
        ladderNote.Text = "local list · the hub is not responding"
    end
    for i, r in ipairs(ST.ladder) do
        local on, col = hasRarity(r.name), rc(r.name)
        local b = mk("TextButton", {
            Size = UDim2.new(0, 22 + #r.name * 6.4, 0, 24),
            BackgroundColor3 = col, BackgroundTransparency = on and 0 or 1,
            BorderSizePixel = 0, LayoutOrder = i,
            Font = Enum.Font.GothamBold, TextSize = 10,
            TextColor3 = on and C.ink or col, Text = r.name, AutoButtonColor = false,
        }, chipHolder)
        corner(b, 3); stroke(b, col, on and 1 or 0.5); pressable(b, 0.93)
        b.MouseEnter:Connect(function()
            if not on then tw(b, EASE.fast, { BackgroundTransparency = 0.86 }) end
        end)
        b.MouseLeave:Connect(function()
            if not on then tw(b, EASE.fast, { BackgroundTransparency = 1 }) end
        end)
        b.MouseButton1Click:Connect(function()
            for j, v in ipairs(CFG.RARITIES) do
                if tostring(v):lower() == tostring(r.name):lower() then
                    table.remove(CFG.RARITIES, j); save(); renderChips(); return
                end
            end
            table.insert(CFG.RARITIES, r.name); save(); renderChips()
        end)
    end
end

do
    local y = 110
    local function quick(text, x, w, fn)
        local b = mk("TextButton", {
            Position = UDim2.new(0,x,0,y), Size = UDim2.new(0,w,0,24),
            BackgroundColor3 = C.raise, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
            TextSize = 10, TextColor3 = C.dim, Text = text, AutoButtonColor = false,
        }, pgFilter)
        corner(b, 3); stroke(b, C.line2, 0); pressable(b)
        b.MouseEnter:Connect(function() tw(b, EASE.fast, { TextColor3 = C.txt }) end)
        b.MouseLeave:Connect(function() tw(b, EASE.fast, { TextColor3 = C.dim }) end)
        b.MouseButton1Click:Connect(function() fn(); save(); renderChips() end)
    end
    quick("ALL", 0, 70, function()
        CFG.RARITIES = {}
        for _, r in ipairs(ST.ladder) do table.insert(CFG.RARITIES, r.name) end
    end)
    quick("NONE", 76, 70, function() CFG.RARITIES = {} end)
    quick("RARE ONLY", 152, 86, function()
        CFG.RARITIES = {}
        for _, r in ipairs(ST.ladder) do
            if (tonumber(r.rank) or 0) >= 5 then table.insert(CFG.RARITIES, r.name) end
        end
    end)
end

caption(pgFilter, "WEIGHT AND FRESHNESS", 2, 146, 220)
field(pgFilter, "MIN KG", 0, 162, 124, CFG.MIN_KG, function(v) CFG.MIN_KG = tonumber(v) or 0 end)
field(pgFilter, "MAX KG · 0 = no limit", 134, 162, 166, CFG.MAX_KG, function(v) CFG.MAX_KG = tonumber(v) or 0 end)
field(pgFilter, "MAX AGE (s)", 310, 162, 118, CFG.MAX_AGE, function(v)
    CFG.MAX_AGE = math.max(0, tonumber(v) or 0)
end)

caption(pgFilter, "RULES", 2, 210, 220)
toggleRow(pgFilter, 0, 226, 258, "ignore what was already there on start",
    function() return CFG.ONLY_NEW end,
    function(v) CFG.ONLY_NEW = v; if v then ST.cursor = ST.eggSeq end end)
toggleRow(pgFilter, 266, 226, 258, "only servers with a free slot",
    function() return CFG.HAS_SLOT end,
    function(v) CFG.HAS_SLOT = v end)

mk("TextLabel", {
    Position = UDim2.new(0,2,0,266), Size = UDim2.new(1,-4,0,46),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10.5,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    TextColor3 = C.faint, TextWrapped = true,
    Text = "Finds older than MAX AGE stay visible in the list, tagged STALE, but "
        .. "auto join will not go for them. You can still join them yourself with ▶.",
}, pgFilter)

-- ═════════════════════════════════════════════════════════════════════ CONFIG
caption(pgConfig, "CONNECTION", 2, 0, 220)
field(pgConfig, "HUB URL", 0, 16, 528, CFG.HUB, function(v) CFG.HUB = (v:gsub("%s+",""):gsub("/+$","")) end)
field(pgConfig, "API KEY", 0, 62, 326, CFG.KEY, function(v) CFG.KEY = (v:gsub("%s+","")) end)
field(pgConfig, "NAME OF THIS CLIENT", 336, 62, 192, CFG.CLIENT, function(v) CFG.CLIENT = v end)

caption(pgConfig, "PACING", 2, 112, 220)
field(pgConfig, "POLL (s)", 0, 128, 100, CFG.POLL, function(v) CFG.POLL = math.max(2, tonumber(v) or 4) end)
field(pgConfig, "COOLDOWN (s)", 110, 128, 116, CFG.COOLDOWN, function(v) CFG.COOLDOWN = math.max(3, tonumber(v) or 8) end)
field(pgConfig, "CLAIM WAIT (s)", 236, 128, 190, CFG.WAIT, function(v) CFG.WAIT = math.max(5, math.min(50, tonumber(v) or 20)) end)

do
    local test = mk("TextButton", {
        Position = UDim2.new(0,0,0,188), Size = UDim2.new(0,162,0,30),
        BackgroundColor3 = C.amber, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, pgConfig)
    corner(test, 3); pressable(test)
    local tl = mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 11,
        TextColor3 = C.ink, Text = "TEST CONNECTION",
    }, test)
    test.MouseButton1Click:Connect(function()
        tl.Text = "TESTING…"
        task.spawn(function()
            local res, err = httpJson("GET", "/api/meta")
            tl.Text = res and "CONNECTED ✓" or "NO CONNECTION"
            if res then
                pushLog(("hub ok · %d servers · %d eggs"):format(res.servers or 0, res.eggs or 0), C.green)
            else
                pushLog("hub error: " .. tostring(err), C.red)
            end
            task.delay(2, function() tl.Text = "TEST CONNECTION" end)
        end)
    end)

    mk("TextLabel", {
        Position = UDim2.new(0,174,0,188), Size = UDim2.new(1,-174,0,46),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10.5,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        TextColor3 = C.faint, TextWrapped = true,
        Text = "Each field saves when you leave it. The same API key you set on the hub and the reporter.",
    }, pgConfig)
end

-- ═════════════════════════════════════════════════════════════════════════ LOG
do
    logList = mk("ScrollingFrame", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = C.line2,
        CanvasSize = UDim2.new(0,0,0,0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, pgLog)
    mk("UIListLayout", { Padding = UDim.new(0,1), SortOrder = Enum.SortOrder.LayoutOrder }, logList)

    renderLog = function()
        for _, c in ipairs(logList:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        for i, e in ipairs(ST.logs) do
            if i > 60 then break end
            local row = mk("Frame", {
                Size = UDim2.new(1,-6,0,18), BackgroundTransparency = 1, LayoutOrder = i,
            }, logList)
            mk("Frame", {
                Position = UDim2.new(0,0,0,5), Size = UDim2.new(0,2,0,8),
                BackgroundColor3 = e.c, BorderSizePixel = 0,
            }, row)
            label(row, e.t, 10, 0, 58, 18, 10, C.line2, MONO)
            label(row, e.s, 72, 0, 440, 18, 10.5, e.c, MONO).TextTruncate = Enum.TextTruncate.AtEnd
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════ status
local function paintStatus()
    readout.servers.Text = tostring(ST.servers)
    readout.eggs.Text    = tostring(ST.eggsLive)
    readout.hops.Text    = tostring(ST.hops)
    readout.pool.Text    = ST.pool and tostring(ST.pool) or "—"

    connDot.BackgroundColor3 = ST.connected and C.green or C.red
    connLbl.Text = ST.connected and "live" or "offline"
    connLbl.TextColor3 = ST.connected and C.dim or C.red
    connStroke.Color = ST.connected and C.line or C.red
    connStroke.Transparency = ST.connected and 0 or 0.5

    if not ST.connected then
        subLbl.Text = "hub: " .. tostring(ST.lastErr or "no response")
        subLbl.TextColor3 = C.red
    elseif ST.inServer then
        subLbl.Text = "on the server of " .. tostring(ST.inServer.name or "?")
        subLbl.TextColor3 = C.green
    elseif ST.latency >= 0 then
        subLbl.Text = "last target in " .. ST.latency .. " ms"
        subLbl.TextColor3 = C.faint
    else
        subLbl.Text = "connected · waiting for a target"
        subLbl.TextColor3 = C.faint
    end
end

-- ═══════════════════════════════════════════════════════════════════════ loops
task.spawn(function()
    while true do
        local meta, err = httpJson("GET", "/api/meta")
        if meta then
            if not ST.connected then pushLog("connected to the hub", C.green) end
            ST.connected, ST.lastErr = true, nil
            ST.servers  = meta.servers or 0
            ST.eggsLive = meta.eggs or 0
            -- The hub reports its scraped job-id pool in /api/meta, so the
            -- readout costs no extra request.
            if type(meta.pool) == "table" and type(meta.pool.pool) == "table" then
                ST.pool = tonumber(meta.pool.pool.total)
            end
            if tonumber(meta.eggSeq) then
                ST.eggSeq = tonumber(meta.eggSeq)
                if ST.cursor == nil then ST.cursor = ST.eggSeq end
            end
            if type(meta.ladder) == "table" and #meta.ladder > 0 then
                local changed = (ST.ladderFrom ~= "hub") or (#meta.ladder ~= #ST.ladder)
                applyLadder(meta.ladder, "hub")
                if changed then pcall(renderChips) end
            end
        else
            if ST.connected or ST.lastErr ~= err then pushLog("hub: " .. tostring(err), C.red) end
            ST.connected, ST.lastErr = false, err
        end

        -- The LIST does not filter by age: it also shows stale finds, tagged.
        local q = "?limit=30"
        if #CFG.RARITIES > 0 then q = q .. "&rarities=" .. HS:UrlEncode(table.concat(CFG.RARITIES, ",")) end
        if (tonumber(CFG.MIN_KG) or 0) > 0 then q = q .. "&minKg=" .. tostring(CFG.MIN_KG) end
        if (tonumber(CFG.MAX_KG) or 0) > 0 then q = q .. "&maxKg=" .. tostring(CFG.MAX_KG) end
        if CFG.HAS_SLOT then q = q .. "&hasSlot=1" end

        local feed = httpJson("GET", "/api/feed" .. q)
        if feed and feed.eggs then ST.candidates = feed.eggs end

        if ST.connected and #ST.candidates == 0 then
            ST.diag = httpJson("POST", "/api/diag", filterBody(true))
        else
            ST.diag = nil
        end

        pcall(renderList)
        pcall(paintStatus)
        task.wait(math.max(2, CFG.POLL))
    end
end)

task.spawn(function()
    while true do
        if autoOn and (os.clock() - ST.lastHop) > CFG.COOLDOWN then
            local body = filterBody(true)
            body.wait = math.max(5, CFG.WAIT)
            local res, err = httpJson("POST", "/api/claim", body)
            if res and res.found and res.target then
                ST.latency = tonumber(res.latencyMs) or -1
                doHop(res.target)
            elseif not res then
                if os.clock() - (ST.lastClaimErr or 0) > 20 then
                    ST.lastClaimErr = os.clock()
                    pushLog("claim: " .. tostring(err), C.amber)
                end
            end
        end
        task.wait(1)
    end
end)

-- ══════════════════════════════════════════════════════════════════════ toggle
local function togglePanel()
    if root.Visible then
        tw(uiScale, EASE.fast, { Scale = uiScale.Scale * 0.95 })
        task.wait(0.12)
        root.Visible = false
        fitViewport()
    else
        root.Visible = true
        local s = uiScale.Scale
        uiScale.Scale = s * 0.95
        tw(uiScale, EASE.back, { Scale = s })
    end
end

UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightControl then togglePanel() end
    -- 1-4 jump straight to a section, the same keys the web console uses.
    if not root.Visible then return end
    local n = ({
        [Enum.KeyCode.One] = 1, [Enum.KeyCode.Two] = 2,
        [Enum.KeyCode.Three] = 3, [Enum.KeyCode.Four] = 4,
    })[input.KeyCode]
    if n then selectTab(order[n]) end
end)

-- Floating button: mobile has no Right Control. Draggable so it stays out of
-- the way, and a tap opens the panel.
do
    local fab = mk("TextButton", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 12, 0.5, 0), Size = UDim2.new(0, 44, 0, 44),
        BackgroundColor3 = C.panel, BorderSizePixel = 0, Text = "",
        AutoButtonColor = false, Active = true, Draggable = true,
        Visible = IS_TOUCH,
    }, gui)
    corner(fab, 5)
    stroke(fab, C.amber, 0.35, 1)
    mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 12, TextColor3 = C.amber, Text = "AJ",
    }, fab)
    pressable(fab, 0.9)
    fab.MouseButton1Click:Connect(togglePanel)
end

for _, step in ipairs({
    { "chips",  function() renderChips() end },
    { "tabs",   function() selectTab("hunt") end },
    { "toggle", paintAuto },
    { "layout", function() layoutHunt(false) end },
    { "status", paintStatus },
}) do
    local ok, err = pcall(step[2])
    if not ok then pushLog("failed to draw " .. step[1] .. ": " .. tostring(err), C.red) end
end

if not httpreq then
    pushLog("your executor does not expose request(): the AJ cannot reach the hub", C.red)
end
pushLog("SAE AJ v5 ready · " .. (IS_TOUCH and "mobile" or "PC"), C.cyan)
