--[[
    JF · EGG ESP v8 — zonas al hub · bases nunca
    F7 = labels    F8 = panel

    Cambio grande del v8 frente al v7:

      El webhook y el hub SOLO reciben huevos de ZONA. Ya no es un toggle que
      se pueda dejar mal puesto: si un huevo no sale de AreaEggSlotsClient no
      se envia a ningun sitio, punto. El panel puede seguir pintando los de
      base en pantalla (util para ti), pero eso ya no contamina el feed.

    Ademas:
      · cada huevo viaja con su ZONA real (Forest, Volcano, Snow…), sacada de
        Workspace.__OBJECTS.Areas.GuardAreas, no de adivinar
      · payload mas rico: rarityNum, odds, growthSec, earnRate
      · snapshots full=true bien formados, para que el hub tire lo que ya no esta
      · auto hop igual que en v7
]]

local Players           = game:GetService("Players")
local Workspace         = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local HttpService       = game:GetService("HttpService")
local TeleportService   = game:GetService("TeleportService")

local LocalPlayer = Players.LocalPlayer

local CFG = {
    TOGGLE_LABELS  = Enum.KeyCode.F7,
    TOGGLE_PANEL   = Enum.KeyCode.F8,
    MAX_DISTANCE   = 5000,
    REFRESH        = 1,
    MIN_KG         = 0,
    MAX_KG         = math.huge,
    COLOR_FALLBACK = true,
    COLOR_TOL      = 0.02,
    SEND_GUESSED   = false,   -- los adivinados por color nunca salen por defecto
    SHOW_BASE      = false,   -- SOLO afecta a los labels en pantalla
    ZONE_CONTAINER = "AreaEggSlotsClient",
    CONFIG_FILE    = "jf_esp_config.json",
    VISITED_FILE   = "jf_esp_visited.json",
    HUB_FLUSH      = 0.25,
    HUB_FULL       = 20,
    -- auto hop
    HOP_DWELL      = 25,
    HOP_MAXPLAYERS = 2,
    HOP_PAGES      = 8,
    VISITED_TTL    = 3 * 3600,
    HOP_RETRY      = 3,
    HOP_EMPTY      = 10,
    HOP_STUCK      = 20,
}

-- Los de base se siguen leyendo para poder contarlos y etiquetarlos, pero
-- SEND_CONTAINERS es la unica lista que puede acabar en la red.
local CONTAINERS      = { "AreaEggSlotsClient", "PlacedEggRenders", "Eggs", "New Pets" }
local SEND_CONTAINERS = { AreaEggSlotsClient = true }

local GENERIC = {
    Color3.new(0.639216, 0.635294, 0.647059),
    Color3.new(1, 0.313726, 0.313726),
}

local DIAG = {}
local function diag(fmt, ...) DIAG[#DIAG+1] = string.format(fmt, ...) end

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props) do o[k] = v end
    if parent then o.Parent = parent end
    return o
end

----------------------------------------------------------------------
-- MÓDULOS DEL JUEGO
----------------------------------------------------------------------
local function nav(root, path)
    local node = root
    for seg in path:gmatch("[^%.]+") do node = node and node:FindFirstChild(seg) end
    return node
end

local function req(path)
    local m = nav(ReplicatedStorage, path)
    if not m then return nil, "no existe" end
    local ok, v = pcall(require, m)
    if not ok then return nil, "require fallo" end
    return v
end

local EggState,   e1 = req("Client.EggState")
local EggRecords, e2 = req("Shared.Util.EggRecords")
local Assets,     e3 = req("Data.Assets")

diag("EggState:%s EggRecords:%s Assets:%s",
    EggState and "OK" or tostring(e1), EggRecords and "OK" or tostring(e2),
    Assets and "OK" or tostring(e3))

----------------------------------------------------------------------
-- ÍNDICES DE ASSETS
----------------------------------------------------------------------
local assetIndex, colorIndex, rarityList = {}, {}, {}
do
    local function addColor(c, id)
        if typeof(c) ~= "Color3" then return end
        for _, g in ipairs(GENERIC) do
            if math.abs(c.R-g.R)<0.01 and math.abs(c.G-g.G)<0.01
               and math.abs(c.B-g.B)<0.01 then return end
        end
        colorIndex[#colorIndex+1] = { c = c, id = id }
    end

    if Assets and type(Assets.ByRarity) == "table" then
        for rarityName, group in pairs(Assets.ByRarity) do
            if type(group) == "table" then
                for assetId, cfg in pairs(group) do
                    if type(cfg) == "table" then
                        local R = cfg.Rarity
                        assetIndex[assetId] = {
                            id        = assetId,
                            rarity    = (R and R.DisplayName) or rarityName,
                            rarityNum = (R and R.RarityNumber) or 0,
                            odds      = (R and R.DefaultRarityValue) or "?",
                            color     = (R and typeof(R.Color)=="Color3" and R.Color) or Color3.new(1,1,1),
                            eggName   = (cfg.Egg and cfg.Egg.DisplayName) or (assetId.." Egg"),
                            petName   = cfg.DisplayName or assetId,
                            baseKg    = (cfg.Egg and cfg.Egg.WeightKg) or 0,
                            growth    = (cfg.Egg and cfg.Egg.GrowthTime) or 0,
                            earn      = cfg.EarningRate or 0,
                        }
                        addColor(cfg.BaseModelColor, assetId)
                        if type(cfg.PossibleModelColors) == "table" then
                            for _, e in pairs(cfg.PossibleModelColors) do
                                if type(e) == "table" then addColor(e[1], assetId) end
                            end
                        end
                    end
                end
            end
        end
    end

    local seen = {}
    for _, info in pairs(assetIndex) do
        if not seen[info.rarity] then
            seen[info.rarity] = true
            rarityList[#rarityList+1] = { name = info.rarity, num = info.rarityNum, color = info.color }
        end
    end
    table.sort(rarityList, function(a, b) return a.num < b.num end)

    local n = 0; for _ in pairs(assetIndex) do n = n + 1 end
    diag("assets:%d rarezas:%d colores:%d", n, #rarityList, #colorIndex)
end

----------------------------------------------------------------------
-- ZONAS DEL MAPA
-- Workspace.__OBJECTS.Areas.GuardAreas tiene una carpeta por zona (Forest,
-- Volcano, Snow, Titan Temple…). Con un punto de referencia de cada una basta
-- para decir a que zona pertenece cada huevo.
----------------------------------------------------------------------
local AREAS = {}

local function indexAreas()
    AREAS = {}
    local guard = nav(Workspace, "__OBJECTS.Areas.GuardAreas")
    if not guard then return end
    for _, area in ipairs(guard:GetChildren()) do
        local anchor
        for _, d in ipairs(area:GetDescendants()) do
            if d:IsA("BasePart") then anchor = d break end
        end
        if anchor then AREAS[#AREAS+1] = { name = area.Name, pos = anchor.Position } end
    end
    diag("zonas:%d", #AREAS)
end
pcall(indexAreas)

-- El nombre del modelo a veces ya lleva la zona: FirstAreaEgg_x_y_Forest:Slot_002
local function areaFromName(modelName)
    local a = modelName:match("^FirstAreaEgg_[%d_]+_([%a%s]+):Slot")
    return a
end

local function areaOf(model, pos)
    local byName = areaFromName(model.Name)
    if byName then return byName end
    if not pos or #AREAS == 0 then return "" end
    local best, bestD = "", math.huge
    for _, a in ipairs(AREAS) do
        local d = (a.pos - pos).Magnitude
        if d < bestD then bestD, best = d, a.name end
    end
    return best
end

----------------------------------------------------------------------
-- RECORDS
----------------------------------------------------------------------
local ASSET_KEYS = { "AssetId","Asset","AssetName","Species","EggType","Type","Id","Name" }
local ID_FIELDS  = { "Uid","UID","uid","Id","ID","SlotKey","Key","ModelName","Slot" }

local function recordAssetId(rec)
    if type(rec) ~= "table" then return nil end
    for _, k in ipairs(ASSET_KEYS) do
        local v = rec[k]
        if type(v) == "string" and assetIndex[v] then return v end
    end
    for _, v in pairs(rec) do
        if type(v) == "string" and assetIndex[v] then return v end
    end
    return nil
end

local function looksLikeRecord(t)
    if type(t) ~= "table" then return false end
    if recordAssetId(t) then return true end
    if EggRecords and EggRecords.DisplayName then
        local ok, v = pcall(EggRecords.DisplayName, t)
        if ok and type(v) == "string" and v ~= "" then return true end
    end
    return false
end

local function deepIndex(node, out, depth, key, seen)
    if type(node) ~= "table" or depth > 6 or seen[node] then return end
    seen[node] = true
    if looksLikeRecord(node) then
        if type(key) == "string" then out[key] = node end
        for _, f in ipairs(ID_FIELDS) do
            local v = node[f]
            if type(v) == "string" then out[v] = node end
        end
        return
    end
    for k, v in pairs(node) do deepIndex(v, out, depth+1, k, seen) end
end

local function collectRecords()
    local out = {}
    if not EggState then return out end
    local seen = {}
    local function take(t) if type(t)=="table" then deepIndex(t, out, 0, nil, seen) end end

    local ok, r = pcall(function() return EggState.ReadFieldEggs() end); if ok then take(r) end
    ok, r = pcall(function() return EggState.ReadOwnedEggs() end);       if ok then take(r) end
    for _, p in ipairs(Players:GetPlayers()) do
        local ok2, r2 = pcall(function() return EggState.ReadOwnerEggs(p.UserId) end)
        if ok2 then take(r2) end
    end
    return out
end

local function fetchField(key)
    if not EggState or not EggState.ReadFieldEgg or type(key) ~= "string" then return nil end
    local ok, r = pcall(EggState.ReadFieldEgg, key)
    if ok and looksLikeRecord(r) then return r end
    return nil
end

local function recordKg(rec, info)
    if EggRecords and EggRecords.WeightKg then
        local ok, v = pcall(EggRecords.WeightKg, rec)
        if ok and type(v) == "number" and v > 0 then return v end
    end
    return (info and info.baseKg) or 0
end

local function recordName(rec, info)
    if EggRecords and EggRecords.DisplayName then
        local ok, v = pcall(EggRecords.DisplayName, rec)
        if ok and type(v) == "string" and v ~= "" then return v end
    end
    return (info and info.eggName) or "???"
end

local function guessByColor(model)
    if not CFG.COLOR_FALLBACK then return nil end
    local best, bestD = nil, CFG.COLOR_TOL
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then
            local c, generic = d.Color, false
            for _, g in ipairs(GENERIC) do
                if math.abs(c.R-g.R)<0.01 and math.abs(c.G-g.G)<0.01 and math.abs(c.B-g.B)<0.01 then generic = true break end
            end
            if not generic then
                for _, entry in ipairs(colorIndex) do
                    local e = entry.c
                    local dist = math.sqrt((c.R-e.R)^2+(c.G-e.G)^2+(c.B-e.B)^2)
                    if dist < bestD then bestD, best = dist, entry.id end
                end
            end
        end
    end
    return best
end

----------------------------------------------------------------------
-- HTTP
----------------------------------------------------------------------
local function httpPost(url, body, headers)
    local fn = (syn and syn.request) or (http and http.request) or http_request or request
    if not fn then return false, "executor sin request()" end
    local h = { ["Content-Type"] = "application/json" }
    if headers then for k, v in pairs(headers) do h[k] = v end end
    local ok, res = pcall(fn, { Url = url, Method = "POST", Headers = h, Body = body })
    if not ok then return false, tostring(res) end
    local code = res and (res.StatusCode or res.Status or res.status_code) or 0
    if code >= 200 and code < 300 then return true, res.Body end
    return false, "HTTP " .. tostring(code)
end

local function colorInt(c)
    return math.floor(c.R*255)*65536 + math.floor(c.G*255)*256 + math.floor(c.B*255)
end

local function comma(n)
    local s = tostring(math.floor(n + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

----------------------------------------------------------------------
-- ESTADO WEBHOOK / HUB / HOP
----------------------------------------------------------------------
local WH  = { url="", enabled=false, rarities={}, sent={}, count=0, status="inactivo", queue={} }
local HUB = { url="", key="", enabled=false, onlyMarked=false, pending={}, known={},
              live={}, count=0, pushes=0, status="inactivo", lastMs=0, blocked=0 }
local HOP = { enabled=false, dwell=CFG.HOP_DWELL, maxPlayers=CFG.HOP_MAXPLAYERS,
              busy=false, busySince=0, fails=0, since=os.clock(), hops=0,
              visited={}, status="inactivo" }

local function saveConfig()
    pcall(function()
        if type(writefile) ~= "function" then return end
        writefile(CFG.CONFIG_FILE, HttpService:JSONEncode({
            url = WH.url, enabled = WH.enabled, rarities = WH.rarities,
            hubUrl = HUB.url, hubKey = HUB.key,
            hubEnabled = HUB.enabled, hubOnlyMarked = HUB.onlyMarked,
            showBase = CFG.SHOW_BASE,
            hopEnabled = HOP.enabled, hopDwell = HOP.dwell, hopMax = HOP.maxPlayers,
        }))
    end)
end

local function loadConfig()
    pcall(function()
        if type(readfile) ~= "function" or type(isfile) ~= "function" then return end
        if not isfile(CFG.CONFIG_FILE) then return end
        local d = HttpService:JSONDecode(readfile(CFG.CONFIG_FILE))
        WH.url         = d.url or ""
        WH.enabled     = d.enabled or false
        WH.rarities    = d.rarities or {}
        HUB.url        = d.hubUrl or ""
        HUB.key        = d.hubKey or ""
        HUB.enabled    = d.hubEnabled or false
        HUB.onlyMarked = d.hubOnlyMarked or false
        if d.showBase ~= nil then CFG.SHOW_BASE = d.showBase end
        HOP.enabled    = d.hopEnabled or false
        HOP.dwell      = tonumber(d.hopDwell) or CFG.HOP_DWELL
        HOP.maxPlayers = tonumber(d.hopMax) or CFG.HOP_MAXPLAYERS
    end)
end
loadConfig()

local function loadVisited()
    pcall(function()
        if type(readfile) ~= "function" or type(isfile) ~= "function" then return end
        if not isfile(CFG.VISITED_FILE) then return end
        local d = HttpService:JSONDecode(readfile(CFG.VISITED_FILE))
        local now = os.time()
        for jobId, at in pairs(d) do
            if type(at) == "number" and (now - at) < CFG.VISITED_TTL then
                HOP.visited[jobId] = at
            end
        end
    end)
end

local function saveVisited()
    pcall(function()
        if type(writefile) ~= "function" then return end
        writefile(CFG.VISITED_FILE, HttpService:JSONEncode(HOP.visited))
    end)
end
loadVisited()

----------------------------------------------------------------------
-- LA REGLA DEL v8
-- Un solo sitio decide si un huevo puede salir a la red. Ni el webhook ni el
-- hub tienen forma de saltarselo.
----------------------------------------------------------------------
local function sendable(e)
    if not e.zone then return false end                       -- base: fuera, siempre
    if e.mark == "~" and not CFG.SEND_GUESSED then return false end
    return true
end

----------------------------------------------------------------------
-- WEBHOOK
----------------------------------------------------------------------
local function buildEmbed(e)
    local pos = e.anchor and e.anchor.Position or Vector3.new()
    local info = e.info or {}
    local jobId = game.JobId ~= "" and game.JobId or "servidor privado / studio"

    return HttpService:JSONEncode({
        embeds = {{
            title       = "🥚  " .. e.name,
            color       = colorInt(e.color),
            description = string.format("**%s**  ·  %s", e.rarity, info.odds or "?"),
            fields = {
                { name = "Peso",      value = "`" .. comma(e.kg) .. " kg`",           inline = true },
                { name = "Mascota",   value = info.petName or "?",                    inline = true },
                { name = "Zona",      value = e.area ~= "" and e.area or "Zona",      inline = true },
                { name = "Ganancia",  value = "`" .. comma(info.earn or 0) .. "/s`",  inline = true },
                { name = "Eclosión",  value = "`" .. tostring(info.growth or 0) .. "s`", inline = true },
                { name = "Posición",  value = string.format("`%d, %d, %d`", pos.X, pos.Y, pos.Z), inline = true },
                { name = "Job ID",    value = "```" .. jobId .. "```",                inline = false },
                { name = "Unirse",    value = string.format("```js\nRoblox.GameLauncher.joinGameInstance(%d, \"%s\")\n```", game.PlaceId, jobId), inline = false },
                { name = "Jugadores", value = string.format("`%d / %d`", #Players:GetPlayers(), Players.MaxPlayers), inline = true },
            },
            footer    = { text = "EAG By joszz  ·  zona" },
            timestamp = DateTime.now():ToIsoDate(),
        }},
    })
end

task.spawn(function()
    while true do
        if #WH.queue > 0 and WH.url ~= "" then
            local body = table.remove(WH.queue, 1)
            local ok, err = httpPost(WH.url, body)
            if ok then
                WH.count  = WH.count + 1
                WH.status = "enviado " .. os.date("%H:%M:%S")
            else
                WH.status = "error: " .. tostring(err)
            end
            task.wait(1.5)
        else
            task.wait(0.5)
        end
    end
end)

local function maybeSend(e, uid)
    if not WH.enabled or WH.url == "" then return end
    if not sendable(e) then return end
    if not WH.rarities[e.rarity] then return end
    if WH.sent[uid] then return end
    WH.sent[uid] = true
    WH.queue[#WH.queue+1] = buildEmbed(e)
end

----------------------------------------------------------------------
-- HUB
----------------------------------------------------------------------
local function eggPayload(e, uid)
    local info = e.info or {}
    local pos  = e.anchor and e.anchor.Position or Vector3.new()
    return {
        uid       = uid,
        name      = e.name,
        species   = info.id or "",
        rarity    = e.rarity,
        rarityNum = info.rarityNum or 0,
        odds      = info.odds or "",
        kg        = math.floor(e.kg * 100 + 0.5) / 100,
        petName   = info.petName or "",
        growth    = tostring(info.growth or 0) .. "s",
        growthSec = tonumber(info.growth) or 0,
        earn      = comma(info.earn or 0),
        earnRate  = tonumber(info.earn) or 0,
        area      = e.area or "",
        source    = "zone",
        pos       = string.format("%d, %d, %d", pos.X, pos.Y, pos.Z),
    }
end

local function hubTrack(e, uid)
    if not HUB.enabled or HUB.url == "" then return end
    if not sendable(e) then
        if e.zone == false then HUB.blocked = HUB.blocked + 1 end
        return
    end
    if HUB.onlyMarked and not WH.rarities[e.rarity] then return end

    local payload = eggPayload(e, uid)
    HUB.live[uid] = payload
    if not HUB.known[uid] then
        HUB.known[uid] = true
        HUB.pending[uid] = payload
    end
end

-- full = "esto es todo lo que hay aqui ahora". El hub borra lo que no venga.
local function hubSend(eggs, tag, full)
    if HUB.url == "" then return false, "falta la URL" end
    local body = HttpService:JSONEncode({
        jobId      = game.JobId ~= "" and game.JobId or "studio",
        placeId    = tostring(game.PlaceId),
        players    = #Players:GetPlayers(),
        maxPlayers = Players.MaxPlayers,
        reporter   = LocalPlayer.Name,
        full       = full and true or false,
        eggs       = eggs,
    })
    local t0 = os.clock()
    local ok, err = httpPost(HUB.url .. "/api/report", body, { ["x-eag-key"] = HUB.key })
    HUB.lastMs = math.floor((os.clock() - t0) * 1000)
    HUB.pushes = HUB.pushes + 1
    if ok then
        HUB.count  = HUB.count + #eggs
        HUB.status = string.format("%s ok · %dms · %s", tag, HUB.lastMs, os.date("%H:%M:%S"))
    else
        HUB.status = tag .. " error: " .. tostring(err)
    end
    return ok, err
end

task.spawn(function()
    while true do
        if HUB.enabled and HUB.url ~= "" then
            local batch, n = {}, 0
            for uid, payload in pairs(HUB.pending) do
                batch[#batch+1] = payload
                HUB.pending[uid] = nil
                n = n + 1
                if n >= 60 then break end
            end
            if #batch > 0 then
                local ok = hubSend(batch, "push")
                if not ok then
                    for _, p in ipairs(batch) do HUB.known[p.uid] = nil end
                end
            end
        end
        task.wait(CFG.HUB_FLUSH)
    end
end)

task.spawn(function()
    while true do
        task.wait(CFG.HUB_FULL)
        if HUB.enabled and HUB.url ~= "" then
            local all = {}
            for _, payload in pairs(HUB.live) do all[#all+1] = payload end
            hubSend(all, "snapshot", true)
        end
    end
end)

----------------------------------------------------------------------
-- AUTO HOP
----------------------------------------------------------------------
local function hubFlushNow()
    if not (HUB.enabled and HUB.url ~= "") then return end
    local all = {}
    for _, payload in pairs(HUB.live) do all[#all+1] = payload end
    HUB.pending = {}
    hubSend(all, "final", true)
end

local function httpGetJson(url)
    local body
    local ok = pcall(function() body = game:HttpGet(url, true) end)
    if not ok or not body then
        local fn = (syn and syn.request) or (http and http.request) or http_request or request
        if not fn then return nil end
        local ok2, res = pcall(fn, { Url = url, Method = "GET" })
        if not ok2 or not res then return nil end
        body = res.Body
    end
    if not body then return nil end
    local ok3, decoded = pcall(function() return HttpService:JSONDecode(body) end)
    if not ok3 then return nil end
    return decoded
end

local function findNextServer()
    local placeId = game.PlaceId
    local best, cursor = nil, ""
    for _ = 1, CFG.HOP_PAGES do
        local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100")
            :format(placeId)
        if cursor ~= "" then url = url .. "&cursor=" .. cursor end

        local page = httpGetJson(url)
        if not page or not page.data then break end

        for _, srv in ipairs(page.data) do
            local playing = srv.playing
            if playing and srv.id ~= game.JobId and not HOP.visited[srv.id] then
                if playing <= HOP.maxPlayers then
                    if playing <= 1 then return srv end
                    if best == nil or playing < best.playing then best = srv end
                end
            end
        end

        cursor = page.nextPageCursor or ""
        if cursor == "" then break end
    end
    return best
end

local function hopRetryIn(sec)
    HOP.since = os.clock() - HOP.dwell + sec
    HOP.busy = false
end

local function hopFailRetry(why)
    HOP.fails = HOP.fails + 1
    local wait = CFG.HOP_RETRY
    if HOP.fails > 4 then wait = math.min(CFG.HOP_RETRY * HOP.fails, 20) end
    HOP.status = ("%s · reintento en %ds"):format(why, wait)
    hopRetryIn(wait)
end

local function doHop()
    if HOP.busy then return end
    HOP.busy = true
    HOP.busySince = os.clock()

    HOP.status = "subiendo lo encontrado…"
    hubFlushNow()

    HOP.status = "buscando server vacio…"
    local target = findNextServer()
    if not target then
        HOP.status = ("sin servers nuevos · reintento en %ds"):format(CFG.HOP_EMPTY)
        hopRetryIn(CFG.HOP_EMPTY)
        return
    end

    HOP.visited[target.id] = os.time()
    if game.JobId ~= "" then HOP.visited[game.JobId] = os.time() end
    saveVisited()
    HOP.hops = HOP.hops + 1
    HOP.status = ("saltando -> %s · %d jugadores"):format(target.id:sub(1, 8), target.playing or 0)

    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, target.id, LocalPlayer)
    end)
    if not ok then hopFailRetry("fallo el salto: " .. tostring(err)) end
end

TeleportService.TeleportInitFailed:Connect(function(_, _, msg)
    hopFailRetry("teleport rechazado: " .. tostring(msg))
end)

task.spawn(function()
    while true do
        task.wait(1)
        if HOP.enabled then
            if HOP.busy then
                if (os.clock() - HOP.busySince) > CFG.HOP_STUCK then
                    hopFailRetry("el salto no llego a ocurrir")
                end
            elseif (os.clock() - HOP.since) >= HOP.dwell then
                pcall(doHop)
            end
        end
    end
end)

----------------------------------------------------------------------
-- WORKSPACE
----------------------------------------------------------------------
local function uidFromModelName(n)
    local _, uid = n:match("^(%d+)_(%w+)$")
    return uid or n
end

local function eachEggModel(fn)
    for _, c in ipairs(Workspace:GetChildren()) do
        if table.find(CONTAINERS, c.Name) then
            for _, m in ipairs(c:GetChildren()) do fn(m, c.Name) end
        end
    end
end

local function anchorOf(model)
    local hb = model:FindFirstChild("Hitbox")
    if hb and hb:IsA("BasePart") then return hb end
    if model:IsA("BasePart") then return model end
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then return d end
    end
    return nil
end

local function passes(kg) return kg >= CFG.MIN_KG and kg <= CFG.MAX_KG end

----------------------------------------------------------------------
-- LABELS
----------------------------------------------------------------------
local labels, showLabels = {}, true

local function makeLabel(model, anchor)
    local bb = new("BillboardGui", {
        Name = "JF_ESP", Adornee = anchor,
        Size = UDim2.new(0, 240, 0, 54),
        StudsOffset = Vector3.new(0, 3.5, 0),
        AlwaysOnTop = true, MaxDistance = CFG.MAX_DISTANCE,
    }, model)
    new("TextLabel", {
        Name = "T", Size = UDim2.new(1,0,1,0),
        BackgroundColor3 = Color3.new(0,0,0), BackgroundTransparency = 0.35,
        Font = Enum.Font.GothamBold, TextSize = 13,
        TextColor3 = Color3.new(1,1,1), TextStrokeTransparency = 0.4,
        RichText = true,
    }, bb)
    return bb
end

local function clearLabel(model)
    local l = labels[model]
    if l then pcall(function() l:Destroy() end) end
    labels[model] = nil
end

----------------------------------------------------------------------
local entries = {}
local stats = { zone=0, zoneOk=0, base=0, baseOk=0, guessed=0, records=0, byContainer={}, byArea={} }

local function refresh()
    local recs = collectRecords()
    local nrec = 0; for _ in pairs(recs) do nrec = nrec + 1 end
    stats.records = nrec

    local seen, list = {}, {}
    local liveUids = {}
    stats.zone, stats.zoneOk, stats.base, stats.baseOk, stats.guessed = 0,0,0,0,0
    stats.byContainer, stats.byArea = {}, {}

    eachEggModel(function(model, container)
        seen[model] = true
        local isZone = SEND_CONTAINERS[container] == true
        if isZone then stats.zone = stats.zone + 1 else stats.base = stats.base + 1 end
        stats.byContainer[container] = (stats.byContainer[container] or 0) + 1

        -- Los de base solo se pintan si tu lo pides, y aun asi jamas se envian.
        if not isZone and not CFG.SHOW_BASE then clearLabel(model) return end

        local uid = uidFromModelName(model.Name)
        local rec = recs[uid] or recs[model.Name] or fetchField(model.Name) or fetchField(uid)

        local info, kg, name, rarity, col, mark
        if rec then
            if isZone then stats.zoneOk = stats.zoneOk+1 else stats.baseOk = stats.baseOk+1 end
            local aid = recordAssetId(rec)
            info   = aid and assetIndex[aid] or nil
            kg     = recordKg(rec, info)
            name   = recordName(rec, info)
            rarity = info and info.rarity or "???"
            col    = info and info.color or Color3.new(1,1,1)
            mark   = ""
        else
            local aid = guessByColor(model)
            if not aid then clearLabel(model) return end
            stats.guessed = stats.guessed + 1
            info = assetIndex[aid]
            kg, name, rarity, col, mark = info.baseKg, info.eggName, info.rarity, info.color, "~"
        end

        if not passes(kg) then clearLabel(model) return end
        local anchor = anchorOf(model)
        if not anchor then clearLabel(model) return end

        local bb = labels[model]
        if not bb or not bb.Parent then bb = makeLabel(model, anchor); labels[model] = bb end
        bb.Adornee = anchor

        local area = isZone and areaOf(model, anchor.Position) or ""
        if area ~= "" then stats.byArea[area] = (stats.byArea[area] or 0) + 1 end

        local entry = {
            model=model, name=name, rarity=rarity, kg=kg, color=col,
            anchor=anchor, mark=mark, zone=isZone, area=area, info=info,
        }
        list[#list+1] = entry
        if isZone then liveUids[uid] = true end
        maybeSend(entry, uid)
        hubTrack(entry, uid)
    end)

    for model in pairs(labels) do
        if not seen[model] or not model.Parent then clearLabel(model) end
    end

    for uid in pairs(HUB.live) do
        if not liveUids[uid] then HUB.live[uid] = nil end
    end

    table.sort(list, function(a,b) return a.kg > b.kg end)
    entries = list
end

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local BG, BG2, BG3 = Color3.fromRGB(16,16,20), Color3.fromRGB(24,24,30), Color3.fromRGB(10,10,13)
local ACCENT = Color3.fromRGB(120,255,170)
local BLUE   = Color3.fromRGB(124,92,255)
local TXT    = Color3.fromRGB(216,220,226)
local MUTED  = Color3.fromRGB(130,136,148)
local ORANGE_BG = Color3.fromRGB(128,80,20)

local panelFrame, headLabel, listBody
local paneList, paneHook, paneHub
local urlBox, enableBtn, statusLabel
local hubUrlBox, hubKeyBox, hubStatus, hopStatus

do
    local parent
    local okH, hui = pcall(function() return gethui() end)
    if okH and hui then parent = hui end
    if not parent then parent = LocalPlayer:WaitForChild("PlayerGui") end
    local old = parent:FindFirstChild("JF_ESP_GUI"); if old then old:Destroy() end

    local gui = new("ScreenGui", { Name="JF_ESP_GUI", ResetOnSpawn=false, DisplayOrder=999999 }, parent)

    panelFrame = new("Frame", {
        Size = UDim2.new(0, 500, 0, 470), Position = UDim2.new(0, 24, 0, 80),
        BackgroundColor3 = BG, BorderSizePixel = 0, Active = true, Draggable = true,
    }, gui)
    new("UICorner", { CornerRadius = UDim.new(0, 8) }, panelFrame)

    local head = new("Frame", { Size=UDim2.new(1,0,0,58), BackgroundColor3=BG2, BorderSizePixel=0 }, panelFrame)
    new("UICorner", { CornerRadius = UDim.new(0, 8) }, head)

    headLabel = new("TextLabel", {
        Size = UDim2.new(1,-20,1,0), Position = UDim2.new(0,12,0,0),
        BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 12,
        TextColor3 = ACCENT, TextXAlignment = Enum.TextXAlignment.Left, Text = "JF EGG ESP",
    }, head)

    local tabs = new("Frame", { Size=UDim2.new(1,-16,0,30), Position=UDim2.new(0,8,0,62), BackgroundTransparency=1 }, panelFrame)
    new("UIListLayout", { FillDirection=Enum.FillDirection.Horizontal, Padding=UDim.new(0,6) }, tabs)

    local function mkTab(text)
        local b = new("TextButton", {
            Size=UDim2.new(0,120,1,0), BackgroundColor3=BG3, BorderSizePixel=0,
            Font=Enum.Font.GothamBold, TextSize=12, TextColor3=MUTED, Text=text, AutoButtonColor=false,
        }, tabs)
        new("UICorner", { CornerRadius = UDim.new(0,6) }, b)
        return b
    end
    local tabList, tabHook, tabHub = mkTab("LISTA"), mkTab("WEBHOOK"), mkTab("HUB")

    paneList = new("ScrollingFrame", {
        Size=UDim2.new(1,-16,1,-104), Position=UDim2.new(0,8,0,98),
        BackgroundColor3=BG3, BorderSizePixel=0, ScrollBarThickness=6,
        AutomaticCanvasSize=Enum.AutomaticSize.Y, CanvasSize=UDim2.new(0,0,0,0),
    }, panelFrame)
    new("UICorner", { CornerRadius = UDim.new(0,6) }, paneList)

    listBody = new("TextLabel", {
        Size=UDim2.new(1,-12,0,0), Position=UDim2.new(0,6,0,6),
        AutomaticSize=Enum.AutomaticSize.Y, BackgroundTransparency=1,
        Font=Enum.Font.Code, TextSize=12, TextColor3=TXT,
        TextXAlignment=Enum.TextXAlignment.Left, TextYAlignment=Enum.TextYAlignment.Top,
        RichText=true, Text="",
    }, paneList)

    paneHook = new("Frame", { Size=UDim2.new(1,-16,1,-104), Position=UDim2.new(0,8,0,98),
        BackgroundColor3=BG3, BorderSizePixel=0, Visible=false }, panelFrame)
    new("UICorner", { CornerRadius = UDim.new(0,6) }, paneHook)

    paneHub = new("Frame", { Size=UDim2.new(1,-16,1,-104), Position=UDim2.new(0,8,0,98),
        BackgroundColor3=BG3, BorderSizePixel=0, Visible=false }, panelFrame)
    new("UICorner", { CornerRadius = UDim.new(0,6) }, paneHub)

    local function label(parent2, text, y)
        return new("TextLabel", {
            Size=UDim2.new(1,-20,0,16), Position=UDim2.new(0,10,0,y), BackgroundTransparency=1,
            Font=Enum.Font.GothamBold, TextSize=11, TextColor3=MUTED,
            TextXAlignment=Enum.TextXAlignment.Left, Text=text,
        }, parent2)
    end

    local function textBox(parent2, y, placeholder, value)
        local b = new("TextBox", {
            Size=UDim2.new(1,-20,0,30), Position=UDim2.new(0,10,0,y),
            BackgroundColor3=BG2, BorderSizePixel=0, Font=Enum.Font.Code, TextSize=11,
            TextColor3=TXT, PlaceholderText=placeholder, PlaceholderColor3=Color3.fromRGB(90,94,104),
            ClearTextOnFocus=false, Text=value, TextXAlignment=Enum.TextXAlignment.Left,
        }, parent2)
        new("UICorner", { CornerRadius = UDim.new(0,6) }, b)
        new("UIPadding", { PaddingLeft = UDim.new(0,8) }, b)
        return b
    end

    local function mkBtn(parent2, text, x, wdt, col)
        local b = new("TextButton", {
            Size=UDim2.new(0,wdt,0,30), Position=UDim2.new(0,x,1,-40), BackgroundColor3=col,
            BorderSizePixel=0, Font=Enum.Font.GothamBold, TextSize=11,
            TextColor3=Color3.new(1,1,1), Text=text, AutoButtonColor=false,
        }, parent2)
        new("UICorner", { CornerRadius = UDim.new(0,6) }, b)
        return b
    end

    local function toggle(parent2, y, get, set, textFor)
        local b = new("TextButton", {
            Size=UDim2.new(1,-20,0,26), Position=UDim2.new(0,10,0,y), BackgroundColor3=BG2,
            BorderSizePixel=0, Font=Enum.Font.GothamBold, TextSize=11,
            TextXAlignment=Enum.TextXAlignment.Left, TextColor3=MUTED, Text="", AutoButtonColor=false,
        }, parent2)
        new("UICorner", { CornerRadius = UDim.new(0,6) }, b)
        new("UIPadding", { PaddingLeft = UDim.new(0,10) }, b)
        local function paint()
            local on = get()
            b.Text = (on and "✓  " or "✕  ") .. textFor
            b.TextColor3 = on and ACCENT or MUTED
        end
        paint()
        b.MouseButton1Click:Connect(function() set(not get()); paint(); saveConfig() end)
        return b
    end

    ---------------------------------------------------------------- WEBHOOK
    label(paneHook, "URL DEL WEBHOOK", 10)
    urlBox = textBox(paneHook, 30, "https://discord.com/api/webhooks/...", WH.url)
    urlBox.FocusLost:Connect(function() WH.url = urlBox.Text; saveConfig() end)

    label(paneHook, "RAREZAS A NOTIFICAR  ·  solo se envian huevos de ZONA", 72)
    local chipHolder = new("ScrollingFrame", {
        Size=UDim2.new(1,-20,0,150), Position=UDim2.new(0,10,0,92), BackgroundTransparency=1,
        ScrollBarThickness=4, AutomaticCanvasSize=Enum.AutomaticSize.Y, CanvasSize=UDim2.new(0,0,0,0),
    }, paneHook)
    new("UIGridLayout", {
        CellSize=UDim2.new(0,145,0,26), CellPadding=UDim2.new(0,6,0,6),
        SortOrder=Enum.SortOrder.LayoutOrder,
    }, chipHolder)

    for i, r in ipairs(rarityList) do
        local chip = new("TextButton", {
            LayoutOrder=i, BackgroundColor3=BG2, BorderSizePixel=0, Font=Enum.Font.GothamBold,
            TextSize=11, Text=r.name, TextColor3=MUTED, AutoButtonColor=false,
        }, chipHolder)
        new("UICorner", { CornerRadius = UDim.new(0,5) }, chip)
        local st = new("UIStroke", { Color=r.color, Transparency=0.7, Thickness=1 }, chip)
        local function paint()
            local on = WH.rarities[r.name]
            chip.TextColor3       = on and r.color or MUTED
            chip.BackgroundColor3 = on and Color3.fromRGB(34,34,44) or BG2
            st.Transparency       = on and 0 or 0.75
        end
        paint()
        chip.MouseButton1Click:Connect(function()
            WH.rarities[r.name] = (not WH.rarities[r.name]) or nil
            paint(); saveConfig()
        end)
    end

    enableBtn = mkBtn(paneHook, "", 10, 150, Color3.fromRGB(45,45,58))
    local function paintEnable()
        enableBtn.Text = WH.enabled and "● ENVIANDO" or "○ DESACTIVADO"
        enableBtn.BackgroundColor3 = WH.enabled and Color3.fromRGB(28,110,70) or Color3.fromRGB(45,45,58)
    end
    paintEnable()
    enableBtn.MouseButton1Click:Connect(function()
        WH.url = urlBox.Text; WH.enabled = not WH.enabled; paintEnable(); saveConfig()
    end)

    mkBtn(paneHook, "PROBAR", 168, 90, Color3.fromRGB(45,90,160)).MouseButton1Click:Connect(function()
        WH.url = urlBox.Text
        if WH.url == "" then WH.status = "falta la URL" return end
        WH.queue[#WH.queue+1] = HttpService:JSONEncode({
            embeds = {{
                title = "🥚  Prueba de conexión",
                color = colorInt(ACCENT),
                description = "El webhook está configurado correctamente.",
                fields = {{ name="Job ID", value="```"..(game.JobId ~= "" and game.JobId or "n/a").."```", inline=false }},
                footer = { text = "EAG By joszz" },
                timestamp = DateTime.now():ToIsoDate(),
            }},
        })
    end)

    mkBtn(paneHook, "LIMPIAR ENVIADOS", 266, 140, Color3.fromRGB(120,50,50)).MouseButton1Click:Connect(function()
        WH.sent = {}; WH.count = 0; WH.status = "historial limpio"
    end)

    statusLabel = new("TextLabel", {
        Size=UDim2.new(1,-20,0,16), Position=UDim2.new(0,10,1,-62), BackgroundTransparency=1,
        Font=Enum.Font.Code, TextSize=11, TextColor3=MUTED,
        TextXAlignment=Enum.TextXAlignment.Left, Text="",
    }, paneHook)

    -------------------------------------------------------------------- HUB
    label(paneHub, "URL DEL HUB (RAILWAY)", 8)
    hubUrlBox = textBox(paneHub, 26, "https://tu-app.up.railway.app", HUB.url)
    hubUrlBox.FocusLost:Connect(function()
        HUB.url = (hubUrlBox.Text:gsub("%s+", ""):gsub("/+$", ""))
        hubUrlBox.Text = HUB.url; saveConfig()
    end)

    label(paneHub, "API KEY", 60)
    hubKeyBox = textBox(paneHub, 78, "la misma API_KEY del hub", HUB.key)
    hubKeyBox.FocusLost:Connect(function()
        HUB.key = (hubKeyBox.Text:gsub("%s+", "")); saveConfig()
    end)

    new("TextLabel", {
        Size=UDim2.new(1,-20,0,26), Position=UDim2.new(0,10,0,112), BackgroundTransparency=1,
        Font=Enum.Font.GothamBold, TextSize=11, TextColor3=ACCENT,
        TextXAlignment=Enum.TextXAlignment.Left, TextWrapped=true,
        Text = "◆  Al hub y al webhook SOLO van huevos de ZONA. Los de base nunca salen.",
    }, paneHub)

    toggle(paneHub, 142, function() return HUB.onlyMarked end,
        function(v) HUB.onlyMarked = v end,
        "subir solo las rarezas marcadas en WEBHOOK")

    toggle(paneHub, 172, function() return CFG.SHOW_BASE end,
        function(v) CFG.SHOW_BASE = v end,
        "pintar tambien los huevos de base (solo visual)")

    local hopBtn = new("TextButton", {
        Size=UDim2.new(1,-20,0,28), Position=UDim2.new(0,10,0,204),
        BackgroundColor3=Color3.fromRGB(45,45,58), BorderSizePixel=0,
        Font=Enum.Font.GothamBold, TextSize=11, TextXAlignment=Enum.TextXAlignment.Left,
        TextColor3=MUTED, Text="", AutoButtonColor=false,
    }, paneHub)
    new("UICorner", { CornerRadius = UDim.new(0,6) }, hopBtn)
    new("UIPadding", { PaddingLeft = UDim.new(0,10) }, hopBtn)
    local function paintHop()
        hopBtn.Text = (HOP.enabled and "●  AUTO HOP ACTIVO" or "○  AUTO HOP APAGADO")
            .. "   ·   escanea, sube todo y salta"
        hopBtn.TextColor3 = HOP.enabled and Color3.new(1,1,1) or MUTED
        hopBtn.BackgroundColor3 = HOP.enabled and ORANGE_BG or Color3.fromRGB(45,45,58)
    end
    paintHop()
    hopBtn.MouseButton1Click:Connect(function()
        HOP.enabled = not HOP.enabled
        HOP.since = os.clock()
        HOP.status = HOP.enabled and "escaneando este server" or "inactivo"
        paintHop(); saveConfig()
    end)

    hopStatus = new("TextLabel", {
        Size=UDim2.new(1,-20,0,14), Position=UDim2.new(0,10,0,236), BackgroundTransparency=1,
        Font=Enum.Font.Code, TextSize=11, TextColor3=MUTED,
        TextXAlignment=Enum.TextXAlignment.Left, Text="",
    }, paneHub)

    label(paneHub, "SEGUNDOS ESCANEANDO", 254)
    local dwellBox = new("TextBox", {
        Size=UDim2.new(0,140,0,26), Position=UDim2.new(0,10,0,272), BackgroundColor3=BG2,
        BorderSizePixel=0, Font=Enum.Font.Code, TextSize=11, TextColor3=TXT,
        ClearTextOnFocus=false, Text=tostring(HOP.dwell), TextXAlignment=Enum.TextXAlignment.Left,
    }, paneHub)
    new("UICorner", { CornerRadius = UDim.new(0,6) }, dwellBox)
    new("UIPadding", { PaddingLeft = UDim.new(0,8) }, dwellBox)
    dwellBox.FocusLost:Connect(function()
        HOP.dwell = math.max(8, tonumber(dwellBox.Text) or CFG.HOP_DWELL)
        dwellBox.Text = tostring(HOP.dwell); saveConfig()
    end)

    new("TextLabel", {
        Size=UDim2.new(0,180,0,16), Position=UDim2.new(0,162,0,254), BackgroundTransparency=1,
        Font=Enum.Font.GothamBold, TextSize=11, TextColor3=MUTED,
        TextXAlignment=Enum.TextXAlignment.Left, Text="MAX. JUGADORES DEL DESTINO",
    }, paneHub)
    local maxBox = new("TextBox", {
        Size=UDim2.new(0,140,0,26), Position=UDim2.new(0,162,0,272), BackgroundColor3=BG2,
        BorderSizePixel=0, Font=Enum.Font.Code, TextSize=11, TextColor3=TXT,
        ClearTextOnFocus=false, Text=tostring(HOP.maxPlayers), TextXAlignment=Enum.TextXAlignment.Left,
    }, paneHub)
    new("UICorner", { CornerRadius = UDim.new(0,6) }, maxBox)
    new("UIPadding", { PaddingLeft = UDim.new(0,8) }, maxBox)
    maxBox.FocusLost:Connect(function()
        HOP.maxPlayers = math.max(1, tonumber(maxBox.Text) or CFG.HOP_MAXPLAYERS)
        maxBox.Text = tostring(HOP.maxPlayers); saveConfig()
    end)

    local hubEnableBtn = mkBtn(paneHub, "", 10, 130, Color3.fromRGB(45,45,58))
    local function paintHub()
        hubEnableBtn.Text = HUB.enabled and "● REPORTANDO" or "○ DESACTIVADO"
        hubEnableBtn.BackgroundColor3 = HUB.enabled and Color3.fromRGB(52,40,130) or Color3.fromRGB(45,45,58)
    end
    paintHub()
    hubEnableBtn.MouseButton1Click:Connect(function()
        HUB.url = (hubUrlBox.Text:gsub("%s+", ""):gsub("/+$", ""))
        HUB.key = (hubKeyBox.Text:gsub("%s+", ""))
        HUB.enabled = not HUB.enabled
        paintHub(); saveConfig()
        if HUB.enabled then HUB.known = {}; HUB.status = "encendido" end
    end)

    mkBtn(paneHub, "PROBAR", 148, 70, BLUE).MouseButton1Click:Connect(function()
        HUB.url = (hubUrlBox.Text:gsub("%s+", ""):gsub("/+$", ""))
        HUB.key = (hubKeyBox.Text:gsub("%s+", ""))
        saveConfig()
        task.spawn(function()
            local ok, err = hubSend({}, "test")
            HUB.status = ok and ("hub ok · " .. HUB.lastMs .. "ms") or ("hub error: " .. tostring(err))
        end)
    end)

    mkBtn(paneHub, "RE-ENVIAR TODO", 226, 120, Color3.fromRGB(120,50,50)).MouseButton1Click:Connect(function()
        HUB.known = {}; HUB.status = "re-enviando..."
    end)

    mkBtn(paneHub, "OLVIDAR VISITADOS", 354, 125, Color3.fromRGB(120,50,50)).MouseButton1Click:Connect(function()
        HOP.visited = {}; saveVisited(); HOP.status = "lista de visitados vacia"
    end)

    hubStatus = new("TextLabel", {
        Size=UDim2.new(1,-20,0,32), Position=UDim2.new(0,10,1,-76), BackgroundTransparency=1,
        Font=Enum.Font.Code, TextSize=11, TextColor3=MUTED,
        TextXAlignment=Enum.TextXAlignment.Left, TextYAlignment=Enum.TextYAlignment.Top, Text="",
    }, paneHub)

    local function selectTab(which)
        paneList.Visible = (which == "list")
        paneHook.Visible = (which == "hook")
        paneHub.Visible  = (which == "hub")
        tabList.TextColor3 = (which=="list") and ACCENT or MUTED
        tabHook.TextColor3 = (which=="hook") and ACCENT or MUTED
        tabHub.TextColor3  = (which=="hub")  and BLUE   or MUTED
        tabList.BackgroundColor3 = (which=="list") and BG2 or BG3
        tabHook.BackgroundColor3 = (which=="hook") and BG2 or BG3
        tabHub.BackgroundColor3  = (which=="hub")  and BG2 or BG3
    end
    tabList.MouseButton1Click:Connect(function() selectTab("list") end)
    tabHook.MouseButton1Click:Connect(function() selectTab("hook") end)
    tabHub.MouseButton1Click:Connect(function()  selectTab("hub")  end)
    selectTab("list")
end

----------------------------------------------------------------------
-- LOOP
----------------------------------------------------------------------
local acc = 0
pcall(refresh)

RunService.RenderStepped:Connect(function(dt)
    acc = acc + dt
    if acc >= CFG.REFRESH then acc = 0; pcall(refresh) end

    local char = LocalPlayer.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")

    local rows = {}
    for i, e in ipairs(entries) do
        local dist = hrp and (e.anchor.Position - hrp.Position).Magnitude or 0
        local bb = labels[e.model]
        if bb and bb.Parent then
            bb.Enabled = showLabels
            local t = bb:FindFirstChild("T")
            if t then
                t.Text = string.format(
                    '<font color="#%s"><b>%s%s</b></font>\n%s · <b>%s kg</b> · %dm%s',
                    e.color:ToHex(), e.mark, e.name, e.rarity,
                    comma(e.kg), math.floor(dist),
                    e.zone and (" · " .. (e.area ~= "" and e.area:upper() or "ZONA")) or " · base")
            end
        end
        if i <= 70 then
            rows[#rows+1] = string.format(
                '<font color="#%s">%-22s</font>%10s kg %5dm  %s%s',
                e.color:ToHex(), (e.mark..e.name):sub(1,22),
                comma(e.kg), math.floor(dist), e.rarity,
                e.zone and ("  [" .. (e.area ~= "" and e.area:sub(1,8) or "Z") .. "]") or "  ·base")
        end
    end

    local nqueue = 0; for _ in pairs(HUB.pending) do nqueue = nqueue + 1 end
    local nlive  = 0; for _ in pairs(HUB.live)    do nlive  = nlive  + 1 end

    local hopTxt = "OFF"
    if HOP.enabled then
        local left = math.max(0, math.ceil(HOP.dwell - (os.clock() - HOP.since)))
        hopTxt = HOP.busy and "saltando" or ("salta en " .. left .. "s")
    end

    headLabel.Text = string.format(
        "JF EGG ESP v8        F7 labels · F8 panel\n" ..
        "ZONA %d/%d  ·  base %d ignorados en envio  ·  color~ %d\n" ..
        "webhook %s · %d env   |   hub %s · %d subidos   |   scan %s · %d saltos",
        stats.zoneOk, stats.zone, stats.base, stats.guessed,
        WH.enabled and "ON" or "OFF", WH.count,
        HUB.enabled and "ON" or "OFF", HUB.count,
        hopTxt, HOP.hops)

    local areas = {}
    for name, n in pairs(stats.byArea) do areas[#areas+1] = string.format("%s=%d", name, n) end
    table.sort(areas)
    local footer = "\n\n<font color=\"#5a5f6e\">zonas: "
        .. (#areas > 0 and table.concat(areas, "  ") or "ninguna") .. "</font>"

    listBody.Text = ((#rows > 0) and table.concat(rows, "\n")
                    or (table.concat(DIAG, "\n") .. "\n\nsin resultados")) .. footer

    statusLabel.Text = string.format("cola:%d  enviados:%d  ·  %s", #WH.queue, WH.count, WH.status)

    hubStatus.Text = string.format(
        "cola:%d  vivos:%d  subidos:%d  peticiones:%d  ultima:%dms\n%s",
        nqueue, nlive, HUB.count, HUB.pushes, HUB.lastMs, HUB.status)

    local nvis = 0; for _ in pairs(HOP.visited) do nvis = nvis + 1 end
    hopStatus.Text = string.format("saltos:%d  ·  visitados:%d  ·  %s", HOP.hops, nvis, HOP.status)
end)

UserInputService.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.KeyCode == CFG.TOGGLE_LABELS then showLabels = not showLabels
    elseif i.KeyCode == CFG.TOGGLE_PANEL then panelFrame.Visible = not panelFrame.Visible end
end)
