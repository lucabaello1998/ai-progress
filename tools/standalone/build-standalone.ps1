# Compila el .exe autocontenido (no necesita PowerShell 7 instalado).
# Requiere el SDK de .NET 8+ y conexion a NuGet la primera vez (restore del SDK de PowerShell).
$ErrorActionPreference = 'Stop'
$raiz = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$proyecto = Join-Path $PSScriptRoot 'ai-progress-standalone.csproj'
$salida = Join-Path $raiz 'dist'

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'Falta el SDK de .NET (winget install Microsoft.DotNet.SDK.8)'
}

& dotnet publish $proyecto -c Release -o $salida
if ($LASTEXITCODE -ne 0) { throw "dotnet publish fallo con codigo $LASTEXITCODE" }

$exe = Join-Path $salida 'ai-progress.exe'
if (-not (Test-Path $exe)) { throw "No se genero $exe" }
$item = Get-Item $exe
'OK {0} ({1:N1} MB)' -f $item.FullName, ($item.Length / 1MB)

# Paquete para compartir: el .exe + la carpeta runtimes que usa en el primer arranque.
$leeme = Join-Path $salida 'LEEME.txt'
@'
ai-progress (Windows)
====================

1) Descomprimi esta carpeta completa.
2) Doble clic en ai-progress.exe.

No hace falta instalar PowerShell ni .NET: el .exe trae todo.
La configuracion y el status.json viven en:
  %LOCALAPPDATA%\ai-progress\runtime

Opcional: clic derecho en ai-progress.exe > Crear acceso directo, y el switch
"Iniciar con Windows" del menu del widget para que arranque solo.
'@ | Set-Content -LiteralPath $leeme -Encoding UTF8

$zip = Join-Path $salida 'ai-progress-portable.zip'
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Get-ChildItem -LiteralPath $salida | Where-Object { $_.Name -ne 'ai-progress-portable.zip' } | ForEach-Object { $_.FullName }) -DestinationPath $zip -Force
'OK {0} ({1:N1} MB)' -f $zip, ((Get-Item $zip).Length / 1MB)
