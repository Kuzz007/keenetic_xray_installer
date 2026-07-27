#!/bin/sh
set -e

XRAY_BACKUP_DIR="/opt/etc/xray/backups"
KEEP_BACKUPS="${KEEP_BACKUPS:-2}"
DRY_RUN="0"
ALL_BACKUPS="0"
CLEAN_OPKG_LISTS="1"
CLEAN_TMP="1"

usage() {
    cat <<'USAGE'
Usage: vless-go-cleanup [options]

Безопасная очистка места на /opt для VLESS Go / Xray.

По умолчанию:
  - удаляет временные файлы VLESS Go / Xray из /opt/tmp
  - удаляет opkg cache/lists
  - оставляет последние 2 backup-бинарника Xray

Options:
  --dry-run              Показать, что будет удалено, но ничего не удалять.
  --keep-backups N       Сколько последних Xray backup-ов оставить. По умолчанию: 2.
  --all-backups          Удалить все Xray backup-бинарники.
  --no-opkg              Не чистить opkg lists/cache.
  --no-tmp               Не чистить /opt/tmp.
  -h, --help             Показать справку.

Примеры:
  vless-go-cleanup
  vless-go-cleanup --dry-run
  vless-go-cleanup --keep-backups 1
  vless-go-cleanup --all-backups
USAGE
}

size_opt() {
    df -h /opt 2>/dev/null || true
}

run_rm() {
    if [ "$DRY_RUN" = "1" ]; then
        for path in "$@"; do
            [ -e "$path" ] || continue
            echo "DRY-RUN remove: $path"
        done
        return 0
    fi
    rm -rf "$@" 2>/dev/null || true
}

remove_glob() {
    pattern="$1"
    # shellcheck disable=SC2086
    set -- $pattern
    [ "$1" = "$pattern" ] && return 0
    run_rm "$@"
}

cleanup_tmp() {
    [ "$CLEAN_TMP" = "1" ] || return 0
    echo "== Очистка временных файлов =="
    remove_glob '/opt/tmp/keenetic_xray_installer'
    remove_glob '/opt/tmp/keenetic_xray_installer-*'
    remove_glob '/opt/tmp/main.tar.gz'
    remove_glob '/opt/tmp/xray-failover-go-linux-arm64*'
    remove_glob '/opt/tmp/xray-failover-go-linux-arm64-pr*.zip'
    remove_glob '/opt/tmp/vless-go-xray-core-update.*'
    remove_glob '/opt/tmp/config.vless-go-update.*'
    remove_glob '/opt/tmp/xray-core-*'
    remove_glob '/opt/tmp/Xray-linux-*.zip'
    remove_glob '/opt/tmp/release.json'
    remove_glob '/opt/tmp/releases.json'
}

cleanup_opkg() {
    [ "$CLEAN_OPKG_LISTS" = "1" ] || return 0
    echo "== Очистка opkg cache/lists =="
    run_rm /opt/var/opkg-lists/*
    run_rm /opt/var/cache/opkg/*
}

cleanup_backups() {
    echo "== Очистка Xray backup-бинарников =="
    [ -d "$XRAY_BACKUP_DIR" ] || { echo "Backup directory отсутствует: $XRAY_BACKUP_DIR"; return 0; }

    if [ "$ALL_BACKUPS" = "1" ]; then
        remove_glob "$XRAY_BACKUP_DIR/xray.*.bak"
        return 0
    fi

    case "$KEEP_BACKUPS" in
        ''|*[!0-9]*) echo "ОШИБКА: --keep-backups должен быть числом" >&2; exit 1 ;;
    esac

    if [ "$KEEP_BACKUPS" -eq 0 ]; then
        remove_glob "$XRAY_BACKUP_DIR/xray.*.bak"
        return 0
    fi

    # BusyBox-compatible: list newest first, delete everything after N.
    old_files="$(ls -1t "$XRAY_BACKUP_DIR"/xray.*.bak 2>/dev/null | sed -n "$((KEEP_BACKUPS + 1)),\$p" || true)"
    [ -n "$old_files" ] || { echo "Старых backup-ов для удаления нет."; return 0; }

    echo "$old_files" | while IFS= read -r file; do
        [ -n "$file" ] || continue
        run_rm "$file"
    done
}

show_usage_top() {
    echo "== Использование /opt до очистки =="
    size_opt
    echo
}

show_usage_bottom() {
    echo
    echo "== Использование /opt после очистки =="
    size_opt
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN="1"; shift ;;
        --keep-backups) [ "$#" -ge 2 ] || { echo "ОШИБКА: --keep-backups требует значение" >&2; exit 1; }; KEEP_BACKUPS="$2"; shift 2 ;;
        --all-backups) ALL_BACKUPS="1"; shift ;;
        --no-opkg) CLEAN_OPKG_LISTS="0"; shift ;;
        --no-tmp) CLEAN_TMP="0"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ОШИБКА: неизвестный аргумент: $1" >&2; usage >&2; exit 1 ;;
    esac
done

show_usage_top
cleanup_tmp
cleanup_opkg
cleanup_backups
show_usage_bottom

echo
if [ "$DRY_RUN" = "1" ]; then
    echo "DRY-RUN завершён. Файлы не удалялись."
else
    echo "Очистка завершена."
fi
