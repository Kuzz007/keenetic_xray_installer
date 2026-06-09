#!/bin/sh
set -eu

# xray-go-size-check - read-only footprint and budget report.
# No files are changed. Raw VLESS/subscription sources are never printed.

MINIMAL_BUDGET_MB="${MINIMAL_BUDGET_MB:-40}"
FULL_BUDGET_MB="${FULL_BUDGET_MB:-80}"
JSON=0

usage() {
    cat <<'USAGE'
xray-go-size-check - read-only size budget check

Usage:
  xray-go-size-check [--minimal-budget-mb N] [--full-budget-mb N]
  xray-go-size-check --json

Default budgets:
  Minimal Go: 40 MB
  Full Go:    80 MB steady-state

No files are changed.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --minimal-budget-mb)
            [ "$#" -ge 2 ] || { echo "ERROR: --minimal-budget-mb requires a value" >&2; exit 2; }
            MINIMAL_BUDGET_MB="$2"
            shift 2
            ;;
        --full-budget-mb)
            [ "$#" -ge 2 ] || { echo "ERROR: --full-budget-mb requires a value" >&2; exit 2; }
            FULL_BUDGET_MB="$2"
            shift 2
            ;;
        --json|json)
            JSON=1
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

case "$MINIMAL_BUDGET_MB" in ''|*[!0-9]*) echo "ERROR: invalid Minimal budget: $MINIMAL_BUDGET_MB" >&2; exit 2 ;; esac
case "$FULL_BUDGET_MB" in ''|*[!0-9]*) echo "ERROR: invalid Full budget: $FULL_BUDGET_MB" >&2; exit 2 ;; esac

mb_to_kb() { echo $(($1 * 1024)); }
kb_to_mb_1dp() {
    kb="${1:-0}"
    awk 'BEGIN { printf "%.1f", '"$kb"' / 1024 }'
}

path_kb() {
    total=0
    for p in "$@"; do
        [ -e "$p" ] || continue
        size="$(du -sk "$p" 2>/dev/null | awk '{print $1}' | tail -n 1)"
        [ -n "$size" ] || size=0
        total=$((total + size))
    done
    echo "$total"
}

glob_kb() {
    total=0
    # shellcheck disable=SC2048,SC2086
    for p in $*; do
        case "$p" in *'*'*) continue ;; esac
        [ -e "$p" ] || continue
        size="$(du -sk "$p" 2>/dev/null | awk '{print $1}' | tail -n 1)"
        [ -n "$size" ] || size=0
        total=$((total + size))
    done
    echo "$total"
}

xray_bin_path() {
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

opt_free_kb() {
    df -Pk /opt 2>/dev/null | awk 'NR==2 {print $4}'
}

opt_used_kb() {
    du -sk /opt 2>/dev/null | awk '{print $1}'
}

budget_status() {
    used="$1"
    budget="$2"
    if [ "$used" -le "$budget" ]; then
        echo OK
    elif [ "$used" -le $((budget + budget / 5)) ]; then
        echo WARN
    else
        echo FAIL
    fi
}

print_component() {
    label="$1"
    kb="$2"
    printf '  %-32s %8s MB\n' "$label:" "$(kb_to_mb_1dp "$kb")"
}

XRAY_DIR="${XRAY_DIR:-/opt/etc/xray}"

XRAY_BIN="$(xray_bin_path)"
XRAY_BIN_KB=0
[ -n "$XRAY_BIN" ] && XRAY_BIN_KB="$(path_kb "$XRAY_BIN")"
GO_RESOLVER_KB="$(path_kb /opt/bin/xray-failover-go)"

CORE_HELPERS_KB="$(path_kb \
    /opt/bin/xray-go \
    /opt/bin/vless-go-update \
    /opt/bin/vless-go-failover \
    /opt/bin/vless-go-socks-auth \
    /opt/bin/failover-go \
    /opt/bin/xray-go-manifest \
    /opt/bin/xray-go-size-check \
    /opt/bin/xray-go-space-gate \
    /opt/bin/xray-go-setup \
    /opt/libexec/vless-go-lock.sh)"

# Minimal state/config is intentionally a precise file list, not the whole
# /opt/etc/xray directory. Existing full installs may keep large routing data,
# old generated artifacts, or user files there; those must not inflate the
# Minimal Go <=40 MB core budget.
STATE_CONFIG_KB="$(path_kb \
    "$XRAY_DIR/config.json" \
    "$XRAY_DIR/xray-go.manifest" \
    "$XRAY_DIR/xray-go.direct-install.plan" \
    "$XRAY_DIR/xray-go.direct-init.plan" \
    "$XRAY_DIR/vless-go.source" \
    "$XRAY_DIR/vless-go.primary" \
    "$XRAY_DIR/vless-go.backup" \
    "$XRAY_DIR/vless-go.active" \
    "$XRAY_DIR/vless-go.primary.selector" \
    "$XRAY_DIR/vless-go.backup.selector" \
    "$XRAY_DIR/vless-go-socks-auth.conf")"
XRAY_DIR_TOTAL_KB="$(path_kb "$XRAY_DIR")"
EXTRA_XRAY_DIR_KB=0
if [ "$XRAY_DIR_TOTAL_KB" -gt "$STATE_CONFIG_KB" ]; then
    EXTRA_XRAY_DIR_KB=$((XRAY_DIR_TOTAL_KB - STATE_CONFIG_KB))
fi

MINIMAL_CORE_KB=$((XRAY_BIN_KB + GO_RESOLVER_KB + CORE_HELPERS_KB + STATE_CONFIG_KB))

OPTIONAL_HELPERS_KB="$(path_kb \
    /opt/bin/vless-go-watchdog \
    /opt/bin/vless-go-recover \
    /opt/bin/vless-go-doctor \
    /opt/bin/vless-go-doctor-summary \
    /opt/bin/vless-go-privacy-check \
    /opt/bin/xray-go-safety-check \
    /opt/bin/vless-go-history \
    /opt/bin/vless-go-cleanup \
    /opt/bin/vless-go-auto-update \
    /opt/bin/xray-go-direct-full \
    /opt/bin/xray-go-direct-uninstall)"

MANUAL_ONLY_KB="$(path_kb /opt/bin/vless-go-xray-core-update)"

INIT_CRON_KB="$(path_kb \
    /opt/etc/init.d/S24xray \
    /opt/etc/init.d/S26vless-go-watchdog \
    /opt/var/spool/cron/crontabs/root)"

LOG_KB="$(path_kb \
    /opt/var/log/vless-go-watchdog.log \
    /opt/var/log/vless-go-watchdog-detail.log \
    /opt/var/log/vless-go-recover.log \
    /opt/var/log/vless-go-history.log)"

XRAY_BACKUP_KB="$(glob_kb /opt/sbin/xray.bak* /opt/sbin/xray.*.bak /opt/bin/xray.bak*)"
GO_BACKUP_KB="$(glob_kb /opt/bin/xray-failover-go.bak*)"
TMP_STAGE_KB="$(glob_kb /opt/tmp/xray-go-* /opt/tmp/vless-go-* /opt/tmp/xray-core-* /opt/tmp/vless-xray-core-*)"

FULL_STEADY_KB=$((MINIMAL_CORE_KB + OPTIONAL_HELPERS_KB + INIT_CRON_KB + LOG_KB))
RECLAIMABLE_KB=$((XRAY_BACKUP_KB + GO_BACKUP_KB + TMP_STAGE_KB))
FULL_WITH_RECLAIMABLE_KB=$((FULL_STEADY_KB + RECLAIMABLE_KB))

MINIMAL_BUDGET_KB="$(mb_to_kb "$MINIMAL_BUDGET_MB")"
FULL_BUDGET_KB="$(mb_to_kb "$FULL_BUDGET_MB")"
MINIMAL_STATUS="$(budget_status "$MINIMAL_CORE_KB" "$MINIMAL_BUDGET_KB")"
FULL_STATUS="$(budget_status "$FULL_STEADY_KB" "$FULL_BUDGET_KB")"
FULL_WITH_RECLAIMABLE_STATUS="$(budget_status "$FULL_WITH_RECLAIMABLE_KB" "$FULL_BUDGET_KB")"

OPT_FREE_KB="$(opt_free_kb || echo 0)"
OPT_USED_KB="$(opt_used_kb || echo 0)"

if [ "$JSON" = 1 ]; then
    printf '{'
    printf '"schema":"xray-go.size.v1"'
    printf ',"minimal_budget_mb":%s' "$MINIMAL_BUDGET_MB"
    printf ',"full_budget_mb":%s' "$FULL_BUDGET_MB"
    printf ',"minimal_core_kb":%s' "$MINIMAL_CORE_KB"
    printf ',"full_steady_kb":%s' "$FULL_STEADY_KB"
    printf ',"manual_only_kb":%s' "$MANUAL_ONLY_KB"
    printf ',"minimal_state_config_kb":%s' "$STATE_CONFIG_KB"
    printf ',"extra_xray_dir_kb":%s' "$EXTRA_XRAY_DIR_KB"
    printf ',"reclaimable_kb":%s' "$RECLAIMABLE_KB"
    printf ',"full_with_reclaimable_kb":%s' "$FULL_WITH_RECLAIMABLE_KB"
    printf ',"minimal_status":"%s"' "$MINIMAL_STATUS"
    printf ',"full_status":"%s"' "$FULL_STATUS"
    printf ',"full_with_reclaimable_status":"%s"' "$FULL_WITH_RECLAIMABLE_STATUS"
    printf ',"opt_free_kb":%s' "${OPT_FREE_KB:-0}"
    printf ',"opt_used_kb":%s' "${OPT_USED_KB:-0}"
    printf '}\n'
    exit 0
fi

cat <<EOF
== Xray Go size-check ==
Read-only: no files are changed.
Raw VLESS/subscription values are not printed.

Budgets:
  Minimal Go: ${MINIMAL_BUDGET_MB} MB
  Full Go:    ${FULL_BUDGET_MB} MB steady-state
EOF

echo
echo "== Components =="
print_component "Xray binary" "$XRAY_BIN_KB"
[ -n "$XRAY_BIN" ] && echo "    path: $XRAY_BIN"
print_component "Go resolver" "$GO_RESOLVER_KB"
print_component "minimal core helpers" "$CORE_HELPERS_KB"
print_component "minimal state/config" "$STATE_CONFIG_KB"
print_component "extra xray dir data" "$EXTRA_XRAY_DIR_KB"
print_component "optional/full-lite helpers" "$OPTIONAL_HELPERS_KB"
print_component "manual-only helpers" "$MANUAL_ONLY_KB"
print_component "init/cron" "$INIT_CRON_KB"
print_component "logs" "$LOG_KB"
print_component "Xray backups" "$XRAY_BACKUP_KB"
print_component "Go resolver backups" "$GO_BACKUP_KB"
print_component "tmp/staging" "$TMP_STAGE_KB"

echo
echo "== Budget estimate =="
printf '  %-32s %8s MB  [%s <= %s MB]\n' "minimal core estimate:" "$(kb_to_mb_1dp "$MINIMAL_CORE_KB")" "$MINIMAL_STATUS" "$MINIMAL_BUDGET_MB"
printf '  %-32s %8s MB  [%s <= %s MB]\n' "full-lite steady estimate:" "$(kb_to_mb_1dp "$FULL_STEADY_KB")" "$FULL_STATUS" "$FULL_BUDGET_MB"
printf '  %-32s %8s MB\n' "manual-only helpers:" "$(kb_to_mb_1dp "$MANUAL_ONLY_KB")"
printf '  %-32s %8s MB  [%s <= %s MB]\n' "full-lite + reclaimable:" "$(kb_to_mb_1dp "$FULL_WITH_RECLAIMABLE_KB")" "$FULL_WITH_RECLAIMABLE_STATUS" "$FULL_BUDGET_MB"
printf '  %-32s %8s MB (%s KB)\n' "reclaimable estimate:" "$(kb_to_mb_1dp "$RECLAIMABLE_KB")" "$RECLAIMABLE_KB"

echo
echo "== /opt filesystem =="
printf '  %-32s %8s MB\n' "/opt used:" "$(kb_to_mb_1dp "${OPT_USED_KB:-0}")"
printf '  %-32s %8s MB\n' "/opt free:" "$(kb_to_mb_1dp "${OPT_FREE_KB:-0}")"

echo
echo "== Policy =="
echo "Minimal Go must keep subscriptions/bot-link flow and fit the 40 MB target."
echo "Minimal state/config counts only xray-go core files, not the whole /opt/etc/xray directory."
echo "xray-go-setup, xray-go-size-check and xray-go-space-gate are part of Minimal so the installer can run first-run setup and post-install adaptive expansion."
echo "Post-install expansion may add watchdog/recovery/summary/basic checks if space allows."
echo "Xray-core update helper is manual-only and excluded from Minimal/full-lite auto expansion."
echo "Xray-core update may create large Xray binary backups and must stay explicit opt-in."

if [ "$MINIMAL_STATUS" = FAIL ]; then
    echo
    echo "[FAIL] Minimal estimate exceeds budget. Check Xray binary size and core helper split."
elif [ "$MINIMAL_STATUS" = WARN ]; then
    echo
    echo "[WARN] Minimal estimate is close to or slightly above budget. Consider stripping optional helpers/backups."
else
    echo
    echo "[OK] Minimal estimate is within budget."
fi

if [ "$FULL_STATUS" = FAIL ]; then
    echo "[FAIL] Full-lite steady estimate exceeds budget. Do not auto-expand before cleanup."
elif [ "$FULL_STATUS" = WARN ]; then
    echo "[WARN] Full-lite steady estimate is near budget. Auto-expansion should be conservative."
else
    echo "[OK] Full-lite steady estimate is within budget."
fi

if [ "$EXTRA_XRAY_DIR_KB" -gt 1024 ]; then
    echo "[INFO] Extra /opt/etc/xray data detected ($(kb_to_mb_1dp "$EXTRA_XRAY_DIR_KB") MB). It is excluded from Minimal budget; inspect before cleanup."
fi

if [ "$MANUAL_ONLY_KB" -gt 0 ]; then
    echo "[INFO] Manual-only helper present: vless-go-xray-core-update ($(kb_to_mb_1dp "$MANUAL_ONLY_KB") MB). It is excluded from Minimal/full-lite budgets."
fi

if [ "$RECLAIMABLE_KB" -gt 0 ]; then
    echo "[INFO] Reclaimable files detected (${RECLAIMABLE_KB} KB). Use cleanup dry-run before deciding profile expansion."
else
    echo "[OK] No reclaimable backup/staging files detected by this check."
fi
