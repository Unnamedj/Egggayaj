--[[ ─────────────────────────────────────────────────────────────────────────
     SAE · AUTO JOINER  v5   ·   by joszz
     Panel: Right Control (PC)  ·  boton flotante (movil)

     Novedades del v5:

       · Interfaz rehecha: pestañas con indicador deslizante, tarjetas con
         profundidad, entradas escalonadas, pulsaciones con rebote.
       · Funciona en movil y en PC: el panel se escala solo al viewport y hay
         un boton flotante arrastrable para abrirlo sin teclado.
       · Los hallazgos viejos SE MUESTRAN, marcados, pero el auto join no va a
         por ellos. Puedes unirte tu a mano si quieres.
       · Banner "UNIENDOSE A ..." al saltar, visible aunque el panel este
         cerrado.
       · Al aterrizar, la GUI enseña IN THE SERVER con el huevo por el que
         viniste. Sobrevive al teleport.
     ───────────────────────────────────────────────────────────────────────── ]]

local CFG = {
    HUB        = "https://TU-APP.up.railway.app",
    KEY        = "TU-API-KEY",
    CLIENT     = "sae-1",
    POLL       = 4,
    WAIT       = 20,
    COOLDOWN   = 8,
    MIN_KG     = 0,
    MAX_KG     = 0,
    MAX_AGE    = 120,      -- s. Mas viejo que esto: se ve, pero no se salta solo
    RARITIES   = { "Legendary", "Mythic", "Cosmic", "Secret", "Exotic",
                   "Eternal", "Divine", "Titan" },
    HAS_SLOT   = true,
    ONLY_NEW   = false,
    SCRIPT_URL = "",
    _schema    = 3,
}

-- ───────────────────────────────────────────────────────────────── servicios
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

-- ───────────────────────────────────────────────────────────────────── paleta
local C = {
    bg     = Color3.fromRGB(11, 12, 18),
    bg2    = Color3.fromRGB(16, 18, 26),
    card   = Color3.fromRGB(23, 26, 37),
    card2  = Color3.fromRGB(32, 36, 50),
    line   = Color3.fromRGB(45, 50, 68),
    txt    = Color3.fromRGB(237, 240, 248),
    txt2   = Color3.fromRGB(166, 174, 193),
    mut    = Color3.fromRGB(114, 123, 145),
    acc    = Color3.fromRGB(129, 97, 255),
    acc2   = Color3.fromRGB(46, 216, 240),
    ok     = Color3.fromRGB(54, 214, 156),
    bad    = Color3.fromRGB(252, 98, 122),
    warn   = Color3.fromRGB(252, 194, 40),
    ink    = Color3.fromRGB(10, 12, 18),
    white  = Color3.fromRGB(255, 255, 255),
}

local function hex(h)
    h = tostring(h or ""):gsub("#", "")
    if #h ~= 6 then return C.mut end
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
    ladder     = FALLBACK_LADDER, ladderFrom = "local",
    colors     = {},
    candidates = {},
    diag       = nil,
    logs       = {},
    lastErr    = nil,
    inServer   = nil,   -- el huevo por el que aterrizamos aqui
    seenUids   = {},
}
local autoOn = false

local function rc(r) return ST.colors[tostring(r):lower()] or C.mut end

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
    -- Recoge tambien los ajustes del v4 para no perder la URL ni la key.
    local src = isfile(FILE) and FILE or (isfile("eag_aj_v4.json") and "eag_aj_v4.json") or nil
    if not src then return end
    local migrated = false
    pcall(function()
        local d = HS:JSONDecode(readfile(src))
        local schema = tonumber(d._schema) or 1
        for k, v in pairs(d) do
            if CFG[k] ~= nil then CFG[k] = v end
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
    if not httpreq then return nil, "el executor no tiene request()" end
    local base = hubBase()
    if base == "" then return nil, "falta la URL del hub (AJUSTES)" end
    local opts = {
        Url = base .. path, Method = method,
        Headers = { ["Content-Type"] = "application/json", ["x-eag-key"] = CFG.KEY },
    }
    if body then opts.Body = HS:JSONEncode(body) end
    local ok, res = pcall(httpreq, opts)
    if not ok then return nil, "sin red" end
    local code = res.StatusCode or res.Status or 0
    if code == 401 then return nil, "API key incorrecta" end
    if code == 404 then return nil, "404 · revisa la URL del hub" end
    if code < 200 or code >= 300 then return nil, "HTTP " .. tostring(code) end
    local dok, dec = pcall(function() return HS:JSONDecode(res.Body) end)
    if not dok then return nil, "respuesta ilegible" end
    if type(dec) == "table" and tonumber(dec.eggSeq) then ST.eggSeq = tonumber(dec.eggSeq) end
    return dec
end

-- El filtro base. `forJoin` añade el corte por edad: la lista lo enseña TODO,
-- pero el salto automatico solo va a por lo fresco.
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
local function corner(o, r) mk("UICorner", { CornerRadius = UDim.new(0, r or 10) }, o) end
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
local function grad(o, rot, a, b)
    return mk("UIGradient", { Rotation = rot or 0, Color = ColorSequence.new(a, b) }, o)
end

local EASE = {
    out  = TweenInfo.new(0.22, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
    fast = TweenInfo.new(0.13, Enum.EasingStyle.Quad,  Enum.EasingDirection.Out),
    back = TweenInfo.new(0.42, Enum.EasingStyle.Back,  Enum.EasingDirection.Out),
    soft = TweenInfo.new(0.32, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
}
local function tw(obj, info, props)
    local t = TS:Create(obj, info or EASE.out, props)
    t:Play()
    return t
end

-- Rebote al pulsar. Da sensacion tactil, que en movil se agradece.
local function pressable(btn, scaleDown)
    local s = mk("UIScale", { Scale = 1 }, btn)
    local down = scaleDown or 0.94
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
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = col or C.txt2, Text = text,
    }, parent)
end
local function caption(parent, text, x, y, w)
    return mk("TextLabel", {
        Position = UDim2.new(0,x,0,y), Size = UDim2.new(0,w,0,13),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9.5,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.mut, Text = text,
    }, parent)
end

local function ago(ms)
    local s = math.max(0, math.floor((tonumber(ms) or 0) / 1000))
    if s < 60 then return s .. "s" end
    if s < 3600 then return math.floor(s/60) .. "m " .. (s % 60) .. "s" end
    return math.floor(s/3600) .. "h " .. math.floor((s % 3600)/60) .. "m"
end

-- ─────────────────────────────────────────────────────────────────────── root
local gui = mk("ScreenGui", {
    Name = "SAE_AJ", ResetOnSpawn = false, IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
gui.Parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")

local W, H = 560, 424
local root = mk("Frame", {
    Size = UDim2.new(0, W, 0, H),
    Position = UDim2.new(0.5, -W/2, 0.5, -H/2),
    BackgroundColor3 = C.bg, BorderSizePixel = 0,
    Active = true, Draggable = true,
}, gui)
corner(root, 16)
stroke(root, C.line, 0.2)
grad(root, 125, Color3.fromRGB(26, 22, 46), Color3.fromRGB(10, 11, 17))

-- El panel se encoge para caber en cualquier pantalla, movil incluido, sin
-- tener que mantener dos maquetaciones distintas.
local uiScale = mk("UIScale", { Scale = 1 }, root)
local function fitViewport()
    local cam = workspace.CurrentCamera
    if not cam then return end
    local vp = cam.ViewportSize
    if vp.X < 10 then return end
    local s = math.min(1, (vp.X - 20) / W, (vp.Y - 20) / H)
    uiScale.Scale = math.max(0.55, s)
end
fitViewport()
task.spawn(function()
    local cam = workspace.CurrentCamera
    if cam then cam:GetPropertyChangedSignal("ViewportSize"):Connect(fitViewport) end
end)

-- ── cabecera ──────────────────────────────────────────────────────────────
local header = mk("Frame", { Size = UDim2.new(1,0,0,48), BackgroundTransparency = 1 }, root)
mk("Frame", {
    Position = UDim2.new(0,0,1,-1), Size = UDim2.new(1,0,0,1),
    BackgroundColor3 = C.line, BorderSizePixel = 0, BackgroundTransparency = 0.4,
}, header)

do
    local badge = mk("Frame", {
        Position = UDim2.new(0,16,0,14), Size = UDim2.new(0,22,0,22),
        BackgroundColor3 = C.acc, BorderSizePixel = 0,
    }, header)
    corner(badge, 7)
    grad(badge, 130, C.acc, C.acc2)
    mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.ink, Text = "S",
    }, badge)
end

label(header, "SAE", 46, 9, 34, 16, 14, C.acc2, Enum.Font.GothamBold)
label(header, "AUTO JOINER", 80, 9, 170, 16, 14, C.txt, Enum.Font.GothamBold)
local subLbl = label(header, "conectando con el hub", 46, 26, 300, 13, 10.5, C.mut)

local connPill = mk("Frame", {
    Position = UDim2.new(1,-190,0,14), Size = UDim2.new(0,142,0,22),
    BackgroundColor3 = C.card, BorderSizePixel = 0,
}, header)
round(connPill); stroke(connPill, C.line, 0.35)
local connDot = mk("Frame", {
    Position = UDim2.new(0,10,0,8), Size = UDim2.new(0,6,0,6),
    BackgroundColor3 = C.warn, BorderSizePixel = 0,
}, connPill)
round(connDot)
local connLbl = mk("TextLabel", {
    Position = UDim2.new(0,22,0,0), Size = UDim2.new(1,-28,1,0),
    BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 10.5,
    TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.txt2, Text = "conectando",
}, connPill)

-- Latido del punto de conexion: se nota vivo sin gastar nada.
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

do
    local close = mk("TextButton", {
        Position = UDim2.new(1,-40,0,14), Size = UDim2.new(0,22,0,22),
        BackgroundColor3 = C.card, BorderSizePixel = 0, Text = "✕",
        Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.mut, AutoButtonColor = false,
    }, header)
    corner(close, 7); stroke(close, C.line, 0.35)
    pressable(close)
    close.MouseEnter:Connect(function() tw(close, EASE.fast, { BackgroundColor3 = C.card2 }) end)
    close.MouseLeave:Connect(function() tw(close, EASE.fast, { BackgroundColor3 = C.card }) end)
    close.MouseButton1Click:Connect(function()
        tw(root, EASE.fast, { BackgroundTransparency = 1 })
        tw(uiScale, EASE.fast, { Scale = uiScale.Scale * 0.94 })
        task.wait(0.13)
        root.Visible = false
        root.BackgroundTransparency = 0
        fitViewport()
    end)
end

-- ── pestañas con indicador deslizante ─────────────────────────────────────
local TAB_W, TAB_GAP = 126, 4
local tabBar = mk("Frame", {
    Position = UDim2.new(0,14,0,58), Size = UDim2.new(1,-28,0,32),
    BackgroundColor3 = C.bg2, BorderSizePixel = 0,
}, root)
corner(tabBar, 10)
stroke(tabBar, C.line, 0.55)

local tabGlide = mk("Frame", {
    Position = UDim2.new(0,3,0,3), Size = UDim2.new(0,TAB_W,0,26),
    BackgroundColor3 = C.card2, BorderSizePixel = 0,
}, tabBar)
corner(tabGlide, 8)
grad(tabGlide, 90, C.card2, Color3.fromRGB(40, 45, 62))

local function newPage()
    return mk("Frame", {
        Position = UDim2.new(0,14,0,100), Size = UDim2.new(1,-28,1,-114),
        BackgroundTransparency = 1, Visible = false,
    }, root)
end
local pgHunt, pgFilter, pgConfig, pgLog = newPage(), newPage(), newPage(), newPage()
local pages = { hunt = pgHunt, filter = pgFilter, config = pgConfig, log = pgLog }
local order = { "hunt", "filter", "config", "log" }

local tabBtns, selectTab = {}, nil
local function mkTab(i, key, text, tip)
    local x = 3 + (i - 1) * (TAB_W + TAB_GAP)
    local b = mk("TextButton", {
        Position = UDim2.new(0,x,0,3), Size = UDim2.new(0,TAB_W,0,26),
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.mut,
        Text = text, AutoButtonColor = false,
    }, tabBar)
    tabBtns[key] = b
    b.MouseButton1Click:Connect(function() selectTab(key) end)
    b.MouseEnter:Connect(function()
        if b.TextColor3 ~= C.txt then tw(b, EASE.fast, { TextColor3 = C.txt2 }) end
        subLbl.Text = tip
    end)
    b.MouseLeave:Connect(function()
        if b.TextColor3 ~= C.txt then tw(b, EASE.fast, { TextColor3 = C.mut }) end
    end)
    return b
end
mkTab(1, "hunt",   "CAZA",    "objetivos en vivo y salto automatico")
mkTab(2, "filter", "FILTROS", "rareza, peso y frescura")
mkTab(3, "config", "AJUSTES", "conexion con el hub y ritmo")
mkTab(4, "log",    "LOG",     "registro de actividad")

selectTab = function(key)
    for i, k in ipairs(order) do
        local on = (k == key)
        local p = pages[k]
        if on then
            tw(tabGlide, EASE.out, {
                Position = UDim2.new(0, 3 + (i - 1) * (TAB_W + TAB_GAP), 0, 3),
            })
            p.Visible = true
            p.Position = UDim2.new(0, 14, 0, 108)
            tw(p, EASE.out, { Position = UDim2.new(0, 14, 0, 100) })
        else
            p.Visible = false
        end
        tw(tabBtns[k], EASE.fast, { TextColor3 = on and C.txt or C.mut })
    end
end

-- ───────────────────────────────────────────────────────────── banner de salto
-- Vive fuera del panel: se ve aunque lo tengas cerrado.
local banner = mk("Frame", {
    AnchorPoint = Vector2.new(0.5, 0),
    Position = UDim2.new(0.5, 0, 0, -80),
    Size = UDim2.new(0, 340, 0, 58),
    BackgroundColor3 = C.card, BorderSizePixel = 0, Visible = false,
}, gui)
corner(banner, 13)
local bannerStroke = stroke(banner, C.acc, 0.35, 1.4)
grad(banner, 100, Color3.fromRGB(30, 26, 52), Color3.fromRGB(18, 20, 30))
local bannerScale = mk("UIScale", { Scale = 1 }, banner)

local bannerBar = mk("Frame", {
    Position = UDim2.new(0,0,0,12), Size = UDim2.new(0,4,1,-24),
    BackgroundColor3 = C.acc, BorderSizePixel = 0,
}, banner)
corner(bannerBar, 2)
local bannerTitle = label(banner, "UNIENDOSE A", 16, 10, 200, 13, 9.5, C.acc2, Enum.Font.GothamBold)
local bannerName  = label(banner, "", 16, 25, 250, 18, 14, C.txt, Enum.Font.GothamBold)
bannerName.TextTruncate = Enum.TextTruncate.AtEnd
local bannerTag = mk("TextLabel", {
    Position = UDim2.new(1,-100,0,20), Size = UDim2.new(0,84,0,20),
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.mut, Text = "",
}, banner)

-- Barra de progreso que se vacia: da idea de que el teleport esta en marcha.
local bannerProg = mk("Frame", {
    Position = UDim2.new(0,0,1,-3), Size = UDim2.new(1,0,0,3),
    BackgroundColor3 = C.acc, BorderSizePixel = 0, BackgroundTransparency = 0.25,
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
    bannerScale.Scale = 0.92
    bannerProg.Size = UDim2.new(1, 0, 0, 3)
    tw(banner, EASE.back, { Position = UDim2.new(0.5, 0, 0, 14) })
    tw(bannerScale, EASE.back, { Scale = 1 })
    tw(bannerProg, TweenInfo.new(4.2, Enum.EasingStyle.Linear), { Size = UDim2.new(0, 0, 0, 3) })

    task.delay(4.4, function()
        if bannerToken ~= myToken then return end
        tw(banner, EASE.soft, { Position = UDim2.new(0.5, 0, 0, -80) })
        tw(bannerScale, EASE.soft, { Scale = 0.92 })
        task.wait(0.34)
        if bannerToken == myToken then banner.Visible = false end
    end)
end

-- ───────────────────────────────────────────────────────────────────────── log
local logList, renderLog
local function pushLog(txt, col)
    table.insert(ST.logs, 1, { t = os.date("%H:%M:%S"), s = txt, c = col or C.mut })
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

local layoutHunt   -- se define con la pagina CAZA
local paintInServer

local function doHop(target)
    if not target or not target.jobId then return end
    if target.jobId == game.JobId then
        pushLog("ya estas en ese server", C.warn)
        return
    end
    ST.lastHop = os.clock()
    ST.hops = ST.hops + 1
    if tonumber(target.seq) then ST.cursor = math.max(ST.cursor or 0, tonumber(target.seq)) end

    showBanner(target)
    pushLog(("salto -> %s · %s %s kg"):format(
        tostring(target.name), tostring(target.rarity),
        tostring(math.floor(tonumber(target.kg) or 0))), C.acc2)

    -- Se guarda el huevo entero, no solo el jobId: al aterrizar la GUI necesita
    -- saber POR QUE vino aqui para enseñar el IN THE SERVER.
    if canFile then
        pcall(function()
            writefile(PENDING, HS:JSONEncode({
                jobId = target.jobId, at = os.time(),
                name = target.name, rarity = target.rarity,
                kg = target.kg, area = target.area, uid = target.uid,
            }))
        end)
    end
    local qt = queue_on_teleport or (syn and syn.queue_on_teleport)
    if qt and CFG.SCRIPT_URL ~= "" then
        pcall(qt, ('loadstring(game:HttpGet("%s"))()'):format(CFG.SCRIPT_URL))
    end

    local placeId = tonumber(target.placeId) or game.PlaceId
    local ok, err = pcall(function()
        TPS:TeleportToPlaceInstance(placeId, target.jobId, LP)
    end)
    if not ok then
        ST.fails = ST.fails + 1
        pushLog("fallo el teleport: " .. tostring(err), C.bad)
        reportHop(target.jobId, false, tostring(err))
    end
end

TPS.TeleportInitFailed:Connect(function(_, result, msg)
    ST.fails = ST.fails + 1
    pushLog("teleport rechazado: " .. tostring(msg), C.bad)
    if canFile and isfile(PENDING) then
        pcall(function()
            local t = HS:JSONDecode(readfile(PENDING))
            reportHop(t.jobId, false, tostring(result))
            if delfile then delfile(PENDING) end
        end)
    end
end)

-- ═══════════════════════════════════════════════════════════════════════ CAZA
-- IN THE SERVER: el huevo por el que aterrizamos aqui.
local inCard = mk("Frame", {
    Size = UDim2.new(1,0,0,46), BackgroundColor3 = C.card,
    BorderSizePixel = 0, Visible = false,
}, pgHunt)
corner(inCard, 11)
local inStroke = stroke(inCard, C.ok, 0.5)
grad(inCard, 90, Color3.fromRGB(24, 34, 32), Color3.fromRGB(22, 25, 35))
local inBar = mk("Frame", {
    Position = UDim2.new(0,0,0,10), Size = UDim2.new(0,3,1,-20),
    BackgroundColor3 = C.ok, BorderSizePixel = 0,
}, inCard)
local inTitle = label(inCard, "IN THE SERVER", 14, 8, 160, 13, 9.5, C.ok, Enum.Font.GothamBold)
local inName  = label(inCard, "", 14, 23, 300, 15, 12.5, C.txt, Enum.Font.GothamMedium)
inName.TextTruncate = Enum.TextTruncate.AtEnd
local inTag = mk("TextLabel", {
    Position = UDim2.new(1,-150,0,14), Size = UDim2.new(0,138,0,18),
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.mut, Text = "",
}, inCard)

-- fila superior: interruptor + contadores
local topRow = mk("Frame", { Size = UDim2.new(1,0,0,62), BackgroundTransparency = 1 }, pgHunt)

local autoCard = mk("Frame", {
    Size = UDim2.new(0,240,0,62), BackgroundColor3 = C.card, BorderSizePixel = 0,
}, topRow)
corner(autoCard, 12)
local autoStroke = stroke(autoCard, C.line, 0.5)
label(autoCard, "SALTO AUTOMATICO", 15, 12, 170, 14, 11, C.txt, Enum.Font.GothamBold)
local autoSub = mk("TextLabel", {
    Position = UDim2.new(0,15,0,29), Size = UDim2.new(0,150,0,24),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10.5,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    TextColor3 = C.mut, TextWrapped = true, Text = "en pausa",
}, autoCard)

local sw = mk("TextButton", {
    Position = UDim2.new(1,-66,0,19), Size = UDim2.new(0,50,0,25),
    BackgroundColor3 = C.card2, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
}, autoCard)
round(sw)
local swStroke = stroke(sw, C.line, 0.35)
local knob = mk("Frame", {
    Position = UDim2.new(0,3,0,3), Size = UDim2.new(0,19,0,19),
    BackgroundColor3 = C.mut, BorderSizePixel = 0,
}, sw)
round(knob)
local knobGlow = stroke(knob, C.ok, 1, 2)

local function paintAuto()
    tw(knob, EASE.back, {
        Position = autoOn and UDim2.new(0,28,0,3) or UDim2.new(0,3,0,3),
        BackgroundColor3 = autoOn and C.ink or C.mut,
    })
    tw(sw, EASE.out, { BackgroundColor3 = autoOn and C.ok or C.card2 })
    tw(autoStroke, EASE.out, {
        Color = autoOn and C.ok or C.line, Transparency = autoOn and 0.5 or 0.5,
    })
    tw(knobGlow, EASE.out, { Transparency = autoOn and 0.4 or 1 })
    swStroke.Transparency = autoOn and 1 or 0.35
    autoSub.Text = autoOn and "buscando objetivos frescos" or "en pausa"
    tw(autoSub, EASE.fast, { TextColor3 = autoOn and C.ok or C.mut })
end

sw.MouseButton1Click:Connect(function()
    autoOn = not autoOn
    if autoOn and CFG.ONLY_NEW then ST.cursor = ST.eggSeq end
    pushLog(autoOn and "auto join ON" or "auto join en pausa", autoOn and C.ok or C.mut)
    paintAuto()
end)
pressable(sw, 0.96)

local statCards = {}
do
    local x = 250
    for _, spec in ipairs({ {"servers","SERVERS"}, {"matches","OBJETIVOS"}, {"hops","SALTOS"} }) do
        local f = mk("Frame", {
            Position = UDim2.new(0,x,0,0), Size = UDim2.new(0,90,0,62),
            BackgroundColor3 = C.card, BorderSizePixel = 0,
        }, topRow)
        corner(f, 12); stroke(f, C.line, 0.5)
        statCards[spec[1]] = mk("TextLabel", {
            Position = UDim2.new(0,0,0,13), Size = UDim2.new(1,0,0,22),
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 18,
            TextColor3 = C.txt, Text = "0",
        }, f)
        mk("TextLabel", {
            Position = UDim2.new(0,0,0,38), Size = UDim2.new(1,0,0,13),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 9,
            TextColor3 = C.mut, Text = spec[2],
        }, f)
        x = x + 94
    end
end

-- banda de diagnostico
local diagCard = mk("Frame", {
    Size = UDim2.new(1,0,0,44), BackgroundColor3 = C.card,
    BorderSizePixel = 0, Visible = false,
}, pgHunt)
corner(diagCard, 11)
local diagStroke = stroke(diagCard, C.warn, 0.55)
local diagBar = mk("Frame", {
    Position = UDim2.new(0,0,0,10), Size = UDim2.new(0,3,1,-20),
    BackgroundColor3 = C.warn, BorderSizePixel = 0,
}, diagCard)
local diagTitle = label(diagCard, "", 14, 8, 380, 14, 11, C.warn, Enum.Font.GothamBold)
local diagBody = mk("TextLabel", {
    Position = UDim2.new(0,14,0,24), Size = UDim2.new(1,-160,0,14),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10.5,
    TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.txt2,
    TextTruncate = Enum.TextTruncate.AtEnd, Text = "",
}, diagCard)
local diagBtn = mk("TextButton", {
    Position = UDim2.new(1,-140,0,10), Size = UDim2.new(0,128,0,24),
    BackgroundColor3 = C.card2, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
    TextSize = 10, TextColor3 = C.txt2, Text = "", AutoButtonColor = false, Visible = false,
}, diagCard)
corner(diagBtn, 8); stroke(diagBtn, C.line, 0.4); pressable(diagBtn)
local diagAction = nil
diagBtn.MouseButton1Click:Connect(function() if diagAction then diagAction() end end)

local listLabel = caption(pgHunt, "OBJETIVOS EN VIVO", 2, 0, 220)
local list = mk("ScrollingFrame", {
    Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = C.line,
    CanvasSize = UDim2.new(0,0,0,0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
}, pgHunt)
mk("UIListLayout", { Padding = UDim.new(0,6), SortOrder = Enum.SortOrder.LayoutOrder }, list)

local emptyLbl = mk("TextLabel", {
    Size = UDim2.new(1,0,0,52), BackgroundTransparency = 1,
    Font = Enum.Font.Gotham, TextSize = 11.5, TextColor3 = C.mut, TextWrapped = true,
    Text = "sin objetivos",
}, list)

-- Las tarjetas de arriba aparecen y desaparecen, asi que la lista se recoloca.
layoutHunt = function(animate)
    local y = 0
    local function place(obj, h)
        if not obj.Visible then return end
        local target = UDim2.new(0, 0, 0, y)
        if animate then tw(obj, EASE.out, { Position = target }) else obj.Position = target end
        y = y + h
    end
    place(inCard, 52)
    place(topRow, 68)
    place(diagCard, 50)
    listLabel.Position = UDim2.new(0, 2, 0, y)
    y = y + 17
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

-- Al arrancar: ¿venimos de un salto? Entonces enseña IN THE SERVER.
task.spawn(function()
    if canFile and isfile(PENDING) then
        local ok, t = pcall(function() return HS:JSONDecode(readfile(PENDING)) end)
        if ok and t and t.jobId then
            local landed = (t.jobId == game.JobId)
            reportHop(t.jobId, landed, landed and "ok" or "aterrizo en otro server")
            if landed then
                ST.inServer = {
                    name = t.name, rarity = t.rarity, kg = t.kg,
                    area = t.area, uid = t.uid, at = t.at,
                }
                pushLog(("aterrizaje confirmado · %s"):format(tostring(t.name or "?")), C.ok)
                task.wait(0.4)
                pcall(paintInServer)
            else
                pushLog("aterrizo en otro server", C.warn)
            end
        end
        pcall(function() if delfile then delfile(PENDING) end end)
    end
end)

local function buildRow(e, i, isNew)
    local stale = isStale(e)
    local col = rc(e.rarity)
    local row = mk("Frame", {
        Size = UDim2.new(1,-6,0,46), BackgroundColor3 = C.card,
        BackgroundTransparency = 1, BorderSizePixel = 0, LayoutOrder = i,
    }, list)
    corner(row, 10)
    local rs = stroke(row, C.line, 1)

    mk("Frame", {
        Position = UDim2.new(0,0,0,10), Size = UDim2.new(0,3,1,-20),
        BackgroundColor3 = col, BorderSizePixel = 0, BackgroundTransparency = stale and 0.5 or 0,
    }, row)

    local nameLbl = label(row, tostring(e.name), 14, 6, 190, 16, 12.5,
        stale and C.txt2 or C.txt, Enum.Font.GothamMedium)
    nameLbl.TextTruncate = Enum.TextTruncate.AtEnd

    local sub = ("%s · %s · %s/%s jug · hace %s"):format(
        tostring(e.rarity),
        (e.area ~= nil and e.area ~= "" and e.area or "zona"),
        tostring(e.players or "?"), tostring(e.maxPlayers or "?"), ago(e.ageMs))
    local subLblRow = label(row, sub, 14, 23, 250, 14, 10, C.mut)
    subLblRow.TextTruncate = Enum.TextTruncate.AtEnd

    -- Las etiquetas se colocan de derecha a izquierda con un cursor: si no, un
    -- huevo viejo Y en uso a la vez las superponia.
    local rx = 70 + 72
    local kgTag = mk("Frame", {
        Position = UDim2.new(1,-rx,0,13), Size = UDim2.new(0,72,0,20),
        BackgroundColor3 = col, BorderSizePixel = 0,
        BackgroundTransparency = stale and 0.93 or 0.85,
    }, row)
    round(kgTag); stroke(kgTag, col, stale and 0.75 or 0.5)
    mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = col,
        Text = ("%s kg"):format(tostring(math.floor((tonumber(e.kg) or 0) + 0.5))),
    }, kgTag)

    -- Marca de viejo: se ve, pero el auto join no ira a por el.
    if stale then
        rx = rx + 6 + 48
        local tag = mk("Frame", {
            Position = UDim2.new(1,-rx,0,13), Size = UDim2.new(0,48,0,20),
            BackgroundColor3 = C.mut, BackgroundTransparency = 0.85, BorderSizePixel = 0,
        }, row)
        round(tag); stroke(tag, C.mut, 0.6)
        mk("TextLabel", {
            Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
            Font = Enum.Font.GothamBold, TextSize = 9.5, TextColor3 = C.mut, Text = "viejo",
        }, tag)
    end

    if e.claimed then
        rx = rx + 6 + 46
        mk("TextLabel", {
            Position = UDim2.new(1,-rx,0,13), Size = UDim2.new(0,46,0,20),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 9.5,
            TextColor3 = C.warn, Text = "en uso",
        }, row)
    end

    -- El texto se recorta justo antes de la primera etiqueta, sin pisarla.
    nameLbl.Size = UDim2.new(1, -(rx + 22), 0, 16)
    subLblRow.Size = UDim2.new(1, -(rx + 22), 0, 14)

    local cp = mk("TextButton", {
        Position = UDim2.new(1,-62,0,12), Size = UDim2.new(0,24,0,22),
        BackgroundColor3 = C.card2, BorderSizePixel = 0, Text = "⧉",
        Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.mut, AutoButtonColor = false,
    }, row)
    corner(cp, 7); pressable(cp)
    cp.MouseButton1Click:Connect(function()
        local set = setclipboard or toclipboard or (syn and syn.write_clipboard)
        if set then pcall(set, tostring(e.jobId)); pushLog("job id copiado", C.mut) end
    end)

    local join = mk("TextButton", {
        Position = UDim2.new(1,-33,0,12), Size = UDim2.new(0,26,0,22),
        BackgroundColor3 = C.acc, BorderSizePixel = 0, Text = "▶",
        Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.white,
        AutoButtonColor = false,
    }, row)
    corner(join, 7); grad(join, 20, C.acc, Color3.fromRGB(96, 66, 244)); pressable(join, 0.9)
    join.MouseButton1Click:Connect(function() doHop(e) end)

    row.MouseEnter:Connect(function()
        tw(row, EASE.fast, { BackgroundColor3 = C.card2 })
        tw(rs, EASE.fast, { Color = col, Transparency = 0.45 })
    end)
    row.MouseLeave:Connect(function()
        tw(row, EASE.fast, { BackgroundColor3 = C.card })
        tw(rs, EASE.fast, { Color = C.line, Transparency = 0.55 })
    end)

    -- La lista se repinta cada poll, asi que solo se anima lo que de verdad es
    -- nuevo: si no, todo entraria en cascada cada 4 segundos y mareaba.
    local restTr = stale and 0.35 or 0
    if isNew then
        task.delay(math.min(i, 12) * 0.03, function()
            if not row.Parent then return end
            tw(row, EASE.out, { BackgroundTransparency = restTr })
            tw(rs, EASE.out, { Transparency = 0.55 })
            -- destello del color de su rareza, para pillarlo de reojo
            local flash = mk("Frame", {
                Size = UDim2.new(1,0,1,0), BackgroundColor3 = col,
                BackgroundTransparency = 0.72, BorderSizePixel = 0, ZIndex = 0,
            }, row)
            corner(flash, 10)
            tw(flash, TweenInfo.new(0.95, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
                { BackgroundTransparency = 1 })
            task.delay(1.05, function() if flash and flash.Parent then flash:Destroy() end end)
        end)
    else
        row.BackgroundTransparency = restTr
        rs.Transparency = 0.55
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
        show("sin conexion con el hub", tostring(ST.lastErr or "no responde"), C.bad)
        emptyLbl.Text = "revisa la URL y la API key en AJUSTES"
        layoutHunt(true); return
    end
    if not d then
        diagCard.Visible = false
        emptyLbl.Text = "consultando al hub…"
        layoutHunt(true); return
    end
    if (tonumber(d.passed) or 0) > 0 then
        diagCard.Visible = false
        emptyLbl.Text = ("%d objetivo(s) disponibles · tomando…"):format(d.passed)
        layoutHunt(true); return
    end
    if d.servers == 0 then
        show("ningun reporter esta enviando", "el hub esta vacio", C.warn)
        emptyLbl.Text = "esperando a que algun reporter suba huevos"
        layoutHunt(true); return
    end
    if d.rarityFilterUnknown then
        show("tus rarezas no existen en el juego",
            "ninguna coincide con la lista real", C.bad,
            "MARCAR LAS RARAS", function()
                CFG.RARITIES = {}
                for _, r in ipairs(ST.ladder) do
                    if (tonumber(r.rank) or 0) >= 5 then table.insert(CFG.RARITIES, r.name) end
                end
                save()
                pushLog("filtro de rarezas rehecho", C.ok)
            end)
        emptyLbl.Text = "arregla el filtro de rarezas"
        layoutHunt(true); return
    end
    if d.total == 0 then
        show("los servers estan vacios",
            ("%d reportando, 0 huevos ahora mismo"):format(d.servers), C.warn)
        emptyLbl.Text = "esperando huevos"
        layoutHunt(true); return
    end
    if d.top then
        local bits = {}
        for reason, n in pairs(d.drops or {}) do bits[#bits+1] = ("%d %s"):format(n, reason) end
        table.sort(bits)
        local btnText, action
        if d.top.reason == "rareza no marcada" then
            btnText, action = "IR A FILTROS", function() selectTab("filter") end
        elseif d.top.reason == "anterior al cursor" then
            btnText, action = "ACEPTAR LOS DE AHORA", function()
                ST.cursor = 0
                pushLog("cursor a cero", C.warn)
            end
        end
        show(("%d huevos en el hub, ninguno encaja"):format(d.total),
            table.concat(bits, "  ·  "), C.warn, btnText, action)
        emptyLbl.Text = "ajusta los filtros o espera un hallazgo"
        layoutHunt(true); return
    end
    diagCard.Visible = false
    emptyLbl.Text = "sin objetivos"
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
        and ("OBJETIVOS EN VIVO   ·   %d frescos de %d"):format(fresh, #ST.candidates)
        or "OBJETIVOS EN VIVO"
    paintDiag()
end

-- ═════════════════════════════════════════════════════════════════════ FILTROS
local function field(parent, lbl, x, y, w, value, onChange)
    caption(parent, lbl, x + 2, y, w)
    local box = mk("TextBox", {
        Position = UDim2.new(0,x,0,y+16), Size = UDim2.new(0,w,0,30),
        BackgroundColor3 = C.card, BorderSizePixel = 0,
        Font = Enum.Font.Gotham, TextSize = 11.5, TextColor3 = C.txt,
        ClearTextOnFocus = false, Text = tostring(value),
    }, parent)
    corner(box, 9); pad(box, 10, 10)
    local s = stroke(box, C.line, 0.5)
    box.Focused:Connect(function()
        tw(s, EASE.fast, { Color = C.acc, Transparency = 0 })
        tw(box, EASE.fast, { BackgroundColor3 = C.card2 })
    end)
    box.FocusLost:Connect(function()
        tw(s, EASE.fast, { Color = C.line, Transparency = 0.5 })
        tw(box, EASE.fast, { BackgroundColor3 = C.card })
        onChange(box.Text); save()
    end)
    return box
end

local function toggleRow(parent, x, y, w, text, get, set)
    local b = mk("TextButton", {
        Position = UDim2.new(0,x,0,y), Size = UDim2.new(0,w,0,32),
        BackgroundColor3 = C.card, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, parent)
    corner(b, 9); pressable(b, 0.98)
    local s = stroke(b, C.line, 0.5)
    local mark = mk("Frame", {
        Position = UDim2.new(0,11,0,10), Size = UDim2.new(0,13,0,13),
        BackgroundColor3 = C.card2, BorderSizePixel = 0,
    }, b)
    corner(mark, 4)
    local ms = stroke(mark, C.line, 0.2)
    local tick = mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.ink, Text = "✓",
    }, mark)
    local lbl = label(b, text, 32, 0, w - 42, 32, 11, C.txt2)
    lbl.TextYAlignment = Enum.TextYAlignment.Center
    local function paint()
        local on = get()
        tick.Visible = on
        tw(mark, EASE.fast, { BackgroundColor3 = on and C.ok or C.card2 })
        tw(ms, EASE.fast, { Color = on and C.ok or C.line })
        tw(lbl, EASE.fast, { TextColor3 = on and C.txt or C.mut })
        tw(s, EASE.fast, { Color = on and C.ok or C.line, Transparency = on and 0.55 or 0.5 })
    end
    b.MouseButton1Click:Connect(function() set(not get()); paint(); save() end)
    paint()
    return b
end

caption(pgFilter, "RAREZAS ACEPTADAS", 2, 0, 220)
local ladderNote = mk("TextLabel", {
    Position = UDim2.new(1,-214,0,0), Size = UDim2.new(0,212,0,13),
    BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 9.5,
    TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.warn,
    Text = "", Visible = false,
}, pgFilter)

local chipHolder = mk("ScrollingFrame", {
    Position = UDim2.new(0,0,0,17), Size = UDim2.new(1,0,0,88),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(0,0,0,0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
    ScrollingDirection = Enum.ScrollingDirection.Y,
}, pgFilter)
do
    local lay = mk("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0,5), SortOrder = Enum.SortOrder.LayoutOrder,
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
        ladderNote.Text = "lista local · el hub no responde"
    end
    for i, r in ipairs(ST.ladder) do
        local on, col = hasRarity(r.name), rc(r.name)
        local b = mk("TextButton", {
            Size = UDim2.new(0, 24 + #r.name * 6.6, 0, 26),
            BackgroundColor3 = on and col or C.card, BorderSizePixel = 0, LayoutOrder = i,
            Font = Enum.Font.GothamBold, TextSize = 10.5,
            TextColor3 = on and C.ink or col, Text = r.name, AutoButtonColor = false,
        }, chipHolder)
        round(b); stroke(b, col, on and 1 or 0.55); pressable(b, 0.92)
        b.MouseEnter:Connect(function()
            if not on then tw(b, EASE.fast, { BackgroundColor3 = C.card2 }) end
        end)
        b.MouseLeave:Connect(function()
            if not on then tw(b, EASE.fast, { BackgroundColor3 = C.card }) end
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
            BackgroundColor3 = C.card, BorderSizePixel = 0, Font = Enum.Font.GothamMedium,
            TextSize = 10.5, TextColor3 = C.txt2, Text = text, AutoButtonColor = false,
        }, pgFilter)
        corner(b, 7); stroke(b, C.line, 0.5); pressable(b)
        b.MouseEnter:Connect(function() tw(b, EASE.fast, { BackgroundColor3 = C.card2 }) end)
        b.MouseLeave:Connect(function() tw(b, EASE.fast, { BackgroundColor3 = C.card }) end)
        b.MouseButton1Click:Connect(function() fn(); save(); renderChips() end)
    end
    quick("todas", 0, 72, function()
        CFG.RARITIES = {}
        for _, r in ipairs(ST.ladder) do table.insert(CFG.RARITIES, r.name) end
    end)
    quick("ninguna", 78, 72, function() CFG.RARITIES = {} end)
    quick("solo raras", 156, 88, function()
        CFG.RARITIES = {}
        for _, r in ipairs(ST.ladder) do
            if (tonumber(r.rank) or 0) >= 5 then table.insert(CFG.RARITIES, r.name) end
        end
    end)
end

caption(pgFilter, "PESO Y FRESCURA", 2, 146, 220)
field(pgFilter, "KG MINIMO", 0, 162, 124, CFG.MIN_KG, function(v) CFG.MIN_KG = tonumber(v) or 0 end)
field(pgFilter, "KG MAXIMO · 0 = libre", 134, 162, 166, CFG.MAX_KG, function(v) CFG.MAX_KG = tonumber(v) or 0 end)
field(pgFilter, "EDAD MAX (s)", 310, 162, 118, CFG.MAX_AGE, function(v)
    CFG.MAX_AGE = math.max(0, tonumber(v) or 0)
end)

caption(pgFilter, "REGLAS", 2, 212, 220)
toggleRow(pgFilter, 0, 228, 258, "ignorar lo que ya habia al encender",
    function() return CFG.ONLY_NEW end,
    function(v) CFG.ONLY_NEW = v; if v then ST.cursor = ST.eggSeq end end)
toggleRow(pgFilter, 266, 228, 258, "solo servers con hueco",
    function() return CFG.HAS_SLOT end,
    function(v) CFG.HAS_SLOT = v end)

mk("TextLabel", {
    Position = UDim2.new(0,2,0,266), Size = UDim2.new(1,-4,0,40),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10.5,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    TextColor3 = C.mut, TextWrapped = true,
    Text = "Los hallazgos mas viejos que EDAD MAX se siguen viendo en la lista, "
        .. "marcados como «viejo», pero el salto automatico no va a por ellos. "
        .. "Puedes unirte tu a mano con ▶.",
}, pgFilter)

-- ══════════════════════════════════════════════════════════════════════ AJUSTES
caption(pgConfig, "CONEXION", 2, 0, 220)
field(pgConfig, "HUB URL", 0, 16, 528, CFG.HUB, function(v) CFG.HUB = (v:gsub("%s+",""):gsub("/+$","")) end)
field(pgConfig, "API KEY", 0, 64, 326, CFG.KEY, function(v) CFG.KEY = (v:gsub("%s+","")) end)
field(pgConfig, "NOMBRE DE ESTE CLIENTE", 336, 64, 192, CFG.CLIENT, function(v) CFG.CLIENT = v end)

caption(pgConfig, "RITMO", 2, 114, 220)
field(pgConfig, "POLL (s)", 0, 130, 100, CFG.POLL, function(v) CFG.POLL = math.max(2, tonumber(v) or 4) end)
field(pgConfig, "COOLDOWN (s)", 110, 130, 116, CFG.COOLDOWN, function(v) CFG.COOLDOWN = math.max(3, tonumber(v) or 8) end)
field(pgConfig, "ESPERA CLAIM (s)", 236, 130, 124, CFG.WAIT, function(v) CFG.WAIT = math.max(5, math.min(50, tonumber(v) or 20)) end)
field(pgConfig, "RAW · auto reload", 370, 130, 158, CFG.SCRIPT_URL, function(v) CFG.SCRIPT_URL = v end)

do
    local test = mk("TextButton", {
        Position = UDim2.new(0,0,0,192), Size = UDim2.new(0,162,0,32),
        BackgroundColor3 = C.acc, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, pgConfig)
    corner(test, 9); grad(test, 20, C.acc, Color3.fromRGB(96,66,244)); pressable(test)
    local tl = mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 11.5,
        TextColor3 = C.white, Text = "PROBAR CONEXION",
    }, test)
    test.MouseButton1Click:Connect(function()
        tl.Text = "PROBANDO…"
        task.spawn(function()
            local res, err = httpJson("GET", "/api/meta")
            tl.Text = res and "CONECTADO ✓" or "SIN CONEXION"
            if res then
                pushLog(("hub ok · %d servers · %d huevos"):format(res.servers or 0, res.eggs or 0), C.ok)
            else
                pushLog("hub error: " .. tostring(err), C.bad)
            end
            task.delay(2, function() tl.Text = "PROBAR CONEXION" end)
        end)
    end)

    mk("TextLabel", {
        Position = UDim2.new(0,174,0,192), Size = UDim2.new(1,-174,0,40),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10.5,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        TextColor3 = C.mut, TextWrapped = true,
        Text = "Cada campo se guarda al salir de el. La misma API key que pusiste en el hub y en el reporter.",
    }, pgConfig)
end

-- ═════════════════════════════════════════════════════════════════════════ LOG
do
    logList = mk("ScrollingFrame", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1, BorderSizePixel = 0,
        ScrollBarThickness = 3, ScrollBarImageColor3 = C.line,
        CanvasSize = UDim2.new(0,0,0,0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollingDirection = Enum.ScrollingDirection.Y,
    }, pgLog)
    mk("UIListLayout", { Padding = UDim.new(0,2), SortOrder = Enum.SortOrder.LayoutOrder }, logList)

    renderLog = function()
        for _, c in ipairs(logList:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        for i, e in ipairs(ST.logs) do
            if i > 60 then break end
            local row = mk("Frame", {
                Size = UDim2.new(1,-6,0,19), BackgroundTransparency = 1, LayoutOrder = i,
            }, logList)
            mk("Frame", {
                Position = UDim2.new(0,0,0,6), Size = UDim2.new(0,2,0,8),
                BackgroundColor3 = e.c, BorderSizePixel = 0,
            }, row)
            label(row, e.t, 10, 0, 56, 19, 10, C.mut, Enum.Font.Code)
            label(row, e.s, 70, 0, 440, 19, 11, e.c).TextTruncate = Enum.TextTruncate.AtEnd
        end
    end
end

-- ══════════════════════════════════════════════════════════════════════ estado
local function paintStatus()
    statCards.servers.Text = tostring(ST.servers)
    statCards.matches.Text = tostring(#ST.candidates)
    statCards.hops.Text    = tostring(ST.hops)
    connDot.BackgroundColor3 = ST.connected and C.ok or C.bad
    connLbl.Text = ST.connected and ("en vivo · " .. ST.eggsLive .. " huevos") or "sin conexion"
    connLbl.TextColor3 = ST.connected and C.txt2 or C.bad

    if not ST.connected then
        subLbl.Text = "hub: " .. tostring(ST.lastErr or "sin respuesta")
        subLbl.TextColor3 = C.bad
    elseif ST.inServer then
        subLbl.Text = "estas en el server de " .. tostring(ST.inServer.name or "?")
        subLbl.TextColor3 = C.ok
    elseif ST.latency >= 0 then
        subLbl.Text = "ultimo objetivo recibido en " .. ST.latency .. " ms"
        subLbl.TextColor3 = C.mut
    else
        subLbl.Text = "conectado · esperando objetivo"
        subLbl.TextColor3 = C.mut
    end
end

-- ═══════════════════════════════════════════════════════════════════════ loops
task.spawn(function()
    while true do
        local meta, err = httpJson("GET", "/api/meta")
        if meta then
            if not ST.connected then pushLog("conectado al hub", C.ok) end
            ST.connected, ST.lastErr = true, nil
            ST.servers  = meta.servers or 0
            ST.eggsLive = meta.eggs or 0
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
            if ST.connected or ST.lastErr ~= err then pushLog("hub: " .. tostring(err), C.bad) end
            ST.connected, ST.lastErr = false, err
        end

        -- La LISTA no filtra por edad: enseña tambien lo viejo, marcado.
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
                    pushLog("claim: " .. tostring(err), C.warn)
                end
            end
        end
        task.wait(1)
    end
end)

-- ══════════════════════════════════════════════════════════════════════ toggle
local function togglePanel()
    if root.Visible then
        tw(uiScale, EASE.fast, { Scale = uiScale.Scale * 0.94 })
        task.wait(0.12)
        root.Visible = false
        fitViewport()
    else
        root.Visible = true
        local s = uiScale.Scale
        uiScale.Scale = s * 0.94
        tw(uiScale, EASE.back, { Scale = s })
    end
end

UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightControl then togglePanel() end
end)

-- Boton flotante: en movil no hay Right Control. Arrastrable para que no
-- estorbe, y con un toque abre el panel.
do
    local fab = mk("TextButton", {
        AnchorPoint = Vector2.new(0, 0.5),
        Position = UDim2.new(0, 12, 0.5, 0), Size = UDim2.new(0, 46, 0, 46),
        BackgroundColor3 = C.acc, BorderSizePixel = 0, Text = "",
        AutoButtonColor = false, Active = true, Draggable = true,
        Visible = IS_TOUCH,
    }, gui)
    round(fab)
    grad(fab, 130, C.acc, C.acc2)
    stroke(fab, C.white, 0.75, 1.4)
    mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 15, TextColor3 = C.ink, Text = "S",
    }, fab)
    pressable(fab, 0.9)
    fab.MouseButton1Click:Connect(togglePanel)
end

for _, step in ipairs({
    { "chips",  function() renderChips() end },
    { "tabs",   function() selectTab("hunt") end },
    { "toggle", paintAuto },
    { "layout", function() layoutHunt(false) end },
    { "estado", paintStatus },
}) do
    local ok, err = pcall(step[2])
    if not ok then pushLog("fallo al pintar " .. step[1] .. ": " .. tostring(err), C.bad) end
end

if not httpreq then
    pushLog("tu executor no expone request(): el AJ no puede hablar con el hub", C.bad)
end
pushLog("SAE AJ v5 listo · " .. (IS_TOUCH and "movil" or "PC"), C.acc2)
