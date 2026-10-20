#!/usr/bin/env bash
# Instalador de ai-progress para Linux (GTK3).
# Uso: ./install.sh [--autostart] [--no-start] [--dir CARPETA]
set -euo pipefail

ORIGEN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTINO="${XDG_DATA_HOME:-$HOME/.local/share}/ai-progress"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONOS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
AUTOSTART=0
ARRANCAR=1

while [ $# -gt 0 ]; do
  case "$1" in
    --autostart) AUTOSTART=1 ;;
    --no-start) ARRANCAR=0 ;;
    --dir) DESTINO="$2"; shift ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    *) echo "Opcion desconocida: $1" >&2; exit 1 ;;
  esac
  shift
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "Falta python3." >&2
  exit 1
fi
if ! python3 -c "import gi; gi.require_version('Gtk','3.0'); from gi.repository import Gtk" >/dev/null 2>&1; then
  echo "Falta PyGObject + GTK3. En Debian/Ubuntu: sudo apt install python3-gi gir1.2-gtk-3.0" >&2
  exit 1
fi

echo "ai-progress -> $DESTINO"
mkdir -p "$DESTINO" "$APPS" "$ICONOS"
cp "$ORIGEN/ai-progress-gtk.py" "$DESTINO/"
cp "$ORIGEN/config.example.json" "$ORIGEN/status.example.json" "$ORIGEN/README.md" "$DESTINO/"
cp "$ORIGEN/uninstall.sh" "$DESTINO/"
chmod +x "$DESTINO/uninstall.sh"
if [ -d "$ORIGEN/assets" ]; then
  cp -r "$ORIGEN/assets" "$DESTINO/"
fi
if [ -f "$ORIGEN/assets/ai-progress.png" ]; then
  cp "$ORIGEN/assets/ai-progress.png" "$ICONOS/ai-progress.png"
  command -v gtk-update-icon-cache >/dev/null 2>&1 && \
    gtk-update-icon-cache -q "${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor" >/dev/null 2>&1 || true
fi

# Datos propios: no se pisan si ya existen.
[ -f "$DESTINO/config.json" ] || cp "$DESTINO/config.example.json" "$DESTINO/config.json"
[ -f "$DESTINO/status.json" ] || printf '{"tasks": []}\n' > "$DESTINO/status.json"

ENTRADA="$APPS/ai-progress.desktop"
cat > "$ENTRADA" <<EOF
[Desktop Entry]
Type=Application
Name=ai-progress
Comment=Progreso de agentes de IA
Exec=/usr/bin/env python3 "$DESTINO/ai-progress-gtk.py"
Icon=ai-progress
Terminal=false
Categories=Utility;
StartupNotify=false
EOF
echo "entrada de menu: $ENTRADA"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$APPS" || true

if [ "$AUTOSTART" = "1" ]; then
  mkdir -p "$HOME/.config/autostart"
  cp "$ENTRADA" "$HOME/.config/autostart/ai-progress.desktop"
  echo "arranque al iniciar sesion: activado"
else
  echo "arranque al iniciar sesion: desactivado (se prende desde el menu del widget)"
fi

if [ "$ARRANCAR" = "1" ]; then
  if command -v setsid >/dev/null 2>&1; then
    setsid python3 "$DESTINO/ai-progress-gtk.py" >/dev/null 2>&1 &
  else
    nohup python3 "$DESTINO/ai-progress-gtk.py" >/dev/null 2>&1 &
  fi
  echo "widget iniciado"
fi

echo
echo "Listo. Para desinstalar: $DESTINO/uninstall.sh"
