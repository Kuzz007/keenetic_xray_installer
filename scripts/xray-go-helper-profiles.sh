#!/bin/sh
set -eu

# xray-go-helper-profiles - profile-aware helper lists for direct-install v2.
#
# This file is intentionally read-only/list-only. It does not install anything.
# It defines which shell helpers belong to Minimal Go, full-lite auto expansion,
# and manual-only maintenance.
#
# Policy:
#   minimal   = subscriptions + selector + primary/backup + Proxy0/SOCKS5
#   full-lite = minimal + watchdog/recovery/summary/basic checks/history/cleanup
#   manual    = helpers that must not be installed by Minimal/full-lite expansion
#
# Xray-core update is manual-only because it can create large Xray binary backups.

REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"

XRAY_GO_CMD="${XRAY_GO_CMD:-/opt/bin/xray-go}"
XRAY_GO_URL="${XRAY_GO_URL:-${RAW_BASE}/scripts/xray-go.sh}"
GO_UPDATE_CMD="${GO_UPDATE_CMD:-/opt/bin/vless-go-update}"
GO_UPDATE_URL="${GO_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-update.sh}"
GO_FAILOVER_CMD="${GO_FAILOVER_CMD:-/opt/bin/vless-go-failover}"
GO_FAILOVER_URL="${GO_FAILOVER_URL:-${RAW_BASE}/scripts/vless-go-failover.sh}"
GO_SOCKS_AUTH_CMD="${GO_SOCKS_AUTH_CMD:-/opt/bin/vless-go-socks-auth}"
GO_SOCKS_AUTH_URL="${GO_SOCKS_AUTH_URL:-${RAW_BASE}/scripts/vless-go-socks-auth.sh}"
FAILOVER_GO_CMD="${FAILOVER_GO_CMD:-/opt/bin/failover-go}"
FAILOVER_GO_URL="${FAILOVER_GO_URL:-${RAW_BASE}/scripts/failover-go.sh}"
MANIFEST_CMD="${MANIFEST_CMD:-/opt/bin/xray-go-manifest}"
MANIFEST_URL="${MANIFEST_URL:-${RAW_BASE}/scripts/xray-go-manifest.sh}"
LOCK_HELPER="${LOCK_HELPER:-/opt/libexec/vless-go-lock.sh}"
LOCK_HELPER_URL="${LOCK_HELPER_URL:-${RAW_BASE}/scripts/vless-go-lock.sh}"

GO_WATCHDOG_CMD="${GO_WATCHDOG_CMD:-/opt/bin/vless-go-watchdog}"
GO_WATCHDOG_URL="${GO_WATCHDOG_URL:-${RAW_BASE}/scripts/vless-go-watchdog.sh}"
GO_RECOVER_CMD="${GO_RECOVER_CMD:-/opt/bin/vless-go-recover}"
GO_RECOVER_URL="${GO_RECOVER_URL:-${RAW_BASE}/scripts/vless-go-recover.sh}"
DOCTOR_CMD="${DOCTOR_CMD:-/opt/bin/vless-go-doctor}"
DOCTOR_URL="${DOCTOR_URL:-${RAW_BASE}/scripts/vless-go-doctor.sh}"
GO_DOCTOR_SUMMARY_CMD="${GO_DOCTOR_SUMMARY_CMD:-/opt/bin/vless-go-doctor-summary}"
GO_DOCTOR_SUMMARY_URL="${GO_DOCTOR_SUMMARY_URL:-${RAW_BASE}/scripts/vless-go-doctor-summary.sh}"
GO_PRIVACY_CHECK_CMD="${GO_PRIVACY_CHECK_CMD:-/opt/bin/vless-go-privacy-check}"
GO_PRIVACY_CHECK_URL="${GO_PRIVACY_CHECK_URL:-${RAW_BASE}/scripts/vless-go-privacy-check.sh}"
GO_SAFETY_CHECK_CMD="${GO_SAFETY_CHECK_CMD:-/opt/bin/xray-go-safety-check}"
GO_SAFETY_CHECK_URL="${GO_SAFETY_CHECK_URL:-${RAW_BASE}/scripts/xray-go-safety-check.sh}"
GO_HISTORY_CMD="${GO_HISTORY_CMD:-/opt/bin/vless-go-history}"
GO_HISTORY_URL="${GO_HISTORY_URL:-${RAW_BASE}/scripts/vless-go-history.sh}"
GO_CLEANUP_CMD="${GO_CLEANUP_CMD:-/opt/bin/vless-go-cleanup}"
GO_CLEANUP_URL="${GO_CLEANUP_URL:-${RAW_BASE}/scripts/vless-go-cleanup.sh}"
GO_AUTO_UPDATE_CMD="${GO_AUTO_UPDATE_CMD:-/opt/bin/vless-go-auto-update}"
GO_AUTO_UPDATE_URL="${GO_AUTO_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-auto-update.sh}"
DIRECT_FULL_UPDATE_CMD="${DIRECT_FULL_UPDATE_CMD:-/opt/bin/xray-go-direct-full}"
DIRECT_FULL_UPDATE_URL="${DIRECT_FULL_UPDATE_URL:-${RAW_BASE}/scripts/xray-go-direct-full.sh}"
DIRECT_UNINSTALL_CMD="${DIRECT_UNINSTALL_CMD:-/opt/bin/xray-go-direct-uninstall}"
DIRECT_UNINSTALL_URL="${DIRECT_UNINSTALL_URL:-${RAW_BASE}/scripts/xray-go-direct-uninstall.sh}"
GO_SIZE_CHECK_CMD="${GO_SIZE_CHECK_CMD:-/opt/bin/xray-go-size-check}"
GO_SIZE_CHECK_URL="${GO_SIZE_CHECK_URL:-${RAW_BASE}/scripts/xray-go-size-check.sh}"

XRAY_CORE_UPDATE_CMD="${XRAY_CORE_UPDATE_CMD:-/opt/bin/vless-go-xray-core-update}"
XRAY_CORE_UPDATE_URL="${XRAY_CORE_UPDATE_URL:-${RAW_BASE}/scripts/vless-go-xray-core-update.sh}"

emit_minimal_helpers() {
    cat <<EOF_MINIMAL
exec|$XRAY_GO_CMD|$XRAY_GO_URL|xray-go wrapper
exec|$GO_UPDATE_CMD|$GO_UPDATE_URL|vless-go-update helper
exec|$GO_FAILOVER_CMD|$GO_FAILOVER_URL|vless-go-failover helper
exec|$GO_SOCKS_AUTH_CMD|$GO_SOCKS_AUTH_URL|vless-go-socks-auth helper
exec|$FAILOVER_GO_CMD|$FAILOVER_GO_URL|failover-go menu
exec|$MANIFEST_CMD|$MANIFEST_URL|manifest helper
read|$LOCK_HELPER|$LOCK_HELPER_URL|lock helper
EOF_MINIMAL
}

emit_full_lite_helpers() {
    emit_minimal_helpers
    cat <<EOF_FULL_LITE
exec|$GO_WATCHDOG_CMD|$GO_WATCHDOG_URL|vless-go-watchdog helper
exec|$GO_RECOVER_CMD|$GO_RECOVER_URL|vless-go-recover helper
exec|$DOCTOR_CMD|$DOCTOR_URL|doctor helper
exec|$GO_DOCTOR_SUMMARY_CMD|$GO_DOCTOR_SUMMARY_URL|doctor summary helper
exec|$GO_PRIVACY_CHECK_CMD|$GO_PRIVACY_CHECK_URL|privacy-check helper
exec|$GO_SAFETY_CHECK_CMD|$GO_SAFETY_CHECK_URL|safety-check helper
exec|$GO_HISTORY_CMD|$GO_HISTORY_URL|history helper
exec|$GO_CLEANUP_CMD|$GO_CLEANUP_URL|cleanup helper
exec|$GO_AUTO_UPDATE_CMD|$GO_AUTO_UPDATE_URL|auto-update helper
exec|$DIRECT_FULL_UPDATE_CMD|$DIRECT_FULL_UPDATE_URL|direct full/update helper
exec|$DIRECT_UNINSTALL_CMD|$DIRECT_UNINSTALL_URL|direct uninstall helper
exec|$GO_SIZE_CHECK_CMD|$GO_SIZE_CHECK_URL|size-check helper
EOF_FULL_LITE
}

emit_manual_helpers() {
    cat <<EOF_MANUAL
exec|$XRAY_CORE_UPDATE_CMD|$XRAY_CORE_UPDATE_URL|Xray-core updater helper
EOF_MANUAL
}

emit_full_helpers() {
    emit_full_lite_helpers
    emit_manual_helpers
}

usage() {
    cat <<'USAGE'
xray-go-helper-profiles - print direct-install helper specs

Usage:
  xray-go-helper-profiles minimal
  xray-go-helper-profiles full-lite
  xray-go-helper-profiles manual
  xray-go-helper-profiles full

Output format:
  mode|target_path|source_url|label

Policy:
  minimal/full-lite exclude vless-go-xray-core-update.
  Xray-core updater is manual-only and appears only in manual/full.
USAGE
}

profile="${1:-full-lite}"
[ "$#" -le 1 ] || { usage >&2; exit 2; }

case "$profile" in
    minimal)
        emit_minimal_helpers
        ;;
    full-lite|lite)
        emit_full_lite_helpers
        ;;
    manual|maintenance)
        emit_manual_helpers
        ;;
    full)
        emit_full_helpers
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "ERROR: unknown helper profile: $profile" >&2
        usage >&2
        exit 2
        ;;
esac
