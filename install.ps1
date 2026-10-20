<#
  Instalador simple de ai-progress para Windows.

  Uso:
    doble clic en install.cmd
    o: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 [-Dir <carpeta>] [-Autostart] [-Desktop] [-NoStart]

  Copia el programa a %LOCALAPPDATA%\ai-progress, crea el acceso directo del menu
  Inicio y, si se pide, el arranque con Windows.
#>
[CmdletBinding()]
param(
    [string]$Dir = (Join-Path $env:LOCALAPPDATA 'ai-progress'),
    [switch]$Autostart,
    [switch]$Desktop,
    [switch]$NoStart
)

$ErrorActionPreference = 'Stop'
$origen = $PSScriptRoot
$destino = [System.IO.Path]::GetFullPath($Dir)

function Copiar([string]$nombre) {
    $ruta = Join-Path $origen $nombre
    if (Test-Path -LiteralPath $ruta) {
        Copy-Item -LiteralPath $ruta -Destination $destino -Force
    }
}

Write-Host "ai-progress -> $destino"
New-Item -ItemType Directory -Force -Path $destino | Out-Null

# Programa (no se copian config.json/status.json del repo: son datos locales).
foreach ($archivo in @('ai-progress.ps1', 'ai-progress.exe', 'launch.vbs',
                       'config.example.json', 'status.example.json', 'README.md', 'uninstall.ps1')) {
    Copiar $archivo
}
$assets = Join-Path $origen 'assets'
if (Test-Path -LiteralPath $assets) {
    New-Item -ItemType Directory -Force -Path (Join-Path $destino 'assets') | Out-Null
    Copy-Item -Path (Join-Path $assets '*') -Destination (Join-Path $destino 'assets') -Force
}

# Datos: si ya existen, no se tocan.
$config = Join-Path $destino 'config.json'
if (-not (Test-Path -LiteralPath $config)) {
    Copy-Item -LiteralPath (Join-Path $destino 'config.example.json') -Destination $config
}
$status = Join-Path $destino 'status.json'
if (-not (Test-Path -LiteralPath $status)) {
    '{"tasks": []}' | Set-Content -LiteralPath $status -Encoding UTF8
}

# Acceso directo en el menu Inicio.
$exe = Join-Path $destino 'ai-progress.exe'
$ws = New-Object -ComObject WScript.Shell
$inicio = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
$lnk = Join-Path $inicio 'ai-progress.lnk'
$acceso = $ws.CreateShortcut($lnk)
$acceso.TargetPath = $exe
$acceso.WorkingDirectory = $destino
$acceso.IconLocation = "$exe,0"
$acceso.Description = 'ai-progress'
$acceso.Save()
Write-Host "acceso directo: $lnk"

if ($Desktop) {
    $lnkEscritorio = Join-Path ([Environment]::GetFolderPath('Desktop')) 'ai-progress.lnk'
    $acceso2 = $ws.CreateShortcut($lnkEscritorio)
    $acceso2.TargetPath = $exe
    $acceso2.WorkingDirectory = $destino
    $acceso2.IconLocation = "$exe,0"
    $acceso2.Description = 'ai-progress'
    $acceso2.Save()
    Write-Host "acceso directo: $lnkEscritorio"
}

# Arranque con Windows (se puede prender/apagar despues desde el menu del widget).
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ($Autostart) {
    if (-not (Test-Path $run)) { New-Item -Path $run -Force | Out-Null }
    Set-ItemProperty -Path $run -Name 'ai-progress' -Value ('"' + $exe + '"')
    Write-Host 'arranque con Windows: activado'
} else {
    Write-Host 'arranque con Windows: desactivado (se prende desde el menu del widget)'
}

$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if (-not $pwsh) {
    Write-Warning 'Falta PowerShell 7: winget install Microsoft.PowerShell'
}

if (-not $NoStart -and $pwsh) {
    Start-Process -FilePath $exe
    Write-Host 'widget iniciado'
}

Write-Host ''
Write-Host 'Listo. Para desinstalar: uninstall.ps1'
