# 🥚 EAG HUB

Relé entre el **ESP** (que escanea servers de Roblox) y el **AJ** (que salta al
server donde acaba de aparecer un huevo bueno), con un dashboard web en vivo.

Node.js sin dependencias, listo para Railway.

```
ESP v8  ──POST /api/report──▶  HUB  ──POST /api/claim──▶  AJ v3
(escanea zonas)                 │                        (salta al server)
                                └──▶ Dashboard (SSE en vivo)
```

## Estructura

| Archivo | Qué hace |
|---|---|
| `server.js` | Servidor HTTP: API + estáticos + SSE |
| `lib/store.js` | Estado en memoria: servers, huevos, claims, log de actividad |
| `lib/rarity.js` | La escalera de rarezas real del juego (Common → Titan) |
| `public/index.html` · `app.js` · `styles.css` | Dashboard |
| `scripts/ESP_v8.lua` | ESP: escanea y reporta **solo huevos de zona** |
| `scripts/AJ_v3.lua` | Auto joiner: solo salta a hallazgos **nuevos** |
| `Dockerfile` · `railway.json` | Despliegue |

## Deploy en Railway

1. **New Project → Deploy from GitHub repo** → este repo.
2. Root Directory: vacío (`/`).
3. Variable `API_KEY` = una clave larga y aleatoria.
4. Settings → Networking → **Generate Domain**. Esa URL es tu `HUB_URL`.

Variables opcionales: `PUBLIC_READ` (true = dashboard sin key),
`SERVER_TTL_SEC` (480), `CLAIM_TTL_SEC` (240).

En local:

```bash
API_KEY=test node server.js   # http://localhost:3000
```

## Configurar los scripts

En el **ESP** (tab HUB) y en el **AJ** (tab engranaje), pon la misma
`HUB_URL` y la misma `API_KEY`.

---

## Qué cambió en esta versión

### La escalera de rarezas ahora es la del juego

Antes el hub solo conocía `Common…Divine`. Rarezas reales del juego como
**Cosmic, Eternal, Exotic, Titan, Squishy God, Rainbow** no existían en la
lista, así que:

- no se podían marcar como filtro, y
- al ordenar el feed se les daba el rango *más bajo*, es decir, un Titan de
  52.000 kg aparecía por debajo de un Common.

`lib/rarity.js` ahora replica la tabla `RarityNumber` del juego (1 → 11), con
sus colores. El dashboard, el ESP y el AJ leen la escalera del hub, así que los
tres coinciden siempre.

### El ESP solo manda huevos de zona

Regla dura, no un toggle: si un huevo no sale de `AreaEggSlotsClient`, no llega
ni al webhook ni al hub. Una sola función (`sendable`) decide, y las dos vías de
envío pasan por ella.

Además cada huevo viaja con su **zona real** (Forest, Volcano, Snow, Abyss
Ocean, Titan Temple…), resuelta contra `Workspace.__OBJECTS.Areas.GuardAreas`,
y con `odds`, `growthSec`, `earnRate` y `rarityNum`.

El toggle que queda (`pintar también los de base`) es solo visual: cambia lo que
ves en pantalla, nunca lo que se envía.

### El AJ ya no salta a hallazgos viejos

Cada huevo recibe un número de secuencia (`seq`) al descubrirse. Al encender el
auto join, el AJ apunta el `eggSeq` actual del hub como **cursor** y a partir de
ahí solo acepta huevos con `seq` mayor. Nada de aterrizar en un server donde el
huevo lleva seis minutos y ya se lo llevaron.

Se apoya en dos cortes más:

- `maxAgeSec` — descarta cualquier huevo de más de N segundos (90 por defecto).
- el cursor avanza solo tras cada salto, así que un objetivo no se repite.

### Snapshots que sí limpian

El ESP mandaba `full: true` para decir "esto es todo lo que hay aquí", pero el
hub lo ignoraba y los huevos ya recogidos se quedaban pegados en el feed para
siempre. Ahora un report con `full` borra lo que no venga en la lista.

### Dashboard nuevo

Tres pestañas, todo con **edades que corren en vivo** (`hace 12s`, `hace 4m 03s`),
calculadas contra el reloj del hub y no el del navegador:

- **Huevos** — feed ordenado por rareza real y peso, con zona, ganancia,
  eclosión, server, jugadores y quién lo reportó.
- **Servers** — una tarjeta por server: mejor huevo, mezcla de rarezas, ocupación,
  hace cuánto fue el último reporte y cuánto lleva vivo.
- **Actividad** — la línea de tiempo del hub: cada hallazgo, cada server que
  entra o cae, cada claim, cada salto, con su hora.

---

## API

| Método | Ruta | Quién | Qué hace |
|---|---|---|---|
| POST | `/api/report` | ESP | Sube huevos. `full:true` = snapshot completo |
| GET | `/api/feed` | Dashboard / AJ | Lista filtrada (long-poll con `wait=20`) |
| POST | `/api/claim` | AJ | Pide un objetivo y bloquea su server |
| POST | `/api/release` | AJ | Libera un claim |
| POST | `/api/hop` | AJ | Reporta si el teleport salió bien |
| GET | `/api/meta` | Todos | Stats, escalera de rarezas, cursor `eggSeq` |
| GET | `/api/servers` | Dashboard | Servers con detalle |
| GET | `/api/events` | Dashboard | Log de actividad con timestamps |
| GET | `/api/stream` | Dashboard | SSE en vivo |
| POST | `/api/purge` | Admin | Borra todo |
| GET | `/healthz` | Railway | Health check |

### Filtros de `/api/feed` y `/api/claim`

Por query string (GET) o en el cuerpo JSON (POST):

| Filtro | Ejemplo | Qué hace |
|---|---|---|
| `rarities` | `Cosmic,Titan` | Solo estas rarezas |
| `minKg` / `maxKg` | `25` / `9000` | Rango de peso |
| `minRank` | `7` | Rareza mínima por rango (7 = Cosmic) |
| `sinceSeq` | `1420` | **Solo huevos descubiertos después** |
| `maxAgeSec` | `90` | Descarta hallazgos más viejos |
| `hasSlot` | `1` | Solo servers con hueco libre |
| `maxPlayers` | `4` | Servers con como mucho N jugadores |
| `exclude` | `job1,job2` | Ignora estos servers |
| `wait` | `20` | Long-poll: espera hasta N s a que aparezca algo |

Autenticación: cabecera `x-eag-key`, `x-api-key`, `Authorization: Bearer …` o
`?key=`. Escribir siempre exige key; leer también, salvo `PUBLIC_READ=true`.

## Notas

Todo vive en memoria: si Railway reinicia el contenedor, el feed se vacía y se
repuebla en segundos con el siguiente report del ESP.
