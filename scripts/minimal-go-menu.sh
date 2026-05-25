#!/bin/sh
set -u

RELEASE_VERSION="${MINIMAL_GO_RELEASE_VERSION:-0.1.3-go-experimental}"
STATUS_CMD="/opt/bin/minimal-go-status"
SWITCH_CMD="/opt/bin/minimal-go-switch"
UPDATE_CMD="/opt/bin/minimal-go-update"
RECOVER_CMD="/opt/bin/vless-go-recover"
FAILOVER_LOG="/opt/var/log/xray-minimal-go-failover.log"
HISTORY_LOG="/opt/var/log/minimal-go-switch-history.log"

have() { [ -x "$1" ]; }
pause() { printf '\nНажмите Enter, чтобы продолжить... '; IFS= read -r _ans; }

read_vless() {
  prompt="$1"
  while :; do
    printf '%s' "$prompt"
    IFS= read -r url
    case "$url" in
      vless://*) printf '%s' "$url"; return 0 ;;
      '') echo "Значение обязательно." ;;
      *) echo "Minimal Go поддерживает только прямые vless:// ссылки." ;;
    esac
  done
}

slot_ru() {
  case "$1" in
    primary) printf '%s' "основной" ;;
    backup) printf '%s' "резервный" ;;
    *) printf '%s' "$1" ;;
  esac
}

run_status() {
  if have "$STATUS_CMD"; then
    "$STATUS_CMD"
  else
    echo "Команда minimal-go-status не найдена: $STATUS_CMD"
    return 1
  fi
}

run_switch() {
  slot="$1"
  if have "$SWITCH_CMD"; then
    "$SWITCH_CMD" "$slot"
  else
    echo "Команда minimal-go-switch не найдена: $SWITCH_CMD"
    return 1
  fi
}

run_update() {
  slot="$1"
  slot_name="$(slot_ru "$slot")"
  if ! have "$UPDATE_CMD"; then
    echo "Команда minimal-go-update не найдена: $UPDATE_CMD"
    return 1
  fi
  url="$(read_vless "Новая VLESS-ссылка для слота $slot_name ($slot): ")"
  echo
  "$UPDATE_CMD" "$slot" "$url"
  active="$(cat /opt/etc/xray/minimal-go-active 2>/dev/null || true)"
  if [ "$active" = "$slot" ]; then
    echo "Активный слот — $slot_name ($slot); применяю обновлённую ссылку..."
    run_switch "$slot"
  else
    echo "Ссылка для слота $slot_name ($slot) сохранена, но не применена."
    echo "Активный слот: ${active:-unknown}"
    echo "Чтобы применить позже: minimal-go-switch $slot"
  fi
}

run_recovery_status() {
  if have "$RECOVER_CMD"; then
    "$RECOVER_CMD" --mode minimal status
  else
    echo "Команда vless-go-recover не найдена: $RECOVER_CMD"
    return 1
  fi
}

run_recovery() {
  if have "$RECOVER_CMD"; then
    "$RECOVER_CMD" --mode minimal run
  else
    echo "Команда vless-go-recover не найдена: $RECOVER_CMD"
    return 1
  fi
}

show_logs() {
  echo "== Лог Minimal Go failover =="
  if [ -s "$FAILOVER_LOG" ]; then
    tail -n 80 "$FAILOVER_LOG"
  else
    echo "Лог не найден или пустой: $FAILOVER_LOG"
  fi
  echo
  echo "== История Minimal Go =="
  if [ -s "$HISTORY_LOG" ]; then
    tail -n 80 "$HISTORY_LOG"
  else
    echo "История не найдена или пустая: $HISTORY_LOG"
  fi
}

while :; do
  clear 2>/dev/null || true
  cat <<MENU
Меню Minimal Go
Release: $RELEASE_VERSION

1. Статус
2. Переключить на основной слот
3. Переключить на резервный слот
4. Обновить VLESS основного слота
5. Обновить VLESS резервного слота
6. Статус восстановления
7. Запустить восстановление
8. Логи
0. Выход
MENU
  printf '\nВыберите пункт: '
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
    0|q|Q|exit|выход) exit 0 ;;
    *) echo "Неизвестный пункт: $choice"; pause ;;
  esac
done
