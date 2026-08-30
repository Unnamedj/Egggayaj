--[[ ─────────────────────────────────────────────────────────────────────────
     EAG · AUTO JOINER  v4   ·   by joszz
     Panel: Right Control

     Que cambia frente al v3:

       1. YA NO SE QUEDA MUDO. Si no salta, te dice por que: "el hub tiene 6
          huevos, 4 con rareza no marcada y 2 anteriores al cursor". Antes te
          quedabas mirando una lista vacia sin saber si fallaba el hub, el
          filtro o el ESP.
       2. Nunca manda una lista de rarezas vacia. Una tabla vacia de Lua puede
          viajar como {} y el hub la leia como un filtro imposible: ese era el
          motivo real de "mande algo y no salio".
       3. Interfaz rehecha: pestañas de verdad en vez del carril de iconos
          dibujados a mano, tarjetas con jerarquia y estados claros.
       4. Config propia (eag_aj_v4.json). El v3 reusaba el fichero del v2 y se
          heredaban filtros viejos, como MIN_KG=25, que tumbaban todo en
          silencio.
     ───────────────────────────────────────────────────────────────────────── ]]

local CFG = {
    HUB        = "https://TU-APP.up.railway.app",
    KEY        = "TU-API-KEY",
    CLIENT     = "aj-1",
    POLL       = 4,
    WAIT       = 20,
    COOLDOWN   = 8,
    MIN_KG     = 0,
    MAX_KG     = 0,
    MAX_AGE    = 120,
    RARITIES   = { "Legendary", "Mythic", "Cosmic", "Secret", "Exotic",
                   "Eternal", "Divine", "Titan" },
    HAS_SLOT   = true,
    -- El corte por defecto para no ir a hallazgos viejos es MAX_AGE, no el
    -- cursor. Ver la nota larga sobre por que, mas abajo en filterBody().
    ONLY_NEW   = false,
    SCRIPT_URL = "",
    _schema    = 2,
}

-- ───────────────────────────────────────────────────────────────── servicios
local Players = game:GetService("Players")
local TPS     = game:GetService("TeleportService")
local UIS     = game:GetService("UserInputService")
local TS      = game:GetService("TweenService")
local HS      = game:GetService("HttpService")
local LP      = Players.LocalPlayer

local httpreq = (syn and syn.request) or (fluxus and fluxus.request)
    or http_request or request or (http and http.request)

-- ───────────────────────────────────────────────────────────────────── paleta
local C = {
    bg    = Color3.fromRGB(10, 11, 16),
    bg2   = Color3.fromRGB(15, 17, 24),
    card  = Color3.fromRGB(22, 25, 35),
    card2 = Color3.fromRGB(30, 34, 47),
    line  = Color3.fromRGB(42, 47, 63),
    txt   = Color3.fromRGB(235, 238, 246),
    txt2  = Color3.fromRGB(162, 170, 189),
    mut   = Color3.fromRGB(110, 119, 140),
    acc   = Color3.fromRGB(124, 92, 255),
    acc2  = Color3.fromRGB(34, 211, 238),
    ok    = Color3.fromRGB(52, 211, 153),
    bad   = Color3.fromRGB(251, 95, 120),
    warn  = Color3.fromRGB(251, 191, 36),
    ink   = Color3.fromRGB(10, 12, 18),
}

local function hex(h)
    h = tostring(h or ""):gsub("#", "")
    if #h ~= 6 then return C.mut end
    return Color3.fromRGB(
        tonumber(h:sub(1,2),16) or 120,
        tonumber(h:sub(3,4),16) or 120,
        tonumber(h:sub(5,6),16) or 120)
end

-- La escalera real del juego, integrada. El hub manda la suya en /api/meta y
-- la sustituye, pero sin esto los chips de rareza salian VACIOS cuando el hub
-- no respondia: te quedabas sin poder configurar nada y sin saber por que.
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
    eggSeq     = 0,
    cursor     = nil,
    ladder     = FALLBACK_LADDER,
    ladderFrom = "local",
    colors     = {},
    candidates = {},
    diag       = nil,
    logs       = {},
    lastErr    = nil,
}
local autoOn = false

local function rc(r) return ST.colors[tostring(r):lower()] or C.mut end

local function applyLadder(rows, from)
    ST.ladder = rows
    ST.ladderFrom = from
    ST.colors = {}
    for _, r in ipairs(rows) do
        ST.colors[tostring(r.name):lower()] = hex(r.color)
    end
end
applyLadder(FALLBACK_LADDER, "local")

-- ───────────────────────────────────────────────────────────── persistencia
local FILE    = "eag_aj_v4.json"
local PENDING = "eag_aj_pending.json"
local canFile = (writefile and readfile and isfile) ~= nil

local function save()
    if not canFile then return end
    pcall(function() writefile(FILE, HS:JSONEncode(CFG)) end)
end
local migrated = false
local function load()
    if not canFile or not isfile(FILE) then return end
    pcall(function()
        local d = HS:JSONDecode(readfile(FILE))
        local schema = tonumber(d._schema) or 1
        for k, v in pairs(d) do
            if CFG[k] ~= nil then CFG[k] = v end
        end
        -- Los ajustes guardados con la version anterior traen ONLY_NEW=true,
        -- que con el reporter de un solo disparo deja al AJ sin objetivos para
        -- siempre. Se apaga una sola vez; la URL y la key se conservan.
        if schema < 2 then
            CFG.ONLY_NEW = false
            CFG._schema = 2
            migrated = true
        end
    end)
    if migrated then save() end
end
load()

-- ─────────────────────────────────────────────────────────────────────── http
-- Se normaliza en CADA peticion, no solo al salir del campo de texto. Una barra
-- final convertia /api/meta en //api/meta, que el hub servia como fichero: 404.
local function hubBase()
    local u = tostring(CFG.HUB or ""):gsub("%s+", "")
    u = u:gsub("/+$", "")            -- barras finales
    u = u:gsub("/api$", "")          -- por si pegaste la URL con /api ya puesto
    if u ~= "" and not u:match("^https?://") then u = "https://" .. u end
    return u
end

local function httpJson(method, path, body)
    if not httpreq then return nil, "el executor no tiene request()" end
    local base = hubBase()
    if base == "" then return nil, "falta la URL del hub (pestaña AJUSTES)" end
    local opts = {
        Url = base .. path,
        Method = method,
        Headers = { ["Content-Type"] = "application/json", ["x-eag-key"] = CFG.KEY },
    }
    if body then opts.Body = HS:JSONEncode(body) end
    local ok, res = pcall(httpreq, opts)
    if not ok then return nil, "sin red" end
    local code = res.StatusCode or res.Status or 0
    if code == 401 then return nil, "API key incorrecta" end
    if code == 404 then return nil, "404 · revisa la URL del hub en AJUSTES" end
    if code < 200 or code >= 300 then return nil, "HTTP " .. tostring(code) end
    local dok, dec = pcall(function() return HS:JSONDecode(res.Body) end)
    if not dok then return nil, "respuesta ilegible" end
    if type(dec) == "table" and tonumber(dec.eggSeq) then ST.eggSeq = tonumber(dec.eggSeq) end
    return dec
end

-- El cuerpo compartido por /api/claim, /api/feed y /api/diag: si los tres no
-- piden lo mismo, el diagnostico deja de explicar lo que de verdad pasa.
local function filterBody()
    local b = {
        client  = CFG.CLIENT,
        minKg   = tonumber(CFG.MIN_KG) or 0,
        hasSlot = CFG.HAS_SLOT,
    }
    -- Nunca mandes una lista vacia: en Lua viaja como {} y el hub no puede
    -- saber si querias "todas" o "ninguna".
    if #CFG.RARITIES > 0 then b.rarities = CFG.RARITIES end
    if (tonumber(CFG.MAX_KG) or 0) > 0 then b.maxKg = CFG.MAX_KG end

    -- Asi se evitan los hallazgos viejos: por EDAD. Un huevo descubierto hace
    -- mas de MAX_AGE segundos ya no vale, lo reportara quien sea y cuando sea.
    if (tonumber(CFG.MAX_AGE) or 0) > 0 then b.maxAgeSec = CFG.MAX_AGE end

    -- El cursor (sinceSeq) es OTRA cosa y va apagado por defecto: descarta todo
    -- lo que el hub ya conocia al encender el auto join. Suena parecido, pero
    -- con el reporter mandando UN reporte por server, si el reporter paso por
    -- ahi antes de que encendieras el AJ esos huevos quedan detras del cursor
    -- y nadie los vuelve a reportar: el AJ se queda esperando eternamente.
    if CFG.ONLY_NEW and ST.cursor then b.sinceSeq = ST.cursor end
    if game.JobId ~= "" then b.exclude = { game.JobId } end
    return b
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
local function label(parent, text, x, y, w, h, size, col, font)
    return mk("TextLabel", {
        Position = UDim2.new(0,x,0,y), Size = UDim2.new(0,w,0,h),
        BackgroundTransparency = 1, Font = font or Enum.Font.Gotham, TextSize = size or 11,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = col or C.txt2, Text = text,
    }, parent)
end
local function caption(parent, text, x, y, w)
    return mk("TextLabel", {
        Position = UDim2.new(0,x,0,y), Size = UDim2.new(0,w,0,12),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.mut, Text = text,
    }, parent)
end

-- ─────────────────────────────────────────────────────────────────────── root
local gui = mk("ScreenGui", {
    Name = "EAG_AJ_V4", ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
gui.Parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")

local W, H = 544, 408
local root = mk("Frame", {
    Size = UDim2.new(0, W, 0, H),
    Position = UDim2.new(0.5, -W/2, 0.5, -H/2),
    BackgroundColor3 = C.bg, BorderSizePixel = 0,
    Active = true, Draggable = true,
}, gui)
corner(root, 14)
stroke(root, C.line, 0.25)
mk("UIGradient", {
    Rotation = 125,
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(24, 20, 42)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(13, 14, 21)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 11, 16)),
    }),
}, root)

-- ── cabecera ──────────────────────────────────────────────────────────────
local header = mk("Frame", { Size = UDim2.new(1,0,0,46), BackgroundTransparency = 1 }, root)
mk("Frame", {
    Position = UDim2.new(0,0,1,-1), Size = UDim2.new(1,0,0,1),
    BackgroundColor3 = C.line, BorderSizePixel = 0, BackgroundTransparency = 0.45,
}, header)

do
    local badge = mk("Frame", {
        Position = UDim2.new(0,16,0,13), Size = UDim2.new(0,20,0,20),
        BackgroundColor3 = C.acc, BorderSizePixel = 0,
    }, header)
    corner(badge, 6)
    mk("UIGradient", { Rotation = 130, Color = ColorSequence.new(C.acc, C.acc2) }, badge)
end

label(header, "EAG", 44, 8, 30, 15, 13, C.acc2, Enum.Font.GothamBold)
label(header, "AUTO JOINER", 74, 8, 160, 15, 13, C.txt, Enum.Font.GothamBold)
local subLbl = label(header, "conectando con el hub", 44, 24, 300, 13, 10, C.mut)

local connPill = mk("Frame", {
    Position = UDim2.new(1,-186,0,13), Size = UDim2.new(0,140,0,20),
    BackgroundColor3 = C.card, BorderSizePixel = 0,
}, header)
round(connPill); stroke(connPill, C.line, 0.35)
local connDot = mk("Frame", {
    Position = UDim2.new(0,9,0,7), Size = UDim2.new(0,6,0,6),
    BackgroundColor3 = C.warn, BorderSizePixel = 0,
}, connPill)
round(connDot)
local connLbl = mk("TextLabel", {
    Position = UDim2.new(0,20,0,0), Size = UDim2.new(1,-25,1,0),
    BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.txt2, Text = "conectando",
}, connPill)

do
    local close = mk("TextButton", {
        Position = UDim2.new(1,-38,0,13), Size = UDim2.new(0,20,0,20),
        BackgroundColor3 = C.card, BorderSizePixel = 0, Text = "✕",
        Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.mut, AutoButtonColor = false,
    }, header)
    corner(close, 6); stroke(close, C.line, 0.35)
    close.MouseButton1Click:Connect(function() root.Visible = false end)
end

-- ── pestañas ──────────────────────────────────────────────────────────────
local tabRow = mk("Frame", {
    Position = UDim2.new(0,14,0,56), Size = UDim2.new(1,-28,0,28),
    BackgroundColor3 = C.bg2, BorderSizePixel = 0,
}, root)
corner(tabRow, 9)
pad(tabRow, 3, 3, 3, 3)
mk("UIListLayout", {
    FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0,3),
}, tabRow)

local function newPage()
    return mk("Frame", {
        Position = UDim2.new(0,14,0,94), Size = UDim2.new(1,-28,1,-108),
        BackgroundTransparency = 1, Visible = false,
    }, root)
end
local pgHunt, pgFilter, pgConfig, pgLog = newPage(), newPage(), newPage(), newPage()
local pages = { hunt = pgHunt, filter = pgFilter, config = pgConfig, log = pgLog }

local tabBtns, selectTab = {}, nil
local function mkTab(key, text, tip)
    local b = mk("TextButton", {
        Size = UDim2.new(0, 124, 1, 0), BackgroundColor3 = C.card,
        BackgroundTransparency = 1, BorderSizePixel = 0,
        Font = Enum.Font.GothamBold, TextSize = 10.5, TextColor3 = C.mut,
        Text = text, AutoButtonColor = false,
    }, tabRow)
    corner(b, 7)
    tabBtns[key] = b
    b.MouseButton1Click:Connect(function() selectTab(key) end)
    b.MouseEnter:Connect(function() subLbl.Text = tip end)
    return b
end
mkTab("hunt",   "CAZA",    "objetivos en vivo y salto automatico")
mkTab("filter", "FILTROS", "rareza, peso y frescura")
mkTab("config", "AJUSTES", "conexion con el hub y ritmo")
mkTab("log",    "LOG",     "registro de actividad")

selectTab = function(key)
    for k, p in pairs(pages) do p.Visible = (k == key) end
    for k, b in pairs(tabBtns) do
        local on = (k == key)
        TS:Create(b, TweenInfo.new(0.14), {
            BackgroundTransparency = on and 0 or 1,
        }):Play()
        b.BackgroundColor3 = C.card2
        b.TextColor3 = on and C.txt or C.mut
    end
end

-- ───────────────────────────────────────────────────────────────────────── log
local logList, renderLog
local function pushLog(txt, col)
    table.insert(ST.logs, 1, { t = os.date("%H:%M:%S"), s = txt, c = col or C.mut })
    if #ST.logs > 120 then table.remove(ST.logs) end
    print("[EAG-AJ]", txt)
    if renderLog then renderLog() end
end

-- ─────────────────────────────────────────────────────────────────── teleport
local function reportHop(jobId, ok, reason)
    task.spawn(function()
        httpJson("POST", "/api/hop", { jobId = jobId, ok = ok, client = CFG.CLIENT, reason = reason or "" })
    end)
end

local function doHop(target)
    if not target or not target.jobId then return end
    if target.jobId == game.JobId then
        pushLog("ya estas en ese server", C.warn)
        return
    end
    ST.lastHop = os.clock()
    ST.hops = ST.hops + 1
    if tonumber(target.seq) then
        ST.cursor = math.max(ST.cursor or 0, tonumber(target.seq))
    end

    pushLog(("salto -> %s · %s %s %s kg (hace %ds)"):format(
        tostring(target.jobId):sub(1,8), tostring(target.rarity), tostring(target.name),
        tostring(math.floor(tonumber(target.kg) or 0)),
        math.floor((tonumber(target.ageMs) or 0)/1000)), C.acc2)

    if canFile then
        pcall(function() writefile(PENDING, HS:JSONEncode({ jobId = target.jobId, at = os.time() })) end)
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

task.spawn(function()
    if canFile and isfile(PENDING) then
        local ok, t = pcall(function() return HS:JSONDecode(readfile(PENDING)) end)
        if ok and t and t.jobId then
            local landed = (t.jobId == game.JobId)
            reportHop(t.jobId, landed, landed and "ok" or "aterrizo en otro server")
            pushLog(landed and "aterrizaje confirmado" or "aterrizo en otro server",
                landed and C.ok or C.warn)
        end
        pcall(function() if delfile then delfile(PENDING) end end)
    end
end)

-- ═══════════════════════════════════════════════════════════════════════ CAZA
local autoCard = mk("Frame", {
    Size = UDim2.new(0,236,0,60), BackgroundColor3 = C.card, BorderSizePixel = 0,
}, pgHunt)
corner(autoCard, 11)
local autoStroke = stroke(autoCard, C.line, 0.5)

label(autoCard, "SALTO AUTOMATICO", 14, 11, 160, 13, 10.5, C.txt, Enum.Font.GothamBold)
local autoSub = mk("TextLabel", {
    Position = UDim2.new(0,14,0,28), Size = UDim2.new(0,150,0,24),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    TextColor3 = C.mut, TextWrapped = true, Text = "en pausa",
}, autoCard)

local sw = mk("TextButton", {
    Position = UDim2.new(1,-64,0,18), Size = UDim2.new(0,48,0,24),
    BackgroundColor3 = C.card2, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
}, autoCard)
round(sw)
local swStroke = stroke(sw, C.line, 0.35)
local knob = mk("Frame", {
    Position = UDim2.new(0,3,0,3), Size = UDim2.new(0,18,0,18),
    BackgroundColor3 = C.mut, BorderSizePixel = 0,
}, sw)
round(knob)

local function paintAuto()
    local t = TweenInfo.new(0.18, Enum.EasingStyle.Quad)
    TS:Create(knob, t, {
        Position = autoOn and UDim2.new(0,27,0,3) or UDim2.new(0,3,0,3),
        BackgroundColor3 = autoOn and C.ink or C.mut,
    }):Play()
    TS:Create(sw, t, { BackgroundColor3 = autoOn and C.ok or C.card2 }):Play()
    TS:Create(autoStroke, t, {
        Color = autoOn and C.ok or C.line, Transparency = autoOn and 0.55 or 0.5,
    }):Play()
    swStroke.Transparency = autoOn and 1 or 0.35
    if autoOn then
        autoSub.Text = CFG.ONLY_NEW and "solo hallazgos nuevos" or "cualquier hallazgo"
        autoSub.TextColor3 = C.ok
    else
        autoSub.Text = "en pausa"
        autoSub.TextColor3 = C.mut
    end
end

sw.MouseButton1Click:Connect(function()
    autoOn = not autoOn
    if autoOn then
        ST.cursor = ST.eggSeq
        pushLog(("auto join ON · ignorando los %d hallazgos previos"):format(ST.eggSeq), C.ok)
    else
        pushLog("auto join en pausa", C.mut)
    end
    paintAuto()
end)

-- tarjetas de estado
local statCards = {}
do
    local x = 246
    local function tile(key, cap)
        local f = mk("Frame", {
            Position = UDim2.new(0,x,0,0), Size = UDim2.new(0,80,0,60),
            BackgroundColor3 = C.card, BorderSizePixel = 0,
        }, pgHunt)
        corner(f, 11); stroke(f, C.line, 0.5)
        statCards[key] = mk("TextLabel", {
            Position = UDim2.new(0,0,0,13), Size = UDim2.new(1,0,0,20),
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 17,
            TextColor3 = C.txt, Text = "0",
        }, f)
        mk("TextLabel", {
            Position = UDim2.new(0,0,0,36), Size = UDim2.new(1,0,0,12),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 8.5,
            TextColor3 = C.mut, Text = cap,
        }, f)
        x = x + 86
    end
    tile("servers", "SERVERS")
    tile("matches", "OBJETIVOS")
    tile("hops",    "SALTOS")
end

-- ── banda de diagnostico: aparece solo cuando no hay objetivos ────────────
local diagCard = mk("Frame", {
    Position = UDim2.new(0,0,0,68), Size = UDim2.new(1,0,0,42),
    BackgroundColor3 = C.card, BorderSizePixel = 0, Visible = false,
}, pgHunt)
corner(diagCard, 10)
local diagStroke = stroke(diagCard, C.warn, 0.6)
local diagBar = mk("Frame", {
    Position = UDim2.new(0,0,0,9), Size = UDim2.new(0,3,1,-18),
    BackgroundColor3 = C.warn, BorderSizePixel = 0,
}, diagCard)
local diagTitle = label(diagCard, "", 14, 7, 380, 13, 10.5, C.warn, Enum.Font.GothamBold)
local diagBody  = mk("TextLabel", {
    Position = UDim2.new(0,14,0,22), Size = UDim2.new(1,-150,0,14),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.txt2,
    TextTruncate = Enum.TextTruncate.AtEnd, Text = "",
}, diagCard)

local diagBtn = mk("TextButton", {
    Position = UDim2.new(1,-132,0,9), Size = UDim2.new(0,120,0,24),
    BackgroundColor3 = C.card2, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
    TextSize = 9.5, TextColor3 = C.txt2, Text = "", AutoButtonColor = false, Visible = false,
}, diagCard)
corner(diagBtn, 7); stroke(diagBtn, C.line, 0.4)
local diagAction = nil
diagBtn.MouseButton1Click:Connect(function()
    if diagAction then diagAction() end
end)

caption(pgHunt, "OBJETIVOS EN VIVO", 2, 118, 200)

local list = mk("ScrollingFrame", {
    Position = UDim2.new(0,0,0,134), Size = UDim2.new(1,0,1,-134),
    BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = C.line,
    CanvasSize = UDim2.new(0,0,0,0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, pgHunt)
mk("UIListLayout", { Padding = UDim.new(0,5), SortOrder = Enum.SortOrder.LayoutOrder }, list)

local emptyLbl = mk("TextLabel", {
    Size = UDim2.new(1,0,0,48), BackgroundTransparency = 1,
    Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.mut, TextWrapped = true,
    Text = "sin objetivos",
}, list)

-- Coloca la lista segun haya o no banda de diagnostico visible.
local function layoutHunt(showDiag)
    diagCard.Visible = showDiag
    local y = showDiag and 118 or 76
    list.Position = UDim2.new(0,0,0, y + 16)
    list.Size = UDim2.new(1,0,1, -(y + 16))
    for _, c in ipairs(pgHunt:GetChildren()) do
        if c:IsA("TextLabel") and c.Text == "OBJETIVOS EN VIVO" then
            c.Position = UDim2.new(0,2,0,y)
        end
    end
end

local function buildRow(e, i)
    local row = mk("Frame", {
        Size = UDim2.new(1,-5,0,42), BackgroundColor3 = C.card,
        BorderSizePixel = 0, LayoutOrder = i,
    }, list)
    corner(row, 9)
    local rs = stroke(row, C.line, 0.6)
    local col = rc(e.rarity)

    mk("Frame", {
        Position = UDim2.new(0,0,0,9), Size = UDim2.new(0,3,1,-18),
        BackgroundColor3 = col, BorderSizePixel = 0,
    }, row)

    label(row, tostring(e.name), 14, 5, 200, 15, 12, C.txt, Enum.Font.GothamMedium)
        .TextTruncate = Enum.TextTruncate.AtEnd

    local age = math.floor((tonumber(e.ageMs) or 0) / 1000)
    local sub = ("%s · %s · %s/%s jug · hace %ds"):format(
        tostring(e.rarity),
        (e.area ~= nil and e.area ~= "" and e.area or "zona"),
        tostring(e.players or "?"), tostring(e.maxPlayers or "?"), age)
    label(row, sub, 14, 21, 260, 13, 10, C.mut).TextTruncate = Enum.TextTruncate.AtEnd

    local tag = mk("Frame", {
        Position = UDim2.new(1,-172,0,11), Size = UDim2.new(0,68,0,19),
        BackgroundColor3 = col, BorderSizePixel = 0, BackgroundTransparency = 0.86,
    }, row)
    round(tag); stroke(tag, col, 0.55)
    mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 10.5, TextColor3 = col,
        Text = ("%s kg"):format(tostring(math.floor((tonumber(e.kg) or 0) + 0.5))),
    }, tag)

    if e.claimed then
        mk("TextLabel", {
            Position = UDim2.new(1,-100,0,11), Size = UDim2.new(0,44,0,19),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 9.5,
            TextColor3 = C.warn, Text = "en uso",
        }, row)
    end

    local cp = mk("TextButton", {
        Position = UDim2.new(1,-54,0,11), Size = UDim2.new(0,21,0,20),
        BackgroundColor3 = C.card2, BorderSizePixel = 0, Text = "⧉",
        Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.mut, AutoButtonColor = false,
    }, row)
    corner(cp, 6)
    cp.MouseButton1Click:Connect(function()
        local set = setclipboard or toclipboard or (syn and syn.write_clipboard)
        if set then pcall(set, tostring(e.jobId)); pushLog("job id copiado", C.mut) end
    end)

    local join = mk("TextButton", {
        Position = UDim2.new(1,-29,0,11), Size = UDim2.new(0,23,0,20),
        BackgroundColor3 = C.acc, BorderSizePixel = 0, Text = "▶",
        Font = Enum.Font.GothamBold, TextSize = 9, TextColor3 = Color3.new(1,1,1),
        AutoButtonColor = false,
    }, row)
    corner(join, 6)
    join.MouseButton1Click:Connect(function() doHop(e) end)

    row.MouseEnter:Connect(function()
        TS:Create(rs, TweenInfo.new(0.12), { Color = col, Transparency = 0.4 }):Play()
    end)
    row.MouseLeave:Connect(function()
        TS:Create(rs, TweenInfo.new(0.12), { Color = C.line, Transparency = 0.6 }):Play()
    end)
end

-- Traduce el diagnostico del hub a una frase util y, cuando toca, a un boton
-- que arregla el problema de un clic.
local function paintDiag()
    if #ST.candidates > 0 then
        layoutHunt(false)
        return
    end
    local d = ST.diag
    emptyLbl.Visible = true
    diagAction = nil
    diagBtn.Visible = false

    if not ST.connected then
        layoutHunt(true)
        diagTitle.Text = "sin conexion con el hub"
        diagBody.Text = tostring(ST.lastErr or "no responde")
        diagTitle.TextColor3 = C.bad; diagBar.BackgroundColor3 = C.bad; diagStroke.Color = C.bad
        emptyLbl.Text = "revisa la URL y la API key en AJUSTES"
        return
    end

    if not d then layoutHunt(false); emptyLbl.Text = "consultando al hub…"; return end

    diagTitle.TextColor3 = C.warn; diagBar.BackgroundColor3 = C.warn; diagStroke.Color = C.warn

    -- Si el hub dice que SI hay objetivos libres, no hay nada que diagnosticar:
    -- es un desfase de un tick entre el feed y el claim.
    if (tonumber(d.passed) or 0) > 0 then
        layoutHunt(false)
        emptyLbl.Text = ("%d objetivo(s) disponibles · tomando…"):format(d.passed)
        return
    end

    if d.servers == 0 then
        layoutHunt(true)
        diagTitle.Text = "ningun ESP esta reportando"
        diagBody.Text = "el hub esta vacio: enciende el reporter en otra cuenta"
        emptyLbl.Text = "esperando a que algun ESP suba huevos"
        return
    end

    if d.rarityFilterUnknown then
        layoutHunt(true)
        diagTitle.TextColor3 = C.bad; diagBar.BackgroundColor3 = C.bad; diagStroke.Color = C.bad
        diagTitle.Text = "tus rarezas no existen en el juego"
        diagBody.Text = "ninguna de las marcadas coincide con la lista real"
        diagBtn.Text = "MARCAR LAS RARAS"
        diagBtn.Visible = true
        diagAction = function()
            CFG.RARITIES = {}
            for _, r in ipairs(ST.ladder) do
                if (tonumber(r.rank) or 0) >= 5 then
                    table.insert(CFG.RARITIES, r.name)
                end
            end
            save()
            pushLog("filtro de rarezas rehecho con la lista del hub", C.ok)
        end
        emptyLbl.Text = "arregla el filtro de rarezas"
        return
    end

    if d.total == 0 then
        layoutHunt(true)
        diagTitle.Text = "los servers estan vacios"
        diagBody.Text = ("%d servers reportando, 0 huevos ahora mismo"):format(d.servers)
        emptyLbl.Text = "esperando huevos"
        return
    end

    if d.top then
        layoutHunt(true)
        diagTitle.Text = ("%d huevos en el hub, ninguno te sirve"):format(d.total)
        local bits = {}
        for reason, n in pairs(d.drops or {}) do
            bits[#bits+1] = ("%d %s"):format(n, reason)
        end
        table.sort(bits)
        diagBody.Text = table.concat(bits, "  ·  ")

        if d.top.reason == "anterior al cursor" then
            diagBtn.Text = "ACEPTAR LOS DE AHORA"
            diagBtn.Visible = true
            diagAction = function()
                ST.cursor = 0
                pushLog("cursor a cero: tambien valen los hallazgos ya conocidos", C.warn)
            end
        elseif d.top.reason == "rareza no marcada" then
            diagBtn.Text = "IR A FILTROS"
            diagBtn.Visible = true
            diagAction = function() selectTab("filter") end
        end
        emptyLbl.Text = "ajusta los filtros o espera un hallazgo nuevo"
        return
    end

    layoutHunt(false)
    emptyLbl.Text = "sin objetivos"
end

local function renderList()
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    emptyLbl.Visible = (#ST.candidates == 0)
    for i, e in ipairs(ST.candidates) do
        if i <= 30 then buildRow(e, i) end
    end
    paintDiag()
end

-- ═════════════════════════════════════════════════════════════════════ FILTROS
local function field(parent, lbl, x, y, w, value, onChange)
    caption(parent, lbl, x + 2, y, w)
    local box = mk("TextBox", {
        Position = UDim2.new(0,x,0,y+15), Size = UDim2.new(0,w,0,28),
        BackgroundColor3 = C.card, BorderSizePixel = 0,
        Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.txt,
        ClearTextOnFocus = false, Text = tostring(value),
    }, parent)
    corner(box, 8)
    pad(box, 9, 9)
    local s = stroke(box, C.line, 0.5)
    box.Focused:Connect(function()
        TS:Create(s, TweenInfo.new(0.15), { Color = C.acc, Transparency = 0 }):Play()
    end)
    box.FocusLost:Connect(function()
        TS:Create(s, TweenInfo.new(0.15), { Color = C.line, Transparency = 0.5 }):Play()
        onChange(box.Text); save()
    end)
    return box
end

local function toggleRow(parent, x, y, w, text, get, set)
    local b = mk("TextButton", {
        Position = UDim2.new(0,x,0,y), Size = UDim2.new(0,w,0,30),
        BackgroundColor3 = C.card, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, parent)
    corner(b, 8)
    local s = stroke(b, C.line, 0.5)
    local mark = mk("Frame", {
        Position = UDim2.new(0,11,0,9), Size = UDim2.new(0,12,0,12),
        BackgroundColor3 = C.card2, BorderSizePixel = 0,
    }, b)
    corner(mark, 4)
    local ms = stroke(mark, C.line, 0.2)
    local tick = mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 9, TextColor3 = C.ink, Text = "✓",
    }, mark)
    local lbl = label(b, text, 31, 0, w - 40, 30, 11, C.txt2)
    lbl.TextYAlignment = Enum.TextYAlignment.Center
    local function paint()
        local on = get()
        tick.Visible = on
        mark.BackgroundColor3 = on and C.ok or C.card2
        ms.Color = on and C.ok or C.line
        lbl.TextColor3 = on and C.txt or C.mut
        s.Color = on and C.ok or C.line
        s.Transparency = on and 0.6 or 0.5
    end
    b.MouseButton1Click:Connect(function() set(not get()); paint(); save() end)
    paint()
    return b
end

caption(pgFilter, "RAREZAS ACEPTADAS", 2, 0, 200)
local ladderNote = mk("TextLabel", {
    Position = UDim2.new(1,-210,0,0), Size = UDim2.new(0,208,0,12),
    BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Right, TextColor3 = C.warn,
    Text = "", Visible = false,
}, pgFilter)

local chipHolder = mk("ScrollingFrame", {
    Position = UDim2.new(0,0,0,16), Size = UDim2.new(1,0,0,84),
    BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
    ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(0,0,0,0),
    AutomaticCanvasSize = Enum.AutomaticSize.Y,
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
            Size = UDim2.new(0, 22 + #r.name * 6.4, 0, 24),
            BackgroundColor3 = on and col or C.card, BorderSizePixel = 0, LayoutOrder = i,
            Font = Enum.Font.GothamBold, TextSize = 10,
            TextColor3 = on and C.ink or col, Text = r.name, AutoButtonColor = false,
        }, chipHolder)
        round(b)
        stroke(b, col, on and 1 or 0.6)
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
    local y = 106
    local function quick(text, x, w, fn)
        local b = mk("TextButton", {
            Position = UDim2.new(0,x,0,y), Size = UDim2.new(0,w,0,22),
            BackgroundColor3 = C.card, BorderSizePixel = 0, Font = Enum.Font.GothamMedium,
            TextSize = 10, TextColor3 = C.txt2, Text = text, AutoButtonColor = false,
        }, pgFilter)
        corner(b, 6); stroke(b, C.line, 0.5)
        b.MouseButton1Click:Connect(function() fn(); save(); renderChips() end)
    end
    quick("todas", 0, 68, function()
        CFG.RARITIES = {}
        for _, r in ipairs(ST.ladder) do table.insert(CFG.RARITIES, r.name) end
    end)
    quick("ninguna", 74, 68, function() CFG.RARITIES = {} end)
    quick("solo raras", 148, 84, function()
        CFG.RARITIES = {}
        for _, r in ipairs(ST.ladder) do
            if (tonumber(r.rank) or 0) >= 5 then table.insert(CFG.RARITIES, r.name) end
        end
    end)
end

caption(pgFilter, "PESO Y FRESCURA", 2, 140, 200)
field(pgFilter, "KG MINIMO", 0, 156, 118, CFG.MIN_KG, function(v) CFG.MIN_KG = tonumber(v) or 0 end)
field(pgFilter, "KG MAXIMO · 0 = libre", 128, 156, 158, CFG.MAX_KG, function(v) CFG.MAX_KG = tonumber(v) or 0 end)
field(pgFilter, "EDAD MAX (s)", 296, 156, 110, CFG.MAX_AGE, function(v) CFG.MAX_AGE = math.max(0, tonumber(v) or 0) end)

caption(pgFilter, "REGLAS", 2, 204, 200)
toggleRow(pgFilter, 0, 220, 244, "ignorar lo que ya habia al encender",
    function() return CFG.ONLY_NEW end,
    function(v) CFG.ONLY_NEW = v; if v then ST.cursor = ST.eggSeq end end)
toggleRow(pgFilter, 252, 220, 244, "solo servers con hueco",
    function() return CFG.HAS_SLOT end,
    function(v) CFG.HAS_SLOT = v end)

mk("TextLabel", {
    Position = UDim2.new(0,2,0,256), Size = UDim2.new(1,-4,0,44),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    TextColor3 = C.mut, TextWrapped = true,
    Text = "Lo que evita los hallazgos viejos es EDAD MAX, no la casilla. "
        .. "Enciendela solo si quieres descartar ademas todo lo que el hub ya "
        .. "conocia: si el reporter paso por un server antes que tu, esos "
        .. "huevos no volveran a aparecer y el AJ puede quedarse sin nada.",
}, pgFilter)

-- ══════════════════════════════════════════════════════════════════════ AJUSTES
caption(pgConfig, "CONEXION", 2, 0, 200)
field(pgConfig, "HUB URL", 0, 16, 502, CFG.HUB, function(v) CFG.HUB = (v:gsub("%s+",""):gsub("/+$","")) end)
field(pgConfig, "API KEY", 0, 62, 310, CFG.KEY, function(v) CFG.KEY = (v:gsub("%s+","")) end)
field(pgConfig, "NOMBRE DE ESTE CLIENTE", 320, 62, 182, CFG.CLIENT, function(v) CFG.CLIENT = v end)

caption(pgConfig, "RITMO", 2, 110, 200)
field(pgConfig, "POLL (s)", 0, 126, 96, CFG.POLL, function(v) CFG.POLL = math.max(2, tonumber(v) or 4) end)
field(pgConfig, "COOLDOWN (s)", 104, 126, 110, CFG.COOLDOWN, function(v) CFG.COOLDOWN = math.max(3, tonumber(v) or 8) end)
field(pgConfig, "ESPERA CLAIM (s)", 222, 126, 118, CFG.WAIT, function(v) CFG.WAIT = math.max(5, math.min(50, tonumber(v) or 20)) end)
field(pgConfig, "RAW · auto reload", 348, 126, 154, CFG.SCRIPT_URL, function(v) CFG.SCRIPT_URL = v end)

local testLbl
do
    local test = mk("TextButton", {
        Position = UDim2.new(0,0,0,186), Size = UDim2.new(0,156,0,30),
        BackgroundColor3 = C.acc, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, pgConfig)
    corner(test, 8)
    mk("UIGradient", { Rotation = 20, Color = ColorSequence.new(C.acc, Color3.fromRGB(92,62,240)) }, test)
    testLbl = mk("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 11,
        TextColor3 = Color3.fromRGB(255,255,255), Text = "PROBAR CONEXION",
    }, test)
    test.MouseButton1Click:Connect(function()
        testLbl.Text = "PROBANDO…"
        task.spawn(function()
            local res, err = httpJson("GET", "/api/meta")
            if res then
                testLbl.Text = "CONECTADO ✓"
                pushLog(("hub ok · %d servers · %d huevos · cursor %d")
                    :format(res.servers or 0, res.eggs or 0, res.eggSeq or 0), C.ok)
            else
                testLbl.Text = "SIN CONEXION"
                pushLog("hub error: " .. tostring(err), C.bad)
            end
            task.delay(2, function() testLbl.Text = "PROBAR CONEXION" end)
        end)
    end)

    mk("TextLabel", {
        Position = UDim2.new(0,168,0,186), Size = UDim2.new(1,-168,0,34),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
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
    }, pgLog)
    mk("UIListLayout", { Padding = UDim.new(0,2), SortOrder = Enum.SortOrder.LayoutOrder }, logList)

    renderLog = function()
        for _, c in ipairs(logList:GetChildren()) do
            if c:IsA("Frame") then c:Destroy() end
        end
        for i, e in ipairs(ST.logs) do
            if i > 60 then break end
            local row = mk("Frame", {
                Size = UDim2.new(1,-5,0,18), BackgroundTransparency = 1, LayoutOrder = i,
            }, logList)
            mk("Frame", {
                Position = UDim2.new(0,0,0,6), Size = UDim2.new(0,2,0,7),
                BackgroundColor3 = e.c, BorderSizePixel = 0,
            }, row)
            label(row, e.t, 9, 0, 54, 18, 10, C.mut, Enum.Font.Code)
            label(row, e.s, 66, 0, 420, 18, 10.5, e.c).TextTruncate = Enum.TextTruncate.AtEnd
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
    elseif autoOn and CFG.ONLY_NEW then
        subLbl.Text = ("cursor #%d · solo hallazgos posteriores"):format(ST.cursor or 0)
        subLbl.TextColor3 = C.mut
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
            ST.connected = true
            ST.lastErr = nil
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
            ST.connected = false
            ST.lastErr = err
        end

        -- /api/feed es GET: la query sale del mismo filtro que usan claim y diag.
        local q = "?limit=30"
        if #CFG.RARITIES > 0 then q = q .. "&rarities=" .. HS:UrlEncode(table.concat(CFG.RARITIES, ",")) end
        if (tonumber(CFG.MIN_KG) or 0) > 0 then q = q .. "&minKg=" .. tostring(CFG.MIN_KG) end
        if (tonumber(CFG.MAX_KG) or 0) > 0 then q = q .. "&maxKg=" .. tostring(CFG.MAX_KG) end
        if (tonumber(CFG.MAX_AGE) or 0) > 0 then q = q .. "&maxAgeSec=" .. tostring(CFG.MAX_AGE) end
        if CFG.HAS_SLOT then q = q .. "&hasSlot=1" end
        if CFG.ONLY_NEW and ST.cursor then
            q = q .. "&sinceSeq=" .. tostring(ST.cursor) .. "&newest=1"
        end

        local feed = httpJson("GET", "/api/feed" .. q)
        if feed and feed.eggs then ST.candidates = feed.eggs end

        -- Solo preguntamos "por que no hay nada" cuando de verdad no hay nada.
        if ST.connected and #ST.candidates == 0 then
            ST.diag = httpJson("POST", "/api/diag", filterBody())
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
            local body = filterBody()
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
UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.RightControl then
        root.Visible = not root.Visible
    end
end)

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
pushLog("AJ v4 listo · " .. CFG.HUB, C.acc2)
