#!/bin/sh
set -e

# Auto installer: выбирает full/minimal edition по свободному месту /opt.

REPO_BASE="https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main"
FULL_URL="$REPO_BASE/xray_vless_failover.sh"
MINIMAL_URL="$REPO_BASE/xray_vless_failover_minimal.sh"

FULL_TMP="/opt/tmp/xray_vless_failover.sh"
MINIMAL_TMP="/opt/tmp/xray_vless_failover_minimal.sh"

THRESHOLD_KB="${THRESHOLD_KB:-80000}"

read_tty() {
    prompt="$1"

    if [ -r /dev/tty ]; then
        printf "%s" "$prompt" >/dev/tty
        IFS= read -r REPLY </dev/tty
    else
        printf "%s" "$prompt" >&2
        IFS= read -r REPLY
    fi
}

confirm_install() {
    label="$1"

    read_tty "Установить $label edition? [Y/n]: "
    ans="$REPLY"

    case "$ans" in
        n|N|no|NO|Нет|нет)
            echo "Отменено."
            exit 0
            ;;
    esac
}

download_installer() {
    url="$1"
    output="$2"
    label="$3"

    echo "Скачиваем $label installer..."
    if ! curl -fsSL -o "$output" "$url"; then
        echo "ОШИБКА: не удалось скачать $label installer: $url"
        echo "Проверьте интернет, DNS и доступность GitHub/raw.githubusercontent.com."
        exit 1
    fi

    if ! sh -n "$output"; then
        echo "ОШИБКА: скачанный $label installer не прошёл shell-синтаксис: $output"
        exit 1
    fi

    chmod +x "$output"
}

if ! command -v curl >/dev/null 2>&1; then
    echo "ОШИБКА: curl не найден."
    echo "Выполните: opkg update && opkg install curl ca-bundle"
    exit 1
fi

mkdir -p /opt/tmp

FREE_KB="$(df -k /opt 2>/dev/null | awk 'NR==2 { print $4 }')"
[ -n "$FREE_KB" ] || FREE_KB="0"

echo "Свободно на /opt: ${FREE_KB} KB"
echo "Порог для full edition: ${THRESHOLD_KB} KB"
echo

if [ "$FREE_KB" -lt "$THRESHOLD_KB" ]; then
    echo "Обнаружено мало свободного места."
    echo "Рекомендуется Minimal edition:"
    echo "- только прямые vless:// ссылки"
    echo "- без подписок"
    echo "- без python3"
    echo "- без cron"
    echo "- без обновления ядра через GitHub"
    echo

    confirm_install "Minimal"
    download_installer "$MINIMAL_URL" "$MINIMAL_TMP" "Minimal"
    exec "$MINIMAL_TMP" "$@"
else
    echo "Места достаточно для Full edition."
    echo "Full edition поддерживает подписки, failover, обновление ссылок и служебные команды."
    echo

    confirm_install "Full"
    download_installer "$FULL_URL" "$FULL_TMP" "Full"
    exec "$FULL_TMP" "$@"
fi
