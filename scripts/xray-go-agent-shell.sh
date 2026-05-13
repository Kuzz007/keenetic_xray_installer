#!/opt/bin/sh
set -u

CONF="/opt/etc/xray/xray-go-agent.conf"
ONCE="0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    -config) CONF="$2"; shift 2 ;;
    -once) ONCE="1"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

[ -f "$CONF" ] || { echo "config not found: $CONF" >&2; exit 1; }
. "$CONF"

POLL_INTERVAL="${POLL_INTERVAL:-5}"
ROUTER_NAME="${ROUTER_NAME:-$ROUTER_ID}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
have() { [ -x "$1" ]; }

json_escape() {
  sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' '
}

json_unescape() {
  sed 's/\\\//\//g; s/\\u0026/\&/g; s/\\u003c/</g; s/\\u003e/>/g'
}

json_get() {
  key="$1"
  sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | json_unescape
}

failover_cmd() {
  if have /opt/bin/vless-go-failover; then echo /opt/bin/vless-go-failover; return 0; fi
  if have /opt/bin/failover; then echo /opt/bin/failover; return 0; fi
  return 1
}

features() {
  out=""
  if have /opt/bin/xray-go || failover_cmd >/dev/null 2>&1; then out="$out,status,switch"; fi
  if failover_cmd >/dev/null 2>&1; then out="$out,source_update"; fi
  if have /opt/bin/xray-go || have /opt/bin/vless-go-doctor || have /opt/bin/xray-doctor; then out="$out,doctor"; fi
  if have /opt/bin/xray-go || have /opt/bin/vless-go-history || have /opt/bin/history; then out="$out,history"; fi
  if have /opt/bin/vless-go-watchdog || have /opt/bin/watchdog || [ -f /opt/var/log/vless-go-watchdog.log ]; then out="$out,watchdog"; fi
  if have /opt/bin/xray-go || have /opt/bin/vless-go-recover; then out="$out,recovery"; fi
  out="${out#,}"
  [ -n "$out" ] || out="status"
  printf '%s' "$out"
}

status_cmd() {
  if have /opt/bin/xray-go; then /opt/bin/xray-go status 2>&1; return $?; fi
  fc="$(failover_cmd 2>/dev/null || true)"
  if [ -n "$fc" ]; then "$fc" status 2>&1; return $?; fi
  echo "status command not found"
  return 1
}

short_status() {
  st="$(status_cmd 2>&1)"
  feat="$(features)"
  printf '%s\n' "$st" | grep -E 'активный слот:|health: OK|hourly recovery:|daemon: запущен|основной профиль:|резервный профиль:' | tr '\n' '; '
  printf 'features: %s' "$feat"
}

set_source() {
  slot="$1"
  selector="${2:-first}"
  source="$3"
  [ -n "$selector" ] || selector="first"
  [ -n "$source" ] || { echo "source is empty"; return 1; }
  fc="$(failover_cmd 2>/dev/null || true)"
  [ -n "$fc" ] || { echo "not found: /opt/bin/vless-go-failover or /opt/bin/failover"; return 1; }
  mkdir -p /opt/etc/xray/source-backups
  old="/opt/etc/xray/vless-go.$slot"
  if [ -s "$old" ]; then cp "$old" "/opt/etc/xray/source-backups/$(date '+%Y%m%d-%H%M%S').$slot" 2>/dev/null || true; fi
  "$fc" "set-$slot" "$source" --selector "$selector" 2>&1
}

run_action() {
  action="$1"
  selector="$2"
  source="$3"
  case "$action" in
    status|source_status) status_cmd ;;
    doctor)
      if have /opt/bin/xray-go; then /opt/bin/xray-go doctor --support 2>&1
      elif have /opt/bin/vless-go-doctor; then /opt/bin/vless-go-doctor --support 2>&1
      elif have /opt/bin/xray-doctor; then /opt/bin/xray-doctor --support 2>&1
      else echo "unsupported action on this router: $action"; return 1; fi ;;
    switch_primary)
      if have /opt/bin/xray-go; then /opt/bin/xray-go switch primary 2>&1
      else fc="$(failover_cmd 2>/dev/null || true)"; [ -n "$fc" ] && "$fc" switch primary 2>&1 || { echo "unsupported action on this router: $action"; return 1; }; fi ;;
    switch_backup)
      if have /opt/bin/xray-go; then /opt/bin/xray-go switch backup 2>&1
      else fc="$(failover_cmd 2>/dev/null || true)"; [ -n "$fc" ] && "$fc" switch backup 2>&1 || { echo "unsupported action on this router: $action"; return 1; }; fi ;;
    history)
      if have /opt/bin/xray-go; then /opt/bin/xray-go history 2>&1
      elif have /opt/bin/vless-go-history; then /opt/bin/vless-go-history 2>&1
      elif have /opt/bin/history; then /opt/bin/history 2>&1
      else echo "unsupported action on this router: $action"; return 1; fi ;;
    watchdog_log) tail -n 100 /opt/var/log/vless-go-watchdog.log 2>/dev/null || true ;;
    recovery_log) tail -n 100 /opt/var/log/vless-go-recover.log 2>/dev/null || true ;;
    recover_status|recover_check|recover_run|recover_enable|recover_disable)
      case "$action" in
        recover_status) sub="status" ;;
        recover_check) sub="check" ;;
        recover_run) sub="run" ;;
        recover_enable) sub="enable-hourly" ;;
        recover_disable) sub="disable-hourly" ;;
      esac
      if have /opt/bin/xray-go; then
        if [ "$sub" = "run" ]; then /opt/bin/xray-go recover 2>&1; else /opt/bin/xray-go recover "$sub" 2>&1; fi
      elif have /opt/bin/vless-go-recover; then
        /opt/bin/vless-go-recover "$sub" 2>&1
      else echo "unsupported action on this router: $action"; return 1; fi ;;
    set_primary_source) set_source primary "$selector" "$source" ;;
    set_backup_source) set_source backup "$selector" "$source" ;;
    *) echo "unknown action: $action"; return 1 ;;
  esac
}

post_result() {
  command_id="$1"
  ok="$2"
  output="$3"
  escaped_output="$(printf '%s' "$output" | json_escape)"
  payload='{"command_id":"'"$command_id"'","router_id":"'"$ROUTER_ID"'","ok":'"$ok"',"output":"'"$escaped_output"'"}'
  curl -fsS -H "Content-Type: application/json" -H "Authorization: Bearer $AGENT_TOKEN" -d "$payload" "${SERVER_URL%/}/agent/result" >/dev/null
}

poll_once() {
  st="$(short_status | json_escape)"
  rn="$(printf '%s' "$ROUTER_NAME" | json_escape)"
  payload='{"router_id":"'"$ROUTER_ID"'","name":"'"$rn"'","status":"'"$st"'"}'
  resp="$(curl -fsS -H "Content-Type: application/json" -H "Authorization: Bearer $AGENT_TOKEN" -d "$payload" "${SERVER_URL%/}/agent/poll" 2>&1)" || { log "poll failed: $resp"; return 1; }
  command_id="$(printf '%s' "$resp" | json_get id)"
  [ -n "$command_id" ] || return 0
  action="$(printf '%s' "$resp" | json_get action)"
  selector="$(printf '%s' "$resp" | json_get selector)"
  source="$(printf '%s' "$resp" | json_get source)"
  tmp="/tmp/xray-go-agent-shell.out.$$"
  if run_action "$action" "$selector" "$source" >"$tmp" 2>&1; then ok=true; else ok=false; fi
  out="$(cat "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"
  post_result "$command_id" "$ok" "$out" || log "result post failed"
}

log "xray-go-agent-shell started router_id=$ROUTER_ID name=$ROUTER_NAME server=$SERVER_URL"
while :; do
  poll_once || true
  [ "$ONCE" = "1" ] && exit 0
  sleep "$POLL_INTERVAL"
done
