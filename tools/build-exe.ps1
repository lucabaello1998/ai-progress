# Compila ai-progress.exe (lanzador sin consola, con icono) usando el csc que ya
# viene con Windows (.NET Framework 4.x). No hace falta instalar nada.
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent $PSScriptRoot
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { throw 'No encontre csc.exe (.NET Framework 4.x)' }

$icono = Join-Path $raiz 'assets\ai-progress.ico'
if (-not (Test-Path $icono)) {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) { & $python.Source (Join-Path $raiz 'tools\build-icon.py') }
}
if (-not (Test-Path $icono)) { throw 'Falta assets\ai-progress.ico (corre tools\build-icon.py)' }

$salida = Join-Path $raiz 'ai-progress.exe'
$fuente = Join-Path $raiz 'tools\launcher\ai-progress-launcher.cs'
$argumentos = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    ('/out:' + $salida),
    ('/win32icon:' + $icono),
    '/r:System.Windows.Forms.dll',
    '/r:System.Drawing.dll',
    $fuente
)
& $csc $argumentos
if ($LASTEXITCODE -ne 0) { throw "csc fallo con codigo $LASTEXITCODE" }
$item = Get-Item $salida
'OK {0} ({1:N0} B)' -f $item.FullName, $item.Length
