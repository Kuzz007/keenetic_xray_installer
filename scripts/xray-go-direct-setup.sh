#!/bin/sh
set -eu

# Keenetic Xray Go direct setup planner / guarded scaffold.
# Plan mode is read-only first-run/setup analysis.
# Apply mode is guarded. By default it is read-only; phase-1 state writes are
# enabled only with explicit --write-state and still do not generate config,
# change Proxy0, edit cron/init, or restart services.

XRAY_DIR="${XRAY_DIR:-/opt/etc/xray}"
MANIFEST_FILE="$XRAY_DIR/xray-go.manifest"
CONFIG_FILE="$XRAY_DIR/config.json"
SOURCE_STORE="$XRAY_DIR/vless-go.source"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
PRIMARY_SELECTOR="$XRAY_DIR/vless-go.primary.selector"
BACKUP_SELECTOR="$XRAY_DIR/vless-go.backup.selector"
SOCKS_AUTH_CONF="$XRAY_DIR/vless-go-socks-auth.conf"
WATCHDOG_CONF="$XRAY_DIR/vless-go-watchdog.conf"
DIRECT_INSTALL_PLAN="$XRAY_DIR/xray-go.direct-install.plan"
DIRECT_INIT_PLAN="$XRAY_DIR/xray-go.direct-init.plan"
GO_RESOLVER="${GO_RESOLVER:-/opt/bin/xray-failover-go}"
XRAY_BIN="${XRAY_BIN:-/opt/sbin/xray}"
FAILOVER_HELPER="${FAILOVER_HELPER:-/opt/bin/vless-go-failover}"
UPDATE_HELPER="${UPDATE_HELPER:-/opt/bin/vless-go-update}"
RECOVER_HELPER="${RECOVER_HELPER:-/opt/bin/vless-go-recover}"
DOCTOR_HELPER="${DOCTOR_HELPER:-/opt/bin/vless-go-doctor}"
SUMMARY_HELPER="${SUMMARY_HELPER:-/opt/bin/vless-go-doctor-summary}"

MODE="plan"
YES=0
OK=0
WARN=0
FAIL=0

ARG_PRIMARY_SOURCE=""
ARG_BACKUP_SOURCE=""
ARG_ACTIVE=""
ARG_PRIMARY_SELECTOR=""
ARG_BACKUP_SELECTOR=""
ARG_SOCKS_AUTH=""
INPUT_ARGS_SEEN=0
WRITE_STATE=0
FORCE_STATE_OVERWRITE=0
WRITE_STATE_READY=0

usage() {
    cat <<'USAGE'
Keenetic Xray Go direct setup planner

Usage:
  xray-go-direct-setup.sh [--plan]
  xray-go-direct-setup.sh --apply --yes [setup inputs]
  xray-go-direct-setup.sh --apply --yes --write-state [setup inputs]

Modes:
  --plan          Read-only setup analysis. Default.
  --apply --yes   Guarded setup apply scaffold.

Validation-only setup inputs:
  --primary-source SRC             vless://, http:// or https:// single-line source
  --backup-source SRC              vless://, http:// or https:// single-line source
  --active primary|backup          active slot for future apply
  --primary-selector first|index:N primary subscription selector
  --backup-selector first|index:N  backup subscription selector
  --socks-auth auto|keep|disable   future SOCKS auth policy

Phase-1 real apply:
  --write-state                    Write only source/state/selector files.
  --force-state-overwrite          Allow replacing existing state files.

Phase-1 write-state does not generate config.json, change Proxy0, edit cron/init, or restart services.
Raw source values and credentials are never printed.
USAGE
}

require_arg() {
    opt="$1"
    [ "$#" -ge 2 ] || { echo "ERROR: $opt requires a value." >&2; exit 2; }
    [ -n "$2" ] || { echo "ERROR: $opt value must not be empty." >&2; exit 2; }
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --plan|--dry-run)
            MODE="plan"
            ;;
        --apply)
            MODE="apply"
            ;;
        --yes|-y)
            YES=1
            ;;
        --write-state)
            WRITE_STATE=1
            ;;
        --force-state-overwrite)
            FORCE_STATE_OVERWRITE=1
            ;;
        --primary-source)
            require_arg "$1" "${2:-}"
            ARG_PRIMARY_SOURCE="$2"
            INPUT_ARGS_SEEN=1
            shift
            ;;
        --backup-source)
            require_arg "$1" "${2:-}"
            ARG_BACKUP_SOURCE="$2"
            INPUT_ARGS_SEEN=1
            shift
            ;;
        --active)
            require_arg "$1" "${2:-}"
            ARG_ACTIVE="$2"
            INPUT_ARGS_SEEN=1
            shift
            ;;
        --primary-selector)
            require_arg "$1" "${2:-}"
            ARG_PRIMARY_SELECTOR="$2"
            INPUT_ARGS_SEEN=1
            shift
            ;;
        --backup-selector)
            require_arg "$1" "${2:-}"
            ARG_BACKUP_SELECTOR="$2"
            INPUT_ARGS_SEEN=1
            shift
            ;;
        --socks-auth)
            require_arg "$1" "${2:-}"
            ARG_SOCKS_AUTH="$2"
            INPUT_ARGS_SEEN=1
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
    shift
done

if [ "$MODE" = "apply" ] && [ "$YES" != 1 ]; then
    echo "ERROR: --apply requires --yes." >&2
    echo "This guarded scaffold requires explicit confirmation." >&2
    exit 2
fi

if [ "$WRITE_STATE" = 1 ] && { [ "$MODE" != "apply" ] || [ "$YES" != 1 ]; }; then
    echo "ERROR: --write-state requires --apply --yes." >&2
    exit 2
fi

if [ "$WRITE_STATE" = 1 ] && [ "$FORCE_STATE_OVERWRITE" = 1 ]; then
    echo "ERROR: --force-state-overwrite is reserved for a later repair mode and is disabled in this build." >&2
    exit 2
fi

[ -n "$ARG_PRIMARY_SELECTOR" ] || ARG_PRIMARY_SELECTOR="first"
[ -n "$ARG_BACKUP_SELECTOR" ] || ARG_BACKUP_SELECTOR="first"
[ -n "$ARG_SOCKS_AUTH" ] || ARG_SOCKS_AUTH="keep"

ok() { echo "[OK] $*"; OK=$((OK + 1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
info() { echo "$*"; }

trim_value() {
    printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

strip_manifest_quotes() {
    value="$(trim_value "$1")"
    first="$(printf '%s' "$value" | cut -c 1 2>/dev/null || true)"
    last="$(printf '%s' "$value" | sed 's/^.*\(.\)$/\1/' 2>/dev/null || true)"
    if [ "$first" = '"' ] && [ "$last" = '"' ]; then
        value="${value#\"}"
        value="${value%\"}"
    elif [ "$first" = "'" ] && [ "$last" = "'" ]; then
        value="${value#\'}"
        value="${value%\'}"
    fi
    trim_value "$value"
}

manifest_get() {
    key="$1"
    [ -f "$MANIFEST_FILE" ] || return 1
    value="$(sed -n "s/^${key}=//p" "$MANIFEST_FILE" 2>/dev/null | tail -n 1)"
    [ -n "$value" ] || return 1
    strip_manifest_quotes "$value"
}

sha256_file() {
    file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
        return 0
    fi
    if command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" | awk '{print $NF}'
        return 0
    fi
    return 1
}

source_type() {
    value="$1"
    case "$value" in
        vless://*) printf '%s\n' "direct vless link" ;;
        http://*|https://*) printf '%s\n' "subscription URL" ;;
        *) printf '%s\n' "unknown format" ;;
    esac
}

validate_source_value() {
    value="$1"
    [ -n "$value" ] || return 1
    line_count="$(printf '%s\n' "$value" | wc -l | tr -d ' ')"
    [ "$line_count" = "1" ] || return 1
    case "$(source_type "$value")" in
        "direct vless link"|"subscription URL") return 0 ;;
        *) return 1 ;;
    esac
}

source_input_state() {
    value="$1"
    label="$2"
    if validate_source_value "$value"; then
        type="$(source_type "$value")"
        size="$(printf '%s' "$value" | wc -c | tr -d ' ')"
        ok "$label input valid ($type); size=${size} bytes"
    else
        fail "$label input invalid; raw value is not printed"
    fi
}

valid_selector_value() {
    value="$1"
    case "$value" in
        first) return 0 ;;
        index:*)
            n="${value#index:}"
            case "$n" in
                ''|*[!0-9]*|0) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

valid_active_slot() {
    case "$1" in
        primary|backup) return 0 ;;
        *) return 1 ;;
    esac
}

valid_socks_auth_policy() {
    case "$1" in
        auto|keep|disable) return 0 ;;
        *) return 1 ;;
    esac
}

file_state() {
    path="$1"
    label="$2"
    if [ -s "$path" ]; then
        size="$(wc -c < "$path" 2>/dev/null | tr -d ' ' || echo '?')"
        ok "$label present: $path (${size} bytes)"
        return 0
    fi
    if [ -e "$path" ]; then
        warn "$label exists but is empty: $path"
        return 1
    fi
    warn "$label missing: $path"
    return 1
}

classify_source_file() {
    path="$1"
    label="$2"
    if [ ! -s "$path" ]; then
        warn "$label not configured: $path"
        return 1
    fi

    first="$(sed -n '1p' "$path" 2>/dev/null || true)"
    lines="$(wc -l < "$path" 2>/dev/null | tr -d ' ' || echo '?')"
    size="$(wc -c < "$path" 2>/dev/null | tr -d ' ' || echo '?')"
    type="$(source_type "$first")"

    case "$type" in
        "unknown format") warn "$label configured but format is unknown; lines=$lines size=${size} bytes"; return 1 ;;
        *) ok "$label configured ($type); lines=$lines size=${size} bytes"; return 0 ;;
    esac
}

selector_state() {
    path="$1"
    label="$2"
    if [ ! -s "$path" ]; then
        warn "$label selector missing; default would be first"
        return 1
    fi
    value="$(sed -n '1p' "$path" 2>/dev/null || true)"
    if valid_selector_value "$value"; then
        ok "$label selector valid: $value"
    else
        warn "$label selector invalid or unsupported; value is not printed"
        return 1
    fi
}

find_xray_init() {
    for f in /opt/etc/init.d/*xray* /opt/etc/init.d/*Xray*; do
        [ -e "$f" ] || continue
        case "$f" in
            *watchdog*|*Watchdog*) continue ;;
        esac
        [ -x "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

init_status_line() {
    init="$1"
    [ -x "$init" ] || return 1
    "$init" status 2>&1 | head -n 1 || true
}

proxy0_exists() {
    if command -v ndmc >/dev/null 2>&1; then
        ndmc -c 'show interface Proxy0' >/dev/null 2>&1
        return $?
    fi
    return 2
}

xray_config_valid() {
    [ -x "$XRAY_BIN" ] || return 1
    [ -s "$CONFIG_FILE" ] || return 1
    "$XRAY_BIN" run -test -config "$CONFIG_FILE" >/dev/null 2>&1
}

print_header() {
    info "Keenetic Xray Go direct setup planner"
    info "Mode: $MODE"
    info "Version: 0.1.5-direct-setup-write-state"
    info "Xray dir: $XRAY_DIR"
    if [ "$MODE" = "apply" ]; then
        info "Guarded setup apply scaffold. Confirmation accepted: --apply --yes"
    fi
    if [ "$WRITE_STATE" = 1 ]; then
        info "Phase-1 state write requested. Only source/state/selector files may be changed."
        info "Config, Proxy0, cron, init, Xray and watchdog services are not changed."
    else
        info "This is read-only. No sources, config, Proxy0, cron, init, or services are changed."
    fi
}

check_direct_layer() {
    info ""
    info "== Direct layer =="

    if [ -s "$MANIFEST_FILE" ]; then
        ok "manifest present: $MANIFEST_FILE"
        mode="$(manifest_get INSTALL_MODE || true)"
        edition="$(manifest_get EDITION || true)"
        version="$(manifest_get VERSION || true)"
        arch="$(manifest_get ARCH || true)"
        modules="$(manifest_get MODULES || true)"
        [ "$mode" = "direct" ] && ok "manifest install mode: direct" || warn "manifest install mode is not direct: ${mode:-unknown}"
        [ -n "$edition" ] && ok "manifest edition: $edition" || warn "manifest edition missing"
        [ -n "$version" ] && info "  version: $version"
        [ -n "$arch" ] && info "  arch: $arch"
        [ -n "$modules" ] && info "  modules: $modules"
    else
        warn "manifest missing: $MANIFEST_FILE"
        warn "direct setup would normally run after direct code layer is installed"
    fi

    if [ -x "$GO_RESOLVER" ]; then
        ok "Go resolver executable: $GO_RESOLVER"
        expected_sha="$(manifest_get BINARY_SHA256 || true)"
        if [ -n "$expected_sha" ]; then
            current_sha="$(sha256_file "$GO_RESOLVER" 2>/dev/null || true)"
            if [ "$current_sha" = "$expected_sha" ]; then
                ok "Go resolver sha256 matches manifest"
            else
                warn "Go resolver sha256 does not match manifest"
            fi
        fi
    else
        warn "Go resolver missing: $GO_RESOLVER"
    fi

    file_state "$DIRECT_INSTALL_PLAN" "direct-install plan" || true
    file_state "$DIRECT_INIT_PLAN" "direct-init plan" || true

    for helper in "$FAILOVER_HELPER" "$UPDATE_HELPER" "$RECOVER_HELPER" "$DOCTOR_HELPER" "$SUMMARY_HELPER"; do
        if [ -x "$helper" ]; then
            ok "helper executable: $helper"
        else
            warn "helper missing: $helper"
        fi
    done
}

check_runtime_state() {
    info ""
    info "== Runtime state =="

    if [ -s "$CONFIG_FILE" ]; then
        ok "Xray config present: $CONFIG_FILE"
        if xray_config_valid; then
            ok "Xray config validates"
        else
            warn "Xray config does not validate or Xray binary is unavailable"
        fi
    else
        warn "Xray config missing: $CONFIG_FILE"
    fi

    if [ -x "$XRAY_BIN" ]; then
        ok "Xray binary executable: $XRAY_BIN"
        "$XRAY_BIN" version 2>/dev/null | head -n 1 | sed 's/^/  /' || true
    else
        warn "Xray binary missing: $XRAY_BIN"
    fi

    xray_init="$(find_xray_init 2>/dev/null || true)"
    if [ -n "$xray_init" ]; then
        ok "Xray init found: $xray_init"
        status="$(init_status_line "$xray_init" || true)"
        [ -n "$status" ] && info "  status: $status"
    else
        warn "Xray init script not found under /opt/etc/init.d"
    fi

    if [ -x /opt/etc/init.d/S26vless-go-watchdog ]; then
        ok "watchdog init found: /opt/etc/init.d/S26vless-go-watchdog"
        status="$(/opt/etc/init.d/S26vless-go-watchdog status 2>&1 | head -n 1 || true)"
        [ -n "$status" ] && info "  status: $status"
    else
        warn "watchdog init missing: /opt/etc/init.d/S26vless-go-watchdog"
    fi

    case "$(proxy0_exists; echo $?)" in
        0) ok "Proxy0 interface exists" ;;
        2) warn "ndmc not found; Proxy0 check skipped" ;;
        *) warn "Proxy0 interface not found or not readable" ;;
    esac
}

check_sources() {
    info ""
    info "== Source/config inputs =="
    info "Raw VLESS/subscription values are not printed."

    classify_source_file "$SOURCE_STORE" "current source" || true
    classify_source_file "$PRIMARY_STORE" "primary source" || true
    classify_source_file "$BACKUP_STORE" "backup source" || true

    if [ -s "$ACTIVE_STORE" ]; then
        active="$(sed -n '1p' "$ACTIVE_STORE" 2>/dev/null || true)"
        case "$active" in
            primary|backup) ok "active slot valid: $active" ;;
            *) warn "active slot is invalid or unknown; value is not printed" ;;
        esac
    else
        warn "active slot file missing: $ACTIVE_STORE"
    fi

    selector_state "$PRIMARY_SELECTOR" "primary" || true
    selector_state "$BACKUP_SELECTOR" "backup" || true

    file_state "$SOCKS_AUTH_CONF" "SOCKS auth config" || true
    file_state "$WATCHDOG_CONF" "watchdog config" || true
}

check_input_args() {
    info ""
    info "== Setup input validation =="
    info "Raw setup input values are not printed."

    if [ "$INPUT_ARGS_SEEN" != 1 ]; then
        info "No explicit setup input arguments supplied. Existing state only."
        return 0
    fi

    [ -n "$ARG_PRIMARY_SOURCE" ] && source_input_state "$ARG_PRIMARY_SOURCE" "primary source"
    [ -n "$ARG_BACKUP_SOURCE" ] && source_input_state "$ARG_BACKUP_SOURCE" "backup source"

    if [ -n "$ARG_ACTIVE" ]; then
        if valid_active_slot "$ARG_ACTIVE"; then
            ok "active input valid: $ARG_ACTIVE"
        else
            fail "active input invalid; supported values: primary, backup"
        fi
    fi

    if [ -n "$ARG_PRIMARY_SELECTOR" ]; then
        if valid_selector_value "$ARG_PRIMARY_SELECTOR"; then
            ok "primary selector input valid: $ARG_PRIMARY_SELECTOR"
        else
            fail "primary selector input invalid; supported values: first, index:N"
        fi
    fi

    if [ -n "$ARG_BACKUP_SELECTOR" ]; then
        if valid_selector_value "$ARG_BACKUP_SELECTOR"; then
            ok "backup selector input valid: $ARG_BACKUP_SELECTOR"
        else
            fail "backup selector input invalid; supported values: first, index:N"
        fi
    fi

    if [ -n "$ARG_SOCKS_AUTH" ]; then
        if valid_socks_auth_policy "$ARG_SOCKS_AUTH"; then
            ok "SOCKS auth policy input valid: $ARG_SOCKS_AUTH"
        else
            fail "SOCKS auth policy input invalid; supported values: auto, keep, disable"
        fi
    fi

    if [ "$WRITE_STATE" = 1 ]; then
        info "State write requested. Inputs are validated before any file write."
    elif [ "$MODE" = "apply" ]; then
        info "Input validation only. No files are written in this build."
    else
        info "Input preview only. No files are written."
    fi
}

print_write_item() {
    label="$1"
    target="$2"
    condition="$3"
    [ -n "$condition" ] || return 0
    info "  - $label -> $target"
}

print_staged_write_plan() {
    info ""
    info "== Staged write plan =="

    if [ "$INPUT_ARGS_SEEN" != 1 ]; then
        info "No explicit setup input arguments supplied; no staged writes planned."
        return 0
    fi

    if [ "$WRITE_STATE" = 1 ]; then
        info "Phase-1 state write requested. Config/service operations remain disabled."
    else
        info "No files are written in this build. This is a future real-apply plan only."
    fi
    info "Future target writes after validation succeeds:"
    print_write_item "primary source" "$PRIMARY_STORE" "$ARG_PRIMARY_SOURCE"
    print_write_item "backup source" "$BACKUP_STORE" "$ARG_BACKUP_SOURCE"
    print_write_item "active slot" "$ACTIVE_STORE" "$ARG_ACTIVE"
    print_write_item "primary selector" "$PRIMARY_SELECTOR" "$ARG_PRIMARY_SELECTOR"
    print_write_item "backup selector" "$BACKUP_SELECTOR" "$ARG_BACKUP_SELECTOR"

    if [ -n "$ARG_ACTIVE" ]; then
        info "  - current source -> $SOURCE_STORE (from selected active slot)"
    fi

    if [ -n "$ARG_SOCKS_AUTH" ]; then
        case "$ARG_SOCKS_AUTH" in
            auto) info "  - SOCKS auth -> $SOCKS_AUTH_CONF (preserve existing or generate if missing)" ;;
            keep) info "  - SOCKS auth -> $SOCKS_AUTH_CONF (preserve existing only)" ;;
            disable) info "  - SOCKS auth -> disabled policy (no credentials would be printed)" ;;
        esac
    fi

    info ""
    info "Backup and atomic-write rules for future real apply:"
    info "  - create $XRAY_DIR before writes"
    info "  - backup existing targets as <path>.bak.<timestamp> before replace"
    info "  - write each target to <path>.tmp.$$ first"
    info "  - chmod 600 for source/selector/auth/state files"
    info "  - atomically mv temp file into place only after write succeeds"
    info "  - never print raw source values or generated credentials"

    info ""
    info "Future config/service sequence after staged state writes:"
    info "  - generate active config through $FAILOVER_HELPER update-active --no-restart"
    info "  - validate config with $XRAY_BIN run -test -config $CONFIG_FILE"
    info "  - only after config validation: restart Xray/watchdog if required"
    info "  - run xray-go summary, xray-go doctor --support, xray-go privacy-check, xray-go safety-check"
}

state_target_exists() {
    [ -e "$PRIMARY_STORE" ] || [ -e "$BACKUP_STORE" ] || [ -e "$ACTIVE_STORE" ] || [ -e "$SOURCE_STORE" ] || [ -e "$PRIMARY_SELECTOR" ] || [ -e "$BACKUP_SELECTOR" ]
}

validate_write_state_request() {
    [ "$WRITE_STATE" = 1 ] || return 0

    info ""
    info "== Write-state guard =="

    if [ -z "$ARG_PRIMARY_SOURCE" ]; then fail "--write-state requires --primary-source"; fi
    if [ -z "$ARG_BACKUP_SOURCE" ]; then fail "--write-state requires --backup-source"; fi
    if [ -z "$ARG_ACTIVE" ]; then fail "--write-state requires --active primary|backup"; fi

    if state_target_exists && [ "$FORCE_STATE_OVERWRITE" != 1 ]; then
        fail "write-state refused: existing state/source/selector files are present; no changes made"
        info "This protects configured routers from accidental overwrite. Fresh installs should have no existing state files."
    fi

    if [ "$FAIL" -eq 0 ]; then
        WRITE_STATE_READY=1
        ok "write-state guard passed: phase-1 state files may be written"
    else
        info "write-state skipped because guard checks failed."
    fi
}

backup_existing_file() {
    path="$1"
    [ -e "$path" ] || return 0
    ts="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo $$)"
    backup="$path.bak.$ts"
    cp -p "$path" "$backup" 2>/dev/null || cp "$path" "$backup"
    chmod 600 "$backup" 2>/dev/null || true
    info "  backup: $path -> $backup"
}

atomic_write_file() {
    path="$1"
    value="$2"
    label="$3"
    tmp="$path.tmp.$$"
    mkdir -p "$(dirname "$path")"
    backup_existing_file "$path"
    umask 077
    printf '%s\n' "$value" > "$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$path"
    ok "wrote $label: $path"
}

selected_active_source() {
    case "$ARG_ACTIVE" in
        primary) printf '%s\n' "$ARG_PRIMARY_SOURCE" ;;
        backup) printf '%s\n' "$ARG_BACKUP_SOURCE" ;;
        *) return 1 ;;
    esac
}

apply_write_state_phase1() {
    [ "$WRITE_STATE" = 1 ] || return 0

    info ""
    info "== Write-state phase 1 =="

    if [ "$WRITE_STATE_READY" != 1 ]; then
        info "No changes made. Write-state phase was not authorized by guard checks."
        return 0
    fi

    active_source="$(selected_active_source)"
    atomic_write_file "$PRIMARY_STORE" "$ARG_PRIMARY_SOURCE" "primary source"
    atomic_write_file "$BACKUP_STORE" "$ARG_BACKUP_SOURCE" "backup source"
    atomic_write_file "$ACTIVE_STORE" "$ARG_ACTIVE" "active slot"
    atomic_write_file "$PRIMARY_SELECTOR" "$ARG_PRIMARY_SELECTOR" "primary selector"
    atomic_write_file "$BACKUP_SELECTOR" "$ARG_BACKUP_SELECTOR" "backup selector"
    atomic_write_file "$SOURCE_STORE" "$active_source" "current source"

    info "Phase-1 state write complete. Config generation and service restart were not executed."
}

print_setup_plan() {
    info ""
    info "== Setup plan classification =="

    have_config=0
    have_primary=0
    have_backup=0
    have_active=0
    have_manifest=0
    [ -s "$CONFIG_FILE" ] && have_config=1
    [ -s "$PRIMARY_STORE" ] && have_primary=1
    [ -s "$BACKUP_STORE" ] && have_backup=1
    [ -s "$ACTIVE_STORE" ] && have_active=1
    [ -s "$MANIFEST_FILE" ] && have_manifest=1

    if [ "$have_config" = 1 ] && [ "$have_primary" = 1 ] && [ "$have_backup" = 1 ] && [ "$have_active" = 1 ] && [ "$have_manifest" = 1 ]; then
        ok "existing configured Full Go/direct runtime detected"
        info "Plan: direct first-run setup would be a no-op unless a future --force/repair mode is requested."
    else
        warn "fresh or incomplete setup detected"
        info "Plan for future direct setup apply:"
        [ "$have_manifest" = 1 ] || info "  - install direct code layer first: install.sh --direct-apply --yes"
        [ "$have_primary" = 1 ] || info "  - require primary source input"
        [ "$have_backup" = 1 ] || info "  - require backup source input or explicit single-source mode"
        [ "$have_active" = 1 ] || info "  - select active slot: primary or backup"
        [ "$have_config" = 1 ] || info "  - generate and validate $CONFIG_FILE"
        info "  - configure SOCKS auth policy"
        info "  - ensure Proxy0 points at 127.0.0.1:10808"
        info "  - start/restart Xray and watchdog only after config validation"
        info "  - run summary, doctor, privacy-check and safety-check"
    fi

    info ""
    info "== Guarded apply boundary =="
    if [ "$WRITE_STATE" = 1 ]; then
        info "Confirmation accepted: --apply --yes --write-state"
        info "Phase-1 writes only source/state/selector files after guard checks."
        info "Config, Proxy0, cron, init and services are not changed."
    elif [ "$MODE" = "apply" ]; then
        info "Confirmation accepted: --apply --yes"
        info "No changes made in this build. Real setup apply is intentionally disabled."
        info "Validated safety boundary: sources/config/Proxy0/cron/init/services were not changed."
    else
        info "A future --direct-setup apply should require --yes and should not print raw sources."
        info "It should write only setup/runtime files after validation succeeds."
    fi
}

print_header
check_direct_layer
check_runtime_state
check_sources
check_input_args
print_staged_write_plan
validate_write_state_request
apply_write_state_phase1
print_setup_plan

info ""
info "== Result =="
info "OK=$OK WARN=$WARN FAIL=$FAIL"
if [ "$WRITE_STATE" = 1 ]; then
    if [ "$WRITE_STATE_READY" = 1 ]; then
        info "Direct setup write-state phase complete. Config/services unchanged."
    else
        info "Direct setup write-state phase refused. No changes made."
    fi
elif [ "$MODE" = "apply" ]; then
    info "Direct setup guarded scaffold complete. No changes made."
else
    info "Direct setup plan complete. No changes made."
fi

[ "$FAIL" -eq 0 ]