#!/opt/bin/sh
set -u

QUIET="0"
LOG="${LOG:-/opt/var/log/xray-go-agent-watchdog.log}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet|-q) QUIET="1"; shift ;;
    -h|--help|help) echo "Usage: xray-go-agent-watchdog [--quiet]"; exit 0 ;;
    *) echo "ERROR: unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line" >> "$LOG"
  [ "$QUIET" = "1" ] || printf '%s\n' "$line"
}

alive() {
  init="$1"
  [ -x "$init" ] || return 1
  "$init" status 2>&1 | grep -qi 'alive\|running'
}

check_service() {
  init="$1"
  name="$2"
  [ -x "$init" ] || return 2
  if alive "$init"; then
    [ "$QUIET" = "1" ] || log "$name alive"
    return 0
  fi
  log "$name not alive; starting"
  "$init" restart >/dev/null 2>&1 || "$init" start >/dev/null 2>&1 || true
  sleep 2
  if alive "$init"; then log "$name recovered"; else log "$name still not alive"; fi
}

if [ -x /opt/etc/init.d/S28xray-go-agent-shell ]; then
  check_service /opt/etc/init.d/S28xray-go-agent-shell xray-go-agent-shell
elif [ -x /opt/etc/init.d/S28xray-go-agent ]; then
  check_service /opt/etc/init.d/S28xray-go-agent xray-go-agent
else
  log "no agent init service found"
fi
