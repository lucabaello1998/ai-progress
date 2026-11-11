#!/usr/bin/env python3
"""Verificación de ai-progress sin abrir ventana.

Cubre lo que se rompe en silencio en este proyecto, que no tiene build ni tests:

  1. Que `ai-progress-gtk.py --dump` siga armando el modelo en los dos idiomas
     (si un `TEXTS['clave']` queda sin 'en', la interfaz muestra la clave cruda).
  2. Que todos los textos tengan español e inglés, y que ninguna cadena quede vacía.
  3. Que cada tarea de `status.json` de ejemplo se pueda modelar: las que están
     `done`/`error` terminan cerradas y las demás no.
  4. Que `ai-progress.ps1` (la versión Windows) parsee sin errores de sintaxis.

Uso: python3 tools/check.py
Sale con código 1 si algo falla.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GTK = os.path.join(RAIZ, 'ai-progress-gtk.py')
PS1 = os.path.join(RAIZ, 'ai-progress.ps1')

fallas = []


def ok(nombre, cond, detalle=''):
    if cond:
        print('  ok   ', nombre)
    else:
        fallas.append(nombre)
        print('  FALLA', nombre, ('-> ' + detalle) if detalle else '')


def dump(idioma, config=None):
    """Corre la versión GTK en modo sin ventana y devuelve el modelo."""
    args = [sys.executable, GTK, '--dump', '--lang', idioma]
    if config:
        args += ['--config', config]
    salida = subprocess.run(args, cwd=RAIZ, capture_output=True, text=True, timeout=120)
    if salida.returncode != 0:
        return None, (salida.stderr or salida.stdout).strip()[-400:]
    try:
        return json.loads(salida.stdout), ''
    except json.JSONDecodeError as error:
        return None, str(error)


print('== modelo (--dump) ==')
modelos = {}
for idioma in ('es', 'en'):
    modelo, error = dump(idioma)
    modelos[idioma] = modelo
    ok(f'--dump en {idioma} devuelve JSON', modelo is not None, error)

modelo = modelos.get('es') or {}
ok('el idioma elegido es el que se pidió',
    (modelos.get('es') or {}).get('idioma') == 'es' and (modelos.get('en') or {}).get('idioma') == 'en',
    f"es={(modelos.get('es') or {}).get('idioma')} en={(modelos.get('en') or {}).get('idioma')}")
ok('trae las cuatro secciones',
    set(modelo.get('secciones') or {}) == {'tareas', 'claude', 'codex', 'opencode'},
    str(list((modelo.get('secciones') or {}).keys())))
ayuda = modelo.get('ayuda') or {}
ok('trae la ayuda', bool(ayuda.get('titulo')) and len(ayuda.get('bloques') or []) > 0)

print('\n== tareas ==')
tareas = []
for bloque in (modelo.get('secciones') or {}).get('tareas', {}).get('bloques', []):
    if bloque.get('tipo') == 'tarea':
        tareas.append(bloque)
ok('se modeló al menos una tarea', len(tareas) > 0)
ok('cada tarea tiene nombre, barra y detalle',
    all(t.get('nombre') and isinstance(t.get('barra'), dict) and 'modo' in t['barra'] for t in tareas))

# Las cerradas se dibujan llenas; las que no, nunca al 100%.
cerradas = [t for t in tareas if t['detalle'] in ('Listo', 'Error')]
abiertas = [t for t in tareas if t not in cerradas]
ok('las tareas cerradas muestran la barra llena',
    all(t['barra'].get('valor') == 1.0 for t in cerradas))
ok('las abiertas no muestran 100%',
    all(t['barra'].get('valor') is None or t['barra']['valor'] < 1.0 for t in abiertas))

en_bloqueadas = [b for b in (modelos.get('en') or {}).get('secciones', {}).get('tareas', {}).get('bloques', [])
                 if b.get('tipo') == 'tarea']
ok('los dos idiomas dibujan la misma cantidad de tareas', len(en_bloqueadas) == len(tareas),
    f'es={len(tareas)} en={len(en_bloqueadas)}')

print('\n== status.example.json ==')
# El ejemplo documentado tiene que poder dibujarse: es lo que copia cualquiera
# que arranca, y una forma de progreso que no se modela deja la barra colgada.
with tempfile.TemporaryDirectory() as tmp:
    config = os.path.join(tmp, 'config.json')
    with open(config, 'w', encoding='utf-8') as archivo:
        json.dump({'statusPaths': [os.path.join(RAIZ, 'status.example.json')]}, archivo)
    ejemplo_es, error_es = dump('es', config)
    ejemplo_en, error_en = dump('en', config)

ok('el ejemplo se modela en español', ejemplo_es is not None, error_es)
ok('el ejemplo se modela en inglés', ejemplo_en is not None, error_en)

bloques_ejemplo = (ejemplo_es or {}).get('secciones', {}).get('tareas', {}).get('bloques', [])
tareas_ejemplo = [b for b in bloques_ejemplo if b.get('tipo') == 'tarea']
ok('el ejemplo dibuja sus 5 tareas', len(tareas_ejemplo) == 5, str(len(tareas_ejemplo)))

detalles = [t.get('detalle') for t in tareas_ejemplo]
ok('la tarea bloqueada del ejemplo se marca bloqueada', 'Bloqueada' in detalles, str(detalles))
ok('la tarea terminada del ejemplo se marca lista', 'Listo' in detalles, str(detalles))

detalles_en = [b.get('detalle') for b in (ejemplo_en or {}).get('secciones', {}).get('tareas', {}).get('bloques', [])
               if b.get('tipo') == 'tarea']
ok('y en inglés dice Blocked / Done', 'Blocked' in detalles_en and 'Done' in detalles_en, str(detalles_en))

print('\n== textos ==')
sys.path.insert(0, RAIZ)
try:
    import importlib.util
    spec = importlib.util.spec_from_file_location('aip_gtk', GTK)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    textos = modulo.TXT
except Exception as error:  # noqa: BLE001 - si no importa, no hay nada que verificar
    textos = None
    detail = str(error)

if textos is None:
    ok('se puede importar el módulo para revisar los textos', False, detail)
else:
    sin_en = [k for k, v in textos.items() if not v.get('en')]
    sin_es = [k for k, v in textos.items() if not v.get('es')]
    vacias = [k for k, v in textos.items() if not str(v.get('es', '')).strip() or not str(v.get('en', '')).strip()]
    ok(f'{len(textos)} textos tienen español e inglés', not sin_en and not sin_es,
       f'sin en: {sin_en} · sin es: {sin_es}')
    ok('ningún texto quedó vacío', not vacias, str(vacias))

print('\n== versión Windows (PowerShell) ==')
pwsh = shutil.which('pwsh')
if not pwsh:
    print('  info  pwsh no está en el PATH: se saltea el chequeo de sintaxis')
else:
    script = (
        '$e = $null; $t = $null; '
        f'[System.Management.Automation.Language.Parser]::ParseFile("{PS1}", [ref]$t, [ref]$e) | Out-Null; '
        'if ($e.Count -gt 0) { $e | ForEach-Object { Write-Output ($_.Extent.StartLineNumber.ToString() + ": " + $_.Message) }; exit 1 }'
    )
    salida = subprocess.run([pwsh, '-NoProfile', '-Command', script], capture_output=True, text=True, timeout=120)
    ok('ai-progress.ps1 parsea sin errores', salida.returncode == 0, (salida.stdout or salida.stderr).strip())

print('\n' + '=' * 60)
if fallas:
    print(f'  {len(fallas)} problema(s): ' + ', '.join(fallas))
    sys.exit(1)
print('  Todo en orden.')
