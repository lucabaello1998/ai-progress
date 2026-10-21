# ai-progress

Widget flotante para **Windows y Linux** que muestra, siempre visible arriba a la derecha:

1. **Tareas de agentes de IA** — barras de progreso reales, leyendo un `status.json` que
   mantienen los agentes (Claude Code, OpenCode o cualquier script propio).
2. **Uso de Claude** — ventana de 5 h y límite semanal de 7 días, leído del cache de la CLI
   (`~/.claude.json`), con indicador de qué tan viejo es el dato.
3. **Uso de Codex** — sesiones y tokens del día desde los logs locales
   (`~/.codex/sessions/**/rollout-*.jsonl`); si el log trae límites, también muestra las barras
   de 5 h / semanal.
4. **Uso de OpenCode** — sesiones, prompts, pasos, tokens y costo del día, vía
   `opencode stats --days 0 --json` (refresco cada 60 s).
5. **Otros modelos** — proveedores propios definidos en `config.json` (un comando CLI o un
   archivo JSON con métricas).

El **menú hamburguesa** (arriba a la derecha) abre un **popup flotante** — con fondo y borde
propios, no empuja el contenido — con *switchs* para prender/apagar cada sección, el switch **Modo claro**
(tema claro/oscuro) y el switch **Español/English** (idioma de la interfaz); todo se guarda en `config.json`.
El botón **?** muestra la explicación de cómo funciona dentro del propio widget, y al pie del popup
está la leyenda del autor.

![screenshot](docs/screenshot.png)

Popup del menú (switchs por sección + leyenda):

![menú abierto](docs/screenshot-menu.png)

Con la ayuda abierta (botón **?**):

![screenshot con la ayuda abierta](docs/screenshot-ayuda.png)

Modo claro (switch **Modo claro** del menú):

![modo claro](docs/screenshot-claro.png)

En inglés (switch **Español/English** del menú):

![interfaz en inglés](docs/screenshot-en.png)

Versión Linux (Python + GTK3), mismo widget y mismos datos:

![versión Linux](docs/screenshot-linux.png)

## Historia

`ai-progress` es la evolución de un proyecto personal anterior: **`claude-progress`**, un widget
mínimo que armé para mirar el uso de Claude Code (ventana de 5 h y límite semanal) y el progreso
de sus tareas de background, mientras corría workflows largos de agentes. Nunca fue un repo: vivió
siempre en una carpeta local, como herramienta de trabajo.

Cuando el día a día se repartió entre más herramientas — Codex, OpenCode, Claude, workflows
multiagente — ese widget se quedó corto: miraba solo a Claude Code y no sabía nada de las otras
herramientas. `ai-progress` es la generalización: un monitor flotante para todas las herramientas
de IA, con progreso real de tareas, uso por proveedor, menú de secciones y tema claro/oscuro.

La idea de fondo no cambió: pegarle un vistazo y saber qué está pasando, sin abrir una terminal ni
cambiar de ventana.

## Requisitos

- Windows + **PowerShell 7** (`pwsh`) — usa `ConvertFrom-Json -AsHashtable` — o Linux + **Python 3**
  + **GTK3** (`python3-gi`, `gir1.2-gtk-3.0`).
- Opcional: CLI de OpenCode (`opencode` en el PATH, `%USERPROFILE%\bin\opencode.exe`, o el que
  trae OpenCode Desktop) para la sección de OpenCode. La de Codex funciona con solo tener sus
  logs locales.

## Instalación (Windows)

- **Portable**: doble clic en `ai-progress.exe` (no abre consola). Es un lanzador chico: no hay
  que compilar nada.
- **Sin dependencias**: `dist\ai-progress.exe` (~84 MB) trae el runtime de .NET y el motor de
  PowerShell adentro: no hace falta tener PowerShell 7 instalado. Se compila con
  `tools\standalone\build-standalone.ps1` y el paquete para compartir queda en
  `dist\ai-progress-portable.zip`. Sus datos viven en `%LOCALAPPDATA%\ai-progress\runtime`.
- **Instalador**: doble clic en `install.cmd` → copia todo a `%LOCALAPPDATA%\ai-progress`, crea el
  acceso directo del menú Inicio y te pregunta si querés arranque con Windows. Para desinstalar,
  `uninstall.ps1` (conserva `config.json` y `status.json`; con `-Todo` borra todo).

En los dos casos hace falta **PowerShell 7**: `winget install Microsoft.PowerShell`.

El widget es de **instancia única** (abrirlo dos veces no duplica nada), tiene ícono en la
**bandeja** (doble clic muestra/oculta; clic derecho → Mostrar/Ocultar o Salir) y el switch
**Iniciar con Windows** del menú prende/apaga el arranque automático.

## Uso

- **Windows**: `ai-progress.exe` (o `launch.vbs`, que hace lo mismo con `wscript`).
- **Windows** desde consola: `pwsh -NoProfile -ExecutionPolicy Bypass -File .\ai-progress.ps1`.
- **Linux**: `python3 ai-progress-gtk.py` (ver [Linux (GTK3)](#linux-gtk3)).

Es un monitor: cerrar la ventana no cancela ninguna tarea.

## Tareas: `status.json`

El widget lee uno o varios `status.json` (por default el que está al lado del script). Formas de
progreso soportadas por tarea:

| Forma | Campos | Resultado |
|---|---|---|
| Workflow de Claude | `journalPath` + `expectedAgents` | Progreso **real** por agente (lee el `journal.jsonl`) + ETA con la duración de los agentes ya terminados |
| Contador | `total` + `done` | Barra `done/total` + tiempo transcurrido |
| Porcentaje | `progress` (0 a 1) | Barra al porcentaje |
| Sin datos de avance | (ninguno) | Barra indeterminada + tiempo transcurrido |

Campos comunes: `id`, `name`, `startedAt` (ISO), `status` (`running` \| `done` \| `error`),
`detail` (línea extra opcional).

Ejemplo completo en [`status.example.json`](status.example.json). Los agentes lo actualizan al
lanzar tareas largas; por ejemplo:

```json
{
  "tasks": [
    {
      "id": "t1",
      "name": "Build de producción",
      "total": 3,
      "done": 1,
      "startedAt": "2026-10-19T10:00:00Z",
      "status": "running",
      "detail": "vite build — paso 2 de 3"
    }
  ]
}
```

## Idiomas

La interfaz está en **español e inglés**. Se elige con `language` en `config.json`:

- `"auto"` (default): español si el idioma de la interfaz del sistema es español; inglés en
  cualquier otro caso.
- `"es"` / `"en"`: fija el idioma.

El switch **Español/English** del menú lo cambia en caliente y lo guarda (`es`/`en`). Para volver a `auto`,
editá `config.json`. En la versión Linux también se puede forzar con `--lang en` sin tocar el archivo.

## Configuración (`config.json`)

Copiá [`config.example.json`](config.example.json) a `config.json` y editá lo que necesites.
Todo es opcional (el widget arranca con defaults sensatos). El archivo está gitignored, y el
propio widget lo reescribe cuando usás el menú hamburguesa o el botón **?**.

```json
{
  "statusPaths": ["status.json"],
  "sections": { "tasks": true, "claude": true, "codex": true, "opencode": true },
  "showHelp": false,
  "theme": "dark",
  "language": "auto",
  "autostart": false,
  "notifications": true,
  "opencodeCliPath": null,
  "opencodeRefreshSeconds": 60,
  "codexRefreshSeconds": 60,
  "customProviders": []
}
```

### Proveedores propios (`customProviders`)

Cada proveedor agrega una sección, y una fila en el menú para prenderla/apagarla si le ponés
`name` (sin `name` igual aparece la sección, con el `id`). Formas de obtener los datos:

- `command` (+ `args` opcional): se ejecuta y tiene que imprimir **JSON por stdout**.
- `file`: ruta a un JSON local (se relee cada `refreshSeconds`).
- `refreshSeconds` (opcional): cada cuánto se ejecuta/relee; default 60 s.

JSON esperado — todos los campos son opcionales:

```json
{
  "sessions": 3,
  "prompts": 42,
  "steps": 210,
  "tokens": { "input": 320000, "output": 18000, "cache": { "read": 1500000, "write": 0 } },
  "cost": 0.42
}
```

Ejemplo de configuración (para cualquier CLI que exponga stats en JSON):

```json
{
  "customProviders": [
    { "id": "gemini", "name": "Gemini", "command": "gemini", "args": ["stats", "--json"] }
  ]
}
```

## Linux (GTK3)

[`ai-progress-gtk.py`](ai-progress-gtk.py) es la versión Linux del widget: mismo `config.json`,
mismo `status.json`, mismas secciones, temas e idiomas; usa Python 3 + GTK3 (PyGObject).

```bash
sudo apt install python3-gi python3-cairo python3-gi-cairo gir1.2-gtk-3.0
python3 ai-progress-gtk.py
```

- Si hay Wayland con XWayland, arranca en X11 para poder posicionarse arriba a la derecha y quedar
  siempre arriba (en Wayland puro el compositor manda).
- `--dump` imprime el modelo completo (datos + textos ya formateados) como JSON, sin abrir ventana:
  sirve para probar la lógica en un server o en CI.
- `--screenshot salida.png` se autofotografía y cierra (documentación; necesita X11: en Wayland no
  se puede leer el contenido de la ventana).
- `--lang es|en` y `--theme dark|light` fuerzan idioma y tema para esa ejecución.

Instalación con entrada de menú y arranque al iniciar sesión:

```bash
./install.sh              # copia a ~/.local/share/ai-progress + entrada de menú
./install.sh --autostart  # además arranca al iniciar sesión
~/.local/share/ai-progress/uninstall.sh         # desinstala (conserva config/status)
~/.local/share/ai-progress/uninstall.sh --todo  # borra todo
```

## Avisos

El widget avisa con un cartel propio abajo a la derecha (Windows) o con una notificación de
escritorio (Linux, vía `notify-send`) cuando:

- una tarea pasa a **Listo**, y
- el uso de Claude llega al **80%** (una sola vez por ventana de reset).

En Windows no usa las notificaciones del sistema (muchas veces están apagadas o van al centro de
notificaciones): es una ventanita del propio widget, arriba de todo, que se cierra sola a los 6 s
o con un clic. Se apagan con `"notifications": false` en `config.json`.

## Desarrollo

- `tools/build-icon.py` genera `assets/ai-progress.ico` y `.png` (requiere Pillow).
- `tools/build-exe.ps1` compila `ai-progress.exe` con el `csc` que ya trae Windows.
- `tools/standalone/build-standalone.ps1` compila el `.exe` autocontenido (requiere el SDK de .NET
  8+ y NuGet la primera vez; salida en `dist/`, que no se versiona).

## Notas

- Las dos versiones (Windows/PowerShell y Linux/GTK) comparten `config.json` y `status.json`: podés
  usar la misma carpeta en ambos sistemas.
- Solo lee archivos locales; no manda nada a ninguna API. Los únicos procesos que ejecuta son
  los CLIs configurados (OpenCode y los `customProviders`).
- El ETA de workflows es **estimado**: usa la duración real de los agentes ya terminados, no el
  tiempo total transcurrido (una pausa larga no lo infla).
- El % de Claude es un cache de la CLI: puede quedar atrás de lo que muestra el chat (se indica la
  edad del dato). Codex se recalcula cada 60 s desde los logs; si no hubo sesiones hoy, lo dice.
- Viene del widget personal para Claude Code `claude-progress`, generalizado a IA en general
  (ver **Historia**).
- Licencia MIT. Ver [LICENSE](LICENSE).
