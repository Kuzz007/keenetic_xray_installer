#!/bin/sh
set -e

# Auto installer: выбирает full/minimal edition по свободному месту /opt.

REPO_BASE="https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/main"
FULL_URL="$REPO_BASE/xray_vless_failover.sh"
MINIMAL_URL="$REPO_BASE/xray_vless_failover_minimal.sh"

FULL_TMP="/opt/tmp/xray_vless_failover.sh"
MINIMAL_TMP="/opt/tmp/xray_vless_failover_minimal.sh"

THRESHOLD_KB="${THRESHOLD_KB:-80000}"

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
    printf "Установить Minimal edition? [Y/n]: "
    IFS= read -r ans
    case "$ans" in
        n|N|no|NO|Нет|нет)
            echo "Отменено."
            exit 0
            ;;
    esac

    curl -fsSL -o "$MINIMAL_TMP" "$MINIMAL_URL"
    sh -n "$MINIMAL_TMP"
    chmod +x "$MINIMAL_TMP"
    exec "$MINIMAL_TMP" "$@"
else
    echo "Места достаточно для Full edition."
    printf "Установить Full edition? [Y/n]: "
    IFS= read -r ans
    case "$ans" in
        n|N|no|NO|Нет|нет)
            echo "Отменено."
            exit 0
            ;;
    esac

    curl -fsSL -o "$FULL_TMP" "$FULL_URL"
    sh -n "$FULL_TMP"
    chmod +x "$FULL_TMP"
    exec "$FULL_TMP" "$@"
fi
