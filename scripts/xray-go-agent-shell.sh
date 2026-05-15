#!/opt/bin/sh
set -u

CONF="/opt/etc/xray/xray-go-agent.conf"
ONCE="0"
SLOT_STATE_FILE="${SLOT_STATE_FILE:-/opt/var/run/xray-go-agent-shell.last-slot}"

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
exists() { [ -e "$1" ]; }

json_escape() {
  LC_ALL=C tr '\r\n\t' '   ' | LC_ALL=C tr -d '\000-\010\013\014\016-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
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

minimal_mode() {
  exists /opt/etc/xray/minimal-go-active || have /opt/bin/minimal-go-status || have /opt/bin/minimal-go-switch || [ -x /opt/etc/init.d/S25xray-minimal-go-failover ]
}

normalize_selector() {
  sel="$(printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$sel" ] || { printf '%s' "first"; return 0; }
  case "$sel" in
    first|index:*) printf '%s' "$sel"; return 0 ;;
    *[!0-9]*) printf '%s' "$sel"; return 0 ;;
    *) printf 'index:%s' "$sel"; return 0 ;;
  esac
}

features() {
  out=""
  if have /opt/bin/xray-go || failover_cmd >/dev/null 2>&1 || minimal_mode; then out="$out,status"; fi
  if have /opt/bin/xray-go || failover_cmd >/dev/null 2>&1 || have /opt/bin/minimal-go-switch; then out="$out,switch"; fi
  if failover_cmd >/dev/null 2>&1 || have /opt/bin/minimal-go-update; then out="$out,source_update"; fi
  if have /opt/bin/xray-go || have /opt/bin/vless-go-doctor || have /opt/bin/xray-doctor || minimal_mode; then out="$out,doctor"; fi
  if have /opt/bin/xray-go || have /opt/bin/vless-go-history || have /opt/bin/history || exists /opt/var/log/minimal-go-switch-history.log; then out="$out,history"; fi
  if have /opt/bin/vless-go-watchdog || have /opt/bin/watchdog || exists /opt/var/log/vless-go-watchdog.log || exists /opt/var/log/xray-minimal-go-failover.log; then out="$out,watchdog"; fi
  if have /opt/bin/xray-go || have /opt/bin/vless-go-recover; then out="$out,recovery"; fi
  if command -v reboot >/dev/null 2>&1; then out="$out,reboot"; fi
  out="${out#,}"
  [ -n "$out" ] || out="status"
  printf '%s' "$out"
}

status_cmd() {
  if have /opt/bin/xray-go; then /opt/bin/xray-go status 2>&1; return $?; fi
  fc="$(failover_cmd 2>/dev/null || true)"
  if [ -n "$fc" ]; then "$fc" status 2>&1; return $?; fi
  if have /opt/bin/minimal-go-status; then /opt/bin/minimal-go-status 2>&1; return $?; fi
  if have /opt/bin/vless-go-recover; then /opt/bin/vless-go-recover --mode minimal status 2>&1; return $?; fi
  echo "status command not found"
  return 1
}

active_slot() {
  if [ -s /opt/etc/xray/minimal-go-active ]; then sed -n '1p' /opt/etc/xray/minimal-go-active; return 0; fi
  if [ -s /opt/etc/xray/vless-go.active ]; then sed -n '1p' /opt/etc/xray/vless-go.active; return 0; fi
  status_cmd 2>/dev/null | sed -n 's/.*active slot:[[:space:]]*//p; s/.*active:[[:space:]]*//p; s/.*активный слот:[[:space:]]*//p' | head -n 1
}

short_status() {
  st="$(status_cmd 2>&1)"
  feat="$(features)"
  printf '%s\n' "$st" | grep -E 'active:|active slot:|активный слот:|health: OK|hourly recovery:|cron: running|crond: running|daemon: запущен|основной профиль:|резервный профиль:' | tr '\n' '; '
  printf 'features: %s' "$feat"
}

set_source() {
  slot="$1"
  selector="$(normalize_selector "${2:-}")"
  source="$3"
  [ -n "$source" ] || { echo "source is empty"; return 1; }
  mkdir -p /opt/etc/xray/source-backups
  if minimal_mode && have /opt/bin/minimal-go-update; then
    old="/opt/etc/xray/minimal-go-$slot.url"
    if [ -s "$old" ]; then cp "$old" "/opt/etc/xray/source-backups/$(date '+%Y%m%d-%H%M%S').minimal-$slot" 2>/dev/null || true; fi
    /opt/bin/minimal-go-update "$slot" "$source" 2>&1
    return $?
  fi
  fc="$(failover_cmd 2>/dev/null || true)"
  [ -n "$fc" ] || { echo "not found: minimal-go-update, /opt/bin/vless-go-failover or /opt/bin/failover"; return 1; }
  old="/opt/etc/xray/vless-go.$slot"
  if [ -s "$old" ]; then cp "$old" "/opt/etc/xray/source-backups/$(date '+%Y%m%d-%H%M%S').$slot" 2>/dev/null || true; fi
  "$fc" "set-$slot" "$source" --selector "$selector" 2>&1
}

minimal_doctor() {
  echo "== Minimal Go status =="
  status_cmd 2>&1 || true
  if have /opt/bin/vless-go-recover; then
    echo
    echo "== Recovery =="
    /opt/bin/vless-go-recover --mode minimal status 2>&1 || true
  fi
  echo
  echo "== Services =="
  [ -x /opt/etc/init.d/S24xray ] && /opt/etc/init.d/S24xray status 2>&1 || true
  [ -x /opt/etc/init.d/S25xray-minimal-go-failover ] && /opt/etc/init.d/S25xray-minimal-go-failover status 2>&1 || true
}

doctor_cmd() {
  if minimal_mode; then minimal_doctor; return $?; fi
  if have /opt/bin/xray-go; then /opt/bin/xray-go doctor --support 2>&1 || /opt/bin/xray-go doctor 2>&1; return $?; fi
  if have /opt/bin/vless-go-doctor; then /opt/bin/vless-go-doctor 2>&1; return $?; fi
  if have /opt/bin/xray-doctor; then /opt/bin/xray-doctor --support 2>&1 || /opt/bin/xray-doctor 2>&1; return $?; fi
  echo "unsupported action on this router: doctor"
  return 1
}

switch_cmd() {
  slot="$1"
  if have /opt/bin/xray-go; then /opt/bin/xray-go switch "$slot" 2>&1; return $?; fi
  fc="$(failover_cmd 2>/dev/null || true)"
  if [ -n "$fc" ]; then "$fc" switch "$slot" 2>&1; return $?; fi
  if have /opt/bin/minimal-go-switch; then /opt/bin/minimal-go-switch "$slot" 2>&1; return $?; fi
  echo "unsupported switch on this router"
  return 1
}

history_cmd() {
  if have /opt/bin/xray-go; then /opt/bin/xray-go history 2>&1; return $?; fi
  if have /opt/bin/vless-go-history; then /opt/bin/vless-go-history 2>&1; return $?; fi
  if have /opt/bin/history; then /opt/bin/history 2>&1; return $?; fi
  if exists /opt/var/log/minimal-go-switch-history.log; then tail -n 100 /opt/var/log/minimal-go-switch-history.log 2>/dev/null || true; return 0; fi
  echo "unsupported history on this router"
  return 1
}

watchdog_log() {
  if exists /opt/var/log/vless-go-watchdog.log; then tail -n 100 /opt/var/log/vless-go-watchdog.log 2>/dev/null || true; return 0; fi
  if exists /opt/var/log/xray-minimal-go-failover.log; then tail -n 100 /opt/var/log/xray-minimal-go-failover.log 2>/dev/null || true; return 0; fi
  echo "watchdog log not found"
  return 1
}

recovery_log() {
  if exists /opt/var/log/vless-go-recover.log; then tail -n 100 /opt/var/log/vless-go-recover.log 2>/dev/null || true; return 0; fi
  if exists /opt/var/log/xray-minimal-go-failover.log; then tail -n 100 /opt/var/log/xray-minimal-go-failover.log 2>/dev/null || true; return 0; fi
  echo "recovery log not found"
  return 1
}

recover_cmd() {
  sub="$1"
  if have /opt/bin/xray-go; then
    if [ "$sub" = "run" ]; then /opt/bin/xray-go recover 2>&1; else /opt/bin/xray-go recover "$sub" 2>&1; fi
    return $?
  fi
  if have /opt/bin/vless-go-recover; then
    mode="full"
    minimal_mode && mode="minimal"
    /opt/bin/vless-go-recover --mode "$mode" "$sub" 2>&1
    return $?
  fi
  echo "unsupported recovery on this router"
  return 1
}

run_action() {
  action="$1"
  selector="$2"
  source="$3"
  case "$action" in
    status|source_status) status_cmd ;;
    doctor) doctor_cmd ;;
    switch_primary) switch_cmd primary ;;
    switch_backup) switch_cmd backup ;;
    history) history_cmd ;;
    watchdog_log) watchdog_log ;;
    recovery_log) recovery_log ;;
    recover_status) recover_cmd status ;;
    recover_check) recover_cmd check ;;
    recover_run) recover_cmd run ;;
    recover_enable) recover_cmd enable-hourly ;;
    recover_disable) recover_cmd disable-hourly ;;
    set_primary_source) set_source primary "$selector" "$source" ;;
    set_backup_source) set_source backup "$selector" "$source" ;;
    reboot)
      echo "Router reboot scheduled by control bot. Agent will disconnect now."
      ( sleep 2; reboot ) >/dev/null 2>&1 &
      return 0 ;;
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

notify_startup() {
  msg="Router started. Agent online. name=$ROUTER_NAME id=$ROUTER_ID features=$(features)"
  post_result "agent_start" true "$msg" || log "startup notification failed"
}

check_slot_change() {
  slot="$(active_slot | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -n "$slot" ] || return 0
  mkdir -p "$(dirname "$SLOT_STATE_FILE")" 2>/dev/null || true
  if [ ! -s "$SLOT_STATE_FILE" ]; then
    printf '%s\n' "$slot" > "$SLOT_STATE_FILE" 2>/dev/null || true
    return 0
  fi
  old="$(sed -n '1p' "$SLOT_STATE_FILE" 2>/dev/null | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ "$old" = "$slot" ] && return 0
  printf '%s\n' "$slot" > "$SLOT_STATE_FILE" 2>/dev/null || true
  msg="Active slot changed on $ROUTER_NAME ($ROUTER_ID): $old -> $slot"
  post_result "slot_change" true "$msg" || log "slot change notification failed: $old -> $slot"
}

poll_once() {
  check_slot_change
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
  check_slot_change
}

log "xray-go-agent-shell started router_id=$ROUTER_ID name=$ROUTER_NAME server=$SERVER_URL"
notify_startup
check_slot_change
while :; do
  poll_once || true
  [ "$ONCE" = "1" ] && exit 0
  sleep "$POLL_INTERVAL"
done
