#!/bin/sh

set -e

XRAY_BIN="/opt/bin/xray"
BACKUP_DIR="/opt/etc/xray/backups"
TMP_DIR="/opt/tmp/xray-core-update"

REPO="XTLS/Xray-core"
LATEST_API="https://api.github.com/repos/$REPO/releases/latest"
RELEASES_API="https://api.github.com/repos/$REPO/releases"

XRAY_SERVICE="/opt/etc/init.d/S24xray"
FAILOVER_SERVICE="/opt/etc/init.d/S25xray-failover"

USE_PRERELEASE="0"
NO_BACKUP="0"
DO_CLEAN_ONLY="0"

for ARG in "$@"; do
    case "$ARG" in
        --stable)
            USE_PRERELEASE="0"
            ;;
        --prerelease)
            USE_PRERELEASE="1"
            ;;
        --no-backup)
            NO_BACKUP="1"
            ;;
        --clean)
            DO_CLEAN_ONLY="1"
            ;;
        --help|-h)
            echo "Usage:"
            echo "$0"
            echo "$0 --stable"
            echo "$0 --prerelease"
            echo "$0 --no-backup"
            echo "$0 --prerelease --no-backup"
            echo "$0 --clean"
            exit 0
            ;;
        *)
            echo "Unknown option: $ARG"
            echo "Use: $0 --help"
            exit 1
            ;;
    esac
done

clean_temp() {
    echo "Очищаем временные файлы обновления..."
    rm -rf "$TMP_DIR"
    rm -f /opt/tmp/xray-core-update.sh
    rm -f /opt/tmp/xray-core-update-nobackup.sh
    rm -f /opt/tmp/xray.zip
}

show_space() {
    echo
    echo "Свободное место:"
    df -h /opt 2>/dev/null || true
    echo
}

free_kb_opt() {
    df -k /opt 2>/dev/null | awk 'NR==2 {print $4}'
}

need_cmd() {
    CMD="$1"
    PKG="$2"

    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "Команда $CMD не найдена. Устанавливаем пакет $PKG..."
        opkg update
        opkg install "$PKG"
    fi
}

if [ "$DO_CLEAN_ONLY" = "1" ]; then
    echo
    echo "======================================"
    echo " Xray-core updater cleanup"
    echo "======================================"
    echo
    clean_temp
    rm -rf /opt/var/opkg-lists/*
    show_space
    exit 0
fi

echo
echo "======================================"
echo " Xray-core GitHub updater for Entware"
echo " Source: https://github.com/XTLS/Xray-core"
echo "======================================"
echo

if [ "$USE_PRERELEASE" = "1" ]; then
    echo "Mode: latest release including pre-release"
else
    echo "Mode: latest stable release"
fi

if [ "$NO_BACKUP" = "1" ]; then
    echo "Backup: disabled"
else
    echo "Backup: enabled"
fi

echo
echo "Что будет сделано:"
echo "- очистка старых временных файлов обновления"
echo "- определение архитектуры роутера"
echo "- скачивание Xray-core из официального GitHub XTLS/Xray-core"
echo "- backup текущего /opt/bin/xray, если не указан --no-backup"
echo "- замена /opt/bin/xray"
echo "- проверка версии"
echo "- проверка /opt/etc/xray/config.json, если файл существует"
echo "- перезапуск Xray"
echo "- перезапуск failover, если он установлен"
echo

if ! command -v opkg >/dev/null 2>&1; then
    echo "ОШИБКА: opkg не найден. Entware недоступен."
    exit 1
fi

echo "[1/9] Предварительная очистка..."
rm -rf "$TMP_DIR"
mkdir -p /opt/tmp
show_space

echo "[2/9] Проверяем зависимости..."

need_cmd curl curl
opkg install ca-bundle >/dev/null 2>&1 || true
need_cmd unzip unzip

echo
echo "[3/9] Определяем архитектуру..."

ARCH="$(uname -m 2>/dev/null || echo unknown)"

case "$ARCH" in
    aarch64|arm64)
        ASSET_ARCH="arm64-v8a"
        ;;
    armv7l|armv7)
        ASSET_ARCH="arm32-v7a"
        ;;
    armv6l|armv6)
        ASSET_ARCH="arm32-v6"
        ;;
    mips)
        ASSET_ARCH="mips32"
        ;;
    mipsel|mipsle)
        ASSET_ARCH="mips32le"
        ;;
    x86_64|amd64)
        ASSET_ARCH="64"
        ;;
    i386|i686)
        ASSET_ARCH="32"
        ;;
    *)
        echo "ОШИБКА: неизвестная архитектура: $ARCH"
        echo
        echo "Поддерживаемые варианты:"
        echo "- aarch64 / arm64"
        echo "- armv7"
        echo "- armv6"
        echo "- mips"
        echo "- mipsel"
        echo "- x86_64"
        exit 1
        ;;
esac

ASSET_NAME="Xray-linux-${ASSET_ARCH}.zip"

echo "Архитектура системы: $ARCH"
echo "GitHub asset: $ASSET_NAME"

echo
echo "[4/9] Получаем release из GitHub..."

mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

RELEASE_JSON="$TMP_DIR/release.json"

if [ "$USE_PRERELEASE" = "1" ]; then
    echo "Запрашиваем список releases, включая pre-release..."
    curl -fsSL -o "$RELEASE_JSON" "$RELEASES_API?per_page=1"
else
    echo "Запрашиваем latest stable release..."
    curl -fsSL -o "$RELEASE_JSON" "$LATEST_API"
fi

TAG="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$RELEASE_JSON" | head -n 1)"

if [ -z "$TAG" ]; then
    echo "ОШИБКА: не удалось определить tag_name release."
    echo "Проверь доступ к GitHub API."
    clean_temp
    exit 1
fi

echo "Selected release: $TAG"

DOWNLOAD_URL="$(sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*'"$ASSET_NAME"'\)".*/\1/p' "$RELEASE_JSON" | head -n 1)"

if [ -z "$DOWNLOAD_URL" ]; then
    echo "ОШИБКА: не найден asset для архитектуры:"
    echo "$ASSET_NAME"
    echo
    echo "Доступные Xray-linux assets:"
    grep '"name"' "$RELEASE_JSON" | grep 'Xray-linux' || true
    clean_temp
    exit 1
fi

echo "Download URL:"
echo "$DOWNLOAD_URL"

echo
echo "[5/9] Скачиваем Xray-core..."

ZIP_FILE="$TMP_DIR/xray.zip"
curl -fL -o "$ZIP_FILE" "$DOWNLOAD_URL"

echo
echo "[6/9] Распаковываем только бинарник xray..."

unzip -o "$ZIP_FILE" xray >/dev/null

if [ ! -x "$TMP_DIR/xray" ]; then
    if [ -f "$TMP_DIR/xray" ]; then
        chmod +x "$TMP_DIR/xray"
    else
        echo "ОШИБКА: бинарник xray не найден внутри архива."
        clean_temp
        exit 1
    fi
fi

rm -f "$ZIP_FILE"

show_space

echo "[7/9] Backup текущего Xray..."

if [ "$NO_BACKUP" = "1" ]; then
    echo "Backup отключён параметром --no-backup."
else
    if [ -x "$XRAY_BIN" ]; then
        mkdir -p "$BACKUP_DIR"

        FREE_KB="$(free_kb_opt)"
        XRAY_SIZE_KB="$(du -k "$XRAY_BIN" 2>/dev/null | awk '{print $1}')"

        if [ -n "$FREE_KB" ] && [ -n "$XRAY_SIZE_KB" ] && [ "$FREE_KB" -lt "$XRAY_SIZE_KB" ]; then
            echo "ПРЕДУПРЕЖДЕНИЕ: места для backup недостаточно."
            echo "Свободно KB: $FREE_KB"
            echo "Размер текущего xray KB: $XRAY_SIZE_KB"
            echo
            echo "Запусти обновление с --no-backup или освободи место:"
            echo "rm -rf /opt/tmp/* /opt/var/opkg-lists/*"
            clean_temp
            exit 1
        fi

        OLD_VERSION="$("$XRAY_BIN" version 2>/dev/null | head -n 1 || true)"
        BACKUP_FILE="$BACKUP_DIR/xray.backup.$(date '+%Y%m%d-%H%M%S' 2>/dev/null || date +%s)"

        cp "$XRAY_BIN" "$BACKUP_FILE"
        chmod +x "$BACKUP_FILE"

        echo "Текущая версия:"
        echo "$OLD_VERSION"
        echo "Backup создан:"
        echo "$BACKUP_FILE"
    else
        echo "Текущий /opt/bin/xray не найден. Будет установлена новая версия."
    fi
fi

echo
echo "[8/9] Останавливаем сервисы и заменяем бинарник..."

if [ -x "$FAILOVER_SERVICE" ]; then
    "$FAILOVER_SERVICE" stop >/dev/null 2>&1 || true
fi

if [ -x "$XRAY_SERVICE" ]; then
    "$XRAY_SERVICE" stop >/dev/null 2>&1 || true
fi

rm -f "$XRAY_BIN"
cp "$TMP_DIR/xray" "$XRAY_BIN"
chmod +x "$XRAY_BIN"

echo "Новая версия:"
"$XRAY_BIN" version | head -n 3 || true

echo
echo "[9/9] Проверяем config, чистим временные файлы и запускаем сервисы..."

if [ -f /opt/etc/xray/config.json ]; then
    "$XRAY_BIN" run -test -config /opt/etc/xray/config.json
fi

clean_temp

if [ -x "$XRAY_SERVICE" ]; then
    "$XRAY_SERVICE" start
else
    echo "ПРЕДУПРЕЖДЕНИЕ: $XRAY_SERVICE не найден. Xray не запущен автоматически."
fi

if [ -x "$FAILOVER_SERVICE" ]; then
    "$FAILOVER_SERVICE" start || true
fi

echo
echo "======================================"
echo " ГОТОВО"
echo "======================================"
echo
echo "Xray binary:"
echo "$XRAY_BIN"
echo
echo "Xray version:"
"$XRAY_BIN" version | head -n 1 || true
echo
if [ "$NO_BACKUP" = "0" ]; then
    echo "Backup folder:"
    echo "$BACKUP_DIR"
    echo
fi
echo "Проверка:"
echo "/opt/etc/init.d/S24xray status"
echo "netstat -lntp | grep 10808"
echo
echo "Очистка при нехватке места:"
echo "rm -rf /opt/tmp/* /opt/var/opkg-lists/*"
echo
