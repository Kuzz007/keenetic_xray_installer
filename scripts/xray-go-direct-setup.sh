#!/bin/sh
set -eu

# Keenetic Xray Go direct setup planner.
# Read-only first-run/setup analysis. It does not write sources, config,
# Proxy0 settings, cron, init scripts, or restart services.

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
DIRECT_CHECK_CMD="${DIRECT_CHECK_CMD:-/opt/bin/xray-go-safety-check}"
GO_RESOLVER="${GO_RESOLVER:-/opt/bin/xray-failover-go}"
XRAY_BIN="${XRAY_BIN:-/opt/sbin/xray}"
FAILOVER_HELPER="${FAILOVER_HELPER:-/opt/bin/vless-go-failover}"
UPDATE_HELPER="${UPDATE_HELPER:-/opt/bin/vless-go-update}"
RECOVER_HELPER="${RECOVER_HELPER:-/opt/bin/vless-go-recover}"
DOCTOR_HELPER="${DOCTOR_HELPER:-/opt/bin/vless-go-doctor}"
SUMMARY_HELPER="${SUMMARY_HELPER:-/opt/bin/vless-go-doctor-summary}"

OK=0
WARN=0
FAIL=0

ok() { echo "[OK] $*"; OK=$((OK + 1)); }
warn() { echo "[WARN] $*"; WARN=$((WARN + 1)); }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
info() { echo "$*"; }

manifest_get() {
    key="$1"
    [ -f "$MANIFEST_FILE" ] || return 1
    sed -n "s/^${key}=//p" "$MANIFEST_FILE" 2>/dev/null | tail -n 1
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
    case "$first" in
        vless://*) type="direct vless link" ;;
        http://*|https://*) type="subscription URL" ;;
        *) type="unknown format" ;;
    esac

    case "$type" in
        "unknown format") warn "$label configured but format is unknown; lines=$lines size=${size} bytes"; return 1 ;;
        *) ok "$label configured ($type); lines=$lines size=${size} bytes"; return 0 ;;
    esac
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
    info "Mode: plan"
    info "Version: 0.1.0-direct-setup-plan"
    info "Xray dir: $XRAY_DIR"
    info "This is read-only. No sources, config, Proxy0, cron, init, or services are changed."
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
    info "== Future guarded apply boundary =="
    info "A future --direct-setup apply should require --yes and should not print raw sources."
    info "It should write only setup/runtime files after validation succeeds."
}

print_header
check_direct_layer
check_runtime_state
check_sources
print_setup_plan

info ""
info "== Result =="
info "OK=$OK WARN=$WARN FAIL=$FAIL"
info "Direct setup plan complete. No changes made."

[ "$FAIL" -eq 0 ]
