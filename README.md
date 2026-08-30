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
| `scripts/ESP_v9.lua` | Reporter: **un escaneo, un reporte**, solo huevos de zona |
| `scripts/AJ_v4.lua` | Auto joiner: solo hallazgos **nuevos**, y te dice por qué si no salta |
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

## El reporter no mandaba nada habiendo legendarios

Me pasé de estricto. Al endurecer la resolución de rarezas rompí la resolución
entera. Tres causas, la primera es la gorda:

**1. Colisiones falsas.** `ReadFieldEggs()` y `ReadOwnerEggs()` devuelven el
mismo huevo en **dos tablas distintas**. Yo comparaba por identidad de tabla,
así que lo tomaba por dos records en conflicto y anulaba la clave. Resultado:
ningún huevo se resolvía. Reproducido:

```
Un Legendary presente en las dos lecturas del juego:
  v9 inicial   -> clave anulada  =>  no se resuelve  =>  no se envia
  v9 corregido -> Salamander (Legendary)
```

Ahora la colisión se juzga por si los dos records **discrepan en el asset**, no
por si son la misma tabla. Una colisión de verdad (`Slot_002` compartido por dos
huevos distintos) se sigue detectando.

**2. Quité campos que sí valían.** Saqué `Name` e `Id` de la lista de campos de
asset sin comprobar que el juego no los usara. Los dumps que me pasaste nunca
capturaron un record de huevo real —solo nombres de funciones—, así que endurecí
contra nombres de campo que no había verificado. Están de vuelta.

**3. Sin red de seguridad.** La búsqueda vuelve a ser amplia (mira todos los
campos de texto), pero **determinista**: si varios apuntan al mismo asset, vale;
si se contradicen, no se resuelve. El fallo original del v8 no era mirar campos
de más, era que `pairs()` decidía el ganador.

### Y dos cosas para que esto no se repita a ciegas

- **No borra el hub.** Si hay huevos de zona delante y no se resuelve ninguno,
  ya no manda un `full=true` vacío —eso le decía al hub «aquí no hay nada» y
  borraba lo bueno de un reporte anterior—. No manda, y lo grita en el panel.
- **Pestaña DIAGNOSTICO** con botón de copiar: estado de los tres módulos del
  juego, cuántos modelos de zona hay, cuántos records se leyeron, por qué se
  descartó cada huevo, y **los nombres de campo de un record real**. Eso último
  es lo que faltaba para no seguir adivinando.

---

## v9 / v4 — por qué el AJ no saltaba

Tres fallos distintos, los tres reproducidos con test antes de tocar nada.

### 1. Un filtro imposible que no avisaba

Si la lista de rarezas del AJ iba vacía, Lua la mandaba como `{}` y el hub la
convertía en el texto `"[object Object]"`: un filtro que **no coincide con nada,
nunca**. El AJ se quedaba mudo y parecía que el hub no recibía.

Ahora un valor que no es una lista usable significa *sin filtro*, y el AJ nunca
manda una lista vacía.

### 2. El ESP se equivocaba de rarezas

Tres causas, todas en cómo se ataba cada huevo a su record:

| | Qué pasaba | Ahora |
|---|---|---|
| `pairs(rec)` | Recorría el record y se quedaba con el primer texto que sonara a asset. Sin orden garantizado → el mismo huevo podía resolverse como dos assets distintos | Solo campos de asset explícitos, en orden fijo |
| Claves compartidas | Los records se indexaban también por `Slot`, `Key`, `ModelName`. `Slot_002` se repite en todos los servers, así que **un huevo cogía el record de otro** — un Legendary reportado como Common | Solo identificadores únicos (`Uid`, `Id`), y una clave que dos records reclaman se marca inservible |
| Adivinar por color | Sin record, deducía la rareza del color del modelo | Lo que no se resuelve con certeza **no se envía** |

### 3. El goteo continuo se corregía a sí mismo

El v8 reescaneaba cada segundo y subía correcciones sobre la marcha. El v9
escanea, espera a que el resultado se repita 3 veces seguidas, y **entonces**
manda una vez todo el server con `full=true`. Un server, un reporte.

Si el server tarda en cargar, espera (hasta 22 s). Si está vacío de verdad,
espera un mínimo de 3 s antes de darlo por bueno. Si nunca se estabiliza, corta
por tiempo y manda igual.

### Y si aun así no salta, ahora te lo dice

`POST /api/diag` recorre el mismo embudo que `/api/claim` y cuenta cuántos
huevos caen en cada regla. El AJ lo traduce a una frase y, cuando puede, a un
botón que lo arregla:

| Situación | Lo que ves |
|---|---|
| Nadie reportando | «ningún ESP está reportando» |
| Servers sin huevos | «los servers están vacíos (3 reportando)» |
| Filtro de rareza mal | «tus rarezas no existen en el juego» → **MARCAR LAS RARAS** |
| Todo anterior al cursor | «6 anterior al cursor» → **ACEPTAR LOS DE AHORA** |
| Rareza no marcada | «4 rareza no marcada» → **IR A FILTROS** |

`/api/diag` y `/api/claim` comparten los mismos jueces (`serverReject` /
`eggReject`) a propósito: si divergieran, el diagnóstico mentiría justo cuando
más falta hace.

### Otras cosas del v4

- Interfaz rehecha: pestañas de verdad en vez del carril de iconos dibujados a
  mano con frames rotados.
- Config propia (`eag_aj_v4.json`). El v3 reusaba el fichero del v2, así que se
  heredaban filtros viejos —como `MIN_KG=25`— que tumbaban todo en silencio.

---

## Qué cambió antes (v8 / v3)

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
| POST | `/api/diag` | AJ | Por qué un filtro no devuelve nada |
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
