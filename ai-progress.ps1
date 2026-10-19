# ai-progress — Widget flotante de progreso para agentes de IA (Claude, Codex, OpenCode y más).
#
# Que muestra (siempre visible, arriba a la derecha):
#   1) TAREAS: lee un status.json (la ruta default es la de esta carpeta) que los agentes
#      mantienen al dia al lanzar tareas largas - Claude Code, OpenCode o cualquier script.
#      Soporta tres formas de progreso, por tarea:
#        - Workflow de Claude: journalPath + expectedAgents -> progreso REAL por agente
#          (linea "started"/"result" por agente) + ETA estimado con la duracion de los ya
#          terminados.
#        - Contadores: total + done -> "done/total".
#        - Porcentaje: progress (0 a 1).
#        Si no hay datos de avance: barra indeterminada + tiempo transcurrido.
#   2) Uso de CLAUDE: ventana de 5hs + limite semanal de 7 dias, leido de ~/.claude.json
#      (cachedUsageUtilization) - el mismo dato que la CLI cachea cada vez que habla con la API.
#   3) Uso de CODEX: sesiones de hoy y tokens del dia desde los logs locales
#      (~/.codex/sessions/**/rollout-*.jsonl); si el log trae rate_limits, muestra las barras
#      de 5hs / semanal tambien.
#   4) Uso de OPENCODE: tokens y costo del dia, corriendo `opencode stats --days 0 --json`
#      (se refresca cada opencodeRefreshSeconds, default 60, para no spamear el CLI).
#   5) OTROS: proveedores propios definidos en config.json -> customProviders (un comando CLI
#      o un archivo JSON que devuelva metrics con forma {sessions, prompts, steps, tokens, cost}).
#
# MENU (hamburguesa arriba a la derecha): abre un popup flotante -fondo mas oscuro, no empuja
# el contenido- con switchs para prender/apagar cada seccion y el switch "Modo claro" (tema
# dark/light). Las elecciones se guardan en config.json (sections / theme). Al final del popup
# va la leyenda "Hecho por Luca Baello".
# El boton "?" muestra la explicacion de como funciona todo, adentro del widget.
#
# No habla con ninguna API ni manda nada: solo lee archivos locales y corre CLIs ya instalados.
# Cerrar la ventana NO cancela nada - es un monitor.
#
# Configuracion opcional en config.json (al lado de este script):
#   {
#     "statusPaths": ["status.json"],
#     "sections": { "tasks": true, "claude": true, "codex": true, "opencode": true },
#     "showHelp": false,
#     "theme": "dark",
#     "opencodeCliPath": null,
#     "opencodeRefreshSeconds": 60,
#     "codexRefreshSeconds": 60,
#     "customProviders": [
#       { "id": "gemini", "name": "Gemini", "command": "gemini", "args": ["stats", "--json"] }
#     ]
#   }
#
# Basado en el widget claude-progress (para Claude Code), generalizado a IA en general.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------- Config ----------
$config = @{
    statusPaths            = @((Join-Path $scriptDir 'status.json'))
    opencodeCliPath        = $null
    opencodeRefreshSeconds = 60
    codexRefreshSeconds    = 60
    sections               = @{ tasks = $true; claude = $true; codex = $true; opencode = $true }
    showHelp               = $false
    theme                  = 'dark'
    customProviders        = @()
}
$configPath = Join-Path $scriptDir 'config.json'
if (Test-Path $configPath) {
    try {
        # Get-Content (no Read-ArchivoCompartido): esta funcion se define mas abajo.
        $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($cfg['statusPaths']) {
            $config.statusPaths = @($cfg['statusPaths'] | ForEach-Object {
                if ([System.IO.Path]::IsPathRooted([string]$_)) { [string]$_ } else { Join-Path $scriptDir ([string]$_) }
            })
        }
        if ($cfg['opencodeCliPath']) { $config.opencodeCliPath = [string]$cfg['opencodeCliPath'] }
        if ($cfg['opencodeRefreshSeconds']) { $config.opencodeRefreshSeconds = [int]$cfg['opencodeRefreshSeconds'] }
        if ($cfg['codexRefreshSeconds']) { $config.codexRefreshSeconds = [int]$cfg['codexRefreshSeconds'] }
        if ($cfg['sections']) {
            foreach ($clave in @($cfg['sections'].Keys)) { $config.sections[[string]$clave] = [bool]$cfg['sections'][$clave] }
        }
        if ($null -ne $cfg['showHelp']) { $config.showHelp = [bool]$cfg['showHelp'] }
        if (@('dark', 'light') -contains [string]$cfg['theme']) { $config.theme = [string]$cfg['theme'] }
        if ($cfg['customProviders']) {
            $config.customProviders = @($cfg['customProviders'] | Where-Object { $_['id'] -and ($_['command'] -or $_['file']) })
        }
    } catch { }
}
foreach ($prov in $config.customProviders) {
    $cid = 'custom:' + [string]$prov['id']
    if ($null -eq $config.sections[$cid]) { $config.sections[$cid] = $true }
}

# ---------- Colores ----------
# La paleta la arma Aplicar-Tema (mas abajo), segun config.theme ('dark' | 'light').
# El switch "Modo claro" del popup llama a Repintar-Tema, que la re-aplica en caliente.

# Rutas y estado interno de cada fuente.
$claudeConfigPath = Join-Path $env:USERPROFILE '.claude.json'
$codexSessionsDir = Join-Path $env:USERPROFILE '.codex\sessions'
$script:ultimoUsoConocido = $null
$script:ultimaLecturaExitosaEn = $null
$script:usoOpenCode = $null
$script:usoOpenCodeLeidoEn = $null
$script:usoCodex = $null
$script:usoCodexLeidoEn = $null
$script:customUso = @{}
$script:customLeido = @{}
$script:popupCerradoEn = [datetime]::MinValue

function New-Brush($color) { New-Object System.Windows.Media.SolidColorBrush $color }

function Read-ArchivoCompartido([string]$path) {
    # Abre con FileShare.ReadWrite: tolera leer mientras otro proceso (la CLI, un agente)
    # esta reescribiendo el archivo.
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $reader = New-Object System.IO.StreamReader($stream)
        return $reader.ReadToEnd()
    } finally {
        $stream.Dispose()
    }
}

function Format-Duracion([double]$minutos) {
    if ($minutos -lt 1) { return "menos de 1 min" }
    if ($minutos -lt 60) { return "$([math]::Round($minutos)) min" }
    $horas = [math]::Floor($minutos / 60)
    $restoMin = [math]::Round($minutos % 60)
    return "${horas}h ${restoMin}m"
}

function Format-Numero([double]$n) {
    if ($n -ge 1000000) { return "$([math]::Round($n / 1000000, 1))M" }
    if ($n -ge 1000) { return "$([math]::Round($n / 1000, 1))k" }
    return [string][int]$n
}

function Format-FechaResetLocal($local) {
    if ($local.Date -eq (Get-Date).Date) {
        return "reinicia hoy a las $($local.ToString('HH:mm'))"
    }
    return "reinicia el $($local.ToString('dd/MM')) a las $($local.ToString('HH:mm'))"
}

function Format-Reset($resetsAt) {
    # Parametro sin tipo a proposito: ConvertFrom-Json puede devolver [datetime] ya convertido
    # (ISO 8601); si viene como string se parsea con cultura invariante.
    if ($null -eq $resetsAt -or $resetsAt -eq '') { return $null }
    try {
        if ($resetsAt -is [datetime]) {
            $local = $resetsAt
            if ($local.Kind -eq [System.DateTimeKind]::Utc) { $local = $local.ToLocalTime() }
        } elseif ($resetsAt -is [datetimeoffset]) {
            $local = $resetsAt.LocalDateTime
        } else {
            $local = [datetimeoffset]::Parse([string]$resetsAt, [System.Globalization.CultureInfo]::InvariantCulture).ToLocalTime().DateTime
        }
        return Format-FechaResetLocal $local
    } catch {
        return $null
    }
}

function Format-ResetUnix($segundos) {
    # Para rate limits de Codex: resets_at viene en segundos unix.
    if ($null -eq $segundos) { return $null }
    try {
        $local = [System.DateTimeOffset]::FromUnixTimeSeconds([long]$segundos).ToLocalTime().DateTime
        return Format-FechaResetLocal $local
    } catch {
        return $null
    }
}

function Convertir-FechaLocal($valor) {
    # ConvertFrom-Json puede devolver [datetime] ya convertido (ISO 8601); si viene como
    # string se parsea con cultura invariante. Devuelve hora local o $null si no se pudo.
    # (Un [string] sobre un [datetime] intermedio usa la cultura del proceso y rompe el parseo.)
    if ($null -eq $valor -or $valor -eq '') { return $null }
    $fecha = $null
    if ($valor -is [datetime]) {
        $fecha = $valor
    } elseif ($valor -is [datetimeoffset]) {
        $fecha = $valor.LocalDateTime
    } else {
        try {
            $fecha = [datetime]::Parse([string]$valor, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        } catch {
            return $null
        }
    }
    if ($fecha.Kind -eq [System.DateTimeKind]::Utc) { $fecha = $fecha.ToLocalTime() }
    return $fecha
}

function Get-ColorPorPorcentaje([int]$porcentaje) {
    if ($porcentaje -ge 90) { return $colorDanger }
    if ($porcentaje -ge 70) { return $colorWarning }
    return $colorPrimario
}

function New-Separador {
    $sep = New-Object System.Windows.Controls.Border
    $sep.Height = 1
    $sep.Background = New-Brush $colorBorde
    $sep.Margin = '0,10,0,10'
    return $sep
}

function New-EncabezadoSeccion([string]$texto, [string]$derecha = $null, $colorDerecha = $null, $fuente = 12) {
    $grid = New-Object System.Windows.Controls.Grid
    $colIzq = New-Object System.Windows.Controls.ColumnDefinition
    $colDer = New-Object System.Windows.Controls.ColumnDefinition
    $colDer.Width = 'Auto'
    $grid.ColumnDefinitions.Add($colIzq)
    $grid.ColumnDefinitions.Add($colDer)

    $titulo = New-Object System.Windows.Controls.TextBlock
    $titulo.Text = $texto
    $titulo.Foreground = New-Brush $colorTexto
    $titulo.FontWeight = 'Bold'
    $titulo.FontSize = $fuente
    [System.Windows.Controls.Grid]::SetColumn($titulo, 0)
    $grid.Children.Add($titulo) | Out-Null

    if ($derecha) {
        $lado = New-Object System.Windows.Controls.TextBlock
        $lado.Text = $derecha
        $lado.FontSize = 9
        if ($colorDerecha) { $lado.Foreground = New-Brush $colorDerecha } else { $lado.Foreground = New-Brush $colorTextoSecundario }
        [System.Windows.Controls.Grid]::SetColumn($lado, 1)
        $grid.Children.Add($lado) | Out-Null
    }
    return $grid
}

function New-Texto([string]$texto, [double]$tamano = 11, $color = $null, [bool]$italica = $false, [string]$margen = '0,2,0,2') {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $texto
    $tb.FontSize = $tamano
    $tb.TextWrapping = 'Wrap'
    $tb.Margin = $margen
    if ($color) { $tb.Foreground = New-Brush $color } else { $tb.Foreground = New-Brush $colorTexto }
    if ($italica) { $tb.FontStyle = 'Italic' }
    return $tb
}

function Guardar-Config {
    # Persiste las preferencias de UI y los proveedores (config.json queda gitignored).
    try {
        $obj = @{
            statusPaths            = @($config.statusPaths)
            opencodeCliPath        = $config.opencodeCliPath
            opencodeRefreshSeconds = $config.opencodeRefreshSeconds
            codexRefreshSeconds    = $config.codexRefreshSeconds
            sections               = $config.sections
            showHelp               = [bool]$config.showHelp
            theme                  = [string]$config.theme
            customProviders        = @($config.customProviders)
        }
        $obj | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $configPath -Encoding UTF8
    } catch { }
}

# ---------- Tema (dark | light) ----------
function Aplicar-Tema {
    # Arma la paleta global segun config.theme. Lo que se dibuja despues (y lo que re-arma
    # Refrescar-Todo) lee estas variables, asi que cambiar de tema es re-llamar esto.
    $script:colorPrimario = [System.Windows.Media.Color]::FromRgb(0xF9, 0x73, 0x16)   # naranja FletAR
    $alphaFondo = 235
    # Para el screenshot del README el fondo va opaco (si no, se transparenta el escritorio).
    if ($env:AI_PROGRESS_CAPTURE) { $alphaFondo = 255 }

    if ($config.theme -eq 'light') {
        $script:colorFondo = [System.Windows.Media.Color]::FromArgb($alphaFondo, 246, 247, 249)  # #F6F7F9
        $script:colorBorde = [System.Windows.Media.Color]::FromRgb(203, 210, 220)
        $script:colorTexto = [System.Windows.Media.Color]::FromRgb(31, 41, 55)
        $script:colorTextoSecundario = [System.Windows.Media.Color]::FromRgb(107, 114, 128)
        $script:colorOk = [System.Windows.Media.Color]::FromRgb(21, 128, 61)
        $script:colorWarning = [System.Windows.Media.Color]::FromRgb(180, 83, 9)
        $script:colorDanger = [System.Windows.Media.Color]::FromRgb(185, 28, 28)
        $script:colorOpenCode = [System.Windows.Media.Color]::FromRgb(2, 132, 199)
        $script:colorCodex = [System.Windows.Media.Color]::FromRgb(13, 138, 106)
        $script:colorCustom = [System.Windows.Media.Color]::FromRgb(124, 58, 237)
        $script:colorBarraFondo = [System.Windows.Media.Color]::FromArgb(40, 0, 0, 0)
        $script:colorPopupFondo = [System.Windows.Media.Color]::FromRgb(255, 255, 255)
        $script:colorPopupBorde = [System.Windows.Media.Color]::FromRgb(209, 213, 219)
        $script:colorRielOff = [System.Windows.Media.Color]::FromRgb(203, 213, 225)
        $script:colorPalanca = [System.Windows.Media.Color]::FromRgb(255, 255, 255)
        $script:colorDim = [System.Windows.Media.Color]::FromRgb(148, 155, 165)
        $script:opacidadSombra = 0.25
    } else {
        $script:colorFondo = [System.Windows.Media.Color]::FromArgb($alphaFondo, 30, 37, 48)     # #1E2530
        $script:colorBorde = [System.Windows.Media.Color]::FromRgb(90, 98, 110)
        $script:colorTexto = [System.Windows.Media.Colors]::WhiteSmoke
        $script:colorTextoSecundario = [System.Windows.Media.Color]::FromRgb(0x9C, 0xA3, 0xAF)
        $script:colorOk = [System.Windows.Media.Color]::FromRgb(0x22, 0xC5, 0x5E)
        $script:colorWarning = [System.Windows.Media.Color]::FromRgb(0xF5, 0x9E, 0x0B)
        $script:colorDanger = [System.Windows.Media.Color]::FromRgb(0xEF, 0x44, 0x44)
        $script:colorOpenCode = [System.Windows.Media.Color]::FromRgb(0x38, 0xBD, 0xF8)
        $script:colorCodex = [System.Windows.Media.Color]::FromRgb(0x10, 0xA3, 0x7F)
        $script:colorCustom = [System.Windows.Media.Color]::FromRgb(0xA7, 0x8B, 0xFA)
        $script:colorBarraFondo = [System.Windows.Media.Color]::FromArgb(80, 255, 255, 255)
        $script:colorPopupFondo = [System.Windows.Media.Color]::FromRgb(0x11, 0x15, 0x1C)
        $script:colorPopupBorde = [System.Windows.Media.Color]::FromRgb(0x3A, 0x42, 0x50)
        $script:colorRielOff = [System.Windows.Media.Color]::FromRgb(70, 78, 90)
        $script:colorPalanca = [System.Windows.Media.Color]::FromRgb(240, 240, 240)
        $script:colorDim = [System.Windows.Media.Color]::FromRgb(110, 118, 130)
        $script:opacidadSombra = 0.6
    }
}

function Repintar-Tema {
    # Cambio de tema en caliente: repinta el chrome fijo (ventana, header, popup). El contenido
    # de las secciones lo redibuja quien llama al handler (Refrescar-Todo).
    Aplicar-Tema
    $borderRaiz.Background = New-Brush $colorFondo
    $borderRaiz.BorderBrush = New-Brush $colorBorde
    $tituloVentana.Foreground = New-Brush $colorTexto
    if ($config.showHelp) { $botonAyuda.Foreground = New-Brush $colorPrimario } else { $botonAyuda.Foreground = New-Brush $colorTextoSecundario }
    $cerrar.Foreground = New-Brush $colorTextoSecundario
    $marcoPopup.Background = New-Brush $colorPopupFondo
    $marcoPopup.BorderBrush = New-Brush $colorPopupBorde
    $sombraPopup.Opacity = $opacidadSombra
    foreach ($lineaMenu in $lineasHamburguesa.Children) {
        if ($popup.IsOpen) { $lineaMenu.Background = New-Brush $colorPrimario } else { $lineaMenu.Background = New-Brush $colorTextoSecundario }
    }
}

Aplicar-Tema

# ================= Ventana =================
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

$window = New-Object System.Windows.Window
$window.Title = "Progreso IA"
$window.WindowStyle = 'None'
$window.AllowsTransparency = $true
$window.Background = [System.Windows.Media.Brushes]::Transparent
$window.Topmost = $true
$window.ShowInTaskbar = $false
$window.ResizeMode = 'NoResize'
$window.SizeToContent = 'Height'
$window.Width = 380
$window.Left = $screen.Width - $window.Width - 20
$window.Top = 20

$borderRaiz = New-Object System.Windows.Controls.Border
$borderRaiz.Background = New-Brush $colorFondo
$borderRaiz.BorderBrush = New-Brush $colorBorde
$borderRaiz.BorderThickness = 1
$borderRaiz.CornerRadius = 10
$borderRaiz.Padding = 14

# ScrollViewer: si hay muchas secciones prendidas (o la ayuda abierta), no se sale de pantalla.
$scroll = New-Object System.Windows.Controls.ScrollViewer
$scroll.VerticalScrollBarVisibility = 'Auto'
$scroll.HorizontalScrollBarVisibility = 'Disabled'
$scroll.MaxHeight = $screen.Height - 70
$borderRaiz.Child = $scroll
$window.Content = $borderRaiz

$panelRaiz = New-Object System.Windows.Controls.StackPanel
$scroll.Content = $panelRaiz

# --- Header (arrastrable: hamburguesa + ayuda + cerrar, todo centrado verticalmente) ---
$header = New-Object System.Windows.Controls.Grid
$colTitulo = New-Object System.Windows.Controls.ColumnDefinition
$colMenu = New-Object System.Windows.Controls.ColumnDefinition
$colMenu.Width = 'Auto'
$colAyuda = New-Object System.Windows.Controls.ColumnDefinition
$colAyuda.Width = 'Auto'
$colCerrar = New-Object System.Windows.Controls.ColumnDefinition
$colCerrar.Width = 'Auto'
$header.ColumnDefinitions.Add($colTitulo)
$header.ColumnDefinitions.Add($colMenu)
$header.ColumnDefinitions.Add($colAyuda)
$header.ColumnDefinitions.Add($colCerrar)

$tituloVentana = New-Object System.Windows.Controls.TextBlock
$tituloVentana.Text = "Progreso IA"
$tituloVentana.Foreground = New-Brush $colorTexto
$tituloVentana.FontWeight = 'Bold'
$tituloVentana.FontSize = 13
$tituloVentana.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($tituloVentana, 0)
$header.Children.Add($tituloVentana) | Out-Null

# Menu hamburguesa: 3 lineas dibujadas (no depende de glifos de la fuente).
$botonMenu = New-Object System.Windows.Controls.Border
$botonMenu.Background = [System.Windows.Media.Brushes]::Transparent
$botonMenu.Cursor = 'Hand'
$botonMenu.Margin = '12,0,0,0'
$botonMenu.Padding = '2'
$botonMenu.VerticalAlignment = 'Center'
$lineasHamburguesa = New-Object System.Windows.Controls.StackPanel
foreach ($i in 1..3) {
    $lineaMenu = New-Object System.Windows.Controls.Border
    $lineaMenu.Width = 14
    $lineaMenu.Height = 2
    $lineaMenu.Background = New-Brush $colorTextoSecundario
    if ($i -lt 3) { $lineaMenu.Margin = '0,0,0,3' }
    $lineasHamburguesa.Children.Add($lineaMenu) | Out-Null
}
$botonMenu.Child = $lineasHamburguesa
[System.Windows.Controls.Grid]::SetColumn($botonMenu, 1)
# Down solo evita que el header arrastre la ventana; el toggle del popup va en Up: con
# StaysOpen=false, abrir el popup con el mouse todavia apretado hace que el mismo click lo
# cierre al instante. Ademas se difiere la apertura al dispatcher: se abre cuando el evento
# de click ya termino del todo.
$botonMenu.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
})
$botonMenu.Add_MouseLeftButtonUp({
    param($s, $e)
    $e.Handled = $true
    if ($popup.IsOpen) { $popup.IsOpen = $false; return }
    # Si el popup se acaba de cerrar con este mismo click, no reabrirlo por rebote.
    if (((Get-Date) - $script:popupCerradoEn).TotalMilliseconds -lt 250) { return }
    $s.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{
        Actualizar-Menu
        # Alineado a la derecha del boton (el marco tiene 12px de margen para la sombra).
        $popup.HorizontalOffset = [double]$botonMenu.ActualWidth - ($marcoPopup.Width + 24)
        $popup.VerticalOffset = -6
        $popup.IsOpen = $true
    }) | Out-Null
})
$header.Children.Add($botonMenu) | Out-Null

$botonAyuda = New-Object System.Windows.Controls.TextBlock
$botonAyuda.Text = "?"
$botonAyuda.FontSize = 13
$botonAyuda.FontWeight = 'Bold'
$botonAyuda.Cursor = 'Hand'
$botonAyuda.Margin = '12,0,0,0'
$botonAyuda.VerticalAlignment = 'Center'
if ($config.showHelp) { $botonAyuda.Foreground = New-Brush $colorPrimario } else { $botonAyuda.Foreground = New-Brush $colorTextoSecundario }
[System.Windows.Controls.Grid]::SetColumn($botonAyuda, 2)
$botonAyuda.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $config.showHelp = -not [bool]$config.showHelp
    Guardar-Config
    if ($config.showHelp) { $s.Foreground = New-Brush $colorPrimario } else { $s.Foreground = New-Brush $colorTextoSecundario }
    Refrescar-Todo
})
$header.Children.Add($botonAyuda) | Out-Null

$cerrar = New-Object System.Windows.Controls.TextBlock
$cerrar.Text = [char]0x00D7
$cerrar.Foreground = New-Brush $colorTextoSecundario
$cerrar.FontSize = 15
$cerrar.Cursor = 'Hand'
$cerrar.Margin = '12,0,0,0'
$cerrar.VerticalAlignment = 'Center'
[System.Windows.Controls.Grid]::SetColumn($cerrar, 3)
$cerrar.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $window.Close()
})
$header.Children.Add($cerrar) | Out-Null

$header.Cursor = 'SizeAll'
$header.Add_MouseLeftButtonDown({
    param($s, $e)
    if (-not $e.Handled) { $window.DragMove() }
})
$panelRaiz.Children.Add($header) | Out-Null

# --- Popup del menu (flota sobre el contenido; fondo mas oscuro para distinguir las opciones) ---
$popup = New-Object System.Windows.Controls.Primitives.Popup
$popup.PlacementTarget = $botonMenu
$popup.Placement = 'Bottom'
$popup.StaysOpen = $false
$popup.AllowsTransparency = $true

$marcoPopup = New-Object System.Windows.Controls.Border
$marcoPopup.Width = 212
$marcoPopup.Margin = '12'
$marcoPopup.CornerRadius = 10
$marcoPopup.Background = New-Brush $colorPopupFondo
$marcoPopup.BorderBrush = New-Brush $colorPopupBorde
$marcoPopup.BorderThickness = 1
$marcoPopup.Padding = '12,8,12,10'
$sombraPopup = New-Object System.Windows.Media.Effects.DropShadowEffect
$sombraPopup.BlurRadius = 12
$sombraPopup.ShadowDepth = 0
$sombraPopup.Opacity = $opacidadSombra
$sombraPopup.Color = [System.Windows.Media.Colors]::Black
$marcoPopup.Effect = $sombraPopup

$panelPopup = New-Object System.Windows.Controls.StackPanel
$marcoPopup.Child = $panelPopup
$popup.Child = $marcoPopup

$popup.Add_Opened({
    foreach ($lineaMenu in $lineasHamburguesa.Children) { $lineaMenu.Background = New-Brush $colorPrimario }
})
$popup.Add_Closed({
    $script:popupCerradoEn = Get-Date
    foreach ($lineaMenu in $lineasHamburguesa.Children) { $lineaMenu.Background = New-Brush $colorTextoSecundario }
})

# --- Secciones: cada contenedor arranca con su separador, asi al ocultarlo desaparece todo ---
function New-ContenedorSeccion {
    $cont = New-Object System.Windows.Controls.StackPanel
    $cont.Children.Add((New-Separador)) | Out-Null
    $panel = New-Object System.Windows.Controls.StackPanel
    $cont.Children.Add($panel) | Out-Null
    $cont.Tag = $panel
    return $cont
}

$contTareas = New-ContenedorSeccion
$panelTareas = $contTareas.Tag
$panelRaiz.Children.Add($contTareas) | Out-Null

$contClaude = New-ContenedorSeccion
$panelClaude = $contClaude.Tag
$panelRaiz.Children.Add($contClaude) | Out-Null

$contCodex = New-ContenedorSeccion
$panelCodex = $contCodex.Tag
$panelRaiz.Children.Add($contCodex) | Out-Null

$contOpenCode = New-ContenedorSeccion
$panelOpenCode = $contOpenCode.Tag
$panelRaiz.Children.Add($contOpenCode) | Out-Null

$contCustom = New-ContenedorSeccion
$panelCustom = $contCustom.Tag
$panelRaiz.Children.Add($contCustom) | Out-Null

$contAyuda = New-ContenedorSeccion
$panelAyuda = $contAyuda.Tag
$panelRaiz.Children.Add($contAyuda) | Out-Null

function Set-Visible($contenedor, [bool]$visible) {
    if ($visible) { $contenedor.Visibility = 'Visible' } else { $contenedor.Visibility = 'Collapsed' }
}

# ================= Tareas =================
function Get-ProgresoJournal([string]$journalPath) {
    $resultado = [PSCustomObject]@{ Completados = 0; Duraciones = @(); EnVuelo = @() }
    if (-not (Test-Path $journalPath)) { return $resultado }

    $journalDir = Split-Path -Parent $journalPath
    $pendientes = @{}
    $completadosCount = 0
    $duraciones = @()

    try {
        $lineas = Get-Content -LiteralPath $journalPath -ErrorAction Stop
    } catch {
        return $resultado
    }

    foreach ($linea in $lineas) {
        if ([string]::IsNullOrWhiteSpace($linea)) { continue }
        try { $evento = $linea | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        if (-not $evento.key) { continue }

        if ($evento.type -eq 'started') {
            $pendientes[$evento.key] = $evento.agentId
        } elseif ($evento.type -eq 'result') {
            $agentId = $evento.agentId
            $pendientes.Remove($evento.key)
            $completadosCount++

            $jsonlPath = Join-Path $journalDir "agent-$agentId.jsonl"
            $metaPath = Join-Path $journalDir "agent-$agentId.meta.json"
            if ((Test-Path $jsonlPath) -and (Test-Path $metaPath)) {
                try {
                    $fin = (Get-Item -LiteralPath $jsonlPath).LastWriteTime
                    $inicio = (Get-Item -LiteralPath $metaPath).CreationTime
                    $duracionMin = ($fin - $inicio).TotalMinutes
                    if ($duracionMin -gt 0) { $duraciones += $duracionMin }
                } catch {}
            }
        }
    }

    $enVuelo = @()
    foreach ($agentId in $pendientes.Values) {
        $metaPath = Join-Path $journalDir "agent-$agentId.meta.json"
        if (Test-Path $metaPath) {
            try {
                $inicio = (Get-Item -LiteralPath $metaPath).CreationTime
                $enVuelo += ((Get-Date) - $inicio).TotalMinutes
            } catch {}
        }
    }

    $resultado.Completados = $completadosCount
    $resultado.Duraciones = $duraciones
    $resultado.EnVuelo = $enVuelo
    return $resultado
}

function Get-EtaMinutos([int]$esperados, [int]$completados, [double[]]$duraciones, [double[]]$enVuelo) {
    # ETA con la duracion real de los agentes YA terminados (no el total transcurrido:
    # una pausa larga inflaria el promedio sin limite).
    if (-not $duraciones -or $duraciones.Count -eq 0) { return $null }
    $promedio = ($duraciones | Measure-Object -Average).Average

    $noIniciados = $esperados - $completados - $enVuelo.Count
    if ($noIniciados -lt 0) { $noIniciados = 0 }

    $etaEnVuelo = 0
    if ($enVuelo.Count -gt 0) {
        $maxTranscurrido = ($enVuelo | Measure-Object -Maximum).Maximum
        $etaEnVuelo = [math]::Max($promedio - $maxTranscurrido, $promedio * 0.15)
    }

    return $etaEnVuelo + ($noIniciados * $promedio)
}

function Refrescar-Tareas {
    $panelTareas.Children.Clear()
    Set-Visible $contTareas ([bool]$config.sections.tasks)
    if (-not $config.sections.tasks) { return }

    $tareas = @()
    foreach ($ruta in $config.statusPaths) {
        if (-not (Test-Path $ruta)) { continue }
        try {
            $datos = Read-ArchivoCompartido $ruta | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $datos -and $null -ne $datos.tasks) { $tareas += @($datos.tasks) }
        } catch { }
    }

    $activas = @($tareas | Where-Object { $_.status -ne 'done' -and $_.status -ne 'error' }).Count
    $panelTareas.Children.Add((New-EncabezadoSeccion "Tareas" "$activas activas" $null 12)) | Out-Null

    if ($tareas.Count -eq 0) {
        $panelTareas.Children.Add((New-Texto "Sin tareas en curso." 11 $colorTextoSecundario $true '0,4,0,0')) | Out-Null
        return
    }

    foreach ($tarea in $tareas) {
        $fila = New-Object System.Windows.Controls.StackPanel
        $fila.Margin = '0,6,0,6'

        $nombre = New-Object System.Windows.Controls.TextBlock
        $nombre.Text = [string]$tarea.name
        $nombre.Foreground = New-Brush $colorTexto
        $nombre.FontSize = 12
        $nombre.TextWrapping = 'Wrap'
        $fila.Children.Add($nombre) | Out-Null

        $completados = 0
        $tieneJournal = $false
        $duraciones = @()
        $enVuelo = @()
        if ($tarea.journalPath) {
            $tieneJournal = $true
            $progreso = Get-ProgresoJournal ([string]$tarea.journalPath)
            $completados = $progreso.Completados
            $duraciones = $progreso.Duraciones
            $enVuelo = $progreso.EnVuelo
        }

        $esperados = 0
        if ($tarea.expectedAgents) { $esperados = [int]$tarea.expectedAgents }
        $total = 0
        if ($tarea.total) { $total = [int]$tarea.total }
        $hechos = 0
        if ($null -ne $tarea.done) { $hechos = [int]$tarea.done }

        $barra = New-Object System.Windows.Controls.ProgressBar
        $barra.Height = 8
        $barra.Margin = '0,5,0,4'
        $barra.Foreground = New-Brush $colorPrimario
        $barra.Background = New-Brush $colorBarraFondo
        $barra.BorderThickness = 0

        $estado = [string]$tarea.status
        if ($estado -eq 'done') {
            $barra.IsIndeterminate = $false
            $barra.Minimum = 0; $barra.Maximum = 1; $barra.Value = 1
            $barra.Foreground = New-Brush $colorOk
        } elseif ($estado -eq 'error') {
            $barra.IsIndeterminate = $false
            $barra.Minimum = 0; $barra.Maximum = 1; $barra.Value = 1
            $barra.Foreground = New-Brush $colorDanger
        } elseif ($tieneJournal -and $esperados -gt 0) {
            $barra.IsIndeterminate = $false
            $barra.Minimum = 0
            $barra.Maximum = $esperados
            $barra.Value = [math]::Min($completados, $esperados)
        } elseif ($total -gt 0) {
            $barra.IsIndeterminate = $false
            $barra.Minimum = 0
            $barra.Maximum = $total
            $barra.Value = [math]::Min($hechos, $total)
        } elseif ($null -ne $tarea.progress) {
            $barra.IsIndeterminate = $false
            $barra.Minimum = 0; $barra.Maximum = 1
            $barra.Value = [math]::Max(0, [math]::Min(1, [double]$tarea.progress))
        } else {
            $barra.IsIndeterminate = $true
        }
        $fila.Children.Add($barra) | Out-Null

        $detalle = New-Object System.Windows.Controls.TextBlock
        $detalle.Foreground = New-Brush $colorTextoSecundario
        $detalle.FontSize = 11
        $detalle.TextWrapping = 'Wrap'

        if ($estado -eq 'done') {
            $detalle.Text = "Listo"
            $detalle.Foreground = New-Brush $colorOk
        } elseif ($estado -eq 'error') {
            $detalle.Text = "Error"
            $detalle.Foreground = New-Brush $colorDanger
        } else {
            $elapsedMin = 0
            $inicio = Convertir-FechaLocal $tarea.startedAt
            if ($null -ne $inicio) { $elapsedMin = ((Get-Date) - $inicio).TotalMinutes }

            if ($tieneJournal -and $esperados -gt 0) {
                $texto = "$completados/$esperados agentes"
                $restantes = $esperados - $completados
                if ($restantes -le 0) {
                    $texto += " - terminando..."
                } else {
                    $etaMin = Get-EtaMinutos $esperados $completados $duraciones $enVuelo
                    if ($null -ne $etaMin) {
                        $texto += " - ~$(Format-Duracion $etaMin) restantes (estimado)"
                    } else {
                        $texto += " - estimando tiempo..."
                    }
                }
                $detalle.Text = $texto
            } elseif ($total -gt 0) {
                $detalle.Text = "$hechos/$total - hace $(Format-Duracion $elapsedMin)"
            } elseif ($null -ne $tarea.progress) {
                $pct = [math]::Round([double]$tarea.progress * 100)
                $detalle.Text = "$pct% - hace $(Format-Duracion $elapsedMin)"
            } else {
                $detalle.Text = "En progreso - hace $(Format-Duracion $elapsedMin)"
            }
        }
        $fila.Children.Add($detalle) | Out-Null

        if ($tarea.detail) {
            $extra = New-Object System.Windows.Controls.TextBlock
            $extra.Text = [string]$tarea.detail
            $extra.Foreground = New-Brush $colorTextoSecundario
            $extra.FontSize = 10
            $extra.FontStyle = 'Italic'
            $extra.TextWrapping = 'Wrap'
            $fila.Children.Add($extra) | Out-Null
        }

        $panelTareas.Children.Add($fila) | Out-Null
    }
}

# ================= Uso de Claude =================
function Get-UsoClaudeGeneral {
    if (-not (Test-Path $claudeConfigPath)) { return $script:ultimoUsoConocido }
    try {
        # -AsHashtable: el config tiene rutas de proyecto como claves que difieren solo en
        # mayus/minus (C:/ vs c:/) y el modo objeto normal falla por claves "duplicadas".
        $contenido = Read-ArchivoCompartido $claudeConfigPath
        $cfgClaude = $contenido | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        $util = $cfgClaude.cachedUsageUtilization.utilization
        if ($null -eq $util) { return $script:ultimoUsoConocido }

        $edadDatoSegundos = $null
        if ($cfgClaude.cachedUsageUtilization.fetchedAtMs) {
            $fetchedAtMs = [double]$cfgClaude.cachedUsageUtilization.fetchedAtMs
            $ahoraMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $edadDatoSegundos = ($ahoraMs - $fetchedAtMs) / 1000
        }

        $resultado = [PSCustomObject]@{
            CincoHorasPorcentaje = [int]$util.five_hour.utilization
            CincoHorasReset      = Format-Reset $util.five_hour.resets_at
            SieteDiasPorcentaje  = [int]$util.seven_day.utilization
            SieteDiasReset       = Format-Reset $util.seven_day.resets_at
            EdadDatoSegundos     = $edadDatoSegundos
        }
        $script:ultimoUsoConocido = $resultado
        $script:ultimaLecturaExitosaEn = Get-Date
        return $resultado
    } catch {
        return $script:ultimoUsoConocido
    }
}

function New-FilaBarra($etiqueta, [int]$porcentaje, $reset, $color) {
    $contenedor = New-Object System.Windows.Controls.StackPanel
    $contenedor.Margin = '0,4,0,4'

    $encabezado = New-Object System.Windows.Controls.Grid
    $colEtiqueta = New-Object System.Windows.Controls.ColumnDefinition
    $colPorcentaje = New-Object System.Windows.Controls.ColumnDefinition
    $colPorcentaje.Width = 'Auto'
    $encabezado.ColumnDefinitions.Add($colEtiqueta)
    $encabezado.ColumnDefinitions.Add($colPorcentaje)

    $tbEtiqueta = New-Object System.Windows.Controls.TextBlock
    $tbEtiqueta.Text = $etiqueta
    $tbEtiqueta.Foreground = New-Brush $colorTexto
    $tbEtiqueta.FontSize = 11
    [System.Windows.Controls.Grid]::SetColumn($tbEtiqueta, 0)
    $encabezado.Children.Add($tbEtiqueta) | Out-Null

    $tbPorcentaje = New-Object System.Windows.Controls.TextBlock
    $tbPorcentaje.Text = "$porcentaje%"
    $tbPorcentaje.Foreground = New-Brush $color
    $tbPorcentaje.FontSize = 11
    $tbPorcentaje.FontWeight = 'Bold'
    [System.Windows.Controls.Grid]::SetColumn($tbPorcentaje, 1)
    $encabezado.Children.Add($tbPorcentaje) | Out-Null

    $contenedor.Children.Add($encabezado) | Out-Null

    $barra = New-Object System.Windows.Controls.ProgressBar
    $barra.Height = 6
    $barra.Margin = '0,3,0,2'
    $barra.Minimum = 0
    $barra.Maximum = 100
    $barra.Value = $porcentaje
    $barra.Foreground = New-Brush $color
    $barra.Background = New-Brush $colorBarraFondo
    $barra.BorderThickness = 0
    $contenedor.Children.Add($barra) | Out-Null

    if ($reset) {
        $tbReset = New-Object System.Windows.Controls.TextBlock
        $tbReset.Text = $reset
        $tbReset.Foreground = New-Brush $colorTextoSecundario
        $tbReset.FontSize = 10
        $contenedor.Children.Add($tbReset) | Out-Null
    }
    return $contenedor
}

function Refrescar-UsoClaude {
    $panelClaude.Children.Clear()
    Set-Visible $contClaude ([bool]$config.sections.claude)
    if (-not $config.sections.claude) { return }

    $uso = Get-UsoClaudeGeneral

    # Dos edades distintas: (a) cuando leyo ESTE script, (b) que tan vieja es la foto que la
    # propia CLI guardo (puede quedar minutos atras de lo que muestra el chat).
    $textoEdad = $null
    $colorEdad = $colorTextoSecundario
    if ($null -eq $uso) {
        $textoEdad = "sin datos"
    } elseif ($null -eq $uso.EdadDatoSegundos) {
        $textoEdad = "edad del dato desconocida"
    } else {
        $edadMin = $uso.EdadDatoSegundos / 60
        if ($uso.EdadDatoSegundos -lt 60) {
            $textoEdad = "dato de hace $([math]::Round($uso.EdadDatoSegundos))s"
            $colorEdad = $colorOk
        } elseif ($edadMin -lt 5) {
            $textoEdad = "dato de hace $(Format-Duracion $edadMin)"
        } else {
            $textoEdad = "dato de hace $(Format-Duracion $edadMin) (puede ir atras)"
            $colorEdad = $colorWarning
        }
    }
    $panelClaude.Children.Add((New-EncabezadoSeccion "Uso - Claude" $textoEdad $colorEdad 12)) | Out-Null

    if ($null -eq $uso) {
        $panelClaude.Children.Add((New-Texto "Sin datos de uso todavia." 11 $colorTextoSecundario $true)) | Out-Null
        return
    }

    $panelClaude.Children.Add((New-Texto "Cache de la CLI, no se refresca sola - corre /usage en Claude de vez en cuando." 9 $colorTextoSecundario $true '0,4,0,2')) | Out-Null

    $panelClaude.Children.Add((New-FilaBarra "Sesion (5 hs)" $uso.CincoHorasPorcentaje $uso.CincoHorasReset (Get-ColorPorPorcentaje $uso.CincoHorasPorcentaje))) | Out-Null
    $panelClaude.Children.Add((New-FilaBarra "Semanal (7 dias)" $uso.SieteDiasPorcentaje $uso.SieteDiasReset (Get-ColorPorPorcentaje $uso.SieteDiasPorcentaje))) | Out-Null
}

# ================= Uso de Codex =================
function Get-UsoCodex {
    if ($null -ne $script:usoCodexLeidoEn -and
        ((Get-Date) - $script:usoCodexLeidoEn).TotalSeconds -lt $config.codexRefreshSeconds) {
        return $script:usoCodex
    }
    $script:usoCodexLeidoEn = Get-Date
    $script:usoCodex = $null
    if (-not (Test-Path $codexSessionsDir)) { return $script:usoCodex }

    # Cada sesion de Codex es un rollout-*.jsonl; el ultimo evento token_count de cada archivo
    # trae el acumulado de ESA sesion (total_token_usage) y, si la version lo guarda, los
    # rate limits (5 hs / semanal). Se suman los archivos modificados hoy.
    $hoy = (Get-Date).Date
    $archivos = @(Get-ChildItem -LiteralPath $codexSessionsDir -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $hoy })

    $input = 0.0; $cache = 0.0; $output = 0.0; $razonamiento = 0.0
    $rate5 = $null; $rate7 = $null; $reset5 = $null; $reset7 = $null
    foreach ($f in $archivos) {
        try {
            $texto = $null
            $tail = @(Get-Content -LiteralPath $f.FullName -Tail 600 -ErrorAction Stop)
            for ($i = $tail.Count - 1; $i -ge 0; $i--) {
                if ($tail[$i] -match '"token_count"') { $texto = $tail[$i]; break }
            }
            if (-not $texto -and $f.Length -lt 25MB) {
                $m = Select-String -LiteralPath $f.FullName -Pattern '"token_count"' -ErrorAction SilentlyContinue | Select-Object -Last 1
                if ($m) { $texto = $m.Line }
            }
            if (-not $texto) { continue }
            $ev = $texto | ConvertFrom-Json -ErrorAction Stop
            $tu = $ev.payload.info.total_token_usage
            if ($tu) {
                $input += [double]$tu.input_tokens
                $cache += [double]$tu.cached_input_tokens
                $output += [double]$tu.output_tokens
                $razonamiento += [double]$tu.reasoning_output_tokens
            }
            $rl = $ev.payload.rate_limits
            if ($rl) {
                if ($null -ne $rl.primary.used_percent) { $rate5 = [int][math]::Round([double]$rl.primary.used_percent) }
                if ($null -ne $rl.secondary.used_percent) { $rate7 = [int][math]::Round([double]$rl.secondary.used_percent) }
                if ($null -ne $rl.primary.resets_at) { $reset5 = Format-ResetUnix $rl.primary.resets_at }
                if ($null -ne $rl.secondary.resets_at) { $reset7 = Format-ResetUnix $rl.secondary.resets_at }
            }
        } catch { }
    }

    $script:usoCodex = [PSCustomObject]@{
        Sesiones     = $archivos.Count
        TokenIn      = $input
        TokenCache   = $cache
        TokenOut     = $output
        Razonamiento = $razonamiento
        Rate5        = $rate5
        Rate7        = $rate7
        Reset5       = $reset5
        Reset7       = $reset7
    }
    return $script:usoCodex
}

function Refrescar-UsoCodex {
    $panelCodex.Children.Clear()
    Set-Visible $contCodex ([bool]$config.sections.codex)
    if (-not $config.sections.codex) { return }

    $textoEdad = $null
    if ($null -ne $script:usoCodexLeidoEn) {
        $seg = ((Get-Date) - $script:usoCodexLeidoEn).TotalSeconds
        if ($seg -lt 90) { $textoEdad = "actualizado hace $([math]::Round($seg))s" }
        else { $textoEdad = "actualizado hace $(Format-Duracion ($seg / 60))" }
    } else {
        $textoEdad = "sin datos"
    }
    $panelCodex.Children.Add((New-EncabezadoSeccion "Uso - Codex (hoy)" $textoEdad $colorCodex 12)) | Out-Null

    $uso = Get-UsoCodex
    if ($null -eq $uso) {
        $panelCodex.Children.Add((New-Texto "No encontre sesiones de Codex (~/.codex/sessions)." 11 $colorTextoSecundario $true)) | Out-Null
        return
    }
    if ($uso.Sesiones -eq 0) {
        $panelCodex.Children.Add((New-Texto "Sin sesiones de Codex hoy." 11 $colorTextoSecundario $true)) | Out-Null
        return
    }

    if ($null -ne $uso.Rate5) {
        $panelCodex.Children.Add((New-FilaBarra "Sesion (5 hs)" $uso.Rate5 $uso.Reset5 (Get-ColorPorPorcentaje $uso.Rate5))) | Out-Null
    }
    if ($null -ne $uso.Rate7) {
        $panelCodex.Children.Add((New-FilaBarra "Semanal (7 dias)" $uso.Rate7 $uso.Reset7 (Get-ColorPorPorcentaje $uso.Rate7))) | Out-Null
    }

    $sesionTxt = if ($uso.Sesiones -eq 1) { "1 sesion" } else { "$($uso.Sesiones) sesiones" }
    $panelCodex.Children.Add((New-Texto $sesionTxt 11 $colorTexto $false '0,4,0,2')) | Out-Null
    $lineaTokens = "Tokens: $(Format-Numero $uso.TokenIn) in"
    if ($uso.TokenCache -gt 0) { $lineaTokens += " ($(Format-Numero $uso.TokenCache) cache)" }
    $lineaTokens += " - $(Format-Numero $uso.TokenOut) out"
    if ($uso.Razonamiento -gt 0) { $lineaTokens += " - $(Format-Numero $uso.Razonamiento) razonamiento" }
    $panelCodex.Children.Add((New-Texto $lineaTokens 11 $colorTextoSecundario)) | Out-Null
}

# ================= Uso de OpenCode =================
function Get-RutaOpenCodeCli {
    if ($config.opencodeCliPath -and (Test-Path ([string]$config.opencodeCliPath))) { return [string]$config.opencodeCliPath }
    $candidatos = @(
        (Join-Path $env:USERPROFILE 'bin\opencode.exe')
    )
    foreach ($c in $candidatos) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    $cmd = Get-Command opencode -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $cliDir = Join-Path $env:APPDATA 'ai.opencode.desktop\cli'
    if (Test-Path $cliDir) {
        $exe = Get-ChildItem $cliDir -Recurse -Filter 'opencode-cli.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($exe) { return $exe.FullName }
    }
    return $null
}

function Get-UsoOpenCode {
    if ($null -ne $script:usoOpenCodeLeidoEn -and
        ((Get-Date) - $script:usoOpenCodeLeidoEn).TotalSeconds -lt $config.opencodeRefreshSeconds) {
        return $script:usoOpenCode
    }
    $cli = Get-RutaOpenCodeCli
    if (-not $cli) { $script:usoOpenCodeLeidoEn = Get-Date; return $script:usoOpenCode }
    try {
        $json = & $cli stats --days 0 --json 2>$null | Out-String
        $j = $json | ConvertFrom-Json -ErrorAction Stop
        $script:usoOpenCode = [PSCustomObject]@{
            Sesiones     = [int]$j.sessions
            Prompts      = [int]$j.prompts
            Pasos        = [int]$j.steps
            TokenIn      = [double]$j.tokens.input
            TokenOut     = [double]$j.tokens.output
            TokenCache   = [double]$j.tokens.cache.read + [double]$j.tokens.cache.write
            Razonamiento = [double]$j.tokens.reasoning
            Costo        = [double]$j.cost
        }
        $script:usoOpenCodeLeidoEn = Get-Date
    } catch {
        $script:usoOpenCodeLeidoEn = Get-Date
    }
    return $script:usoOpenCode
}

function Refrescar-UsoOpenCode {
    $panelOpenCode.Children.Clear()
    Set-Visible $contOpenCode ([bool]$config.sections.opencode)
    if (-not $config.sections.opencode) { return }

    $uso = Get-UsoOpenCode

    $textoEdad = $null
    if ($null -ne $script:usoOpenCodeLeidoEn) {
        $seg = ((Get-Date) - $script:usoOpenCodeLeidoEn).TotalSeconds
        if ($seg -lt 90) { $textoEdad = "actualizado hace $([math]::Round($seg))s" }
        else { $textoEdad = "actualizado hace $(Format-Duracion ($seg / 60))" }
    } else {
        $textoEdad = "sin datos"
    }
    $panelOpenCode.Children.Add((New-EncabezadoSeccion "Uso - OpenCode (hoy)" $textoEdad $colorOpenCode 12)) | Out-Null

    if ($null -eq $uso) {
        $panelOpenCode.Children.Add((New-Texto "Sin datos: no encontre el CLI de OpenCode (config.json -> opencodeCliPath) o el servicio no responde." 10 $colorTextoSecundario $true '0,4,0,0')) | Out-Null
        return
    }

    $sesionTxt = if ($uso.Sesiones -eq 1) { "1 sesion" } else { "$($uso.Sesiones) sesiones" }
    $promptTxt = if ($uso.Prompts -eq 1) { "1 prompt" } else { "$($uso.Prompts) prompts" }
    $pasoTxt = if ($uso.Pasos -eq 1) { "1 paso" } else { "$($uso.Pasos) pasos" }

    $panelOpenCode.Children.Add((New-Texto "$sesionTxt - $promptTxt - $pasoTxt" 11 $colorTexto $false '0,4,0,2')) | Out-Null
    $panelOpenCode.Children.Add((New-Texto "Tokens: $(Format-Numero $uso.TokenIn) in - $(Format-Numero $uso.TokenOut) out - $(Format-Numero $uso.TokenCache) cache" 11 $colorTextoSecundario)) | Out-Null
    $costoTxt = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.00}', $uso.Costo)
    $panelOpenCode.Children.Add((New-Texto "Costo: `$ $costoTxt" 11 $colorTextoSecundario)) | Out-Null
}

# ================= Proveedores propios (config.json -> customProviders) =================
function Get-UsoProviderCustom($prov) {
    # Cada proveedor custom tiene: id, name, y o bien command (+args) que devuelve JSON por
    # stdout, o bien file (un JSON local). El JSON acepta: sessions, prompts, steps,
    # tokens {input, output, cache {read, write}}, cost.
    $id = [string]$prov['id']
    $refresh = 60
    if ($prov['refreshSeconds']) { $refresh = [int]$prov['refreshSeconds'] }
    if ($script:customLeido[$id] -and ((Get-Date) - $script:customLeido[$id]).TotalSeconds -lt $refresh) {
        return $script:customUso[$id]
    }
    $script:customLeido[$id] = Get-Date
    try {
        $json = $null
        if ($prov['file']) {
            $rutaArchivo = [string]$prov['file']
            if (-not [System.IO.Path]::IsPathRooted($rutaArchivo)) { $rutaArchivo = Join-Path $scriptDir $rutaArchivo }
            $json = Read-ArchivoCompartido $rutaArchivo
        } else {
            $argsProv = @()
            if ($prov['args']) { $argsProv = @($prov['args']) }
            $json = & ([string]$prov['command']) @argsProv 2>$null | Out-String
        }
        $j = $json | ConvertFrom-Json -ErrorAction Stop
        $script:customUso[$id] = [PSCustomObject]@{
            Sesiones   = [int]$j.sessions
            Prompts    = [int]$j.prompts
            Pasos      = [int]$j.steps
            TokenIn    = [double]$j.tokens.input
            TokenOut   = [double]$j.tokens.output
            TokenCache = [double]$j.tokens.cache.read + [double]$j.tokens.cache.write
            Costo      = [double]$j.cost
        }
    } catch {
        $script:customUso[$id] = $null
    }
    return $script:customUso[$id]
}

function Refrescar-ProvidersCustom {
    $panelCustom.Children.Clear()
    $visibles = @($config.customProviders | Where-Object { [bool]$config.sections['custom:' + [string]$_['id']] })
    Set-Visible $contCustom ($visibles.Count -gt 0)
    if ($visibles.Count -eq 0) { return }

    foreach ($prov in $visibles) {
        $id = [string]$prov['id']
        $nombre = $id
        if ($prov['name']) { $nombre = [string]$prov['name'] }
        $uso = Get-UsoProviderCustom $prov

        $textoEdad = $null
        if ($script:customLeido[$id] -and $null -ne $uso) {
            $seg = ((Get-Date) - $script:customLeido[$id]).TotalSeconds
            if ($seg -lt 90) { $textoEdad = "actualizado hace $([math]::Round($seg))s" }
            else { $textoEdad = "actualizado hace $(Format-Duracion ($seg / 60))" }
        }
        $panelCustom.Children.Add((New-EncabezadoSeccion "Uso - $nombre (hoy)" $textoEdad $colorCustom 12)) | Out-Null

        if ($null -eq $uso) {
            $panelCustom.Children.Add((New-Texto "Sin datos: revisa command/file y args del proveedor en config.json." 10 $colorTextoSecundario $true '0,4,0,0')) | Out-Null
            continue
        }
        $detalle = @()
        if ($uso.Sesiones -or $uso.Prompts -or $uso.Pasos) {
            $detalle += "$($uso.Sesiones) sesiones - $($uso.Prompts) prompts - $($uso.Pasos) pasos"
        }
        if ($uso.TokenIn -or $uso.TokenOut -or $uso.TokenCache) {
            $detalle += "Tokens: $(Format-Numero $uso.TokenIn) in - $(Format-Numero $uso.TokenOut) out - $(Format-Numero $uso.TokenCache) cache"
        }
        if ($uso.Costo -gt 0) {
            $costoTxt = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.00}', $uso.Costo)
            $detalle += "Costo: `$ $costoTxt"
        }
        if ($detalle.Count -eq 0) { $detalle += "Sin metricas para hoy." }
        foreach ($l in $detalle) {
            $panelCustom.Children.Add((New-Texto $l 11 $colorTextoSecundario)) | Out-Null
        }
    }
}

# ================= Ayuda =================
function Refrescar-Ayuda {
    $panelAyuda.Children.Clear()
    Set-Visible $contAyuda ([bool]$config.showHelp)
    if (-not $config.showHelp) { return }

    $panelAyuda.Children.Add((New-EncabezadoSeccion "Como funciona" $null $null 12)) | Out-Null
    $lineas = @(
        '· Tareas: los agentes escriben status.json al lanzar tareas largas. Si la tarea trae journalPath, se cuenta 1 linea por agente ("started"/"result") y el ETA usa la duracion real de los agentes YA terminados.'
        '· Claude: lee el cache de uso que la CLI deja en ~/.claude.json. No se refresca solo: corre /usage en Claude de vez en cuando.'
        '· Codex: suma los tokens del dia desde las sesiones locales (~/.codex/sessions/<fecha>/*.jsonl) y, si el log los trae, muestra los limites de 5 hs / semanal.'
        '· OpenCode: corre `opencode stats --days 0 --json` cada 60 segundos.'
        '· Otros modelos: se agregan en config.json -> customProviders, con un comando CLI (command + args) o un archivo JSON (file). Deben devolver: sessions, tokens {input, output, cache}, cost.'
        '· El menu hamburguesa de arriba (a la derecha) abre un popup con switchs para prender y apagar cada seccion, y el switch "Modo claro" para cambiar el tema; todo se guarda en config.json. Al final del popup esta la leyenda del autor.'
        '· Todo es local: el widget no manda nada a ninguna API; solo lee archivos y corre CLIs ya instalados.'
    )
    foreach ($l in $lineas) {
        $panelAyuda.Children.Add((New-Texto $l 10 $colorTextoSecundario $false '0,3,0,3')) | Out-Null
    }
}

# ================= Menu de secciones (hamburguesa) =================
$seccionesMenu = @(
    @{ id = 'tasks'; nombre = 'Tareas' },
    @{ id = 'claude'; nombre = 'Claude' },
    @{ id = 'codex'; nombre = 'Codex' },
    @{ id = 'opencode'; nombre = 'OpenCode' }
)
foreach ($prov in $config.customProviders) {
    if ($prov['id'] -and $prov['name']) {
        $seccionesMenu += @{ id = 'custom:' + [string]$prov['id']; nombre = [string]$prov['name'] }
    }
}

# El handler lee el id desde el Tag de la fila: un scriptblock por fila capturaria mal la
# variable del loop (en PowerShell los closures comparten la variable del foreach).
$filaMenuHandler = {
    param($s, $e)
    $sid = [string]$s.Tag
    if ($sid -eq 'theme') {
        # La fila del tema no es una seccion: alterna la paleta y repinta en caliente.
        $config.theme = if ($config.theme -eq 'light') { 'dark' } else { 'light' }
        Guardar-Config
        Repintar-Tema
    } else {
        $config.sections[$sid] = -not [bool]$config.sections[$sid]
        Guardar-Config
    }
    Actualizar-Menu
    Refrescar-Todo
}

function New-FilaMenu($sec) {
    # Fila del menu: nombre + switch on/off; toda la fila es clickeable. La fila 'theme' (Modo
    # claro) no es una seccion: su estado sale de config.theme.
    $fila = New-Object System.Windows.Controls.Grid
    $fila.Tag = $sec.id
    $fila.Cursor = 'Hand'
    if ($sec.margen) { $fila.Margin = $sec.margen } else { $fila.Margin = '0,4,0,4' }
    $colNombre = New-Object System.Windows.Controls.ColumnDefinition
    $colSwitch = New-Object System.Windows.Controls.ColumnDefinition
    $colSwitch.Width = 'Auto'
    $fila.ColumnDefinitions.Add($colNombre)
    $fila.ColumnDefinitions.Add($colSwitch)

    if ($sec.id -eq 'theme') {
        $activo = ($config.theme -eq 'light')
    } else {
        $activo = [bool]$config.sections[[string]$sec.id]
    }

    $nombre = New-Object System.Windows.Controls.TextBlock
    $nombre.Text = $sec.nombre
    $nombre.FontSize = 11
    $nombre.VerticalAlignment = 'Center'
    if ($activo) { $nombre.Foreground = New-Brush $colorTexto } else { $nombre.Foreground = New-Brush $colorTextoSecundario }
    [System.Windows.Controls.Grid]::SetColumn($nombre, 0)
    $fila.Children.Add($nombre) | Out-Null

    $riel = New-Object System.Windows.Controls.Border
    $riel.Width = 30
    $riel.Height = 16
    $riel.CornerRadius = 8
    if ($activo) { $riel.Background = New-Brush $colorPrimario } else { $riel.Background = New-Brush $colorRielOff }
    $riel.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($riel, 1)

    $palanca = New-Object System.Windows.Controls.Border
    $palanca.Width = 12
    $palanca.Height = 12
    $palanca.CornerRadius = 6
    $palanca.Background = New-Brush $colorPalanca
    $palanca.Margin = '2'
    if ($activo) { $palanca.HorizontalAlignment = 'Right' } else { $palanca.HorizontalAlignment = 'Left' }
    $riel.Child = $palanca
    $fila.Children.Add($riel) | Out-Null

    $fila.Add_MouseLeftButtonDown($filaMenuHandler)
    return $fila
}

function Actualizar-Menu {
    # Reconstruye el contenido del popup (switchs + leyenda). El color de la hamburguesa lo
    # manejan los eventos Opened/Closed del popup.
    $panelPopup.Children.Clear()
    foreach ($sec in $seccionesMenu) {
        $panelPopup.Children.Add((New-FilaMenu $sec)) | Out-Null
    }
    # Fila del tema, separada de las secciones (no prende/apaga nada: cambia la paleta).
    $panelPopup.Children.Add((New-FilaMenu @{ id = 'theme'; nombre = 'Modo claro'; margen = '0,10,0,4' })) | Out-Null
    $panelPopup.Children.Add((New-Separador)) | Out-Null
    $leyenda = New-Object System.Windows.Controls.TextBlock
    $leyenda.Text = "Hecho por Luca Baello"
    $leyenda.FontSize = 10
    $leyenda.Foreground = New-Brush $colorTextoSecundario
    $leyenda.HorizontalAlignment = 'Center'
    $leyenda.Margin = '0,0,0,1'
    $panelPopup.Children.Add($leyenda) | Out-Null
    $repo = New-Object System.Windows.Controls.TextBlock
    $repo.Text = "github.com/lucabaello1998/ai-progress"
    $repo.FontSize = 9
    $repo.Foreground = New-Brush $colorDim
    $repo.HorizontalAlignment = 'Center'
    $panelPopup.Children.Add($repo) | Out-Null
}

# ================= Refresco total =================
function Refrescar-Todo {
    Refrescar-Tareas
    Refrescar-UsoClaude
    Refrescar-UsoCodex
    Refrescar-UsoOpenCode
    Refrescar-ProvidersCustom
    Refrescar-Ayuda
}

Actualizar-Menu
Refrescar-Todo

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    Refrescar-Todo
})
$timer.Start()

# Captura del README: AI_PROGRESS_CAPTURE_MENU=1 abre el popup del menu a los 0.8s.
if ($env:AI_PROGRESS_CAPTURE_MENU) {
    $abrirMenuCaptura = New-Object System.Windows.Threading.DispatcherTimer
    $abrirMenuCaptura.Interval = [TimeSpan]::FromMilliseconds(800)
    $abrirMenuCaptura.Add_Tick({
        $abrirMenuCaptura.Stop()
        Actualizar-Menu
        $popup.HorizontalOffset = [double]$botonMenu.ActualWidth - ($marcoPopup.Width + 24)
        $popup.VerticalOffset = -6
        $popup.IsOpen = $true
    })
    $abrirMenuCaptura.Start()
}

$window.Add_Closed({
    $timer.Stop()
    # Sin una Application WPF, cerrar la ventana no termina el dispatcher: se apaga a mano
    # para que el proceso salga limpio (si no, queda un pwsh invisible vivo).
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

# Modo captura (para el screenshot del README): AI_PROGRESS_CAPTURE=<ruta.png> ->
# se autofotografia a los 2s y se cierra. No se usa en el uso normal.
if ($env:AI_PROGRESS_CAPTURE) {
    $captura = New-Object System.Windows.Threading.DispatcherTimer
    $captura.Interval = [TimeSpan]::FromSeconds(2)
    $captura.Add_Tick({
        $captura.Stop()
        try {
            # PointToScreen convierte DIPs a pixeles con el DPI real: evita que la region
            # capturada se corra si la pantalla no esta al 100%.
            $p1 = $window.PointToScreen([System.Windows.Point]::new(0, 0))
            $p2 = $window.PointToScreen([System.Windows.Point]::new($window.ActualWidth, $window.ActualHeight))
            $ancho = [int][math]::Ceiling($p2.X - $p1.X)
            $alto = [int][math]::Ceiling($p2.Y - $p1.Y)
            $x = [int][math]::Round($p1.X)
            $y = [int][math]::Round($p1.Y)
            $dir = Split-Path -Parent $env:AI_PROGRESS_CAPTURE
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
            $bmp = New-Object System.Drawing.Bitmap $ancho, $alto
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
            $bmp.Save($env:AI_PROGRESS_CAPTURE, [System.Drawing.Imaging.ImageFormat]::Png)
            $logTxt = "Actual=$($window.ActualWidth)x$($window.ActualHeight) Left=$($window.Left) Top=$($window.Top) p1=($($p1.X),$($p1.Y)) p2=($($p2.X),$($p2.Y)) crop=${ancho}x${alto}"
            Set-Content -LiteralPath ($env:AI_PROGRESS_CAPTURE + '.log') -Value $logTxt -Encoding UTF8
            $g.Dispose()
            $bmp.Dispose()
        } catch { }
        $window.Close()
    })
    $captura.Start()
}

$window.Show() | Out-Null
[System.Windows.Threading.Dispatcher]::Run()
