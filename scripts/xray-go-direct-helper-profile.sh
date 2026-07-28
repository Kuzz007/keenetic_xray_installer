#!/bin/sh
set -eu

# Shared helpers used across install.sh and several scripts/*.sh entrypoints.
#
# This file is not meant to be sourced at runtime - scripts/build-generated-scripts.sh
# concatenates it into each published script (from scripts/src/direct/ and
# scripts/src/misc/) so every one of them stays a single self-contained file,
# safe to curl and run directly. Edit the functions here, then run
# scripts/build-generated-scripts.sh to regenerate the published scripts; do
# not hand-edit these function bodies in the generated files.
#
# Not every published script uses every function here - each still gets the
# full set, since a few unused shell functions cost nothing at runtime and
# it keeps this file the single source of truth rather than tracking a
# per-script subset.

fetch_url() {
    url="$1"
    output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' -o "$output" "$url"
        return $?
    fi

    if command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
        return $?
    fi

    echo "ERROR: curl or wget is required." >&2
    echo "Hint: opkg update && opkg install curl" >&2
    return 127
}

sha256_file() {
    file="$1"
    [ -s "$file" ] || { echo ""; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$file" 2>/dev/null | awk '{print $NF}'
    else
        echo ""
    fi
}

looks_like_shell_script() {
    head -n 1 "$1" 2>/dev/null | grep -Eq '^#!/bin/sh|^#!/opt/bin/sh|^#!/usr/bin/env[[:space:]]+sh'
}

# xray-go-direct-helper-profile - install/stage helpers by direct profile.
#
# This is the profile-aware replacement path for the old single helper list.
# By default it is read-only and prints the selected helper list.
# Writes require: --apply --yes
#
# Policy:
#   minimal/full-lite never include vless-go-xray-core-update.
#   Xray-core update is manual-only and appears only in manual/full profiles.

REPO_BRANCH="${REPO_BRANCH:-main}"
RAW_BASE="${RAW_BASE:-https://raw.githubusercontent.com/Kuzz007/keenetic_xray_installer/${REPO_BRANCH}}"
TMP_DIR="${TMPDIR:-/opt/tmp}"
STAGE_DIR="${XRAY_GO_HELPER_STAGE_DIR:-${TMP_DIR}/xray-go-helper-profile}"
PROFILE_CMD="${PROFILE_CMD:-/opt/bin/xray-go-helper-profiles}"
PROFILE_URL="${PROFILE_URL:-${RAW_BASE}/scripts/xray-go-helper-profiles.sh}"
HELPER_INDEX="${HELPER_INDEX:-${STAGE_DIR}/helpers.index}"

PROFILE="full-lite"
MODE="dry-run"
ASSUME_YES="0"
INSTALL_PROFILE_CMD="1"
CLEAN_STAGE="1"

usage() {
    cat <<'USAGE'
xray-go-direct-helper-profile - profile-aware direct helper installer

Usage:
  xray-go-direct-helper-profile --profile minimal --dry-run
  xray-go-direct-helper-profile --profile full-lite --dry-run
  xray-go-direct-helper-profile --profile full-lite --apply --yes
  xray-go-direct-helper-profile --profile manual --apply --yes
  xray-go-direct-helper-profile --profile full --apply --yes

Profiles:
  minimal    core/subscription/failover helpers only
  full-lite  minimal + watchdog/recovery/summary/basic checks/history/cleanup
  manual     manual-only maintenance helpers, currently xray-core updater
  full       full-lite + manual

Safety:
  --dry-run is default and makes no changes.
  --apply requires --yes.
  minimal/full-lite exclude vless-go-xray-core-update by policy.
  Successful --apply removes its staging dir by default.
  Use --keep-stage only for debugging.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile)
            [ "$#" -ge 2 ] || { echo "ERROR: --profile requires a value" >&2; exit 2; }
            PROFILE="$2"
            shift 2
            ;;
        --dry-run|--plan|dry-run|plan)
            MODE="dry-run"
            shift
            ;;
        --apply|apply|--install|install)
            MODE="apply"
            shift
            ;;
        -y|--yes)
            ASSUME_YES="1"
            shift
            ;;
        --no-profile-helper)
            INSTALL_PROFILE_CMD="0"
            shift
            ;;
        --keep-stage|--no-clean-stage)
            CLEAN_STAGE="0"
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

case "$PROFILE" in
    minimal|full-lite|lite|manual|maintenance|full) ;;
    *) echo "ERROR: unknown profile: $PROFILE" >&2; usage >&2; exit 2 ;;
esac

[ "$MODE" = "dry-run" ] || [ "$ASSUME_YES" = "1" ] || {
    echo "ERROR: --apply requires --yes" >&2
    exit 2
}

verify_shell_helper() {
    file="$1"
    label="$2"
    if ! sh -n "$file"; then
        echo "ERROR: shell syntax check failed for $label: $file" >&2
        exit 1
    fi
}

install_profile_helper() {
    [ "$INSTALL_PROFILE_CMD" = "1" ] || return 0
    [ "$MODE" = "apply" ] || return 0
    mkdir -p "$(dirname "$PROFILE_CMD")" "$STAGE_DIR"
    tmp="${STAGE_DIR}/xray-go-helper-profiles.$$"
    echo "Installing helper profile command: $PROFILE_CMD"
    fetch_url "$PROFILE_URL" "$tmp"
    verify_shell_helper "$tmp" "xray-go-helper-profiles"
    chmod +x "$tmp"
    mv "$tmp" "$PROFILE_CMD"
    chmod +x "$PROFILE_CMD"
}

profile_script_path() {
    # Always prefer the fresh profile list from the repository. This prevents a
    # stale installed /opt/bin/xray-go-helper-profiles from omitting new Minimal
    # helpers such as xray-go-size-check. Fall back to the installed helper only
    # if the fresh copy cannot be fetched.
    mkdir -p "$STAGE_DIR"
    tmp="${STAGE_DIR}/xray-go-helper-profiles.runtime"
    if fetch_url "$PROFILE_URL" "$tmp"; then
        verify_shell_helper "$tmp" "xray-go-helper-profiles"
        chmod +x "$tmp"
        echo "$tmp"
        return 0
    fi

    if [ -x "$PROFILE_CMD" ]; then
        echo "WARN: using installed helper profile fallback: $PROFILE_CMD" >&2
        echo "$PROFILE_CMD"
        return 0
    fi

    echo "ERROR: cannot fetch helper profile list and no installed fallback exists" >&2
    return 1
}

cleanup_stage_dir() {
    [ "$MODE" = "apply" ] || return 0
    [ "$CLEAN_STAGE" = "1" ] || { echo "Keeping stage dir for debugging: $STAGE_DIR"; return 0; }
    [ -n "$STAGE_DIR" ] || return 0

    case "$STAGE_DIR" in
        /opt/tmp/xray-go-helper-profile|/opt/tmp/xray-go-helper-profile/*|/tmp/xray-go-helper-profile|/tmp/xray-go-helper-profile/*)
            rm -rf "$STAGE_DIR"
            echo "Stage dir cleaned: $STAGE_DIR"
            ;;
        *)
            echo "WARN: refusing to auto-clean non-standard stage dir: $STAGE_DIR" >&2
            echo "      Remove it manually after inspection if needed." >&2
            ;;
    esac
}

# Keep auth-aware patches self-contained so full-lite installed through this helper
# does not regress SOCKS-auth health checks.
patch_recover_helper_auth() {
    file="$1"
    tmp="${file}.auth.$$"
    awk '
        /^health_check\(\) \{/ {
            print "load_socks_auth_config() {"
            print "    XRAY_SOCKS_AUTH=\"${XRAY_SOCKS_AUTH:-0}\""
            print "    XRAY_SOCKS_USER=\"${XRAY_SOCKS_USER:-}\""
            print "    XRAY_SOCKS_PASS=\"${XRAY_SOCKS_PASS:-}\""
            print "    if [ -s \"$XRAY_DIR/vless-go-socks-auth.conf\" ]; then"
            print "        . \"$XRAY_DIR/vless-go-socks-auth.conf\""
            print "    fi"
            print "}"
            print ""
            print "socks_auth_enabled() {"
            print "    load_socks_auth_config"
            print "    [ \"${XRAY_SOCKS_AUTH:-0}\" = \"1\" ] && [ -n \"${XRAY_SOCKS_USER:-}\" ] && [ -n \"${XRAY_SOCKS_PASS:-}\" ]"
            print "}"
            print ""
            print "health_check() {"
            print "    ensure_dependencies || return 1"
            print "    for URL in $CHECK_URLS; do"
            print "        if socks_auth_enabled; then"
            print "            if curl -fsS --proxy-user \"$XRAY_SOCKS_USER:$XRAY_SOCKS_PASS\" --socks5-hostname \"$SOCKS_HOST:$SOCKS_PORT\" --connect-timeout \"$CONNECT_TIMEOUT\" --max-time \"$MAX_TIME\" \"$URL\" >/dev/null 2>&1; then"
            print "                return 0"
            print "            fi"
            print "        elif curl -fsS --socks5-hostname \"$SOCKS_HOST:$SOCKS_PORT\" --connect-timeout \"$CONNECT_TIMEOUT\" --max-time \"$MAX_TIME\" \"$URL\" >/dev/null 2>&1; then"
            print "            return 0"
            print "        fi"
            print "    done"
            print "    return 1"
            print "}"
            skip=1
            next
        }
        skip && /^}/ { skip=0; next }
        skip { next }
        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

patch_doctor_helper_auth() {
    file="$1"
    tmp="${file}.auth.$$"
    awk '
        /^check_socks_health\(\) \{/ {
            print "load_socks_auth_config() {"
            print "    XRAY_SOCKS_AUTH=\"${XRAY_SOCKS_AUTH:-0}\""
            print "    XRAY_SOCKS_USER=\"${XRAY_SOCKS_USER:-}\""
            print "    XRAY_SOCKS_PASS=\"${XRAY_SOCKS_PASS:-}\""
            print "    if [ -s \"$XRAY_DIR/vless-go-socks-auth.conf\" ]; then"
            print "        . \"$XRAY_DIR/vless-go-socks-auth.conf\""
            print "    fi"
            print "}"
            print ""
            print "socks_auth_enabled() {"
            print "    load_socks_auth_config"
            print "    [ \"${XRAY_SOCKS_AUTH:-0}\" = \"1\" ] && [ -n \"${XRAY_SOCKS_USER:-}\" ] && [ -n \"${XRAY_SOCKS_PASS:-}\" ]"
            print "}"
            print ""
            print "check_socks_health() {"
            print "    if ! has_cmd curl; then warn \"curl не найден; SOCKS health-check невозможен\"; return 0; fi"
            print "    if socks_auth_enabled; then"
            print "        ok \"SOCKS auth config найден; health-check использует proxy-user\""
            print "        if curl -fsS --proxy-user \"$XRAY_SOCKS_USER:$XRAY_SOCKS_PASS\" --socks5-hostname \"$SOCKS_HOST:$SOCKS_PORT\" --connect-timeout \"$CONNECT_TIMEOUT\" --max-time \"$MAX_TIME\" \"$CHECK_URL\" >/dev/null 2>/tmp/vless-go-doctor.curl.$$; then"
            print "            ok \"SOCKS health-check OK через $CHECK_URL\""
            print "        else"
            print "            warn \"SOCKS health-check не прошёл через $CHECK_URL\""
            print "            sed '\''s/^/  /'\'' /tmp/vless-go-doctor.curl.$$"
            print "        fi"
            print "    elif curl -fsS --socks5-hostname \"$SOCKS_HOST:$SOCKS_PORT\" --connect-timeout \"$CONNECT_TIMEOUT\" --max-time \"$MAX_TIME\" \"$CHECK_URL\" >/dev/null 2>/tmp/vless-go-doctor.curl.$$; then"
            print "        ok \"SOCKS health-check OK через $CHECK_URL\""
            print "    else"
            print "        warn \"SOCKS health-check не прошёл через $CHECK_URL\""
            print "        sed '\''s/^/  /'\'' /tmp/vless-go-doctor.curl.$$"
            print "    fi"
            print "    rm -f /tmp/vless-go-doctor.curl.$$ 2>/dev/null || true"
            print "}"
            skip=1
            next
        }
        skip && /^}/ { skip=0; next }
        skip { next }
        { print }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
}

patch_staged_helper_auth() {
    file="$1"
    label="$2"
    case "$(basename "$file")" in
        vless-go-recover)
            echo "Patching $label for SOCKS auth-aware health-check"
            patch_recover_helper_auth "$file"
            ;;
        vless-go-doctor)
            echo "Patching $label for SOCKS auth-aware health-check"
            patch_doctor_helper_auth "$file"
            ;;
    esac
}

list_profile() {
    script="$(profile_script_path)"
    "$script" "$PROFILE"
}

print_plan() {
    echo "== xray-go helper profile =="
    echo "Profile: $PROFILE"
    echo "Mode: $MODE"
    echo "Stage dir: $STAGE_DIR"
    echo "Helper index: $HELPER_INDEX"
    echo
    echo "-- Helpers --"
    list_profile
    echo
    case "$PROFILE" in
        minimal|full-lite|lite)
            if list_profile | grep -q 'vless-go-xray-core-update'; then
                echo "[FAIL] policy violation: xray-core updater appears in $PROFILE" >&2
                exit 1
            fi
            echo "[OK] policy: xray-core updater excluded from $PROFILE"
            ;;
        manual|maintenance|full)
            echo "[INFO] manual/full profile may include xray-core updater"
            ;;
    esac
}

stage_and_install_helpers() {
    [ "$MODE" = "apply" ] || return 0
    mkdir -p "$STAGE_DIR"
    tmp_index="${HELPER_INDEX}.$$"
    : > "$tmp_index"

    list_profile | while IFS='|' read -r mode dest url label; do
        [ -n "${dest:-}" ] || continue
        staged="${STAGE_DIR}/$(basename "$dest")"
        echo "Staging $label: $staged"
        fetch_url "$url" "$staged"
        patch_staged_helper_auth "$staged" "$label"
        verify_shell_helper "$staged" "$label"
        case "$mode" in
            exec) chmod +x "$staged" ;;
            read) chmod 644 "$staged" ;;
            *) echo "ERROR: unsupported helper mode: $mode" >&2; exit 1 ;;
        esac
        helper_sha="$(sha256_file "$staged")"
        printf '%s|%s|%s|%s|%s\n' "$mode" "$dest" "$staged" "$helper_sha" "$label" >> "$tmp_index"
    done

    chmod 600 "$tmp_index" 2>/dev/null || true
    mv "$tmp_index" "$HELPER_INDEX"

    while IFS='|' read -r mode dest staged helper_sha label; do
        [ -n "${dest:-}" ] || continue
        [ -s "$staged" ] || { echo "ERROR: missing staged helper: $staged" >&2; exit 1; }
        mkdir -p "$(dirname "$dest")"
        tmp_dest="$(dirname "$dest")/.$(basename "$dest").$$"
        echo "Installing $label: $dest"
        cp "$staged" "$tmp_dest"
        case "$mode" in
            exec) chmod +x "$tmp_dest" ;;
            read) chmod 644 "$tmp_dest" ;;
            *) echo "ERROR: unsupported helper mode: $mode" >&2; rm -f "$tmp_dest" 2>/dev/null || true; exit 1 ;;
        esac
        mv "$tmp_dest" "$dest"
    done < "$HELPER_INDEX"

    install_profile_helper
    echo "Helper profile installed: $PROFILE"
    cleanup_stage_dir
}

print_plan
stage_and_install_helpers

if [ "$MODE" = "dry-run" ]; then
    echo "Dry-run: no changes made."
fi
