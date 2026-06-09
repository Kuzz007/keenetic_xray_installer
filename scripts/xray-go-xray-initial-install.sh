#!/bin/sh
set -eu

# xray-go-xray-initial-install - install Xray binary for fresh direct installs.
#
# This is not the Xray-core update helper. It only fills the missing Xray binary
# on a fresh router. If Xray already exists, it is a no-op. Manual update remains
# explicit via vless-go-xray-core-update.

XRAY_BIN_TARGET="${XRAY_BIN_TARGET:-/opt/sbin/xray}"
XRAY_CONFIG="${XRAY_CONFIG:-/opt/etc/xray/config.json}"
XRAY_INIT="${XRAY_INIT:-/opt/etc/init.d/S24xray}"
TMP_CLEANUP_DIRS="${TMP_CLEANUP_DIRS:-/opt/tmp/xray-go-direct-install /opt/tmp/xray-go-helper-profile}"
MODE="apply"
ASSUME_YES="0"
START_AFTER_INSTALL="0"

usage() {
    cat <<'USAGE'
xray-go-xray-initial-install - fresh-install Xray binary helper

Usage:
  xray-go-xray-initial-install --apply --yes
  xray-go-xray-initial-install --dry-run

Safety:
  If Xray already exists, this script makes no binary changes.
  It does not install vless-go-xray-core-update.
  It does not update an existing Xray binary.
  It installs xray-core/xray through Entware opkg only when Xray is missing.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --apply|apply) MODE="apply"; shift ;;
        --dry-run|--plan|plan) MODE="dry-run"; shift ;;
        --yes|-y) ASSUME_YES="1"; shift ;;
        --start) START_AFTER_INSTALL="1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [ "$MODE" = "apply" ] && [ "$ASSUME_YES" != "1" ]; then
    echo "ERROR: --apply requires --yes" >&2
    exit 2
fi

get_xray_bin() {
    if command -v xray >/dev/null 2>&1; then
        command -v xray
    elif [ -x /opt/sbin/xray ]; then
        echo /opt/sbin/xray
    elif [ -x /opt/bin/xray ]; then
        echo /opt/bin/xray
    else
        echo ""
    fi
}

opkg_bin() {
    if command -v opkg >/dev/null 2>&1; then
        command -v opkg
    elif [ -x /opt/bin/opkg ]; then
        echo /opt/bin/opkg
    else
        echo ""
    fi
}

kb_to_mb_1dp() {
    awk 'BEGIN { printf "%.1f", '"${1:-0}"' / 1024 }'
}

opt_free_kb() {
    df -Pk /opt 2>/dev/null | awk 'NR==2 {print $4}'
}

cleanup_staging() {
    echo "Cleaning direct staging before Xray install..."
    for d in $TMP_CLEANUP_DIRS; do
        case "$d" in
            /opt/tmp/xray-go-direct-install|/opt/tmp/xray-go-helper-profile|/tmp/xray-go-direct-install|/tmp/xray-go-helper-profile)
                [ -e "$d" ] && rm -rf "$d" && echo "  removed: $d" || true
                ;;
            *)
                echo "  skip non-standard cleanup path: $d"
                ;;
        esac
    done
}

ensure_xray_target_path() {
    found="$(get_xray_bin)"
    [ -n "$found" ] || return 1
    mkdir -p "$(dirname "$XRAY_BIN_TARGET")"
    if [ "$found" != "$XRAY_BIN_TARGET" ] && [ ! -e "$XRAY_BIN_TARGET" ]; then
        ln -s "$found" "$XRAY_BIN_TARGET" 2>/dev/null || cp "$found" "$XRAY_BIN_TARGET"
        chmod +x "$XRAY_BIN_TARGET" 2>/dev/null || true
        echo "Xray compatibility path created: $XRAY_BIN_TARGET -> $found"
    fi
}

install_xray_init() {
    mkdir -p /opt/etc/init.d
    if [ -x "$XRAY_INIT" ]; then
        echo "[OK] Xray init already exists: $XRAY_INIT"
        return 0
    fi

    cat > "$XRAY_INIT" <<EOF_INIT
#!/bin/sh

ENABLED=yes
PROCS=xray
ARGS="run -config $XRAY_CONFIG"
PREARGS=""
DESC="Xray"

. /opt/etc/init.d/rc.func
EOF_INIT
    chmod 755 "$XRAY_INIT"
    echo "Xray init installed: $XRAY_INIT"
}

print_status() {
    echo "== Xray initial install status =="
    found="$(get_xray_bin)"
    if [ -n "$found" ]; then
        echo "[OK] Xray binary found: $found"
        "$found" version 2>/dev/null | sed -n '1,2p' || true
    else
        echo "[WARN] Xray binary missing"
    fi
    free="$(opt_free_kb || echo 0)"
    echo "/opt free: $(kb_to_mb_1dp "${free:-0}") MB"
    [ -x "$XRAY_INIT" ] && echo "[OK] Xray init: $XRAY_INIT" || echo "[WARN] Xray init missing: $XRAY_INIT"
}

cat <<EOF_INTRO
== Xray Go initial Xray install ==
Mode: $MODE
Target path: $XRAY_BIN_TARGET
Init script: $XRAY_INIT
EOF_INTRO

print_status

if [ "$MODE" = "dry-run" ]; then
    echo "Dry-run: no changes made."
    exit 0
fi

if [ -n "$(get_xray_bin)" ]; then
    ensure_xray_target_path || true
    install_xray_init
    echo "Xray already installed; no binary install/update performed."
    exit 0
fi

OPKG="$(opkg_bin)"
[ -n "$OPKG" ] || { echo "ERROR: opkg not found; Entware unavailable" >&2; exit 1; }

cleanup_staging
free_after_cleanup="$(opt_free_kb || echo 0)"
echo "/opt free after cleanup: $(kb_to_mb_1dp "${free_after_cleanup:-0}") MB"

echo "Updating Entware package index..."
"$OPKG" update

echo "Installing Xray through Entware opkg..."
if "$OPKG" install xray-core; then
    echo "Installed package: xray-core"
elif "$OPKG" install xray; then
    echo "Installed package: xray"
else
    echo "ERROR: failed to install xray-core/xray through opkg" >&2
    exit 1
fi

ensure_xray_target_path || { echo "ERROR: Xray package installed but xray binary was not found" >&2; exit 1; }
install_xray_init

XRAY_BIN="$(get_xray_bin)"
echo "Installed Xray version:"
"$XRAY_BIN" version | sed -n '1,2p'

if [ "$START_AFTER_INSTALL" = "1" ] && [ -s "$XRAY_CONFIG" ]; then
    "$XRAY_INIT" restart || "$XRAY_INIT" start || true
fi

echo "Initial Xray install complete."
