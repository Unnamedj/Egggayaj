--[[
    SAE · EGG REPORTER v9
    F7 = labels    F8 = panel

    Cambio de fondo frente al v8: el envio ya NO es un goteo continuo.

      El v8 reescaneaba cada segundo y subia correcciones sobre la marcha. Eso
      hacia que un huevo llegara al hub con una rareza y se corrigiera despues,
      o peor, que se quedara con la equivocada.

      El v9 hace cuatro cosas, en este orden y sin adelantarse:

        1. ESPERA a que el server termine de cargar. No escanea para saberlo:
           escucha el ChildAdded del contenedor de huevos. Mientras sigan
           apareciendo modelos el server sigue cargando; cuando lleva QUIET
           segundos sin novedades, ya esta. Asi se adapta solo a un server
           rapido o a uno que tarda 30s, sin numeros magicos.
        2. UN escaneo. Uno solo.
        3. Manda ese resultado de una vez, con full=true.
        4. Y solo entonces salta al siguiente server.

    Por que se equivocaba de rarezas (los tres fallos, ya corregidos):

      1. recordAssetId recorria pairs(rec) y se quedaba con el primer texto que
         sonara a asset. pairs() no tiene orden estable, asi que el mismo huevo
         podia resolverse como dos assets distintos en dos pasadas.
      2. Los records se indexaban tambien por campos como Slot o Key, que los
         huevos de zona COMPARTEN (Slot_002 se repite en cada server). Un huevo
         acababa cogiendo el record de otro.
      3. Si no habia record, adivinaba la rareza por el color del modelo.

      Ahora la busqueda sigue siendo amplia, pero DETERMINISTA: campos con
      prioridad en orden fijo, luego el nombre visible, y por ultimo el resto
      de campos solo si todos apuntan al mismo asset. Una colision se juzga por
      si dos records DISCREPAN, no por si son la misma tabla: el juego devuelve
      el mismo huevo en dos lecturas distintas y compararlo por identidad
      anulaba la clave y dejaba el reporte a cero.

      Lo que no se resuelve con certeza no se envia. Y si no se resuelve NADA
      habiendo huevos delante, no se manda un snapshot vacio: eso le diria al
      hub que el server esta limpio y borraria un reporte bueno anterior.

    Los labels en pantalla siguen refrescandose en vivo: eso es cosmetico y no
    toca la red.
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
    LABEL_REFRESH  = 1,
    ZONE_CONTAINER = "AreaEggSlotsClient",
    CONFIG_FILE    = "jf_reporter_v9.json",
    VISITED_FILE   = "jf_esp_visited.json",

    -- Esperar a que el server cargue, y ENTONCES una sola pasada.
    -- No hace falta escanear para saber si ha terminado de cargar: el
    -- contenedor de huevos avisa cada vez que le añaden un modelo, asi que
    -- basta con esperar a que deje de avisar.
    QUIET          = 2.5,   -- s sin modelos nuevos = el server ya cargo
    READY_TIMEOUT  = 60,    -- s como mucho esperando esa señal
    HEARTBEAT      = 120,   -- s entre latidos que mantienen vivo el reporte

    -- auto hop
    HOP_AFTER_SEND = true,
    HOP_MAXPLAYERS = 2,
    HOP_PAGES      = 8,
    VISITED_TTL    = 3 * 3600,
    HOP_RETRY      = 4,
    HOP_STUCK      = 20,
}

-- Los de base se leen para poder contarlos y etiquetarlos en pantalla, pero
-- solo este contenedor puede acabar en la red.
local CONTAINERS = { "AreaEggSlotsClient", "PlacedEggRenders", "Eggs", "New Pets" }
local ZONE_OK    = { AreaEggSlotsClient = true }

local DIAG = {}
local function diag(fmt, ...) DIAG[#DIAG+1] = string.format(fmt, ...) end

local function new(class, props, parent)
    local o = Instance.new(class)
    for k, v in pairs(props or {}) do o[k] = v end
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
-- ÍNDICE DE ASSETS
----------------------------------------------------------------------
local assetIndex, rarityList = {}, {}
local byEggName = {}   -- nombre -> info, o false si dos assets lo comparten

do
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
                    end
                end
            end
        end
    end

    -- Indice por nombre de huevo. Si dos assets distintos comparten nombre se
    -- marca como ambiguo y nunca se usa: preferimos no resolver a resolver mal.
    for _, info in pairs(assetIndex) do
        local k = tostring(info.eggName):lower()
        if byEggName[k] == nil then
            byEggName[k] = info
        elseif byEggName[k] and byEggName[k].id ~= info.id then
            byEggName[k] = false
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
    diag("assets:%d rarezas:%d", n, #rarityList)
end

----------------------------------------------------------------------
-- ZONAS DEL MAPA
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

local function areaOf(model, pos)
    local byName = model.Name:match("^FirstAreaEgg_[%d_]+_([%a%s]+):Slot")
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
-- RESOLUCIÓN DE RECORDS
----------------------------------------------------------------------
-- Estos campos tienen PRIORIDAD para identificar el asset, en este orden.
-- Si ninguno acierta se mira el resto del record, pero de forma ordenada:
-- el problema del v8 no era mirar campos de mas, era que pairs() decidia el
-- ganador y pairs() no tiene orden garantizado.
local ASSET_KEYS = { "AssetId", "Asset", "AssetName", "Species", "EggType", "Type", "Id", "Name" }

-- Claves con las que se puede localizar un record desde el nombre del modelo.
local ID_FIELDS = { "Uid", "UID", "uid", "Id", "ID", "Key", "SlotKey", "ModelName", "Slot" }

local function displayNameOf(rec)
    if EggRecords and EggRecords.DisplayName then
        local ok, v = pcall(EggRecords.DisplayName, rec)
        if ok and type(v) == "string" and v ~= "" then return v end
    end
    return nil
end

-- Determinista pase lo que pase:
--   1. campos con prioridad, en orden fijo
--   2. nombre visible, si es inequivoco
--   3. cualquier otro campo de texto que sea un asset conocido, pero SOLO si
--      todos apuntan al mismo. Si discrepan, no se resuelve: preferimos
--      omitir el huevo a mandarlo con la rareza de otro.
local function recordAssetId(rec)
    if type(rec) ~= "table" then return nil end

    for _, k in ipairs(ASSET_KEYS) do
        local v = rec[k]
        if type(v) == "string" and assetIndex[v] then return v end
    end

    local dn = displayNameOf(rec)
    if dn then
        local hit = byEggName[dn:lower()]
        if hit then return hit.id end
    end

    local only
    for _, v in pairs(rec) do
        if type(v) == "string" and assetIndex[v] then
            if only == nil then only = v
            elseif only ~= v then return nil end
        end
    end
    return only
end

-- Sirve tambien con assetIndex vacio (si Data.Assets no cargo): asi el
-- diagnostico puede enseñar que records hay aunque no se puedan resolver.
local function looksLikeRecord(t)
    if type(t) ~= "table" then return false end
    for _, k in ipairs(ASSET_KEYS) do
        if type(t[k]) == "string" and assetIndex[t[k]] then return true end
    end
    if displayNameOf(t) ~= nil then return true end
    for _, f in ipairs({ "Uid", "UID", "uid" }) do
        if type(t[f]) == "string" and t[f] ~= "" then return true end
    end
    return false
end

-- Dos lecturas distintas (ReadFieldEggs y ReadOwnerEggs) devuelven el MISMO
-- huevo en tablas distintas. Comparar por identidad marcaba eso como colision
-- y anulaba la clave: con eso no se resolvia ni un huevo. Lo que importa es si
-- discrepan en el asset, no si son la misma tabla.
local function put(out, key, node)
    if type(key) ~= "string" or key == "" then return end
    local cur = out[key]
    if cur == nil or cur == node then out[key] = node; return end
    if cur == false then return end
    local a, b = recordAssetId(cur), recordAssetId(node)
    if a and b and a == b then return end   -- el mismo huevo visto dos veces
    out[key] = false                        -- de verdad se contradicen
end

local function deepIndex(node, out, depth, key, seen)
    if type(node) ~= "table" or depth > 6 or seen[node] then return end
    seen[node] = true
    if looksLikeRecord(node) then
        put(out, key, node)
        for _, f in ipairs(ID_FIELDS) do
            put(out, node[f], node)
        end
        return
    end
    for k, v in pairs(node) do deepIndex(v, out, depth+1, k, seen) end
end

local function collectRecords()
    local out = {}
    if not EggState then return out, 0 end
    local seen = {}
    local function take(t) if type(t)=="table" then deepIndex(t, out, 0, nil, seen) end end

    local ok, r = pcall(function() return EggState.ReadFieldEggs() end); if ok then take(r) end
    ok, r = pcall(function() return EggState.ReadOwnedEggs() end);       if ok then take(r) end
    for _, p in ipairs(Players:GetPlayers()) do
        local ok2, r2 = pcall(function() return EggState.ReadOwnerEggs(p.UserId) end)
        if ok2 then take(r2) end
    end
    local n = 0; for _, v in pairs(out) do if v then n = n + 1 end end
    return out, n
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
    if code == 401 then return false, "API key incorrecta" end
    if code == 404 then return false, "404 · revisa la URL del hub" end
    if code >= 200 and code < 300 then return true, res.Body end
    return false, "HTTP " .. tostring(code)
end


local function colorInt(c)
    return math.floor(c.R*255)*65536 + math.floor(c.G*255)*256 + math.floor(c.B*255)
end

local function comma(n)
    local s = tostring(math.floor(tonumber(n) or 0 + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

----------------------------------------------------------------------
-- ESTADO
----------------------------------------------------------------------
local WH  = { url="", enabled=false, rarities={}, count=0, status="inactivo", queue={} }
local HUB = { url="", key="", enabled=true, count=0, status="inactivo", lastMs=0 }
local HOP = { enabled=false, busy=false, busySince=0, hops=0, visited={}, status="inactivo" }

-- Se normaliza en cada envio, no solo al salir del campo: una barra final
-- convertia /api/report en //api/report, que el hub servia como fichero (404).
local function hubBase()
    local u = tostring(HUB.url or ""):gsub("%s+", "")
    u = u:gsub("/+$", ""):gsub("/api$", "")
    if u ~= "" and not u:match("^https?://") then u = "https://" .. u end
    return u
end

local SCAN = {
    -- espera | escaneando | enviando | listo | error
    phase   = "espera",
    failStreak = 0,
    passes  = 0,
    stable  = 0,
    found   = 0,
    skipped = 0,
    base    = 0,
    sent    = 0,
    detail  = "",
    eggs    = {},
    doneAt  = 0,
}

local function saveConfig()
    pcall(function()
        if type(writefile) ~= "function" then return end
        writefile(CFG.CONFIG_FILE, HttpService:JSONEncode({
            url = WH.url, enabled = WH.enabled, rarities = WH.rarities,
            hubUrl = HUB.url, hubKey = HUB.key, hubEnabled = HUB.enabled,
            hopEnabled = HOP.enabled, hopMax = CFG.HOP_MAXPLAYERS,
        }))
    end)
end

local function loadConfig()
    pcall(function()
        if type(readfile) ~= "function" or type(isfile) ~= "function" then return end
        if not isfile(CFG.CONFIG_FILE) then return end
        local d = HttpService:JSONDecode(readfile(CFG.CONFIG_FILE))
        WH.url      = d.url or ""
        WH.enabled  = d.enabled or false
        WH.rarities = d.rarities or {}
        HUB.url     = d.hubUrl or ""
        HUB.key     = d.hubKey or ""
        if d.hubEnabled ~= nil then HUB.enabled = d.hubEnabled end
        HOP.enabled = d.hopEnabled or false
        CFG.HOP_MAXPLAYERS = tonumber(d.hopMax) or CFG.HOP_MAXPLAYERS
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
            if type(at) == "number" and (now - at) < CFG.VISITED_TTL then HOP.visited[jobId] = at end
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
-- ESCANEO
----------------------------------------------------------------------
local function anchorOf(model)
    local hb = model:FindFirstChild("Hitbox")
    if hb and hb:IsA("BasePart") then return hb end
    if model:IsA("BasePart") then return model end
    for _, d in ipairs(model:GetDescendants()) do
        if d:IsA("BasePart") then return d end
    end
    return nil
end

local function uidFromModelName(n)
    local _, uid = n:match("^(%d+)_(%w+)$")
    return uid or n
end

-- Una pasada completa. Devuelve solo lo que se resolvio CON CERTEZA, mas los
-- contadores de lo que se dejo fuera y por que.
local function scanOnce()
    local recs, nrec = collectRecords()
    local eggs, skipped, base = {}, 0, 0

    -- Todo lo que hace falta para entender un escaneo que sale mal, sin tener
    -- que adivinar desde fuera.
    local D = { zone = 0, why = {}, sampleKeys = nil, sampleName = nil, misses = {} }
    local function fail(reason, modelName)
        skipped = skipped + 1
        D.why[reason] = (D.why[reason] or 0) + 1
        if #D.misses < 6 then D.misses[#D.misses+1] = (modelName or "?") .. " → " .. reason end
    end

    for _, container in ipairs(Workspace:GetChildren()) do
        if table.find(CONTAINERS, container.Name) then
            local isZone = ZONE_OK[container.Name] == true
            for _, model in ipairs(container:GetChildren()) do
                if not isZone then
                    base = base + 1
                else
                    D.zone = D.zone + 1
                    local uid = uidFromModelName(model.Name)
                    local collided = (recs[uid] == false) or (recs[model.Name] == false)

                    local rec = recs[uid]
                    if rec == false then rec = nil end
                    if not rec then
                        local alt = recs[model.Name]
                        if alt ~= false then rec = alt end
                    end
                    if not rec then rec = fetchField(model.Name) or fetchField(uid) end

                    -- Guarda una muestra de los campos de un record real: es lo
                    -- unico que dice como se llaman de verdad en este juego.
                    if rec and not D.sampleKeys then
                        local ks = {}
                        for k, v in pairs(rec) do
                            if #ks < 14 then ks[#ks+1] = tostring(k) .. "=" .. type(v) end
                        end
                        table.sort(ks)
                        D.sampleKeys = table.concat(ks, " ")
                        D.sampleName = displayNameOf(rec) or "(sin DisplayName)"
                    end

                    local aid = rec and recordAssetId(rec) or nil
                    local info = aid and assetIndex[aid] or nil
                    local anchor = anchorOf(model)

                    if info and anchor then
                        eggs[#eggs+1] = {
                            uid    = uid,
                            info   = info,
                            kg     = recordKg(rec, info),
                            name   = info.eggName,
                            rarity = info.rarity,
                            color  = info.color,
                            anchor = anchor,
                            area   = areaOf(model, anchor.Position),
                            model  = model,
                        }
                    elseif not anchor then
                        fail("sin parte fisica", model.Name)
                    elseif not rec then
                        fail(collided and "clave duplicada" or "sin record", model.Name)
                    else
                        fail("record sin asset reconocible", model.Name)
                    end
                end
            end
        end
    end

    table.sort(eggs, function(a, b) return a.uid < b.uid end)
    D.records = nrec
    return eggs, skipped, base, nrec, D
end

-- Espera a que el server este cargado de verdad. Esto NO escanea: mira si el
-- cliente cargo, si hay personaje, si existe el contenedor de zona, y sobre
-- todo escucha su ChildAdded. Mientras sigan apareciendo modelos, el server
-- sigue cargando; cuando lleva QUIET segundos sin novedades, ya esta.
-- Devuelve el contenedor, o nil y el motivo.
local function waitForServer()
    local t0 = os.clock()
    local function timeLeft() return CFG.READY_TIMEOUT - (os.clock() - t0) end

    SCAN.phase = "espera"

    SCAN.detail = "esperando a que cargue el cliente"
    if not game:IsLoaded() then pcall(function() game.Loaded:Wait() end) end

    SCAN.detail = "esperando al personaje"
    if not LocalPlayer.Character then
        pcall(function() LocalPlayer.CharacterAdded:Wait() end)
    end

    SCAN.detail = "esperando la zona de huevos"
    local zone = Workspace:FindFirstChild(CFG.ZONE_CONTAINER)
    if not zone then
        local ok, z = pcall(function()
            return Workspace:WaitForChild(CFG.ZONE_CONTAINER, math.max(1, timeLeft()))
        end)
        zone = ok and z or nil
    end
    if not zone then return nil, "no aparecio " .. CFG.ZONE_CONTAINER end

    local lastAdd = os.clock()
    local conn = zone.ChildAdded:Connect(function() lastAdd = os.clock() end)

    while true do
        task.wait(0.3)
        local quiet  = os.clock() - lastAdd
        local models = #zone:GetChildren()
        SCAN.detail = ("%d modelos en la zona · %.1fs sin novedades"):format(models, quiet)

        if models > 0 and quiet >= CFG.QUIET then
            -- collectRecords es caro, asi que solo se comprueba cuando el
            -- contenedor ya esta quieto. Los records del juego pueden llegar
            -- despues que los modelos.
            local _, nrec = collectRecords()
            if nrec > 0 then
                conn:Disconnect()
                return zone
            end
            SCAN.detail = ("%d modelos, esperando los datos del juego"):format(models)
        end

        if timeLeft() <= 0 then
            conn:Disconnect()
            return zone, "se agoto la espera"
        end
    end
end

----------------------------------------------------------------------
-- ENVÍO (una sola vez)
----------------------------------------------------------------------
local function eggPayload(e)
    local info = e.info
    local pos  = e.anchor and e.anchor.Position or Vector3.new()
    return {
        uid       = e.uid,
        name      = info.eggName,
        species   = info.id,
        rarity    = info.rarity,
        rarityNum = info.rarityNum,
        odds      = info.odds,
        kg        = math.floor(e.kg * 100 + 0.5) / 100,
        petName   = info.petName,
        growth    = tostring(info.growth or 0) .. "s",
        growthSec = tonumber(info.growth) or 0,
        earn      = comma(info.earn or 0),
        earnRate  = tonumber(info.earn) or 0,
        area      = e.area or "",
        source    = "zone",
        pos       = string.format("%d, %d, %d", pos.X, pos.Y, pos.Z),
    }
end

local function buildEmbed(e)
    local pos = e.anchor and e.anchor.Position or Vector3.new()
    local info = e.info
    local jobId = game.JobId ~= "" and game.JobId or "servidor privado / studio"
    return HttpService:JSONEncode({
        embeds = {{
            title       = "🥚  " .. info.eggName,
            color       = colorInt(e.color),
            description = string.format("**%s**  ·  %s", info.rarity, info.odds or "?"),
            fields = {
                { name = "Peso",      value = "`" .. comma(e.kg) .. " kg`",            inline = true },
                { name = "Mascota",   value = info.petName or "?",                     inline = true },
                { name = "Zona",      value = (e.area ~= "" and e.area) or "Zona",     inline = true },
                { name = "Ganancia",  value = "`" .. comma(info.earn or 0) .. "/s`",   inline = true },
                { name = "Eclosión",  value = "`" .. tostring(info.growth or 0) .. "s`", inline = true },
                { name = "Posición",  value = string.format("`%d, %d, %d`", pos.X, pos.Y, pos.Z), inline = true },
                { name = "Job ID",    value = "```" .. jobId .. "```",                 inline = false },
                { name = "Unirse",    value = string.format("```js\nRoblox.GameLauncher.joinGameInstance(%d, \"%s\")\n```", game.PlaceId, jobId), inline = false },
                { name = "Jugadores", value = string.format("`%d / %d`", #Players:GetPlayers(), Players.MaxPlayers), inline = true },
            },
            footer    = { text = "SAE By joszz  ·  zona" },
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
                WH.count = WH.count + 1
                WH.status = "enviado " .. os.date("%H:%M:%S")
            else
                WH.status = "error: " .. tostring(err)
            end
            task.wait(1.6)
        else
            task.wait(0.5)
        end
    end
end)

-- Un reporte, con full=true: el hub se queda exactamente con esto para este
-- server y tira cualquier cosa anterior.
-- Lo ultimo que se mando bien, ya convertido a payload plano: el latido lo
-- reenvia sin volver a tocar los modelos del juego.
local LAST = { payload = nil, jobId = nil, at = 0 }

local function sendReport(eggs)
    if not HUB.enabled or HUB.url == "" then
        HUB.status = "hub apagado o sin URL"
        return false, "sin hub"
    end
    local payload = {}
    for _, e in ipairs(eggs) do payload[#payload+1] = eggPayload(e) end

    local body = HttpService:JSONEncode({
        jobId      = game.JobId ~= "" and game.JobId or "studio",
        placeId    = tostring(game.PlaceId),
        players    = #Players:GetPlayers(),
        maxPlayers = Players.MaxPlayers,
        reporter   = LocalPlayer.Name,
        full       = true,
        eggs       = payload,
    })

    local t0 = os.clock()
    local ok, err = httpPost(hubBase() .. "/api/report", body, { ["x-eag-key"] = HUB.key })
    HUB.lastMs = math.floor((os.clock() - t0) * 1000)
    if ok then
        HUB.count = HUB.count + #payload
        HUB.status = string.format("%d huevos · %dms · %s", #payload, HUB.lastMs, os.date("%H:%M:%S"))
        LAST.payload = payload
        LAST.jobId = game.JobId
        LAST.at = os.time()
    else
        HUB.status = "error: " .. tostring(err)
    end
    return ok, err
end

-- Latido. El hub olvida un server que lleva SERVER_TTL_SEC sin dar señales
-- (8 min por defecto), asi que un reporte de un solo disparo se evaporaba y el
-- hallazgo desaparecia aunque el huevo siguiera ahi. Reenvia EXACTAMENTE lo
-- mismo: los uid ya son conocidos, asi que no crea huevos nuevos, no cambia
-- ninguna rareza y no dispara eventos en el AJ. Solo dice "sigo aqui".
task.spawn(function()
    while true do
        task.wait(CFG.HEARTBEAT)
        if HUB.enabled and LAST.payload and LAST.jobId == game.JobId and not HOP.busy then
            local body = HttpService:JSONEncode({
                jobId      = game.JobId ~= "" and game.JobId or "studio",
                placeId    = tostring(game.PlaceId),
                players    = #Players:GetPlayers(),
                maxPlayers = Players.MaxPlayers,
                reporter   = LocalPlayer.Name,
                full       = true,
                eggs       = LAST.payload,
            })
            local ok = httpPost(hubBase() .. "/api/report", body, { ["x-eag-key"] = HUB.key })
            if ok then
                HUB.status = string.format("%d huevos · latido %s",
                    #LAST.payload, os.date("%H:%M:%S"))
            end
        end
    end
end)

local function sendWebhook(eggs)
    if not WH.enabled or WH.url == "" then return end
    for _, e in ipairs(eggs) do
        if WH.rarities[e.rarity] then WH.queue[#WH.queue+1] = buildEmbed(e) end
    end
end

----------------------------------------------------------------------
-- AUTO HOP
----------------------------------------------------------------------
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
    local best, cursor = nil, ""
    for _ = 1, CFG.HOP_PAGES do
        local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100")
            :format(game.PlaceId)
        if cursor ~= "" then url = url .. "&cursor=" .. cursor end
        local page = httpGetJson(url)
        if not page or not page.data then break end
        for _, srv in ipairs(page.data) do
            local playing = srv.playing
            if playing and srv.id ~= game.JobId and not HOP.visited[srv.id] then
                if playing <= CFG.HOP_MAXPLAYERS then
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

local runScan  -- declarado antes para que doHop pueda reintentar el ciclo

local function doHop()
    if HOP.busy then return end
    HOP.busy = true
    HOP.busySince = os.clock()
    HOP.status = "buscando server vacio…"

    local target = findNextServer()
    if not target then
        HOP.status = "sin servers nuevos · reintento en 10s"
        HOP.busy = false
        task.delay(10, function() if HOP.enabled then doHop() end end)
        return
    end

    HOP.visited[target.id] = os.time()
    if game.JobId ~= "" then HOP.visited[game.JobId] = os.time() end
    saveVisited()
    HOP.hops = HOP.hops + 1
    HOP.status = ("saltando -> %s · %d jug"):format(target.id:sub(1,8), target.playing or 0)

    local ok, err = pcall(function()
        TeleportService:TeleportToPlaceInstance(game.PlaceId, target.id, LocalPlayer)
    end)
    if not ok then
        HOP.status = "fallo el salto: " .. tostring(err)
        HOP.busy = false
        task.delay(CFG.HOP_RETRY, function() if HOP.enabled then doHop() end end)
    end
end

TeleportService.TeleportInitFailed:Connect(function(_, _, msg)
    HOP.status = "teleport rechazado: " .. tostring(msg)
    HOP.busy = false
    task.delay(CFG.HOP_RETRY, function() if HOP.enabled then doHop() end end)
end)

task.spawn(function()
    while true do
        task.wait(2)
        if HOP.enabled and HOP.busy and (os.clock() - HOP.busySince) > CFG.HOP_STUCK then
            HOP.status = "el salto no llego a ocurrir"
            HOP.busy = false
            doHop()
        end
    end
end)

----------------------------------------------------------------------
-- EL CICLO: escanear hasta que se estabilice -> mandar una vez -> saltar
----------------------------------------------------------------------
local scanning = false

runScan = function(manual)
    if scanning then return end
    scanning = true

    task.spawn(function()
        SCAN.phase, SCAN.passes = "espera", 0

        -- 1. Esperar. Aqui no se escanea nada: solo se espera la señal de que
        --    el server termino de cargar.
        local zoneFolder, warn = waitForServer()
        if not zoneFolder then
            SCAN.phase = "error"
            SCAN.detail = tostring(warn)
            SCAN.doneAt = os.time()
            scanning = false
            return
        end

        -- 2. Un escaneo. Uno solo.
        SCAN.phase = "escaneando"
        SCAN.detail = "escaneo unico"
        local eggs, skipped, base, nrec, D = scanOnce()
        SCAN.passes = 1
        SCAN.found, SCAN.skipped, SCAN.base, SCAN.diag = #eggs, skipped, base, D
        SCAN.eggs = eggs

        local zone = (D and D.zone) or 0

        -- Habia modelos de zona delante y no se resolvio ninguno: es un fallo
        -- de resolucion, no un server vacio. Mandar full=true con lista vacia
        -- le diria al hub "aqui no hay nada" y borraria un reporte bueno.
        if #eggs == 0 and zone > 0 then
            SCAN.failStreak = (SCAN.failStreak or 0) + 1
            SCAN.phase = "error"
            SCAN.doneAt = os.time()
            SCAN.sent = 0
            SCAN.detail = ("%d modelos de zona y 0 resueltos · no se manda nada · mira DIAGNOSTICO")
                :format(zone)
            scanning = false

            -- Si falla en varios servers seguidos el problema no es el server:
            -- dejar de saltar y quedarse quieto para que se pueda mirar.
            if SCAN.failStreak >= 3 then
                HOP.status = "parado: " .. SCAN.failStreak .. " servers seguidos sin resolver nada"
                return
            end
            if HOP.enabled and not manual then task.wait(2); doHop() end
            return
        end

        -- 3. Enviar.
        SCAN.failStreak = 0
        SCAN.phase = "enviando"
        SCAN.detail = ("mandando %d huevos"):format(#eggs)

        sendWebhook(eggs)
        local ok, err = sendReport(eggs)

        SCAN.sent = ok and #eggs or 0
        SCAN.doneAt = os.time()
        SCAN.phase = ok and "listo" or "error"
        SCAN.detail = ok
            and ("%d enviados · %d sin record · %d de base ignorados")
                :format(#eggs, skipped, base)
            or ("no se pudo enviar: " .. tostring(err))

        scanning = false

        -- 4. Y solo ahora, el salto. Nunca antes, y solo si el reporte llego.
        if ok and HOP.enabled and not manual then
            task.wait(1)
            doHop()
        end
    end)
end

----------------------------------------------------------------------
-- LABELS (solo visual, se refrescan en vivo)
----------------------------------------------------------------------
local labels, showLabels, liveList = {}, true, {}

local function clearLabel(model)
    local l = labels[model]
    if l then pcall(function() l:Destroy() end) end
    labels[model] = nil
end

local function refreshLabels()
    local eggs = SCAN.eggs
    local seen = {}
    for _, e in ipairs(eggs) do
        if e.model and e.model.Parent and e.anchor then
            seen[e.model] = true
            local bb = labels[e.model]
            if not bb or not bb.Parent then
                bb = new("BillboardGui", {
                    Name = "JF_ESP", Adornee = e.anchor,
                    Size = UDim2.new(0, 240, 0, 54),
                    StudsOffset = Vector3.new(0, 3.5, 0),
                    AlwaysOnTop = true, MaxDistance = CFG.MAX_DISTANCE,
                }, e.model)
                new("TextLabel", {
                    Name = "T", Size = UDim2.new(1,0,1,0),
                    BackgroundColor3 = Color3.new(0,0,0), BackgroundTransparency = 0.35,
                    Font = Enum.Font.GothamBold, TextSize = 13,
                    TextColor3 = Color3.new(1,1,1), TextStrokeTransparency = 0.4,
                    RichText = true,
                }, bb)
                labels[e.model] = bb
            end
            bb.Adornee = e.anchor
        end
    end
    for model in pairs(labels) do
        if not seen[model] or not model.Parent then clearLabel(model) end
    end
    liveList = eggs
end

----------------------------------------------------------------------
-- GUI
----------------------------------------------------------------------
local C = {
    bg   = Color3.fromRGB(13, 14, 19),
    card = Color3.fromRGB(22, 24, 33),
    card2= Color3.fromRGB(29, 32, 43),
    line = Color3.fromRGB(40, 44, 58),
    txt  = Color3.fromRGB(232, 236, 245),
    txt2 = Color3.fromRGB(158, 166, 185),
    mut  = Color3.fromRGB(108, 116, 138),
    acc  = Color3.fromRGB(124, 92, 255),
    acc2 = Color3.fromRGB(34, 211, 238),
    ok   = Color3.fromRGB(52, 211, 153),
    bad  = Color3.fromRGB(251, 95, 120),
    warn = Color3.fromRGB(251, 191, 36),
    ink  = Color3.fromRGB(10, 12, 18),
}

local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r or 9) }, o) end
local function round(o)     new("UICorner", { CornerRadius = UDim.new(1, 0) }, o) end
local function stroke(o, col, tr, th)
    return new("UIStroke", { Color = col or C.line, Transparency = tr or 0, Thickness = th or 1 }, o)
end

local panel, phaseLbl, detailLbl, phaseDot, listBody, hubStatusLbl, whStatusLbl, hopBtnLbl, rescanLbl
local diagBody
local diagText = ""

do
    local parent
    local okH, hui = pcall(function() return gethui() end)
    if okH and hui then parent = hui end
    if not parent then parent = LocalPlayer:WaitForChild("PlayerGui") end
    local old = parent:FindFirstChild("JF_REPORTER"); if old then old:Destroy() end

    local gui = new("ScreenGui", { Name="JF_REPORTER", ResetOnSpawn=false, DisplayOrder=999999 }, parent)

    local W, H = 470, 356
    panel = new("Frame", {
        Size = UDim2.new(0, W, 0, H), Position = UDim2.new(0, 26, 0, 80),
        BackgroundColor3 = C.bg, BorderSizePixel = 0, Active = true, Draggable = true,
    }, gui)
    corner(panel, 13)
    stroke(panel, C.line, 0.3)
    new("UIGradient", {
        Rotation = 120,
        Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(23, 20, 38)),
            ColorSequenceKeypoint.new(0.6, Color3.fromRGB(14, 15, 22)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(11, 12, 17)),
        }),
    }, panel)

    -- cabecera
    local head = new("Frame", { Size = UDim2.new(1,0,0,42), BackgroundTransparency = 1 }, panel)
    new("Frame", {
        Position = UDim2.new(0,0,1,-1), Size = UDim2.new(1,0,0,1),
        BackgroundColor3 = C.line, BorderSizePixel = 0, BackgroundTransparency = 0.4,
    }, head)

    local badge = new("Frame", {
        Position = UDim2.new(0,13,0,11), Size = UDim2.new(0,20,0,20),
        BackgroundColor3 = C.acc, BorderSizePixel = 0,
    }, head)
    corner(badge, 6)
    new("UIGradient", { Rotation = 130, Color = ColorSequence.new(C.acc, C.acc2) }, badge)

    new("TextLabel", {
        Position = UDim2.new(0,41,0,6), Size = UDim2.new(0,200,0,14),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 12.5,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.txt,
        Text = "SAE · EGG REPORTER",
    }, head)
    new("TextLabel", {
        Position = UDim2.new(0,41,0,21), Size = UDim2.new(0,240,0,12),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.mut,
        Text = "un escaneo · un reporte · F7 labels · F8 panel",
    }, head)

    local close = new("TextButton", {
        Position = UDim2.new(1,-33,0,11), Size = UDim2.new(0,20,0,20),
        BackgroundColor3 = C.card, BorderSizePixel = 0, Text = "✕",
        Font = Enum.Font.GothamBold, TextSize = 10, TextColor3 = C.mut, AutoButtonColor = false,
    }, head)
    corner(close, 6); stroke(close, C.line, 0.35)
    close.MouseButton1Click:Connect(function() panel.Visible = false end)

    -- tabs
    local tabRow = new("Frame", {
        Position = UDim2.new(0,12,0,50), Size = UDim2.new(1,-24,0,26), BackgroundTransparency = 1,
    }, panel)
    new("UIListLayout", {
        FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0,5),
    }, tabRow)

    local panes = {}
    local function mkPane()
        local p = new("Frame", {
            Position = UDim2.new(0,12,0,84), Size = UDim2.new(1,-24,1,-96),
            BackgroundTransparency = 1, Visible = false,
        }, panel)
        return p
    end
    local pResult, pHub, pHook = mkPane(), mkPane(), mkPane()
    panes.result, panes.hub, panes.hook = pResult, pHub, pHook

    local tabBtns = {}
    local selectTab
    local function mkTab(key, text)
        local b = new("TextButton", {
            Size = UDim2.new(0, 104, 1, 0), BackgroundColor3 = C.card, BorderSizePixel = 0,
            Font = Enum.Font.GothamBold, TextSize = 11, TextColor3 = C.mut,
            Text = text, AutoButtonColor = false,
        }, tabRow)
        corner(b, 7)
        tabBtns[key] = b
        b.MouseButton1Click:Connect(function() selectTab(key) end)
        return b
    end
    local pDiag = mkPane()
    panes.diag = pDiag
    mkTab("result", "RESULTADO"); mkTab("hub", "HUB")
    mkTab("hook", "WEBHOOK"); mkTab("diag", "DIAGNOSTICO")

    selectTab = function(key)
        for k, p in pairs(panes) do p.Visible = (k == key) end
        for k, b in pairs(tabBtns) do
            b.BackgroundColor3 = (k == key) and C.card2 or C.card
            b.TextColor3 = (k == key) and C.txt or C.mut
        end
    end

    ------------------------------------------------------------- RESULTADO
    local statusCard = new("Frame", {
        Size = UDim2.new(1,0,0,62), BackgroundColor3 = C.card, BorderSizePixel = 0,
    }, pResult)
    corner(statusCard, 10); stroke(statusCard, C.line, 0.5)

    phaseDot = new("Frame", {
        Position = UDim2.new(0,14,0,15), Size = UDim2.new(0,8,0,8),
        BackgroundColor3 = C.warn, BorderSizePixel = 0,
    }, statusCard)
    round(phaseDot)

    phaseLbl = new("TextLabel", {
        Position = UDim2.new(0,30,0,9), Size = UDim2.new(1,-140,0,18),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.txt, Text = "esperando",
    }, statusCard)

    detailLbl = new("TextLabel", {
        Position = UDim2.new(0,30,0,29), Size = UDim2.new(1,-44,0,24),
        BackgroundTransparency = 1, Font = Enum.Font.Gotham, TextSize = 10.5,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        TextColor3 = C.mut, TextWrapped = true, Text = "",
    }, statusCard)

    local rescan = new("TextButton", {
        Position = UDim2.new(1,-112,0,13), Size = UDim2.new(0,98,0,26),
        BackgroundColor3 = C.acc, BorderSizePixel = 0, Text = "", AutoButtonColor = false,
    }, statusCard)
    corner(rescan, 7)
    rescanLbl = new("TextLabel", {
        Size = UDim2.new(1,0,1,0), BackgroundTransparency = 1,
        Font = Enum.Font.GothamBold, TextSize = 10.5,
        TextColor3 = Color3.new(1,1,1), Text = "RE-ESCANEAR",
    }, rescan)
    rescan.MouseButton1Click:Connect(function() runScan(true) end)

    new("TextLabel", {
        Position = UDim2.new(0,2,0,70), Size = UDim2.new(1,-4,0,12),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.mut,
        Text = "LO QUE SE ENVIO",
    }, pResult)

    local listScroll = new("ScrollingFrame", {
        Position = UDim2.new(0,0,0,86), Size = UDim2.new(1,0,1,-86),
        BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(0,0,0,0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, pResult)
    listBody = new("TextLabel", {
        Size = UDim2.new(1,-8,0,0), Position = UDim2.new(0,4,0,2),
        AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        Font = Enum.Font.Code, TextSize = 11, TextColor3 = C.txt2,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        RichText = true, Text = "",
    }, listScroll)

    ------------------------------------------------------------------- HUB
    local function fieldOn(parent2, label, y, placeholder, value, onDone)
        new("TextLabel", {
            Position = UDim2.new(0,2,0,y), Size = UDim2.new(1,-4,0,12),
            BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9,
            TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.mut, Text = label,
        }, parent2)
        local b = new("TextBox", {
            Position = UDim2.new(0,0,0,y+15), Size = UDim2.new(1,0,0,28),
            BackgroundColor3 = C.card, BorderSizePixel = 0, Font = Enum.Font.Code, TextSize = 10.5,
            TextColor3 = C.txt, PlaceholderText = placeholder,
            PlaceholderColor3 = Color3.fromRGB(88,94,108),
            ClearTextOnFocus = false, Text = value, TextXAlignment = Enum.TextXAlignment.Left,
        }, parent2)
        corner(b, 8)
        new("UIPadding", { PaddingLeft = UDim.new(0,9), PaddingRight = UDim.new(0,9) }, b)
        local s = stroke(b, C.line, 0.5)
        b.Focused:Connect(function() s.Color = C.acc; s.Transparency = 0 end)
        b.FocusLost:Connect(function()
            s.Color = C.line; s.Transparency = 0.5
            onDone(b.Text); saveConfig()
        end)
        return b
    end

    local hubUrlBox = fieldOn(pHub, "URL DEL HUB", 0, "https://tu-app.up.railway.app", HUB.url,
        function(v) HUB.url = (v:gsub("%s+",""):gsub("/+$","")) end)
    local hubKeyBox = fieldOn(pHub, "API KEY", 50, "la misma API_KEY del hub", HUB.key,
        function(v) HUB.key = (v:gsub("%s+","")) end)

    local function toggleOn(parent2, y, get, set, text)
        local b = new("TextButton", {
            Position = UDim2.new(0,0,0,y), Size = UDim2.new(1,0,0,28),
            BackgroundColor3 = C.card, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
            TextSize = 10.5, TextXAlignment = Enum.TextXAlignment.Left,
            TextColor3 = C.mut, Text = "", AutoButtonColor = false,
        }, parent2)
        corner(b, 8)
        new("UIPadding", { PaddingLeft = UDim.new(0,11) }, b)
        local s = stroke(b, C.line, 0.5)
        local function paint()
            local on = get()
            b.Text = (on and "●   " or "○   ") .. text
            b.TextColor3 = on and C.txt or C.mut
            s.Color = on and C.ok or C.line
            s.Transparency = on and 0.55 or 0.5
        end
        paint()
        b.MouseButton1Click:Connect(function() set(not get()); paint(); saveConfig() end)
        return b, paint
    end

    toggleOn(pHub, 100, function() return HUB.enabled end,
        function(v) HUB.enabled = v end, "reportar al hub")

    local _, paintHopBtn = toggleOn(pHub, 134, function() return HOP.enabled end,
        function(v)
            HOP.enabled = v
            HOP.status = v and "activo" or "inactivo"
            -- Si lo enciendes con el escaneo ya terminado, salta ya.
            if v and SCAN.phase == "listo" and not HOP.busy then task.delay(0.5, doHop) end
        end,
        "auto hop: al terminar el reporte, saltar al siguiente server")
    hopBtnLbl = paintHopBtn

    local testBtn = new("TextButton", {
        Position = UDim2.new(0,0,0,172), Size = UDim2.new(0,140,0,28),
        BackgroundColor3 = C.card2, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
        TextSize = 10.5, TextColor3 = C.txt2, Text = "PROBAR CONEXION", AutoButtonColor = false,
    }, pHub)
    corner(testBtn, 7); stroke(testBtn, C.line, 0.4)
    testBtn.MouseButton1Click:Connect(function()
        HUB.url = (hubUrlBox.Text:gsub("%s+",""):gsub("/+$",""))
        HUB.key = (hubKeyBox.Text:gsub("%s+",""))
        saveConfig()
        testBtn.Text = "PROBANDO…"
        task.spawn(function()
            local ok, err = httpPost(hubBase() .. "/api/report",
                HttpService:JSONEncode({ jobId = "test-" .. tostring(math.random(10000,99999)), eggs = {} }),
                { ["x-eag-key"] = HUB.key })
            testBtn.Text = ok and "CONECTADO ✓" or "FALLO"
            HUB.status = ok and "conexion ok" or ("error: " .. tostring(err))
            task.delay(2, function() testBtn.Text = "PROBAR CONEXION" end)
        end)
    end)

    local forgetBtn = new("TextButton", {
        Position = UDim2.new(0,148,0,172), Size = UDim2.new(0,150,0,28),
        BackgroundColor3 = C.card2, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
        TextSize = 10.5, TextColor3 = C.txt2, Text = "OLVIDAR VISITADOS", AutoButtonColor = false,
    }, pHub)
    corner(forgetBtn, 7); stroke(forgetBtn, C.line, 0.4)
    forgetBtn.MouseButton1Click:Connect(function()
        HOP.visited = {}; saveVisited(); HOP.status = "lista de visitados vacia"
    end)

    hubStatusLbl = new("TextLabel", {
        Position = UDim2.new(0,2,1,-40), Size = UDim2.new(1,-4,0,38),
        BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        TextColor3 = C.mut, TextWrapped = true, Text = "",
    }, pHub)

    --------------------------------------------------------------- WEBHOOK
    fieldOn(pHook, "URL DEL WEBHOOK DE DISCORD", 0, "https://discord.com/api/webhooks/...",
        WH.url, function(v) WH.url = v end)

    local _, paintWh = toggleOn(pHook, 50, function() return WH.enabled end,
        function(v) WH.enabled = v end, "avisar por webhook")

    new("TextLabel", {
        Position = UDim2.new(0,2,0,86), Size = UDim2.new(1,-4,0,12),
        BackgroundTransparency = 1, Font = Enum.Font.GothamBold, TextSize = 9,
        TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = C.mut,
        Text = "RAREZAS A NOTIFICAR",
    }, pHook)

    local chips = new("ScrollingFrame", {
        Position = UDim2.new(0,0,0,102), Size = UDim2.new(1,0,1,-142),
        BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(0,0,0,0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, pHook)
    do
        local lay = new("UIListLayout", {
            FillDirection = Enum.FillDirection.Horizontal,
            Padding = UDim.new(0,5), SortOrder = Enum.SortOrder.LayoutOrder,
        }, chips)
        pcall(function() lay.Wraps = true end)
    end

    for i = #rarityList, 1, -1 do
        local r = rarityList[i]
        local chip = new("TextButton", {
            LayoutOrder = #rarityList - i,
            Size = UDim2.new(0, 22 + #r.name * 6.4, 0, 24),
            BackgroundColor3 = C.card, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
            TextSize = 10, Text = r.name, TextColor3 = r.color, AutoButtonColor = false,
        }, chips)
        round(chip)
        local st = stroke(chip, r.color, 0.6)
        local function paint()
            local on = WH.rarities[r.name]
            chip.BackgroundColor3 = on and r.color or C.card
            chip.TextColor3 = on and C.ink or r.color
            st.Transparency = on and 1 or 0.6
        end
        paint()
        chip.MouseButton1Click:Connect(function()
            WH.rarities[r.name] = (not WH.rarities[r.name]) or nil
            paint(); saveConfig()
        end)
    end

    whStatusLbl = new("TextLabel", {
        Position = UDim2.new(0,2,1,-34), Size = UDim2.new(1,-4,0,32),
        BackgroundTransparency = 1, Font = Enum.Font.Code, TextSize = 10,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        TextColor3 = C.mut, TextWrapped = true, Text = "",
    }, pHook)

    ----------------------------------------------------------- DIAGNOSTICO
    local diagScroll = new("ScrollingFrame", {
        Position = UDim2.new(0,0,0,0), Size = UDim2.new(1,0,1,-36),
        BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 3,
        ScrollBarImageColor3 = C.line, CanvasSize = UDim2.new(0,0,0,0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
    }, pDiag)
    diagBody = new("TextLabel", {
        Size = UDim2.new(1,-8,0,0), Position = UDim2.new(0,4,0,2),
        AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1,
        Font = Enum.Font.Code, TextSize = 10.5, TextColor3 = C.txt2,
        TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
        TextWrapped = true, RichText = true, Text = "",
    }, diagScroll)

    local copyBtn = new("TextButton", {
        Position = UDim2.new(0,0,1,-30), Size = UDim2.new(0,180,0,28),
        BackgroundColor3 = C.acc, BorderSizePixel = 0, Font = Enum.Font.GothamBold,
        TextSize = 10.5, TextColor3 = Color3.new(1,1,1),
        Text = "COPIAR DIAGNOSTICO", AutoButtonColor = false,
    }, pDiag)
    corner(copyBtn, 7)
    copyBtn.MouseButton1Click:Connect(function()
        local set = setclipboard or toclipboard or (syn and syn.write_clipboard)
        local plain = diagText:gsub("<[^>]->", "")
        if set and pcall(set, plain) then
            copyBtn.Text = "COPIADO ✓"
        else
            print("[SAE DIAG]\n" .. plain)
            copyBtn.Text = "EN LA CONSOLA (F9)"
        end
        task.delay(2, function() copyBtn.Text = "COPIAR DIAGNOSTICO" end)
    end)

    selectTab("result")
end

----------------------------------------------------------------------
-- PINTADO
----------------------------------------------------------------------
local PHASE_COLOR = {
    espera       = C.warn,
    escaneando   = C.acc2,
    enviando     = C.acc,
    listo        = C.ok,
    error        = C.bad,
}
local PHASE_TEXT = {
    espera       = "esperando al server",
    escaneando   = "escaneando",
    enviando     = "enviando al hub",
    listo        = "reporte enviado",
    error        = "no se pudo enviar",
}

local acc = 0
RunService.RenderStepped:Connect(function(dt)
    acc = acc + dt
    if acc < 0.25 then return end
    acc = 0

    phaseDot.BackgroundColor3 = PHASE_COLOR[SCAN.phase] or C.mut
    phaseLbl.Text = PHASE_TEXT[SCAN.phase] or SCAN.phase
    phaseLbl.TextColor3 = (SCAN.phase == "error") and C.bad or C.txt
    detailLbl.Text = SCAN.detail
    rescanLbl.Text = scanning and "ESCANEANDO…" or "RE-ESCANEAR"

    pcall(refreshLabels)

    local char = LocalPlayer.Character
    local hrp  = char and char:FindFirstChild("HumanoidRootPart")

    local rows = {}
    for i, e in ipairs(liveList) do
        local dist = (hrp and e.anchor) and (e.anchor.Position - hrp.Position).Magnitude or 0
        local bb = labels[e.model]
        if bb and bb.Parent then
            bb.Enabled = showLabels
            local t = bb:FindFirstChild("T")
            if t then
                t.Text = string.format(
                    '<font color="#%s"><b>%s</b></font>\n%s · <b>%s kg</b> · %dm · %s',
                    e.color:ToHex(), e.name, e.rarity, comma(e.kg), math.floor(dist),
                    (e.area ~= "" and e.area:upper() or "ZONA"))
            end
        end
        if i <= 60 then
            rows[#rows+1] = string.format(
                '<font color="#%s">%-22s</font>%9s kg  %-10s %s',
                e.color:ToHex(), tostring(e.name):sub(1,22), comma(e.kg),
                tostring(e.rarity):sub(1,10), tostring(e.area):sub(1,12))
        end
    end

    if #rows > 0 then
        listBody.Text = table.concat(rows, "\n")
    elseif SCAN.phase == "listo" then
        listBody.Text = '<font color="#6c748a">este server no tenia huevos de zona resolubles</font>'
    else
        listBody.Text = '<font color="#6c748a">' .. table.concat(DIAG, "\n") .. '</font>'
    end

    -- ── diagnostico ────────────────────────────────────────────────────────
    if diagBody then
        local D = SCAN.diag or {}
        local nAssets = 0; for _ in pairs(assetIndex) do nAssets = nAssets + 1 end
        local L = {}
        local function add(s) L[#L+1] = s end

        add("MODULOS DEL JUEGO")
        add(("  EggState   %s"):format(EggState   and "OK" or "NO CARGA  <-- sin esto no hay records"))
        add(("  EggRecords %s"):format(EggRecords and "OK" or "NO CARGA"))
        add(("  Data.Assets %s"):format(Assets    and "OK" or "NO CARGA  <-- sin esto no hay rarezas"))
        add(("  assets indexados: %d   rarezas: %d   zonas: %d"):format(nAssets, #rarityList, #AREAS))
        add("")
        add("ULTIMO ESCANEO")
        add(("  modelos de zona:   %d"):format(D.zone or 0))
        add(("  modelos de base:   %d  (nunca se envian)"):format(SCAN.base or 0))
        add(("  records leidos:    %d"):format(D.records or 0))
        add(("  resueltos:         %d"):format(SCAN.found or 0))
        add(("  descartados:       %d"):format(SCAN.skipped or 0))

        if D.why and next(D.why) then
            add("")
            add("POR QUE SE DESCARTARON")
            local ks = {}
            for k in pairs(D.why) do ks[#ks+1] = k end
            table.sort(ks)
            for _, k in ipairs(ks) do add(("  %-28s %d"):format(k, D.why[k])) end
        end

        if D.sampleKeys then
            add("")
            add("CAMPOS DE UN RECORD REAL")
            add("  " .. D.sampleKeys)
            add("  DisplayName -> " .. tostring(D.sampleName))
        elseif (D.zone or 0) > 0 then
            add("")
            add("  NINGUN record encontrado para los huevos de zona.")
            add("  Es lo que hay que mirar: sin record no se puede saber la rareza.")
        end

        if D.misses and #D.misses > 0 then
            add("")
            add("EJEMPLOS QUE FALLARON")
            for _, m in ipairs(D.misses) do add("  " .. m) end
        end

        if #DIAG > 0 then
            add("")
            add("ARRANQUE")
            for _, d in ipairs(DIAG) do add("  " .. d) end
        end

        diagText = table.concat(L, "\n")
        diagBody.Text = diagText
    end

    local nvis = 0; for _ in pairs(HOP.visited) do nvis = nvis + 1 end
    hubStatusLbl.Text = string.format(
        "hub: %s\nsubidos:%d  ultima:%dms  ·  saltos:%d  visitados:%d\n%s",
        HUB.status, HUB.count, HUB.lastMs, HOP.hops, nvis, HOP.status)

    whStatusLbl.Text = string.format("cola:%d  enviados:%d  ·  %s", #WH.queue, WH.count, WH.status)
end)

UserInputService.InputBegan:Connect(function(i, gp)
    if gp then return end
    if i.KeyCode == CFG.TOGGLE_LABELS then
        showLabels = not showLabels
    elseif i.KeyCode == CFG.TOGGLE_PANEL then
        panel.Visible = not panel.Visible
    end
end)

-- Arranca solo: entras al server, escanea, manda una vez, y si el auto hop
-- esta encendido salta al siguiente.
runScan(false)
