#!/bin/sh
set -e

# Xray VLESS Failover Minimal Go Edition public entrypoint.
# Keep this filename as the current installer URL, but avoid embedded gzip/base64 payloads.
# Some Keenetic/Entware environments report gzip crc/magic errors with self-extracting wrappers.

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
PLAIN_URL="${MINIMAL_GO_PLAIN_URL:-${REPO_BASE}/xray_vless_failover_minimal.sh}"
TMP_DIR="${TMP_DIR:-/opt/tmp}"
OUT="$TMP_DIR/xray_vless_failover_minimal_go.plain.$$"

cleanup() { rm -f "$OUT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

mkdir -p "$TMP_DIR"

fetch_plain() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -o "$OUT" "$PLAIN_URL"
        return $?
    fi
    if command -v wget >/dev/null 2>&1; then
        wget --header='Cache-Control: no-cache' -O "$OUT" "$PLAIN_URL" || wget --no-check-certificate --header='Cache-Control: no-cache' -O "$OUT" "$PLAIN_URL"
        return $?
    fi
    echo "ERROR: curl or wget required" >&2
    return 1
}

install_fixed_menu() {
    MENU_BIN="/opt/bin/failover"
    [ -x /opt/bin/xray-failover-switch ] || return 0
    [ -x /opt/bin/vless-failover-status ] || return 0
    mkdir -p /opt/bin

    cat > "$MENU_BIN" <<'MENU'
#!/bin/sh

LOGFILE="/opt/var/log/xray-vless-failover.log"
HISTORY_LOG="/opt/var/log/xray-vless-switch-history.log"

pause() {
    echo
    printf "Нажмите Enter для возврата в меню..."
    IFS= read -r _
}

manual_switch_menu() {
    while true; do
        clear
        echo "======================================"
        echo " Ручное переключение профиля"
        echo "======================================"
        echo "1 Переключиться на Основной"
        echo "2 Переключиться на Резервный"
        echo "0 Отмена"
        echo "======================================"
        printf "Выберите пункт: "
        IFS= read -r target_choice

        case "$target_choice" in
            1)
                /opt/bin/xray-failover-switch primary
                return
                ;;
            2)
                /opt/bin/xray-failover-switch backup
                return
                ;;
            0)
                echo "Отмена."
                return
                ;;
            *)
                echo "Неверный пункт."
                pause
                ;;
        esac
    done
}

show_menu() {
    clear
    echo "======================================"
    echo " Xray VLESS Failover Minimal"
    echo "======================================"
    echo "1 Обновление VLESS-ссылок"
    echo "2 Лог в реальном времени"
    echo "3 Диагностика"
    echo "4 История переключений"
    echo "5 Ручное переключение профиля"
    echo "0 Выход"
    echo "======================================"
    printf "Выберите пункт: "
}

while true; do
    show_menu
    IFS= read -r choice

    case "$choice" in
        1)
            /opt/bin/vless-failover-update
            pause
            ;;
        2)
            if [ -f "$LOGFILE" ]; then
                tail -f "$LOGFILE"
            else
                echo "Лог не найден: $LOGFILE"
                pause
            fi
            ;;
        3)
            /opt/bin/vless-failover-status
            pause
            ;;
        4)
            if [ -f "$HISTORY_LOG" ]; then
                tail -n 80 "$HISTORY_LOG"
            else
                echo "История переключений пока пуста."
            fi
            pause
            ;;
        5)
            manual_switch_menu
            pause
            ;;
        0)
            echo "Выход."
            exit 0
            ;;
        *)
            echo "Неверный пункт."
            pause
            ;;
    esac
done
MENU
    chmod +x "$MENU_BIN"
    echo "Minimal Go menu updated: manual switch now asks for primary/backup."
}

echo "Downloading Minimal plain installer..."
fetch_plain || { echo "ERROR: failed to download Minimal installer: $PLAIN_URL" >&2; exit 1; }

if ! head -n 1 "$OUT" | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh'; then
    echo "ERROR: downloaded Minimal installer does not look like a shell script: $PLAIN_URL" >&2
    head -n 3 "$OUT" >&2 || true
    exit 1
fi

if ! sh -n "$OUT"; then
    echo "ERROR: downloaded Minimal installer failed shell syntax check: $PLAIN_URL" >&2
    exit 1
fi

chmod +x "$OUT"
sh "$OUT" "$@"
RC="$?"

if [ "$RC" -eq 0 ]; then
    install_fixed_menu || true
fi

exit "$RC"
