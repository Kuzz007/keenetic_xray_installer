#!/bin/sh
set -u

STATUS_CMD="/opt/bin/minimal-go-status"
SWITCH_CMD="/opt/bin/minimal-go-switch"
UPDATE_CMD="/opt/bin/minimal-go-update"
RECOVER_CMD="/opt/bin/vless-go-recover"
FAILOVER_LOG="/opt/var/log/xray-minimal-go-failover.log"
HISTORY_LOG="/opt/var/log/minimal-go-switch-history.log"

have() { [ -x "$1" ]; }
pause() { printf '\nPress Enter to continue... '; IFS= read -r _ans; }

read_vless() {
  prompt="$1"
  while :; do
    printf '%s' "$prompt"
    IFS= read -r url
    case "$url" in
      vless://*) printf '%s' "$url"; return 0 ;;
      '') echo "Value is required." ;;
      *) echo "Only direct vless:// links are supported in Minimal Go." ;;
    esac
  done
}

run_status() {
  if have "$STATUS_CMD"; then
    "$STATUS_CMD"
  else
    echo "minimal-go-status not found: $STATUS_CMD"
    return 1
  fi
}

run_switch() {
  slot="$1"
  if have "$SWITCH_CMD"; then
    "$SWITCH_CMD" "$slot"
  else
    echo "minimal-go-switch not found: $SWITCH_CMD"
    return 1
  fi
}

run_update() {
  slot="$1"
  if ! have "$UPDATE_CMD"; then
    echo "minimal-go-update not found: $UPDATE_CMD"
    return 1
  fi
  url="$(read_vless "New $slot vless:// URL: ")"
  echo
  "$UPDATE_CMD" "$slot" "$url"
  active="$(cat /opt/etc/xray/minimal-go-active 2>/dev/null || true)"
  if [ "$active" = "$slot" ]; then
    echo "Active slot is $slot; applying updated source..."
    run_switch "$slot"
  else
    echo "Saved $slot source. Active slot is ${active:-unknown}; not applied."
    echo "To apply later: minimal-go-switch $slot"
  fi
}

run_recovery_status() {
  if have "$RECOVER_CMD"; then
    "$RECOVER_CMD" --mode minimal status
  else
    echo "vless-go-recover not found: $RECOVER_CMD"
    return 1
  fi
}

run_recovery() {
  if have "$RECOVER_CMD"; then
    "$RECOVER_CMD" --mode minimal run
  else
    echo "vless-go-recover not found: $RECOVER_CMD"
    return 1
  fi
}

show_logs() {
  echo "== Minimal Go failover log =="
  if [ -s "$FAILOVER_LOG" ]; then
    tail -n 80 "$FAILOVER_LOG"
  else
    echo "Log not found or empty: $FAILOVER_LOG"
  fi
  echo
  echo "== Minimal Go history =="
  if [ -s "$HISTORY_LOG" ]; then
    tail -n 80 "$HISTORY_LOG"
  else
    echo "History not found or empty: $HISTORY_LOG"
  fi
}

while :; do
  clear 2>/dev/null || true
  cat <<'MENU'
Minimal Go menu

1. Status
2. Switch primary
3. Switch backup
4. Update primary VLESS
5. Update backup VLESS
6. Recovery status
7. Recovery run
8. Logs
0. Exit
MENU
  printf '\nSelect: '
  IFS= read -r choice
  echo
  case "$choice" in
    1) run_status; pause ;;
    2) run_switch primary; pause ;;
    3) run_switch backup; pause ;;
    4) run_update primary; pause ;;
    5) run_update backup; pause ;;
    6) run_recovery_status; pause ;;
    7) run_recovery; pause ;;
    8) show_logs; pause ;;
    0|q|Q|exit) exit 0 ;;
    *) echo "Unknown selection: $choice"; pause ;;
  esac
done
