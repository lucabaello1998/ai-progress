#!/usr/bin/env bash
# Desinstalador de ai-progress (Linux).
# Uso: ./uninstall.sh [--todo] [--dir CARPETA]
# Por defecto conserva config.json y status.json; con --todo borra todo.
set -euo pipefail

DESTINO="${XDG_DATA_HOME:-$HOME/.local/share}/ai-progress"
APPS="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
ICONOS="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
TODO=0

while [ $# -gt 0 ]; do
  case "$1" in
    --todo) TODO=1 ;;
    --dir) DESTINO="$2"; shift ;;
    -h|--help) sed -n '2,4p' "$0"; exit 0 ;;
    *) echo "Opcion desconocida: $1" >&2; exit 1 ;;
  esac
  shift
done

pkill -f "$DESTINO/ai-progress-gtk.py" 2>/dev/null || true
rm -f "$APPS/ai-progress.desktop" "$HOME/.config/autostart/ai-progress.desktop" "$ICONOS/ai-progress.png"
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q "$APPS" || true

if [ ! -d "$DESTINO" ]; then
  echo "No hay instalacion en $DESTINO"
  exit 0
fi

if [ "$TODO" = "1" ]; then
  rm -rf "$DESTINO"
  echo "Borrado completo: $DESTINO"
else
  find "$DESTINO" -mindepth 1 -maxdepth 1 ! -name config.json ! -name status.json -exec rm -rf {} +
  echo "Programa borrado. Tus datos quedaron en: $DESTINO"
  echo "Para borrar tambien los datos: ./uninstall.sh --todo"
fi
