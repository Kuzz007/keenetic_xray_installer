profile_external_ip() {
    HOST="$1"
    PORT="$2"
    curl -k -sS \
        --socks5-hostname "$HOST:$PORT" \
        --connect-timeout 5 \
        --max-time 10 \
        "$IP_CHECK_URL" 2>/dev/null || true
}

test_https_healthcheck_through_socks() {
    HOST="$1"
    PORT="$2"
    HTTP_CODE="$(curl -k -sS \
        --socks5-hostname "$HOST:$PORT" \
        --connect-timeout 5 \
        --max-time 10 \
        -o /dev/null \
        -w '%{http_code}' \
        "$DNS_CHECK_URL" 2>/dev/null || true)"
    [ "$HTTP_CODE" = "204" ]
}

test_socks_endpoint() {
    HOST="$1"
    PORT="$2"
    OK_COUNT="0"

    for URL in $CHECK_URLS; do
        RESULT="$(curl -k -sS \
            --socks5-hostname "$HOST:$PORT" \
            --connect-timeout 5 \
            --max-time 10 \
            -o /dev/null \
            -w 'url=%{url_effective} http_code=%{http_code} time_total=%{time_total}' \
            "$URL" 2>/dev/null || true)"

        echo "$RESULT"
        HTTP_CODE="$(echo "$RESULT" | sed -n 's/.*http_code=\([0-9][0-9][0-9]\).*/\1/p')"

        case "$HTTP_CODE" in
            204|200|301|302)
                OK_COUNT="$((OK_COUNT + 1))"
                ;;
        esac
    done

    if [ "$OK_COUNT" -gt 0 ]; then
        EXT_IP="$(profile_external_ip "$HOST" "$PORT")"
        if [ -n "$EXT_IP" ]; then
            echo "Внешний IP через туннель: $EXT_IP"
        else
            echo "Внешний IP через туннель: не удалось определить"
        fi

        if test_https_healthcheck_through_socks "$HOST" "$PORT"; then
            echo "Дополнительная HTTPS-проверка через туннель: OK"
        else
            echo "Дополнительная HTTPS-проверка через туннель: нестабильна"
        fi
        return 0
    fi

    return 1
}
