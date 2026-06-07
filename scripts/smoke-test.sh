#!/bin/sh
set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
FAILURES=0
WARNINGS=0

info() { printf '%s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; FAILURES=$((FAILURES + 1)); }

check_file_exists() { path="$1"; if [ -f "$ROOT_DIR/$path" ]; then ok "exists: $path"; else fail "missing: $path"; fi; }
check_syntax() { path="$1"; if [ ! -f "$ROOT_DIR/$path" ]; then fail "syntax skipped, missing: $path"; return 0; fi; if sh -n "$ROOT_DIR/$path"; then ok "sh -n: $path"; else fail "sh -n failed: $path"; fi; }
check_contains() { path="$1"; pattern="$2"; label="$3"; if grep -q -- "$pattern" "$ROOT_DIR/$path" 2>/dev/null; then ok "$label"; else fail "$label"; fi; }
check_not_contains() { path="$1"; pattern="$2"; label="$3"; if grep -q -- "$pattern" "$ROOT_DIR/$path" 2>/dev/null; then fail "$label"; else ok "$label"; fi; }
check_executable_hint() { path="$1"; if [ ! -f "$ROOT_DIR/$path" ]; then warn "executable check skipped, missing: $path"; return 0; fi; if [ -x "$ROOT_DIR/$path" ]; then ok "executable in checkout: $path"; else warn "not executable in checkout: $path"; fi; }
check_repo_plain_target() { entrypoint="$1"; target="$2"; label="$3"; check_file_exists "$target"; check_contains "$entrypoint" "$target" "$label points at existing repo path: $target"; }

info "== Required top-level installers =="
for path in \
    install.sh \
    xray_vless_failover_auto_latest.sh \
    xray_vless_failover_go.sh \
    xray_vless_failover_minimal_go.sh \
    xray_vless_failover_auto.sh \
    xray_vless_failover.sh \
    xray_vless_failover_minimal.sh \
    xray_vless_go_watchdog_install.sh
    do check_file_exists "$path"; check_syntax "$path"; done

info ""
info "== Downloader entrypoint target guardrails =="
check_repo_plain_target install.sh scripts/xray-go-direct-install.sh "install.sh direct-install entrypoint"
check_repo_plain_target install.sh scripts/xray-go-direct-init.sh "install.sh direct-init entrypoint"
check_repo_plain_target install.sh scripts/xray-go-direct-full.sh "install.sh direct-full entrypoint"
check_repo_plain_target install.sh scripts/xray-go-direct-uninstall.sh "install.sh direct-uninstall entrypoint"
check_repo_plain_target xray_vless_failover_go.sh scripts/install-entware-feed.sh "Go/Entware entrypoint"
check_repo_plain_target xray_vless_failover_minimal_go.sh xray_vless_failover_minimal.sh "Minimal Go entrypoint"
check_contains install.sh 'AUTO_LATEST_URL' "install.sh keeps Auto Latest URL override"
check_contains install.sh 'DIRECT_INSTALL_URL' "install.sh keeps direct-install URL override"
check_contains install.sh 'DIRECT_INIT_URL' "install.sh keeps direct-init URL override"
check_contains install.sh 'DIRECT_FULL_URL' "install.sh keeps direct-full URL override"
check_contains install.sh 'DIRECT_UNINSTALL_URL' "install.sh keeps direct-uninstall URL override"
check_contains install.sh '--direct-experimental' "install.sh keeps direct experimental mode"
check_contains install.sh '--direct-detect-only' "install.sh keeps direct detect-only mode"
check_contains install.sh '--direct-init-experimental' "install.sh keeps direct-init experimental mode"
check_contains install.sh '--direct-init-post-check' "install.sh keeps direct-init post-check mode"
check_contains install.sh '--direct-full-dry-run' "install.sh keeps direct-full dry-run mode"
check_contains install.sh '--direct-full-experimental' "install.sh keeps direct-full apply mode"
check_contains install.sh '--direct-uninstall-dry-run' "install.sh keeps direct-uninstall dry-run mode"
check_contains xray_vless_failover_go.sh 'GO_PLAIN_URL' "Go/Entware entrypoint keeps URL override"
check_contains xray_vless_failover_minimal_go.sh 'MINIMAL_GO_PLAIN_URL' "Minimal Go entrypoint keeps URL override"
check_not_contains xray_vless_failover_go.sh 'xray_vless_failover_old_go.sh' "Go/Entware entrypoint does not point at removed old_go path"
check_not_contains xray_vless_failover_minimal_go.sh 'xray_vless_failover_minimal_old_go.sh' "Minimal Go entrypoint does not point at removed minimal_old_go path"

info ""
info "== xray-go wrapper guardrails =="
check_contains scripts/xray-go.sh 'GO_DOCTOR_SUMMARY_URL' "xray-go has doctor summary URL"
check_contains scripts/xray-go.sh 'refresh_doctor_summary' "xray-go can refresh doctor summary helper"
check_contains scripts/xray-go.sh 'run_summary' "xray-go has summary command path"
check_contains scripts/xray-go.sh 'xray-go summary' "xray-go usage documents summary command"
check_contains scripts/xray-go.sh 'xray-go doctor --summary' "xray-go usage documents doctor summary mode"
check_contains scripts/xray-go.sh '--summary|summary' "xray-go doctor accepts summary mode"
check_contains scripts/xray-go.sh 'GO_PRIVACY_CHECK_URL' "xray-go has privacy check URL"
check_contains scripts/xray-go.sh 'refresh_privacy_check' "xray-go can refresh privacy checker"
check_contains scripts/xray-go.sh 'run_privacy_check' "xray-go has privacy-check command path"
check_contains scripts/xray-go.sh 'xray-go privacy-check' "xray-go usage documents privacy-check command"
check_contains scripts/xray-go.sh 'privacy-check|privacy' "xray-go accepts privacy-check command"
check_contains scripts/xray-go.sh 'DIRECT_FULL_UPDATE_URL' "xray-go has direct full update URL"
check_contains scripts/xray-go.sh 'refresh_direct_full_update' "xray-go can refresh direct full updater"
check_contains scripts/xray-go.sh 'DIRECT_UNINSTALL_URL' "xray-go has direct uninstall URL"
check_contains scripts/xray-go.sh 'refresh_direct_uninstall' "xray-go can refresh direct uninstall planner"
check_contains scripts/xray-go.sh 'manifest_get_value INSTALL_MODE' "xray-go reads manifest install mode"
check_contains scripts/xray-go.sh 'run_direct_go_update' "xray-go has direct go update path"
check_contains scripts/xray-go.sh 'run_opkg_go_update' "xray-go preserves opkg-compatible update path"
check_contains scripts/xray-go.sh 'run_uninstall' "xray-go has uninstall command path"
check_contains scripts/xray-go.sh 'run_version' "xray-go has enhanced version command path"
check_contains scripts/xray-go.sh 'Manifest summary' "xray-go version shows manifest summary"
check_contains scripts/xray-go.sh 'Manifest sha256 match' "xray-go version checks resolver sha256 against manifest"
check_contains scripts/xray-go.sh 'Helper paths' "xray-go version shows helper paths"
check_contains scripts/xray-go.sh 'Direct install mode detected' "xray-go announces direct update mode"
check_contains scripts/xray-go.sh '--dry-run' "xray-go exposes update/uninstall dry-run"
check_contains scripts/xray-go.sh 'xray-go update go --dry-run' "xray-go usage documents update dry-run"
check_contains scripts/xray-go.sh 'xray-go uninstall --dry-run' "xray-go usage documents uninstall dry-run"

info ""
info "== Doctor summary helper guardrails =="
check_file_exists scripts/vless-go-doctor-summary.sh
check_syntax scripts/vless-go-doctor-summary.sh
check_contains scripts/vless-go-doctor-summary.sh '== Summary ==' "doctor summary prints Summary section"
check_contains scripts/vless-go-doctor-summary.sh 'Manifest sha256' "doctor summary reports manifest sha256 state"
check_contains scripts/vless-go-doctor-summary.sh 'SOCKS health' "doctor summary reports SOCKS health"
check_contains scripts/vless-go-doctor-summary.sh 'OK=' "doctor summary prints OK/WARN/FAIL result"
check_not_contains scripts/vless-go-doctor-summary.sh 'subscription URL' "doctor summary should not print subscription URL label"

info ""
info "== Privacy checker guardrails =="
check_file_exists scripts/vless-go-privacy-check.sh
check_syntax scripts/vless-go-privacy-check.sh
check_contains scripts/vless-go-privacy-check.sh 'This checker does not print captured diagnostic output.' "privacy checker does not print captured output"
check_contains scripts/vless-go-privacy-check.sh 'raw proxy URL' "privacy checker scans raw proxy URLs"
check_contains scripts/vless-go-privacy-check.sh 'UUID-like value' "privacy checker scans UUID-like values"
check_contains scripts/vless-go-privacy-check.sh 'SOCKS password variable' "privacy checker scans SOCKS password variables"
check_contains scripts/vless-go-privacy-check.sh 'proxy credentials in URL' "privacy checker scans URL credentials"
check_contains scripts/vless-go-privacy-check.sh 'Captured outputs are removed automatically' "privacy checker removes captured output"

info ""
info "== Doctor manifest guardrails =="
check_contains scripts/vless-go-doctor.sh 'MANIFEST_FILE="$XRAY_DIR/xray-go.manifest"' "doctor knows direct manifest path"
check_contains scripts/vless-go-doctor.sh 'check_manifest' "doctor has manifest check"
check_contains scripts/vless-go-doctor.sh 'manifest install mode' "doctor reports install mode"
check_contains scripts/vless-go-doctor.sh 'manifest binary sha256 matches target' "doctor verifies manifest binary sha256"
check_contains scripts/vless-go-doctor.sh 'manifest binary executable' "doctor checks manifest binary executable"
check_contains scripts/vless-go-doctor.sh 'section "Manifest"' "doctor prints dedicated manifest section"
check_not_contains scripts/vless-go-doctor.sh 'manifest source' "doctor manifest section should not print raw source"

info ""
info "== Direct-install skeleton guardrails =="
check_contains scripts/xray-go-direct-install.sh '--download-binary' "direct-install keeps binary staging mode"
check_contains scripts/xray-go-direct-install.sh '--install-binary' "direct-install keeps explicit binary install mode"
check_contains scripts/xray-go-direct-install.sh 'GO_RESOLVER_BACKUP' "direct-install backs up existing Go resolver"
check_contains scripts/xray-go-direct-install.sh 'install_binary_from_stage' "direct-install installs binary only through explicit function"
check_contains scripts/xray-go-direct-install.sh '--stage-helpers' "direct-install keeps helper staging mode"
check_contains scripts/xray-go-direct-install.sh '--install-helpers' "direct-install keeps explicit helper install mode"
check_contains scripts/xray-go-direct-install.sh 'HELPER_INDEX' "direct-install tracks staged helper index"
check_contains scripts/xray-go-direct-install.sh 'verify_shell_helper' "direct-install checks helper shell syntax"
check_contains scripts/xray-go-direct-install.sh 'No first-run setup was executed' "direct-install skeleton documents no first-run setup"

info ""
info "== Direct-init guardrails =="
check_contains scripts/xray-go-direct-init.sh '--stage-watchdog-init' "direct-init keeps watchdog init staging mode"
check_contains scripts/xray-go-direct-init.sh '--install-watchdog-init' "direct-init keeps explicit watchdog init install mode"
check_contains scripts/xray-go-direct-init.sh '--post-check' "direct-init keeps read-only post-check mode"
check_contains scripts/xray-go-direct-init.sh '--enable-recovery-cron' "direct-init keeps explicit recovery cron enable mode"
check_contains scripts/xray-go-direct-init.sh '--disable-recovery-cron' "direct-init keeps explicit recovery cron disable mode"
check_contains scripts/xray-go-direct-init.sh 'RECOVERY_CRON_MARKER' "direct-init manages cron by marker"
check_contains scripts/xray-go-direct-init.sh 'remove_recovery_cron_lines' "direct-init removes old recovery cron line before writing"
check_contains scripts/xray-go-direct-init.sh 'WATCHDOG_INSTALLER_STAGE' "direct-init stages watchdog installer before running"
check_contains scripts/xray-go-direct-init.sh 'No first-run setup was executed' "direct-init documents no first-run setup"

info ""
info "== Direct-full orchestrator guardrails =="
check_file_exists scripts/xray-go-direct-full.sh
check_syntax scripts/xray-go-direct-full.sh
check_contains scripts/xray-go-direct-full.sh '--dry-run' "direct-full keeps dry-run mode"
check_contains scripts/xray-go-direct-full.sh '--apply' "direct-full keeps explicit apply mode"
check_contains scripts/xray-go-direct-full.sh 'requires --yes' "direct-full apply documents --yes requirement"
check_contains scripts/xray-go-direct-full.sh 'ASSUME_YES' "direct-full apply tracks explicit confirmation"
check_contains scripts/xray-go-direct-full.sh 'run_remote_helper' "direct-full runs smaller helpers in apply mode"
check_contains scripts/xray-go-direct-full.sh 'Planned full direct-install sequence' "direct-full prints planned sequence"
check_contains scripts/xray-go-direct-full.sh 'Direct full dry-run complete. No changes made.' "direct-full documents dry-run read-only behavior"
check_contains scripts/xray-go-direct-full.sh 'No first-run setup was executed. VLESS sources were not edited.' "direct-full documents apply safety boundary"
check_contains scripts/xray-go-direct-full.sh 'SHOW_COMMANDS' "direct-full can hide command examples"

info ""
info "== Direct-uninstall guardrails =="
check_file_exists scripts/xray-go-direct-uninstall.sh
check_syntax scripts/xray-go-direct-uninstall.sh
check_contains scripts/xray-go-direct-uninstall.sh '--dry-run' "direct-uninstall keeps dry-run mode"
check_contains scripts/xray-go-direct-uninstall.sh 'No changes made.' "direct-uninstall documents read-only behavior"
check_contains scripts/xray-go-direct-uninstall.sh 'does not stop services, delete files, edit cron, or modify VLESS sources' "direct-uninstall documents safety boundary"
check_contains scripts/xray-go-direct-uninstall.sh 'Would remove direct code files' "direct-uninstall lists code files"
check_contains scripts/xray-go-direct-uninstall.sh 'Would preserve user/runtime data by default' "direct-uninstall preserves user data by default"
check_contains scripts/xray-go-direct-uninstall.sh 'RECOVERY_CRON_MARKER' "direct-uninstall plans cron by marker"

info ""
info "== Embedded payload guardrails for public entrypoints =="
for path in install.sh xray_vless_failover_auto_latest.sh xray_vless_failover_go.sh xray_vless_failover_minimal_go.sh; do
    check_not_contains "$path" 'PAYLOAD_B64' "$path has no embedded base64 payload marker"
    check_not_contains "$path" 'gzip -dc' "$path has no gzip self-extract decode path"
done

info ""
info "== Auto-latest read-only mode guardrails =="
check_contains xray_vless_failover_auto_latest.sh 'detect-only).*no changes made' "Auto-latest keeps detect-only no-change exit path"
check_contains xray_vless_failover_auto_latest.sh 'doctor).*run_doctor' "Auto-latest keeps doctor path before install flow"
check_contains xray_vless_failover_auto_latest.sh 'update-only).*need_opkg' "Auto-latest gates dependency bootstrap to update-only/install paths"
check_contains xray_vless_failover_auto_latest.sh 'args="--repair-only"' "Go update-only starts without forced --no-restart"

info ""
info "== Entware feed architecture guardrails =="
check_contains scripts/install-entware-feed.sh 'detect_entware_arch' "Feed installer detects Entware architecture"
check_contains scripts/install-entware-feed.sh 'normalize_feed_tag' "Feed installer maps architecture to release tag"
check_contains scripts/install-entware-feed.sh 'mipsel-3.4' "Feed installer supports mipsel feed suffix"
check_contains scripts/install-entware-feed.sh 'mipselsf-k3.4' "Feed installer supports mipselsf feed suffix"
check_contains packaging/entware/failover-go/postinst 'asset_name_for_arch' "Package postinst maps architecture to Go resolver asset"
check_contains packaging/entware/failover-go/postinst 'xray-failover-go-linux-mipsle' "Package postinst supports mipsle resolver asset"

info ""
info "== Helper scripts syntax =="
for file in "$ROOT_DIR"/scripts/*.sh; do [ -e "$file" ] || continue; rel="scripts/$(basename "$file")"; check_syntax "$rel"; done

info ""
info "== Packaging maintainer scripts syntax =="
for path in packaging/entware/failover-go/postinst packaging/entware/failover-go/prerm; do check_file_exists "$path"; check_syntax "$path"; done

info ""
info "== Runtime helper executable bits =="
info "Executable bits are warnings because install/update/package flows chmod helpers during deployment."
for path in \
    install.sh \
    scripts/xray-go.sh \
    scripts/xray-go-direct-install.sh \
    scripts/xray-go-direct-init.sh \
    scripts/xray-go-direct-full.sh \
    scripts/xray-go-direct-uninstall.sh \
    scripts/xray-go-installer-update.sh \
    scripts/failover-go.sh \
    scripts/vless-go-update.sh \
    scripts/vless-go-failover.sh \
    scripts/vless-go-auto-update.sh \
    scripts/vless-go-watchdog.sh \
    scripts/vless-go-history.sh \
    scripts/vless-go-cleanup.sh \
    scripts/vless-go-recover.sh \
    scripts/vless-go-doctor.sh \
    scripts/vless-go-doctor-summary.sh \
    scripts/vless-go-privacy-check.sh \
    scripts/vless-go-xray-core-update.sh \
    scripts/vless-go-web-install.sh \
    scripts/build-entware-ipk.sh
    do check_executable_hint "$path"; done

info ""
info "== Summary =="
if [ "$FAILURES" -eq 0 ]; then ok "smoke test passed with $WARNINGS warning(s)"; exit 0; fi
fail "smoke test failed: $FAILURES issue(s), $WARNINGS warning(s)"
exit 1
