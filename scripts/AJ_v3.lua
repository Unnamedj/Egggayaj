--[[ ─────────────────────────────────────────────────────────────────────────
     EAG · AJ  v3   ·   by joszz
     Auto joiner conectado al EAG HUB.

     Lo que cambia frente al v2:

       1. NO SALTA A HALLAZGOS VIEJOS. Al encender el auto join, el AJ apunta
          el cursor del hub (eggSeq) y a partir de ahi solo acepta huevos
          descubiertos DESPUES de ese momento. Nada de aterrizar en un server
          donde el huevo lleva 6 minutos y ya se lo llevaron.
       2. Rarezas de verdad. La lista sale de la escalera real del juego que
          publica el hub (Common..Titan, con Cosmic, Eternal, Exotic, Divine…),
          asi que marcar "Cosmic" ahora significa algo. Antes esas rarezas ni
          existian en la lista y se ordenaban como si fueran basura.
       3. Panel mas pequeño y mas limpio: 560x392 en vez de 690x460.

     Panel: Right Control
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
    MAX_AGE    = 90,        -- s. Ni con el cursor: un huevo mas viejo no vale
    RARITIES   = { "Legendary", "Mythic", "Cosmic", "Secret", "Eternal", "Divine", "Titan" },
    HAS_SLOT   = true,
    ONLY_NEW   = true,      -- el cambio grande del v3
    SCRIPT_URL = "",
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
    bg    = Color3.fromRGB(9, 10, 15),
    rail  = Color3.fromRGB(13, 14, 21),
    card  = Color3.fromRGB(21, 23, 33),
    card2 = Color3.fromRGB(28, 31, 43),
    line  = Color3.fromRGB(38, 42, 57),
    txt   = Color3.fromRGB(233, 236, 245),
    txt2  = Color3.fromRGB(158, 166, 185),
    mut   = Color3.fromRGB(108, 116, 138),
    acc   = Color3.fromRGB(124, 92, 255),
    acc2  = Color3.fromRGB(34, 211, 238),
    ok    = Color3.fromRGB(52, 211, 153),
    bad   = Color3.fromRGB(251, 95, 120),
    warn  = Color3.fromRGB(251, 191, 36),
    ink   = Color3.fromRGB(10, 12, 18),
}

-- "#7c5cff" -> Color3. El hub manda los colores de rareza en hex.
local function hex(h)
    h = tostring(h or ""):gsub("#", "")
    if #h ~= 6 then return C.mut end
    return Color3.fromRGB(
        tonumber(h:sub(1, 2), 16) or 120,
        tonumber(h:sub(3, 4), 16) or 120,
        tonumber(h:sub(5, 6), 16) or 120)
end

local ST = {
    connected = false,
    servers = 0, eggsLive = 0,
    hops = 0, fails = 0,
    lastHop = 0, latency = -1,
    eggSeq = 0,       -- ultimo cursor conocido del hub
    cursor = nil,     -- desde donde aceptamos huevos (nil = aun no arrancado)
    ladder = {},      -- { {name, rank, color} } de mas raro a mas comun
    colors = {},      -- name(lower) -> Color3
    candidates = {},
    logs = {},
    lastErr = nil,
}
local autoOn = false

local function rc(r)
    return ST.colors[tostring(r):lower()] or C.mut
end

-- ───────────────────────────────────────────────────────────── persistencia
local FILE    = "eag_aj.json"
local PENDING = "eag_aj_pending.json"
local canFile = (writefile and readfile and isfile) ~= nil

local function save()
    if not canFile then return end
    pcall(function() writefile(FILE, HS:JSONEncode(CFG)) end)
end
local function load()
    if not canFile or not isfile(FILE) then return end
    pcall(function()
        for k, v in pairs(HS:JSONDecode(readfile(FILE))) do
            if CFG[k] ~= nil then CFG[k] = v end
        end
    end)
end
load()

-- ─────────────────────────────────────────────────────────────────────── http
local function httpJson(method, path, body)
    if not httpreq then return nil, "el executor no tiene request()" end
    local opts = {
        Url = CFG.HUB .. path,
        Method = method,
        Headers = { ["Content-Type"] = "application/json", ["x-eag-key"] = CFG.KEY },
    }
    if body then opts.Body = HS:JSONEncode(body) end
    local ok, res = pcall(httpreq, opts)
    if not ok then return nil, tostring(res) end
    local code = res.StatusCode or res.Status or 0
    if code == 401 then return nil, "API key incorrecta" end
    if code < 200 or code >= 300 then return nil, "HTTP " .. tostring(code) end
    local dok, dec = pcall(function() return HS:JSONDecode(res.Body) end)
    if not dok then return nil, "respuesta ilegible" end
    if type(dec) == "table" and tonumber(dec.eggSeq) then ST.eggSeq = tonumber(dec.eggSeq) end
    return dec
end

-- ───────────────────────────────────────────────────────────────── UI helpers
local function mk(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end
local function corner(o, r) mk("UICorner", { CornerRadius = UDim.new(0, r or 9) }, o) end
local function round(o)     mk("UICorner", { CornerRadius = UDim.new(1, 0) }, o) end
local function stroke(o, col, tr, th)
    return mk("UIStroke", { Color = col or C.line, Transparency = tr or 0, Thickness = th or 1 }, o)
end

-- Iconos dibujados con frames sobre una rejilla de 16: nada de emojis, que
-- cambian de forma segun la plataforma.
local function icon(kind, parent, size, col)
    size = size or 16
    local box = mk("Frame", { Size = UDim2.new(0, size, 0, size), BackgroundTransparency = 1 }, parent)
    local u = size / 16
    local function bar(x, y, w, h, rot, r)
        local f = mk("Frame", {
            Position = UDim2.new(0, x*u, 0, y*u), Size = UDim2.new(0, w*u, 0, h*u),
            BackgroundColor3 = col, BorderSizePixel = 0, Rotation = rot or 0,
        }, box)
        if r then corner(f, r) end
        return f
    end
    local function ring(x, y, d, th)
        local f = mk("Frame", {
            Position = UDim2.new(0, x*u, 0, y*u), Size = UDim2.new(0, d*u, 0, d*u),
            BackgroundTransparency = 1,
        }, box)
        round(f); stroke(f, col, 0, th or 1.6); return f
    end
    local function dot(x, y, d)
        local f = mk("Frame", {
            Position = UDim2.new(0, x*u, 0, y*u), Size = UDim2.new(0, d*u, 0, d*u),
            BackgroundColor3 = col, BorderSizePixel = 0,
        }, box)
        round(f); return f
    end

    if kind == "target" then
        ring(1,1,14,1.6); ring(4.5,4.5,7,1.6); dot(7,7,2)
    elseif kind == "filter" then
        bar(1,3,14,1.8,0,1); bar(3.5,7.1,9,1.8,0,1); bar(6,11.2,4,1.8,0,1)
    elseif kind == "gear" then
        ring(3,3,10,1.8); dot(6.6,6.6,2.8)
        bar(7.1,0,1.8,3,0,1); bar(7.1,13,1.8,3,0,1)
        bar(0,7.1,3,1.8,0,1); bar(13,7.1,3,1.8,0,1)
    elseif kind == "log" then
        dot(1,2.4,2); dot(1,7,2); dot(1,11.6,2)
        bar(5,3,10,1.6,0,1); bar(5,7.6,10,1.6,0,1); bar(5,12.2,7,1.6,0,1)
    elseif kind == "bolt" then
        bar(6.5,0.7,2,7.6,23,1); bar(6.2,7.1,5.6,1.9,0,1); bar(7.5,7.7,2,7.6,23,1)
    elseif kind == "check" then
        bar(3.5,7.5,2,5,-37,1); bar(8.5,2.7,2,10.6,41,1)
    elseif kind == "cross" then
        bar(7.1,1.5,1.9,13,45,1); bar(7.1,1.5,1.9,13,-45,1)
    elseif kind == "copy" then
        local a = mk("Frame", { Position=UDim2.new(0,1*u,0,1*u), Size=UDim2.new(0,9*u,0,9*u),
            BackgroundTransparency=1 }, box)
        corner(a, math.max(2, 2*u)); stroke(a, col, 0, 1.5)
        local b = mk("Frame", { Position=UDim2.new(0,6*u,0,6*u), Size=UDim2.new(0,9*u,0,9*u),
            BackgroundColor3=C.card, BorderSizePixel=0 }, box)
        corner(b, math.max(2, 2*u)); stroke(b, col, 0, 1.5)
    elseif kind == "play" then
        bar(6.4,2.4,1.9,7.2,-45,1); bar(6.4,6.6,1.9,7.2,45,1)
    end
    return box
end

-- ─────────────────────────────────────────────────────────────────────── root
local gui = mk("ScreenGui", {
    Name = "EAG_AJ", ResetOnSpawn = false,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
})
gui.Parent = (gethui and gethui()) or LP:WaitForChild("PlayerGui")

local W, H = 560, 392
local root = mk("Frame", {
    Size = UDim2.new(0, W, 0, H),
    Position = UDim2.new(0.5, -W/2, 0.5, -H/2),
    BackgroundColor3 = C.bg, BorderSizePixel = 0,
    Active = true, Draggable = true,
}, gui)
corner(root, 14)
stroke(root, C.line, 0.3)
mk("UIGradient", {
    Rotation = 120,
    Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(21, 18, 36)),
        ColorSequenceKeypoint.new(0.55, Color3.fromRGB(11, 12, 19)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(9, 10, 15)),
    }),
}, root)

-- ── cabecera ──────────────────────────────────────────────────────────────
local header = mk("Frame", { Size = UDim2.new(1,0,0,44), BackgroundTransparency = 1 }, root)
mk("Frame", {
    Position = UDim2.new(0,0,1,-1), Size = UDim2.new(1,0,0,1),
    BackgroundColor3 = C.line, BorderSizePixel = 0, BackgroundTransparency = 0.4,
}, header)

do
    local badge = mk("Frame", {
        Position = UDim2.new(0,14,0,12), Size = UDim2.new(0,20,0,20),
        BackgroundColor3 = C.acc, BorderSizePixel = 0,
    }, header)
    corner(badge, 6)
    mk("UIGradient", { Rotation = 130, Color = ColorSequence.new(C.acc, C.acc2) }, badge)
    icon("bolt", badge, 12, C.ink).Position = UDim2.new(0,4,0,4)
end

mk("TextLabel", {
    Position = UDim2.new(0,42,0,7), Size = UDim2.new(0,180,0,14),
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12.5,
    TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.txt, Text = "EAG · AUTO JOINER",
}, header)

local subLbl = mk("TextLabel", {
    Position = UDim2.new(0,42,0,22), Size = UDim2.new(0,300,0,12),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10.5,
    TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.mut, Text = "conectando con el hub",
}, header)

local connPill = mk("Frame", {
    Position = UDim2.new(1,-176,0,12), Size = UDim2.new(0,130,0,20),
    BackgroundColor3 = C.card, BorderSizePixel = 0,
}, header)
round(connPill); stroke(connPill, C.line, 0.35)
local dot = mk("Frame", {
    Position = UDim2.new(0,9,0,7), Size = UDim2.new(0,6,0,6),
    BackgroundColor3 = C.warn, BorderSizePixel = 0,
}, connPill)
round(dot)
local connLbl = mk("TextLabel", {
    Position = UDim2.new(0,20,0,0), Size = UDim2.new(1,-25,1,0),
    BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.txt2, Text = "conectando",
}, connPill)

do
    local close = mk("TextButton", {
        Position = UDim2.new(1,-38,0,12), Size = UDim2.new(0,20,0,20),
        BackgroundColor3 = C.card, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, header)
    corner(close, 6); stroke(close, C.line, 0.35)
    icon("cross", close, 9, C.mut).Position = UDim2.new(0,5.5,0,5.5)
    close.MouseButton1Click:Connect(function() root.Visible = false end)
end

-- ── rail + paginas ────────────────────────────────────────────────────────
local rail = mk("Frame", {
    Position = UDim2.new(0,0,0,44), Size = UDim2.new(0,46,1,-44),
    BackgroundColor3 = C.rail, BorderSizePixel = 0, BackgroundTransparency = 0.4,
}, root)
mk("Frame", {
    Position = UDim2.new(1,-1,0,0), Size = UDim2.new(0,1,1,0),
    BackgroundColor3 = C.line, BorderSizePixel = 0, BackgroundTransparency = 0.4,
}, rail)

local host = mk("Frame", {
    Position = UDim2.new(0,46,0,44), Size = UDim2.new(1,-46,1,-44), BackgroundTransparency = 1,
}, root)

local function newPage()
    return mk("Frame", {
        Position = UDim2.new(0,14,0,12), Size = UDim2.new(1,-28,1,-24),
        BackgroundTransparency = 1, Visible = false,
    }, host)
end
local pgHunt, pgFilter, pgConfig, pgLog = newPage(), newPage(), newPage(), newPage()

local tabs, selectTab = {}, nil
local function railBtn(kind, key, y, tip)
    local b = mk("TextButton", {
        Position = UDim2.new(0,8,0,y), Size = UDim2.new(0,30,0,30),
        BackgroundColor3 = C.card, BackgroundTransparency = 1,
        BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, rail)
    corner(b, 9)
    local ic = icon(kind, b, 16, C.mut)
    ic.Position = UDim2.new(0,7,0,7)
    local mark = mk("Frame", {
        Position = UDim2.new(0,-8,0,9), Size = UDim2.new(0,3,0,12),
        BackgroundColor3 = C.acc, BorderSizePixel = 0, Visible = false,
    }, b)
    corner(mark, 2)
    tabs[key] = { btn = b, ic = ic, mark = mark }
    b.MouseButton1Click:Connect(function() selectTab(key) end)
    b.MouseEnter:Connect(function() subLbl.Text = tip end)
    return b
end

railBtn("target", "hunt",   12,  "caza: objetivos y salto automatico")
railBtn("filter", "filter", 50,  "filtros de rareza, peso y frescura")
railBtn("gear",   "config", 88,  "conexion con el hub")
railBtn("log",    "log",    126, "registro de actividad")

local function paintIcon(holder, col)
    for _, d in ipairs(holder:GetDescendants()) do
        if d:IsA("Frame") and d.BackgroundTransparency < 1 then d.BackgroundColor3 = col end
        if d:IsA("UIStroke") then d.Color = col end
    end
    for _, d in ipairs(holder:GetChildren()) do
        if d:IsA("Frame") and d.BackgroundTransparency < 1 then d.BackgroundColor3 = col end
    end
end

selectTab = function(key)
    pgHunt.Visible   = (key == "hunt")
    pgFilter.Visible = (key == "filter")
    pgConfig.Visible = (key == "config")
    pgLog.Visible    = (key == "log")
    for k, t in pairs(tabs) do
        local on = (k == key)
        t.mark.Visible = on
        TS:Create(t.btn, TweenInfo.new(0.15), { BackgroundTransparency = on and 0 or 1 }):Play()
        paintIcon(t.ic, on and C.txt or C.mut)
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
    -- El cursor avanza al huevo que acabamos de tomar: no lo volvemos a mirar.
    if tonumber(target.seq) then
        ST.cursor = math.max(ST.cursor or 0, tonumber(target.seq))
    end

    pushLog(("salto -> %s · %s %s %.0f kg (hace %ds)"):format(
        target.jobId:sub(1,8), tostring(target.rarity), tostring(target.name),
        tonumber(target.kg) or 0, math.floor((tonumber(target.ageMs) or 0)/1000)), C.acc2)

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

-- ═══════════════════════════════════════════════════════════════════════ HUNT
local autoCard = mk("Frame", {
    Size = UDim2.new(0,222,0,56), BackgroundColor3 = C.card, BorderSizePixel = 0,
}, pgHunt)
corner(autoCard, 10)
local autoStroke = stroke(autoCard, C.line, 0.5)

mk("TextLabel", {
    Position = UDim2.new(0,13,0,10), Size = UDim2.new(0,140,0,13),
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 11,
    TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.txt, Text = "SALTO AUTOMATICO",
}, autoCard)

local autoSub = mk("TextLabel", {
    Position = UDim2.new(0,13,0,26), Size = UDim2.new(0,150,0,20),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    TextColor3 = C.mut, TextWrapped = true, Text = "en pausa",
}, autoCard)

local sw = mk("TextButton", {
    Position = UDim2.new(1,-62,0,16), Size = UDim2.new(0,48,0,24),
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
        Color = autoOn and C.ok or C.line, Transparency = autoOn and 0.6 or 0.5,
    }):Play()
    swStroke.Transparency = autoOn and 1 or 0.35
    if autoOn then
        autoSub.Text = CFG.ONLY_NEW and "solo hallazgos nuevos" or "buscando objetivo…"
        autoSub.TextColor3 = C.ok
    else
        autoSub.Text = "en pausa"
        autoSub.TextColor3 = C.mut
    end
end

sw.MouseButton1Click:Connect(function()
    autoOn = not autoOn
    if autoOn then
        -- Aqui esta el arreglo del v3: al encender, el reloj se pone a cero.
        -- Todo lo que el hub ya conocia queda fuera de juego.
        ST.cursor = ST.eggSeq
        pushLog(("auto join ON · ignorando los %d hallazgos anteriores"):format(ST.eggSeq), C.ok)
    else
        pushLog("auto join en pausa", C.mut)
    end
    paintAuto()
end)

-- ── tarjetas de estado ────────────────────────────────────────────────────
local statCards = {}
do
    local x = 230
    local function tile(key, cap)
        local f = mk("Frame", {
            Position = UDim2.new(0,x,0,0), Size = UDim2.new(0,84,0,56),
            BackgroundColor3 = C.card, BorderSizePixel = 0,
        }, pgHunt)
        corner(f, 10); stroke(f, C.line, 0.5)
        statCards[key] = mk("TextLabel", {
            Position = UDim2.new(0,0,0,11), Size = UDim2.new(1,0,0,20),
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 17,
            TextColor3 = C.txt, Text = "0",
        }, f)
        mk("TextLabel", {
            Position = UDim2.new(0,0,0,33), Size = UDim2.new(1,0,0,12),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 9,
            TextColor3 = C.mut, Text = cap,
        }, f)
        x = x + 90
    end
    tile("servers", "SERVERS")
    tile("matches", "OBJETIVOS")
    tile("hops",    "SALTOS")
end

mk("TextLabel", {
    Position = UDim2.new(0,2,0,66), Size = UDim2.new(1,-4,0,12),
    BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9,
    TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.mut,
    Text = "OBJETIVOS EN VIVO",
}, pgHunt)

local list = mk("ScrollingFrame", {
    Position = UDim2.new(0,0,0,82), Size = UDim2.new(1,0,1,-82),
    BackgroundTransparency = 1, BorderSizePixel = 0,
    ScrollBarThickness = 3, ScrollBarImageColor3 = C.line,
    CanvasSize = UDim2.new(0,0,0,0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
}, pgHunt)
mk("UIListLayout", { Padding = UDim.new(0,5), SortOrder = Enum.SortOrder.LayoutOrder }, list)

local emptyLbl = mk("TextLabel", {
    Size = UDim2.new(1,0,0,60), BackgroundTransparency = 1,
    Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.mut, TextWrapped = true,
    Text = "ningun huevo cumple los filtros todavia",
}, list)

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

    mk("TextLabel", {
        Position = UDim2.new(0,13,0,5), Size = UDim2.new(0,190,0,15),
        BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        TextColor3 = C.txt, Text = tostring(e.name),
    }, row)

    local age = math.floor((tonumber(e.ageMs) or 0) / 1000)
    mk("TextLabel", {
        Position = UDim2.new(0,13,0,21), Size = UDim2.new(0,250,0,13),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
        TextColor3 = C.mut,
        Text = ("%s · %s · %s/%s jug · hace %ds"):format(
            tostring(e.rarity), (e.area ~= nil and e.area ~= "" and e.area or "zona"),
            tostring(e.players or "?"), tostring(e.maxPlayers or "?"), age),
    }, row)

    local tag = mk("Frame", {
        Position = UDim2.new(1,-168,0,11), Size = UDim2.new(0,66,0,19),
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
            Position = UDim2.new(1,-98,0,11), Size = UDim2.new(0,44,0,19),
            BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 9.5,
            TextColor3 = C.warn, Text = "en uso",
        }, row)
    end

    local cp = mk("TextButton", {
        Position = UDim2.new(1,-52,0,11), Size = UDim2.new(0,20,0,20),
        BackgroundColor3 = C.card2, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, row)
    corner(cp, 6)
    icon("copy", cp, 11, C.mut).Position = UDim2.new(0,4.5,0,4.5)
    cp.MouseButton1Click:Connect(function()
        local set = setclipboard or toclipboard or (syn and syn.write_clipboard)
        if set then pcall(set, tostring(e.jobId)); pushLog("job id copiado", C.mut) end
    end)

    local join = mk("TextButton", {
        Position = UDim2.new(1,-28,0,11), Size = UDim2.new(0,22,0,20),
        BackgroundColor3 = C.acc, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, row)
    corner(join, 6)
    icon("play", join, 11, Color3.fromRGB(255,255,255)).Position = UDim2.new(0,5.5,0,4.5)
    join.MouseButton1Click:Connect(function() doHop(e) end)

    row.MouseEnter:Connect(function()
        TS:Create(rs, TweenInfo.new(0.12), { Color = col, Transparency = 0.4 }):Play()
    end)
    row.MouseLeave:Connect(function()
        TS:Create(rs, TweenInfo.new(0.12), { Color = C.line, Transparency = 0.6 }):Play()
    end)
end

local function renderList()
    for _, c in ipairs(list:GetChildren()) do
        if c:IsA("Frame") then c:Destroy() end
    end
    emptyLbl.Visible = (#ST.candidates == 0)
    if #ST.candidates == 0 then
        emptyLbl.Text = (CFG.ONLY_NEW and autoOn)
            and "esperando un hallazgo nuevo…\n(los anteriores se ignoran a proposito)"
            or "ningun huevo cumple los filtros todavia"
    end
    for i, e in ipairs(ST.candidates) do
        if i <= 30 then buildRow(e, i) end
    end
end

-- ═════════════════════════════════════════════════════════════════════ FILTROS
local function sectionLabel(parent, text, y)
    return mk("TextLabel", {
        Position = UDim2.new(0,2,0,y), Size = UDim2.new(1,-4,0,12),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.mut, Text = text,
    }, parent)
end

local function field(parent, label, x, y, w, value, onChange)
    mk("TextLabel", {
        Position = UDim2.new(0,x+2,0,y), Size = UDim2.new(0,w,0,12),
        BackgroundTransparency = 1, Font = Enum.Font.GothamMedium, TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.mut, Text = label,
    }, parent)
    local box = mk("TextBox", {
        Position = UDim2.new(0,x,0,y+15), Size = UDim2.new(0,w,0,28),
        BackgroundColor3 = C.card, BorderSizePixel = 0,
        Font = Enum.Font.Gotham, TextSize = 11, TextColor3 = C.txt,
        ClearTextOnFocus = false, Text = tostring(value),
    }, parent)
    corner(box, 8)
    mk("UIPadding", { PaddingLeft = UDim.new(0,9), PaddingRight = UDim.new(0,9) }, box)
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
        Position = UDim2.new(0,10,0,9), Size = UDim2.new(0,12,0,12),
        BackgroundColor3 = C.card2, BorderSizePixel = 0,
    }, b)
    corner(mark, 4)
    local ms = stroke(mark, C.line, 0.2)
    local chk = icon("check", mark, 9, C.ink)
    chk.Position = UDim2.new(0,1.5,0,1.5)
    local lbl = mk("TextLabel", {
        Position = UDim2.new(0,30,0,0), Size = UDim2.new(1,-38,1,0),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.txt2, Text = text,
    }, b)
    local function paint()
        local on = get()
        chk.Visible = on
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

sectionLabel(pgFilter, "RAREZAS ACEPTADAS", 0)
local chipHolder = mk("ScrollingFrame", {
    Position = UDim2.new(0,0,0,16), Size = UDim2.new(1,0,0,86),
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
    for i, r in ipairs(ST.ladder) do
        local on, col = hasRarity(r.name), rc(r.name)
        local b = mk("TextButton", {
            Size = UDim2.new(0, 20 + #r.name * 6.2, 0, 24),
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

sectionLabel(pgFilter, "PESO Y FRESCURA", 110)
field(pgFilter, "KG MINIMO", 0, 126, 120, CFG.MIN_KG, function(v)
    CFG.MIN_KG = tonumber(v) or 0
end)
field(pgFilter, "KG MAXIMO · 0 = sin limite", 130, 126, 160, CFG.MAX_KG, function(v)
    CFG.MAX_KG = tonumber(v) or 0
end)
field(pgFilter, "EDAD MAX (s)", 300, 126, 110, CFG.MAX_AGE, function(v)
    CFG.MAX_AGE = math.max(0, tonumber(v) or 0)
end)

sectionLabel(pgFilter, "REGLAS", 174)
toggleRow(pgFilter, 0, 190, 250, "solo hallazgos nuevos",
    function() return CFG.ONLY_NEW end,
    function(v)
        CFG.ONLY_NEW = v
        if v then ST.cursor = ST.eggSeq end
    end)
toggleRow(pgFilter, 258, 190, 220, "solo servers con hueco",
    function() return CFG.HAS_SLOT end,
    function(v) CFG.HAS_SLOT = v end)

mk("TextLabel", {
    Position = UDim2.new(0,2,0,228), Size = UDim2.new(1,-4,0,34),
    BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
    TextColor3 = C.mut, TextWrapped = true,
    Text = "\"Solo hallazgos nuevos\" descarta todo lo que el hub ya conocia al encender el auto join. Es lo que evita aterrizar en un server donde el huevo ya se lo llevaron.",
}, pgFilter)

-- ══════════════════════════════════════════════════════════════════════ CONFIG
sectionLabel(pgConfig, "CONEXION", 0)
field(pgConfig, "HUB URL", 0, 16, 486, CFG.HUB, function(v) CFG.HUB = (v:gsub("%s+",""):gsub("/+$", "")) end)
field(pgConfig, "API KEY", 0, 62, 300, CFG.KEY, function(v) CFG.KEY = (v:gsub("%s+","")) end)
field(pgConfig, "NOMBRE DE ESTE CLIENTE", 310, 62, 176, CFG.CLIENT, function(v) CFG.CLIENT = v end)

sectionLabel(pgConfig, "RITMO", 110)
field(pgConfig, "POLL (s)", 0, 126, 92, CFG.POLL, function(v) CFG.POLL = math.max(2, tonumber(v) or 4) end)
field(pgConfig, "COOLDOWN (s)", 100, 126, 104, CFG.COOLDOWN, function(v) CFG.COOLDOWN = math.max(3, tonumber(v) or 8) end)
field(pgConfig, "ESPERA CLAIM (s)", 212, 126, 110, CFG.WAIT, function(v) CFG.WAIT = math.max(5, math.min(50, tonumber(v) or 20)) end)
field(pgConfig, "RAW · auto reload", 330, 126, 156, CFG.SCRIPT_URL, function(v) CFG.SCRIPT_URL = v end)

do
    local test = mk("TextButton", {
        Position = UDim2.new(0,0,0,186), Size = UDim2.new(0,150,0,30),
        BackgroundColor3 = C.acc, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, pgConfig)
    corner(test, 8)
    mk("UIGradient", { Rotation = 20, Color = ColorSequence.new(C.acc, Color3.fromRGB(92,62,240)) }, test)
    icon("bolt", test, 12, Color3.fromRGB(255,255,255)).Position = UDim2.new(0,16,0,9)
    local tl = mk("TextLabel", {
        Position = UDim2.new(0,34,0,0), Size = UDim2.new(1,-40,1,0),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 11,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextColor3 = Color3.fromRGB(255,255,255), Text = "PROBAR CONEXION",
    }, test)

    test.MouseButton1Click:Connect(function()
        tl.Text = "PROBANDO…"
        task.spawn(function()
            local res, err = httpJson("GET", "/api/meta")
            if res then
                tl.Text = "CONECTADO"
                pushLog(("hub ok · %d servers · %d huevos · cursor %d")
                    :format(res.servers or 0, res.eggs or 0, res.eggSeq or 0), C.ok)
            else
                tl.Text = "SIN CONEXION"
                pushLog("hub error: " .. tostring(err), C.bad)
            end
            task.delay(2, function() tl.Text = "PROBAR CONEXION" end)
        end)
    end)

    mk("TextLabel", {
        Position = UDim2.new(0,162,0,186), Size = UDim2.new(1,-162,0,34),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        TextColor3 = C.mut, TextWrapped = true,
        Text = "Cada campo se guarda al salir de el. La misma API key que pusiste en el hub y en el ESP.",
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
            mk("TextLabel", {
                Position = UDim2.new(0,9,0,0), Size = UDim2.new(0,52,1,0),
                BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 10,
                TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.mut, Text = e.t,
            }, row)
            mk("TextLabel", {
                Position = UDim2.new(0,64,0,0), Size = UDim2.new(1,-70,1,0),
                BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10.5,
                TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd,
                TextColor3 = e.c, Text = e.s,
            }, row)
        end
    end
end

-- ══════════════════════════════════════════════════════════════════════ estado
local function paintStatus()
    statCards.servers.Text = tostring(ST.servers)
    statCards.matches.Text = tostring(#ST.candidates)
    statCards.hops.Text    = tostring(ST.hops)
    dot.BackgroundColor3   = ST.connected and C.ok or C.bad
    connLbl.Text = ST.connected and ("en vivo · " .. ST.eggsLive) or "sin conexion"
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
-- Los mismos filtros que usa el claim, para que la lista muestre exactamente
-- lo que el AJ es capaz de tomar.
local function feedQuery()
    local q = "?limit=30"
    if #CFG.RARITIES > 0 then q = q .. "&rarities=" .. HS:UrlEncode(table.concat(CFG.RARITIES, ",")) end
    if (tonumber(CFG.MIN_KG) or 0) > 0 then q = q .. "&minKg=" .. tostring(CFG.MIN_KG) end
    if (tonumber(CFG.MAX_KG) or 0) > 0 then q = q .. "&maxKg=" .. tostring(CFG.MAX_KG) end
    if (tonumber(CFG.MAX_AGE) or 0) > 0 then q = q .. "&maxAgeSec=" .. tostring(CFG.MAX_AGE) end
    if CFG.HAS_SLOT then q = q .. "&hasSlot=1" end
    if CFG.ONLY_NEW and autoOn and ST.cursor then
        q = q .. "&sinceSeq=" .. tostring(ST.cursor) .. "&newest=1"
    end
    return "/api/feed" .. q
end

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
                -- Arranque en frio: nunca empezamos mirando el historico.
                if ST.cursor == nil then ST.cursor = ST.eggSeq end
            end
            if type(meta.ladder) == "table" and #meta.ladder > 0 then
                local changed = (#meta.ladder ~= #ST.ladder)
                ST.ladder = meta.ladder
                ST.colors = {}
                for _, r in ipairs(meta.ladder) do
                    ST.colors[tostring(r.name):lower()] = hex(r.color)
                end
                if changed then renderChips() end
            end
        else
            if ST.connected or ST.lastErr ~= err then pushLog("hub: " .. tostring(err), C.bad) end
            ST.connected = false
            ST.lastErr = err
        end

        local feed = httpJson("GET", feedQuery())
        if feed and feed.eggs then
            ST.candidates = feed.eggs
            renderList()
        end
        paintStatus()
        task.wait(math.max(2, CFG.POLL))
    end
end)

task.spawn(function()
    while true do
        if autoOn and (os.clock() - ST.lastHop) > CFG.COOLDOWN then
            local body = {
                client   = CFG.CLIENT,
                rarities = CFG.RARITIES,
                minKg    = tonumber(CFG.MIN_KG) or 0,
                hasSlot  = CFG.HAS_SLOT,
                exclude  = { game.JobId },
                wait     = math.max(5, CFG.WAIT),
            }
            if (tonumber(CFG.MAX_KG) or 0) > 0 then body.maxKg = CFG.MAX_KG end
            if (tonumber(CFG.MAX_AGE) or 0) > 0 then body.maxAgeSec = CFG.MAX_AGE end
            if CFG.ONLY_NEW and ST.cursor then body.sinceSeq = ST.cursor end

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

-- Paso a paso: si uno falla, el resto del panel sigue vivo y el fallo acaba en
-- el log en vez de dejar la UI a medio pintar.
for _, step in ipairs({
    { "chips",  function() renderChips() end },
    { "tabs",   function() selectTab("hunt") end },
    { "toggle", paintAuto },
    { "estado", paintStatus },
}) do
    local ok, err = pcall(step[2])
    if not ok then pushLog("fallo al pintar " .. step[1] .. ": " .. tostring(err), C.bad) end
end

if not httpreq then
    pushLog("tu executor no expone request(): el AJ no puede hablar con el hub", C.bad)
end
pushLog("AJ v3 listo · " .. CFG.HUB, C.acc2)
