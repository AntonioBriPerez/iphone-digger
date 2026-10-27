#!/bin/bash
# Installs the Python side of iPhone Digger (pymobiledevice3) in a private venv the app finds on its own.
set -euo pipefail

VENV="$HOME/Library/Application Support/iPhoneDigger/venv"
PYTHON="${PYTHON:-python3}"

if ! "$PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
  echo "Hace falta Python 3.10 o superior (por ejemplo: brew install python)." >&2
  exit 1
fi

echo "→ Creando entorno en $VENV"
"$PYTHON" -m venv "$VENV"
"$VENV/bin/python3" -m pip install --quiet --upgrade pip
echo "→ Instalando pymobiledevice3"
"$VENV/bin/python3" -m pip install --quiet --upgrade pymobiledevice3
"$VENV/bin/python3" -c 'import pymobiledevice3, importlib.metadata as m; print("✓ pymobiledevice3", m.version("pymobiledevice3"))'
echo "Listo. Abre iPhone Digger."
