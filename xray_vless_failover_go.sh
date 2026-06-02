#!/bin/sh
set -e

# Xray VLESS Failover Go/Entware public entrypoint.
# Installs/updates the Entware feed package, then performs first-run setup by
# asking for primary/backup VLESS or subscription URLs. No embedded gzip/base64.

REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_BASE="${REPO_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
PLAIN_URL="${GO_PLAIN_URL:-${REPO_BASE}/scripts/install-entware-feed.sh}"
TMP_DIR="${TMP_DIR:-/opt/tmp}"
OUT="$TMP_DIR/xray_vless_failover_go.feed.$$"

DO_SETUP="1"
NO_RESTART="0"
FORCE_SETUP="0"
ASSUME_YES="0"
FEED_ARGS=""

usage() {
    cat <<'USAGE'
Usage: xray_vless_failover_go.sh [options]

Default mode:
  Install/update Go/Entware edition, ask for primary and backup VLESS/subscription URLs,
  apply primary profile, start watchdog and enable hourly recovery.

Options:
  --no-setup             Install/update package only; do not ask for links
  --repair-only          Alias for --no-setup, intended for update/repair paths
  --update-only          Alias for --no-setup, intended for update/repair paths
  --force-setup          Ask for links even if primary and backup are already configured
  --no-restart           Do not restart/switch Xray while applying primary
  -y, --yes              Use defaults for yes/no prompts where possible
  -h, --help             Show help

Environment overrides:
  PRIMARY_URL            Primary VLESS link or subscription URL
  BACKUP_URL             Backup VLESS link or subscription URL
  PRIMARY_SELECTOR       Primary selector: first, index:N, or N
  BACKUP_SELECTOR        Backup selector: first, index:N, or N
  GO_PLAIN_URL           Feed bootstrap URL override
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-setup|--repair-only|--update-only) DO_SETUP="0"; FEED_ARGS="$FEED_ARGS $1"; shift ;;
        --force-setup) FORCE_SETUP="1"; shift ;;
        --no-restart) NO_RESTART="1"; FEED_ARGS="$FEED_ARGS $1"; shift ;;
        -y|--yes) ASSUME_YES="1"; FEED_ARGS="$FEED_ARGS $1"; shift ;;
        -h|--help|help) usage; exit 0 ;;
        *) FEED_ARGS="$FEED_ARGS $1"; shift ;;
    esac
done

cleanup() { rm -f "$OUT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

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

need_exec() {
    if [ ! -x "$1" ]; then
        echo "ERROR: required command not found or not executable: $1" >&2
        exit 1
    fi
}

normalize_selector() {
    value="$1"
    case "$value" in
        ''|first) echo first ;;
        index:[1-9]*[!0-9]*) return 1 ;;
        index:[1-9]*) echo "$value" ;;
        [1-9]*[!0-9]*) return 1 ;;
        [1-9]*) echo "index:$value" ;;
        *) return 1 ;;
    esac
}

show_profiles_hint() {
    slot="$1"
    source_value="$2"
    [ -n "$source_value" ] || return 0
    case "$source_value" in
        http://*|https://*)
            echo
            echo "Subscription profile listing is not available in this installer build."
            echo "For $slot selector use 'first' or a profile number, e.g. 1 = index:1."
            echo
            ;;
    esac
}

prompt_source() {
    slot="$1"
    env_value="$2"
    if [ -n "$env_value" ]; then
        printf '%s' "$env_value"
        return 0
    fi

    while true; do
        read_tty "Enter $slot VLESS link or subscription URL: "
        if [ -n "$REPLY" ]; then
            printf '%s' "$REPLY"
            return 0
        fi
        echo "ERROR: $slot URL cannot be empty." >&2
    done
}

prompt_selector() {
    slot="$1"
    source_value="$2"
    env_value="$3"
    default="first"

    show_profiles_hint "$slot" "$source_value" >&2

    if [ -n "$env_value" ]; then
        normalize_selector "$env_value"
        return $?
    fi

    while true; do
        echo "Selector for $slot supports: first, index:N, or just N. Default: $default" >&2
        read_tty "Enter $slot selector [$default]: "
        value="$REPLY"
        [ -n "$value" ] || value="$default"
        if selector="$(normalize_selector "$value")"; then
            printf '%s' "$selector"
            return 0
        fi
        echo "ERROR: invalid selector: $value" >&2
    done
}

already_configured() {
    [ -s /opt/etc/xray/vless-go.primary ] && [ -s /opt/etc/xray/vless-go.backup ]
}

run_feed_install() {
    mkdir -p "$TMP_DIR"
    echo "Downloading Go/Entware feed installer..."
    fetch_plain || { echo "ERROR: failed to download Go/Entware feed installer: $PLAIN_URL" >&2; exit 1; }

    if ! head -n 1 "$OUT" | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh'; then
        echo "ERROR: downloaded Go/Entware feed installer does not look like a shell script: $PLAIN_URL" >&2
        head -n 3 "$OUT" >&2 || true
        exit 1
    fi

    if ! sh -n "$OUT"; then
        echo "ERROR: downloaded Go/Entware feed installer failed shell syntax check: $PLAIN_URL" >&2
        exit 1
    fi

    chmod +x "$OUT"
    sh "$OUT" $FEED_ARGS
}

print_final_summary() {
    echo
    echo "Final non-interactive status summary:"
    echo

    if [ -x /opt/bin/vless-go-failover ]; then
        /opt/bin/vless-go-failover status || true
    else
        echo "WARN: /opt/bin/vless-go-failover not found"
    fi

    echo
    if [ -x /opt/bin/vless-go-watchdog ]; then
        /opt/bin/vless-go-watchdog status || true
    else
        echo "WARN: /opt/bin/vless-go-watchdog not found"
    fi

    echo
    if [ -x /opt/bin/vless-go-recover ]; then
        /opt/bin/vless-go-recover --mode full status || true
    else
        echo "WARN: /opt/bin/vless-go-recover not found"
    fi

    echo
    if [ -x /opt/bin/vless-go-doctor ]; then
        /opt/bin/vless-go-doctor || true
    else
        echo "WARN: /opt/bin/vless-go-doctor not found"
    fi
}

run_first_setup() {
    if [ "$FORCE_SETUP" != "1" ] && already_configured; then
        echo "Existing primary and backup profiles detected; skipping first-run setup."
        echo "Use --force-setup to replace them, or run failover-go for menu management."
        return 0
    fi

    need_exec /opt/bin/vless-go-failover
    need_exec /opt/bin/vless-go-watchdog
    need_exec /opt/bin/vless-go-recover
    need_exec /opt/bin/vless-go-doctor

    echo
    echo "Go/Entware first-run setup"
    echo "Private links are stored under /opt/etc/xray and are not printed back."
    echo

    primary_value="$(prompt_source primary "${PRIMARY_URL:-}")"
    primary_selector="$(prompt_selector primary "$primary_value" "${PRIMARY_SELECTOR:-}")" || { echo "ERROR: invalid primary selector" >&2; exit 1; }

    backup_value="$(prompt_source backup "${BACKUP_URL:-}")"
    backup_selector="$(prompt_selector backup "$backup_value" "${BACKUP_SELECTOR:-}")" || { echo "ERROR: invalid backup selector" >&2; exit 1; }

    echo
    echo "Saving primary profile..."
    /opt/bin/vless-go-failover set-primary "$primary_value" --selector "$primary_selector"

    echo "Saving backup profile..."
    /opt/bin/vless-go-failover set-backup "$backup_value" --selector "$backup_selector"

    echo "Applying primary profile..."
    if [ "$NO_RESTART" = "1" ]; then
        /opt/bin/vless-go-failover switch primary --no-restart
    else
        /opt/bin/vless-go-failover switch primary
    fi

    echo "Starting watchdog..."
    if [ -x /opt/etc/init.d/S26vless-go-watchdog ]; then
        /opt/etc/init.d/S26vless-go-watchdog start || true
    else
        echo "WARN: watchdog init not found: /opt/etc/init.d/S26vless-go-watchdog" >&2
    fi

    echo "Enabling hourly recovery..."
    /opt/bin/vless-go-recover --mode full enable-hourly || true

    echo
    echo "Installation and first-run setup complete."
    print_final_summary
    echo
    echo "Use 'failover-go' later to open the management menu."
}

run_feed_install

if [ "$DO_SETUP" = "1" ]; then
    run_first_setup
else
    echo "Setup skipped. Use 'failover-go' for menu management or rerun with --force-setup."
fi
