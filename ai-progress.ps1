# ai-progress — Widget flotante de progreso para agentes de IA.
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
#   3) Uso de OPENCODE: tokens y costo del dia, corriendo `opencode stats --days 0 --json`
#      (se refresca cada opencodeRefreshSeconds, default 60, para no spamear el CLI).
#
# No habla con ninguna API ni manda nada: solo lee archivos locales y corre el CLI de OpenCode.
# Cerrar la ventana NO cancela nada - es un monitor.
#
# Configuracion opcional en config.json (al lado de este script):
#   { "statusPaths": ["status.json"], "opencodeCliPath": null, "opencodeRefreshSeconds": 60 }
#
# Basado en el widget claude-progress (para Claude Code), generalizado a IA en general.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---------- Config ----------
$config = @{
    statusPaths            = @((Join-Path $scriptDir 'status.json'))
    opencodeCliPath        = $null
    opencodeRefreshSeconds = 60
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
    } catch { }
}

# ---------- Colores (paleta FletAR, pensada para fondo oscuro semitransparente) ----------
$colorFondo = [System.Windows.Media.Color]::FromArgb(235, 30, 37, 48)      # #1E2530 semitransparente
# Para el screenshot del README el fondo va opaco (si no, se transparenta el escritorio).
if ($env:AI_PROGRESS_CAPTURE) { $colorFondo = [System.Windows.Media.Color]::FromArgb(255, 30, 37, 48) }
$colorBorde = [System.Windows.Media.Color]::FromArgb(255, 90, 98, 110)
$colorPrimario = [System.Windows.Media.Color]::FromRgb(0xF9, 0x73, 0x16)  # naranja FletAR
$colorTexto = [System.Windows.Media.Colors]::WhiteSmoke
$colorTextoSecundario = [System.Windows.Media.Color]::FromRgb(0x9C, 0xA3, 0xAF)
$colorOk = [System.Windows.Media.Color]::FromRgb(0x22, 0xC5, 0x5E)
$colorWarning = [System.Windows.Media.Color]::FromRgb(0xF5, 0x9E, 0x0B)
$colorDanger = [System.Windows.Media.Color]::FromRgb(0xEF, 0x44, 0x44)
$colorOpenCode = [System.Windows.Media.Color]::FromRgb(0x38, 0xBD, 0xF8)  # cyan para OpenCode

# Ruta del config principal de Claude Code (ahi cachea el uso de cuenta).
$claudeConfigPath = Join-Path $env:USERPROFILE '.claude.json'
$script:ultimoUsoConocido = $null
$script:ultimaLecturaExitosaEn = $null
$script:usoOpenCode = $null
$script:usoOpenCodeLeidoEn = $null

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

function Format-Reset($resetsAt) {
    # Parametro sin tipo a proposito: ConvertFrom-Json ya convierte strings ISO en [datetime]
    # (hora local); tipar como [string] forzaria una re-conversion dependiente de la cultura.
    if ($null -eq $resetsAt -or $resetsAt -eq '') { return $null }
    try {
        if ($resetsAt -is [datetime]) {
            $local = $resetsAt
            if ($local.Kind -eq [System.DateTimeKind]::Utc) { $local = $local.ToLocalTime() }
        } else {
            $local = [datetimeoffset]::Parse([string]$resetsAt, [System.Globalization.CultureInfo]::InvariantCulture).ToLocalTime().DateTime
        }
        if ($local.Date -eq (Get-Date).Date) {
            return "reinicia hoy a las $($local.ToString('HH:mm'))"
        }
        return "reinicia el $($local.ToString('dd/MM')) a las $($local.ToString('HH:mm'))"
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

# ================= Ventana =================
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

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$window.Left = $screen.Width - $window.Width - 20
$window.Top = 20

$borderRaiz = New-Object System.Windows.Controls.Border
$borderRaiz.Background = New-Brush $colorFondo
$borderRaiz.BorderBrush = New-Brush $colorBorde
$borderRaiz.BorderThickness = 1
$borderRaiz.CornerRadius = 10
$borderRaiz.Padding = 14
$window.Content = $borderRaiz

$panelRaiz = New-Object System.Windows.Controls.StackPanel
$borderRaiz.Child = $panelRaiz

# --- Header (arrastrable + boton de cerrar) ---
$header = New-Object System.Windows.Controls.Grid
$colTitulo = New-Object System.Windows.Controls.ColumnDefinition
$colCerrar = New-Object System.Windows.Controls.ColumnDefinition
$colCerrar.Width = 'Auto'
$header.ColumnDefinitions.Add($colTitulo)
$header.ColumnDefinitions.Add($colCerrar)

$tituloVentana = New-Object System.Windows.Controls.TextBlock
$tituloVentana.Text = "Progreso IA"
$tituloVentana.Foreground = New-Brush $colorTexto
$tituloVentana.FontWeight = 'Bold'
$tituloVentana.FontSize = 13
[System.Windows.Controls.Grid]::SetColumn($tituloVentana, 0)
$header.Children.Add($tituloVentana) | Out-Null

$cerrar = New-Object System.Windows.Controls.TextBlock
$cerrar.Text = [char]0x00D7
$cerrar.Foreground = New-Brush $colorTextoSecundario
$cerrar.FontSize = 16
$cerrar.Cursor = 'Hand'
$cerrar.Margin = '10,0,0,0'
[System.Windows.Controls.Grid]::SetColumn($cerrar, 1)
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
$panelRaiz.Children.Add((New-Separador)) | Out-Null

# --- Paneles (se reconstruyen en cada tick) ---
$panelTareas = New-Object System.Windows.Controls.StackPanel
$panelRaiz.Children.Add($panelTareas) | Out-Null
$panelRaiz.Children.Add((New-Separador)) | Out-Null

$panelClaude = New-Object System.Windows.Controls.StackPanel
$panelRaiz.Children.Add($panelClaude) | Out-Null
$panelRaiz.Children.Add((New-Separador)) | Out-Null

$panelOpenCode = New-Object System.Windows.Controls.StackPanel
$panelRaiz.Children.Add($panelOpenCode) | Out-Null

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
        $vacio = New-Object System.Windows.Controls.TextBlock
        $vacio.Text = "Sin tareas en curso."
        $vacio.Foreground = New-Brush $colorTextoSecundario
        $vacio.FontStyle = 'Italic'
        $vacio.FontSize = 11
        $vacio.Margin = '0,4,0,0'
        $panelTareas.Children.Add($vacio) | Out-Null
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
        $barra.Background = New-Brush ([System.Windows.Media.Color]::FromArgb(80, 255, 255, 255))
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

function Refrescar-UsoClaude {
    $panelClaude.Children.Clear()

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
        $sinDatos = New-Object System.Windows.Controls.TextBlock
        $sinDatos.Text = "Sin datos de uso todavia."
        $sinDatos.Foreground = New-Brush $colorTextoSecundario
        $sinDatos.FontStyle = 'Italic'
        $sinDatos.FontSize = 11
        $panelClaude.Children.Add($sinDatos) | Out-Null
        return
    }

    $aclaracion = New-Object System.Windows.Controls.TextBlock
    $aclaracion.Text = "Cache de la CLI, no se refresca sola - corre /usage en Claude de vez en cuando."
    $aclaracion.FontSize = 9
    $aclaracion.FontStyle = 'Italic'
    $aclaracion.TextWrapping = 'Wrap'
    $aclaracion.Foreground = New-Brush $colorTextoSecundario
    $aclaracion.Margin = '0,4,0,2'
    $panelClaude.Children.Add($aclaracion) | Out-Null

    $filas = @(
        @{ Etiqueta = "Sesion (5 hs)"; Porcentaje = $uso.CincoHorasPorcentaje; Reset = $uso.CincoHorasReset },
        @{ Etiqueta = "Semanal (7 dias)"; Porcentaje = $uso.SieteDiasPorcentaje; Reset = $uso.SieteDiasReset }
    )

    foreach ($fila in $filas) {
        $contenedor = New-Object System.Windows.Controls.StackPanel
        $contenedor.Margin = '0,4,0,4'

        $encabezado = New-Object System.Windows.Controls.Grid
        $colEtiqueta = New-Object System.Windows.Controls.ColumnDefinition
        $colPorcentaje = New-Object System.Windows.Controls.ColumnDefinition
        $colPorcentaje.Width = 'Auto'
        $encabezado.ColumnDefinitions.Add($colEtiqueta)
        $encabezado.ColumnDefinitions.Add($colPorcentaje)

        $etiqueta = New-Object System.Windows.Controls.TextBlock
        $etiqueta.Text = $fila.Etiqueta
        $etiqueta.Foreground = New-Brush $colorTexto
        $etiqueta.FontSize = 11
        [System.Windows.Controls.Grid]::SetColumn($etiqueta, 0)
        $encabezado.Children.Add($etiqueta) | Out-Null

        $colorBarra = Get-ColorPorPorcentaje $fila.Porcentaje
        $porcentajeTexto = New-Object System.Windows.Controls.TextBlock
        $porcentajeTexto.Text = "$($fila.Porcentaje)%"
        $porcentajeTexto.Foreground = New-Brush $colorBarra
        $porcentajeTexto.FontSize = 11
        $porcentajeTexto.FontWeight = 'Bold'
        [System.Windows.Controls.Grid]::SetColumn($porcentajeTexto, 1)
        $encabezado.Children.Add($porcentajeTexto) | Out-Null

        $contenedor.Children.Add($encabezado) | Out-Null

        $barra = New-Object System.Windows.Controls.ProgressBar
        $barra.Height = 6
        $barra.Margin = '0,3,0,2'
        $barra.Minimum = 0
        $barra.Maximum = 100
        $barra.Value = $fila.Porcentaje
        $barra.Foreground = New-Brush $colorBarra
        $barra.Background = New-Brush ([System.Windows.Media.Color]::FromArgb(80, 255, 255, 255))
        $barra.BorderThickness = 0
        $contenedor.Children.Add($barra) | Out-Null

        if ($fila.Reset) {
            $resetTexto = New-Object System.Windows.Controls.TextBlock
            $resetTexto.Text = $fila.Reset
            $resetTexto.Foreground = New-Brush $colorTextoSecundario
            $resetTexto.FontSize = 10
            $contenedor.Children.Add($resetTexto) | Out-Null
        }

        $panelClaude.Children.Add($contenedor) | Out-Null
    }
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
        $sinDatos = New-Object System.Windows.Controls.TextBlock
        $sinDatos.Text = "Sin datos: no encontre el CLI de OpenCode (config.json -> opencodeCliPath) o el servicio no responde."
        $sinDatos.Foreground = New-Brush $colorTextoSecundario
        $sinDatos.FontStyle = 'Italic'
        $sinDatos.FontSize = 10
        $sinDatos.TextWrapping = 'Wrap'
        $sinDatos.Margin = '0,4,0,0'
        $panelOpenCode.Children.Add($sinDatos) | Out-Null
        return
    }

    $sesionTxt = if ($uso.Sesiones -eq 1) { "1 sesion" } else { "$($uso.Sesiones) sesiones" }
    $promptTxt = if ($uso.Prompts -eq 1) { "1 prompt" } else { "$($uso.Prompts) prompts" }
    $pasoTxt = if ($uso.Pasos -eq 1) { "1 paso" } else { "$($uso.Pasos) pasos" }

    $linea1 = New-Object System.Windows.Controls.TextBlock
    $linea1.Text = "$sesionTxt - $promptTxt - $pasoTxt"
    $linea1.Foreground = New-Brush $colorTexto
    $linea1.FontSize = 11
    $linea1.Margin = '0,4,0,2'
    $panelOpenCode.Children.Add($linea1) | Out-Null

    $linea2 = New-Object System.Windows.Controls.TextBlock
    $linea2.Text = "Tokens: $(Format-Numero $uso.TokenIn) in - $(Format-Numero $uso.TokenOut) out - $(Format-Numero $uso.TokenCache) cache"
    $linea2.Foreground = New-Brush $colorTextoSecundario
    $linea2.FontSize = 11
    $linea2.Margin = '0,0,0,2'
    $panelOpenCode.Children.Add($linea2) | Out-Null

    $costoTxt = [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:0.00}', $uso.Costo)
    $linea3 = New-Object System.Windows.Controls.TextBlock
    $linea3.Text = "Costo: `$ $costoTxt"
    $linea3.Foreground = New-Brush $colorTextoSecundario
    $linea3.FontSize = 11
    $panelOpenCode.Children.Add($linea3) | Out-Null
}

# ================= Arranque =================
Refrescar-Tareas
Refrescar-UsoClaude
Refrescar-UsoOpenCode

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(2)
$timer.Add_Tick({
    Refrescar-Tareas
    Refrescar-UsoClaude
    Refrescar-UsoOpenCode
})
$timer.Start()

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
            $src = [System.Windows.PresentationSource]::FromVisual($window)
            $m = $src.CompositionTarget.TransformToDevice
            $ancho = [int][math]::Ceiling($window.ActualWidth * $m.M11)
            $alto = [int][math]::Ceiling($window.ActualHeight * $m.M22)
            $x = [int][math]::Round($window.Left * $m.M11)
            $y = [int][math]::Round($window.Top * $m.M22)
            $dir = Split-Path -Parent $env:AI_PROGRESS_CAPTURE
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
            $bmp = New-Object System.Drawing.Bitmap $ancho, $alto
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size)
            $bmp.Save($env:AI_PROGRESS_CAPTURE, [System.Drawing.Imaging.ImageFormat]::Png)
            $g.Dispose()
            $bmp.Dispose()
        } catch { }
        $window.Close()
    })
    $captura.Start()
}

$window.Show() | Out-Null
[System.Windows.Threading.Dispatcher]::Run()
