#!/usr/bin/env sh
set -u

REPO="${REPO:-Kuzz007/keenetic_xray_installer}"
TAG="${TAG:-latest}"
CONTROL_SERVER_BIN="${CONTROL_SERVER_BIN:-/usr/local/bin/xray-go-control-server}"
CONTROL_SERVER_SERVICE="${CONTROL_SERVER_SERVICE:-xray-go-control-server}"
CONTROL_SERVER_HEALTH_URL="${CONTROL_SERVER_HEALTH_URL:-http://127.0.0.1:18090/health}"
ASSET_BASE="https://github.com/${REPO}/releases/download/${TAG}"

ASSETS="
xray-failover-go-linux-arm64
xray-failover-go-linux-arm64.sha256
xray-failover-go-linux-mipsle
xray-failover-go-linux-mipsle.sha256
vless-go-web-linux-arm64
vless-go-web-linux-arm64.sha256
vless-go-web-linux-mipsle
vless-go-web-linux-mipsle.sha256
xray-go-agent-linux-arm64
xray-go-agent-linux-arm64.sha256
xray-go-agent-linux-mipsle
xray-go-agent-linux-mipsle.sha256
xray-go-agent-linux-mips
xray-go-agent-linux-mips.sha256
xray-go-control-server-linux-amd64
xray-go-control-server-linux-amd64.sha256
xray-go-control-server-linux-arm64
xray-go-control-server-linux-arm64.sha256
"

ok_count=0
warn_count=0
fail_count=0

say() { printf '%s\n' "$*"; }
ok() { ok_count=$((ok_count + 1)); say "[OK] $*"; }
warn() { warn_count=$((warn_count + 1)); say "[WARN] $*"; }
fail() { fail_count=$((fail_count + 1)); say "[FAIL] $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
Usage: $0 [--help]

Read-only checklist for publishing and validating the ${TAG} release.

Environment overrides:
  REPO=${REPO}
  TAG=${TAG}
  CONTROL_SERVER_BIN=${CONTROL_SERVER_BIN}
  CONTROL_SERVER_SERVICE=${CONTROL_SERVER_SERVICE}
  CONTROL_SERVER_HEALTH_URL=${CONTROL_SERVER_HEALTH_URL}

Typical VPS usage after GitHub Actions succeeds:
  sh scripts/release-latest-checklist.sh
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1"; usage; exit 2 ;;
  esac
done

check_url() {
  url="$1"
  label="$2"
  if ! have curl; then
    warn "curl not found; cannot check $label"
    return 0
  fi
  if curl -fsIL --max-time 20 "$url" >/dev/null 2>&1; then
    ok "$label reachable"
  else
    fail "$label unreachable: $url"
  fi
}

say "== Release latest checklist =="
say "repo: ${REPO}"
say "tag: ${TAG}"
say ""

say "== 1. Manual GitHub checks =="
say "[TODO] Confirm PRs are merged into main before publishing."
say "[TODO] Confirm GitHub Actions -> Publish Go experimental release succeeded."
say "[TODO] Confirm workflow inputs: branch=main tag=${TAG}."
say ""

say "== 2. Release asset checks =="
for asset in $ASSETS; do
  check_url "${ASSET_BASE}/${asset}" "asset ${asset}"
done
say ""

say "== 3. VPS control-server checks =="
if [ -x "$CONTROL_SERVER_BIN" ]; then
  ok "control-server binary exists and is executable: $CONTROL_SERVER_BIN"
  if "$CONTROL_SERVER_BIN" -h >/dev/null 2>&1; then
    ok "control-server binary starts with -h"
  else
    warn "control-server binary did not return success for -h; this may be normal if -h behavior changes"
  fi
else
  fail "control-server binary missing or not executable: $CONTROL_SERVER_BIN"
fi

if have systemctl; then
  if systemctl is-active --quiet "$CONTROL_SERVER_SERVICE"; then
    ok "systemd service active: $CONTROL_SERVER_SERVICE"
  else
    fail "systemd service not active: $CONTROL_SERVER_SERVICE"
  fi
else
  warn "systemctl not found; skipping service status"
fi

if have curl; then
  health="$(curl -fsS --max-time 10 "$CONTROL_SERVER_HEALTH_URL" 2>/dev/null || true)"
  if [ "$health" = "OK" ]; then
    ok "health endpoint OK: $CONTROL_SERVER_HEALTH_URL"
  else
    fail "health endpoint failed or unexpected response: $CONTROL_SERVER_HEALTH_URL"
  fi
else
  warn "curl not found; skipping health endpoint"
fi
say ""

say "== 4. Manual Telegram bot checks =="
say "[TODO] Open /menu -> 📡 Роутеры."
say "[TODO] Confirm router list opens and all expected routers are visible."
say "[TODO] Press 🩺 Диагностика всех."
say "[TODO] Confirm queued command ids use doctor_all-<timestamp>."
say "[TODO] Confirm all routers send standalone doctor results."
say "[TODO] Confirm final summary arrives after the last doctor result."
say "[TODO] Confirm 📬 Results has no empty leading separator."
say ""

say "== 5. Optional post-release router checks =="
say "[TODO] If scripts changed, press 🔄 Обновить скрипты на всех."
say "[TODO] If agent changed, press 🔁 Обновить агентов на всех."
say "[TODO] Confirm agent_start events after agent update."
say "[TODO] Confirm agent version/capabilities in router cards."
say ""

say "== Summary =="
say "OK=${ok_count} WARN=${warn_count} FAIL=${fail_count}"

if [ "$fail_count" -gt 0 ]; then
  exit 1
fi
exit 0
