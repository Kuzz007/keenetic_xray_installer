#!/bin/sh
set -eu

# xray-go-direct-setup-wizard - interactive first-run source/state wizard.
#
# It never prints raw VLESS/subscription values after input. In plan mode it only
# validates and shows a write plan. In apply mode it delegates guarded writes to
# xray-go-direct-setup.sh --write-state, which refuses to overwrite existing
# state/source/selector files.

REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
DIRECT_SETUP_URL="${DIRECT_SETUP_URL:-${RAW_BASE}/scripts/xray-go-direct-setup.sh}"
TMP_DIR="${TMPDIR:-/tmp}"
SETUP_TMP="${TMP_DIR}/xray-go-direct-setup-wizard.setup.$$"

MODE="plan"
YES="0"

usage() {
    cat <<'USAGE'
xray-go-setup - interactive first-run setup wizard

Usage:
  xray-go-setup --plan
  xray-go-setup --apply --yes

What it asks:
  primary source: vless://... or http(s) subscription URL
  backup source:  vless://..., http(s) subscription URL, or 'same'
  active slot:    primary or backup
  selectors:      first or index:N
  SOCKS auth:     auto, keep, or disable

Safety:
  Plan mode is default and writes nothing.
  Apply mode requires --yes and writes only source/state/selector files.
  Raw source values are never printed by this script.
  Existing state/source/selector files are protected by xray-go-direct-setup.sh.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --plan|--dry-run|plan|dry-run)
            MODE="plan"
            shift
            ;;
        --apply|apply)
            MODE="apply"
            shift
            ;;
        --yes|-y)
            YES="1"
            shift
            ;;
        -h|--help|help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$MODE" = "apply" ] && [ "$YES" != "1" ]; then
    echo "ERROR: --apply requires --yes" >&2
    exit 2
fi

cleanup() { rm -f "$SETUP_TMP" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

fetch_url() {
    url="$1"
    out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' -o "$out" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$out" "$url"
    else
        echo "ERROR: curl or wget is required" >&2
        return 127
    fi
}

trim_value() {
    printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

source_type() {
    case "$1" in
        vless://*) echo "direct vless link" ;;
        http://*|https://*) echo "subscription URL" ;;
        *) echo "unknown format" ;;
    esac
}

valid_source() {
    value="$1"
    [ -n "$value" ] || return 1
    lines="$(printf '%s\n' "$value" | wc -l | tr -d ' ')"
    [ "$lines" = "1" ] || return 1
    case "$(source_type "$value")" in
        "direct vless link"|"subscription URL") return 0 ;;
        *) return 1 ;;
    esac
}

valid_selector() {
    case "$1" in
        first) return 0 ;;
        index:*)
            n="${1#index:}"
            case "$n" in ''|*[!0-9]*|0) return 1 ;; *) return 0 ;; esac
            ;;
        *) return 1 ;;
    esac
}

valid_active() {
    case "$1" in primary|backup) return 0 ;; *) return 1 ;; esac
}

valid_socks_auth() {
    case "$1" in auto|keep|disable) return 0 ;; *) return 1 ;; esac
}

read_line() {
    prompt="$1"
    # Prompt must go to stderr because callers capture stdout with command
    # substitution. If printed to stdout, the prompt is swallowed into the
    # variable and looks like the wizard is hanging.
    printf '%s' "$prompt" >&2
    IFS= read -r value || value=""
    trim_value "$value"
}

read_source_required() {
    label="$1"
    while :; do
        value="$(read_line "$label: ")"
        if valid_source "$value"; then
            type="$(source_type "$value")"
            size="$(printf '%s' "$value" | wc -c | tr -d ' ')"
            echo "[OK] $label accepted ($type, ${size} bytes); raw value hidden" >&2
            printf '%s\n' "$value"
            return 0
        fi
        echo "[FAIL] $label invalid. Use vless://... or http(s) subscription URL. Raw value hidden." >&2
    done
}

read_backup_source() {
    primary="$1"
    while :; do
        value="$(read_line "Backup source [vless/http(s), or 'same' to reuse primary]: ")"
        case "$value" in
            same|SAME|Same|"")
                echo "[OK] backup source will reuse primary; raw value hidden" >&2
                printf '%s\n' "$primary"
                return 0
                ;;
        esac
        if valid_source "$value"; then
            type="$(source_type "$value")"
            size="$(printf '%s' "$value" | wc -c | tr -d ' ')"
            echo "[OK] backup source accepted ($type, ${size} bytes); raw value hidden" >&2
            printf '%s\n' "$value"
            return 0
        fi
        echo "[FAIL] backup source invalid. Use vless://..., http(s), or same. Raw value hidden." >&2
    done
}

read_choice() {
    prompt="$1"
    default="$2"
    validator="$3"
    while :; do
        value="$(read_line "$prompt [$default]: ")"
        [ -n "$value" ] || value="$default"
        if "$validator" "$value"; then
            printf '%s\n' "$value"
            return 0
        fi
        echo "[FAIL] invalid value: $value" >&2
    done
}

fetch_setup() {
    mkdir -p "$TMP_DIR"
    echo "Fetching guarded setup helper: $DIRECT_SETUP_URL"
    fetch_url "$DIRECT_SETUP_URL" "$SETUP_TMP"
    sh -n "$SETUP_TMP"
    chmod +x "$SETUP_TMP"
}

cat <<EOF_INTRO
== Xray Go first-run setup wizard ==
Mode: $MODE
Repository branch/ref: $REPO_BRANCH
Raw source values are accepted from your terminal input but are not printed back.
EOF_INTRO

echo
PRIMARY_SOURCE="$(read_source_required "Primary source")"
BACKUP_SOURCE="$(read_backup_source "$PRIMARY_SOURCE")"
ACTIVE_SLOT="$(read_choice "Active slot" "primary" valid_active)"
PRIMARY_SELECTOR="$(read_choice "Primary selector" "first" valid_selector)"
BACKUP_SELECTOR="$(read_choice "Backup selector" "first" valid_selector)"
SOCKS_AUTH="$(read_choice "SOCKS auth policy" "keep" valid_socks_auth)"

echo
echo "== Wizard summary =="
echo "primary source: accepted ($(source_type "$PRIMARY_SOURCE"), $(printf '%s' "$PRIMARY_SOURCE" | wc -c | tr -d ' ') bytes; hidden)"
echo "backup source:  accepted ($(source_type "$BACKUP_SOURCE"), $(printf '%s' "$BACKUP_SOURCE" | wc -c | tr -d ' ') bytes; hidden)"
echo "active slot:    $ACTIVE_SLOT"
echo "primary selector: $PRIMARY_SELECTOR"
echo "backup selector:  $BACKUP_SELECTOR"
echo "SOCKS auth:     $SOCKS_AUTH"

fetch_setup

if [ "$MODE" = "apply" ]; then
    echo
    echo "== Applying phase-1 write-state via guarded setup helper =="
    sh "$SETUP_TMP" \
        --apply --yes --write-state \
        --primary-source "$PRIMARY_SOURCE" \
        --backup-source "$BACKUP_SOURCE" \
        --active "$ACTIVE_SLOT" \
        --primary-selector "$PRIMARY_SELECTOR" \
        --backup-selector "$BACKUP_SELECTOR" \
        --socks-auth "$SOCKS_AUTH"
else
    echo
    echo "== Plan/validation via guarded setup helper =="
    sh "$SETUP_TMP" \
        --apply --yes \
        --primary-source "$PRIMARY_SOURCE" \
        --backup-source "$BACKUP_SOURCE" \
        --active "$ACTIVE_SLOT" \
        --primary-selector "$PRIMARY_SELECTOR" \
        --backup-selector "$BACKUP_SELECTOR" \
        --socks-auth "$SOCKS_AUTH"
    echo
    echo "Plan mode complete. No files were written. Re-run with: xray-go-setup --apply --yes"
fi
