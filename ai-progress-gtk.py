#!/usr/bin/env python3
# ai-progress (Linux) — Widget flotante de progreso para agentes de IA.
#
# Version Linux/GTK3 del widget ai-progress.ps1 (Windows/WPF): misma config.json, mismo
# status.json, mismas fuentes de datos y los mismos textos en español/ingles.
#
# Que muestra (siempre visible, arriba a la derecha):
#   1) TAREAS: status.json (por defecto el de esta carpeta). Soporta journalPath +
#      expectedAgents (progreso real por agente + ETA), total/done y progress (0 a 1).
#   2) Uso de CLAUDE: cache de la CLI en ~/.claude.json (cachedUsageUtilization).
#   3) Uso de CODEX: sesiones de hoy en ~/.codex/sessions/**/rollout-*.jsonl.
#   4) Uso de OPENCODE: corre `opencode stats --days 0 --json` (con timeout).
#   5) Proveedores propios (config.json -> customProviders): command o file JSON.
#
# Requisitos (Ubuntu/Debian): sudo apt install python3-gi python3-cairo gir1.2-gtk-3.0
# Uso: python3 ai-progress-gtk.py             (widget)
#      python3 ai-progress-gtk.py --dump      (sin GUI: imprime el modelo como JSON)
#      python3 ai-progress-gtk.py --screenshot out.png   (se autofotografia y cierra)
#
# Nota Wayland: si hay XWayland disponible se fuerza GDK_BACKEND=x11 para poder posicionar
# la ventana arriba a la derecha y mantenerla arriba. En X11 puro no hace falta nada.
import argparse
import collections
import datetime
import json
import os
import re
import shutil
import subprocess
import sys

DIR_SCRIPT = os.path.dirname(os.path.abspath(__file__))
RUTA_CONFIG_DEFECTO = os.path.join(DIR_SCRIPT, 'config.json')
RUTA_CLAUDE = os.path.join(os.path.expanduser('~'), '.claude.json')
DIR_CODEX = os.path.join(os.path.expanduser('~'), '.codex', 'sessions')

# ---------- Textos (es | en) ----------
TXT = {
    'titulo': {'es': 'Progreso IA', 'en': 'AI progress'},
    'sec_tasks': {'es': 'Tareas', 'en': 'Tasks'},
    'sec_claude': {'es': 'Claude', 'en': 'Claude'},
    'sec_codex': {'es': 'Codex', 'en': 'Codex'},
    'sec_opencode': {'es': 'OpenCode', 'en': 'OpenCode'},
    'activas': {'es': '{0} activas', 'en': '{0} active'},
    'activa1': {'es': '1 activa', 'en': '1 active'},
    'sin_tareas': {'es': 'Sin tareas en curso.', 'en': 'No tasks running.'},
    'listo': {'es': 'Listo', 'en': 'Done'},
    'error': {'es': 'Error', 'en': 'Error'},
    'agentes': {'es': '{0}/{1} agentes', 'en': '{0}/{1} agents'},
    'terminando': {'es': 'terminando...', 'en': 'finishing...'},
    'restantes': {'es': '~{0} restantes (estimado)', 'en': '~{0} left (estimated)'},
    'estimando': {'es': 'estimando tiempo...', 'en': 'estimating time...'},
    'contador_hace': {'es': '{0}/{1} - hace {2}', 'en': '{0}/{1} - {2} ago'},
    'pct_hace': {'es': '{0}% - hace {1}', 'en': '{0}% - {1} ago'},
    'progreso_hace': {'es': 'En progreso - hace {0}', 'en': 'In progress - {0} ago'},
    'dur_menos_1': {'es': 'menos de 1 min', 'en': 'less than 1 min'},
    'reset_hoy': {'es': 'reinicia hoy a las {0}', 'en': 'resets today at {0}'},
    'reset_dia': {'es': 'reinicia el {0} a las {1}', 'en': 'resets {0} at {1}'},
    'sin_datos': {'es': 'sin datos', 'en': 'no data'},
    'edad_desconocida': {'es': 'edad del dato desconocida', 'en': 'data age unknown'},
    'dato_hace_s': {'es': 'dato de hace {0}s', 'en': 'data from {0}s ago'},
    'dato_hace': {'es': 'dato de hace {0}', 'en': 'data from {0} ago'},
    'puede_atras': {'es': 'dato de hace {0} (puede ir atras)', 'en': 'data from {0} ago (may be behind)'},
    'uso_claude': {'es': 'Uso - Claude', 'en': 'Usage - Claude'},
    'sin_uso': {'es': 'Sin datos de uso todavia.', 'en': 'No usage data yet.'},
    'claude_nota': {'es': 'Cache de la CLI, no se refresca sola - corre /usage en Claude de vez en cuando.',
                    'en': 'CLI cache, it does not refresh on its own - run /usage in Claude now and then.'},
    'sesion_5h': {'es': 'Sesion (5 hs)', 'en': 'Session (5 h)'},
    'semanal_7d': {'es': 'Semanal (7 dias)', 'en': 'Weekly (7 days)'},
    'actualizado_s': {'es': 'actualizado hace {0}s', 'en': 'updated {0}s ago'},
    'actualizado': {'es': 'actualizado hace {0}', 'en': 'updated {0} ago'},
    'uso_codex': {'es': 'Uso - Codex (hoy)', 'en': 'Usage - Codex (today)'},
    'codex_sin_carpeta': {'es': 'No encontre sesiones de Codex (~/.codex/sessions).',
                          'en': 'No Codex sessions found (~/.codex/sessions).'},
    'codex_sin_hoy': {'es': 'Sin sesiones de Codex hoy.', 'en': 'No Codex sessions today.'},
    'n_sesion1': {'es': '1 sesion', 'en': '1 session'},
    'n_sesiones': {'es': '{0} sesiones', 'en': '{0} sessions'},
    'n_prompt1': {'es': '1 prompt', 'en': '1 prompt'},
    'n_prompts': {'es': '{0} prompts', 'en': '{0} prompts'},
    'n_paso1': {'es': '1 paso', 'en': '1 step'},
    'n_pasos': {'es': '{0} pasos', 'en': '{0} steps'},
    'razonamiento': {'es': 'razonamiento', 'en': 'reasoning'},
    'uso_opencode': {'es': 'Uso - OpenCode (hoy)', 'en': 'Usage - OpenCode (today)'},
    'opencode_sin_cli': {'es': 'Sin datos: no encontre el CLI de OpenCode (config.json -> opencodeCliPath) o el servicio no responde.',
                         'en': 'No data: OpenCode CLI not found (config.json -> opencodeCliPath) or the service is not responding.'},
    'uso_prov': {'es': 'Uso - {0} (hoy)', 'en': 'Usage - {0} (today)'},
    'prov_sin_datos': {'es': 'Sin datos: revisa command/file y args del proveedor en config.json.',
                       'en': 'No data: check the provider command/file and args in config.json.'},
    'costo': {'es': 'Costo: $ {0}', 'en': 'Cost: $ {0}'},
    'sin_metricas': {'es': 'Sin metricas para hoy.', 'en': 'No metrics for today.'},
    'ayuda_titulo': {'es': 'Como funciona', 'en': 'How it works'},
    'ayuda_1': {'es': '· Tareas: los agentes escriben status.json al lanzar tareas largas. Si la tarea trae journalPath, se cuenta 1 linea por agente ("started"/"result") y el ETA usa la duracion real de los agentes YA terminados.',
                'en': '· Tasks: agents write status.json when they launch long tasks. If the task has journalPath, one line per agent ("started"/"result") is counted and the ETA uses the real duration of agents that ALREADY finished.'},
    'ayuda_2': {'es': '· Claude: lee el cache de uso que la CLI deja en ~/.claude.json. No se refresca solo: corre /usage en Claude de vez en cuando.',
                'en': '· Claude: reads the usage cache the CLI leaves in ~/.claude.json. It does not refresh on its own: run /usage in Claude now and then.'},
    'ayuda_3': {'es': '· Codex: suma los tokens del dia desde las sesiones locales (~/.codex/sessions/<fecha>/*.jsonl) y, si el log los trae, muestra los limites de 5 hs / semanal.',
                'en': '· Codex: adds up today tokens from local sessions (~/.codex/sessions/<date>/*.jsonl) and, if the log includes them, shows the 5 h / weekly limits.'},
    'ayuda_4': {'es': '· OpenCode: corre `opencode stats --days 0 --json` cada 60 segundos.',
                'en': '· OpenCode: runs `opencode stats --days 0 --json` every 60 seconds.'},
    'ayuda_5': {'es': '· Otros modelos: se agregan en config.json -> customProviders, con un comando CLI (command + args) o un archivo JSON (file). Pueden devolver (todo opcional): sessions, prompts, steps, tokens {input, output, cache}, cost.',
                'en': '· Other models: add them in config.json -> customProviders, with a CLI command (command + args) or a JSON file (file). They can return (all optional): sessions, prompts, steps, tokens {input, output, cache}, cost.'},
    'ayuda_6': {'es': '· El menu hamburguesa de arriba (a la derecha) abre un popup con switchs para prender y apagar cada seccion, el switch "Modo claro" para cambiar el tema y el switch "English" para pasar la interfaz a ingles; todo se guarda en config.json. Al final del popup esta la leyenda del autor.',
                'en': '· The hamburger menu above (right side) opens a popup with switches to turn each section on/off, the "Light mode" switch to change the theme and the language switch to switch between Spanish and English; everything is saved in config.json. The author credit is at the bottom of the popup.'},
    'ayuda_7': {'es': '· Todo es local: el widget no manda nada a ninguna API; solo lee archivos y corre CLIs ya instalados.',
                'en': '· Everything is local: the widget sends nothing to any API; it only reads files and runs already installed CLIs.'},
    'modo_claro': {'es': 'Modo claro', 'en': 'Light mode'},
    'leyenda': {'es': 'Hecho por Luca Baello', 'en': 'Made by Luca Baello'},
}

IDIOMA = 'es'


def T(clave):
    par = TXT.get(clave)
    if not par:
        return clave
    return par.get(IDIOMA) or clave


def TF(clave, *valores):
    return T(clave).format(*valores)


# ---------- Config ----------
def config_defecto():
    return {
        'statusPaths': [os.path.join(DIR_SCRIPT, 'status.json')],
        'opencodeCliPath': None,
        'opencodeRefreshSeconds': 60,
        'codexRefreshSeconds': 60,
        'sections': {'tasks': True, 'claude': True, 'codex': True, 'opencode': True},
        'showHelp': False,
        'theme': 'dark',
        'language': 'auto',
        'customProviders': [],
    }


def _entero(valor, defecto):
    try:
        n = int(float(str(valor)))
    except (TypeError, ValueError):
        return defecto
    return max(-1000000000, min(1000000000, n))


def cargar_config(ruta):
    cfg = config_defecto()
    try:
        with open(ruta, 'r', encoding='utf-8-sig') as f:
            datos = json.load(f)
        if not isinstance(datos, dict):
            raise ValueError('config.json no es un objeto JSON')
    except FileNotFoundError:
        return cfg
    except Exception:
        # Config roto: copia recuperable antes de que el primer guardado la pise.
        try:
            shutil.copyfile(ruta, ruta + '.bak')
        except Exception:
            pass
        return cfg

    rutas = datos.get('statusPaths')
    if isinstance(rutas, list) and rutas:
        # Se guardan tal como vinieron (relativas si son relativas): asi la misma config
        # sirve en Windows y en Linux. La resolucion se hace al leer.
        cfg['statusPaths'] = [str(p) for p in rutas]
    if datos.get('opencodeCliPath'):
        cfg['opencodeCliPath'] = str(datos['opencodeCliPath'])
    for clave in ('opencodeRefreshSeconds', 'codexRefreshSeconds'):
        if str(datos.get(clave)).strip():
            n = _entero(datos.get(clave), 0)
            if n > 0:
                cfg[clave] = n
    if isinstance(datos.get('sections'), dict):
        for clave, valor in datos['sections'].items():
            cfg['sections'][str(clave)] = bool(valor)
    if datos.get('showHelp') is not None:
        cfg['showHelp'] = bool(datos['showHelp'])
    if str(datos.get('theme')).lower() in ('dark', 'light'):
        cfg['theme'] = str(datos['theme']).lower()
    if str(datos.get('language')).lower() in ('auto', 'es', 'en'):
        cfg['language'] = str(datos['language']).lower()
    if isinstance(datos.get('customProviders'), list):
        cfg['customProviders'] = [
            p for p in datos['customProviders']
            if isinstance(p, dict) and p.get('id') and (p.get('command') or p.get('file'))
        ]
    for prov in cfg['customProviders']:
        cid = 'custom:' + str(prov['id'])
        cfg['sections'].setdefault(cid, True)
    return cfg


def guardar_config(cfg, ruta):
    # Merge sobre el archivo: las claves desconocidas del usuario se conservan.
    salida = {}
    try:
        with open(ruta, 'r', encoding='utf-8-sig') as f:
            previo = json.load(f)
        if isinstance(previo, dict):
            salida = previo
    except Exception:
        salida = {}
    claves = ('statusPaths', 'opencodeCliPath', 'opencodeRefreshSeconds', 'codexRefreshSeconds',
              'sections', 'showHelp', 'theme', 'language', 'customProviders')
    for clave in claves:
        for existente in [k for k in salida if str(k).lower() == clave.lower()]:
            del salida[existente]
        salida[clave] = cfg[clave]
    try:
        if os.path.dirname(ruta):
            os.makedirs(os.path.dirname(ruta), exist_ok=True)
        with open(ruta, 'w', encoding='utf-8') as f:
            json.dump(salida, f, ensure_ascii=False, indent=2)
    except Exception:
        pass


def resolver_idioma(cfg):
    idioma = str(cfg.get('language') or 'auto').lower()
    if idioma in ('es', 'en'):
        return idioma
    entorno = (os.environ.get('LC_ALL') or os.environ.get('LC_MESSAGES')
               or os.environ.get('LANG') or '')
    return 'es' if entorno.lower().startswith('es') else 'en'


# ---------- Helpers de formato ----------
def leer_archivo(ruta):
    with open(ruta, 'r', encoding='utf-8-sig', errors='replace') as f:
        return f.read()


def _traducir_ruta(ruta):
    """Traduce rutas absolutas del otro sistema (C:\\... <-> /mnt/c/...) para que la misma
    config.json sirva en Windows y en WSL."""
    if not ruta:
        return ruta
    if os.name == 'nt':
        coincidencia = re.match(r'^/mnt/([A-Za-z])/(.*)$', ruta)
        if coincidencia:
            return coincidencia.group(1).upper() + ':\\' + coincidencia.group(2).replace('/', '\\')
    else:
        coincidencia = re.match(r'^([A-Za-z]):[\\/](.*)$', ruta)
        if coincidencia:
            candidata = '/mnt/' + coincidencia.group(1).lower() + '/' + coincidencia.group(2).replace('\\', '/')
            if os.path.exists(candidata):
                return candidata
    return ruta


def resolver_ruta(ruta):
    """Ruta lista para abrir: relativa al script si hace falta, traducida si viene del otro SO."""
    ruta = str(ruta)
    absoluta = os.path.isabs(ruta)
    if os.name != 'nt' and re.match(r'^[A-Za-z]:[\\/]', ruta):
        absoluta = True  # ruta de Windows vista desde Linux
    if not absoluta:
        return os.path.join(DIR_SCRIPT, ruta)
    if os.path.exists(ruta):
        return ruta
    return _traducir_ruta(ruta)


def convertir_numero(valor, defecto=0.0):
    if valor is None or isinstance(valor, bool):
        return defecto if valor is None else float(valor)
    try:
        n = float(valor)
    except (TypeError, ValueError):
        return defecto
    if n != n or n in (float('inf'), float('-inf')):
        return defecto
    return n


def format_duracion(minutos):
    if minutos < 1:
        return T('dur_menos_1')
    if minutos < 60:
        return '%d min' % round(minutos)
    horas = int(minutos // 60)
    resto = round(minutos % 60)
    return '%dh %dm' % (horas, resto)


def format_numero(n):
    n = convertir_numero(n)
    if n >= 1000000:
        return ('%g' % round(n / 1000000, 1)) + 'M'
    if n >= 1000:
        return ('%g' % round(n / 1000, 1)) + 'k'
    return str(int(n))


def _parse_fecha(valor):
    if valor is None or valor == '':
        return None
    if isinstance(valor, datetime.datetime):
        fecha = valor
    else:
        texto = str(valor).strip()
        try:
            fecha = datetime.datetime.fromisoformat(texto.replace('Z', '+00:00'))
        except ValueError:
            return None
    # Sin zona horaria se asume hora local (igual que PowerShell con los ISO sin offset).
    fecha = fecha.astimezone()
    return fecha


def format_fecha_reset_local(fecha):
    ahora = datetime.datetime.now().astimezone()
    if fecha.date() == ahora.date():
        return TF('reset_hoy', fecha.strftime('%H:%M'))
    formato = '%m/%d' if IDIOMA == 'en' else '%d/%m'
    return TF('reset_dia', fecha.strftime(formato), fecha.strftime('%H:%M'))


def format_reset(valor):
    fecha = _parse_fecha(valor)
    if fecha is None:
        return None
    return format_fecha_reset_local(fecha)


def format_reset_unix(segundos):
    if segundos is None:
        return None
    try:
        fecha = datetime.datetime.fromtimestamp(float(segundos)).astimezone()
    except (TypeError, ValueError, OSError):
        return None
    return format_fecha_reset_local(fecha)


def convertir_fecha(valor):
    return _parse_fecha(valor)


def color_por_porcentaje(pct):
    if pct >= 90:
        return 'danger'
    if pct >= 70:
        return 'warn'
    return 'orange'


def _creacion(ruta):
    st = os.stat(ruta)
    return getattr(st, 'st_birthtime', None) or st.st_mtime


# ---------- Tareas ----------
def get_progreso_journal(journal_path):
    resultado = {'completados': 0, 'duraciones': [], 'en_vuelo': []}
    if not os.path.isfile(journal_path):
        return resultado
    journal_dir = os.path.dirname(journal_path)
    try:
        lineas = leer_archivo(journal_path).splitlines()
    except OSError:
        return resultado

    pendientes = {}
    duraciones = []
    completados = 0
    for linea in lineas:
        linea = linea.strip()
        if not linea:
            continue
        try:
            evento = json.loads(linea)
        except ValueError:
            continue
        if not isinstance(evento, dict) or not evento.get('key'):
            continue
        if evento.get('type') == 'started':
            pendientes[str(evento['key'])] = evento.get('agentId')
        elif evento.get('type') == 'result':
            agent_id = evento.get('agentId')
            pendientes.pop(str(evento['key']), None)
            completados += 1
            jsonl = os.path.join(journal_dir, 'agent-%s.jsonl' % agent_id)
            meta = os.path.join(journal_dir, 'agent-%s.meta.json' % agent_id)
            if os.path.isfile(jsonl) and os.path.isfile(meta):
                try:
                    duracion = (os.path.getmtime(jsonl) - _creacion(meta)) / 60.0
                    if duracion > 0:
                        duraciones.append(duracion)
                except OSError:
                    pass

    en_vuelo = []
    ahora = datetime.datetime.now().timestamp()
    for agent_id in pendientes.values():
        meta = os.path.join(journal_dir, 'agent-%s.meta.json' % agent_id)
        if os.path.isfile(meta):
            try:
                en_vuelo.append((ahora - _creacion(meta)) / 60.0)
            except OSError:
                pass
    resultado['completados'] = completados
    resultado['duraciones'] = duraciones
    resultado['en_vuelo'] = en_vuelo
    return resultado


def get_eta_minutos(esperados, completados, duraciones, en_vuelo):
    if not duraciones:
        return None
    promedio = sum(duraciones) / len(duraciones)
    no_iniciados = max(0, esperados - completados - len(en_vuelo))
    eta_vuelo = 0.0
    if en_vuelo:
        max_transcurrido = max(en_vuelo)
        eta_vuelo = max(promedio - max_transcurrido, promedio * 0.15)
    return eta_vuelo + no_iniciados * promedio


def leer_status(rutas):
    tareas = []
    for ruta in rutas:
        ruta = resolver_ruta(ruta)
        if not os.path.isfile(ruta):
            continue
        try:
            datos = json.loads(leer_archivo(ruta))
        except Exception:
            continue
        if isinstance(datos, dict) and isinstance(datos.get('tasks'), list):
            # Una entrada rara en tasks no debe romper el refresco (ni el timer de GTK).
            tareas.extend(t for t in datos['tasks'] if isinstance(t, dict))
    return tareas


# ---------- Claude ----------
_ULTIMO_CLAUDE = {'uso': None}


def get_uso_claude():
    """Lee el cache de la CLI. Si el archivo esta a medio escribir o desaparece, devuelve el
    ultimo dato bueno (igual que la version Windows)."""
    if not os.path.isfile(RUTA_CLAUDE):
        return _ULTIMO_CLAUDE['uso']
    try:
        cfg = json.loads(leer_archivo(RUTA_CLAUDE))
        cache_util = cfg.get('cachedUsageUtilization') or {}
        util = cache_util.get('utilization') or {}
        if not util:
            return _ULTIMO_CLAUDE['uso']
        cinco = util.get('five_hour') or {}
        siete = util.get('seven_day') or {}
        edad = None
        fetched = cache_util.get('fetchedAtMs')
        if fetched:
            edad = (datetime.datetime.now().timestamp() * 1000 - convertir_numero(fetched)) / 1000.0
        uso = {
            'cinco_pct': int(round(convertir_numero(cinco.get('utilization')))),
            'cinco_reset': cinco.get('resets_at'),
            'siete_pct': int(round(convertir_numero(siete.get('utilization')))),
            'siete_reset': siete.get('resets_at'),
            'edad_seg': edad,
        }
        _ULTIMO_CLAUDE['uso'] = uso
        return uso
    except Exception:
        return _ULTIMO_CLAUDE['uso']


# ---------- Codex ----------
def get_uso_codex():
    if not os.path.isdir(DIR_CODEX):
        return None
    hoy = datetime.date.today()
    archivos = []
    for raiz, _dirs, nombres in os.walk(DIR_CODEX):
        for nombre in nombres:
            if not nombre.endswith('.jsonl'):
                continue
            ruta = os.path.join(raiz, nombre)
            try:
                mtime = datetime.datetime.fromtimestamp(os.path.getmtime(ruta))
            except OSError:
                continue
            if mtime.date() >= hoy:
                archivos.append(ruta)

    if not archivos:
        return {'sesiones': 0}

    entrada = 0.0
    cache = 0.0
    salida = 0.0
    razonamiento = 0.0
    rate5 = rate7 = reset5 = reset7 = None
    for ruta in archivos:
        try:
            with open(ruta, 'r', encoding='utf-8-sig', errors='replace') as f:
                # Solo las ultimas 600 lineas, sin cargar el archivo entero en memoria.
                tail = list(collections.deque(f, maxlen=600))
            texto = None
            for linea in reversed(tail):
                if '"token_count"' in linea:
                    texto = linea
                    break
            if texto is None and os.path.getsize(ruta) < 25 * 1024 * 1024:
                with open(ruta, 'r', encoding='utf-8-sig', errors='replace') as f:
                    for linea in f:
                        if '"token_count"' in linea:
                            texto = linea
            if not texto:
                continue
            evento = json.loads(texto)
            payload = evento.get('payload') or {}
            tu = (payload.get('info') or {}).get('total_token_usage') or {}
            entrada += convertir_numero(tu.get('input_tokens'))
            cache += convertir_numero(tu.get('cached_input_tokens'))
            salida += convertir_numero(tu.get('output_tokens'))
            razonamiento += convertir_numero(tu.get('reasoning_output_tokens'))
            rl = payload.get('rate_limits') or {}
            primario = rl.get('primary') or {}
            secundario = rl.get('secondary') or {}
            if primario.get('used_percent') is not None:
                rate5 = round(convertir_numero(primario.get('used_percent')))
            if secundario.get('used_percent') is not None:
                rate7 = round(convertir_numero(secundario.get('used_percent')))
            if primario.get('resets_at') is not None:
                reset5 = primario.get('resets_at')
            if secundario.get('resets_at') is not None:
                reset7 = secundario.get('resets_at')
        except Exception:
            continue
    return {
        'sesiones': len(archivos), 'entrada': entrada, 'cache': cache,
        'salida': salida, 'razonamiento': razonamiento,
        'rate5': rate5, 'rate7': rate7, 'reset5': reset5, 'reset7': reset7,
    }


# ---------- OpenCode ----------
_ULTIMO_OPENCODE = {'uso': None}


def resolver_cli_opencode(cfg):
    ruta = cfg.get('opencodeCliPath')
    if ruta and os.path.isfile(str(ruta)) and os.access(str(ruta), os.X_OK):
        return str(ruta)
    candidatos = [
        os.path.join(os.path.expanduser('~'), 'bin', 'opencode'),
        os.path.join(os.path.expanduser('~'), '.opencode', 'bin', 'opencode'),
        os.path.join(os.path.expanduser('~'), '.local', 'bin', 'opencode'),
    ]
    for candidato in candidatos:
        if os.path.isfile(candidato) and os.access(candidato, os.X_OK):
            return candidato
    return shutil.which('opencode')


def get_uso_opencode(cfg):
    cli = resolver_cli_opencode(cfg)
    if not cli:
        return _ULTIMO_OPENCODE['uso']
    try:
        proceso = subprocess.run([cli, 'stats', '--days', '0', '--json'],
                                 capture_output=True, text=True, timeout=10)
        datos = json.loads(proceso.stdout)
        tokens = datos.get('tokens') or {}
        cache = tokens.get('cache') or {}
        uso = {
            'sesiones': _entero(datos.get('sessions'), 0),
            'prompts': _entero(datos.get('prompts'), 0),
            'pasos': _entero(datos.get('steps'), 0),
            'entrada': convertir_numero(tokens.get('input')),
            'salida': convertir_numero(tokens.get('output')),
            'cache': convertir_numero(cache.get('read')) + convertir_numero(cache.get('write')),
            'costo': convertir_numero(datos.get('cost')),
        }
        _ULTIMO_OPENCODE['uso'] = uso
        return uso
    except Exception:
        return _ULTIMO_OPENCODE['uso']


# ---------- Proveedores custom ----------
def get_uso_provider_custom(cfg, prov):
    try:
        if prov.get('file'):
            datos = json.loads(leer_archivo(resolver_ruta(prov['file'])))
        else:
            args = prov.get('args') or []
            if isinstance(args, str):
                args = [args]
            comando = [str(prov.get('command'))] + [str(a) for a in args]
            proceso = subprocess.run(comando, capture_output=True, text=True, timeout=10)
            datos = json.loads(proceso.stdout)
        tokens = datos.get('tokens') or {}
        cache = tokens.get('cache') or {}
        return {
            'sesiones': _entero(datos.get('sessions'), 0),
            'prompts': _entero(datos.get('prompts'), 0),
            'pasos': _entero(datos.get('steps'), 0),
            'entrada': convertir_numero(tokens.get('input')),
            'salida': convertir_numero(tokens.get('output')),
            'cache': convertir_numero(cache.get('read')) + convertir_numero(cache.get('write')),
            'costo': convertir_numero(datos.get('cost')),
        }
    except Exception:
        return None


def refresh_provider(prov):
    valor = prov.get('refreshSeconds')
    if valor is None:
        return 60
    n = _entero(valor, 60)
    return n if 1 <= n <= 86400 else 60


# ---------- Modelo (datos + textos, sin GUI) ----------
def construir_modelo(cfg, cache):
    """Devuelve el modelo completo del widget: secciones con bloques ya formateados.

    cache: dict compartido entre refrescos (codex/opencode/custom con su TTL).
    """
    ahora = datetime.datetime.now().timestamp()
    modelo = {'idioma': IDIOMA, 'tema': cfg['theme'], 'secciones': {}}

    # --- Tareas ---
    tareas = leer_status(cfg['statusPaths'])
    activas = len([t for t in tareas if t.get('status') not in ('done', 'error')])
    texto_activas = T('activa1') if activas == 1 else TF('activas', activas)
    bloques = [{'tipo': 'texto', 'texto': texto_activas, 'clase': 'dim'}]
    if not tareas:
        bloques.append({'tipo': 'texto', 'texto': T('sin_tareas'), 'clase': 'dim', 'italica': True})
    for tarea in tareas:
        nombre = str(tarea.get('name') or '')
        estado = str(tarea.get('status') or '')
        completados = 0
        duraciones = []
        en_vuelo = []
        if tarea.get('journalPath'):
            progreso = get_progreso_journal(str(tarea['journalPath']))
            completados = progreso['completados']
            duraciones = progreso['duraciones']
            en_vuelo = progreso['en_vuelo']
        esperados = _entero(tarea.get('expectedAgents'), 0)
        total = _entero(tarea.get('total'), 0)
        hechos = _entero(tarea.get('done'), 0)
        tiene_journal = bool(tarea.get('journalPath'))

        barra = {'modo': 'indef'}
        detalle = ''
        clase_detalle = 'dim'
        if estado == 'done':
            barra = {'modo': 'frac', 'valor': 1.0, 'color': 'ok'}
            detalle = T('listo')
            clase_detalle = 'ok'
        elif estado == 'error':
            barra = {'modo': 'frac', 'valor': 1.0, 'color': 'danger'}
            detalle = T('error')
            clase_detalle = 'danger'
        else:
            inicio = convertir_fecha(tarea.get('startedAt'))
            elapsed = ((datetime.datetime.now().astimezone() - inicio).total_seconds() / 60.0) if inicio else 0
            if tiene_journal and esperados > 0:
                barra = {'modo': 'frac', 'valor': min(completados, esperados) / float(esperados), 'color': 'orange'}
                texto = TF('agentes', completados, esperados)
                restantes = esperados - completados
                if restantes <= 0:
                    texto += ' - ' + T('terminando')
                else:
                    eta = get_eta_minutos(esperados, completados, duraciones, en_vuelo)
                    texto += ' - ' + (TF('restantes', format_duracion(eta)) if eta is not None else T('estimando'))
                detalle = texto
            elif total > 0:
                barra = {'modo': 'frac', 'valor': min(hechos, total) / float(total), 'color': 'orange'}
                detalle = TF('contador_hace', hechos, total, format_duracion(elapsed))
            elif tarea.get('progress') is not None:
                valor = max(0.0, min(1.0, convertir_numero(tarea.get('progress'))))
                barra = {'modo': 'frac', 'valor': valor, 'color': 'orange'}
                detalle = TF('pct_hace', round(valor * 100), format_duracion(elapsed))
            else:
                detalle = TF('progreso_hace', format_duracion(elapsed))
        bloques.append({
            'tipo': 'tarea', 'nombre': nombre, 'barra': barra,
            'detalle': detalle, 'clase_detalle': clase_detalle,
            'extra': str(tarea.get('detail') or ''),
        })
    modelo['secciones']['tareas'] = {
        'titulo': T('sec_tasks'), 'visible': bool(cfg['sections'].get('tasks', True)), 'bloques': bloques,
    }

    # --- Claude ---
    visible_claude = bool(cfg['sections'].get('claude', True))
    uso = get_uso_claude() if visible_claude else None
    texto_edad = None
    color_edad = 'dim'
    if uso is None:
        texto_edad = T('sin_datos')
    elif uso['edad_seg'] is None:
        texto_edad = T('edad_desconocida')
    else:
        edad_min = uso['edad_seg'] / 60.0
        if uso['edad_seg'] < 60:
            texto_edad = TF('dato_hace_s', round(uso['edad_seg']))
            color_edad = 'ok'
        elif edad_min < 5:
            texto_edad = TF('dato_hace', format_duracion(edad_min))
        else:
            texto_edad = TF('puede_atras', format_duracion(edad_min))
            color_edad = 'warn'
    bloques = []
    if uso is None:
        bloques.append({'tipo': 'texto', 'texto': T('sin_uso'), 'clase': 'dim', 'italica': True})
    else:
        bloques.append({'tipo': 'texto', 'texto': T('claude_nota'), 'clase': 'dim', 'italica': True, 'chico': True})
        bloques.append({'tipo': 'fila_barra', 'etiqueta': T('sesion_5h'), 'pct': uso['cinco_pct'],
                        'reset': format_reset(uso.get('cinco_reset')),
                        'color': color_por_porcentaje(uso['cinco_pct'])})
        bloques.append({'tipo': 'fila_barra', 'etiqueta': T('semanal_7d'), 'pct': uso['siete_pct'],
                        'reset': format_reset(uso.get('siete_reset')),
                        'color': color_por_porcentaje(uso['siete_pct'])})
    modelo['secciones']['claude'] = {
        'titulo': T('uso_claude'), 'visible': bool(cfg['sections'].get('claude', True)),
        'edad': texto_edad, 'color_edad': color_edad, 'bloques': bloques,
    }

    # --- Codex ---
    visible_codex = bool(cfg['sections'].get('codex', True))
    ttl = _entero(cfg.get('codexRefreshSeconds'), 60)
    if visible_codex:
        guardado = cache.get('codex') or {}
        if guardado.get('leido') is not None and ahora - guardado['leido'] < ttl:
            uso = guardado.get('uso')
            leido = guardado['leido']
        else:
            uso = get_uso_codex()
            leido = ahora
            cache['codex'] = {'leido': leido, 'uso': uso}
    else:
        uso, leido = None, None
    texto_edad = T('sin_datos')
    if leido is not None:
        seg = ahora - leido
        texto_edad = TF('actualizado_s', round(seg)) if seg < 90 else TF('actualizado', format_duracion(seg / 60.0))
    bloques = []
    if uso is None:
        bloques.append({'tipo': 'texto', 'texto': T('codex_sin_carpeta'), 'clase': 'dim', 'italica': True})
    elif uso['sesiones'] == 0:
        bloques.append({'tipo': 'texto', 'texto': T('codex_sin_hoy'), 'clase': 'dim', 'italica': True})
    else:
        if uso.get('rate5') is not None:
            bloques.append({'tipo': 'fila_barra', 'etiqueta': T('sesion_5h'), 'pct': uso['rate5'],
                            'reset': format_reset_unix(uso.get('reset5')),
                            'color': color_por_porcentaje(uso['rate5'])})
        if uso.get('rate7') is not None:
            bloques.append({'tipo': 'fila_barra', 'etiqueta': T('semanal_7d'), 'pct': uso['rate7'],
                            'reset': format_reset_unix(uso.get('reset7')),
                            'color': color_por_porcentaje(uso['rate7'])})
        sesion_txt = T('n_sesion1') if uso['sesiones'] == 1 else TF('n_sesiones', uso['sesiones'])
        linea = 'Tokens: %s in' % format_numero(uso['entrada'])
        if uso['cache'] > 0:
            linea += ' (%s cache)' % format_numero(uso['cache'])
        linea += ' - %s out' % format_numero(uso['salida'])
        if uso['razonamiento'] > 0:
            linea += ' - %s %s' % (format_numero(uso['razonamiento']), T('razonamiento'))
        bloques.append({'tipo': 'texto', 'texto': sesion_txt, 'clase': 'normal'})
        bloques.append({'tipo': 'texto', 'texto': linea, 'clase': 'dim'})
    modelo['secciones']['codex'] = {
        'titulo': T('uso_codex'), 'visible': bool(cfg['sections'].get('codex', True)),
        'edad': texto_edad, 'color_edad': 'codex', 'bloques': bloques,
    }

    # --- OpenCode ---
    visible_opencode = bool(cfg['sections'].get('opencode', True))
    ttl = _entero(cfg.get('opencodeRefreshSeconds'), 60)
    if visible_opencode:
        guardado = cache.get('opencode') or {}
        if guardado.get('leido') is not None and ahora - guardado['leido'] < ttl:
            uso = guardado.get('uso')
            leido = guardado['leido']
        else:
            uso = get_uso_opencode(cfg)
            leido = ahora
            cache['opencode'] = {'leido': leido, 'uso': uso}
    else:
        uso, leido = None, None
    texto_edad = T('sin_datos')
    if leido is not None:
        seg = ahora - leido
        texto_edad = TF('actualizado_s', round(seg)) if seg < 90 else TF('actualizado', format_duracion(seg / 60.0))
    bloques = []
    if uso is None:
        bloques.append({'tipo': 'texto', 'texto': T('opencode_sin_cli'), 'clase': 'dim', 'italica': True, 'chico': True})
    else:
        sesion_txt = T('n_sesion1') if uso['sesiones'] == 1 else TF('n_sesiones', uso['sesiones'])
        prompt_txt = T('n_prompt1') if uso['prompts'] == 1 else TF('n_prompts', uso['prompts'])
        paso_txt = T('n_paso1') if uso['pasos'] == 1 else TF('n_pasos', uso['pasos'])
        bloques.append({'tipo': 'texto', 'texto': '%s - %s - %s' % (sesion_txt, prompt_txt, paso_txt), 'clase': 'normal'})
        bloques.append({'tipo': 'texto', 'texto': 'Tokens: %s in - %s out - %s cache' % (
            format_numero(uso['entrada']), format_numero(uso['salida']), format_numero(uso['cache'])), 'clase': 'dim'})
        bloques.append({'tipo': 'texto', 'texto': TF('costo', '%.2f' % uso['costo']), 'clase': 'dim'})
    modelo['secciones']['opencode'] = {
        'titulo': T('uso_opencode'), 'visible': bool(cfg['sections'].get('opencode', True)),
        'edad': texto_edad, 'color_edad': 'opencode', 'bloques': bloques,
    }

    # --- Proveedores custom ---
    customs = []
    for prov in cfg['customProviders']:
        cid = 'custom:' + str(prov['id'])
        nombre = str(prov.get('name') or prov['id'])
        visible = bool(cfg['sections'].get(cid, True))
        ttl = refresh_provider(prov)
        if visible:
            guardado = cache.get(cid) or {}
            if guardado.get('leido') is not None and ahora - guardado['leido'] < ttl:
                uso = guardado.get('uso')
                leido = guardado['leido']
            else:
                uso = get_uso_provider_custom(cfg, prov)
                leido = ahora
                cache[cid] = {'leido': leido, 'uso': uso}
        else:
            uso, leido = None, None
        texto_edad = None
        if uso is not None:
            seg = ahora - leido
            texto_edad = TF('actualizado_s', round(seg)) if seg < 90 else TF('actualizado', format_duracion(seg / 60.0))
        bloques = []
        if uso is None:
            bloques.append({'tipo': 'texto', 'texto': T('prov_sin_datos'), 'clase': 'dim', 'italica': True, 'chico': True})
        else:
            if uso['sesiones'] or uso['prompts'] or uso['pasos']:
                sesion_txt = T('n_sesion1') if uso['sesiones'] == 1 else TF('n_sesiones', uso['sesiones'])
                prompt_txt = T('n_prompt1') if uso['prompts'] == 1 else TF('n_prompts', uso['prompts'])
                paso_txt = T('n_paso1') if uso['pasos'] == 1 else TF('n_pasos', uso['pasos'])
                bloques.append({'tipo': 'texto', 'texto': '%s - %s - %s' % (sesion_txt, prompt_txt, paso_txt), 'clase': 'normal'})
            if uso['entrada'] or uso['salida'] or uso['cache']:
                bloques.append({'tipo': 'texto', 'texto': 'Tokens: %s in - %s out - %s cache' % (
                    format_numero(uso['entrada']), format_numero(uso['salida']), format_numero(uso['cache'])), 'clase': 'dim'})
            if uso['costo'] > 0:
                bloques.append({'tipo': 'texto', 'texto': TF('costo', '%.2f' % uso['costo']), 'clase': 'dim'})
            if not bloques:
                bloques.append({'tipo': 'texto', 'texto': T('sin_metricas'), 'clase': 'dim', 'italica': True})
        customs.append({
            'id': cid, 'titulo': TF('uso_prov', nombre),
            'visible': bool(cfg['sections'].get(cid, True)),
            'edad': texto_edad, 'color_edad': 'custom', 'bloques': bloques,
        })
    modelo['customs'] = customs

    # --- Ayuda ---
    modelo['ayuda'] = {
        'titulo': T('ayuda_titulo'), 'visible': bool(cfg['showHelp']),
        'bloques': [{'tipo': 'texto', 'texto': T('ayuda_%d' % i), 'clase': 'dim', 'chico': True} for i in range(1, 8)],
    }
    return modelo


# ---------- UI (GTK3) ----------
CSS_DARK = """
#raiz { background-color: rgba(30, 37, 48, 0.94); border: 1px solid #5A626E; border-radius: 10px; }
label { color: #F5F5F5; }
.dim { color: #9CA3AF; }
.dimchico { color: #9CA3AF; font-size: 9px; }
.titulo { font-weight: bold; font-size: 13px; }
.seccion { font-weight: bold; font-size: 12px; }
.normal { font-size: 11px; }
.chico { font-size: 10px; }
.nota { font-size: 9px; color: #9CA3AF; }
.ok { color: #22C55E; }
.warn { color: #F59E0B; }
.danger { color: #EF4444; }
.opencode { color: #38BDF8; }
.codex { color: #10A37F; }
.custom { color: #A78BFA; }
.nombre-tarea { font-size: 12px; }
progressbar { min-height: 6px; }
progressbar trough { background-color: rgba(255, 255, 255, 0.25); border-radius: 3px; min-height: 6px; }
progressbar progress { background-color: #F97316; border-radius: 3px; min-height: 6px; }
.barra-ok progress { background-color: #22C55E; }
.barra-danger progress { background-color: #EF4444; }
.barra-indef progress { background-color: #6B7280; }
popover { background-color: #11151C; border: 1px solid #3A4250; border-radius: 8px; }
popover label { color: #F5F5F5; }
button { background: transparent; border: none; color: #9CA3AF; padding: 0 4px; }
button:hover { color: #F97316; }
switch { background-color: #464E5A; border-radius: 8px; min-width: 30px; min-height: 16px; }
switch:checked { background-color: #F97316; }
switch slider { background-color: #F0F0F0; min-width: 12px; min-height: 12px; }
separator { background-color: #5A626E; min-height: 1px; }
.fila-menu { padding: 4px 2px; }
"""

CSS_LIGHT = """
#raiz { background-color: rgba(246, 247, 249, 0.97); border: 1px solid #CBD2DC; border-radius: 10px; }
label { color: #1F2937; }
.dim { color: #6B7280; }
.dimchico { color: #6B7280; font-size: 9px; }
.titulo { font-weight: bold; font-size: 13px; }
.seccion { font-weight: bold; font-size: 12px; }
.normal { font-size: 11px; }
.chico { font-size: 10px; }
.nota { font-size: 9px; color: #6B7280; }
.ok { color: #15803D; }
.warn { color: #B45309; }
.danger { color: #B91C1C; }
.opencode { color: #0284C7; }
.codex { color: #0D8A6A; }
.custom { color: #7C3AED; }
.nombre-tarea { font-size: 12px; }
progressbar { min-height: 6px; }
progressbar trough { background-color: rgba(0, 0, 0, 0.16); border-radius: 3px; min-height: 6px; }
progressbar progress { background-color: #F97316; border-radius: 3px; min-height: 6px; }
.barra-ok progress { background-color: #16A34A; }
.barra-danger progress { background-color: #DC2626; }
.barra-indef progress { background-color: #9CA3AF; }
popover { background-color: #FFFFFF; border: 1px solid #D1D5DB; border-radius: 8px; }
popover label { color: #1F2937; }
button { background: transparent; border: none; color: #6B7280; padding: 0 4px; }
button:hover { color: #F97316; }
switch { background-color: #CBD5E1; border-radius: 8px; min-width: 30px; min-height: 16px; }
switch:checked { background-color: #F97316; }
switch slider { background-color: #FFFFFF; min-width: 12px; min-height: 12px; }
separator { background-color: #CBD2DC; min-height: 1px; }
.fila-menu { padding: 4px 2px; }
"""


class Widget:
    def __init__(self, cfg, ruta_cfg, captura=None):
        import gi
        gi.require_version('Gtk', '3.0')
        gi.require_version('Gdk', '3.0')
        from gi.repository import Gtk, Gdk, GLib
        self.Gtk = Gtk
        self.Gdk = Gdk
        self.GLib = GLib
        self.cfg = cfg
        self.ruta_cfg = ruta_cfg
        self.captura = captura
        self.cache = {}
        self.barras_indef = []
        self.proveedor_css = Gtk.CssProvider()
        # Se registra una sola vez; cambiar de tema solo recarga el CSS.
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), self.proveedor_css,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self.ventana = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
        self.ventana.set_decorated(False)
        self.ventana.set_resizable(False)
        self.ventana.set_keep_above(True)
        self.ventana.set_skip_taskbar_hint(True)
        self.ventana.set_skip_pager_hint(True)
        self.ventana.set_title(T('titulo'))
        self.ventana.set_size_request(380, -1)
        self.ventana.set_name('ventana')
        try:
            pantalla = self.ventana.get_screen()
            visual = pantalla.get_rgba_visual()
            if visual is not None:
                self.ventana.set_visual(visual)
                self.ventana.set_app_paintable(True)
        except Exception:
            pass

        self.raiz = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.raiz.set_name('raiz')
        self.raiz.set_margin_top(0)
        self.ventana.add(self.raiz)

        self.aplicar_tema()
        self.construir_header()
        self.construir_contenido()
        self.ventana.connect('destroy', Gtk.main_quit)

        # Timer de refresco (2 s, igual que la version Windows).
        GLib.timeout_add_seconds(2, self.refrescar)
        # Pulso de las barras indeterminadas.
        GLib.timeout_add(120, self.pulsar)
        self.ventana.connect('map-event', self.mapeada)
        self.refrescar()
        self.ventana.show_all()
        # El WM puede pisar la posicion al mapear: se reintenta un instante despues.
        GLib.timeout_add(250, self.posicionar)
        if self.captura:
            GLib.timeout_add(1200, self.autocaptura)

    # --- chrome fijo ---
    def aplicar_tema(self):
        css = CSS_LIGHT if self.cfg['theme'] == 'light' else CSS_DARK
        self.proveedor_css.load_from_data(css.encode('utf-8'))

    def construir_header(self):
        Gtk = self.Gtk
        self.header = Gtk.EventBox()
        self.header.set_visible_window(False)
        fila = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        fila.set_margin_start(14)
        fila.set_margin_end(14)
        fila.set_margin_top(14)
        fila.set_margin_bottom(0)

        self.titulo = Gtk.Label(label=T('titulo'))
        self.titulo.get_style_context().add_class('titulo')
        self.titulo.set_xalign(0)
        fila.pack_start(self.titulo, True, True, 0)

        boton_menu = Gtk.Button(label='\u2630')
        boton_menu.set_relief(Gtk.ReliefStyle.NONE)
        boton_menu.connect('clicked', self.abrir_menu)
        self.boton_menu = boton_menu
        fila.pack_start(boton_menu, False, False, 4)

        self.boton_ayuda = Gtk.Button(label='?')
        self.boton_ayuda.set_relief(Gtk.ReliefStyle.NONE)
        self.boton_ayuda.connect('clicked', self.toggle_ayuda)
        fila.pack_start(self.boton_ayuda, False, False, 0)

        boton_cerrar = Gtk.Button(label='\u00d7')
        boton_cerrar.set_relief(Gtk.ReliefStyle.NONE)
        boton_cerrar.connect('clicked', lambda *_: Gtk.main_quit())
        fila.pack_start(boton_cerrar, False, False, 0)

        self.header.add(fila)
        self.header.add_events(self.Gdk.EventMask.BUTTON_PRESS_MASK)
        self.header.connect('button-press-event', self.arrastrar)
        self.raiz.pack_start(self.header, False, False, 0)

    def construir_contenido(self):
        Gtk = self.Gtk
        self.scroll = Gtk.ScrolledWindow()
        self.scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.scroll.set_margin_start(14)
        self.scroll.set_margin_end(14)
        self.scroll.set_margin_top(4)
        self.scroll.set_margin_bottom(10)
        monitor = self._monitor()
        alto = monitor.get_workarea().height if monitor is not None else 800
        self.scroll.set_max_content_height(max(300, alto - 90))
        self.scroll.set_propagate_natural_height(True)
        self.panel = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self.scroll.add(self.panel)
        self.raiz.pack_start(self.scroll, True, True, 0)

    def arrastrar(self, widget, evento):
        if evento.button == 1:
            self.ventana.begin_move_drag(evento.button, int(evento.x_root), int(evento.y_root), evento.time)
            return True
        return False

    def mapeada(self, *_):
        self.posicionar()
        return False

    def _monitor(self):
        # En Wayland puro puede no haber monitor "primario": se usa el primero.
        display = self.Gdk.Display.get_default()
        if display is None:
            return None
        monitor = display.get_primary_monitor()
        if monitor is None and display.get_n_monitors():
            monitor = display.get_monitor(0)
        return monitor

    def posicionar(self):
        try:
            monitor = self._monitor()
            if monitor is None:
                return False
            area = monitor.get_workarea()
            ancho = self.ventana.get_size()[0]
            self.ventana.move(area.x + area.width - ancho - 20, area.y + 20)
        except Exception:
            pass
        return False

    # --- menu popup ---
    def abrir_menu(self, boton):
        Gtk = self.Gtk
        if getattr(self, 'popover', None) is not None:
            self.popover.destroy()
        popover = Gtk.Popover()
        popover.set_relative_to(boton)
        popover.set_position(Gtk.PositionType.BOTTOM)
        caja = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        caja.set_margin_top(10)
        caja.set_margin_bottom(10)
        caja.set_margin_start(14)
        caja.set_margin_end(14)

        filas = [('tasks', T('sec_tasks')), ('claude', T('sec_claude')),
                 ('codex', T('sec_codex')), ('opencode', T('sec_opencode'))]
        for prov in self.cfg['customProviders']:
            if prov.get('id') and prov.get('name'):
                filas.append(('custom:' + str(prov['id']), str(prov['name'])))
        for sid, nombre in filas:
            caja.pack_start(self.fila_menu(sid, nombre, bool(self.cfg['sections'].get(sid, True))), False, False, 2)
        caja.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 8)
        caja.pack_start(self.fila_menu('theme', T('modo_claro'), self.cfg['theme'] == 'light'), False, False, 2)
        caja.pack_start(self.fila_menu('language', 'English', IDIOMA == 'en'), False, False, 2)
        caja.pack_start(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL), False, False, 8)
        leyenda = Gtk.Label(label=T('leyenda'))
        leyenda.get_style_context().add_class('dimchico')
        caja.pack_start(leyenda, False, False, 2)
        repo = Gtk.Label(label='github.com/lucabaello1998/ai-progress')
        repo.get_style_context().add_class('dimchico')
        caja.pack_start(repo, False, False, 0)
        popover.add(caja)
        popover.show_all()
        self.popover = popover

    def fila_menu(self, sid, nombre, activo):
        Gtk = self.Gtk
        fila = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        fila.get_style_context().add_class('fila-menu')
        etiqueta = Gtk.Label(label=nombre)
        etiqueta.set_xalign(0)
        fila.pack_start(etiqueta, True, True, 0)
        switch = Gtk.Switch()
        switch.set_active(activo)
        switch.set_valign(Gtk.Align.CENTER)
        switch.set_can_focus(False)

        def cambiar(_s, estado, _sid=sid):
            self.alternar(_sid, estado)
            return False
        switch.connect('notify::active', cambiar)
        fila.pack_start(switch, False, False, 0)
        return fila

    def alternar(self, sid, estado):
        reetiquetar = False
        if sid == 'theme':
            self.cfg['theme'] = 'light' if estado else 'dark'
            self.aplicar_tema()
        elif sid == 'language':
            global IDIOMA
            IDIOMA = 'en' if estado else 'es'
            self.cfg['language'] = IDIOMA
            self.ventana.set_title(T('titulo'))
            self.titulo.set_text(T('titulo'))
            reetiquetar = True
        else:
            self.cfg['sections'][sid] = bool(estado)
        guardar_config(self.cfg, self.ruta_cfg)
        self.refrescar()
        # Si cambio el idioma, el popup abierto tiene etiquetas viejas: se rehace.
        if reetiquetar and getattr(self, 'popover', None) is not None:
            self.popover.popdown()
            self.abrir_menu(self.boton_menu)

    def toggle_ayuda(self, *_):
        self.cfg['showHelp'] = not self.cfg['showHelp']
        guardar_config(self.cfg, self.ruta_cfg)
        self.refrescar()

    # --- render ---
    def limpiar_panel(self):
        for hijo in list(self.panel.get_children()):
            self.panel.remove(hijo)

    def etiqueta(self, texto, clase='normal', italica=False, wrap=True):
        Gtk = self.Gtk
        lab = Gtk.Label(label=texto)
        lab.set_xalign(0)
        lab.set_line_wrap(wrap)
        lab.set_use_markup(False)
        ctx = lab.get_style_context()
        for c in clase.split():
            if c:
                ctx.add_class(c)
        if italica:
            lab.set_attributes(self._attr_italica())
        return lab

    def _attr_italica(self):
        from gi.repository import Pango
        atributos = Pango.AttrList()
        atributos.insert(Pango.attr_style_new(Pango.Style.ITALIC))
        return atributos

    def barra(self, valor=None, color='orange'):
        Gtk = self.Gtk
        barra = Gtk.ProgressBar()
        if valor is None:
            barra.get_style_context().add_class('barra-indef')
            self.barras_indef.append(barra)
        else:
            barra.get_style_context().add_class('barra-%s' % color)
            barra.set_fraction(max(0.0, min(1.0, float(valor))))
        return barra

    def render_seccion(self, seccion, separador=True, es_custom=False):
        Gtk = self.Gtk
        if not seccion.get('visible', True):
            return
        caja = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        caja.set_margin_top(8)
        caja.set_margin_bottom(4)
        encabezado = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
        titulo = Gtk.Label(label=seccion['titulo'])
        titulo.get_style_context().add_class('seccion')
        titulo.set_xalign(0)
        encabezado.pack_start(titulo, True, True, 0)
        if seccion.get('edad'):
            edad = Gtk.Label(label=seccion['edad'])
            edad.get_style_context().add_class(seccion.get('color_edad') or 'dim')
            edad.get_style_context().add_class('chico')
            edad.set_xalign(1)
            encabezado.pack_start(edad, False, False, 0)
        caja.pack_start(encabezado, False, False, 0)

        for bloque in seccion['bloques']:
            if bloque['tipo'] == 'texto':
                clase = bloque.get('clase', 'normal')
                if bloque.get('chico'):
                    clase += ' chico'
                lab = self.etiqueta(bloque['texto'], clase, bloque.get('italica', False))
                lab.set_margin_top(2)
                caja.pack_start(lab, False, False, 0)
            elif bloque['tipo'] == 'tarea':
                nombre = self.etiqueta(bloque['nombre'], 'nombre-tarea')
                nombre.set_margin_top(6)
                caja.pack_start(nombre, False, False, 0)
                barra = bloque['barra']
                if barra['modo'] == 'frac':
                    caja.pack_start(self.barra(barra['valor'], barra.get('color', 'orange')), False, False, 2)
                else:
                    caja.pack_start(self.barra(None), False, False, 2)
                detalle = self.etiqueta(bloque['detalle'], bloque.get('clase_detalle', 'dim'))
                caja.pack_start(detalle, False, False, 0)
                if bloque.get('extra'):
                    extra = self.etiqueta(bloque['extra'], 'dim chico', italica=True)
                    caja.pack_start(extra, False, False, 0)
            elif bloque['tipo'] == 'fila_barra':
                fila = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=6)
                fila.set_margin_top(4)
                etiqueta = Gtk.Label(label=bloque['etiqueta'])
                etiqueta.get_style_context().add_class('normal')
                etiqueta.set_xalign(0)
                fila.pack_start(etiqueta, True, True, 0)
                pct = Gtk.Label(label='%d%%' % bloque['pct'])
                pct.get_style_context().add_class(bloque['color'])
                pct.get_style_context().add_class('normal')
                fila.pack_start(pct, False, False, 0)
                caja.pack_start(fila, False, False, 0)
                caja.pack_start(self.barra(bloque['pct'] / 100.0, bloque['color']), False, False, 2)
                if bloque.get('reset'):
                    reset = self.etiqueta(bloque['reset'], 'dim chico')
                    caja.pack_start(reset, False, False, 0)
        if separador:
            sep = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
            sep.set_margin_top(8)
            sep.set_margin_bottom(2)
            self.panel.pack_start(sep, False, False, 0)
        self.panel.pack_start(caja, False, False, 0)

    def refrescar(self, *_):
        # Un dato raro (status.json a medio escribir, seccion rota) no debe matar el timer:
        # si el callback de GLib lanza, GTK lo desregistra y el widget queda congelado.
        try:
            self._refrescar()
        except Exception as error:
            print('refresco fallo: %s' % error, file=sys.stderr)
        return True

    def _refrescar(self):
        self.barras_indef = []
        self.limpiar_panel()
        modelo = construir_modelo(self.cfg, self.cache)
        self.render_seccion(modelo['secciones']['tareas'])
        self.render_seccion(modelo['secciones']['claude'])
        self.render_seccion(modelo['secciones']['codex'])
        self.render_seccion(modelo['secciones']['opencode'])
        for custom in modelo['customs']:
            self.render_seccion(custom, es_custom=True)
        if modelo['ayuda']['visible']:
            self.render_seccion(modelo['ayuda'], separador=False)
        self.ventana.queue_resize()
        self.ventana.show_all()

    def pulsar(self):
        for barra in list(self.barras_indef):
            try:
                barra.pulse()
            except Exception:
                pass
        return True

    def autocaptura(self):
        try:
            display = self.Gdk.Display.get_default()
            nombre = type(display).__name__ if display is not None else ''
            if 'Wayland' in nombre:
                # Wayland no expone el contenido de la ventana: no hay captura propia posible.
                print('--screenshot necesita X11: en Wayland no se puede leer la ventana.', file=sys.stderr)
            else:
                gdkwin = self.ventana.get_window()
                ancho, alto = self.ventana.get_size()
                pixbuf = self.Gdk.pixbuf_get_from_window(gdkwin, 0, 0, ancho, alto)
                if pixbuf is not None and self.captura:
                    carpeta = os.path.dirname(os.path.abspath(self.captura))
                    os.makedirs(carpeta, exist_ok=True)
                    pixbuf.savev(os.path.abspath(self.captura), 'png', [], [])
                else:
                    print('captura fallo: la ventana no devolvio pixbuf', file=sys.stderr)
        except Exception as error:
            print('captura fallo: %s' % error, file=sys.stderr)
        self.Gtk.main_quit()
        return False


# ---------- Entrada ----------
def mostrar_error(mensaje):
    print(mensaje, file=sys.stderr)
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description='ai-progress (Linux, GTK3)')
    parser.add_argument('--config', default=RUTA_CONFIG_DEFECTO)
    parser.add_argument('--dump', action='store_true', help='sin GUI: imprime el modelo como JSON')
    parser.add_argument('--screenshot', metavar='PNG', help='se autofotografia y cierra')
    parser.add_argument('--lang', choices=['es', 'en'])
    parser.add_argument('--theme', choices=['dark', 'light'])
    args = parser.parse_args()

    # En Wayland preferimos XWayland (X11) si esta disponible: permite posicionar la
    # ventana y mantenerla arriba como en Windows.
    if os.environ.get('WAYLAND_DISPLAY') and os.environ.get('DISPLAY'):
        os.environ.setdefault('GDK_BACKEND', 'x11')

    cfg = cargar_config(args.config)
    if args.lang:
        cfg['language'] = args.lang
    if args.theme:
        cfg['theme'] = args.theme

    global IDIOMA
    IDIOMA = resolver_idioma(cfg)

    if args.dump:
        modelo = construir_modelo(cfg, {})
        print(json.dumps(modelo, ensure_ascii=False, indent=2, default=str))
        return

    import gi
    gi.require_version('Gtk', '3.0')
    gi.require_version('Gdk', '3.0')
    from gi.repository import Gtk
    ok, _argv = Gtk.init_check(None)
    if not ok:
        mostrar_error('No hay display grafico (DISPLAY/WAYLAND_DISPLAY). '
                      'En WSL hace falta WSLg; en un server, corre con --dump.')
    app = Widget(cfg, args.config, args.screenshot)
    Gtk.main()


if __name__ == '__main__':
    main()
