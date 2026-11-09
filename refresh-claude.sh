#!/bin/zsh
# Renueva el login de Claude Code abriendo claude una vez y cerrándolo.
# Lo llama DeskWidgets cuando no puede renovar el token por su cuenta.
# Usa la suscripción, no ANTHROPIC_API_KEY, para no cobrar por API.
export PATH=/opt/homebrew/bin:/usr/local/bin:$PATH
LOG=/tmp/dw-usage.log
command -v claude >/dev/null || { echo "$(date -u) refresh-claude: claude not found" >> $LOG; exit 1; }
# claude refresca el token OAuth antes de llamar a la API; un prompt mínimo con Haiku basta
cd /tmp
env -u ANTHROPIC_API_KEY claude -p "ok" --model haiku >/dev/null 2>&1 &
pid=$!
( sleep 90; kill $pid 2>/dev/null ) &
watchdog=$!
wait $pid; rc=$?
kill $watchdog 2>/dev/null
echo "$(date -u) refresh-claude: exit $rc" >> $LOG
