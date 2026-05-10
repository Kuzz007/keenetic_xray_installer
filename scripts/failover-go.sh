#!/bin/sh
set -e

XRAY_DIR="/opt/etc/xray"
ACTIVE_STORE="$XRAY_DIR/vless-go.active"
PRIMARY_STORE="$XRAY_DIR/vless-go.primary"
BACKUP_STORE="$XRAY_DIR/vless-go.backup"
WATCHDOG_CONF="$XRAY_DIR/vless-go-watchdog.conf"
WATCHDOG_LOG="/opt/var/log/vless-go-watchdog.log"
WATCHDOG_INIT="/opt/etc/init.d/S26vless-go-watchdog"
XRAY_CORE_UPDATE_CMD="/opt/bin/vless-go-xray-core-update"
GO_UPDATE_CMD="/opt/bin/vless-go-update"
GO_AUTO_UPDATE_CMD="/opt/bin/vless-go-auto-update"
GO_FAILOVER_CMD="/opt/bin/vless-go-failover"
GO_WATCHDOG_CMD="/opt/bin/vless-go-watchdog"
GO_DOCTOR_CMD="/opt/bin/vless-go-doctor"
GO_INSTALLER_UPDATE_CMD="/opt/bin/xray-go-installer-update"

read_tty() {
    prompt="$1"
    if [ -r /dev/tty ]; then
        printf "%s" "$prompt" >/dev/tty
        IFS= read -r REPLY </dev/tty
    else
        printf "%s" "$prompt" >&2
        IFS= read -r REPLY
    fi
}

pause() {
    read_tty "Press Enter to continue..."
}

require_cmd() {
    if [ ! -x "$1" ]; then
        echo "ERROR: command not found or not executable: $1" >&2
        return 1
    fi
    return 0
}

show_header() {
    clear 2>/dev/null || true
    echo "========================================"
    echo " VLESS Go / Xray failover menu"
    echo "========================================"
    echo
}

active_slot() {
    if [ -s "$ACTIVE_STORE" ]; then
        sed -n '1p' "$ACTIVE_STORE"
    else
        echo "primary"
    fi
}

slot_configured() {
    case "$1" in
        primary) [ -s "$PRIMARY_STORE" ] ;;
        backup) [ -s "$BACKUP_STORE" ] ;;
        *) return 1 ;;
    esac
}

selector_file() {
    case "$1" in
        primary|backup) echo "$XRAY_DIR/vless-go.$1.selector" ;;
        *) return 1 ;;
    esac
}

read_selector() {
    FILE="$(selector_file "$1")" || return 1
    VALUE="$(sed -n '1p' "$FILE" 2>/dev/null || true)"
    echo "${VALUE:-first}"
}

prompt_selector() {
    SLOT="$1"
    CURRENT="$(read_selector "$SLOT" 2>/dev/null || echo first)"
    echo "Current $SLOT selector: $CURRENT"
    echo "Selector controls which profile is used when a subscription contains multiple VLESS links."
    echo "Supported values: first, index:N"
    echo
    read_tty "Enter selector for $SLOT [default: $CURRENT]: "
    VALUE="$REPLY"
    if [ -z "$VALUE" ]; then
        VALUE="$CURRENT"
    fi
    case "$VALUE" in
        first|index:[1-9]*)
            echo "$VALUE"
            ;;
        *)
            echo "ERROR: invalid selector: $VALUE" >&2
            return 1
            ;;
    esac
}

show_status() {
    show_header
    echo "[Status]"
    if require_cmd "$GO_FAILOVER_CMD"; then
        "$GO_FAILOVER_CMD" status || true
    fi
    echo
    if require_cmd "$GO_WATCHDOG_CMD"; then
        "$GO_WATCHDOG_CMD" status || true
    fi
    echo
    pause
}

run_doctor() {
    show_header
    echo "[Doctor diagnostics]"
    if require_cmd "$GO_DOCTOR_CMD"; then
        "$GO_DOCTOR_CMD" || true
    fi
    echo
    pause
}

switch_slot() {
    SLOT="$1"
    show_header
    echo "[Switch to $SLOT]"
    if require_cmd "$GO_FAILOVER_CMD"; then
        "$GO_FAILOVER_CMD" switch "$SLOT"
    fi
    echo
    pause
}

replace_source() {
    SLOT="$1"
    show_header
    echo "[Add/replace $SLOT VLESS link or subscription URL]"
    echo "Current value will not be printed."
    echo
    read_tty "Enter new $SLOT VLESS link or subscription URL: "
    VALUE="$REPLY"
    if [ -z "$VALUE" ]; then
        echo "Canceled: empty value."
        pause
        return 0
    fi

    SELECTOR="$(prompt_selector "$SLOT")" || { pause; return 1; }

    if require_cmd "$GO_FAILOVER_CMD"; then
        "$GO_FAILOVER_CMD" "set-$SLOT" "$VALUE" --selector "$SELECTOR"
    fi

    echo
    read_tty "Switch to $SLOT now? [y/N]: "
    case "$REPLY" in
        y|Y|yes|YES)
            "$GO_FAILOVER_CMD" switch "$SLOT"
            ;;
        *)
            echo "Saved only. You can switch later from the menu."
            ;;
    esac
    echo
    pause
}

set_slot_selector() {
    SLOT="$1"
    show_header
    echo "[Set $SLOT profile selector]"
    if ! require_cmd "$GO_FAILOVER_CMD"; then
        pause
        return 0
    fi
    SELECTOR="$(prompt_selector "$SLOT")" || { pause; return 1; }
    "$GO_FAILOVER_CMD" set-selector "$SLOT" "$SELECTOR"
    echo
    read_tty "Apply $SLOT now with this selector? [y/N]: "
    case "$REPLY" in
        y|Y|yes|YES) "$GO_FAILOVER_CMD" switch "$SLOT" ;;
        *) echo "Selector saved only." ;;
    esac
    echo
    pause
}

update_all_sources() {
    show_header
    echo "[Update primary and backup subscriptions now]"
    if ! require_cmd "$GO_FAILOVER_CMD"; then
        pause
        return 0
    fi

    ORIGINAL="$(active_slot)"
    echo "Original active slot: $ORIGINAL"
    echo

    UPDATED="0"

    if slot_configured primary; then
        echo "Updating/validating primary without restart..."
        "$GO_FAILOVER_CMD" switch primary --no-restart
        UPDATED="1"
        echo
    else
        echo "Primary source is not configured; skipping."
    fi

    if slot_configured backup; then
        echo "Updating/validating backup without restart..."
        "$GO_FAILOVER_CMD" switch backup --no-restart
        UPDATED="1"
        echo
    else
        echo "Backup source is not configured; skipping."
    fi

    if [ "$UPDATED" = "0" ]; then
        echo "Nothing was updated."
        pause
        return 0
    fi

    case "$ORIGINAL" in
        primary|backup)
            echo "Restoring active slot: $ORIGINAL"
            "$GO_FAILOVER_CMD" switch "$ORIGINAL"
            ;;
        *)
            echo "Unknown original active slot: $ORIGINAL"
            echo "Leaving the last validated slot active."
            ;;
    esac

    echo
    pause
}

configure_auto_update() {
    show_header
    echo "[Subscription auto-update]"
    if ! require_cmd "$GO_AUTO_UPDATE_CMD"; then
        pause
        return 0
    fi

    "$GO_AUTO_UPDATE_CMD" status || true
    echo
    echo "1. Enable daily auto-update with default schedule"
    echo "2. Enable with custom cron schedule"
    echo "3. Disable auto-update"
    echo "4. Run auto-update now"
    echo "0. Back"
    echo
    read_tty "Choose: "
    case "$REPLY" in
        1) "$GO_AUTO_UPDATE_CMD" enable ;;
        2)
            read_tty "Enter cron schedule, for example '17 4 * * *': "
            [ -n "$REPLY" ] && "$GO_AUTO_UPDATE_CMD" enable "$REPLY" || echo "Canceled."
            ;;
        3) "$GO_AUTO_UPDATE_CMD" disable ;;
        4) "$GO_AUTO_UPDATE_CMD" run ;;
        0) return 0 ;;
        *) echo "Unknown choice." ;;
    esac
    echo
    pause
}

toggle_recovery() {
    show_header
    echo "[Backup -> primary auto-recovery]"
    if [ ! -f "$WATCHDOG_CONF" ]; then
        echo "ERROR: watchdog config not found: $WATCHDOG_CONF" >&2
        pause
        return 1
    fi

    CURRENT="$(grep '^AUTO_RECOVER_PRIMARY=' "$WATCHDOG_CONF" 2>/dev/null | tail -n 1 | cut -d= -f2 || true)"
    CURRENT="${CURRENT:-0}"
    echo "Current AUTO_RECOVER_PRIMARY=$CURRENT"
    echo
    if [ "$CURRENT" = "1" ]; then
        read_tty "Disable backup -> primary auto-recovery? [y/N]: "
        case "$REPLY" in
            y|Y|yes|YES) sed -i 's/^AUTO_RECOVER_PRIMARY=.*/AUTO_RECOVER_PRIMARY=0/' "$WATCHDOG_CONF" ;;
            *) echo "No change."; pause; return 0 ;;
        esac
    else
        read_tty "Enable backup -> primary auto-recovery? [y/N]: "
        case "$REPLY" in
            y|Y|yes|YES)
                if grep -q '^AUTO_RECOVER_PRIMARY=' "$WATCHDOG_CONF"; then
                    sed -i 's/^AUTO_RECOVER_PRIMARY=.*/AUTO_RECOVER_PRIMARY=1/' "$WATCHDOG_CONF"
                else
                    echo 'AUTO_RECOVER_PRIMARY=1' >> "$WATCHDOG_CONF"
                fi
                ;;
            *) echo "No change."; pause; return 0 ;;
        esac
    fi

    if [ -x "$WATCHDOG_INIT" ]; then
        "$WATCHDOG_INIT" restart || true
    else
        echo "WARNING: watchdog init not found: $WATCHDOG_INIT" >&2
    fi
    echo
    pause
}

show_watchdog_log() {
    show_header
    echo "[Watchdog log]"
    if [ -s "$WATCHDOG_LOG" ]; then
        tail -n 80 "$WATCHDOG_LOG"
    else
        echo "Log is empty or missing: $WATCHDOG_LOG"
    fi
    echo
    pause
}

follow_watchdog_log() {
    show_header
    echo "[Watchdog log: live follow]"
    echo "Press Ctrl+C to stop following and return to shell/menu."
    echo
    if [ -e "$WATCHDOG_LOG" ]; then
        tail -n 50 -f "$WATCHDOG_LOG"
    else
        echo "Log is missing: $WATCHDOG_LOG"
        pause
    fi
}

update_go_edition() {
    show_header
    echo "[Update Go edition]"
    if require_cmd "$GO_INSTALLER_UPDATE_CMD"; then
        "$GO_INSTALLER_UPDATE_CMD" --first
    fi
    echo
    pause
}

update_xray_core() {
    show_header
    echo "[Update Xray-core]"
    if [ -x "$XRAY_CORE_UPDATE_CMD" ]; then
        "$XRAY_CORE_UPDATE_CMD"
    else
        echo "Xray-core GitHub updater is not implemented in Go edition yet."
        echo "Planned command: $XRAY_CORE_UPDATE_CMD"
        echo "This menu item is reserved for the next roadmap PR."
    fi
    echo
    pause
}

show_menu() {
    show_header
    echo "1. Status"
    echo "2. Doctor diagnostics"
    echo "3. Switch to primary"
    echo "4. Switch to backup"
    echo "5. Add/replace primary VLESS/subscription URL"
    echo "6. Add/replace backup VLESS/subscription URL"
    echo "7. Set primary profile selector"
    echo "8. Set backup profile selector"
    echo "9. Update primary and backup subscriptions now"
    echo "10. Configure cron auto-update"
    echo "11. Enable/disable backup -> primary recovery"
    echo "12. Show watchdog log"
    echo "13. Follow watchdog log live"
    echo "14. Update Go edition"
    echo "15. Update Xray-core"
    echo "0. Exit"
    echo
}

while true; do
    show_menu
    read_tty "Choose: "
    case "$REPLY" in
        1) show_status ;;
        2) run_doctor ;;
        3) switch_slot primary ;;
        4) switch_slot backup ;;
        5) replace_source primary ;;
        6) replace_source backup ;;
        7) set_slot_selector primary ;;
        8) set_slot_selector backup ;;
        9) update_all_sources ;;
        10) configure_auto_update ;;
        11) toggle_recovery ;;
        12) show_watchdog_log ;;
        13) follow_watchdog_log ;;
        14) update_go_edition ;;
        15) update_xray_core ;;
        0|q|Q|exit|quit) exit 0 ;;
        *) echo "Unknown choice."; sleep 1 ;;
    esac
done
