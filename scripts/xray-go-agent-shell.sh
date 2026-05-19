#!/opt/bin/sh
set -u

CONF="/opt/etc/xray/xray-go-agent.conf"
ONCE="0"
AGENT_VERSION="0.1.4-shell-experimental"
SLOT_STATE_FILE="${SLOT_STATE_FILE:-/opt/var/run/xray-go-agent-shell.last-slot}"
UPDATE_SCRIPTS_LOG="/opt/var/log/xray-go-update-scripts.log"
RESULT_LOG="/opt/var/log/xray-go-agent-result.log"
ROUTES_CATALOG_URL="https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-keenetic-routes-catalog.sh"
ROUTES_CATALOG_PATH="/opt/bin/xray-keenetic-routes-catalog"
FEATURES_CACHE=""
CAPABILITIES_CACHE=""

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
result_log() { mkdir -p /opt/var/log 2>/dev/null || true; echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$RESULT_LOG" 2>/dev/null || true; }
have() { [ -x "$1" ]; }
exists() { [ -e "$1" ]; }

clean_output() {
  sed 's/\x1b\[[0-9;]*[A-Za-z]//g; s/\[[0-9][0-9;]*m//g; s/\[m//g' | LC_ALL=C tr -d '\000-\010\013\014\016-\037'
}

json_escape() {
  clean_output | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\n/\\n/g;s/\r//g;s/\t/  /g'
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
  if exists "$RESULT_LOG" || [ -d /opt/var/log ]; then out="$out,agent_log"; fi
  if command -v reboot >/dev/null 2>&1; then out="$out,reboot"; fi
  out="$out,update_scripts,update_agent"
  [ -x "$ROUTES_CATALOG_PATH" ] && out="$out,routes_catalog"
  out="${out#,}"
  [ -n "$out" ] || out="status"
  printf '%s' "$out"
}

has_feature_in() {
  feature_list="$1"
  feature="$2"
  case ",$feature_list," in
    *,"$feature",*) return 0 ;;
    *) return 1 ;;
  esac
}

has_feature() {
  feature_list="${FEATURES_CACHE:-}"
  [ -n "$feature_list" ] || feature_list="$(features)"
  has_feature_in "$feature_list" "$1"
}

capabilities_from_features() {
  feature_list="$1"
  out="agent_start,slot_change"
  has_feature_in "$feature_list" status && out="$out,status,source_status"
  has_feature_in "$feature_list" switch && out="$out,switch_primary,switch_backup"
  has_feature_in "$feature_list" source_update && out="$out,set_primary_source,set_backup_source"
  has_feature_in "$feature_list" doctor && out="$out,doctor"
  has_feature_in "$feature_list" history && out="$out,history"
  has_feature_in "$feature_list" watchdog && out="$out,watchdog_log,recovery_log"
  has_feature_in "$feature_list" recovery && out="$out,recover_status,recover_check,recover_run,recover_enable,recover_disable"
  has_feature_in "$feature_list" agent_log && out="$out,agent_result_log"
  has_feature_in "$feature_list" reboot && out="$out,reboot"
  has_feature_in "$feature_list" update_scripts && out="$out,update_scripts"
  has_feature_in "$feature_list" update_agent && out="$out,update_agent"
  has_feature_in "$feature_list" routes_catalog && out="$out,routes_list,routes_preview,routes_apply,routes_apply_custom,routes_remove"
  printf '%s' "$out"
}

capabilities() {
  if [ -n "${CAPABILITIES_CACHE:-}" ]; then
    printf '%s' "$CAPABILITIES_CACHE"
    return 0
  fi
  capabilities_from_features "$(features)"
}

refresh_feature_cache() {
  FEATURES_CACHE="$(features)"
  CAPABILITIES_CACHE="$(capabilities_from_features "$FEATURES_CACHE")"
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
  feat="${FEATURES_CACHE:-$(features)}"
  caps="${CAPABILITIES_CACHE:-$(capabilities_from_features "$feat") }"
  caps="$(printf '%s' "$caps" | sed 's/[[:space:]]*$//')"
  printf '%s\n' "$st" | grep -E 'active:|active slot:|активный слот:|health: OK|hourly recovery:|cron: running|crond: running|daemon: запущен|основной профиль:|резервный профиль:' | tr '\n' '; '
  printf 'agent: shell version=%s; capabilities: %s; features: %s' "$AGENT_VERSION" "$caps" "$feat"
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
    /opt/bin/minimal-go-update "$slot" "$source" 2>&1 || return $?
    active="$(active_slot | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    if [ "$active" = "$slot" ]; then
      echo "Active Minimal Go slot $slot changed; applying new source..."
      /opt/bin/minimal-go-switch "$slot" 2>&1 || return $?
      echo "Minimal Go source saved and applied: slot=$slot"
    else
      echo "Minimal Go source saved but not applied: slot=$slot active=${active:-unknown}"
      echo "To apply later: minimal-go-switch $slot"
    fi
    return 0
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

agent_result_log() {
  if exists "$RESULT_LOG"; then
    echo "== Agent result log =="
    echo "log: $RESULT_LOG"
    tail -n 100 "$RESULT_LOG" 2>/dev/null || true
    return 0
  fi
  echo "agent result log not found: $RESULT_LOG"
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

install_routes_catalog_helper() {
  mkdir -p /opt/bin
  tmp="${ROUTES_CATALOG_PATH}.tmp.$$"
  echo "Installing routes catalog helper..."
  if curl -fsSL -H 'Cache-Control: no-cache' -o "$tmp" "$ROUTES_CATALOG_URL"; then
    if head -n 1 "$tmp" | grep -q '^#!/bin/sh'; then
      chmod +x "$tmp"
      mv "$tmp" "$ROUTES_CATALOG_PATH"
      echo "Installed: $ROUTES_CATALOG_PATH"
      return 0
    fi
    rm -f "$tmp"
    echo "ERROR: downloaded routes catalog helper does not look like a shell script"
    return 1
  fi
  rc="$?"
  rm -f "$tmp"
  echo "ERROR: failed to download routes catalog helper"
  return "$rc"
}

value_after_prefix() {
  prefix="$1"
  file="$2"
  sed -n "s/^${prefix}[[:space:]]*//p" "$file" 2>/dev/null | sed -n '1p'
}

update_scripts_summary() {
  log_file="$1"
  edition="$(value_after_prefix 'Selected edition:' "$log_file")"
  [ -n "$edition" ] || edition="unknown"
  mode="$(value_after_prefix 'Mode:' "$log_file")"
  [ -n "$mode" ] || mode="update-only"
  recovery="unknown"
  [ -x /opt/bin/vless-go-recover ] && recovery="updated"
  menu="no"
  [ -x /opt/bin/minimal-go-menu ] && menu="yes"
  routes_catalog="missing"
  [ -x "$ROUTES_CATALOG_PATH" ] && routes_catalog="installed"
  echo "✅ Scripts update completed"
  echo "edition: $edition"
  echo "mode: $mode"
  echo "recovery: $recovery"
  echo "minimal-go-menu: $menu"
  echo "routes-catalog: $routes_catalog"
  echo "log: $UPDATE_SCRIPTS_LOG"
}

update_scripts_cmd() {
  mkdir -p /opt/tmp /opt/var/log
  url="https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray_vless_failover_auto_latest.sh"
  dst="/opt/tmp/xray_vless_failover_auto_latest.sh"
  tmp="/opt/tmp/xray-go-update-scripts.out.$$"
  echo "Updating router scripts via auto_latest repair path..." > "$tmp"
  curl -fsSL -H 'Cache-Control: no-cache' -o "$dst" "$url" >> "$tmp" 2>&1 || { cp "$tmp" "$UPDATE_SCRIPTS_LOG" 2>/dev/null || true; cat "$tmp"; rm -f "$tmp"; return 1; }
  chmod +x "$dst" >> "$tmp" 2>&1 || { cp "$tmp" "$UPDATE_SCRIPTS_LOG" 2>/dev/null || true; cat "$tmp"; rm -f "$tmp"; return 1; }
  "$dst" --update-only --no-restart >> "$tmp" 2>&1
  rc="$?"
  echo >> "$tmp"
  install_routes_catalog_helper >> "$tmp" 2>&1
  routes_rc="$?"
  cp "$tmp" "$UPDATE_SCRIPTS_LOG" 2>/dev/null || true
  update_scripts_summary "$UPDATE_SCRIPTS_LOG"
  if [ "$rc" -ne 0 ]; then
    echo "status: failed"
    echo "error: update_scripts exited with code $rc"
    rm -f "$tmp"
    return "$rc"
  fi
  if [ "$routes_rc" -ne 0 ]; then
    echo "status: failed"
    echo "error: routes catalog helper install failed"
    rm -f "$tmp"
    return "$routes_rc"
  fi
  rm -f "$tmp"
  return 0
}

update_agent_cmd() {
  mkdir -p /opt/tmp
  url="https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/scripts/xray-go-agent-auto-install.sh"
  dst="/opt/tmp/xray-go-agent-auto-install.sh"
  curl -fsSL -H 'Cache-Control: no-cache' -o "$dst" "$url" || return $?
  chmod +x "$dst" || return $?
  agent="auto"
  [ -x /opt/bin/xray-go-agent ] && agent="go"
  [ -x /opt/bin/xray-go-agent-shell ] && agent="shell"
  echo "Agent update scheduled in background. Current agent type: $agent"
  ( sleep 2; "$dst" --agent "$agent" --server-url "$SERVER_URL" --router-id "$ROUTER_ID" --router-name "$ROUTER_NAME" --agent-token "$AGENT_TOKEN" --poll-interval "$POLL_INTERVAL" >/opt/var/log/xray-go-agent-update.log 2>&1 ) &
}

routes_cmd() {
  sub="$1"
  list_id="$2"
  payload="${3:-}"
  [ -x "$ROUTES_CATALOG_PATH" ] || { echo "routes catalog helper not installed: $ROUTES_CATALOG_PATH"; return 1; }
  case "$sub" in
    list) "$ROUTES_CATALOG_PATH" list ;;
    preview) [ -n "$list_id" ] || { echo "routes preview requires list id"; return 1; }; "$ROUTES_CATALOG_PATH" preview "$list_id" ;;
    apply) [ -n "$list_id" ] || { echo "routes apply requires list id"; return 1; }; "$ROUTES_CATALOG_PATH" apply "$list_id" ;;
    apply-custom)
      [ -n "$list_id" ] || { echo "routes apply-custom requires list id"; return 1; }
      [ -n "$payload" ] || { echo "routes apply-custom requires payload"; return 1; }
      printf '%b' "$payload" | "$ROUTES_CATALOG_PATH" apply-custom "$list_id"
      ;;
    remove) [ -n "$list_id" ] || { echo "routes remove requires list id"; return 1; }; "$ROUTES_CATALOG_PATH" remove "$list_id" ;;
    *) echo "unknown routes subcommand: $sub"; return 1 ;;
  esac
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
    agent_result_log) agent_result_log ;;
    recover_status) recover_cmd status ;;
    recover_check) recover_cmd check ;;
    recover_run) recover_cmd run ;;
    recover_enable) recover_cmd enable-hourly ;;
    recover_disable) recover_cmd disable-hourly ;;
    set_primary_source) set_source primary "$selector" "$source" ;;
    set_backup_source) set_source backup "$selector" "$source" ;;
    update_scripts) update_scripts_cmd; rc="$?"; refresh_feature_cache; return "$rc" ;;
    update_agent) update_agent_cmd ;;
    routes_list) routes_cmd list "" ;;
    routes_preview) routes_cmd preview "$selector" ;;
    routes_apply) routes_cmd apply "$selector" ;;
    routes_apply_custom) routes_cmd apply-custom "$selector" "$source" ;;
    routes_remove) routes_cmd remove "$selector" ;;
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
  output_len="$(printf '%s' "$output" | wc -c | tr -d ' ')"
  escaped_output="$(printf '%s' "$output" | json_escape)"
  payload='{"command_id":"'"$command_id"'","router_id":"'"$ROUTER_ID"'","ok":'"$ok"',"output":"'"$escaped_output"'"}'
  payload_len="$(printf '%s' "$payload" | wc -c | tr -d ' ')"
  result_log "POST start command_id=$command_id ok=$ok output_len=$output_len payload_len=$payload_len"
  tmp_post="/tmp/xray-go-agent-post.$$"
  if curl -fsS -w '%{http_code}' -o "$tmp_post" -H "Content-Type: application/json" -H "Authorization: Bearer $AGENT_TOKEN" -d "$payload" "${SERVER_URL%/}/agent/result" >"$tmp_post.code" 2>"$tmp_post.err"; then
    code="$(cat "$tmp_post.code" 2>/dev/null || true)"
    result_log "POST ok command_id=$command_id status=${code:-unknown}"
    rm -f "$tmp_post" "$tmp_post.code" "$tmp_post.err"
    return 0
  fi
  rc="$?"
  code="$(cat "$tmp_post.code" 2>/dev/null || true)"
  err="$(cat "$tmp_post.err" 2>/dev/null | head -c 200 || true)"
  body="$(cat "$tmp_post" 2>/dev/null | head -c 200 || true)"
  result_log "POST failed command_id=$command_id rc=$rc status=${code:-unknown} err=$err body=$body"
  rm -f "$tmp_post" "$tmp_post.code" "$tmp_post.err"
  return "$rc"
}

notify_startup() {
  msg="Router started. Agent online. name=$ROUTER_NAME id=$ROUTER_ID version=$AGENT_VERSION capabilities=${CAPABILITIES_CACHE:-$(capabilities)} features=${FEATURES_CACHE:-$(features)}"
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
  resp="$(curl -fsS -H "Content-Type: application/json" -H "Authorization: Bearer $AGENT_TOKEN" -d "$payload" "${SERVER_URL%/}/agent/poll" 2>&1)" || { log "poll failed: $resp"; result_log "poll failed: $resp"; return 1; }
  command_id="$(printf '%s' "$resp" | json_get id)"
  [ -n "$command_id" ] || return 0
  action="$(printf '%s' "$resp" | json_get action)"
  selector="$(printf '%s' "$resp" | json_get selector)"
  source="$(printf '%s' "$resp" | json_get source)"
  result_log "COMMAND start command_id=$command_id action=$action"
  tmp="/tmp/xray-go-agent-shell.out.$$"
  start_ts="$(date +%s 2>/dev/null || echo 0)"
  if run_action "$action" "$selector" "$source" >"$tmp" 2>&1; then ok=true; else ok=false; fi
  end_ts="$(date +%s 2>/dev/null || echo 0)"
  duration=$((end_ts - start_ts))
  out="$(cat "$tmp" 2>/dev/null || true)"
  out_len="$(printf '%s' "$out" | wc -c | tr -d ' ')"
  rm -f "$tmp"
  result_log "COMMAND done command_id=$command_id action=$action ok=$ok duration=${duration}s output_len=$out_len"
  post_result "$command_id" "$ok" "$out" || log "result post failed"
  check_slot_change
}

refresh_feature_cache
log "xray-go-agent-shell started version=$AGENT_VERSION router_id=$ROUTER_ID name=$ROUTER_NAME server=$SERVER_URL"
result_log "agent start version=$AGENT_VERSION router_id=$ROUTER_ID"
notify_startup
check_slot_change
while :; do
  poll_once || true
  [ "$ONCE" = "1" ] && exit 0
  sleep "$POLL_INTERVAL"
done
