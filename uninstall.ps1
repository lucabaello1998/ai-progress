<#
  Desinstalador de ai-progress (Windows).

  Uso:
    powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1 [-Dir <carpeta>] [-Todo]

  Por defecto borra el programa y los accesos directos, pero conserva config.json y
  status.json en la carpeta. Con -Todo borra la carpeta completa.
#>
[CmdletBinding()]
param(
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'ai-progress'),
    [switch]$Todo
)

$ErrorActionPreference = 'Stop'
$destino = [System.IO.Path]::GetFullPath($Dir)

# Cerrar instancias que corran desde esta carpeta (solo el widget, no este script).
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object {
    $_.ProcessId -ne $PID -and
    $_.CommandLine -and
    $_.CommandLine -match 'ai-progress\.ps1' -and
    $_.CommandLine.IndexOf($destino, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

# Accesos directos.
foreach ($lnk in @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\ai-progress.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'ai-progress.lnk')
)) {
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
}

# Arranque con Windows, solo si apunta a esta instalacion.
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$valor = (Get-ItemProperty -Path $run -Name 'ai-progress' -ErrorAction SilentlyContinue).'ai-progress'
if ($valor -and $valor.IndexOf($destino, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
    Remove-ItemProperty -Path $run -Name 'ai-progress' -ErrorAction SilentlyContinue
}

if (-not (Test-Path -LiteralPath $destino)) {
    Write-Host "No hay instalacion en $destino"
    return
}

if ($Todo) {
    Remove-Item -LiteralPath $destino -Recurse -Force
    Write-Host "Borrado completo: $destino"
} else {
    Get-ChildItem -LiteralPath $destino -Force |
        Where-Object { $_.Name -notin @('config.json', 'status.json') } |
        Remove-Item -Recurse -Force
    Write-Host "Programa borrado. Tus datos quedaron en: $destino"
    Write-Host 'Para borrar tambien los datos: uninstall.ps1 -Todo'
}
