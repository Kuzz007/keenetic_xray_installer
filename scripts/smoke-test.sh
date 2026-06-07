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
check_repo_plain_target xray_vless_failover_go.sh scripts/install-entware-feed.sh "Go/Entware entrypoint"
check_repo_plain_target xray_vless_failover_minimal_go.sh xray_vless_failover_minimal.sh "Minimal Go entrypoint"
check_contains install.sh 'AUTO_LATEST_URL' "install.sh keeps Auto Latest URL override"
check_contains install.sh 'DIRECT_INSTALL_URL' "install.sh keeps direct-install URL override"
check_contains install.sh 'DIRECT_INIT_URL' "install.sh keeps direct-init URL override"
check_contains install.sh 'DIRECT_FULL_URL' "install.sh keeps direct-full URL override"
check_contains install.sh '--direct-experimental' "install.sh keeps direct experimental mode"
check_contains install.sh '--direct-detect-only' "install.sh keeps direct detect-only mode"
check_contains install.sh '--direct-init-experimental' "install.sh keeps direct-init experimental mode"
check_contains install.sh '--direct-init-post-check' "install.sh keeps direct-init post-check mode"
check_contains install.sh '--direct-full-dry-run' "install.sh keeps direct-full dry-run mode"
check_contains xray_vless_failover_go.sh 'GO_PLAIN_URL' "Go/Entware entrypoint keeps URL override"
check_contains xray_vless_failover_minimal_go.sh 'MINIMAL_GO_PLAIN_URL' "Minimal Go entrypoint keeps URL override"
check_not_contains xray_vless_failover_go.sh 'xray_vless_failover_old_go.sh' "Go/Entware entrypoint does not point at removed old_go path"
check_not_contains xray_vless_failover_minimal_go.sh 'xray_vless_failover_minimal_old_go.sh' "Minimal Go entrypoint does not point at removed minimal_old_go path"

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
check_contains scripts/xray-go-direct-full.sh 'Planned full direct-install sequence' "direct-full prints planned sequence"
check_contains scripts/xray-go-direct-full.sh 'Equivalent commands, not executed by dry-run' "direct-full prints non-executed command plan"
check_contains scripts/xray-go-direct-full.sh 'No changes made' "direct-full documents read-only behavior"
check_contains scripts/xray-go-direct-full.sh 'SHOW_COMMANDS' "direct-full can hide command examples"
check_not_contains scripts/xray-go-direct-full.sh 'run_downloaded_script' "direct-full does not run downloaded installers itself"
check_not_contains scripts/xray-go-direct-full.sh 'fetch_url' "direct-full does not download during dry-run"

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
    scripts/vless-go-xray-core-update.sh \
    scripts/vless-go-web-install.sh \
    scripts/build-entware-ipk.sh
    do check_executable_hint "$path"; done

info ""
info "== Summary =="
if [ "$FAILURES" -eq 0 ]; then ok "smoke test passed with $WARNINGS warning(s)"; exit 0; fi
fail "smoke test failed: $FAILURES issue(s), $WARNINGS warning(s)"
exit 1
