#!/bin/sh
set -e

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT_DIR"

patch_file() {
    TARGET="$1"
    [ -f "$TARGET" ] || { echo "Missing: $TARGET" >&2; exit 1; }

    python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
original = text

func = r'''
install_base_routes_option() {
    echo
    echo "Базовый список доменов/CIDR может быть добавлен в маршрутизацию Keenetic через Proxy0."
    echo "Списки будут видны в веб-интерфейсе: Маршрутизация -> Маршруты DNS -> Списки доменных имён."
    read_tty "Установить базовый список доменов/CIDR через xray-keenetic-routes.sh? [y/N]: "

    case "$REPLY" in
        y|Y|yes|YES|д|Д|да|Да|ДА) ;;
        *)
            echo "Базовый список маршрутов не устанавливаем."
            echo "Позже можно установить вручную: xray-routes-sync"
            return 0
            ;;
    esac

    if ! command -v ndmc >/dev/null 2>&1; then
        echo "ПРЕДУПРЕЖДЕНИЕ: ndmc не найден. Установка маршрутов пропущена."
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "ПРЕДУПРЕЖДЕНИЕ: curl не найден. Установка маршрутов пропущена."
        return 0
    fi

    ROUTES_URL="${ROUTES_URL:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main/xray-keenetic-routes.sh}"
    ROUTES_TMP="$TMP_DIR/xray-keenetic-routes.sh"

    mkdir -p "$TMP_DIR"

    echo "Скачиваем xray-keenetic-routes.sh..."
    if ! curl -fsSL -o "$ROUTES_TMP" "$ROUTES_URL"; then
        echo "ПРЕДУПРЕЖДЕНИЕ: не удалось скачать xray-keenetic-routes.sh."
        echo "Маршруты можно установить позже вручную."
        return 0
    fi

    if ! sh -n "$ROUTES_TMP"; then
        echo "ПРЕДУПРЕЖДЕНИЕ: скачанный xray-keenetic-routes.sh не прошёл shell-синтаксис."
        return 0
    fi

    chmod +x "$ROUTES_TMP"

    echo "Устанавливаем команды маршрутов..."
    if ! "$ROUTES_TMP" install; then
        echo "ПРЕДУПРЕЖДЕНИЕ: не удалось установить команды маршрутов."
        return 0
    fi

    echo "Применяем базовые DNS routes через Proxy0..."
    if command -v xray-routes-sync >/dev/null 2>&1; then
        if ! xray-routes-sync; then
            echo "ПРЕДУПРЕЖДЕНИЕ: xray-routes-sync завершился с ошибкой."
            return 0
        fi
    elif [ -x /opt/bin/xray-keenetic-routes ]; then
        if ! /opt/bin/xray-keenetic-routes sync; then
            echo "ПРЕДУПРЕЖДЕНИЕ: /opt/bin/xray-keenetic-routes sync завершился с ошибкой."
            return 0
        fi
    else
        echo "ПРЕДУПРЕЖДЕНИЕ: команда xray-routes-sync не найдена после установки."
        return 0
    fi

    echo "Базовый список доменов/CIDR установлен."
}
'''

if 'install_base_routes_option()' not in text:
    anchor = '\ncreate_failover_daemon() {\n'
    if anchor not in text:
        raise SystemExit(f'ERROR: anchor create_failover_daemon not found in {path}')
    text = text.replace(anchor, '\n' + func + anchor, 1)

call = '\nconfigure_proxy0\n'
call_with_routes = '\nconfigure_proxy0\ninstall_base_routes_option\n'
if 'install_base_routes_option' in text and call_with_routes not in text:
    if call not in text:
        raise SystemExit(f'ERROR: configure_proxy0 call not found in {path}')
    text = text.replace(call, call_with_routes, 1)

if text == original:
    print(f'Already patched: {path}')
else:
    path.write_text(text)
    print(f'Patched: {path}')
PY

    sh -n "$TARGET"
}

patch_file "src/full/xray_vless_failover.sh"
patch_file "src/minimal/xray_vless_failover_minimal.sh"

echo "Base routes install option patched in full and minimal sources."
