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
    /opt/libexec/vless-go-lock.sh 2>/dev/null || echo 0)"

STATE_CONFIG_KB="$(path_kb /opt/etc/xray)"

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
    /opt/bin/vless-go-xray-core-update \
    /opt/bin/xray-go-direct-full \
    /opt/bin/xray-go-direct-uninstall \
    /opt/bin/xray-go-size-check 2>/dev/null || echo 0)"

INIT_CRON_KB="$(path_kb \
    /opt/etc/init.d/S24xray \
    /opt/etc/init.d/S26vless-go-watchdog \
    /opt/var/spool/cron/crontabs/root 2>/dev/null || echo 0)"

LOG_KB="$(path_kb \
    /opt/var/log/vless-go-watchdog.log \
    /opt/var/log/vless-go-watchdog-detail.log \
    /opt/var/log/vless-go-recover.log \
    /opt/var/log/vless-go-history.log 2>/dev/null || echo 0)"

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
print_component "state/config" "$STATE_CONFIG_KB"
print_component "optional helpers" "$OPTIONAL_HELPERS_KB"
print_component "init/cron" "$INIT_CRON_KB"
print_component "logs" "$LOG_KB"
print_component "Xray backups" "$XRAY_BACKUP_KB"
print_component "Go resolver backups" "$GO_BACKUP_KB"
print_component "tmp/staging" "$TMP_STAGE_KB"

echo
echo "== Budget estimate =="
printf '  %-32s %8s MB  [%s <= %s MB]\n' "minimal core estimate:" "$(kb_to_mb_1dp "$MINIMAL_CORE_KB")" "$MINIMAL_STATUS" "$MINIMAL_BUDGET_MB"
printf '  %-32s %8s MB  [%s <= %s MB]\n' "full steady estimate:" "$(kb_to_mb_1dp "$FULL_STEADY_KB")" "$FULL_STATUS" "$FULL_BUDGET_MB"
printf '  %-32s %8s MB  [%s <= %s MB]\n' "full + reclaimable:" "$(kb_to_mb_1dp "$FULL_WITH_RECLAIMABLE_KB")" "$FULL_WITH_RECLAIMABLE_STATUS" "$FULL_BUDGET_MB"
printf '  %-32s %8s MB\n' "reclaimable estimate:" "$(kb_to_mb_1dp "$RECLAIMABLE_KB")"

echo
echo "== /opt filesystem =="
printf '  %-32s %8s MB\n' "/opt used:" "$(kb_to_mb_1dp "${OPT_USED_KB:-0}")"
printf '  %-32s %8s MB\n' "/opt free:" "$(kb_to_mb_1dp "${OPT_FREE_KB:-0}")"

echo
echo "== Policy =="
echo "Minimal Go must keep subscriptions/bot-link flow and fit the 40 MB target."
echo "Post-install expansion may add watchdog/recovery/summary/basic checks if space allows."
echo "Xray-core update remains manual-only and must not be auto-installed by size expansion."

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
    echo "[FAIL] Full steady estimate exceeds budget. Do not auto-expand before cleanup."
elif [ "$FULL_STATUS" = WARN ]; then
    echo "[WARN] Full steady estimate is near budget. Auto-expansion should be conservative."
else
    echo "[OK] Full steady estimate is within budget."
fi

if [ "$RECLAIMABLE_KB" -gt 0 ]; then
    echo "[INFO] Reclaimable files detected. Use cleanup dry-run before deciding profile expansion."
fi
