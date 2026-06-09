#!/bin/sh
set -eu

# xray-go-space-gate - decide whether Minimal Go may expand to full-lite.
#
# Default mode is a non-persistent plan: it stages fresh helper copies in /tmp,
# prints a decision, and cleans the stage. Persistent changes require --apply --yes.
#
# Safety policy:
#   - Minimal must remain valid before any expansion.
#   - full-lite may be installed only if the size budget and free-space margin pass.
#   - vless-go-xray-core-update is never installed by this gate.

REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
STAGE_DIR="${XRAY_GO_SPACE_GATE_STAGE_DIR:-${TMPDIR:-/tmp}/xray-go-space-gate}"
SIZE_CHECK_CMD="${SIZE_CHECK_CMD:-/opt/bin/xray-go-size-check}"
SIZE_CHECK_URL="${SIZE_CHECK_URL:-${RAW_BASE}/scripts/xray-go-size-check.sh}"
HELPER_PROFILE_CMD="${HELPER_PROFILE_CMD:-/opt/bin/xray-go-direct-helper-profile}"
HELPER_PROFILE_URL="${HELPER_PROFILE_URL:-${RAW_BASE}/scripts/xray-go-direct-helper-profile.sh}"

MODE="plan"
YES="0"
TARGET_PROFILE="full-lite"
MINIMAL_BUDGET_MB="${MINIMAL_BUDGET_MB:-40}"
FULL_BUDGET_MB="${FULL_BUDGET_MB:-80}"
MIN_FREE_MB="${SPACE_GATE_MIN_FREE_MB:-8}"
MAX_RECLAIMABLE_MB="${SPACE_GATE_MAX_RECLAIMABLE_MB:-16}"
KEEP_STAGE="0"

usage() {
    cat <<'USAGE'
xray-go-space-gate - Minimal -> full-lite expansion planner

Usage:
  xray-go-space-gate --plan
  xray-go-space-gate --apply --yes

Options:
  --target full-lite          Expansion target. Only full-lite is supported.
  --minimal-budget-mb N       Minimal budget, default 40.
  --full-budget-mb N          Full-lite steady budget, default 80.
  --min-free-mb N             Required /opt free-space margin, default 8.
  --max-reclaimable-mb N      Warn/hold if reclaimable estimate is above N, default 16.
  --keep-stage                Keep /tmp staging files for debugging.

Safety:
  Plan mode is default and makes no persistent changes.
  Apply mode requires --yes.
  This gate never installs vless-go-xray-core-update.
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
        -y|--yes)
            YES="1"
            shift
            ;;
        --target|--profile)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            TARGET_PROFILE="$2"
            shift 2
            ;;
        --minimal-budget-mb)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            MINIMAL_BUDGET_MB="$2"
            shift 2
            ;;
        --full-budget-mb)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            FULL_BUDGET_MB="$2"
            shift 2
            ;;
        --min-free-mb)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            MIN_FREE_MB="$2"
            shift 2
            ;;
        --max-reclaimable-mb)
            [ "$#" -ge 2 ] || { echo "ERROR: $1 requires a value" >&2; exit 2; }
            MAX_RECLAIMABLE_MB="$2"
            shift 2
            ;;
        --keep-stage)
            KEEP_STAGE="1"
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

case "$TARGET_PROFILE" in
    full-lite|lite) TARGET_PROFILE="full-lite" ;;
    *) echo "ERROR: unsupported target profile: $TARGET_PROFILE" >&2; echo "Only full-lite is allowed by space-gate." >&2; exit 2 ;;
esac

for n in "$MINIMAL_BUDGET_MB" "$FULL_BUDGET_MB" "$MIN_FREE_MB" "$MAX_RECLAIMABLE_MB"; do
    case "$n" in ''|*[!0-9]*) echo "ERROR: numeric option expected, got: $n" >&2; exit 2 ;; esac
done

[ "$MODE" = "plan" ] || [ "$YES" = "1" ] || { echo "ERROR: --apply requires --yes" >&2; exit 2; }

cleanup_stage() {
    [ "$KEEP_STAGE" = "1" ] && { echo "Keeping stage dir: $STAGE_DIR"; return 0; }
    case "$STAGE_DIR" in
        /tmp/xray-go-space-gate|/tmp/xray-go-space-gate/*|/opt/tmp/xray-go-space-gate|/opt/tmp/xray-go-space-gate/*)
            rm -rf "$STAGE_DIR" 2>/dev/null || true
            ;;
    esac
}
trap cleanup_stage EXIT INT TERM

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

verify_shell() {
    file="$1"
    label="$2"
    sh -n "$file" || { echo "ERROR: shell syntax check failed for $label" >&2; exit 1; }
}

stage_script() {
    url="$1"
    fallback="$2"
    name="$3"
    mkdir -p "$STAGE_DIR"
    staged="$STAGE_DIR/$name"
    if fetch_url "$url" "$staged"; then
        verify_shell "$staged" "$name"
        chmod +x "$staged"
        echo "$staged"
        return 0
    fi
    if [ -x "$fallback" ]; then
        echo "WARN: using installed fallback for $name: $fallback" >&2
        echo "$fallback"
        return 0
    fi
    echo "ERROR: cannot fetch $name and fallback is not executable: $fallback" >&2
    return 1
}

json_string() {
    key="$1"
    printf '%s\n' "$SIZE_JSON" | sed -n 's/.*"'"$key"'":"\([^"]*\)".*/\1/p'
}

json_number() {
    key="$1"
    value="$(printf '%s\n' "$SIZE_JSON" | sed -n 's/.*"'"$key"'":\([0-9][0-9]*\).*/\1/p')"
    [ -n "$value" ] || value=0
    echo "$value"
}

kb_to_mb_1dp() {
    kb="${1:-0}"
    awk 'BEGIN { printf "%.1f", '"$kb"' / 1024 }'
}

SIZE_SCRIPT="$(stage_script "$SIZE_CHECK_URL" "$SIZE_CHECK_CMD" xray-go-size-check)"
SIZE_JSON="$($SIZE_SCRIPT --minimal-budget-mb "$MINIMAL_BUDGET_MB" --full-budget-mb "$FULL_BUDGET_MB" --json)"

MINIMAL_STATUS="$(json_string minimal_status)"
FULL_STATUS="$(json_string full_status)"
FULL_WITH_RECLAIMABLE_STATUS="$(json_string full_with_reclaimable_status)"
MINIMAL_CORE_KB="$(json_number minimal_core_kb)"
FULL_STEADY_KB="$(json_number full_steady_kb)"
RECLAIMABLE_KB="$(json_number reclaimable_kb)"
EXTRA_XRAY_DIR_KB="$(json_number extra_xray_dir_kb)"
OPT_FREE_KB="$(json_number opt_free_kb)"
MANUAL_ONLY_KB="$(json_number manual_only_kb)"

MIN_FREE_KB=$((MIN_FREE_MB * 1024))
MAX_RECLAIMABLE_KB=$((MAX_RECLAIMABLE_MB * 1024))

DECISION="expand"
REASONS=""
add_reason() {
    REASONS="${REASONS}${REASONS:+\n}- $*"
}

if [ "$MINIMAL_STATUS" != "OK" ]; then
    DECISION="hold"
    add_reason "Minimal budget status is $MINIMAL_STATUS; expansion is blocked."
fi

if [ "$FULL_STATUS" != "OK" ]; then
    DECISION="hold"
    add_reason "Full-lite steady budget status is $FULL_STATUS."
fi

if [ "$OPT_FREE_KB" -lt "$MIN_FREE_KB" ]; then
    DECISION="hold"
    add_reason "/opt free is $(kb_to_mb_1dp "$OPT_FREE_KB") MB, below required ${MIN_FREE_MB} MB margin."
fi

if [ "$RECLAIMABLE_KB" -gt "$MAX_RECLAIMABLE_KB" ]; then
    DECISION="hold"
    add_reason "Reclaimable estimate is $(kb_to_mb_1dp "$RECLAIMABLE_KB") MB, above ${MAX_RECLAIMABLE_MB} MB; run cleanup dry-run first."
fi

case "$FULL_WITH_RECLAIMABLE_STATUS" in
    FAIL)
        DECISION="hold"
        add_reason "Full-lite + reclaimable status is FAIL; cleanup should run before expansion."
        ;;
    WARN)
        add_reason "Full-lite + reclaimable status is WARN; expansion is still allowed if reclaimable is within threshold."
        ;;
esac

if [ "$MANUAL_ONLY_KB" -gt 0 ]; then
    add_reason "Manual-only helpers are present ($(kb_to_mb_1dp "$MANUAL_ONLY_KB") MB) but excluded from this gate."
fi

if [ "$EXTRA_XRAY_DIR_KB" -gt 1024 ]; then
    add_reason "Extra /opt/etc/xray data exists ($(kb_to_mb_1dp "$EXTRA_XRAY_DIR_KB") MB) and is excluded from Minimal budget."
fi

echo "== Xray Go space-gate =="
echo "Mode: $MODE"
echo "Target: $TARGET_PROFILE"
echo "Minimal budget: ${MINIMAL_BUDGET_MB} MB"
echo "Full-lite budget: ${FULL_BUDGET_MB} MB"
echo "Required /opt free margin: ${MIN_FREE_MB} MB"
echo "Max reclaimable before hold: ${MAX_RECLAIMABLE_MB} MB"
echo
echo "== Size snapshot =="
printf '  %-28s %8s MB  [%s]\n' "minimal core:" "$(kb_to_mb_1dp "$MINIMAL_CORE_KB")" "$MINIMAL_STATUS"
printf '  %-28s %8s MB  [%s]\n' "full-lite steady:" "$(kb_to_mb_1dp "$FULL_STEADY_KB")" "$FULL_STATUS"
printf '  %-28s %8s MB  [%s]\n' "reclaimable:" "$(kb_to_mb_1dp "$RECLAIMABLE_KB")" "$FULL_WITH_RECLAIMABLE_STATUS"
printf '  %-28s %8s MB\n' "/opt free:" "$(kb_to_mb_1dp "$OPT_FREE_KB")"
printf '  %-28s %8s MB\n' "extra xray dir data:" "$(kb_to_mb_1dp "$EXTRA_XRAY_DIR_KB")"
printf '  %-28s %8s MB\n' "manual-only helpers:" "$(kb_to_mb_1dp "$MANUAL_ONLY_KB")"
echo
echo "== Decision =="
if [ "$DECISION" = "expand" ]; then
    echo "[OK] Expansion to full-lite is allowed."
else
    echo "[HOLD] Keep Minimal Go for now."
fi

if [ -n "$REASONS" ]; then
    printf '%s\n' "$REASONS"
fi

echo
echo "Policy: xray-core update is manual-only and will not be installed by space-gate."

if [ "$MODE" = "plan" ]; then
    echo "Plan mode: no persistent changes made."
    exit 0
fi

if [ "$DECISION" != "expand" ]; then
    echo "Apply skipped: decision is HOLD."
    exit 0
fi

PROFILE_SCRIPT="$(stage_script "$HELPER_PROFILE_URL" "$HELPER_PROFILE_CMD" xray-go-direct-helper-profile)"
echo
sh "$PROFILE_SCRIPT" --profile "$TARGET_PROFILE" --apply --yes

echo
echo "Space-gate apply complete: $TARGET_PROFILE installed without xray-core updater."
